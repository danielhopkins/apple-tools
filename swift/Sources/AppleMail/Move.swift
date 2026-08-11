import AppleToolsStyle
import ArgumentParser
import Foundation
import MailLibrary

// MARK: - Moving received mail between mailboxes

/// One *copy* of one message, resolved off the index and ready to hand to Mail.
///
/// A Message-ID can name several copies — the same mail in INBOX and Archive,
/// or in two accounts — so this is deliberately per-copy rather than per-ID.
/// Each is reported separately, because "moved" is a different answer for each
/// one.
struct MoveTarget {
  let messageID: String
  /// Mail's AppleScript `id of message`.
  ///
  /// This is the Envelope Index ROWID, verified identical against a live store:
  /// `first message of <mailbox> whose id is <rowid>` returned the matching
  /// `message id` header every time. It is the reason this command can exist —
  /// see `moveScript` for why the alternative is unacceptable.
  let rowid: Int64
  let accountName: String
  let source: MailboxRef
  let destination: MailboxRef
  let subject: String
}

/// A copy that will not be moved, and why. Not an error: a sweep that names a
/// message already sitting in the destination should say so and carry on.
struct MoveSkip {
  let messageID: String
  let reason: String
}

/// A copy that could not be resolved or that Mail refused. Collected rather
/// than thrown — a 200-message sweep that dies on the first stale ID leaves the
/// mailbox in a state nobody can describe.
struct MoveFailure {
  let messageID: String
  let reason: String
  var accountName: String?
  var sourcePath: String?
}

/// Move the named copies to `dst`, in one Apple Event per message.
///
/// **The predicate is `whose id is <n>`, and that is load-bearing.** Mail's
/// scripting interface stops answering under sustained load, and the way this
/// tool has wedged it before is a whole-mailbox walk: enumerating every message
/// to compare a header. `delete-draft` gets away with exactly that because
/// Drafts holds a handful of messages; a sweep out of INBOX or Junk does not.
///
/// Measured on this store's 37,220-message Archive: `whose id is` answers in
/// 0.9s, and identically for the newest and the oldest message in the mailbox —
/// so Mail resolves it against an index rather than by scanning. For comparison
/// the AppleScript *search* engine takes 154s over the same store. Never
/// rewrite this as a `repeat with m in messages of …`.
///
/// The account is addressed by **id, not display name**. Mail's account `id` is
/// the same UUID the Envelope Index uses in its mailbox URLs — verified live:
/// `first account whose id is "F0B7E186-…"` returned the account whose display
/// name is `🌈`. Display names are not unique and are user-editable, so matching
/// on one could file mail into the wrong account's mailbox; the UUID is the
/// identifier the index already resolved everything against.
///
/// `read status` is set before the move, while the reference is still valid.
private func moveScript(inScriptTimeout: Int) -> String {
  """
  on run argv
    set acctID to item 1 of argv
    set srcPath to item 2 of argv
    set dstPath to item 3 of argv
    set markRead to item 4 of argv
    set out to ""
    with timeout of \(inScriptTimeout) seconds
      tell application "Mail"
        set acct to first account whose id is acctID
        set src to mailbox srcPath of acct
        set dst to mailbox dstPath of acct
        repeat with i from 5 to (count of argv)
          set theId to item i of argv
          try
            set m to first message of src whose id is (theId as integer)
            if markRead is "1" then set read status of m to true
            set mailbox of m to dst
            set out to out & theId & tab & "ok" & linefeed
          on error errMsg number errNum
            if errNum is -1712 then error errMsg number errNum
            set out to out & theId & tab & "err" & tab & errMsg & linefeed
          end try
        end repeat
      end tell
    end timeout
    return out
  end run
  """
}

