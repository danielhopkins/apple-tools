import AppleToolsSearch
import Foundation

/// Search and export against `chat.db`. Nothing here talks to Messages.app, so
/// it works with Messages closed.

// MARK: - Model

/// A conversation. `style` 45 is one-to-one, 43 is a group — Messages' own
/// spelling, kept as a boolean because nothing outside needs the number.
public struct Chat: Sendable {
  public let rowid: Int64
  public let guid: String
  /// `chat123...` for a group, a phone number or email for a direct chat.
  public let identifier: String
  /// The user-set group name, when there is one.
  public let displayName: String?
  public let isGroup: Bool
  public let service: String?
  public let participants: [String]
  public let messageCount: Int
  public let lastMessageDate: Date?

  /// What to show in a list: the group name if set, otherwise the participants,
  /// otherwise the raw identifier. An unnamed group is extremely common — 2 of
  /// every 3 groups on a real store — so falling back to the roster matters.
  public var title: String {
    if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
      return displayName
    }
    if !participants.isEmpty {
      return participants.joined(separator: ", ")
    }
    return identifier
  }
}

/// Why a row exists. Most are `.message`; the rest are the things that make a
/// naive `SELECT text` look like it has holes in it.
public enum MessageKind: String, Sendable {
  case message
  /// A "Loved"/"Liked" reaction attached to another message.
  case tapback
  /// Someone joined or left, or the group was renamed.
  case systemEvent
  /// A rich-link preview, a sticker, ScreenTime, Find My, and similar.
  case appMessage
}

public struct Attachment: Sendable {
  public let rowid: Int64
  public let filename: String?
  public let path: URL?
  public let mimeType: String?
  public let totalBytes: Int64
  public let isSticker: Bool
  /// True when the recorded path does not exist — an attachment that was never
  /// downloaded, or one iCloud has since offloaded.
  public let isMissing: Bool
}

public struct Message: Sendable {
  public let rowid: Int64
  public let guid: String
  public let date: Date?
  public let isFromMe: Bool
  /// The other party's phone number or email. Nil for messages you sent and for
  /// system events with no originator.
  public let handle: String?
  public let text: String?
  /// True when `text` was NULL and the body came out of `attributedBody`.
  public let textFromArchive: Bool
  public let service: String?
  public let kind: MessageKind
  public let chatRowID: Int64?
  public let chatTitle: String?
  public let isRead: Bool
  public let dateEdited: Date?
  public let dateRetracted: Date?
  public let attachments: [Attachment]

  /// Who to show as the author.
  public var sender: String {
    if isFromMe { return "me" }
    return handle ?? "unknown"
  }
}

// MARK: - Requests

public struct SearchRequest: Sendable {
  public var query: String
  public var chat: String?
  public var handle: String?
  public var sinceDays: Int?
  public var beforeDays: Int?
  public var limit: Int
  public var fromMeOnly: Bool
  public var toMeOnly: Bool
  public var withAttachmentsOnly: Bool
  public var includeSystemEvents: Bool

  public init(
    query: String, chat: String? = nil, handle: String? = nil, sinceDays: Int? = nil,
    beforeDays: Int? = nil, limit: Int = 50, fromMeOnly: Bool = false, toMeOnly: Bool = false,
    withAttachmentsOnly: Bool = false, includeSystemEvents: Bool = false
  ) {
    self.query = query
    self.chat = chat
    self.handle = handle
    self.sinceDays = sinceDays
    self.beforeDays = beforeDays
    self.limit = limit
    self.fromMeOnly = fromMeOnly
    self.toMeOnly = toMeOnly
    self.withAttachmentsOnly = withAttachmentsOnly
    self.includeSystemEvents = includeSystemEvents
  }
}

// MARK: - Store

public final class MessageStore {
  private let db: ChatDatabase
  public var isStale: Bool { db.isStale }

  public init(database: ChatDatabase) {
    self.db = database
  }

