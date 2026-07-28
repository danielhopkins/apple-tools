import AppKit  // NSWorkspace, to see whether Mail is running before talking to it
import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import CoreServices  // AEDeterminePermissionToAutomateTarget, for `status`
import Foundation
import MailLibrary

/// Which implementation a read command uses.
///
/// `filesystem` reads Mail's own SQLite index and the .emlx files on disk; it
/// needs Full Disk Access, works with Mail closed, and answers a whole-store
/// search in milliseconds. `applescript` drives Mail.app; it needs Automation
/// → Mail and Mail running, and hits a ~120s event timeout that returns an
/// empty list rather than an error. `auto` prefers the first and falls back to
/// the second, which matters for messages the index knows about but whose body
/// has not been downloaded.
enum MailEngine: String, ExpressibleByArgument, CaseIterable {
  case auto
  case filesystem
  case applescript
}

func warn(_ message: String) {
  FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

/// Whether Mail.app is up. Checked before any `tell application "Mail"`, which
/// would otherwise launch it as a side effect of a read-only command.
func isMailRunning() -> Bool {
  NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
}

/// Common rendering for both engines, so the two paths cannot drift apart in
/// what they print.
enum MailOutput {
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

  static func table(_ messages: [MessageSummary]) {
    if messages.isEmpty {
      print("No messages found.")
      return
    }
    for (offset, message) in messages.enumerated() {
      let subject = message.subject.isEmpty ? "(no subject)" : message.subject
      let location = [message.account, message.mailbox]
        .filter { !$0.isEmpty }.joined(separator: "/")

      print("\(Style.dim("\(offset + 1)."))  \(Style.title(subject))")
      var meta = "    \(message.from)"
      if let date = message.date {
        meta += Style.dim("  ·  ") + Style.time(compactDate.string(from: date))
      }
      if !location.isEmpty { meta += "  " + Style.dim("[\(location)]") }
      var badges: [String] = []
      if message.unread { badges.append("unread") }
      if message.flagged { badges.append("flagged") }
      if message.attachmentCount > 0 { badges.append("\(message.attachmentCount) attached") }
      if !badges.isEmpty { meta += "  " + Style.dim("(" + badges.joined(separator: ", ") + ")") }
      print(meta)
      if !message.id.isEmpty { print("    " + Style.identifier(message.id)) }
      print()
    }
    print(Style.dim("\(messages.count) \(messages.count == 1 ? "result" : "results")"))
  }

  static func json(_ messages: [MessageSummary]) {
    let payload = messages.map { message -> [String: Any] in
      var row: [String: Any] = [
        "id": message.id,
        "subject": message.subject,
        "from": message.from,
        "account": message.account,
        "mailbox": message.mailbox,
        "unread": message.unread,
        "flagged": message.flagged,
        "attachments": message.attachmentCount,
      ]
      if let date = message.date {
        row["date"] = compactDate.string(from: date)
        row["date_iso"] = isoDate.string(from: date)
      }
      return row
    }
    let data = try! JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
  }
}

@main
struct AppleMail: AsyncParsableCommand {
  /// ArgumentParser has no coloured help, so generate it, style it and print
  /// it here rather than letting the default path emit the plain version.
  static func main() async {
    if let help = HelpColor.requested(root: AppleMail.self, arguments: CommandLine.arguments) {
      print(help)
      Foundation.exit(0)
    }
    await AppleMail.main(nil)
  }

  static let configuration = CommandConfiguration(
    commandName: "apple-mail",
    abstract: "Search and export Apple Mail messages",
    discussion: """
      Examples:
        apple-mail accounts --json                        # addresses for --from
        apple-mail search "invoice" --since 30 --json     # bounded search
        apple-mail draft --to a@b.com --subject "Hi" --body "text"
      """,
    version: appleToolsVersion,
    subcommands: [
      Search.self, Export.self, Accounts.self, Draft.self, DeleteDraft.self, Send.self,
      Status.self,
    ]
  )
}

// MARK: - Accounts

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Report Mail automation state without requesting it"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    let settingsPath = "System Settings → Privacy & Security → Automation"

    // AEDeterminePermissionToAutomateTarget is the only way to read Automation
    // state without side effects: askUserIfNeeded = false means it reports
    // rather than prompts. Sending a real Apple Event to find out would trigger
    // the very dialog a status command must not trigger.
    var target = AEAddressDesc()
    let bundleID = "com.apple.mail"
    let created = bundleID.withCString { pointer in
      AECreateDesc(
        typeApplicationBundleID, pointer, strlen(pointer), &target)
    }

    // AECreateDesc returns OSErr (Int16), the permission call OSStatus (Int32).
    var code = OSStatus(created)
    if created == noErr {
      code = AEDeterminePermissionToAutomateTarget(
        &target, typeWildCard, typeWildCard, false)
      AEDisposeDesc(&target)
    }

    let (automation, automationOK, automationAdvice): (String, Bool, String?) = {
      switch code {
      case noErr:
        return ("authorized", true, nil)
      case OSStatus(errAEEventNotPermitted):
        return ("denied", false, "Re-enable Mail under \(settingsPath).")
      case OSStatus(errAEEventWouldRequireUserConsent):
        return ("notDetermined", false,
                "Run any mail command from a terminal to trigger the prompt.")
      case OSStatus(procNotFound):
        // Automation state cannot be determined while the target is not
        // running; this says nothing about whether the grant exists.
        return ("mailNotRunning", false, "Open Mail.app, then check again.")
      default:
        return ("unknown(\(code))", false, nil)
      }
    }()

    // Reads no longer need Automation at all: the file-system engine covers
    // search, export and accounts, and only draft/send still drive Mail. So
    // the tool is usable when *either* grant is in place, and reporting only
    // the Automation state would call a working install broken.
    var indexPath: String?
    var indexCount: Int?
    var indexStale = false
    var indexError: String?
    do {
      let store = try MailStore()
      indexPath = store.databasePath.path
      indexCount = try? store.index.messageCount()
      indexStale = store.isStale
    } catch {
      indexError = error.localizedDescription
    }
    let fileSystemOK = indexPath != nil

    let usable = fileSystemOK || automationOK
    let advice: String? = {
      if fileSystemOK && automationOK { return nil }
      if fileSystemOK {
        return "Reads work. Drafting and sending need Automation → Mail: \(automationAdvice ?? "")"
          .trimmingCharacters(in: .whitespaces)
      }
      if automationOK {
        return "Drafting works, but reads fall back to slow AppleScript. Grant Full Disk "
          + "Access to this terminal to read Mail's index directly."
      }
      return
        "No access. Grant Full Disk Access for reads, and Automation → Mail for drafting. "
        + (automationAdvice ?? "")
    }()

    if json {
      var fileSystem: [String: Any] = ["readable": fileSystemOK, "stale": indexStale]
      if let indexPath { fileSystem["path"] = indexPath }
      if let indexCount { fileSystem["messages"] = indexCount }
      if let indexError { fileSystem["error"] = indexError }

      var payload: [String: Any] = [
        "status": fileSystemOK ? (automationOK ? "authorized" : "readOnly") : automation,
        "usable": usable,
        "automation": automation,
        "filesystem": fileSystem,
      ]
      if let advice { payload["advice"] = advice }
      let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    } else {
      print("Mail automation (draft/send): \(automation)")
      if let indexPath {
        let count = indexCount.map { " — \($0) messages" } ?? ""
        print("Mail index (search/export):  readable\(count)")
        print("  \(indexPath)")
        if indexStale { print("  warning: reading a stale snapshot; the write-ahead log was skipped.") }
      } else {
        print("Mail index (search/export):  unreadable — \(indexError ?? "unknown")")
      }
      if let advice { print(advice) }
    }
  }
}

