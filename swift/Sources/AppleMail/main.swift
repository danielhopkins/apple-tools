import AppleToolsVersion
import ArgumentParser
import Foundation

@main
struct AppleMail: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "apple-mail",
    abstract: "Search and export Apple Mail messages",
    version: appleToolsVersion,
    subcommands: [Search.self, Export.self, Accounts.self]
  )
}

// MARK: - Accounts

struct Accounts: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List Mail accounts and mailboxes"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    let script = """
      tell application "Mail"
        set output to ""
        set allAccounts to every account
        repeat with acct in allAccounts
          set acctName to name of acct
          set output to output & "Account: " & acctName & linefeed
          try
            set mboxes to every mailbox of acct
            repeat with mbox in mboxes
              set output to output & "  " & name of mbox & linefeed
            end repeat
          end try
        end repeat
        return output
      end tell
      """
    let result = try runAppleScript(script)

    guard json else {
      print(result)
      return
    }

    // Reshape the indented "Account:" listing into [{name, mailboxes}].
    var accounts: [[String: Any]] = []
    for line in result.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.hasPrefix("Account: ") {
        accounts.append([
          "name": String(line.dropFirst("Account: ".count)),
          "mailboxes": [String](),
        ])
      } else if !accounts.isEmpty {
        let mailbox = line.trimmingCharacters(in: .whitespaces)
        if !mailbox.isEmpty {
          var mailboxes = accounts[accounts.count - 1]["mailboxes"] as? [String] ?? []
          mailboxes.append(mailbox)
          accounts[accounts.count - 1]["mailboxes"] = mailboxes
        }
      }
    }

    let data = try JSONSerialization.data(
      withJSONObject: accounts, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "[]")
  }
}

// MARK: - Search

struct Search: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Search mail messages"
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
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm"

    for (i, row) in results.enumerated() {
      let subject = row["subject"] ?? "(no subject)"
      let from = row["from"] ?? ""
      let date = row["date"] ?? ""
      let mailbox = row["mailbox"] ?? ""
      let account = row["account"] ?? ""
      let id = row["id"] ?? ""

      let location =
        [account, mailbox].filter { !$0.isEmpty }.joined(separator: "/")
      print("\(i + 1). \(subject)")
      print("   From: \(from)")
      print("   Date: \(date)  [\(location)]")
      if !id.isEmpty {
        print("   ID: \(id)")
      }
      print()
    }
    print("\(results.count) result(s)")
  }

  func printJSON(_ results: [[String: String]]) {
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

// MARK: - AppleScript Helper

func runAppleScript(_ source: String) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  process.arguments = ["-e", source]

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
