import Foundation
import SQLite3

/// Read-only access to the call history store,
/// `~/Library/Application Support/CallHistoryDB/CallHistory.storedata`.
///
/// Same trade as `ChatDatabase` and `EnvelopeIndex`: reading the file directly
/// works with Phone.app closed, answers in milliseconds, and costs a Full Disk
/// Access grant for the calling terminal.
///
/// There is no AppleScript fallback and there never can be. Phone.app ships no
/// scripting dictionary at all (`sdef` reports error -192, and its Info.plist
/// has neither `NSAppleScriptEnabled` nor `OSAScriptingDefinition`), no
/// AppIntents metadata, and no Shortcuts actions. Reading this file is the only
/// route to call history.
///
/// The store is a Core Data SQLite database. It is a *relay mirror* of the
/// iPhone's history, not the whole history: the iPhone keeps years, this keeps
/// however far back continuity has been syncing. Report it as "recents".

public enum CallHistoryError: Error, LocalizedError {
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

/// Call history stores `ZDATE` as **seconds** since the Apple epoch
/// (2001-01-01), in a `TIMESTAMP` column that SQLite holds as a `REAL`.
///
/// Two traps live here, both hit while building this:
///
/// 1. Messages' `chat.db` uses *nanoseconds* for the same conceptual column.
///    Sharing a converter between the two silently misreads every date by a
///    factor of 10^9, so this is deliberately its own type rather than a reuse
///    of `MessagesLibrary.AppleEpoch`.
/// 2. Because the column is a `REAL`, comparing it against the *text* that
///    `strftime('%s', ...)` returns matches nothing — SQLite will not coerce
///    across those storage classes. It is not an error, just an empty result,
///    which reads exactly like "no calls". Every date bound below goes in as a
///    `double`, never as a string.
public enum CallHistoryEpoch {
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

public final class CallHistoryDatabase {
  private var db: OpaquePointer?
  public let databasePath: URL
  /// True when the write-ahead log had to be bypassed, so the most recent calls
  /// may be missing.
  public private(set) var isStale = false

  public static func defaultPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
  {
    home.appendingPathComponent(
      "Library/Application Support/CallHistoryDB/CallHistory.storedata")
  }

  public static func open(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> CallHistoryDatabase
  {
    // An explicit override, for tests and for seeing what a command does
    // without Full Disk Access. Same seam as APPLE_MAIL_INDEX_PATH: pointing it
    // at a path that does not exist must report *that*, so an unreadable
    // override never masquerades as a missing grant.
    if let override = ProcessInfo.processInfo.environment["APPLE_PHONE_DB_PATH"] {
      let path = URL(fileURLWithPath: override)
      guard FileManager.default.fileExists(atPath: path.path) else {
        throw CallHistoryError.unavailable(
          "No call history database at \(path.path) (from APPLE_PHONE_DB_PATH).")
      }
      return try CallHistoryDatabase(path: path)
    }

    let path = defaultPath(home: home)
    guard FileManager.default.fileExists(atPath: path.path) else {
      throw CallHistoryError.unavailable(
        "No call history database at \(path.path). Phone.app has never run on this Mac, or "
          + "iPhone call relay has never been enabled.")
    }
    guard FileManager.default.isReadableFile(atPath: path.path) else {
      throw CallHistoryError.unavailable(
        "Cannot read \(path.path). Reading it needs Full Disk Access for this terminal "
          + "(System Settings → Privacy & Security → Full Disk Access).")
    }
    return try CallHistoryDatabase(path: path)
  }

  public init(path: URL) throws {
    databasePath = path

    // The store is in WAL mode and Phone.app leaves a large -wal behind even
    // when closed — 2.5 MB against a 240 KB main file here, so the log holds
    // most of the recent history. A plain read-only open replays it;
    // `immutable=1` does not and would silently serve a checkpoint-old view. So
    // immutable is a fallback that sets `isStale`, never the default.
    guard let encoded = path.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else {
      throw CallHistoryError.unavailable("Cannot encode database path: \(path.path)")
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
      throw CallHistoryError.unavailable(
        "Cannot open the call history database: \(message). This usually means the terminal "
          + "lacks Full Disk Access.")
    }
    db = opened
    sqlite3_busy_timeout(opened, 1000)
    sqlite3_exec(opened, "PRAGMA query_only = 1", nil, nil, nil)
  }

  deinit {
    if let db { sqlite3_close_v2(db) }
  }

  public enum Bind {
    case int(Int64)
    case double(Double)
    case text(String)
  }

  public func query(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw CallHistoryError.query(String(cString: sqlite3_errmsg(db)))
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
        throw CallHistoryError.query(String(cString: sqlite3_errmsg(db)))
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
        default: break
        }
      }
      rows.append(row)
    }
    return rows
  }
}
