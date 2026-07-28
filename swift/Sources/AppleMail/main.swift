import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import CoreServices  // AEDeterminePermissionToAutomateTarget, for `status`
import Foundation

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
    subcommands: [Search.self, Export.self, Accounts.self, Draft.self, Send.self, Status.self]
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

    let (name, usable, advice): (String, Bool, String?) = {
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

    if json {
      var payload: [String: Any] = ["status": name, "usable": usable]
      if let advice { payload["advice"] = advice }
      let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    } else {
      print("Mail automation: \(name)\(usable ? "" : "  (cannot drive Mail)")")
      if let advice { print(advice) }
    }
  }
}

struct Accounts: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List Mail accounts and mailboxes"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
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
      Bound every search: Mail hits a ~120s AppleScript timeout and then returns
      an EMPTY result rather than an error, which looks identical to no matches.

      Examples:
        apple-mail search "invoice"                          # subject, default
        apple-mail search "budget" --field all --since 30    # slower: bodies too
        apple-mail search "" --mailbox inbox --unread --since 7 --limit 20
        apple-mail search "alice@example.com" --field sender --since 60 --json
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

  @Flag(name: .long, help: "Output as JSON")
  var json: Bool = false

  func run() async throws {
    let results = try searchAppleScript()
    if json {
      printJSON(results)
    } else {
      printTable(results)
    }
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

  func printTable(_ results: [[String: String]]) {
    if results.isEmpty {
      print("No messages found.")
      return
    }

    for (i, row) in results.enumerated() {
      let subject = row["subject"] ?? "(no subject)"
      let from = row["from"] ?? ""
      let date = row["date"] ?? ""
      let mailbox = row["mailbox"] ?? ""
      let account = row["account"] ?? ""
      let id = row["id"] ?? ""

      let location =
        [account, mailbox].filter { !$0.isEmpty }.joined(separator: "/")

      // Three lines rather than four: sender and date belong together, and the
      // "From:"/"Date:" labels were doing less work than the layout does.
      print("\(Style.dim("\(i + 1)."))  \(Style.title(subject))")
      var meta = "    \(from)"
      if !date.isEmpty {
        meta += Style.dim("  ·  ") + Style.time(AppleMailDate.short(date))
      }
      if !location.isEmpty { meta += "  " + Style.dim("[\(location)]") }
      print(meta)
      if !id.isEmpty {
        print("    " + Style.identifier(id))
      }
      print()
    }
    print(Style.dim("\(results.count) \(results.count == 1 ? "result" : "results")"))
  }

  func printJSON(_ results: [[String: String]]) {
    var results = results
    for index in results.indices {
      if let raw = results[index]["date"], let iso = AppleMailDate.isoString(raw) {
        results[index]["date_iso"] = iso
      }
    }
    let data = try! JSONSerialization.data(
      withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
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

  func run() async throws {
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

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    let argv = try compose.arguments(action: "save")
    let result = try runAppleScript(composeScript, arguments: argv)

    let parts = result.split(separator: "|", maxSplits: 2).map(String.init)
    let subject = parts.count > 1 ? parts[1] : compose.subject
    let sender = parts.count > 2 ? parts[2] : ""

    if json {
      let payload: [String: Any] = [
        "status": "saved", "subject": subject, "sender": sender,
        "to": compose.to, "cc": compose.cc, "bcc": compose.bcc,
        "attachments": compose.attach.count,
      ]
      let data = try JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
      print("Draft saved: \(subject.isEmpty ? "(no subject)" : subject)")
      if !sender.isEmpty { print("  from: \(sender)") }
      let recipients = compose.to + compose.cc.map { "cc:" + $0 } + compose.bcc.map { "bcc:" + $0 }
      print("  to:   \(recipients.joined(separator: ", "))")
      print("It is in your Drafts mailbox — review it in Mail before sending.")
    }
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
