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

    /// 🛑 **The second guessing mistake.** An earlier version refused `uncle`,
    /// `aunt`, `nephew` and `niece`, claiming Contacts had no neutral term for
    /// either direction. It has both: `ParentsSibling` and `SiblingsChild`. The
    /// error came from searching for an obvious English word instead of reading
    /// the generated label list.
    func testAuntAndUncleInvertThroughTheNeutralKinshipTerms() {
        XCTAssertEqual(RelationGraph.inverse(of: "uncle"), "siblingschild")
        XCTAssertEqual(RelationGraph.inverse(of: "aunt"), "siblingschild")
        XCTAssertEqual(RelationGraph.inverse(of: "nephew"), "parentssibling")
        XCTAssertEqual(RelationGraph.inverse(of: "niece"), "parentssibling")
        XCTAssertEqual(RelationGraph.inverse(of: "parentssibling"), "siblingschild")
        XCTAssertEqual(RelationGraph.inverse(of: "siblingschild"), "parentssibling")
    }

    /// ⚠️ What is left really is ambiguous, and each was checked against the
    /// label list rather than assumed: there is no `Stepsibling`, no neutral
    /// term for grandaunt/granduncle or grandnephew/grandniece, and no
    /// `Student`.
    func testTheRemainingAmbiguousLabels() {
        for label in ["stepbrother", "stepsister", "grandaunt", "granduncle",
                      "grandnephew", "grandniece", "teacher"] {
            XCTAssertNil(RelationGraph.inverse(of: label),
                         "\(label) must not be inverted automatically")
            XCTAssertTrue(
                RelationGraph.ambiguityReason(for: label).contains("no label"),
                "the refusal for \(label) must say why")
        }
    }

    /// Birth order inverts, because both neutral forms exist.
    func testBirthOrderInverts() {
        XCTAssertEqual(RelationGraph.inverse(of: "elderbrother"), "youngersibling")
        XCTAssertEqual(RelationGraph.inverse(of: "youngersister"), "eldersibling")
        // ⚠️ The *eldest* sibling's other side is only "younger", not
        // "youngest": everyone is younger than the eldest, but not all of them
        // are the youngest.
        XCTAssertEqual(RelationGraph.inverse(of: "eldestbrother"), "youngersibling")
        XCTAssertEqual(RelationGraph.inverse(of: "youngestsister"), "eldersibling")
        XCTAssertEqual(RelationGraph.inverse(of: "eldercousin"), "youngercousin")
    }

    /// Step-family inverts through its own neutral terms.
    func testStepFamilyInverts() {
        XCTAssertEqual(RelationGraph.inverse(of: "stepfather"), "stepchild")
        XCTAssertEqual(RelationGraph.inverse(of: "stepdaughter"), "stepparent")
        XCTAssertEqual(RelationGraph.inverse(of: "stepparent"), "stepchild")
    }

    /// A gender-qualified form of a symmetric relation drops the qualifier.
    func testGenderQualifiedSymmetricLabelsDropTheQualifier() {
        XCTAssertEqual(RelationGraph.inverse(of: "malefriend"), "friend")
        XCTAssertEqual(RelationGraph.inverse(of: "femalecousin"), "cousin")
        XCTAssertEqual(RelationGraph.inverse(of: "boyfriend"), "partner")
        XCTAssertEqual(RelationGraph.inverse(of: "girlfriend"), "partner")
    }

    func testAnUnknownLabelIsRefused() {
        XCTAssertNil(RelationGraph.inverse(of: "landlord"))
        let reason = RelationGraph.ambiguityReason(for: "landlord")
        XCTAssertTrue(reason.contains("landlord"))
        XCTAssertFalse(reason.contains("no label for the other side"),
                       "an unknown label is not a missing-term problem")
    }

    /// A refusal the user cannot act on is a dead end.
    func testRefusalsSuggestSomething() {
        XCTAssertEqual(RelationGraph.inverseSuggestions(for: "stepbrother"),
                       ["stepbrother", "stepsister"])
        XCTAssertEqual(RelationGraph.inverseSuggestions(for: "grandniece"),
                       ["grandaunt", "granduncle"])
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

// MARK: - Coverage against the real SDK vocabulary

/// 🛑 **The inverse table was built by guessing which labels exist, and it was
/// wrong twice.**
///
/// First it refused `father` on the reasoning that "son or daughter" had no
/// single term — `Child` does. Then it refused `uncle`, `aunt`, `nephew` and
/// `niece` claiming no neutral term existed — `ParentsSibling` and
/// `SiblingsChild` both do. Neither error came from a bad rule; both came from
/// not reading the list.
///
/// So these tests check the table against the generated vocabulary itself.
final class RelationCoverageTests: XCTestCase {

    private var vocabulary: Set<String> {
        Set(ContactRelations.names.map(RelationGraph.normalize))
    }

    /// 🛑 **Every inverse must be a label the SDK actually defines.** Writing a
    /// label Contacts does not know stores it as a custom string, so the other
    /// card ends up with a relation that never matches anything.
    func testEveryInverseIsARealSDKLabel() {
        let known = vocabulary
        for (label, _) in RelationGraph.rules {
            guard let other = RelationGraph.inverse(of: label) else { continue }
            XCTAssertTrue(known.contains(other),
                          "\(label) inverts to '\(other)', which is not an SDK label")
        }
    }

    /// Every label the table names must itself exist. A typo'd key is a rule
    /// that silently never fires.
    func testEveryRuleKeyIsARealSDKLabel() {
        let known = vocabulary
        for (label, _) in RelationGraph.rules {
            XCTAssertTrue(known.contains(label),
                          "'\(label)' has a rule but is not an SDK label")
        }
    }

    /// ⚠️ **A label marked ambiguous must really have no neutral partner.**
    /// This is the check that would have caught the aunt/uncle mistake: if a
    /// plausible neutral term exists in the vocabulary, the refusal is wrong.
    func testAmbiguousLabelsHaveNoObviousNeutralTerm() {
        let known = vocabulary
        // The neutral term for a gendered pair, where one exists.
        let neutralCandidates: [String: String] = [
            "stepbrother": "stepsibling",
            "stepsister": "stepsibling",
            "grandaunt": "grandparentssibling",
            "granduncle": "grandparentssibling",
            "grandnephew": "grandsiblingschild",
            "grandniece": "grandsiblingschild",
            "teacher": "student",
        ]
        for (label, candidate) in neutralCandidates {
            XCTAssertNil(RelationGraph.inverse(of: label),
                         "\(label) should still be ambiguous")
            XCTAssertFalse(
                known.contains(candidate),
                "'\(candidate)' IS an SDK label, so \(label) should not be refused")
        }
    }

    /// The plain English labels a person would actually type must all resolve.
    /// The 190-odd hyper-specific kinship terms are left unmapped on purpose.
    func testTheCommonEnglishLabelsAllHaveRules() {
        let everyday = [
            "spouse", "husband", "wife", "partner", "boyfriend", "girlfriend",
            "friend", "colleague", "cousin", "sibling",
            "parent", "child", "father", "mother", "son", "daughter",
            "brother", "sister",
            "grandparent", "grandchild", "grandfather", "grandmother",
            "grandson", "granddaughter",
            "uncle", "aunt", "nephew", "niece",
            "stepparent", "stepchild", "stepfather", "stepmother",
            "stepson", "stepdaughter",
            "manager", "assistant",
        ]
        for label in everyday {
            XCTAssertNotNil(RelationGraph.inverse(of: label),
                            "'\(label)' is an everyday relation and must invert")
        }
    }

    /// ⚠️ Records how much of the vocabulary is deliberately unmapped, so a
    /// reader is not left wondering whether the gap is an oversight.
    func testTheUnmappedRemainderIsTheSpecificKinshipTerms() {
        let known = vocabulary
        let mapped = Set(RelationGraph.rules.keys)
        let unmapped = known.subtracting(mapped)
        // These are terms like `auntfatherselderbrotherswife` — a kinship path,
        // not a word anyone types at a CLI. They refuse cleanly and --inverse
        // still works.
        XCTAssertGreaterThan(unmapped.count, 100,
                             "the remainder should be the specific kinship terms")
        for label in unmapped {
            XCTAssertNil(RelationGraph.inverse(of: label),
                         "'\(label)' is unmapped but returns an inverse")
        }
    }
}
