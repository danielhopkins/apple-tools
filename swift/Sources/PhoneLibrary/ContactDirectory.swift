import AppleToolsSearch
import Foundation
import SQLite3

/// Resolving a call's handle to a person's name.
///
/// **Why not the Contacts framework.** Two reasons, and the second is the
/// decisive one:
///
/// 1. `ZCALLRECORD.ZNAME` is empty — 1 of 289 rows on a real store — so every
///    row needs resolving and the lookup has to be a bulk map, not a per-row
///    query.
/// 2. `CNContactStore` would need its own TCC grant, and taking it would break
///    the read this tool exists for. `apple-contacts` gets a *tool-bound* grant
///    by re-executing itself disclaimed; a disclaimed process becomes its own
///    responsible process, which is exactly what Full Disk Access is attributed
///    to. So a disclaiming `apple-phone` would lose the terminal's Full Disk
///    Access and stop being able to read call history at all.
///
/// Reading the AddressBook SQLite stores instead costs nothing extra: they sit
/// under the same Full Disk Access grant the call history needs, so the tool
/// stays a **single-grant** tool, exactly like `apple messages`.
///
/// This is READ ONLY, for the same reason `NoteStore` is: writing these stores
/// would desynchronise Core Data's change tracking and CloudKit sync state.
public struct ContactMatch: Sendable {
  public let name: String
  public let contactID: String

  public init(name: String, contactID: String) {
    self.name = name
    self.contactID = contactID
  }
}

/// One reachable handle belonging to a contact, for resolving a name to
/// something dialable.
public struct ContactNumber: Sendable {
  public let name: String
  public let contactID: String
  public let value: String
  public let isEmail: Bool
  public let isPrimary: Bool
  public let orderingIndex: Int64
}

/// Why resolution is or is not working.
///
/// The three cases must stay distinct. "Every caller is unknown" is the correct
/// answer for an empty address book and a *wrong* one when the store simply
/// could not be opened — and the two are indistinguishable from the result
/// alone, which is precisely the failure this repo treats as worse than an
/// error. Anything that depends on a name refuses outright in the `unreadable`
/// case rather than reporting a confident-looking lie.
public enum ContactAvailability: String, Sendable {
  /// At least one address book opened.
  case available
  /// No address book on this Mac at all. Nothing to read; not a permission
  /// problem, and not an error.
  case noAddressBook
  /// Stores exist but none could be opened. Almost always a missing Full Disk
  /// Access grant.
  case unreadable
}

public struct ContactDirectory {
  /// Keyed by `PhoneNumber.matchKey`, so both sides of a comparison agree.
  private let byKey: [String: ContactMatch]
  /// Every handle, kept in source order for name lookups.
  private let numbers: [ContactNumber]

  public let availability: ContactAvailability
  /// How many sources had to be read without replaying their write-ahead log, so
  /// a very recently added contact may be missing from them.
  public let staleSources: Int

  /// True only when a name lookup can be trusted. A caller that needs to
  /// distinguish "no contacts" from "cannot read contacts" reads
  /// `availability`.
  public var isAvailable: Bool { availability == .available }

  public var count: Int { byKey.count }

  public func lookup(_ handle: String) -> ContactMatch? {
    byKey[PhoneNumber.matchKey(handle)]
  }

  /// Handles belonging to contacts whose name contains every term in `query`,
  /// matched case-insensitively — the same AND-of-terms rule the search commands
  /// use, so "margot hop" finds "Margot Hopkins".
  ///
  /// Returns handles rather than contacts because the caller needs something to
  /// dial, and grouping by `contactID` is what tells it whether the name was
  /// ambiguous.
  public func findByName(_ query: String, email: Bool = false) -> [ContactNumber] {
    let terms = parseSearchTerms(query).map { $0.lowercased() }
    guard !terms.isEmpty else { return [] }
    return numbers.filter { entry in
      guard entry.isEmail == email else { return false }
      let name = entry.name.lowercased()
      return terms.allSatisfy { name.contains($0) }
    }
  }

  /// An empty directory, for when resolution is deliberately switched off.
  /// Reports `noAddressBook` rather than `unreadable`: nothing failed here, so
  /// nothing should warn about a grant.
  public static var empty: ContactDirectory {
    ContactDirectory(byKey: [:], numbers: [], availability: .noAddressBook, staleSources: 0)
  }

  private init(
    byKey: [String: ContactMatch], numbers: [ContactNumber], availability: ContactAvailability,
    staleSources: Int
  ) {
    self.byKey = byKey
    self.numbers = numbers
    self.availability = availability
    self.staleSources = staleSources
  }

  /// Overridable so the `unreadable` path can be exercised without revoking a
  /// real grant — the same seam `APPLE_MAIL_INDEX_PATH` provides for mail, and
  /// for the same reason: the interesting failure is otherwise untestable.
  private static var base: String {
    if let override = ProcessInfo.processInfo.environment["APPLE_PHONE_ADDRESSBOOK_DIR"] {
      return override
    }
    return ("~/Library/Application Support/AddressBook" as NSString).expandingTildeInPath
  }

  /// Every AddressBook source database on this machine. The root store is
  /// usually empty and the real contacts live under `Sources/<uuid>/`, one
  /// directory per account, so all of them are read and merged.
  private static func databases() -> [String] {
    let manager = FileManager.default
    var found: [String] = []

    let sources = (base as NSString).appendingPathComponent("Sources")
    if let entries = try? manager.contentsOfDirectory(atPath: sources) {
      for entry in entries.sorted() {
        let candidate = (sources as NSString)
          .appendingPathComponent(entry)
          .appending("/AddressBook-v22.abcddb")
        if manager.fileExists(atPath: candidate) { found.append(candidate) }
      }
    }

    let root = (base as NSString).appendingPathComponent("AddressBook-v22.abcddb")
    if manager.fileExists(atPath: root) { found.append(root) }

    return found
  }

