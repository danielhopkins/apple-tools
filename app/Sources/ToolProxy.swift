// Running a tool on behalf of a terminal, so the APP's grant is what counts.
//
// This is Route B from `docs/todo-index-app.md`. A tool typed into a terminal
// is attributed to the TERMINAL, wherever its binary lives, so `apple mail
// search` in Ghostty needs Ghostty's Full Disk Access. The app's grant only
// covers children the app itself spawns. So the shim hands the argument vector
// here, the app spawns the real tool, and stdout, stderr and the exit code go
// back. One grant, on the app, and every terminal works.
//
// 🛑 THIS IS A SECURITY DECISION, NOT A CONVENIENCE, AND IT IS OFF BY DEFAULT.
// With it on, the app will read the user's mail, messages, notes, calendar and
// contacts on behalf of ANY process running as this user, with no prompt and no
// dialog. `lab/SECURITY.md` already concedes that the index file has that
// property; this extends it from one file to every store.
//
//   defaults write com.boulderhopkins.apple-tools toolProxy -bool true
//
// ⚠️ THE SOCKET'S ONLY BOUNDARY IS THE FILE MODE. 0600 in a 0700 directory
// means "this user", which is exactly the attacker the setting is about. There
// is no stronger check available that would mean anything: any process that can
// connect can also read the mounted index, and could equally well ask the user
// to approve its own grant.
//
// ⚠️ SO EVERY PROXIED COMMAND IS LOGGED, with a timestamp and the caller's pid.
// An audit trail is the one mitigation that costs nothing and is worth having.

import Foundation

@MainActor
final class ToolProxy: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var served = 0
    @Published private(set) var lastCommand: String? = nil

    nonisolated static var socket: URL {
        Paths.supportDirectory.appendingPathComponent("tools.sock")
    }
    nonisolated static var log: URL {
        Paths.logDirectory.appendingPathComponent("proxy.log")
    }

    /// 🛑 Read every time, not cached. Turning the setting off must stop the
    /// service, and a cached copy would keep it answering.
    nonisolated static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "toolProxy")
    }

    private var task: Process?

    func apply() {
        if Self.enabled { start() } else { stop() }
    }

    /// 🛑 SPAWN A CHILD TO OWN THE SOCKET. The app process cannot: a Unix
    /// socket bound by AppleTools.app itself refuses every connection from
    /// another process with ECONNREFUSED, while the app connects to it fine.
    /// `index.sock`, bound by `vec daemon`, sits in the same directory with the
    /// same mode and owner and any shell reaches it. The only difference is
    /// which process called bind(), and that difference cost hours — `lsof`
    /// shows neither socket, so it could not tell them apart either.
    ///
    /// ⚠️ The TCC identity is unaffected. Responsibility runs down the whole
    /// process tree, so a tool this daemon spawns is still attributed to the
    /// app.
    func start() {
        guard !running,
              let helpers = Paths.helpersDirectory,
              case let daemon = helpers.appendingPathComponent("apple-proxy"),
              FileManager.default.isExecutableFile(atPath: daemon.path)
        else { return }

        let child = Process()
        child.executableURL = daemon
        child.arguments = ["--serve", Self.socket.path,
                           helpers.appendingPathComponent("apple").path,
                           Self.log.path]
        child.environment = Child.environment()
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.running = false; self?.task = nil }
        }
        do {
            try child.run()
            task = child
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        task?.terminate()
        task = nil
        running = false
        // ⚠️ Remove the socket file too. A file left behind looks live to the
        // shim, which then connects to nothing and reports a confusing error
        // instead of "the proxy is off".
        unlink(Self.socket.path)
    }

    /// What the daemon has served, for the window.
    ///
    /// ⚠️ Read from the log file rather than counted in memory. The daemon is a
    /// separate process now, so the app never sees a request go past.
    func readActivity() {
        guard let text = try? String(contentsOf: Self.log, encoding: .utf8) else { return }
        let commands = text.split(separator: "\n").filter { $0.contains(": apple ") }
        served = commands.count
        lastCommand = commands.last.map {
            String($0[($0.range(of: ": apple ")?.lowerBound ?? $0.startIndex)...]
                .dropFirst(2))
        }
    }
}
