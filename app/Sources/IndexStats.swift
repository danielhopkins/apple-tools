// What the window shows, read in one call.
//
// ⚠️ ONE SUBPROCESS PER REFRESH, not five. `index.py stats` returns the
// sources, their containers, the growth history and the model in a single
// JSON document. The window refreshes on a timer, and five python starts per
// tick is five python starts per tick.

import Foundation

struct Container: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let records: Int
    let chunks: Int
}

struct SourceStat: Identifiable, Equatable {
    var id: String { tool }
    let tool: String
    let records: Int
    let chunks: Int
    let updated: Date?
    let containers: [Container]
}

struct HistoryPoint: Identifiable, Equatable {
    var id: String { "\(tool)-\(date.timeIntervalSince1970)" }
    let date: Date
    let tool: String
    let records: Int
    let chunks: Int
}

struct IndexStats: Equatable {
    var version = ""
    var path = ""
    var encrypted = false
    var bytes = 0
    var chunks = 0
    var models: [(String, Int)] = []
    var sources: [SourceStat] = []
    var history: [HistoryPoint] = []
    var loaded = false
    var error: String? = nil

    static func == (a: IndexStats, b: IndexStats) -> Bool {
        a.version == b.version && a.bytes == b.bytes && a.chunks == b.chunks
            && a.sources == b.sources && a.history.count == b.history.count
            && a.error == b.error && a.encrypted == b.encrypted
    }

    /// 🛑 Rows under more than one model name is the failure that returns
    /// confident nonsense: two vector spaces ranked against one query.
    var mixedModels: Bool { models.filter { $0.1 > 0 }.count > 1 }
    var vectors: Int { models.map(\.1).max() ?? 0 }
    var backlog: Int { max(0, chunks - vectors) }

    /// The whole index over time, in chunks. ⚠️ Chunks, not records: a chunk is
    /// what costs storage and what gets embedded.
    var totals: [(Date, Int)] {
        Dictionary(grouping: history, by: \.date)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.chunks }) }
            .sorted { $0.0 < $1.0 }
    }

    var toolsInHistory: [String] {
        Array(Set(history.map(\.tool))).sorted()
    }
}

enum StatsReader {
    static func read() -> IndexStats {
        var stats = IndexStats()
        guard let script = Paths.indexScript else {
            stats.error = "no index.py found"
            return stats
        }
        let result = Child.run(Paths.python,
                               [script.path, "--db", Paths.database.path, "stats"],
                               timeout: 120)
        guard result.ok, let data = result.out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            // ⚠️ The last stderr line, because a traceback's first line names
            // the file rather than the failure.
            stats.error = result.err.split(separator: "\n").last.map(String.init)
                ?? "stats failed (exit \(result.status))"
            return stats
        }

        stats.version = root["version"] as? String ?? ""
        stats.path = root["db"] as? String ?? ""
        stats.encrypted = root["encrypted"] as? Bool ?? false
        stats.bytes = root["bytes"] as? Int ?? 0
        stats.chunks = root["chunks"] as? Int ?? 0
        stats.models = (root["models"] as? [[String: Any]] ?? []).map {
            ($0["model"] as? String ?? "?", $0["vectors"] as? Int ?? 0)
        }
        stats.sources = (root["sources"] as? [[String: Any]] ?? []).map { entry in
            SourceStat(
                tool: entry["tool"] as? String ?? "?",
                records: entry["records"] as? Int ?? 0,
                chunks: entry["chunks"] as? Int ?? 0,
                updated: (entry["updated"] as? Double).map(Date.init(timeIntervalSince1970:)),
                containers: (entry["containers"] as? [[String: Any]] ?? []).map {
                    Container(name: $0["name"] as? String ?? "?",
                              records: $0["records"] as? Int ?? 0,
                              chunks: $0["chunks"] as? Int ?? 0)
                })
        }
        stats.history = (root["history"] as? [[String: Any]] ?? []).compactMap {
            guard let ts = $0["ts"] as? Double else { return nil }
            return HistoryPoint(date: Date(timeIntervalSince1970: ts),
                                tool: $0["tool"] as? String ?? "?",
                                records: $0["records"] as? Int ?? 0,
                                chunks: $0["chunks"] as? Int ?? 0)
        }
        stats.loaded = true
        return stats
    }
}
