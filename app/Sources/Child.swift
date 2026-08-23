// Running a helper as a child of the app.
//
// 🛑 THIS IS THE WHOLE REASON THE APP EXISTS. macOS attributes a privacy
// request to the RESPONSIBLE process, which for a child of the app is the app.
// So one Full Disk Access grant on the app covers `apple-mail`, `apple-notes`,
// `apple-messages`, `apple-phone` and `apple-maps` when the APP runs them. A
// launchd agent has no such identity, which is why `apple-index refresh` has
// been a terminal job until now.
//
// 🛑 A tool typed into a terminal is still attributed to the TERMINAL, wherever
// its binary lives. Putting the helpers in the bundle changes nothing about
// that. Only children the app itself spawns inherit the app's grants.

import Foundation

struct ChildResult {
    var status: Int32
    var out: String
    var err: String
    var seconds: Double
    var ok: Bool { status == 0 }
}

enum Child {
    /// The environment every child gets.
    ///
    /// 🛑 THE THREE DISCLAIMING TOOLS RUN AS THE APP, and that is only correct
    /// because the app now holds Calendar, Reminders and Contacts itself.
    ///
    /// `reminders`, `apple-calendar` and `apple-contacts` re-execute themselves
    /// disclaimed, which makes each one its own responsible process. That is
    /// right from a terminal and wrong here: it throws away the app's grants,
    /// and a disclaimed child loses the app's **Full Disk Access** — which
    /// costs `apple contacts` its `has_photo` column and `apple calendar` its
    /// sync tables. `APPLE_TOOLS_OWN_TCC_IDENTITY` makes them skip the re-exec.
    ///
    /// 🛑 THE MARKER STOPS THE DISCLAIM, IT DOES NOT START IT. The name reads
    /// as the opposite of what it does here.
    ///
    /// ⚠️ THIS ONLY WORKS BECAUSE OF TWO ENTITLEMENTS, and without them it
    /// fails silently. `com.apple.security.personal-information.calendars` and
    /// `.addressbook` read as App Sandbox entitlements and are NOT: on macOS
    /// 26+ a non-sandboxed Developer ID app cannot obtain those grants without
    /// them. Measured here — no dialog ever appeared, notarized or not, before
    /// or after a reboot, and every request answered `refused` or `Access
    /// Denied`. Adding the two entitlements granted both immediately. See
    /// `docs/prior-art.md` for where the answer came from.
    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["APPLE_TOOLS_OWN_TCC_IDENTITY"] = "1"
        env["APPLE_TOOLS_TCC_HOST"] = "app"
        // ⚠️ The notes directory goes on PATH too. `apple-notes` and its Python
        // modules live under Resources rather than Helpers, and the `apple`
        // dispatcher finds a tool that is not beside it by looking at PATH.
        var pathParts: [String] = []
        if let helpers = Paths.helpersDirectory { pathParts.append(helpers.path) }
        if let notes = Paths.notesDirectory { pathParts.append(notes.path) }
        if !pathParts.isEmpty {
            env["PATH"] = (pathParts + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
                .joined(separator: ":")
        }
        if let models = Paths.modelsDirectory {
            env["VEC_COREML_DIR"] = models.path
        }
        // ⚠️ A GUI app inherits no terminal, so anything that asks for one gets
        // the answer it deserves. Nothing here may prompt.
        env["APPLE_TOOLS_NONINTERACTIVE"] = "1"
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Run a child to completion and collect everything it said.
    ///
    /// ⚠️ Reads both pipes on their own threads. Draining stdout first and stderr
    /// afterwards deadlocks as soon as a child writes more than a pipe buffer to
    /// stderr, and `apple mail` does exactly that when it reports a scan depth.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String],
                    extraEnvironment: [String: String] = [:],
                    timeout: TimeInterval = 900) -> ChildResult {
        let started = Date()
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = environment(extra: extraEnvironment)
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(outPipe, { outData.append($0) }),
                             (errPipe, { errData.append($0) })]
                as [(Pipe, (Data) -> Void)] {
            group.enter()
            DispatchQueue.global().async {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        do { try task.run() } catch {
            return ChildResult(status: 127, out: "",
                               err: "cannot run \(executable.path): \(error)",
                               seconds: 0)
        }

        // A deadline, because a wedged Mail can hang an Apple Event for minutes
        // and the scheduler must not be held by one.
        let deadline = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        task.waitUntilExit()
        deadline.cancel()
        group.wait()

        return ChildResult(
            status: task.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? "",
            seconds: Date().timeIntervalSince(started))
    }

    /// Run one of the eight tools through the `apple` dispatcher.
    static func apple(_ arguments: [String], timeout: TimeInterval = 120) -> ChildResult {
        guard let helpers = Paths.helpersDirectory else {
            return ChildResult(status: 127, out: "",
                               err: "no `apple` dispatcher found on this machine",
                               seconds: 0)
        }
        return run(helpers.appendingPathComponent("apple"), arguments, timeout: timeout)
    }
}