struct Accounts: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List Mail accounts and mailboxes",
    discussion: """
      Mail.app is authoritative here — only it knows whether an account is
      enabled, and its account names are what --from matches. So when Mail is
      already running this asks Mail. When it is not, this reads the on-disk
      store instead rather than launching Mail just to list accounts; the names
      come from the system Accounts database and the `enabled` field is omitted
      because the store does not record it.
      """
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  @Option(name: .long, help: "Read engine: auto, filesystem, applescript")
  var engine: MailEngine = .auto

  func run() async throws {
    // `tell application "Mail"` launches Mail when it is not running, which
    // turns `accounts` into a multi-second app launch (and, on a cold Mail, a
    // hang). Only pay that when Mail is already up.
    let useFileSystem =
      engine == .filesystem || (engine == .auto && !isMailRunning())
    if useFileSystem {
      do {
        try runFileSystem()
        return
      } catch {
        if engine == .filesystem { throw error }
        warn("note: file-system accounts unavailable (\(error.localizedDescription))")
      }
    }
    try runAppleScript_()
  }

  private func runFileSystem() throws {
    let store = try MailStore()
    let accounts = store.accountSummaries()

    if json {
      let payload = accounts.map { account -> [String: Any] in
        var row: [String: Any] = [
          "name": account.name,
          "addresses": [account.address].compactMap { $0 },
          "mailboxes": account.mailboxes,
          "type": account.scheme,
          "id": account.uuid,
        ]
        row["full_name"] = ""
        return row
      }
      let data = try JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8) ?? "[]")
      return
    }

    for account in accounts {
      let address = account.address ?? ""
      print("\(Style.title(account.name))  \(Style.identifier(address))")
      if !account.mailboxes.isEmpty {
        print("  " + Style.dim(account.mailboxes.joined(separator: ", ")))
      }
    }
  }

  private func runAppleScript_() throws {
    // `email addresses of acct` cannot be iterated with `repeat with` — the
    // loop yields nothing. Coercing the whole list to string does work, so the
    // delimiter is set explicitly and the result split on this side.
    let script = """
      set AppleScript's text item delimiters to ","
      tell application "Mail"
        set output to ""
        repeat with acct in every account
          set addrs to ""
          try
            set addrs to (email addresses of acct) as string
          end try
          set fn to ""
          try
            set fn to full name of acct
          end try
          set en to "true"
          try
            set en to (enabled of acct) as string
          end try
          set output to output & "ACCOUNT\t" & (name of acct) & "\t" & en & "\t" & fn & "\t" & addrs & linefeed
          try
            repeat with mbox in (every mailbox of acct)
              set output to output & "MAILBOX\t" & (name of mbox) & linefeed
            end repeat
          end try
        end repeat
        return output
      end tell
      """
    let result = try runAppleScript(script)

    var accounts: [[String: Any]] = []
    for line in result.split(separator: "\n", omittingEmptySubsequences: true) {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard let kind = fields.first else { continue }

      if kind == "ACCOUNT", fields.count >= 5 {
        let addresses = fields[4]
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        accounts.append([
          "name": fields[1],
          "enabled": fields[2] == "true",
          "full_name": fields[3],
          "addresses": addresses,
          "mailboxes": [String](),
        ])
      } else if kind == "MAILBOX", fields.count >= 2, !accounts.isEmpty {
        var mailboxes = accounts[accounts.count - 1]["mailboxes"] as? [String] ?? []
        mailboxes.append(fields[1])
        accounts[accounts.count - 1]["mailboxes"] = mailboxes
      }
    }

    if json {
      let data = try JSONSerialization.data(
        withJSONObject: accounts, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8) ?? "[]")
      return
    }

    // The address is what --from needs, so it leads. The mailbox list is
    // reference material — one wrapped, dimmed line rather than a column of
    // twelve that buries everything else.
    for account in accounts {
      let name = account["name"] as? String ?? "?"
      let addresses = (account["addresses"] as? [String] ?? []).joined(separator: ", ")
      let disabled = (account["enabled"] as? Bool ?? true) ? "" : Style.warning("  (disabled)")

      print("\(Style.title(name))  \(Style.identifier(addresses))\(disabled)")

      let mailboxes = account["mailboxes"] as? [String] ?? []
      if !mailboxes.isEmpty {
        print("  " + Style.dim(mailboxes.joined(separator: ", ")))
      }
    }
  }
}

// MARK: - Search

