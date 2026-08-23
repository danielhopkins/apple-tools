// What the index holds, read straight out of SQLite, read-only.
//
// ⚠️ Read-only and `immutable=0`. The daemon and an ingest both write this file
// with a write-ahead log; opening it immutable would read a stale snapshot and
// report a backlog that had already been embedded.

import Foundation
import SQLite3

struct SourceFacts: Identifiable, Equatable {
    var id: String { tool }
    let tool: String
    var records = 0
    var chunks = 0
    var lastRefresh: Date? = nil
}

struct ModelFacts: Identifiable, Equatable {
    var id: String { model }
    let model: String
    var vectors = 0
}

struct IndexFacts: Equatable {
    var sources: [SourceFacts] = []
    var models: [ModelFacts] = []
    var chunks = 0
    var megabytes = 0.0
    var consentGranted: Date? = nil
    var missing = false
    var error: String? = nil

    /// Chunks with no vector under the model that is furthest along.
    var backlog: Int { max(0, chunks - (models.map(\.vectors).max() ?? 0)) }

    /// 🛑 Rows under more than one model name is the failure that returns
    /// confident nonsense: two vector spaces ranked against one query.
    var mixedModels: Bool { models.filter { $0.vectors > 0 }.count > 1 }
}

enum IndexReader {
    static func read(_ path: URL = Paths.database) -> IndexFacts {
        var facts = IndexFacts()
        guard FileManager.default.fileExists(atPath: path.path) else {
            facts.missing = true
            return facts
        }
        facts.megabytes = size(of: path)

        // 🛑 A PLAIN PATH, NOT A `file:` URI. The path contains a space
        // ("Application Support"), and SQLite will not parse an unencoded
        // space in a URI — it opens, and then every `prepare` fails with "no
        // such table". `index.py` percent-encodes for exactly this reason;
        // `SQLITE_OPEN_READONLY` needs no URI at all.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            facts.error = "cannot open the index"
            return facts
        }
        defer { sqlite3_close(db) }
        // ⚠️ A busy index is normal: an ingest holds a write lock in bursts.
        sqlite3_busy_timeout(db, 2000)

        var lastRefresh: [String: Date] = [:]
        each(db, "SELECT tool, updated FROM source_state") { statement in
            guard let tool = text(statement, 0) else { return }
            let stamp = sqlite3_column_double(statement, 1)
            if stamp > 0 { lastRefresh[tool] = Date(timeIntervalSince1970: stamp) }
        }

        each(db, """
            SELECT r.tool, COUNT(DISTINCT r.rid), COUNT(c.cid)
            FROM record r LEFT JOIN chunk c ON c.rid = r.rid
            GROUP BY r.tool ORDER BY r.tool
            """) { statement in
            guard let tool = text(statement, 0) else { return }
            var source = SourceFacts(tool: tool)
            source.records = Int(sqlite3_column_int64(statement, 1))
            source.chunks = Int(sqlite3_column_int64(statement, 2))
            source.lastRefresh = lastRefresh[tool]
            facts.sources.append(source)
        }

        each(db, "SELECT COUNT(*) FROM chunk") { statement in
            facts.chunks = Int(sqlite3_column_int64(statement, 0))
        }
        each(db, "SELECT model, COUNT(*) FROM vector GROUP BY model ORDER BY model") {
            statement in
            guard let model = text(statement, 0) else { return }
            facts.models.append(ModelFacts(model: model,
                                           vectors: Int(sqlite3_column_int64(statement, 1))))
        }
        each(db, "SELECT granted_at FROM consent ORDER BY granted_at LIMIT 1") { statement in
            let stamp = sqlite3_column_double(statement, 0)
            if stamp > 0 { facts.consentGranted = Date(timeIntervalSince1970: stamp) }
        }
        return facts
    }

    /// The index plus its write-ahead log. ⚠️ The `-wal` file is often hundreds
    /// of megabytes on its own, and a size that ignores it under-reports what
    /// the user is actually storing.
    static func size(of path: URL) -> Double {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let candidate = path.path + suffix
            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate),
               let bytes = attributes[.size] as? Int64 { total += bytes }
        }
        return Double(total) / 1e6
    }

    // MARK: - a very small SQLite helper

    private static func each(_ db: OpaquePointer, _ sql: String,
                             _ row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement else { return }
        defer { sqlite3_finalize(prepared) }
        while sqlite3_step(prepared) == SQLITE_ROW { row(prepared) }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
