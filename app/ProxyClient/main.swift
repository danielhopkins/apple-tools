// The signed client that hands an `apple` command to the app.
//
// 🛑 IT EXISTS TO BE SIGNED. A Python or shell client works just as well over
// the socket, and the app cannot tell one from any other script on the machine:
// their code identity is `/usr/bin/python3`, signed by Apple. A Mach-O signed
// with this developer's identity gives the app something to check.
//
// ⚠️ It is still not a boundary. Anything running as this user can execute this
// binary and read its output. See `PeerIdentity.swift`.
//
// Exit 250 means "the app did not answer", which `bin/apple` reads as "run the
// tool directly". Every other code is the real tool's own, and passes through
// unchanged, because callers branch on 1 vs 2 vs 64 vs 75.

import Foundation

// 🛑 `--serve` makes this the DAEMON. The app spawns it that way, because a
// socket bound by the app process itself refuses every outside connection. See
// Serve.swift for the measurement.
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--serve" {
    Serve.run(socketPath: CommandLine.arguments[2],
              dispatcher: CommandLine.arguments[3],
              logPath: CommandLine.arguments[4])
}

let socketPath = NSString(string:
    "~/Library/Application Support/apple-tools/tools.sock").expandingTildeInPath

func giveUp() -> Never { exit(250) }

guard FileManager.default.fileExists(atPath: socketPath) else { giveUp() }

let handle = socket(AF_UNIX, SOCK_STREAM, 0)
guard handle >= 0 else { giveUp() }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { giveUp() }
withUnsafeMutablePointer(to: &address.sun_path) { raw in
    raw.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { out in
        for (index, byte) in pathBytes.enumerated() { out[index] = CChar(byte) }
        out[pathBytes.count] = 0
    }
}
let size = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, size) }
}
guard connected == 0 else { giveUp() }

// ⚠️ A generous deadline. `apple mail search --field content` reads 40,000
// message bodies and takes ten seconds on a cold store.
var deadline = timeval(tv_sec: 1800, tv_usec: 0)
setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &deadline,
           socklen_t(MemoryLayout<timeval>.size))

let request: [String: Any] = ["op": "run", "args": Array(CommandLine.arguments.dropFirst())]
guard var payload = try? JSONSerialization.data(withJSONObject: request) else { giveUp() }
payload.append(0x0A)
guard payload.withUnsafeBytes({ write(handle, $0.baseAddress, $0.count) }) == payload.count
else { giveUp() }

var data = Data()
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let got = read(handle, &buffer, buffer.count)
    if got <= 0 { break }
    data.append(contentsOf: buffer[0..<got])
    if data.last == 0x0A { break }
}
close(handle)

guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      reply["ok"] as? Bool == true else { giveUp() }

FileHandle.standardOutput.write((reply["stdout"] as? String ?? "").data(using: .utf8)!)
FileHandle.standardError.write((reply["stderr"] as? String ?? "").data(using: .utf8)!)
exit(Int32(reply["status"] as? Int ?? 0))
