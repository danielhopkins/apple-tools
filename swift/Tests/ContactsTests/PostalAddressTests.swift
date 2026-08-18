import Contacts
import XCTest

@testable import ContactsLibrary

/// 🛑 **This file exists because the parser was first probed by running
/// `apple contacts add` against a real address book.** Seventeen contacts were
/// created in the user's live iCloud to see how a string parsed, and they synced
/// to every device before being deleted. Contacts writes have no undo.
///
/// `PostalAddress` was moved into its own target for exactly this reason. Every
/// question about how a string parses is answered here, offline, with no store
/// of any kind involved. **Never probe a parser through a write command.**
///
/// The two bugs those live probes found are pinned below, and each one failed
/// silently rather than erroring.
final class FreeTextAddressTests: XCTestCase {

    private func parse(_ value: String) throws -> String {
        PostalAddress.describe(try PostalAddress.freeText(value))
    }

    // MARK: The shape the heuristic is built for

    func testAFullUSAddress() throws {
        XCTAssertEqual(
            try parse("124 Gregory St, Chicago, IL 60601, USA"),
            "street=124 Gregory St;city=Chicago;state=IL;zip=60601;country=USA")
    }

    func testAUSAddressWithNoCountry() throws {
        XCTAssertEqual(
            try parse("4800 Baseline Rd, Boulder, CO 80303"),
            "street=4800 Baseline Rd;city=Boulder;state=CO;zip=80303")
    }

    func testAMultiWordStateStillSplitsFromTheZip() throws {
        XCTAssertEqual(
            try parse("500 Fifth Ave, New York, New York 10110"),
            "street=500 Fifth Ave;city=New York;state=New York;zip=10110")
    }

    /// A street really can carry a comma. It must not become the city, which is
    /// why the city is taken from the end rather than the street from the start.
    func testACommaInsideTheStreetSurvives() throws {
        XCTAssertEqual(
            try parse("124 Gregory St, Apt 3, Chicago, IL 60601"),
            "street=124 Gregory St, Apt 3;city=Chicago;state=IL;zip=60601")
    }

    func testAStreetOnItsOwn() throws {
        XCTAssertEqual(try parse("PO Box 12"), "street=PO Box 12")
    }

    // MARK: The two bugs the live probes found

    /// 🛑 **`1 Infinite Loop, Cupertino, CA` produced `country=CA`.**
    ///
    /// The first rule was "a trailing component with no digits is the country".
    /// A state abbreviation has no digits either. The fix finds the postal line
    /// first and takes the country only from after it.
    func testABareStateIsNotMistakenForACountry() throws {
        XCTAssertEqual(
            try parse("1 Infinite Loop, Cupertino, CA"),
            "street=1 Infinite Loop;city=Cupertino;state=CA")
    }

    /// 🛑 **`SW1A 2AA` was split into `state=SW1A;zip=2AA`.**
    ///
    /// A US state abbreviation never carries a digit; a UK postcode always
    /// does. That is what separates `IL 60601` from `SW1A 2AA`.
    func testAUKPostcodeStaysWhole() throws {
        XCTAssertEqual(
            try parse("10 Downing St, London, SW1A 2AA, United Kingdom"),
            "street=10 Downing St;city=London;zip=SW1A 2AA;country=United Kingdom")
    }

    /// 🛑 **`ON M5H 2N2` produced `state=ON M5H;zip=2N2`.**
    ///
    /// A Canadian postcode is two tokens and follows a province. Taking only
    /// the last token as the postcode cut it in half. Both halves mix letters
    /// and digits, which a province name never does.
    func testACanadianPostcodeKeepsBothHalves() throws {
        XCTAssertEqual(
            try parse("100 Queen St W, Toronto, ON M5H 2N2, Canada"),
            "street=100 Queen St W;city=Toronto;state=ON;zip=M5H 2N2;country=Canada")
    }

    func testANumericPostcodeWithNoState() throws {
        XCTAssertEqual(
            try parse("12 Rue de Rivoli, Paris, 75001, France"),
            "street=12 Rue de Rivoli;city=Paris;zip=75001;country=France")
    }

    func testAnEmptyValueIsRefused() {
        XCTAssertThrowsError(try PostalAddress.freeText("   "))
        XCTAssertThrowsError(try PostalAddress.freeText(",,,"))
    }
}

// MARK: - The structured form

final class StructuredAddressTests: XCTestCase {

    private func parse(_ value: String) throws -> String {
        PostalAddress.describe(try PostalAddress.structured(value))
    }

    func testEveryFieldRoundTrips() throws {
        XCTAssertEqual(
            try parse("street=124 Gregory St;city=Chicago;state=IL;zip=60601;country=USA"),
            "street=124 Gregory St;city=Chicago;state=IL;zip=60601;country=USA")
    }

