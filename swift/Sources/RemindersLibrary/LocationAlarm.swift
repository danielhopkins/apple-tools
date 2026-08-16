import ArgumentParser
import CoreLocation
import EventKit
import Foundation
import Geocoding

/// Location reminders — "remind me when I get to the hardware shop".
///
/// EventKit models one as an `EKAlarm` carrying an `EKStructuredLocation` with
/// a real `geoLocation`, plus a `proximity` of `.enter` or `.leave`. All of it
/// is public API, unlike the calendar pin: `EKEvent.structuredLocation` accepts
/// a coordinate too, but nothing here geocodes for it. This does.
///
/// 🛑 **`reminders` cannot read the Maps store, so it resolves over the
/// network.** It re-executes itself disclaimed so the Reminders grant follows
/// the binary, and a disclaimed process loses the terminal's Full Disk Access —
/// measured with a probe that read `MapsSync_0.0.1` fine until it disclaimed.
/// To place a reminder at a shop the user actually goes to, pipe the local
/// answer in:
///
///     apple reminders add Errands "milk" \
///       --at "$(apple maps geocode costco --json | jq -r '.[0]|"\(.latitude),\(.longitude)"')"
///
/// ⚠️ **A structured location without a `geoLocation` triggers nothing.** It
/// still shows a name in Reminders.app, so a failed geocode that saved anyway
/// would look exactly like a working location reminder and simply never fire.
/// Every path here refuses rather than saving a title-only location.

public enum Proximity: String, ExpressibleByArgument, CaseIterable {
    case arrive
    case leave

    var ekProximity: EKAlarmProximity {
        switch self {
        case .arrive: return .enter
        case .leave: return .leave
        }
    }
}

public struct LocationOptions: ParsableArguments {
    public init() {}

    @Option(
        name: .customLong("at"),
        help: ArgumentHelp(
            "Trigger at this place: a name, an address, or \"lat,lon\"",
            discussion: "A name or address is resolved through Apple Maps, which is a "
                + "network call — the only one this tool makes. A \"lat,lon\" pair is used "
                + "directly and touches nothing. Use `apple maps geocode` to resolve a "
                + "place you have actually been, which reminders cannot read itself."))
    public var at: String?

    @Option(
        name: .customLong("on"),
        help: "Fire on 'arrive' or 'leave' (default: arrive)")
    public var proximity: Proximity = .arrive

    @Option(
        name: .customLong("radius"),
        help: "How close, in metres (default: 100)")
    public var radius: Double?

    @Option(
        name: .customLong("near"),
        help: "Bias the Maps search near this place or \"lat,lon\"")
    public var near: String?

    @Flag(
        name: .customLong("clear-location"),
        help: "Remove the location trigger from the reminder")
    public var clearLocation = false

    public func validate() throws {
        if clearLocation && at != nil {
            throw ValidationError("--at and --clear-location are opposites; pass one.")
        }
        if let radius, radius <= 0 {
            throw ValidationError("--radius must be greater than 0 metres (got \(radius)).")
        }
        if at == nil && !clearLocation {
            // `--on` and `--radius` without `--at` would be silently dropped,
            // and a location reminder that never fires is the failure this
            // whole type exists to prevent.
            if radius != nil || near != nil {
                throw ValidationError("--radius and --near only mean something with --at.")
            }
        }
    }

    /// Resolve `--at` into an alarm, or nil when no location was asked for.
    ///
    /// ⚠️ Ambiguity is reported, not guessed. A Maps search for a shop name
    /// returns every branch, and silently taking the first would put the
    /// reminder at the wrong one — the mistake nobody notices until the alarm
    /// fails to fire.
    public func makeAlarm() throws -> EKAlarm? {
        guard let at else { return nil }

        let resolved = try resolve(at)
        let location = EKStructuredLocation(title: resolved.name)
        location.geoLocation = CLLocation(
            latitude: resolved.latitude, longitude: resolved.longitude)
        location.radius = radius ?? 100

        let alarm = EKAlarm()
        alarm.structuredLocation = location
        alarm.proximity = proximity.ekProximity
        return alarm
    }

    /// A human-readable line describing what was attached, for the non-JSON
    /// output. Nil when nothing was.
    public func describe(_ alarm: EKAlarm?) -> String? {
        guard let alarm, let location = alarm.structuredLocation,
            let point = location.geoLocation
        else { return nil }
        let verb = proximity == .arrive ? "arriving at" : "leaving"
        return String(
            format: "Reminds on %@ %@ (%.5f,%.5f, %.0fm)",
            verb, location.title ?? "the location",
            point.coordinate.latitude, point.coordinate.longitude, location.radius)
    }

    private func resolve(_ query: String) throws -> GeocodeResult {
        if Coordinate.looksLikeCoordinates(query) {
            guard let parsed = Coordinate.parseLabelled(query) else {
                throw ValidationError(
                    "'\(query)' looks like a coordinate pair but is out of range. "
                        + "Latitude is -90..90 and longitude is -180..180, in that order.")
            }
            return GeocodeResult(
                name: parsed.label ?? query,
                latitude: parsed.coordinate.latitude, longitude: parsed.coordinate.longitude,
                source: .coordinate)
        }

        let geocoder = NetworkGeocoder()
        let results = try geocoder.resolve(query, near: try bias(geocoder), limit: 5)
        guard let best = results.first else {
            throw ValidationError("Apple Maps found nothing for '\(query)'.")
        }

        // Two results at the same place are one answer. Distinct places are a
        // question for the user.
        let distinct = results.filter { candidate in
            CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                .distance(from: CLLocation(latitude: best.latitude, longitude: best.longitude))
                > 250
        }
        guard distinct.isEmpty else {
            let lines = results.prefix(5).map { candidate -> String in
                let where_ = candidate.address ?? "no address"
                return String(
                    format: "  %@ — %@ (%.5f,%.5f)", candidate.name, where_,
                    candidate.latitude, candidate.longitude)
            }
            throw ValidationError(
                "'\(query)' matches \(results.count) places. Pass one as \"lat,lon\", "
                    + "or narrow it with --near:\n" + lines.joined(separator: "\n"))
        }
        return best
    }

    private func bias(_ geocoder: NetworkGeocoder) throws -> CLLocationCoordinate2D? {
        guard let near else { return nil }
        if let literal = Coordinate.parse(near) { return literal }
        return try geocoder.resolve(near, limit: 1).first?.coordinate
    }
}

extension EKReminder {
    /// Drop every alarm that carries a location, leaving time alarms alone.
    ///
    /// ⚠️ A reminder can hold both a due-date alarm and a location alarm.
    /// Clearing all alarms would silently cancel the time reminder too.
    func removeLocationAlarms() {
        for alarm in alarms ?? [] where alarm.structuredLocation != nil {
            removeAlarm(alarm)
        }
    }
}