struct Search: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Search mail messages",
    discussion: """
      Reads Mail's own index and message files directly, so a search covers
      every mailbox, runs in milliseconds, and works with Mail.app closed. That
      needs Full Disk Access; without it this falls back to driving Mail over
      AppleScript, which is slow enough to need --since and --limit and returns
      an EMPTY list rather than an error when it times out.

      --field content greps message bodies, which the AppleScript path could
      never finish. It reads files, so it is the one slow mode; narrowing with
      --since or --mailbox helps, but is no longer required.

      Examples:
        apple-mail search "invoice"                          # subject, default
        apple-mail search "budget" --field content           # full-text
        apple-mail search "" --mailbox inbox --unread --limit 20
        apple-mail search "alice@example.com" --field sender --json
      """
  )

  @Argument(help: "Search term")
  var query: String

  @Option(name: .long, help: "Account name (e.g. 🏡, 🦅 SH)")
  var account: String?

  @Option(name: .long, help: "Mailbox name (default: inbox, archive, sent, drafts, flagged)")
  var mailbox: String?

  @Option(name: .long, help: "Search in: subject, sender, content, all (default: subject)")
  var field: String = "subject"

  @Option(name: .long, help: "Only messages newer than N days")
  var since: Int?

  @Option(name: .long, help: "Max results to return")
  var limit: Int = 20

  @Option(name: .long, help: "Only messages older than N days")
  var before: Int?

  @Flag(name: .long, help: "Only flagged/starred messages")
  var flagged: Bool = false

  @Flag(name: .long, help: "Only unread messages")
  var unread: Bool = false

  @Flag(name: .long, help: "Only messages with attachments")
  var hasAttachment: Bool = false

  @Flag(name: .long, help: "Include trash and junk in search")
  var all: Bool = false

  @Flag(
    name: .long,
    help: "Also match attachment filenames (contents are never searched)")
  var attachmentNames: Bool = false

  @Flag(name: .long, help: "Output as JSON")
  var json: Bool = false

  @Option(name: .long, help: "Read engine: auto, filesystem, applescript")
  var engine: MailEngine = .auto

  func run() async throws {
    if engine != .applescript {
      do {
        try runFileSystem()
        return
      } catch {
        // --engine filesystem is a request for that engine specifically, so a
        // silent fallback would hide exactly what the caller asked to see.
        if engine == .filesystem { throw error }
        warn("note: file-system search unavailable (\(error.localizedDescription))")
        warn("note: falling back to AppleScript — slower, and Mail.app must be running.")
      }
    }

    if field == "content" || field == "all" {
      warn(
        "note: AppleScript body search reads every message one at a time and usually "
          + "times out. Grant Full Disk Access to use the file-system engine instead.")
    }
    // searchAppleScript sorts on Mail's locale date *string* ("Monday, July
    // 27, 2026 at ..."), which orders alphabetically — so April sorts above
    // July. Re-sort once the strings have been parsed into real dates.
    let results = try searchAppleScript()
    emit(
      results.compactMap(Search.summary(fromAppleScript:))
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
  }

  private func emit(_ messages: [MessageSummary]) {
    if json {
      MailOutput.json(messages)
    } else {
      MailOutput.table(messages)
    }
  }

  private func runFileSystem() throws {
    let store = try MailStore()
    if store.isStale {
      warn(
        "warning: could not replay Mail's write-ahead log, so results may be missing "
          + "recently received mail. Quitting Mail.app and retrying usually fixes this.")
    }

    var request = SearchRequest(query: query, field: field, limit: limit)
    request.account = account
    request.mailbox = mailbox
    request.since = since.map { Date(timeIntervalSinceNow: -Double($0) * 86_400) }
    request.before = before.map { Date(timeIntervalSinceNow: -Double($0) * 86_400) }
    request.flaggedOnly = flagged
    request.unreadOnly = unread
    request.withAttachmentsOnly = hasAttachment
    request.includeTrashAndJunk = all
    request.matchAttachmentNames = attachmentNames

    let result = try store.search(request)
    emit(result.messages)

    // A body search that read 40,000 files and found nothing is a different
    // event from one that read 12, and the difference is invisible otherwise.
    if result.bodiesRead > 0 {
      warn("note: scanned \(result.bodiesRead) message bodies of \(result.candidates) candidates.")
    }
  }

  /// The AppleScript path still returns loose strings; map them onto the same
  /// shape the file-system path produces so output is identical either way.
  static func summary(fromAppleScript row: [String: String]) -> MessageSummary? {
    MessageSummary(
      rowid: 0,
      id: row["id"] ?? "",
      subject: row["subject"] ?? "",
      from: row["from"] ?? "",
      date: row["date"].flatMap(AppleMailDate.date(from:)),
      account: row["account"] ?? "",
      mailbox: row["mailbox"] ?? "",
      mailboxURL: "",
      unread: false,
      flagged: false,
      attachmentCount: 0)
  }

  // Unified mailbox names that Mail.app supports natively (cross-account)
  static let unifiedMailboxes: [String: String] = [
    "inbox": "inbox",
    "sent": "sent mailbox",
    "drafts": "drafts mailbox",
    "trash": "trash mailbox",
    "junk": "junk mailbox",
  ]

  func searchAppleScript() throws -> [[String: String]] {
    let predicate: String
    let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
    switch field {
    case "sender":
      predicate = "sender contains \"\(escapedQuery)\""
    case "content":
      predicate = "content contains \"\(escapedQuery)\""
    case "all":
      predicate =
        "(subject contains \"\(escapedQuery)\" or sender contains \"\(escapedQuery)\" or content contains \"\(escapedQuery)\")"
    default:
      predicate = "subject contains \"\(escapedQuery)\""
    }

    var extraPredicates: [String] = []
    if let since = since {
      extraPredicates.append("date received > (current date) - \(since) * days")
    }
    if let before = before {
      extraPredicates.append("date received < (current date) - \(before) * days")
    }
    if flagged {
      extraPredicates.append("flagged status is not equal to -1")
    }
    if unread {
      extraPredicates.append("read status is false")
    }
    let filterSuffix = extraPredicates.isEmpty ? "" : " and " + extraPredicates.joined(separator: " and ")

    var allResults: [[String: String]] = []

    // Determine which unified mailboxes to search
    var unifiedToSearch: [String]  // AppleScript names like "inbox", "sent mailbox"
    var perAccountToSearch: [String]  // Per-account mailbox names like "Archive"

    if let mailbox = mailbox {
      let lower = mailbox.lowercased()
      if let unified = Search.unifiedMailboxes[lower] {
        unifiedToSearch = [unified]
        perAccountToSearch = []
      } else {
        unifiedToSearch = []
        perAccountToSearch = [resolveMailboxName(lower)]
      }
    } else {
      // Default: important mailboxes (like Gmail/Mail.app default search)
      unifiedToSearch = ["inbox", "sent mailbox", "drafts mailbox"]
      perAccountToSearch = ["Archive"]
      if all {
        unifiedToSearch.append(contentsOf: ["trash mailbox", "junk mailbox"])
      }
    }

    // Search unified mailboxes (cross-account, fast)
    for mboxRef in unifiedToSearch {
      let script = buildSearchScript(
        mailboxExpr: mboxRef,
        predicate: predicate,
        filterSuffix: filterSuffix,
        limit: limit,
        hasAttachment: hasAttachment,
        accountExpr: "name of account of mailbox of msg",
        mailboxNameExpr: "name of mailbox of msg"
      )
      allResults.append(contentsOf: try parseResults(try runAppleScript(script)))
    }

    // Search per-account mailboxes (for things like Archive that have no unified view)
    if !perAccountToSearch.isEmpty {
      let accounts: [String]
      if let account = account {
        accounts = [account]
      } else {
        let acctScript = """
          tell application "Mail"
            set output to ""
            repeat with acct in every account
              set output to output & name of acct & linefeed
            end repeat
            return output
          end tell
          """
        let acctResult = try runAppleScript(acctScript)
        accounts = acctResult.split(separator: "\n").map(String.init)
      }

      for acctName in accounts {
        for mboxName in perAccountToSearch {
          let script = buildSearchScript(
            mailboxExpr: "mailbox \"\(mboxName)\" of account \"\(acctName)\"",
            predicate: predicate,
            filterSuffix: filterSuffix,
            limit: limit,
            hasAttachment: hasAttachment,
            accountExpr: "\"\(acctName)\"",
            mailboxNameExpr: "\"\(mboxName)\""
          )
          allResults.append(contentsOf: (try? parseResults(try runAppleScript(script))) ?? [])
        }
      }
    }

    // Deduplicate by message ID
    var seen = Set<String>()
    allResults = allResults.filter { row in
      guard let id = row["id"], !id.isEmpty else { return true }
      return seen.insert(id).inserted
    }

    // Sort by date descending
    allResults.sort { ($0["date"] ?? "") > ($1["date"] ?? "") }
    return Array(allResults.prefix(limit))
  }

  func buildSearchScript(
    mailboxExpr: String, predicate: String, filterSuffix: String,
    limit: Int, hasAttachment: Bool, accountExpr: String, mailboxNameExpr: String
  ) -> String {
    var lines = [
      "tell application \"Mail\"",
      "  set output to \"\"",
      "  set matchCount to 0",
      "  try",
      "    set msgs to (messages of \(mailboxExpr) whose \(predicate)\(filterSuffix))",
      "    repeat with msg in msgs",
      "      if matchCount ≥ \(limit) then exit repeat",
    ]
    if hasAttachment {
      lines.append("      if (count of mail attachments of msg) > 0 then")
    }
    lines.append(contentsOf: [
      "      set msgSubject to subject of msg",
      "      set msgSender to sender of msg",
      "      set msgDate to date received of msg",
      "      set msgId to message id of msg",
      "      set msgAccount to \(accountExpr)",
      "      set msgMailbox to \(mailboxNameExpr)",
      "      set output to output & \"SUBJECT:\" & msgSubject & linefeed & \"FROM:\" & msgSender & linefeed & \"DATE:\" & (msgDate as string) & linefeed & \"ACCOUNT:\" & msgAccount & linefeed & \"MAILBOX:\" & msgMailbox & linefeed & \"MSGID:\" & msgId & linefeed & \"---\" & linefeed",
      "      set matchCount to matchCount + 1",
    ])
    if hasAttachment {
      lines.append("      end if")
    }
    lines.append(contentsOf: [
      "    end repeat",
      "  end try",
      "  return output",
      "end tell",
    ])
    return lines.joined(separator: "\n")
  }

  /// Resolve a case-insensitive mailbox name to the actual name Mail.app uses.
  /// Common mappings: "archive" -> "Archive", "sent messages" -> "Sent Messages", etc.
  func resolveMailboxName(_ lower: String) -> String {
    // Well-known mailbox names and their canonical forms
    let known: [String: String] = [
      "archive": "Archive",
      "sent messages": "Sent Messages",
      "sent items": "Sent Items",
      "sent mail": "Sent Mail",
      "deleted messages": "Deleted Messages",
      "deleted items": "Deleted Items",
      "junk email": "Junk Email",
    ]
    return known[lower] ?? lower.capitalized
  }

  func parseResults(_ raw: String) -> [[String: String]] {
    var results: [[String: String]] = []
    let messages = raw.components(separatedBy: "---\n")
    for msg in messages where !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      var row: [String: String] = [:]
      for line in msg.split(separator: "\n") {
        let s = String(line)
        if s.hasPrefix("SUBJECT:") { row["subject"] = String(s.dropFirst(8)) }
        else if s.hasPrefix("FROM:") { row["from"] = String(s.dropFirst(5)) }
        else if s.hasPrefix("DATE:") { row["date"] = String(s.dropFirst(5)) }
        else if s.hasPrefix("ACCOUNT:") { row["account"] = String(s.dropFirst(8)) }
        else if s.hasPrefix("MAILBOX:") { row["mailbox"] = String(s.dropFirst(8)) }
        else if s.hasPrefix("MSGID:") { row["id"] = String(s.dropFirst(6)) }
      }
      if !row.isEmpty { results.append(row) }
    }
    return results
  }

}

