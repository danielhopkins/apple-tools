import Foundation
import SQLite3
import XCTest

@testable import MapsLibrary

// MARK: - Fixture

/// A MapsSync store built from scratch, so these tests never touch the real one
/// and run with Maps.app closed, offline, on a machine with no history at all.
///
/// The schema below is copied from a real `MapsSync_0.0.1`, trimmed to the
/// columns the library reads. The traps being pinned are all in the *data*:
/// NULL `ZHIDDEN`, locations with no visit, guide items in no guide.
final class MapsFixture {
  let url: URL
  private let directory: URL

  init(name: String = "maps-fixture") throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("apple-tools-maps-tests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent(name)

    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
      throw MapsStoreError.unavailable("could not create the fixture store")
    }
    defer { sqlite3_close_v2(db) }
    try Self.exec(db, Self.schema)
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  func run(_ sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
      throw MapsStoreError.unavailable("could not reopen the fixture store")
    }
    defer { sqlite3_close_v2(db) }
    try Self.exec(db, sql)
  }

  func database() throws -> MapsDatabase { try MapsDatabase(path: url) }
  func visits() throws -> VisitStore { VisitStore(database: try database()) }
  func guides() throws -> GuideStore { GuideStore(database: try database()) }

  private static func exec(_ db: OpaquePointer, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(error)
      throw MapsStoreError.query(message)
    }
  }

  static let schema = """
    CREATE TABLE ZVISIT (
      Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZHIDDEN INTEGER,
      ZVISITCLASSIFICATION INTEGER, ZLOCATION INTEGER, ZCREATETIME TIMESTAMP,
      ZMODIFICATIONTIME TIMESTAMP, ZSTARTDATE TIMESTAMP, ZIDENTIFIER BLOB);
    CREATE TABLE ZVISITEDLOCATION (
      Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZENCLOSINGREGIONMUID INTEGER,
      ZENCLOSINGREGIONPROVIDER INTEGER, ZHIDDEN INTEGER, ZMAPITEMTOPLEVELCATEGORY INTEGER,
      ZMUID INTEGER, ZCREATETIME TIMESTAMP, ZLATESTVISITDATE TIMESTAMP, ZLATITUDE FLOAT,
      ZLONGITUDE FLOAT, ZMAPITEMLASTREFRESHED TIMESTAMP, ZMODIFICATIONTIME TIMESTAMP,
      ZMAPITEMADDRESS VARCHAR, ZMAPITEMCATEGORY VARCHAR, ZMAPITEMCITY VARCHAR,
      ZMAPITEMIDENTIFIER VARCHAR, ZMAPITEMNAME VARCHAR, ZIDENTIFIER BLOB, ZMAPITEMSTORAGE BLOB);
    CREATE TABLE ZCOLLECTION (
      Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZPLACESCOUNT INTEGER,
      ZPOSITIONINDEX INTEGER, ZCREATETIME TIMESTAMP, ZMODIFICATIONTIME TIMESTAMP,
      ZCOLLECTIONDESCRIPTION VARCHAR, ZIMAGEURL VARCHAR, ZTITLE VARCHAR, ZIDENTIFIER BLOB,
      ZIMAGE BLOB);
    CREATE TABLE ZCOLLECTIONITEM (
      Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZPOSITIONINDEX INTEGER,
      ZDROPPEDPINFLOORORDINAL INTEGER, ZMUID INTEGER, ZORIGIN INTEGER, ZTYPE INTEGER,
      ZMAPITEM INTEGER, ZMUID1 INTEGER, ZCREATETIME TIMESTAMP, ZMODIFICATIONTIME TIMESTAMP,
      ZLATITUDE FLOAT, ZLONGITUDE FLOAT, ZMAPITEMLASTREFRESHED TIMESTAMP, ZCUSTOMNAME VARCHAR,
      ZMAPITEMADDRESS VARCHAR, ZMAPITEMCATEGORY VARCHAR, ZMAPITEMNAME VARCHAR,
      ZPLACEITEMNOTE VARCHAR, ZIDENTIFIER BLOB, ZORIGINALIDENTIFIER BLOB,
      ZDROPPEDPINCOORDINATE BLOB, ZTRANSITLINESTORAGE BLOB);
    CREATE TABLE Z_7PLACES (
      Z_7COLLECTIONS INTEGER, Z_8PLACES INTEGER, PRIMARY KEY (Z_7COLLECTIONS, Z_8PLACES));
    """

  /// Apple-epoch seconds for a date N days before a fixed "now".
  static func daysAgo(_ days: Double) -> Double {
    MapsEpoch.raw(from: Date().addingTimeInterval(-days * 86_400))
  }
}

