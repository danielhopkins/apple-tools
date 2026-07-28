import XCTest

@testable import MailLibrary

/// The pure helpers around the Envelope Index. These are the ones where being
/// subtly wrong produces plausible-looking but incorrect results rather than an
/// error — the wrong mailbox, a missing file, a search that matches everything.
final class EnvelopeIndexTests: XCTestCase {

  // MARK: Mailbox URLs

  func testParsesIMAPMailboxURL() throws {
    let ref = try XCTUnwrap(
      parseMailboxURL(
        rowid: 5, url: "imap://F0B7E186-F9E9-4535-8C7C-24DBE1A5C84E/Sent%20Messages",
        totalCount: 1180, unreadCount: 0))
    XCTAssertEqual(ref.scheme, "imap")
    XCTAssertEqual(ref.accountUUID, "F0B7E186-F9E9-4535-8C7C-24DBE1A5C84E")
    XCTAssertEqual(ref.name, "Sent Messages")
    XCTAssertEqual(ref.components, ["Sent Messages"])
  }

  func testParsesNestedGmailMailboxURL() throws {
    // Gmail nests everything under [Gmail]; the name is the last component, but
    // the .emlx path needs every component.
    let ref = try XCTUnwrap(
      parseMailboxURL(
        rowid: 31, url: "imap://3CB7FB07-FCFB-4367-A8D7-DCFE7A3CE447/%5BGmail%5D/Trash",
        totalCount: 39, unreadCount: 0))
    XCTAssertEqual(ref.components, ["[Gmail]", "Trash"])
    XCTAssertEqual(ref.name, "Trash")
    XCTAssertEqual(ref.path, "[Gmail]/Trash")
    XCTAssertTrue(ref.isTrash)
  }

  func testParsesPercentEncodedEmojiMailbox() throws {
    let ref = try XCTUnwrap(
      parseMailboxURL(
        rowid: 33,
        url: "local://66C76001-4B8B-4BB8-B111-636F3DA6F77F/Recovered%20Messages%20(%F0%9F%8C%88)",
        totalCount: 22, unreadCount: 0))
    XCTAssertEqual(ref.name, "Recovered Messages (🌈)")
    XCTAssertEqual(ref.scheme, "local")
  }

  func testRejectsMailboxURLWithNoPath() {
    XCTAssertNil(parseMailboxURL(rowid: 1, url: "imap://UUID", totalCount: 0, unreadCount: 0))
    XCTAssertNil(parseMailboxURL(rowid: 1, url: "nonsense", totalCount: 0, unreadCount: 0))
  }

  // MARK: Trash and junk

  func testRecognisesTrashAcrossAccountTypes() {
    // IMAP, Exchange and Gmail each name it differently; missing one means
    // deleted mail silently comes back in search results.
    for name in ["Deleted Messages", "Deleted Items", "Trash", "Bin"] {
      let ref = parseMailboxURL(rowid: 1, url: "imap://U/\(name)", totalCount: 0, unreadCount: 0)
      XCTAssertEqual(ref?.isTrash, true, "\(name) should be trash")
    }
  }

  func testRecognisesJunkAcrossAccountTypes() {
    for name in ["Junk", "Junk Email", "Spam", "Bulk Mail"] {
      let ref = parseMailboxURL(rowid: 1, url: "imap://U/\(name)", totalCount: 0, unreadCount: 0)
      XCTAssertEqual(ref?.isJunk, true, "\(name) should be junk")
    }
  }

  func testArchiveIsNeitherTrashNorJunk() {
    let ref = parseMailboxURL(rowid: 1, url: "imap://U/Archive", totalCount: 0, unreadCount: 0)
    XCTAssertEqual(ref?.isTrash, false)
    XCTAssertEqual(ref?.isJunk, false)
  }

  // MARK: --mailbox aliases

  func testSentAliasMatchesEveryAccountTypesSpelling() {
    let matches = MailboxNames.matching("sent")
    XCTAssertTrue(matches.contains("sent messages"))  // IMAP
    XCTAssertTrue(matches.contains("sent items"))  // Exchange
    XCTAssertTrue(matches.contains("sent mail"))  // Gmail
  }

  func testAliasLookupIsCaseInsensitive() {
    XCTAssertEqual(MailboxNames.matching("INBOX"), MailboxNames.matching("inbox"))
  }

  func testUnknownMailboxNameMatchesOnlyItself() {
    XCTAssertEqual(MailboxNames.matching("Statements"), ["statements"])
  }

  // MARK: .emlx placement

  func testEmlxSubdirectoriesMatchMailsLayout() {
    // Verified against the real store: Mail splits the digits of rowid/1000,
    // least-significant first, and messages under 1000 sit directly in Data.
    XCTAssertEqual(emlxSubdirectories(forRowID: 84), [])
    XCTAssertEqual(emlxSubdirectories(forRowID: 999), [])
    XCTAssertEqual(emlxSubdirectories(forRowID: 12345), ["2", "1"])
    XCTAssertEqual(emlxSubdirectories(forRowID: 105895), ["5", "0", "1"])
  }

  // MARK: LIKE escaping

  func testEscapesLikeWildcards() {
    // Without this, searching for "50%" matches every message in the store.
    XCTAssertEqual(escapeLikePattern("50%"), "50\\%")
    XCTAssertEqual(escapeLikePattern("a_b"), "a\\_b")
    XCTAssertEqual(escapeLikePattern("back\\slash"), "back\\\\slash")
  }

  func testLeavesOrdinaryTextAlone() {
    XCTAssertEqual(escapeLikePattern("invoice"), "invoice")
  }

  // MARK: Formatting

  func testSubjectPrefixIsRejoined() {
    // Mail stores "Re: " apart from the subject; neither half alone is what
    // the user saw in the message list.
    XCTAssertEqual(fullSubject(prefix: "Re: ", subject: "Budget"), "Re: Budget")
    XCTAssertEqual(fullSubject(prefix: nil, subject: "Budget"), "Budget")
    XCTAssertEqual(fullSubject(prefix: "Fwd: ", subject: nil), "Fwd: ")
  }

  func testAddressFormatting() {
    XCTAssertEqual(
      formatAddress(address: "a@b.com", comment: "Alice"), "Alice <a@b.com>")
    XCTAssertEqual(formatAddress(address: "a@b.com", comment: ""), "a@b.com")
    XCTAssertEqual(formatAddress(address: "a@b.com", comment: "   "), "a@b.com")
  }

  // MARK: Message-IDs

  func testMessageIDCandidatesCoverBothSpellings() {
    // The index stores angle brackets, search results print without them, so
    // a copy-pasted id has to work either way.
    XCTAssertEqual(messageIDCandidates("x@y"), ["<x@y>", "x@y"])
    XCTAssertEqual(messageIDCandidates("<x@y>"), ["<x@y>", "x@y"])
    XCTAssertEqual(messageIDCandidates("  x@y  "), ["<x@y>", "x@y"])
  }

  func testStrippingAngleBrackets() {
    XCTAssertEqual(strippingAngleBrackets("<x@y>"), "x@y")
    XCTAssertEqual(strippingAngleBrackets("x@y"), "x@y")
    XCTAssertEqual(strippingAngleBrackets(""), "")
  }
}
