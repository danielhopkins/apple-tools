// Everywhere you have been, read in one call.
//
// ⚠️ THREE SOURCES, THREE UNITS, NEVER ADDED. `maps` records a genuine arrival
// out of Maps' Visited Places. `photos` records that a camera was somewhere on
// some day. A plugin such as `dawarich` records a stay its server detected,
// confirmed or guessed. The same place often has all of them, and they measure
// different things, so a row carries `visits`, `photoDays` and the plugin's
// own counts side by side and nothing here sums them. See `cmd_places` in
// lab/index.py.

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
    /// Days on which a photograph was taken here BY THE USER'S OWN CAMERA.
    /// 🛑 NOT a visit count.
    let photoDays: Int
    /// Days on which every photograph here came from the iCloud Shared
    /// Library — somebody else's camera. Evidence that THEY were here. Six
    /// such photos in London, Ontario, once drew this user a dot for a trip
    /// a relative took. Never added to `photoDays`, never sizes a dot.
    let photoDaysShared: Int
    /// Arrivals Maps recorded here. 🛑 NOT a day count, and not comparable to
    /// `photoDays` — one is an arrival and the other is a calendar day.
    let visits: Int
    /// A plugin's own counts, keyed by plugin name: stays it confirmed, and
    /// stays its server guessed. 🛑 A third and fourth unit, never added to
    /// the two above. `index.py` names them `<plugin>_visits` and
    /// `<plugin>_suggested`; only the plugins the index holds appear.
    let pluginVisits: [String: Int]
    let pluginSuggested: [String: Int]
    let first: Date?
    let last: Date?

    /// The plugins that know this place, for the legend and the dot.
    var plugins: [String] { sources.filter { $0 != "maps" && $0 != "photos" }.sorted() }

    /// Nothing but somebody else's camera puts anyone here.
    var othersOnly: Bool {
        sources == ["photos"] && photoDays == 0 && photoDaysShared > 0
    }

    /// 🛑 FOR SIZING A DOT ONLY. It takes the larger of numbers that do not
    /// share a unit, which is not a measurement of anything. Never print it.
    /// ⚠️ A suggested stay is a guess and sizes nothing, the same rule the
    /// merge anchor follows in `index.py`.
    var weight: Int { ([photoDays, visits] + Array(pluginVisits.values)).max() ?? 0 }
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
    /// Places each plugin knows, keyed by plugin name (`from_<plugin>`).
    var fromPlugins: [String: Int] = [:]
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
        for (key, value) in counts where key.hasPrefix("from_") {
            let tool = String(key.dropFirst("from_".count))
            if tool != "photos", tool != "maps", let n = value as? Int {
                stats.fromPlugins[tool] = n
            }
        }
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
            var pluginVisits: [String: Int] = [:]
            var pluginSuggested: [String: Int] = [:]
            for (key, value) in $0 {
                guard let n = value as? Int, key != "visits" else { continue }
                if key.hasSuffix("_visits") {
                    pluginVisits[String(key.dropLast("_visits".count))] = n
                } else if key.hasSuffix("_suggested") {
                    pluginSuggested[String(key.dropLast("_suggested".count))] = n
                }
            }
            return Place(
                name: $0["name"] as? String ?? "",
                where_: $0["where"] as? String ?? "",
                country: $0["country"] as? String,
                latitude: lat, longitude: lon,
                sources: $0["sources"] as? [String] ?? [],
                photoDays: $0["photo_days"] as? Int ?? 0,
                photoDaysShared: $0["photo_days_shared"] as? Int ?? 0,
                visits: $0["visits"] as? Int ?? 0,
                pluginVisits: pluginVisits, pluginSuggested: pluginSuggested,
                first: date($0["first"]), last: date($0["last"]))
        }
        stats.loaded = true
        return stats
    }
}
