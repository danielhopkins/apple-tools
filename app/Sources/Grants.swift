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

    private let events = EKEventStore()
    private let contacts = CNContactStore()

    /// Ask for whatever is still undetermined, then report all three.
    func requestAndRead() {
        Task {
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await events.requestFullAccessToEvents()
            }
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try? await events.requestFullAccessToReminders()
            }
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                _ = try? await contacts.requestAccess(for: .contacts)
            }
            await MainActor.run { self.read() }
        }
    }

    func read() {
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

    /// ⚠️ `writeOnly` is the trap: "Add Only" looks granted and cannot read a
    /// single event, and macOS will not offer to upgrade it. Only a manual
    /// toggle fixes it.
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

    static func openPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings."
                      + "PrivacySecurity.extension?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
