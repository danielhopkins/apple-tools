import AppleToolsStyle
import AppleToolsVersion
import ArgumentParser
import EventKit
import Foundation
import TCCResponsibility

private let store = EKEventStore()

// MARK: - Access

private let settingsPath = "System Settings → Privacy & Security → Calendars"

/// Takes ownership of this process's TCC identity, unless Calendar already
/// works.
///
/// Without this, macOS attributes the request to whichever terminal launched
/// us, so the grant lands on the terminal app rather than this binary and the
/// tool is denied under any terminal that has not itself been granted. Re-
/// executing disclaimed keys the grant here instead. It also sidesteps the
/// "Add Only" trap: writeOnly is a state of the *terminal's* grant, and this
/// binary's own grant starts fresh at notDetermined, so macOS will prompt.
///
/// Skipped when access already works, so an existing grant is untouched. Does
/// not return when it re-executes.
func claimOwnTCCIdentity() {
    let status = EKEventStore.authorizationStatus(for: .event)
    TCCResponsibility.claimOwnIdentity(
        unless: status == .fullAccess || status == .authorized)
}

/// Prompts for (or confirms) Calendar access. Called at the top of each command
/// rather than at startup, so `--help` works without a TCC grant.
func requireCalendarAccess() throws {
    claimOwnTCCIdentity()

    // macOS only shows a prompt when the status is notDetermined. Once it is
    // anything else — including writeOnly ("Add Only"), which cannot read
    // events — requestFullAccessToEvents returns false without any dialog, so
    // report what is actually wrong instead of asking for a grant that will
    // never be offered.
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .fullAccess, .authorized:
        return
    case .writeOnly:
        throw ValidationError(
            """
            calendar access is set to "Add Only", which cannot read events.
            macOS will not prompt to upgrade this, so change it by hand:
            \(settingsPath) → set this terminal to "Full Access".
            """)
    case .denied:
        throw ValidationError(
            """
            calendar access was denied. macOS will not prompt again, so re-enable it in:
            \(settingsPath)
            """)
    case .restricted:
        throw ValidationError(
            "calendar access is restricted by a device policy or parental controls.")
    case .notDetermined:
        break  // fall through and prompt
    @unknown default:
        break
    }

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
            "calendar access was not granted\(detail)\nGrant it in \(settingsPath).")
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
    /// Only set for recurring events: the value to pass back as --occurrence so
    /// show/edit/delete act on this instance rather than the series master.
    let occurrence: String?
    /// How the series repeats. `recurring: true` never said *how*.
    let recurrence: RecurrenceInfo?
    /// ⚠️ Objects, not bare names, since 26.812.0 — each carries `email`,
    /// `status`, `role`, `organizer` and `is_me`. Reading `.attendees[]` as a
    /// string used to work and no longer does; read `.attendees[].name`.
    let attendees: [AttendeeInfo]?
    let organizer: AttendeeInfo?
    /// The current user's own response, when they are an invitee.
    let myStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, title, calendar, start, end, allDay, location, notes, url
        case recurring, occurrence, recurrence, attendees, organizer
        case myStatus = "my_status"
    }
}

private func info(_ event: EKEvent) -> EventInfo {
    EventInfo(
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
        occurrence: event.hasRecurrenceRules
            ? event.startDate.map { iso8601.string(from: $0) }
            : nil,
        recurrence: RecurrenceInfo(event.recurrenceRules?.first),
        attendees: Attendees.list(event),
        organizer: Attendees.organizer(event),
        myStatus: Attendees.myStatus(event)
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
    return "\(Style.time(when))  \(Style.title(title))\(Style.dim(location))  "
        + Style.dim("[\(calendarName)]")
}

// MARK: - Shell completion

/// Completion source for --calendar. Returns nothing rather than prompting when
/// access is missing, so pressing TAB can never pop a permission dialog.
func calendarNameCompletion(_ arguments: [String]) -> [String] {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess, .authorized:
        // ':' separates the value from its description in zsh completion lists.
        return store.calendars(for: .event)
            .map { $0.title.replacingOccurrences(of: ":", with: "\\:") }
    default:
        return []
    }
}

func writableCalendarNameCompletion(_ arguments: [String]) -> [String] {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess, .authorized:
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { $0.title.replacingOccurrences(of: ":", with: "\\:") }
    default:
        return []
    }
}

// MARK: - Calendar lookup

