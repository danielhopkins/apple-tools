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

    private var stats: PlacesStats { model.places }

    var body: some View {
        Panel("Places", trailing: {
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
                TopPlaces(places: stats.places, selected: $selected)
            }
        }
        .onAppear { model.refreshPlaces() }
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
    private var drawn: [Place] { Array(places.prefix(400)) }

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

    /// A place both sources know is drawn differently, because it is the only
    /// kind whose two numbers can disagree.
    private var color: Color {
        place.sources.contains("maps")
            ? (place.sources.contains("photos") ? .purple : .orange)
            : .blue
    }

    var body: some View {
        Circle()
            .fill(color.opacity(0.55))
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
            HStack(spacing: 14) {
                Key(color: .blue, text: "photos only  \(stats.fromPhotos - stats.both)")
                Key(color: .orange, text: "Maps only  \(stats.fromMaps - stats.both)")
                Key(color: .purple, text: "both  \(stats.both)")
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
        if place.visits > 0 {
            parts.append("\(place.visits) "
                         + (place.visits == 1 ? "recorded arrival" : "recorded arrivals"))
        }
        if !place.where_.isEmpty, place.where_ != place.name {
            parts.append(place.where_)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(places.prefix(12)) { place in
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
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = place }
            }
            Text("d = days photographed · v = arrivals Maps recorded. "
                 + "Different units; not comparable.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }
}
