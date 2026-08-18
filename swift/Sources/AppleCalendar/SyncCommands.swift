import ArgumentParser
import CalendarSyncLibrary
import EventKit
import Foundation

/// The read commands that answer "did that write reach the server?".
///
/// 🛑 **They exist because nothing did.** Diagnosing one 403 took an hour of
/// hand-written SQL plus an `NSKeyedArchiver` plist decode, and the answer was
/// two columns and one table away the whole time.

// MARK: - sync-errors

struct SyncErrors: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-errors",
        abstract: "Show sync failures Calendar recorded but never reported",
        discussion: """
          Decodes Calendar's own Error table, including the archived plist that
          holds the HTTP status. A row here means the server refused a write and
          EventKit gave up on it: the item stays in the local store, visible in
          Calendar.app and returned by `events`, while absent from the server.

          🛑 An empty result is NOT proof everything synced. In the second
          observed failure mode the local copy is deleted and no Error row is
          written at all. Run `unsynced` as well.
          """)

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        // No EventKit call: this reads the store only, so it needs Full Disk
        // Access rather than the Calendar grant.
        guard SyncStore.isReadable else {
            throw ValidationError(
                """
                cannot read Calendar's store.

                This command reads Calendar.sqlitedb directly, which needs Full
                Disk Access for this terminal — a different grant from the
                Calendar one that `events` and `add` use.

                  System Settings -> Privacy & Security -> Full Disk Access
                """)
        }

        let failures = SyncStore.failures()

        if json {
            printJSON(failures)
            return
        }

        guard !failures.isEmpty else {
            print("No sync errors recorded.")
            print("note: this table is empty in the failure mode where the item "
                  + "is deleted rather than stuck.")
            print("      Run `apple calendar unsynced` too.")
            return
        }

        for failure in failures {
            let status = failure.httpStatus.map { " HTTP \($0)" } ?? ""
            print("\(failure.scope)\(status)  \(failure.domain ?? "?")")
            if let item = failure.item { print("  event:    \(item)") }
            if let calendar = failure.calendar { print("  calendar: \(calendar)") }
            if let store = failure.store { print("  account:  \(store)") }
            print("  error_code \(failure.errorCode), error_type \(failure.errorType)")
        }
        print("")
        print("\(failures.count) error\(failures.count == 1 ? "" : "s"). "
              + "EventKit stops retrying an item once it records one.")
    }
}

// MARK: - unsynced

struct Unsynced: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unsynced",
        abstract: "List events that never reached their server",
        discussion: """
          An event whose external_id is empty was never accepted by the server.
          On a healthy machine this prints nothing.

          Three filters keep it honest, and each was measured against a real
          store. Without them this command reports 468 healthy events as broken:

            detached occurrences   329 on CalDAV never carry an external_id
            generated stores       139 in Birthdays and Siri suggestions
            disabled accounts      10 of 16 stores here are switched off
          """)

    @Option(name: .long, help: "Only this calendar, by name",
            completion: .custom(calendarNameCompletion))
    var calendar: String?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        var identifier: String?
        if let name = calendar {
            // Resolving a name needs EventKit; the scan itself does not.
            try requireCalendarAccess()
            let matches = try calendars(named: [name])
            guard let first = matches.first else {
                throw ValidationError("no calendar named '\(name)'")
            }
            // ⚠️ Titles are not unique. Narrowing to one identifier would hide
            // rows on the other calendar of the same name, so refuse instead.
            if matches.count > 1 {
                throw ValidationError(
                    "\(matches.count) calendars are named '\(name)'; "
                    + "drop --calendar to scan them all")
            }
            identifier = first.calendarIdentifier
        }

        guard let pending = SyncStore.pending(calendarIdentifier: identifier) else {
            throw ValidationError(
                """
                cannot read Calendar's store.

                This command reads Calendar.sqlitedb directly, which needs Full
                Disk Access for this terminal — a different grant from the
                Calendar one that `events` and `add` use.

                  System Settings -> Privacy & Security -> Full Disk Access
                """)
        }

        if json {
            printJSON(pending)
            return
        }

        guard !pending.isEmpty else {
            print("Everything has reached its server.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for item in pending {
            let when = item.start.map(formatter.string(from:)) ?? "no date"
            print("\(when)  \(item.summary ?? "<untitled>")")
            print("  \(item.calendar) (\(item.store), \(item.backend))")
            for failure in item.errors {
                let status = failure.httpStatus.map { "HTTP \($0)" } ?? "no status"
                print("  error: \(status) \(failure.domain ?? "") "
                      + "(scope: \(failure.scope))")
            }
        }
        print("")
        print("\(pending.count) event\(pending.count == 1 ? "" : "s") not on a server.")
        print("note: a write that is only seconds old is still in flight; "
              + "sync takes about 4s here.")
        print("      One with an error above will never retry on its own.")
    }
}

