import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import CoreLocation
import Foundation
import Geocoding
import MapsLibrary

func warn(_ message: String) {
  FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

// MARK: - Rendering

enum Output {
  static let compactDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()

  static let dayOnly: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  static let isoDate: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func json(_ value: Any) throws {
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
  }

  static func encode(_ place: Place) -> [String: Any] {
    var payload: [String: Any] = [
      "id": place.id,
      "name": place.name,
      "latitude": place.latitude,
      "longitude": place.longitude,
      "visits": place.visitCount,
    ]
    if let identifier = place.identifier { payload["identifier"] = identifier }
    if let address = place.address { payload["address"] = address }
    if let city = place.city { payload["city"] = city }
    if !place.categories.isEmpty {
      payload["categories"] = place.categories
      payload["category"] = place.categories[0]
    }
    // Raw on purpose: Apple's own enum, and nothing here knows the names.
    if let top = place.topLevelCategory { payload["top_level_category"] = top }
    if let muid = place.muid { payload["muid"] = muid }
    if let first = place.firstVisit { payload["first_visit"] = isoDate.string(from: first) }
    if let latest = place.latestVisit { payload["latest_visit"] = isoDate.string(from: latest) }
    return payload
  }

  static func encode(_ visit: Visit) -> [String: Any] {
    var payload: [String: Any] = [
      "id": visit.id,
      "place": encode(visit.place),
    ]
    if let date = visit.date { payload["date"] = isoDate.string(from: date) }
    // Two values appear on a real store and the schema does not say what they
    // mean, so the number goes through unlabelled rather than being named.
    if let classification = visit.classification { payload["classification"] = classification }
    return payload
  }

  static func encode(_ item: GuidePlace) -> [String: Any] {
    var payload: [String: Any] = [
      "id": item.id,
      "name": item.name,
      "latitude": item.latitude,
      "longitude": item.longitude,
    ]
    if let identifier = item.identifier { payload["identifier"] = identifier }
    if let original = item.mapItemName { payload["map_item_name"] = original }
    if let address = item.address { payload["address"] = address }
    if !item.categories.isEmpty {
      payload["categories"] = item.categories
      payload["category"] = item.categories[0]
    }
    if let muid = item.muid { payload["muid"] = muid }
    if let note = item.note { payload["note"] = note }
    if item.isDroppedPin { payload["dropped_pin"] = true }
    if let created = item.created { payload["created"] = isoDate.string(from: created) }
    return payload
  }

  static func encode(_ guide: Guide, includePlaces: Bool) -> [String: Any] {
    var payload: [String: Any] = [
      "id": guide.id,
      "title": guide.title,
      "places_count": guide.placeCount,
    ]
    if let identifier = guide.identifier { payload["identifier"] = identifier }
    if let summary = guide.summary { payload["description"] = summary }
    if let created = guide.created { payload["created"] = isoDate.string(from: created) }
    if let modified = guide.modified { payload["modified"] = isoDate.string(from: modified) }
    // Only surfaced when Maps' own counter disagrees with the join, which would
    // mean the store is inconsistent and the number cannot be trusted.
    if guide.declaredCount != guide.placeCount {
      payload["declared_places_count"] = guide.declaredCount
    }
    if includePlaces { payload["places"] = guide.places.map(encode) }
    return payload
  }

  static func encode(_ result: GeocodeResult) -> [String: Any] {
    var payload: [String: Any] = [
      "name": result.name,
      "latitude": result.latitude,
      "longitude": result.longitude,
      "source": result.source.rawValue,
      // The one field a caller needs to know whether this answer left the
      // machine. Never inferred from `source` by a consumer that may not know
      // every case.
      "network": result.source.isNetwork,
    ]
    if let address = result.address { payload["address"] = address }
    if let category = result.category { payload["category"] = category }
    if let visits = result.visitCount { payload["visits"] = visits }
    // Ready to hand straight to `apple reminders --at` or `apple calendar --at`,
    // which is the whole point of this command. Carrying the name means the
    // reminder reads "Costco Wholesale" rather than "39.96,-105.17".
    payload["at"] = result.atForm
    return payload
  }

  static func line(_ result: GeocodeResult) {
    print("\(Style.title(result.name))  \(Style.identifier(coordinates(result)))")
    var detail: [String] = []
    if let address = result.address { detail.append(Style.dim(address)) }
    if let visits = result.visitCount, visits > 0 {
      detail.append(Style.dim(visits == 1 ? "1 visit" : "\(visits) visits"))
    }
    detail.append(
      result.source.isNetwork
        ? Style.warning(result.source.rawValue) : Style.success(result.source.rawValue))
    print("    \(detail.joined(separator: "  "))")
  }

  /// Six decimal places is about 0.1 m, which is finer than any source here.
  static func coordinates(_ result: GeocodeResult) -> String {
    String(format: "%.6f,%.6f", result.latitude, result.longitude)
  }

  /// `Boulder · Swimming Lessons`, dropping whichever half is missing.
  static func context(_ place: Place) -> String? {
    let parts = [place.city, place.category].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  static func line(_ place: Place) {
    let count = place.visitCount == 1 ? "1 visit" : "\(place.visitCount) visits"
    print("\(Style.title(place.name))  \(Style.dim(count))")

    var detail: [String] = []
    if let context = context(place) { detail.append(Style.dim(context)) }
    if let latest = place.latestVisit {
      detail.append(Style.time("last \(dayOnly.string(from: latest))"))
    }
    if !detail.isEmpty { print("    \(detail.joined(separator: "  "))") }
  }

  static func line(_ visit: Visit) {
    let when = visit.date.map { compactDate.string(from: $0) } ?? "unknown date"
    print("\(Style.time(when))  \(Style.title(visit.place.name))")
    if let context = context(visit.place) { print("    \(Style.dim(context))") }
  }

  static func line(_ item: GuidePlace) {
    var name = Style.title(item.name)
    if item.isDroppedPin { name += "  \(Style.dim("dropped pin"))" }
    print("  \(name)")
    if let address = item.address { print("    \(Style.dim(address))") }
    if let note = item.note { print("    \(Style.label(note))") }
  }
}

/// Open the store, and say so on stderr when the write-ahead log was skipped —
/// a stale read looks exactly like a complete one.
func openDatabase() throws -> MapsDatabase {
  let database = try MapsDatabase.open()
  if database.isStale {
    warn(
      "warning: the write-ahead log could not be replayed, so recent visits may be missing.")
  }
  return database
}

// MARK: - Commands

struct AppleMaps: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "apple-maps",
    abstract: "Read Apple Maps visited places and guides",
    discussion: """
      Reads Maps' own store directly, so it works with Maps.app closed and
      answers in milliseconds. Reading it needs Full Disk Access for this
      terminal.

      Maps.app has no AppleScript dictionary, and its App Intents only drive
      navigation, so reading this store is the only route to visits and guides.
      Everything here is read-only, and deliberately so: CloudKit mirrors the
      store, and a write would fight the sync engine.

      ⚠️ This is Maps' "Visited Places", not Significant Locations. Significant
      Locations belongs to routined, under /var/db/locationd, which no
      unprivileged process can read. Do not report one as the other.
      """,
    version: appleToolsVersion,
    subcommands: [Places.self, Visits.self, Guides.self, Geocode.self, Status.self],
    defaultSubcommand: Places.self
  )
}

