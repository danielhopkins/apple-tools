import Contacts
import ContactsLibrary
import Foundation

/// Contacts stores its built-in labels wrapped as `_$!<Home>!$_`. Custom labels
/// the user invents are stored as plain strings. These helpers convert between
/// that storage form and the friendly names the CLI accepts and prints.
enum Labels {
    private static let openWrapper = "_$!<"
    private static let closeWrapper = ">!$_"

    static func wrap(_ name: String) -> String {
        "\(openWrapper)\(name)\(closeWrapper)"
    }

    /// The handful of built-in labels Contacts stores *unwrapped*.
    ///
    /// Everything else Apple defines arrives as `_$!<Home>!$_`, which is what
    /// tells a built-in label apart from one the user typed. These three are
    /// bare strings and so are indistinguishable from a custom label except by
    /// being on this list.
    private static let bareBuiltInLabels: Set<String> = [
        CNLabelEmailiCloud,            // "iCloud"
        CNLabelPhoneNumberiPhone,      // "iPhone"
        CNLabelPhoneNumberAppleWatch,  // "Apple Watch"
    ]

    /// `_$!<Father>!$_` -> "father"; a custom label is returned as written.
    ///
    /// ⚠️ **A custom label keeps its case.** Contacts stores a label the user
    /// invented verbatim — "LinkedIn", not "linkedin" — and lowercasing it here
    /// made `get` → `edit` → `get` lossy: re-passing exactly what was read wrote
    /// back a different label than the one that had been there. Only built-in
    /// labels are normalised, because their friendly spelling is ours to choose.
    static func decode(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        let wrapped = raw.hasPrefix(openWrapper) && raw.hasSuffix(closeWrapper)
        guard wrapped || bareBuiltInLabels.contains(raw) else { return raw }

        // `CNLabeledValue.localizedString(forLabel:)` handles the labels Apple
        // knows about, but returns unrecognised wrapped labels verbatim, so
        // strip the wrapper by hand as a fallback.
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: raw)
        if !localized.hasPrefix(openWrapper) {
            return localized.lowercased()
        }
        return String(raw.dropFirst(openWrapper.count).dropLast(closeWrapper.count))
            .lowercased()
    }

    /// "younger-sister", "younger sister" and "youngerSister" all normalise to
    /// the same key so the generated relation list can be matched loosely.
    private static func normalize(_ input: String) -> String {
        input.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Encoding user input

    private static let emailLabels: [String: String] = [
        "home": CNLabelHome, "work": CNLabelWork, "school": CNLabelSchool,
        "other": CNLabelOther, "icloud": CNLabelEmailiCloud,
    ]

    private static let phoneLabels: [String: String] = [
        "home": CNLabelHome, "work": CNLabelWork, "school": CNLabelSchool,
        "other": CNLabelOther, "mobile": CNLabelPhoneNumberMobile,
        "iphone": CNLabelPhoneNumberiPhone, "main": CNLabelPhoneNumberMain,
        "homefax": CNLabelPhoneNumberHomeFax, "workfax": CNLabelPhoneNumberWorkFax,
        "otherfax": CNLabelPhoneNumberOtherFax, "pager": CNLabelPhoneNumberPager,
        "applewatch": CNLabelPhoneNumberAppleWatch,
    ]

    private static let addressLabels: [String: String] = [
        "home": CNLabelHome, "work": CNLabelWork, "school": CNLabelSchool,
        "other": CNLabelOther,
    ]

    /// URLs have their own vocabulary — `homepage`, and none of email's
    /// `icloud`. This used to be `emailLabels`, a copy-paste that accepted a
    /// label URLs do not have and rejected the one they do.
    private static let urlLabels: [String: String] = [
        "home": CNLabelHome, "work": CNLabelWork, "school": CNLabelSchool,
        "other": CNLabelOther, "homepage": CNLabelURLAddressHomePage,
    ]

    /// A name Contacts knows becomes its constant; anything else is kept
    /// verbatim, as the custom label it is.
    ///
    /// 🛑 These used to return `Optional`, and the call sites used `flatMap`, so
    /// an unrecognised label was **silently dropped** and the value written
    /// unlabelled with a zero exit code. Re-passing what `get` had just printed
    /// therefore destroyed the label — the documented "read it first, re-pass
    /// what you want to keep" workflow could not round-trip its own output.
    ///
    /// Contacts stores a label the user invented as a plain string, which is
    /// what `relation` and `date` below have always done, so there was never a
    /// reason to refuse one here.
    static func email(_ name: String) -> String { emailLabels[normalize(name)] ?? name }
    static func phone(_ name: String) -> String { phoneLabels[normalize(name)] ?? name }
    static func url(_ name: String) -> String { urlLabels[normalize(name)] ?? name }

    /// Is this one of the built-in URL labels?
    ///
    /// 🛑 Used to settle `work:example.com`, where the prefix is both a valid
    /// URI scheme by grammar and an obvious label. A built-in label wins, so
    /// `work:`, `home:` and `school:` never turn into schemes.
    static func isKnownURLLabel(_ name: String) -> Bool {
        urlLabels[normalize(name)] != nil
    }

    /// Postal addresses take only the four generic labels. There is no
    /// address-specific constant in the SDK, unlike email's `icloud` or URL's
    /// `homepage`, so this table is deliberately the short one.
    static func address(_ name: String) -> String { addressLabels[normalize(name)] ?? name }

    /// Relations resolve against the generated SDK vocabulary. Anything else is
    /// kept as a plain custom label, which is exactly how Contacts.app stores a
    /// label the user typed themselves.
    static func relation(_ name: String) -> String {
        if let canonical = ContactRelations.byLowercasedName[normalize(name)] {
            return wrap(canonical)
        }
        return name
    }

    static func isKnownRelation(_ name: String) -> Bool {
        ContactRelations.byLowercasedName[normalize(name)] != nil
    }

    /// Only `anniversary` has a constant; every other date label (death,
    /// graduation, ...) is a custom label.
    static func date(_ name: String) -> String {
        normalize(name) == "anniversary" ? CNLabelDateAnniversary : name
    }

    /// Suggestions for an unrecognised relation, for error messages.
    ///
    /// Substring matching alone is not enough: it catches "sister" inside
    /// "youngerSister", but a plain typo like "fathr" shares no substring with
    /// "father" and produced no suggestion at all — which is the case the hint
    /// exists for. So fall back to edit distance when nothing matches by
    /// substring.
    static func nearestRelations(to name: String, limit: Int = 6) -> [String] {
        let needle = normalize(name)
        guard !needle.isEmpty else { return [] }

        let substring = ContactRelations.names
            .filter { $0.lowercased().contains(needle) || needle.contains($0.lowercased()) }
        if !substring.isEmpty {
            return substring.prefix(limit).map { $0.lowercased() }
        }

        // Allow roughly one edit per three characters, so short labels are not
        // matched to everything and long ones still tolerate a slip.
        let budget = max(1, needle.count / 3)
        return ContactRelations.names
            .map { (name: $0, distance: editDistance(needle, $0.lowercased())) }
            .filter { $0.distance <= budget }
            .sorted { ($0.distance, $0.name) < ($1.distance, $1.name) }
            .prefix(limit)
            .map { $0.name.lowercased() }
    }

    /// Levenshtein distance, two rows at a time.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

// MARK: - Date parsing

enum ContactDate {
    /// Accepts `YYYY-MM-DD` and `--MM-DD` (a day with no year, which Contacts
    /// supports for birthdays and anniversaries).
    static func parse(_ value: String) -> DateComponents? {
        var components = DateComponents()

        if value.hasPrefix("--") {
            let parts = value.dropFirst(2).split(separator: "-")
            guard parts.count == 2,
                  let month = Int(parts[0]), let day = Int(parts[1]),
                  (1...12).contains(month), (1...31).contains(day)
            else { return nil }
            components.month = month
            components.day = day
            return components
        }

        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    static func format(_ components: DateComponents?) -> String? {
        guard let components, let month = components.month, let day = components.day else {
            return nil
        }
        if let year = components.year {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }
}
