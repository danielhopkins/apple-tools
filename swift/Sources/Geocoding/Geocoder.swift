import CoreLocation
import Foundation
import MapKit

/// Turning a place name or an address into a coordinate.
///
/// 🛑 **This is the only part of apple-tools that touches the network**, and it
/// is in its own target so that stays visible. `MKLocalSearch` and `CLGeocoder`
/// both query Apple's servers. Nothing else in the repo makes a network call,
/// and the README says so, so a new dependency on this target is a decision
/// rather than an implementation detail.
///
/// ⚠️ **Neither API needs Location Services.** They ask Apple where a *named
/// place* is; they never ask where the user is. So this costs no new TCC grant.
/// Nothing here reads `CLLocationManager`.
///
/// 🛑 **It must not live in `MapsLibrary`.** `reminders` needs geocoding, and
/// `reminders` re-executes itself *disclaimed* so its Reminders grant follows
/// the binary. Measured: a disclaimed process **loses the terminal's Full Disk
/// Access** — a probe that read `MapsSync_0.0.1` fine as a plain process failed
/// with "You don't have permission" once disclaimed. So `reminders` can never
/// read the Maps store, and a geocoder it can use cannot link one.

public enum GeocodeSource: String, Sendable {
  /// A place the user has actually been. Local, free, and usually the one they
  /// mean when they say a bare name like "costco".
  case visitedPlace = "visited-place"
  /// A place saved in one of the user's Maps guides.
  case guidePlace = "guide-place"
  /// Apple's Maps search. A network call.
  case mapsSearch = "maps-search"
  /// Apple's address geocoder. A network call.
  case addressLookup = "address-lookup"
  /// A literal `lat,lon` the caller typed. No lookup at all.
  case coordinate = "coordinate"

  public var isNetwork: Bool { self == .mapsSearch || self == .addressLookup }
}

public struct GeocodeResult: Sendable {
  public let name: String
  public let address: String?
  public let latitude: Double
  public let longitude: Double
  public let source: GeocodeSource
  /// How many times the user has been here, when the answer came from the
  /// local store. This is what makes a local hit rankable against another.
  public let visitCount: Int?
  public let category: String?

  public init(
    name: String, address: String? = nil, latitude: Double, longitude: Double,
    source: GeocodeSource, visitCount: Int? = nil, category: String? = nil
  ) {
    self.name = name
    self.address = address
    self.latitude = latitude
    self.longitude = longitude
    self.source = source
    self.visitCount = visitCount
    self.category = category
  }

  public var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

public enum GeocodeError: Error, LocalizedError {
  case noResults(String)
  case timedOut(String)
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .noResults(let message): return message
    case .timedOut(let message): return message
    case .failed(let message): return message
    }
  }
}

// MARK: - Literal coordinates

