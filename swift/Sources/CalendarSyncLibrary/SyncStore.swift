import Foundation
import SQLite3

/// Reads Calendar's own SQLite store to answer one question EventKit cannot:
/// **did this write reach the server?**
///
/// 🛑 **`EKEventStore.save` returning true is not evidence a write synced.** It
/// is not even evidence the write was attempted — the push happens
/// asynchronously, long after `add` has printed its JSON and exited. Measured
/// 2026-08-18: `apple calendar add` returned a full, populated event record,
/// exit 0, for a write Google CalDAV refused with HTTP 403. The event sat in
/// the local store forever and never reached the server. Calendar.app surfaced
/// it hours later as "Your event couldn't be refreshed."
///
/// That is the whole reason this file exists. Everything here is a read.
///
/// ⚠️ **This needs Full Disk Access, which the Calendar grant does not give.**
/// `apple-calendar` re-executes itself disclaimed when the Calendar grant is
/// missing, and a disclaimed process loses the terminal's Full Disk Access. So
/// on a machine whose Calendar grant already works the store is readable, and
/// on one still being set up it is not. Every entry point here therefore
/// degrades to `.unknown` rather than failing, and callers must treat "cannot
/// read the store" as an unknown answer, never as a healthy one.
public enum SyncStore {

    // MARK: - Where the store lives

