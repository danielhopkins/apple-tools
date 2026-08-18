import Foundation

/// The rules for linking two contacts to each other.
///
/// 🛑 **A relation stores a NAME and nothing else.** Contacts.app shows a
/// relation as a tappable link, which reads as though it holds a reference to
/// the other card. It does not. Measured on a real store: all 54 relation rows
/// carry a `ZUNIQUEID`, all 54 values are distinct, and **not one** matches any
/// `ZABCDRECORD.ZUNIQUEID`. That column is the relation row's own sync id.
///
/// So there is no stored edge between two contacts. A link is a name that
/// happens to match another card, resolved when it is read. That has three
/// consequences everything here has to live with:
///
/// - **Renaming a contact silently breaks every link to it.** Nothing updates.
/// - **A relation can point at nobody**, and that is not corruption.
/// - **A relation can point at several people**, when two cards share a name.
enum RelationDirection {
    /// The same label applies from both sides: a spouse's spouse is a spouse.
    case symmetric
    /// The inverse exists and is unambiguous.
    case inverse(String)
    /// No inverse can be written, because the SDK has no term for it.
    case ambiguous
}

public enum RelationGraph {

    /// What the other side of a relation should say.
    ///
    /// 🛑 **A gendered label inverts to the NEUTRAL term, and that is not a
    /// guess.** An earlier version refused `father` outright, reasoning that the
    /// other side is "son or daughter" and Contacts records no gender. That was
    /// wrong: `child` is exactly the term for "son or daughter", the SDK defines
    /// it, and writing it states nothing that is not true. The same holds for
    /// `sibling` and `grandchild`.
    ///
    /// ⚠️ **The inverse generalises; it does not round-trip.** `father` gives the
    /// other card `child`, and `child` inverts to `parent`, not back to
    /// `father`. That is correct — the store never knew the father's gender was
    /// recoverable from the child's side — and it is why `--inverse son` exists
    /// for anyone who wants the specific term.
    ///
    /// ⚠️ Every entry is a claim written onto somebody else's card, so a label
    /// only appears here when its inverse is true for certain.
    static let rules: [String: RelationDirection] = [
        // MARK: Symmetric — the relation reads the same from either side.
        "spouse": .symmetric,
        "partner": .symmetric,
        "friend": .symmetric,
        "colleague": .symmetric,
        "cousin": .symmetric,
        "sibling": .symmetric,

        // MARK: Neutral pairs.
        "parent": .inverse("child"),
        "child": .inverse("parent"),
        "grandparent": .inverse("grandchild"),
        "grandchild": .inverse("grandparent"),
        "greatgrandparent": .inverse("greatgrandchild"),
        "greatgrandchild": .inverse("greatgrandparent"),
        "stepparent": .inverse("stepchild"),
        "stepchild": .inverse("stepparent"),
        "manager": .inverse("assistant"),
        "assistant": .inverse("manager"),

        // 🛑 `ParentsSibling` and `SiblingsChild` are the SDK's neutral terms
        // for aunt/uncle and nephew/niece. An earlier version claimed no such
        // term existed and refused all four, because the search only looked for
        // an obvious English word.
        "parentssibling": .inverse("siblingschild"),
        "siblingschild": .inverse("parentssibling"),
        "uncle": .inverse("siblingschild"),
        "aunt": .inverse("siblingschild"),
        "nephew": .inverse("parentssibling"),
        "niece": .inverse("parentssibling"),

        // MARK: Birth order. Both neutral forms exist, so an elder brother's
        // other side is a younger sibling — a real inverse, not a guess.
        "eldersibling": .inverse("youngersibling"),
        "youngersibling": .inverse("eldersibling"),
        "elderbrother": .inverse("youngersibling"),
        "eldersister": .inverse("youngersibling"),
        "youngerbrother": .inverse("eldersibling"),
        "youngersister": .inverse("eldersibling"),
        // ⚠️ The *eldest* sibling's other side is only "younger", not
        // "youngest" — everyone else is younger than the eldest, but they are
        // not all the youngest.
        "eldestbrother": .inverse("youngersibling"),
        "eldestsister": .inverse("youngersibling"),
        "youngestbrother": .inverse("eldersibling"),
        "youngestsister": .inverse("eldersibling"),
        "eldercousin": .inverse("youngercousin"),
        "youngercousin": .inverse("eldercousin"),

        // MARK: Gendered labels invert to the neutral term.
        // 🛑 `husband` and `wife` are NOT symmetric: if B is A's husband, A is
        // B's wife or husband, and only `spouse` covers both.
        "husband": .inverse("spouse"),
        "wife": .inverse("spouse"),
        "boyfriend": .inverse("partner"),
        "girlfriend": .inverse("partner"),
        "malepartner": .inverse("partner"),
        "femalepartner": .inverse("partner"),
        "malefriend": .inverse("friend"),
        "femalefriend": .inverse("friend"),
        "malecousin": .inverse("cousin"),
        "femalecousin": .inverse("cousin"),
        "father": .inverse("child"),
        "mother": .inverse("child"),
        "son": .inverse("parent"),
        "daughter": .inverse("parent"),
        "brother": .inverse("sibling"),
        "sister": .inverse("sibling"),
        "grandfather": .inverse("grandchild"),
        "grandmother": .inverse("grandchild"),
        "grandson": .inverse("grandparent"),
        "granddaughter": .inverse("grandparent"),
        "greatgrandfather": .inverse("greatgrandchild"),
        "greatgrandmother": .inverse("greatgrandchild"),
        "greatgrandson": .inverse("greatgrandparent"),
        "greatgranddaughter": .inverse("greatgrandparent"),
        "stepfather": .inverse("stepchild"),
        "stepmother": .inverse("stepchild"),
        "stepson": .inverse("stepparent"),
        "stepdaughter": .inverse("stepparent"),

        // MARK: Genuinely ambiguous — the SDK defines both gendered terms and
        // NO neutral one, so nothing can be written without inventing a gender.
        // Each was checked against the generated label list, not assumed.
        "stepbrother": .ambiguous,   // no `Stepsibling`
        "stepsister": .ambiguous,
        "grandaunt": .ambiguous,     // no neutral for grandnephew/grandniece
        "granduncle": .ambiguous,
        "grandnephew": .ambiguous,   // no neutral for grandaunt/granduncle
        "grandniece": .ambiguous,
        "teacher": .ambiguous,       // the SDK has no `Student`
    ]

