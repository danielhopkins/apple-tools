import Foundation
import SQLite3
import XCTest

@testable import PhoneLibrary

// MARK: - Handle normalisation

final class PhoneNumberTests: XCTestCase {
  /// Every spelling below was observed in a single real `ZADDRESS` column. They
  /// have to collapse to one key or a contact never matches the call it placed.
  func testMatchKeyCollapsesTheShapesRealDataUses() {
    let key = "3035551212"
    XCTAssertEqual(PhoneNumber.matchKey("3035551212"), key)
    XCTAssertEqual(PhoneNumber.matchKey("13035551212"), key)
    XCTAssertEqual(PhoneNumber.matchKey("+13035551212"), key)
    XCTAssertEqual(PhoneNumber.matchKey("+1 (303) 555-1212"), key)
    XCTAssertEqual(PhoneNumber.matchKey("303-555-1212"), key)
    XCTAssertEqual(PhoneNumber.matchKey("303.555.1212"), key)
  }

  func testShortHandlesKeyOnEveryDigit() {
    // A short code must not be padded or truncated into something that could
    // collide with the tail of a real number.
    XCTAssertEqual(PhoneNumber.matchKey("611"), "611")
    XCTAssertEqual(PhoneNumber.matchKey("5551212"), "5551212")
  }

  func testEmailsKeyCaseInsensitively() {
    XCTAssertEqual(PhoneNumber.matchKey("Person@Example.COM"), "person@example.com")
    XCTAssertTrue(PhoneNumber.isEmail("person@example.com"))
    XCTAssertFalse(PhoneNumber.isEmail("+13035551212"))
  }

  func testDisplayPunctuatesNANPAndPassesEverythingElseThrough() {
    XCTAssertEqual(PhoneNumber.display("3035551212"), "(303) 555-1212")
    XCTAssertEqual(PhoneNumber.display("13035551212"), "(303) 555-1212")
    XCTAssertEqual(PhoneNumber.display("+13035551212"), "(303) 555-1212")
    // Unknown length: showing the real value beats inventing a format.
    XCTAssertEqual(PhoneNumber.display("+442071234567"), "+442071234567")
    XCTAssertEqual(PhoneNumber.display("611"), "611")
    XCTAssertEqual(PhoneNumber.display("person@example.com"), "person@example.com")
  }

  func testDialableOnlyAssumesACountryCodeWhenItCan() {
    XCTAssertEqual(PhoneNumber.dialable("3035551212"), "+13035551212")
    XCTAssertEqual(PhoneNumber.dialable("13035551212"), "+13035551212")
    XCTAssertEqual(PhoneNumber.dialable("+442071234567"), "+442071234567")
    // No plus and not a NANP length: pass the digits through rather than
    // guessing a country we do not know.
    XCTAssertEqual(PhoneNumber.dialable("2071234567890"), "2071234567890")
    XCTAssertEqual(PhoneNumber.dialable("611"), "611")
  }
}

// MARK: - The epoch trap

final class CallHistoryEpochTests: XCTestCase {
  /// Call history stores seconds; `chat.db` stores nanoseconds for the same
  /// conceptual column. Reusing one converter for both is off by 10^9, so this
  /// pins the unit.
  func testDateIsAppleEpochSeconds() throws {
    // 2026-08-03 22:57:34 UTC, as seconds since 2001-01-01.
    let raw: Double = 807_490_654
    let date = try XCTUnwrap(CallHistoryEpoch.date(from: raw))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    XCTAssertEqual(parts.year, 2026)
    XCTAssertEqual(parts.month, 8)
    XCTAssertEqual(parts.day, 3)
  }

  func testZeroMeansUnsetRatherThan2001() {
    XCTAssertNil(CallHistoryEpoch.date(from: 0))
  }

  func testRawRoundTrips() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let raw = CallHistoryEpoch.raw(from: now)
    let back = try XCTUnwrap(CallHistoryEpoch.date(from: raw))
    XCTAssertEqual(back.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
  }
}

// MARK: - Dialing

final class DialerTests: XCTestCase {
  func testBuildsTelURLInE164() throws {
    let url = try Dialer.url(for: "303-555-1212")
    XCTAssertEqual(url.absoluteString, "tel:+13035551212")
  }

