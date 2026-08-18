import Foundation
import XCTest

@testable import ContactsLibrary

/// 🛑 **The rule this file exists to pin: `died` reports what is KNOWN, never
/// what is stored.** A year-only death has to occupy a real month and day,
/// because Contacts refuses a date without them — so the card holds a day that
/// is false and the label is the only thing that says so. Every test below that
/// asserts `2020` rather than `2020-01-01` is guarding against that placeholder
/// escaping into a caller's hands.
///
/// Offline, like `PostalAddressTests`, and for the same reason: seventeen real
/// contacts were once created in a live iCloud account to see how a string
/// parsed. Contacts writes sync to every device and have no undo.
final class DeathDateParseTests: XCTestCase {

    // MARK: A full date — every component is real

    func testAFullDateKeepsTheOrdinaryLabel() throws {
        let written = try DeathDate.parse("2020-04-30")
        XCTAssertEqual(written.label, "death")
        XCTAssertEqual(written.precision, .date)
        XCTAssertEqual(written.known, "2020-04-30")
        XCTAssertEqual(written.components.year, 2020)
        XCTAssertEqual(written.components.month, 4)
        XCTAssertEqual(written.components.day, 30)
    }

    /// The three cards already on the store were written by hand, years before
    /// this code, with exactly this label. Changing it would strand them.
    func testTheExactLabelIsTheOneAlreadyInUse() {
        XCTAssertEqual(DeathDate.exactLabel, "death")
    }

    // MARK: A year alone — the day is a placeholder

    func testAYearGetsItsOwnLabelSoTheFakeDayIsDeclared() throws {
        let written = try DeathDate.parse("2020")
        XCTAssertEqual(written.label, "death-year")
        XCTAssertEqual(written.precision, .year)
    }

    /// 🛑 Contacts refuses a date with no month or day (`CNErrorDomain 302`,
    /// key paths `dates.value.month` and `dates.value.day`). So a year MUST be
    /// padded, and the padding must be deterministic.
    func testAYearIsPaddedToARealDateBecauseContactsDemandsOne() throws {
        let written = try DeathDate.parse("2020")
        XCTAssertEqual(written.components.year, 2020)
        XCTAssertEqual(written.components.month, 1, "Contacts rejects a date with no month")
        XCTAssertEqual(written.components.day, 1, "Contacts rejects a date with no day")
    }

    /// 🛑 The whole point. A caller handed `2020-01-01` would report a day the
    /// user never gave and cannot have meant.
    func testAYearReportsTheYearAndNotThePlaceholder() throws {
        let written = try DeathDate.parse("2020")
        XCTAssertEqual(written.known, "2020")
        XCTAssertNotEqual(written.known, "2020-01-01")
    }

    // MARK: A day with no year — Apple stores this natively

    func testAYearLessDateKeepsTheOrdinaryLabel() throws {
        let written = try DeathDate.parse("--04-30")
        XCTAssertEqual(written.label, "death", "nothing is invented, so nothing is declared")
        XCTAssertEqual(written.precision, .dayOnly)
        XCTAssertEqual(written.known, "--04-30")
        XCTAssertNil(written.components.year)
        XCTAssertEqual(written.components.month, 4)
        XCTAssertEqual(written.components.day, 30)
    }

    // MARK: Refusals

    /// 🛑 `2020-04` is refused rather than padded to the 1st. Contacts rejects
    /// it outright, and inventing a day would record a month as though it were
    /// exact — with no label left to disclose it, since `death-year` would be a
    /// lie about the year's precision too.
    func testAYearAndMonthIsRefusedRatherThanPadded() {
        XCTAssertThrowsError(try DeathDate.parse("2020-04")) { error in
            let text = (error as? DeathDate.ParseError)?.description ?? ""
            XCTAssertTrue(text.contains("day"), "the refusal must say what is missing")
            XCTAssertTrue(text.contains("2020"), "and offer the year as the way out")
        }
    }

    func testGarbageIsRefused() {
        for bad in ["", "   ", "yesterday", "20-04-30", "2020-13-01", "2020-04-32",
                    "--13-01", "--04", "2020-04-30-01", "0000"] {
            XCTAssertThrowsError(try DeathDate.parse(bad), "'\(bad)' should not parse")
        }
    }
}

// MARK: - Reading a card back

final class DeathDateReadTests: XCTestCase {

    private func date(_ year: Int?, _ month: Int?, _ day: Int?) -> DateComponents {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return c
    }

    func testAFullDateReadsBackWhole() {
        let read = DeathDate.read([("death", date(2020, 4, 30))])
        XCTAssertEqual(read, DeathDate.Recorded(died: "2020-04-30", precision: .date))
    }

    /// 🛑 The stored card says 2020-01-01. The answer must say 2020.
    func testAYearOnlyCardNeverLeaksItsPlaceholderDay() {
        let read = DeathDate.read([("death-year", date(2020, 1, 1))])
        XCTAssertEqual(read, DeathDate.Recorded(died: "2020", precision: .year))
    }

