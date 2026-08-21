import Foundation
import SQLite3
import XCTest

@testable import CalendarSyncLibrary

// MARK: - Fixture

/// A Calendar.sqlitedb built from scratch, so these tests never touch the real
/// one and run offline with Calendar.app closed.
///
/// The schema is trimmed to the columns the reader uses. Everything being
/// pinned is in the **data**: the three classes of row that look unsynced and
/// are not, and the two backends that report a synced item differently.
final class CalendarFixture {
    let url: URL
    private let directory: URL

    /// The columns the reader touches, and nothing else.
    ///
    /// ⚠️ `orig_item_id` really is `0` for a normal item in the live store, not
    /// NULL. Testing `IS NOT NULL` matches every row and reports the whole
    /// store as detached occurrences — a wrong reading that happened once
    /// during this work, so the fixture keeps the real default.
    static let schema = """
        CREATE TABLE Store (
            ROWID INTEGER PRIMARY KEY,
            type INTEGER,
            name TEXT,
            disabled INTEGER
        );
        CREATE TABLE Calendar (
            ROWID INTEGER PRIMARY KEY,
            store_id INTEGER,
            title TEXT,
            UUID TEXT
        );
        CREATE TABLE CalendarItem (
            ROWID INTEGER PRIMARY KEY,
            calendar_id INTEGER,
            summary TEXT,
            start_date REAL,
            orig_item_id INTEGER DEFAULT 0,
            external_id TEXT,
            external_mod_tag TEXT,
            unique_identifier TEXT
        );
        CREATE TABLE Error (
            ROWID INTEGER PRIMARY KEY,
            store_owner_id INTEGER DEFAULT 0,
            calendar_owner_id INTEGER DEFAULT 0,
            calendaritem_owner_id INTEGER DEFAULT 0,
            error_type INTEGER,
            error_code INTEGER,
            user_info BLOB
        );
        """

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tools-calendar-sync-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Calendar.sqlitedb")
        try run(Self.schema)
    }

    deinit {
        setenv("APPLE_CALENDAR_DB_PATH", "", 1)
        unsetenv("APPLE_CALENDAR_DB_PATH")
        try? FileManager.default.removeItem(at: directory)
    }

    func run(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close_v2(db) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw NSError(domain: "fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    /// Points the reader at this fixture for the duration of a test.
    func use() { setenv("APPLE_CALENDAR_DB_PATH", url.path, 1) }

    // MARK: Convenience builders

    static let calDAVUUID = "AAAAAAAA-0000-0000-0000-000000000001"
    static let exchangeUUID = "BBBBBBBB-0000-0000-0000-000000000002"
    static let generatedUUID = "CCCCCCCC-0000-0000-0000-000000000003"
    static let disabledUUID = "DDDDDDDD-0000-0000-0000-000000000004"

    /// One store of each kind that matters, matching the live layout.
    func seedStores() throws {
        try run("""
            INSERT INTO Store (ROWID, type, name, disabled) VALUES
                (1, 2, 'Google', 0),
                (2, 1, 'Exchange', 0),
                (3, 5, 'Other', NULL),
                (4, 2, 'Old Account', 1);
            INSERT INTO Calendar (ROWID, store_id, title, UUID) VALUES
                (10, 1, 'Personal',  '\(Self.calDAVUUID)'),
                (11, 2, 'Work',      '\(Self.exchangeUUID)'),
                (12, 3, 'Birthdays', '\(Self.generatedUUID)'),
                (13, 4, 'Stale',     '\(Self.disabledUUID)');
            """)
    }

    func insert(id: Int, calendar: Int, summary: String, unique: String,
                externalId: String? = nil, modTag: String? = nil,
                detached: Bool = false) throws {
        func quote(_ value: String?) -> String {
            value.map { "'\($0)'" } ?? "NULL"
        }
        try run("""
            INSERT INTO CalendarItem
                (ROWID, calendar_id, summary, start_date, orig_item_id,
                 external_id, external_mod_tag, unique_identifier)
            VALUES (\(id), \(calendar), '\(summary)', 0, \(detached ? 99 : 0),
                    \(quote(externalId)), \(quote(modTag)), '\(unique)');
            """)
    }
}

// MARK: - The false-positive classes

/// 🛑 A bare "empty `external_id` means unsynced" scan reported **468 healthy
/// events** on a real store. Each filter below removes one class of those, and
/// each class is a different reason.
final class UnsyncedFiltersTests: XCTestCase {
    var fixture: CalendarFixture!

    override func setUpWithError() throws {
        fixture = try CalendarFixture()
        try fixture.seedStores()
        fixture.use()
    }

    override func tearDown() {
        unsetenv("APPLE_CALENDAR_DB_PATH")
        fixture = nil
    }

    func testAHealthyStoreReportsNothing() throws {
        try fixture.insert(id: 100, calendar: 10, summary: "synced",
                           unique: "u-synced", externalId: "/x.ics", modTag: "1")
        XCTAssertEqual(SyncStore.pending()?.count, 0)
    }

    func testADetachedOccurrenceIsNotUnsynced() throws {
        // 329 of 330 detached occurrences on real Google CalDAV carry an empty
        // external_id and are perfectly healthy.
        try fixture.insert(id: 101, calendar: 10, summary: "moved occurrence",
                           unique: "u-series/RID=804520800", detached: true)
        XCTAssertEqual(SyncStore.pending()?.count, 0,
                       "a detached occurrence was reported as unsynced")
    }

    func testAGeneratedStoreItemIsNotUnsynced() throws {
        // The live "Other" store (type 5) holds 138 Birthdays entries and a
        // Siri suggestion, all with an empty external_id, none of them broken.
        try fixture.insert(id: 102, calendar: 12, summary: "a birthday",
                           unique: "u-birthday")
        XCTAssertEqual(SyncStore.pending()?.count, 0,
                       "a store with no server was reported as unsynced")
    }

    func testADisabledAccountIsSkipped() throws {
        // 10 of 16 stores on the real machine are disabled accounts.
        try fixture.insert(id: 103, calendar: 13, summary: "old account event",
                           unique: "u-stale")
        XCTAssertEqual(SyncStore.pending()?.count, 0,
                       "an item in a disabled account was reported as unsynced")
    }

    func testARealUnsyncedEventIsReported() throws {
        // The guards must not suppress the case they exist to surface.
        try fixture.insert(id: 104, calendar: 10, summary: "never reached Google",
                           unique: "u-stuck")
        let pending = try XCTUnwrap(SyncStore.pending())
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.summary, "never reached Google")
        XCTAssertEqual(pending.first?.backend, "calDAV")
    }

    func testAllFourClassesTogether() throws {
        try fixture.insert(id: 110, calendar: 10, summary: "ok",
                           unique: "u-a", externalId: "/a.ics", modTag: "1")
        try fixture.insert(id: 111, calendar: 10, summary: "detached",
                           unique: "u-b/RID=1", detached: true)
        try fixture.insert(id: 112, calendar: 12, summary: "birthday", unique: "u-c")
        try fixture.insert(id: 113, calendar: 13, summary: "stale", unique: "u-d")
        try fixture.insert(id: 114, calendar: 10, summary: "the real one", unique: "u-e")

        let pending = try XCTUnwrap(SyncStore.pending())
        XCTAssertEqual(pending.map(\.summary), ["the real one"])
    }

    func testTheScanCanBeNarrowedToOneCalendar() throws {
        try fixture.insert(id: 120, calendar: 10, summary: "calDAV stuck", unique: "u-1")
        try fixture.insert(id: 121, calendar: 11, summary: "exchange stuck", unique: "u-2")
        XCTAssertEqual(SyncStore.pending()?.count, 2)
        XCTAssertEqual(
            SyncStore.pending(calendarIdentifier: CalendarFixture.exchangeUUID)?
                .map(\.summary),
            ["exchange stuck"])
    }
}