    func testWhitespaceAroundKeysAndValuesIsTrimmed() throws {
        XCTAssertEqual(
            try parse("  street = 1 Main St ; city = Boulder "),
            "street=1 Main St;city=Boulder")
    }

    /// `get` prints `zip`; the SDK calls it `postalCode`. Re-passing what `get`
    /// printed has to work — that is the documented read-then-re-pass workflow.
    func testBothSpellingsOfThePostalCodeAreAccepted() throws {
        XCTAssertEqual(try parse("zip=60601"), "zip=60601")
        XCTAssertEqual(try parse("postalCode=60601"), "zip=60601")
    }

    /// 🛑 An unrecognised key must be an error, never a dropped field.
    func testAnUnknownKeyIsRefused() {
        XCTAssertThrowsError(try PostalAddress.structured("citty=Chicago")) { error in
            let text = (error as? PostalAddress.ParseError)?.description ?? ""
            XCTAssertTrue(text.contains("citty"), "the error must name the bad key")
        }
    }

    func testAComponentWithNoEqualsIsRefused() {
        XCTAssertThrowsError(try PostalAddress.structured("street=1 Main St;Boulder"))
    }

    func testAnEmptyStructuredValueIsRefused() {
        XCTAssertThrowsError(try PostalAddress.structured(";;"))
    }
}

// MARK: - Choosing between the two

/// 🛑 **The second bug the live probes found, and the worse of the two.**
///
/// `isStructured` first required a *recognised* key. So `citty=Chicago` was not
/// structured, fell through to the free-text parser, and was written as a street
/// reading `citty=Chicago` — with a zero exit code. The `default:` branch that
/// exists to catch a bad key was never reached, because the value never got to
/// the structured parser at all.
final class AddressShapeTests: XCTestCase {

    func testAMisspelledKeyStillReachesTheStructuredParser() {
        XCTAssertTrue(PostalAddress.isStructured("citty=Chicago"),
                      "a typo'd key was silently parsed as free text")
        XCTAssertThrowsError(try PostalAddress.parse("citty=Chicago"))
    }

    func testARecognisedKeyIsStructured() {
        XCTAssertTrue(PostalAddress.isStructured("street=1 Main St;city=Boulder"))
    }

    func testAPlainAddressIsFreeText() {
        XCTAssertFalse(PostalAddress.isStructured("124 Gregory St, Chicago, IL 60601"))
        XCTAssertFalse(PostalAddress.isStructured("PO Box 12"))
    }

    /// ⚠️ A bare `=` is not enough to mean structured. A street can hold one,
    /// and treating it as structured would refuse a perfectly good address.
    func testAnEqualsInsideAStreetIsNotStructured() {
        XCTAssertFalse(PostalAddress.isStructured("Apt 3 = rear, Chicago, IL 60601"))
        XCTAssertNoThrow(try PostalAddress.parse("Apt 3 = rear, Chicago, IL 60601"))
    }

    func testParseRoutesToTheRightShape() throws {
        let structured = try PostalAddress.parse("street=1 Main St;city=Boulder")
        XCTAssertEqual(structured.street, "1 Main St")
        XCTAssertEqual(structured.city, "Boulder")

        let free = try PostalAddress.parse("1 Main St, Boulder, CO 80301")
        XCTAssertEqual(free.street, "1 Main St")
        XCTAssertEqual(free.city, "Boulder")
        XCTAssertEqual(free.state, "CO")
        XCTAssertEqual(free.postalCode, "80301")
    }
}

// MARK: - describe

/// 🛑 `describe` is what the post-write check compares, so a field missing from
/// it is a field whose loss the confirmation cannot see.
final class AddressDescribeTests: XCTestCase {

    func testEveryFieldParseCanSetIsDescribed() throws {
        let all = "street=s;city=c;state=t;zip=z;country=o;"
            + "subLocality=l;subAdministrativeArea=a;isoCountryCode=i"
        let address = try PostalAddress.structured(all)
        let described = PostalAddress.describe(address)
        for field in ["street=s", "city=c", "state=t", "zip=z", "country=o",
                      "sublocality=l", "subadministrativearea=a", "isocountrycode=i"] {
            XCTAssertTrue(described.contains(field),
                          "\(field) is set by parse but missing from describe")
        }
    }

    func testAnEmptyAddressDescribesAsEmpty() {
        XCTAssertEqual(PostalAddress.describe(CNMutablePostalAddress()), "")
    }

    func testDescribeOutputFeedsBackIntoStructured() throws {
        // The read-then-re-pass workflow, on the one field that has two names.
        let original = try PostalAddress.parse("124 Gregory St, Chicago, IL 60601, USA")
        let text = PostalAddress.describe(original)
        let again = try PostalAddress.parse(text)
        XCTAssertEqual(PostalAddress.describe(again), text)
    }
}