// MARK: - Export

struct Export: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Export a mail message by message ID"
  )

  @Argument(help: "Message ID (from search results)")
  var messageId: String

  @Option(name: .long, help: "Account name")
  var account: String?

  @Flag(name: .long, help: "Output as JSON")
  var json: Bool = false

  @Flag(name: .long, help: "Print the raw RFC 822 source instead of the rendered message")
  var raw: Bool = false

  @Option(name: .long, help: "Read engine: auto, filesystem, applescript")
  var engine: MailEngine = .auto

  func run() async throws {
    if engine != .applescript {
      do {
        try runFileSystem()
        return
      } catch {
        if engine == .filesystem { throw error }
        warn("note: file-system export unavailable (\(error.localizedDescription))")
      }
    }
    if raw || json {
      // Mail's AppleScript surface exposes neither, so promising them here
      // would mean silently returning something else.
      throw ValidationError("--raw and --json need the file-system engine (Full Disk Access).")
    }
    try runAppleScript_()
  }

  private func runFileSystem() throws {
    let store = try MailStore()
    let message = try store.export(messageID: messageId, account: account)

    if raw {
      FileHandle.standardOutput.write(message.source)
      return
    }

    if json {
      var payload: [String: Any] = [
        "id": message.summary.id,
        "subject": message.summary.subject,
        "from": message.summary.from,
        "to": message.to,
        "cc": message.cc,
        "account": message.summary.account,
        "mailbox": message.summary.mailbox,
        "unread": message.summary.unread,
        "flagged": message.summary.flagged,
        "attachments": message.attachments,
        "body": message.body,
        "headers": message.rawHeaders,
      ]
      if let date = message.summary.date {
        payload["date"] = MailOutput.compactDate.string(from: date)
        payload["date_iso"] = MailOutput.isoDate.string(from: date)
      }
      if let replyTo = message.replyTo { payload["reply_to"] = replyTo }
      let data = try JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8) ?? "{}")
      return
    }

    // Same layout the AppleScript path prints, so switching engines does not
    // change what a caller has to parse.
    print("Subject: \(message.summary.subject)")
    print("From: \(message.summary.from)")
    if let date = message.summary.date {
      print("Date: \(MailOutput.compactDate.string(from: date))")
    }
    print("To: \(message.to.joined(separator: ", "))")
    if !message.cc.isEmpty { print("Cc: \(message.cc.joined(separator: ", "))") }
    print("Account: \(message.summary.account)")
    print("Mailbox: \(message.summary.mailbox)")
    if !message.attachments.isEmpty {
      print("Attachments: \(message.attachments.joined(separator: ", "))")
    }
    print()
    print(message.body)
  }

  private func runAppleScript_() throws {
    let accounts: [String]
    if let account = account {
      accounts = [account]
    } else {
      let acctScript = """
        tell application "Mail"
          set output to ""
          repeat with acct in every account
            set output to output & name of acct & linefeed
          end repeat
          return output
        end tell
        """
      let acctResult = try runAppleScript(acctScript)
      accounts = acctResult.split(separator: "\n").map(String.init)
    }

    let mailboxes = ["INBOX", "Archive", "Sent Messages", "Drafts", "Junk", "Trash"]
    let escapedId = messageId.replacingOccurrences(of: "\"", with: "\\\"")

    for acctName in accounts {
      for mboxName in mailboxes {
        let script = """
          tell application "Mail"
            try
              set msgs to (messages of mailbox "\(mboxName)" of account "\(acctName)" whose message id is "\(escapedId)")
              if (count of msgs) > 0 then
                set msg to item 1 of msgs
                set output to "Subject: " & subject of msg & linefeed
                set output to output & "From: " & sender of msg & linefeed
                set output to output & "Date: " & (date received of msg as string) & linefeed
                set output to output & "To: " & (address of every to recipient of msg as string) & linefeed
                try
                  set output to output & "Cc: " & (address of every cc recipient of msg as string) & linefeed
                end try
                set output to output & "Account: \(acctName)" & linefeed
                set output to output & "Mailbox: \(mboxName)" & linefeed
                set output to output & linefeed
                set output to output & content of msg
                return output
              end if
            end try
            return ""
          end tell
          """
        if let result = try? runAppleScript(script), !result.isEmpty {
          print(result)
          return
        }
      }
    }

    FileHandle.standardError.write("Message not found: \(messageId)\n".data(using: .utf8)!)
    throw ExitCode.failure
  }
}