    public static var path: String {
        if let override = ProcessInfo.processInfo.environment["APPLE_CALENDAR_DB_PATH"] {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
    }

    // MARK: - Store backends

    /// `Store.type`, as observed on a real machine carrying all six.
    ///
    /// Only `exchange` and `calDAV` have a server, so only those two can have a
    /// write that fails to reach one. The rest are generated or local, and
    /// their items carry an empty `external_id` **by design**.
    public enum Backend: Int {
        case local = 0
        case exchange = 1
        case calDAV = 2
        case subscribed = 4
        case generated = 5     // "Other": Birthdays, Found in Mail, Siri suggestions
        case reminders = 6

        public var name: String {
            switch self {
            case .local: return "local"
            case .exchange: return "exchange"
            case .calDAV: return "calDAV"
            case .subscribed: return "subscribed"
            case .generated: return "generated"
            case .reminders: return "reminders"
            }
        }

        /// 🛑 The single most important predicate here. A store with no server
        /// cannot have an unsynced item, and treating one as unsynced produced
        /// **139 false positives** on this machine — 138 in the generated
        /// `Birthdays` calendar and one Siri suggestion in `Found in Natural
        /// Language`, all with an empty `external_id`, an empty
        /// `external_mod_tag`, and nothing wrong with them.
        public var hasServer: Bool {
            switch self {
            case .exchange, .calDAV: return true
            case .local, .subscribed, .generated, .reminders: return false
            }
        }
    }

    // MARK: - Results

    public enum State: String, Encodable {
        /// The server has it: `external_id` is populated.
        case synced
        /// A normal item in a server-backed store with no `external_id` yet.
        /// Either still in flight, or stuck forever. `errors` tells them apart.
        case pending
        /// Nothing to sync: a generated/local/subscribed store, or a detached
        /// occurrence, whose empty `external_id` means nothing.
        case notApplicable
        /// The store could not be read, or the row was not found.
        case unknown
    }

    /// One link of an archived `NSError` chain.
    public struct ErrorLink: Encodable {
        public let code: Int
        public let domain: String?
    }

    public struct Failure: Encodable {
        /// Which of the three owner columns the `Error` row names.
        public let scope: String            // "item" | "calendar" | "store"
        public let errorCode: Int
        public let errorType: Int
        /// `NSCode` out of the archived `user_info` plist. 403 in the observed
        /// failures.
        public let httpStatus: Int?
        /// `NSDomain`, e.g. `CoreDAVHTTPStatusErrorDomain`.
        public let domain: String?
        public let item: String?
        public let calendar: String?
        public let store: String?
        /// Every link of the archived error chain, outermost first. Reported in
        /// full so a wrapper code is never mistaken for the cause.
        public let chain: [ErrorLink]

        enum CodingKeys: String, CodingKey {
            case scope, domain, item, calendar, store, chain
            case errorCode = "error_code"
            case errorType = "error_type"
            case httpStatus = "http_status"
        }
    }

    public struct Status: Encodable {
        public let state: State
        /// Why the state is `notApplicable` or `unknown`. Absent otherwise, so
        /// a reader never has to interpret an empty string.
        public let reason: String?
        public let backend: String?
        public let externalId: String?
        /// The server ETag. Reported, never used to decide anything — see the
        /// table on `pending(...)`. Exchange leaves it empty on every item it
        /// has, so a check built on it calls a healthy Exchange store 100%
        /// broken.
        public let hasModTag: Bool?
        public let detached: Bool?
        public let errors: [Failure]

        enum CodingKeys: String, CodingKey {
            case state, reason, backend, detached, errors
            case externalId = "external_id"
            case hasModTag = "has_mod_tag"
        }

        public static func unknown(_ reason: String) -> Status {
            Status(state: .unknown, reason: reason, backend: nil, externalId: nil,
                   hasModTag: nil, detached: nil, errors: [])
        }
    }

    /// A snapshot taken BEFORE a write, so an edit can be judged on what
    /// changed rather than on what was already there.
    ///
    /// 🛑 **An edit cannot be confirmed by `external_id` alone.** The event
    /// already has one from its create, so a check that only asks "is it set?"
    /// returns `synced` instantly for an edit the server never saw. Measured:
    /// `edit --json` came back in 0.17s reporting success, having confirmed
    /// nothing about the edit at all.
    public struct Baseline {
        public let existed: Bool
        public let externalId: String?
        public let modTag: String?
    }

    /// One row of the pending scan.
    public struct PendingItem: Encodable {
        public let summary: String?
        public let calendar: String
        public let store: String
        public let backend: String
        public let start: Date?
        public let uniqueIdentifier: String
        public let errors: [Failure]

        enum CodingKeys: String, CodingKey {
            case summary, calendar, store, backend, start, errors
            case uniqueIdentifier = "unique_identifier"
        }
    }

    // MARK: - Opening

    /// Opens the store read-only, or returns nil.
    ///
    /// 🛑 **Plain `mode=ro` first, `immutable=1` only as a fallback, and never a
    /// file copy.** Calendar keeps a write-ahead log. `immutable=1` does not
    /// replay it, and a `cp` does not carry it, so a freshly written item reads
    /// as ABSENT and an already-synced one reads as PENDING. Both wrong, in
    /// opposite directions, with no error. Two rounds of wrong conclusions came
    /// out of a copy-based reader during the 403 investigation, and
    /// `apple contacts` and `apple phone` each hit the same trap on their own
    /// stores before this.
    private static func open() -> OpaquePointer? {
        let file = path
        guard FileManager.default.fileExists(atPath: file) else { return nil }

        var handle: OpaquePointer?
        var status = sqlite3_open_v2(
            "file:\(file)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if status != SQLITE_OK {
            sqlite3_close(handle)
            handle = nil
            status = sqlite3_open_v2(
                "file:\(file)?immutable=1", &handle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        }
        guard status == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }

        // Never let a read path take a write lock on a store the sync engine
        // owns.
        sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)

        // 🛑 Opening a SQLite file validates nothing. `sqlite3_open_v2` never
        // reads the header, and sqlite treats a 0- or 1-byte file as a valid
        // empty database — so a truncated store would look like "opened, no
        // events" and report every write as unknown-but-fine. Probe for the
        // schema this reader depends on. Same guard `apple phone` puts on the
        // AddressBook stores.
        var probe: OpaquePointer?
        let sql = "SELECT 1 FROM CalendarItem LIMIT 0"
        guard sqlite3_prepare_v2(handle, sql, -1, &probe, nil) == SQLITE_OK else {
            sqlite3_finalize(probe)
            sqlite3_close(handle)
            return nil
        }
        sqlite3_finalize(probe)
        return handle
    }

    /// True when the store is readable at all. Used by `status` to report the
    /// half of the tool that depends on Full Disk Access.
    public static var isReadable: Bool {
        guard let handle = open() else { return false }
        sqlite3_close(handle)
        return true
    }

    // MARK: - Small sqlite helpers

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private static func query(
        _ handle: OpaquePointer, _ sql: String, bind: [String] = [],
        each: (OpaquePointer?) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: sqlite must copy the bytes, since the Swift String
        // backing them can be released before the step.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
    }

    // MARK: - The Error table

    /// Pulls `NSCode` and `NSDomain` out of an archived `user_info` blob.
    ///
    /// ⚠️ `user_info` is an `NSKeyedArchiver` plist, not a plain one. Rather
    /// than unarchive it — which needs a class whitelist and can throw on an
    /// unexpected class — this walks `$objects` for the values directly. That
    /// is what the plist is: a flat object table plus references into it.
    private static func decodeUserInfo(_ data: Data) -> [ErrorLink] {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else {
            return []
        }

        var chain: [ErrorLink] = []
        for object in objects {
            guard let dictionary = object as? [String: Any],
                  let code = (dictionary["NSCode"] as? NSNumber)?.intValue else { continue }
            var domain: String?
            if let index = uidValue(dictionary["NSDomain"]), objects.indices.contains(index) {
                domain = objects[index] as? String
            }
            chain.append(ErrorLink(code: code, domain: domain))
        }
        return chain
    }

