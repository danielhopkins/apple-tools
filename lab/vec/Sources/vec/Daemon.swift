// The warm daemon, in Swift.
//
// It replaces `daemon.py`, which held PyTorch and 661 MB to answer a socket.
// This holds the Core ML model and the int8 matrix, speaks the same protocol on
// the same Unix socket, and `index.py` cannot tell which one answered.
//
// 🛑 IT SERVES, IT DOES NOT INGEST. Reading the index file needs no grant.
// Reading Mail, Notes and Messages needs Full Disk Access, and a launchd agent
// has none — measured, all three. So refreshing stays a terminal job and this
// process never spawns one. `daemon.py` learned that the hard way: a failing
// ingest prints no change lines, which looks exactly like "nothing changed".
//
// 🛑 The socket is mode 0600 inside the 0700 index directory, and it is NEVER a
// TCP port. It answers with the plaintext-derived vectors of every indexed
// message; a bad bind address would put the whole corpus on the network.

import Foundation
import Accelerate
import CoreML
import SQLite3

final class WarmIndex {
    private let path: String
    private let embedder: CoreMLEmbedder
    private let lock = NSLock()

    private(set) var cids: [Int64] = []
    private(set) var matrix: [Int8] = []          // row-major, `dim` per row
    private(set) var tools: [String] = []
    private(set) var fingerprint = ""
    private(set) var chunks = 0

    var dim: Int { embedder.dim }
    /// The stored name, `…-v1`, used in SQL.
    var storedModel: String { embedder.name }
    /// The name the protocol uses. See `CoreMLEmbedder.shortName`.
    var model: String { CoreMLEmbedder.shortName }
    var megabytes: Double { Double(matrix.count) / 1e6 }

    init(path: String, embedder: CoreMLEmbedder) {
        self.path = path
        self.embedder = embedder
        reload()
    }