// MARK: - Dates

/// AppleScript hands back `date received` as a locale string like
/// "Monday, July 27, 2026 at 2:13:37 PM". That is unreadable in a list and
/// unsortable in JSON, so it is reparsed here using the same locale that
/// produced it and re-emitted compactly.
enum AppleMailDate {
  private static let parsers: [DateFormatter] = {
    let styles: [(DateFormatter.Style, DateFormatter.Style)] = [
      (.full, .medium), (.full, .short), (.long, .medium), (.long, .short),
      (.medium, .medium), (.medium, .short), (.short, .short),
    ]
    return styles.map { dateStyle, timeStyle in
      let formatter = DateFormatter()
      formatter.dateStyle = dateStyle
      formatter.timeStyle = timeStyle
      return formatter
    }
  }()

  private static func parse(_ raw: String) -> Date? {
    for parser in parsers {
      if let date = parser.date(from: raw) { return date }
    }
    return nil
  }

  /// Exposed so the AppleScript path can hand back a real `Date` and share the
  /// file-system path's formatting.
  static func date(from raw: String) -> Date? { parse(raw) }

  private static let compact: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()

  private static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter
  }()

  /// "2026-07-27 14:13", or the original string if it cannot be parsed.
  static func short(_ raw: String) -> String {
    parse(raw).map { compact.string(from: $0) } ?? raw
  }

  /// ISO-8601, or nil when unparseable. Emitted alongside the raw string in
  /// JSON so callers get something sortable without guessing at the locale.
  static func isoString(_ raw: String) -> String? {
    parse(raw).map { iso.string(from: $0) }
  }
}

// MARK: - Compose

