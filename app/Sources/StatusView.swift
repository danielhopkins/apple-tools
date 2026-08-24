// The window.
//
// 🛑 A spinner is not indexing status. Four questions, in the order a person
// asks them:
//
//   1. can it read my data          permissions, and what to do when not
//   2. what is it indexing          per source, per ACCOUNT or FOLDER
//   3. how is it growing            every input over time, and the size
//   4. what version am I running    named in the header, not buried
//
// Each exists because its absence produced a wrong answer: a source failing
// for a week looked like a quiet one, "223k chunks, silent for 60 minutes" was
// read as a hang, 820 MB of decoded mail was a surprise, and a stale build was
// diagnosed for an hour as a code bug.

import Charts
import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Header(model: model)
                if !model.diagnostics.latest.appHasFullDiskAccess { Onboarding() }
                Permissions(model: model)
                Growth(model: model)
                Sources(model: model)
                Storage(model: model)
                Advanced(model: model)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.reread() }
    }
}

// MARK: - header

private struct Header: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("AppleTools").font(.system(size: 26, weight: .semibold))
                // 🛑 THE VERSION, IN THE HEADER. A stale build was diagnosed as
                // a code bug for an hour because nothing on screen said which
                // build was running.
                Text(model.appVersion)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                StatusPill(model: model)
            }

            Text(phase)
                .font(.callout)
                .foregroundStyle(model.indexer.lastCycleError == nil
                                 ? Color.secondary : Color.red)
            if let failure = model.indexer.lastCycleError {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(3)
            }

            HStack(spacing: 10) {
                Button(model.indexer.isRunning ? "Indexing…" : "Refresh Now") {
                    model.indexer.refresh()
                }
                .disabled(model.indexer.isRunning)
                .buttonStyle(.borderedProminent)
                Toggle("Automatic", isOn: Binding(
                    get: { model.indexer.automatic },
                    set: { model.indexer.automatic = $0; model.indexer.saveState() }))
                Toggle("Start at Login", isOn: Binding(
                    get: { model.loginItem.state == .enabled },
                    set: { model.loginItem.set($0) }))
                Spacer()
            }
            if let failure = model.loginItem.failure {
                Text(failure).font(.caption).foregroundStyle(.red)
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
                return "not indexed yet · every 5 minutes once it starts"
            }
            return "last indexed \(Format.ago(when)) · every 5 minutes, on wake, on unlock"
        }
    }
}

private struct StatusPill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let ok = model.healthy
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(ok ? "Healthy" : "Needs attention").font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background((ok ? Color.green : Color.orange).opacity(0.14), in: Capsule())
    }
}

// MARK: - 1. permissions