  func testFaceTimeAudioUsesItsOwnScheme() throws {
    let url = try Dialer.url(for: "3035551212", service: .facetimeAudio)
    XCTAssertEqual(url.absoluteString, "facetime-audio:+13035551212")
    let byEmail = try Dialer.url(for: "person@example.com", service: .facetimeAudio)
    XCTAssertEqual(byEmail.absoluteString, "facetime-audio:person@example.com")
  }

  /// Asserts the *message*, not just that it threw. The first version of this
  /// only checked for a throw and happily passed while the error text was
  /// spliced together wrong and read as nonsense.
  func testRefusesAnEmailOnTelAndSaysWhy() {
    XCTAssertThrowsError(try Dialer.url(for: "person@example.com")) { error in
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("person@example.com"), "got: \(message)")
      XCTAssertTrue(message.contains("--facetime-audio"), "got: \(message)")
      XCTAssertFalse(message.contains("tel:"), "message is spliced wrong: \(message)")
    }
  }

  func testUnroutableSaysWhatItGot() {
    XCTAssertThrowsError(try Dialer.url(for: "12")) { error in
      XCTAssertTrue(error.localizedDescription.contains("'12'"), "got: \(error)")
    }
  }

  /// Dialing a typo is not recoverable, so anything too short to be a real
  /// target is refused rather than dialed.
  func testRefusesSomethingTooShortToBeANumber() {
    XCTAssertThrowsError(try Dialer.url(for: "12"))
    XCTAssertThrowsError(try Dialer.url(for: ""))
    XCTAssertThrowsError(try Dialer.url(for: "   "))
  }

  func testShortCodesAreAllowed() throws {
    XCTAssertEqual(try Dialer.url(for: "611").absoluteString, "tel:611")
  }
}

// MARK: - Block list

final class BlockListTests: XCTestCase {
  private func writeFixture(_ items: [[String: Any]], revision: Int) throws -> URL {
    let root: [String: Any] = [
      "__kCMFBlockListStoreTopLevelKey": [
        "__kCMFBlockListStoreArrayKey": items,
        "__kCMFBlockListStoreRevisionKey": revision,
        "__kCMFBlockListStoreRevisionTimestampKey": Date(timeIntervalSince1970: 1_749_766_000),
        "__kCMFBlockListStoreVersionKey": 1,
      ]
    ]
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("blocklist-\(UUID().uuidString).plist")
    let data = try PropertyListSerialization.data(
      fromPropertyList: root, format: .binary, options: 0)
    try data.write(to: url)
    return url
  }

  func testParsesTheRealPlistShape() throws {
    let url = try writeFixture(
      [
        [
          "__kCMFItemPhoneNumberCountryCodeKey": "us",
          "__kCMFItemPhoneNumberUnformattedKey": "+13035551212",
          "__kCMFItemTypeKey": 0,
          "__kCMFItemVersionKey": 1,
        ],
        [
          "__kCMFItemPhoneNumberCountryCodeKey": "us",
          "__kCMFItemPhoneNumberUnformattedKey": "+17205559999",
          "__kCMFItemTypeKey": 0,
          "__kCMFItemVersionKey": 1,
        ],
      ], revision: 25)
    defer { try? FileManager.default.removeItem(at: url) }

    setenv("APPLE_PHONE_BLOCKLIST_PATH", url.path, 1)
    defer { unsetenv("APPLE_PHONE_BLOCKLIST_PATH") }

    let list = BlockList.load()
    XCTAssertTrue(list.isAvailable)
    XCTAssertEqual(list.items.count, 2)
    XCTAssertEqual(list.revision, 25)
    XCTAssertNotNil(list.revisionDate)
    XCTAssertEqual(list.items.first?.kind, .phone)

    // Matching has to survive the store's inconsistent formatting: the block
    // list keeps E.164 while ZADDRESS may hold bare digits for the same number.
    XCTAssertTrue(list.isBlocked("+13035551212"))
    XCTAssertTrue(list.isBlocked("3035551212"))
    XCTAssertTrue(list.isBlocked("13035551212"))
    XCTAssertFalse(list.isBlocked("3035550000"))
  }

  func testAMissingPlistIsEmptyRatherThanAnError() {
    setenv("APPLE_PHONE_BLOCKLIST_PATH", "/nonexistent/cmf.plist", 1)
    defer { unsetenv("APPLE_PHONE_BLOCKLIST_PATH") }

    let list = BlockList.load()
    XCTAssertTrue(list.items.isEmpty)
    XCTAssertFalse(list.isAvailable)
    XCTAssertFalse(list.isBlocked("3035551212"))
  }
}