// MARK: - Exchange is not CalDAV

/// 🛑 **`external_mod_tag` is unusable as a sync signal.** Exchange never
/// populates it — 172 of 172 items on a real store, including one written and
/// confirmed synced during this work. A check keyed on the ETag calls a healthy
/// Exchange account 100% broken.
final class BackendDifferenceTests: XCTestCase {
    var fixture: CalendarFixture!

    override func setUpWithError() throws {
        fixture = try CalendarFixture()
        try fixture.seedStores()
        fixture.use()
    }

    override func tearDown() {
        unsetenv("APPLE_CALENDAR_DB_PATH")
        fixture = nil
    }

    func testAnExchangeItemWithNoETagIsSynced() throws {
        // Exactly what a real Exchange write looks like after it syncs.
        try fixture.insert(id: 200, calendar: 11, summary: "work meeting",
                           unique: "u-ex", externalId: "AAMkAD...=", modTag: nil)
        let status = SyncStore.status(eventIdentifier: "DEVICE:u-ex",
                                      calendarIdentifier: CalendarFixture.exchangeUUID)
        XCTAssertEqual(status.state, .synced)
        XCTAssertEqual(status.hasModTag, false, "Exchange never sets the ETag")
        XCTAssertEqual(SyncStore.pending()?.count, 0,
                       "an ETag-based check would call this unsynced")
    }

    func testACalDAVItemCarriesBothColumns() throws {
        try fixture.insert(id: 201, calendar: 10, summary: "personal",
                           unique: "u-dav", externalId: "/p.ics", modTag: "\"63922751442\"")
        let status = SyncStore.status(eventIdentifier: "DEVICE:u-dav",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .synced)
        XCTAssertEqual(status.hasModTag, true)
    }

