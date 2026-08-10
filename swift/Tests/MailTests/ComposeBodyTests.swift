import XCTest

@testable import MailLibrary

/// The body conversion behind `compose`/`reply`/`forward`.
///
/// These pin the two decisions the whole compose design rests on: that what
/// reaches the pasteboard is **RTF** (HTML there makes Mail insert the body
/// twice), and that a `--body` is taken literally while `--markdown` is not.
/// Everything here is offline — no Mail, no pasteboard.
final class ComposeBodyTests: XCTestCase {

  // MARK: What lands on the pasteboard

  func testProducesRealRTF() throws {
    let data = try ComposeBody.rtf(from: "hello", format: .plain)
    let head = String(decoding: data.prefix(6), as: UTF8.self)
    XCTAssertEqual(head, "{\\rtf1", "not an RTF document: \(head)")
  }

  func testPlainBodySurvivesIntoTheRTF() throws {
    let data = try ComposeBody.rtf(from: "PROBE-12345 the body", format: .plain)
    let rtf = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(rtf.contains("PROBE-12345"), "the body is not in the RTF")
  }

  /// The reason `--body` is not Markdown by default: prose containing an
  /// asterisk or underscore must arrive as written, not silently restyled.
  func testPlainBodyDoesNotInterpretMarkdown() throws {
    let source = "costs *rose* 10_000 units"
    let attributed = try ComposeBody.attributedString(from: source, format: .plain)
    XCTAssertEqual(attributed.string, source, "a plain body was interpreted as Markdown")
  }

  // MARK: Markdown

  func testMarkdownDropsTheMarkersFromTheText() throws {
    let attributed = try ComposeBody.attributedString(from: "a **bold** word", format: .markdown)
    XCTAssertEqual(attributed.string, "a bold word")
  }

  /// 🛑 Asserted on the **font**, not on the RTF text. Markdown emphasis arrives
  /// as `inlinePresentationIntent`, which is semantic and has no RTF
  /// representation — so a body can convert with the intent intact and no bold
  /// in it. Grepping the RTF for `\\b` also matches `\\brdr…` and other control
  /// words, so it passes whether or not the bold is really there.
  func testMarkdownBoldBecomesAnActualBoldFont() throws {
    let attributed = try ComposeBody.attributedString(from: "a **bold** word", format: .markdown)
    let boldRange = (attributed.string as NSString).range(of: "bold")
    let font = attributed.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
    let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
    XCTAssertTrue(
      traits.contains(.boldFontMask), "bold is not a bold font: \(font?.fontName ?? "none")")
  }

  func testMarkdownItalicBecomesAnActualItalicFont() throws {
    let attributed = try ComposeBody.attributedString(from: "an *italic* word", format: .markdown)
    let range = (attributed.string as NSString).range(of: "italic")
    let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
    XCTAssertTrue(
      traits.contains(.italicFontMask), "italic is not italic: \(font?.fontName ?? "none")")
  }

  func testUnemphasisedTextKeepsTheBodyFont() throws {
    let attributed = try ComposeBody.attributedString(from: "a **bold** word", format: .markdown)
    let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
    XCTAssertFalse(traits.contains(.boldFontMask), "emphasis leaked onto the surrounding text")
  }

  func testMarkdownLinksSurvive() throws {
    let attributed = try ComposeBody.attributedString(
      from: "see [the docs](https://example.com/x)", format: .markdown)
    let range = (attributed.string as NSString).range(of: "the docs")
    let link = attributed.attribute(.link, at: range.location, effectiveRange: nil)
    XCTAssertNotNil(link, "the link was dropped")
    XCTAssertTrue("\(link ?? "")".contains("example.com"))
  }

  func testUnorderedListGetsRealBullets() throws {
    let attributed = try ComposeBody.attributedString(from: "- one\n- two", format: .markdown)
    XCTAssertTrue(attributed.string.contains("•"), "no bullet: \(attributed.string.debugDescription)")
    XCTAssertTrue(
      attributed.string.contains("\n"), "list items ran together: \(attributed.string.debugDescription)")
  }

  func testOrderedListKeepsItsNumbers() throws {
    let attributed = try ComposeBody.attributedString(from: "1. first\n2. second", format: .markdown)
    XCTAssertTrue(attributed.string.contains("1."), attributed.string.debugDescription)
    XCTAssertTrue(attributed.string.contains("2."), attributed.string.debugDescription)
  }

  /// 🛑 The default `.inlineOnly` parsing collapses every paragraph onto one
  /// line, which reads as the tool having eaten the formatting. `.full` is
  /// load-bearing.
  func testMarkdownKeepsParagraphBreaks() throws {
    let attributed = try ComposeBody.attributedString(
      from: "first para\n\nsecond para", format: .markdown)
    XCTAssertTrue(
      attributed.string.contains("\n"),
      "paragraphs were collapsed onto one line: \(attributed.string.debugDescription)")
  }

  func testMarkdownListBecomesText() throws {
    let attributed = try ComposeBody.attributedString(
      from: "- one\n- two", format: .markdown)
    XCTAssertTrue(attributed.string.contains("one"))
    XCTAssertTrue(attributed.string.contains("two"))
    XCTAssertFalse(attributed.string.contains("- one"), "the list marker was left in the text")
  }

  // MARK: HTML in, RTF out

  func testHTMLIsConvertedRatherThanPassedThrough() throws {
    let data = try ComposeBody.rtf(from: "<p>hello <b>there</b></p>", format: .html)
    let rtf = String(decoding: data, as: UTF8.self)
    XCTAssertEqual(String(decoding: data.prefix(6), as: UTF8.self), "{\\rtf1")
    XCTAssertTrue(rtf.contains("hello"))
    // The point of converting: no HTML tags reach the pasteboard, because HTML
    // on the pasteboard is what makes Mail insert the body twice.
    XCTAssertFalse(rtf.contains("<p>"), "raw HTML leaked onto the pasteboard")
    XCTAssertFalse(rtf.contains("<b>"), "raw HTML leaked onto the pasteboard")
  }

  func testHTMLEntitiesAreDecoded() throws {
    let attributed = try ComposeBody.attributedString(
      from: "<p>Tom &amp; Jerry</p>", format: .html)
    XCTAssertTrue(attributed.string.contains("Tom & Jerry"))
  }

  // MARK: Unicode and edge cases

  func testUnicodeSurvives() throws {
    let data = try ComposeBody.rtf(from: "café — naïve 🎉", format: .plain)
    let attributed = try ComposeBody.attributedString(from: "café — naïve 🎉", format: .plain)
    XCTAssertEqual(attributed.string, "café — naïve 🎉")
    XCTAssertFalse(data.isEmpty)
  }

  func testEmptyBodyStillConverts() throws {
    // An empty body is the caller's business to reject; the converter must not
    // crash on one.
    let data = try ComposeBody.rtf(from: "", format: .plain)
    XCTAssertFalse(data.isEmpty, "an empty body produced no RTF document at all")
  }

  func testMultilinePlainBodyKeepsItsLineBreaks() throws {
    let attributed = try ComposeBody.attributedString(
      from: "line one\nline two", format: .plain)
    XCTAssertEqual(attributed.string, "line one\nline two")
  }

  func testEveryFormatIsCovered() {
    // A new case must get a conversion path and a test, rather than silently
    // falling through to plain.
    XCTAssertEqual(ComposeBody.Format.allCases.count, 3)
  }
}
