import XCTest

@testable import MailLibrary

/// The .emlx container and MIME decoding. Everything here is a shape that
/// actually turned up in the store — the byte-counted trailer, quoted-printable
/// soft breaks, base64 bodies, RFC 2047 subjects — because those are what a
/// naive parser gets wrong.
final class EmlxTests: XCTestCase {

  // MARK: Container

  func testPayloadUsesByteCountNotEndOfFile() throws {
    // An .emlx is <count>\n<message><plist>. Reading to EOF glues Mail's own
    // plist onto the end of the body.
    let message = "Subject: Hi\n\nBody text"
    let file = Data("\(message.utf8.count)\n\(message)<?xml version=\"1.0\"?><plist/>".utf8)
    XCTAssertEqual(String(decoding: try emlxPayload(file), as: UTF8.self), message)
  }

  func testPayloadRejectsMissingByteCount() {
    XCTAssertThrowsError(try emlxPayload(Data("no newline here".utf8)))
  }

  func testPayloadToleratesShortFile() throws {
    // A truncated .partial.emlx claims more bytes than it has; clamping beats
    // throwing, because a partial body is still worth reading.
    let file = Data("9999\nSubject: X\n\nshort".utf8)
    XCTAssertTrue(String(decoding: try emlxPayload(file), as: UTF8.self).contains("short"))
  }

  // MARK: Headers

  func testUnfoldsContinuationLines() {
    let message = parseRFC822(Data("Subject: one\n  two\n\tthree\nFrom: a@b.c\n\nbody".utf8))
    XCTAssertEqual(message.headers.first("Subject"), "one two three")
    XCTAssertEqual(message.headers.first("From"), "a@b.c")
  }

  func testHeaderLookupIsCaseInsensitive() {
    let message = parseRFC822(Data("MESSAGE-ID: <x@y>\n\nbody".utf8))
    XCTAssertEqual(message.headers.first("message-id"), "<x@y>")
  }

  func testSplitsOnCRLFBlankLine() {
    let message = parseRFC822(Data("Subject: X\r\n\r\nbody here".utf8))
    XCTAssertEqual(message.headers.first("Subject"), "X")
    XCTAssertEqual(message.text, "body here")
  }

  // MARK: RFC 2047

  func testDecodesBase64EncodedWord() {
    XCTAssertEqual(decodeEncodedWords("=?UTF-8?B?SGVsbG8gd29ybGQ=?="), "Hello world")
  }

  func testDecodesQuotedPrintableEncodedWordWithUnderscore() {
    // In an encoded word '_' is a space, which plain quoted-printable does not do.
    XCTAssertEqual(decodeEncodedWords("=?UTF-8?Q?Your_receipt?="), "Your receipt")
  }

  func testDecodesEncodedWordAmongPlainText() {
    XCTAssertEqual(
      decodeEncodedWords("Re: =?UTF-8?B?w7xiZXI=?= now"), "Re: über now")
  }

  func testLeavesUnparseableEncodedWordAlone() {
    XCTAssertEqual(decodeEncodedWords("=?UTF-8?B?truncated"), "=?UTF-8?B?truncated")
  }

  func testPassesThroughTextWithoutEncodedWords() {
    XCTAssertEqual(decodeEncodedWords("Plain subject"), "Plain subject")
  }

  // MARK: Transfer encodings

  func testQuotedPrintableDecodesHexAndSoftBreaks() {
    let input = Data("caf=C3=A9 and a soft=\nbreak".utf8)
    XCTAssertEqual(String(decoding: decodeQuotedPrintable(input), as: UTF8.self), "café and a softbreak")
  }

  func testQuotedPrintableHandlesCRLFSoftBreak() {
    let input = Data("one=\r\ntwo".utf8)
    XCTAssertEqual(String(decoding: decodeQuotedPrintable(input), as: UTF8.self), "onetwo")
  }

  func testQuotedPrintableKeepsStrayEquals() {
    let input = Data("100% = done".utf8)
    XCTAssertEqual(String(decoding: decodeQuotedPrintable(input), as: UTF8.self), "100% = done")
  }

  func testBase64BodyIsDecoded() {
    let encoded = Data("SGVsbG8gYm9keQ==".utf8)
    XCTAssertEqual(
      String(decoding: decodeTransferEncoding(encoded, encoding: "base64"), as: UTF8.self),
      "Hello body")
  }

  func testUnknownTransferEncodingIsLeftAlone() {
    let raw = Data("as-is".utf8)
    XCTAssertEqual(decodeTransferEncoding(raw, encoding: "7bit"), raw)
  }

  // MARK: MIME structure

