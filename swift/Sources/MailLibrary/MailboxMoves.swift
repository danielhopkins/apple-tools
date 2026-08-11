import Foundation

/// Which mailbox a user-supplied name refers to, within one account.
///
/// Three rules in order, most specific first, because Gmail makes the leaf name
/// both ambiguous and unusable: the index knows the mailbox as
/// `[Gmail]/All Mail`, Mail's AppleScript accepts `mailbox "[Gmail]/All Mail"`
/// and rejects `mailbox "All Mail"` outright (-1728), and `apple mail accounts`
/// prints the leaf. So a full-path match always wins over a leaf-name match,
/// and both errors quote paths — a name copied out of `accounts` is not always
/// a name Mail will take.
///
/// The last rule is the alias table, so `--to trash` lands in `Deleted Messages`
/// on IMAP, `Deleted Items` on Exchange and `[Gmail]/Trash` on Gmail without the
/// caller knowing which is which.
///
/// `flag` names the option being resolved, so the ambiguity message can tell
/// the caller what to be more specific with.
public func resolveMailbox(
  _ wanted: String, among boxes: [MailboxRef], accountName: String, flag: String
) throws -> MailboxRef {
  let target = wanted.lowercased()

  var matches = boxes.filter { $0.path.lowercased() == target }
  if matches.isEmpty { matches = boxes.filter { $0.name.lowercased() == target } }
  if matches.isEmpty {
    let aliases = MailboxNames.matching(wanted)
    matches = boxes.filter { aliases.contains($0.name.lowercased()) }
  }

  if matches.count == 1, let only = matches.first { return only }

  if matches.isEmpty {
    throw EnvelopeIndexError.notFound("""
      No mailbox '\(wanted)' in account '\(accountName)'.
      Available: \(boxes.map(\.path).sorted().joined(separator: ", "))
      """)
  }
  throw EnvelopeIndexError.notFound("""
    '\(wanted)' is ambiguous in account '\(accountName)': \
    \(matches.map(\.path).sorted().joined(separator: ", ")).
    Name one exactly with \(flag).
    """)
}

/// What the move script reported, per message: `<id>\tok`, or
/// `<id>\terr\t<message>`.
///
/// The value is a double optional on purpose. `.some(nil)` is "Mail moved it",
/// `.some(.some(text))` is "Mail refused, and said why", and a **missing key**
/// is "Mail never mentioned this message at all" — which happens when a script
/// is killed partway through a chunk. Collapsing the last two would report a
/// message nobody looked at as one Mail declined to move.
public func parseMoveVerdicts(_ output: String) -> [String: String?] {
  var verdicts: [String: String?] = [:]
  for line in output.components(separatedBy: .newlines) {
    let fields = line.components(separatedBy: "\t")
    guard fields.count >= 2, !fields[0].isEmpty else { continue }
    if fields[1] == "ok" {
      verdicts[fields[0]] = String?.none
    } else {
      // An error message can itself contain tabs, so everything after the
      // marker is the message rather than just the next field.
      let detail = fields.count > 2 ? fields[2...].joined(separator: "\t") : ""
      verdicts[fields[0]] = detail.isEmpty ? "move failed" : detail
    }
  }
  return verdicts
}
