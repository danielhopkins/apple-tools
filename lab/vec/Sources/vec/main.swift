// vec — the embedding and vector-search half of the semantic index lab.
//
// Python owns ingestion, FTS5 and result fusion. This binary owns exactly two
// things Python cannot do without a dependency:
//
//   1. NLContextualEmbedding — a 512-dim on-device transformer. Measured on
//      macOS 27.0: 24.5 ms/chunk single-threaded, assets already on disk, and
//      it works from a CLI with no bundle identifier.
//   2. The dot products. The system python3 has no numpy, so scoring 290k
//      vectors in Python would be far too slow. Accelerate does it here.
//
// Vectors are stored int8: mean-pooled, L2-normalised, scaled by 127. That is
// 512 bytes per chunk, so a 290k-chunk index costs ~148 MB instead of ~594 MB
// as float32. Cosine similarity is dot(query_unit, stored_int8) / 127.
//
// This binary writes ONLY the `vector` table. Python creates the schema.

import Foundation
import NaturalLanguage
import Accelerate
import CoreML
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - argv

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("vec: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

struct Args {
    var command = ""
    var flags: [String: String] = [:]

    init(_ argv: [String]) {
        var rest = argv.dropFirst()
        command = rest.first ?? ""
        rest = rest.dropFirst()
        var it = rest.makeIterator()
        while let a = it.next() {
            guard a.hasPrefix("--") else { fail("unexpected argument '\(a)'") }
            let key = String(a.dropFirst(2))
            guard let value = it.next() else { fail("--\(key) needs a value") }
            flags[key] = value
        }
    }

    func str(_ k: String) -> String? { flags[k] }
    func req(_ k: String) -> String {
        guard let v = flags[k] else { fail("--\(k) is required") }
        return v
    }
    func int(_ k: String, _ fallback: Int) -> Int {
        guard let v = flags[k] else { return fallback }
        guard let n = Int(v) else { fail("--\(k) must be a number") }
        return n
    }
}

// MARK: - sqlite

final class DB {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool) {
        // 🛑 Never open a WAL database with SQLITE_OPEN_READONLY. A reader has
        // to create the -shm file when none exists, and a read-only handle
        // cannot, so the open fails with "unable to open database file". It
        // works only when another process happens to have the -shm open
        // already, which is exactly the kind of bug that hides in testing.
        // Open read-write and forbid writes with a pragma instead.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            fail("cannot open \(path): \(String(cString: sqlite3_errmsg(handle)))")
        }
        exec("PRAGMA busy_timeout = 5000")
        if readOnly {
            exec("PRAGMA query_only = 1")
        } else {
            exec("PRAGMA journal_mode = WAL")
        }
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            fail("sql failed: \(message)\n  \(sql)")
        }
    }

    func prepare(_ sql: String) -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            fail("prepare failed: \(String(cString: sqlite3_errmsg(handle)))\n  \(sql)")
        }
        return s
    }

    func scalarInt(_ sql: String) -> Int {
        let s = prepare(sql)
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
    }

    var raw: OpaquePointer? { handle }
}

// MARK: - the model

// 🛑 WHICH MODEL, AND WHY IT MATTERS MORE THAN ANYTHING ELSE HERE.
//
// The first version used NLContextualEmbedding with mean-pooled token vectors.
// It retrieved badly, and the failure was invisible until a real question
// exposed it. Measured, for the query "bathroom code":
//
//     text                     NLContextual   NLEmbedding.sentence (distance)
//     the bathroom door code      0.9461            0.4123  <- closest
//     Bathroom code               0.9735            0.5466
//     Bathroom code 3384          0.8173            0.8082
//     Hub open house              0.8977            1.0763
//     Showroom appointment        0.8955            1.1046
//     Junkyard social             0.9020            1.1674  <- furthest
//
// Under NLContextual, "Junkyard social" beat the literal answer. The sentence
// model ordered every candidate correctly.
//
// ⚠️ Mean-centering the vectors did NOT fix it, so this is not the usual
// anisotropy problem. Apple documents NLContextualEmbedding as a FEATURE LAYER
// for training a model with CreateML, not as a similarity embedding. Pooling
// its token vectors and comparing them by cosine is a use it was never for.
//
// A vector's model is recorded per row, because two models do not share a
// vector space and mixing them silently returns nonsense.