    func testAGeneratedStoreIsNotApplicableRatherThanPending() throws {
        try fixture.insert(id: 202, calendar: 12, summary: "birthday", unique: "u-bd")
        let status = SyncStore.status(eventIdentifier: "DEVICE:u-bd",
                                      calendarIdentifier: CalendarFixture.generatedUUID)
        XCTAssertEqual(status.state, .notApplicable)
        XCTAssertNotNil(status.reason)
    }

    func testADetachedOccurrenceIsNotApplicable() throws {
        try fixture.insert(id: 203, calendar: 10, summary: "moved",
                           unique: "u-s/RID=804520800", detached: true)
        let status = SyncStore.status(eventIdentifier: "DEVICE:u-s/RID=804520800",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .notApplicable)
        XCTAssertEqual(status.detached, true)
    }
}

// MARK: - Identifier handling

final class IdentifierTests: XCTestCase {
    var fixture: CalendarFixture!

    override func setUpWithError() throws {
        fixture = try CalendarFixture()
        try fixture.seedStores()
        fixture.use()
    }

    override func tearDown() {
        unsetenv("APPLE_CALENDAR_DB_PATH")
        fixture = nil
    }

    /// 🛑 `unique_identifier` is NOT unique. 64 values are shared on a real
    /// store, because one Exchange meeting syncs into several Google calendars.
    /// One id was measured naming three rows at once. Looking up on the id
    /// alone returns whichever row sqlite reaches first.
    func testTheCalendarDisambiguatesASharedIdentifier() throws {
        try fixture.insert(id: 300, calendar: 10, summary: "on calDAV",
                           unique: "shared-id", externalId: "/a.ics", modTag: "1")
        try fixture.insert(id: 301, calendar: 11, summary: "on exchange",
                           unique: "shared-id")

        let onCalDAV = SyncStore.status(eventIdentifier: "DEVICE:shared-id",
                                        calendarIdentifier: CalendarFixture.calDAVUUID)
        let onExchange = SyncStore.status(eventIdentifier: "DEVICE:shared-id",
                                          calendarIdentifier: CalendarFixture.exchangeUUID)
        XCTAssertEqual(onCalDAV.state, .synced)
        XCTAssertEqual(onExchange.state, .pending,
                       "the two rows must not be confused for each other")
    }

    /// ⚠️ A detached occurrence carries `/RID=<seconds>` in BOTH the EventKit
    /// identifier and the store column. Stripping it looks up the series master
    /// and reports the wrong row.
    func testTheRIDSuffixIsNotStripped() throws {
        try fixture.insert(id: 302, calendar: 10, summary: "the series",
                           unique: "series-id", externalId: "/s.ics", modTag: "1")
        try fixture.insert(id: 303, calendar: 10, summary: "the occurrence",
                           unique: "series-id/RID=804520800", detached: true)

        let status = SyncStore.status(eventIdentifier: "DEVICE:series-id/RID=804520800",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.detached, true,
                       "the lookup fell through to the series master")
    }

    func testAnUnknownEventIsUnknownNotSynced() {
        let status = SyncStore.status(eventIdentifier: "DEVICE:nothing",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .unknown)
    }
}

// MARK: - Confirming an edit

/// 🛑 **An edit cannot be confirmed by `external_id` alone.** The event already
/// has one from its create, so a presence check returns `synced` instantly for
/// an edit the server never saw. Measured on the real tool before this fix:
/// `edit --json` returned in 0.17s reporting success.
final class EditConfirmationTests: XCTestCase {
    var fixture: CalendarFixture!

    override func setUpWithError() throws {
        fixture = try CalendarFixture()
        try fixture.seedStores()
        fixture.use()
    }

    override func tearDown() {
        unsetenv("APPLE_CALENDAR_DB_PATH")
        fixture = nil
    }

