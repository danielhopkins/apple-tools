// Everywhere you have been, read in one call.
//
// ⚠️ TWO SOURCES, TWO UNITS, NEVER ADDED. `maps` records a genuine arrival
// out of Maps' Visited Places. `photos` records that a camera was somewhere on
// some day. The same place usually has both, and they measure different
// things, so a row carries `visits` and `photoDays` side by side and nothing
// here sums them. See `cmd_places` in lab/index.py.

import Foundation

struct Place: Identifiable, Equatable {
    var id: String { "\(latitude),\(longitude)" }
    let name: String
    /// The full address or category line, when the source had one.
    let where_: String
    let country: String?
    let latitude: Double
    let longitude: Double
    /// Which sources know this place: "photos", "maps", or both.
    let sources: [String]
    /// Days on which a photograph was taken here. 🛑 NOT a visit count.
    let photoDays: Int
    /// Arrivals Maps recorded here. 🛑 NOT a day count, and not comparable to
    /// `photoDays` — one is an arrival and the other is a calendar day.
    let visits: Int
    let first: Date?
    let last: Date?

    /// 🛑 FOR SIZING A DOT ONLY. It takes the larger of two numbers that do not
    /// share a unit, which is not a measurement of anything. Never print it.
    var weight: Int { max(photoDays, visits) }
}

struct CountryCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let places: Int
}

struct PlacesStats: Equatable {
    var loaded = false
    var error: String?
    var generated: Date?
    var places: [Place] = []
    var countries: [CountryCount] = []
    var total = 0
    /// 🛑 Places Photos knows, places Maps knows, and places BOTH know. The
    /// third is not the overlap of two independent answers to one question —
    /// it is the number of rows that got merged, and it is the honest way to
    /// say that neither source alone is "everywhere you have been".
    var fromPhotos = 0
    var fromMaps = 0
    var both = 0
    var first: Date?
    var last: Date?
}

enum PlacesReader {
    static func read() -> PlacesStats {
        var stats = PlacesStats()
        guard let script = Paths.indexScript else {
            stats.error = "no index.py found"
            return stats
        }
        let result = Child.run(
            Paths.python,
            [script.path, "--db", Paths.database.path, "places"],
            timeout: 120)
        guard result.ok, let data = result.out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            stats.error = result.err.split(separator: "\n").last.map(String.init)
                ?? "places failed (exit \(result.status))"
            return stats
        }
        func date(_ value: Any?) -> Date? {
            (value as? Double).map(Date.init(timeIntervalSince1970:))
        }
        let counts = root["counts"] as? [String: Any] ?? [:]
        stats.total = counts["places"] as? Int ?? 0
        stats.fromPhotos = counts["from_photos"] as? Int ?? 0
        stats.fromMaps = counts["from_maps"] as? Int ?? 0
        stats.both = counts["both"] as? Int ?? 0
        let span = root["span"] as? [String: Any] ?? [:]
        stats.first = date(span["first"])
        stats.last = date(span["last"])
        stats.generated = date(root["generated"])
        stats.countries = (root["countries"] as? [[String: Any]] ?? [])
            .compactMap {
                guard let name = $0["name"] as? String else { return nil }
                return CountryCount(name: name, places: $0["places"] as? Int ?? 0)
            }
        stats.places = (root["places"] as? [[String: Any]] ?? []).compactMap {
            guard let lat = $0["latitude"] as? Double,
                  let lon = $0["longitude"] as? Double else { return nil }
            return Place(
                name: $0["name"] as? String ?? "",
                where_: $0["where"] as? String ?? "",
                country: $0["country"] as? String,
                latitude: lat, longitude: lon,
                sources: $0["sources"] as? [String] ?? [],
                photoDays: $0["photo_days"] as? Int ?? 0,
                visits: $0["visits"] as? Int ?? 0,
                first: date($0["first"]), last: date($0["last"]))
        }
        stats.loaded = true
        return stats
    }
}
