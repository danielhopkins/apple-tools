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
  case query(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    case .query(let message): return message
    }
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
    db = opened
    sqlite3_busy_timeout(opened, 1000)
    sqlite3_exec(opened, "PRAGMA query_only = 1", nil, nil, nil)

    // 🛑 Opening a SQLite file validates nothing. `sqlite3_open_v2` never reads
    // the header, and sqlite treats a 0- or 1-byte file as a valid empty
    // database — so a truncated store would look like "opened, no visits" and
    // report an empty history as an answer. Probe for the expected schema
    // instead, exactly as PhoneLibrary does.
    guard try hasTable("ZVISIT"), try hasTable("ZVISITEDLOCATION"), try hasTable("ZCOLLECTION")
    else {
      throw MapsStoreError.unavailable(
        "\(path.path) is not a Maps store: it has no ZVISIT/ZVISITEDLOCATION/ZCOLLECTION tables.")
    }
  }

  deinit {
    if let db { sqlite3_close_v2(db) }
  }

  private func hasTable(_ name: String) throws -> Bool {
    let rows = try query(
      "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name = ?", [.text(name)])
    return (rows.first?["n"] as? Int64 ?? 0) > 0
  }

  public enum Bind {
    case int(Int64)
    case double(Double)
    case text(String)
  }

  public func query(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
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
