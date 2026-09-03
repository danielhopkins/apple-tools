// The two diagnostic panes: what was read, and what it costs.
//
// 🛑 A spinner is not indexing status. Two questions, in the order a person
// asks them:
//
//   1. can it read my data, and what did it read      Sources
//   2. how is it growing, and what does it cost       Index size
//
// Each exists because its absence produced a wrong answer: a source failing
// for a week looked like a quiet one, "223k chunks, silent for 60 minutes" was
// read as a hang, and 820 MB of decoded mail was a surprise.
//
// 🛑 QUESTION 1 WAS TWO PANELS UNTIL 26.827. "Permissions" listed eight names
// with ticks and "Indexed" listed the same eight with counts, a screen apart,
// and the real question joins them: *mail says 40,000 records — is that
// everything, or is the grant half broken?* Answering it meant scrolling
// between two panels and matching names by eye.
//
// 🛑 A STANDING PARAGRAPH IS NOT A WARNING, and this window had eight of them
// — orange text on a machine with nothing wrong. Everything permanently true
// now lives behind an `Explain` button; what stays on the page is what is true
// right now. See `Explain.swift`.
//
// The window's frame, the rail and the pane header are in `Shell.swift`.

import Charts
import SwiftUI

// MARK: - 1 and 2, together: can it read this, and what did it read?

// 🛑 ONE ROW PER SOURCE, NOT TWO LISTS. "Permissions" and "Indexed" were the
// same eight names in two lists a screen apart, and the question a person
// actually has joins them: *mail says 40,000 records — is that everything, or
// is the grant half broken?*
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
    /// The app's own Full Disk Access, for a source whose grant IS that and
    /// which has no row in `apple status`. Nil for every other source.
    var appFullDiskAccess: Bool? = nil

    /// ⚠️ THREE STATES, NOT TWO. A tool with no permission record is not
    /// broken — `files` has no grant of its own, it reads whatever folders the
    /// user named. Drawing it red would invent a fault.
    ///
    /// 🛑 BUT "NO ROW IN `apple status`" IS NOT THE SAME AS "NEEDS NOTHING",
    /// and photos was drawn dashed for exactly that reason: there is no
    /// `apple-photos` binary, so the grant table has nothing to say about it.
    /// It needs Full Disk Access like `notes`, `messages`, `maps` and `phone`.
    /// Measured from a launchd job, which has none: the library STATS FINE and
    /// the sqlite open fails with `authorization denied`. A dashed mark on a
    /// source that can be genuinely broken hides the breakage.
    var readable: Bool? { permission?.usable ?? appFullDiskAccess }

    /// What this source's mark is actually about.
    var grantName: String? {
        permission != nil ? nil : (appFullDiskAccess != nil
                                   ? "Full Disk Access" : nil)
    }

    /// The one line of context beside the name. ⚠️ NOT AN EMPTY CELL, and the
    /// two reasons for one are different: `phone` is read for the people
    /// report and never indexed, `files` has simply not been given a folder
    /// yet — and that row exists precisely so it can be.
    var note: String {
        if tool == "files" {
            if folderCount == 0 {
                return "no folders added yet — open this row to add one"
            }
            return folderCount == 1 ? "1 folder" : "\(folderCount) folders"
        }
        if stat != nil { return "" }
        return "read on demand, not indexed"
    }

    /// How many folders `files` is configured to read. ⚠️ Zero is a real
    /// answer, not a missing one: the row exists precisely so the first folder
    /// can be added from it.
    var folderCount: Int = 0

    var dot: Color {
        readable == false ? .orange : readable == true ? .green : .secondary
    }
}

/// Sources with no tool of their own whose grant is the app's Full Disk
/// Access. ⚠️ `files` is deliberately NOT here: it reads folders the user
/// named and has no grant to report.
private let fullDiskAccessSources: Set<String> = ["photos"]

/// The one column geometry the header, the rows and the breakdowns all share.
/// 🛑 THREE COPIES OF THESE WIDTHS DRIFT. A breakdown line indented under a
/// row has to land in the row's own columns, or the numbers stop being
/// comparable by eye — which is the entire reason they are in columns.
private enum Column {
    static let caret: CGFloat = 14
    static let name: CGFloat = 96
    static let records: CGFloat = 78
    static let chunks: CGFloat = 78
    static let state: CGFloat = 88
    static let gap: CGFloat = 10
}

