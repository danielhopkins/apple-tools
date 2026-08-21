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
            let outlook = failure.retryable
                ? "retryable — EventKit may still land this one"
                : "terminal — the server will answer the same way again"
            print("  \(outlook)")
        }
        print("")
        // 🛑 This line used to read "EventKit stops retrying an item once it
        // records one", flatly. Measured false: of 16 items that recorded an
        // HTTP 403 in one burst, 16 synced and EventKit cleared 15 of the rows.
        // A row here is a report, not a verdict.
        let stuck = failures.filter { !$0.retryable }.count
        print("\(failures.count) error\(failures.count == 1 ? "" : "s"), "
              + "\(stuck) terminal. A retryable row often clears itself;")
        print("run `apple calendar unsynced` to see what is actually still missing.")
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

    /// 🛑 **The deadline extends itself once the server says it is throttling.**
    /// 30s is right for a healthy write and hopeless for a throttled one, and
    /// picking one number for both was the whole problem. Measured on a Google
    /// calendar, three bursts on 2026-08-21:
    ///
    /// | burst | recorded a 403 | median sync | over 30s |
    /// |---|---|---|---|
    /// | 20 adds, no edits | 0 | 19s | 5 of 20 |
    /// | 30 add+edit pairs | **16** | **156s** | 19 of 30 |
    /// | 30 add+edit pairs, repeat | 0 | 30s | 11 of 30 |
    ///
    /// So the tool waits 30s by default, and stretches to this only once it has
    /// evidence a wait will help. A caller who sets `--sync-timeout` higher
    /// keeps their number; this never shortens a deadline.
    @Option(name: .long,
            help: "Seconds to keep waiting once the server reports throttling (default: 180)")
    var throttleTimeout: Double = 180
}

/// A failure that is not the caller's fault, so it must not print a usage block.
struct CalendarRuntimeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum SyncConfirmation {

    /// Polls until the server takes the event, refuses it, or the deadline passes.
    ///
    /// ⚠️ **30 seconds is generous for ONE write, and not for a burst.** Six
    /// timed trials on this machine put create-to-`external_id` at **4 seconds
    /// every time**, with and without a manual `reload calendars`. A single
    /// write by hand still syncs in 6.
    ///
    /// 🛑 **Under load that number moves a long way, and an earlier version of
    /// this comment claimed otherwise.** The live suite writes ~70 events to one
    /// Exchange calendar in a burst, and the server throttles:
    ///
    /// | run | timed out at 30s |
    /// |---|---|
    /// | 71 tests in 322s | 3 |
    /// | 71 tests in 928s | **26** |
    ///
    /// Every one of those was a healthy write the server had not yet confirmed.
    /// So "still pending at 30s" means *this caller could not confirm it*, never
    /// *the write failed*. The test harness raises its own deadline for that
    /// reason; the default here stays at 30, because a person writing one event
    /// should not wait two minutes to be told something went wrong.
    ///
    /// ⚠️ **`reload calendars` does not help.** It exits 0, does not need
    /// Calendar.app running, does not wipe pending writes — and does not speed
    /// anything up. Measured across the same six trials. So nothing here calls
    /// it.
    static func wait(event: EKEvent, timeout: Double, throttleTimeout: Double = 180,
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

        let start = Date()
        var deadline = start.addingTimeInterval(max(0, timeout))
        var announcedThrottle = false
        var status = look()

        while status.state == .pending && Date() < deadline {
            // 🛑 **Only an error recorded AFTER the save can stop the wait.**
            // A fresh create has no `external_id` at t=0, so the first look is
            // always `pending`; giving up there on any error at all meant one
            // stale row on the calendar failed every write that followed it.
            // With no snapshot the store was unreadable, so nothing is known
            // to be old — poll to the deadline instead of guessing.
            let fresh = snapshot.map { snap in status.errors.filter(snap.isNew) }
                ?? []

            // 🛑 **A retryable error is not a reason to stop waiting.** Breaking
            // here on any error at all is what turned a Google rate limit into
            // "the server REFUSED it", on 16 of 30 writes that then synced. See
            // `Failure.retryable` for the measurement.
            if !fresh.isEmpty && fresh.contains(where: { !$0.retryable }) { break }

            if !fresh.isEmpty && !announcedThrottle {
                announcedThrottle = true
                // The deadline only ever grows. A caller who asked for longer
                // than the throttle budget keeps their own number.
                let budget = max(timeout, throttleTimeout)
                deadline = max(deadline, start.addingTimeInterval(budget))
                let note = SyncStore.Message.throttling(
                    status: fresh.first?.httpStatus, waitingUpTo: Int(budget))
                FileHandle.standardError.write(Data((note + "\n\n").utf8))
            }

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
                          throttleTimeout: options.throttleTimeout,
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
            // 🛑 **"Refused" and "not confirmed yet" are different answers, and
            // reporting both as failure was wrong.**
            //
            // The confirmation exists for the write a server REFUSES — Google
            // answering HTTP 403, EventKit recording an `Error` row and never
            // retrying. That case is real, unrecoverable, and still fails here.
            //
            // A write the server has simply not confirmed in time is not that.
            // Measured on this machine: two full suite runs a day apart, both at
            // a 120s deadline, each left 7 of 71 writes unconfirmed — and
            // `unsynced` reported "Everything has reached its server" straight
            // afterwards, every time. The account rate-limits sustained writes;
            // the writes land.
            //
            // ⚠️ It is not a test-only condition. One `edit` on the Family
            // calendar hit it during ordinary use, printed a failure, and the
            // title had already changed on the server.
            let newErrors = snapshot.map { snap in status.errors.filter(snap.isNew) }
                ?? status.errors

            // 🛑 **Only a TERMINAL error is a refusal.** Every new error being
            // retryable means the server is throttling, and EventKit is still
            // trying — measured, 16 of 16 such writes landed. Calling that
            // "REFUSED" and exiting 1 was wrong about a write that succeeded
            // two minutes later. See `Failure.retryable`.
            let terminal = newErrors.filter { !$0.retryable }
            guard terminal.isEmpty else {
                return try refused(status, errors: terminal)
            }

            let waited = Int(newErrors.isEmpty
                             ? options.syncTimeout
                             : max(options.syncTimeout, options.throttleTimeout))
            let note = SyncStore.Message.unconfirmed(
                afterSeconds: waited,
                httpStatus: newErrors.compactMap(\.httpStatus).first)
            FileHandle.standardError.write(Data((note + "\n\n").utf8))
            return status
        }
    }

