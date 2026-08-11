import XCTest

@testable import MailLibrary

/// `move` writes to real mail that syncs to every device, so the two pieces of
/// it that can be tested without touching Mail are tested hard: which mailbox a
/// name resolves to, and what the script's report actually said.
///
/// Both were measured against a live store — the Gmail cases in particular are
/// not hypothetical. `mailbox "All Mail"` is rejected by Mail with -1728 while
/// `mailbox "[Gmail]/All Mail"` works, and `apple mail accounts` prints the
/// leaf, so path-beats-leaf is the rule that keeps a copied-out name usable.
final class MailboxMoveTests: XCTestCase {
  private let imap = "F0B7E186-F9E9-4535-8C7C-24DBE1A5C84E"
  private let gmail = "3CB7FB07-FCFB-4367-A8D7-DCFE7A3CE447"
  private let exchange = "4061B1C3-2EAB-442B-BDD7-AA55A3C3E05C"

  private func box(_ url: String) -> MailboxRef {
    guard let ref = parseMailboxURL(rowid: 1, url: url, totalCount: 0, unreadCount: 0) else {
      preconditionFailure("bad fixture URL: \(url)")
    }
    return ref
  }

  private lazy var imapBoxes: [MailboxRef] = [
    box("imap://\(imap)/INBOX"),
    box("imap://\(imap)/Archive"),
    box("imap://\(imap)/Receipts"),
    box("imap://\(imap)/Junk"),
    box("imap://\(imap)/Deleted%20Messages"),
  ]

  private lazy var gmailBoxes: [MailboxRef] = [
    box("imap://\(gmail)/INBOX"),
    box("imap://\(gmail)/%5BGmail%5D/All%20Mail"),
    box("imap://\(gmail)/%5BGmail%5D/Trash"),
    box("imap://\(gmail)/%5BGmail%5D/Spam"),
  ]

  private lazy var exchangeBoxes: [MailboxRef] = [
    box("ews://\(exchange)/Inbox"),
    box("ews://\(exchange)/Deleted%20Items"),
    box("ews://\(exchange)/Junk%20Email"),
  ]

  // MARK: Resolution

  func testResolvesAPlainName() throws {
    let resolved = try resolveMailbox(
      "Receipts", among: imapBoxes, accountName: "🌈", flag: "--to")
    XCTAssertEqual(resolved.path, "Receipts")
  }

  func testResolutionIgnoresCase() throws {
    let resolved = try resolveMailbox(
      "receipts", among: imapBoxes, accountName: "🌈", flag: "--to")
    XCTAssertEqual(resolved.path, "Receipts")
  }

  /// A name with a space in it, percent-encoded in the URL, has to come back
  /// decoded — iCloud's trash is `Deleted Messages`, and naming it `Trash`
  /// makes IMAP create a stray folder.
  func testResolvesAPercentEncodedName() throws {
    let resolved = try resolveMailbox(
      "Deleted Messages", among: imapBoxes, accountName: "🌈", flag: "--to")
    XCTAssertEqual(resolved.path, "Deleted Messages")
  }

  /// The alias table is what lets one `--to trash` work across three account
  /// types that spell it three different ways.
  func testTrashAliasResolvesPerAccountType() throws {
    XCTAssertEqual(
      try resolveMailbox("trash", among: imapBoxes, accountName: "🌈", flag: "--to").path,
      "Deleted Messages")
    XCTAssertEqual(
      try resolveMailbox("trash", among: exchangeBoxes, accountName: "🏫", flag: "--to").path,
      "Deleted Items")
    XCTAssertEqual(
      try resolveMailbox("trash", among: gmailBoxes, accountName: "☀️", flag: "--to").path,
      "[Gmail]/Trash")
  }

  func testJunkAliasResolvesPerAccountType() throws {
    XCTAssertEqual(
      try resolveMailbox("junk", among: imapBoxes, accountName: "🌈", flag: "--to").path, "Junk")
    XCTAssertEqual(
      try resolveMailbox("junk", among: exchangeBoxes, accountName: "🏫", flag: "--to").path,
      "Junk Email")
    XCTAssertEqual(
      try resolveMailbox("junk", among: gmailBoxes, accountName: "☀️", flag: "--to").path,
      "[Gmail]/Spam")
  }

  /// Mail rejects `mailbox "All Mail"` with -1728 and accepts the full path, so
  /// a leaf name has to resolve to the path rather than being passed through.
  func testGmailLeafNameResolvesToTheFullPath() throws {
    let resolved = try resolveMailbox(
      "All Mail", among: gmailBoxes, accountName: "☀️", flag: "--to")
    XCTAssertEqual(resolved.path, "[Gmail]/All Mail")
  }

  func testGmailFullPathResolvesToItself() throws {
    let resolved = try resolveMailbox(
      "[Gmail]/All Mail", among: gmailBoxes, accountName: "☀️", flag: "--to")
    XCTAssertEqual(resolved.path, "[Gmail]/All Mail")
  }

