import ArgumentParser
import EventKit
import Foundation

private let store = EKEventStore()

// MARK: - Access

/// Prompts for (or confirms) Calendar access. Called at the top of each command
/// rather than at startup, so `--help` works without a TCC grant.
func requireCalendarAccess() throws {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var returnError: Error?
    store.requestFullAccessToEvents { ok, error in
        granted = ok
        returnError = error
        semaphore.signal()
    }
    semaphore.wait()

    guard granted else {
        let detail = returnError.map { ": \($0.localizedDescription)" } ?? ""
        throw ValidationError(
            "you need to grant calendar access\(detail)\n"
            + "Grant it in System Settings → Privacy & Security → Calendars.")
    }
}

// MARK: - Date parsing

/// A date argument accepting natural language ("tomorrow 9am", "next friday")
/// as well as ISO-ish forms ("2026-07-27", "2026-07-27 14:30").
struct DateArg: ExpressibleByArgument {
    let date: Date

    init?(argument: String) {
        guard let parsed = DateArg.parse(argument) else { return nil }
        self.date = parsed
    }

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Explicit formats first — NSDataDetector is lenient in ways that surprise.
        let explicit = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"]
        for format in explicit {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: trimmed) { return date }
        }

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = detector.matches(in: trimmed, options: .anchored, range: range)
        return matches.first?.date
    }
}

private let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter
}()

private let humanFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE MMM d, h:mm a"
    return formatter
}()

private let humanDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE MMM d"
    return formatter
}()

// MARK: - Output

struct CalendarInfo: Encodable {
    let title: String
    let identifier: String
    let allowsModification: Bool
    let source: String
}

struct EventInfo: Encodable {
    let id: String
    let title: String
    let calendar: String
    let start: String
    let end: String
    let allDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let recurring: Bool
    let attendees: [String]?
}

private func info(_ event: EKEvent) -> EventInfo {
    let attendees = event.attendees?.compactMap { attendee -> String? in
        attendee.name ?? attendee.url.absoluteString
    }
    return EventInfo(
        id: event.eventIdentifier ?? "",
        title: event.title ?? "<untitled>",
        calendar: event.calendar?.title ?? "<unknown>",
        start: event.startDate.map { iso8601.string(from: $0) } ?? "",
        end: event.endDate.map { iso8601.string(from: $0) } ?? "",
        allDay: event.isAllDay,
        location: event.location,
        notes: event.notes,
        url: event.url?.absoluteString,
        recurring: event.hasRecurrenceRules,
        attendees: (attendees?.isEmpty ?? true) ? nil : attendees
    )
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value),
          let string = String(data: data, encoding: .utf8) else {
        print("error: failed to encode JSON")
        exit(1)
    }
    print(string)
}

private func describe(_ event: EKEvent) -> String {
    let title = event.title ?? "<untitled>"
    let calendarName = event.calendar?.title ?? "<unknown>"

    let when: String
    if event.isAllDay {
        when = event.startDate.map { humanDayFormatter.string(from: $0) + " (all day)" } ?? "?"
    } else if let start = event.startDate, let end = event.endDate {
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "h:mm a"
        when = "\(humanFormatter.string(from: start))–\(endFormatter.string(from: end))"
    } else {
        when = "?"
    }

    let location = event.location.map { " @ \($0)" } ?? ""
    return "\(when)  \(title)\(location)  [\(calendarName)]"
}

// MARK: - Calendar lookup

private func calendars(named names: [String]) throws -> [EKCalendar] {
    let all = store.calendars(for: .event)
    guard !names.isEmpty else { return all }

    return try names.map { name in
        guard let match = all.first(where: { $0.title.lowercased() == name.lowercased() }) else {
            throw ValidationError(
                "no calendar named '\(name)'. Available: \(all.map { $0.title }.joined(separator: ", "))")
        }
        return match
    }
}

private func writableCalendar(named name: String?) throws -> EKCalendar {
    if let name {
        let match = try calendars(named: [name])[0]
        guard match.allowsContentModifications else {
            throw ValidationError("calendar '\(match.title)' is read-only")
        }
        return match
    }
    guard let fallback = store.defaultCalendarForNewEvents else {
        throw ValidationError("no default calendar; pass --calendar")
    }
    return fallback
}

private func event(withId id: String) throws -> EKEvent {
    guard let match = store.event(withIdentifier: id) else {
        throw ValidationError("no event with id '\(id)'")
    }
    return match
}

// MARK: - Commands

struct AppleCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-calendar",
        abstract: "Read and write macOS Calendar events via EventKit",
        subcommands: [Calendars.self, Events.self, Show.self, Add.self, Edit.self, Delete.self],
        defaultSubcommand: Events.self
    )
}

