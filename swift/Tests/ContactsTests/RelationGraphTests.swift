import XCTest

@testable import ContactsLibrary

/// 🛑 **Every entry in the inverse table is a claim written onto somebody
/// else's card.** `link A B --relation spouse` also edits B. A wrong rule states
/// a wrong fact about a real person, and nobody notices for months.
///
/// So the table is small on purpose, and these tests pin what it must NOT do as
/// hard as what it must.
final class RelationInverseTests: XCTestCase {

    // MARK: What may be inferred

    func testSymmetricRelationsInvertToThemselves() {
        for label in ["spouse", "husband", "wife", "partner", "friend",
                      "colleague", "cousin", "sibling"] {
            XCTAssertEqual(RelationGraph.inverse(of: label), label,
                           "\(label) should be symmetric")
        }
    }

    func testGenderNeutralPairsInvert() {
        XCTAssertEqual(RelationGraph.inverse(of: "parent"), "child")
        XCTAssertEqual(RelationGraph.inverse(of: "child"), "parent")
        XCTAssertEqual(RelationGraph.inverse(of: "grandparent"), "grandchild")
        XCTAssertEqual(RelationGraph.inverse(of: "grandchild"), "grandparent")
        XCTAssertEqual(RelationGraph.inverse(of: "manager"), "assistant")
        XCTAssertEqual(RelationGraph.inverse(of: "assistant"), "manager")
    }

    func testEveryInverseIsItselfInvertible() {
        // A rule that does not round-trip is a rule that would write one card
        // and then refuse to undo it.
        for (label, _) in RelationGraph.rules {
            guard let other = RelationGraph.inverse(of: label) else { continue }
            XCTAssertNotNil(
                RelationGraph.inverse(of: other),
                "\(label) inverts to \(other), which has no rule of its own")
        }
    }

    // MARK: What must NOT be inferred

    /// 🛑 The inverse of "my father" is "my son" or "my daughter", and Contacts
    /// records no gender. Guessing writes a wrong fact.
    func testGenderedRelationsAreRefused() {
        for label in ["father", "mother", "son", "daughter", "brother", "sister"] {
            XCTAssertNil(RelationGraph.inverse(of: label),
                         "\(label) must not be inverted automatically")
            XCTAssertTrue(
                RelationGraph.ambiguityReason(for: label).contains("gender"),
                "the refusal for \(label) must say why")
        }
    }

    func testAnUnknownLabelIsRefusedWithoutClaimingGender() {
        XCTAssertNil(RelationGraph.inverse(of: "landlord"))
        let reason = RelationGraph.ambiguityReason(for: "landlord")
        XCTAssertTrue(reason.contains("landlord"))
        XCTAssertFalse(reason.contains("gender"),
                       "an unknown label is not a gender problem")
    }

    /// A refusal the user cannot act on is a dead end, so a gendered label must
    /// come with something to type.
    func testGenderedRefusalsSuggestSomething() {
        XCTAssertEqual(RelationGraph.inverseSuggestions(for: "father"),
                       ["son", "daughter", "child"])
        XCTAssertEqual(RelationGraph.inverseSuggestions(for: "daughter"),
                       ["father", "mother", "parent"])
        XCTAssertEqual(RelationGraph.inverseSuggestions(for: "sister"),
                       ["brother", "sister", "sibling"])
        XCTAssertTrue(RelationGraph.inverseSuggestions(for: "landlord").isEmpty)
    }

    // MARK: Matching

    /// ⚠️ Matching ignores case, spaces and hyphens, matching `Labels.relation`.
    /// A user typing `Spouse` or `grand-parent` must not fall through to a
    /// refusal.
    func testMatchingIgnoresCaseAndPunctuation() {
        XCTAssertEqual(RelationGraph.inverse(of: "SPOUSE"), "spouse")
        XCTAssertEqual(RelationGraph.inverse(of: "Grand-Parent"), "grandchild")
        XCTAssertEqual(RelationGraph.inverse(of: "grand parent"), "grandchild")
        XCTAssertEqual(RelationGraph.normalize("younger-sister"),
                       RelationGraph.normalize("youngerSister"))
    }

    /// 🛑 A relation is stored in two spellings on one real machine —
    /// `_$!<Father>!$_` on one card and a plain `Sibling` on another. Anything
    /// comparing labels has to normalise, or it misses real matches. That bug
    /// made `link` report "would add" for a relation the contact already had,
    /// and a second run would have written a duplicate.
    func testNormalizeCollapsesTheSpellingsThatActuallyOccur() {
        XCTAssertEqual(RelationGraph.normalize("Father"), "father")
        XCTAssertEqual(RelationGraph.normalize("father"), "father")
        XCTAssertEqual(RelationGraph.normalize("Grand Parent"),
                       RelationGraph.normalize("grandparent"))
    }
}