  /// A path match must beat a leaf match, or a mailbox called `Archive` nested
  /// under something else could shadow the top-level one the caller named.
  func testAFullPathBeatsALeafOfTheSameName() throws {
    let boxes = [
      box("imap://\(imap)/Archive"),
      box("imap://\(imap)/Old/Archive"),
    ]
    XCTAssertEqual(
      try resolveMailbox("Old/Archive", among: boxes, accountName: "🌈", flag: "--to").path,
      "Old/Archive")
  }

  /// A top-level mailbox and a nested one sharing a leaf name is *not*
  /// ambiguous: the bare name is an exact path match for the top-level one, and
  /// preferring it is the whole point of trying paths first.
  func testATopLevelPathBeatsANestedLeafOfTheSameName() throws {
    let boxes = [
      box("imap://\(imap)/Archive"),
      box("imap://\(imap)/Old/Archive"),
    ]
    XCTAssertEqual(
      try resolveMailbox("Archive", among: boxes, accountName: "🌈", flag: "--to").path,
      "Archive")
  }

  /// Two mailboxes sharing a leaf name with neither at the top level: refuse
  /// rather than pick, because the wrong one is a move nobody notices until
  /// much later.
  func testAmbiguousLeafNameIsRefused() {
    let boxes = [
      box("imap://\(imap)/Old/Archive"),
      box("imap://\(imap)/New/Archive"),
    ]
    XCTAssertThrowsError(
      try resolveMailbox("Archive", among: boxes, accountName: "🌈", flag: "--to")
    ) { error in
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("ambiguous"), message)
      // Both candidates, by path, or the advice to "name one exactly" is useless.
      XCTAssertTrue(message.contains("Old/Archive"), message)
      XCTAssertTrue(message.contains("New/Archive"), message)
      XCTAssertTrue(message.contains("--to"), message)
    }
  }

  /// Nothing is ever created, so an unknown destination is an error — and it
  /// has to list what does exist, as paths.
  func testUnknownMailboxListsWhatExists() {
    XCTAssertThrowsError(
      try resolveMailbox("Nonexistent", among: gmailBoxes, accountName: "☀️", flag: "--to")
    ) { error in
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("No mailbox 'Nonexistent'"), message)
      XCTAssertTrue(message.contains("[Gmail]/All Mail"), message)
    }
  }

  /// An alias that no mailbox in this account satisfies is still an error, not
  /// a silent no-op: an Exchange account has no `Archive`.
  func testAliasWithNoMatchInThisAccountIsRefused() {
    XCTAssertThrowsError(
      try resolveMailbox("archive", among: exchangeBoxes, accountName: "🏫", flag: "--to"))
  }

  // MARK: Verdicts

  func testParsesSuccessAndFailure() {
    let verdicts = parseMoveVerdicts("101\tok\n102\terr\tMail said no\n")
    XCTAssertEqual(verdicts.count, 2)
    // .some(nil) is "moved".
    XCTAssertEqual(verdicts["101"], .some(nil))
    XCTAssertEqual(verdicts["102"], .some("Mail said no"))
  }

  /// The three states must stay distinct. A message Mail never reported on —
  /// a chunk killed by the deadline partway through — is not the same as one
  /// Mail refused, and reporting it as refused invents an error Mail never gave.
  func testAnUnmentionedMessageHasNoEntry() {
    let verdicts = parseMoveVerdicts("101\tok\n")
    XCTAssertNil(verdicts.index(forKey: "999"))
    XCTAssertEqual(verdicts["101"], .some(nil))
  }

  /// AppleScript error text is arbitrary and has contained tabs, so everything
  /// after the marker is the message.
  func testKeepsTabsInsideAnErrorMessage() {
    let verdicts = parseMoveVerdicts("102\terr\tCan't get message\tid 5\n")
    XCTAssertEqual(verdicts["102"], .some("Can't get message\tid 5"))
  }

  func testErrorWithNoTextStillCountsAsAFailure() {
    let verdicts = parseMoveVerdicts("102\terr\n")
    XCTAssertEqual(verdicts["102"], .some("move failed"))
  }

  /// Empty output is what a killed script leaves behind. It must yield no
  /// verdicts at all rather than anything that reads as success.
  func testEmptyOutputYieldsNoVerdicts() {
    XCTAssertTrue(parseMoveVerdicts("").isEmpty)
    XCTAssertTrue(parseMoveVerdicts("\n\n").isEmpty)
  }

  func testIgnoresMalformedLines() {
    let verdicts = parseMoveVerdicts("garbage\n\n101\tok\n\t\n")
    XCTAssertEqual(verdicts.count, 1)
    XCTAssertEqual(verdicts["101"], .some(nil))
  }
}
