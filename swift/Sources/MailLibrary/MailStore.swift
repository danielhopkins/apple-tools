import AppleToolsSearch
import Foundation

/// Search and export against the on-disk mail store: the Envelope Index for
/// metadata, the `.emlx` files for bodies. Nothing here talks to Mail.app, so
/// it works with Mail closed and has no ~120s event timeout to trip over.

public struct MessageSummary: Sendable {
  public let rowid: Int64
  public let id: String
  public let subject: String
  public let from: String
  public let date: Date?
  public let account: String
  public let mailbox: String
  /// The mailbox's index URL. Carried because mailbox *names* are not unique —
  /// three accounts here have an "Archive" — and finding a message's .emlx
  /// needs the exact mailbox, not one that happens to share its name.
  public let mailboxURL: String
  public let unread: Bool
  public let flagged: Bool
  public let attachmentCount: Int
  public var attachmentNames: String = ""

  public init(
    rowid: Int64, id: String, subject: String, from: String, date: Date?, account: String,
    mailbox: String, mailboxURL: String, unread: Bool, flagged: Bool, attachmentCount: Int,
    attachmentNames: String = ""
  ) {
    self.attachmentNames = attachmentNames
    self.rowid = rowid
    self.id = id
    self.subject = subject
    self.from = from
    self.date = date
    self.account = account
    self.mailbox = mailbox
    self.mailboxURL = mailboxURL
    self.unread = unread
    self.flagged = flagged
    self.attachmentCount = attachmentCount
  }
}

public struct ExportedMessage: Sendable {
  public let summary: MessageSummary
  public let to: [String]
  public let cc: [String]
  public let dateSent: Date?
  public let replyTo: String?
  public let attachments: [String]
  public let body: String
  public let rawHeaders: String
  public let source: Data
}

public struct SearchRequest: Sendable {
  public var query: String
  /// subject, sender, content, or all.
  public var field: String
  public var account: String?
  public var mailbox: String?
  public var since: Date?
  public var before: Date?
  public var limit: Int
  public var flaggedOnly: Bool
  public var unreadOnly: Bool
  public var withAttachmentsOnly: Bool
  /// Trash and junk are excluded unless asked for.
  public var includeTrashAndJunk: Bool
  /// Also match terms against attachment filenames. Opt-in.
  public var matchAttachmentNames: Bool = false

  public init(
    query: String, field: String = "subject", account: String? = nil, mailbox: String? = nil,
    since: Date? = nil, before: Date? = nil, limit: Int = 20, flaggedOnly: Bool = false,
    unreadOnly: Bool = false, withAttachmentsOnly: Bool = false, includeTrashAndJunk: Bool = false
  ) {
    self.query = query
    self.field = field
    self.account = account
    self.mailbox = mailbox
    self.since = since
    self.before = before
    self.limit = limit
    self.flaggedOnly = flaggedOnly
    self.unreadOnly = unreadOnly
    self.withAttachmentsOnly = withAttachmentsOnly
    self.includeTrashAndJunk = includeTrashAndJunk
  }
}

public struct SearchResult: Sendable {
  public let messages: [MessageSummary]
  /// How many messages the index matched before any body was read. Reported so
  /// a content search that scanned 40,000 messages does not look like one that
  /// scanned 12.
  public let candidates: Int
  /// How many bodies were actually opened. Zero for a metadata-only search.
  public let bodiesRead: Int
}

public final class MailStore {
  public let index: EnvelopeIndex
  private let allMailboxes: [MailboxRef]
  private let byURL: [String: MailboxRef]

  public var isStale: Bool { index.isStale }
  public var databasePath: URL { index.databasePath }

