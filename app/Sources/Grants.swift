// The three grants the app CAN ask for.
//
// 🛑 Full Disk Access is not one of them. There is no API that requests it: no
// prompt, no `requestAccess`, no entitlement. The user adds the app in System
// Settings by hand and macOS relaunches it. Calendar, Reminders and Contacts
// are different — each framework can prompt, and the app is the right thing to
// prompt for, because it is the responsible process for every tool it spawns.
//
// ⚠️ macOS ONLY PROMPTS WHEN THE STATE IS `notDetermined`. Once it is anything
// else the request returns silently and no dialog ever appears. So a `denied`
// state is never fixed by asking again — only by the user toggling the switch.
// The window says which of the two it is.
//
// 🛑 LAUNCHING THE APP BINARY FROM A TERMINAL MEASURES THE TERMINAL. The
// responsible process for `AppleTools.app/Contents/MacOS/AppleTools` typed into
// a shell is the shell, so the app borrows the terminal's grants and every
// source appears to work. Measured here: one cycle reported no errors that way
// and the same build reported two failures when launched with `open`. Always
// launch it with `open`, or from Finder.
//
// 🛑 ONE TCC DIALOG AT A TIME, AND IT WAITS FOR A PERSON. A request does not
// return until the user answers, so these are chained: each one starts only
// when the one before it finishes. Asking for the next while a dialog is up
// gets the next one **denied** — measured, `Access Denied` from Contacts with
// the reminders dialog still on screen, and TCC recorded that denial.
//
// ⚠️ THE DIALOG IS EASY TO MISS, AND EASY TO MISDIAGNOSE. It belongs to
// `UserNotificationCenter`, which is a BACKGROUND process, so a check of
// "visible processes" does not list it and the prompt looks absent. It cost a
// wrong conclusion here — that an unnotarized app cannot get a prompt at all —
// and a round trip through Apple's notary service to disprove. To see whether
// one is up:
//
//     osascript -e 'tell application "System Events" to tell process \
//       "UserNotificationCenter" to get value of every static text of window 1'
//
import AppKit
import Contacts
import EventKit
import Foundation

@MainActor
final class Grants: ObservableObject {
    enum State: String {
        case granted, denied, notDetermined, restricted, writeOnly, unknown
    }

    struct Entry: Identifiable, Equatable {
        var id: String { name }
        let name: String
        var state: State
        /// The System Settings pane, for the states asking again cannot fix.
        let pane: String
        var settled: Bool { state == .granted }
    }

    @Published private(set) var entries: [Entry] = []

    // 🛑 `nonisolated`, because the request must NOT run on the main actor.
    // Measured: with the request on the main actor, a 20s deadline task raced
    // against it NEVER RAN — EventKit's reminders request occupies the actor
    // without suspending, so the timer beside it never got scheduled and the
    // "deadline" was no deadline at all.
    // ⚠️ A FRESH STORE PER REQUEST. Apple's guidance is that a store must be
    // created after the previous request settles, and a reused one is a
    // documented source of a request that answers without prompting.
    private nonisolated func newEventStore() -> EKEventStore { EKEventStore() }
    private nonisolated func newContactStore() -> CNContactStore { CNContactStore() }

    /// What each request actually returned, so "it did not prompt" stays a
    /// measurement rather than a guess.
    @Published private(set) var attempts: [String: String] = [:]

