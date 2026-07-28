import Foundation
import SQLite3

/// Read-only access to Mail's own index, `~/Library/Mail/V*/MailData/Envelope
/// Index`. This is the whole reason the file-system path exists: the same
/// search that takes AppleScript ~120s (and then returns an empty list rather
/// than an error) is a single indexed query here, and it works with Mail.app
/// closed.
///
/// Needs Full Disk Access rather than Automation → Mail. See `MailStore` for
/// how that trade is presented to the caller.

public enum EnvelopeIndexError: Error, LocalizedError {
  case unavailable(String)
  case query(String)
  case notFound(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    case .query(let message): return message
    case .notFound(let message): return message
    }
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Mailboxes

/// One row of the `mailboxes` table, with its URL taken apart.
public struct MailboxRef: Sendable {
  public let rowid: Int64
  public let url: String
  public let accountUUID: String
  public let scheme: String
  /// Percent-decoded path, e.g. ["[Gmail]", "Trash"].
  public let components: [String]
  public let totalCount: Int
  public let unreadCount: Int

  public var name: String { components.last ?? "" }
  public var path: String { components.joined(separator: "/") }
  public var isTrash: Bool { MailboxNames.trash.contains(name.lowercased()) }
  public var isJunk: Bool { MailboxNames.junk.contains(name.lowercased()) }
}

/// Mailbox names vary by account type — IMAP calls it "Deleted Messages",
/// Exchange "Deleted Items", Gmail "[Gmail]/Trash" — so every lookup here is
/// by a set of known spellings rather than one canonical string.
public enum MailboxNames {
  public static let trash: Set<String> = [
    "trash", "deleted messages", "deleted items", "bin",
  ]
  public static let junk: Set<String> = [
    "junk", "junk mail", "junk email", "junk e-mail", "spam", "bulk mail",
  ]
  /// User-facing aliases accepted by `--mailbox`.
  public static let aliases: [String: Set<String>] = [
    "inbox": ["inbox"],
    "sent": ["sent messages", "sent items", "sent mail", "sent"],
    "drafts": ["drafts", "draft"],
    "archive": ["archive", "all mail"],
    "trash": trash,
    "junk": junk,
  ]

  /// The set of concrete mailbox names a user-supplied `--mailbox` should
  /// match. An unknown name matches only itself.
  public static func matching(_ input: String) -> Set<String> {
    let key = input.lowercased()
    return aliases[key] ?? [key]
  }
}

/// Parse `imap://<ACCOUNT-UUID>/Sent%20Messages` into its parts. Returns nil
/// for a URL with no path, which would otherwise produce a nameless mailbox.
public func parseMailboxURL(rowid: Int64, url: String, totalCount: Int, unreadCount: Int)
  -> MailboxRef?
{
  guard let separator = url.range(of: "://") else { return nil }
  let scheme = String(url[url.startIndex..<separator.lowerBound])
  var parts = url[separator.upperBound...].components(separatedBy: "/")
  guard !parts.isEmpty else { return nil }
  let accountUUID = parts.removeFirst()
  let components = parts.compactMap { $0.removingPercentEncoding ?? $0 }.filter { !$0.isEmpty }
  guard !components.isEmpty else { return nil }
  return MailboxRef(
    rowid: rowid, url: url, accountUUID: accountUUID, scheme: scheme,
    components: components, totalCount: totalCount, unreadCount: unreadCount)
}

/// Directory digits Mail inserts between `Data/` and `Messages/` for a message
/// ROWID: the digits of rowid/1000, least-significant first. 84 -> [] (a flat
/// `Data/Messages`), 12345 -> ["2","1"], 105895 -> ["5","0","1"].
public func emlxSubdirectories(forRowID rowid: Int64) -> [String] {
  var quotient = rowid / 1000
  var digits: [String] = []
  while quotient > 0 {
    digits.append(String(quotient % 10))
    quotient /= 10
  }
  return digits
}

/// Escape the LIKE metacharacters so a query term matches literally. Pair with
/// `ESCAPE '\'`; without it a search for "50%" matches everything.
public func escapeLikePattern(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "%", with: "\\%")
    .replacingOccurrences(of: "_", with: "\\_")
}

/// Mail keeps "Re: " / "Fwd: " in `messages.subject_prefix` and the rest in
/// `subjects.subject`; neither alone is what the user saw.
public func fullSubject(prefix: String?, subject: String?) -> String {
  (prefix ?? "") + (subject ?? "")
}

/// Render a sender the way the AppleScript path does: `Name <addr>`, or the
/// bare address when Mail recorded no display name.
public func formatAddress(address: String, comment: String) -> String {
  let name = comment.trimmingCharacters(in: .whitespaces)
  return name.isEmpty ? address : "\(name) <\(address)>"
}

// MARK: - The index

