// The status window.
//
// 🛑 A spinner is not indexing status. Each section below exists because its
// absence has already produced a wrong answer in `lab/`:
//
//   per source     a source failing for a week must not look like a quiet one
//   backlog        "223k chunks, silent for 60 minutes" was read as a hang
//   permissions    every access failure looks identical without the state
//   size           820 MB of decoded mail must never be a surprise
//   model          rows under two model names return confident nonsense

import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Header(model: model)
                if !model.diagnostics.latest.appHasFullDiskAccess { Onboarding() }
                Endpoint(model: model)
                Sources(model: model)
                Embedding(model: model)
                Permissions(model: model)
                Frameworks(model: model)
                Security(model: model)
            }
            .padding(22)
        }
        .onAppear { model.reread() }
    }
}

// MARK: - header

private struct Header: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Index").font(.title2).bold()
                Spacer()
                Text(String(format: "%.0f MB", model.facts.megabytes))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(phase)
                .font(.callout)
                .foregroundStyle(model.indexer.lastCycleError == nil
                                 ? Color.secondary : Color.red)
            if let failure = model.indexer.lastCycleError {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button(model.indexer.isRunning ? "Indexing…" : "Refresh Now") {
                    model.indexer.refresh()
                }
                .disabled(model.indexer.isRunning)
                Toggle("Automatically", isOn: Binding(
                    get: { model.indexer.automatic },
                    set: { model.indexer.automatic = $0; model.indexer.saveState() }))
                Toggle("Start at Login", isOn: Binding(
                    get: { model.loginItem.state == .enabled },
                    set: { model.loginItem.set($0) }))
                Spacer()
                Button("Recheck Permissions") { model.diagnostics.check() }
                    .disabled(model.diagnostics.busy)
            }
            if model.loginItem.state == .needsApproval {
                Note("macOS is holding this login item for your approval. Turn "
                     + "it on in System Settings \u{2192} General \u{2192} Login Items.",
                     tint: .orange)
            }
            if let failure = model.loginItem.failure {
                Note(failure, tint: .red)
            }
        }
    }

    private var phase: String {
        switch model.indexer.phase {
        case .ingesting(let source): return "reading \(source)…"
        case .embedding: return "embedding new chunks…"
        case .reloading: return "reloading the search endpoint…"
        case .idle:
            guard let when = model.indexer.lastCycleFinished else {
                return "not indexed yet. Every 5 minutes once it starts."
            }
            return "last indexed \(Format.ago(when)) · every 5 minutes, and on wake"
        }
    }
}

// MARK: - Full Disk Access

private struct Onboarding: View {
    var body: some View {
        Card(tint: .orange) {
            Text("This app cannot read your data yet").font(.headline)
            Text("""
                 It reads your mail, messages, notes, calendar, contacts, call \
                 history and visited places from the stores on this Mac. \
                 Nothing leaves the machine.

                 macOS has no way for an app to ask for Full Disk Access. You \
                 add it by hand, once. macOS then restarts this app.
                 """)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Full Disk Access…") {
                Diagnostics.openFullDiskAccessPane()
            }
        }
    }
}

// MARK: - the search endpoint

private struct Endpoint: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Search endpoint") {
            switch model.search.state {
            case .running(let pid):
                Row("state", "answering · pid \(pid)")
            case .stopped:
                Row("state", "starting…")
            case .failed(let why):
                Row("state", why, tint: .red)
            }
            Row("socket", Paths.socket.path)
            if let ping = model.search.lastPing, ping["ok"] as? Bool == true {
                Row("holding", "\(Format.count(ping["vectors"] as? Int ?? 0)) vectors"
                    + "  ·  \(ping["model"] as? String ?? "?")")
                Row("resident", String(format: "%.0f MB",
                                       ping["resident_megabytes"] as? Double ?? 0))
            } else if case .running = model.search.state {
                Row("holding", "loading the model…")
            }
            if model.search.evictedAgent {
                Note("""
                     The launchd agent was serving this socket and is now \
                     unloaded. The app serves it instead, and it can also index.
                     """)
            }
        }
    }
}

// MARK: - per source

private struct Sources: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Sources") {
            if model.facts.missing {
                Text("No index yet. It builds itself on the first refresh.")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("source").gridColumnAlignment(.leading)
                    Text("records").gridColumnAlignment(.trailing)
                    Text("chunks").gridColumnAlignment(.trailing)
                    Text("last read").gridColumnAlignment(.leading)
                    Text("").gridColumnAlignment(.leading)
                }
                .font(.caption).foregroundStyle(.secondary)

                ForEach(model.facts.sources) { source in
                    let run = model.indexer.runs[source.tool]
                    GridRow {
                        Text(source.tool)
                        Text(Format.count(source.records)).monospacedDigit()
                        Text(Format.count(source.chunks)).monospacedDigit()
                        Text(source.lastRefresh.map(Format.ago) ?? "—")
                            .foregroundStyle(.secondary)
                        if let error = run?.error {
                            Text(error).foregroundStyle(.red).lineLimit(1)
                                .help(error)
                        } else if let run, run.changed {
                            Text("+\(run.added) ~\(run.updated) -\(run.removed)")
                                .foregroundStyle(.green)
                        } else {
                            Text("")
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                }
            }
            if let sweep = model.indexer.lastFullSweep {
                Note("Deletions are swept weekly. Last full sweep \(Format.ago(sweep)).")
            } else {
                Note("Deletions are swept weekly. No full sweep yet.")
            }
        }
    }
}

// MARK: - embedding and the model

