// The proxy daemon, which runs as a CHILD of the app.
//
// 🛑 THE APP PROCESS CANNOT OWN THIS SOCKET, and that is measured, not assumed.
// A Unix socket bound by AppleTools.app itself refuses every connection from
// another process with ECONNREFUSED, while the app connects to it perfectly
// well. The search socket, bound by `vec daemon`, sits in the SAME directory
// with the SAME mode and the SAME owner, and any shell connects to it. The one
// difference is which process called bind().
//
//   index.sock   bound by `vec daemon`, a child   -> shell connects
//   tools.sock   bound by the app process         -> ECONNREFUSED
//
// So the accept loop lives here, in a child the app spawns, exactly as the
// search endpoint already does.
//
// ⚠️ THE TCC IDENTITY STILL COMES FROM THE APP. Responsibility is inherited
// down the whole process tree, so a tool this daemon spawns is attributed to
// the app, not to this binary. That is the same property `index.py` relies on
// when the app runs it.

import Foundation
import Security

enum Serve {
    static func run(socketPath: String, dispatcher: String, logPath: String) -> Never {
        note(logPath, "proxyd starting for \(dispatcher)")
        unlink(socketPath)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { fail(logPath, "cannot create a socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            fail(logPath, "socket path too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { out in
                for (index, byte) in bytes.enumerated() { out[index] = CChar(byte) }
                out[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0 else {
            fail(logPath, "cannot bind: \(String(cString: strerror(errno)))")
        }
        // 🛑 Owner only. Anything that can connect can read every store the app
        // can reach.
        chmod(socketPath, 0o600)
        guard listen(listener, 16) == 0 else { fail(logPath, "cannot listen") }
        note(logPath, "proxyd listening on \(socketPath)")

        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            Thread.detachNewThread {
                handle(client, dispatcher: dispatcher, logPath: logPath)
                close(client)
            }
        }
    }

    private static func handle(_ client: Int32, dispatcher: String, logPath: String) {
        var uid: uid_t = 0, gid: gid_t = 0
        getpeereid(client, &uid, &gid)
        guard uid == getuid() else { return }

        let peer = PeerIdentity.check(client)
        guard peer.valid else {
            note(logPath, "refused pid \(peer.pid): \(peer.reason)")
            reply(client, ["ok": false, "error": "refused: \(peer.reason)"])
            return
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let got = read(client, &buffer, buffer.count)
            if got <= 0 { break }
            data.append(contentsOf: buffer[0..<got])
            if data.last == 0x0A { break }
        }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["op"] as? String == "run",
              let arguments = request["args"] as? [String], !arguments.isEmpty else {
            reply(client, ["ok": false, "error": "expected {op:\"run\", args:[…]}"])
            return
        }

        note(logPath, "pid \(peer.pid): apple " + arguments.joined(separator: " "))

        // 🛑 ALWAYS THROUGH THE `apple` DISPATCHER, never a path from the
        // request. The caller picks a subcommand and its flags, which is broad
        // enough; it must not also pick the executable.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: dispatcher)
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice

        // ⚠️ Both pipes on their own threads. Draining one and then the other
        // deadlocks as soon as a child fills a pipe buffer on the second, and
        // `apple mail` writes its scan depth to stderr.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(out, { outData.append($0) }),
                             (err, { errData.append($0) })] as [(Pipe, (Data) -> Void)] {
            group.enter()
            DispatchQueue.global().async {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        do { try task.run() } catch {
            reply(client, ["ok": false, "error": "cannot run \(dispatcher): \(error)"])
            return
        }
        task.waitUntilExit()
        group.wait()

        reply(client, ["ok": true,
                       "status": Int(task.terminationStatus),
                       "stdout": String(data: outData, encoding: .utf8) ?? "",
                       "stderr": String(data: errData, encoding: .utf8) ?? ""])
    }

    private static func reply(_ client: Int32, _ body: [String: Any]) {
        guard var encoded = try? JSONSerialization.data(withJSONObject: body) else { return }
        encoded.append(0x0A)
        _ = encoded.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    /// ⚠️ O_APPEND, never "open, seek, write". Two threads that both find the
    /// file missing and both write atomically lose one line, and the lost line
    /// is always the one that would have explained the failure.
    static func note(_ path: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    private static func fail(_ path: String, _ message: String) -> Never {
        note(path, "FATAL: " + message)
        exit(1)
    }
}
