import ArgumentParser
import CoreLocation
import EventKit
import Foundation
import Geocoding

/// Giving an event a real map pin.
///
/// 🛑 **This repo used to say a pin was impossible, and that was true until
/// something here geocoded.** `--location` writes `EKEvent.location`, which is
/// plain text; the coordinate lives on a separate `EKStructuredLocation`, and
/// only that produces a map thumbnail or a travel-time alert. Nothing geocodes
/// a string after the fact — not EventKit on save, not the calDAV server on
/// sync, not Calendar.app on display. Real street addresses sat in this store
/// for months without ever gaining a coordinate.
///
/// So `--at` resolves the place through Apple Maps and sets the coordinate
/// itself. That is a network call, and the only one `apple-calendar` makes.
///
/// ⚠️ **`--location` still does not geocode, deliberately.** It stays a verbatim
/// text write, because a location that is not a place — "Zoom", "my desk", a
/// room name — must not be silently turned into a coordinate somewhere else in
/// the world. Ask for a pin explicitly.
struct PinnedLocationOptions: ParsableArguments {
    @Option(
        name: .customLong("at"),
        help: ArgumentHelp(
            "Set the location AND a real map pin: a place, an address, or \"lat,lon\"",
            discussion: "Unlike --location, this resolves the place through Apple Maps and "
                + "attaches the coordinate, which is what gives a client a map thumbnail and "
                + "a travel-time alert. It is a network call. A \"lat,lon\" pair is used "
                + "directly and touches nothing."))
    var at: String?

    @Option(
        name: .customLong("pin-radius"),
        help: "Radius of the pin in metres (default: Apple's own)")
    var pinRadius: Double?

    @Option(
        name: .customLong("near"),
        help: "Bias the Maps search near this place or \"lat,lon\"")
    var near: String?

    @Flag(
        name: .customLong("clear-pin"),
        help: "Remove the structured location, leaving the location text alone")
    var clearPin = false

    func validate() throws {
        if clearPin && at != nil {
            throw ValidationError("--at and --clear-pin are opposites; pass one.")
        }
        if let pinRadius, pinRadius <= 0 {
            throw ValidationError("--pin-radius must be greater than 0 metres.")
        }
        if at == nil && (pinRadius != nil || near != nil) {
            throw ValidationError("--pin-radius and --near only mean something with --at.")
        }
    }

    var wasSpecified: Bool { at != nil || clearPin }

    /// Resolve once, before anything is written, so a failed lookup never
    /// leaves a half-edited event behind.
    func resolve() throws -> GeocodeResult? {
        guard let at else { return nil }

        if Coordinate.looksLikeCoordinates(at) {
            guard let parsed = Coordinate.parseLabelled(at) else {
                throw ValidationError(
                    "'\(at)' looks like a coordinate pair but is out of range. "
                        + "Latitude is -90..90 and longitude is -180..180, in that order.")
            }
            return GeocodeResult(
                name: parsed.label ?? at,
                latitude: parsed.coordinate.latitude, longitude: parsed.coordinate.longitude,
                source: .coordinate)
        }

        let geocoder = NetworkGeocoder()
        var bias: CLLocationCoordinate2D?
        if let near {
            if let literal = Coordinate.parse(near) {
                bias = literal
            } else {
                bias = try geocoder.resolve(near, limit: 1).first?.coordinate
            }
        }

        let results = try geocoder.resolve(at, near: bias, limit: 5)
        guard let best = results.first else {
            throw ValidationError("Apple Maps found nothing for '\(at)'.")
        }

        // ⚠️ Distinct branches are a question for the user, not a coin flip.
        // Silently taking the first is how a meeting ends up pinned to the
        // wrong shop in the wrong town.
        let elsewhere = results.filter { candidate in
            CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                .distance(from: CLLocation(latitude: best.latitude, longitude: best.longitude))
                > 250
        }
        guard elsewhere.isEmpty else {
            let lines = results.prefix(5).map { candidate -> String in
                String(
                    format: "  %@ — %@ (%.5f,%.5f)", candidate.name,
                    candidate.address ?? "no address", candidate.latitude, candidate.longitude)
            }
            throw ValidationError(
                "'\(at)' matches \(results.count) places. Pass one as \"lat,lon\", or "
                    + "narrow it with --near:\n" + lines.joined(separator: "\n"))
        }
        return best
    }

    /// Apply a resolved place to an event.
    ///
    /// Sets `location` too, because an event with a pin and no location text
    /// shows as blank in every client that reads only the text field.
    func apply(_ resolved: GeocodeResult?, to event: EKEvent) {
        if clearPin {
            event.structuredLocation = nil
            return
        }
        guard let resolved else { return }

        let structured = EKStructuredLocation(title: resolved.address ?? resolved.name)
        structured.geoLocation = CLLocation(
            latitude: resolved.latitude, longitude: resolved.longitude)
        if let pinRadius { structured.radius = pinRadius }
        event.structuredLocation = structured
        event.location = resolved.address ?? resolved.name
    }

    func describe(_ resolved: GeocodeResult?) -> String? {
        guard let resolved else { return clearPin ? "Removed the map pin." : nil }
        return String(
            format: "Pinned to %@ (%.5f,%.5f)", resolved.address ?? resolved.name,
            resolved.latitude, resolved.longitude)
    }
}