struct Calendars: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List available calendars")

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Flag(name: .long, help: "Only calendars that can be written to")
    var writable = false

    func run() throws {
        try requireCalendarAccess()
        var all = store.calendars(for: .event)
        if writable {
            all = all.filter { $0.allowsContentModifications }
        }
        let sorted = all.sorted { $0.title.lowercased() < $1.title.lowercased() }

        if json {
            printJSON(sorted.map {
                CalendarInfo(
                    title: $0.title,
                    identifier: $0.calendarIdentifier,
                    allowsModification: $0.allowsContentModifications,
                    source: $0.source?.title ?? "<unknown>"
                )
            })
        } else {
            for calendar in sorted {
                let readonly = calendar.allowsContentModifications ? "" : " (read-only)"
                print("\(calendar.title)\(readonly)")
            }
        }
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List events in a date range (defaults to the next 7 days)")

    @Option(name: .long, help: "Start of range, e.g. 'today', '2026-07-27'")
    var from: DateArg?

    @Option(name: .long, help: "End of range (exclusive of --days)")
    var to: DateArg?

    @Option(name: .long, help: "Number of days from --from (default 7)")
    var days: Int?

    @Option(name: .long, help: "Limit to these calendars (repeatable)")
    var calendar: [String] = []

    @Option(name: .long, help: "Only events whose title, location, or notes match")
    var search: String?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireCalendarAccess()
        let start = from?.date ?? Foundation.Calendar.current.startOfDay(for: Date())

        let end: Date
        if let to {
            end = to.date
        } else {
            let span = days ?? 7
            guard let computed = Foundation.Calendar.current.date(
                byAdding: .day, value: span, to: start) else {
                throw ValidationError("could not compute end date from --days \(span)")
            }
            end = computed
        }

        guard end > start else {
            throw ValidationError("end of range must be after the start")
        }

        let targets = try calendars(named: calendar)
        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: targets.isEmpty ? nil : targets)

        var found = store.events(matching: predicate)
        if let search {
            let needle = search.lowercased()
            found = found.filter { event in
                [event.title, event.location, event.notes]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(needle) }
            }
        }
        found.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        if json {
            printJSON(found.map(info))
        } else if found.isEmpty {
            print("No events found")
        } else {
            for event in found {
                print(describe(event))
            }
        }
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a single event by id")

    @Argument(help: "Event identifier, from `events --json`")
    var id: String

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireCalendarAccess()
        let match = try event(withId: id)
        if json {
            printJSON(info(match))
        } else {
            print(describe(match))
            if let notes = match.notes, !notes.isEmpty {
                print("\n\(notes)")
            }
        }
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create an event")

    @Argument(parsing: .remaining, help: "Event title")
    var title: [String]

    @Option(name: .long, help: "Calendar to add to (defaults to your default calendar)")
    var calendar: String?

    @Option(name: .long, help: "Start time, e.g. 'tomorrow 9am'")
    var start: DateArg

    @Option(name: .long, help: "End time (default: 1 hour after start)")
    var end: DateArg?

    @Option(name: .long, help: "Duration in minutes (alternative to --end)")
    var duration: Int?

    @Flag(name: .long, help: "Create as an all-day event")
    var allDay = false

    @Option(name: .long, help: "Location")
    var location: String?

    @Option(name: .long, help: "Notes body")
    var notes: String?

    @Option(name: .long, help: "URL to attach")
    var url: String?

    @Flag(name: .long, help: "Output the created event as JSON")
    var json = false

    func run() throws {
        try requireCalendarAccess()
        let name = title.joined(separator: " ")
        guard !name.isEmpty else {
            throw ValidationError("event title is required")
        }
        if end != nil && duration != nil {
            throw ValidationError("pass either --end or --duration, not both")
        }

        let event = EKEvent(eventStore: store)
        event.title = name
        event.calendar = try writableCalendar(named: calendar)
        event.startDate = start.date
        event.isAllDay = allDay

        if let end {
            event.endDate = end.date
        } else if let duration {
            event.endDate = start.date.addingTimeInterval(TimeInterval(duration * 60))
        } else {
            event.endDate = start.date.addingTimeInterval(3600)
        }

        guard let endDate = event.endDate, endDate >= start.date else {
            throw ValidationError("end time must be at or after the start time")
        }

        event.location = location
        event.notes = notes
        if let url {
            event.url = URL(string: url)
        }

        try store.save(event, span: .thisEvent, commit: true)

        if json {
            printJSON(info(event))
        } else {
            print("Created '\(name)' — \(describe(event))")
        }
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Edit an existing event")

    @Argument(help: "Event identifier, from `events --json`")
    var id: String

    @Option(name: .long, help: "New title")
    var title: String?

    @Option(name: .long, help: "New start time")
    var start: DateArg?

    @Option(name: .long, help: "New end time")
    var end: DateArg?

    @Option(name: .long, help: "New location")
    var location: String?

    @Option(name: .long, help: "New notes body (replaces existing notes)")
    var notes: String?

    @Flag(name: .long, help: "Apply to this and all future occurrences of a recurring event")
    var future = false

    @Flag(name: .long, help: "Output the updated event as JSON")
    var json = false

    func run() throws {
        try requireCalendarAccess()
        let match = try event(withId: id)

        guard title != nil || start != nil || end != nil || location != nil || notes != nil else {
            throw ValidationError("nothing to change; pass at least one of --title/--start/--end/--location/--notes")
        }

        if let title { match.title = title }
        if let start { match.startDate = start.date }
        if let end { match.endDate = end.date }
        if let location { match.location = location }
        if let notes { match.notes = notes }

        if let startDate = match.startDate, let endDate = match.endDate, endDate < startDate {
            throw ValidationError("end time must be at or after the start time")
        }

        try store.save(match, span: future ? .futureEvents : .thisEvent, commit: true)

        if json {
            printJSON(info(match))
        } else {
            print("Updated '\(match.title ?? "<untitled>")' — \(describe(match))")
        }
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete an event")

    @Argument(help: "Event identifier, from `events --json`")
    var id: String

    @Flag(name: .long, help: "Delete this and all future occurrences of a recurring event")
    var future = false

    func run() throws {
        try requireCalendarAccess()
        let match = try event(withId: id)
        let title = match.title ?? "<untitled>"
        try store.remove(match, span: future ? .futureEvents : .thisEvent, commit: true)
        print("Deleted '\(title)'")
    }
}

// MARK: - Entry point

AppleCalendar.main()
