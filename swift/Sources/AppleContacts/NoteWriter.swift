import ContactsLibrary  // DeathDate.marker
import CoreServices  // AEDeterminePermissionToAutomateTarget, for `status`
import Foundation

/// Writing a contact note, the one way macOS allows it.
///
/// 🛑 **Every in-process route is walled off by the same entitlement, and the
/// legacy AddressBook framework is NOT an exception.** `CNContactNoteKey` has
/// needed `com.apple.developer.contacts.notes` since 10.15, which Apple grants
/// only to signed apps by request. The obvious escape — `ABPerson` +
/// `kABNoteProperty`, the framework `editViaAddressBook` already uses to get
/// past the note wall — was measured on 683 real contacts and read **zero**
/// notes, raising `NSCocoaErrorDomain 134092` on every one. `ABPerson` is now a
/// shim over the same Core Data store, so it hits the same wall. A direct write
/// to `AddressBook-v22.abcddb` would desynchronise Core Data's change tracking
/// and CloudKit's sync state, so that is not a route either.
///
/// Contacts.app holds the entitlement, and AppleScript is not subject to it. So
/// the note goes through Contacts.app, and only the note does — every other
/// field still takes the Contacts-framework path.
///
/// ⚠️ **This launches Contacts.app**, the same trade `apple notes delete` makes.
/// Reads never do: they come off the AddressBook SQLite store via `NoteStore`.
enum NoteWriter {
    private static let bundleID = "com.apple.AddressBook"
    static let settingsPath = "System Settings → Privacy & Security → Automation"

    /// What a command asked to do to the note's text.
    enum Change: Equatable {
        case set(String)
        case append(String)
        case clear

        var mode: String {
            switch self {
            case .set: return "set"
            case .append: return "append"
            case .clear: return "clear"
            }
        }

        var text: String {
            switch self {
            case .set(let text), .append(let text): return text
            case .clear: return ""
            }
        }
    }

    /// One note write: an optional text change, and whether to leave the death
    /// marker on the card afterwards.
    ///
    /// 🛑 **Both halves travel in ONE osascript call.** Marking is
    /// read-modify-write — the marker must not stack when it is already there —
    /// and splitting it into a second launch would both double the cost (0.87s
    /// each) and open a window where another writer could change the note in
    /// between. The AppleScript does the whole thing against the live note.
    struct Request: Equatable {
        var change: Change?
        var markDeceased: Bool = false

        /// The note the contact should hold afterwards, given what it holds now.
        ///
        /// Kept in Swift rather than only in the AppleScript so the confirmation
        /// has something to compare against, and so the ordering rules are
        /// testable without writing a contact.
        ///
        /// ⚠️ **The text change lands first, then the marker.** `--died` with
        /// `--note` means "this is the new note, and the person died", so the
        /// marker has to survive the replacement.
        func applied(to existing: String?) -> String {
            var current = existing ?? ""
            switch change {
            case .set(let text): current = text
            case .clear: current = ""
            case .append(let text):
                current = current.isEmpty ? text : current + "\n" + text
            case nil: break
            }
            if markDeceased, let marked = DeathDate.noteWithMarker(current) {
                current = marked
            }
            return current
        }
    }

    /// 🛑 **The text is passed as an argument, never interpolated.** The escaping
    /// this replaces had to double backslashes and quotes, and still had no
    /// answer for a newline: an AppleScript string literal cannot contain a raw
    /// one, and **11 of the 52 notes on a real store are multi-line**. `on run
    /// argv` sidesteps all of it — a note carrying quotes, backslashes, tabs,
    /// emoji and a dagger round-tripped byte-identical.
    private static let script = """
        on run argv
          set theID to item 1 of argv
          set theMode to item 2 of argv
          set theText to item 3 of argv
          set doMark to item 4 of argv
          set theMarker to item 5 of argv
          set theDagger to item 6 of argv
          tell application "Contacts"
            set thePerson to first person whose id is theID
            set current to note of thePerson
            if current is missing value then set current to ""
            if theMode is "set" then
              set current to theText
            else if theMode is "clear" then
              set current to ""
            else if theMode is "append" then
              if current is "" then
                set current to theText
              else
                set current to current & linefeed & theText
              end if
            end if
            if doMark is "yes" and current does not contain theDagger then
              if current is "" then
                set current to theMarker
              else
                set current to theMarker & linefeed & linefeed & current
              end if
            end if
            set note of thePerson to current
            save
            set written to note of thePerson
            if written is missing value then return ""
            return written
          end tell
        end run
        """