    /// Reads a keyed-archiver UID, which is how one archived object references
    /// another.
    ///
    /// 🛑 **There is no public Swift API for this, and pairing matters.**
    /// `PropertyListSerialization` surfaces a UID as an opaque `__NSCFType`
    /// whose only readable face is its description,
    /// `<CFKeyedArchiverUID 0x… [0x…]>{value = 7}`. `NSKeyedUnarchiver` is the
    /// documented route and is worse here: it needs a class allowlist, and an
    /// archived `userInfo` can carry arbitrary classes.
    ///
    /// ⚠️ **Scanning `$objects` for a loose "…ErrorDomain" string instead — the
    /// obvious shortcut — is wrong.** CoreDAV wraps errors, so a real blob holds
    /// a chain. Measured on an archive built by Apple's own `NSKeyedArchiver`:
    /// `NSCode` 8 (`CalDAVErrorDomain`) wrapping `NSCode` 403
    /// (`CoreDAVHTTPStatusErrorDomain`). Taking the last of each happened to
    /// give the right pair, and only because of emission order. Reversed, it
    /// would report the wrapper's code with the HTTP domain — a number and a
    /// name that never belonged together.
    private static func uidValue(_ object: Any?) -> Int? {
        guard let object else { return nil }
        if let number = object as? NSNumber { return number.intValue }
        let description = String(describing: object)
        guard let range = description.range(of: "{value = "),
              let end = description[range.upperBound...].firstIndex(of: "}") else {
            return nil
        }
        return Int(description[range.upperBound..<end].trimmingCharacters(in: .whitespaces))
    }

    /// Every row of the `Error` table, with its owner columns resolved to names.
    ///
    /// ⚠️ **An empty result does not mean the store is healthy.** In the second
    /// observed failure mode the local copy is *deleted* and no `Error` row is
    /// written at all, so a check that only reads this table reports success
    /// for 19 events that were lost. Pair it with `pending(...)`, and with the
    /// event still existing at all.
    public static func failures() -> [Failure] {
        guard let handle = open() else { return [] }
        defer { sqlite3_close(handle) }
        return failures(handle)
    }

    private static func failures(_ handle: OpaquePointer) -> [Failure] {
        // `error_code` names which owner column is populated, and all three
        // scopes were observed during one incident:
        //   3 -> calendaritem_owner_id, one event failed to push
        //   4 -> calendar_owner_id,     the whole calendar failed to sync
        //   5 -> store_owner_id,        the whole account failed to sync
        let sql = """
            SELECT e.error_code, e.error_type, e.user_info,
                   ci.summary, c.title, s.name,
                   e.calendaritem_owner_id, e.calendar_owner_id, e.store_owner_id
            FROM Error e
            LEFT JOIN CalendarItem ci ON ci.ROWID = e.calendaritem_owner_id
            LEFT JOIN Calendar c ON c.ROWID = COALESCE(ci.calendar_id, e.calendar_owner_id)
            LEFT JOIN Store s ON s.ROWID = COALESCE(c.store_id, e.store_owner_id)
            ORDER BY e.ROWID
            """

        var found: [Failure] = []
        query(handle, sql) { row in
            var chain: [ErrorLink] = []
            if let blob = sqlite3_column_blob(row, 2) {
                let count = Int(sqlite3_column_bytes(row, 2))
                if count > 0 {
                    chain = decodeUserInfo(Data(bytes: blob, count: count))
                }
            }
            // Prefer the link that carries a real HTTP status; the outer links
            // are transport wrappers whose codes mean something else entirely.
            let chosen = chain.first { ($0.domain ?? "").contains("HTTPStatus") }
                ?? chain.first
            let httpStatus = chosen?.code
            let domain = chosen?.domain
            let scope: String
            if sqlite3_column_int64(row, 6) != 0 {
                scope = "item"
            } else if sqlite3_column_int64(row, 7) != 0 {
                scope = "calendar"
            } else if sqlite3_column_int64(row, 8) != 0 {
                scope = "store"
            } else {
                scope = "unknown"
            }
            found.append(Failure(
                scope: scope,
                errorCode: Int(sqlite3_column_int(row, 0)),
                errorType: Int(sqlite3_column_int(row, 1)),
                httpStatus: httpStatus,
                domain: domain,
                item: text(row, 3),
                calendar: text(row, 4),
                store: text(row, 5),
                chain: chain))
        }
        return found
    }

