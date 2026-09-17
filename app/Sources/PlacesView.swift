// A world map of everywhere you have been.
//
// 🛑 THIS PANEL MAKES NETWORK CALLS, AND IT IS THE ONLY PART OF THE APP THAT
// DOES. MapKit fetches its tiles from Apple every time the map draws. Until
// this panel existed, `apple maps geocode` and the `--at` flags were the whole
// network surface of this repo, they lived in their own `Geocoding` target so
// a dependency on them was a decision, and `--local-only` could refuse them.
//
// ⚠️ THE PLACES THEMSELVES NEVER LEAVE THE MACHINE. MapKit asks Apple for
// pictures of the world at a zoom and a region; it is not handed the user's
// coordinates as data, and nothing here uploads a place, a date or a name.
// What an observer could infer is the REGION being looked at, which is a
// weaker thing than the pin list but is not nothing.
//
// The map is built lazily and only while the panel is open, so a window that
// is never scrolled this far makes no request at all.

import SwiftUI
import MapKit

struct Places: View {
    @ObservedObject var model: AppModel
    @State private var selected: Place?
    /// A filter over name and address. ⚠️ It exists because "why don't my
    /// photos show Dallas" had an answer — three days in Irving, The Colony
    /// and Grapevine — that no top-twelve list could show.
    @State private var query = ""

    private var stats: PlacesStats { model.places }

    static func color(for place: Place) -> Color {
        if place.othersOnly { return .gray }
        if place.sources.count > 1 { return .purple }
        if place.sources.contains("maps") { return .orange }
        if place.sources.contains("photos") { return .blue }
        return .green
    }

    var body: some View {
        PaneSection("Places", trailing: {
            if stats.loaded {
                Text("\(stats.total) places · \(stats.countries.count) countries")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }) {
            if let error = stats.error {
                Note(error, tint: .red)
            } else if !stats.loaded {
                Note("reading…")
            } else if stats.places.isEmpty {
                Note("No located photos and no visited places. "
                     + "`apple-index refresh` builds this from the Photos "
                     + "library and the Maps store.")
            } else {
                WorldMap(places: stats.places, selected: $selected)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Legend(stats: stats, selected: selected)
                TopPlaces(places: stats.places, selected: $selected, query: $query)
            }
        }
    }
}

// MARK: - the map

private struct WorldMap: View {
    let places: [Place]
    @Binding var selected: Place?

    /// 🛑 A CAP, BECAUSE MAPKIT DRAWS EVERY ANNOTATION IT IS GIVEN. 1,487 pins
    /// at world zoom is a solid smear that says nothing and scrolls badly. The
    /// top 400 by weight cover every place the user has been more than once,
    /// and the count in the badge is always the full total so the cap can
    /// never read as "this is everywhere".
    ///
    /// 🛑 BUT THE CAP MUST NOT ERASE A REGION. The top 400 are almost all
    /// within an hour of home, so three photo days in Dallas — one day each,
    /// weight 1, rank ~1,200 — drew nothing at all, and the map said the user
    /// had never been to Texas. A place is drawn if it is in the top 400 OR
    /// no drawn place lies within 25 km of it: every region gets a dot, and
    /// a dense one still does not get a thousand.
    private var drawn: [Place] {
        var kept: [Place] = []
        for (rank, place) in places.enumerated() {
            if rank < 400 {
                kept.append(place)
                continue
            }
            let alone = !kept.contains { metres($0, place) < 25_000 }
            if alone { kept.append(place) }
        }
        return kept
    }

    private func metres(_ a: Place, _ b: Place) -> Double {
        let lat = (a.latitude + b.latitude) / 2 * .pi / 180
        let dx = (b.longitude - a.longitude) * .pi / 180 * cos(lat)
        let dy = (b.latitude - a.latitude) * .pi / 180
        return 6_371_000 * (dx * dx + dy * dy).squareRoot()
    }

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            ForEach(drawn) { place in
                Annotation(coordinate: CLLocationCoordinate2D(
                    latitude: place.latitude, longitude: place.longitude)) {
                    Dot(place: place, isSelected: selected?.id == place.id)
                        .onTapGesture { selected = place }
                } label: {
                    // ⚠️ NO LABEL BY DEFAULT. Every pin carrying its name is
                    // unreadable anywhere the user actually spends time, and
                    // the names here are often street addresses.
                    EmptyView()
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls { MapZoomStepper(); MapPitchToggle() }
    }
}

private struct Dot: View {
    let place: Place
    let isSelected: Bool

    /// ⚠️ AREA, NOT DIAMETER, and on a fourth root. The largest place here has
    /// 1,647 photo days and the smallest has one; scaling the radius linearly
    /// makes everywhere except home invisible, and scaling by day count makes
    /// home a disc that covers Colorado.
    private var size: CGFloat {
        let scaled = pow(Double(max(place.weight, 1)), 0.25)
        return CGFloat(min(max(scaled * 3.0, 6.0), 22.0))
    }