// MARK: - The epoch trap

final class MapsEpochTests: XCTestCase {
  /// MapsSync stores seconds. `chat.db` stores nanoseconds for the same
  /// conceptual column, and call history stores seconds. Reusing one converter
  /// across all three is off by 10^9 for one of them, so this pins the unit.
  func testDateIsAppleEpochSeconds() throws {
    // 2026-08-05 22:02:00 UTC, as seconds since 2001-01-01.
    let raw: Double = 807_660_120
    let date = try XCTUnwrap(MapsEpoch.date(from: raw))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    XCTAssertEqual(parts.year, 2026)
    XCTAssertEqual(parts.month, 8)
    XCTAssertEqual(parts.day, 5)
  }

  func testZeroMeansUnsetRatherThan2001() {
    XCTAssertNil(MapsEpoch.date(from: 0))
  }

  func testRawRoundTrips() throws {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let raw = MapsEpoch.raw(from: date)
    let back = try XCTUnwrap(MapsEpoch.date(from: raw))
    XCTAssertEqual(back.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
  }
}

// MARK: - Column decoding

final class MapsColumnTests: XCTestCase {
  /// Categories arrive as one `||`-joined string, most specific first. Not
  /// splitting them turns a category filter into a substring grep over an
  /// unrelated category's name.
  func testCategoriesSplitOnDoublePipe() {
    let raw = "Dining||American Cuisine||Breakfast and Brunch Restaurant||Restaurant"
    XCTAssertEqual(
      MapsColumn.categories(raw),
      ["Dining", "American Cuisine", "Breakfast and Brunch Restaurant", "Restaurant"])
  }

  func testASingleCategoryIsStillAList() {
    XCTAssertEqual(MapsColumn.categories("Park"), ["Park"])
    XCTAssertEqual(MapsColumn.categories(""), [])
    XCTAssertEqual(MapsColumn.categories(nil), [])
  }

  /// Maps stores every stable id as a 16-byte UUID blob, not as text. Rendering
  /// it is what makes an id comparable across devices.
  func testUUIDBlobDecodesToAUUIDString() {
    var bytes: [UInt8] = [
      0x4B, 0x04, 0xA7, 0xAA, 0x51, 0xD3, 0x48, 0xF5,
      0x94, 0xDA, 0x58, 0x60, 0x7D, 0xBB, 0x41, 0xA3,
    ]
    XCTAssertEqual(
      MapsColumn.uuid(Data(bytes)), "4B04A7AA-51D3-48F5-94DA-58607DBB41A3")

    // Anything that is not exactly 16 bytes is not an identifier, and guessing
    // one from a short blob would produce a plausible wrong id.
    bytes.removeLast()
    XCTAssertNil(MapsColumn.uuid(Data(bytes)))
    XCTAssertNil(MapsColumn.uuid("not a blob"))
    XCTAssertNil(MapsColumn.uuid(nil))
  }
}

// MARK: - Opening the store

final class MapsDatabaseTests: XCTestCase {
  /// 🛑 Opening a SQLite file validates nothing, and sqlite treats a 0-byte file
  /// as a valid empty database. Without a schema probe a truncated store reads
  /// as "opened fine, you have never been anywhere".
  func testAnEmptyFileIsRefusedRatherThanReadAsAnEmptyHistory() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("apple-tools-maps-empty-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: path.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: path) }

    XCTAssertThrowsError(try MapsDatabase(path: path)) { error in
      XCTAssertTrue(
        "\(error)".contains("not a Maps store"),
        "an unusable store must say so, not report an empty history: \(error)")
    }
  }

