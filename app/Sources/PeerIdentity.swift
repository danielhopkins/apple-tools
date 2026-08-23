// Who is on the other end of the socket, and may they use the app's grants?
//
// 🛑 READ THE LIMIT FIRST, BECAUSE IT GOVERNS EVERYTHING BELOW.
//
// Within one user account, macOS gives no boundary. Everything here runs as the
// same uid, so a program that wants the app's grants can simply EXECUTE the
// approved client and read its output. Verifying the peer's code signature does
// NOT stop that, and nothing available can.
//
// What it does buy, and why it is still worth having:
//
//   ✅ a program cannot speak the protocol DIRECTLY — it must exec our client,
//      which puts our binary in the audit log as the caller
//   ✅ an accidental or careless connection is refused rather than served
//   ✅ the identity in the log is trustworthy, not a self-reported name
//   🛑 it is NOT a boundary against anything running as this user
//
// **The real control stays the setting, which is off by default.**
//
// 🛑 THE AUDIT TOKEN, NEVER THE PID. `LOCAL_PEERPID` is racy: a pid can be
// reused, and a process can exec something else between the connect and the
// check. Apple has said for years to use the audit token, and `LOCAL_PEERTOKEN`
// is how a Unix socket hands one over.

import Foundation
import Security

enum PeerIdentity {
    /// Only a Mach-O signed by this developer, under this identifier, may ask.
    ///
    /// ⚠️ The client MUST be a signed binary of ours for this to say anything.
    /// A Python or shell client's identity is `/usr/bin/python3` or `/bin/bash`,
    /// signed by Apple, which every script on the machine shares — a
    /// requirement matching that grants access to all of them and means nothing.
    static let requirementText = """
        anchor apple generic \
        and certificate leaf[subject.OU] = "25RCAA3JLJ" \
        and identifier "com.boulderhopkins.apple-tools.proxy"
        """

    private static let requirement: SecRequirement? = {
        var out: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &out)
                == errSecSuccess else { return nil }
        return out
    }()

    struct Peer {
        let uid: uid_t
        let pid: pid_t
        /// Nil when the signature could not be read at all.
        let valid: Bool
        let reason: String
    }

    static func check(_ client: Int32) -> Peer {
        var uid: uid_t = 0, gid: gid_t = 0
        getpeereid(client, &uid, &gid)

        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let got = withUnsafeMutablePointer(to: &token) {
            getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &length)
        }
        // ⚠️ `audit_token_to_pid` is unavailable to Swift, and the layout is
        // stable: val[5] is the pid. It is used for the LOG ONLY; the check
        // below uses the whole token.
        let pid = pid_t(bitPattern: got == 0 ? token.val.5 : 0)

        guard got == 0 else {
            return Peer(uid: uid, pid: pid, valid: false,
                        reason: "the kernel gave no audit token for this peer")
        }
        guard let requirement else {
            return Peer(uid: uid, pid: pid, valid: false,
                        reason: "the code requirement did not compile")
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        let found = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard found == errSecSuccess, let code else {
            return Peer(uid: uid, pid: pid, valid: false,
                        reason: "no code identity for the peer (OSStatus \(found))")
        }
        let checked = SecCodeCheckValidity(code, [], requirement)
        guard checked == errSecSuccess else {
            return Peer(uid: uid, pid: pid, valid: false,
                        reason: "the peer is not the signed AppleTools client "
                                + "(OSStatus \(checked))")
        }
        return Peer(uid: uid, pid: pid, valid: true, reason: "signed client")
    }
}