  public init(index: EnvelopeIndex) throws {
    self.index = index
    allMailboxes = try index.mailboxes()
    byURL = Dictionary(allMailboxes.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public convenience init() throws {
    try self.init(index: try EnvelopeIndex.open())
  }

  // MARK: Resolution

  private func mailbox(forURL url: String?) -> MailboxRef? {
    url.flatMap { byURL[$0] }
  }

  /// Mailboxes to search, after applying --account, --mailbox and --all.
  func resolveMailboxes(account: String?, mailbox: String?, includeTrashAndJunk: Bool) throws
    -> [MailboxRef]
  {
    var candidates = allMailboxes

    if let account {
      let uuids = Set(try index.accountUUIDs(matching: account))
      guard !uuids.isEmpty else {
        throw EnvelopeIndexError.notFound(
          "No account matching '\(account)'. Run `apple mail accounts` for the exact names.")
      }
      candidates = candidates.filter { uuids.contains($0.accountUUID) }
    }

    if let mailbox {
      let wanted = MailboxNames.matching(mailbox)
      candidates = candidates.filter { wanted.contains($0.name.lowercased()) }
      guard !candidates.isEmpty else {
        throw EnvelopeIndexError.notFound("No mailbox matching '\(mailbox)'.")
      }
      // An explicit --mailbox trash is a request for trash; do not then filter
      // it back out.
      return candidates
    }

    if !includeTrashAndJunk {
      candidates = candidates.filter { !$0.isTrash && !$0.isJunk }
    }
    return candidates
  }

  private func summary(_ row: [String: Any]) -> MessageSummary? {
    guard let rowid = row["rowid"] as? Int64 else { return nil }
    let box = mailbox(forURL: row["mailbox_url"] as? String)
    return MessageSummary(
      rowid: rowid,
      id: strippingAngleBrackets(row["message_id"] as? String ?? ""),
      subject: fullSubject(
        prefix: row["subject_prefix"] as? String, subject: row["subject"] as? String),
      from: formatAddress(
        address: row["sender_address"] as? String ?? "",
        comment: row["sender_comment"] as? String ?? ""),
      date: (row["date_received"] as? Int64).map { Date(timeIntervalSince1970: TimeInterval($0)) },
      account: box.map { index.displayName(forAccount: $0.accountUUID) } ?? "",
      mailbox: box?.name ?? "",
      mailboxURL: box?.url ?? "",
      unread: (row["read"] as? Int64 ?? 0) == 0,
      flagged: (row["flagged"] as? Int64 ?? 0) != 0,
      attachmentCount: Int(row["attachment_count"] as? Int64 ?? 0),
      attachmentNames: row["attachment_names"] as? String ?? "")
  }

  // MARK: Search

  public func search(_ request: SearchRequest) throws -> SearchResult {
    var filter = EnvelopeIndex.Filter()
    filter.unreadOnly = request.unreadOnly
    filter.flaggedOnly = request.flaggedOnly
    filter.withAttachmentsOnly = request.withAttachmentsOnly
    filter.since = request.since
    filter.before = request.before

    // Only constrain by mailbox when something actually narrows it; binding
    // 30-odd rowids for "everything except trash" is slower than not binding.
    let boxes = try resolveMailboxes(
      account: request.account, mailbox: request.mailbox,
      includeTrashAndJunk: request.includeTrashAndJunk)
    if boxes.count != allMailboxes.count {
      filter.mailboxRowIDs = boxes.map(\.rowid)
    }

    let needsBody = request.field == "content" || request.field == "all"
    let terms = parseSearchTerms(request.query).map { $0.lowercased() }

    // Subject and sender live in the index, so the database can do the whole
    // job and LIMIT in SQL.
    filter.matchAttachmentNames = request.matchAttachmentNames

    if !needsBody {
      filter.terms = terms
      filter.field = request.field
      let rows = try index.messages(filter: filter, limit: request.limit)
      let messages = rows.compactMap(summary)
      return SearchResult(messages: messages, candidates: messages.count, bodiesRead: 0)
    }

    // A body search has no index to lean on, so every candidate is a possible
    // hit and they are walked newest-first until `limit` is reached. An empty
    // query means "no text predicate at all" — a plain listing.
    let rows = try index.messages(filter: filter, limit: terms.isEmpty ? request.limit : nil)
    let candidates = rows.compactMap(summary)
    if terms.isEmpty {
      return SearchResult(messages: candidates, candidates: candidates.count, bodiesRead: 0)
    }

    var matches: [MessageSummary] = []
    var bodiesRead = 0
    let batchSize = 256
    var start = 0

    while start < candidates.count, matches.count < request.limit {
      let end = min(start + batchSize, candidates.count)
      let batch = Array(candidates[start..<end])
      var verdicts = [Bool](repeating: false, count: batch.count)
      var reads = [Int](repeating: 0, count: batch.count)

      verdicts.withUnsafeMutableBufferPointer { verdictBuffer in
        reads.withUnsafeMutableBufferPointer { readBuffer in
          DispatchQueue.concurrentPerform(iterations: batch.count) { offset in
            let message = batch[offset]
            // For `all` a term may land in the subject, the sender or the
            // body, and different terms may land in different places — so the
            // metadata is folded into the same haystack rather than checked
            // as a separate alternative. Terms already satisfied by metadata
            // need not be looked for in the body, and when that leaves none
            // the file is never opened.
            var remaining = terms
            var metadata = request.field == "all" ? "\(message.subject) \(message.from)" : ""
            if request.matchAttachmentNames { metadata += " " + message.attachmentNames }
            if !metadata.isEmpty {
              let lowered = metadata.lowercased()
              remaining = terms.filter { !lowered.contains($0) }
              if remaining.isEmpty {
                verdictBuffer[offset] = true
                return
              }
            }
            readBuffer[offset] = 1
            verdictBuffer[offset] = self.bodyContains(remaining, message: message)
          }
        }
      }

      for (offset, matched) in verdicts.enumerated() where matched {
        matches.append(batch[offset])
        if matches.count >= request.limit { break }
      }
      bodiesRead += reads.reduce(0, +)
      start = end
    }

    return SearchResult(
      messages: matches, candidates: candidates.count, bodiesRead: bodiesRead)
  }

  private func bodyContains(_ lowercasedTerms: [String], message: MessageSummary) -> Bool {
    guard let box = byURL[message.mailboxURL],
      let path = index.emlxPath(ofMessage: message.rowid, in: box),
      let parsed = try? readEmlx(at: path)
    else { return false }
    return containsAllTerms(parsed.text, lowercasedTerms)
  }

  // MARK: Export

  public func export(messageID: String, account: String?) throws -> ExportedMessage {
    // The index stores Message-IDs with angle brackets; search results print
    // them without. Accept either so a copy-paste from `search` works.
    var rows: [[String: Any]] = []
    for candidate in messageIDCandidates(messageID) {
      rows = try index.messages(withMessageID: candidate)
      if !rows.isEmpty { break }
    }
    guard !rows.isEmpty else {
      throw EnvelopeIndexError.notFound("Message not found: \(messageID)")
    }

    // One Message-ID can have copies in several mailboxes; prefer the account
    // the caller named, then the newest.
    var chosen = rows[0]
    if let account {
      let uuids = Set((try? index.accountUUIDs(matching: account)) ?? [])
      if let preferred = rows.first(where: { row in
        guard let box = mailbox(forURL: row["mailbox_url"] as? String) else { return false }
        return uuids.contains(box.accountUUID)
      }) {
        chosen = preferred
      }
    }

    guard let summary = summary(chosen), let box = mailbox(forURL: chosen["mailbox_url"] as? String)
    else {
      throw EnvelopeIndexError.notFound("Message not found: \(messageID)")
    }
    guard let path = index.emlxPath(ofMessage: summary.rowid, in: box) else {
      throw EnvelopeIndexError.notFound(
        "Message '\(messageID)' is in the index but its body is not on disk — Mail has not "
          + "downloaded it. Opening it in Mail.app once will fetch it.")
    }

    let parsed = try readEmlx(at: path)
    let (to, cc) = try index.recipients(ofMessage: summary.rowid)
    return ExportedMessage(
      summary: summary,
      to: to, cc: cc,
      dateSent: (chosen["date_sent"] as? Int64).flatMap {
        $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
      },
      replyTo: parsed.headers.first("Reply-To"),
      attachments: try index.attachmentNames(ofMessage: summary.rowid),
      body: parsed.text,
      rawHeaders: parsed.headers.raw,
      source: parsed.source)
  }

  // MARK: Attachments

  /// The message's attachments, with the summary for context.
  ///
  /// Bytes come from Mail's own attachment directory when it has one, because
  /// that is where they actually are: Mail strips payloads out of the `.emlx`
  /// and stores them decoded on disk. Parsing the message alone yields
  /// zero-byte files. The MIME structure is still parsed, for content types
  /// and to tell an inline image from a paperclip attachment, and it supplies
  /// the bytes for the messages that *do* carry them inline — anything Mail
  /// composed locally, for one.
  ///
  /// Separate from `export` because reading attachment bytes is the expensive
  /// part and almost no caller of `export` wants it.
  public func attachments(messageID: String, account: String?) throws
    -> (summary: MessageSummary, files: [MailAttachment])
  {
    let message = try export(messageID: messageID, account: account)
    let embedded = MailLibrary.attachments(inRFC822: message.source)

    guard let box = byURL[message.summary.mailboxURL] else { return (message.summary, embedded) }
    let onDisk = index.attachmentFiles(ofMessage: message.summary.rowid, in: box)
    guard !onDisk.isEmpty else { return (message.summary, embedded) }

    // Match on filename: the directory is named by MIME part path, which the
    // parser does not track, but Mail names the file exactly as the part did.
    var metadata: [String: MailAttachment] = [:]
    for item in embedded { metadata[item.originalName.lowercased()] = item }

    var files: [MailAttachment] = []
    for (_, url) in onDisk {
      guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
      let name = url.lastPathComponent
      let match = metadata[name.lowercased()]
      files.append(
        MailAttachment(
          name: safeFilename(name, fallback: "attachment-\(files.count + 1)"),
          originalName: name,
          contentType: match?.contentType ?? "application/octet-stream",
          data: data,
          isInline: match?.isInline ?? false))
    }

    // A part Mail did not write out but that carries its own bytes still
    // counts; without this an inline image embedded in a locally composed
    // message would vanish from the listing.
    let written = Set(files.map { $0.originalName.lowercased() })
    files.append(
      contentsOf: embedded.filter {
        !written.contains($0.originalName.lowercased()) && !$0.data.isEmpty
      })
    return (message.summary, files)
  }

  // MARK: Accounts

  public struct AccountSummary: Sendable {
    public let name: String
    public let address: String?
    public let uuid: String
    public let scheme: String
    public let mailboxes: [String]
  }

  public func accountSummaries() -> [AccountSummary] {
    let known = index.accounts()
    var order: [String] = []
    var grouped: [String: [MailboxRef]] = [:]
    for box in allMailboxes {
      if grouped[box.accountUUID] == nil { order.append(box.accountUUID) }
      grouped[box.accountUUID, default: []].append(box)
    }
    return order.map { uuid in
      let boxes = grouped[uuid] ?? []
      return AccountSummary(
        name: known[uuid]?.name ?? uuid,
        address: known[uuid]?.address,
        uuid: uuid,
        scheme: boxes.first?.scheme ?? "",
        mailboxes: boxes.map(\.path).sorted())
    }
  }
}

// MARK: - Message-ID shapes

public func strippingAngleBrackets(_ id: String) -> String {
  var value = id
  if value.hasPrefix("<") { value.removeFirst() }
  if value.hasSuffix(">") { value.removeLast() }
  return value
}

public func messageIDCandidates(_ id: String) -> [String] {
  let trimmed = id.trimmingCharacters(in: .whitespaces)
  if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
    return [trimmed, String(trimmed.dropFirst().dropLast())]
  }
  return ["<\(trimmed)>", trimmed]
}
