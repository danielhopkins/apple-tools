import XCTest

@testable import MailLibrary

/// Attachment filenames come from whoever sent the mail, and `--save` joins
/// them onto a directory the user named. That makes them hostile input, so the
/// sanitising is tested harder than the parsing.
final class AttachmentTests: XCTestCase {

  // MARK: Filename safety

  func testStripsPathTraversal() {
    XCTAssertEqual(safeFilename("../../../etc/passwd", fallback: "x"), "passwd")
    XCTAssertEqual(safeFilename("/etc/passwd", fallback: "x"), "passwd")
    XCTAssertEqual(safeFilename("a/b/c/report.pdf", fallback: "x"), "report.pdf")
  }

  func testStripsWindowsAndClassicMacSeparators() {
    // A Windows sender may quote a full path, and ':' was the separator on
    // HFS+ — still special enough to be worth removing.
    XCTAssertEqual(safeFilename(#"C:\Windows\System32\evil.exe"#, fallback: "x"), "evil.exe")
    XCTAssertEqual(safeFilename("Macintosh HD:notes.txt", fallback: "x"), "notes.txt")
  }

  func testRefusesNamesThatAreOnlyDots() {
    XCTAssertEqual(safeFilename("..", fallback: "fallback"), "fallback")
    XCTAssertEqual(safeFilename(".", fallback: "fallback"), "fallback")
    XCTAssertEqual(safeFilename("", fallback: "fallback"), "fallback")
    XCTAssertEqual(safeFilename("   ", fallback: "fallback"), "fallback")
  }

  func testKeepsLegitimateNamesContainingDots() {
    // "3360 Mitchell Ln..pdf" is a real filename in this mail store. Treating
    // "contains .." as traversal would mangle it, so the check is on the whole
    // name being dots, not on the substring appearing.
    XCTAssertEqual(
      safeFilename("3360 Mitchell Ln..pdf", fallback: "x"), "3360 Mitchell Ln..pdf")
    XCTAssertEqual(safeFilename("report.final.v2.pdf", fallback: "x"), "report.final.v2.pdf")
  }

  func testStripsLeadingDotsSoTheFileIsNotHidden() {
    XCTAssertEqual(safeFilename(".bashrc", fallback: "x"), "bashrc")
    XCTAssertEqual(safeFilename("...hidden.txt", fallback: "x"), "hidden.txt")
  }

  func testStripsNullBytes() {
    XCTAssertEqual(safeFilename("report\0.pdf", fallback: "x"), "report.pdf")
  }

  func testTruncatesOverlongNamesKeepingTheExtension() {
    let long = String(repeating: "a", count: 400) + ".pdf"
    let safe = safeFilename(long, fallback: "x")
    XCTAssertLessThanOrEqual(safe.utf8.count, 200)
    XCTAssertTrue(safe.hasSuffix(".pdf"), "the extension is what makes the file openable")
  }

  func testKeepsUnicodeAndSpaces() {
    XCTAssertEqual(safeFilename("naïve café.pdf", fallback: "x"), "naïve café.pdf")
  }

  // MARK: RFC 2231

  func testDecodesRFC2231WithCharset() {
    XCTAssertEqual(decodeRFC2231("UTF-8''Invoice%20March.pdf"), "Invoice March.pdf")
  }

  func testDecodesRFC2231NonASCII() {
    XCTAssertEqual(decodeRFC2231("UTF-8''caf%C3%A9.pdf"), "café.pdf")
  }

  func testDecodesRFC2231WithLanguageTag() {
    XCTAssertEqual(decodeRFC2231("UTF-8'en'report%20v2.pdf"), "report v2.pdf")
  }

  func testDecodesRFC2231WithoutCharsetPrefix() {
    XCTAssertEqual(decodeRFC2231("plain%20name.pdf"), "plain name.pdf")
  }

  // MARK: Filename resolution

  func testPrefersContentDispositionFilename() {
    XCTAssertEqual(
      attachmentFilename(
        disposition: #"attachment; filename="from-disposition.pdf""#,
        contentType: #"application/pdf; name="from-content-type.pdf""#),
      "from-disposition.pdf")
  }

  func testFallsBackToContentTypeName() {
    XCTAssertEqual(
      attachmentFilename(
        disposition: "attachment", contentType: #"application/pdf; name="fallback.pdf""#),
      "fallback.pdf")
  }

  func testAcceptsUnquotedFilename() {
    // Real mail in this store sends `filename=Invoice_x.pdf` with no quotes.
    XCTAssertEqual(
      attachmentFilename(disposition: "ATTACHMENT; filename=Invoice_x.pdf", contentType: ""),
      "Invoice_x.pdf")
  }

  func testDecodesEncodedWordFilename() {
    XCTAssertEqual(
      attachmentFilename(
        disposition: "attachment; filename==?UTF-8?B?Y2Fmw6kucGRm?=", contentType: ""),
      "café.pdf")
  }

  func testPrefersExtendedParameterOverPlain() {
    // When a sender supplies both, the RFC 2231 one is the accurate one.
    XCTAssertEqual(
      attachmentFilename(
        disposition: #"attachment; filename="cafe.pdf"; filename*=UTF-8''caf%C3%A9.pdf"#,
        contentType: ""),
      "café.pdf")
  }

  func testNoFilenameMeansNotAnAttachment() {
    // Mail's own rule, verified against its index: a nameless inline part
    // (a tracking pixel) is not an attachment.
    XCTAssertNil(attachmentFilename(disposition: "inline", contentType: "image/gif"))
  }

  // MARK: End to end over MIME

  func testExtractsAndDecodesAnAttachment() {
    let body = """
      Content-Type: multipart/mixed; boundary="M"

      --M
      Content-Type: text/plain

      see attached
      --M
      Content-Type: application/pdf; name="doc.pdf"
      Content-Disposition: attachment; filename="doc.pdf"
      Content-Transfer-Encoding: base64

      cXVhcnRlcmx5IHJlcG9ydA==
      --M--
      """
    let found = attachments(inRFC822: Data(body.utf8))
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.name, "doc.pdf")
    XCTAssertEqual(found.first.map { String(decoding: $0.data, as: UTF8.self) }, "quarterly report")
    XCTAssertEqual(found.first?.isInline, false)
  }

  func testMarksContentIDPartsInline() {
    let body = """
      Content-Type: multipart/related; boundary="M"

      --M
      Content-Type: image/png; name="logo.png"
      Content-ID: <logo@example.com>
      Content-Transfer-Encoding: base64

      aGVsbG8=
      --M--
      """
    let found = attachments(inRFC822: Data(body.utf8))
    XCTAssertEqual(found.first?.isInline, true)
  }

  func testDisambiguatesDuplicateNames() {
    let body = """
      Content-Type: multipart/mixed; boundary="M"

      --M
      Content-Type: text/plain; name="notes.txt"
      Content-Disposition: attachment; filename="notes.txt"

      first
      --M
      Content-Type: text/plain; name="notes.txt"
      Content-Disposition: attachment; filename="notes.txt"

      second
      --M--
      """
    let found = attachments(inRFC822: Data(body.utf8))
    XCTAssertEqual(found.map(\.name), ["notes.txt", "notes-2.txt"])
  }

  func testIgnoresNamelessParts() {
    let body = """
      Content-Type: multipart/related; boundary="M"

      --M
      Content-Type: text/html

      <p>hi</p>
      --M
      Content-Type: image/gif
      Content-ID: <pixel@tracker>
      Content-Transfer-Encoding: base64

      R0lGOD==
      --M--
      """
    XCTAssertTrue(attachments(inRFC822: Data(body.utf8)).isEmpty)
  }
}