    /// Apply `change` to the contact with this AddressBook id, and return the
    /// note Contacts.app holds afterwards.
    ///
    /// ⚠️ **Pass the CONTAINER-BACKED id**, not a unified one — the same rule
    /// `editViaAddressBook` follows. AppleScript addresses the AddressBook
    /// record, and a unified identifier may name no record at all.
    static func apply(_ request: Request, toContactId id: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // "none" leaves the text alone, which is what `--died` on its own wants.
        process.arguments = [
            "-e", script, id,
            request.change?.mode ?? "none",
            request.change?.text ?? "",
            request.markDeceased ? "yes" : "no",
            DeathDate.marker,
            DeathDate.daggerScalar,
        ]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw RuntimeError("could not run osascript to write the note: \(error.localizedDescription)")
        }

        // Read before waiting: a note large enough to fill the pipe buffer would
        // otherwise deadlock, and the longest note on a real store is 514 bytes
        // with nothing capping it.
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RuntimeError(explain(detail, id: id))
        }

        // osascript appends a newline of its own to the returned text. Only that
        // one is dropped, so a note whose own last character is a newline keeps
        // every other one.
        var written = String(data: stdoutData, encoding: .utf8) ?? ""
        if written.hasSuffix("\n") { written.removeLast() }
        return written
    }

    /// Turn osascript's error text into something the caller can act on.
    private static func explain(_ detail: String, id: String) -> String {
        if detail.contains("-1743") || detail.lowercased().contains("not authorized") {
            return """
                Contacts.app refused the note write: this terminal does not have \
                Automation → Contacts. Writing a note is the one thing that needs it; \
                every other field, and every read, does not.
                Grant it in \(settingsPath), then try again.
                """
        }
        if detail.contains("-1728") || detail.lowercased().contains("can't get") {
            return """
                Contacts.app has no record with id '\(id)'. Note writes address the \
                AddressBook record directly, so a unified identifier will not resolve. \
                Get the id from `apple-contacts search --json`.
                """
        }
        return "Contacts.app refused the note write: \(detail.isEmpty ? "no error reported" : detail)"
    }

    /// Ask TCC whether we may automate Contacts, without prompting.
    ///
    /// `nil` means it did not answer in time. Bounded because `apple-mail`
    /// measured this same call blocking for **502 seconds** against an app that
    /// was not servicing Apple Events — `askUserIfNeeded: false` stops it
    /// prompting, not blocking. Contacts.app has never been seen to wedge that
    /// way, but a status command must not be the place that finds out.
    static func automationPermission(timeout: TimeInterval = 3) -> OSStatus? {
        final class Box: @unchecked Sendable { var value: OSStatus = noErr }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var target = AEAddressDesc()
            let created = bundleID.withCString { pointer in
                AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
            }
            var code = OSStatus(created)
            if created == noErr {
                code = AEDeterminePermissionToAutomateTarget(
                    &target, typeWildCard, typeWildCard, false)
                AEDisposeDesc(&target)
            }
            box.value = code
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    /// `(name, usable, advice)` for the Automation grant, for `status`.
    static func automationState() -> (String, Bool, String?) {
        switch automationPermission() {
        case nil:
            return ("unknown", false,
                    "The Automation permission check did not answer. Notes cannot be written "
                    + "until Contacts.app is restarted.")
        case noErr:
            return ("authorized", true, nil)
        case OSStatus(errAEEventNotPermitted):
            return ("denied", false, "Re-enable Contacts under \(settingsPath).")
        case OSStatus(errAEEventWouldRequireUserConsent):
            return ("notDetermined", false,
                    "Write a note from a terminal to trigger the prompt.")
        case OSStatus(procNotFound):
            // Automation state cannot be read while the target is not running.
            // This says nothing about whether the grant exists, and a note write
            // launches Contacts.app anyway.
            return ("contactsNotRunning", false,
                    "Contacts.app is not running. A note write launches it; check again after.")
        case let code:
            return ("unknown(\(code.map(String.init) ?? "?"))", false, nil)
        }
    }
}