protocol TextEmbedder {
    var dim: Int { get }
    var name: String { get }
    func raw(_ text: String) -> [Float]?
}

/// NLEmbedding.sentenceEmbedding — a real sentence similarity embedding.
final class SentenceEmbedder: TextEmbedder {
    private let model: NLEmbedding
    let dim: Int
    let name = "sentence-v1"

    init() {
        guard let m = NLEmbedding.sentenceEmbedding(for: .english) else {
            fail("NLEmbedding.sentenceEmbedding is unavailable for English")
        }
        model = m
        dim = m.dimension
    }

    func raw(_ text: String) -> [Float]? {
        // Measured: it answers for 18, 82, 420, 900 and 2000 characters, and
        // returns nil for whitespace only.
        guard let v = model.vector(for: text) else { return nil }
        return v.map { Float($0) }
    }
}

/// The original mean-pooled contextual embedder. Kept so an existing index
/// stays queryable and so the comparison can be re-run.
final class ContextualEmbedder: TextEmbedder {
    private let model: NLContextualEmbedding
    let dim: Int
    let name = "contextual-v1"

    init() {
        guard let m = NLContextualEmbedding(language: .english) else {
            fail("NLContextualEmbedding is unavailable for English on this machine")
        }
        if !m.hasAvailableAssets {
            fail("the embedding model assets are not on disk. Run `vec assets`.")
        }
        do { try m.load() } catch { fail("cannot load the embedding model: \(error)") }
        model = m
        dim = m.dimension
    }

    deinit { model.unload() }

    func raw(_ text: String) -> [Float]? {
        let clipped = text.count > 1200 ? String(text.prefix(1200)) : text
        guard let result = try? model.embeddingResult(for: clipped, language: .english)
        else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        var tokens = 0
        result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            tokens += 1
            return true
        }
        guard tokens > 0 else { return nil }
        let inverse = 1.0 / Double(tokens)
        return (0..<dim).map { Float(sum[$0] * inverse) }
    }
}

func makeEmbedder(_ name: String) -> TextEmbedder {
    switch name {
    case "sentence": return SentenceEmbedder()
    case "contextual": return ContextualEmbedder()
    default: fail("--model must be 'sentence' or 'contextual'")
    }
}

final class Embedder {
    let backend: TextEmbedder
    let dim: Int
    var name: String { backend.name }

    init(_ backendName: String) {
        backend = makeEmbedder(backendName)
        dim = backend.dim
    }

    /// L2-normalise, scale to int8. Returns nil when the text has no content.
    func encode(_ text: String) -> [Int8]? {
        // The window is 256 tokens. Python chunks to ~900 characters, but a
        // pathological record could still arrive long, so clamp here too rather
        // than trusting the caller.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard var mean = backend.raw(text) else { return nil }

        var norm: Float = 0
        vDSP_svesq(mean, 1, &norm, vDSP_Length(dim))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }

        var scale = 127.0 / norm
        vDSP_vsmul(mean, 1, &scale, &mean, 1, vDSP_Length(dim))

        return mean.map { value -> Int8 in
            let rounded = value.rounded()
            return Int8(max(-127, min(127, rounded)))
        }
    }

    /// A unit-length float vector, for scoring against stored int8 rows.
    func encodeQuery(_ text: String) -> [Float]? {
        guard let quantised = encode(text) else { return nil }
        var floats = quantised.map { Float($0) }
        var norm: Float = 0
        vDSP_svesq(floats, 1, &norm, vDSP_Length(dim))
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        var inverse = 1.0 / norm
        vDSP_vsmul(floats, 1, &inverse, &floats, 1, vDSP_Length(dim))
        return floats
    }
}

// MARK: - the Core ML path