  public convenience init() throws {
    self.init(database: try ChatDatabase.open())
  }

  // MARK: Chats

  public func chats(limit: Int? = nil, search: String? = nil) throws -> [Chat] {
    // Participants come back as one grouped string per chat rather than a
    // second query per row; on a 1,317-chat store the N+1 version was the whole
    // cost of `chats`.
    var sql = """
      SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style, c.service_name,
             (SELECT COUNT(*) FROM chat_message_join j WHERE j.chat_id = c.ROWID) AS message_count,
             (SELECT MAX(m.date) FROM chat_message_join j
                JOIN message m ON m.ROWID = j.message_id
               WHERE j.chat_id = c.ROWID) AS last_date,
             (SELECT GROUP_CONCAT(h.id, CHAR(31)) FROM chat_handle_join hj
                JOIN handle h ON h.ROWID = hj.handle_id
               WHERE hj.chat_id = c.ROWID) AS participants
        FROM chat c
      """
    var binds: [ChatDatabase.Bind] = []
    if let search, !search.isEmpty {
      let pattern = "%\(escapeLikePattern(search))%"
      sql += """
         WHERE (c.display_name LIKE ? ESCAPE '\\' OR c.chat_identifier LIKE ? ESCAPE '\\'
                OR EXISTS (SELECT 1 FROM chat_handle_join hj JOIN handle h ON h.ROWID = hj.handle_id
                            WHERE hj.chat_id = c.ROWID AND h.id LIKE ? ESCAPE '\\'))
        """
      binds = [.text(pattern), .text(pattern), .text(pattern)]
    }
    // Chats with no messages sort last rather than first; a NULL MAX() would
    // otherwise float empty conversations to the top of every listing.
    sql += " ORDER BY last_date IS NULL, last_date DESC"
    if let limit { sql += " LIMIT \(limit)" }

    return try db.query(sql, binds).map(makeChat)
  }

  private func makeChat(_ row: [String: Any]) -> Chat {
    let participants = (row["participants"] as? String)?
      .components(separatedBy: "\u{1F}")
      .filter { !$0.isEmpty } ?? []
    return Chat(
      rowid: row["ROWID"] as? Int64 ?? 0,
      guid: row["guid"] as? String ?? "",
      identifier: row["chat_identifier"] as? String ?? "",
      displayName: (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      isGroup: (row["style"] as? Int64) == 43,
      service: row["service_name"] as? String,
      participants: participants,
      messageCount: Int(row["message_count"] as? Int64 ?? 0),
      lastMessageDate: (row["last_date"] as? Int64).flatMap(AppleEpoch.date(from:))
    )
  }

  /// Resolve a user-supplied chat reference: a numeric ROWID, a chat GUID, a
  /// `chat123...` identifier, a phone number or email, or a group name.
  ///
  /// Ambiguity is an error rather than a silent pick — exporting the wrong
  /// conversation is the kind of mistake that is only obvious much later.
  public func findChat(_ reference: String) throws -> Chat {
    let trimmed = reference.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw ChatDatabaseError.notFound("No chat given.")
    }

    if let rowid = Int64(trimmed) {
      let rows = try chatsMatching("c.ROWID = ?", [.int(rowid)])
      if let only = rows.first, rows.count == 1 { return only }
    }

    // Exact identifiers before fuzzy names, so a group literally named after a
    // phone number cannot shadow the handle it looks like.
    let exact = try chatsMatching(
      "c.guid = ? OR c.chat_identifier = ?", [.text(trimmed), .text(trimmed)])
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 { throw ambiguous(trimmed, exact) }

    let matches = try chats(search: trimmed)
    switch matches.count {
    case 0:
      throw ChatDatabaseError.notFound(
        "No chat matching '\(trimmed)'. Run `apple messages chats` to see what exists.")
    case 1:
      return matches[0]
    default:
      // A handle that appears in several conversations is normal — one direct
      // chat plus a few groups. Prefer the direct one, which is what someone
      // typing a phone number almost always means.
      let direct = matches.filter { !$0.isGroup && $0.identifier == trimmed }
      if direct.count == 1 { return direct[0] }
      throw ambiguous(trimmed, matches)
    }
  }