/// Creating a message is the least reliable corner of Mail's AppleScript
/// interface. What follows is what actually works, established empirically:
///
///  * `save` on an outgoing message reliably produces a draft, filed in the
///    Drafts mailbox of whichever account matches `sender`.
///  * Values must be passed as argv. Interpolating them into the script breaks
///    on quotes and backslashes, and would let message text run as AppleScript.
///  * File paths must be coerced to aliases OUTSIDE the `tell application
///    "Mail"` block. Inside it, `POSIX file` resolves in Mail's own context and
///    fails with -1728.
///  * Attachments go into `content of msg` `at after the last paragraph`, and
///    only after the body is set.
///  * Reading `to recipients` / `cc recipients` / `bcc recipients` back off a
///    saved draft is BROKEN — all three return the last-added recipient. The
///    RFC822 `source` is the only trustworthy read. Nothing here relies on the
///    property read; the tests parse `source`.
///  * Mail wraps any programmatically set body in
///    `<blockquote type="cite">`, with the quote styling neutralised inline.
///    This happens for `content`, for `html content` and for visible compose
///    windows alike — there is no way to avoid it from AppleScript.
private let composeScript = """
  on run argv
    set theSubject to item 1 of argv
    set theBody to item 2 of argv
    set theSender to item 3 of argv
    set bodyIsHTML to (item 4 of argv is "1")
    set theAction to item 5 of argv

    set i to 6
    set toList to {}
    set n to (item i of argv) as integer
    set i to i + 1
    repeat n times
      set end of toList to item i of argv
      set i to i + 1
    end repeat

    set ccList to {}
    set n to (item i of argv) as integer
    set i to i + 1
    repeat n times
      set end of ccList to item i of argv
      set i to i + 1
    end repeat

    set bccList to {}
    set n to (item i of argv) as integer
    set i to i + 1
    repeat n times
      set end of bccList to item i of argv
      set i to i + 1
    end repeat

    -- Resolve attachments to aliases here, outside the Mail tell block.
    set fileList to {}
    set n to (item i of argv) as integer
    set i to i + 1
    repeat n times
      set end of fileList to ((POSIX file (item i of argv)) as alias)
      set i to i + 1
    end repeat

    tell application "Mail"
      if bodyIsHTML then
        set msg to make new outgoing message with properties {subject:theSubject, visible:false}
        set html content of msg to theBody
      else
        set msg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
      end if

      -- --from accepts an account name as well as an address, because the
      -- names people see can be emoji and are not valid senders.
      -- `item 1 of (email addresses of acct)` yields nothing, the same way
      -- iterating that list does. Coercing the list to text is the form that
      -- works, so take the first comma-separated item off that.
      if theSender is not "" and theSender does not contain "@" then
        set AppleScript's text item delimiters to ","
        repeat with acct in every account
          if (name of acct) is theSender then
            try
              set theSender to text item 1 of ((email addresses of acct) as string)
            end try
          end if
        end repeat
      end if

      tell msg
        if theSender is not "" then set sender to theSender
        repeat with a in toList
          make new to recipient at end of to recipients with properties {address:a}
        end repeat
        repeat with a in ccList
          make new cc recipient at end of cc recipients with properties {address:a}
        end repeat
        repeat with a in bccList
          make new bcc recipient at end of bcc recipients with properties {address:a}
        end repeat
      end tell

      repeat with f in fileList
        tell content of msg
          make new attachment with properties {file name:f} at after the last paragraph
        end tell
        delay 0.4
      end repeat

      if theAction is "send" then
        send msg
        return "sent"
      else
        save msg
        return "saved|" & (subject of msg) & "|" & (sender of msg)
      end if
    end tell
  end run
  """

struct ComposeOptions: ParsableArguments {
  @Option(name: .long, help: "Recipient address. Repeat for several.")
  var to: [String] = []

  @Option(name: .long, help: "Cc address. Repeat for several.")
  var cc: [String] = []

  @Option(name: .long, help: "Bcc address. Repeat for several.")
  var bcc: [String] = []

  @Option(name: .long, help: "Subject line")
  var subject: String = ""

  @Option(name: .long, help: "Message body")
  var body: String?

  @Option(name: .long, help: "Read the body from a file, or '-' for stdin")
  var bodyFile: String?

  @Flag(name: .long, help: "Treat the body as HTML")
  var html = false

  @Option(name: .long, help: "Send from this account address; defaults to your default account")
  var from: String?

  @Option(name: .long, help: "File to attach. Repeat for several.")
  var attach: [String] = []

  /// Resolves --body / --body-file, validates attachments, and returns the
  /// argv vector the compose script expects.
  func arguments(action: String) throws -> [String] {
    if body != nil && bodyFile != nil {
      throw ValidationError("pass either --body or --body-file, not both")
    }

    var text = body ?? ""
    if let bodyFile {
      if bodyFile == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        text = String(data: data, encoding: .utf8) ?? ""
      } else {
        guard let contents = try? String(contentsOfFile: bodyFile, encoding: .utf8) else {
          throw ValidationError("could not read --body-file '\(bodyFile)'")
        }
        text = contents
      }
    }

    guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else {
      throw ValidationError("no recipients; pass at least one --to, --cc or --bcc")
    }

    // Validate attachments up front. A path that fails inside the script aborts
    // it midway and leaves an orphan draft behind.
    var paths: [String] = []
    for path in attach {
      let expanded = (path as NSString).expandingTildeInPath
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
            !isDirectory.boolValue else {
        throw ValidationError("attachment not found (or is a directory): \(path)")
      }
      paths.append(URL(fileURLWithPath: expanded).standardizedFileURL.path)
    }

    var argv = [subject, text, from ?? "", html ? "1" : "0", action]
    argv.append(String(to.count));  argv.append(contentsOf: to)
    argv.append(String(cc.count));  argv.append(contentsOf: cc)
    argv.append(String(bcc.count)); argv.append(contentsOf: bcc)
    argv.append(String(paths.count)); argv.append(contentsOf: paths)
    return argv
  }
}

struct Draft: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Create a draft message (does not send)",
    discussion: """
      Writes to the Drafts mailbox of the account matching --from. Never sends.
      Get the addresses --from accepts from `apple-mail accounts`; an account
      name works too.

      Examples:
        apple-mail draft --to a@b.com --subject "Q3" --body "Here it is."
        apple-mail draft --to a@b.com --cc c@d.com --bcc e@f.com --subject "Hi" \\
                         --body "text" --attach ~/report.pdf
        apple-mail draft --to a@b.com --from "dan@theinevitable.co" \\
                         --subject "Re: budget" --body-file -   # body on stdin
        apple-mail draft --to a@b.com --subject "Hi" --html --body "<p>Hi</p>"
      """)

  @OptionGroup var compose: ComposeOptions

  @Option(
    name: .long,
    help: "Message-ID of a draft to replace: write this one, then trash that one")
  var replace: String?

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    // Mail cannot edit a saved draft in place — `set sender` errors once saved,
    // and reading recipients back returns the last-added one for every list. So
    // "replace" is write-then-remove, in that order: if the removal fails the
    // user has two drafts, which is recoverable, whereas removing first and
    // failing to write loses the content outright.
    let target = replace.map { strippingAngleBrackets($0.trimmingCharacters(in: .whitespaces)) }
    if let target {
      guard try countDrafts(messageID: target) > 0 else {
        throw ValidationError(
          "No draft with Message-ID '\(target)' to replace. Nothing was written. "
            + "Check with: apple mail search \"\" --mailbox drafts --json")
      }
    }

    // Learning the Message-ID costs two full enumerations of Drafts, and Mail
    // degrades badly under Apple Event volume — its scripting interface stops
    // answering entirely if pushed. So only pay for it when the caller can
    // actually use the answer.
    let wantsMessageID = json || replace != nil
    let idsBefore = wantsMessageID ? ((try? draftMessageIDs()) ?? []) : []

    let argv = try compose.arguments(action: "save")
    let result = try runAppleScript(composeScript, arguments: argv)

    let parts = result.split(separator: "|", maxSplits: 2).map(String.init)
    let subject = parts.count > 1 ? parts[1] : compose.subject
    let sender = parts.count > 2 ? parts[2] : ""

    // Exactly one new id means we know which draft is ours. Zero or several
    // (a concurrent save, or Mail not having settled) leaves it unreported
    // rather than guessed at.
    var messageID = ""
    if wantsMessageID {
      let appeared = ((try? draftMessageIDs()) ?? []).subtracting(idsBefore)
      if appeared.count == 1 { messageID = appeared.first! }
    }

    var removal: DraftRemoval?
    if let target {
      removal = try removeDraft(messageID: target, account: nil)
      if removal == .failed {
        warn(
          "warning: the new draft was saved, but Mail would not move the old one (\(target)) "
            + "out of Drafts. You now have both — remove the old one in Mail.app.")
      }
    }

    if json {
      var payload: [String: Any] = [
        "status": "saved", "subject": subject, "sender": sender,
        "to": compose.to, "cc": compose.cc, "bcc": compose.bcc,
        "attachments": compose.attach.count,
      ]
      if !messageID.isEmpty { payload["message_id"] = messageID }
      if let target {
        payload["replaced"] = target
        // "removed" means Mail performed the move — the old draft is on its
        // way to trash. "confirmed" means Drafts no longer lists it, which can
        // lag by seconds on IMAP and is not something to block on.
        payload["replaced_removed"] = removal != .failed
        payload["replaced_confirmed"] = removal == .confirmed
      }
      let data = try JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
      print("Draft saved: \(subject.isEmpty ? "(no subject)" : subject)")
      if !sender.isEmpty { print("  from: \(sender)") }
      let recipients = compose.to + compose.cc.map { "cc:" + $0 } + compose.bcc.map { "bcc:" + $0 }
      print("  to:   \(recipients.joined(separator: ", "))")
      if !messageID.isEmpty { print("  id:   \(messageID)") }
      if let target, removal != .failed { print("Replaced \(target) — the old draft is in trash.") }
      print("It is in your Drafts mailbox — review it in Mail before sending.")
    }
  }
}