/// Where the converted model and its vocab live.
///
/// ⚠️ Resolved from the BINARY, not the working directory, so `vec` works from
/// anywhere. `--models-dir` and `VEC_COREML_DIR` override it, which is what an
/// app bundle will pass.
func coremlDirectory(_ args: Args) -> URL {
    if let explicit = args.str("models-dir") {
        return URL(fileURLWithPath: explicit)
    }
    if let fromEnvironment = ProcessInfo.processInfo.environment["VEC_COREML_DIR"] {
        return URL(fileURLWithPath: fromEnvironment)
    }
    // ⚠️ Do NOT count path components up from the binary. SwiftPM makes
    // `.build/release` a SYMLINK to `.build/<triple>/release`, so resolving the
    // path adds a level and a fixed count lands in the wrong directory. Walk up
    // looking for the directory instead.
    var base = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    // An install puts the packages in `models/` beside the binary; a checkout
    // puts them under `coreml/build`. Look for both, walking up.
    for _ in 0..<8 {
        let installed = base.appendingPathComponent("models").standardizedFileURL
        if FileManager.default.fileExists(atPath:
                installed.appendingPathComponent("vocab.txt").path) {
            return installed
        }
        // 🛑 `build`, the FIXED-shape packages — not `build-enum`. Measured:
        // the enumerated model costs **1369 MB resident** against **192 MB**
        // for a fixed one, because Core ML holds an execution plan per shape.
        // It saves 470 MB on disk and spends 1.2 GB of RAM to do it.
        let candidate = base.appendingPathComponent("coreml/build").standardizedFileURL
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        base = base.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: "coreml/build-enum")
}

func makeCoreMLEmbedder(_ args: Args, wantBatch: Int = 32) -> CoreMLEmbedder {
    // 🛑 THE BACKEND DEPENDS ON THE BATCH, and the winner flips between them.
    //
    //   batch 32 (bulk embed): GPU 1041 chunks/sec, ANE 737. GPU wins.
    //   batch 1  (one query):  ANE 0.9 ms, GPU 3.7-6.9 ms. ANE wins by 7x.
    //
    // 🛑 `.all` IS NOT THE ANE. Core ML places the model per load, and three
    // alternating rounds gave 2.9 ms once and 6.4-6.9 ms twice for the same
    // flag. `.cpuAndNeuralEngine` forces it and measured 0.9-1.0 ms in every
    // round. A single run of `.all` looked like a 2x win and was noise.
    //
    // ⚠️ This mixes two numerics: the corpus is embedded on the GPU and a query
    // on the ANE, which agree to about 1e-5. Differences that size have flipped
    // the adaptive fusion rule before, so it was checked rather than assumed —
    // `eval.py` scores MRR 0.535 on either backend.
    let defaultUnits = wantBatch == 1 ? "cpuAndNeuralEngine" : "cpuAndGPU"
    let units: MLComputeUnits
    switch args.str("units") ?? defaultUnits {
    case "all": units = .all
    case "cpuOnly": units = .cpuOnly
    case "cpuAndNeuralEngine": units = .cpuAndNeuralEngine
    default: units = .cpuAndGPU
    }
    do {
        return try CoreMLEmbedder(modelsDir: coremlDirectory(args), units: units,
                                  wantBatch: wantBatch)
    } catch {
        fail("\(error)")
    }
}

/// Read `LIMIT` chunks that have no vector for this model.
func pendingChunks(_ db: DB, model: String, limit: Int) -> [(Int64, String)] {
    var rows: [(Int64, String)] = []
    let select = db.prepare("""
        SELECT c.cid, c.text FROM chunk c
        LEFT JOIN vector v ON v.cid = c.cid AND v.model = '\(model)'
        WHERE v.cid IS NULL
        ORDER BY c.cid
        LIMIT \(limit)
        """)
    while sqlite3_step(select) == SQLITE_ROW {
        let cid = sqlite3_column_int64(select, 0)
        let text = sqlite3_column_text(select, 1).map { String(cString: $0) } ?? " "
        rows.append((cid, text))
    }
    sqlite3_finalize(select)
    return rows
}

