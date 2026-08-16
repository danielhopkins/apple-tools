import AppleToolsSearch
import Foundation

/// Apple Maps' "Visited Places" history.
///
/// Two tables carry it. `ZVISITEDLOCATION` is one row per place, with the name,
/// address, category list and a real coordinate. `ZVISIT` is one row per
/// arrival, pointing back at a place.
///
/// ⚠️ **This is not Significant Locations.** That is a separate store owned by
/// `routined`, under `/var/db/locationd/`, which no unprivileged process can
/// read. Never describe what this returns as Significant Locations; they are
/// different features with different retention.

public struct Place {
  public let id: Int
  /// The stable cross-device id, decoded from the 16-byte UUID blob.
  public let identifier: String?
  public let name: String
  public let address: String?
  public let city: String?
  /// Most specific first, split from the `||`-joined column.
  public let categories: [String]
  /// Apple's own top-level category enum. Reported raw because nothing here
  /// knows the mapping, and inventing a name for `6` would be a guess.
  public let topLevelCategory: Int?
  public let latitude: Double
  public let longitude: Double
  /// Apple's place id. Two `ZVISITEDLOCATION` rows for one real place share it.
  public let muid: Int?
  public let visitCount: Int
  public let firstVisit: Date?
  public let latestVisit: Date?

  public var category: String? { categories.first }

  /// Everything a `--search` term may match: name, address, city, categories.
  var haystack: String {
    ([name, address ?? "", city ?? ""] + categories).joined(separator: " ")
  }
}

public struct Visit {
  public let id: Int
  public let date: Date?
  /// ⚠️ Reported raw on purpose. Two values appear on a real store — `1` on 389
  /// visits and `3` on 51 — and nothing in the schema says what they mean. The
  /// `3` visits are a subset of places that also have `1` visits, so it is a
  /// property of the arrival rather than of the place. Naming these would be a
  /// guess, so the tool passes the number through.
  public let classification: Int?
  public let place: Place
}

public struct VisitsRequest {
  public var sinceDays: Int?
  public var beforeDays: Int?
  public var search: String?
  public var minVisits: Int?
  public var limit: Int?

  public init() {}
}

public final class VisitStore {
  private let database: MapsDatabase

  public init(database: MapsDatabase) {
    self.database = database
  }

  public var databasePath: URL { database.databasePath }
  public var isStale: Bool { database.isStale }

  // MARK: - Places

  /// Every place with at least one visit, most-visited first.
  ///
  /// 🛑 **The join is not optional, and `ZVISITEDLOCATION` alone overcounts.**
  /// On this store 123 of its 314 rows have **no `ZVISIT` at all** and a NULL
  /// `ZLATESTVISITDATE`. They are duplicate rows for places that already have a
  /// visited row — three separate "Ocean First" rows, two "Frequent Flyers" —
  /// so they look like ordinary places and inflate any count taken off that
  /// table. Counting rows there reports 314 places where the honest answer is
  /// 191. A place is a row that has a visit; nothing else is.
  public func places(_ request: VisitsRequest = VisitsRequest()) throws -> [Place] {
    var sql = """
      SELECT l.Z_PK, l.ZIDENTIFIER, l.ZMAPITEMNAME, l.ZMAPITEMADDRESS, l.ZMAPITEMCITY,
             l.ZMAPITEMCATEGORY, l.ZMAPITEMTOPLEVELCATEGORY, l.ZLATITUDE, l.ZLONGITUDE, l.ZMUID,
             COUNT(v.Z_PK) AS visit_count,
             MIN(v.ZSTARTDATE) AS first_visit,
             MAX(v.ZSTARTDATE) AS latest_visit
      FROM ZVISITEDLOCATION l
      JOIN ZVISIT v ON v.ZLOCATION = l.Z_PK
      WHERE \(Self.notHidden("l")) AND \(Self.notHidden("v"))
      """
    var binds: [MapsDatabase.Bind] = []
    Self.appendDateWindow(request, to: &sql, binds: &binds, column: "v.ZSTARTDATE")

    sql += "\nGROUP BY l.Z_PK"
    if let minimum = request.minVisits {
      sql += "\nHAVING COUNT(v.Z_PK) >= \(max(0, minimum))"
    }
    sql += "\nORDER BY visit_count DESC, latest_visit DESC"

    var places = try database.query(sql, binds).map(Self.place)
    places = Self.filter(places, search: request.search)
    if let limit = request.limit, places.count > limit {
      places = Array(places.prefix(limit))
    }
    return places
  }

  // MARK: - Visits