private struct Embedding: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Embedding") {
            Row("chunks", Format.count(model.facts.chunks))
            ForEach(model.facts.models) { entry in
                Row(entry.model, "\(Format.count(entry.vectors)) vectors")
            }
            if model.facts.backlog > 0 {
                // ⚠️ Quote a rate, and quote the one for THIS model. A single
                // hard-coded rate once told a caller "52 minutes" for a backlog
                // that finished in 5.
                let minutes = Double(model.facts.backlog) / 1000.0 / 60.0
                Row("to embed", "\(Format.count(model.facts.backlog)) chunks"
                    + String(format: " · about %.0f min at ~1000 chunks/sec", minutes),
                    tint: .orange)
            } else if model.facts.chunks > 0 {
                Row("to embed", "nothing")
            }
            if model.facts.mixedModels {
                Note("""
                     🛑 Vectors exist under more than one model name. A search \
                     that mixes two vector spaces returns confident nonsense. \
                     Delete the rows of the model you are not using.
                     """, tint: .red)
            }
        }
    }
}

// MARK: - permissions, and the Step 0 answer

private struct Permissions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Permissions") {
            let diagnosis = model.diagnostics.latest
            Row("this app", diagnosis.appHasFullDiskAccess
                ? "can read the protected stores"
                : "cannot read the protected stores",
                tint: diagnosis.appHasFullDiskAccess ? nil : .red)
            // 🛑 The measurement the whole schedule rests on. If a child does
            // not inherit the app's grant, the app cannot index and this window
            // must say so rather than showing an empty source list.
            Row("its helpers", diagnosis.inheritance.rawValue,
                tint: diagnosis.inheritance == .no ? .red : nil)

            if let failure = diagnosis.error {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(diagnosis.tools) { tool in
                    GridRow {
                        Text(tool.usable ? "✓" : "✗")
                            .foregroundStyle(tool.usable ? .green : .red)
                        Text(tool.tool)
                        Text(tool.status).foregroundStyle(.secondary)
                        Text(tool.usable ? "" : tool.pane).foregroundStyle(.secondary)
                    }
                    .font(.system(.body, design: .monospaced))
                }
            }
            if let when = diagnosis.checked {
                Note("Checked \(Format.ago(when)).")
            }
        }
    }
}

// MARK: - the three grants the app can ask for

private struct Frameworks: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Calendar, Reminders and Contacts") {
            Note("""
                 🛑 The index does not need these. `apple-calendar`, `reminders` \
                 and `apple-contacts` each carry their OWN grant, because each \
                 one disclaims and becomes its own responsible process. That is \
                 how all six sources index while the rows below say no.

                 They would matter only if the app itself read a calendar or a \
                 contact directly, which it does not.
                 """)
            ForEach(model.grants.entries) { entry in
                if let attempt = model.grants.attempts[entry.name],
                   !entry.settled, attempt != "skipped: already decided" {
                    Note("last request for \(entry.name): \(attempt)", tint: .red)
                }
            }
            ForEach(model.grants.entries) { entry in
                HStack(spacing: 12) {
                    Text(entry.settled ? "✓" : "✗")
                        .foregroundStyle(entry.settled ? Color.green : Color.red)
                    Text(entry.name).frame(width: 100, alignment: .leading)
                    Text(entry.state.rawValue).foregroundStyle(.secondary)
                    Spacer()
                    // ⚠️ Asking again does nothing once the state is anything
                    // but notDetermined. Only a manual toggle fixes those.
                    if !entry.settled && entry.state != .notDetermined {
                        Button("Open Settings…") { Grants.openPane(entry.pane) }
                            .controlSize(.small)
                    }
                    // ⚠️ Only a person may start this. Each unanswered request
                    // costs its full deadline with the app frontmost.
                    if entry.state == .notDetermined {
                        Button("Ask Again") { model.grants.requestAndRead(force: true) }
                            .controlSize(.small)
                    }
                }
                .font(.system(.body, design: .monospaced))
            }
        }
    }
}

// MARK: - the vault, and deleting the index

private struct Security: View {
    @ObservedObject var model: AppModel
    @State private var confirming = false

    var body: some View {
        Section("Security") {
            switch model.vault.state {
            case .mounted:
                Row("index", "encrypted, unlocked while this app runs")
            case .locked:
                Row("index", "encrypted and locked", tint: .orange)
            case .absent:
                Row("index", "NOT encrypted", tint: .red)
            case .failed(let why):
                Row("index", why, tint: .red)
            }
            Row("at", Paths.database.path)
            if let progress = model.vaultProgress {
                Row("moving", progress, tint: .orange)
            }
            if let failure = model.vaultFailure {
                Note(failure, tint: .red)
            }
            Note("AES-256 disk image. The key sits in your Keychain, so the "
                 + "index survives a backup as ciphertext and a stolen disk "
                 + "gives up nothing.")
            // 🛑 Say the limit out loud. A reader who takes "encrypted" at
            // face value will assume more than this delivers.
            Note("🛑 While this app runs, the index is mounted, and any program "
                 + "running as you can read it \u{2014} the same exposure the "
                 + "plain file always had, now limited to the time the app is "
                 + "open. Stronger needs the readers to hold a key themselves, "
                 + "which Python's stdlib sqlite3 cannot do.", tint: .orange)

            if confirming {
                Note("This deletes the index and its key. \u{2018}apple-index "
                     + "refresh\u{2019} rebuilds it in about eight minutes.",
                     tint: .red)
                HStack {
                    Button("Delete Everything") { model.forgetIndex() }
                    Button("Cancel") { confirming = false }
                }
            } else {
                Button("Delete the Index\u{2026}") { confirming = true }
            }
        }
    }
}

// MARK: - small pieces

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Row: View {
    let label: String
    let value: String
    var tint: Color? = nil

    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value).foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(.body, design: .monospaced))
    }
}

private struct Note: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Card<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