// MARK: - Contact resolution failing

/// The three availability states must stay distinguishable. "Every caller is
/// unknown" is the right answer for an empty address book and a wrong one when
/// the store could not be opened, and nothing downstream can tell them apart
/// from the result alone.
final class ContactAvailabilityTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("addressbook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("APPLE_PHONE_ADDRESSBOOK_DIR", directory.path, 1)
  }

  override func tearDownWithError() throws {
    unsetenv("APPLE_PHONE_ADDRESSBOOK_DIR")
    try? FileManager.default.removeItem(at: directory)
  }

  func testNoAddressBookIsNotAGrantProblem() {
    // Directory exists but holds no store at all.
    let contacts = ContactDirectory.load()
    XCTAssertEqual(contacts.availability, .noAddressBook)
    XCTAssertFalse(contacts.isAvailable)
    XCTAssertEqual(contacts.count, 0)
    XCTAssertNil(contacts.lookup("+13035551212"))
  }

  func testAStoreThatWillNotOpenIsReportedAsUnreadable() throws {
    // A file in the right place that is not a database stands in for the one
    // Full Disk Access would otherwise refuse to open.
    let store = directory.appendingPathComponent("AddressBook-v22.abcddb")
    try Data("not a database".utf8).write(to: store)

    let contacts = ContactDirectory.load()
    XCTAssertEqual(contacts.availability, .unreadable)
    XCTAssertFalse(contacts.isAvailable)
    // The distinction that matters: unreadable, not simply empty.
    XCTAssertNotEqual(contacts.availability, .noAddressBook)
  }

  /// sqlite accepts a zero- or one-byte file as a valid *empty* database, so a
  /// truncated store answers queries against `sqlite_master` without complaint.
  /// Checked separately because it is the case that silently reported every
  /// caller as unknown before the probe looked for the schema instead.
  func testATruncatedStoreIsUnreadableNotEmpty() throws {
    let store = directory.appendingPathComponent("AddressBook-v22.abcddb")

    for bytes in [Data(), Data("x".utf8)] {
      try bytes.write(to: store)
      let contacts = ContactDirectory.load()
      XCTAssertEqual(
        contacts.availability, .unreadable,
        "a \(bytes.count)-byte file is an empty sqlite database, not an address book")
      XCTAssertFalse(contacts.isAvailable)
    }
  }

  func testFindByNameReturnsNothingRatherThanCrashingWhenUnavailable() {
    let contacts = ContactDirectory.load()
    XCTAssertTrue(contacts.findByName("Margot").isEmpty)
  }

  /// Call history has to keep working with no contacts at all — only names go
  /// missing. This is the whole reason resolution is a separate store.
  func testCallHistoryStillReadsWithoutContacts() throws {
    let fixture = try CallStoreFixture()
    defer { fixture.tearDown() }

    let store = try CallStore()
    XCTAssertEqual(store.contactAvailability, .noAddressBook)
    let calls = try store.recents(RecentsRequest())
    XCTAssertEqual(calls.count, 6)
    XCTAssertFalse(calls.contains { $0.isKnown })
    // Numbers are still shown, and still punctuated.
    XCTAssertEqual(calls.first?.who, "(303) 555-1212")
  }
}

// MARK: - Resolving names out of the address book

