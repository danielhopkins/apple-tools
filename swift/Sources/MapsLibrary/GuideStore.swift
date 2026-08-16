import AppleToolsSearch
import Foundation

/// Apple Maps guides — the lists Maps.app calls "My Guides".
///
/// Three tables carry them. `ZCOLLECTION` is the guide. `ZCOLLECTIONITEM` is a
/// saved place. `Z_7PLACES` is the many-to-many join between them, and it is
/// genuinely many-to-many: one place here belongs to two guides.

public struct GuidePlace {
  public let id: Int
  public let identifier: String?
  /// What Maps shows. `ZCUSTOMNAME` is the name as saved and is set on 122 of
  /// 126 items here, so it wins; `ZMAPITEMNAME` is the fallback.
  public let name: String
  /// Present only when the saved name differs from the place's own name.
  public let mapItemName: String?
  public let address: String?
  public let categories: [String]
  public let latitude: Double
  public let longitude: Double
  public let muid: Int?
  /// The per-place note Maps.app lets you attach. Empty on every item here, so
  /// the plain output omits it rather than printing a blank field.
  public let note: String?
  /// True when the item is a pin the user dropped rather than a real place.
  public let isDroppedPin: Bool
  public let created: Date?

  var haystack: String {
    ([name, mapItemName ?? "", address ?? "", note ?? ""] + categories).joined(separator: " ")
  }
}

public struct Guide {
  public let id: Int
  public let identifier: String?
  public let title: String
  public let summary: String?
  /// The count Maps maintains on the row itself. Kept by a Core Data trigger on
  /// `Z_7PLACES`, and it agreed exactly with the join on this store (115 both
  /// ways), so a disagreement is worth reporting rather than hiding.
  public let declaredCount: Int
  public let created: Date?
  public let modified: Date?
  public let places: [GuidePlace]

  /// What the join really holds. `places.count` and `declaredCount` should
  /// match; `status` compares them.
  public var placeCount: Int { places.count }

  var haystack: String {
    ([title, summary ?? ""] + places.map(\.name)).joined(separator: " ")
  }
}

public final class GuideStore {
  private let database: MapsDatabase

  public init(database: MapsDatabase) {
    self.database = database
  }

  /// Every guide, in the order Maps.app shows them, each with its places.
  ///
  /// 🛑 **Places come through `Z_7PLACES`, never from `ZCOLLECTIONITEM`
  /// directly.** 12 of the 126 item rows here belong to no guide at all — the
  /// same orphan pattern `ZVISITEDLOCATION` shows. Listing the item table
  /// directly invents saved places the user cannot see in Maps.app.
  public func guides(search: String? = nil) throws -> [Guide] {
    let items = try placesByGuide()

    let rows = try database.query(
      """
      SELECT Z_PK, ZIDENTIFIER, ZTITLE, ZCOLLECTIONDESCRIPTION, ZPLACESCOUNT,
             ZCREATETIME, ZMODIFICATIONTIME
      FROM ZCOLLECTION
      ORDER BY ZPOSITIONINDEX, Z_PK
      """)

    var guides = rows.map { row -> Guide in
      let id = MapsColumn.int(row["Z_PK"]) ?? 0
      let title = MapsColumn.string(row["ZTITLE"]) ?? "(untitled guide)"
      // Maps seeds the default "My Places" guide with a description equal to
      // its own title. Printing that back is noise, not information.
      var summary = MapsColumn.string(row["ZCOLLECTIONDESCRIPTION"])
      if summary == title { summary = nil }
      return Guide(
        id: id,
        identifier: MapsColumn.uuid(row["ZIDENTIFIER"]),
        title: title,
        summary: summary,
        declaredCount: MapsColumn.int(row["ZPLACESCOUNT"]) ?? 0,
        created: MapsColumn.date(row["ZCREATETIME"]),
        modified: MapsColumn.date(row["ZMODIFICATIONTIME"]),
        places: items[id] ?? [])
    }

    if let terms = Self.terms(search) {
      guides = guides.filter { containsAllTerms($0.haystack, terms) }
    }
    return guides
  }