    /// The exit code for a write whose confirmation did not complete.
    ///
    /// 🛑 **Call this AFTER printing the event, never before.** The old code
    /// threw from `check`, so a `--json` caller got a usage block and no event
    /// record at all — no id to look up, nothing to retry with. That is what
    /// turned a slow server into 26 test failures.
    ///
    /// ⚠️ **Exit 75, not 0 and not 64.** `EX_TEMPFAIL` is the sysexits code for
    /// exactly this: the operation was not completed, try again later. 0 would
    /// claim the server has it. 64 is `EX_USAGE` and claims the command was
    /// typed wrong, which is what ArgumentParser's `ValidationError` produced.
    static func finish(_ status: SyncStore.Status?) throws {
        guard status?.state == .pending else { return }
        throw ExitCode(75)
    }

    private static func refused(
        _ status: SyncStore.Status, errors: [SyncStore.Failure]
    ) throws -> SyncStore.Status {
            var lines = [
                "the event was saved locally and the server REFUSED it.",
                "",
            ]
            // Name only an error this write produced. A row that predates
            // the save explains nothing about it, and printing it sends the
            // reader after the wrong event.
            let blame = errors
            if let failure = blame.first {
                let http = failure.httpStatus.map { "HTTP \($0)" } ?? "no HTTP status"
                lines.append("  \(http) \(failure.domain ?? "") (scope: \(failure.scope))")
                lines.append("")
                // ⚠️ Reached only for a TERMINAL status now. A retryable one —
                // 403, 429, 5xx — waits instead, because EventKit does retry
                // those and the old wording claimed it never retries anything.
                lines.append("This status is one the server will give again, so the write will")
                lines.append("not fix itself. The local copy stays visible in Calendar.app and")
                lines.append("in `events` while the server does not have it.")
                lines.append("")
                lines.append("Rebuild it with:  apple calendar resync <id>")
            } else {
                lines.append("No error was recorded, so it may still be in flight — but a")
                lines.append("healthy write on this machine syncs in about 4 seconds.")
            }
            lines.append("")
            lines.append("Check with:  apple calendar unsynced")
            lines.append("Skip this wait with --no-confirm-sync.")
            // ⚠️ Not a ValidationError. Nothing was typed wrong, and a usage
            // block under a server refusal sends the reader after the wrong
            // thing entirely.
            throw CalendarRuntimeError(lines.joined(separator: "\n"))
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

        // 🛑 **`resync` is the one command where "unconfirmed" must still stop.**
        // Everywhere else the write is benign and the event is on the calendar
        // either way. Here the next step DELETES the original, so proceeding on
        // an unconfirmed copy risks leaving the user with neither a working
        // event nor the stuck one they started with. Two copies are recoverable
        // in Calendar.app; zero are not.
        if after?.state == .pending {
            throw CalendarRuntimeError("""
                the rebuilt copy is not confirmed on the server, so the stuck \
                original was NOT deleted.
                Nothing was lost. There are two copies of '\(title)' right now:
                  original: \(id)
                  rebuilt:  \(copy.eventIdentifier ?? "?")
                Check with `apple calendar sync-status`, then delete whichever \
                one the server does not have.
                """)
        }

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