  private func chatsMatching(_ predicate: String, _ binds: [ChatDatabase.Bind]) throws -> [Chat] {
    let sql = """
      SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style, c.service_name,
             (SELECT COUNT(*) FROM chat_message_join j WHERE j.chat_id = c.ROWID) AS message_count,
             (SELECT MAX(m.date) FROM chat_message_join j
                JOIN message m ON m.ROWID = j.message_id
               WHERE j.chat_id = c.ROWID) AS last_date,
             (SELECT GROUP_CONCAT(h.id, CHAR(31)) FROM chat_handle_join hj
                JOIN handle h ON h.ROWID = hj.handle_id
               WHERE hj.chat_id = c.ROWID) AS participants
        FROM chat c WHERE \(predicate)
      """
    return try db.query(sql, binds).map(makeChat)
  }

  private func ambiguous(_ reference: String, _ matches: [Chat]) -> ChatDatabaseError {
    let listed = matches.prefix(8).map { "  \($0.rowid)  \($0.title)" }.joined(separator: "\n")
    let more = matches.count > 8 ? "\n  ... and \(matches.count - 8) more" : ""
    return ChatDatabaseError.notFound(
      "'\(reference)' matches \(matches.count) chats. Pass one of these ids:\n\(listed)\(more)")
  }

  // MARK: Messages

  /// Every message in one conversation, oldest first — the order a transcript
  /// reads in.
  public func messages(
    inChat chat: Chat, limit: Int? = nil, includeSystemEvents: Bool = false
  ) throws -> [Message] {
    var sql = """
      \(messageSelect)
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ?
      """
    if !includeSystemEvents { sql += " AND m.item_type = 0" }
    // Newest-first in SQL so LIMIT keeps the most recent messages, then
    // reversed for display — a LIMIT on an ascending sort would hand back the
    // oldest N, which is never what "last 50" means.
    sql += " ORDER BY m.date DESC"
    if let limit { sql += " LIMIT \(limit)" }

    let rows = try db.query(sql, [.int(chat.rowid)])
    let messages = try hydrate(rows)
    return messages.reversed()
  }

  /// How many archived bodies one search will decode before giving up. Well
  /// clear of the 4,227 such rows on a 103k-message store, so in practice the
  /// scan is always complete; `lastSearchWasTruncated` says when it was not.
  private static let archiveScanCap = 100_000

  /// True when the previous `search` hit `archiveScanCap` and so may have
  /// missed archived matches. Never silently swallowed — the CLI reports it.
  public private(set) var lastSearchWasTruncated = false