  /// One guide by name or by numeric id.
  ///
  /// ⚠️ **An ambiguous name is an error, not a guess.** Guide titles are not
  /// unique — nothing stops two guides called "Chicago" — and showing the wrong
  /// one is a mistake the reader notices much later, if at all. Same rule
  /// `apple messages` uses for an ambiguous chat reference.
  public func guide(matching reference: String) throws -> Guide {
    let all = try guides()

    if let id = Int(reference), let match = all.first(where: { $0.id == id }) {
      return match
    }
    if let match = all.first(where: { $0.identifier?.caseInsensitiveCompare(reference) == .orderedSame }) {
      return match
    }

    let exact = all.filter { $0.title.caseInsensitiveCompare(reference) == .orderedSame }
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 { throw Self.ambiguous(reference, exact) }

    let partial = all.filter { $0.title.range(of: reference, options: .caseInsensitive) != nil }
    if partial.count == 1 { return partial[0] }
    if partial.count > 1 { throw Self.ambiguous(reference, partial) }

    throw MapsStoreError.query(
      "No guide matches '\(reference)'. Run `apple maps guides` to list them.")
  }

  private static func ambiguous(_ reference: String, _ matches: [Guide]) -> MapsStoreError {
    let lines = matches.map { guide -> String in
      let count = guide.placeCount == 1 ? "1 place" : "\(guide.placeCount) places"
      return "  \(guide.id)  \(guide.title) (\(count))"
    }
    return MapsStoreError.query(
      "'\(reference)' matches \(matches.count) guides. Name one by id:\n"
        + lines.joined(separator: "\n"))
  }

  // MARK: - Places

  private func placesByGuide() throws -> [Int: [GuidePlace]] {
    let rows = try database.query(
      """
      SELECT p.Z_7COLLECTIONS AS guide_id,
             ci.Z_PK, ci.ZIDENTIFIER, ci.ZCUSTOMNAME, ci.ZMAPITEMNAME, ci.ZMAPITEMADDRESS,
             ci.ZMAPITEMCATEGORY, ci.ZLATITUDE, ci.ZLONGITUDE, ci.ZMUID, ci.ZPLACEITEMNOTE,
             ci.ZDROPPEDPINCOORDINATE, ci.ZCREATETIME
      FROM Z_7PLACES p
      JOIN ZCOLLECTIONITEM ci ON ci.Z_PK = p.Z_8PLACES
      ORDER BY p.Z_7COLLECTIONS, ci.ZPOSITIONINDEX, ci.Z_PK
      """)

    var byGuide: [Int: [GuidePlace]] = [:]
    for row in rows {
      guard let guideID = MapsColumn.int(row["guide_id"]) else { continue }
      let saved = MapsColumn.string(row["ZCUSTOMNAME"])
      let original = MapsColumn.string(row["ZMAPITEMNAME"])
      let place = GuidePlace(
        id: MapsColumn.int(row["Z_PK"]) ?? 0,
        identifier: MapsColumn.uuid(row["ZIDENTIFIER"]),
        name: saved ?? original ?? "(unnamed place)",
        // Only worth showing when the user renamed the place.
        mapItemName: (saved != nil && original != nil && saved != original) ? original : nil,
        address: MapsColumn.string(row["ZMAPITEMADDRESS"]),
        categories: MapsColumn.categories(row["ZMAPITEMCATEGORY"]),
        latitude: MapsColumn.double(row["ZLATITUDE"]) ?? 0,
        longitude: MapsColumn.double(row["ZLONGITUDE"]) ?? 0,
        muid: MapsColumn.int(row["ZMUID"]),
        note: MapsColumn.string(row["ZPLACEITEMNOTE"]),
        isDroppedPin: row["ZDROPPEDPINCOORDINATE"] != nil,
        created: MapsColumn.date(row["ZCREATETIME"]))
      byGuide[guideID, default: []].append(place)
    }
    return byGuide
  }

  /// `ZCOLLECTIONITEM` rows in no guide. Reported by `status` as the evidence
  /// for why the item count is higher than the sum of the guides.
  public func orphanedItemCount() throws -> Int {
    let rows = try database.query(
      """
      SELECT COUNT(*) AS n FROM ZCOLLECTIONITEM ci
      WHERE NOT EXISTS (SELECT 1 FROM Z_7PLACES p WHERE p.Z_8PLACES = ci.Z_PK)
      """)
    return MapsColumn.int(rows.first?["n"]) ?? 0
  }

  private static func terms(_ search: String?) -> [String]? {
    guard let search, !search.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let parsed = parseSearchTerms(search).map { $0.lowercased() }
    return parsed.isEmpty ? nil : parsed
  }
}
