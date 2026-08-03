import XCTest

@testable import MailLibrary

/// The AppleScript search is the last place a value is interpolated into a
/// script rather than passed as `argv`, so this escaping is the only thing
/// between a search term and the parser.
///
/// Half of these pin what is escaped; the other half pin what is deliberately
/// *not*, because the failure mode there is a silently altered query rather
/// than a visible syntax error. See the doc comment on
/// `escapedForAppleScriptLiteral` for the measurements behind the split.
final class AppleScriptLiteralTests: XCTestCase {
  func testLeavesOrdinaryTextAlone() {
    XCTAssertEqual(escapedForAppleScriptLiteral("budget review"), "budget review")
    XCTAssertEqual(escapedForAppleScriptLiteral("Grüße 🦅"), "Grüße 🦅")
  }

  func testEscapesQuotes() {
    XCTAssertEqual(escapedForAppleScriptLiteral("say \"hi\""), "say \\\"hi\\\"")
  }

  /// The regression this file exists for. The old escaping handled `"` and not
  /// `\`, so `search 'back\slash' --engine applescript` died with -2741.
  func testEscapesBackslashes() {
    XCTAssertEqual(escapedForAppleScriptLiteral("back\\slash"), "back\\\\slash")
    XCTAssertEqual(escapedForAppleScriptLiteral("trailing\\"), "trailing\\\\")
  }

  /// Backslash has to be escaped before quote, or the backslash the quote pass
  /// introduces is escaped in turn and the literal ends early.
  func testBackslashIsEscapedBeforeQuote() {
    XCTAssertEqual(escapedForAppleScriptLiteral("\\\""), "\\\\\\\"")
  }

  /// `osascript -e` accepts all of these inside a literal, so escaping them
  /// would change the search term without fixing anything. U+2028 rewritten to
  /// `\n` is character id 10 where the user typed 8232.
  func testLeavesWhitespaceAndUnicodeSeparatorsVerbatim() {
    for raw in ["a\nb", "a\r\nb", "a\tb", "a\u{2028}b", "a\u{2029}b"] {
      XCTAssertEqual(
        escapedForAppleScriptLiteral(raw), raw,
        "escaping this would silently alter the query; it is legal in a literal")
    }
  }

  /// Structural rather than by example, so an escape that forgets a case fails
  /// here: nothing an escaped literal contains may terminate it.
  func testResultNeverContainsAnUnescapedQuote() {
    let nasty = "he said \"x\" \\ then\u{2028}\r\n\tdone"
    let escaped = escapedForAppleScriptLiteral(nasty)
    var index = escaped.startIndex
    while index < escaped.endIndex {
      if escaped[index] == "\\" {
        // Skip the escaped character, whatever it is.
        index = escaped.index(index, offsetBy: 2, limitedBy: escaped.endIndex) ?? escaped.endIndex
        continue
      }
      XCTAssertNotEqual(escaped[index], "\"", "unescaped quote in \(escaped)")
      index = escaped.index(after: index)
    }
  }
}
