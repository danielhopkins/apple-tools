import Contacts
import Foundation

/// Turns a `--address` value into a `CNMutablePostalAddress`.
///
/// 🛑 **`get` returned an `addresses` array that `edit` and `add` could not
/// write.** A contact who moved had to be fixed by hand in Contacts.app, and
/// the skill claimed addresses were writable, which sent a reader looking for a
/// flag that did not exist.
///
/// Two input shapes, because neither alone is good enough:
///
/// - **Structured** — `street=124 Gregory St;city=Chicago;state=IL;zip=60601`.
///   Exact, and the only form that can express an address the free-text parser
///   gets wrong.
/// - **Free text** — `124 Gregory St, Chicago, IL 60601, USA`. Far nicer to
///   type, and how every other multi-value flag here reads.
///
/// ⚠️ **A free-text parse is a guess, so it is always echoed on stderr.** This
/// repo refuses ambiguity rather than guessing — `maps geocode`, `notes delete`
/// and `calendar --at` all do. A postal address cannot be refused on the same
/// terms, because there is no rule that separates a street from a city. So the
/// guess is made, then shown, and the structured form is named as the way to
/// correct it.
public enum PostalAddress {

    /// Which of the two shapes a value uses.
    ///
    /// 🛑 **Match a bare word before the `=`, NOT a recognised key.** Requiring
    /// a known key was the first version, and it meant a typo silently changed
    /// which parser ran: `citty=Chicago` fell through to free text and was
    /// written as a street reading `citty=Chicago`, with a zero exit code. The
    /// `default:` branch that exists to catch a bad key was never reached.
    ///
    /// ⚠️ A bare `=` alone is still not enough — a street like `Apt 3 = rear`
    /// has one. The word before it must be letters only, which no street is.
    public static func isStructured(_ value: String) -> Bool {
        value.split(separator: ";").contains { part in
            guard let equals = part.firstIndex(of: "=") else { return false }
            let key = part[part.startIndex..<equals]
                .trimmingCharacters(in: .whitespaces)
            return !key.isEmpty && key.allSatisfy { $0.isLetter }
        }
    }

    /// The structured keys, and the CNPostalAddress field each sets.
    ///
    /// `zip` and `postalcode` are both accepted because `get` prints `zip` and
    /// the SDK calls it `postalCode`. Re-passing what `get` printed has to work
    /// — that is the documented "read it first, re-pass what you want to keep"
    /// workflow, and it is why the label encoders stopped returning Optional.
    public static let keys: Set<String> = [
        "street", "city", "state", "zip", "postalcode", "country", "sublocality",
        "subadministrativearea", "isocountrycode",
    ]

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    // MARK: - Structured