public enum Coordinate {
  /// Parse `40.03,-105.23` or `40.03, -105.23`.
  ///
  /// Accepting a literal pair is what lets a tool that cannot read the Maps
  /// store still be driven from one:
  ///
  ///     apple maps geocode "costco" --json | jq -r '.[0] | "\(.latitude),\(.longitude)"'
  ///
  /// ⚠️ Ranges are checked. A swapped pair like `-105.23,40.03` is a longitude
  /// in the latitude slot, and silently accepting it puts the reminder in the
  /// wrong hemisphere rather than failing.
  public static func parse(_ text: String) -> CLLocationCoordinate2D? {
    let parts = text.split(separator: ",", maxSplits: 1).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard parts.count == 2,
      let latitude = Double(parts[0]), let longitude = Double(parts[1]),
      (-90...90).contains(latitude), (-180...180).contains(longitude)
    else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  /// Whether a string looks like a coordinate pair at all, so a failed parse
  /// can say "that is out of range" rather than searching Maps for it.
  public static func looksLikeCoordinates(_ text: String) -> Bool {
    labelSplit(text) != nil
  }

  /// Parse `Costco Wholesale@39.959595,-105.174511`.
  ///
  /// A bare pair has no label. This form exists so a coordinate resolved
  /// somewhere else keeps its name: without it, piping `apple maps geocode`
  /// into `--at` produces a reminder whose location reads "39.96,-105.17",
  /// which is correct and useless. `geocode --json` emits this string as `at`.
  ///
  /// ⚠️ Split on the **last** `@`, and only when the right-hand side really
  /// parses. A place name may contain one, and treating "Bar@Home, Boulder" as
  /// a labelled coordinate would send the lookup somewhere else entirely.
  public static func parseLabelled(_ text: String) -> (label: String?, coordinate: CLLocationCoordinate2D)? {
    guard let split = labelSplit(text), let coordinate = parse(split.pair) else { return nil }
    return (split.label, coordinate)
  }

  /// Format for round-tripping through `--at`.
  public static func label(_ name: String, _ latitude: Double, _ longitude: Double) -> String {
    String(format: "%@@%.6f,%.6f", name, latitude, longitude)
  }

  private static func labelSplit(_ text: String) -> (label: String?, pair: String)? {
    func isPair(_ candidate: String) -> Bool {
      let parts = candidate.split(separator: ",", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      return parts.count == 2 && parts.allSatisfy { Double($0) != nil }
    }

    if isPair(text) { return (nil, text) }
    guard let at = text.lastIndex(of: "@") else { return nil }
    let pair = String(text[text.index(after: at)...])
    guard isPair(pair) else { return nil }
    let label = String(text[text.startIndex..<at]).trimmingCharacters(in: .whitespaces)
    return (label.isEmpty ? nil : label, pair)
  }
}

extension GeocodeResult {
  /// The `Name@lat,lon` string to hand back to a `--at` flag elsewhere.
  public var atForm: String {
    Coordinate.label(name, latitude, longitude)
  }
}

// MARK: - Network

public struct NetworkGeocoder {
  /// Wall-clock bound on a lookup. A network call in a CLI that never returns
  /// is worse than one that fails, and every other outward call in this repo
  /// is bounded the same way.
  public let timeout: TimeInterval

  public init(timeout: TimeInterval = 15) {
    self.timeout = timeout
  }

  /// Search Apple Maps for a place.
  ///
  /// ⚠️ **A region bias changes the answer completely.** `MKLocalSearch` for
  /// "costco" with no region returns whatever Apple ranks globally. Pass the
  /// user's own area — `apple maps geocode` derives it from where they have
  /// actually been — and the results become the ones they mean.
  public func search(
    _ query: String, near: CLLocationCoordinate2D? = nil, spanMeters: Double = 50_000,
    limit: Int = 10
  ) throws -> [GeocodeResult] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    if let near {
      request.region = MKCoordinateRegion(
        center: near, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    }

    let outcome = try run(query: query) { done in
      let search = MKLocalSearch(request: request)
      search.start { response, error in
        if let error { return done(.failure(error)) }
        let items = response?.mapItems ?? []
        done(.success(items.prefix(limit).map(Self.result)))
      }
    }
    return outcome
  }

  /// Resolve an address string. Used as a backstop when Maps search finds
  /// nothing, because the two disagree: `CLGeocoder` handles a bare street
  /// address that `MKLocalSearch` returns no business for.
  public func lookupAddress(_ query: String) throws -> [GeocodeResult] {
    try run(query: query) { done in
      CLGeocoder().geocodeAddressString(query) { placemarks, error in
        if let error { return done(.failure(error)) }
        let results = (placemarks ?? []).compactMap { placemark -> GeocodeResult? in
          guard let location = placemark.location else { return nil }
          return GeocodeResult(
            name: placemark.name ?? query,
            address: Self.address(from: placemark),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            source: .addressLookup)
        }
        done(.success(results))
      }
    }
  }

  /// Maps search first, address lookup as a backstop, and a clear error when
  /// neither finds anything.
  public func resolve(
    _ query: String, near: CLLocationCoordinate2D? = nil, limit: Int = 10
  ) throws -> [GeocodeResult] {
    let found = try search(query, near: near, limit: limit)
    if !found.isEmpty { return found }

    let byAddress = try lookupAddress(query)
    if !byAddress.isEmpty { return byAddress }

    throw GeocodeError.noResults(
      "Apple Maps found nothing for '\(query)'. Try a fuller address, or add "
        + "--near to say roughly where to look.")
  }

  // MARK: - Bridging a callback API into a CLI

  /// 🛑 **A semaphore deadlocks here, and that is not obvious.** Both
  /// `MKLocalSearch` and `CLGeocoder` deliver their completion **on the main
  /// queue**. A command-line tool runs its work on the main *thread* without
  /// ever entering a run loop, so nothing drains that queue: blocking on a
  /// semaphore waits forever for a callback that cannot be delivered. Measured
  /// — the first version of this timed out at 15s on every network lookup while
  /// the local path answered instantly.
  ///
  /// So the request starts on the calling (main) thread and the run loop is
  /// driven by hand until the completion lands. `run(mode:before:)` returns
  /// early whenever an input source fires, so the 0.05s slice is a ceiling on
  /// latency after the answer arrives, not a poll interval.
  ///
  /// ⚠️ Call this from the main thread. It is where a `main.swift` body already
  /// runs, and driving `RunLoop.main` from anywhere else does not drain it.
  private func run(
    query: String, _ start: (@escaping (Result<[GeocodeResult], Error>) -> Void) -> Void
  ) throws -> [GeocodeResult] {
    let box = ResultBox()
    start { outcome in box.set(outcome) }

    let deadline = Date().addingTimeInterval(timeout)
    while box.take() == nil, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    guard box.take() != nil else {
      throw GeocodeError.timedOut(
        "Apple Maps did not answer for '\(query)' within \(Int(timeout))s. "
          + "This is the one command here that needs the network.")
    }

    switch box.take() {
    case .success(let results): return results
    case .failure(let error):
      // A network failure and a "no such place" both arrive as an error, and
      // only the message tells them apart. Pass it through rather than
      // flattening both into "not found".
      throw GeocodeError.failed("Apple Maps could not resolve '\(query)': \(error.localizedDescription)")
    case nil:
      throw GeocodeError.failed("Apple Maps returned nothing for '\(query)'.")
    }
  }

  private static func result(_ item: MKMapItem) -> GeocodeResult {
    let placemark = item.placemark
    return GeocodeResult(
      name: item.name ?? placemark.name ?? "(unnamed)",
      address: address(from: placemark),
      latitude: placemark.coordinate.latitude,
      longitude: placemark.coordinate.longitude,
      source: .mapsSearch,
      category: item.pointOfInterestCategory.map {
        // The raw category is `MKPOICategoryCafe`; the readable half is what a
        // user recognises, and matches how the Maps store spells its own.
        $0.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
      })
  }

  private static func address(from placemark: CLPlacemark) -> String? {
    var parts: [String] = []
    if let street = [placemark.subThoroughfare, placemark.thoroughfare]
      .compactMap({ $0 }).joined(separator: " ").nilIfEmpty
    {
      parts.append(street)
    }
    if let city = placemark.locality { parts.append(city) }
    if let state = placemark.administrativeArea { parts.append(state) }
    if let postal = placemark.postalCode { parts.append(postal) }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }
}

/// A `final class` holding the outcome, so the escaping completion has
/// something to write into that Swift will let it capture.
private final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<[GeocodeResult], Error>?

  func set(_ outcome: Result<[GeocodeResult], Error>) {
    lock.lock()
    defer { lock.unlock() }
    value = outcome
  }

  func take() -> Result<[GeocodeResult], Error>? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
