// The search endpoint: the app owns it, and supervises it.
//
// `vec daemon` already holds the Core ML model and the whole int8 matrix and
// answers a Unix socket in about 33 ms. It is measured, it is shipped, and its
// protocol is what `apple-index` and the skill already speak. So the app runs
// it as a child and keeps it alive, rather than growing a second copy of it.
//
// 🛑 THE LAUNCHD AGENT AND THE APP CANNOT BOTH SERVE. They bind the same path,
// the second one wins the file and the first one keeps a socket nobody reaches.
// Two daemons raced this socket twice during development and one search took
// 10.7 seconds. So the app boots the agent out before it binds, and says so.

import Foundation

@MainActor
final class SearchService: ObservableObject {
    enum State: Equatable {
        case stopped
        case running(pid: Int32)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var lastPing: [String: Any]? = nil
    @Published private(set) var evictedAgent = false

    private var task: Process?
    private var restarts = 0
    private var stopping = false

    static let agentLabel = "com.boulderhopkins.apple-index"

    // MARK: - the launchd agent

    /// True when the old launchd agent is loaded, whatever state it is in.
    static func agentIsLoaded() -> Bool {
        let result = Child.run(URL(fileURLWithPath: "/bin/launchctl"),
                               ["print", "gui/\(getuid())/\(agentLabel)"],
                               timeout: 10)
        return result.ok
    }

    /// Unload it. ⚠️ `bootout` is asynchronous: the service is still tearing
    /// down when the command returns, so the caller waits for the socket rather
    /// than binding straight away.
    @discardableResult
    static func evictAgent() -> Bool {
        guard agentIsLoaded() else { return false }
        _ = Child.run(URL(fileURLWithPath: "/bin/launchctl"),
                      ["bootout", "gui/\(getuid())/\(agentLabel)"], timeout: 20)
        for _ in 0..<20 {
            if !agentIsLoaded() { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }

    // MARK: - the child

    func start() {
        guard case .running = state else { return launch() }
    }

    private func launch() {
        stopping = false
        guard let vec = Paths.vec else {
            state = .failed("no `vec` binary found. Install apple-tools, or set "
                            + "the toolsRoot default to a checkout.")
            return
        }
        if Self.evictAgent() { evictedAgent = true }
        // A stale socket file from a crashed daemon would make bind() fail.
        try? FileManager.default.removeItem(at: Paths.socket)

        let log = Paths.logDirectory.appendingPathComponent("search.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: log)
        handle?.seekToEndOfFile()

        let task = Process()
        task.executableURL = vec
        task.arguments = ["daemon",
                          "--db", Paths.database.path,
                          "--socket", Paths.socket.path,
                          "--reload-every", "60"]
        task.environment = Child.environment()
        task.standardOutput = handle ?? FileHandle.nullDevice
        task.standardError = handle ?? FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.childExited(status: finished.terminationStatus) }
        }
        do {
            try task.run()
            self.task = task
            state = .running(pid: task.processIdentifier)
        } catch {
            state = .failed("cannot start the search endpoint: \(error)")
        }
    }

    private func childExited(status: Int32) {
        task = nil
        if stopping { state = .stopped; return }
        // ⚠️ Backing off matters: a daemon that cannot load its model exits
        // immediately, and an unbounded restart loop would spin a core and fill
        // the log rather than showing the user one clear failure.
        restarts += 1
        if restarts > 5 {
            state = .failed("the search endpoint exited \(restarts) times "
                            + "(last status \(status)). See logs/search.log.")
            return
        }
        state = .stopped
        let delay = Double(min(restarts, 5)) * 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launch()
        }
    }

    func stop() {
        stopping = true
        task?.terminate()
        task = nil
        state = .stopped
    }

    func restart() {
        restarts = 0
        stop()
        launch()
    }

    // MARK: - talking to it

    /// Ask the endpoint what it is holding. Also the liveness check.
    func refreshPing() {
        let reply = Self.request(["op": "ping"])
        lastPing = reply
    }

    /// Tell it the index moved, rather than waiting up to 60s for it to notice.
    static func reload() {
        _ = request(["op": "reload"], timeout: 60)
    }

    /// One request over the Unix socket. Same wire format `index.py` uses:
    /// one JSON object, newline terminated, one JSON object back.
    static func request(_ body: [String: Any], timeout: TimeInterval = 5) -> [String: Any]? {
        let path = Paths.socket.path
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return nil }
        defer { close(handle) }

        var timeval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeval,
                   socklen_t(MemoryLayout<Foundation.timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeval,
                   socklen_t(MemoryLayout<Foundation.timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { out in
                for (index, byte) in bytes.enumerated() { out[index] = CChar(byte) }
                out[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, size) }
        }
        guard connected == 0 else { return nil }

        guard var payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
        guard sent == payload.count else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let got = read(handle, &buffer, buffer.count)
            if got <= 0 { break }
            data.append(contentsOf: buffer[0..<got])
            if data.last == 0x0A { break }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