/// Builds address book sources with the columns `ContactDirectory` reads, so
/// resolution can be tested without depending on whose Mac is running it.
final class ContactDirectoryTests: XCTestCase {
  private var root: URL!
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private struct Person {
    var uniqueID: String
    var first: String?
    var last: String?
    var organization: String?
    var phones: [(String, Bool)] = []  // value, isPrimary
    var emails: [String] = []
  }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ab-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    setenv("APPLE_PHONE_ADDRESSBOOK_DIR", root.path, 1)
  }

  override func tearDownWithError() throws {
    unsetenv("APPLE_PHONE_ADDRESSBOOK_DIR")
    try? FileManager.default.removeItem(at: root)
  }

  /// One source database under `Sources/<name>/`, as a real address book lays out.
  private func addSource(_ name: String, people: [Person]) throws {
    let dir = root.appendingPathComponent("Sources/\(name)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("AddressBook-v22.abcddb").path

    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
    else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close_v2(handle) }

    let schema = """
      CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZUNIQUEID VARCHAR,
        ZFIRSTNAME VARCHAR, ZLASTNAME VARCHAR, ZNICKNAME VARCHAR, ZORGANIZATION VARCHAR);
      CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER,
        ZFULLNUMBER VARCHAR, ZISPRIMARY INTEGER, ZORDERINGINDEX INTEGER);
      CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER,
        ZADDRESS VARCHAR, ZISPRIMARY INTEGER, ZORDERINGINDEX INTEGER);
      """
    guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
      throw CocoaError(.fileWriteUnknown)
    }

    func exec(_ sql: String, _ text: [String?], _ ints: [Int64]) throws {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
      }
      defer { sqlite3_finalize(statement) }
      var index: Int32 = 1
      for value in text {
        if let value {
          sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
          sqlite3_bind_null(statement, index)
        }
        index += 1
      }
      for value in ints {
        sqlite3_bind_int64(statement, index, value)
        index += 1
      }
      guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    for (offset, person) in people.enumerated() {
      let pk = Int64(offset + 1)
      try exec(
        "INSERT INTO ZABCDRECORD (ZUNIQUEID, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, Z_PK) "
          + "VALUES (?, ?, ?, ?, ?)",
        [person.uniqueID, person.first, person.last, person.organization], [pk])
      for (order, phone) in person.phones.enumerated() {
        try exec(
          "INSERT INTO ZABCDPHONENUMBER (ZFULLNUMBER, ZOWNER, ZISPRIMARY, ZORDERINGINDEX) "
            + "VALUES (?, ?, ?, ?)",
          [phone.0], [pk, phone.1 ? 1 : 0, Int64(order)])
      }
      for (order, email) in person.emails.enumerated() {
        try exec(
          "INSERT INTO ZABCDEMAILADDRESS (ZADDRESS, ZOWNER, ZISPRIMARY, ZORDERINGINDEX) "
            + "VALUES (?, ?, ?, ?)",
          [email], [pk, 0, Int64(order)])
      }
    }
  }

  /// 🛑 The regression that this suite exists for.
  ///
  /// Contacts leaves a multi-megabyte write-ahead log behind, and `immutable=1`
  /// tells sqlite the file cannot change — so it does not replay that log. A
  /// contact added minutes ago lives only there, and resolution missed it while
  /// reporting the caller as plainly "unknown".
  ///
  /// Reproduced by holding the writer connection open, which stops sqlite
  /// checkpointing the WAL into the main file on close. That is exactly the state
  /// a running Contacts.app leaves the store in.
  func testSeesContactsThatAreStillOnlyInTheWriteAheadLog() throws {
    let dir = root.appendingPathComponent("Sources/W")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("AddressBook-v22.abcddb").path

    var writer: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
    // Deliberately NOT closed until the assertions are done.
    defer { sqlite3_close_v2(writer) }

    let setup = """
      PRAGMA journal_mode=WAL;
      CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZUNIQUEID VARCHAR,
        ZFIRSTNAME VARCHAR, ZLASTNAME VARCHAR, ZNICKNAME VARCHAR, ZORGANIZATION VARCHAR);
      CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER,
        ZFULLNUMBER VARCHAR, ZISPRIMARY INTEGER, ZORDERINGINDEX INTEGER);
      CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER,
        ZADDRESS VARCHAR, ZISPRIMARY INTEGER, ZORDERINGINDEX INTEGER);
      INSERT INTO ZABCDRECORD (Z_PK, ZUNIQUEID, ZFIRSTNAME, ZLASTNAME)
        VALUES (1, 'NEW:ABPerson', 'Ahmed', 'Jamil');
      INSERT INTO ZABCDPHONENUMBER (ZOWNER, ZFULLNUMBER, ZISPRIMARY, ZORDERINGINDEX)
        VALUES (1, '+13122969659', 1, 0);
      """
    XCTAssertEqual(sqlite3_exec(writer, setup, nil, nil, nil), SQLITE_OK)

    // A WAL really is present and holding the rows.
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: path + "-wal"),
      "test cannot prove anything without an un-checkpointed WAL")

    let contacts = ContactDirectory.load()
    XCTAssertEqual(contacts.availability, .available)
    XCTAssertEqual(
      contacts.lookup("+13122969659")?.name, "Ahmed Jamil",
      "immutable=1 would skip the WAL and miss this contact entirely")
    XCTAssertEqual(contacts.findByName("Ahmed").count, 1)
    // Nothing had to fall back, so no source is flagged stale.
    XCTAssertEqual(contacts.staleSources, 0)
  }

  func testResolvesANumberToAName() throws {
    try addSource(
      "A",
      people: [
        Person(
          uniqueID: "AAA:ABPerson", first: "Margot", last: "Hopkins",
          phones: [("+17655551212", true)])
      ])

    let contacts = ContactDirectory.load()
    XCTAssertEqual(contacts.availability, .available)
    // However the call history spelled it.
    XCTAssertEqual(contacts.lookup("+17655551212")?.name, "Margot Hopkins")
    XCTAssertEqual(contacts.lookup("7655551212")?.name, "Margot Hopkins")
    XCTAssertEqual(contacts.lookup("17655551212")?.name, "Margot Hopkins")
    XCTAssertNil(contacts.lookup("+13035550000"))
  }

  /// A FaceTime call's handle is an Apple ID, so emails have to be indexed too
  /// or those rows never resolve.
  func testResolvesAnAppleIDToAName() throws {
    try addSource(
      "A",
      people: [
        Person(uniqueID: "AAA:ABPerson", first: "Cat", last: "Cantor", emails: ["cat@example.com"])
      ])

    let contacts = ContactDirectory.load()
    XCTAssertEqual(contacts.lookup("cat@example.com")?.name, "Cat Cantor")
    XCTAssertEqual(contacts.lookup("Cat@Example.COM")?.name, "Cat Cantor")
  }

  func testFallsBackToCompanyWhenThereIsNoPersonalName() throws {
    try addSource(
      "A",
      people: [
        Person(
          uniqueID: "AAA:ABPerson", first: nil, last: nil,
          organization: "Boulder Medical Center", phones: [("+13035554444", false)])
      ])

    let contacts = ContactDirectory.load()
    XCTAssertEqual(contacts.lookup("3035554444")?.name, "Boulder Medical Center")
  }

  func testFindByNameIsAnAndOfTerms() throws {
    try addSource(
      "A",
      people: [
        Person(
          uniqueID: "A1:ABPerson", first: "Margot", last: "Hopkins",
          phones: [("+17655551212", true)]),
        Person(
          uniqueID: "A2:ABPerson", first: "Stephanie", last: "Hopkins",
          phones: [("+13035551212", true)]),
      ])

    let contacts = ContactDirectory.load()
    XCTAssertEqual(contacts.findByName("margot hop").map(\.name), ["Margot Hopkins"])
    // A surname alone is genuinely ambiguous, and the caller decides what to do.
    XCTAssertEqual(Set(contacts.findByName("hopkins").map(\.name)).count, 2)
    XCTAssertTrue(contacts.findByName("nobody").isEmpty)
    // Phones and emails are separate namespaces.
    XCTAssertTrue(contacts.findByName("margot", email: true).isEmpty)
  }

  /// The same person routinely exists as separate cards in more than one source
  /// — iCloud and "On My Mac". Grouping candidates by contact id reported that as
  /// "matches more than one contact" while listing a single name, which is not an
  /// answer anyone can act on. What matters is the set of distinct *numbers*.
  func testDuplicateCardsAcrossSourcesAreOnePerson() throws {
    let person = Person(
      uniqueID: "ICLOUD:ABPerson", first: "Cat", last: "Cantor",
      phones: [("+17204808645", true)])
    try addSource("A", people: [person])
    try addSource(
      "B",
      people: [
        Person(
          uniqueID: "LOCAL:ABPerson", first: "Cat", last: "Cantor",
          phones: [("(720) 480-8645", false)])
      ])

    let contacts = ContactDirectory.load()
    let matches = contacts.findByName("Cat Cantor")
    // Two cards, two rows...
    XCTAssertEqual(matches.count, 2)
    XCTAssertEqual(Set(matches.map(\.contactID)).count, 2)
    // ...one name, and one number once normalised. That is what makes it
    // resolvable rather than ambiguous.
    XCTAssertEqual(Set(matches.map(\.name)), ["Cat Cantor"])
    XCTAssertEqual(Set(matches.map { PhoneNumber.matchKey($0.value) }).count, 1)
  }
}