    public static func structured(_ value: String) throws -> CNMutablePostalAddress {
        let address = CNMutablePostalAddress()
        var seen = false

        for part in value.split(separator: ";") {
            let text = part.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard let equals = text.firstIndex(of: "=") else {
                throw ParseError(description: """
                    '\(text)' is not KEY=VALUE. In a structured address every \
                    component needs a key.
                    Valid keys: \(keys.sorted().joined(separator: ", "))
                    """)
            }
            let key = text[text.startIndex..<equals]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let field = String(text[text.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "street": address.street = field
            case "city": address.city = field
            case "state": address.state = field
            case "zip", "postalcode": address.postalCode = field
            case "country": address.country = field
            case "sublocality": address.subLocality = field
            case "subadministrativearea": address.subAdministrativeArea = field
            case "isocountrycode": address.isoCountryCode = field
            default:
                // 🛑 Never drop an unrecognised key silently. A typo'd `citty=`
                // would otherwise write an address missing its city and report
                // success — the failure mode the label encoders were fixed for.
                throw ParseError(description: """
                    '\(key)' is not an address field.
                    Valid keys: \(keys.sorted().joined(separator: ", "))
                    """)
            }
            seen = true
        }

        guard seen else {
            throw ParseError(description: "the address is empty")
        }
        return address
    }

    // MARK: - Free text

    /// Splits a comma-separated address the way a US postal address reads.
    ///
    /// ⚠️ **This is a heuristic and it will be wrong for some addresses.** It
    /// knows one shape: `street, city, STATE ZIP, country`, with the country and
    /// the state/zip both optional. It has no knowledge of any other country's
    /// conventions.
    ///
    /// The caller must show the user what it produced.
    public static func freeText(_ value: String) throws -> CNMutablePostalAddress {
        var parts = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            throw ParseError(description: "the address is empty")
        }

        let address = CNMutablePostalAddress()

        // 🛑 **Find the postal line first, and take the country from after it.**
        // The obvious rule — "a trailing component with no digits is the
        // country" — turns `1 Infinite Loop, Cupertino, CA` into a country of
        // CA. A country follows the postal line; that is the only reliable
        // signal in a comma-separated address.
        //
        // Never index 0: that is the street, and a street starts with a number.
        var postalIndex: Int?
        for index in stride(from: parts.count - 1, through: 1, by: -1) {
            let tokens = parts[index].split(separator: " ").map(String.init)
            if tokens.count <= 3, let last = tokens.last, isPostalCode(last) {
                postalIndex = index
                break
            }
        }

        if let index = postalIndex {
            // Everything after the postal line is the country.
            if index < parts.count - 1 {
                address.country = parts[(index + 1)...].joined(separator: ", ")
            }
            let tokens = parts[index].split(separator: " ").map(String.init)
            // ⚠️ **A postal line splits three ways, and each was measured on a
            // real address:**
            //
            //   `IL 60601`      state + zip. A US state abbreviation carries no
            //                   digit; a zip is all digits.
            //   `SW1A 2AA`      one UK postcode, no state. Splitting it gave
            //                   `state=SW1A;zip=2AA`.
            //   `ON M5H 2N2`    a Canadian province plus a two-token postcode.
            //                   Taking only the last token gave
            //                   `state=ON M5H;zip=2N2`.
            //
            // A postcode half mixes letters and digits. A state name never does.
            func isPostcodeHalf(_ token: String) -> Bool {
                token.contains(where: \.isNumber) && token.contains(where: \.isLetter)
            }

            if tokens.count == 3, isPostcodeHalf(tokens[1]), isPostcodeHalf(tokens[2]) {
                address.state = tokens[0]
                address.postalCode = "\(tokens[1]) \(tokens[2])"
            } else if tokens.count >= 2, let first = tokens.first,
                      !first.contains(where: \.isNumber) {
                address.postalCode = tokens.last ?? ""
                address.state = tokens.dropLast().joined(separator: " ")
            } else {
                address.postalCode = parts[index]
            }
            parts.removeSubrange(index...)
        } else if parts.count >= 2, let last = parts.last,
                  last.count <= 3, !last.contains(where: \.isNumber) {
            // A bare state abbreviation with the zip left off.
            address.state = last
            parts.removeLast()
        }

        // City: the last of what remains, but only when a street survives it.
        if parts.count >= 2 {
            address.city = parts.removeLast()
        }

        // Street: everything left, rejoined. A street really can carry a comma
        // — `124 Gregory St, Apt 3` — and it lands here rather than becoming a
        // city, because the city was taken from the end.
        address.street = parts.joined(separator: ", ")

        guard !address.street.isEmpty || !address.city.isEmpty else {
            throw ParseError(description: "could not find a street or a city in '\(value)'")
        }
        return address
    }

    /// ⚠️ Deliberately loose. A US ZIP, a UK or Canadian postcode and a plain
    /// numeric code all have to pass, and a state name must not.
    private static func isPostalCode(_ text: String) -> Bool {
        guard !text.isEmpty, text.contains(where: \.isNumber) else { return false }
        return text.allSatisfy { $0.isNumber || $0.isLetter || $0 == "-" }
    }

    // MARK: - Entry point

    public static func parse(_ value: String) throws -> CNMutablePostalAddress {
        isStructured(value) ? try structured(value) : try freeText(value)
    }

    /// One line naming every field that was set, for the stderr echo and for
    /// the post-write check.
    ///
    /// 🛑 The post-write check compares this string, so it must include every
    /// field `parse` can set. A field left out here is a field whose loss the
    /// confirmation cannot see.
    public static func describe(_ address: CNPostalAddress) -> String {
        var parts: [String] = []
        func add(_ name: String, _ value: String) {
            if !value.isEmpty { parts.append("\(name)=\(value)") }
        }
        add("street", address.street)
        add("city", address.city)
        add("state", address.state)
        add("zip", address.postalCode)
        add("country", address.country)
        add("sublocality", address.subLocality)
        add("subadministrativearea", address.subAdministrativeArea)
        add("isocountrycode", address.isoCountryCode)
        return parts.joined(separator: ";")
    }
}