    /// 🛑 The same four counts `index.py` uses. A re-ingest, a rechunk or a new
    /// model all move it, which is exactly when warm vectors become a lie.
    static func fingerprint(_ db: DB) -> (String, Int) {
        let statement = db.prepare("""
            SELECT (SELECT COUNT(*) FROM record),
                   (SELECT COUNT(*) FROM chunk),
                   (SELECT COUNT(*) FROM vector),
                   (SELECT COALESCE(MAX(cid), 0) FROM chunk)
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return ("", 0) }
        let records = Int(sqlite3_column_int64(statement, 0))
        let chunks = Int(sqlite3_column_int64(statement, 1))
        let vectors = Int(sqlite3_column_int64(statement, 2))
        let maxCid = Int(sqlite3_column_int64(statement, 3))
        return ("r\(records)-c\(chunks)-v\(vectors)-m\(maxCid)", chunks)
    }

    func reload() {
        let started = Date()
        let db = DB(path: path, readOnly: true)
        let (mark, liveChunks) = Self.fingerprint(db)

        var freshCids: [Int64] = []
        var freshMatrix: [Int8] = []
        var freshTools: [String] = []
        // The tool comes along for the ride so a --tool search masks the matrix
        // before scoring rather than filtering results afterwards.
        let statement = db.prepare("""
            SELECT v.cid, v.v, r.tool FROM vector v
            JOIN chunk c ON c.cid = v.cid
            JOIN record r ON r.rid = c.rid
            WHERE v.model = '\(storedModel)' AND v.dim = \(dim)
            """)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 1),
                  Int(sqlite3_column_bytes(statement, 1)) == dim else { continue }
            freshCids.append(sqlite3_column_int64(statement, 0))
            let bytes = blob.assumingMemoryBound(to: Int8.self)
            freshMatrix.append(contentsOf: UnsafeBufferPointer(start: bytes, count: dim))
            freshTools.append(sqlite3_column_text(statement, 2)
                                .map { String(cString: $0) } ?? "")
        }
        sqlite3_finalize(statement)

        lock.lock()
        cids = freshCids
        matrix = freshMatrix
        tools = freshTools
        fingerprint = mark
        chunks = liveChunks
        lock.unlock()

        log(String(format: "%d vectors warm (%.0f MB) in %.1fs  index=%@",
                   freshCids.count, Double(freshMatrix.count) / 1e6,
                   Date().timeIntervalSince(started), mark))
    }

    /// True when the index has moved since the last reload.
    func isStale() -> Bool {
        let db = DB(path: path, readOnly: true)
        let (mark, _) = Self.fingerprint(db)
        lock.lock(); defer { lock.unlock() }
        return mark != fingerprint
    }

    func search(query: String, limit: Int, tool: String?) throws -> [(Int64, Float)] {
        let vector = try embedder.encodeQuery(query)

        lock.lock()
        let cids = self.cids, matrix = self.matrix, tools = self.tools
        lock.unlock()
        if cids.isEmpty { return [] }

        var best: [(Int64, Float)] = []
        var scratch = [Float](repeating: 0, count: dim)
        matrix.withUnsafeBufferPointer { rows in
            guard let base = rows.baseAddress else { return }
            for index in 0..<cids.count {
                // 🛑 Mask BEFORE scoring. A tool filter applied to the results
                // keeps whichever records survived a GLOBAL ranking, which on a
                // 68%-mail index is very few.
                if let tool = tool, tools[index] != tool { continue }
                vDSP_vflt8(base + index * dim, 1, &scratch, 1, vDSP_Length(dim))
                var dot: Float = 0
                vDSP_dotpr(vector, 1, scratch, 1, &dot, vDSP_Length(dim))
                let score = dot / 127.0
                if score <= 0 { continue }
                if best.count < limit {
                    best.append((cids[index], score))
                    if best.count == limit { best.sort { $0.1 > $1.1 } }
                } else if score > best[best.count - 1].1 {
                    best[best.count - 1] = (cids[index], score)
                    var position = best.count - 1
                    while position > 0 && best[position].1 > best[position - 1].1 {
                        best.swapAt(position, position - 1)
                        position -= 1
                    }
                }
            }
        }
        if best.count < limit { best.sort { $0.1 > $1.1 } }
        return best
    }
}

/// 🛑 A DIRECTORY LISTING, NOT A TCC QUERY. No API reports Full Disk Access.
///
/// ⚠️ A user who revokes the grant expects their mail to stop being readable.
/// The index is an ordinary file and keeps answering, which `SECURITY.md` names
/// as a real gap. So the daemon checks, and refuses to serve once the grant is
/// gone rather than quietly outliving it.
func hasFullDiskAccess() -> Bool {
    let probe = NSString(string: "~/Library/Mail").expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: probe, isDirectory: &isDirectory)
    else { return true }        // no Mail here; absence is not a denial
    do {
        _ = try FileManager.default.contentsOfDirectory(atPath: probe)
        return true
    } catch {
        return false
    }
}

func log(_ message: String) {
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write(
        "[\(stamp.string(from: Date()))] \(message)\n".data(using: .utf8)!)
}

func commandDaemon(_ args: Args) {
    let dbPath = args.req("db")
    let socketPath = args.str("socket")
        ?? (dbPath as NSString).deletingLastPathComponent + "/index.sock"
    let reloadEvery = args.int("reload-every", 60)

    let embedder = makeCoreMLEmbedder(args, wantBatch: 1)
    log("model ready: \(embedder.name)")
    let warm = WarmIndex(path: dbPath, embedder: embedder)

    // 🛑 A SEPARATE loop from any refresh, and the only one this process runs.
    // Reloading reads the index file, which no grant protects. Ingesting reads
    // Mail and Notes, which Full Disk Access protects and launchd does not have.
    if reloadEvery > 0 {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: Double(reloadEvery))
                if warm.isStale() {
                    log("index changed; reloading vectors")
                    warm.reload()
                }
            }
        }
        log("watching the index every \(reloadEvery)s")
    }
    log("refresh disabled; run `apple-index refresh` from a terminal")

    unlink(socketPath)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { fail("cannot create a socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    // sun_path is a fixed C array; copy the bytes in rather than assigning.
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        fail("socket path is too long: \(socketPath)")
    }
    withUnsafeMutablePointer(to: &address.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { out in
            for (index, byte) in pathBytes.enumerated() { out[index] = CChar(byte) }
            out[pathBytes.count] = 0
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
    }
    guard bound == 0 else { fail("cannot bind \(socketPath): \(String(cString: strerror(errno)))") }
    // 🛑 Owner only. Anything that can connect can read every indexed message.
    chmod(socketPath, 0o600)
    guard listen(listener, 16) == 0 else { fail("cannot listen on \(socketPath)") }
    log("listening on \(socketPath)")

    while true {
        let client = accept(listener, nil, nil)
        if client < 0 { continue }
        defer { close(client) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let got = read(client, &buffer, buffer.count)
            if got <= 0 { break }
            data.append(contentsOf: buffer[0..<got])
            if data.last == 0x0A { break }
        }
        if data.isEmpty { continue }

        var reply: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw CoreMLEmbedder.Failure("the request is not an object") }
            switch request["op"] as? String ?? "" {
            case "ping":
                reply = ["ok": true, "model": warm.model,
                         "full_disk_access": hasFullDiskAccess(),
                         "vectors": warm.cids.count,
                         "fingerprint": warm.fingerprint,
                         "megabytes": (warm.megabytes * 10).rounded() / 10,
                         "chunks": warm.chunks,
                         "refresh_enabled": false,
                         "reload_enabled": reloadEvery > 0]
            case "search":
                // 🛑 DO NOT GATE THIS ON FULL DISK ACCESS. A first version did,
                // and the launchd agent then refused every search on startup —
                // because a launchd agent NEVER HAS the grant, and serving does
                // not need one. The probe cannot tell "the user revoked it"
                // from "this process never had it". That check belongs in the
                // terminal-launched commands, which do run under the user's
                // grant; `index.py` warns there.
                //
                // ⚠️ The failure also confirms the measurement this whole design
                // rests on: an agent has no Full Disk Access. `ping` reports the
                // probe so it stays visible rather than being assumed.
                // 🛑 One model per daemon. A client asking for another must be
                // refused, never quietly answered out of the wrong vector
                // space. That bug once made two models score identically in an
                // evaluation, because both were served the same vectors.
                if let wanted = request["model"] as? String, wanted != warm.model {
                    reply = ["ok": false,
                             "error": "daemon holds \(warm.model), not \(wanted)"]
                    break
                }
                let query = request["query"] as? String ?? ""
                let limit = request["limit"] as? Int ?? 100
                let started = Date()
                let hits = try warm.search(query: query, limit: limit,
                                           tool: request["tool"] as? String)
                reply = ["ok": true,
                         "hits": hits.map { ["cid": $0.0, "score": $0.1] },
                         "elapsed_ms": (Date().timeIntervalSince(started) * 10000)
                                        .rounded() / 10]
            case "reload":
                warm.reload()
                reply = ["ok": true, "fingerprint": warm.fingerprint]
            case let other:
                reply = ["ok": false, "error": "unknown op '\(other)'"]
            }
        } catch {
            reply = ["ok": false, "error": "\(error)"]
        }

        if let encoded = try? JSONSerialization.data(withJSONObject: reply) {
            var out = encoded
            out.append(0x0A)
            _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        }
    }
}
