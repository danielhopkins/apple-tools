import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import CoreServices  // AEDeterminePermissionToAutomateTarget, for `status`
import Foundation
import MessagesLibrary

func warn(_ message: String) {
  FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

/// Messages.app. Its bundle id is still the one from the iPhone SMS app.
let messagesBundleID = "com.apple.MobileSMS"

// MARK: - Rendering

enum Output {
  static let compactDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()

  static let isoDate: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func json(_ value: Any) throws {
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
  }

  static func encode(_ chat: Chat) -> [String: Any] {
    var payload: [String: Any] = [
      "id": chat.rowid,
      "guid": chat.guid,
      "identifier": chat.identifier,
      "title": chat.title,
      "is_group": chat.isGroup,
      "participants": chat.participants,
      "message_count": chat.messageCount,
    ]
    if let name = chat.displayName { payload["display_name"] = name }
    if let service = chat.service { payload["service"] = service }
    if let date = chat.lastMessageDate { payload["last_message"] = isoDate.string(from: date) }
    return payload
  }

  static func encode(_ message: Message) -> [String: Any] {
    var payload: [String: Any] = [
      "id": message.rowid,
      "guid": message.guid,
      "from_me": message.isFromMe,
      "sender": message.sender,
      "kind": message.kind.rawValue,
      "is_read": message.isRead,
    ]
    if let date = message.date { payload["date"] = isoDate.string(from: date) }
    if let text = message.text { payload["text"] = text }
    // Only present when true, so it reads as a note about provenance rather
    // than a field every message carries.
    if message.textFromArchive { payload["text_from_archive"] = true }
    if let handle = message.handle { payload["handle"] = handle }
    if let service = message.service { payload["service"] = service }
    if let title = message.chatTitle { payload["chat"] = title }
    if let chatID = message.chatRowID { payload["chat_id"] = chatID }
    if let edited = message.dateEdited { payload["date_edited"] = isoDate.string(from: edited) }
    if let retracted = message.dateRetracted {
      payload["date_retracted"] = isoDate.string(from: retracted)
    }
    if !message.attachments.isEmpty {
      payload["attachments"] = message.attachments.map(encode)
    }
    return payload
  }

  static func encode(_ attachment: Attachment) -> [String: Any] {
    var payload: [String: Any] = [
      "id": attachment.rowid,
      "bytes": attachment.totalBytes,
      "is_sticker": attachment.isSticker,
      "missing": attachment.isMissing,
    ]
    if let name = attachment.filename { payload["filename"] = name }
    if let path = attachment.path { payload["path"] = path.path }
    if let mime = attachment.mimeType { payload["mime_type"] = mime }
    return payload
  }

  /// One line per message, for search results.
  static func line(_ message: Message, index: Int) {
    let when = message.date.map { compactDate.string(from: $0) } ?? "unknown date"
    let body = message.text ?? placeholder(for: message)
    print("\(Style.dim("\(index)."))  \(Style.title(message.sender))  \(Style.time(when))")
    if let chat = message.chatTitle {
      print("    \(Style.dim(chat))")
    }
    print("    \(body)")
    if !message.attachments.isEmpty {
      let names = message.attachments.map { $0.filename ?? "attachment" }
      print("    \(Style.label("attachments:")) \(names.joined(separator: ", "))")
    }
    print("")
  }

  /// What to show when a message has no text of its own.
  static func placeholder(for message: Message) -> String {
    switch message.kind {
    case .tapback: return Style.dim("(tapback)")
    case .systemEvent: return Style.dim("(group event)")
    case .appMessage: return Style.dim("(app message)")
    case .message:
      if !message.attachments.isEmpty { return Style.dim("(attachment only)") }
      return Style.dim("(no text)")
    }
  }

  static func size(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    return unit == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[unit])
  }
}

/// Opening the store is the same three lines everywhere, and the failure is
/// almost always the same missing grant, so the advice lives in one place.
func openStore() throws -> MessageStore {
  let store = try MessageStore()
  if store.isStale {
    warn(
      "note: read the database without replaying its write-ahead log, so the most recent "
        + "messages may be missing.")
  }
  return store
}

// MARK: - Commands

struct AppleMessages: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "apple-messages",
    abstract: "Search and export Messages conversations",
    discussion: """
      Reads ~/Library/Messages/chat.db directly, so it works with Messages
      closed and answers a whole-store search in milliseconds. Reading it needs
      Full Disk Access for this terminal.
      """,
    version: appleToolsVersion,
    subcommands: [Chats.self, Search.self, Export.self, Attachments.self, Status.self],
    defaultSubcommand: nil
  )
}

struct Chats: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List conversations, most recently active first"
  )

  @Argument(help: "Only chats matching this name, handle, or identifier")
  var search: String?

  @Option(name: .long, help: "Maximum chats to list")
  var limit: Int = 50

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let store = try openStore()
    let chats = try store.chats(limit: limit, search: search)

    if json {
      try Output.json(chats.map(Output.encode))
      return
    }
    if chats.isEmpty {
      print("No conversations found.")
      return
    }
    for chat in chats {
      let when = chat.lastMessageDate.map { Output.compactDate.string(from: $0) } ?? "—"
      let kind = chat.isGroup ? "group" : "direct"
      print("\(Style.identifier(String(chat.rowid)))  \(Style.title(chat.title))")
      print(
        "    \(Style.dim(kind))  \(Style.dim("\(chat.messageCount) messages"))  "
          + "\(Style.time(when))")
    }
  }
}