  func testAValidFixtureOpens() throws {
    let fixture = try MapsFixture()
    let database = try fixture.database()
    XCTAssertFalse(database.isStale)
  }
}

// MARK: - Visits

final class VisitStoreTests: XCTestCase {
  /// 🛑 `ZHIDDEN` is NULL on every row of a real store — 440 of 440 visits and
  /// 314 of 314 locations. So `ZHIDDEN = 0` matches nothing and the command
  /// returns an empty history, which reads exactly like "you have never been
  /// anywhere". Only `IS NOT 1` covers NULL and 0 together.
  func testNullHiddenRowsAreVisible() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZHIDDEN, ZMAPITEMNAME, ZLATITUDE, ZLONGITUDE)
        VALUES (1, NULL, 'Ocean First', 40.0, -105.2);
      INSERT INTO ZVISIT (Z_PK, ZHIDDEN, ZLOCATION, ZSTARTDATE)
        VALUES (1, NULL, 1, \(MapsFixture.daysAgo(1)));
      """)

    let places = try fixture.visits().places()
    XCTAssertEqual(places.count, 1, "a NULL ZHIDDEN must not filter the row out")
    XCTAssertEqual(places.first?.name, "Ocean First")
    XCTAssertEqual(try fixture.visits().visits().count, 1)
  }

  /// A row that really is hidden stays hidden, on either table.
  func testExplicitlyHiddenRowsAreExcluded() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZHIDDEN, ZMAPITEMNAME) VALUES (1, 1, 'Hidden Place');
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZHIDDEN, ZMAPITEMNAME) VALUES (2, 0, 'Shown Place');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (1, 1, \(MapsFixture.daysAgo(1)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (2, 2, \(MapsFixture.daysAgo(1)));
      INSERT INTO ZVISIT (Z_PK, ZHIDDEN, ZLOCATION, ZSTARTDATE)
        VALUES (3, 1, 2, \(MapsFixture.daysAgo(2)));
      """)

    let places = try fixture.visits().places()
    XCTAssertEqual(places.map(\.name), ["Shown Place"])
    XCTAssertEqual(places.first?.visitCount, 1, "the hidden visit must not be counted")
  }

  /// 🛑 123 of 314 `ZVISITEDLOCATION` rows on a real store carry no visit at
  /// all. They are duplicates of places that already have a visited row — three
  /// "Ocean First" rows here — so counting that table reports places the user
  /// has never been. A place is a row that has a visit.
  func testLocationsWithNoVisitAreNotPlaces() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (1, 'Ocean First');
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (2, 'Ocean First');
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (3, 'Ocean First');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (1, 1, \(MapsFixture.daysAgo(1)));
      """)

    let store = try fixture.visits()
    XCTAssertEqual(try store.places().count, 1, "two duplicate rows carry no visit")
    XCTAssertEqual(try store.orphanedLocationCount(), 2)
    XCTAssertEqual(try store.coverage().places, 1)
  }

  func testPlacesAggregateVisitCountAndDates() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME, ZMAPITEMCITY, ZMAPITEMCATEGORY)
        VALUES (1, 'Frequent Flyers', 'Boulder', 'Educational Institution||Gym');
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME, ZMAPITEMCITY) VALUES (2, 'Safeway', 'Boulder');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (1, 1, \(MapsFixture.daysAgo(30)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (2, 1, \(MapsFixture.daysAgo(10)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (3, 1, \(MapsFixture.daysAgo(2)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (4, 2, \(MapsFixture.daysAgo(5)));
      """)

    let places = try fixture.visits().places()
    XCTAssertEqual(places.map(\.name), ["Frequent Flyers", "Safeway"], "most-visited first")

    let gym = places[0]
    XCTAssertEqual(gym.visitCount, 3)
    XCTAssertEqual(gym.categories, ["Educational Institution", "Gym"])
    XCTAssertEqual(gym.category, "Educational Institution")
    let first = try XCTUnwrap(gym.firstVisit)
    let latest = try XCTUnwrap(gym.latestVisit)
    XCTAssertLessThan(first, latest)
  }

  /// The date window is bound as a double. The column is a `REAL`, and comparing
  /// it against the text `strftime('%s', ...)` returns matches nothing at all —
  /// no error, just an empty result that reads as "no visits".
  func testSinceAndBeforeNarrowTheWindow() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (1, 'Chipotle');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (1, 1, \(MapsFixture.daysAgo(1)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (2, 1, \(MapsFixture.daysAgo(40)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (3, 1, \(MapsFixture.daysAgo(400)));
      """)

    let store = try fixture.visits()
    XCTAssertEqual(try store.visits().count, 3)

    var recent = VisitsRequest()
    recent.sinceDays = 7
    XCTAssertEqual(try store.visits(recent).count, 1)
    XCTAssertEqual(try store.places(recent).first?.visitCount, 1)

    var old = VisitsRequest()
    old.beforeDays = 100
    XCTAssertEqual(try store.visits(old).count, 1)

    var window = VisitsRequest()
    window.sinceDays = 100
    window.beforeDays = 7
    XCTAssertEqual(try store.visits(window).count, 1)
  }

  /// Search is an AND of substring terms across name, address, city and
  /// category — the same rule `apple mail` and `apple messages` use.
  func testSearchMatchesAllTermsAcrossEveryField() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME, ZMAPITEMCITY, ZMAPITEMCATEGORY)
        VALUES (1, 'Christensen Park', 'Boulder', 'Travel and Leisure||Park');
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME, ZMAPITEMCITY, ZMAPITEMCATEGORY)
        VALUES (2, 'Blue Sparrow Coffee', 'Denver', 'Cafe||Dining');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (1, 1, \(MapsFixture.daysAgo(1)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (2, 2, \(MapsFixture.daysAgo(1)));
      """)

    let store = try fixture.visits()

    var byCity = VisitsRequest()
    byCity.search = "boulder"
    XCTAssertEqual(try store.places(byCity).map(\.name), ["Christensen Park"])

    // Terms may land in different fields: "denver" is the city, "cafe" a category.
    var acrossFields = VisitsRequest()
    acrossFields.search = "denver cafe"
    XCTAssertEqual(try store.places(acrossFields).map(\.name), ["Blue Sparrow Coffee"])

    // A quoted phrase requires adjacency.
    var phrase = VisitsRequest()
    phrase.search = "\"sparrow coffee\""
    XCTAssertEqual(try store.places(phrase).count, 1)

    var missing = VisitsRequest()
    missing.search = "boulder cafe"
    XCTAssertTrue(try store.places(missing).isEmpty, "every term must match")
  }

  func testMinVisitsAndLimit() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (1, 'Often');
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (2, 'Once');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (1, 1, \(MapsFixture.daysAgo(1)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (2, 1, \(MapsFixture.daysAgo(2)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (3, 2, \(MapsFixture.daysAgo(3)));
      """)

    let store = try fixture.visits()
    var request = VisitsRequest()
    request.minVisits = 2
    XCTAssertEqual(try store.places(request).map(\.name), ["Often"])

    request = VisitsRequest()
    request.limit = 1
    XCTAssertEqual(try store.places(request).count, 1)
    XCTAssertEqual(try store.visits(request).count, 1)
  }

  /// 🛑 A truncated listing must say how many rows it left out.
  ///
  /// Without this the row count a caller gets IS the answer they report, and it
  /// is wrong. Measured on a real store: `apple maps visits` defaults to 50 rows
  /// against 450, and a question about one place got the answer **1** when the
  /// true answer was **4**. The three older arrivals sat past the cut, and
  /// nothing in the output distinguished that from "you went there once".
  func testListingReportsWhatTheLimitCutOff() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (1, 'Elks Lodge');
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (2, 'Elsewhere');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (1, 1, \(MapsFixture.daysAgo(1)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (2, 1, \(MapsFixture.daysAgo(2)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (3, 1, \(MapsFixture.daysAgo(3)));
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE) VALUES (4, 2, \(MapsFixture.daysAgo(4)));
      """)

    let store = try fixture.visits()

    var capped = VisitsRequest()
    capped.limit = 2
    let cut = try store.visitListing(capped)
    XCTAssertEqual(cut.items.count, 2, "the limit still applies")
    XCTAssertEqual(cut.matched, 4, "and the caller can see what it cost")
    XCTAssertTrue(cut.truncated)

    // ⚠️ The count is taken AFTER filtering, not before. Reporting "2 of 4"
    // for a search that only ever matched 3 would be a different lie.
    var searched = VisitsRequest()
    searched.search = "Elks"
    searched.limit = 2
    let filtered = try store.visitListing(searched)
    XCTAssertEqual(filtered.matched, 3, "matched counts the search, not the store")
    XCTAssertTrue(filtered.truncated)

    // A listing that fits is never reported as truncated.
    var whole = VisitsRequest()
    whole.limit = 100
    let full = try store.visitListing(whole)
    XCTAssertEqual(full.matched, 4)
    XCTAssertFalse(full.truncated)
    XCTAssertFalse(try store.placeListing(whole).truncated)
  }

  /// The classification value goes through as a number. Two values appear on a
  /// real store and nothing in the schema says what they mean, so naming them
  /// would be a guess presented as a fact.
  func testClassificationIsReportedRaw() throws {
    let fixture = try MapsFixture()
    try fixture.run(
      """
      INSERT INTO ZVISITEDLOCATION (Z_PK, ZMAPITEMNAME) VALUES (1, 'Elks Lodge');
      INSERT INTO ZVISIT (Z_PK, ZLOCATION, ZSTARTDATE, ZVISITCLASSIFICATION)
        VALUES (1, 1, \(MapsFixture.daysAgo(1)), 3);
      """)

    XCTAssertEqual(try fixture.visits().visits().first?.classification, 3)
  }

  func testAnEmptyStoreReportsNoCoverageRatherThanFailing() throws {
    let fixture = try MapsFixture()
    let coverage = try fixture.visits().coverage()
    XCTAssertEqual(coverage.visits, 0)
    XCTAssertEqual(coverage.places, 0)
    XCTAssertNil(coverage.earliest)
    XCTAssertNil(coverage.latest)
  }
}

// MARK: - Guides

final class GuideStoreTests: XCTestCase {
  /// Held for the lifetime of the test. `MapsFixture.deinit` deletes the temp
  /// directory, so letting it go out of scope while a `MapsDatabase` still has
  /// the file open fails the query with a bare "disk I/O error".
  private var held: MapsFixture!

  override func tearDown() {
    held = nil
    super.tearDown()
  }

  private func populated() throws -> MapsFixture {
    let fixture = try MapsFixture()
    held = fixture
    try fixture.run(
      """
      INSERT INTO ZCOLLECTION (Z_PK, ZTITLE, ZPLACESCOUNT, ZPOSITIONINDEX, ZCREATETIME)
        VALUES (1, 'Boulder Playgrounds', 2, 0, \(MapsFixture.daysAgo(400)));
      INSERT INTO ZCOLLECTION (Z_PK, ZTITLE, ZPLACESCOUNT, ZPOSITIONINDEX, ZCREATETIME)
        VALUES (2, '2024 Chicago', 1, 1, \(MapsFixture.daysAgo(800)));
      INSERT INTO ZCOLLECTIONITEM (Z_PK, ZPOSITIONINDEX, ZCUSTOMNAME, ZMAPITEMNAME,
                                   ZMAPITEMADDRESS, ZMAPITEMCATEGORY, ZLATITUDE, ZLONGITUDE)
        VALUES (1, 0, 'Christensen Park', 'Christensen Park',
                '3100 Kings Ridge Blvd', 'Travel and Leisure||Park', 40.0, -105.2);
      INSERT INTO ZCOLLECTIONITEM (Z_PK, ZPOSITIONINDEX, ZCUSTOMNAME, ZMAPITEMNAME)
        VALUES (2, 1, 'The good swings', 'Parkside Park');
      INSERT INTO ZCOLLECTIONITEM (Z_PK, ZPOSITIONINDEX, ZMAPITEMNAME) VALUES (3, 0, 'The Bean');
      INSERT INTO ZCOLLECTIONITEM (Z_PK, ZPOSITIONINDEX, ZMAPITEMNAME) VALUES (4, 0, 'Orphan');
      INSERT INTO Z_7PLACES VALUES (1, 1);
      INSERT INTO Z_7PLACES VALUES (1, 2);
      INSERT INTO Z_7PLACES VALUES (2, 3);
      """)
    return fixture
  }

  func testGuidesListWithTheirPlaces() throws {
    let guides = try populated().guides().guides()
    XCTAssertEqual(guides.map(\.title), ["Boulder Playgrounds", "2024 Chicago"])
    XCTAssertEqual(guides[0].placeCount, 2)
    XCTAssertEqual(guides[0].places.map(\.name), ["Christensen Park", "The good swings"])
    XCTAssertEqual(guides[0].places[0].categories, ["Travel and Leisure", "Park"])
  }

  /// 🛑 12 of 126 `ZCOLLECTIONITEM` rows on a real store belong to no guide.
  /// Listing that table directly invents saved places the user cannot see in
  /// Maps.app, so places must come through `Z_7PLACES`.
  func testItemsInNoGuideAreNotListed() throws {
    let fixture = try populated()
    let store = try fixture.guides()
    let listed = try store.guides().flatMap(\.places).map(\.name)
    XCTAssertFalse(listed.contains("Orphan"))
    XCTAssertEqual(try store.orphanedItemCount(), 1)
  }

  /// One saved place can sit in two guides. The join is genuinely
  /// many-to-many, so it must appear in both.
  func testOnePlaceCanBelongToTwoGuides() throws {
    let fixture = try populated()
    try fixture.run("INSERT INTO Z_7PLACES VALUES (2, 1);")

    let guides = try fixture.guides().guides()
    XCTAssertEqual(guides[0].places.count, 2)
    XCTAssertEqual(guides[1].places.map(\.name).sorted(), ["Christensen Park", "The Bean"])
  }

  /// A renamed place keeps both names: what the user called it, and what Maps
  /// calls it. Reporting only one loses the ability to find the place again.
  func testARenamedPlaceKeepsBothNames() throws {
    let guides = try populated().guides().guides()
    let renamed = try XCTUnwrap(guides[0].places.first { $0.name == "The good swings" })
    XCTAssertEqual(renamed.mapItemName, "Parkside Park")

    let unchanged = try XCTUnwrap(guides[0].places.first { $0.name == "Christensen Park" })
    XCTAssertNil(
      unchanged.mapItemName, "an unrenamed place must not repeat its own name")
  }

  func testGuideLookupByIdTitleAndPartialTitle() throws {
    let store = try populated().guides()
    XCTAssertEqual(try store.guide(matching: "1").title, "Boulder Playgrounds")
    XCTAssertEqual(try store.guide(matching: "2024 Chicago").id, 2)
    XCTAssertEqual(try store.guide(matching: "playground").id, 1, "partial, case-insensitive")
  }

  /// ⚠️ Guide titles are not unique. Showing the wrong one is a mistake the
  /// reader notices much later, if at all, so an ambiguous name is an error
  /// naming the candidates.
  func testAnAmbiguousTitleIsAnErrorNotAGuess() throws {
    let fixture = try populated()
    try fixture.run(
      """
      INSERT INTO ZCOLLECTION (Z_PK, ZTITLE, ZPLACESCOUNT, ZPOSITIONINDEX)
        VALUES (3, '2025 Chicago', 0, 2);
      """)

    XCTAssertThrowsError(try fixture.guides().guide(matching: "chicago")) { error in
      let message = "\(error)"
      XCTAssertTrue(message.contains("matches 2 guides"), message)
      XCTAssertTrue(message.contains("2024 Chicago"), message)
      XCTAssertTrue(message.contains("2025 Chicago"), message)
    }
  }

  /// An exact title wins over a partial match, so a guide whose name is a
  /// prefix of another stays reachable.
  func testAnExactTitleBeatsAPartialMatch() throws {
    let fixture = try populated()
    try fixture.run(
      """
      INSERT INTO ZCOLLECTION (Z_PK, ZTITLE, ZPLACESCOUNT, ZPOSITIONINDEX)
        VALUES (3, '2024 Chicago (deep dish)', 0, 2);
      """)
    XCTAssertEqual(try fixture.guides().guide(matching: "2024 Chicago").id, 2)
  }

  func testAnUnknownGuideNamesTheListingCommand() throws {
    XCTAssertThrowsError(try populated().guides().guide(matching: "nowhere")) { error in
      XCTAssertTrue("\(error)".contains("apple maps guides"), "\(error)")
    }
  }

  func testSearchFiltersGuidesByTitleAndPlaceName() throws {
    let store = try populated().guides()
    XCTAssertEqual(try store.guides(search: "playground").map(\.title), ["Boulder Playgrounds"])
    // A guide is found by what it holds, not only by what it is called.
    XCTAssertEqual(try store.guides(search: "bean").map(\.title), ["2024 Chicago"])
  }

  /// Maps seeds "My Places" with a description equal to its title, so the
  /// plain listing would print the name twice.
  func testADescriptionEqualToTheTitleIsDropped() throws {
    let fixture = try populated()
    try fixture.run(
      """
      INSERT INTO ZCOLLECTION (Z_PK, ZTITLE, ZCOLLECTIONDESCRIPTION, ZPLACESCOUNT, ZPOSITIONINDEX)
        VALUES (3, 'My Places', 'My Places', 0, 2);
      INSERT INTO ZCOLLECTION (Z_PK, ZTITLE, ZCOLLECTIONDESCRIPTION, ZPLACESCOUNT, ZPOSITIONINDEX)
        VALUES (4, 'Ski trips', 'Where we went in 2026', 0, 3);
      """)

    let guides = try fixture.guides().guides()
    XCTAssertNil(try XCTUnwrap(guides.first { $0.id == 3 }).summary)
    XCTAssertEqual(
      try XCTUnwrap(guides.first { $0.id == 4 }).summary, "Where we went in 2026",
      "a real description must survive")
  }

  func testAnEmptyGuideIsListedRatherThanDropped() throws {
    let fixture = try populated()
    try fixture.run(
      """
      INSERT INTO ZCOLLECTION (Z_PK, ZTITLE, ZPLACESCOUNT, ZPOSITIONINDEX)
        VALUES (3, 'My Places', 0, 2);
      """)

    let guides = try fixture.guides().guides()
    let empty = try XCTUnwrap(guides.first { $0.title == "My Places" })
    XCTAssertEqual(empty.placeCount, 0)
  }
}