private func calendars(named names: [String]) throws -> [EKCalendar] {
    let all = store.calendars(for: .event)
    guard !names.isEmpty else { return all }

    // Titles are not unique — a subscribed "Birthdays" and a writable one can
    // coexist. Return every match rather than the first, so a read of that name
    // covers both instead of silently showing half the events.
    return try names.flatMap { name -> [EKCalendar] in
        let matches = all.filter { $0.title.lowercased() == name.lowercased() }
        guard !matches.isEmpty else {
            throw ValidationError(
                "no calendar named '\(name)'. Available: \(all.map { $0.title }.joined(separator: ", "))")
        }
        return matches
    }
}

private func writableCalendar(named name: String?) throws -> EKCalendar {
    if let name {
        // Calendar titles are not unique. A subscribed read-only "Birthdays"
        // can sit alongside a writable one of the same name, and taking the
        // first match rejected the write as read-only even though `calendars
        // --writable` had just offered that name. Prefer a match that actually
        // accepts writes.
        let matches = store.calendars(for: .event)
            .filter { $0.title.lowercased() == name.lowercased() }
        guard !matches.isEmpty else {
            _ = try calendars(named: [name])  // reuse its "no calendar named" error
            throw ValidationError("no calendar named '\(name)'")
        }
        guard let writable = matches.first(where: { $0.allowsContentModifications }) else {
            throw ValidationError("calendar '\(matches[0].title)' is read-only")
        }
        return writable
    }
    guard let fallback = store.defaultCalendarForNewEvents else {
        throw ValidationError("no default calendar; pass --calendar")
    }
    return fallback
}

/// Look up an event by identifier.
///
/// For a recurring event, `EKEventStore.event(withIdentifier:)` returns the
/// *series master* — the first occurrence, which can be years before the one
/// the caller actually saw in `events`. Passing `occurrence` resolves the
/// specific instance instead by scanning the day it falls on.
private func event(withId id: String, occurrence: Date? = nil) throws -> EKEvent {
    guard let master = store.event(withIdentifier: id) else {
        throw ValidationError("no event with id '\(id)'")
    }

    guard let occurrence else { return master }

    guard master.hasRecurrenceRules else {
        // Harmless to pass --occurrence for a one-off; just don't go searching.
        return master
    }

    let calendar = Foundation.Calendar.current
    let dayStart = calendar.startOfDay(for: occurrence)
    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
        throw ValidationError("could not build a search window around the occurrence date")
    }

    let predicate = store.predicateForEvents(
        withStart: dayStart, end: dayEnd,
        calendars: master.calendar.map { [$0] })

    // Compare base identifiers, not whole ones. Moving a single occurrence
    // *detaches* it, and a detached instance carries a "/RID=<seconds>" suffix
    // — so an exact match stops finding the very instance the caller just
    // moved, and `--occurrence <its new date>` fails with "no occurrence on
    // that day" for an event plainly visible in `events`.
    let base = id.components(separatedBy: "/RID=").first ?? id
    let instances = store.events(matching: predicate)
        .filter { ($0.eventIdentifier?.components(separatedBy: "/RID=").first ?? "") == base }

    guard !instances.isEmpty else {
        throw ValidationError(
            "no occurrence of '\(master.title ?? id)' on "
            + "\(humanDayFormatter.string(from: occurrence)). "
            + "Use `events --json` to list real occurrences.")
    }

    // A day can hold more than one instance; take the closest start.
    return instances.min {
        abs($0.startDate.timeIntervalSince(occurrence))
            < abs($1.startDate.timeIntervalSince(occurrence))
    } ?? master
}

/// Guard the write paths against silently editing the wrong instance.
private func resolveForWrite(
    id: String, occurrence: DateArg?, series: Bool, verb: String
) throws -> EKEvent {
    // 🛑 An identifier gains a "/RID=<seconds>" suffix once that occurrence has
    // been *detached* (any single-occurrence edit does it), and it then resolves
    // to the detached instance rather than the series master. A detached
    // instance carries no recurrence rule of its own, so `--series --repeat`
    // against one fails with "The repeat field cannot be changed" — while
    // reporting the event's title, so it reads as the right event refusing.
    // --series means the master, so ask for the master.
    if series, let base = id.components(separatedBy: "/RID=").first, base != id,
       let seriesMaster = try? event(withId: base) {
        return seriesMaster
    }

    let master = try event(withId: id)

    guard master.hasRecurrenceRules else { return master }

    if series {
        return master
    }

    guard let occurrence else {
        throw ValidationError(
            """
            '\(master.title ?? id)' is a recurring event, and this id refers to the \
            whole series (first occurrence \
            \(master.startDate.map { humanDayFormatter.string(from: $0) } ?? "unknown")).
            Pass --occurrence with the instance you mean — `events --json` reports it \
            as "occurrence" — or --series to \(verb) the series itself.
            """)
    }

    return try event(withId: id, occurrence: occurrence.date)
}