    func testAnUnchangedETagMeansTheEditHasNotSynced() throws {
        try fixture.insert(id: 400, calendar: 10, summary: "event",
                           unique: "u-edit", externalId: "/e.ics",
                           modTag: "\"63922751442\"")
        let before = SyncStore.baseline(eventIdentifier: "DEVICE:u-edit",
                                        calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertTrue(before.existed)

        let status = SyncStore.status(eventIdentifier: "DEVICE:u-edit",
                                      calendarIdentifier: CalendarFixture.calDAVUUID,
                                      against: before)
        XCTAssertEqual(status.state, .pending,
                       "an unchanged ETag was read as a synced edit")
    }

    func testAChangedETagMeansTheEditSynced() throws {
        try fixture.insert(id: 401, calendar: 10, summary: "event",
                           unique: "u-edit2", externalId: "/e.ics",
                           modTag: "\"63922751442\"")
        let before = SyncStore.baseline(eventIdentifier: "DEVICE:u-edit2",
                                        calendarIdentifier: CalendarFixture.calDAVUUID)
        // The server bumped it — measured 442 -> 478 at t+4s on a real write.
        try fixture.run(
            "UPDATE CalendarItem SET external_mod_tag = '\"63922751478\"' WHERE ROWID = 401")

        let status = SyncStore.status(eventIdentifier: "DEVICE:u-edit2",
                                      calendarIdentifier: CalendarFixture.calDAVUUID,
                                      against: before)
        XCTAssertEqual(status.state, .synced)
    }

    /// 🛑 On Exchange **nothing** changes locally when an edit reaches the
    /// server. Measured across 16 seconds of polling: no ETag at all,
    /// `external_id` byte-identical, `sequence_num` and `modified_properties`
    /// unchanged. So the honest answer is `unknown`, and saying `synced` would
    /// be the exact lie this whole feature removes.
    func testAnExchangeEditIsUnknownNotSynced() throws {
        try fixture.insert(id: 402, calendar: 11, summary: "work",
                           unique: "u-ex-edit", externalId: "AAMkAD...=")
        let before = SyncStore.baseline(eventIdentifier: "DEVICE:u-ex-edit",
                                        calendarIdentifier: CalendarFixture.exchangeUUID)

        let status = SyncStore.status(eventIdentifier: "DEVICE:u-ex-edit",
                                      calendarIdentifier: CalendarFixture.exchangeUUID,
                                      against: before)
        XCTAssertEqual(status.state, .unknown)
        XCTAssertNotNil(status.reason)
    }

    /// A create passes no baseline, so the appearance of an `external_id` is
    /// the whole signal and must still read as synced.
    func testACreateStillConfirmsOnExternalIdAlone() throws {
        try fixture.insert(id: 403, calendar: 10, summary: "new",
                           unique: "u-new", externalId: "/n.ics", modTag: "1")
        let status = SyncStore.status(eventIdentifier: "DEVICE:u-new",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .synced)
    }
}

// MARK: - The Error table

final class SyncErrorTests: XCTestCase {
    var fixture: CalendarFixture!

    override func setUpWithError() throws {
        fixture = try CalendarFixture()
        try fixture.seedStores()
        fixture.use()
    }

    override func tearDown() {
        unsetenv("APPLE_CALENDAR_DB_PATH")
        fixture = nil
    }

    func testAnEmptyErrorTableReportsNothing() {
        XCTAssertEqual(SyncStore.failures().count, 0)
    }

    /// `error_code` names which owner column is populated. All three scopes
    /// appeared during one real incident.
    func testEachScopeIsNamedFromItsOwnerColumn() throws {
        try fixture.insert(id: 500, calendar: 10, summary: "stuck event",
                           unique: "u-err")
        try fixture.run("""
            INSERT INTO Error (ROWID, calendaritem_owner_id, error_type, error_code)
                VALUES (1, 500, 1, 3);
            INSERT INTO Error (ROWID, calendar_owner_id, error_type, error_code)
                VALUES (2, 10, 1, 4);
            INSERT INTO Error (ROWID, store_owner_id, error_type, error_code)
                VALUES (3, 1, 1, 5);
            """)

        let failures = SyncStore.failures()
        XCTAssertEqual(failures.map(\.scope), ["item", "calendar", "store"])
        XCTAssertEqual(failures.map(\.errorCode), [3, 4, 5])
        XCTAssertEqual(failures[0].item, "stuck event")
    }