struct Search: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Search message bodies",
    discussion: """
      A query is an AND of terms matched as substrings: `dinner friday` finds
      messages containing both words in any order. Double-quote for a phrase.

      Messages whose body is stored only as an archived attributed string are
      searched too — about 4% of a long-lived store, and invisible to a plain
      query over the text column.
      """
  )

  @Argument(help: "Terms to search for")
  var query: String

  @Option(name: .long, help: "Restrict to one conversation (id, name, or handle)")
  var chat: String?

  @Option(name: .long, help: "Restrict to messages with this handle (phone or email)")
  var handle: String?

  @Option(name: .long, help: "Only messages from the last N days")
  var since: Int?

  @Option(name: .long, help: "Only messages older than N days")
  var before: Int?

  @Option(name: .long, help: "Maximum results")
  var limit: Int = 50

  @Flag(name: .long, help: "Only messages you sent")
  var fromMe = false

  @Flag(name: .long, help: "Only messages you received")
  var toMe = false

  @Flag(name: .long, help: "Only messages carrying an attachment")
  var hasAttachment = false

  @Flag(name: .long, help: "Include joins, leaves and renames")
  var includeEvents = false

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    guard !(fromMe && toMe) else {
      throw ValidationError("--from-me and --to-me are mutually exclusive.")
    }
    let store = try openStore()
    let request = SearchRequest(
      query: query, chat: chat, handle: handle, sinceDays: since, beforeDays: before,
      limit: limit, fromMeOnly: fromMe, toMeOnly: toMe, withAttachmentsOnly: hasAttachment,
      includeSystemEvents: includeEvents)
    let results = try store.search(request)
    if store.lastSearchWasTruncated {
      warn(
        "note: stopped after scanning \(100_000) archived message bodies; there may be more "
          + "matches. Narrow with --chat, --since or --handle.")
    }

    if json {
      try Output.json(results.map(Output.encode))
      return
    }
    if results.isEmpty {
      print("No messages found.")
      return
    }
    for (offset, message) in results.enumerated() {
      Output.line(message, index: offset + 1)
    }
  }
}

struct Export: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Print one conversation as a transcript, oldest first"
  )

  @Argument(help: "Chat id, group name, phone number, or email")
  var chat: String

  @Option(name: .long, help: "Only the most recent N messages")
  var limit: Int?

  @Flag(name: .long, help: "Include joins, leaves and renames")
  var includeEvents = false

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  @Option(name: .shortAndLong, help: "Write to a file instead of stdout")
  var output: String?

  func run() throws {
    let store = try openStore()
    let resolved = try store.findChat(chat)
    let messages = try store.messages(
      inChat: resolved, limit: limit, includeSystemEvents: includeEvents)

    if json {
      var payload = Output.encode(resolved)
      payload["messages"] = messages.map(Output.encode)
      if let output {
        let data = try JSONSerialization.data(
          withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: output))
        print("Wrote \(messages.count) messages to \(output)")
      } else {
        try Output.json(payload)
      }
      return
    }

    var lines: [String] = []
    lines.append("# \(resolved.title)")
    if resolved.isGroup, !resolved.participants.isEmpty {
      lines.append("Participants: \(resolved.participants.joined(separator: ", "))")
    }
    lines.append("")
    for message in messages {
      let when = message.date.map { Output.compactDate.string(from: $0) } ?? "unknown date"
      let body = message.text ?? Output.placeholder(for: message)
      lines.append("[\(when)] \(message.sender): \(body)")
      for attachment in message.attachments {
        let name = attachment.filename ?? "attachment"
        let note = attachment.isMissing ? " (not downloaded)" : ""
        lines.append("    <attachment: \(name)\(note)>")
      }
    }
    let text = lines.joined(separator: "\n")

    if let output {
      try text.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
      print("Wrote \(messages.count) messages to \(output)")
    } else {
      print(text)
    }
  }
}