struct Sources: View {
    @ObservedObject var model: AppModel
    /// 🛑 ONE ROW AT A TIME. Several open at once pushed the table's own
    /// footer off the bottom of the pane, which is the failure the rail was
    /// built to end.
    @State private var open: String? = nil

    var body: some View {
        PaneSection("Sources", subtitle: access, trailing: {
            HStack(spacing: 12) {
                Button("Recheck") { model.diagnostics.check() }
                    .disabled(model.diagnostics.busy)
                    .buttonStyle(.link)
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
            }
        }) {
            // ⚠️ SPACING 0, and its own stack. `PaneSection` puts 12 points
            // between its children, which between table rows is a gap wide
            // enough that the columns stop reading as a table.
            VStack(alignment: .leading, spacing: 0) {
                header
                if lines.isEmpty {
                    Note("Nothing indexed yet. It builds itself on the first "
                         + "refresh.").padding(.top, 8)
                }
                ForEach(lines) { line in
                    SourceRow(line: line,
                              expanded: open == line.tool,
                              toggle: { open = open == line.tool ? nil : line.tool },
                              folders: model.folders)
                }
            }
            blocked
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

    /// The app's own grant, in one line. ⚠️ Every row below depends on it, and
    /// "children inherit the app's grant" is the measurement the whole
    /// schedule rests on.
    private var access: String {
        let diagnosis = model.diagnostics.latest
        let mine = diagnosis.appHasFullDiskAccess
            ? "Full Disk Access granted" : "Full Disk Access NOT granted"
        switch diagnosis.inheritance {
        case .yes:     return mine + " · helpers inherit it"
        case .no:      return mine + " · helpers do NOT inherit it"
        default:       return mine + " · inheritance unknown"
        }
    }

    private var header: some View {
        HStack(spacing: Column.gap) {
            Color.clear.frame(width: Column.caret, height: 1)
            // ⚠️ THE DOT'S WIDTH AND ITS GAP, so "source" starts where a
            // source name starts. Without them the heading sat 13 points to
            // the left of every value it heads.
            HStack(spacing: 7) {
                Color.clear.frame(width: 6, height: 1)
                Text("source")
            }
            .frame(width: Column.name, alignment: .leading)
            Spacer(minLength: 12)
            Text("records").frame(width: Column.records, alignment: .trailing)
            Text("chunks").frame(width: Column.chunks, alignment: .trailing)
            Text("last read").frame(width: Column.state, alignment: .trailing)
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 🛑 THE BREAKAGE, WITHOUT OPENING A ROW. A source that cannot be read
    /// showed its reason only inside its own expanded row, so the one machine
    /// that needed the message was the one machine nobody had expanded.
    @ViewBuilder
    private var blocked: some View {
        let stuck = lines.filter { $0.readable == false }
        if !stuck.isEmpty {
            ForEach(stuck) { line in
                HStack(spacing: 10) {
                    Text(reason(for: line))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if let pane = line.permission?.pane,
                       let fragment = Grants.settingsFragment(for: pane) {
                        Button("Open Settings…") { Grants.openPane(fragment) }
                            .controlSize(.small)
                    } else if line.grantName == "Full Disk Access" {
                        Button("Open Settings…") {
                            Diagnostics.openFullDiskAccessPane()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.orange.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func reason(for line: SourceLine) -> String {
        if let permission = line.permission {
            return "\(line.tool): \(permission.status). "
                + "System Settings → \(permission.pane). "
                + "⚠️ A toggle is the only fix; no retry here can grant it."
        }
        return "\(line.tool) can be read by you but not by the indexing job — "
            + "Full Disk Access is missing for the app."
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
            out.append(SourceLine(
                tool: source.tool, stat: source,
                permission: permissions[source.tool],
                error: model.indexer.runs[source.tool]?.error,
                appFullDiskAccess: fullDiskAccessSources.contains(source.tool)
                    ? model.diagnostics.latest.appHasFullDiskAccess : nil))
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
        let folders = model.folders.entries.count
        return out.map { line in
            var copy = line
            if line.tool == "files" { copy.folderCount = folders }
            return copy
        }
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
            HStack(spacing: Column.gap) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: Column.caret)
                HStack(spacing: 7) {
                    Circle().fill(line.dot).frame(width: 6, height: 6)
                        .help(mark)
                    Text(line.tool).font(.body.weight(.medium))
                }
                .frame(width: Column.name, alignment: .leading)
                Text(line.note).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(line.stat.map { Format.count($0.records) } ?? "—")
                    .frame(width: Column.records, alignment: .trailing)
                Text(line.stat.map { Format.count($0.chunks) } ?? "—")
                    .frame(width: Column.chunks, alignment: .trailing)
                state.frame(width: Column.state, alignment: .trailing)
            }
            .font(.callout).monospacedDigit()
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .onTapGesture(perform: toggle)

            if expanded { detail }
            Divider().opacity(0.35)
        }
    }

    @ViewBuilder
    private var state: some View {
        if let error = line.error {
            Text("failing").font(.caption).foregroundStyle(.red).help(error)
        } else if line.readable == false {
            Text(line.permission?.status ?? "no access")
                .font(.caption).foregroundStyle(.orange)
        } else if let when = line.stat?.updated {
            Text(Format.ago(when)).font(.caption).foregroundStyle(.secondary)
        } else {
            Text("on demand").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var mark: String {
        if line.readable == false {
            return line.permission?.status
                ?? line.grantName.map { "needs \($0)" } ?? "no access"
        }
        if line.readable == true {
            return line.grantName.map { "readable, via \($0)" } ?? "readable"
        }
        return "no permission of its own"
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let permission = line.permission, !permission.usable,
               let advice = permission.advice {
                Note(advice)
            }
            if let error = line.error {
                Note(error, tint: .red)
            }
            // 🛑 The folder editor lives in the row it configures. `files` is
            // the one source whose contents are a decision rather than a store
            // at a fixed path.
            if line.tool == "files" {
                // 🛑 THE BREAKDOWN GOES INSIDE THE EDITOR FOR THIS SOURCE, and
                // nowhere else. A folder's contents belong under the folder,
                // and drawing them again in a flat list below would be the
                // same numbers twice, split differently — see `files_by_root`
                // in index.py for why the two disagree by design.
                FolderList(folders: folders, stat: line.stat)
            }
            // 🛑 THE HEADING AND THE FOOTNOTE DO NOT DEPEND ON A BREAKDOWN.
            // They used to sit inside `if !stat.containers.isEmpty`, so the
            // two sources that have no containers — `phone`, which is never
            // indexed, and `photos` when it cannot be read — opened onto
            // NOTHING AT ALL. An empty row under a caret reads as a fault in
            // the window rather than as the answer, which for both of those is
            // "there is nothing here, and here is why".
            // ⚠️ `files` draws its own heading inside FolderList, per folder.
            if line.tool != "files" {
                Text(heading).font(.caption2.weight(.semibold))
                    .kerning(0.7).foregroundStyle(.tertiary)
                if let stat = line.stat, !stat.containers.isEmpty {
                    breakdown(stat)
                }
            }
            // ⚠️ WHAT A RECORD IS, PER SOURCE. "40,473" and "12,904" are drawn
            // in the same column in the same font, and they count different
            // things: one email against a block of consecutive texts. Nothing
            // else on this window says so.
            if let footnote {
                Note(footnote)
            }
        }
        .padding(.leading, Column.caret + Column.gap)
        .padding(.top, 2).padding(.bottom, 10)
    }

    /// What one record of this source actually is, and the one caveat that
    /// changes how its number should be read.
    ///
    /// 🛑 EVERY LINE HERE IS A MEASURED FACT FROM `index.py`, not a
    /// description. The kinds are what each adapter emits: `mail` yields one
    /// `message` per email, `messages` yields one `conversation` per block,
    /// `maps` yields both a `place` and a `visit`, `photos` yields a `place`
    /// and a `day`.
    private var footnote: String? {
        switch line.tool {
        case "mail":
            return "A record is one email. Chunks are the pieces it was split "
                 + "into for searching, and they are what the index costs."
        case "messages":
            return "A record is a block of consecutive texts, not one message."
        case "calendar":
            return "A record is one event. An event dated in the future is "
                 + "indexed, but it is not contact."
        case "notes":
            return "A record is one note. A locked note is skipped."
        case "maps":
            return "Two kinds in one count: a place you have been, and each "
                 + "arrival at it."
        case "photos":
            // ⚠️ THE FAILURE, ONLY WHILE IT IS FAILING. Measured from a
            // launchd job, which has no Full Disk Access. Printing it on a
            // healthy machine would be a standing warning about nothing.
            if line.readable == false {
                return "The library stats fine and the sqlite open fails with "
                     + "`authorization denied`. That needs Full Disk Access "
                     + "for this app."
            }
            return "Two kinds in one count: a place, and a day a camera was "
                 + "somewhere. Never one photograph."
        case "contacts": return "A record is one card."
        case "reminders": return "A record is one reminder."
        case "phone":
            return "Call history on a Mac is a relay mirror of the iPhone and "
                 + "covers only recent months. It is read for the "
                 + "relationships report and never indexed."
        case "files":
            return "Every .md, .markdown, .txt, .docx, .pptx and .pdf, down "
                 + "through subfolders. Text over 2 MB is truncated. A "
                 + "scanned PDF has no text layer and cannot be indexed at "
                 + "all; nothing on this Mac does OCR."
        default: return nil
        }
    }

    /// 🛑 BY ACCOUNT, MAILBOX, LIST OR FOLDER. "40,473 emails" does not answer
    /// "what am I indexing"; "🌈/Archive 18,204" does.
    ///
    /// ⚠️ SCROLLS ONCE IT IS LONG. This vault has 60 folders, and expanding one
    /// row used to push the next four panels off the bottom of the window.
    @ViewBuilder
    private func breakdown(_ stat: SourceStat) -> some View {
        let list = VStack(alignment: .leading, spacing: 3) {
            ForEach(stat.containers) { part in
                HStack(spacing: Column.gap) {
                    Text(part.name)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    // ⚠️ BOTH NUMBERS, in the parent row's columns. Records
                    // alone cannot say why one folder costs more of the index
                    // than another: 199 files in Current Work are 4,779
                    // chunks, and 306 in Reading are 3,232.
                    Text(Format.count(part.records))
                        .frame(width: Column.records, alignment: .trailing)
                    Text(Format.count(part.chunks))
                        .frame(width: Column.chunks, alignment: .trailing)
                    Color.clear.frame(width: Column.state, height: 1)
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        if stat.containers.count > 12 {
            ScrollView { list.padding(.trailing, 8) }.frame(maxHeight: 220)
        } else {
            list
        }
        if line.tool == "files" {
            // ⚠️ SAY WHEN IT WAS CUT. The fold happens before the cut, so 60
            // rows means 60 top-level FOLDERS — and a vault with more than
            // that reported a short list with nothing on screen distinguishing
            // it from a complete one. Same class of bug as the silent
            // `--limit` in `apple maps`.
            if stat.containers.count >= 60 {
                Note("The 60 largest top-level folders. There are more.",
                     tint: .orange)
            }
            // 🛑 THE TOP LEVEL, NOT THE BIGGEST FOLDERS. `files` is the one
            // source whose container is a PATH rather than a flat name, so it
            // listed every subfolder separately, ordered by size — 49 rows
            // answering "which folder is biggest", which is not a question
            // anybody has. A folder now carries its own files and everything
            // under it.
            //
            // ⚠️ THAT IS WHY THESE ARE NOT NESTED UNDER THE FOLDERS ABOVE.
            // A record's container is its path RELATIVE to whichever root
            // holds it, with the root's own name where the file sits at the
            // top — so two roots with a `Reading` folder are already one row
            // here, and nothing in the stats output says which root a row came
            // from. Drawing these as children of a configured folder would
            // attribute somebody else's files to it.
            ExplainLabel("Top-level folders, across every indexed folder",
                         "How a folder is counted", """
                         One row per top-level folder in each indexed folder, \
                         carrying its own files and everything in its \
                         subfolders.

                         Records are files. Chunks are the pieces they were \
                         split into for searching, and they are what the index \
                         costs — a folder of long documents can hold fewer \
                         files than another and far more of the index.

                         ⚠️ A file sitting directly in an indexed folder is \
                         filed under that folder's own name. Two indexed \
                         folders that each contain a folder of the same name \
                         are one row here.
                         """)
        } else if stat.containers.count >= 60 {
            Note("The 60 largest.")
        }
    }

    private var heading: String {
        // ⚠️ TWO SOURCES HAVE NOTHING TO BREAK DOWN, and each is a different
        // kind of nothing. `phone` is read on demand and never indexed;
        // `photos` that cannot be read has no records at all.
        if line.tool == "phone" { return "Read for the relationships report only" }
        if line.stat == nil || line.stat?.containers.isEmpty == true {
            return line.readable == false ? "Nothing read" : "Nothing indexed yet"
        }
        switch line.tool {
        case "mail":     return "By account and mailbox"
        case "messages": return "By conversation"
        case "calendar": return "By calendar"
        case "files":    return "By folder"
        case "maps":     return "By category"
        default:         return "By account"
        }
    }
}

// MARK: - the folders the `files` source reads

private struct FolderList: View {
    @ObservedObject var folders: Folders
    /// ⚠️ Optional, because the window draws before the first `stats` returns
    /// and a configured folder is real whether or not it has been indexed yet.
    let stat: SourceStat?

    private func root(named name: String) -> RootStat? {
        stat?.roots.first { $0.name == name }
    }

    /// 🛑 EVERY ROOT IN THE INDEX THAT IS NO LONGER A CONFIGURED FOLDER.
    /// Removing a folder does NOT remove its records — indexing only ever
    /// adds — so those records keep costing index space with nothing on the
    /// window to say they are there. They used to vanish from this panel the
    /// moment the folder was removed, which read as "gone".
    private var orphans: [RootStat] {
        let configured = Set(folders.entries.map(\.name))
        return (stat?.roots ?? []).filter { !configured.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Indexed folders").font(.caption2.weight(.semibold))
                .kerning(0.7).foregroundStyle(.tertiary)
            ForEach(folders.entries) { folder in
                VStack(alignment: .leading, spacing: 3) {
                    header(folder)
                    if let root = root(named: folder.name) {
                        summary(root)
                        contents(root)
                    } else if folder.present {
                        Text("not indexed yet")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.leading, Indent.body)
                    }
                }
                .padding(.bottom, 4)
            }
            if !orphans.isEmpty {
                orphaned
            }
            controls
            if let failure = folders.failure {
                Note(failure, tint: .red)
            }
        }
        .padding(.bottom, 6)
    }

    private enum Indent {
        /// Clears the icon and its gap, so a child row starts under the name.
        static let body: CGFloat = 26
    }

    // MARK: one configured folder

    @ViewBuilder
    private func header(_ folder: IndexedFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: folder.kind == "obsidian"
                  ? "book.closed" : "folder")
                .foregroundStyle(folder.kind == "obsidian"
                                 ? Color.accentColor : Color.secondary)
                .help(folder.kind == "obsidian" ? "Obsidian vault"
                                                : "Plain folder")
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
            Spacer(minLength: 12)
            // ⚠️ THE PARENT ROW'S COLUMNS, so a folder's total sits directly
            // under the source's total and the two can be read against each
            // other. Blank rather than zero when nothing has been indexed.
            if let root = root(named: folder.name) {
                Text(Format.count(root.records))
                    .frame(width: Column.records, alignment: .trailing)
                Text(Format.count(root.chunks))
                    .frame(width: Column.chunks, alignment: .trailing)
            } else {
                Color.clear.frame(width: Column.records + Column.chunks,
                                  height: 1)
            }
            // 🛑 THE STATE COLUMN'S WIDTH, not the button's own. Without the
            // frame the button sized itself and pushed this row's two numbers
            // 44px right of the source row's, so a folder's total no longer
            // sat under the source total it is part of.
            Button("Remove") { folders.remove(folder) }
                .controlSize(.small)
                .help("Stop indexing this folder")
                .frame(width: Column.state, alignment: .trailing)
        }
        .font(.caption).monospacedDigit()
    }

    /// What is actually in there, by format.
    ///
    /// 🛑 THE COUNTS ARE RECORDS, AND A RECORD IS A FILE HERE. It is worth
    /// saying because the same column means something different on every other
    /// source — one email, a block of ten texts, one event.
    @ViewBuilder
    private func summary(_ root: RootStat) -> some View {
        let parts = root.kinds
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\(Format.count($0.value)) \(Self.label($0.key, $0.value))" }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, Indent.body)
        }
    }

    /// ⚠️ THE LABEL IS WHAT THE USER CALLS IT, not the `kind` the adapter
    /// emits. `docx` is a file extension; "Word" is the thing on the screen.
    private static func label(_ kind: String, _ count: Int) -> String {
        switch kind {
        case "note":  return count == 1 ? "note" : "notes"
        case "file":  return count == 1 ? "text file" : "text files"
        case "pdf":   return "PDF"
        case "docx":  return "Word"
        case "pptx":  return "PowerPoint"
        default:      return kind
        }
    }

    /// The top-level folders inside one configured folder.
    ///
    /// 🛑 THE TOP LEVEL, NOT THE BIGGEST FOLDERS. `files` is the one source
    /// whose container is a PATH rather than a flat name, so it once listed
    /// every subfolder separately, ordered by size — an answer to "which
    /// folder is biggest", which is nobody's question. A folder carries its
    /// own files and everything under it.
    @ViewBuilder
    private func contents(_ root: RootStat) -> some View {
        // ⚠️ A FOLDER WITH NOTHING BUT LOOSE FILES NEEDS NO CHILD ROW. Its one
        // row would repeat the folder's own totals verbatim, which reads as
        // two facts and is one.
        let onlyLoose = root.containers.count == 1
            && root.containers[0].name.isEmpty
        VStack(alignment: .leading, spacing: 3) {
            ForEach(onlyLoose ? [] : root.containers) { part in
                HStack(spacing: Column.gap) {
                    // 🛑 AN EMPTY NAME IS THE FOLDER'S OWN LOOSE FILES, and it
                    // is a real row. It used to be filed under the folder's
                    // NAME, which collided with a subfolder that happened to
                    // share it — indistinguishable once you had only the
                    // container. The uid tells them apart. See index.py.
                    Text(part.name.isEmpty ? "files at the top level" : part.name)
                        .font(.system(.caption, design: .monospaced))
                        .italic(part.name.isEmpty)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    // ⚠️ BOTH NUMBERS. Records alone cannot say why one folder
                    // costs more of the index than another: 225 files in
                    // Current Work are 5,483 chunks, and 306 in Reading are
                    // 3,232.
                    Text(Format.count(part.records))
                        .frame(width: Column.records, alignment: .trailing)
                    Text(Format.count(part.chunks))
                        .frame(width: Column.chunks, alignment: .trailing)
                    Color.clear.frame(width: Column.state, height: 1)
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if root.truncated {
                // ⚠️ SAY WHEN IT WAS CUT. The fold happens before the cut, so a
                // hidden row is a whole top-level folder — and a short list
                // used to look exactly like a complete one.
                Note("The 60 largest folders in here. There are more.",
                     tint: .orange)
            }
        }
        .padding(.leading, Indent.body)
    }

    // MARK: records from folders that are no longer configured

    @ViewBuilder
    private var orphaned: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Still in the index, no longer indexed")
                .font(.caption2.weight(.semibold))
                .kerning(0.7).foregroundStyle(.tertiary)
            ForEach(orphans) { root in
                HStack(spacing: Column.gap) {
                    Image(systemName: "folder.badge.minus")
                        .foregroundStyle(.orange)
                    Text(root.name).font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(Format.count(root.records))
                        .frame(width: Column.records, alignment: .trailing)
                    Text(Format.count(root.chunks))
                        .frame(width: Column.chunks, alignment: .trailing)
                    Color.clear.frame(width: Column.state, height: 1)
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Note("Removing a folder does not remove what it already put in "
                 + "the index. These go when the files source is rebuilt in "
                 + "full.")
        }
        .padding(.bottom, 4)
    }

    // MARK: add, and the half nobody expects

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            Button("Add Folder…") { folders.choose() }
                .controlSize(.small)
                .disabled(folders.busy)
            // ⚠️ WHAT IS READ IS NOW ON THE PAGE, in this row's footnote.
            // This button keeps the half nobody expects: what pressing it
            // does NOT do.
            Explain("What adding and removing a folder do", """
                    An Obsidian vault is recognised and its .obsidian \
                    folder skipped, along with .git, node_modules and any \
                    Attachments folder.

                    🛑 Adding a folder does not index it — the next run \
                    does. Removing one does not remove what it already \
                    put in the index, because indexing only ever adds. \
                    Those records go when the files source is rebuilt in \
                    full.
                    """)
            if let note = folders.lastAction {
                Note(note)
            }
            Spacer()
            ExplainLabel("Top-level folders inside each indexed folder",
                         "How a folder is counted", """
                         One row per top-level folder, carrying its own files \
                         and everything in its subfolders.

                         Records are files. Chunks are the pieces they were \
                         split into for searching, and they are what the index \
                         costs — a folder of long documents can hold fewer \
                         files than another and far more of the index.

                         ⚠️ A file sitting directly in an indexed folder gets \
                         its own row, "files at the top level". It is NOT \
                         merged with a subfolder that happens to share the \
                         indexed folder's name.
                         """)
        }
    }
}

// MARK: - 2. how is it growing, and what does it cost

struct IndexSize: View {
    @ObservedObject var model: AppModel
    @AppStorage("growthByTool") private var byTool = true
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            growth
            storage
        }
    }

    // MARK: growth

    private var growth: some View {
        PaneSection("Growth", trailing: {
            HStack(spacing: 10) {
                Explain("Where the early history comes from", """
                        A point is recorded on every indexing run. Points from \
                        before this app existed are derived from when each \
                        record was last written, so the early part of the \
                        curve is an approximation rather than a measurement.

                        Chunks, not records: a chunk is what costs storage and \
                        what gets embedded. The areas are stacked, so they add \
                        up to the total.
                        """)
                Picker("", selection: $byTool) {
                    Text("Total").tag(false)
                    Text("By source").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                chart
                sidebar.frame(width: 226)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 6) {
            if stats.history.count < 2 {
                Note("Not enough history yet. A point is recorded on every "
                     + "indexing run.")
                    .frame(height: 210, alignment: .top)
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
                Chart {
                    ForEach(stats.totals, id: \.0) { day, chunks in
                        AreaMark(x: .value("day", day), y: .value("chunks", chunks),
                                 series: .value("series", "measured"))
                            .foregroundStyle(.tint.opacity(0.22))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("day", day), y: .value("chunks", chunks),
                                 series: .value("series", "measured"))
                            .foregroundStyle(.tint)
                            .interpolationMethod(.monotone)
                    }
                    // ⚠️ DASHED, AND ONLY IN THE TOTAL VIEW. It is arithmetic
                    // on the last 30 days, not a measurement, and a solid line
                    // would read as one. It cannot be drawn over the stacked
                    // chart at all: a projection has no source to belong to.
                    if let ahead = projection {
                        ForEach(ahead.line, id: \.0) { day, chunks in
                            LineMark(x: .value("day", day),
                                     y: .value("chunks", chunks),
                                     series: .value("series", "projected"))
                                .foregroundStyle(.tint.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        }
                    }
                }
                .chartYAxisLabel("chunks")
                .frame(height: 210)
                // ⚠️ TOP LEADING, NOT TRAILING. Swift Charts puts the value
                // axis on the trailing edge, so an annotation in that corner
                // is drawn straight through "2,000,000".
                .overlay(alignment: .topLeading) {
                    if let ahead = projection {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("≈ \(Format.bytes(ahead.bytes)) by \(ahead.when)")
                                .font(.caption)
                            Text("at the last 30 days' rate")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        let stats = model.stats
        return VStack(alignment: .leading, spacing: 14) {
            // ⚠️ A 2×2 GRID, NOT A ROW. Beside a chart there is no width for
            // four statistics in a line, and wrapping them silently put "to
            // embed" on its own where it reads as a heading.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Stat("chunks", Format.count(stats.chunks))
                    Stat("embedded", Format.count(stats.vectors))
                }
                GridRow {
                    Stat("on disk", Format.bytes(stats.bytes))
                    // 🛑 ALWAYS DRAWN, and grey at zero. It used to appear only
                    // with a backlog, so the grid changed shape between two
                    // refreshes a minute apart.
                    Stat("to embed", Format.count(stats.backlog),
                         tint: stats.backlog > 0 ? .orange : nil)
                }
            }
            if !quiet.isEmpty {
                Divider()
                // 🛑 A SOURCE FAILING FOR A WEEK LOOKS EXACTLY LIKE A QUIET
                // ONE. Every source is read on every five-minute cycle, so a
                // last-read date measured in days is not a calm store — it is
                // a read that has not succeeded since then.
                HStack(spacing: 6) {
                    Text("GONE QUIET").font(.caption2.weight(.semibold))
                        .kerning(0.7).foregroundStyle(.tertiary)
                    Explain("What this list means", """
                            Every source is read on every indexing run, so a \
                            source that was last read days ago is not a store \
                            with nothing new in it. It is a read that has not \
                            succeeded since then.

                            A grant that was revoked, a store that moved, or a \
                            helper that is failing all look like this. Open \
                            the Sources pane and expand the row to see what it \
                            said.
                            """)
                }
                ForEach(quiet, id: \.tool) { source in
                    HStack {
                        Text(source.tool).font(.callout)
                        Spacer()
                        Text(source.updated.map(Format.ago) ?? "never")
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(source.stale ? Color.orange
                                                          : Color.secondary)
                    }
                }
            }
        }
    }

    /// Sources whose last successful read is older than a day, oldest first.
    /// ⚠️ A source with no `updated` at all has never been read and is not
    /// listed here — it has no row in the stats output either.
    private var quiet: [(tool: String, updated: Date?, stale: Bool)] {
        let day: TimeInterval = 86_400
        return model.stats.sources.compactMap { source -> (String, Date?, Bool)? in
            guard let updated = source.updated,
                  Date().timeIntervalSince(updated) > day else { return nil }
            return (source.tool, updated,
                    Date().timeIntervalSince(updated) > 7 * day)
        }
        .sorted { ($0.1 ?? .distantPast) < ($1.1 ?? .distantPast) }
        .prefix(5)
        .map { (tool: $0.0, updated: $0.1, stale: $0.2) }
    }

    /// Where the index lands six months out, at the rate of the last 30 days.
    ///
    /// 🛑 ARITHMETIC, NOT A FORECAST, and it says so on the page. It is the
    /// answer to "is this going to eat my disk", which a curve alone does not
    /// give: 1.2 GB is unremarkable and 1.2 GB growing at 40 MB a week is not.
    ///
    /// ⚠️ NOTHING IS DRAWN unless there are 14 days of history to take a rate
    /// from and the rate is positive. A projection off three days of history
    /// is a number with an error bar wider than itself, and a downward one
    /// would claim the index is about to shrink, which it never does — the
    /// ingest only ever adds.
    private var projection: (line: [(Date, Int)], bytes: Int, when: String)? {
        let totals = model.stats.totals
        guard let last = totals.last, model.stats.chunks > 0,
              model.stats.bytes > 0 else { return nil }
        let window = last.0.addingTimeInterval(-30 * 86_400)
        guard let first = totals.first(where: { $0.0 >= window }) ?? totals.first
            else { return nil }
        let days = last.0.timeIntervalSince(first.0) / 86_400
        guard days >= 14 else { return nil }
        let rate = Double(last.1 - first.1) / days
        guard rate > 0 else { return nil }
        let ahead = 182.0
        let target = last.1 + Int(rate * ahead)
        // 🛑 A RATE THAT PROJECTS A DOUBLING IS THE FIRST INGEST, NOT A TREND.
        // Measured on a two-day window during development: the line reached
        // 2,000,000 chunks, the whole measured curve was flattened into a
        // sliver at the baseline, and the chart stopped answering the question
        // it exists for. The index only ever appends, so 30 days that added as
        // much as the previous years is a backfill finishing, and extending it
        // six months is arithmetic on a transient.
        guard target < 2 * last.1 else { return nil }
        let when = last.0.addingTimeInterval(ahead * 86_400)
        let perChunk = Double(model.stats.bytes) / Double(model.stats.chunks)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return ([(last.0, last.1), (when, target)],
                Int(Double(target) * perChunk),
                formatter.string(from: when))
    }

    // MARK: storage

    private var storage: some View {
        PaneSection("Storage") {
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

// MARK: - the search endpoint and the proxy switch

struct Advanced: View {
    @ObservedObject var model: AppModel
    @AppStorage("toolProxy") private var proxy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            PaneSection("Search endpoint") {
                HStack {
                    Text("State").frame(width: 150, alignment: .leading)
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
            }

            PaneSection("Permission proxy") {
                HStack(spacing: 8) {
                    Toggle("Let terminals use this app's permissions", isOn: $proxy)
                        .onChange(of: proxy) { _, _ in model.toolProxy.apply() }
                    Explain("What this switch gives away", """
                            With this on, the app reads your mail, messages, \
                            notes, calendar and contacts on behalf of any \
                            program running as you, with no prompt.

                            🛑 Only a signed AppleTools client is accepted. \
                            That stops a program speaking the protocol \
                            directly. It does not stop one from running that \
                            client, so treat this as granting every process \
                            running as you the access this app holds.

                            Every proxied command is written to the log.
                            """)
                    Spacer()
                }
                // ⚠️ ONE LINE, AND ONLY WHILE IT IS ON. The paragraph used to
                // sit here in orange whether the switch was on or off, which
                // is how a real warning gets read as decoration.
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
}

// MARK: - onboarding

struct Onboarding: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This app cannot read your data yet")
                .font(.headline).foregroundStyle(.orange)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 11))
    }
}

// MARK: - small pieces

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

/// ⚠️ NOT `private`: `PlacesView.swift` and `PeopleView.swift` say the same
/// kinds of things and a second copy would drift.
struct Note: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