public final class EnvelopeIndex {
  private var db: OpaquePointer?
  /// e.g. ~/Library/Mail/V10
  public let versionDirectory: URL
  public let databasePath: URL
  /// True when the WAL had to be bypassed, so reads may miss recent mail.
  public private(set) var isStale = false

  /// Newest `~/Library/Mail/V<n>/MailData/Envelope Index` that we can read.
  public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
    let mailDirectory = home.appendingPathComponent("Library/Mail")
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: mailDirectory, includingPropertiesForKeys: nil)
    else { return nil }
    let versioned = entries.compactMap { url -> (Int, URL)? in
      let name = url.lastPathComponent
      guard name.hasPrefix("V"), let version = Int(name.dropFirst()) else { return nil }
      return (version, url)
    }
    for (_, directory) in versioned.sorted(by: { $0.0 > $1.0 }) {
      let candidate = directory.appendingPathComponent("MailData/Envelope Index")
      if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  public static func open(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> EnvelopeIndex
  {
    guard let path = discover(home: home) else {
      throw EnvelopeIndexError.unavailable(
        "No readable Envelope Index under ~/Library/Mail/V*. Reading it needs Full Disk "
          + "Access for this terminal (System Settings → Privacy & Security → Full Disk Access).")
    }
    return try EnvelopeIndex(path: path)
  }

  public init(path: URL) throws {
    databasePath = path
    versionDirectory = path.deletingLastPathComponent().deletingLastPathComponent()

    // The index is in WAL mode, and Mail leaves a multi-megabyte -wal behind
    // even when it is not running. A plain read-only open replays that WAL, so
    // it sees today's mail; `immutable=1` does not, and would silently serve a
    // view of the database from whenever the last checkpoint happened. So it is
    // only ever a fallback, and it sets `isStale` when used.
    guard let encoded = path.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else {
      throw EnvelopeIndexError.unavailable("Cannot encode database path: \(path.path)")
    }
    let readOnly = "file://\(encoded)?mode=ro"
    var handle: OpaquePointer?
    var status = sqlite3_open_v2(
      readOnly, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)

    if status != SQLITE_OK {
      if let handle { sqlite3_close_v2(handle) }
      handle = nil
      // A read-only connection needs the -shm file to replay the WAL; if Mail
      // holds it in a way we cannot map, immutable is better than nothing as
      // long as the staleness is reported rather than hidden.
      status = sqlite3_open_v2(
        "file://\(encoded)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
      isStale = status == SQLITE_OK
    }

    guard status == SQLITE_OK, let opened = handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
      if let handle { sqlite3_close_v2(handle) }
      throw EnvelopeIndexError.unavailable("Cannot open the Envelope Index: \(message)")
    }
    db = opened
    sqlite3_busy_timeout(opened, 1000)
    sqlite3_exec(opened, "PRAGMA query_only = 1", nil, nil, nil)
  }

  deinit {
    if let db { sqlite3_close_v2(db) }
  }

  // MARK: Low-level query

  public enum Bind {
    case int(Int64)
    case text(String)
  }

  /// Rows keyed by column name. NULL and BLOB columns are omitted rather than
  /// mapped to a sentinel, so `row["x"] as? String` means "present and text".
  public func query(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw EnvelopeIndexError.query(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    for (offset, bind) in binds.enumerated() {
      let index = Int32(offset + 1)
      switch bind {
      case .int(let value): sqlite3_bind_int64(statement, index, value)
      case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
      }
    }

    var rows: [[String: Any]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw EnvelopeIndexError.query(String(cString: sqlite3_errmsg(db)))
      }
      var row: [String: Any] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
        case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
        case SQLITE_TEXT:
          if let text = sqlite3_column_text(statement, column) {
            row[name] = String(cString: text)
          }
        default: break
        }
      }
      rows.append(row)
    }
    return rows
  }

  // MARK: Mailboxes and accounts

  public func mailboxes() throws -> [MailboxRef] {
    try query("SELECT ROWID, url, total_count, unread_count FROM mailboxes").compactMap { row in
      guard let rowid = row["ROWID"] as? Int64, let url = row["url"] as? String else { return nil }
      return parseMailboxURL(
        rowid: rowid, url: url,
        totalCount: Int(row["total_count"] as? Int64 ?? 0),
        unreadCount: Int(row["unread_count"] as? Int64 ?? 0))
    }
  }

  private var accountCache: [String: MailAccountInfo]?

  /// Account UUID -> display name and address, from the system Accounts store.
  ///
  /// Mail's per-protocol account row usually carries no description of its own
  /// and points at a parent account that has one — that parent is where the
  /// names the user actually sees (here: emoji) live. Reading only the child
  /// row yields blanks, so the parent is joined in.
  public func accounts() -> [String: MailAccountInfo] {
    if let accountCache { return accountCache }
    var result: [String: MailAccountInfo] = [:]
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
    var handle: OpaquePointer?
    if sqlite3_open_v2("file://\(path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
      == SQLITE_OK, let handle
    {
      defer { sqlite3_close_v2(handle) }
      let sql = """
        SELECT child.ZIDENTIFIER,
               COALESCE(NULLIF(child.ZACCOUNTDESCRIPTION, ''), parent.ZACCOUNTDESCRIPTION),
               COALESCE(NULLIF(child.ZUSERNAME, ''), parent.ZUSERNAME)
        FROM ZACCOUNT child
        LEFT JOIN ZACCOUNT parent ON child.ZPARENTACCOUNT = parent.Z_PK
        WHERE child.ZIDENTIFIER IS NOT NULL
        """
      var statement: OpaquePointer?
      if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement {
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
          guard let identifier = sqlite3_column_text(statement, 0) else { continue }
          let uuid = String(cString: identifier)
          let name = sqlite3_column_text(statement, 1).map { String(cString: $0) }
          let address = sqlite3_column_text(statement, 2).map { String(cString: $0) }
          result[uuid] = MailAccountInfo(
            uuid: uuid, name: name?.isEmpty == false ? name! : uuid, address: address)
        }
      }
    } else if let handle {
      sqlite3_close_v2(handle)
    }
    accountCache = result
    return result
  }

  public func displayName(forAccount uuid: String) -> String {
    accounts()[uuid]?.name ?? uuid
  }

  /// UUIDs whose display name, address, or UUID matches what the user typed.
  public func accountUUIDs(matching input: String) throws -> [String] {
    let target = input.lowercased()
    let known = accounts()
    let present = Set(try mailboxes().map(\.accountUUID))
    return
      present
      .filter { uuid in
        if uuid.lowercased() == target { return true }
        guard let info = known[uuid] else { return false }
        return info.name.lowercased() == target || info.address?.lowercased() == target
      }
      .sorted()
  }

  // MARK: Messages

  private static let columns = """
    m.ROWID AS rowid, g.message_id_header AS message_id,
    a.address AS sender_address, a.comment AS sender_comment,
    m.subject_prefix AS subject_prefix, s.subject AS subject,
    m.date_received AS date_received, m.date_sent AS date_sent,
    m.read AS read, m.flagged AS flagged, b.url AS mailbox_url,
    (SELECT COUNT(*) FROM attachments att WHERE att.message = m.ROWID) AS attachment_count,
    (SELECT group_concat(att.name, ' ') FROM attachments att WHERE att.message = m.ROWID)
      AS attachment_names
    """

  private static let joins = """
    FROM messages m
    JOIN message_global_data g ON m.global_message_id = g.ROWID
    JOIN mailboxes b ON m.mailbox = b.ROWID
    LEFT JOIN subjects s ON m.subject = s.ROWID
    LEFT JOIN addresses a ON m.sender = a.ROWID
    """

  public struct Filter {
    public var mailboxRowIDs: [Int64]?
    public var unreadOnly = false
    public var flaggedOnly = false
    public var withAttachmentsOnly = false
    public var since: Date?
    public var before: Date?
    /// Terms that must **all** match. Empty means "no text predicate", which
    /// is what a content search needs since the body is not in this database.
    public var terms: [String] = []
    /// One of subject, sender, all. Ignored when `terms` is empty.
    public var field = "subject"
    /// Also match a term against attachment *filenames*. Off by default:
    /// searching for "invoice" should find messages about invoices, not every
    /// message that happens to carry a file called invoice.pdf. Attachment
    /// *contents* are never searched, with or without this.
    public var matchAttachmentNames = false

    public init() {}
  }

  public func messages(filter: Filter, limit: Int?) throws -> [[String: Any]] {
    // `deleted` is Mail's own tombstone; rows survive it, and including them
    // resurrects mail the user deleted. A missing Message-ID means the row
    // cannot be addressed by `export`, so it is dropped too.
    var conditions = ["m.deleted = 0", "g.message_id_header IS NOT NULL"]
    var binds: [Bind] = []

    if let rowIDs = filter.mailboxRowIDs {
      guard !rowIDs.isEmpty else { return [] }
      conditions.append("m.mailbox IN (\(rowIDs.map { _ in "?" }.joined(separator: ",")))")
      binds.append(contentsOf: rowIDs.map { Bind.int($0) })
    }
    if filter.unreadOnly { conditions.append("m.read = 0") }
    if filter.flaggedOnly { conditions.append("m.flagged = 1") }
    if filter.withAttachmentsOnly {
      conditions.append("EXISTS (SELECT 1 FROM attachments att WHERE att.message = m.ROWID)")
    }
    if let since = filter.since {
      conditions.append("m.date_received >= ?")
      binds.append(.int(Int64(since.timeIntervalSince1970)))
    }
    if let before = filter.before {
      conditions.append("m.date_received <= ?")
      binds.append(.int(Int64(before.timeIntervalSince1970)))
    }
    // Every term gets its own condition, ANDed: `budget review` means both
    // words appear, each possibly in a different place.
    let subject = "(COALESCE(m.subject_prefix, '') || COALESCE(s.subject, ''))"
    let attachmentMatch =
      "EXISTS (SELECT 1 FROM attachments att WHERE att.message = m.ROWID "
      + "AND att.name LIKE ? ESCAPE '\\')"
    for term in filter.terms where !term.isEmpty {
      let pattern = "%\(escapeLikePattern(term))%"
      var alternatives: [String] = []
      switch filter.field {
      case "sender":
        alternatives = ["a.address LIKE ? ESCAPE '\\'", "a.comment LIKE ? ESCAPE '\\'"]
        binds.append(contentsOf: [.text(pattern), .text(pattern)])
      case "subject":
        alternatives = ["\(subject) LIKE ? ESCAPE '\\'"]
        binds.append(.text(pattern))
      default:
        alternatives = [
          "\(subject) LIKE ? ESCAPE '\\'", "a.address LIKE ? ESCAPE '\\'",
          "a.comment LIKE ? ESCAPE '\\'",
        ]
        binds.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern)])
      }
      if filter.matchAttachmentNames {
        alternatives.append(attachmentMatch)
        binds.append(.text(pattern))
      }
      conditions.append("(" + alternatives.joined(separator: " OR ") + ")")
    }

    var sql = """
      SELECT \(Self.columns)
      \(Self.joins)
      WHERE \(conditions.joined(separator: " AND "))
      ORDER BY m.date_received DESC
      """
    if let limit {
      sql += "\nLIMIT ?"
      binds.append(.int(Int64(limit)))
    }
    return try query(sql, binds)
  }

  /// Every non-deleted copy of a Message-ID, newest first. The same message can
  /// exist in several mailboxes and accounts.
  public func messages(withMessageID header: String) throws -> [[String: Any]] {
    try query(
      """
      SELECT \(Self.columns)
      \(Self.joins)
      WHERE g.message_id_header = ? AND m.deleted = 0
      ORDER BY m.date_received DESC
      """, [.text(header)])
  }

  /// `type` 0 is To, 1 is Cc, 2 is Bcc.
  public func recipients(ofMessage rowid: Int64) throws -> (to: [String], cc: [String]) {
    let rows = try query(
      """
      SELECT r.type AS type, a.address AS address, a.comment AS comment
      FROM recipients r JOIN addresses a ON r.address = a.ROWID
      WHERE r.message = ? ORDER BY r.position
      """, [.int(rowid)])
    var to: [String] = []
    var cc: [String] = []
    for row in rows {
      let formatted = formatAddress(
        address: row["address"] as? String ?? "", comment: row["comment"] as? String ?? "")
      if (row["type"] as? Int64 ?? 0) == 1 { cc.append(formatted) } else { to.append(formatted) }
    }
    return (to, cc)
  }

  public func attachmentNames(ofMessage rowid: Int64) throws -> [String] {
    try query("SELECT name FROM attachments WHERE message = ? ORDER BY ROWID", [.int(rowid)])
      .compactMap { $0["name"] as? String }
  }

  public func messageCount() throws -> Int {
    Int(try query("SELECT COUNT(*) AS n FROM messages WHERE deleted = 0").first?["n"] as? Int64 ?? 0)
  }

  // MARK: .emlx lookup

  /// `V10/<account>/<Mailbox>.mbox/<store-uuid>/Data/<digits>/Messages/<rowid>.emlx`.
  /// The store directory is a UUID we have no record of, so it is globbed. A
  /// message that has not been downloaded has no file at all.
  public func emlxPath(ofMessage rowid: Int64, in mailbox: MailboxRef) -> URL? {
    var directory = versionDirectory.appendingPathComponent(mailbox.accountUUID)
    for component in mailbox.components {
      directory = directory.appendingPathComponent(component + ".mbox")
    }
    guard
      let stores = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return nil }

    let subdirectories = emlxSubdirectories(forRowID: rowid)
    for store in stores where store.hasDirectoryPath {
      var messages = store.appendingPathComponent("Data")
      for part in subdirectories { messages = messages.appendingPathComponent(part) }
      messages = messages.appendingPathComponent("Messages")
      // `.partial.emlx` is a message whose body was only partly fetched; it
      // still parses, and it is better than reporting the message missing.
      for name in ["\(rowid).emlx", "\(rowid).partial.emlx"] {
        let candidate = messages.appendingPathComponent(name)
        if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
      }
    }
    return nil
  }
}

public struct MailAccountInfo: Sendable {
  public let uuid: String
  public let name: String
  public let address: String?
}
