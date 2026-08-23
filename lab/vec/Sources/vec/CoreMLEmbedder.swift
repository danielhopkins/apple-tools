// CoreMLEmbedder — e5-small-v2 as a Core ML model, with no Python anywhere.
//
// The measurements behind every choice here are in coreml/BAKEOFF.md. Three of
// them are load-bearing at this call site:
//
//   🛑 `.cpuAndGPU`, never `.all`. The Neural Engine is slower than the GPU at
//      every sequence length measured, and an ENUMERATED-shape model runs up to
//      60x slower on it. `.all` is the name that sounds safest and it is the
//      wrong answer twice over.
//   🛑 The prefixes are load-bearing. E5 is trained asymmetrically: a stored
//      passage gets "passage: " and a query gets "query: ". Dropping them makes
//      a strong model score like a weak one.
//   🛑 Pooling and L2-normalisation happen INSIDE the graph, so this file must
//      not repeat them. It normalises again only to undo float drift.

import Foundation
import CoreML
import Accelerate

final class CoreMLEmbedder {
    static let modelName = "e5-small-coreml-v1"
    /// 🛑 The name the CLI and the socket protocol use, WITHOUT the `-v1`.
    /// `daemon.py` advertises the short name and `index.py` sends the short
    /// name, so a daemon comparing the stored name declines every request —
    /// silently, because a decline only prints under `--verbose`.
    static let shortName = "e5-small-coreml"
    static let passagePrefix = "passage: "
    static let queryPrefix = "query: "

    let dim = 384
    var name: String { Self.modelName }

    private let packages: [Int: URL]
    private var loaded: [Int: MLModel] = [:]
    private let computeUnits: MLComputeUnits
    private let tokenizer: WordPiece
    private let lengths: [Int]        // the enumerated sequence lengths, sorted
    private let batchSize: Int

    /// Where the time goes, so "the model is slow" is never a guess.
    private(set) var tokenizeSeconds: Double = 0
    private(set) var predictSeconds: Double = 0

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    /// `wantBatch` picks the batch size: 32 for a bulk embed, 1 for a query.
    ///
    /// 🛑 A DIRECTORY OF FIXED PACKAGES IS A BUCKET SET, NOT A CHOICE OF ONE.
    /// An earlier version took the first package matching the batch, which in
    /// a directory holding s64/s128/s256/s384/s512 meant **s128 for every
    /// chunk** — so everything longer than 128 tokens was truncated. Parity
    /// against the Python path fell to 68.11%, which is exactly the share of
    /// this corpus that fits in 128 tokens. The number named the bug.
    ///
    /// One package carrying enumerated shapes still works and stays one model.
    /// ⚠️ It costs **1369 MB resident against 192 MB** for fixed packages,
    /// because Core ML holds an execution plan per shape.
    init(modelsDir: URL, units: MLComputeUnits = .cpuAndGPU, wantBatch: Int = 32) throws {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(atPath: modelsDir.path))?
            .filter { $0.hasSuffix(".mlpackage") }.sorted() ?? []
        guard !entries.isEmpty
        else { throw Failure("no .mlpackage in \(modelsDir.path) — run coreml/run-convert.sh") }

        // 🛑 Split on "-" and match whole components. `range(of: "-s")` finds
        // the "-s" inside "e5-small" and reads the sequence length out of
        // "mall-v2-s128", which parses as nil and fell back to 128 for EVERY
        // package. Every chunk was then truncated at 128 tokens, and the only
        // sign was a parity score of 68.11% — the share of the corpus that
        // fits in 128.
        func parts(_ entry: String) -> [Substring] {
            return (entry as NSString).deletingPathExtension.split(separator: "-")
        }
        func batchOf(_ entry: String) -> Int {
            for part in parts(entry) where part.hasPrefix("b") {
                if let value = Int(part.dropFirst()) { return value }
            }
            return 1
        }
        var candidates = entries.filter { batchOf($0) == wantBatch }
        if candidates.isEmpty {
            // No package at the wanted batch: take the largest available, and
            // pad short groups up to it.
            let best = entries.map(batchOf).max() ?? 1
            candidates = entries.filter { batchOf($0) == best }
        }
        batchSize = batchOf(candidates[0])