struct Geocode: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Turn a place name or address into a coordinate",
    discussion: """
      Answers from the user's own Maps data first, and asks Apple Maps only if
      nothing local matches. A place they have been to already carries a real
      coordinate, so the local answer costs no network call and is usually the
      one they mean: "costco" is the branch they actually go to, not whichever
      branch Apple ranks first.

      🛑 The network fallback is the only part of apple-tools that leaves the
      machine. --local-only refuses it; --network-only skips the local store.

      A Maps search is biased toward where the user has recently been, taken
      from their own visit history. Nothing asks Location Services where they
      are now. Override with --near, which takes "lat,lon" or a place name.
      """
  )

  @Argument(help: "A place name, an address, or \"lat,lon\"")
  var query: String

  @Option(name: .long, help: "Bias the search near this place or \"lat,lon\"")
  var near: String?

  @Option(name: .long, help: "Maximum results")
  var limit: Int = 5

  @Flag(name: .long, help: "Never touch the network; only places you have been or saved")
  var localOnly = false

  @Flag(name: .long, help: "Skip your own places and ask Apple Maps")
  var networkOnly = false

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    guard !(localOnly && networkOnly) else {
      throw ValidationError("--local-only and --network-only are opposites; pass one.")
    }

    // A literal pair is not a lookup at all, and answering it without touching
    // the store or the network keeps `--local-only` honest for scripted input.
    if Coordinate.looksLikeCoordinates(query) {
      guard let parsed = Coordinate.parseLabelled(query) else {
        throw ValidationError(
          "'\(query)' looks like a coordinate pair but is out of range. "
            + "Latitude is -90..90 and longitude is -180..180, in that order.")
      }
      let result = GeocodeResult(
        name: parsed.label ?? query,
        latitude: parsed.coordinate.latitude, longitude: parsed.coordinate.longitude,
        source: .coordinate)
      try emit([result])
      return
    }

    var results: [GeocodeResult] = []
    var localFailure: String?

    if !networkOnly {
      do {
        let local = LocalGeocoder(database: try openDatabase())
        results = try local.resolve(query, limit: limit)
      } catch {
        // Without Full Disk Access the local half cannot answer. That is a
        // reason to fall through to the network, not to fail — but it must be
        // said, or a network answer looks like a local one.
        localFailure = error.localizedDescription
      }
    }

    if results.isEmpty && !localOnly {
      if let localFailure { warn("note: could not read your Maps store (\(localFailure))") }
      results = try NetworkGeocoder().resolve(query, near: try searchBias(), limit: limit)
    }

    if results.isEmpty {
      if let localFailure { throw GeocodeError.failed(localFailure) }
      throw GeocodeError.noResults(
        "Nothing in your visited places or guides matches '\(query)'. "
          + "Drop --local-only to ask Apple Maps.")
    }
    try emit(results)
  }

  /// Where to centre a Maps search. An explicit `--near` wins; otherwise the
  /// user's own recent visits provide it, and a store we cannot read simply
  /// means no bias rather than an error.
  private func searchBias() throws -> CLLocationCoordinate2D? {
    if let near {
      if let literal = Coordinate.parse(near) { return literal }
      guard let resolved = try NetworkGeocoder().resolve(near, limit: 1).first else { return nil }
      return resolved.coordinate
    }
    guard let database = try? MapsDatabase.open() else { return nil }
    return try? LocalGeocoder(database: database).searchCentre()
  }

  private func emit(_ results: [GeocodeResult]) throws {
    if json {
      try Output.json(results.map(Output.encode))
      return
    }
    for result in results { Output.line(result) }
  }
}

