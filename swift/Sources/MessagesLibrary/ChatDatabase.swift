import Foundation
import SQLite3

/// Read-only access to Messages' own store, `~/Library/Messages/chat.db`.
///
/// Same trade as `EnvelopeIndex`: reading the file directly is orders of
/// magnitude faster than driving Messages.app, works with Messages closed, and
/// costs a Full Disk Access grant for the calling terminal rather than an
/// Automation grant.
///
/// Unlike Mail there is no AppleScript read path to fall back to — Messages'
/// scripting dictionary exposes `send` and little else, so this is the only way
/// to read history.

public enum ChatDatabaseError: Error, LocalizedError {
  case unavailable(String)
  case query(String)
  case notFound(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    case .query(let message): return message
    case .notFound(let message): return message
    }
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Messages stores timestamps as nanoseconds since the Apple epoch
/// (2001-01-01). Older rows — anything written before macOS 10.13 — used whole
/// seconds instead, and both spellings still coexist in a long-lived store, so
/// every conversion has to sniff the magnitude rather than assume.
public enum AppleEpoch {
  public static let offset: TimeInterval = 978_307_200

  /// Nanosecond values are ~10^18; second values are ~10^8. Anything past this
  /// threshold is nanoseconds.
  private static let nanosecondThreshold: Int64 = 1_000_000_000_000

  public static func date(from raw: Int64) -> Date? {
    guard raw != 0 else { return nil }
    let seconds =
      raw > nanosecondThreshold
      ? TimeInterval(raw) / 1_000_000_000
      : TimeInterval(raw)
    return Date(timeIntervalSince1970: seconds + offset)
  }
}

public final class ChatDatabase {
  private var db: OpaquePointer?
  public let databasePath: URL
  /// True when the WAL had to be bypassed, so reads may miss recent messages.
  public private(set) var isStale = false

  public static func defaultPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
  {
    home.appendingPathComponent("Library/Messages/chat.db")
  }

  public static func open(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> ChatDatabase
  {
    let path = defaultPath(home: home)
    guard FileManager.default.fileExists(atPath: path.path) else {
      throw ChatDatabaseError.unavailable(
        "No Messages database at \(path.path). Messages has never been set up on this Mac.")
    }
    guard FileManager.default.isReadableFile(atPath: path.path) else {
      throw ChatDatabaseError.unavailable(
        "Cannot read \(path.path). Reading it needs Full Disk Access for this terminal "
          + "(System Settings → Privacy & Security → Full Disk Access).")
    }
    return try ChatDatabase(path: path)
  }

  public init(path: URL) throws {
    databasePath = path

    // chat.db is in WAL mode and Messages leaves a large -wal behind even when
    // closed — 600 KB of today's messages on a store this size. A plain
    // read-only open replays it; `immutable=1` does not and would silently
    // serve a checkpoint-old view. So immutable is a fallback that sets
    // `isStale` rather than the default. Same reasoning as EnvelopeIndex.
    guard let encoded = path.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else {
      throw ChatDatabaseError.unavailable("Cannot encode database path: \(path.path)")
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
      throw ChatDatabaseError.unavailable(
        "Cannot open the Messages database: \(message). This usually means the terminal "
          + "lacks Full Disk Access.")
    }
    db = opened
    sqlite3_busy_timeout(opened, 1000)
    sqlite3_exec(opened, "PRAGMA query_only = 1", nil, nil, nil)
  }

  deinit {
    if let db { sqlite3_close_v2(db) }
  }

  // MARK: Low-level query

  public enum Bind {
    case int(Int64)
    case text(String)
  }

  /// Rows keyed by column name. Unlike the Mail reader this keeps BLOBs, as
  /// `Data` — the message body of a text-less message lives in one.
  public func query(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw ChatDatabaseError.query(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    for (offset, bind) in binds.enumerated() {
      let index = Int32(offset + 1)
      switch bind {
      case .int(let value): sqlite3_bind_int64(statement, index, value)
      case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
      }
    }

    var rows: [[String: Any]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw ChatDatabaseError.query(String(cString: sqlite3_errmsg(db)))
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
          let count = Int(sqlite3_column_bytes(statement, column))
          if count > 0, let pointer = sqlite3_column_blob(statement, column) {
            row[name] = Data(bytes: pointer, count: count)
          }
        default: break
        }
      }
      rows.append(row)
    }
    return rows
  }
}

/// Escape the LIKE metacharacters so a query term matches literally. Pair with
/// `ESCAPE '\'`; without it a search for "50%" matches every message.
public func escapeLikePattern(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "%", with: "\\%")
    .replacingOccurrences(of: "_", with: "\\_")
}