struct Move: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "move",
    abstract: "Move received messages to another mailbox, by Message-ID",
    discussion: """
      Built for sweeps: filing the mail that arrived before a filter rule
      existed, or rescuing mail that was filed wrongly. Takes many Message-IDs
      at once, and `-` reads them from stdin, one per line.

      This moves real mail, and the move syncs everywhere. Run it with --dry-run
      first — that resolves everything against Mail's index and prints what
      would move without sending Mail a single Apple Event.

      Destination mailboxes are per-account and must exist; nothing is created.
      Name them as `apple mail accounts` prints them, or by full path for a
      nested one (Gmail's are `[Gmail]/All Mail`, not `All Mail`).

      A Message-ID can have copies in more than one mailbox. Every copy is
      moved and reported separately; narrow with --from or --account.

      Drafts are refused — their Message-ID changes when they are edited, so a
      sweep would act on the wrong message. Use `delete-draft` instead.

      Needs Full Disk Access to resolve the messages, and Automation → Mail with
      Mail.app running to move them.

      Examples:
        apple-mail search "receipt" --mailbox inbox --json | jq -r '.[].id' \\
          | apple-mail move - --to Receipts --dry-run
        apple-mail move <id> <id> --to Receipts --mark-read --json
      """)

  @Argument(help: "Message-IDs to move, or `-` to read them from stdin")
  var messageIds: [String] = []

  @Option(name: .long, help: "Destination mailbox, in each message's own account")
  var to: String

  @Option(name: .long, help: "Only move copies in this mailbox")
  var from: String?

  @Option(name: .long, help: "Only move copies in this account")
  var account: String?

  @Flag(name: .long, help: "Resolve and report what would move, touching nothing")
  var dryRun = false

  @Flag(name: .long, help: "Mark each message read as it moves")
  var markRead = false

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  /// Ids from argv, or from stdin when the sole argument is `-`. A sweep is
  /// usually the tail of a pipeline, and argv has a length limit that a few
  /// thousand Message-IDs would reach.
  private func collectMessageIDs() throws -> [String] {
    var raw = messageIds
    if raw.contains("-") {
      raw.removeAll { $0 == "-" }
      let piped = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
      raw.append(contentsOf: piped.components(separatedBy: .newlines))
    }

    var seen = Set<String>()
    var ids: [String] = []
    for entry in raw {
      let id = strippingAngleBrackets(entry.trimmingCharacters(in: .whitespaces))
      guard !id.isEmpty, seen.insert(id).inserted else { continue }
      ids.append(id)
    }
    guard !ids.isEmpty else {
      throw ValidationError(
        "No Message-IDs given. Pass them as arguments, or `-` to read them from stdin.")
    }
    return ids
  }

  func run() async throws {
    let ids = try collectMessageIDs()

    let index: EnvelopeIndex
    do {
      index = try EnvelopeIndex.open()
    } catch {
      throw MailUnavailable(message: """
        cannot resolve messages: \(error.localizedDescription)
        move reads Mail's own index to find each message, which needs Full Disk Access for \
        this terminal (System Settings → Privacy & Security → Full Disk Access).
        """)
    }
    if index.isStale {
      warn(
        "warning: could not replay Mail's write-ahead log, so recently received mail may be "
          + "invisible here. Quitting Mail.app and retrying usually fixes this.")
    }

    let resolved = try resolve(ids: ids, index: index)
    let targets = resolved.targets
    let skips = resolved.skips
    var failures = resolved.failures

    if dryRun {
      report(moved: [], failures: failures, skips: skips, planned: targets)
      // An id that will not resolve is a finding, not a rehearsal detail: a
      // caller checking the exit code before running for real should see it
      // now rather than at the point where mail starts moving.
      throw ExitCode(failures.isEmpty ? 0 : 1)
    }

    guard !targets.isEmpty else {
      report(moved: [], failures: failures, skips: skips, planned: [])
      throw ExitCode(failures.isEmpty ? 0 : 1)
    }

    // Bounded, and refuses to start against a Mail that is down or already
    // stuck — the same gate every other Apple Event in this tool goes through.
    try MailPreflight.check("Moving messages")

    var outcomes: [(target: MoveTarget, outcome: Outcome)] = []
    for (group, members) in Self.grouped(targets) {
      // Chunked so one wedge or timeout costs a chunk rather than the sweep,
      // and so the deadline stays proportionate to the work in flight.
      for chunk in stride(from: 0, to: members.count, by: 25).map({
        Array(members[$0..<min($0 + 25, members.count)])
      }) {
        let deadline = MailDeadline.move(count: chunk.count)
        let arguments =
          [group.accountUUID, group.source, group.destination, markRead ? "1" : "0"]
          + chunk.map { String($0.rowid) }

        do {
          let output = try runAppleScript(
            moveScript(inScriptTimeout: MailDeadline.inScript(under: deadline)),
            arguments: arguments, deadline: deadline)
          let verdicts = parseMoveVerdicts(output)
          for target in chunk {
            switch verdicts[String(target.rowid)] {
            case .some(nil):
              outcomes.append((target, .moved))
            case .some(.some(let message)):
              // Mail named this message and declined it. That is an answer, and
              // it is not second-guessed below.
              outcomes.append((target, .refused(message)))
            case nil:
              outcomes.append((target, .unknown("Mail reported nothing for this message")))
            }
          }
        } catch {
          // A whole chunk lost — a timeout, or Mail refusing the account or
          // mailbox outright. Which of these Mail got through before it stopped
          // answering is exactly what we do not know, so they are `unknown` and
          // the index gets to decide.
          for target in chunk {
            outcomes.append((target, .unknown(error.localizedDescription)))
          }
        }
      }
    }

    // Ask the index about everything Mail did not explicitly refuse. A message
    // Mail never reported on may still have been moved — killing `osascript`
    // does not call off work Mail already started — and reporting a move that
    // demonstrably happened as a failure sends the caller back to re-run it.
    let checkable = outcomes.filter { !$0.outcome.isRefusal }.map(\.target)
    let confirmed = confirm(checkable)

    var moved: [MoveTarget] = []
    for (target, outcome) in outcomes {
      let landed = confirmed.contains(Self.key(target))
      switch outcome {
      case .moved:
        moved.append(target)
      case .unknown where landed:
        moved.append(target)
      case .unknown(let reason):
        failures.append(
          MoveFailure(
            messageID: target.messageID, reason: reason,
            accountName: target.accountName, sourcePath: target.source.path))
      case .refused(let reason):
        failures.append(
          MoveFailure(
            messageID: target.messageID, reason: reason,
            accountName: target.accountName, sourcePath: target.source.path))
      }
    }

    report(moved: moved, failures: failures, skips: skips, planned: [], confirmed: confirmed)

    if !moved.isEmpty {
      // Same shape as delete-draft's warning, and the same cause: an IMAP move
      // is copy-then-expunge, so the source copy survives in the index until
      // the server catches up. A re-listing before then is not a failed move.
      warn(
        "note: the copies are in \(to) now, but the originals linger in their old mailbox "
          + "until the server expunges them (~2 min on IMAP).")
    }
    if !failures.isEmpty { throw ExitCode(1) }
  }

  /// What the script had to say about one message.
  ///
  /// The distinction that matters is `refused` versus `unknown`. Mail naming a
  /// message and declining it is an answer to be reported as-is; Mail never
  /// mentioning it — a chunk killed by the deadline — means nobody knows yet,
  /// and the index is a better witness than the silence.
  private enum Outcome {
    case moved
    case refused(String)
    case unknown(String)

    var isRefusal: Bool {
      if case .refused = self { return true }
      return false
    }
  }

  /// Identity for confirmation: a message is confirmed *into a mailbox*, so
  /// both halves are needed.
  private static func key(_ target: MoveTarget) -> String {
    "\(target.messageID)\u{1}\(target.destination.url)"
  }

  // MARK: Resolution

  private struct Resolution {
    var targets: [MoveTarget] = []
    var skips: [MoveSkip] = []
    var failures: [MoveFailure] = []
  }

  /// Everything is worked out here, from the index alone, before Mail is asked
  /// for anything. A --dry-run stops after this and is therefore free.
  private func resolve(ids: [String], index: EnvelopeIndex) throws -> Resolution {
    let boxes = try index.mailboxes()
    let byURL = Dictionary(boxes.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
    let byAccount = Dictionary(grouping: boxes, by: \.accountUUID)

    var wantedAccounts: Set<String>?
    if let account {
      let uuids = Set(try index.accountUUIDs(matching: account))
      guard !uuids.isEmpty else {
        throw ValidationError(
          "No account matching '\(account)'. Run `apple mail accounts` for the exact names.")
      }
      wantedAccounts = uuids
    }

    var result = Resolution()
    for id in ids {
      var rows: [[String: Any]] = []
      for candidate in messageIDCandidates(id) {
        rows = try index.messages(withMessageID: candidate)
        if !rows.isEmpty { break }
      }
      guard !rows.isEmpty else {
        result.failures.append(
          MoveFailure(messageID: id, reason: "not found in Mail's index"))
        continue
      }

      var considered = 0
      for row in rows {
        guard let rowid = row["rowid"] as? Int64,
          let source = byURL[row["mailbox_url"] as? String ?? ""]
        else { continue }
        if let wantedAccounts, !wantedAccounts.contains(source.accountUUID) { continue }
        if let from,
          !(source.path.lowercased() == from.lowercased()
            || MailboxNames.matching(from).contains(source.name.lowercased()))
        { continue }
        considered += 1

        let accountName = index.displayName(forAccount: source.accountUUID)
        let subject = fullSubject(
          prefix: row["subject_prefix"] as? String, subject: row["subject"] as? String)

        // A draft's Message-ID changes when it is edited and saved, so an id
        // handed to a sweep may already name a different message. Refused for
        // the same reason `reply` refuses a draft.
        if MailboxNames.aliases["drafts"]!.contains(source.name.lowercased()) {
          result.skips.append(
            MoveSkip(
              messageID: id,
              reason: "in \(accountName)/\(source.path) — drafts are refused; use delete-draft"))
          continue
        }

        // Surfaced as a ValidationError so a mistyped mailbox exits 64 with
        // usage, like every other bad option, rather than as a runtime failure.
        let destination: MailboxRef
        do {
          destination = try resolveMailbox(
            to, among: byAccount[source.accountUUID] ?? [], accountName: accountName, flag: "--to")
        } catch let error as EnvelopeIndexError {
          throw ValidationError(error.localizedDescription)
        }

        if destination.url == source.url {
          result.skips.append(
            MoveSkip(messageID: id, reason: "already in \(accountName)/\(destination.path)"))
          continue
        }

        result.targets.append(
          MoveTarget(
            messageID: id, rowid: rowid, accountName: accountName,
            source: source, destination: destination, subject: subject))
      }

      if considered == 0 {
        let where_ =
          [
            account.map { "account '\($0)'" }, from.map { "mailbox '\($0)'" },
          ].compactMap { $0 }.joined(separator: " and ")
        result.failures.append(
          MoveFailure(
            messageID: id,
            reason: where_.isEmpty ? "no movable copy found" : "no copy in \(where_)"))
      }
    }
    return result
  }

  // MARK: Talking to Mail

  /// The account is keyed by UUID, not display name — two accounts can show the
  /// same name, and the script addresses Mail by id for the same reason.
  private struct Group: Hashable {
    let accountUUID: String
    let source: String
    let destination: String
  }

  /// One script run per (account, source, destination): the script resolves
  /// those three once and then moves every id under them.
  private static func grouped(_ targets: [MoveTarget]) -> [(Group, [MoveTarget])] {
    var order: [Group] = []
    var members: [Group: [MoveTarget]] = [:]
    for target in targets {
      let group = Group(
        accountUUID: target.source.accountUUID, source: target.source.path,
        destination: target.destination.path)
      if members[group] == nil { order.append(group) }
      members[group, default: []].append(target)
    }
    return order.map { ($0, members[$0]!) }
  }

  /// Which moves the index can independently confirm.
  ///
  /// Deliberately checks that a copy has *appeared in the destination*, not
  /// that it has left the source. An IMAP move is copy-then-expunge, so the
  /// source copy survives for minutes; waiting for it to go would report a
  /// perfectly good move as failed. Same rule `delete-draft` uses for trash.
  ///
  /// Best-effort: a fresh index read that fails is not a reason to call a move
  /// unsuccessful, so an unreadable index confirms nothing and reports nothing.
  private func confirm(_ moved: [MoveTarget]) -> Set<String> {
    guard !moved.isEmpty, let index = try? EnvelopeIndex.open() else { return [] }
    var confirmed = Set<String>()
    for target in moved {
      let key = Self.key(target)
      for candidate in messageIDCandidates(target.messageID) {
        guard let rows = try? index.messages(withMessageID: candidate), !rows.isEmpty else {
          continue
        }
        if rows.contains(where: { ($0["mailbox_url"] as? String) == target.destination.url }) {
          confirmed.insert(key)
        }
        break
      }
    }
    return confirmed
  }

  // MARK: Output

  private func report(
    moved: [MoveTarget], failures: [MoveFailure], skips: [MoveSkip], planned: [MoveTarget],
    confirmed: Set<String> = []
  ) {
    let shown = dryRun ? planned : moved
    if json {
      var results: [[String: Any]] = []
      for target in shown {
        var row: [String: Any] = [
          "id": target.messageID,
          "subject": target.subject,
          "account": target.accountName,
          "from_mailbox": target.source.path,
          "to_mailbox": target.destination.path,
          "moved": !dryRun,
        ]
        if !dryRun { row["confirmed"] = confirmed.contains(Self.key(target)) }
        results.append(row)
      }
      for skip in skips {
        results.append(["id": skip.messageID, "moved": false, "skipped": skip.reason])
      }
      for failure in failures {
        var row: [String: Any] = [
          "id": failure.messageID, "moved": false, "error": failure.reason,
        ]
        if let name = failure.accountName { row["account"] = name }
        if let path = failure.sourcePath { row["from_mailbox"] = path }
        results.append(row)
      }
      let payload: [String: Any] = [
        "destination": to,
        "dry_run": dryRun,
        "moved": dryRun ? 0 : moved.count,
        "would_move": dryRun ? planned.count : 0,
        "skipped": skips.count,
        "failed": failures.count,
        "results": results,
      ]
      let data = try! JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8)!)
      return
    }

    for target in shown {
      let mark = dryRun ? Style.dim("would move") : Style.success("moved")
      let subject = target.subject.isEmpty ? "(no subject)" : target.subject
      print("\(mark)  \(Style.title(subject))")
      print(
        "    "
          + Style.dim(
            "\(target.accountName)  \(target.source.path) → \(target.destination.path)"))
    }
    for skip in skips {
      print("\(Style.dim("skipped"))  \(Style.identifier(skip.messageID))")
      print("    " + Style.dim(skip.reason))
    }
    for failure in failures {
      print("\(Style.warning("failed"))   \(Style.identifier(failure.messageID))")
      print("    " + Style.dim(failure.reason))
    }

    var parts: [String] = []
    parts.append(dryRun ? "\(shown.count) would move" : "\(shown.count) moved")
    if !skips.isEmpty { parts.append("\(skips.count) skipped") }
    if !failures.isEmpty { parts.append("\(failures.count) failed") }
    print()
    print(Style.dim(parts.joined(separator: ", ") + " → \(to)"))
    if dryRun && !shown.isEmpty {
      print(Style.dim("Nothing was moved. Re-run without --dry-run."))
    }
  }
}