  /// Individual arrivals, newest first.
  ///
  /// ⚠️ **A visit has a start and no end.** `ZVISIT` carries `ZSTARTDATE` and
  /// nothing else time-shaped, so this store cannot say how long you stayed
  /// anywhere. Do not report a duration from it.
  public func visits(_ request: VisitsRequest = VisitsRequest()) throws -> [Visit] {
    var sql = """
      SELECT v.Z_PK AS visit_id, v.ZSTARTDATE, v.ZVISITCLASSIFICATION,
             l.Z_PK, l.ZIDENTIFIER, l.ZMAPITEMNAME, l.ZMAPITEMADDRESS, l.ZMAPITEMCITY,
             l.ZMAPITEMCATEGORY, l.ZMAPITEMTOPLEVELCATEGORY, l.ZLATITUDE, l.ZLONGITUDE, l.ZMUID,
             (SELECT COUNT(*) FROM ZVISIT n WHERE n.ZLOCATION = l.Z_PK) AS visit_count
      FROM ZVISIT v
      JOIN ZVISITEDLOCATION l ON l.Z_PK = v.ZLOCATION
      WHERE \(Self.notHidden("l")) AND \(Self.notHidden("v"))
      """
    var binds: [MapsDatabase.Bind] = []
    Self.appendDateWindow(request, to: &sql, binds: &binds, column: "v.ZSTARTDATE")
    sql += "\nORDER BY v.ZSTARTDATE DESC"

    let rows = try database.query(sql, binds)
    var visits = rows.map { row in
      Visit(
        id: MapsColumn.int(row["visit_id"]) ?? 0,
        date: MapsColumn.date(row["ZSTARTDATE"]),
        classification: MapsColumn.int(row["ZVISITCLASSIFICATION"]),
        place: Self.place(row))
    }

    if let terms = Self.terms(request.search) {
      visits = visits.filter { containsAllTerms($0.place.haystack, terms) }
    }
    if let limit = request.limit, visits.count > limit {
      visits = Array(visits.prefix(limit))
    }
    return visits
  }

  /// The window the store actually covers, so a caller never presents a
  /// year of relayed history as if it were everything.
  public func coverage() throws -> (earliest: Date?, latest: Date?, visits: Int, places: Int) {
    let rows = try database.query(
      """
      SELECT MIN(v.ZSTARTDATE) AS earliest, MAX(v.ZSTARTDATE) AS latest,
             COUNT(*) AS visits, COUNT(DISTINCT v.ZLOCATION) AS places
      FROM ZVISIT v WHERE \(Self.notHidden("v"))
      """)
    guard let row = rows.first else { return (nil, nil, 0, 0) }
    return (
      MapsColumn.date(row["earliest"]),
      MapsColumn.date(row["latest"]),
      MapsColumn.int(row["visits"]) ?? 0,
      MapsColumn.int(row["places"]) ?? 0
    )
  }

  /// `ZVISITEDLOCATION` rows carrying no visit. Reported by `status` alone, as
  /// the evidence for why the place count is lower than the row count.
  public func orphanedLocationCount() throws -> Int {
    let rows = try database.query(
      """
      SELECT COUNT(*) AS n FROM ZVISITEDLOCATION l
      WHERE NOT EXISTS (SELECT 1 FROM ZVISIT v WHERE v.ZLOCATION = l.Z_PK)
      """)
    return MapsColumn.int(rows.first?["n"]) ?? 0
  }

  // MARK: - Row decoding

  private static func place(_ row: [String: Any]) -> Place {
    Place(
      id: MapsColumn.int(row["Z_PK"]) ?? 0,
      identifier: MapsColumn.uuid(row["ZIDENTIFIER"]),
      name: MapsColumn.string(row["ZMAPITEMNAME"]) ?? "(unnamed place)",
      address: MapsColumn.string(row["ZMAPITEMADDRESS"]),
      city: MapsColumn.string(row["ZMAPITEMCITY"]),
      categories: MapsColumn.categories(row["ZMAPITEMCATEGORY"]),
      topLevelCategory: MapsColumn.int(row["ZMAPITEMTOPLEVELCATEGORY"]),
      latitude: MapsColumn.double(row["ZLATITUDE"]) ?? 0,
      longitude: MapsColumn.double(row["ZLONGITUDE"]) ?? 0,
      muid: MapsColumn.int(row["ZMUID"]),
      visitCount: MapsColumn.int(row["visit_count"]) ?? 0,
      firstVisit: MapsColumn.date(row["first_visit"]),
      latestVisit: MapsColumn.date(row["latest_visit"]))
  }

  // MARK: - Predicates

  /// 🛑 **`ZHIDDEN` is NULL, not 0, on every row of a real store** — 440 of 440
  /// visits and 314 of 314 locations here. So the obvious `ZHIDDEN = 0` matches
  /// **nothing** and the command returns an empty history, which reads exactly
  /// like "you have never been anywhere". SQLite's `IS NOT 1` covers NULL and 0
  /// together, and is the only spelling that does.
  static func notHidden(_ alias: String) -> String {
    "\(alias).ZHIDDEN IS NOT 1"
  }

  /// `--since` / `--before` as a half-open window on Apple-epoch seconds.
  /// Bound as doubles: the column is a `REAL`, and comparing it to the text
  /// `strftime` returns matches nothing without erroring.
  private static func appendDateWindow(
    _ request: VisitsRequest, to sql: inout String, binds: inout [MapsDatabase.Bind], column: String
  ) {
    let now = Date()
    if let since = request.sinceDays {
      let cutoff = now.addingTimeInterval(-Double(since) * 86_400)
      sql += "\n  AND \(column) >= ?"
      binds.append(.double(MapsEpoch.raw(from: cutoff)))
    }
    if let before = request.beforeDays {
      let cutoff = now.addingTimeInterval(-Double(before) * 86_400)
      sql += "\n  AND \(column) <= ?"
      binds.append(.double(MapsEpoch.raw(from: cutoff)))
    }
  }

  private static func terms(_ search: String?) -> [String]? {
    guard let search, !search.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let parsed = parseSearchTerms(search).map { $0.lowercased() }
    return parsed.isEmpty ? nil : parsed
  }

  private static func filter(_ places: [Place], search: String?) -> [Place] {
    guard let terms = terms(search) else { return places }
    return places.filter { containsAllTerms($0.haystack, terms) }
  }
}