    /// The label the other card should carry, or nil when nothing can be
    /// inferred.
    public static func inverse(of label: String) -> String? {
        switch rules[normalize(label)] {
        case .symmetric: return normalize(label)
        case .inverse(let other): return other
        case .ambiguous, .none: return nil
        }
    }

    /// Why no inverse could be inferred, phrased for the user.
    public static func ambiguityReason(for label: String) -> String {
        let key = normalize(label)
        switch rules[key] {
        case .ambiguous:
            // ⚠️ Not always a gender problem. `teacher` has no inverse because
            // the SDK defines no `Student` at all, and saying "gender-neutral"
            // there sent the reader looking for the wrong thing.
            return "Contacts defines no label for the other side of '\(key)'"
        case .none:
            return "there is no inverse rule for '\(key)'"
        default:
            return ""
        }
    }

    /// A suggestion to put in the refusal, so the user has something to type.
    public static func inverseSuggestions(for label: String) -> [String] {
        switch normalize(label) {
        case "stepbrother", "stepsister": return ["stepbrother", "stepsister"]
        case "grandaunt", "granduncle": return ["grandnephew", "grandniece"]
        case "grandnephew", "grandniece": return ["grandaunt", "granduncle"]
        default: return []
        }
    }

    /// Matching ignores case, spaces and hyphens, the same way `Labels.relation`
    /// does, so `younger-sister` and `youngerSister` behave alike.
    public static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" }
    }
}