        var found: [Int: String] = [:]
        var enumerated: [Int] = []
        for entry in candidates {
            for part in parts(entry) {
                if part.hasPrefix("s"), let length = Int(part.dropFirst()) {
                    found[length] = entry
                } else if part.hasPrefix("e"), part.contains("_"),
                          part.dropFirst().allSatisfy({ $0.isNumber || $0 == "_" }) {
                    // ⚠️ The underscore is required. Without it "e5" — the first
                    // component of "e5-small-v2" — parses as the enumerated
                    // shape list [5], and the first prediction fails with
                    // "MultiArray shape (32 x 5) does not match (32 x 64)".
                    let all = part.dropFirst().split(separator: "_")
                        .compactMap { Int($0) }.sorted()
                    if !all.isEmpty {
                        enumerated = all
                        for length in all { found[length] = entry }
                    }
                }
            }
        }
        guard !found.isEmpty else {
            throw Failure("cannot read the shapes out of \(candidates)")
        }
        // ⚠️ Never mix an enumerated package with fixed ones: they would share
        // a bucket table while only one of them can serve a given shape.
        if !enumerated.isEmpty {
            found = found.filter { enumerated.contains($0.key) }
        }
        packages = found.mapValues { modelsDir.appendingPathComponent($0) }
        lengths = found.keys.sorted()

