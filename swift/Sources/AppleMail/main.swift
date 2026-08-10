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
      Reading only. Composing was removed in 26.810.0 — Mail re-wraps any body
      written by a script in <blockquote type="cite"> the moment the draft is
      opened, so every draft this tool wrote reached recipients as a quotation.
      See docs/apple-mail-drafts.md. Compose in Mail.app.

      Examples:
        apple-mail accounts --json                        # accounts and mailboxes
        apple-mail search "invoice" --since 30 --json     # bounded search
        apple-mail export <message-id> --json             # one message
      """,
    version: appleToolsVersion,
    subcommands: [
      Search.self, Export.self, Attachments.self, Accounts.self, DeleteDraft.self, Status.self,
    ]
  )
}

// MARK: - Automation permission

/// Somewhere for the detached permission thread to leave its answer.
private final class PermissionBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: OSStatus?
  var value: OSStatus? {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); defer { lock.unlock() }; stored = newValue }
  }
}

/// Ask TCC whether we may automate Mail, under a wall-clock bound. `nil` means it
/// did not answer in time.
///
/// 🛑 **`AEDeterminePermissionToAutomateTarget` blocks for minutes when Mail's
/// scripting interface is wedged, and then answers wrongly.** Measured against a
/// wedged Mail: `AECreateDesc` returned in 0.000013s, and this call returned
/// **-600 (`procNotFound`) after 502 seconds** — with Mail running the whole time
/// at a known pid. `askUserIfNeeded: false` stops it *prompting*; it does not
/// stop it *blocking*.
///
/// Both halves of that are bugs for us. It is the first thing `status` does, so
/// the one command whose job is to answer "is Mail wedged?" without hanging sat
/// there for eight minutes — `APPLE_MAIL_PROBE_TIMEOUT` included, because that
/// bounds the osascript probe further down and this never got there. And when it
/// finally answered, `procNotFound` would have been reported as `mailNotRunning`
/// with "Open Mail.app, then check again", which is the wrong instruction for a
/// Mail that is already open and wedged.
///
/// The call cannot be cancelled, so it runs on a detached queue and the answer is
/// abandoned if it does not arrive. The work leaks until it returns; this is a
/// short-lived CLI that is about to exit, and a leaked thread is a far smaller
/// problem than a command that never finishes.
func automationPermission(timeout: TimeInterval = 3) -> OSStatus? {
  let box = PermissionBox()
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    var target = AEAddressDesc()
    let bundleID = "com.apple.mail"
    let created = bundleID.withCString { pointer in
      AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
    }
    // AECreateDesc returns OSErr (Int16), the permission call OSStatus (Int32).
    var code = OSStatus(created)
    if created == noErr {
      code = AEDeterminePermissionToAutomateTarget(
        &target, typeWildCard, typeWildCard, false)
      AEDisposeDesc(&target)
    }
    box.value = code
    done.signal()
  }
  guard done.wait(timeout: .now() + timeout) == .success else { return nil }
  return box.value
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
    //
    // 🛑 It is bounded, because it never returns against a wedged Mail. See
    // `automationPermission`.
    let code = automationPermission()

    let (automation, automationOK, automationAdvice): (String, Bool, String?) = {
      switch code {
      case nil:
        // The permission call itself blocked. That is not a grant problem — it is
        // Mail not servicing Apple Events, which is exactly what this command is
        // here to tell the user.
        return ("unknown", false,
                "The Automation permission check did not answer, which means Mail is not "
                  + "servicing Apple Events. Its grant is unknown until Mail is restarted.")
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
        return ("unknown(\(code!))", false, nil)
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

    // Whether Mail is actually answering, which is a different question from
    // whether we are allowed to ask. Only probed when the grant is already
    // authorized: on `notDetermined` the probe *is* the consent dialog this
    // command exists to avoid triggering.
    let mailRunning = isMailRunning()
    // A permission check that did not answer is itself proof Mail is not
    // answering, so say so rather than reporting `responsive` as unknown — and
    // do not then send a probe to a target we already know is not replying.
    let responsive: Bool? =
      code == nil
      ? (mailRunning ? false : nil)
      : ((automationOK && mailRunning) ? MailPreflight.isResponsive() : nil)

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

      var mailApp: [String: Any] = ["running": mailRunning]
      if let responsive { mailApp["responsive"] = responsive }

      var payload: [String: Any] = [
        "status": fileSystemOK ? (automationOK ? "authorized" : "readOnly") : automation,
        "usable": usable,
        "automation": automation,
        "filesystem": fileSystem,
        "mail_app": mailApp,
      ]
      if let advice { payload["advice"] = advice }
      if responsive == false {
        payload["advice"] =
          "Mail.app is running but not answering Apple Events — drafting and sending will "
          + "not work until it is restarted. \(wedgedAdvice)"
      }
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
      switch responsive {
      case true: print("Mail.app:                    running, answering Apple Events")
      case false: print("Mail.app:                    running but WEDGED — not answering")
      case nil: print("Mail.app:                    \(mailRunning ? "running" : "not running")")
      }
      if let advice { print(advice) }
      if responsive == false { print(wedgedAdvice) }
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

    // Mail is up, so asking it is the better answer — unless it has stopped
    // answering, in which case the store's account list (minus `enabled`) beats
    // hanging on an event that will never come back.
    do {
      try MailPreflight.check("Listing accounts from Mail")
    } catch {
      if engine == .applescript { throw error }
      warn("note: \(error.localizedDescription)")
      warn("note: reading accounts from the on-disk store instead; `enabled` will be missing.")
      try runFileSystem()
      return
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
    let result = try runAppleScript(script, deadline: MailDeadline.search)

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
      needs Full Disk Access; without it this reports the missing grant rather
      than falling back to AppleScript, because driving Mail with a
      whole-mailbox query is what wedges Mail.

      --engine applescript asks for that path anyway. It refuses --field
      content, --field all and --has-attachment (each makes Mail open every
      message body), requires Mail to be already running and answering, and
      gives up after 60s instead of hanging.

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

  /// The two ways to ask Mail for something it cannot do without reading every
  /// message body. Refused rather than warned about: the warning went to stderr
  /// while the request went to Mail anyway, and this is the single most
  /// reliable way to lock Mail up for minutes.
  func validate() throws {
    guard engine == .applescript else { return }

    if field == "content" || field == "all" {
      throw ValidationError("""
        refusing `--field \(field)` on the AppleScript engine. `content contains` makes Mail
        materialise every message body in the mailbox — a network fetch each, on an IMAP
        account — and it wedges Mail long before it answers.
        Grant Full Disk Access and drop --engine: the same search runs on Mail's index in
        about 0.2s. `--field subject` and `--field sender` are safe here.
        """)
    }

    if hasAttachment {
      throw ValidationError("""
        refusing --has-attachment on the AppleScript engine: counting attachments asks Mail
        to open every candidate message one at a time.
        Grant Full Disk Access and drop --engine — the index records attachment counts, so
        this costs nothing there.
        """)
    }
  }

  func run() async throws {
    if engine != .applescript {
      do {
        try runFileSystem()
        return
      } catch {
        // --engine filesystem is a request for that engine specifically, so a
        // silent fallback would hide exactly what the caller asked to see.
        if engine == .filesystem { throw error }
        // `auto` used to fall back to AppleScript here. It no longer does. The
        // fallback silently swapped a millisecond index read for the one code
        // path that launches Mail and drives it with a whole-mailbox predicate,
        // so the effect of a missing grant was not "slower search" but "wedged
        // Mail". Ask for that explicitly if you want it.
        throw MailUnavailable(message: """
          cannot search: \(error.localizedDescription)
          Search reads Mail's own index, which needs Full Disk Access for this terminal
          (System Settings → Privacy & Security → Full Disk Access).
          Not falling back to AppleScript on its own: that path launches Mail.app and hands it
          a whole-mailbox query, which is what wedges Mail. If you want it anyway, ask for it
          with --engine applescript --field subject.
          """)
      }
    }

    // Bounded, and refuses to start on a Mail that is down or already stuck.
    try MailPreflight.check("Searching over AppleScript")

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
    // The one value in this tool that still gets interpolated into a script
    // rather than passed as argv — a `whose` predicate is part of the query
    // expression Mail compiles, so it cannot come from an argument.
    // `escapedForAppleScriptLiteral` is what makes that safe; see its doc
    // comment for which characters break a literal and, more importantly,
    // which look like they should and must be left alone.
    let escapedQuery = escapedForAppleScriptLiteral(query)
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
      // Same reasoning as the per-account walk below: a timeout here has left
      // whole mailboxes unsearched, so report the wedge rather than a short
      // list that looks complete.
      do {
        allResults.append(
          contentsOf: parseResults(try runAppleScript(script, deadline: MailDeadline.search)))
      } catch let error as AppleScriptError where error.timedOut {
        throw MailUnavailable(message: """
          Mail stopped answering partway through the search (\(mboxRef)): \(error.message)
          Results would be missing whole mailboxes, so this is an error rather than a short list.
          \(wedgedAdvice)
          """)
      }
    }

    // Search per-account mailboxes (for things like Archive that have no unified view)
    if !perAccountToSearch.isEmpty {
      let accounts: [String]
      if let account = account {
        accounts = [account]
      } else {
        let acctScript = """
          with timeout of \(MailDeadline.inScript(under: MailDeadline.search)) seconds
            tell application "Mail"
              set output to ""
              repeat with acct in every account
                set output to output & name of acct & linefeed
              end repeat
              return output
            end tell
          end timeout
          """
        let acctResult = try runAppleScript(acctScript, deadline: MailDeadline.search)
        accounts = acctResult.split(separator: "\n").map(String.init)
      }

      for acctName in accounts {
        for mboxName in perAccountToSearch {
          // Both are interpolated, so both are escaped: the mailbox name comes
          // straight from `--mailbox`, and an account name is whatever the user
          // called the account — emoji and quotes included.
          let box = escapedForAppleScriptLiteral(mboxName)
          let acct = escapedForAppleScriptLiteral(acctName)
          let script = buildSearchScript(
            mailboxExpr: "mailbox \"\(box)\" of account \"\(acct)\"",
            predicate: predicate,
            filterSuffix: filterSuffix,
            limit: limit,
            hasAttachment: hasAttachment,
            accountExpr: "\"\(acct)\"",
            mailboxNameExpr: "\"\(box)\""
          )
          // A missing mailbox is expected — not every account has an "Archive"
          // — so a failure here is skipped rather than fatal. But a *timeout* is
          // not a missing mailbox: it means Mail is going under, and swallowing
          // it silently drops whole accounts from the results and invites the
          // next query on top. Stop and say so.
          do {
            allResults.append(
              contentsOf: parseResults(try runAppleScript(script, deadline: MailDeadline.search))
            )
          } catch let error as AppleScriptError where error.timedOut {
            throw MailUnavailable(message: """
              Mail stopped answering partway through the search (\(acctName)/\(mboxName)): \
              \(error.message)
              Results would be missing whole accounts, so this is an error rather than a short list.
              \(wedgedAdvice)
              """)
          } catch {
            continue
          }
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
    // Both callers run this under `MailDeadline.search`, so that is the budget
    // the in-script timeout has to expire inside of.
    let inScript = MailDeadline.inScript(under: MailDeadline.search)
    var lines = [
      "tell application \"Mail\"",
      "  set output to \"\"",
      "  set matchCount to 0",
      "  try",
      "    with timeout of \(inScript) seconds",
      "      set msgs to (messages of \(mailboxExpr) whose \(predicate)\(filterSuffix))",
      "      repeat with msg in msgs",
      "        if matchCount ≥ \(limit) then exit repeat",
    ]
    if hasAttachment {
      lines.append("        if (count of mail attachments of msg) > 0 then")
    }
    lines.append(contentsOf: [
      "        set msgSubject to subject of msg",
      "        set msgSender to sender of msg",
      "        set msgDate to date received of msg",
      "        set msgId to message id of msg",
      "        set msgAccount to \(accountExpr)",
      "        set msgMailbox to \(mailboxNameExpr)",
      "        set output to output & \"SUBJECT:\" & msgSubject & linefeed & \"FROM:\" & msgSender & linefeed & \"DATE:\" & (msgDate as string) & linefeed & \"ACCOUNT:\" & msgAccount & linefeed & \"MAILBOX:\" & msgMailbox & linefeed & \"MSGID:\" & msgId & linefeed & \"---\" & linefeed",
      "        set matchCount to matchCount + 1",
    ])
    if hasAttachment {
      lines.append("        end if")
    }
    lines.append(contentsOf: [
      "      end repeat",
      "    end timeout",
      // The `try` is here because a missing mailbox is expected — not every
      // account has an "Archive" — and swallowing that is what lets the walk
      // continue. A timeout is not a missing mailbox: swallowing it returns
      // whatever `output` had accumulated, which reads as a complete result
      // and is instead a search that stopped early against a Mail that is
      // going under. Re-raise it so `runAppleScript` sees -1712 and the caller
      // can tell the two apart.
      "  on error errMsg number errNum",
      "    if errNum is -1712 then error errMsg number errNum",
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
    // An empty id is not a harmless no-op: both engines match it against a
    // message whose Message-ID is itself empty, so it silently exports an
    // arbitrary message rather than reporting that nothing was asked for.
    guard !messageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError("MESSAGE-ID is empty — pass an id from `apple-mail search`.")
    }
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
    // Unlike search, export keeps its AppleScript fallback: it is the only way
    // to read a message whose body Mail has not downloaded yet. But it only
    // runs when Mail is already up and answering — never by launching Mail, and
    // never onto a queue that is already stuck.
    try MailPreflight.check("Exporting over AppleScript")
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
      let acctResult = try runAppleScript(acctScript, deadline: MailDeadline.search)
      accounts = acctResult.split(separator: "\n").map(String.init)
    }

    // Mailbox names are per-account and localised, so a hardcoded English list
    // ("INBOX", "Sent Messages", "Junk", "Trash") silently misses whole folders
    // on an Exchange account, whose real names are "Inbox", "Sent Items",
    // "Junk Email", "Deleted Items". Every mismatched by-name specifier throws,
    // the `try` swallows it, and the message reports as not found even though
    // Mail can see it. So enumerate the account's actual mailboxes and match on
    // message id, which is the one identifier that does not vary by account
    // type or language.
    //
    // The walk recurses: `every mailbox of account` returns only top-level
    // mailboxes, and Exchange accounts routinely nest user folders under them.
    //
    // Two things make the walk survivable. `whose message id is` costs a linear
    // scan per mailbox, so the well-known mailboxes are swept first and the rest
    // only if that misses — finding a sent message went 28s -> 0.9s here. And
    // every Mail interaction raises the Apple Event timeout, because the default
    // is ~120s and a cold walk of three accounts exceeded it, failing with -1712
    // where the old code would have answered (wrongly) at once.
    for acctName in accounts {
      // Values go through argv rather than being interpolated, so a message id
      // containing quotes or backslashes cannot break or inject into the script.
      let script = """
        on run argv
          set targetId to item 1 of argv
          set acctName to item 2 of argv
          set boxes to {}
          with timeout of 900 seconds
            tell application "Mail"
              try
                set boxes to every mailbox of account acctName
              end try
            end tell
          end timeout
          set preferred to {}
          set others to {}
          repeat with mbox in boxes
            set nm to ""
            with timeout of 900 seconds
              tell application "Mail"
                try
                  set nm to name of mbox
                end try
              end tell
            end timeout
            if my isLikely(nm) then
              set end of preferred to mbox
            else
              set end of others to mbox
            end if
          end repeat
          set found to my findMessage(preferred, targetId, acctName)
          if found is not "" then return found
          return my findMessage(others, targetId, acctName)
        end run

        -- Where a message almost always is, across the account types Mail
        -- supports. Only an ordering hint: a miss here still falls through to
        -- every remaining mailbox, so an unusual layout stays correct.
        on isLikely(nm)
          ignoring case
            return nm is in {"inbox", "sent", "sent items", "sent messages", ¬
              "sent mail", "archive", "drafts", "all mail"}
          end ignoring
        end isLikely

        on findMessage(mboxList, targetId, acctName)
          -- Coercing a list of addresses to string joins on the delimiter, which
          -- is "" by default: two recipients would run together into one
          -- unparseable token. The file-system engine joins on ", ", so match it.
          set AppleScript's text item delimiters to ", "
          repeat with mbox in mboxList
            set kids to {}
            with timeout of 900 seconds
              tell application "Mail"
                try
                  set msgs to (messages of mbox whose message id is targetId)
                  if (count of msgs) > 0 then
                    set msg to item 1 of msgs
                    set output to "Subject: " & subject of msg & linefeed
                    set output to output & "From: " & sender of msg & linefeed
                    -- A message in a Sent folder may carry no `date received`.
                    try
                      set output to output & "Date: " & (date received of msg as string) & linefeed
                    on error
                      try
                        set output to output & "Date: " & (date sent of msg as string) & linefeed
                      end try
                    end try
                    set output to output & "To: " & ((address of every to recipient of msg) as string) & linefeed
                    try
                      set output to output & "Cc: " & ((address of every cc recipient of msg) as string) & linefeed
                    end try
                    set output to output & "Account: " & acctName & linefeed
                    set output to output & "Mailbox: " & (name of mbox) & linefeed
                    set output to output & linefeed
                    set output to output & content of msg
                    return output
                  end if
                end try
                try
                  set kids to every mailbox of mbox
                end try
              end tell
            end timeout
            if (count of kids) > 0 then
              set nested to my findMessage(kids, targetId, acctName)
              if nested is not "" then return nested
            end if
          end repeat
          return ""
        end findMessage
        """
      // An account that cannot be walked is skipped so the next one still gets a
      // turn — but a timeout means Mail is under, and continuing would spend the
      // next account's deadline finding that out again.
      do {
        let result = try runAppleScript(
          script, arguments: [messageId, acctName], deadline: MailDeadline.export)
        if !result.isEmpty {
          print(result)
          return
        }
      } catch let error as AppleScriptError where error.timedOut {
        throw MailUnavailable(message: """
          Mail stopped answering while walking '\(acctName)' for the message: \(error.message)
          \(wedgedAdvice)
          """)
      } catch {
        continue
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

// MARK: - Attachments

struct Attachments: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List or save a message's attachments",
    discussion: """
      Lists what a message carries; --save writes the files out. Reads the
      message off disk, so it needs Full Disk Access and never involves
      Mail.app.

      An attachment is a part with a filename — the same rule Mail's own index
      uses, so this agrees with `export --json`. Nameless inline parts
      (tracking pixels) are not attachments; named inline images are, and
      --skip-inline drops them if you only want the paperclip ones.

      Examples:
        apple-mail attachments <id>                       # list
        apple-mail attachments <id> --save ~/Downloads
        apple-mail attachments <id> --save . --skip-inline
      """)

  @Argument(help: "Message ID (from search results)")
  var messageId: String

  @Option(name: .long, help: "Account name")
  var account: String?

  @Option(name: .long, help: "Directory to write the files into (created if missing)")
  var save: String?

  @Flag(name: .long, help: "Skip inline images referenced by the HTML body")
  var skipInline: Bool = false

  @Flag(name: .long, help: "Output as JSON")
  var json: Bool = false

  func run() async throws {
    let store = try MailStore()
    let (summary, all) = try store.attachments(messageID: messageId, account: account)
    let files = skipInline ? all.filter { !$0.isInline } : all

    guard let save else {
      report(files, summary: summary, written: nil)
      return
    }

    let directory = URL(fileURLWithPath: (save as NSString).expandingTildeInPath)
      .standardizedFileURL
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)

    var written: [String] = []
    for file in files {
      var destination = directory.appendingPathComponent(file.name)
      // Never overwrite. The name came from whoever sent the mail, so a
      // collision with something already in the directory is not the user's
      // doing and must not cost them the existing file.
      var attempt = 2
      while FileManager.default.fileExists(atPath: destination.path) {
        let ext = (file.name as NSString).pathExtension
        let stem = (file.name as NSString).deletingPathExtension
        let candidate = ext.isEmpty ? "\(stem)-\(attempt)" : "\(stem)-\(attempt).\(ext)"
        destination = directory.appendingPathComponent(candidate)
        attempt += 1
      }

      // Belt and braces on top of safeFilename: refuse anything that did not
      // land directly inside the target directory. Symlinks are resolved on
      // both sides — /tmp is a link to /private/tmp, so comparing the paths as
      // given rejects a perfectly good destination.
      let parent = destination.deletingLastPathComponent()
        .resolvingSymlinksInPath().standardizedFileURL.path
      let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
      guard parent == root else {
        throw ValidationError("refusing to write '\(file.name)' outside \(root)")
      }
      try file.data.write(to: destination)
      written.append(destination.path)
    }
    report(files, summary: summary, written: written)
  }

  private func report(_ files: [MailAttachment], summary: MessageSummary, written: [String]?) {
    if json {
      var payload: [String: Any] = [
        "id": summary.id,
        "subject": summary.subject,
        "count": files.count,
        "attachments": files.enumerated().map { offset, file -> [String: Any] in
          var row: [String: Any] = [
            "index": offset,
            "name": file.name,
            "content_type": file.contentType,
            "bytes": file.byteCount,
            "inline": file.isInline,
          ]
          if file.originalName != file.name { row["original_name"] = file.originalName }
          if let written, offset < written.count { row["path"] = written[offset] }
          return row
        },
      ]
      if written != nil { payload["saved"] = written?.count ?? 0 }
      let data = try! JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8)!)
      return
    }

    if files.isEmpty {
      print("No attachments.")
      return
    }
    for (offset, file) in files.enumerated() {
      let size = ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)
      var line = "\(Style.dim("\(offset + 1)."))  \(Style.title(file.name))"
      line += "  " + Style.dim("\(file.contentType), \(size)")
      if file.isInline { line += " " + Style.dim("(inline)") }
      print(line)
      if let written, offset < written.count { print("    " + Style.identifier(written[offset])) }
    }
    if let written {
      print()
      print(Style.dim("Saved \(written.count) file\(written.count == 1 ? "" : "s")."))
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

// MARK: - AppleScript Helper

/// Wall-clock budgets for the scripts that drive Mail. These bound *this
/// process*, not Mail: killing `osascript` mid-request does not call off the
/// work Mail already started, so a deadline stops us hanging and stops us
/// queueing more, but it is not a way to un-wedge Mail.
///
/// Overridable with APPLE_MAIL_SCRIPT_TIMEOUT for diagnosis and for the tests,
/// which use a tiny value to exercise the kill path.
enum MailDeadline {
  private static func env(_ name: String) -> TimeInterval? {
    guard let raw = ProcessInfo.processInfo.environment[name], let seconds = Double(raw) else {
      return nil
    }
    return seconds
  }

  /// One bounded Apple Event, used only to decide whether Mail is answering.
  /// A healthy Mail answers in ~0.2s, so seconds already mean trouble.
  static var probe: TimeInterval { env("APPLE_MAIL_PROBE_TIMEOUT") ?? 5 }

  /// A search script. The Apple Event timeout is ~120s and the script swallows
  /// it, so without this a wedged Mail hangs the CLI indefinitely.
  static var search: TimeInterval { env("APPLE_MAIL_SCRIPT_TIMEOUT") ?? 60 }

  /// The export walk enumerates every mailbox of every account and legitimately
  /// takes tens of seconds when Mail is cold, so it gets a much longer rope.
  static var export: TimeInterval { env("APPLE_MAIL_SCRIPT_TIMEOUT") ?? 300 }

  /// Composing deliberately has none. A deadline that fires mid-save would kill
  /// `osascript` with the message half-written, and a partly-saved draft is
  /// worse than a slow one.
  static let compose: TimeInterval? = nil

  /// A reply or forward, which composes *and* looks the original up first.
  ///
  /// Unlike `compose` this is bounded, because the lookup is the part that
  /// hangs: addressing a message wedged Mail here and the CLI then sat with no
  /// output at all. Generous, because the lookup legitimately takes ~6s on a
  /// 37,000-message mailbox. The `save` itself is left *outside* the in-script
  /// timeout for the same reason `compose` has none.
  static var reply: TimeInterval { env("APPLE_MAIL_SCRIPT_TIMEOUT") ?? 180 }

  /// The budget to hand AppleScript *inside* the script, sized to expire a few
  /// seconds before the process deadline above so the interpreter abandons the
  /// Apple Event and exits on its own.
  ///
  /// This does not un-wedge Mail — nothing short of restarting it does, and the
  /// work Mail has already started keeps running either way. What it buys is
  /// the manner of the give-up: a clean -1712 that `osascript` reports and
  /// exits on, instead of a SIGKILL that leaves Mail holding a reply for a
  /// process that no longer exists. The outer deadline stays as the backstop
  /// for a script that ignores its own timeout.
  ///
  /// Floored at 5s so a shrunken `APPLE_MAIL_SCRIPT_TIMEOUT` — the tests use
  /// fractions of a second — cannot produce a zero or negative `with timeout`,
  /// which AppleScript rejects at compile time.
  static func inScript(under deadline: TimeInterval) -> Int {
    max(Int(deadline) - 5, 5)
  }
}

/// Mail is running but cannot be driven, or is not running and must not be
/// launched. Distinct from AppleScriptError so callers can tell "Mail said no"
/// from "we refused to ask".
struct MailUnavailable: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

let wedgedAdvice = """
  Mail's scripting interface stops servicing Apple Events under load and does not
  recover on its own. Quit and reopen Mail.app, then retry.
  """

/// Everything that talks to Mail goes through here first.
///
/// Two failures it exists to prevent, both of which used to be reachable from a
/// plain read command:
///
///  1. **Launching Mail to read from it.** `tell application "Mail"` starts the
///     app when it is down, so a search without Full Disk Access would cold-start
///     Mail and then hand it a whole-mailbox predicate — the worst first request
///     it can be given.
///  2. **Piling onto a Mail that is already under.** Once it stops answering,
///     every further event queues behind the ones already stuck. One bounded
///     probe tells us to stop instead.
enum MailPreflight {
  /// A wedged Mail still answers static properties instantly — `name` came back
  /// at once from an app macOS was reporting as not responding — so the probe
  /// has to touch the message store, which is the thing it cannot do. Counting
  /// an account's mailboxes is the cheapest request that does.
  private static let probeScript =
    "tell application \"Mail\" to return (count of every mailbox of account 1) as string"

  /// Throws unless Mail is up and answering. `action` completes the sentence
  /// "<action> needs Mail.app", so phrase it as a gerund.
  static func check(_ action: String) throws {
    guard isMailRunning() else {
      throw MailUnavailable(message: """
        \(action) needs Mail.app, and Mail is not running. Refusing to launch it: a cold \
        Mail driven by a whole-mailbox query is how Mail gets wedged.
        Either grant Full Disk Access so reads use Mail's index instead (no Mail.app, \
        milliseconds), or open Mail yourself first.
        """)
    }

    do {
      let answer = try runAppleScript(probeScript, deadline: probe)
      // A wedged Mail returns success with empty output as readily as it errors,
      // so an empty answer counts as a failure rather than as zero mailboxes.
      guard !answer.isEmpty else {
        throw MailUnavailable(message: """
          \(action) needs Mail.app, and Mail answered an Apple Event with nothing at all — \
          it is wedged.
          \(wedgedAdvice)
          """)
      }
    } catch let error as MailUnavailable {
      throw error
    } catch let error as AppleScriptError where error.timedOut {
      throw MailUnavailable(message: """
        \(action) needs Mail.app, and Mail did not answer a trivial Apple Event within \
        \(Int(probe))s — it is wedged. Not sending the real request on top of it.
        \(wedgedAdvice)
        """)
    } catch {
      // A prompt refusal is Mail being healthy and saying no — a denied
      // Automation grant, or an account layout the probe did not expect. Pass
      // it through rather than reporting a wedge that isn't one.
      let detail = error.localizedDescription
      if detail.localizedCaseInsensitiveContains("not allowed")
        || detail.localizedCaseInsensitiveContains("not authorized")
        || detail.contains("-1743")
      {
        throw MailUnavailable(message: """
          \(action) needs Automation → Mail, which is not granted: \(detail)
          Grant it under System Settings → Privacy & Security → Automation.
          """)
      }
    }
  }

  private static var probe: TimeInterval { MailDeadline.probe }

  /// Whether Mail is answering, for `status`. Never throws and never prompts —
  /// only call it once the Automation grant is known to be authorized, or the
  /// probe becomes the consent dialog `status` exists to avoid.
  static func isResponsive() -> Bool {
    guard isMailRunning() else { return false }
    guard let answer = try? runAppleScript(probeScript, deadline: probe) else { return false }
    return !answer.isEmpty
  }
}

/// Run an AppleScript, optionally under a wall-clock deadline.
///
/// `deadline: nil` waits as long as the script takes, which is right for
/// composing and wrong for everything else.
func runAppleScript(
  _ source: String, arguments: [String] = [], deadline: TimeInterval? = nil
) throws -> String {
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

  // Drain both pipes while the script runs. Reading them only after it exits
  // deadlocks as soon as the output outgrows the 64 KB pipe buffer: osascript
  // blocks writing, we block waiting for it to exit, and neither side moves —
  // reachable with a large `search --limit`.
  let collected = ScriptOutput()
  let drained = DispatchGroup()
  for (handle, isStdout) in [
    (stdout.fileHandleForReading, true), (stderr.fileHandleForReading, false),
  ] {
    drained.enter()
    DispatchQueue.global().async {
      let data = handle.readDataToEndOfFile()
      collected.store(data, isStdout: isStdout)
      drained.leave()
    }
  }

  let exited = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in exited.signal() }
  try process.run()

  var killed = false
  if let deadline {
    if exited.wait(timeout: .now() + deadline) == .timedOut {
      // Leaving the child alive would orphan an osascript that is still driving
      // Mail — Ctrl-C on the CLI does not reach it, so it has to die here.
      killed = true
      process.terminate()
      if exited.wait(timeout: .now() + 2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 5)
      }
    }
  } else {
    exited.wait()
  }

  // Safe now either way: the child is gone, so both pipe write ends are closed
  // and the readers finish.
  drained.wait()

  if killed {
    throw AppleScriptError(
      message: "Mail did not answer within \(Int(deadline ?? 0))s; gave up and killed the script.",
      timedOut: true)
  }

  if process.terminationStatus != 0 {
    let errStr = String(data: collected.err, encoding: .utf8) ?? "Unknown AppleScript error"
    let trimmed = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
    // -1712 is Mail's own Apple Event timeout, which means the same thing as
    // ours: it is too far behind to answer.
    let itTimedOut = trimmed.contains("-1712") || trimmed.localizedCaseInsensitiveContains("timed out")
    throw AppleScriptError(message: trimmed, timedOut: itTimedOut)
  }

  return String(data: collected.out, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Somewhere for the two pipe readers to put what they read. A plain pair of
/// captured locals would be two threads writing one closure context; this makes
/// the handoff explicit and locked.
private final class ScriptOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var stdoutData = Data()
  private var stderrData = Data()

  func store(_ data: Data, isStdout: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if isStdout { stdoutData = data } else { stderrData = data }
  }

  var out: Data { lock.withLock { stdoutData } }
  var err: Data { lock.withLock { stderrData } }
}

struct AppleScriptError: LocalizedError {
  let message: String
  /// Whether the failure was a timeout — ours or Mail's -1712. Both mean "stop
  /// sending events", which a caller cannot infer from the message text.
  var timedOut: Bool = false
  var errorDescription: String? { message }
}