private struct Permissions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Panel("Permissions", trailing: {
            Button("Recheck") { model.diagnostics.check() }
                .disabled(model.diagnostics.busy)
                .controlSize(.small)
        }) {
            let diagnosis = model.diagnostics.latest
            // ⚠️ The app's own grant first. Every tool below depends on it, and
            // "children inherit the app's grant" is the measurement the whole
            // schedule rests on.
            HStack(spacing: 18) {
                Badge(label: "Full Disk Access",
                      ok: diagnosis.appHasFullDiskAccess,
                      detail: diagnosis.appHasFullDiskAccess ? "granted" : "not granted")
                Badge(label: "Helpers inherit it",
                      ok: diagnosis.childHasFullDiskAccess,
                      detail: diagnosis.inheritance == .yes ? "yes"
                              : diagnosis.inheritance == .no ? "NO" : "unknown")
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)],
                      alignment: .leading, spacing: 8) {
                ForEach(diagnosis.tools) { tool in
                    HStack(spacing: 7) {
                        Image(systemName: tool.usable
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(tool.usable ? Color.green : Color.red)
                        Text(tool.tool).font(.callout)
                        Spacer(minLength: 0)
                        if !tool.usable {
                            Text(tool.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Only shown when something is wrong. A healthy machine says nothing.
            ForEach(diagnosis.blocked) { tool in
                Note("\(tool.tool): \(tool.status) — fix in System Settings → \(tool.pane)",
                     tint: .red)
            }
            ForEach(model.grants.entries.filter { !$0.settled }) { entry in
                HStack(spacing: 8) {
                    Note("\(entry.name) is \(entry.state.rawValue)", tint: .orange)
                    if entry.state == .notDetermined {
                        Button("Ask") { model.grants.requestAndRead(force: true) }
                            .controlSize(.small)
                    } else {
                        Button("Open Settings…") { Grants.openPane(entry.pane) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - 3. growth

private struct Growth: View {
    @ObservedObject var model: AppModel
    @AppStorage("growthByTool") private var byTool = true

    var body: some View {
        Panel("Growth", trailing: {
            Picker("", selection: $byTool) {
                Text("By source").tag(true)
                Text("Total").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 168)
        }) {
            let stats = model.stats
            if stats.history.count < 2 {
                Note("Not enough history yet. A point is recorded on every "
                     + "indexing run.")
            } else if byTool {
                // 🛑 STACKED, so the AREAS sum to the total. Overlaid lines on
                // one axis let mail's 203k chunks flatten every other source
                // into the baseline, which is exactly the source you want to
                // see growing.
                Chart(stats.history) { point in
                    AreaMark(x: .value("day", point.date),
                             y: .value("chunks", point.chunks),
                             stacking: .standard)
                        .foregroundStyle(by: .value("source", point.tool))
                        .interpolationMethod(.monotone)
                }
                .chartLegend(position: .bottom, spacing: 10)
                .chartYAxisLabel("chunks")
                .frame(height: 210)
            } else {
                Chart(stats.totals, id: \.0) { day, chunks in
                    AreaMark(x: .value("day", day), y: .value("chunks", chunks))
                        .foregroundStyle(.tint.opacity(0.22))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("day", day), y: .value("chunks", chunks))
                        .foregroundStyle(.tint)
                        .interpolationMethod(.monotone)
                }
                .chartYAxisLabel("chunks")
                .frame(height: 210)
            }

            HStack(spacing: 26) {
                Stat("chunks", Format.count(stats.chunks))
                Stat("embedded", Format.count(stats.vectors))
                Stat("on disk", Format.bytes(stats.bytes))
                if stats.backlog > 0 {
                    Stat("to embed", Format.count(stats.backlog), tint: .orange)
                }
                Spacer()
            }
            // ⚠️ The seeded part of the curve is an approximation, and saying
            // so costs one line.
            Note("Points before this app existed are derived from when each "
                 + "record was last written, so early history is approximate.")
        }
    }
}

// MARK: - 2. what is indexed

private struct Sources: View {
    @ObservedObject var model: AppModel
    @State private var open: Set<String> = []

    var body: some View {
        Panel("Indexed", trailing: {
            Button(open.isEmpty ? "Expand all" : "Collapse all") {
                open = open.isEmpty
                    ? Set(model.stats.sources.map(\.tool)) : []
            }
            .controlSize(.small)
        }) {
            if model.stats.sources.isEmpty {
                Note("Nothing indexed yet. It builds itself on the first refresh.")
            }
            ForEach(model.stats.sources) { source in
                SourceRow(source: source,
                          expanded: open.contains(source.tool),
                          toggle: {
                              if open.contains(source.tool) { open.remove(source.tool) }
                              else { open.insert(source.tool) }
                          },
                          error: model.indexer.runs[source.tool]?.error)
            }
        }
    }
}

private struct SourceRow: View {
    let source: SourceStat
    let expanded: Bool
    let toggle: () -> Void
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(source.tool).font(.body.weight(.medium))
                        .frame(width: 96, alignment: .leading)
                    Text(Format.count(source.records)).monospacedDigit()
                        .frame(width: 74, alignment: .trailing)
                    Text("records").font(.caption).foregroundStyle(.secondary)
                    Text(Format.count(source.chunks)).monospacedDigit()
                        .frame(width: 74, alignment: .trailing)
                    Text("chunks").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let error {
                        Label("failing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).help(error)
                    } else if let when = source.updated {
                        Text(Format.ago(when)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)

            if expanded {
                // 🛑 BY ACCOUNT, MAILBOX, LIST OR FOLDER. "40,473 emails" does
                // not answer "what am I indexing"; "🌈/Archive 18,204" does.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(source.containers) { part in
                        HStack(spacing: 10) {
                            Text(part.name)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(Format.count(part.records))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    if source.containers.count >= 60 {
                        Note("Showing the 60 largest.")
                    }
                }
                .padding(.leading, 28).padding(.bottom, 8)
            }
            Divider().opacity(0.35)
        }
    }
}

// MARK: - storage and the rest

private struct Storage: View {
    @ObservedObject var model: AppModel
    @State private var confirming = false

    var body: some View {
        Panel("Storage") {
            HStack(spacing: 10) {
                Image(systemName: model.stats.encrypted ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(model.stats.encrypted ? Color.green : Color.red)
                Text(model.stats.encrypted
                     ? "Encrypted, AES-256, unlocked while this app runs"
                     : "NOT encrypted")
                Spacer()
                Text(Format.bytes(model.stats.bytes))
                    .font(.system(.body, design: .monospaced))
            }
            Text(model.stats.path.isEmpty ? Paths.database.path : model.stats.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            if let progress = model.vaultProgress {
                Note(progress, tint: .orange)
            }
            // 🛑 Say the limit out loud. A reader who takes "encrypted" at face
            // value will assume more than this delivers.
            Note("While this app runs the index is mounted, and any program "
                 + "running as you can read it. That is the same exposure the "
                 + "plain file always had, now limited to the time the app is "
                 + "open.", tint: .orange)
            if model.stats.mixedModels {
                Note("🛑 Vectors exist under more than one model name. A search "
                     + "that mixes two vector spaces returns confident nonsense.",
                     tint: .red)
            }
            if confirming {
                Note("This deletes the index and its key. Rebuilding takes "
                     + "about eight minutes.", tint: .red)
                HStack {
                    Button("Delete Everything") { model.forgetIndex(); confirming = false }
                    Button("Cancel") { confirming = false }
                }
            } else {
                Button("Delete the Index…") { confirming = true }
            }
        }
    }
}

private struct Advanced: View {
    @ObservedObject var model: AppModel
    @AppStorage("toolProxy") private var proxy = false

    var body: some View {
        Panel("Advanced") {
            HStack {
                Text("Search endpoint").frame(width: 150, alignment: .leading)
                switch model.search.state {
                case .running(let pid): Text("answering · pid \(pid)")
                case .stopped: Text("starting…").foregroundStyle(.secondary)
                case .failed(let why): Text(why).foregroundStyle(.red)
                }
                Spacer()
            }
            .font(.callout)
            if let ping = model.search.lastPing, ping["ok"] as? Bool == true {
                HStack {
                    Text("").frame(width: 150)
                    Text("\(Format.count(ping["vectors"] as? Int ?? 0)) vectors warm · "
                         + String(format: "%.0f MB", ping["resident_megabytes"] as? Double ?? 0))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Divider().opacity(0.3)
            Toggle("Let terminals use this app's permissions", isOn: $proxy)
                .onChange(of: proxy) { _, _ in model.toolProxy.apply() }
            Note("🛑 With this on, the app reads your mail, messages, notes, "
                 + "calendar and contacts for ANY program running as you, with "
                 + "no prompt. Only a signed AppleTools client is accepted, "
                 + "which stops a program speaking the protocol directly — it "
                 + "does not stop one from running that client. Every proxied "
                 + "command is logged.", tint: proxy ? .orange : .secondary)
            if model.toolProxy.running, model.toolProxy.served > 0 {
                Note("\(model.toolProxy.served) commands served."
                     + (model.toolProxy.lastCommand.map { " Last: \($0)" } ?? ""))
            }
        }
    }
}

// MARK: - onboarding

private struct Onboarding: View {
    var body: some View {
        Panel("This app cannot read your data yet", tint: .orange) {
            Text("""
                 It reads your mail, messages, notes, calendar, contacts, call \
                 history and visited places from the stores on this Mac. \
                 Nothing leaves the machine.

                 macOS has no way for an app to ask for Full Disk Access. You \
                 add it by hand, once. macOS then restarts this app.
                 """)
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Open Full Disk Access…") { Diagnostics.openFullDiskAccessPane() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - small pieces

private struct Panel<Content: View, Trailing: View>: View {
    let title: String
    var tint: Color? = nil
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(_ title: String, tint: Color? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(tint ?? .secondary)
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? Color.gray).opacity(tint == nil ? 0.07 : 0.13),
                    in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct Badge: View {
    let label: String
    let ok: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.shield.fill" : "xmark.shield.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var tint: Color? = nil
    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label; self.value = value; self.tint = tint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Note: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