// MARK: - The store, against a synthetic database

/// Builds a `ZCALLRECORD` matching the real column types — `ZDATE` and
/// `ZDURATION` as REAL, everything else as observed — so these tests exercise
/// the same coercion rules the real store does. In particular the float `ZDATE`
/// is what makes a text date bound into a comparison match nothing.
/// A synthetic call history plus block list, wired up through the environment
/// overrides and torn down afterwards. Shared so the resolution-failure tests
/// can reuse the same six calls.
final class CallStoreFixture {
  let databaseURL: URL
  let blockListURL: URL

  /// Text binds below MUST be transient. Passing `nil` as the destructor means
  /// SQLITE_STATIC, which tells sqlite not to copy — but the pointer a Swift
  /// String bridges to is only valid for the duration of the call, so every
  /// address landed in the fixture as garbage. The failure was invisible in the
  /// rows that ignore ZADDRESS and looked like broken search everywhere else.
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private struct Row {
    var pk: Int64
    var daysAgo: Double
    var duration: Double
    var originated: Int64
    var answered: Int64
    var callType: Int64
    var address: String
    var location: String?
    var provider: String
  }

  init() throws {
    databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("callhistory-\(UUID().uuidString).storedata")

    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(
        databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close_v2(handle) }

    let schema = """
      CREATE TABLE ZCALLRECORD (
        Z_PK INTEGER PRIMARY KEY, ZDATE TIMESTAMP, ZDURATION FLOAT,
        ZORIGINATED INTEGER, ZANSWERED INTEGER, ZCALLTYPE INTEGER,
        ZADDRESS VARCHAR, ZNAME VARCHAR, ZLOCATION VARCHAR,
        ZSERVICE_PROVIDER VARCHAR, ZREAD INTEGER, ZJUNKCONFIDENCE INTEGER,
        ZJUNKIDENTIFICATIONCATEGORY VARCHAR, ZBLOCKEDBYEXTENSIONNAME VARCHAR,
        ZORIGINATINGDEVICENAME VARCHAR, ZWASEMERGENCYCALL INTEGER);
      """
    guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
      throw CocoaError(.fileWriteUnknown)
    }