  func testPrefersPlainTextOverHTMLInAlternative() {
    let body = """
      Content-Type: multipart/alternative; boundary="B"

      --B
      Content-Type: text/plain; charset=utf-8

      the plain version
      --B
      Content-Type: text/html; charset=utf-8

      <p>the html version</p>
      --B--
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "the plain version")
  }

  func testFallsBackToHTMLWhenThePlainPartIsPresentButEmpty() {
    // Mail writes exactly this for every draft it composes, and 2.2% of a real
    // 40k-message store looks the same. An emptiness check on the *array* of
    // parts sees one element and prefers it, losing the entire body — the
    // message then exports blank and no content search can ever match it.
    let body = """
      Content-Type: multipart/alternative; boundary="B"

      --B
      Content-Transfer-Encoding: 7bit
      Content-Type: text/plain; charset=utf-8


      --B
      Content-Type: text/html; charset=utf-8

      <p>the real body</p>
      --B--
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "the real body")
  }

  func testPrefersPlainWhenItActuallyHasText() {
    let body = """
      Content-Type: multipart/alternative; boundary="B"

      --B
      Content-Type: text/plain; charset=utf-8

      plain wins
      --B
      Content-Type: text/html; charset=utf-8

      <p>html loses</p>
      --B--
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "plain wins")
  }

  func testFallsBackToStrippedHTMLWhenThereIsNoPlainPart() {
    let body = """
      Content-Type: text/html; charset=utf-8

      <html><body><p>Hello <b>there</b></p></body></html>
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "Hello there")
  }

  func testNonTextPartsAreNeverDecoded() {
    // A PDF's bytes are not body text under any circumstance. This is the
    // guard that makes "attachment contents are never searched" true even for
    // a part with no Content-Disposition at all.
    let body = """
      Content-Type: multipart/mixed; boundary="M"

      --M
      Content-Type: text/plain

      real body
      --M
      Content-Type: application/pdf; name="secret.pdf"
      Content-Transfer-Encoding: base64

      cXVhcnRlcmx5IHJlcG9ydA==
      --M--
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "real body")
    XCTAssertFalse(message.text.contains("quarterly"))
  }

  func testSkipsAttachmentParts() {
    // A text/plain attachment is a file, not the message body; including it
    // makes searches match on attached content and reads as body text.
    let body = """
      Content-Type: multipart/mixed; boundary="M"

      --M
      Content-Type: text/plain

      real body
      --M
      Content-Type: text/plain; name="notes.txt"
      Content-Disposition: attachment; filename="notes.txt"

      attached file contents
      --M--
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "real body")
    XCTAssertFalse(message.text.contains("attached file contents"))
  }

  func testDecodesBase64PartInsideMultipart() {
    let body = """
      Content-Type: multipart/mixed; boundary="M"

      --M
      Content-Type: text/plain; charset=utf-8
      Content-Transfer-Encoding: base64

      cXVhcnRlcmx5IHJlcG9ydA==
      --M--
      """
    let message = parseRFC822(Data(body.utf8))
    // This is the case a raw grep over the .emlx corpus cannot find.
    XCTAssertEqual(message.text, "quarterly report")
  }

  func testHandlesNestedMultipart() {
    let body = """
      Content-Type: multipart/mixed; boundary="OUT"

      --OUT
      Content-Type: multipart/alternative; boundary="IN"

      --IN
      Content-Type: text/plain

      nested body
      --IN--
      --OUT--
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "nested body")
  }

  func testBoundaryInsideBodyTextIsNotATerminator() {
    // Only a boundary at the start of a line delimits a part.
    let body = """
      Content-Type: multipart/mixed; boundary="X"

      --X
      Content-Type: text/plain

      talking about --X in prose
      --X--
      """
    let message = parseRFC822(Data(body.utf8))
    XCTAssertEqual(message.text, "talking about --X in prose")
  }

  func testMalformedMultipartWithoutBoundaryParameterDoesNotCrash() {
    let message = parseRFC822(Data("Content-Type: multipart/mixed\n\nstuff".utf8))
    XCTAssertEqual(message.text, "")
  }

  // MARK: Charsets

  func testDecodesLatin1Body() {
    var bytes = Data("caf".utf8)
    bytes.append(0xE9)  // é in ISO-8859-1
    XCTAssertEqual(decodeBytes(bytes, charset: "iso-8859-1"), "café")
  }

  func testUnknownCharsetStillProducesText() {
    XCTAssertEqual(decodeBytes(Data("plain".utf8), charset: "x-not-a-charset"), "plain")
  }

  // MARK: HTML

  func testStripsScriptAndStyleContent() {
    let html = "<style>p{color:red}</style><script>alert(1)</script><p>visible</p>"
    XCTAssertEqual(strippingHTML(html), "visible")
  }

  func testDecodesCommonEntities() {
    XCTAssertEqual(strippingHTML("<p>a &amp; b &nbsp;c</p>"), "a & b  c")
  }
}
