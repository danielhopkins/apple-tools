import XCTest

@testable import AppleToolsSearch

/// Query parsing. The bug being pinned here is a silent one: before this,
/// `budget review` was a single substring and matched 0 messages on a store
/// where 1082 mentioned "budget" and a third of those also said "review".
final class SearchTermsTests: XCTestCase {

  func testSplitsOnWhitespace() {
    XCTAssertEqual(parseSearchTerms("budget review"), ["budget", "review"])
  }

  func testSingleWordIsOneTerm() {
    XCTAssertEqual(parseSearchTerms("invoice"), ["invoice"])
  }

  func testCollapsesRepeatedAndSurroundingWhitespace() {
    XCTAssertEqual(parseSearchTerms("  budget \t review \n"), ["budget", "review"])
  }

  func testEmptyQueryHasNoTerms() {
    // No terms means "no text predicate" — a plain listing, not a match-all
    // that then filters everything out.
    XCTAssertEqual(parseSearchTerms(""), [])
    XCTAssertEqual(parseSearchTerms("   "), [])
  }

  func testQuotesGroupAPhrase() {
    XCTAssertEqual(parseSearchTerms("\"budget review\""), ["budget review"])
  }

  func testMixesPhrasesAndBareWords() {
    XCTAssertEqual(
      parseSearchTerms("\"Q3 budget\" review draft"), ["Q3 budget", "review", "draft"])
  }

  func testUnterminatedQuoteTakesTheRestAsAPhrase() {
    // A stray quote is a typo. Failing the search outright would be worse than
    // interpreting it.
    XCTAssertEqual(parseSearchTerms("\"budget review"), ["budget review"])
  }

  func testEmptyQuotesProduceNoTerm() {
    // "" must not become a term: an empty needle matches every message.
    XCTAssertEqual(parseSearchTerms("\"\""), [])
    XCTAssertEqual(parseSearchTerms("invoice \"\""), ["invoice"])
  }

  func testAdjacentQuotedAndBareText() {
    XCTAssertEqual(parseSearchTerms("a \"b c\" d"), ["a", "b c", "d"])
  }

  // MARK: Matching

  func testRequiresEveryTerm() {
    let haystack = "The quarterly budget is attached for review."
    XCTAssertTrue(containsAllTerms(haystack, ["budget", "review"]))
    XCTAssertTrue(containsAllTerms(haystack, ["review", "budget"]))  // order-independent
    XCTAssertFalse(containsAllTerms(haystack, ["budget", "missing"]))
  }

  func testMatchingIsCaseInsensitiveOnTheHaystackSide() {
    // Terms arrive already lowercased; the haystack is lowercased here.
    XCTAssertTrue(containsAllTerms("BUDGET Review", ["budget", "review"]))
  }

  func testPhraseRequiresAdjacency() {
    XCTAssertTrue(containsAllTerms("the budget review is late", ["budget review"]))
    XCTAssertFalse(containsAllTerms("the budget is up for review", ["budget review"]))
  }

  func testNoTermsMatchesAnything() {
    XCTAssertTrue(containsAllTerms("whatever", []))
  }

  func testTermsCanMatchInsideWords() {
    // Substring, not token, matching — documented behaviour rather than an
    // accident, so it gets a test.
    XCTAssertTrue(containsAllTerms("headquarters", ["quarter"]))
  }
}