struct Attachments: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List or save the files in a conversation",
    discussion: """
      Unlike Mail, Messages keeps attachment bytes on disk at the path recorded
      in the database, so no MIME decoding is involved. Files iCloud has
      offloaded are reported as missing rather than saved empty.
      """
  )

  @Argument(help: "Chat id, group name, phone number, or email")
  var chat: String

  @Option(name: .long, help: "Copy the files into this directory")
  var save: String?

  @Flag(name: .long, help: "Skip stickers")
  var skipStickers = false

  @Option(name: .long, help: "Only the most recent N messages")
  var limit: Int?

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let store = try openStore()
    let resolved = try store.findChat(chat)
    let messages = try store.messages(inChat: resolved, limit: limit)

    var files = messages.flatMap { $0.attachments }
    if skipStickers { files = files.filter { !$0.isSticker } }

    guard !files.isEmpty else {
      if json { try Output.json([]) } else { print("No attachments in this conversation.") }
      return
    }

    guard let save else {
      if json {
        try Output.json(files.map(Output.encode))
      } else {
        for file in files {
          let name = file.filename ?? "attachment"
          let note = file.isMissing ? Style.warning("  missing") : ""
          print(
            "\(Style.title(name))  \(Style.dim(file.mimeType ?? "unknown"))  "
              + "\(Style.dim(Output.size(file.totalBytes)))\(note)")
        }
      }
      return
    }

    let directory = URL(fileURLWithPath: save)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var written: [[String: Any]] = []
    var skipped = 0
    for file in files {
      guard let source = file.path, !file.isMissing else {
        skipped += 1
        continue
      }
      // Filenames come from the sender, so reduce to a bare basename before
      // joining — the same rule `apple mail attachments` applies, and for the
      // same reason: a name like "../../x" must not escape the directory.
      let base = ((file.filename ?? "attachment") as NSString).lastPathComponent
      let safe = base.isEmpty || base == "." || base == ".." ? "attachment" : base
      let destination = uniquePath(in: directory, named: safe)
      do {
        try FileManager.default.copyItem(at: source, to: destination)
        written.append(["filename": destination.lastPathComponent, "path": destination.path])
        if !json { print(destination.path) }
      } catch {
        warn("warning: could not save \(safe): \(error.localizedDescription)")
        skipped += 1
      }
    }

    if json {
      try Output.json(["saved": written, "skipped": skipped])
    } else if skipped > 0 {
      warn("note: \(skipped) attachment(s) skipped — not downloaded or unreadable.")
    }
  }

  /// Never overwrite: `photo.jpg` that already exists becomes `photo-2.jpg`.
  private func uniquePath(in directory: URL, named name: String) -> URL {
    let candidate = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var counter = 2
    while true {
      let suffixed = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
      let next = directory.appendingPathComponent(suffixed)
      if !FileManager.default.fileExists(atPath: next.path) { return next }
      counter += 1
    }
  }
}

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Report permission state without requesting it"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    // Reads need Full Disk Access; only sending would need Automation. So the
    // tool is usable when the database opens, and the Automation state is
    // reported alongside rather than gating it.
    var databasePath: String?
    var messageCount: Int?
    var stale = false
    var readError: String?
    do {
      let database = try ChatDatabase.open()
      databasePath = database.databasePath.path
      stale = database.isStale
      let rows = try database.query("SELECT COUNT(*) AS n FROM message")
      messageCount = Int(rows.first?["n"] as? Int64 ?? 0)
    } catch {
      readError = error.localizedDescription
    }

    let readable = readError == nil
    let (automation, automationAdvice) = automationState()

    let status: String
    let advice: String?
    if readable {
      status = "authorized"
      advice = nil
    } else {
      status = "denied"
      advice =
        "Grant Full Disk Access to this terminal in System Settings → Privacy & Security → "
        + "Full Disk Access, then run this again."
    }

    if json {
      var payload: [String: Any] = [
        "status": status,
        "usable": readable,
        "full_disk_access": readable,
        "automation": automation,
      ]
      if let advice { payload["advice"] = advice }
      if let databasePath { payload["database"] = databasePath }
      if let messageCount { payload["messages"] = messageCount }
      if let readError { payload["error"] = readError }
      if stale { payload["stale"] = true }
      try Output.json(payload)
      if !readable { throw ExitCode(1) }
      return
    }

    if readable {
      print(Style.success("✓ Full Disk Access — can read the Messages database"))
      if let databasePath { print("  \(Style.dim(databasePath))") }
      if let messageCount { print("  \(Style.dim("\(messageCount) messages"))") }
      if stale { print("  \(Style.warning("write-ahead log not replayed; may be stale"))") }
    } else {
      print(Style.warning("✗ Full Disk Access — cannot read the Messages database"))
      if let readError { print("  \(readError)") }
      if let advice { print("  \(advice)") }
    }
    print("\(Style.dim("Automation → Messages:")) \(automation)")
    if let automationAdvice { print("  \(Style.dim(automationAdvice))") }
    if !readable { throw ExitCode(1) }
  }

  /// Automation state, read without triggering the dialog that asking for it
  /// would. Only a future `send` needs this; reads do not.
  private func automationState() -> (String, String?) {
    var target = AEAddressDesc()
    let created = messagesBundleID.withCString { pointer in
      AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
    }
    var code = OSStatus(created)
    if created == noErr {
      code = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
      AEDisposeDesc(&target)
    }
    switch code {
    case noErr:
      return ("authorized", nil)
    case OSStatus(errAEEventNotPermitted):
      return ("denied", "Re-enable Messages under System Settings → Privacy & Security → Automation.")
    case OSStatus(errAEEventWouldRequireUserConsent):
      return ("notDetermined", "Not needed for reading; only a send would prompt for it.")
    case OSStatus(procNotFound):
      return ("messagesNotRunning", "Open Messages.app to determine this; reads do not need it.")
    default:
      return ("unknown(\(code))", nil)
    }
  }
}

AppleMessages.main()
