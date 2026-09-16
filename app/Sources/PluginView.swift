// One plugin, inside the Sources row it becomes — or, until it is enabled,
// in the list of plugins the window found.
//
// The panel is the same in both places, and the button on it is the only
// difference: "Enable" while the plugin is found and off, "Disable" once it
// is on. Everything it shows comes from `Plugins`, which asks `apple plugins`.

import SwiftUI

struct PluginPanel: View {
    @ObservedObject var plugins: Plugins
    let entry: PluginEntry
    /// Drafts for the fields, keyed by config key. A secret's draft starts
    /// empty even when one is set: the window never learns the value.
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            identity
            if entry.enabled, let status = entry.status {
                statusLine(status)
            }
            if !entry.knownHosts.isEmpty {
                // 🛑 The one line that says where data goes, drawn whether or
                // not the plugin is on. A person deciding to enable it reads
                // this line first.
                Note("Talks to \(entry.knownHosts.joined(separator: ", ")). Nothing "
                     + "else in this app leaves the machine.", tint: .orange)
            }
            if !entry.fields.isEmpty {
                Text("Configuration").font(.caption2.weight(.semibold))
                    .kerning(0.7).foregroundStyle(.tertiary)
                ForEach(entry.fields) { field in fieldRow(field) }
            }
            controls
            if let note = plugins.lastAction {
                Note(note)
            }
            if let failure = plugins.failure {
                Note(failure, tint: .red)
            }
        }
        .onAppear { seed() }
        .onChange(of: entry) { _ in seed() }
    }

    private var identity: some View {
        HStack(spacing: 6) {
            Text("Plugin").font(.caption2.weight(.semibold)).kerning(0.7)
                .foregroundStyle(.tertiary)
            if let version = entry.version {
                Text("v\(version)").font(.caption).foregroundStyle(.tertiary)
            }
            if let description = entry.description {
                Text("·").foregroundStyle(.tertiary)
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ status: PluginStatus) -> some View {
        HStack(spacing: 7) {
            Circle().fill(status.usable ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(status.status).font(.caption.weight(.medium))
            if let version = status.version {
                Text("server \(version)").font(.caption).foregroundStyle(.secondary)
            }
            if let account = status.account {
                Text("·").foregroundStyle(.tertiary)
                Text(account).font(.caption).foregroundStyle(.secondary)
            }
        }
        if !status.usable, let advice = status.advice {
            Note(advice, tint: .orange)
        }
    }

    /// One config key: a label, a field, and a Save that runs only when the
    /// draft differs from what is stored. ⚠️ A SECRET FIELD NEVER SHOWS THE
    /// VALUE. The window is told `•••` when one is set and nothing when it is
    /// not, and typing a new one replaces it in the Keychain.
    private func fieldRow(_ field: PluginField) -> some View {
        let stored = entry.values[field.key]
        let draft = Binding(get: { drafts[field.key] ?? "" },
                            set: { drafts[field.key] = $0 })
        let dirty = field.secret ? !(drafts[field.key] ?? "").isEmpty
                                 : (drafts[field.key] ?? "") != (stored ?? "")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(field.key).font(.caption.weight(.medium))
                    .frame(width: 72, alignment: .leading)
                Group {
                    if field.secret {
                        SecureField(stored == nil ? "not set" : "set — type to replace",
                                    text: draft)
                    } else {
                        TextField(field.required ? "required" : "optional", text: draft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { save(field) }
                Button("Save") { save(field) }
                    .controlSize(.small)
                    .disabled(!dirty || plugins.busy)
                if field.secret, stored != nil {
                    Button("Clear") { plugins.set(entry.name, key: field.key, value: "") }
                        .controlSize(.small).disabled(plugins.busy)
                }
            }
            if let help = field.help {
                Text(help).font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, 80)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if entry.enabled {
                Button("Disable") { plugins.disable(entry.name) }
                    .controlSize(.small).disabled(plugins.busy)
            } else {
                Button("Enable") { plugins.enable(entry.name) }
                    .controlSize(.small)
                    .disabled(plugins.busy || !entry.missing.isEmpty || !entry.valid)
                if !entry.missing.isEmpty {
                    Text("needs \(entry.missing.joined(separator: ", ")) first")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Check again") { plugins.read() }
                .controlSize(.small).buttonStyle(.link).disabled(plugins.busy)
            if plugins.busy {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func save(_ field: PluginField) {
        let value = drafts[field.key] ?? ""
        if field.secret && value.isEmpty { return }
        plugins.set(entry.name, key: field.key, value: value)
        if field.secret { drafts[field.key] = "" }
    }

    private func seed() {
        for field in entry.fields where !field.secret {
            if drafts[field.key] == nil || drafts[field.key] == "" {
                drafts[field.key] = entry.values[field.key] ?? ""
            }
        }
    }
}

/// The plugins that are on disk and not enabled, under the Sources table.
/// An enabled one has a row of its own up there; this is where the first
/// "Enable" is pressed.
struct AvailablePlugins: View {
    @ObservedObject var plugins: Plugins
    @State private var open: String? = nil

    private var waiting: [PluginEntry] {
        plugins.entries.filter { !$0.enabled }
    }

    var body: some View {
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plugins found, not enabled").font(.caption2.weight(.semibold))
                    .kerning(0.7).foregroundStyle(.tertiary)
                    .padding(.top, 10)
                ForEach(waiting) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(open == entry.name ? 90 : 0))
                            Text(entry.name).font(.body.weight(.medium))
                            Text(entry.installed
                                 ? (entry.valid ? entry.note : "does not answer manifest")
                                 : "configured, not installed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { open = open == entry.name ? nil : entry.name }
                        if open == entry.name, entry.installed, entry.valid {
                            PluginPanel(plugins: plugins, entry: entry)
                                .padding(.leading, 21)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
