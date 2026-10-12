import Foundation
import SQLite3

/// Read-only access to Apple Maps' own store,
/// `~/Library/Containers/com.apple.Maps/Data/Maps/MapsSync_0.0.1`.
///
/// Same trade as `CallHistoryDatabase`, `ChatDatabase` and `EnvelopeIndex`:
/// reading the file directly works with Maps.app closed, answers in
/// milliseconds, and costs a Full Disk Access grant for the calling terminal.
///
/// There is no AppleScript fallback and there never can be. Maps.app ships no
/// scripting dictionary at all — `sdef /System/Applications/Maps.app` prints
/// nothing. Its five App Intents (`StartNavigationIntent`,
/// `UpdateNavigationIntent`, `MapsShowPlacesInAppIntent` and two test intents)
/// all *drive navigation*; none of them reads history. So reading this file is
/// the only route to visits and guides.
///
/// 🛑 **Never write to this store.** CloudKit mirrors it. It carries 1,936
/// `NSCKRecordMetadata` rows and a set of Core Data trigger-maintained
/// denormalised counters (`ZCOLLECTION.ZPLACESCOUNT`,
/// `ZVISITEDLOCATION.ZLATESTVISITDATE`). A direct write would fight the sync
/// engine and desynchronise those counters. Every path here opens read-only and
/// sets `query_only`.

public enum MapsStoreError: Error, LocalizedError {
  case unavailable(String)
  /// The file opened, but its tables are not a Maps store this reader
  /// understands. Distinct from a missing Full Disk Access grant: we could
  /// read the file, we just cannot query it.
  case schema(String)
  case query(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    case .schema(let message): return message
    case .query(let message): return message
    }
  }

  /// Why a store open or read failed. `apple maps status` uses this so a
  /// schema mismatch is not reported as a missing Full Disk Access grant —
  /// which is what `no such table: Z_7PLACES` on macOS 26 used to look like.
  public var accessFailure: MapsAccessFailure {
    switch self {
    case .unavailable(let message):
      if message.contains("APPLE_MAPS_DB_PATH") || message.contains("never run")
        || message.contains("Cannot encode")
      {
        return .missing
      }
      return .permission
    case .schema, .query:
      return .schema
    }
  }

  public static func accessFailure(for error: Error) -> MapsAccessFailure {
    (error as? MapsStoreError)?.accessFailure ?? .schema
  }
}

/// The three ways reading the Maps store can fail. Permission is the only one
/// that Full Disk Access will fix.
public enum MapsAccessFailure: String, Equatable {
  case permission
  case missing
  case schema
}

/// The Collection↔CollectionItem many-to-many join.
///
/// Core Data names this table from the entity ids in `Z_PRIMARYKEY`, not from
/// the entity names. Those ids shift between OS versions: Collection is 6 on
/// macOS 26 (`Z_6PLACES` / `Z_6COLLECTIONS` / `Z_7PLACES`) and 7 on macOS 27
/// (`Z_7PLACES` / `Z_7COLLECTIONS` / `Z_8PLACES`). Hard-coding either pair
/// makes `apple maps` fail on the other OS.
public struct MapsGuideJoin: Equatable {
  public let table: String
  public let collectionsColumn: String
  public let placesColumn: String

  public init(table: String, collectionsColumn: String, placesColumn: String) {
    self.table = table
    self.collectionsColumn = collectionsColumn
    self.placesColumn = placesColumn
  }