// MARK: - sync-status

struct SyncStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-status",
        abstract: "Did this one event reach the server?")

    @Argument(help: "Event identifier, from `events --json`")
    var id: String

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() throws {
        try requireCalendarAccess()
        let event = try event(withId: id)
        guard let calendarIdentifier = event.calendar?.calendarIdentifier else {
            throw ValidationError("that event has no calendar")
        }

        let status = SyncStore.status(
            eventIdentifier: event.eventIdentifier ?? id,
            calendarIdentifier: calendarIdentifier)

        if json {
            printJSON(status)
            return
        }

        print("\(event.title ?? "<untitled>")  [\(status.state.rawValue)]")
        if let reason = status.reason { print("  \(reason)") }
        if let backend = status.backend { print("  backend: \(backend)") }
        if let externalId = status.externalId { print("  server id: \(externalId)") }
        for failure in status.errors {
            let http = failure.httpStatus.map { "HTTP \($0)" } ?? "no status"
            print("  error: \(http) \(failure.domain ?? "") (scope: \(failure.scope))")
        }
    }
}

// MARK: - Confirming a write reached the server

/// Flags shared by `add` and `edit`.
///
/// 🛑 **Confirmation is ON by default, and that is the fix for the bug this
/// file exists for.** The old behaviour — print a full event record the instant
/// EventKit saved — reported success for a write the server refused, and the
/// caller told the user the event was on their calendar.
struct SyncConfirmationOptions: ParsableArguments {
    @Flag(name: .long, inversion: .prefixedNo,
          help: "Wait for the server to accept the write before reporting success")
    var confirmSync = true

    @Option(name: .long, help: "Seconds to wait for the server (default: 30)")
    var syncTimeout: Double = 30
}

enum SyncConfirmation {

