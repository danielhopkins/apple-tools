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

    /// 🛑 SOMEBODY ELSE'S CAMERA IS NOT ON THIS MAP. A place only the iCloud
    /// Shared Library knows is a place a relative photographed; it says
    /// nothing about where the user has been, and drawing it — even hollow
    /// — put dots on trips the user did not take. `apple-index places`
    /// still reports them, under `photo_days_shared`; the window does not.
    private var mine: [Place] { stats.places.filter { !$0.othersOnly } }
    private var hidden: Int { stats.places.count - mine.count }

    static func color(for place: Place) -> Color {
        if place.sources.count > 1 { return .purple }
        if place.sources.contains("maps") { return .orange }
        if place.sources.contains("photos") { return .blue }
        return .green
    }

    var body: some View {
        PaneSection("Places", trailing: {
            if stats.loaded {
                Text("\(mine.count) places · \(stats.countries.count) countries")
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
                WorldMap(places: mine, selected: $selected)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Legend(places: mine, plugins: stats.fromPlugins.keys.sorted(),
                       hidden: hidden, first: stats.first, last: stats.last,
                       selected: selected)
                TopPlaces(places: mine, selected: $selected, query: $query)
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
    /// The span on screen, from the last camera change. Nil until the map has
    /// drawn once, and then every dot is grouped against it.
    @State private var region: MKCoordinateRegion? = nil

    /// 🛑 GROUPED BY WHAT IS ON SCREEN, NOT BY A FIXED RADIUS. The 250 m merge
    /// in `index.py` says what a place IS; this says what can be told apart at
    /// this zoom. Two places closer than ~28 points become one circle with a
    /// count, and a tap on it zooms until they separate. Zoomed out, Boulder
    /// is one circle that says "412"; zoomed in, it is 412 places. Nothing is
    /// hidden and nothing is smeared.
    private var groups: [Group] {
        guard let region else { return drawn.map { Group(places: [$0]) } }
        // Degrees per point, taking the map as ~700 points wide. Exact width
        // does not matter: the cell only has to be a few dots across.
        let cellLat = region.span.latitudeDelta / 340 * 28
        let cellLon = region.span.longitudeDelta / 700 * 28
        var cells: [String: [Place]] = [:]
        for place in drawn {
            let key = "\(Int((place.latitude / cellLat).rounded(.down))),"
                    + "\(Int((place.longitude / cellLon).rounded(.down)))"
            cells[key, default: []].append(place)
        }
        return cells.values.map { Group(places: $0.sorted { $0.weight > $1.weight }) }
    }

    var body: some View {
        Map(position: $camera) {
            ForEach(groups) { group in
                Annotation(coordinate: group.coordinate) {
                    if group.places.count == 1, let place = group.places.first {
                        Dot(place: place, isSelected: selected?.id == place.id)
                            .onTapGesture { selected = place }
                    } else {
                        Cluster(group: group)
                            .onTapGesture { zoom(into: group) }
                    }
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
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
        }
    }

    /// Zoom to the group's own extent, with a margin, so its members fall
    /// into separate cells on the next pass.
    private func zoom(into group: Group) {
        let lats = group.places.map(\.latitude), lons = group.places.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.004),
            longitudeDelta: max((maxLon - minLon) * 1.6, 0.006))
        withAnimation {
            camera = .region(MKCoordinateRegion(center: group.coordinate, span: span))
        }
    }
}

/// Places that share a screen cell at the current zoom.
private struct Group: Identifiable {
    let places: [Place]
    var id: String { places.map(\.id).joined(separator: "|") }
    /// The weightiest member's spot, so a cluster sits where the place a
    /// person knows is, not on the centroid of a parking lot and a park.
    var coordinate: CLLocationCoordinate2D {
        let lead = places[0]
        return CLLocationCoordinate2D(latitude: lead.latitude, longitude: lead.longitude)
    }
}

private struct Cluster: View {
    let group: Group
    private var size: CGFloat {
        CGFloat(min(max(pow(Double(group.places.count), 0.5) * 8.0, 20.0), 40.0))
    }
    var body: some View {
        ZStack {
            Circle().fill(Color.purple.opacity(0.35))
                .overlay(Circle().strokeBorder(Color.purple, lineWidth: 1.5))
            Text("\(group.places.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .help("\(group.places.count) places, the largest \(group.places[0].shown). Tap to zoom.")
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
        Circle()
            .fill(color.opacity(0.55))
            .overlay(Circle().strokeBorder(color, lineWidth: isSelected ? 2.5 : 1))
            .frame(width: size, height: size)
            .help(place.shown)
    }
}

// MARK: - what the colours mean, and what is selected

private struct Legend: View {
    let places: [Place]
    let plugins: [String]
    /// Places left off the map because only somebody else's camera knows them.
    let hidden: Int
    let first: Date?
    let last: Date?
    let selected: Place?

    private static let year: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ⚠️ Counted off the rows, not off `counts`: `from_x` overlap and
            // a legend has to partition the dots it colours.
            let only = { (source: String) in
                places.filter { $0.sources == [source] }.count
            }
            HStack(spacing: 14) {
                Key(color: .blue, text: "photos only  \(only("photos"))")
                Key(color: .orange, text: "Maps only  \(only("maps"))")
                ForEach(plugins, id: \.self) { plugin in
                    Key(color: .green, text: "\(plugin) only  \(only(plugin))")
                }
                Key(color: .purple, text: "more than one  \(places.filter { $0.sources.count > 1 }.count)")
                if hidden > 0 {
                    Text("· \(hidden) from someone else's camera, not shown")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if let place = selected {
                // 🛑 THE TWO NUMBERS ARE NAMED AND KEPT APART. A visit is an
                // arrival Maps recorded; a photo day is a day a picture was
                // taken here. Printing one figure would be printing a number
                // with no unit.
                Text(place.shown).font(.system(size: 12, weight: .medium))
                Text(detail(place))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let first, let last {
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
        if !place.where_.isEmpty, place.where_ != place.shown {
            parts.append(place.where_)
        }
        // Everyone the address book puts here, when the label could not
        // name them all — the second household at one address, or a card
        // whose office merged into a bigger place nearby.
        let named = place.peopleAt.filter { !(place.label ?? "").contains($0.split(separator: " ").first ?? "") }
        if !named.isEmpty {
            parts.append("also on a card: " + named.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

private struct Key: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.55))
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
            $0.shown.lowercased().contains(needle) || $0.where_.lowercased().contains(needle)
                || $0.peopleAt.contains { $0.lowercased().contains(needle) }
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
                    Text(place.shown)
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
