// The plugins the window can see, enable and configure.
//
// 🛑 EVERYTHING HERE GOES THROUGH `apple plugins`, the same manager the
// command line uses. The window keeps no second copy of the list, the config
// file or the Keychain rules: it asks `apple plugins list --json` what exists,
// `apple plugins config NAME --json` what is set (secrets come back as `•••`),
// and `apple NAME status --json` whether the thing on the other end answers.
// One source of truth, and the CLI and the window cannot disagree.
//
// ⚠️ A PLUGIN THAT IS FOUND IS NOT A PLUGIN THAT RUNS. `installed` is what is
// on disk; `enabled` is what the user decided. The window draws both, and the
// button between them is the decision — the first plugin talks to a server,
// so the moment it is enabled is the moment data may leave the machine.

import Foundation

struct PluginField: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let secret: Bool
    let required: Bool
    let help: String?
}

struct PluginStatus: Equatable {
    /// `ok`, `unconfigured`, `unreachable`, `unauthorized`, or `error`.
    let status: String
    let usable: Bool
    let advice: String?
    /// The server's own version, when the plugin reads one.
    let version: String?
    let account: String?
    /// The host it actually connected to. ⚠️ The manifest can only say "the
    /// configured url"; this is the configured url, resolved.
    let hosts: [String]
}

struct PluginEntry: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let path: String?
    let installed: Bool
    let valid: Bool
    let enabled: Bool
    let version: String?
    let description: String?
    /// 🛑 The one line that says where data goes. Empty means the plugin
    /// claims it makes no connection.
    let hosts: [String]
    let indexes: [String]
    let fields: [PluginField]
    /// From the manifest, for the Sources row this plugin becomes.
    let containerLabel: String?
    let footnote: String?
    /// What `config --json` reported: a value, `•••` for a set secret, or
    /// nil for a key that is not set.
    var values: [String: String] = [:]
    var missing: [String] = []
    var status: PluginStatus? = nil

    /// Where it talks to: the real host once `status` has answered, the
    /// manifest's wording until then.
    var knownHosts: [String] {
        if let live = status?.hosts, !live.isEmpty { return live }
        return hosts
    }

    /// The one line beside the name in the Sources table.
    var note: String {
        knownHosts.isEmpty ? "plugin" : "plugin · reads " + knownHosts.joined(separator: ", ")
    }
}

