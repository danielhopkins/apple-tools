import AppleToolsSearch
import CoreLocation
import Foundation
import Geocoding

/// Resolving a place name against the user's own Maps data, with no network
/// call at all.
///
/// This exists because the answer is usually *better* than the network's, not
/// only cheaper. "costco" typed by this user means the Superior one they have
/// been to eight times, not whichever Costco Apple ranks first. A visited place
/// carries a real coordinate already, so nothing has to be geocoded.
///
/// 🛑 **Only `apple-maps` can use this.** Reading the store needs Full Disk
/// Access, which is attributed to the calling terminal. `reminders` re-executes
/// itself disclaimed and therefore loses that grant — measured, not assumed.
/// See `Geocoding.Geocoder` for the probe.
public struct LocalGeocoder {
  private let visits: VisitStore
  private let guides: GuideStore

  public init(database: MapsDatabase) {
    visits = VisitStore(database: database)
    guides = GuideStore(database: database)
  }

  /// Places matching `query`, best first.
  ///
  /// Ranking is deliberate and in this order:
  ///
  /// 1. An exact name match beats a partial one. "Safeway" should not lose to
  ///    "Safeway Fuel Station" because the latter was visited more.
  /// 2. Among equals, more visits wins. That is the whole reason to prefer the
  ///    local answer.
  /// 3. A visited place beats a guide place. The user has been to one.
  public func resolve(_ query: String, limit: Int = 10) throws -> [GeocodeResult] {
    let terms = parseSearchTerms(query).map { $0.lowercased() }
    guard !terms.isEmpty else { return [] }
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

    var results: [(rank: Int, visits: Int, result: GeocodeResult)] = []

    for place in try visits.places() where containsAllTerms(place.haystackForGeocoding, terms) {
      results.append(
        (
          rank: place.name.lowercased() == needle ? 0 : 1,
          visits: place.visitCount,
          result: GeocodeResult(
            name: place.name,
            address: place.address,
            latitude: place.latitude,
            longitude: place.longitude,
            source: .visitedPlace,
            visitCount: place.visitCount,
            category: place.category)
        ))
    }

    for guide in try guides.guides() {
      for item in guide.places where containsAllTerms(item.haystackForGeocoding, terms) {
        // A guide place with no coordinate is a row we cannot answer with.
        // Reporting 0,0 would put the reminder in the Gulf of Guinea.
        guard item.latitude != 0 || item.longitude != 0 else { continue }
        results.append(
          (
            rank: item.name.lowercased() == needle ? 2 : 3,
            visits: 0,
            result: GeocodeResult(
              name: item.name,
              address: item.address,
              latitude: item.latitude,
              longitude: item.longitude,
              source: .guidePlace,
              category: item.categories.first)
          ))
      }
    }

    results.sort { left, right in
      if left.rank != right.rank { return left.rank < right.rank }
      return left.visits > right.visits
    }

    // One real place can appear as several rows — a visited place and a guide
    // entry for the same shop. Collapse on rounded coordinates, keeping the
    // best-ranked, so the caller is not asked to choose between duplicates.
    var seen = Set<String>()
    var deduped: [GeocodeResult] = []
    for entry in results {
      let key = String(
        format: "%.4f,%.4f", entry.result.latitude, entry.result.longitude)
      if seen.insert(key).inserted { deduped.append(entry.result) }
      if deduped.count == limit { break }
    }
    return deduped
  }

  /// Where the user's recent life happens, for biasing a Maps search.
  ///
  /// ⚠️ **A mean of every visit is the wrong centre**, because one trip abroad
  /// drags it into the ocean. This takes the median latitude and longitude of
  /// recent visits instead, which ignores outliers.
  ///
  /// This is why `apple maps geocode` beats a bare `MKLocalSearch`: it knows
  /// roughly where the user is without ever asking Location Services.
  public func searchCentre(recentDays: Int = 120) throws -> CLLocationCoordinate2D? {
    var request = VisitsRequest()
    request.sinceDays = recentDays
    var places = try visits.places(request)
    // A user who has not moved in months still deserves a bias.
    if places.isEmpty { places = try visits.places() }
    guard !places.isEmpty else { return nil }

    let latitudes = places.map(\.latitude).sorted()
    let longitudes = places.map(\.longitude).sorted()
    return CLLocationCoordinate2D(
      latitude: latitudes[latitudes.count / 2],
      longitude: longitudes[longitudes.count / 2])
  }
}

extension Place {
  /// Name, address, city and categories. Same fields `--search` matches, so a
  /// place findable by `apple maps places` is findable by `geocode`.
  var haystackForGeocoding: String { haystack }
}

extension GuidePlace {
  var haystackForGeocoding: String { haystack }
}