    // MARK: - One event

    /// The sync state of a single event.
    ///
    /// `eventIdentifier` is what `events --json` prints. Everything before the
    /// first `:` is a device-level prefix; the part after it is
    /// `CalendarItem.unique_identifier`.
    ///
    /// 🛑 **`unique_identifier` alone is not unique — pass the calendar too.**
    /// 64 values are shared by more than one row on this machine, because one
    /// Exchange meeting can sync into several Google calendars. Measured: one
    /// id names three rows, in `Steph's calendar`, `Family` and `Personal`.
    /// `(unique_identifier, calendar_id)` has zero duplicates, so the pair is
    /// the key. Looking up on the id alone returns whichever row sqlite reaches
    /// first, which is the same class of bug `apple notes delete` refuses.
    /// The pre-write snapshot for an edit. Cheap: one row.
    public static func baseline(eventIdentifier: String, calendarIdentifier: String) -> Baseline {
        guard let handle = open() else {
            return Baseline(existed: false, externalId: nil, modTag: nil)
        }
        defer { sqlite3_close(handle) }

        var result = Baseline(existed: false, externalId: nil, modTag: nil)
        let sql = """
            SELECT ci.external_id, ci.external_mod_tag
            FROM CalendarItem ci
            JOIN Calendar c ON c.ROWID = ci.calendar_id
            WHERE ci.unique_identifier = ? AND c.UUID = ?
            LIMIT 1
            """
        query(handle, sql, bind: [uniquePart(of: eventIdentifier), calendarIdentifier]) { row in
            result = Baseline(existed: true, externalId: text(row, 0), modTag: text(row, 1))
        }
        return result
    }

    /// The store's `unique_identifier` for an EventKit identifier.
    ///
    /// ⚠️ **Do not strip the `/RID=<seconds>` suffix.** A detached occurrence
    /// carries it in BOTH the EventKit identifier and the store column, so
    /// stripping it looks up the series master instead and reports the wrong
    /// row's sync state.
    private static func uniquePart(of eventIdentifier: String) -> String {
        eventIdentifier.split(separator: ":", maxSplits: 1,
                              omittingEmptySubsequences: false)
            .dropFirst().first.map(String.init) ?? eventIdentifier
    }

    public static func status(eventIdentifier: String, calendarIdentifier: String,
                       against baseline: Baseline? = nil) -> Status {
        guard let handle = open() else {
            return .unknown("cannot read Calendar.sqlitedb (needs Full Disk Access)")
        }
        defer { sqlite3_close(handle) }

        let unique = uniquePart(of: eventIdentifier)

        let sql = """
            SELECT ci.external_id, ci.external_mod_tag, ci.orig_item_id,
                   s.type, s.name, c.title
            FROM CalendarItem ci
            JOIN Calendar c ON c.ROWID = ci.calendar_id
            JOIN Store s ON s.ROWID = c.store_id
            WHERE ci.unique_identifier = ? AND c.UUID = ?
            LIMIT 1
            """

        var result: Status?
        let all = failures(handle)
        query(handle, sql, bind: [unique, calendarIdentifier]) { row in
            let externalId = text(row, 0)
            let modTag = text(row, 1)
            let detached = sqlite3_column_int64(row, 2) != 0
            let backend = Backend(rawValue: Int(sqlite3_column_int(row, 3)))
            let storeName = text(row, 4)
            let calendarName = text(row, 5)

            let mine = all.filter { failure in
                switch failure.scope {
                case "item": return failure.item != nil && failure.calendar == calendarName
                case "calendar": return failure.calendar == calendarName
                case "store": return failure.store == storeName
                default: return false
                }
            }

            let state: State
            var reason: String?
            if backend?.hasServer != true {
                state = .notApplicable
                reason = "a \(backend?.name ?? "local") store has no server to sync to"
            } else if detached {
                // 🛑 329 of 330 detached occurrences on Google CalDAV carry an
                // empty external_id and are perfectly healthy. Exchange fills
                // it on all 23 of its own. The column means nothing here.
                state = .notApplicable
                reason = "a detached occurrence carries no external_id of its own"
            } else if externalId == nil {
                state = .pending
            } else if let before = baseline, before.existed {
                // 🛑 **An edit needs a CHANGE, not a value.** `external_id` was
                // already set before the write, so its presence proves only
                // that the create synced, possibly weeks ago.
                //
                // ⚠️ **And the two backends differ completely.** Measured
                // 2026-08-18 on a real event per backend:
                //
                //   calDAV    external_mod_tag "63922751442" -> "63922751478"
                //             at t+4s. The ETag is the signal.
                //   exchange  NOTHING moves. No ETag at all, `external_id`
                //             byte-identical afterwards, `sequence_num` and
                //             `modified_properties` unchanged, `last_modified`
                //             bumped once locally at t+2s and never again.
                //
                // So on Exchange there is no local evidence that an edit
                // reached the server, and reporting "synced" would be the exact
                // lie this file exists to remove. Say unknown, and say why.
                if backend == .exchange {
                    state = .unknown
                    reason = "Exchange records nothing locally when an edit "
                        + "reaches the server, so this cannot be confirmed here"
                } else if modTag != before.modTag {
                    state = .synced
                } else {
                    state = .pending
                }
            } else {
                state = .synced
            }

            result = Status(state: state, reason: reason, backend: backend?.name,
                            externalId: externalId, hasModTag: modTag != nil,
                            detached: detached, errors: mine)
        }

        return result ?? .unknown("no row in Calendar.sqlitedb for this event")
    }