  /// The names Core Data would emit for `Collection.places`.
  public static func derived(collectionEntity: Int, itemEntity: Int) -> MapsGuideJoin {
    MapsGuideJoin(
      table: "Z_\(collectionEntity)PLACES",
      collectionsColumn: "Z_\(collectionEntity)COLLECTIONS",
      placesColumn: "Z_\(itemEntity)PLACES")
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// MapsSync stores every date as **seconds** since the Apple epoch
/// (2001-01-01), in Core Data `TIMESTAMP` columns that SQLite holds as `REAL`.
///
/// This is deliberately its own type rather than a reuse of
/// `PhoneLibrary.CallHistoryEpoch`, even though the unit matches today. The
/// repo already carries one pair of stores that disagree by a factor of 10^9 —
/// call history is seconds, `chat.db` is nanoseconds — and a shared converter
/// is exactly how that becomes a silent bug. Each store owns its unit.
///
/// The `REAL` storage class carries the other trap with it: comparing one of
/// these columns against the *text* `strftime('%s', ...)` returns matches
/// nothing, with no error. Every date bound below goes in as a `double`.
public enum MapsEpoch {
  public static let offset: TimeInterval = 978_307_200

  public static func date(from raw: Double) -> Date? {
    guard raw != 0 else { return nil }
    return Date(timeIntervalSince1970: raw + offset)
  }

  /// Apple-epoch seconds for a `Date`, for binding into a query.
  public static func raw(from date: Date) -> Double {
    date.timeIntervalSince1970 - offset
  }
}

public final class MapsDatabase {
  private var db: OpaquePointer?
  public let databasePath: URL
  /// True when the write-ahead log had to be bypassed, so the most recent
  /// visits may be missing.
  public private(set) var isStale = false
  /// The Collection.places join, resolved from this store's entity ids.
  public let guideJoin: MapsGuideJoin

  public static func defaultPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
  {
    home.appendingPathComponent(
      "Library/Containers/com.apple.Maps/Data/Maps/MapsSync_0.0.1")
  }

  public static func open(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> MapsDatabase
  {
    // An explicit override, for tests and for seeing what a command does
    // without Full Disk Access. Same seam as APPLE_PHONE_DB_PATH and
    // APPLE_MAIL_INDEX_PATH: pointing it at a path that does not exist must
    // report *that*, so an unreadable override never masquerades as a missing
    // grant.
    if let override = ProcessInfo.processInfo.environment["APPLE_MAPS_DB_PATH"] {
      let path = URL(fileURLWithPath: override)
      guard FileManager.default.fileExists(atPath: path.path) else {
        throw MapsStoreError.unavailable(
          "No Maps store at \(path.path) (from APPLE_MAPS_DB_PATH).")
      }
      return try MapsDatabase(path: path)
    }

    let path = defaultPath(home: home)
    guard FileManager.default.fileExists(atPath: path.path) else {
      throw MapsStoreError.unavailable(
        "No Maps store at \(path.path). Maps.app has never run on this Mac.")
    }
    guard FileManager.default.isReadableFile(atPath: path.path) else {
      throw MapsStoreError.unavailable(
        "Cannot read \(path.path). Reading it needs Full Disk Access for this terminal "
          + "(System Settings → Privacy & Security → Full Disk Access).")
    }
    return try MapsDatabase(path: path)
  }

  public init(path: URL) throws {
    databasePath = path

    // The store is in WAL mode and Maps.app leaves a large -wal behind even
    // when closed — 2.8 MB against a 19 MB main file here, and it holds the
    // most recent visits. A plain read-only open replays it; `immutable=1`
    // does not and would silently serve a checkpoint-old view. So immutable is
    // a fallback that sets `isStale`, never the default. This is the same trap
    // that made `apple phone` report a freshly added contact as unknown.
    guard let encoded = path.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else {
      throw MapsStoreError.unavailable("Cannot encode database path: \(path.path)")
    }
    var handle: OpaquePointer?
    var status = sqlite3_open_v2(
      "file://\(encoded)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)

    if status != SQLITE_OK {
      if let handle { sqlite3_close_v2(handle) }
      handle = nil
      status = sqlite3_open_v2(
        "file://\(encoded)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
      isStale = status == SQLITE_OK
    }

    guard status == SQLITE_OK, let opened = handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
      if let handle { sqlite3_close_v2(handle) }
      throw MapsStoreError.unavailable(
        "Cannot open the Maps store: \(message). This usually means the terminal "
          + "lacks Full Disk Access.")
    }
    sqlite3_busy_timeout(opened, 1000)
    sqlite3_exec(opened, "PRAGMA query_only = 1", nil, nil, nil)

    // Probe and resolve through static helpers on `opened`, not instance
    // methods. Swift 6 will not let init call `self.hasTable` / `self.query`
    // until every stored property is set, and `guideJoin` is the one we are
    // still computing.
    let join: MapsGuideJoin
    do {
      // 🛑 Opening a SQLite file validates nothing. `sqlite3_open_v2` never
      // reads the header, and sqlite treats a 0- or 1-byte file as a valid
      // empty database — so a truncated store would look like "opened, no
      // visits" and report an empty history as an answer. Probe for the
      // expected schema instead, exactly as PhoneLibrary does.
      guard try Self.hasTable(opened, "ZVISIT"),
        try Self.hasTable(opened, "ZVISITEDLOCATION"),
        try Self.hasTable(opened, "ZCOLLECTION")
      else {
        throw MapsStoreError.schema(
          "\(path.path) is not a Maps store: it has no ZVISIT/ZVISITEDLOCATION/ZCOLLECTION tables.")
      }

      // The guide-to-place join is the one name that is not stable. Entity
      // tables are `Z` + the entity name (`ZCOLLECTION`); the many-to-many
      // join is `Z_<Collection.Z_ENT>PLACES`, and that number moved between
      // macOS 26 and 27. Resolve it here so a 26 store is not reported as
      // unreadable.
      join = try Self.resolveGuideJoin(opened, path: path)
    } catch {
      sqlite3_close_v2(opened)
      throw error
    }
    db = opened
    guideJoin = join
  }

  deinit {
    if let db { sqlite3_close_v2(db) }
  }

  private static func hasTable(_ db: OpaquePointer, _ name: String) throws -> Bool {
    let rows = try Self.query(
      db, "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name = ?", [.text(name)])
    return (rows.first?["n"] as? Int64 ?? 0) > 0
  }

  /// Collection.places, from `Z_PRIMARYKEY` when present, otherwise from the
  /// table names Core Data actually created. Either source is enough; both
  /// are checked so a fixture with only the join table still opens, and a
  /// real store whose entity ids have shifted still finds the right pair.
  private static func resolveGuideJoin(_ db: OpaquePointer, path: URL) throws -> MapsGuideJoin {
    if let join = try resolveGuideJoinFromPrimaryKey(db) { return join }
    if let join = try resolveGuideJoinFromMaster(db, path: path) { return join }
    throw MapsStoreError.schema(
      "\(path.path) is a Maps store but the Collection-to-place join table was not found. "
        + "Core Data names it Z_<Collection entity id>PLACES from Z_PRIMARYKEY "
        + "(Z_6PLACES on macOS 26, Z_7PLACES on macOS 27), and this reader resolves it at runtime.")
  }

  private static func resolveGuideJoinFromPrimaryKey(_ db: OpaquePointer) throws -> MapsGuideJoin? {
    guard try hasTable(db, "Z_PRIMARYKEY") else { return nil }
    guard let collection = try entityID(db, named: "Collection"),
      let item = try entityID(db, named: "CollectionItem")
    else { return nil }
    let join = MapsGuideJoin.derived(collectionEntity: collection, itemEntity: item)
    return try matches(db, join) ? join : nil
  }

  private static func resolveGuideJoinFromMaster(_ db: OpaquePointer, path: URL) throws
    -> MapsGuideJoin?
  {
    let rows = try Self.query(
      db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z_%PLACES'")
    var found: [MapsGuideJoin] = []
    for row in rows {
      guard let name = MapsColumn.string(row["name"]), isJoinTableName(name) else { continue }
      guard let join = try inspectJoinTable(db, name) else { continue }
      found.append(join)
    }
    if found.count == 1 { return found[0] }
    if found.count > 1 {
      let names = found.map(\.table).sorted().joined(separator: ", ")
      throw MapsStoreError.schema(
        "\(path.path) has more than one Collection-to-place join table (\(names)).")
    }
    return nil
  }

  private static func inspectJoinTable(_ db: OpaquePointer, _ table: String) throws -> MapsGuideJoin?
  {
    let cols = try columns(db, of: table)
    let collections = cols.filter(isCollectionsColumn)
    let places = cols.filter(isPlacesColumn)
    guard collections.count == 1, places.count == 1 else { return nil }
    return MapsGuideJoin(
      table: table, collectionsColumn: collections[0], placesColumn: places[0])
  }

  private static func matches(_ db: OpaquePointer, _ join: MapsGuideJoin) throws -> Bool {
    guard try hasTable(db, join.table) else { return false }
    let cols = try columns(db, of: join.table)
    return cols.contains(join.collectionsColumn) && cols.contains(join.placesColumn)
  }

  private static func entityID(_ db: OpaquePointer, named name: String) throws -> Int? {
    let rows = try Self.query(
      db, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = ?", [.text(name)])
    return MapsColumn.int(rows.first?["Z_ENT"])
  }

  private static func columns(_ db: OpaquePointer, of table: String) throws -> [String] {
    let name = try sqlIdentifier(table)
    return try Self.query(db, "PRAGMA table_info(\(name))").compactMap {
      MapsColumn.string($0["name"])
    }
  }

  /// `Z_6PLACES`, `Z_7PLACES`, `Z_12PLACES` — not `ZCOLLECTION` or `ZPLACES`.
  static func isJoinTableName(_ name: String) -> Bool {
    name.range(of: "^Z_[0-9]+PLACES$", options: .regularExpression) != nil
  }

  static func isCollectionsColumn(_ name: String) -> Bool {
    name.range(of: "^Z_[0-9]+COLLECTIONS$", options: .regularExpression) != nil
  }

  static func isPlacesColumn(_ name: String) -> Bool {
    name.range(of: "^Z_[0-9]+PLACES$", options: .regularExpression) != nil
  }

  /// Identifiers interpolated into SQL. Entity-derived names are digits and
  /// letters only; anything else is a schema we should refuse, not quote.
  static func sqlIdentifier(_ name: String) throws -> String {
    guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
      throw MapsStoreError.schema("Unexpected Maps store identifier: \(name)")
    }
    return name
  }

  public enum Bind {
    case int(Int64)
    case double(Double)
    case text(String)
  }

  public func query(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
    guard let db else { throw MapsStoreError.query("Maps store is not open") }
    return try Self.query(db, sql, binds)
  }

  /// Static so `init` can probe the schema and resolve the join before `self`
  /// is fully formed. The instance `query` is the one callers use afterwards.
  private static func query(_ db: OpaquePointer, _ sql: String, _ binds: [Bind] = []) throws
    -> [[String: Any]]
  {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MapsStoreError.query(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    for (offset, bind) in binds.enumerated() {
      let index = Int32(offset + 1)
      switch bind {
      case .int(let value): sqlite3_bind_int64(statement, index, value)
      case .double(let value): sqlite3_bind_double(statement, index, value)
      case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
      }
    }

    var rows: [[String: Any]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw MapsStoreError.query(String(cString: sqlite3_errmsg(db)))
      }
      var row: [String: Any] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
        case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
        case SQLITE_TEXT:
          if let text = sqlite3_column_text(statement, column) {
            row[name] = String(cString: text)
          }
        case SQLITE_BLOB:
          if let bytes = sqlite3_column_blob(statement, column) {
            let count = Int(sqlite3_column_bytes(statement, column))
            row[name] = Data(bytes: bytes, count: count)
          }
        default: break
        }
      }
      rows.append(row)
    }
    return rows
  }
}

// MARK: - Shared column decoding

enum MapsColumn {
  /// Maps keeps every record's stable id as a **16-byte UUID blob**, not as
  /// text. Rendering it as a UUID string is what makes an id from `--json`
  /// comparable with one from another device's copy of the same record.
  static func uuid(_ value: Any?) -> String? {
    guard let data = value as? Data, data.count == 16 else { return nil }
    let bytes = [UInt8](data)
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      )
    ).uuidString
  }

  /// Categories arrive as one string joined by `||`, most specific first:
  /// `Dining||American Cuisine||Breakfast and Brunch Restaurant||Restaurant`.
  /// Splitting is the difference between filtering on "Cafe" and grepping for
  /// it inside an unrelated category name.
  static func categories(_ value: Any?) -> [String] {
    guard let raw = value as? String, !raw.isEmpty else { return [] }
    return raw.components(separatedBy: "||")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  static func string(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
  }

  static func int(_ value: Any?) -> Int? {
    if let raw = value as? Int64 { return Int(raw) }
    if let raw = value as? Double { return Int(raw) }
    return nil
  }

  static func double(_ value: Any?) -> Double? {
    if let raw = value as? Double { return raw }
    if let raw = value as? Int64 { return Double(raw) }
    return nil
  }

  static func date(_ value: Any?) -> Date? {
    guard let raw = double(value) else { return nil }
    return MapsEpoch.date(from: raw)
  }
}