    /// Archives an NSError chain with Apple's own NSKeyedArchiver.
    ///
    /// 🛑 **Do not hand-build the plist here.** An earlier version of this test
    /// did, and it passed while proving nothing: a hand-built object table can
    /// be given whatever shape the decoder already expects. A real archive puts
    /// `NSDomain` behind a `CFKeyedArchiverUID` reference, which is the part
    /// that is actually hard to read.
    private func archivedError(_ error: NSError) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: [NSUnderlyingErrorKey: error],
            requiringSecureCoding: false)
    }

    private func insertError(blob: Data, itemRowID: Int) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.url.path, &handle), SQLITE_OK)
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO Error (calendaritem_owner_id, error_type, error_code, user_info)
            VALUES (\(itemRowID), 1, 3, ?)
            """
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        _ = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, 1, raw.baseAddress, Int32(blob.count), nil)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        sqlite3_close(handle)
    }

    /// ⚠️ `user_info` is an NSKeyedArchiver plist. The HTTP status is inside it,
    /// and reading it is why diagnosing one 403 took an hour by hand.
    func testTheArchivedUserInfoYieldsTheHTTPStatus() throws {
        let blob = try archivedError(NSError(
            domain: "CoreDAVHTTPStatusErrorDomain", code: 403,
            userInfo: ["CoreDAVHTTPHeaders": ["Server": "GSE"]]))

        try fixture.insert(id: 501, calendar: 10, summary: "403 event", unique: "u-403")
        try insertError(blob: blob, itemRowID: 501)

        let failure = try XCTUnwrap(SyncStore.failures().first)
        XCTAssertEqual(failure.httpStatus, 403)
        XCTAssertEqual(failure.domain, "CoreDAVHTTPStatusErrorDomain")
    }

    /// 🛑 **CoreDAV wraps errors, and the wrapper's code is not the HTTP
    /// status.** Measured on a real Apple-produced archive: `NSCode` 8 in
    /// `CalDAVErrorDomain` carrying `NSCode` 403 in
    /// `CoreDAVHTTPStatusErrorDomain`.
    ///
    /// Scanning `$objects` for any `NSCode` and any "…ErrorDomain" string —
    /// the shortcut that avoids resolving a `CFKeyedArchiverUID` — gave the
    /// right answer here purely because of emission order. This pins the
    /// pairing instead.
    func testAWrappedErrorReportsTheInnerHTTPStatusNotTheWrapper() throws {
        let http = NSError(domain: "CoreDAVHTTPStatusErrorDomain", code: 403,
                           userInfo: [:])
        let outer = NSError(domain: "CalDAVErrorDomain", code: 8,
                            userInfo: [NSUnderlyingErrorKey: http])

        try fixture.insert(id: 503, calendar: 10, summary: "wrapped", unique: "u-wrap")
        try insertError(blob: try archivedError(outer), itemRowID: 503)

        let failure = try XCTUnwrap(SyncStore.failures().first)
        XCTAssertEqual(failure.httpStatus, 403, "it reported the wrapper's code")
        XCTAssertEqual(failure.domain, "CoreDAVHTTPStatusErrorDomain")

        // Nothing is hidden: the whole chain is reported.
        XCTAssertEqual(failure.chain.count, 2)
        XCTAssertEqual(Set(failure.chain.map(\.code)), [8, 403])
        // 🛑 And every code keeps its OWN domain. A shortcut that scans for a
        // loose string can pair 8 with the HTTP domain, which is a number and a
        // name that never belonged together.
        for link in failure.chain where link.code == 8 {
            XCTAssertEqual(link.domain, "CalDAVErrorDomain")
        }
    }

    /// An unreadable blob must not invent a status.
    func testGarbageUserInfoYieldsNoStatus() throws {
        try fixture.insert(id: 504, calendar: 10, summary: "junk", unique: "u-junk")
        try insertError(blob: Data([0x00, 0x01, 0x02, 0x03]), itemRowID: 504)

        let failure = try XCTUnwrap(SyncStore.failures().first)
        XCTAssertNil(failure.httpStatus)
        XCTAssertNil(failure.domain)
        XCTAssertEqual(failure.chain.count, 0)
    }

    /// An error on the item's calendar or account applies to the item too, so a
    /// per-event check must surface it rather than reporting a bare "pending".
    func testAStoreWideErrorReachesAPendingItem() throws {
        try fixture.insert(id: 502, calendar: 10, summary: "stuck", unique: "u-scope")
        try fixture.run(
            "INSERT INTO Error (ROWID, store_owner_id, error_type, error_code) "
            + "VALUES (1, 1, 1, 5);")

        let status = SyncStore.status(eventIdentifier: "DEVICE:u-scope",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .pending)
        XCTAssertEqual(status.errors.count, 1)
        XCTAssertEqual(status.errors.first?.scope, "store")
    }

    // MARK: One item's error is not the whole calendar's

    /// 🛑 **An item-scoped error belongs to ONE item.** The old filter asked
    /// only whether the row named some item and whether the calendar matched,
    /// so every event on that calendar inherited it — and EventKit never clears
    /// the row, so the calendar could never report a healthy write again.
    ///
    /// Measured 2026-08-18: one HTTP 400 from a counter-proposal on somebody
    /// else's invite made every later `add` on "Personal" fail while the events
    /// landed and synced correctly.
    func testAnItemErrorDoesNotAttachToOtherEventsOnTheCalendar() throws {
        try fixture.insert(id: 600, calendar: 10, summary: "their invite",
                           unique: "u-theirs")
        try fixture.insert(id: 601, calendar: 10, summary: "my new event",
                           unique: "u-mine", externalId: "/dav/mine.ics",
                           modTag: "63922751442")
        try fixture.run(
            "INSERT INTO Error (ROWID, calendaritem_owner_id, error_type, error_code) "
            + "VALUES (1, 600, 1, 3);")

        let mine = SyncStore.status(eventIdentifier: "DEVICE:u-mine",
                                    calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(mine.state, .synced)
        XCTAssertEqual(mine.errors.count, 0,
                       "another event's error must not be reported against this one")

        // The event that really failed still carries it.
        let theirs = SyncStore.status(eventIdentifier: "DEVICE:u-theirs",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(theirs.state, .pending)
        XCTAssertEqual(theirs.errors.map(\.scope), ["item"])
    }

    /// The same rule inside `unsynced`: a stuck event must name its own cause,
    /// not the one belonging to the event beside it.
    func testTheScanDoesNotShareOneItemErrorAcrossTheCalendar() throws {
        try fixture.insert(id: 610, calendar: 10, summary: "theirs", unique: "u-a")
        try fixture.insert(id: 611, calendar: 10, summary: "mine", unique: "u-b")
        try fixture.run(
            "INSERT INTO Error (ROWID, calendaritem_owner_id, error_type, error_code) "
            + "VALUES (1, 610, 1, 3);")

        let items = try XCTUnwrap(SyncStore.pending())
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.summary ?? "", $0) })
        XCTAssertEqual(byName["theirs"]?.errors.count, 1)
        XCTAssertEqual(byName["mine"]?.errors.count, 0)
    }

    /// ⚠️ **A synced item cannot be blamed for a broad error.** Its push
    /// succeeded, so a calendar- or store-scoped row is about something else,
    /// and printing it next to `state: synced` reads as a failure.
    func testASyncedItemDropsCalendarAndStoreErrors() throws {
        try fixture.insert(id: 620, calendar: 10, summary: "landed", unique: "u-ok",
                           externalId: "/dav/ok.ics", modTag: "1")
        try fixture.run("""
            INSERT INTO Error (ROWID, calendar_owner_id, error_type, error_code)
                VALUES (1, 10, 1, 4);
            INSERT INTO Error (ROWID, store_owner_id, error_type, error_code)
                VALUES (2, 1, 1, 5);
            """)

        let status = SyncStore.status(eventIdentifier: "DEVICE:u-ok",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .synced)
        XCTAssertEqual(status.errors.count, 0)
    }

    // MARK: Old errors are not evidence about a new write

    /// 🛑 **A row written before the save says nothing about the save.** This is
    /// the fingerprint that lets the wait loop tell the two apart.
    func testTheSnapshotSeparatesOldErrorsFromNewOnes() throws {
        try fixture.insert(id: 630, calendar: 10, summary: "theirs", unique: "u-old")
        try fixture.run(
            "INSERT INTO Error (ROWID, calendaritem_owner_id, error_type, error_code) "
            + "VALUES (1, 630, 1, 3);")

        let before = try XCTUnwrap(SyncStore.errorSnapshot())

        try fixture.insert(id: 631, calendar: 10, summary: "mine", unique: "u-new")
        try fixture.run(
            "INSERT INTO Error (ROWID, calendaritem_owner_id, error_type, error_code) "
            + "VALUES (2, 631, 1, 3);")

        let now = SyncStore.failures()
        XCTAssertEqual(now.count, 2)
        XCTAssertEqual(now.filter(before.isNew).map(\.itemRowid), [631])
    }

    /// An empty store still gives a usable snapshot, so the first error a write
    /// produces is recognised as new.
    func testAnEmptySnapshotCallsEveryLaterErrorNew() throws {
        let before = try XCTUnwrap(SyncStore.errorSnapshot())
        try fixture.insert(id: 640, calendar: 10, summary: "mine", unique: "u-first")
        try fixture.run(
            "INSERT INTO Error (ROWID, calendaritem_owner_id, error_type, error_code) "
            + "VALUES (1, 640, 1, 3);")

        XCTAssertEqual(SyncStore.failures().filter(before.isNew).count, 1)
    }

    /// ⚠️ **An unreadable store yields no snapshot at all**, and the caller must
    /// poll to its deadline rather than treat every error as new.
    func testAnUnreadableStoreYieldsNoSnapshot() {
        setenv("APPLE_CALENDAR_DB_PATH", "/nonexistent/Calendar.sqlitedb", 1)
        XCTAssertNil(SyncStore.errorSnapshot())
    }
}

// MARK: - Degrading safely

final class UnreadableStoreTests: XCTestCase {
    override func tearDown() { unsetenv("APPLE_CALENDAR_DB_PATH") }

    /// ⚠️ **"I cannot check" must never read as "it failed".** Reading this
    /// store needs Full Disk Access, which the Calendar grant does not carry,
    /// so a perfectly good write on a machine without that grant must come back
    /// `unknown` rather than `pending`.
    func testAMissingStoreIsUnknownNotPending() {
        setenv("APPLE_CALENDAR_DB_PATH", "/nonexistent/Calendar.sqlitedb", 1)
        XCTAssertFalse(SyncStore.isReadable)
        let status = SyncStore.status(eventIdentifier: "DEVICE:x",
                                      calendarIdentifier: "any")
        XCTAssertEqual(status.state, .unknown)
        XCTAssertNil(SyncStore.pending(), "a scan it could not run must not look empty")
        XCTAssertEqual(SyncStore.failures().count, 0)
    }

    /// 🛑 Opening a SQLite file validates nothing: sqlite treats a 0-byte file
    /// as a valid empty database. Without a schema probe, a truncated store
    /// looks like "opened, nothing pending" and reports every write as fine.
    func testATruncatedStoreIsUnknownNotEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Calendar.sqlitedb")
        try Data().write(to: path)

        setenv("APPLE_CALENDAR_DB_PATH", path.path, 1)
        XCTAssertFalse(SyncStore.isReadable, "an empty file passed as a real store")
        XCTAssertNil(SyncStore.pending())
    }
}

// MARK: - Rebuilding a stuck event

/// 🛑 **`resync` is the one part of this work with no real failure behind it.**
/// 123 probe writes across two sessions produced no 403, so the rebuild is
/// verified end to end on healthy events only. Whether a fresh item escapes a
/// poisoned account is untested.
///
/// These tests pin what CAN be checked offline: the guards, and the state a
/// rebuilt event must be judged against.
final class ResyncGuardTests: XCTestCase {
    var fixture: CalendarFixture!

    override func setUpWithError() throws {
        fixture = try CalendarFixture()
        try fixture.seedStores()
        fixture.use()
    }

    override func tearDown() {
        unsetenv("APPLE_CALENDAR_DB_PATH")
        fixture = nil
    }

    /// The command refuses a synced event without --force, so the state it
    /// reads must be right. A `pending` event is the one worth rebuilding.
    func testAStuckEventReadsAsPending() throws {
        try fixture.insert(id: 600, calendar: 10, summary: "stuck", unique: "u-stuck")
        let status = SyncStore.status(eventIdentifier: "DEVICE:u-stuck",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .pending, "resync would refuse this as synced")
    }

    /// ⚠️ After a rebuild the NEW event is a different row with a different
    /// identifier. The old one must be gone from the scan, and the new one must
    /// read as synced — not both, and not neither.
    func testARebuiltEventReplacesTheStuckOne() throws {
        try fixture.insert(id: 601, calendar: 10, summary: "stuck", unique: "u-old")
        XCTAssertEqual(SyncStore.pending()?.count, 1)

        // What the rebuild leaves behind: a new row that reached the server.
        try fixture.insert(id: 602, calendar: 10, summary: "stuck",
                           unique: "u-new", externalId: "/new.ics", modTag: "1")
        try fixture.run("DELETE FROM CalendarItem WHERE ROWID = 601")

        XCTAssertEqual(SyncStore.pending()?.count, 0)
        let status = SyncStore.status(eventIdentifier: "DEVICE:u-new",
                                      calendarIdentifier: CalendarFixture.calDAVUUID)
        XCTAssertEqual(status.state, .synced)
    }

    /// 🛑 A rebuild that fails partway must leave TWO events, never zero. The
    /// command creates the copy before deleting the original for exactly this
    /// reason, so the scan has to cope with both being present.
    func testBothCopiesPresentIsVisibleRatherThanHidden() throws {
        try fixture.insert(id: 603, calendar: 10, summary: "dupe", unique: "u-a")
        try fixture.insert(id: 604, calendar: 10, summary: "dupe",
                           unique: "u-b", externalId: "/b.ics", modTag: "1")
        // The stuck one is still reported; the rebuilt one is not.
        let pending = try XCTUnwrap(SyncStore.pending())
        XCTAssertEqual(pending.map(\.uniqueIdentifier), ["u-a"])
    }
}

// MARK: - Which errors are worth waiting through

/// 🛑 **The tool called every `Error` row a permanent refusal, and exited 1.**
///
/// Measured on 2026-08-21, one burst of 30 add+edit pairs on a Google CalDAV
/// calendar: 16 items recorded an HTTP 403, and **all 16 synced anyway**, about
/// 156 seconds later, together. EventKit cleared 15 of the 16 rows itself. So
/// "EventKit stops retrying an item once it records one" is false for a 403,
/// and every one of those writes was reported as refused while succeeding.
///
/// ⚠️ **A retryable status is not a promise the write landed.** The incident in
/// `docs/apple-calendar-caldav-403.md` was a 403 that never cleared. CoreDAV
/// cannot tell a Google rate limit from a real denial. These tests pin the
/// classification only: retryable means *keep waiting*, never *it worked*.
final class RetryableErrorTests: XCTestCase {

    private func failure(http: Int?) -> SyncStore.Failure {
        SyncStore.Failure(
            rowid: 1, itemRowid: 500, scope: "item", errorCode: 3, errorType: 1,
            httpStatus: http, domain: "CoreDAVHTTPStatusErrorDomain",
            item: "event", calendar: "Personal", store: "Google", chain: [])
    }

    /// The measured one. A 403 here is Google throttling far more often than
    /// Google refusing, and treating it as terminal is what this fixes.
    func testA403IsRetryable() {
        XCTAssertTrue(failure(http: 403).retryable)
    }

    func testRateLimitAndServerErrorsAreRetryable() {
        for status in [408, 429, 500, 502, 503, 504, 599] {
            XCTAssertTrue(failure(http: status).retryable, "HTTP \(status)")
        }
    }

    /// 🛑 A 400 is the one that really is terminal, and it must stay that way.
    /// It was a counter-proposed Outlook invite Google will refuse every time.
    func testClientErrorsAreTerminal() {
        for status in [400, 401, 404, 405, 409, 412] {
            XCTAssertFalse(failure(http: status).retryable, "HTTP \(status)")
        }
    }

    /// ⚠️ **No HTTP status means nothing said the server refused anything.**
    /// Calling that terminal would invent a refusal out of a row that carries
    /// no evidence of one.
    func testNoHTTPStatusIsRetryable() {
        XCTAssertTrue(failure(http: nil).retryable)
    }

    /// The flag is in the JSON, so a caller does not re-implement the table.
    func testRetryableIsEncoded() throws {
        let data = try JSONEncoder().encode(failure(http: 403))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["retryable"] as? Bool, true)
        XCTAssertEqual(object["http_status"] as? Int, 403)

        let terminal = try JSONEncoder().encode(failure(http: 400))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: terminal) as? [String: Any])
        XCTAssertEqual(decoded["retryable"] as? Bool, false)
    }

    // MARK: - What the caller actually reads
    //
    // 🛑 A real Google throttle cannot be provoked on demand — three bursts on
    // one afternoon produced 16 errors, then 0, then 0 — so the wording a
    // throttled caller sees is unreachable from a live run. These pin it.

    /// ⚠️ **The note must name the status.** A caller who cannot tell a
    /// throttled account from a slow one cannot choose what to do next.
    func testTheThrottleNoteNamesTheStatusAndTheBudget() {
        let note = SyncStore.Message.throttling(status: 403, waitingUpTo: 180)
        XCTAssertTrue(note.contains("HTTP 403"), note)
        XCTAssertTrue(note.contains("180s"), note)
        XCTAssertTrue(note.contains("retrying"), note)
        // 🛑 It must not read as a refusal. That is the whole change.
        XCTAssertFalse(note.contains("REFUSED"), note)
    }

    /// A row with no HTTP status still gets a note, without inventing one.
    func testTheThrottleNoteSurvivesAMissingStatus() {
        let note = SyncStore.Message.throttling(status: nil, waitingUpTo: 90)
        XCTAssertTrue(note.contains("an error"), note)
        XCTAssertFalse(note.contains("HTTP"), note)
    }

    /// 🛑 The timeout message must say the event is SAVED. A caller reading it
    /// as a failure deletes or rewrites an event that is on its way.
    func testTheUnconfirmedNoteWithAThrottleSaysTheEventIsSaved() {
        let note = SyncStore.Message.unconfirmed(afterSeconds: 180, httpStatus: 403)
        XCTAssertTrue(note.contains("HTTP 403"), note)
        XCTAssertTrue(note.contains("rate limiting"), note)
        XCTAssertTrue(note.contains("event IS saved"), note)
        XCTAssertTrue(note.contains("180s"), note)
        XCTAssertFalse(note.contains("REFUSED"), note)
        // Both repair routes, because neither alone answers "is it missing".
        XCTAssertTrue(note.contains("sync-status"), note)
        XCTAssertTrue(note.contains("unsynced"), note)
    }

    /// ⚠️ No error at all is a different sentence, and it must stay different:
    /// "nothing was refused" is only true when nothing was recorded.
    func testTheUnconfirmedNoteWithNoErrorSaysNothingWasRefused() {
        let note = SyncStore.Message.unconfirmed(afterSeconds: 30, httpStatus: nil)
        XCTAssertTrue(note.contains("Nothing was refused"), note)
        XCTAssertFalse(note.contains("HTTP"), note)
        XCTAssertFalse(note.contains("rate limiting"), note)
        XCTAssertTrue(note.contains("30s"), note)
    }

    /// ⚠️ A row with no HTTP status must still encode, with the key absent
    /// rather than null — the rule every optional key in this tool follows.
    func testAnAbsentStatusOmitsTheKey() throws {
        let data = try JSONEncoder().encode(failure(http: nil))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["http_status"])
        XCTAssertEqual(object["retryable"] as? Bool, true)
    }
}