  /// Build the map once, then look up per call.
  ///
  /// Both phone numbers and email addresses are indexed: a FaceTime call's
  /// handle is an Apple ID, so without the emails those rows would never
  /// resolve.
  public static func load() -> ContactDirectory {
    var byKey: [String: ContactMatch] = [:]
    var numbers: [ContactNumber] = []
    var opened = 0
    var staleSources = 0

    let candidates = databases()
    for path in candidates {
      // 🛑 `immutable=1` is wrong here, and was the first thing this got wrong.
      //
      // Contacts leaves a large write-ahead log behind — 3 MB against a 35 MB
      // main file on a real machine — and `immutable=1` tells sqlite the file
      // cannot change, so it does **not** replay the WAL. A contact added
      // minutes ago lives only in that log, so resolution silently missed it and
      // the caller was reported as unknown. Caught by adding a contact and
      // watching this reader fail to see it.
      //
      // So: a plain read-only open first, which does replay the log, and
      // `immutable=1` only as a fallback for when that fails — the same order
      // `CallHistoryDatabase` and `ChatDatabase` use, and for the same reason.
      guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
      else { continue }

      var handle: OpaquePointer?
      var status = sqlite3_open_v2(
        "file://\(encoded)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
      if status != SQLITE_OK {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
        status = sqlite3_open_v2(
          "file://\(encoded)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if status == SQLITE_OK { staleSources += 1 }
      }
      guard status == SQLITE_OK else {
        if let handle { sqlite3_close_v2(handle) }
        continue
      }
      defer { sqlite3_close_v2(handle) }
      // Belt and braces: never let a read path acquire a write lock on a store
      // that syncs to every one of the user's devices.
      sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)

      // Opening proves nothing, and neither does a query against sqlite_master.
      //
      // `sqlite3_open_v2` does no I/O beyond the file handle — it never reads
      // the header, so it succeeds on a file that is not a database and fails
      // only at the first query. Worse, sqlite treats a **zero- or one-byte file
      // as a valid empty database**, so a truncated store answers
      // `SELECT 1 FROM sqlite_master` perfectly happily and would be counted as
      // a working source holding no contacts — reporting every caller as unknown
      // with no warning, which is the exact silent-wrong-answer this enum exists
      // to prevent.
      //
      // The schema is the only honest signal: a real address book has
      // ZABCDPHONENUMBER, an empty or corrupt file does not. A genuinely empty
      // address book still has the table (Core Data creates it with the store),
      // so this does not misreport "no contacts" as a failure.
      var probe: OpaquePointer?
      let usable =
        sqlite3_prepare_v2(handle, "SELECT 1 FROM ZABCDPHONENUMBER LIMIT 1", -1, &probe, nil)
        == SQLITE_OK
      sqlite3_finalize(probe)
      guard usable else { continue }
      opened += 1

      let phoneSQL = """
        SELECT p.ZFULLNUMBER AS value, r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME,
               r.ZORGANIZATION, r.ZUNIQUEID, p.ZISPRIMARY, p.ZORDERINGINDEX
        FROM ZABCDPHONENUMBER p
        JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER
        WHERE p.ZFULLNUMBER IS NOT NULL AND p.ZFULLNUMBER != ''
        ORDER BY p.ZORDERINGINDEX
        """
      let emailSQL = """
        SELECT e.ZADDRESS AS value, r.ZFIRSTNAME, r.ZLASTNAME, r.ZNICKNAME,
               r.ZORGANIZATION, r.ZUNIQUEID, e.ZISPRIMARY, e.ZORDERINGINDEX
        FROM ZABCDEMAILADDRESS e
        JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER
        WHERE e.ZADDRESS IS NOT NULL AND e.ZADDRESS != ''
        ORDER BY e.ZORDERINGINDEX
        """

      for (isEmailSource, sql) in [(false, phoneSQL), (true, emailSQL)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { continue }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
          func text(_ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, column) else { return nil }
            let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
          }
          guard let value = text(0) else { continue }
          let first = text(1)
          let last = text(2)
          let nickname = text(3)
          let organization = text(4)
          let uniqueID = text(5) ?? ""

          // A contact with no name at all still has a company; fall back to it
          // rather than emitting a blank name that reads as a bug.
          let personal = [first, last].compactMap { $0 }.joined(separator: " ")
          let name = !personal.isEmpty ? personal : (nickname ?? organization)
          guard let name, !name.isEmpty else { continue }

          let key = PhoneNumber.matchKey(value)
          guard !key.isEmpty else { continue }
          // First writer wins. Sources are read in a stable order, so which
          // contact a shared number resolves to does not change run to run.
          if byKey[key] == nil {
            byKey[key] = ContactMatch(name: name, contactID: uniqueID)
          }
          numbers.append(
            ContactNumber(
              name: name, contactID: uniqueID, value: value, isEmail: isEmailSource,
              isPrimary: sqlite3_column_int64(statement, 6) == 1,
              orderingIndex: sqlite3_column_int64(statement, 7)))
        }
      }
    }

    // A store that exists but will not open is the grant; no store at all is
    // just a Mac with no contacts on it.
    let availability: ContactAvailability
    if opened > 0 {
      availability = .available
    } else if candidates.isEmpty {
      availability = .noAddressBook
    } else {
      availability = .unreadable
    }
    return ContactDirectory(
      byKey: byKey, numbers: numbers, availability: availability, staleSources: staleSources)
  }
}