func commandEmbedCoreML(_ args: Args) {
    let db = DB(path: args.req("db"), readOnly: false)
    let window = args.int("batch", 4096)
    let limit = args.int("limit", 0)
    let embedder = makeCoreMLEmbedder(args)
    let model = embedder.name

    let pending = db.scalarInt("""
        SELECT COUNT(*) FROM chunk c
        LEFT JOIN vector v ON v.cid = c.cid AND v.model = '\(model)'
        WHERE v.cid IS NULL
        """)
    let target = limit > 0 ? min(limit, pending) : pending
    if target == 0 {
        print("{\"embedded\":0,\"pending\":0,\"seconds\":0.0}")
        return
    }
    FileHandle.standardError.write("vec: \(target) chunks to embed as \(model)\n".data(using: .utf8)!)

    let started = Date()
    var embedded = 0
    while embedded < target {
        let rows = pendingChunks(db, model: model, limit: min(window, target - embedded))
        if rows.isEmpty { break }
        let vectors: [[Float]]
        do { vectors = try embedder.encode(rows.map { $0.1 },
                                           prefix: CoreMLEmbedder.passagePrefix) }
        catch { fail("\(error)") }

        db.exec("BEGIN")
        let insert = db.prepare("INSERT OR REPLACE INTO vector (cid, model, dim, v) VALUES (?, ?, ?, ?)")
        for (index, row) in rows.enumerated() {
            let packed = CoreMLEmbedder.quantise(vectors[index])
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, row.0)
            sqlite3_bind_text(insert, 2, model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(insert, 3, Int32(embedder.dim))
            packed.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(insert, 4, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
            if sqlite3_step(insert) != SQLITE_DONE { fail("insert failed for chunk \(row.0)") }
        }
        sqlite3_finalize(insert)
        db.exec("COMMIT")

        embedded += rows.count
        let rate = Double(embedded) / Date().timeIntervalSince(started)
        FileHandle.standardError.write(
            String(format: "vec: %d/%d  %.0f chunks/sec\n", embedded, target, rate).data(using: .utf8)!)
    }

    let seconds = Date().timeIntervalSince(started)
    FileHandle.standardError.write(String(format: "vec: tokenize %.1fs, predict %.1fs\n",
                                          embedder.tokenizeSeconds,
                                          embedder.predictSeconds).data(using: .utf8)!)
    print(String(format: "{\"embedded\":%d,\"model\":\"%@\",\"pending\":%d,\"seconds\":%.1f,\"per_second\":%.1f}",
                 embedded, model, pending - embedded, seconds,
                 seconds > 0 ? Double(embedded) / seconds : 0))
}

/// 🛑 The gate on the tokenizer port: re-embed chunks the PYTHON Core ML path
/// already wrote, and compare the stored bytes.
///
/// A tokenizer that splits one word differently produces a different vector and
/// nothing downstream can see it. Comparing against rows written by a path known
/// to match PyTorch turns that into a byte comparison over real text.
func commandVerify(_ args: Args) {
    let db = DB(path: args.req("db"), readOnly: true)
    let sample = args.int("limit", 2000)
    let embedder = makeCoreMLEmbedder(args)
    // 🛑 Compare against rows the PYTHON path wrote, under their own name.
    // Comparing against `e5-small-coreml-v1` after this binary has written it
    // compares the port to ITSELF: 100% identical, and proof of nothing.
    // Write the reference first:
    //   uv run coreml/coreml_embed.py embed --db DB \
    //       --model-name e5-small-coreml-py-v1
    let model = args.str("against") ?? "e5-small-coreml-py-v1"
    _ = embedder.name

    var cids: [Int64] = []
    var texts: [String] = []
    var stored: [[Int8]] = []
    // ⚠️ A random sample, not the first N cids and not `cid % k`. The first N
    // are one source, and the modulo stride returned 114 rows for --limit 500
    // because it strides over deleted cids.
    let select = db.prepare("""
        SELECT c.cid, c.text, v.v FROM chunk c
        JOIN vector v ON v.cid = c.cid AND v.model = '\(model)'
        WHERE c.cid IN (SELECT cid FROM vector WHERE model = '\(model)'
                        ORDER BY RANDOM() LIMIT \(sample))
        """)
    while sqlite3_step(select) == SQLITE_ROW {
        cids.append(sqlite3_column_int64(select, 0))
        texts.append(sqlite3_column_text(select, 1).map { String(cString: $0) } ?? " ")
        let bytes = Int(sqlite3_column_bytes(select, 2))
        if let blob = sqlite3_column_blob(select, 2) {
            let pointer = blob.assumingMemoryBound(to: Int8.self)
            stored.append(Array(UnsafeBufferPointer(start: pointer, count: bytes)))
        } else {
            stored.append([])
        }
    }
    sqlite3_finalize(select)
    if cids.isEmpty {
        fail("""
             no rows for '\(model)'. Write the reference set first:
               uv run coreml/coreml_embed.py embed --db DB --model-name \(model) --limit 20000
             """)
    }

    let started = Date()
    let vectors: [[Float]]
    do { vectors = try embedder.encode(texts, prefix: CoreMLEmbedder.passagePrefix) }
    catch { fail("\(error)") }
    let seconds = Date().timeIntervalSince(started)

    var identical = 0
    var worstCosine: Float = 1
    var worstCid: Int64 = 0
    var maxByteDelta = 0
    var differing: [Int64] = []
    for index in 0..<cids.count {
        let mine = CoreMLEmbedder.quantise(vectors[index])
        let theirs = stored[index]
        guard mine.count == theirs.count else { continue }
        if mine == theirs { identical += 1 } else { differing.append(cids[index]) }
        var dot: Float = 0, a: Float = 0, b: Float = 0
        for component in 0..<mine.count {
            let x = Float(mine[component]), y = Float(theirs[component])
            dot += x * y; a += x * x; b += y * y
            maxByteDelta = max(maxByteDelta, abs(Int(mine[component]) - Int(theirs[component])))
        }
        let cosine = (a > 0 && b > 0) ? dot / (sqrt(a) * sqrt(b)) : 0
        if cosine < worstCosine { worstCosine = cosine; worstCid = cids[index] }
    }

    FileHandle.standardError.write(String(format: "vec: tokenize %.2fs, predict %.2fs\n",
                                          embedder.tokenizeSeconds,
                                          embedder.predictSeconds).data(using: .utf8)!)
    let named = differing.prefix(25).map(String.init).joined(separator: ",")
    FileHandle.standardError.write("vec: differing cids: [\(named)]\n".data(using: .utf8)!)
    print(String(format: "{\"compared\":%d,\"identical\":%d,\"identical_pct\":%.2f,\"worst_cosine\":%.6f,\"worst_cid\":%d,\"max_byte_delta\":%d,\"seconds\":%.2f,\"per_second\":%.1f}",
                 cids.count, identical, 100.0 * Double(identical) / Double(cids.count),
                 worstCosine, worstCid, maxByteDelta, seconds,
                 seconds > 0 ? Double(cids.count) / seconds : 0))
}

// MARK: - commands

func commandAssets() {
    guard let m = NLContextualEmbedding(language: .english) else {
        fail("NLContextualEmbedding is unavailable for English")
    }
    if m.hasAvailableAssets {
        print("assets already on disk: dim=\(m.dimension) maxTokens=\(m.maximumSequenceLength) revision=\(m.revision)")
        return
    }
    print("requesting assets, this downloads a model...")
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    m.requestAssets { _, error in
        failure = error
        done.signal()
    }
    if done.wait(timeout: .now() + 300) == .timedOut { fail("asset request timed out after 300s") }
    if let e = failure { fail("asset request failed: \(e)") }
    print("assets ready: dim=\(m.dimension) maxTokens=\(m.maximumSequenceLength)")
}

func commandEmbed(_ args: Args) {
    if (args.str("model") ?? "") == "e5-small-coreml" { return commandEmbedCoreML(args) }
    let db = DB(path: args.req("db"), readOnly: false)
    let batch = args.int("batch", 500)
    let limit = args.int("limit", 0)          // 0 means "everything outstanding"

    let embedder = Embedder(args.str("model") ?? "sentence")
    let pending = db.scalarInt("""
        SELECT COUNT(*) FROM chunk c
        LEFT JOIN vector v ON v.cid = c.cid AND v.model = '\(args.str("model") ?? "sentence")'
        WHERE v.cid IS NULL
        """)
    let target = limit > 0 ? min(limit, pending) : pending

    if target == 0 {
        print("{\"embedded\":0,\"pending\":0,\"seconds\":0.0}")
        return
    }
    FileHandle.standardError.write("vec: \(target) chunks to embed\n".data(using: .utf8)!)

    let started = Date()
    var embedded = 0
    var skipped = 0

    while embedded + skipped < target {
        let take = min(batch, target - embedded - skipped)
        var rows: [(Int64, String)] = []

        let select = db.prepare("""
            SELECT c.cid, c.text FROM chunk c
            LEFT JOIN vector v ON v.cid = c.cid AND v.model = '\(embedder.name)'
            WHERE v.cid IS NULL
            ORDER BY c.cid
            LIMIT \(take)
            """)
        while sqlite3_step(select) == SQLITE_ROW {
            let cid = sqlite3_column_int64(select, 0)
            let text = String(cString: sqlite3_column_text(select, 1))
            rows.append((cid, text))
        }
        sqlite3_finalize(select)
        if rows.isEmpty { break }

        db.exec("BEGIN")
        let insert = db.prepare("INSERT OR REPLACE INTO vector (cid, model, dim, v) VALUES (?, ?, ?, ?)")
        for (cid, text) in rows {
            guard let vector = embedder.encode(text) else {
                // A chunk that produces no tokens gets a zero vector rather than
                // being left pending forever. Otherwise every later run retries
                // it and the loop never drains.
                let zeros = [Int8](repeating: 0, count: embedder.dim)
                sqlite3_reset(insert)
                sqlite3_bind_int64(insert, 1, cid)
                sqlite3_bind_text(insert, 2, embedder.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(insert, 3, Int32(embedder.dim))
                zeros.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(insert, 4, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
                if sqlite3_step(insert) != SQLITE_DONE { fail("insert failed for chunk \(cid)") }
                skipped += 1
                continue
            }
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, cid)
            sqlite3_bind_text(insert, 2, embedder.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(insert, 3, Int32(embedder.dim))
            vector.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(insert, 4, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
            if sqlite3_step(insert) != SQLITE_DONE { fail("insert failed for chunk \(cid)") }
            embedded += 1
        }
        sqlite3_finalize(insert)
        db.exec("COMMIT")

        let done = embedded + skipped
        let rate = Double(done) / Date().timeIntervalSince(started)
        FileHandle.standardError.write(
            String(format: "vec: %d/%d  %.1f chunks/sec\n", done, target, rate).data(using: .utf8)!)
    }

    let seconds = Date().timeIntervalSince(started)
    let remaining = pending - embedded - skipped
    print(String(format: "{\"embedded\":%d,\"empty\":%d,\"pending\":%d,\"seconds\":%.2f,\"per_second\":%.1f}",
                 embedded, skipped, remaining, seconds,
                 seconds > 0 ? Double(embedded + skipped) / seconds : 0))
}

func commandSearch(_ args: Args) {
    let db = DB(path: args.req("db"), readOnly: true)
    let query = args.req("query")
    let limit = args.int("limit", 50)
    let tool = args.str("tool")

    let q: [Float]
    let dim: Int
    let modelName: String
    if (args.str("model") ?? "") == "e5-small-coreml" {
        let embedder = makeCoreMLEmbedder(args, wantBatch: 1)
        do { q = try embedder.encodeQuery(query) } catch { fail("\(error)") }
        dim = embedder.dim
        modelName = embedder.name
    } else {
        let embedder = Embedder(args.str("model") ?? "sentence")
        guard let vector = embedder.encodeQuery(query) else { fail("the query produced no tokens") }
        q = vector
        dim = embedder.dim
        modelName = embedder.name
    }

    // Brute force. At 290k vectors this is ~148 MB of reads and 148M multiply
    // adds, which Accelerate does in well under a second. Reach for an ANN
    // index only after measuring that this is too slow.
    var best: [(Int64, Float)] = []
    var scratch = [Float](repeating: 0, count: dim)

    // 🛑 Filter on the model. Two models do not share a vector space, so
    // scoring across both returns confident nonsense.
    // 🛑 A tool filter belongs HERE, not after fusion. Applied afterwards it
    // does not search one source: it keeps whichever records of that source
    // survived a GLOBAL ranking, which on a 68%-mail index is very few. A
    // field test asked for `--tool notes --limit 30` and got 4 rows back.
    var scope = ""
    if let tool = tool {
        let safe = tool.replacingOccurrences(of: "'", with: "''")
        scope = " AND cid IN (SELECT c.cid FROM chunk c "
              + "JOIN record r ON r.rid = c.rid WHERE r.tool = '\(safe)')"
    }
    let stmt = db.prepare(
        "SELECT cid, v FROM vector WHERE dim = \(dim) AND model = '\(modelName)'"
        + scope)
    var scanned = 0
    let started = Date()
    while sqlite3_step(stmt) == SQLITE_ROW {
        let cid = sqlite3_column_int64(stmt, 0)
        guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
        let bytes = Int(sqlite3_column_bytes(stmt, 1))
        guard bytes == dim else { continue }
        scanned += 1

        let stored = blob.assumingMemoryBound(to: Int8.self)
        vDSP_vflt8(stored, 1, &scratch, 1, vDSP_Length(dim))
        var dot: Float = 0
        vDSP_dotpr(q, 1, scratch, 1, &dot, vDSP_Length(dim))
        let score = dot / 127.0
        if score <= 0 { continue }

        if best.count < limit {
            best.append((cid, score))
            if best.count == limit { best.sort { $0.1 > $1.1 } }
        } else if score > best[best.count - 1].1 {
            best[best.count - 1] = (cid, score)
            var i = best.count - 1
            while i > 0 && best[i].1 > best[i - 1].1 {
                best.swapAt(i, i - 1)
                i -= 1
            }
        }
    }
    sqlite3_finalize(stmt)
    if best.count < limit { best.sort { $0.1 > $1.1 } }

    let elapsed = Date().timeIntervalSince(started)
    FileHandle.standardError.write(
        String(format: "vec: scanned %d vectors in %.3fs\n", scanned, elapsed).data(using: .utf8)!)

    let rows = best.map { String(format: "{\"cid\":%d,\"score\":%.6f}", $0.0, $0.1) }
    print("[" + rows.joined(separator: ",") + "]")
}

func commandStatus(_ args: Args) {
    let db = DB(path: args.req("db"), readOnly: true)
    let chunks = db.scalarInt("SELECT COUNT(*) FROM chunk")
    let vectors = db.scalarInt("SELECT COUNT(*) FROM vector")
    let bySentence = db.scalarInt("SELECT COUNT(*) FROM vector WHERE model='sentence-v1'")
    let byContextual = db.scalarInt("SELECT COUNT(*) FROM vector WHERE model='contextual-v1'")
    let model = NLContextualEmbedding(language: .english)
    print("""
          {"chunks":\(chunks),"vectors":\(vectors),\
          "sentence":\(bySentence),"contextual":\(byContextual),\
          "dim":\(model?.dimension ?? 0),"assets":\(model?.hasAvailableAssets == true)}
          """)
}

/// Print the token ids for one chunk, so a mismatch can be diffed against
/// Python instead of guessed at.
func commandTokens(_ args: Args) {
    let db = DB(path: args.req("db"), readOnly: true)
    let cid = args.int("cid", 0)
    let embedder = makeCoreMLEmbedder(args, wantBatch: 1)
    _ = embedder
    let vocabURL = coremlDirectory(args).appendingPathComponent("vocab.txt")
    guard let tokenizer = try? WordPiece(vocabularyAt: vocabURL) else { fail("no vocab") }
    let stmt = db.prepare("SELECT text FROM chunk WHERE cid = \(cid)")
    guard sqlite3_step(stmt) == SQLITE_ROW,
          let raw = sqlite3_column_text(stmt, 0) else { fail("no chunk \(cid)") }
    let text = CoreMLEmbedder.passagePrefix + String(cString: raw)
    sqlite3_finalize(stmt)
    let ids = tokenizer.encode(text, maxLength: 512)
    print("{\"cid\":\(cid),\"count\":\(ids.count),\"ids\":[\(ids.map(String.init).joined(separator: ","))]}")
}

// MARK: - dispatch

let args = Args(CommandLine.arguments)
switch args.command {
case "embed":  commandEmbed(args)
case "search": commandSearch(args)
case "status": commandStatus(args)
case "verify": commandVerify(args)
case "daemon": commandDaemon(args)
case "tokens": commandTokens(args)
case "assets": commandAssets()
default:
    print("""
          usage: vec <command> [--flag value]

            embed  --db PATH [--model sentence|contextual|e5-small-coreml] [--batch N] [--limit N]
            search --db PATH --query TEXT [--model ...] [--limit 50] [--tool NAME]
            verify --db PATH [--limit 2000]              tokenizer parity vs the Python rows
            daemon --db PATH [--socket PATH] [--reload-every 60]   serve searches, warm
            status --db PATH                             chunk and vector counts
            assets                                       download the model if missing
          """)
    exit(args.command.isEmpty ? 0 : 1)
}
