// The window.
//
// 🛑 A spinner is not indexing status. Three questions, in the order a person
// asks them:
//
//   1. can it read my data, and what did it read
//   2. how is it growing            every input over time, and the size
//   3. what version am I running    named in the header, not buried
//
// Each exists because its absence produced a wrong answer: a source failing
// for a week looked like a quiet one, "223k chunks, silent for 60 minutes" was
// read as a hang, 820 MB of decoded mail was a surprise, and a stale build was
// diagnosed for an hour as a code bug.
//
// 🛑 QUESTION 1 WAS TWO PANELS UNTIL 26.827. "Permissions" listed eight names
// with ticks and "Indexed" listed the same eight with counts, a screen apart,
// and the real question joins them: *mail says 40,000 records — is that
// everything, or is the grant half broken?* Answering it meant scrolling
// between two panels and matching names by eye.
//
// A fourth section sits below them and is not one of those questions:
//
//   4. who is in all this          the web, the emoji, the people over time
//
// ⚠️ IT IS NOT A DIAGNOSTIC, and it is last for that reason. Nothing above
// depends on it, it costs three seconds of subprocess to build, and it is
// fetched only while the window is open. See `PeopleView.swift`.
//
// 🛑 A STANDING PARAGRAPH IS NOT A WARNING, and this window had eight of them
// — orange text on a machine with nothing wrong. Everything permanently true
// now lives behind an `Explain` button; what stays on the page is what is true
// right now. See `Explain.swift`.

import Charts
import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Header(model: model)
                if !model.diagnostics.latest.appHasFullDiskAccess { Onboarding() }
                Sources(model: model)
                Growth(model: model)
                Storage(model: model)
                Advanced(model: model)
                People(model: model)
                Places(model: model)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // 🛑 ON THE WHOLE WINDOW. Half of what is written here is meant to be
        // copied — a path, an address, a command, an error. `textSelection`
        // travels down the environment, so one line covers every `Text` below
        // rather than the handful somebody remembered to mark.
        //
        // ⚠️ It does not reach the contact web. That is a `WKWebView` drawing
        // SVG, and its text is not text.
        .textSelection(.enabled)
        .onAppear { model.reread(); model.folders.read() }
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

// MARK: - 3. growth

private struct Growth: View {
    @ObservedObject var model: AppModel
    @AppStorage("growthByTool") private var byTool = true

    var body: some View {
        Panel("Growth", trailing: {
            Explain("Where the early history comes from", """
                    A point is recorded on every indexing run. Points from \
                    before this app existed are derived from when each record \
                    was last written, so the early part of the curve is an \
                    approximation rather than a measurement.

                    Chunks, not records: a chunk is what costs storage and \
                    what gets embedded. The areas are stacked, so they add up \
                    to the total.
                    """)
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
        }
    }
}

// MARK: - 1 and 2, together: can it read this, and what did it read?

// 🛑 ONE PANEL, NOT TWO. "Permissions" and "Indexed" were the same eight names
// in two lists a screen apart, and the question a person actually has joins
// them: *mail says 40,000 records — is that everything, or is the grant half
// broken?* Answering that meant scrolling between two panels and matching
// names by eye.
//
// So each source is one row: whether it can be read, how much of it was read,
// and when. The permission detail and the fix appear inside the row they
// belong to, rather than as a list of red lines under a grid of green ticks.

private struct SourceLine: Identifiable {
    var id: String { tool }
    let tool: String
    let stat: SourceStat?
    let permission: ToolPermission?
    let error: String?

    /// ⚠️ THREE STATES, NOT TWO. A tool with no permission record is not
    /// broken — `files` has no grant of its own, it reads whatever folders the
    /// user named. Drawing it red would invent a fault.
    var readable: Bool? { permission?.usable }
}

private struct Sources: View {
    @ObservedObject var model: AppModel
    @State private var open: Set<String> = []

