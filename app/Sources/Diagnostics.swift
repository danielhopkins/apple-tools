// Permission state, and the one measurement the whole design rests on.
//
// 🛑 STEP 0. Everything the app does with a schedule rests on one claim:
//
//     A child process spawned by the app inherits the app's TCC identity, so
//     one Full Disk Access grant on the app covers apple-mail, apple-notes,
//     apple-messages, apple-phone and apple-maps when the app runs them.
//
// That is how TCC is documented to work, and it had not been measured here.
// This file measures it, on every launch, and the status window shows the
// answer. The probe is exact: the app reads a protected directory ITSELF, then
// asks a CHILD to do the same work through `apple status --json`. If the app
// can read it and the child cannot, inheritance is false and the schedule is
// worthless.
//
// ⚠️ A probe run from a terminal proves nothing, because the terminal carries
// its own Full Disk Access. This one runs inside the app, which is the point.

import AppKit
import Foundation

struct ToolPermission: Identifiable, Equatable {
    var id: String { tool }
    let tool: String
    var status = ""
    var usable = false
    var grantedTo = ""
    var pane = ""
    var advice: String? = nil
}

struct Diagnosis: Equatable {
    /// Can the APP itself read a protected store?
    var appHasFullDiskAccess = false
    /// Can a CHILD of the app read one?
    var childHasFullDiskAccess = false
    var tools: [ToolPermission] = []
    var checked: Date? = nil
    var error: String? = nil

    /// The Step 0 answer, in three states rather than two.
    enum Inheritance: String {
        case yes = "children inherit the app's grant"
        case no = "children do NOT inherit the app's grant"
        case unknown = "not measurable until the app has Full Disk Access"
    }

    var inheritance: Inheritance {
        guard appHasFullDiskAccess else { return .unknown }
        return childHasFullDiskAccess ? .yes : .no
    }

    /// Which tools the index can actually read right now.
    var blocked: [ToolPermission] { tools.filter { !$0.usable } }
}

@MainActor
final class Diagnostics: ObservableObject {
    @Published private(set) var latest = Diagnosis()
    @Published private(set) var busy = false

    /// 🛑 A DIRECTORY LISTING, NOT A TCC QUERY. No API reports Full Disk
    /// Access: there is no prompt, no `requestAccess` and no entitlement.
    /// Reading a protected directory is the only honest probe.
    ///
    /// ⚠️ An absent `~/Library/Mail` is not a denial. It is answered `true`
    /// here for the same reason `index.py` answers it true: a machine with no
    /// Mail must not look like a machine with a revoked grant.
    nonisolated static func canReadProtectedStore() -> Bool {
        let probe = NSString(string: "~/Library/Mail").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: probe) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }

    func check() {
        guard !busy else { return }
        busy = true
        // Read the framework grants HERE, on the main actor, and hand them to
        // the background work as a plain dictionary.
        let frameworks = AppModel.shared.grants.entries
            .reduce(into: [String: String]()) { $0[$1.name] = $1.state.rawValue }
        Task.detached(priority: .utility) {
            let result = Self.measure()
            Self.write(result, frameworks: frameworks)
            await MainActor.run {
                self.latest = result
                self.busy = false
            }
        }
    }

    nonisolated static func measure() -> Diagnosis {
        var diagnosis = Diagnosis()
        diagnosis.checked = Date()
        diagnosis.appHasFullDiskAccess = canReadProtectedStore()

        let result = Child.apple(["status", "--json"], timeout: 90)
        guard let data = result.out.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
                as? [String: [String: Any]] else {
            diagnosis.error = result.err.isEmpty
                ? "`apple status` returned nothing readable"
                : String(result.err.prefix(400))
            return diagnosis
        }

        for name in Paths.toolNames {
            guard let entry = parsed[name] else { continue }
            var permission = ToolPermission(tool: name)
            permission.status = entry["status"] as? String ?? ""
            permission.usable = entry["usable"] as? Bool ?? false
            permission.grantedTo = entry["granted_to"] as? String ?? ""
            permission.pane = entry["pane"] as? String ?? ""
            permission.advice = entry["advice"] as? String
            diagnosis.tools.append(permission)
        }

        // 🛑 The Step 0 measurement. `maps` and `messages` need nothing but
        // Full Disk Access — no Automation, no framework grant — so they are
        // the clean signal. `mail` also needs Automation for half its
        // commands, which would muddy the answer.
        let fileOnly = ["maps", "messages", "notes", "phone"]
        let answers = diagnosis.tools.filter { fileOnly.contains($0.tool) }
        diagnosis.childHasFullDiskAccess = answers.contains { $0.usable }
        return diagnosis
    }

    /// 🛑 Write it to a file, because a terminal cannot ask this question.
    /// `authorizationStatus` and every protected read are attributed to the
    /// RESPONSIBLE process, so running any probe from a shell reports the
    /// shell's grants, not the app's. The only way to see what the app sees is
    /// to have the app write it down.
    nonisolated static func write(_ diagnosis: Diagnosis,
                                  frameworks: [String: String]) {
        var body: [String: Any] = [
            "checked": ISO8601DateFormatter().string(from: diagnosis.checked ?? Date()),
            "app_full_disk_access": diagnosis.appHasFullDiskAccess,
            "child_full_disk_access": diagnosis.childHasFullDiskAccess,
            "inheritance": diagnosis.inheritance.rawValue,
            "tools": diagnosis.tools.reduce(into: [String: Any]()) { into, tool in
                into[tool.tool] = ["status": tool.status, "usable": tool.usable,
                                   "granted_to": tool.grantedTo, "pane": tool.pane]
            },
        ]
        if let failure = diagnosis.error { body["error"] = failure }
        // 🛑 Passed IN, never read here. This runs on a background thread and
        // `MainActor.assumeIsolated` off the main actor is a crash, not a
        // fallback.
        if !frameworks.isEmpty { body["frameworks"] = frameworks }
        let path = Paths.supportDirectory.appendingPathComponent("app-diagnostics.json")
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: path.path)
    }

    /// Open the pane the user has to toggle by hand. There is no API that asks.
    static func openFullDiskAccessPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings."
                      + "PrivacySecurity.extension?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