    let rows = [
      // Outgoing, connected.
      Row(
        pk: 1, daysAgo: 0.2, duration: 57, originated: 1, answered: 0, callType: 1,
        address: "+13035551212", location: "Denver, CO", provider: "com.apple.Telephony"),
      // Outgoing that rang out — ZANSWERED is 0 here too, which is exactly why
      // "answered" cannot be used to mean "connected".
      Row(
        pk: 2, daysAgo: 1.0, duration: 0, originated: 1, answered: 0, callType: 1,
        address: "3035551212", location: "Denver, CO", provider: "com.apple.Telephony"),
      // Incoming, answered.
      Row(
        pk: 3, daysAgo: 2.0, duration: 451, originated: 0, answered: 1, callType: 1,
        address: "7205559999", location: "Boulder, CO", provider: "com.apple.Telephony"),
      // Missed.
      Row(
        pk: 4, daysAgo: 3.0, duration: 0, originated: 0, answered: 0, callType: 1,
        address: "+17205558888", location: "Fort Lupton, CO", provider: "com.apple.Telephony"),
      // FaceTime audio to an Apple ID.
      Row(
        pk: 5, daysAgo: 10.0, duration: 120, originated: 1, answered: 0, callType: 8,
        address: "person@example.com", location: nil, provider: "com.apple.FaceTime"),
      // FaceTime video, and old enough to fall outside a --since 7 window.
      Row(
        pk: 6, daysAgo: 40.0, duration: 900, originated: 0, answered: 1, callType: 16,
        address: "+13035554444", location: nil, provider: "com.apple.FaceTime"),
    ]