    var body: some View {
        Panel("Sources", trailing: {
            HStack(spacing: 8) {
                Button("Recheck") { model.diagnostics.check() }
                    .disabled(model.diagnostics.busy)
                    .controlSize(.small)
                Button(open.isEmpty ? "Expand all" : "Collapse all") {
                    open = open.isEmpty ? Set(lines.map(\.tool)) : []
                }
                .controlSize(.small)
            }
        }) {
            let diagnosis = model.diagnostics.latest
            // ⚠️ The app's own grant first. Every row below depends on it, and
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
                Explain("How this app reads your data", """
                        macOS charges a privacy request to the responsible \
                        process. For a helper the app starts, that is the app. \
                        So one Full Disk Access grant on AppleTools covers \
                        every tool it runs, and the same tool typed into a \
                        terminal still needs the terminal's own grant.

                        Calendar, Reminders and Contacts are separate grants \
                        the app holds itself. A tool that cannot be read is \
                        skipped by the indexer; it is not an error, and \
                        nothing else stops working.
                        """)
                Spacer()
            }

            if lines.isEmpty {
                Note("Nothing indexed yet. It builds itself on the first refresh.")
            }
            ForEach(lines) { line in
                SourceRow(line: line,
                          expanded: open.contains(line.tool),
                          toggle: {
                              if open.contains(line.tool) { open.remove(line.tool) }
                              else { open.insert(line.tool) }
                          },
                          folders: model.folders)
            }

            // ⚠️ Only a grant nobody has answered yet gets a button out here.
            // Everything else lives in its own row.
            ForEach(model.grants.entries.filter { $0.state == .notDetermined }) { entry in
                HStack(spacing: 8) {
                    Note("\(entry.name) has never been asked for.", tint: .orange)
                    Button("Ask") { model.grants.requestAndRead(force: true) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// Every source, indexed ones in their own order, then anything that has a
    /// grant but no records of its own.
    private var lines: [SourceLine] {
        let permissions = Dictionary(uniqueKeysWithValues:
            model.diagnostics.latest.tools.map { ($0.tool, $0) })
        var seen = Set<String>()
        var out: [SourceLine] = []
        for source in model.stats.sources {
            seen.insert(source.tool)
            out.append(SourceLine(tool: source.tool, stat: source,
                                  permission: permissions[source.tool],
                                  error: model.indexer.runs[source.tool]?.error))
        }
        for tool in model.diagnostics.latest.tools where !seen.contains(tool.tool) {
            out.append(SourceLine(tool: tool.tool, stat: nil,
                                  permission: tool, error: nil))
        }
        // 🛑 `files` GETS A ROW EVEN WITH NOTHING INDEXED, and that is the
        // whole point of it. Rows come from sources that have records plus
        // tools that have a permission, and `files` has neither until a folder
        // is configured — so the one machine that most needs "Add Folder…" was
        // the one machine with no row to put it in. The first folder still had
        // to be added from the command line.
        if !seen.contains("files") {
            out.append(SourceLine(tool: "files", stat: nil,
                                  permission: nil, error: nil))
        }
        return out
    }
}

private struct SourceRow: View {
    let line: SourceLine
    let expanded: Bool
    let toggle: () -> Void
    /// ⚠️ `Folders`, not the whole `AppModel`. The row used one member of it.
    @ObservedObject var folders: Folders

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 🛑 A TAP GESTURE, NOT A `Button`. A SwiftUI button's LABEL is
            // not selectable text, whatever the environment says — so wrapping
            // the row in one locked exactly the numbers a person wants to
            // copy, on a window whose whole point is numbers. A tap still
            // toggles; a drag now selects.
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                mark
                Text(line.tool).font(.body.weight(.medium))
                    .frame(width: 92, alignment: .leading)
                if let stat = line.stat {
                    Text(Format.count(stat.records)).monospacedDigit()
                        .frame(width: 74, alignment: .trailing)
                    Text("records").font(.caption).foregroundStyle(.secondary)
                    Text(Format.count(stat.chunks)).monospacedDigit()
                        .frame(width: 74, alignment: .trailing)
                    Text("chunks").font(.caption).foregroundStyle(.secondary)
                } else {
                    // 🛑 NOT AN EMPTY ROW, and the two reasons for one are
                    // different. `phone` is read for the people report and
                    // never indexed. `files` has simply not been given a
                    // folder yet — and that row exists precisely so it can be.
                    // A blank line beside a green tick reads as a failure.
                    Text(line.tool == "files"
                         ? "no folders added yet — open this row to add one"
                         : "read on demand, not indexed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let error = line.error {
                    Label("failing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).help(error)
                } else if line.readable == false {
                    Text(line.permission?.status ?? "no access")
                        .font(.caption).foregroundStyle(.orange)
                } else if let when = line.stat?.updated {
                    Text(Format.ago(when)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .onTapGesture(perform: toggle)

            if expanded { detail }
            Divider().opacity(0.35)
        }
    }

    private var mark: some View {
        Image(systemName: line.readable == false
              ? "exclamationmark.circle.fill"
              : line.readable == true ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(line.readable == false ? Color.orange
                             : line.readable == true ? Color.green : Color.secondary)
            .help(line.readable == false
                  ? "\(line.permission?.status ?? "no access")"
                  : line.readable == true ? "readable"
                  : "no permission of its own")
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let permission = line.permission, !permission.usable {
                HStack(spacing: 8) {
                    Note("\(permission.status) — System Settings → "
                         + "\(permission.pane). ⚠️ A toggle is the only fix; no "
                         + "retry here can grant it.", tint: .orange)
                    if let fragment = Grants.settingsFragment(for: permission.pane) {
                        Button("Open Settings…") { Grants.openPane(fragment) }
                            .controlSize(.small)
                    }
                }
                if let advice = permission.advice {
                    Note(advice)
                }
            }
            if let error = line.error {
                Note(error, tint: .red)
            }
            // 🛑 The folder editor lives in the row it configures. `files` is
            // the one source whose contents are a decision rather than a store
            // at a fixed path.
            if line.tool == "files" {
                FolderList(folders: folders)
            }
            if let stat = line.stat, !stat.containers.isEmpty {
                // 🛑 BY ACCOUNT, MAILBOX, LIST OR FOLDER. "40,473 emails" does
                // not answer "what am I indexing"; "🌈/Archive 18,204" does.
                //
                // ⚠️ IN A BOX OF ITS OWN ONCE IT IS LONG. This vault has 60
                // folders, and expanding one row pushed the next four panels
                // off the bottom of the window — which reads as the rest of
                // the window having disappeared.
                let list = VStack(alignment: .leading, spacing: 3) {
                    ForEach(stat.containers) { part in
                        HStack(spacing: 10) {
                            Text(part.name)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            // ⚠️ BOTH NUMBERS, in the parent row's columns.
                            // Records alone cannot say why one folder costs
                            // more of the index than another: 199 files in
                            // Current Work are 4,779 chunks, and 306 in
                            // Reading are 3,232.
                            Text(Format.count(part.records))
                                .frame(width: 62, alignment: .trailing)
                            Text("records").foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            Text(Format.count(part.chunks))
                                .frame(width: 62, alignment: .trailing)
                            Text("chunks").foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                        }
                        .font(.caption).monospacedDigit()
                    }
                }
                if stat.containers.count > 12 {
                    ScrollView { list.padding(.trailing, 8) }
                        .frame(maxHeight: 220)
                } else {
                    list
                }
                if line.tool == "files" {
                    // ⚠️ SAY WHEN IT WAS CUT. The fold happens before the cut,
                    // so 60 rows means 60 top-level FOLDERS — and a vault with
                    // more than that reported a short list with nothing on
                    // screen distinguishing it from a complete one. Same class
                    // of bug as the silent `--limit` in `apple maps`.
                    if stat.containers.count >= 60 {
                        Note("The 60 largest top-level folders. There are more.",
                             tint: .orange)
                    }
                    // 🛑 THE TOP LEVEL, NOT THE BIGGEST FOLDERS. `files` is
                    // the one source whose container is a PATH rather than a
                    // flat name, so it listed every subfolder separately,
                    // ordered by size — 49 rows answering "which folder is
                    // biggest", which is not a question anybody has. A folder
                    // now carries its own files and everything under it.
                    ExplainLabel("Top-level folders", "How a folder is counted", """
                                 One row per top-level folder in each indexed \
                                 folder, carrying its own files and everything \
                                 in its subfolders.

                                 Records are files. Chunks are the pieces they \
                                 were split into for searching, and they are \
                                 what the index costs — a folder of long \
                                 documents can hold fewer files than another \
                                 and far more of the index.

                                 ⚠️ A file sitting directly in an indexed \
                                 folder is filed under that folder's own name.
                                 """)
                } else if stat.containers.count >= 60 {
                    Note("The 60 largest.")
                }
            }
        }
        .padding(.leading, 28).padding(.bottom, 8)
    }
}

// MARK: - the folders the `files` source reads

private struct FolderList: View {
    @ObservedObject var folders: Folders

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(folders.entries) { folder in
                HStack(spacing: 8) {
                    Image(systemName: folder.kind == "obsidian"
                          ? "book.closed" : "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name).font(.callout)
                        Text(folder.display)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if !folder.present {
                        Text("missing").font(.caption).foregroundStyle(.orange)
                    }
                    if !folder.exclude.isEmpty {
                        Text("\(folder.exclude.count) skipped")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(folder.exclude.joined(separator: ", "))
                    }
                    Spacer()
                    Button {
                        folders.remove(folder)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Stop indexing this folder")
                }
            }
            HStack(spacing: 8) {
                Button("Add Folder…") { folders.choose() }
                    .controlSize(.small)
                    .disabled(folders.busy)
                Explain("What gets read", """
                        Every .md, .markdown and .txt file in the folder, \
                        down through its subfolders. An Obsidian vault is \
                        recognised and its .obsidian folder skipped, along \
                        with .git, node_modules and any Attachments folder. \
                        A file over 2 MB is skipped.

                        Adding a folder does not index it — the next run \
                        does. Removing one does not remove what it already \
                        put in the index, because indexing only ever adds. \
                        Those records go when the files source is rebuilt in \
                        full.
                        """)
                Spacer()
            }
            if let note = folders.lastAction {
                Note(note)
            }
            if let failure = folders.failure {
                Note(failure, tint: .red)
            }
        }
        .padding(.vertical, 4)
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
            // 🛑 SAY THE LIMIT OUT LOUD, and say it once. A reader who takes
            // "encrypted" at face value assumes more than this delivers.
            // ⚠️ It was an orange paragraph on a healthy machine, which is how
            // a window teaches people to skip its warnings. The fact never
            // changes, so it is background, not an alarm.
            ExplainLabel("What \u{201c}encrypted\u{201d} covers",
                         "What encryption does and does not protect", """
                         The index is an encrypted disk image. Its key is in \
                         the login keychain, and the image is mounted the \
                         whole time this app runs.

                         🛑 While it is mounted, any program running as you \
                         can read it. That is the same exposure the plain \
                         file always had, now limited to the hours the app is \
                         open. It protects the file at rest — in a backup, on \
                         a stolen disk, in Time Machine — not from software \
                         running as you right now.

                         The index holds the decoded text of your mail. \
                         Deleting the index deletes its key too, which makes \
                         every copy already in a backup unreadable.
                         """)
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
            HStack(spacing: 8) {
                Toggle("Let terminals use this app's permissions", isOn: $proxy)
                    .onChange(of: proxy) { _, _ in model.toolProxy.apply() }
                Explain("What this switch gives away", """
                        With this on, the app reads your mail, messages, \
                        notes, calendar and contacts on behalf of any program \
                        running as you, with no prompt.

                        🛑 Only a signed AppleTools client is accepted. That \
                        stops a program speaking the protocol directly. It \
                        does not stop one from running that client, so treat \
                        this as granting every process running as you the \
                        access this app holds.

                        Every proxied command is written to the log.
                        """)
                Spacer()
            }
            // ⚠️ ONE LINE, AND ONLY WHILE IT IS ON. The paragraph used to sit
            // here in orange whether the switch was on or off, which is how a
            // real warning gets read as decoration.
            if proxy {
                Note("On: any program running as you can read your mail, "
                     + "messages, notes, calendar and contacts through this "
                     + "app, with no prompt.", tint: .orange)
            }
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

/// ⚠️ NOT `private` any more. `PeopleView.swift` builds its panels out of the
/// same two pieces, and a second copy of either would drift from this one.
struct Panel<Content: View, Trailing: View>: View {
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

struct Stat: View {
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

/// ⚠️ NOT `private`, for the same reason `Panel` is not: `PlacesView.swift`
/// says the same kinds of things and a second copy would drift.
struct Note: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