// MARK: - Removing a draft

/// Mail's scripting interface offers four ways to remove a message and only
/// one of them works. Verified against real drafts on macOS 27:
///
///     delete <message>                  silently does nothing
///     move <message> to mailbox "..."   errors
///     set deleted status to true        "Connection is invalid"
///     set mailbox of <message> to ...   WORKS
///
/// Two traps make the working route look broken. The Drafts enumeration is
/// stale within a single script run, so a loop that re-scans after each move
/// keeps finding messages it already moved — ids are collected first and each
/// is moved exactly once. And a move occasionally reports success without
/// taking effect, so the caller re-checks and retries rather than trusting the
/// count this returns.
///
/// Only ever enumerates `mailbox "Drafts"`, so it cannot touch sent or
/// received mail even if handed the Message-ID of one.
private let deleteDraftScript = """
  on run argv
    set target to item 1 of argv
    set acctFilter to item 2 of argv
    set moved to 0
    tell application "Mail"
      repeat with acct in every account
        if acctFilter is "" or (name of acct) is acctFilter then
          try
            set doomed to {}
            repeat with m in messages of (mailbox "Drafts" of acct)
              set mid to ""
              try
                set mid to (message id of m) as string
              end try
              if mid is target then set end of doomed to (id of m)
            end repeat
            repeat with theId in doomed
              try
                set m to (first message of (mailbox "Drafts" of acct) whose id is theId)
                set done to false
                repeat with tn in {"Deleted Messages", "Trash", "Deleted Items", "Bin"}
                  if not done then
                    try
                      set mailbox of m to mailbox tn of acct
                      set done to true
                      set moved to moved + 1
                    end try
                  end if
                end repeat
              end try
            end repeat
          end try
        end if
      end repeat
    end tell
    return moved as string
  end run
  """

/// How many drafts still carry this Message-ID. The only trustworthy check
/// that a removal took effect.
private let countDraftScript = """
  on run argv
    set target to item 1 of argv
    set n to 0
    tell application "Mail"
      repeat with acct in every account
        try
          repeat with m in messages of (mailbox "Drafts" of acct)
            set mid to ""
            try
              set mid to (message id of m) as string
            end try
            if mid is target then set n to n + 1
          end repeat
        end try
      end repeat
    end tell
    return n as string
  end run
  """

/// Drafts, read from Mail's index rather than by asking Mail.
///
/// Every Apple Event spent here is charged against a budget Mail enforces by
/// becoming unresponsive — its scripting interface stops answering under
/// sustained volume, and enumerating Drafts is among the most expensive things
/// to ask it for. The index carries the same information, is measurably
/// fresher than the scripting enumeration (a new draft appears immediately,
/// while a moved one lingers there for ~135s), and costs a local SQLite read.
///
/// Returns nil when the index cannot be read — no Full Disk Access — so the
/// caller falls back to AppleScript rather than reporting an empty mailbox.
private func draftsFromIndex() -> [[String: Any]]? {
  guard let index = try? EnvelopeIndex.open(), let boxes = try? index.mailboxes() else {
    return nil
  }
  let wanted = MailboxNames.matching("drafts")
  let draftBoxes = boxes.filter { wanted.contains($0.name.lowercased()) }
  guard !draftBoxes.isEmpty else { return [] }

  var filter = EnvelopeIndex.Filter()
  filter.mailboxRowIDs = draftBoxes.map(\.rowid)
  return (try? index.messages(filter: filter, limit: nil)) ?? []
}

func countDrafts(messageID: String) throws -> Int {
  let target = strippingAngleBrackets(messageID)
  if let rows = draftsFromIndex() {
    return rows.filter { strippingAngleBrackets($0["message_id"] as? String ?? "") == target }.count
  }
  return Int(try runAppleScript(countDraftScript, arguments: [messageID])) ?? 0
}

/// Every Message-ID currently in Drafts.
///
/// Used to learn the Message-ID of a draft that was just written, by diffing
/// across the save. An outgoing message has no `message id` at all — asking
/// for it errors with "Can't make «class meid» of «class bcke»" — and Mail
/// only assigns one once the message lands in Drafts. Matching on the subject
/// instead would pick the wrong draft whenever two share one.
///
/// Deliberately a separate `osascript` run from the save: the Drafts
/// enumeration is stale *within* a single script run, so a re-scan after
/// saving in the same script would not see the new message.
private let draftIDsScript = """
  on run argv
    set out to ""
    tell application "Mail"
      repeat with acct in every account
        try
          repeat with m in messages of (mailbox "Drafts" of acct)
            try
              set out to out & ((message id of m) as string) & linefeed
            end try
          end repeat
        end try
      end repeat
    end tell
    return out
  end run
  """