/// Shared by `places` and `visits` so the two cannot drift on what a filter means.
struct FilterOptions: ParsableArguments {
  @Option(name: .long, help: "Only visits from the last N days")
  var since: Int?

  @Option(name: .long, help: "Only visits older than N days")
  var before: Int?

  @Option(name: .long, help: "Match name, address, city, or category")
  var search: String?

  func build() -> VisitsRequest {
    var request = VisitsRequest()
    request.sinceDays = since
    request.beforeDays = before
    request.search = search
    return request
  }
}

struct Places: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List places you have been, most-visited first",
    discussion: """
      One line per place, with how many times you went and when you last did.
      This is the grouped view of the same data `visits` prints one arrival at
      a time.

      A place counts only when it has at least one recorded visit. Maps keeps
      duplicate location rows that carry no visit, and counting those would
      report places you have never been.

      A search query is an AND of substring terms, the same rule `apple mail`
      and `apple messages` use: `boulder park` matches both words in any order,
      and `"scott carpenter"` requires the phrase.
      """
  )

  @OptionGroup var filters: FilterOptions

  @Option(name: .long, help: "Only places visited at least N times")
  var minVisits: Int?

  @Option(name: .long, help: "Maximum places to list")
  var limit: Int = 40

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    var request = filters.build()
    request.minVisits = minVisits
    request.limit = limit

    let store = VisitStore(database: try openDatabase())
    let places = try store.places(request)

    if json {
      try Output.json(places.map(Output.encode))
      return
    }
    if places.isEmpty {
      print("No visited places found.")
      return
    }
    for place in places { Output.line(place) }
  }
}

struct Visits: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List individual visits, newest first",
    discussion: """
      One line per arrival. Use `places` instead when the question is where you
      go rather than when you went.

      ⚠️ A visit records a start time and nothing else. The store keeps no end
      time, so it cannot say how long you stayed anywhere.
      """
  )

  @OptionGroup var filters: FilterOptions

  @Option(name: .long, help: "Maximum visits to list")
  var limit: Int = 50

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    var request = filters.build()
    request.limit = limit

    let store = VisitStore(database: try openDatabase())
    let visits = try store.visits(request)

    if json {
      try Output.json(visits.map(Output.encode))
      return
    }
    if visits.isEmpty {
      print("No visits found.")
      return
    }
    for visit in visits { Output.line(visit) }
  }
}