        let vocabURL = modelsDir.appendingPathComponent("vocab.txt")
        guard manager.fileExists(atPath: vocabURL.path) else {
            throw Failure("no vocab.txt beside the model in \(modelsDir.path)")
        }
        tokenizer = try WordPiece(vocabularyAt: vocabURL)
        computeUnits = units
    }

    /// Compile if needed, then load. ⚠️ Lazy on purpose: a bucket set holds
    /// five packages and a short corpus touches two of them.
    private func model(for sequence: Int) throws -> MLModel {
        if let ready = loaded[sequence] { return ready }
        guard let packageURL = packages[sequence] else {
            throw Failure("no package for sequence \(sequence)")
        }
        let manager = FileManager.default
        let stem = packageURL.deletingPathExtension().lastPathComponent
        let compiledURL = packageURL.deletingLastPathComponent()
            .appendingPathComponent(stem + ".mlmodelc")
        if !Self.isFresh(compiled: compiledURL, source: packageURL) {
            let temporary = try MLModel.compileModel(at: packageURL)
            try? manager.removeItem(at: compiledURL)
            try manager.moveItem(at: temporary, to: compiledURL)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let ready = try MLModel(contentsOf: compiledURL, configuration: configuration)
        loaded[sequence] = ready
        return ready
    }

    private static func isFresh(compiled: URL, source: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: compiled.path),
              let compiledDate = (try? manager.attributesOfItem(atPath: compiled.path))?[.modificationDate] as? Date,
              let sourceDate = (try? manager.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date
        else { return false }
        return compiledDate >= sourceDate
    }

    private func bucket(for length: Int) -> Int {
        for size in lengths where length <= size { return size }
        return lengths[lastIndex: 0]
    }

    /// One L2-normalised vector per text, in the order given.
    func encode(_ texts: [String], prefix: String) throws -> [[Float]] {
        // (timings accumulate across calls; the caller prints them)
        let prefixed = texts.map { prefix + ($0.isEmpty ? " " : $0) }
        let cap = lengths[lengths.count - 1]

        // ⚠️ Tokenising is the slow half, not the model. Measured serially at
        // 421 chunks/sec against 878 for the Python path, whose tokenizer is
        // Rust and multi-threaded. `WordPiece` reads only immutable state, so
        // it is safe to run across every core.
        var tokens = [[Int32]](repeating: [], count: prefixed.count)
        let tokenizer = self.tokenizer
        let tokenizeStarted = Date()
        tokens.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: buffer.count) { index in
                buffer[index] = tokenizer.encode(prefixed[index], maxLength: cap)
            }
        }
        tokenizeSeconds += Date().timeIntervalSince(tokenizeStarted)

        var out = [[Float]](repeating: [Float](repeating: 0, count: dim), count: texts.count)
        var byBucket: [Int: [Int]] = [:]
        for (position, ids) in tokens.enumerated() {
            byBucket[bucket(for: ids.count), default: []].append(position)
        }

        for (sequence, positions) in byBucket.sorted(by: { $0.key < $1.key }) {
            let model = try self.model(for: sequence)
            var start = 0
            while start < positions.count {
                let stop = min(start + batchSize, positions.count)
                let real = stop - start
                let ids = try MLMultiArray(shape: [NSNumber(value: batchSize),
                                                   NSNumber(value: sequence)],
                                           dataType: .int32)
                let mask = try MLMultiArray(shape: [NSNumber(value: batchSize),
                                                    NSNumber(value: sequence)],
                                            dataType: .int32)
                let idsBuffer = ids.dataPointer.bindMemory(to: Int32.self, capacity: batchSize * sequence)
                let maskBuffer = mask.dataPointer.bindMemory(to: Int32.self, capacity: batchSize * sequence)
                for slot in 0..<(batchSize * sequence) { idsBuffer[slot] = 0; maskBuffer[slot] = 0 }

                for row in 0..<real {
                    let source = tokens[positions[start + row]]
                    for (column, id) in source.enumerated() where column < sequence {
                        idsBuffer[row * sequence + column] = id
                        maskBuffer[row * sequence + column] = 1
                    }
                }
                // The batch shape is fixed, so a short final group repeats its
                // last row and the extra outputs are thrown away.
                if real < batchSize {
                    let lastRow = (real - 1) * sequence
                    for row in real..<batchSize {
                        for column in 0..<sequence {
                            idsBuffer[row * sequence + column] = idsBuffer[lastRow + column]
                            maskBuffer[row * sequence + column] = maskBuffer[lastRow + column]
                        }
                    }
                }

                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: ids),
                    "attention_mask": MLFeatureValue(multiArray: mask),
                ])
                let predictStarted = Date()
                let result = try model.prediction(from: input)
                predictSeconds += Date().timeIntervalSince(predictStarted)
                guard let embedding = result.featureValue(for: "embedding")?.multiArrayValue
                else { throw Failure("the model returned no 'embedding' output") }
                let values = embedding.dataPointer.bindMemory(to: Float.self,
                                                              capacity: batchSize * dim)
                for row in 0..<real {
                    var vector = [Float](repeating: 0, count: dim)
                    for component in 0..<dim { vector[component] = values[row * dim + component] }
                    out[positions[start + row]] = Self.unit(vector)
                }
                start = stop
            }
        }
        return out
    }

    /// A single vector, for a query.
    func encodeQuery(_ text: String) throws -> [Float] {
        return try encode([text], prefix: Self.queryPrefix)[0]
    }

    private static func unit(_ vector: [Float]) -> [Float] {
        var copy = vector
        var norm: Float = 0
        vDSP_svesq(copy, 1, &norm, vDSP_Length(copy.count))
        norm = sqrt(norm)
        guard norm > 0 else { return copy }
        var inverse = 1.0 / norm
        vDSP_vsmul(copy, 1, &inverse, &copy, 1, vDSP_Length(copy.count))
        return copy
    }

    /// Scale a unit vector to int8, exactly as the Python path stores it.
    ///
    /// 🛑 `.toNearestOrEven`, not `.rounded()`. numpy's `rint` rounds a half to
    /// the even neighbour and Swift's default rounds it away from zero, so the
    /// two disagree on any component that lands exactly on .5 — a byte
    /// difference in a file that is meant to be identical.
    static func quantise(_ vector: [Float]) -> [Int8] {
        return vector.map { value in
            let scaled = (value * 127.0).rounded(.toNearestOrEven)
            return Int8(max(-127, min(127, scaled)))
        }
    }
}

private extension Array {
    subscript(lastIndex offset: Int) -> Element { self[count - 1 - offset] }
}
