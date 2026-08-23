// Indexing on a schedule, which is the thing a CLI could never do.
//
// 🛑 A launchd agent has NO Full Disk Access — measured on mail, notes and
// messages alike — so `apple-index refresh` has been a terminal job. The app
// holds the grant, and a child of the app inherits it. That is the whole reason
// this file exists.
//
// 🛑 NEVER TWO INGESTS AT ONCE. One serial queue and one flag, because the user
// can press Refresh while the scheduler is already running one, and two writers
// on the same SQLite file is how an index gets a half-written record.

import Foundation
import AppKit

struct SourceRun: Identifiable, Equatable {
    var id: String { source }
    let source: String
    var added = 0
    var updated = 0
    var removed = 0
    var total = 0
    var seconds = 0.0
    var error: String? = nil
    var finished = Date()
    var changed: Bool { added != 0 || updated != 0 || removed != 0 }
}

@MainActor
final class Indexer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case ingesting(source: String)
        case embedding
        case reloading
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var runs: [String: SourceRun] = [:]
    @Published private(set) var lastCycleStarted: Date? = nil
    @Published private(set) var lastCycleFinished: Date? = nil
    @Published private(set) var lastCycleError: String? = nil
    @Published private(set) var lastFullSweep: Date? = nil
    @Published var automatic = true

    /// 🛑 Read from `index.py sources --json`, never copied into Swift. The
    /// arguments differ per source and two copies of them drift.
    private(set) var sourceArguments: [String: [String]] = [:]
    private(set) var sources: [String] = []
    /// True when `index.py` could not be asked, so the list above is a guess.
    @Published private(set) var sourcesAreStale = false

    private let queue = DispatchQueue(label: "com.boulderhopkins.apple-tools.indexer")
    private var running = false
    private var current: Process?
    private var scheduler: NSBackgroundActivityScheduler?
    private let state = Paths.supportDirectory.appendingPathComponent("app-state.json")

    /// Five minutes. A "did anything change" sweep costs about 0.1s and a
    /// no-change incremental run 0.1–3.1s per source, so this is cheap.
    static let interval: TimeInterval = 300
    /// ⚠️ Deletion detection is a full id-set sweep, so it runs weekly, not
    /// every five minutes. The 20% deletion guard in `index.py` stays on.
    static let fullSweepInterval: TimeInterval = 7 * 24 * 3600

    init() {
        loadState()
        readSources()
    }

    // MARK: - what refresh runs

    private func readSources() {
        guard let script = Paths.indexScript else { return }
        let result = Child.run(Paths.python, [script.path, "sources"], timeout: 30)
        guard result.ok, let data = result.out.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
                as? [String: [String]]
        else {
            // ⚠️ An older `index.py` has no `sources` command. Indexing still
            // runs, on the fallback list and with no per-source arguments —
            // which means mail WITHOUT bodies. Say so rather than looking fine.
            sourcesAreStale = true
            return
        }
        sourcesAreStale = false
        sourceArguments = parsed
        // ⚠️ Keep `index.py`'s own order rather than sorting: `maps` being
        // last is why a KeyError there once killed a run before the embed step.
        sources = Paths.indexSources.filter { parsed[$0] != nil }
            + parsed.keys.filter { !Paths.indexSources.contains($0) }.sorted()
    }

    // MARK: - the schedule

    func startScheduling() {
        // 🛑 NSBackgroundActivityScheduler, not a Timer and not a launchd
        // StartInterval. It defers on battery and under thermal pressure, and a
        // reindex is exactly the work that should wait for a better moment.
        let activity = NSBackgroundActivityScheduler(
            identifier: "com.boulderhopkins.apple-tools.refresh")
        activity.repeats = true
        activity.interval = Self.interval
        activity.tolerance = 60
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self, self.automatic else { return completion(.finished) }
                self.refresh(full: self.fullSweepIsDue()) { completion(.finished) }
            }
        }
        scheduler = activity

        // ⚠️ Most staleness arrives while the lid is shut, so wake and unlock
        // are worth as much as the interval.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.automatic else { return }
                    self.refresh(full: self.fullSweepIsDue())
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automatic else { return }
                self.refresh(full: self.fullSweepIsDue())
            }
        }
    }

    private func fullSweepIsDue() -> Bool {
        guard let last = lastFullSweep else { return true }
        return Date().timeIntervalSince(last) > Self.fullSweepInterval
    }

    // MARK: - one cycle

    var isRunning: Bool { running }

    func refresh(full: Bool = false, then finished: (() -> Void)? = nil) {
        guard !running else { finished?(); return }
        guard let script = Paths.indexScript else {
            lastCycleError = "no index.py found. Install apple-tools, or set the "
                + "toolsRoot default to a checkout."
            finished?()
            return
        }
        if sourceArguments.isEmpty { readSources() }
        running = true
        lastCycleStarted = Date()
        lastCycleError = nil
        let order = sources.isEmpty ? Paths.indexSources : sources
        // 🛑 Copy the arguments HERE, on the main actor. Reading them from the
        // background queue is a data race that the compiler lets through in
        // Swift 5 mode and that shows up as an empty argument list.
        let perSource = sourceArguments

        queue.async { [weak self] in
            guard let self else { return }
            var sawChange = false
            var failures: [String] = []

            for source in order {
                Task { @MainActor in self.phase = .ingesting(source: source) }

                var arguments = [script.path, "--db", Paths.database.path,
                                 "ingest", "--source", source]
                arguments += perSource[source] ?? []
                // The app records consent in its own window, and `index.py`
                // keeps the record. A GUI child has no terminal to ask from.
                arguments.append("--accept-risk")
                if full { arguments.append("--full") }

                let result = Child.run(Paths.python, arguments, timeout: 3600)
                var run = SourceRun(source: source)
                run.seconds = result.seconds
                if result.ok {
                    Self.parse(result.out, source: source, into: &run)
                    if run.changed { sawChange = true }
                } else {
                    // 🛑 NOT just the last stderr line. An argument-parser
                    // usage message ends with "See 'apple-calendar --help'",
                    // which names nothing — the real failure sits above it. A
                    // first version reported exactly that for two sources and
                    // hid a permission error behind a help pointer.
                    run.error = Self.summarise(result.err, status: result.status)
                    Self.writeLog(source: source, result: result)
                    failures.append("\(source): \(run.error!)")
                }
                Task { @MainActor in self.runs[source] = run }
            }

            if sawChange {
                Task { @MainActor in self.phase = .embedding }
                let result = Child.run(Paths.python,
                                       [script.path, "--db", Paths.database.path,
                                        "embed", "--model", "e5-small-coreml"],
                                       timeout: 6 * 3600)
                if !result.ok {
                    failures.append("embed: " + (result.err.split(separator: "\n")
                        .last.map(String.init) ?? "exit \(result.status)"))
                }
            }

            Task { @MainActor in
                self.phase = .reloading
                // Tell the endpoint the index moved rather than making it wait
                // out its own 60s poll.
                if sawChange { SearchService.reload() }
                self.phase = .idle
                self.running = false
                self.lastCycleFinished = Date()
                self.lastCycleError = failures.isEmpty ? nil : failures.joined(separator: "; ")
                if full { self.lastFullSweep = Date() }
                self.saveState()
                finished?()
            }
        }
    }

    /// The last few meaningful stderr lines, in one line.
    static func summarise(_ stderr: String, status: Int32) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("See '") }
        guard !lines.isEmpty else { return "exit \(status), and it said nothing" }
        return String(lines.suffix(3).joined(separator: " · ").prefix(300))
    }

    /// The whole of what a failing source said, so the one-line summary above
    /// is never the only copy.
    static func writeLog(source: String, result: ChildResult) {
        let path = Paths.logDirectory.appendingPathComponent("ingest-\(source).log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "=== \(stamp)  exit \(result.status)  \(result.seconds)s ===\n"
            + result.err + "\n" + result.out + "\n"
        try? body.data(using: .utf8)?.write(to: path, options: .atomic)
    }

    /// Parse `notes     +3 ~1 -0  (939 total, 2.4s)`.
    static func parse(_ output: String, source: String, into run: inout SourceRun) {
        let pattern = #"^\#(source)\s+\+(\d+) ~(\d+) -(\d+)\s+\((\d+) total, ([\d.]+)s\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else { return }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range) else { return }
        // 🛑 CHECK THE INDEX. `rangeAtIndex:` past the last group RAISES an
        // Objective-C exception, which terminates the process rather than
        // returning nil — so an off-by-one here is a crash, not a wrong number.
        // It cost one: asking for group 6 of a five-group pattern killed the
        // app the first time a source SUCCEEDED, and only then.
        func number(_ index: Int) -> Double {
            guard index < match.numberOfRanges,
                  let r = Range(match.range(at: index), in: output) else { return 0 }
            return Double(output[r]) ?? 0
        }
        run.added = Int(number(1))
        run.updated = Int(number(2))
        run.removed = Int(number(3))
        run.total = Int(number(4))
        run.seconds = number(5)
    }

    func cancel() {
        current?.terminate()
    }

    // MARK: - what survives a restart

    private struct Saved: Codable {
        var lastCycleFinished: Date?
        var lastFullSweep: Date?
        var lastCycleError: String?
        var automatic: Bool?
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: state),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        lastCycleFinished = saved.lastCycleFinished
        lastFullSweep = saved.lastFullSweep
        lastCycleError = saved.lastCycleError
        automatic = saved.automatic ?? true
    }

    func saveState() {
        let saved = Saved(lastCycleFinished: lastCycleFinished,
                          lastFullSweep: lastFullSweep,
                          lastCycleError: lastCycleError,
                          automatic: automatic)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: state, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: state.path)
    }
}