    let now = Date()
    for row in rows {
      let date = now.addingTimeInterval(-row.daysAgo * 86400)
      let sql = """
        INSERT INTO ZCALLRECORD
          (Z_PK, ZDATE, ZDURATION, ZORIGINATED, ZANSWERED, ZCALLTYPE, ZADDRESS,
           ZLOCATION, ZSERVICE_PROVIDER, ZREAD, ZJUNKCONFIDENCE, ZWASEMERGENCYCALL)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, 0);
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
      }
      sqlite3_bind_int64(statement, 1, row.pk)
      sqlite3_bind_double(statement, 2, CallHistoryEpoch.raw(from: date))
      sqlite3_bind_double(statement, 3, row.duration)
      sqlite3_bind_int64(statement, 4, row.originated)
      sqlite3_bind_int64(statement, 5, row.answered)
      sqlite3_bind_int64(statement, 6, row.callType)
      sqlite3_bind_text(statement, 7, row.address, -1, Self.transient)
      if let location = row.location {
        sqlite3_bind_text(statement, 8, location, -1, Self.transient)
      } else {
        sqlite3_bind_null(statement, 8)
      }
      sqlite3_bind_text(statement, 9, row.provider, -1, Self.transient)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        sqlite3_finalize(statement)
        throw CocoaError(.fileWriteUnknown)
      }
      sqlite3_finalize(statement)
    }

    // A fixture block list, so `blocked` does not depend on the real machine.
    let root: [String: Any] = [
      "__kCMFBlockListStoreTopLevelKey": [
        "__kCMFBlockListStoreArrayKey": [
          [
            "__kCMFItemPhoneNumberCountryCodeKey": "us",
            "__kCMFItemPhoneNumberUnformattedKey": "+17205558888",
            "__kCMFItemTypeKey": 0,
          ]
        ],
        "__kCMFBlockListStoreRevisionKey": 3,
      ]
    ]
    blockListURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("blocklist-\(UUID().uuidString).plist")
    try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
      .write(to: blockListURL)

    setenv("APPLE_PHONE_DB_PATH", databaseURL.path, 1)
    setenv("APPLE_PHONE_BLOCKLIST_PATH", blockListURL.path, 1)
  }

  func tearDown() {
    unsetenv("APPLE_PHONE_DB_PATH")
    unsetenv("APPLE_PHONE_BLOCKLIST_PATH")
    try? FileManager.default.removeItem(at: databaseURL)
    try? FileManager.default.removeItem(at: blockListURL)
  }
}

/// Reads the fixture above through the real `CallStore`.
final class CallStoreTests: XCTestCase {
  private var fixture: CallStoreFixture!

  override func setUpWithError() throws {
    fixture = try CallStoreFixture()
  }

  override func tearDownWithError() throws {
    fixture.tearDown()
    fixture = nil
  }

  /// Contacts resolution is off throughout: it would read the real address book
  /// and make these assertions depend on whose Mac is running them.
  private func store() throws -> CallStore {
    try CallStore(resolveContacts: false)
  }

  func testReadsEveryRowNewestFirst() throws {
    let calls = try store().recents(RecentsRequest())
    XCTAssertEqual(calls.count, 6)
    XCTAssertEqual(calls.map(\.id), [1, 2, 3, 4, 5, 6])
  }

  func testDerivesStatusFromTheTwoFlags() throws {
    let calls = try store().recents(RecentsRequest())
    let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })

    XCTAssertEqual(byID[1]?.status, .outgoing)
    XCTAssertEqual(byID[2]?.status, .outgoing)
    XCTAssertEqual(byID[3]?.status, .incoming)
    XCTAssertEqual(byID[4]?.status, .missed)

    // The distinction `status` alone cannot express: both are outgoing, only one
    // reached the other end.
    XCTAssertTrue(byID[1]?.connected == true)
    XCTAssertTrue(byID[2]?.connected == false)
  }

  func testMapsCallTypeToKind() throws {
    let calls = try store().recents(RecentsRequest())
    let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })
    XCTAssertEqual(byID[1]?.kind, .phone)
    XCTAssertEqual(byID[5]?.kind, .facetimeAudio)
    XCTAssertEqual(byID[6]?.kind, .facetimeVideo)
  }

  /// The regression that matters most. `ZDATE` is a REAL, so a date bound as the
  /// text `strftime('%s', ...)` returns matches zero rows — no error, just an
  /// empty list that reads exactly like "no calls". Binding a double is what
  /// makes `--since` work at all.
  func testSinceFiltersInsteadOfSilentlyMatchingNothing() throws {
    var request = RecentsRequest()
    request.sinceDays = 7
    let recent = try store().recents(request)

    XCTAssertFalse(recent.isEmpty, "a REAL ZDATE compared against text matches nothing")
    XCTAssertEqual(recent.map(\.id), [1, 2, 3, 4])
    XCTAssertFalse(recent.contains { $0.id == 6 }, "the 40-day-old call is outside --since 7")
  }

  func testBeforeIsTheComplementOfSince() throws {
    var request = RecentsRequest()
    request.beforeDays = 7
    XCTAssertEqual(try store().recents(request).map(\.id), [5, 6])
  }

  func testDirectionFilters() throws {
    var missed = RecentsRequest()
    missed.missedOnly = true
    XCTAssertEqual(try store().recents(missed).map(\.id), [4])

    var outgoing = RecentsRequest()
    outgoing.outgoingOnly = true
    XCTAssertEqual(try store().recents(outgoing).map(\.id), [1, 2, 5])

    var incoming = RecentsRequest()
    incoming.incomingOnly = true
    // Incoming means received; a missed call is not one you took.
    XCTAssertEqual(try store().recents(incoming).map(\.id), [3, 6])
  }

  func testKindFilter() throws {
    var request = RecentsRequest()
    request.kind = .facetimeAudio
    XCTAssertEqual(try store().recents(request).map(\.id), [5])
  }

  func testHandleFilterIgnoresFormatting() throws {
    // Rows 1 and 2 are the same number written two different ways, which is
    // exactly what a real store contains.
    var request = RecentsRequest()
    request.handle = "(303) 555-1212"
    XCTAssertEqual(try store().recents(request).map(\.id), [1, 2])
  }

  func testBlockedFlagComesFromTheBlockList() throws {
    let calls = try store().recents(RecentsRequest())
    let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })
    XCTAssertTrue(byID[4]?.isBlocked == true)
    XCTAssertTrue(byID[1]?.isBlocked == false)

    var request = RecentsRequest()
    request.blockedOnly = true
    XCTAssertEqual(try store().recents(request).map(\.id), [4])
  }

  func testSearchMatchesDigitsThroughPunctuation() throws {
    var request = RecentsRequest()
    request.query = "303-555-1212"
    XCTAssertEqual(try store().recents(request).map(\.id), [1, 2])
  }

  func testSearchMatchesLocationAndIsAnAndOfTerms() throws {
    var byPlace = RecentsRequest()
    byPlace.query = "denver"
    XCTAssertEqual(try store().recents(byPlace).map(\.id), [1, 2])

    // Both terms must appear; "boulder" only ever coincides with row 3.
    var both = RecentsRequest()
    both.query = "denver boulder"
    XCTAssertTrue(try store().recents(both).isEmpty)
  }

  /// A limit applied before a post-SQL filter would return too few rows. Row 4
  /// is the only blocked call and it is fourth by date, so a limit of 2 pushed
  /// into SQL would drop it and report nothing.
  func testLimitAppliesAfterFiltersThatNeedResolvedData() throws {
    var request = RecentsRequest()
    request.blockedOnly = true
    request.limit = 2
    XCTAssertEqual(try store().recents(request).map(\.id), [4])
  }

  func testLimitStillTruncates() throws {
    var request = RecentsRequest()
    request.limit = 3
    XCTAssertEqual(try store().recents(request).map(\.id), [1, 2, 3])
  }

  func testStatistics() throws {
    let stats = try store().statistics(RecentsRequest())
    XCTAssertEqual(stats.total, 6)
    XCTAssertEqual(stats.outgoing, 3)
    XCTAssertEqual(stats.incoming, 2)
    XCTAssertEqual(stats.missed, 1)
    XCTAssertEqual(stats.talkTime, 57 + 451 + 120 + 900)
    XCTAssertEqual(stats.longest?.id, 6)
    XCTAssertEqual(stats.byKind.reduce(0) { $0 + $1.count }, 6)
  }

  func testMissingDatabaseIsReportedAsSuchNotAsAMissingGrant() {
    setenv("APPLE_PHONE_DB_PATH", "/nonexistent/CallHistory.storedata", 1)
    defer { setenv("APPLE_PHONE_DB_PATH", fixture.databaseURL.path, 1) }

    XCTAssertThrowsError(try CallHistoryDatabase.open()) { error in
      // The override is named in the message so an unreadable override can
      // never be mistaken for Full Disk Access being absent.
      XCTAssertTrue(
        error.localizedDescription.contains("APPLE_PHONE_DB_PATH"),
        "got: \(error.localizedDescription)")
    }
  }
}
