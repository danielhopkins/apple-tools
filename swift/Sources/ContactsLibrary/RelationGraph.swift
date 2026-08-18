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
    /// The inverse depends on something the store does not know — usually the
    /// other person's gender. `father` inverts to son or daughter, and nothing
    /// here may guess which.
    case ambiguous
}

public enum RelationGraph {

    /// What the other side of a relation should say.
    ///
    /// ⚠️ **Deliberately small.** Every entry is a claim that one label implies
    /// another, and a wrong entry writes a wrong fact onto somebody's card. The
    /// gendered pairs — father/son, mother/daughter, brother/sister — are all
    /// left out, because the inverse of "my father" is "my son" or "my
    /// daughter" and the store does not know which.
    static let rules: [String: RelationDirection] = [
        // Symmetric: the relation reads the same from either side.
        "spouse": .symmetric,
        "husband": .symmetric,
        "wife": .symmetric,
        "partner": .symmetric,
        "friend": .symmetric,
        "colleague": .symmetric,
        "cousin": .symmetric,
        "sibling": .symmetric,

        // Unambiguous inverses: neither side depends on gender.
        "parent": .inverse("child"),
        "child": .inverse("parent"),
        "grandparent": .inverse("grandchild"),
        "grandchild": .inverse("grandparent"),
        "manager": .inverse("assistant"),
        "assistant": .inverse("manager"),

        // Named here so the refusal can say WHY, rather than falling through to
        // a generic "no rule". Each is ambiguous for the same reason.
        "father": .ambiguous,
        "mother": .ambiguous,
        "son": .ambiguous,
        "daughter": .ambiguous,
        "brother": .ambiguous,
        "sister": .ambiguous,
    ]

    /// The label the other card should carry, or nil when nothing can be
    /// inferred.
    ///
    /// Returns nil for both "no rule" and "ambiguous". The caller distinguishes
    /// them through `ambiguityReason`, so a user who wrote `--as father` is told
    /// what to pass rather than just refused.
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
                the inverse of '\(key)' depends on the other person's gender, \
                which Contacts does not record
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
        case "father", "mother": return ["son", "daughter", "child"]
        case "son", "daughter": return ["father", "mother", "parent"]
        case "brother", "sister": return ["brother", "sister", "sibling"]
        default: return []
        }
    }

    /// Matching ignores case, spaces and hyphens, the same way `Labels.relation`
    /// does, so `younger-sister` and `youngerSister` behave alike.
    public static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" }
    }
}
