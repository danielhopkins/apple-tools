// The Search pane: one field, the same search the CLI runs, the hits.
//
// It exists to answer "did it index that?" without a terminal. The app holds
// the index and the grant, so it is the one place a search is always
// possible; the daemon it starts is what makes one take 70–300 ms.
//
// 🛑 THIS IS `apple-index search --json`, NOT A SECOND RANKER. The daemon on
// the socket serves the vector half only (chunk ids and scores); the FTS
// half, the fusion and the record lookup live in index.py. Running the
// command is what keeps the window and the CLI returning the same list in
// the same order, which is the whole point of a window that checks the index.
//
// ⚠️ A hit is an id, and the record is read through the `apple` tool. Mail,
// contacts, files and a plugin's places carry a deep link and open on a
// click; a note gets its `applenotes://` link on demand; the rest show the
// command that reads them, copyable. Nothing here shows a body: the index
// holds the plaintext of every email, and the window must not become a
// second reader of it.

import AppKit
import SwiftUI

struct SearchHit: Identifiable, Equatable {
    let uid: String
    let tool: String
    let kind: String
    let recordID: String
    let url: String?
    let title: String
    let container: String?
    let date: Date?
    let snippet: String
    let lexical: Bool
    let semantic: Bool

    var id: String { uid }

    /// The CLI line that reads this record, for a hit with no link.
    var command: String {
        switch tool {
        case "notes":     return "apple notes export \(recordID)"
        case "mail":      return "apple mail export '\(recordID)'"
        case "messages":  return "apple messages export \(recordID)"
        case "calendar":  return "apple calendar show '\(recordID)'"
        case "contacts":  return "apple contacts get '\(recordID)'"
        case "reminders": return "apple reminders show-all --json"
        case "maps":      return "apple maps places --search '\(title.replacingOccurrences(of: "'", with: ""))' --json"
        case "photos":    return "apple-index search '\(title.replacingOccurrences(of: "'", with: ""))' --tool photos --json"
        case "health":    return kind == "workout" ? "apple health workouts --json" : "apple health days --json"
        default:          return "apple-index search --tool \(tool) --json"
        }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var since: Int = 0            // days; 0 = any time
    @Published var tool: String = ""         // "" = every source
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String? = nil
    @Published private(set) var seconds: Double = 0
    @Published private(set) var ran: String? = nil   // the query the hits answer

    static let tools = ["", "mail", "messages", "notes", "calendar", "contacts", "reminders",
                        "maps", "photos", "files", "dawarich", "health"]

    func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        guard let script = Paths.indexScript else {
            error = "no index.py found"
            return
        }
        busy = true
        error = nil
        var args = [script.path, "--db", Paths.database.path, "search", q, "--json", "--limit", "40"]
        if since > 0 { args += ["--since", String(since)] }
        if !tool.isEmpty { args += ["--tool", tool] }
        let arguments = args
        Task.detached(priority: .userInitiated) {
            let result = Child.run(Paths.python, arguments, timeout: 60)
            let parsed = SearchModel.parse(result)
            await MainActor.run {
                self.busy = false
                self.seconds = result.seconds
                self.ran = q
                switch parsed {
                case .success(let hits): self.hits = hits; self.error = nil
                case .failure(let message): self.hits = []; self.error = message
                }
            }
        }
    }

    private enum Parsed { case success([SearchHit]); case failure(String) }

    nonisolated private static func parse(_ result: ChildResult) -> Parsed {
        guard result.ok else {
            return .failure(result.err.split(separator: "\n").last.map(String.init)
                            ?? "search failed (exit \(result.status))")
        }
        guard let data = result.out.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure("search returned something that is not JSON")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return .success(rows.compactMap { row in
            guard let uid = row["uid"] as? String else { return nil }
            let date = (row["date"] as? String).flatMap { iso.date(from: $0) }
            return SearchHit(
                uid: uid,
                tool: row["tool"] as? String ?? "?",
                kind: row["kind"] as? String ?? "",
                recordID: (row["id"] as? String) ?? String(describing: row["id"] ?? ""),
                url: (row["url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                title: row["title"] as? String ?? "",
                container: row["container"] as? String,
                date: date,
                snippet: row["snippet"] as? String ?? "",
                lexical: row["lexical"] as? Bool ?? false,
                semantic: row["semantic"] as? Bool ?? false)
        })
    }

    /// Open the record. A link opens directly; a note asks `apple notes
    /// get-url` for its `applenotes://` link first, because the index does
    /// not store one yet (docs/todo-deep-links.md).
    func open(_ hit: SearchHit) {
        if let url = hit.url.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
            return
        }
        if hit.tool == "notes" {
            Task.detached(priority: .userInitiated) {
                let result = Child.apple(["notes", "get-url", hit.recordID, "--json"], timeout: 20)
                if result.ok, let data = result.out.data(using: .utf8),
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let link = root["url"] as? String, let url = URL(string: link) {
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    func copyCommand(_ hit: SearchHit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.command, forType: .string)
    }
}

struct SearchPane: View {
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Search everything indexed…", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.run() }
                Picker("", selection: $model.since) {
                    Text("any time").tag(0)
                    Text("30 days").tag(30)
                    Text("a year").tag(365)
                }
                .labelsHidden()
                .frame(width: 100)
                Picker("", selection: $model.tool) {
                    ForEach(SearchModel.tools, id: \.self) { t in
                        Text(t.isEmpty ? "all sources" : t).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                Button("Search") { model.run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) }
            } else if let error = model.error {
                Note(error, tint: .red)
            } else if let ran = model.ran {
                if model.hits.isEmpty {
                    Text("Nothing for “\(ran)”.").foregroundStyle(.secondary)
                    Note("The index searches words and meaning, but a visit or a day has no words for a date. For where you were, ask `apple-index whereabouts`; for health figures, `apple health days`.")
                } else {
                    Text("\(model.hits.count) hits for “\(ran)” in \(String(format: "%.2f", model.seconds)) s. The same list as `apple-index search`.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.hits) { hit in
                            HitRow(hit: hit, model: model)
                            Divider()
                        }
                    }
                }
            } else {
                Note("One query across mail, messages, notes, calendar, contacts, reminders, places, photos, your files and every enabled plugin. Words and meaning both: “fundraising” finds a note about a Director of Development.")
            }
        }
        .onAppear { focused = true }
    }
}

private struct HitRow: View {
    let hit: SearchHit
    @ObservedObject var model: SearchModel
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(hit.tool)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(hit.title.isEmpty ? "(untitled)" : hit.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let date = hit.date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let container = hit.container, !container.isEmpty {
                        Text(container).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    // Which half matched. Both is the strongest signal the
                    // ranker has; one alone says how it was found.
                    Text(hit.lexical && hit.semantic ? "words + meaning" : hit.lexical ? "words" : "meaning")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    if hit.url != nil || hit.tool == "notes" {
                        Button("Open") { model.open(hit) }
                            .buttonStyle(.link).font(.caption)
                    }
                    Button("Copy command") { model.copyCommand(hit) }
                        .buttonStyle(.link).font(.caption)
                        .help(hit.command)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(hit) }
    }
}