    /// One colour per single source, and one for any place more than one
    /// source knows — those are the places whose numbers can disagree.
    private var color: Color { Places.color(for: place) }

    var body: some View {
        // ⚠️ HOLLOW for somebody else's camera. A filled dot says "you were
        // here"; this one says "a photo of yours was taken here by someone
        // else", which is a different fact and is drawn as one.
        Circle()
            .fill(color.opacity(place.othersOnly ? 0.0 : 0.55))
            .overlay(Circle().strokeBorder(color, lineWidth: isSelected ? 2.5 : 1))
            .frame(width: size, height: size)
            .help(place.name)
    }
}

// MARK: - what the colours mean, and what is selected

private struct Legend: View {
    let stats: PlacesStats
    let selected: Place?

    private static let year: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ⚠️ Counted off the rows, not off `counts`: `from_x` overlap and
            // a legend has to partition the dots it colours.
            let only = { (source: String) in
                stats.places.filter { $0.sources == [source] }.count
            }
            let others = stats.places.filter(\.othersOnly).count
            HStack(spacing: 14) {
                Key(color: .blue, text: "photos only  \(only("photos") - others)")
                Key(color: .orange, text: "Maps only  \(only("maps"))")
                ForEach(stats.fromPlugins.keys.sorted(), id: \.self) { plugin in
                    Key(color: .green, text: "\(plugin) only  \(only(plugin))")
                }
                Key(color: .purple, text: "more than one  \(stats.places.filter { $0.sources.count > 1 }.count)")
                Key(color: .gray, hollow: true, text: "someone else's camera  \(others)")
            }
            if let place = selected {
                // 🛑 THE TWO NUMBERS ARE NAMED AND KEPT APART. A visit is an
                // arrival Maps recorded; a photo day is a day a picture was
                // taken here. Printing one figure would be printing a number
                // with no unit.
                Text(place.name).font(.system(size: 12, weight: .medium))
                Text(detail(place))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let first = stats.first, let last = stats.last {
                Text("\(Self.year.string(from: first)) to \(Self.year.string(from: last)). "
                     + "Tap a place.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ place: Place) -> String {
        var parts: [String] = []
        if place.photoDays > 0 {
            parts.append("\(place.photoDays) "
                         + (place.photoDays == 1 ? "day photographed" : "days photographed"))
        }
        if place.photoDaysShared > 0 {
            parts.append("\(place.photoDaysShared) "
                         + (place.photoDaysShared == 1 ? "day" : "days")
                         + " on someone else's camera")
        }
        if place.visits > 0 {
            parts.append("\(place.visits) "
                         + (place.visits == 1 ? "recorded arrival" : "recorded arrivals"))
        }
        // 🛑 A plugin's stays are its own unit, and a suggested one is a
        // guess: both are named, and neither is added to anything.
        for plugin in place.plugins {
            let confirmed = place.pluginVisits[plugin] ?? 0
            let guessed = place.pluginSuggested[plugin] ?? 0
            var piece = "\(plugin): "
            if confirmed > 0 { piece += "\(confirmed) confirmed " + (confirmed == 1 ? "stay" : "stays") }
            if guessed > 0 {
                piece += (confirmed > 0 ? ", " : "") + "\(guessed) suggested"
            }
            if confirmed > 0 || guessed > 0 { parts.append(piece) }
        }
        if !place.where_.isEmpty, place.where_ != place.name {
            parts.append(place.where_)
        }
        return parts.joined(separator: " · ")
    }
}

private struct Key: View {
    let color: Color
    var hollow = false
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(hollow ? 0 : 0.55))
                .overlay(Circle().strokeBorder(color, lineWidth: 1))
                .frame(width: 9, height: 9)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - the list

private struct TopPlaces: View {
    let places: [Place]
    @Binding var selected: Place?
    @Binding var query: String

    /// The top twelve, or everything matching the filter — name or address,
    /// so "Dallas" finds a place whose city is Irving and county is Dallas.
    private var shown: [Place] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return Array(places.prefix(12)) }
        return Array(places.filter {
            $0.name.lowercased().contains(needle) || $0.where_.lowercased().contains(needle)
        }.prefix(30))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField("name, city, county or country", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 11))
                if !query.isEmpty {
                    Text("\(shown.count)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            ForEach(shown) { place in
                HStack(spacing: 8) {
                    Text(place.name.isEmpty ? "unnamed" : place.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if place.photoDays > 0 {
                        Text("\(place.photoDays)d")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                    if place.visits > 0 {
                        Text("\(place.visits)v")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    let stays = place.pluginVisits.values.reduce(0, +)
                        + place.pluginSuggested.values.reduce(0, +)
                    if stays > 0 {
                        Text("\(stays)s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = place }
            }
            Text("d = days photographed · v = arrivals Maps recorded · "
                 + "s = stays a plugin detected, confirmed or guessed. "
                 + "Different units; not comparable.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }
}
