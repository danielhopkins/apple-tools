import Foundation

/// How a death is recorded on a contact card.
///
/// 🛑 **Apple defines no death field anywhere.** Measured on macOS 27 across all
/// three layers a contact can be written through:
///
/// | Layer | Date labels it defines | Death? |
/// |---|---|---|
/// | `CNContact` | `CNLabelDateAnniversary`, and nothing else | none |
/// | legacy `AddressBook` | `kABAnniversaryLabel`, and nothing else | none |
/// | `AddressBook-v22.abcddb` | `ZABCDCONTACTDATE.ZLABEL`, free text | no column |
///
/// So a custom label on `CNContactDatesKey` is the only route, and this type is
/// the one place that decides how it is spelled.
///
/// 🛑 **A labelled date REQUIRES a month and a day; only the year is optional.**
/// That is the exact inverse of what "died in 2020" needs. Measured against a
/// real store, with a fixture that was deleted afterwards:
///
/// | Written | Result |
/// |---|---|
/// | `2020` | refused — `CNErrorDomain 302`, key paths `dates.value.month`, `dates.value.day` |
/// | `2020-04` | refused — `CNErrorDomain 302`, key path `dates.value.day` |
/// | `--04-30` | accepted |
/// | `2020-04-30` | accepted |
///
/// `--birthday 2020` fails the same way, so the rule belongs to Contacts and not
/// to one key path.
///
/// ⚠️ **A year-only death therefore stores a day that is not true.** The day is a
/// placeholder and the *label* is what says so. Nothing else can carry that
/// fact: `CNContact` has no free-text field but the note, and the note needs
/// `com.apple.developer.contacts.notes`, an entitlement no command-line tool can
/// hold. Two consequences that everything reading this must respect:
///
/// - **`died` reports what is KNOWN, never what is stored.** A year-only death
///   reads back as `2020`, never as `2020-01-01`. A caller shown the placeholder
///   would report a false date, which is the whole failure this design exists to
///   avoid.
/// - **The raw `dates` array still shows the placeholder**, unchanged, because
///   that really is what the card holds and `get` → `edit` → `get` has to stay a
///   no-op.
public enum DeathDate {

    /// How much of the date is real.
    public enum Precision: String, Sendable {
        /// A full date. Every component is true.
        case date
        /// The year is true; the month and day are a placeholder.
        case year
        /// The month and day are true; the year is unknown. Apple stores this
        /// natively as `--MM-DD`, so nothing is invented.
        case dayOnly = "day-only"
    }

    /// The label for a date whose every component is real.
    ///
    /// ⚠️ Lowercase, and that spelling is load-bearing: three cards on the store
    /// this was built against already use it, written by hand years earlier.
    /// Changing it means rewriting them.
    public static let exactLabel = "death"

    /// The label for a date where only the year is real.
    public static let yearLabel = "death-year"

    /// The month and day written when only the year is known.
    ///
    /// ⚠️ Chosen, not derived. January 1 sorts a year-only death before every
    /// dated one in the same year.
    public static let yearPlaceholder = (month: 1, day: 1)

    /// What a `--died` value means: the label to store, the components to store,
    /// and how much of it is real.
    public struct Written: Equatable, Sendable {
        public let label: String
        public let components: DateComponents
        public let precision: Precision
        /// What `died` will report afterwards. Never the placeholder.
        public let known: String
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Turn a `--died` value into what belongs on the card.
    ///
    /// Accepts `YYYY-MM-DD`, `YYYY`, and `--MM-DD`.
    public static func parse(_ raw: String) throws -> Written {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw ParseError(description: "a death date cannot be empty")
        }

        // --MM-DD: the day is known and the year is not. Apple stores it as-is.
        if value.hasPrefix("--") {
            let parts = value.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let month = Int(parts[0]), let day = Int(parts[1]),
                  (1...12).contains(month), (1...31).contains(day)
            else { throw ParseError(description: malformed(value)) }
            var components = DateComponents()
            components.month = month
            components.day = day
            return Written(
                label: exactLabel, components: components, precision: .dayOnly,
                known: String(format: "--%02d-%02d", month, day))
        }