  /// Full-text search. Terms are ANDed and matched as substrings, matching the
  /// contract `apple mail search` already sets.
  ///
  /// # Why this runs two queries
  ///
  /// Bodies live in two places. `message.text` can be matched in SQL. A body
  /// that exists only as an archived `NSAttributedString` cannot — it has to be
  /// decoded in Swift first, which means every such row is a *candidate*
  /// regardless of the query.
  ///
  /// Matching both in one statement and taking `ORDER BY date DESC LIMIT n`
  /// looks equivalent and is not, because the two populations are wildly
  /// different sizes. Searching "trusting" on a real store: 6 rows match the
  /// text column, but 1,796 archived candidates are *newer* than the newest of
  /// them. Any limit below 1,796 fills entirely with rows the decoder then
  /// rejects, and all six real matches fall off the end — a confidently empty
  /// answer rather than an error.
  ///
  /// So the two are queried separately, each limited on its own terms, and
  /// merged afterwards. The archived side stays cheap because it is bounded by
  /// how many such rows exist at all, not by the size of the store.
  public func search(_ request: SearchRequest) throws -> [Message] {
    lastSearchWasTruncated = false
    let terms = parseSearchTerms(request.query).map { $0.lowercased() }

    var filters: [String] = []
    var filterBinds: [ChatDatabase.Bind] = []

    if let chat = request.chat {
      let resolved = try findChat(chat)
      filters.append(
        "EXISTS (SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID AND j.chat_id = ?)")
      filterBinds.append(.int(resolved.rowid))
    }
    if let handle = request.handle {
      filters.append("h.id LIKE ? ESCAPE '\\'")
      filterBinds.append(.text("%\(escapeLikePattern(handle))%"))
    }
    if let days = request.sinceDays, let cutoff = appleTimestamp(daysAgo: days) {
      filters.append("m.date >= ?")
      filterBinds.append(.int(cutoff))
    }
    if let days = request.beforeDays, let cutoff = appleTimestamp(daysAgo: days) {
      filters.append("m.date <= ?")
      filterBinds.append(.int(cutoff))
    }
    if request.fromMeOnly { filters.append("m.is_from_me = 1") }
    if request.toMeOnly { filters.append("m.is_from_me = 0") }
    if request.withAttachmentsOnly { filters.append("m.cache_has_attachments = 1") }
    if !request.includeSystemEvents { filters.append("m.item_type = 0") }

    func statement(_ extra: [String], _ limit: Int) -> String {
      var sql = messageSelect
      let all = filters + extra
      if !all.isEmpty { sql += " WHERE " + all.joined(separator: " AND ") }
      return sql + " ORDER BY m.date DESC LIMIT \(limit)"
    }

    // With no terms this is a plain "most recent messages" listing, and the
    // archived pass would add nothing a decode could filter.
    guard !terms.isEmpty else {
      return try hydrate(try db.query(statement([], request.limit), filterBinds))
    }

    // 1. The text column, matched entirely in SQL.
    let textClause = terms.map { _ in "m.text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
    let textBinds = terms.map { ChatDatabase.Bind.text("%\(escapeLikePattern($0))%") }
    let textRows = try db.query(
      statement(["m.text IS NOT NULL", textClause], request.limit), filterBinds + textBinds)

    // 2. Archived bodies, decoded and filtered here.
    let archiveRows = try db.query(
      statement(["m.text IS NULL", "m.attributedBody IS NOT NULL"], Self.archiveScanCap),
      filterBinds)
    lastSearchWasTruncated = archiveRows.count >= Self.archiveScanCap

    // Decode and match *before* hydrating. Hydration costs two more queries
    // over the whole row set — attachments and chat titles — and on a real
    // store 2,526 rows reach this point while a handful survive the match, so
    // doing it first pays for all of them to answer nothing.
    let matching = archiveRows.filter { row in
      guard let blob = row["attributedBody"] as? Data,
        let text = TypedStream.decode(blob)
      else { return false }
      return containsAllTerms(text, terms)
    }
    let archived = try hydrate(matching)

    let merged = (try hydrate(textRows) + archived)
      .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    return Array(merged.prefix(request.limit))
  }

  private var messageSelect: String {
    """
    SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.date_edited, m.date_retracted,
           m.is_from_me, m.is_read, m.service, m.item_type, m.associated_message_type,
           m.balloon_bundle_id, m.cache_has_attachments, h.id AS handle_id,
           (SELECT j.chat_id FROM chat_message_join j WHERE j.message_id = m.ROWID LIMIT 1) AS chat_id
      FROM message m
      LEFT JOIN handle h ON h.ROWID = m.handle_id
    """
  }

  /// Turn raw rows into messages: decode archived bodies, classify, and attach
  /// files. Chat titles and attachments are fetched in one batched query each
  /// rather than per row.
  private func hydrate(_ rows: [[String: Any]]) throws -> [Message] {
    let rowids = rows.compactMap { $0["ROWID"] as? Int64 }
    let attachmentsByMessage = try attachments(forMessages: rowids)

    let chatIDs = Set(rows.compactMap { $0["chat_id"] as? Int64 })
    var titles: [Int64: String] = [:]
    if !chatIDs.isEmpty {
      let list = chatIDs.map(String.init).joined(separator: ",")
      for chat in try chatsMatching("c.ROWID IN (\(list))", []) {
        titles[chat.rowid] = chat.title
      }
    }

    return rows.map { row in
      let rowid = row["ROWID"] as? Int64 ?? 0
      var text = row["text"] as? String
      var fromArchive = false
      if text == nil || text?.isEmpty == true, let blob = row["attributedBody"] as? Data {
        text = TypedStream.decode(blob)
        fromArchive = text != nil
      }
      // A body of nothing but attachment placeholders decodes to nil; leave it
      // nil rather than emitting an empty string that reads as a blank message.
      if let value = text, value.isEmpty { text = nil }

      let chatID = row["chat_id"] as? Int64
      return Message(
        rowid: rowid,
        guid: row["guid"] as? String ?? "",
        date: (row["date"] as? Int64).flatMap(AppleEpoch.date(from:)),
        isFromMe: (row["is_from_me"] as? Int64) == 1,
        handle: row["handle_id"] as? String,
        text: text,
        textFromArchive: fromArchive,
        service: row["service"] as? String,
        kind: classify(row),
        chatRowID: chatID,
        chatTitle: chatID.flatMap { titles[$0] },
        isRead: (row["is_read"] as? Int64) == 1,
        dateEdited: (row["date_edited"] as? Int64).flatMap(AppleEpoch.date(from:)),
        dateRetracted: (row["date_retracted"] as? Int64).flatMap(AppleEpoch.date(from:)),
        attachments: attachmentsByMessage[rowid] ?? []
      )
    }
  }

  private func classify(_ row: [String: Any]) -> MessageKind {
    if (row["item_type"] as? Int64 ?? 0) != 0 { return .systemEvent }
    if (row["associated_message_type"] as? Int64 ?? 0) != 0 { return .tapback }
    if row["balloon_bundle_id"] as? String != nil { return .appMessage }
    return .message
  }

  // MARK: Attachments

  public func attachments(forMessages rowids: [Int64]) throws -> [Int64: [Attachment]] {
    guard !rowids.isEmpty else { return [:] }
    let list = rowids.map(String.init).joined(separator: ",")
    let rows = try db.query(
      """
      SELECT maj.message_id, a.ROWID, a.filename, a.mime_type, a.total_bytes, a.is_sticker
        FROM message_attachment_join maj
        JOIN attachment a ON a.ROWID = maj.attachment_id
       WHERE maj.message_id IN (\(list))
      """)

    var result: [Int64: [Attachment]] = [:]
    for row in rows {
      guard let messageID = row["message_id"] as? Int64 else { continue }
      let stored = row["filename"] as? String
      let path = stored.map(expandTilde)
      let missing = path.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
      result[messageID, default: []].append(
        Attachment(
          rowid: row["ROWID"] as? Int64 ?? 0,
          filename: stored.map { ($0 as NSString).lastPathComponent },
          path: path,
          mimeType: row["mime_type"] as? String,
          totalBytes: row["total_bytes"] as? Int64 ?? 0,
          isSticker: (row["is_sticker"] as? Int64) == 1,
          isMissing: missing))
    }
    return result
  }

  /// Attachment paths are stored with a literal `~`, which no file API expands.
  private func expandTilde(_ path: String) -> URL {
    guard path.hasPrefix("~") else { return URL(fileURLWithPath: path) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(String(path.dropFirst().drop(while: { $0 == "/" })))
  }

  private func appleTimestamp(daysAgo days: Int) -> Int64? {
    let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
    let seconds = cutoff.timeIntervalSince1970 - AppleEpoch.offset
    guard seconds > 0 else { return nil }
    return Int64(seconds * 1_000_000_000)
  }
}
