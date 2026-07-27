import Contacts
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

    /// `_$!<Father>!$_` -> "father"; a custom label is returned as written.
    ///
    /// `CNLabeledValue.localizedString(forLabel:)` handles the labels Apple
    /// knows about, but returns unrecognised wrapped labels verbatim, so strip
    /// the wrapper by hand as a fallback.
    static func decode(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        let localized = CNLabeledValue<NSString>.localizedString(forLabel: raw)
        if !localized.hasPrefix(openWrapper) {
            return localized.lowercased()
        }
        if raw.hasPrefix(openWrapper), raw.hasSuffix(closeWrapper) {
            return String(raw.dropFirst(openWrapper.count).dropLast(closeWrapper.count))
                .lowercased()
        }
        return raw
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
        "pager": CNLabelPhoneNumberPager,
    ]

    static func email(_ name: String) -> String? { emailLabels[normalize(name)] }
    static func phone(_ name: String) -> String? { phoneLabels[normalize(name)] }
    static func url(_ name: String) -> String? { emailLabels[normalize(name)] }

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
    static func nearestRelations(to name: String, limit: Int = 6) -> [String] {
        let needle = normalize(name)
        guard !needle.isEmpty else { return [] }
        return ContactRelations.names
            .filter { $0.lowercased().contains(needle) || needle.contains($0.lowercased()) }
            .prefix(limit)
            .map { $0.lowercased() }
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