@MainActor
final class Plugins: ObservableObject {
    @Published private(set) var entries: [PluginEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var failure: String? = nil
    /// Set by an enable, disable or config write, cleared by the next one.
    @Published var lastAction: String? = nil

    func entry(_ name: String) -> PluginEntry? {
        entries.first { $0.name == name }
    }

    /// Everything, in three subprocesses per plugin at most. ⚠️ `status` is a
    /// network call for a plugin that has a host, so it is asked only of an
    /// ENABLED plugin — the window must never make a connection the user has
    /// not turned on.
    func read() {
        busy = true
        Task.detached(priority: .userInitiated) {
            let listed = Child.apple(["plugins", "list", "--json"], timeout: 60)
            guard listed.ok, let data = listed.out.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data)
                    as? [[String: Any]] else {
                let error = listed.err.split(separator: "\n").last.map(String.init)
                await MainActor.run {
                    self.busy = false
                    // ⚠️ An `apple` too old to know `plugins` prints its usage
                    // and exits 1. That is "no plugins", not a failure to show.
                    self.failure = listed.err.contains("unknown tool") ? nil
                        : (error ?? "exit \(listed.status)")
                    self.entries = []
                }
                return
            }
            var built: [PluginEntry] = []
            for row in rows {
                guard let name = row["name"] as? String else { continue }
                var entry = PluginEntry(
                    name: name,
                    path: row["path"] as? String,
                    installed: row["installed"] as? Bool ?? false,
                    valid: row["valid"] as? Bool ?? false,
                    enabled: row["enabled"] as? Bool ?? false,
                    version: row["version"] as? String,
                    description: row["description"] as? String,
                    hosts: row["hosts"] as? [String] ?? [],
                    indexes: row["indexes"] as? [String] ?? [],
                    fields: (row["config"] as? [[String: Any]] ?? []).compactMap {
                        guard let key = $0["key"] as? String else { return nil }
                        return PluginField(key: key,
                                           secret: $0["secret"] as? Bool ?? false,
                                           required: $0["required"] as? Bool ?? false,
                                           help: $0["help"] as? String)
                    },
                    containerLabel: row["container_label"] as? String,
                    footnote: row["footnote"] as? String)
                entry.missing = row["missing"] as? [String] ?? []
                if entry.installed && entry.valid {
                    let config = Child.apple(["plugins", "config", name, "--json"], timeout: 60)
                    if config.ok, let data = config.out.data(using: .utf8),
                       let root = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] {
                        let values = root["config"] as? [String: Any] ?? [:]
                        for (key, value) in values {
                            if let text = value as? String { entry.values[key] = text }
                        }
                        entry.missing = root["missing"] as? [String] ?? entry.missing
                    }
                }
                if entry.enabled {
                    let probe = Child.apple([name, "status", "--json"], timeout: 45)
                    if probe.ok, let data = probe.out.data(using: .utf8),
                       let root = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] {
                        entry.status = PluginStatus(
                            status: root["status"] as? String ?? "unknown",
                            usable: root["usable"] as? Bool ?? false,
                            advice: root["advice"] as? String,
                            version: root["version"] as? String,
                            account: root["account"] as? String,
                            hosts: root["hosts"] as? [String] ?? [])
                    } else {
                        entry.status = PluginStatus(
                            status: "no answer", usable: false,
                            advice: probe.err.split(separator: "\n").last.map(String.init),
                            version: nil, account: nil, hosts: [])
                    }
                }
                built.append(entry)
            }
            let result = built
            await MainActor.run {
                self.busy = false
                self.failure = nil
                self.entries = result
            }
        }
    }

    func enable(_ name: String) {
        run(["plugins", "enable", name, "--json"]) { [weak self] root in
            let hosts = root["hosts"] as? [String] ?? []
            self?.lastAction = hosts.isEmpty
                ? "Enabled. It is read on the next indexing run."
                : "Enabled. It talks to \(hosts.joined(separator: ", ")), and it is "
                  + "read on the next indexing run."
        }
    }

    func disable(_ name: String) {
        run(["plugins", "disable", name, "--json"]) { [weak self] _ in
            // 🛑 SAY WHAT STAYS. Disabling stops the reads; the records it
            // already put in the index survive until that source is rebuilt
            // in full — the same rule a removed folder has.
            self?.lastAction = "Disabled. What it already put in the index stays "
                + "until that source is rebuilt in full."
        }
    }

    /// One key. ⚠️ The value travels as an argument to `apple plugins config`,
    /// the same way it does from a terminal; a secret lands in the Keychain
    /// and never in a file the app writes.
    func set(_ name: String, key: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            run(["plugins", "config", name, "--unset", key, "--json"]) { [weak self] _ in
                self?.lastAction = "Cleared \(key)."
            }
        } else {
            run(["plugins", "config", name, "\(key)=\(trimmed)", "--json"]) { [weak self] _ in
                self?.lastAction = "Saved \(key)."
            }
        }
    }

    private func run(_ arguments: [String],
                     _ handle: @escaping ([String: Any]) -> Void) {
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = Child.apple(arguments, timeout: 60)
            await MainActor.run {
                self.busy = false
                guard result.ok, let data = result.out.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    self.failure = result.err.split(separator: "\n").last
                        .map(String.init) ?? "exit \(result.status)"
                    return
                }
                self.failure = nil
                handle(root)
                self.read()
            }
        }
    }
}