func draftMessageIDs() throws -> Set<String> {
  if let rows = draftsFromIndex() {
    return Set(
      rows.compactMap { $0["message_id"] as? String }
        .map(strippingAngleBrackets)
        .filter { !$0.isEmpty })
  }
  return Set(
    try runAppleScript(draftIDsScript)
      .split(separator: "\n").map(String.init)
      .map(strippingAngleBrackets)
      .filter { !$0.isEmpty })
}

enum DraftRemoval {
  /// A copy is in a trash mailbox — the removal demonstrably happened.
  case confirmed
  /// Mail reported the move but it could not be independently verified.
  case issued
  /// Mail did not move anything and the draft is still in Drafts.
  case failed
}

/// Whether any copy of this message is now in a trash mailbox, according to
/// Mail's own index. Best-effort: needs Full Disk Access, which `delete-draft`
/// otherwise does not, so an unreadable index is not an error.
private func hasTrashCopy(messageID: String) -> Bool {
  guard let index = try? EnvelopeIndex.open(),
    let boxes = try? index.mailboxes()
  else { return false }
  let byURL = Dictionary(boxes.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
  for candidate in messageIDCandidates(messageID) {
    guard let rows = try? index.messages(withMessageID: candidate) else { continue }
    for row in rows {
      if let url = row["mailbox_url"] as? String, let box = byURL[url], box.isTrash { return true }
    }
  }
  return false
}

/// Move every Drafts copy of `messageID` to trash.
///
/// Verification deliberately does *not* wait for the message to leave Drafts.
/// An IMAP move is copy-then-expunge, so the index shows the message in trash
/// *and* Drafts at once, and the Drafts copy survives until the server
/// expunges — measured at ~135 seconds, consistently. Polling the Drafts
/// enumeration for that is both useless and actively harmful: every check
/// enumerates all Drafts, and Mail's scripting interface stops answering
/// entirely under sustained Apple Event volume.
///
/// So success is judged on the trash copy appearing, which the index reports
/// immediately, and the move count is the fallback when the index cannot be
/// read.
func removeDraft(messageID: String, account: String?) throws -> DraftRemoval {
  let moved = Int(try runAppleScript(deleteDraftScript, arguments: [messageID, account ?? ""])) ?? 0
  if hasTrashCopy(messageID: messageID) { return .confirmed }
  if moved > 0 { return .issued }
  // Nothing moved and nothing in trash — but if it is no longer in Drafts
  // either, someone else removed it and there is nothing to report as broken.
  return (try countDrafts(messageID: messageID)) > 0 ? .failed : .confirmed
}

struct DeleteDraft: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete-draft",
    abstract: "Move a draft to trash, by Message-ID",
    discussion: """
      Only ever touches the Drafts mailbox, so it cannot delete sent or received
      mail. `draft --json` reports the Message-ID of what it just wrote; `search
      --mailbox drafts --json` finds one you did not create in this session.

      This is a move to trash, not a purge — the draft lands in Deleted
      Messages / Deleted Items / Trash depending on the account, and there is no
      API to empty that.

      Needs Automation → Mail, and Mail.app running.
      """)

  @Argument(help: "Message-ID of the draft (from `draft --json` or `search`)")
  var messageId: String

  @Option(name: .long, help: "Only look in this account")
  var account: String?

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    let id = strippingAngleBrackets(messageId.trimmingCharacters(in: .whitespaces))

    let before = try countDrafts(messageID: id)
    guard before > 0 else {
      throw ValidationError(
        "No draft with Message-ID '\(id)'. It may already be gone, or it may not be a draft — "
          + "this only looks in Drafts. Check with: apple mail search \"\" --mailbox drafts --json")
    }

    // Trusting the move's own report is exactly the mistake that made this
    // look unreliable; the membership is re-read instead.
    let outcome = try removeDraft(messageID: id, account: account)
    guard outcome != .failed else {
      throw AppleScriptError(
        message:
          "Mail would not move draft '\(id)' out of Drafts. Try again, or move it to Trash "
          + "in Mail.app.")
    }

    if json {
      let payload: [String: Any] = [
        "status": "deleted", "message_id": id, "removed": before,
        "confirmed": outcome == .confirmed,
      ]
      let data = try JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
      print("Draft moved to trash: \(id)")
      if before > 1 { print("  (\(before) copies)") }
    }
    // The Drafts copy of an IMAP message survives the move until the server
    // expunges it — around two minutes. Saying so is the difference between a
    // caller re-listing Drafts and trusting the result, or concluding the
    // delete silently failed.
    warn(
      "note: a copy is in trash now, but the Drafts copy remains until the server "
        + "expunges it (~2 min on IMAP). Re-listing drafts before then still shows it.")
  }
}

struct Send: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Send a message immediately (requires --confirm)")

  @OptionGroup var compose: ComposeOptions

  @Flag(name: .long, help: "Required. Sending cannot be undone.")
  var confirm = false

  func run() async throws {
    guard confirm else {
      throw ValidationError("""
        refusing to send without --confirm. Sending is immediate and irreversible.
        Prefer `apple mail draft` with the same flags, review it in Mail, and send by hand.
        """)
    }
    let argv = try compose.arguments(action: "send")
    _ = try runAppleScript(composeScript, arguments: argv)
    print("Sent to: \(compose.to.joined(separator: ", "))")
  }
}

// MARK: - AppleScript Helper

func runAppleScript(_ source: String, arguments: [String] = []) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  // Values go through argv, never string-interpolated into the script. Quotes,
  // backslashes, newlines, emoji and non-ASCII all survive verbatim, and there
  // is no way for message text to be parsed as AppleScript.
  process.arguments = ["-e", source] + arguments

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr

  try process.run()
  process.waitUntilExit()

  let outData = stdout.fileHandleForReading.readDataToEndOfFile()
  let errData = stderr.fileHandleForReading.readDataToEndOfFile()

  if process.terminationStatus != 0 {
    let errStr = String(data: errData, encoding: .utf8) ?? "Unknown AppleScript error"
    throw AppleScriptError(message: errStr.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  return String(data: outData, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

struct AppleScriptError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