    // MARK: - The scan

    /// Every normal item in a server-backed store with no `external_id`.
    ///
    /// 🛑 **`external_id` is the signal, and `external_mod_tag` must not be.**
    /// The ETag is the obvious choice and it is wrong. Measured across every
    /// enabled server-backed store on 2026-08-18:
    ///
    /// ```
    /// backend        kind      external_id   external_mod_tag   rows
    /// exchange       normal    set           EMPTY               149
    /// exchange       detached  set           EMPTY                23
    /// calDAV         normal    set           set                6653
    /// calDAV         normal    set           EMPTY                19
    /// calDAV         detached  EMPTY         EMPTY                329
    /// calDAV         detached  set           set                    1
    /// ```
    ///
    /// **Exchange never populates the ETag — 172 of 172 items, including one
    /// written and confirmed synced during this work.** So a scan keyed on
    /// `external_mod_tag` reports every Exchange event as never-synced. The
    /// only column that works on both backends is `external_id`, and its one
    /// hole — detached CalDAV occurrences — is closed by the `orig_item_id`
    /// filter below.
    ///
    /// 🛑 **All three filters are load-bearing**, and each was measured against
    /// a real store on 2026-08-18:
    ///
    /// | filter | rows it drops | why they are not unsynced |
    /// |---|---|---|
    /// | `orig_item_id = 0` | 329 | detached occurrences on CalDAV never get one |
    /// | `s.type IN (1, 2)` | 139 | generated stores have no server at all |
    /// | `disabled = 0` | 0 today | 10 of 16 stores here are disabled accounts |
    ///
    /// Measured end to end on 2026-08-18:
    ///
    /// ```
    /// no filters at all                    468
    /// + normal items only                  139
    /// + server-backed stores                 0
    /// ```
    ///
    /// With all three applied the answer on a healthy machine is **empty**, and
    /// that is the point: anything this prints is a real write that never
    /// reached a server.
    public static func pending(calendarIdentifier: String? = nil) -> [PendingItem]? {
        guard let handle = open() else { return nil }
        defer { sqlite3_close(handle) }

        var sql = """
            SELECT ci.summary, c.title, s.name, s.type, ci.start_date,
                   ci.unique_identifier
            FROM CalendarItem ci
            JOIN Calendar c ON c.ROWID = ci.calendar_id
            JOIN Store s ON s.ROWID = c.store_id
            WHERE (ci.external_id IS NULL OR ci.external_id = '')
              AND ci.orig_item_id = 0
              AND s.type IN (1, 2)
              AND COALESCE(s.disabled, 0) = 0
            """
        var bind: [String] = []
        if let identifier = calendarIdentifier {
            sql += " AND c.UUID = ?"
            bind.append(identifier)
        }
        sql += " ORDER BY ci.start_date"

        let all = failures(handle)
        var found: [PendingItem] = []
        query(handle, sql, bind: bind) { row in
            let calendarName = text(row, 1) ?? "?"
            let storeName = text(row, 2) ?? "?"
            let backend = Backend(rawValue: Int(sqlite3_column_int(row, 3)))
            // Apple-epoch seconds, like every other Core Data store here.
            let raw = sqlite3_column_double(row, 4)
            let start = raw == 0 ? nil : Date(timeIntervalSinceReferenceDate: raw)

            let mine = all.filter { failure in
                switch failure.scope {
                case "item", "calendar": return failure.calendar == calendarName
                case "store": return failure.store == storeName
                default: return false
                }
            }

            found.append(PendingItem(
                summary: text(row, 0), calendar: calendarName, store: storeName,
                backend: backend?.name ?? "?", start: start,
                uniqueIdentifier: text(row, 5) ?? "", errors: mine))
        }
        return found
    }
}
