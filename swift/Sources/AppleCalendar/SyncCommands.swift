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
                     against baseline: SyncStore.Baseline? = nil) -> SyncStore.Status {
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
        while status.state == .pending && status.errors.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            status = look()
        }
        return status
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
                      against baseline: SyncStore.Baseline? = nil) throws
        -> SyncStore.Status?
    {
        guard options.confirmSync else { return nil }

        let status = wait(event: event, timeout: options.syncTimeout, against: baseline)

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
            if let failure = status.errors.first {
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
