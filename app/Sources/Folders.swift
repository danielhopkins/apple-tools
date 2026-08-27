// The folders the `files` source indexes.
//
// 🛑 ROOTS ARE CONFIGURED, NEVER GUESSED. Every other source reads a store at a
// known path. This one reads whatever the user names, so a wrong entry is not a
// bug — it is 40,000 files of somebody's Downloads folder in the index.
//
// ⚠️ ADDING A FOLDER DOES NOT INDEX IT, AND REMOVING ONE DOES NOT UNINDEX IT.
// The next cycle picks up an addition. A removal leaves every record already
// written, because `ingest` only ever adds; the records go on the next FULL
// rebuild of that source. Both facts are on screen, because neither is
// guessable from the button that was pressed.

import Foundation
import AppKit

struct IndexedFolder: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let kind: String       // "obsidian" or "folder"
    let present: Bool
    let exclude: [String]

    var display: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

@MainActor
final class Folders: ObservableObject {
    @Published private(set) var entries: [IndexedFolder] = []
    @Published private(set) var busy = false
    @Published private(set) var failure: String? = nil
    /// Set by an add or a remove, cleared by the next one. It says what the
    /// press did NOT do, which is the half nobody expects.
    @Published var lastAction: String? = nil

    func read() {
        run(["files", "--json"]) { [weak self] root in
            guard let self else { return }
            self.entries = (root["roots"] as? [[String: Any]] ?? []).compactMap {
                guard let path = $0["path"] as? String else { return nil }
                return IndexedFolder(
                    path: path,
                    name: $0["name"] as? String ?? path,
                    kind: $0["kind"] as? String ?? "folder",
                    present: $0["present"] as? Bool ?? false,
                    exclude: $0["exclude"] as? [String] ?? [])
            }
        }
    }

    /// ⚠️ `NSOpenPanel`, so the user names the folder themselves. This app can
    /// read every file on the disk, so a typed path is a path nobody checked.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index This Folder"
        panel.message = "Text and Markdown files in this folder are added to the index."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        add(chosen)
    }

    func add(_ folder: URL) {
        run(["files", "add", folder.path, "--json"]) { [weak self] root in
            guard let self else { return }
            if root["already"] as? Bool == true {
                self.lastAction = "Already in the list."
            } else {
                self.lastAction = "Added. It is read on the next indexing run."
            }
        } then: { [weak self] in self?.read() }
    }

    func remove(_ folder: IndexedFolder) {
        run(["files", "remove", folder.path, "--json"]) { [weak self] _ in
            // 🛑 SAY WHAT STAYS. `ingest` only adds, so the records written
            // from this folder survive until the source is rebuilt in full.
            self?.lastAction = "Removed from the list. What it already put in "
                + "the index stays until the files source is rebuilt in full."
        } then: { [weak self] in self?.read() }
    }

    private func run(_ arguments: [String],
                     _ handle: @escaping ([String: Any]) -> Void,
                     then after: (() -> Void)? = nil) {
        guard let script = Paths.indexScript else {
            failure = "no index.py found"
            return
        }
        busy = true
        let python = Paths.python
        let database = Paths.database.path
        Task.detached(priority: .userInitiated) {
            let result = Child.run(python,
                                   [script.path, "--db", database] + arguments,
                                   timeout: 60)
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
                after?()
            }
        }
    }
}