    /// Ask for whatever is still undetermined, then report all three.
    ///
    /// 🛑 COMPLETION HANDLERS AND A PLAIN TIMER, not async/await and not a task
    /// group. Two versions raced the request against `Task.sleep` and the sleep
    /// NEVER FIRED, on the main actor and off it alike: the reminders request
    /// occupies a cooperative thread without suspending, and the timer beside
    /// it was never scheduled. A `DispatchQueue.main.asyncAfter` does not care.
    func requestAndRead(force: Bool = false) {
        read()
        loadAttempts()
        // 🛑 ASK ONCE, NOT ON EVERY LAUNCH. Each unanswered request costs its
        // full deadline, and the app is frontmost with a Dock tile for the
        // whole of it — three of them is a minute of stolen focus at every
        // login, for prompts that never appear. If a grant is still open the
        // window offers a button; a person pressing it is a different thing
        // from the app deciding to interrupt.
        let open = entries.filter { !$0.settled }
        guard force || open.contains(where: { attempts[$0.name] == nil }) else { return }
        // 🛑 BECOME A REAL APP FOR THE LENGTH OF THE ASK. This is LSUIElement,
        // so it runs as an accessory: never frontmost, no Dock tile, no window.
        // ⚠️ It did not help here, and it stays because it is still correct: a
        // prompt belongs to a process the user can see. What it did not fix is
        // below, under `attempts`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // ⚠️ NOT during `applicationDidFinishLaunching`. A request made in the
        // same turn of the run loop as the launch is refused: measured, the
        // FIRST request the process makes returns false with no error and no
        // dialog, and leaves the status `notDetermined`.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) {
            [weak self] in self?.askContacts()
        }
    }

    /// How long to let the app settle before asking for anything.
    private nonisolated static let settleDelay: TimeInterval = 5

    private func askCalendar() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            attempts["calendar"] = "skipped: already decided"
            return askReminders()
        }
        begin("calendar") { [weak self] in self?.askReminders() }
        newEventStore().requestFullAccessToEvents { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.finish("calendar", granted: granted, error: error)
            }
        }
    }

    private func askReminders() {
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else {
            attempts["reminders"] = "skipped: already decided"
            return done()
        }
        begin("reminders") { [weak self] in self?.done() }
        newEventStore().requestFullAccessToReminders { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.finish("reminders", granted: granted, error: error)
            }
        }
    }

    private func askContacts() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else {
            attempts["contacts"] = "skipped: already decided"
            return askCalendar()
        }
        begin("contacts") { [weak self] in self?.askCalendar() }
        newContactStore().requestAccess(for: .contacts) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.finish("contacts", granted: granted, error: error)
            }
        }
    }

    private func done() {
        read()
        // Back to an accessory. A background indexer with a Dock tile is noise,
        // which is why LSUIElement is set in the first place.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Mark a request in flight and arm its deadline.
    ///
    /// ⚠️ A request that never returns leaves no record otherwise, and a
    /// missing key reads as "not tried" rather than "still waiting". Measured
    /// on macOS 27.0 with an unnotarized Developer ID app:
    /// `requestFullAccessToReminders` never came back, and the app sat in
    /// `TCCAccessRequest() IPC` **every two seconds for as long as it ran**.
    ///
    /// 🛑 Losing the race does not cancel the request. Nothing can: there is no
    /// cancel API. The deadline abandons the WAIT so the next grant is still
    /// asked for, and the retry keeps running inside EventKit until the process
    /// exits.
    private func begin(_ name: String, next: @escaping () -> Void) {
        attempts[name] = asking
        write()
        continuations[name] = next
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestDeadline) {
            [weak self] in
            guard let self, self.attempts[name] == self.asking else { return }
            self.attempts[name] = "no answer in \(Int(Self.requestDeadline / 60)) min"
            self.write()
            self.advance(name)
        }
    }

    private func finish(_ name: String, granted: Bool, error: Error?) {
        guard attempts[name] == asking else { return }   // the deadline won
        // ⚠️ Record the RAW status and the full error. `localizedDescription`
        // alone said "Access Denied" for a request the user was never shown,
        // which reads as a decision they made.
        let raw: String
        switch name {
        case "calendar": raw = "\(EKEventStore.authorizationStatus(for: .event).rawValue)"
        case "reminders": raw = "\(EKEventStore.authorizationStatus(for: .reminder).rawValue)"
        default: raw = "\(CNContactStore.authorizationStatus(for: .contacts).rawValue)"
        }
        if let error = error as NSError? {
            attempts[name] = "\(error.domain) \(error.code): "
                + "\(error.localizedDescription) [status \(raw)]"
        } else {
            attempts[name] = (granted ? "granted" : "refused") + " [status \(raw)]"
        }
        read()
        advance(name)
    }

    /// ⚠️ Exactly once per request, whichever of the two arrives first.
    private func advance(_ name: String) {
        guard let next = continuations.removeValue(forKey: name) else { return }
        next()
    }

    /// Shown in the window while a dialog is on screen. ⚠️ It must not read as
    /// "working": the app is waiting for a person, and the dialog can be behind
    /// another window or on a second display.
    let asking = "waiting for your answer to the macOS dialog"
    private var continuations: [String: () -> Void] = [:]

    func read() {
        defer { write() }
        entries = [
            Entry(name: "calendar",
                  state: Self.map(EKEventStore.authorizationStatus(for: .event)),
                  pane: "Privacy_Calendars"),
            Entry(name: "reminders",
                  state: Self.map(EKEventStore.authorizationStatus(for: .reminder)),
                  pane: "Privacy_Reminders"),
            Entry(name: "contacts",
                  state: Self.map(CNContactStore.authorizationStatus(for: .contacts)),
                  pane: "Privacy_Contacts"),
        ]
    }

    /// 🛑 THIS IS A PERSON'S DEADLINE, NOT A MACHINE'S. The request does not
    /// return until the user answers the dialog, and they may be away from the
    /// Mac. A 20s deadline was WRONG and caused the failure it was written to
    /// diagnose: the app moved on while the reminders dialog was still on
    /// screen, and the contacts request behind it came back `Access Denied`
    /// because macOS shows ONE TCC dialog at a time.
    ///
    /// ⚠️ It exists only so a request that will never be answered cannot hold
    /// the chain for the life of the process. Ten minutes, not twenty seconds.
    private nonisolated static let requestDeadline: TimeInterval = 600

    /// ⚠️ `writeOnly` is the trap: "Add Only" looks granted and cannot read a
    /// single event, and macOS will not offer to upgrade it. Only a manual
    /// toggle fixes it, so it must never be reported as granted.
    private static func map(_ status: EKAuthorizationStatus) -> State {
        switch status {
        case .fullAccess: return .granted
        case .authorized: return .granted
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func map(_ status: CNAuthorizationStatus) -> State {
        switch status {
        case .authorized: return .granted
        case .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// What the last run recorded, so a second launch does not ask again.
    private func loadAttempts() {
        guard attempts.isEmpty,
              let data = try? Data(contentsOf: attemptsPath),
              let parsed = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let last = parsed["last_request"] as? [String: String]
        else { return }
        // ⚠️ "asking…" means the last run was killed mid-request. That is not
        // an answer, so it must not count as one.
        attempts = last.filter { $0.value != asking }
    }

    private var attemptsPath: URL {
        Paths.supportDirectory.appendingPathComponent("app-grants.json")
    }

    /// 🛑 The app writes this down because a terminal cannot ask the question.
    /// `authorizationStatus` is answered for the RESPONSIBLE process, so any
    /// probe run from a shell reports the shell's grants, never the app's.
    func write() {
        let body: [String: Any] = [
            "checked": ISO8601DateFormatter().string(from: Date()),
            "state": entries.reduce(into: [String: String]()) {
                $0[$1.name] = $1.state.rawValue },
            "last_request": attempts,
        ]
        let path = attemptsPath
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: path.path)
    }

    static func openPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings."
                      + "PrivacySecurity.extension?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
