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

/// One configured folder of the `files` source, with the folders inside it.
///
/// 🛑 `files` IS THE ONLY SOURCE WITH TWO LEVELS. Every other one files a
/// record under one flat name — an account, a mailbox, a calendar, a list. A
/// file is filed under a path inside a folder the user chose, so its breakdown
/// nests and no other source's does.
struct RootStat: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let records: Int
    let chunks: Int
    /// How many records of each `kind`: `note`, `file`, `pdf`, `docx`, `pptx`.
    let kinds: [String: Int]
    let containers: [Container]
    /// ⚠️ Set when this root has more top-level folders than were sent. The cut
    /// happens per root and AFTER the fold, so a hidden row is a whole missing
    /// folder rather than a number that is quietly short.
    let truncated: Bool
}

struct SourceStat: Identifiable, Equatable {
    var id: String { tool }
    let tool: String
    let records: Int
    let chunks: Int
    let updated: Date?
    let containers: [Container]
    /// `files` only, and empty for every other source.
    let roots: [RootStat]
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
    /// The model actually in use, from `apple-index model`. ⚠️ NOT the same
    /// question as `models`, which counts vectors per name. Only this says
    /// which vector space a search is about to use.
    var model = ""
    var modelEmbedded = 0
    /// The model a switch is moving to, while one is running.
    var switchingTo: String? = nil
    var sources: [SourceStat] = []
    var history: [HistoryPoint] = []
    var loaded = false
    var error: String? = nil

    static func == (a: IndexStats, b: IndexStats) -> Bool {
        a.version == b.version && a.bytes == b.bytes && a.chunks == b.chunks
            && a.sources == b.sources && a.history.count == b.history.count
            && a.error == b.error && a.encrypted == b.encrypted
            && a.model == b.model && a.switchingTo == b.switchingTo
            && a.modelEmbedded == b.modelEmbedded
    }

    /// 🛑 Rows under more than one model name is the failure that returns
    /// confident nonsense: two vector spaces ranked against one query.
    ///
    /// 🛑 EXCEPT DURING A SWITCH, WHICH HOLDS TWO SETS ON PURPOSE. A switch
    /// embeds the new model's vectors BEFORE deleting the old ones, so the
    /// old set keeps answering searches for the whole window and a failure
    /// leaves the working model intact. The database cannot tell that from a
    /// genuine mix — both are simply two names with rows. `switchingTo` is
    /// the only thing that separates them, which is why the model config
    /// carries switch state rather than just a name.
    var mixedModels: Bool {
        switchingTo == nil && models.filter { $0.1 > 0 }.count > 1
    }
    var isSwitching: Bool { switchingTo != nil }
    /// How far a switch has got. ⚠️ Counts the TARGET model's vectors, not the
    /// largest count, which during a switch is still the outgoing model's.
    var switchProgress: (done: Int, total: Int)? {
        guard switchingTo != nil, chunks > 0 else { return nil }
        return (modelEmbedded, chunks)
    }
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
        // ⚠️ Absent on an older index.py, and absent is not an error. The app
        // ships beside the script but a checkout can hold either.
        if let block = root["model"] as? [String: Any] {
            stats.model = block["model"] as? String ?? ""
            stats.modelEmbedded = block["embedded"] as? Int ?? 0
            stats.switchingTo = (block["switching"] as? [String: Any])?["to"] as? String
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
                },
                // ⚠️ Absent for every source but `files`, and absent is not an
                // error: `roots` is a second view of the same records, not a
                // field every source has.
                roots: (entry["roots"] as? [[String: Any]] ?? []).map { root in
                    RootStat(
                        name: root["name"] as? String ?? "?",
                        records: root["records"] as? Int ?? 0,
                        chunks: root["chunks"] as? Int ?? 0,
                        kinds: root["kinds"] as? [String: Int] ?? [:],
                        containers: (root["containers"] as? [[String: Any]] ?? []).map {
                            // 🛑 AN EMPTY NAME IS A REAL ROW: the folder's own
                            // loose files. It must not be defaulted to "?".
                            Container(name: $0["name"] as? String ?? "",
                                      records: $0["records"] as? Int ?? 0,
                                      chunks: $0["chunks"] as? Int ?? 0)
                        },
                        truncated: root["truncated"] as? Bool ?? false)
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
