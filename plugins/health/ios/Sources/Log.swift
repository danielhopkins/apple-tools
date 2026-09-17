// What happened, kept where both halves can read it.
//
// A shortcut cannot say why it produced nothing, and that is the whole
// reason this app exists. Every run appends lines here: what was asked,
// how many rows came back, what was written where, and every error by
// name. The list is shown in the app and mirrored to `log.txt` in the
// iCloud container, so `apple health log` on the Mac shows the same lines.

import Foundation

@MainActor
final class Log: ObservableObject {
    struct Line: Identifiable, Codable {
        let id: UUID
        let when: Date
        let text: String
        let error: Bool
    }

    @Published private(set) var lines: [Line] = []
    private let local: URL
    private var mirror: URL? { Store.container()?.appendingPathComponent("log.txt") }

    static let shared = Log()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        local = support.appendingPathComponent("log.json")
        if let data = try? Data(contentsOf: local),
           let saved = try? JSONDecoder().decode([Line].self, from: data) {
            lines = saved
        }
    }

    func add(_ text: String, error: Bool = false) {
        let line = Line(id: UUID(), when: Date(), text: text, error: error)
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        if let data = try? JSONEncoder().encode(lines) {
            try? data.write(to: local, options: .atomic)
        }
        // The mirror is append-only text; a failure to write it is itself
        // worth a line, but never a loop.
        if let mirror = mirror {
            let stamp = Format.dates.string(from: line.when)
            let row = "\(stamp)\t\(error ? "error" : "info")\t\(text)\n"
            if let handle = try? FileHandle(forWritingTo: mirror) {
                handle.seekToEndOfFile()
                handle.write(row.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? row.data(using: .utf8)!.write(to: mirror)
            }
        }
    }

    func clear() {
        lines = []
        try? FileManager.default.removeItem(at: local)
    }
}

/// Where the files go: the app's own iCloud container, `Documents/health`.
/// ⚠️ `url(forUbiquityContainerIdentifier:)` can take a moment on first
/// launch and returns nil when iCloud Drive is off for the app; both are
/// logged rather than crashed on.
enum Store {
    static let containerID = "iCloud.com.boulderhopkins.apple-tools.health"

    static func container() -> URL? {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
            return nil
        }
        let dir = root.appendingPathComponent("Documents").appendingPathComponent("health")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
