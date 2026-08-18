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
        // Symmetric: the relation reads the same from either side.
        "spouse": .symmetric,
        "partner": .symmetric,
        "friend": .symmetric,
        "colleague": .symmetric,
        "cousin": .symmetric,
        "sibling": .symmetric,

        // Gender-neutral pairs.
        "parent": .inverse("child"),
        "child": .inverse("parent"),
        "grandparent": .inverse("grandchild"),
        "grandchild": .inverse("grandparent"),
        "manager": .inverse("assistant"),
        "assistant": .inverse("manager"),

        // Gendered labels invert to the neutral term for the other side.
        // 🛑 `husband` and `wife` are NOT symmetric: if B is A's husband, A is
        // B's wife or husband, and only `spouse` covers both.
        "husband": .inverse("spouse"),
        "wife": .inverse("spouse"),
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

        // ⚠️ Genuinely ambiguous: the SDK has `Nephew` and `Niece` but no
        // neutral term for either direction, so nothing here can be written
        // without inventing a gender.
        "uncle": .ambiguous,
        "aunt": .ambiguous,
        "nephew": .ambiguous,
        "niece": .ambiguous,
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
            return """
                Contacts has no gender-neutral term for the other side of \
                '\(key)'
                """
        case .none:
            return "there is no inverse rule for '\(key)'"
        default:
            return ""
        }
    }

    /// A suggestion to put in the refusal, so the user has something to type.
    public static func inverseSuggestions(for label: String) -> [String] {
        switch normalize(label) {
        case "uncle", "aunt": return ["nephew", "niece"]
        case "nephew", "niece": return ["uncle", "aunt"]
        default: return []
        }
    }

    /// Matching ignores case, spaces and hyphens, the same way `Labels.relation`
    /// does, so `younger-sister` and `youngerSister` behave alike.
    public static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" }
    }
}