// MARK: - Commands

struct AppleCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-calendar",
        abstract: "Read and write macOS Calendar events via EventKit",
        discussion: """
          Examples:
            apple-calendar status                         # permission state
            apple-calendar calendars --writable           # what accepts writes
            apple-calendar events --days 7 --json         # next week
            apple-calendar events --search "swim" --days 30
            apple-calendar add "Dentist" --start "tomorrow 2pm" --duration 45
            apple-calendar edit <id> --occurrence <occurrence> --start "3pm"
          """,
        version: appleToolsVersion,
        subcommands: [Calendars.self, Events.self, Show.self, Add.self, Edit.self, Invite.self,
                      Delete.self, Status.self],
        defaultSubcommand: Events.self
    )
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report Calendar permission state without requesting it")

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() {
        // Re-exec too, so this reports the identity the other commands actually
        // use. Disclaiming never prompts on its own.
        claimOwnTCCIdentity()

        let status = EKEventStore.authorizationStatus(for: .event)
        let (name, usable, advice): (String, Bool, String?) = {
            switch status {
            case .fullAccess:    return ("fullAccess", true, nil)
            case .authorized:    return ("authorized", true, nil)
            case .writeOnly:     return ("writeOnly", false,
                "Set to \"Full Access\" in \(settingsPath); \"Add Only\" cannot read events.")
            case .denied:        return ("denied", false, "Re-enable in \(settingsPath).")
            case .restricted:    return ("restricted", false, "Blocked by device policy.")
            case .notDetermined: return ("notDetermined", false,
                "Run any command to trigger the permission prompt.")
            @unknown default:    return ("unknown", false, nil)
            }
        }()

        if json {
            var payload: [String: Any] = ["status": name, "usable": usable]
            payload["advice"] = advice
            let data = try? JSONSerialization.data(
                withJSONObject: payload.compactMapValues { $0 },
                options: [.prettyPrinted, .sortedKeys])
            print(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        } else {
            print("Calendar access: \(name)\(usable ? "" : "  (cannot read events)")")
            if let advice { print(advice) }
        }
    }
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
                let readonly = calendar.allowsContentModifications
                    ? "" : Style.warning(" (read-only)")
                print("\(Style.title(calendar.title))\(readonly)")
            }
        }
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List events in a date range (defaults to the next 7 days)",
        discussion: """
          Recurring events carry an "occurrence" field in --json. Pass it back as
          --occurrence to act on that instance rather than the series.

          Examples:
            apple-calendar events                          # next 7 days
            apple-calendar events --days 1 --json          # today
            apple-calendar events --from 2026-08-01 --to 2026-08-31
            apple-calendar events --calendar Family --search "piano"
          """)

    @Option(name: .long, help: "Start of range, e.g. 'today', '2026-07-27'")
    var from: DateArg?

    @Option(name: .long, help: "End of range (exclusive of --days)")
    var to: DateArg?

    @Option(name: .long, help: "Number of days from --from (default 7)")
    var days: Int?

    @Option(
        name: .long,
        help: "Limit to these calendars (repeatable)",
        completion: .custom(calendarNameCompletion))
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

    @Option(name: .long, help: "Which occurrence of a recurring event (its \"occurrence\" field)")
    var occurrence: DateArg?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireCalendarAccess()
        let match = try event(withId: id, occurrence: occurrence?.date)

        // Reads can't do damage, so surface the ambiguity instead of refusing.
        if match.hasRecurrenceRules && occurrence == nil {
            FileHandle.standardError.write(Data("""
                note: this is a recurring series; showing its first occurrence. \
                Pass --occurrence to see a specific instance.

                """.utf8))
        }

        if json {
            printJSON(info(match))
        } else {
            print(describe(match))
            if let list = Attendees.list(match) {
                print("Invitees:")
                for attendee in list { print(Attendees.describe(attendee)) }
            }
            if let notes = match.notes, !notes.isEmpty {
                print("\n\(notes)")
            }
        }
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create an event",
        discussion: """
          Dates take natural language or YYYY-MM-DD [HH:MM]. Default length is
          1 hour. --calendar must match `calendars --writable`.

          Examples:
            apple-calendar add "Dentist" --start "tomorrow 2pm" --duration 45
            apple-calendar add "Standup" --start "2026-08-03 09:00" --end "09:15"
            apple-calendar add "Holiday" --start 2026-08-10 --all-day --calendar Family
          """)

    @Argument(parsing: .remaining, help: "Event title")
    var title: [String]

    @Option(
        name: .long,
        help: "Calendar to add to (defaults to your default calendar)",
        completion: .custom(writableCalendarNameCompletion))
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

    @Option(
        name: .long,
        help: "Invite someone: 'a@b.com' or 'Name <a@b.com>'. Repeatable. Sends a real invitation.")
    var invitee: [String] = []

    @OptionGroup var recurrence: RecurrenceOptions

    @Flag(name: .long, help: "Output the created event as JSON")
    var json = false

    func validate() throws {
        try recurrence.validate()
    }

    func run() throws {
        try requireCalendarAccess()
        let name = title.joined(separator: " ")
        guard !name.isEmpty else {
            throw ValidationError("event title is required")
        }
        if end != nil && duration != nil {
            throw ValidationError("pass either --end or --duration, not both")
        }

        // Parse and check the invitees before creating anything, so a typo
        // cannot leave a half-built event behind that then has to be cleaned up.
        let guests = try invitee.map { spec -> (name: String?, email: String) in
            guard let parsed = AttendeeAddress.parse(spec) else {
                throw ValidationError(
                    "'\(spec)' is not an address. Use 'a@b.com' or 'Name <a@b.com>'.")
            }
            return parsed
        }
        if !guests.isEmpty && !AttendeeAPI.isAvailable {
            throw ValidationError(AttendeeAPI.unavailableMessage)
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

        if let rule = recurrence.rule() {
            event.recurrenceRules = [rule]
            if let warning = recurrence.startDateWarning(start: start.date) {
                FileHandle.standardError.write(Data((warning + "\n").utf8))
            }
            // 🛑 An invitation to a series invites the person to every
            // occurrence, and the mail goes out on save like any other.
            if !guests.isEmpty {
                FileHandle.standardError.write(Data("""
                    note: \(guests.count) invitee\(guests.count == 1 ? "" : "s") on a recurring \
                    event — the invitation covers the whole series, not one occurrence.

                    """.utf8))
            }
        }

        for guest in guests {
            guard let attendee = AttendeeAPI.make(name: guest.name, email: guest.email) else {
                throw ValidationError(
                    "could not build an invitee for '\(guest.email)'. \(AttendeeAPI.unavailableMessage)")
            }
            AttendeeAPI.add(attendee, to: event)
        }

        // .thisEvent on a brand-new event creates the series; there is no
        // earlier occurrence for a span to be relative to.
        try store.save(event, span: .thisEvent, commit: true)

        if json {
            printJSON(info(event))
        } else {
            print("Created '\(name)' — \(describe(event))")
            if let pattern = RecurrenceInfo(event.recurrenceRules?.first) {
                print("Repeats: \(pattern.describe)")
            }
            // EventKit adds the organizer and a self-attendee of its own accord
            // on the first save of an event that has invitees, so report what
            // the event ended up with rather than what was asked for.
            if let list = Attendees.list(event) {
                print("Invitees:")
                for attendee in list { print(Attendees.describe(attendee)) }
                print(Style.warning("Invitations are sent by the server — this is not undoable."))
            }
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

    @Option(name: .long, help: "Which occurrence to edit (its \"occurrence\" field from `events --json`)")
    var occurrence: DateArg?

    @Flag(name: .long, help: "Target the recurring series itself rather than one occurrence")
    var series = false

    @Flag(name: .long, help: "Apply to this and all future occurrences of a recurring event")
    var future = false

    @OptionGroup var recurrence: RecurrenceOptions

    @Flag(name: .long, help: "Output the updated event as JSON")
    var json = false

    func validate() throws {
        try recurrence.validate()
    }

    func run() throws {
        try requireCalendarAccess()

        // 🛑 A recurrence rule belongs to the series, never to one occurrence —
        // there is no such thing as "this Tuesday repeats weekly". Applying it
        // to a single instance would detach that instance and leave the series
        // unchanged, which looks like success and does nothing.
        if recurrence.wasSpecified && !series {
            throw ValidationError("""
                changing how an event repeats applies to the whole series, so it needs --series. \
                (--occurrence targets one instance, which cannot carry a recurrence rule of its own.)
                """)
        }

        let match = try resolveForWrite(
            id: id, occurrence: occurrence, series: series, verb: "edit")

        guard title != nil || start != nil || end != nil || location != nil || notes != nil
            || recurrence.wasSpecified else {
            throw ValidationError(
                "nothing to change; pass at least one of --title/--start/--end/--location/--notes/--repeat")
        }

        // Applied to the retry target too, so both attempts are identical.
        func apply(to event: EKEvent, warn: Bool) {
            if let title { event.title = title }
            if let start { event.startDate = start.date }
            if let end { event.endDate = end.date }
            if let location { event.location = location }
            if let notes { event.notes = notes }

            guard recurrence.wasSpecified else { return }
            if let rule = recurrence.rule() {
                event.recurrenceRules = [rule]
                let effectiveStart = start?.date ?? event.startDate
                if warn, let effectiveStart,
                   let warning = recurrence.startDateWarning(start: effectiveStart) {
                    FileHandle.standardError.write(Data((warning + "\n").utf8))
                }
            } else {
                // --repeat none: collapse the series to a single event.
                event.recurrenceRules = nil
            }
        }
        apply(to: match, warn: true)

        if let startDate = match.startDate, let endDate = match.endDate, endDate < startDate {
            throw ValidationError("end time must be at or after the start time")
        }

        // 🛑 A recurrence-rule change MUST be saved with .futureEvents.
        // Saving a changed rule on the series master with .thisEvent silently
        // rewrites it to FREQ=DAILY;INTERVAL=1 — no error, and `save` reports
        // success. Measured: a monthly BYDAY=4MO series became daily, turning
        // 4 occurrences a year into 365. .futureEvents round-trips correctly.
        // Since a rule change already requires --series, the master is the
        // first occurrence and .futureEvents means exactly "the whole series".
        // 🛑 --series means the whole series, and that requires .futureEvents.
        // With .thisEvent it *detached the first occurrence*, applied the change
        // to that alone and left the series untouched — while reporting success.
        // Measured: `edit --series --location X` produced one detached instance
        // carrying X and five unchanged occurrences. Same root cause as the
        // recurrence-rule corruption above; --series is simply never .thisEvent.
        let span: EKSpan = (series || future || recurrence.wasSpecified)
            ? .futureEvents : .thisEvent
        if !simulatingLostWrite {
            try store.save(match, span: span, commit: true)
        }

        // 🛑 Everything below exists because `save` reporting success is not
        // evidence the change persisted. Reporting `match` here — the object we
        // just mutated — describes the *request*, so it can never fail. The
        // answer has to come from the store.
        let want = IntendedChange(
            start: start?.date, end: end?.date, title: title,
            location: location, notes: notes,
            recurs: recurrence.wasSpecified ? recurrence.isRecurring : nil)
        let intendedStart = start?.date ?? match.startDate

        func readBack() -> EKEvent? {
            WriteConfirmation.locate(
                identifier: match.eventIdentifier ?? id, fallbackID: id,
                near: intendedStart, allowDetachedScan: occurrence != nil && !series,
                in: freshStore())
        }

        var persisted = readBack()
        var problems = WriteConfirmation.mismatches(persisted, want: want)

        // Observed intermittently on a recurring series: the first save takes
        // no effect at all and an identical retry works. Retrying is safe only
        // because nothing landed — a partial write re-resolves to a different
        // occurrence and is reported rather than retried.
        if !problems.isEmpty, !want.isEmpty {
            store.refreshSourcesIfNecessary()
            if let retry = try? resolveForWrite(
                id: id, occurrence: occurrence, series: series, verb: "edit") {
                apply(to: retry, warn: false)
                if simulatingLostWrite || (try? store.save(retry, span: span, commit: true)) != nil {
                    persisted = WriteConfirmation.locate(
                        identifier: retry.eventIdentifier ?? id, fallbackID: id,
                        near: intendedStart, allowDetachedScan: occurrence != nil && !series,
                        in: freshStore())
                    let after = WriteConfirmation.mismatches(persisted, want: want)
                    if after.isEmpty {
                        FileHandle.standardError.write(Data(
                            "note: the first save did not take and was retried.\n".utf8))
                    }
                    problems = after
                }
            }
        }

        guard problems.isEmpty, let saved = persisted else {
            throw ValidationError("""
                the save reported success but the store does not hold the change:
                  \(problems.joined(separator: "\n  "))
                Nothing here is reported as done unless it was read back.
                """)
        }

        if json {
            printJSON(info(saved))
        } else {
            print("Updated '\(saved.title ?? "<untitled>")' — \(describe(saved))")
            if let pattern = RecurrenceInfo(saved.recurrenceRules?.first) {
                print("Repeats: \(pattern.describe)")
            } else if recurrence.wasSpecified {
                print("Repeats: no longer repeats")
            }
        }
    }
}

// MARK: - Confirming a write actually landed

/// What an `edit` asked for, so it can be checked against what the store holds.
struct IntendedChange {
    var start: Date?
    var end: Date?
    var title: String?
    var location: String?
    var notes: String?
    /// True when a recurrence rule should exist afterwards, false when it
    /// should not, nil when recurrence was not part of the request.
    var recurs: Bool?

    var isEmpty: Bool {
        start == nil && end == nil && title == nil && location == nil && notes == nil
            && recurs == nil
    }
}

/// 🛑 **`EKEventStore.save` returning true does not mean the change persisted.**
/// Measured in the field: moving one occurrence of a monthly series returned
/// exit 0 and a JSON body describing the moved, detached occurrence, while a
/// re-read still showed the *original* date and an intact series. An identical
/// retry then worked. So the value a write command reports must come from the
/// store, never from the in-memory object it just mutated — that object always
/// reflects the request and is therefore always "successful".
///
/// Finding the event again is the fiddly part: moving an occurrence **detaches**
/// it, which mints a new identifier ending in `/RID=<seconds>`. So this looks up
/// by identifier first, then falls back to scanning the day around the intended
/// start for anything sharing the same base identifier.
enum WriteConfirmation {
    /// `allowDetachedScan` must be false for a whole-series write. A series edit
    /// that wrongly detached one occurrence leaves that instance carrying the
    /// change, so scanning the day would *find* it and report success for
    /// precisely the bug worth catching.
    static func locate(
        identifier: String, fallbackID: String, near date: Date?,
        allowDetachedScan: Bool, in store: EKEventStore
    ) -> EKEvent? {
        if let direct = store.event(withIdentifier: identifier) { return direct }
        if identifier != fallbackID, let direct = store.event(withIdentifier: fallbackID) {
            return direct
        }
        guard allowDetachedScan, let date else { return nil }

        let base = identifier.components(separatedBy: "/RID=").first ?? identifier
        let calendar = Foundation.Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        return store.events(matching: store.predicateForEvents(
            withStart: dayStart, end: dayEnd, calendars: nil))
            .first { ($0.eventIdentifier?.components(separatedBy: "/RID=").first ?? "") == base }
    }

    /// Field-by-field, naming everything that did not take.
    static func mismatches(_ event: EKEvent?, want: IntendedChange) -> [String] {
        guard let event else { return ["the event could not be found after the save"] }
        var problems: [String] = []

        func compare(_ label: String, _ actual: Date?, _ expected: Date?) {
            guard let expected else { return }
            // Second granularity: stores round sub-second components.
            guard let actual, abs(actual.timeIntervalSince(expected)) < 1 else {
                problems.append(
                    "\(label) is \(actual.map { iso8601.string(from: $0) } ?? "unset"), "
                    + "expected \(iso8601.string(from: expected))")
                return
            }
        }
        compare("start", event.startDate, want.start)
        compare("end", event.endDate, want.end)

        func compareText(_ label: String, _ actual: String?, _ expected: String?) {
            guard let expected, (actual ?? "") != expected else { return }
            problems.append("\(label) is \(actual.map { "'\($0)'" } ?? "unset"), expected '\(expected)'")
        }
        compareText("title", event.title, want.title)
        compareText("location", event.location, want.location)
        compareText("notes", event.notes, want.notes)

        if let recurs = want.recurs, recurs != event.hasRecurrenceRules {
            problems.append(
                recurs
                    ? "the event has no recurrence rule, but one was set"
                    : "the event still repeats, but recurrence was removed")
        }
        return problems
    }
}

/// Test seam: makes every `save` in `edit` a no-op, so the confirmation path
/// can be exercised deliberately.
///
/// The failure it stands in for is real but **intermittent** — a save that
/// reports success and changes nothing — and there is no way to provoke it on
/// demand. Without this the read-back logic would only ever be tested on the
/// happy path, which is exactly how it came to be missing. It can only turn a
/// silent no-op into a loud one, never the reverse.
private var simulatingLostWrite: Bool {
    ProcessInfo.processInfo.environment["APPLE_CALENDAR_SIMULATE_LOST_WRITE"] == "1"
}

/// A fresh store, so a write can be confirmed against what was persisted rather
/// than against the object we just mutated in memory.
private func freshStore() -> EKEventStore {
    let fresh = EKEventStore()
    let semaphore = DispatchSemaphore(value: 0)
    fresh.requestFullAccessToEvents { _, _ in semaphore.signal() }
    semaphore.wait()
    return fresh
}

struct InviteeChange: Encodable {
    let email: String
    let action: String
    let changed: Bool
    let confirmed: Bool?
}

struct Invite: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite",
        abstract: "Add or remove invitees on an existing event",
        discussion: """
          🛑 Saving an invitee change makes the server send a real invitation, and
          removing one sends a cancellation. Neither is undoable. Run --dry-run
          first.

          Only the organizer can change who is invited. For an event someone else
          created this refuses, because a local change would be silently reverted
          by the server.

          Examples:
            apple-calendar invite <id> --add a@b.com --dry-run
            apple-calendar invite <id> --add "Dana White <d@x.com>" --add b@c.com
            apple-calendar invite <id> --remove a@b.com --occurrence 2026-08-20
          """)

    @Argument(help: "Event identifier, from `events --json`")
    var id: String

    @Option(name: .long, help: "Invite this address: 'a@b.com' or 'Name <a@b.com>'. Repeatable.")
    var add: [String] = []

    @Option(name: .long, help: "Uninvite this address. Repeatable.")
    var remove: [String] = []

    @Option(name: .long, help: "Which occurrence to change (its \"occurrence\" field from `events --json`)")
    var occurrence: DateArg?

    @Flag(name: .long, help: "Target the recurring series itself rather than one occurrence")
    var series = false

    @Flag(name: .long, help: "Apply to this and all future occurrences of a recurring event")
    var future = false

    @Flag(name: .long, help: "Show what would change without sending anything")
    var dryRun = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireCalendarAccess()

        guard !add.isEmpty || !remove.isEmpty else {
            throw ValidationError("nothing to do; pass --add and/or --remove")
        }
        guard AttendeeAPI.isAvailable else {
            throw ValidationError(AttendeeAPI.unavailableMessage)
        }

        func parse(_ specs: [String], flag: String) throws -> [(name: String?, email: String)] {
            try specs.map { spec in
                guard let parsed = AttendeeAddress.parse(spec) else {
                    throw ValidationError(
                        "\(flag) '\(spec)' is not an address. Use 'a@b.com' or 'Name <a@b.com>'.")
                }
                return parsed
            }
        }
        let additions = try parse(add, flag: "--add")
        let removals = try parse(remove, flag: "--remove")

        if let clash = additions.first(where: { addition in
            removals.contains { $0.email.compare(addition.email, options: .caseInsensitive) == .orderedSame }
        }) {
            throw ValidationError("'\(clash.email)' is in both --add and --remove.")
        }

        let match = try resolveForWrite(
            id: id, occurrence: occurrence, series: series, verb: "change invitees on")

        if let refusal = Attendees.modificationRefusal(match) {
            throw ValidationError(refusal)
        }

        let existing = match.attendees ?? []
        var changes: [InviteeChange] = []
        var pendingAdds: [(name: String?, email: String)] = []
        var pendingRemovals: [EKParticipant] = []

        for addition in additions {
            if existing.contains(where: { AttendeeAddress.matches($0, addition.email) }) {
                changes.append(.init(
                    email: addition.email, action: "already-invited", changed: false, confirmed: nil))
            } else {
                pendingAdds.append(addition)
                changes.append(.init(
                    email: addition.email, action: "add", changed: true, confirmed: nil))
            }
        }
        for removal in removals {
            if let found = existing.first(where: { AttendeeAddress.matches($0, removal.email) }) {
                pendingRemovals.append(found)
                changes.append(.init(
                    email: removal.email, action: "remove", changed: true, confirmed: nil))
            } else {
                changes.append(.init(
                    email: removal.email, action: "not-invited", changed: false, confirmed: nil))
            }
        }

        if dryRun {
            report(event: match, changes: changes, dryRun: true)
            return
        }

        guard !pendingAdds.isEmpty || !pendingRemovals.isEmpty else {
            report(event: match, changes: changes, dryRun: false)
            return
        }

        for addition in pendingAdds {
            guard let attendee = AttendeeAPI.make(name: addition.name, email: addition.email) else {
                throw ValidationError(
                    "could not build an invitee for '\(addition.email)'. \(AttendeeAPI.unavailableMessage)")
            }
            AttendeeAPI.add(attendee, to: match)
        }
        for participant in pendingRemovals {
            AttendeeAPI.remove(participant, from: match)
        }

        try store.save(match, span: future ? .futureEvents : .thisEvent, commit: true)

        // Confirm against what was persisted. The private calls report nothing,
        // and a save that reports success without taking effect is exactly the
        // failure this needs to catch.
        let persisted = freshStore().event(withIdentifier: match.eventIdentifier ?? id)
        let after = persisted?.attendees ?? []
        let confirmed = changes.map { change -> InviteeChange in
            guard change.changed, persisted != nil else { return change }
            let present = after.contains { AttendeeAddress.matches($0, change.email) }
            let wanted = change.action == "add"
            return .init(
                email: change.email, action: change.action, changed: change.changed,
                confirmed: present == wanted)
        }

        report(event: persisted ?? match, changes: confirmed, dryRun: false)

        if confirmed.contains(where: { $0.confirmed == false }) {
            throw ExitCode(1)
        }
    }

    private func report(event: EKEvent, changes: [InviteeChange], dryRun: Bool) {
        if json {
            struct Payload: Encodable {
                let id: String
                let title: String
                let dryRun: Bool
                let changes: [InviteeChange]
                let attendees: [AttendeeInfo]?
                enum CodingKeys: String, CodingKey {
                    case id, title, changes, attendees
                    case dryRun = "dry_run"
                }
            }
            printJSON(Payload(
                id: event.eventIdentifier ?? id,
                title: event.title ?? "<untitled>",
                dryRun: dryRun,
                changes: changes,
                attendees: Attendees.list(event)))
            return
        }

        print(describe(event))
        for change in changes {
            let verb: String
            switch (change.action, dryRun) {
            case ("add", true):     verb = "would invite"
            case ("add", false):    verb = change.confirmed == false ? "FAILED to invite" : "invited"
            case ("remove", true):  verb = "would uninvite"
            case ("remove", false): verb = change.confirmed == false ? "FAILED to uninvite" : "uninvited"
            case ("already-invited", _): verb = "already invited, unchanged"
            default:                verb = "was not invited, unchanged"
            }
            let line = "  \(verb): \(change.email)"
            print(change.confirmed == false ? Style.warning(line) : line)
        }

        if let list = Attendees.list(event) {
            print("\nInvitees now:")
            for attendee in list { print(Attendees.describe(attendee)) }
        }

        if dryRun {
            print("")
            print(Style.warning("--dry-run: nothing was sent. Re-run without it to apply."))
        } else if changes.contains(where: { $0.changed }) {
            print("")
            print(Style.warning(
                "The server sends the invitations and cancellations. This is not undoable."))
        }
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete an event")

    @Argument(help: "Event identifier, from `events --json`")
    var id: String

    @Option(name: .long, help: "Which occurrence to delete (its \"occurrence\" field from `events --json`)")
    var occurrence: DateArg?

    @Flag(name: .long, help: "Target the recurring series itself rather than one occurrence")
    var series = false

    @Flag(name: .long, help: "Delete this and all future occurrences of a recurring event")
    var future = false

    func run() throws {
        try requireCalendarAccess()
        let match = try resolveForWrite(
            id: id, occurrence: occurrence, series: series, verb: "delete")
        let title = match.title ?? "<untitled>"
        // Same rule as edit: --series is the whole series, never one occurrence.
        // With .thisEvent, `delete --series` removed only the first occurrence
        // and reported the series deleted.
        try store.remove(
            match, span: (series || future) ? .futureEvents : .thisEvent, commit: true)
        print("Deleted '\(title)'")
    }
}

// MARK: - Entry point

// ArgumentParser has no coloured help, so generate it, style it, and print
// it here rather than letting .main() emit the plain version.
if let help = HelpColor.requested(root: AppleCalendar.self, arguments: CommandLine.arguments) {
    print(help)
    exit(0)
}

AppleCalendar.main()
