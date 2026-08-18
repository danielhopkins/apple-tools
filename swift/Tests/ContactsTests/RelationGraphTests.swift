import XCTest

@testable import ContactsLibrary

/// 🛑 **Every entry in the inverse table is a claim written onto somebody
/// else's card.** `link A B --relation spouse` also edits B. A wrong rule states
/// a wrong fact about a real person, and nobody notices for months.
///
/// So the table is small on purpose, and these tests pin what it must NOT do as
/// hard as what it must.
final class RelationInverseTests: XCTestCase {

    // MARK: Symmetric

    func testSymmetricRelationsInvertToThemselves() {
        for label in ["spouse", "partner", "friend", "colleague", "cousin", "sibling"] {
            XCTAssertEqual(RelationGraph.inverse(of: label), label,
                           "\(label) should be symmetric")
        }
    }

    /// 🛑 **`husband` and `wife` are NOT symmetric.** If B is A's husband, A is
    /// B's wife *or* husband, and only `spouse` covers both. An earlier version
    /// had them symmetric, which would have written "husband" onto a wife's card.
    func testHusbandAndWifeInvertToSpouseNotThemselves() {
        XCTAssertEqual(RelationGraph.inverse(of: "husband"), "spouse")
        XCTAssertEqual(RelationGraph.inverse(of: "wife"), "spouse")
    }

    // MARK: Gendered labels invert to the neutral term

    /// 🛑 **The bug this class exists for.** An earlier version refused `father`
    /// outright, reasoning that the other side is "son or daughter" and Contacts
    /// records no gender. That was wrong. `child` is exactly the term for "son
    /// or daughter", the SDK defines it, and writing it states nothing untrue.
    func testGenderedLabelsInvertToTheNeutralTerm() {
        XCTAssertEqual(RelationGraph.inverse(of: "father"), "child")
        XCTAssertEqual(RelationGraph.inverse(of: "mother"), "child")
        XCTAssertEqual(RelationGraph.inverse(of: "son"), "parent")
        XCTAssertEqual(RelationGraph.inverse(of: "daughter"), "parent")
        XCTAssertEqual(RelationGraph.inverse(of: "brother"), "sibling")
        XCTAssertEqual(RelationGraph.inverse(of: "sister"), "sibling")
        XCTAssertEqual(RelationGraph.inverse(of: "grandfather"), "grandchild")
        XCTAssertEqual(RelationGraph.inverse(of: "grandmother"), "grandchild")
        XCTAssertEqual(RelationGraph.inverse(of: "grandson"), "grandparent")
        XCTAssertEqual(RelationGraph.inverse(of: "granddaughter"), "grandparent")
    }

    func testGenderNeutralPairsInvert() {
        XCTAssertEqual(RelationGraph.inverse(of: "parent"), "child")
        XCTAssertEqual(RelationGraph.inverse(of: "child"), "parent")
        XCTAssertEqual(RelationGraph.inverse(of: "grandparent"), "grandchild")
        XCTAssertEqual(RelationGraph.inverse(of: "grandchild"), "grandparent")
        XCTAssertEqual(RelationGraph.inverse(of: "manager"), "assistant")
        XCTAssertEqual(RelationGraph.inverse(of: "assistant"), "manager")
    }

    /// ⚠️ **The inverse generalises; it does not round-trip.** `father` gives
    /// `child`, and `child` gives `parent` — not back to `father`. That is
    /// correct: the child's card never recorded the parent's gender.
    func testTheInverseGeneralisesRatherThanRoundTripping() {
        let child = try? XCTUnwrap(RelationGraph.inverse(of: "father"))
        XCTAssertEqual(child, "child")
        XCTAssertEqual(RelationGraph.inverse(of: "child"), "parent")
        XCTAssertNotEqual(RelationGraph.inverse(of: "child"), "father")
    }

    /// Every label that inverts must invert to one that has a rule of its own,
    /// or `unlink` could write a link it cannot later match.
    func testEveryInverseHasARuleOfItsOwn() {
        for (label, _) in RelationGraph.rules {
            guard let other = RelationGraph.inverse(of: label) else { continue }
            XCTAssertNotNil(
                RelationGraph.inverse(of: other),
                "\(label) inverts to \(other), which has no rule of its own")
        }
    }

    // MARK: What genuinely cannot be inferred

    /// ⚠️ The SDK has `Nephew` and `Niece` and no neutral term for either, so
    /// nothing can be written without inventing a gender. This is the only
    /// family relation left that really is ambiguous.
    func testUncleAndAuntAreRefusedBecauseNoNeutralTermExists() {
        for label in ["uncle", "aunt", "nephew", "niece"] {
            XCTAssertNil(RelationGraph.inverse(of: label),
                         "\(label) must not be inverted automatically")
            XCTAssertTrue(
                RelationGraph.ambiguityReason(for: label).contains("neutral"),
                "the refusal for \(label) must say why")
        }
    }

    func testAnUnknownLabelIsRefused() {
        XCTAssertNil(RelationGraph.inverse(of: "landlord"))
        let reason = RelationGraph.ambiguityReason(for: "landlord")
        XCTAssertTrue(reason.contains("landlord"))
        XCTAssertFalse(reason.contains("neutral"),
                       "an unknown label is not a missing-term problem")
    }

    /// A refusal the user cannot act on is a dead end.
    func testRefusalsSuggestSomething() {
        XCTAssertEqual(RelationGraph.inverseSuggestions(for: "uncle"),
                       ["nephew", "niece"])
        XCTAssertEqual(RelationGraph.inverseSuggestions(for: "niece"),
                       ["uncle", "aunt"])
        XCTAssertTrue(RelationGraph.inverseSuggestions(for: "landlord").isEmpty)
    }

    // MARK: Matching

    /// ⚠️ Matching ignores case, spaces and hyphens, matching `Labels.relation`.
    func testMatchingIgnoresCaseAndPunctuation() {
        XCTAssertEqual(RelationGraph.inverse(of: "SPOUSE"), "spouse")
        XCTAssertEqual(RelationGraph.inverse(of: "Grand-Parent"), "grandchild")
        XCTAssertEqual(RelationGraph.inverse(of: "grand parent"), "grandchild")
        XCTAssertEqual(RelationGraph.inverse(of: "Father"), "child")
        XCTAssertEqual(RelationGraph.normalize("younger-sister"),
                       RelationGraph.normalize("youngerSister"))
    }

    /// 🛑 A relation is stored in two spellings on one real machine —
    /// `_$!<Father>!$_` on one card and a plain `Sibling` on another. Anything
    /// comparing labels has to normalise, or it misses real matches. That bug
    /// made `link` report "would add" for a relation the contact already had.
    func testNormalizeCollapsesTheSpellingsThatActuallyOccur() {
        XCTAssertEqual(RelationGraph.normalize("Father"), "father")
        XCTAssertEqual(RelationGraph.normalize("father"), "father")
        XCTAssertEqual(RelationGraph.normalize("Grand Parent"),
                       RelationGraph.normalize("grandparent"))
    }
}
