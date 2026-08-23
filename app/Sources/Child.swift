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
    /// 🛑 `APPLE_TOOLS_OWN_TCC_IDENTITY` STOPS the disclaim, it does not start
    /// it. `reminders`, `apple-calendar` and `apple-contacts` re-execute
    /// themselves disclaimed so that a TERMINAL's grant is not what TCC keys on.
    /// Inside the app that is exactly wrong: disclaiming makes each tool its own
    /// responsible process, which throws away the app's grants and asks for
    /// three more from a process with no window to show a dialog in. The marker
    /// makes them skip the re-exec and run as the app.
    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["APPLE_TOOLS_OWN_TCC_IDENTITY"] = "1"
        env["APPLE_TOOLS_TCC_HOST"] = "app"
        if let helpers = Paths.helpersDirectory {
            env["PATH"] = helpers.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
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