    /// Polls until the server takes the event, refuses it, or the deadline passes.
    ///
    /// ⚠️ **30 seconds is generous, not tight.** Six timed trials on this
    /// machine put create-to-`external_id` at **4 seconds every time**, with and
    /// without a manual `reload calendars`. So something still pending at 30s is
    /// a real problem rather than a slow network.
    ///
    /// ⚠️ **`reload calendars` does not help.** It exits 0, does not need
    /// Calendar.app running, does not wipe pending writes — and does not speed
    /// anything up. Measured across the same six trials. So nothing here calls
    /// it.
    static func wait(event: EKEvent, timeout: Double,
                     against baseline: SyncStore.Baseline? = nil,
                     since snapshot: SyncStore.ErrorSnapshot? = nil) -> SyncStore.Status {
        guard let calendarIdentifier = event.calendar?.calendarIdentifier,
              let eventIdentifier = event.eventIdentifier else {
            return .unknown("the event has no identifier to look up")
        }

        func look() -> SyncStore.Status {
            SyncStore.status(eventIdentifier: eventIdentifier,
                             calendarIdentifier: calendarIdentifier,
                             against: baseline)
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        var status = look()
        while status.state == .pending && Date() < deadline {
            // 🛑 **Only an error recorded AFTER the save can stop the wait.**
            // A fresh create has no `external_id` at t=0, so the first look is
            // always `pending`; giving up there on any error at all meant one
            // stale row on the calendar failed every write that followed it.
            // With no snapshot the store was unreadable, so nothing is known
            // to be old — poll to the deadline instead of guessing.
            if let snapshot, status.errors.contains(where: snapshot.isNew) { break }
            Thread.sleep(forTimeInterval: 1)
            status = look()
        }
        return status
    }

    /// The `Error` rows that existed before a save, so the wait can tell a new
    /// refusal from an old one. Take it BEFORE calling `store.save`.
    static func errorSnapshot() -> SyncStore.ErrorSnapshot? {
        SyncStore.errorSnapshot()
    }

    /// The snapshot an `edit` must take before it saves.
    ///
    /// ⚠️ Returns nil when the write is a create — there is nothing to compare
    /// against, and the appearance of an `external_id` is the whole signal.
    static func baseline(for event: EKEvent) -> SyncStore.Baseline? {
        guard let calendarIdentifier = event.calendar?.calendarIdentifier,
              let eventIdentifier = event.eventIdentifier else { return nil }
        return SyncStore.baseline(eventIdentifier: eventIdentifier,
                                  calendarIdentifier: calendarIdentifier)
    }

    /// Runs the wait and throws when the write did not reach the server.
    ///
    /// Returns the status so the caller can put it in its own output. A caller
    /// that gets a throw must not have printed a success line yet.
    static func check(event: EKEvent, options: SyncConfirmationOptions,
                      against baseline: SyncStore.Baseline? = nil,
                      since snapshot: SyncStore.ErrorSnapshot? = nil) throws
        -> SyncStore.Status?
    {
        guard options.confirmSync else { return nil }

        let status = wait(event: event, timeout: options.syncTimeout,
                          against: baseline, since: snapshot)

        switch status.state {
        case .synced, .notApplicable:
            return status

        case .unknown:
            // ⚠️ Never turn "I could not check" into a failure. There are two
            // quite different reasons to land here and they need different
            // advice, so do not print one message for both:
            //
            //   1. the store is unreadable — Full Disk Access is missing, which
            //      the Calendar grant does not carry. Fixable.
            //   2. the backend keeps no local record — an Exchange edit changes
            //      nothing in this store at all. NOT fixable, and telling the
            //      user to grant a permission they already have wastes their
            //      time on the wrong thing.
            var advice = "The event was saved locally."
            if !SyncStore.isReadable {
                advice += " Grant Full Disk Access, then run "
                    + "`apple calendar unsynced`."
            } else {
                advice += " Check the server itself if it matters."
            }
            FileHandle.standardError.write(Data("""
                note: could not confirm this reached the server — \
                \(status.reason ?? "unknown reason").
                      \(advice)

                """.utf8))
            return status

        case .pending:
            // 🛑 The whole point. Do not report success for a write the server
            // has not taken.
            var lines = [
                "the event was saved locally but the server has not accepted it.",
                "",
            ]
            // Name only an error this write produced. A row that predates
            // the save explains nothing about it, and printing it sends the
            // reader after the wrong event.
            let blame = snapshot.map { snap in status.errors.filter(snap.isNew) }
                ?? status.errors
            if let failure = blame.first {
                let http = failure.httpStatus.map { "HTTP \($0)" } ?? "no HTTP status"
                lines.append("  \(http) \(failure.domain ?? "") (scope: \(failure.scope))")
                lines.append("")
                lines.append("EventKit records an error once and then stops retrying that item,")
                lines.append("so this will not fix itself. The local copy stays visible in")
                lines.append("Calendar.app and in `events` while the server does not have it.")
            } else {
                lines.append("No error was recorded, so it may still be in flight — but a")
                lines.append("healthy write on this machine syncs in about 4 seconds.")
            }
            lines.append("")
            lines.append("Check with:  apple calendar unsynced")
            lines.append("Skip this wait with --no-confirm-sync.")
            throw ValidationError(lines.joined(separator: "\n"))
        }
    }
}

// MARK: - resync

/// Rebuilds an event the server never accepted.
///
/// 🛑 **EventKit stops retrying an item once it records an `Error` row.** The
/// item then sits in the local store forever — visible in Calendar.app, returned
/// by `events` — while the server does not have it. Nothing local un-sticks it:
/// re-saving the same item does not re-push it.
///
/// ⚠️ **The one route that worked was rebuilding.** In the incident on
/// 2026-08-18 the local copy had to be deleted and the event written again from
/// scratch. This does that through EventKit rather than by hand.
///
/// ⚠️ **This is the one part of the sync work that could not be tested against a
/// real failure.** 123 probe writes across two sessions produced no 403, so the
/// mechanism below is verified end to end on healthy events only. Whether a
/// fresh item escapes a poisoned account is untested, and the command says so.
struct Resync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resync",
        abstract: "Rebuild an event the server never accepted",
        discussion: """
          Copies the event, writes the copy, waits for the server to take it,
          and then deletes the original.

          🛑 The new event gets a NEW identifier. Anything holding the old one
          must be updated.

          ⚠️ Order matters and is deliberate: the copy is created BEFORE the
          original is deleted, so a failure leaves two events rather than none.
          Two are recoverable by hand; zero are not.

          Refused, because each would do damage a rebuild cannot undo:
            - an event with invitees      rebuilding re-sends every invitation
            - a recurring event           the rule and its exceptions cannot be
                                          rebuilt faithfully
            - an event already synced     there is nothing to repair
          Pass --force to override the first and third. Recurring is never
          allowed.
          """)

    @Argument(help: "Event identifier, from `events --json` or `unsynced`")
    var id: String

    @Flag(name: .long, help: "Show the plan without writing anything")
    var dryRun = false

    @Flag(name: .long, help: "Rebuild even if the event is synced or has invitees")
    var force = false

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @OptionGroup var sync: SyncConfirmationOptions

    struct Result: Encodable {
        let rebuilt: Bool
        let oldId: String
        let newId: String?
        let title: String
        let calendar: String
        let syncState: String?

        enum CodingKeys: String, CodingKey {
            case rebuilt, title, calendar
            case oldId = "old_id"
            case newId = "new_id"
            case syncState = "sync_state"
        }
    }

    func run() throws {
        try requireCalendarAccess()
        let original = try event(withId: id)
        guard let calendar = original.calendar else {
            throw ValidationError("that event has no calendar")
        }
        let title = original.title ?? "<untitled>"

        // 🛑 A series carries a recurrence rule plus detached exceptions, and
        // rebuilding it would silently drop every exception — the same damage
        // `edit --series` refuses to do. Never allowed, not even with --force.
        if original.hasRecurrenceRules {
            throw ValidationError("""
                '\(title)' is a recurring event, and a rebuild cannot carry its \
                exceptions across.
                Rebuilding would collapse every moved or edited occurrence back \
                onto the rule.
                Fix a recurring series in Calendar.app.
                """)
        }

        // ⚠️ Rebuilding mails every invitee a fresh invitation, and there is no
        // undo. Refuse rather than surprise anyone.
        if let guests = Attendees.list(original), !guests.isEmpty, !force {
            throw ValidationError("""
                '\(title)' has \(guests.count) invitee\(guests.count == 1 ? "" : "s"), \
                and a rebuild sends each of them a NEW invitation.
                Pass --force if that is what you want.
                """)
        }

        let before = SyncStore.status(
            eventIdentifier: original.eventIdentifier ?? id,
            calendarIdentifier: calendar.calendarIdentifier)

        if before.state == .synced && !force {
            throw ValidationError("""
                '\(title)' already reached the server, so there is nothing to \
                repair.
                Pass --force to rebuild it anyway.
                """)
        }

        if dryRun {
            let plan = """
                Would rebuild '\(title)' on \(calendar.title).
                  current sync state: \(before.state.rawValue)
                  1. create a copy carrying every field, including the map pin
                  2. wait up to \(Int(sync.syncTimeout))s for the server to take it
                  3. delete the original
                Nothing was written. The new event would get a NEW identifier.
                """
            if json {
                printJSON(Result(rebuilt: false, oldId: id, newId: nil,
                                 title: title, calendar: calendar.title,
                                 syncState: before.state.rawValue))
            } else {
                print(plan)
            }
            return
        }

        // 🛑 **Create BEFORE deleting.** If the create fails we still have the
        // original; if the delete fails we have two copies. The stuck original
        // is not on the server, so the copy cannot duplicate anything there.
        // Same rule `apple contacts move` follows: two are recoverable, zero
        // are not.
        let copy = EKEvent(eventStore: store)
        copy.calendar = calendar
        copy.title = original.title
        copy.startDate = original.startDate
        copy.endDate = original.endDate
        copy.isAllDay = original.isAllDay
        copy.notes = original.notes
        copy.url = original.url
        copy.timeZone = original.timeZone
        copy.availability = original.availability
        // ⚠️ Carry the STRUCTURED location, not just the text. Only the
        // structured one holds the coordinate, and re-resolving it would mean
        // another network call that could land on a different branch.
        //
        // 🛑 **Build a NEW EKStructuredLocation; do not assign the original's.**
        // A structured location belongs to one event, and handing the same
        // object to a second one makes the save fail with "Object not found. It
        // may have been deleted." Measured on a real event carrying a map pin:
        // the copy was never created, and only the fact that the original
        // survived kept it from being a data-losing bug.
        if let structured = original.structuredLocation {
            let fresh = EKStructuredLocation(title: structured.title ?? "")
            fresh.geoLocation = structured.geoLocation
            fresh.radius = structured.radius
            copy.structuredLocation = fresh
        } else {
            copy.location = original.location
        }

        // Taken before the save: the stuck original's own error row is
        // already in this table, and it is not evidence about the copy.
        let errorsBefore = SyncConfirmation.errorSnapshot()

        try store.save(copy, span: .thisEvent, commit: true)

        let after = try SyncConfirmation.check(event: copy, options: sync,
                                               since: errorsBefore)

        // Only now is the original safe to remove.
        do {
            try store.remove(original, span: .thisEvent, commit: true)
        } catch {
            throw ValidationError("""
                the rebuilt copy is on the server, but the stuck original could \
                not be deleted:
                  \(error.localizedDescription)
                There are now TWO copies of '\(title)'. Delete the old one in \
                Calendar.app.
                  old id: \(id)
                  new id: \(copy.eventIdentifier ?? "?")
                """)
        }

        if json {
            printJSON(Result(rebuilt: true, oldId: id,
                             newId: copy.eventIdentifier, title: title,
                             calendar: calendar.title,
                             syncState: after?.state.rawValue))
        } else {
            print("Rebuilt '\(title)' on \(calendar.title).")
            print("  old id: \(id)")
            print("  new id: \(copy.eventIdentifier ?? "?")")
            if let state = after?.state { print("  sync:   \(state.rawValue)") }
        }
    }
}