        let parts = value.split(separator: "-", omittingEmptySubsequences: false)

        // YYYY: only the year is real, so the day is a placeholder and the label
        // is what records that.
        if parts.count == 1 {
            guard parts[0].count == 4, let year = Int(parts[0]), year > 0 else {
                throw ParseError(description: malformed(value))
            }
            var components = DateComponents()
            components.year = year
            components.month = yearPlaceholder.month
            components.day = yearPlaceholder.day
            return Written(
                label: yearLabel, components: components, precision: .year,
                known: String(format: "%04d", year))
        }

        // 🛑 YYYY-MM is refused rather than padded. Contacts rejects it outright
        // (`dates.value.day`), and inventing a day would record a month as if it
        // were exact — the same lie the year label exists to prevent, with no
        // label left to disclose it.
        if parts.count == 2 {
            throw ParseError(description: """
                '\(value)' names a month but no day, and Contacts refuses a date \
                without one. Give the full date, or just the year: \
                '\(parts[0])'.
                """)
        }

        guard parts.count == 3,
              parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year > 0, (1...12).contains(month), (1...31).contains(day)
        else { throw ParseError(description: malformed(value)) }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Written(
            label: exactLabel, components: components, precision: .date,
            known: String(format: "%04d-%02d-%02d", year, month, day))
    }

    private static func malformed(_ value: String) -> String {
        "'\(value)' is not a date. Use YYYY-MM-DD, YYYY, or --MM-DD."
    }

    // MARK: Reading a card back

    /// What a card records about a death, or nil if it records none.
    public struct Recorded: Equatable, Sendable {
        /// What is actually known. `2020-04-30`, `2020`, or `--04-30`.
        public let died: String
        public let precision: Precision
    }

    /// Does this label mean a death?
    ///
    /// ⚠️ Matching ignores case, because a card written by hand may say `Death`
    /// and a person who died is not a thing to miss over capitalisation. Writing
    /// always uses the lowercase spelling, so the two never drift apart from this
    /// tool's side.
    ///
    /// 🛑 The whole label must match. A prefix test would make `death-year` match
    /// `death` and report the placeholder day as real.
    public static func isDeathLabel(_ label: String?) -> Bool {
        precision(forLabel: label) != nil
    }

    private static func precision(forLabel label: String?) -> Precision? {
        guard let label else { return nil }
        switch label.lowercased() {
        case exactLabel: return .date
        case yearLabel: return .year
        default: return nil
        }
    }

    /// Read a contact's labelled dates and report the death, if there is one.
    ///
    /// ⚠️ Takes the FIRST death label it finds. A card with two is a mistake
    /// nothing here can adjudicate, and picking one quietly beats inventing a
    /// merged answer.
    public static func read(_ dates: [(label: String?, components: DateComponents)]) -> Recorded? {
        for entry in dates {
            guard let labelled = precision(forLabel: entry.label) else { continue }
            let c = entry.components

            switch labelled {
            case .year:
                // 🛑 The month and day here are the placeholder. Reporting them
                // would hand the caller a false date.
                guard let year = c.year else { continue }
                return Recorded(died: String(format: "%04d", year), precision: .year)

            case .date, .dayOnly:
                guard let month = c.month, let day = c.day else { continue }
                if let year = c.year {
                    return Recorded(
                        died: String(format: "%04d-%02d-%02d", year, month, day),
                        precision: .date)
                }
                return Recorded(
                    died: String(format: "--%02d-%02d", month, day), precision: .dayOnly)
            }
        }
        return nil
    }

    // MARK: The note marker

    /// A dagger in the note, which some address books use to mark a death.
    ///
    /// ⚠️ **This is never the record and never makes anyone deceased.** The death
    /// date is the record. This exists only so `deceased` can report a card that
    /// carries the mark and no date, which is otherwise invisible. The tool
    /// cannot write a note at all, so it can never resolve such a card itself.
    public static func noteMarksDeath(_ note: String?) -> Bool {
        guard let note else { return false }
        return note.contains("\u{2020}")   // †  DAGGER
    }
}