struct Guides: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List your Maps guides, or show the places in one",
    discussion: """
      With no argument, lists every guide with its place count. With a guide
      named by id, title, or part of a title, lists the places it holds.

      An ambiguous title is an error naming the candidates, never a guess.
      """
  )

  @Argument(help: "A guide id, title, or part of a title")
  var guide: String?

  @Option(name: .long, help: "Match a guide's title, description, or place names")
  var search: String?

  @Flag(name: .long, help: "Include every guide's places in the listing")
  var places = false

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    let store = GuideStore(database: try openDatabase())

    if let reference = guide {
      guard search == nil else {
        throw ValidationError("--search lists guides; drop it to show one guide by name.")
      }
      let match = try store.guide(matching: reference)
      if json {
        try Output.json(Output.encode(match, includePlaces: true))
        return
      }
      show(match)
      return
    }

    let guides = try store.guides(search: search)
    if json {
      try Output.json(guides.map { Output.encode($0, includePlaces: places) })
      return
    }
    if guides.isEmpty {
      print("No guides found.")
      return
    }
    for guide in guides {
      list(guide)
      if places { for place in guide.places { Output.line(place) } }
    }
  }

  private func list(_ guide: Guide) {
    let count = guide.placeCount == 1 ? "1 place" : "\(guide.placeCount) places"
    print(
      "\(Style.identifier(String(guide.id)))  \(Style.title(guide.title))  \(Style.dim(count))")
    if let summary = guide.summary { print("    \(Style.dim(summary))") }
  }

  private func show(_ guide: Guide) {
    print(Style.title(guide.title))
    if let summary = guide.summary { print(Style.dim(summary)) }
    var detail: [String] = ["\(guide.placeCount) places"]
    if let created = guide.created {
      detail.append("created \(Output.dayOnly.string(from: created))")
    }
    print(Style.dim(detail.joined(separator: "  ·  ")))

    if guide.places.isEmpty {
      print("\n\(Style.dim("This guide holds no places."))")
      return
    }
    print("")
    for place in guide.places { Output.line(place) }
  }
}

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Report permission state without requesting it"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() throws {
    var databasePath: String?
    var stale = false
    var readError: String?
    var visitCount = 0
    var placeCount = 0
    var guideCount = 0
    var orphanLocations = 0
    var orphanItems = 0
    var earliest: Date?
    var latest: Date?

    do {
      let database = try MapsDatabase.open()
      databasePath = database.databasePath.path
      stale = database.isStale

      let visits = VisitStore(database: database)
      let coverage = try visits.coverage()
      visitCount = coverage.visits
      placeCount = coverage.places
      earliest = coverage.earliest
      latest = coverage.latest
      orphanLocations = try visits.orphanedLocationCount()

      let guides = GuideStore(database: database)
      guideCount = try guides.guides().count
      orphanItems = try guides.orphanedItemCount()
    } catch {
      readError = error.localizedDescription
    }

    let readable = readError == nil
    let status = readable ? "authorized" : "denied"
    let advice: String? =
      readable
      ? nil
      : "Grant Full Disk Access to this terminal in System Settings → Privacy & Security → "
        + "Full Disk Access, then run this again."

    if json {
      var payload: [String: Any] = [
        "status": status,
        "usable": readable,
        "full_disk_access": readable,
        // No Automation key on purpose: Maps.app ships no scripting dictionary,
        // so there is nothing an Automation grant could unlock.
        "scriptable": false,
        // Nothing here writes, and nothing here will. CloudKit mirrors the store.
        "writable": false,
        "visits": visitCount,
        "places": placeCount,
        "guides": guideCount,
        // The evidence for why a place count is lower than the row count, and
        // why a guide place count is lower than the item count.
        "orphaned_locations": orphanLocations,
        "orphaned_guide_items": orphanItems,
      ]
      if let advice { payload["advice"] = advice }
      if let databasePath { payload["database"] = databasePath }
      if let readError { payload["error"] = readError }
      if let earliest { payload["earliest_visit"] = Output.isoDate.string(from: earliest) }
      if let latest { payload["latest_visit"] = Output.isoDate.string(from: latest) }
      if stale { payload["stale"] = true }
      try Output.json(payload)
      if !readable { throw ExitCode(1) }
      return
    }

    if readable {
      print(Style.success("✓ Full Disk Access — can read the Maps store"))
      if let databasePath { print("  \(Style.dim(databasePath))") }
      print("  \(Style.dim("\(visitCount) visits to \(placeCount) places, \(guideCount) guides"))")
      if let earliest, let latest {
        let from = Output.dayOnly.string(from: earliest)
        let to = Output.dayOnly.string(from: latest)
        print("  \(Style.dim("covering \(from) to \(to)"))")
      }
      if orphanLocations > 0 {
        print(
          "  \(Style.dim("\(orphanLocations) location rows carry no visit and are not counted"))")
      }
      if orphanItems > 0 {
        print("  \(Style.dim("\(orphanItems) saved-place rows belong to no guide"))")
      }
      if stale { print("  \(Style.warning("write-ahead log not replayed; may be stale"))") }
    } else {
      print(Style.warning("✗ Full Disk Access — cannot read the Maps store"))
      if let readError { print("  \(readError)") }
    }

    print(Style.dim("Maps.app is not scriptable, and this tool never writes."))
    print(
      Style.dim(
        "Significant Locations is a different store (routined) and is not readable here."))

    if let advice { print("\n\(advice)") }
    if !readable { throw ExitCode(1) }
  }
}

// ArgumentParser has no coloured help, so generate it, style it, and print
// it here rather than letting .main() emit the plain version.
if let help = HelpColor.requested(root: AppleMaps.self, arguments: CommandLine.arguments) {
  print(help)
  exit(0)
}

AppleMaps.main()
