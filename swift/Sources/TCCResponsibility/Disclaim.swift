import Darwin
import Foundation

/// Make a command-line tool responsible for its own TCC permissions.
///
/// macOS attributes a privacy request not to the process that makes it but to
/// the *responsible process*, which for a CLI is the terminal app that launched
/// it. So the grant lands on Terminal.app or Ghostty, the binary's own signature
/// and its embedded `NSContactsUsageDescription` are never consulted, and the
/// same tool that works in one terminal is denied in another — with
/// `requestAccess` returning "Access Denied" immediately, no dialog, and nothing
/// to toggle in System Settings because no record was ever created.
///
/// `responsibility_spawnattrs_setdisclaim` breaks that inheritance: a process
/// spawned with it is its own responsible process, so TCC keys the grant to
/// *this binary* and shows *this binary's* usage description. It is the same
/// mechanism browsers use to give helper processes their own permissions.
///
/// The SPI lives in libsystem but is declared only in the private
/// `spawn_private.h`, so it is resolved with `dlsym` and skipped silently if it
/// ever goes away — in which case the tool behaves exactly as it did before.
public enum TCCResponsibility {
    /// Set in the re-executed child so it never re-executes again.
    private static let marker = "APPLE_TOOLS_OWN_TCC_IDENTITY"

    /// True once this process owns its TCC identity, either because it is the
    /// re-executed child or because re-execution was not needed.
    public static var isDisclaimed: Bool {
        ProcessInfo.processInfo.environment[marker] != nil
    }

    /// Re-execute this process as its own TCC-responsible process.
    ///
    /// Does nothing when `alreadyAuthorized` is true, so a user who has already
    /// granted their terminal keeps working exactly as before and pays no extra
    /// process launch. Otherwise this spawns a disclaimed copy of the current
    /// binary with the same arguments, wires it to the same stdio, waits for it,
    /// and exits with its status — so from the caller's point of view it simply
    /// never returns.
    ///
    /// Falls through (rather than failing) on any error, leaving the caller to
    /// request access the ordinary way.
    public static func claimOwnIdentity(unless alreadyAuthorized: Bool) {
        if alreadyAuthorized || isDisclaimed { return }

        // RTLD_DEFAULT. The SPI is unavailable to Swift's importer because it is
        // declared only in spawn_private.h.
        typealias Disclaim = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "responsibility_spawnattrs_setdisclaim") else { return }
        let setDisclaim = unsafeBitCast(symbol, to: Disclaim.self)

        guard let executable = Bundle.main.executablePath ?? CommandLine.arguments.first
        else { return }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return }
        defer { posix_spawnattr_destroy(&attributes) }

        // The C parameter is `posix_spawnattr_t *`, and posix_spawnattr_t is
        // itself a pointer — so this passes &attributes, not attributes.
        let disclaimed = withUnsafeMutablePointer(to: &attributes) {
            setDisclaim(UnsafeMutableRawPointer($0), 1)
        }
        guard disclaimed == 0 else { return }

        var argv: [UnsafeMutablePointer<CChar>?] =
            CommandLine.arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
            + [strdup("\(marker)=1"), nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        // No file actions: the child inherits stdin/stdout/stderr, so output and
        // exit codes pass through unchanged.
        var child: pid_t = 0
        guard posix_spawn(&child, executable, nil, &attributes, &argv, &envp) == 0
        else { return }

        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}

        if status & 0x7f == 0 {
            exit((status >> 8) & 0xff)
        }
        // Killed by a signal — reproduce that rather than inventing an exit code.
        let signalNumber = status & 0x7f
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
        exit(128 + signalNumber)
    }
}