    /// The placeholder is a convention, not a guarantee. A card edited by hand
    /// in Contacts.app can hold any day under this label, and the year is still
    /// the only part that means anything.
    func testAYearOnlyCardIgnoresWhateverDayItActuallyHolds() {
        let read = DeathDate.read([("death-year", date(2020, 7, 19))])
        XCTAssertEqual(read?.died, "2020")
    }

    func testAYearLessDateReadsBackAsYearLess() {
        let read = DeathDate.read([("death", date(nil, 4, 30))])
        XCTAssertEqual(read, DeathDate.Recorded(died: "--04-30", precision: .dayOnly))
    }

    func testACardWithNoDeathDateReportsNothing() {
        XCTAssertNil(DeathDate.read([]))
        XCTAssertNil(DeathDate.read([("anniversary", date(2013, 5, 11))]))
        XCTAssertNil(DeathDate.read([(nil, date(2013, 5, 11))]))
    }

    func testTheDeathDateIsFoundAmongOtherDates() {
        let read = DeathDate.read([
            ("anniversary", date(2013, 5, 11)),
            ("graduation", date(1999, 6, 15)),
            ("death", date(2020, 4, 30)),
        ])
        XCTAssertEqual(read?.died, "2020-04-30")
    }

    /// ⚠️ A card written by hand may capitalise. A person who died is not a
    /// thing to miss over one letter.
    func testMatchingIgnoresCase() {
        XCTAssertEqual(DeathDate.read([("Death", date(2020, 4, 30))])?.died, "2020-04-30")
        XCTAssertEqual(DeathDate.read([("DEATH-YEAR", date(2020, 1, 1))])?.died, "2020")
    }

    /// 🛑 A prefix test would make `death-year` match `death` and report its
    /// placeholder day as real.
    func testTheWholeLabelMustMatch() {
        XCTAssertNil(DeathDate.read([("death of a friend", date(2020, 4, 30))]))
        XCTAssertNil(DeathDate.read([("deathbed", date(2020, 4, 30))]))
        XCTAssertFalse(DeathDate.isDeathLabel("death-year-approx"))
        XCTAssertFalse(DeathDate.isDeathLabel("predeath"))
        XCTAssertTrue(DeathDate.isDeathLabel("death"))
        XCTAssertTrue(DeathDate.isDeathLabel("death-year"))
    }

    /// A `death-year` row with no year at all carries nothing, and must not be
    /// reported as a death with a blank date.
    func testAnIncompleteRowIsSkippedRatherThanReportedEmpty() {
        XCTAssertNil(DeathDate.read([("death-year", date(nil, 1, 1))]))
        XCTAssertNil(DeathDate.read([("death", date(2020, nil, nil))]))
    }
}

// MARK: - What parse writes is what read gives back

final class DeathDateRoundTripTests: XCTestCase {

    /// Every accepted input must survive the trip through the card unchanged,
    /// because `--died` on an already-recorded death has to be a no-op.
    func testEveryAcceptedInputRoundTrips() throws {
        for input in ["2020-04-30", "2020", "--04-30", "1987-12-31", "1900"] {
            let written = try DeathDate.parse(input)
            let read = DeathDate.read([(written.label, written.components)])
            XCTAssertEqual(read?.died, written.known, "\(input) did not survive")
            XCTAssertEqual(read?.precision, written.precision, "\(input) changed precision")
        }
    }

    func testAYearRoundTripsAsAYearAndNotADate() throws {
        let written = try DeathDate.parse("2020")
        let read = DeathDate.read([(written.label, written.components)])
        XCTAssertEqual(read?.died, "2020")
        XCTAssertEqual(read?.precision, .year)
    }
}

// MARK: - The note marker

/// ⚠️ The marker is never the record. It exists so `deceased` can report a card
/// carrying it with no date, which is otherwise invisible — and which the tool
/// can never fix itself, since it cannot write a note.
final class DeathNoteMarkerTests: XCTestCase {

    func testADaggerAnywhereInTheNoteCounts() {
        XCTAssertTrue(DeathDate.noteMarksDeath("«†»"))
        XCTAssertTrue(DeathDate.noteMarksDeath("†"))
        XCTAssertTrue(DeathDate.noteMarksDeath("ralph@dosser.org\n\n«†»\nhttps://example.invalid"))
    }

    func testAnOrdinaryNoteDoesNot() {
        XCTAssertFalse(DeathDate.noteMarksDeath(nil))
        XCTAssertFalse(DeathDate.noteMarksDeath(""))
        XCTAssertFalse(DeathDate.noteMarksDeath("met at the conference in 2019"))
        // ‡ is a double dagger and a different character.
        XCTAssertFalse(DeathDate.noteMarksDeath("‡"))
    }
}
