// Encryption at rest, for a file that holds the plaintext of every email.
//
// 🛑 SQLCIPHER IS NOT AVAILABLE TO THIS ARCHITECTURE, and the design doc named
// it without checking. Two processes open the index: `index.py`, which uses
// Python's STDLIB `sqlite3`, and `vec`, which uses the system `SQLite3` module.
// Neither can open a SQLCipher file. Reaching it would mean a C extension in
// Python — against the stdlib-only rule the ingest path is built on — and
// vendoring SQLCipher into `vec`. That is a rewrite of the ingest path, not an
// encryption option.
//
// So the index moves into an ENCRYPTED APFS DISK IMAGE. Both readers then see
// an ordinary SQLite file on a mounted volume, and neither changes at all.
//
// 🛑 BE HONEST ABOUT WHAT THIS BUYS. It protects the index AT REST:
//
//   ✅ a Time Machine or cloud backup copies ciphertext
//   ✅ a stolen disk gives up nothing
//   ✅ deleting the key makes 812 MB of decoded mail inert — real revocation,
//      which is what `lab/SECURITY.md` asks for and never had
//   🛑 WHILE MOUNTED, any process running as this user can still read it
//
// That last line is the same exposure the plaintext file always had, now
// limited to the time the app is running rather than forever. It is an
// improvement and it is not a solution. Anything stronger needs the readers
// themselves to hold a key, which is the SQLCipher work above.

import Foundation
import SQLite3
import Security

@MainActor
final class Vault: ObservableObject {
    enum State: Equatable {
        case absent           // no image yet; the index is a plain file
        case locked           // the image exists and is not mounted
        case mounted
        case failed(String)
    }

    @Published private(set) var state: State = .absent

    nonisolated static let volumeName = "AppleToolsIndex"
    /// ⚠️ `-nobrowse` and a private mount point, so the volume never appears in
    /// the Finder sidebar. A user ejecting it by hand would take the index out
    /// from under a running ingest.
    nonisolated static var mountPoint: URL {
        Paths.supportDirectory.appendingPathComponent("mnt", isDirectory: true)
    }
    nonisolated static var image: URL {
        Paths.supportDirectory.appendingPathComponent("index.sparsebundle")
    }
    /// Where the index lives once the vault holds it.
    nonisolated static var databaseInVault: URL {
        mountPoint.appendingPathComponent("lab-index.db")
    }

    nonisolated private static let keychainService = "com.boulderhopkins.apple-tools.index"
    nonisolated private static let keychainAccount = "index-vault"

    // MARK: - state

    func read() {
        guard FileManager.default.fileExists(atPath: Self.image.path) else {
            state = .absent
            return
        }
        state = isMounted() ? .mounted : .locked
    }

    /// ⚠️ Ask the filesystem, not `hdiutil info`. A stale mount record outlives
    /// the mount, and the only question that matters is whether the database is
    /// readable right now.
    func isMounted() -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Self.mountPoint.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        // An unmounted mount point is an empty ordinary directory.
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: Self.mountPoint.path)) ?? []
        return !contents.isEmpty
    }

    // MARK: - the key

    /// 🛑 NEVER on a command line. `hdiutil ... -passphrase <secret>` puts the
    /// key in `ps` output for every process on the machine. Everything here
    /// pipes it through stdin instead, and the Keychain item is written with
    /// `SecItemAdd` rather than the `security` tool for the same reason.
    nonisolated static func storeKey(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        // 🛑 NO BLIND `SecItemDelete` FIRST. A delete-then-add is the usual
        // recipe and it is the wrong shape: the query is a MATCH, not an
        // address, and anything the attributes happen to match goes with it.
        // Update an existing item instead, and add only when there is none.
        var probe = query
        probe[kSecUseDataProtectionKeychain as String] = true
        if SecItemCopyMatching(probe as CFDictionary, nil) == errSecSuccess {
            let update = [kSecValueData as String: key.data(using: .utf8)!]
            let status = SecItemUpdate(probe as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else {
                throw Failure("cannot update the vault key: OSStatus \(status)")
            }
            return
        }
        var add = query
        add[kSecUseDataProtectionKeychain as String] = true
        add[kSecValueData as String] = key.data(using: .utf8)!
        // ⚠️ `AfterFirstUnlock`, not `WhenUnlocked`. The app refreshes the
        // index on a schedule while the screen is locked, and a key that
        // disappears at lock would break every one of those runs.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure("cannot store the vault key: OSStatus \(status)")
        }
    }

    nonisolated static func readKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deleting the key is the revocation path. The image stays and is inert.
    nonisolated static func destroyKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
    }

    nonisolated static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - hdiutil

    /// Run `hdiutil` with the key on STDIN.
    @discardableResult
    nonisolated private static func hdiutil(_ arguments: [String], key: String?) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = arguments
        let input = Pipe(), out = Pipe(), err = Pipe()
        task.standardInput = input
        task.standardOutput = out
        task.standardError = err
        try task.run()
        if let key {
            input.fileHandleForWriting.write(key.data(using: .utf8)!)
        }
        input.fileHandleForWriting.closeFile()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw Failure("hdiutil \(arguments.first ?? "") failed: "
                          + (String(data: stderr, encoding: .utf8) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: stdout, encoding: .utf8) ?? ""
    }

    /// Create the image. ⚠️ A sparse bundle only uses what it holds, so the
    /// size below is a ceiling, not an allocation.
    nonisolated static func create(gigabytes: Int = 40) throws {
        let key = newKey()
        try storeKey(key)
        try hdiutil(["create",
                     "-size", "\(gigabytes)g",
                     "-type", "SPARSEBUNDLE",
                     "-fs", "APFS",
                     "-volname", volumeName,
                     "-encryption", "AES-256",
                     "-stdinpass",
                     "-quiet",
                     image.path], key: key)
    }

    nonisolated static func mount() throws {
        guard let key = readKey() else {
            throw Failure("the vault key is gone from the Keychain. The index "
                          + "cannot be opened, which is what deleting the key "
                          + "is for. Rebuild with: apple-index refresh")
        }
        try FileManager.default.createDirectory(at: mountPoint,
                                                withIntermediateDirectories: true)
        try hdiutil(["attach", image.path,
                     "-stdinpass",
                     "-nobrowse",
                     "-mountpoint", mountPoint.path,
                     "-quiet"], key: key)
    }

    /// Give back the space a sparse bundle is holding but not using.
    ///
    /// ⚠️ A sparse bundle GROWS AND NEVER SHRINKS on its own. After the move it
    /// held 1.9 GB for an 812 MB database, because the copy allocated bands
    /// that the delete then freed inside the volume and not outside it.
    /// `hdiutil compact` needs the image DETACHED, so this runs at quit.
    nonisolated static func compact() {
        guard FileManager.default.fileExists(atPath: image.path),
              let key = readKey() else { return }
        _ = try? hdiutil(["compact", image.path, "-stdinpass", "-quiet"], key: key)
    }

    nonisolated static func unmount() {
        // ⚠️ Best effort. A busy volume refuses, and forcing it while an ingest
        // is writing would corrupt the index.
        _ = try? hdiutil(["detach", mountPoint.path, "-quiet"], key: nil)
    }
}

// MARK: - moving an existing index in

extension Vault {
    /// Move a plaintext index into the vault, or report exactly why not.
    ///
    /// 🛑 THE ORIGINAL IS DELETED ONLY AFTER THE COPY IS VERIFIED. The file is
    /// 812 MB on this machine and rebuilding it costs about eight minutes, but
    /// a half-migrated index that looks complete is far worse than a missing
    /// one. So: copy, open the copy, compare the row counts, and only then
    /// remove the plaintext.
    ///
    /// ⚠️ IT TAKES THE INGEST LOCK FIRST. `index.py` holds an advisory `flock`
    /// on `<db>.lock` for the whole of an ingest, and copying a database out
    /// from under a writer produces a file that opens cleanly and is missing
    /// rows.
    nonisolated static func migrateIfNeeded(log: @escaping (String) -> Void) throws -> Bool {
        let plain = Paths.plainDatabase
        guard FileManager.default.fileExists(atPath: plain.path) else { return false }
        guard !FileManager.default.fileExists(atPath: databaseInVault.path) else {
            return false
        }

        let lock = open(plain.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure("cannot open the ingest lock") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure("an ingest is running. The index moves into the "
                          + "vault when that finishes.")
        }

        // 🛑 CHECKPOINT FIRST. A copy that leaves the write-ahead log behind
        // silently loses everything in it, and on this store that has been
        // 2.2 MB of the most recent mail.
        log("checkpointing the index…")
        try checkpoint(plain)

        let sourceRows = try rowCounts(plain)
        log("moving \(sourceRows.records) records into the encrypted vault…")

        if !FileManager.default.fileExists(atPath: image.path) {
            log("creating the encrypted image…")
            try create()
        }
        if !(try Vault.mountedNow()) {
            log("mounting…")
            try mount()
        }

        let staging = mountPoint.appendingPathComponent("lab-index.db.incoming")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: plain, to: staging)

        let copiedRows = try rowCounts(staging)
        guard copiedRows == sourceRows else {
            try? FileManager.default.removeItem(at: staging)
            throw Failure("the copy does not match: \(sourceRows) became "
                          + "\(copiedRows). Nothing was deleted.")
        }
        // ⚠️ Rename only after the check, so a crash mid-copy leaves an
        // `.incoming` file rather than a short index under the real name.
        try FileManager.default.moveItem(at: staging, to: databaseInVault)

        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: plain.path + suffix)
            // ⚠️ The staging file's SIDECARS too. Removing `.incoming` alone
            // left `-wal` and `-shm` behind inside the vault, where they look
            // like a second half-written index.
            try? FileManager.default.removeItem(atPath: staging.path + suffix)
        }
        log("moved. The plaintext index is gone.")
        return true
    }

    nonisolated static func mountedNow() throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountPoint.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return !((try? FileManager.default.contentsOfDirectory(
            atPath: mountPoint.path)) ?? []).isEmpty
    }

    nonisolated private static func checkpoint(_ path: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE, nil)
                == SQLITE_OK, let db = handle else {
            throw Failure("cannot open \(path.lastPathComponent) to checkpoint it")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 30_000)
        guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                == SQLITE_OK else {
            throw Failure("the checkpoint failed; nothing was moved")
        }
    }

    nonisolated private static func rowCounts(_ path: URL) throws -> Counts {
        var handle: OpaquePointer?
        // 🛑 A plain path. An unencoded space in a `file:` URI makes every
        // `prepare` fail with "no such table" on a database that is perfectly
        // readable — which is exactly how this migration failed the first time.
        guard sqlite3_open_v2(path.path, &handle,
                              SQLITE_OPEN_READONLY, nil)
                == SQLITE_OK, let db = handle else {
            throw Failure("cannot read \(path.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        func count(_ table: String) throws -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1,
                                     &statement, nil) == SQLITE_OK,
                  let prepared = statement else {
                throw Failure("\(path.lastPathComponent) has no \(table) table")
            }
            defer { sqlite3_finalize(prepared) }
            guard sqlite3_step(prepared) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(prepared, 0))
        }
        return Counts(records: try count("record"),
                      chunks: try count("chunk"),
                      vectors: try count("vector"))
    }

    struct Counts: Equatable, CustomStringConvertible {
        let records: Int, chunks: Int, vectors: Int
        var description: String { "\(records)r/\(chunks)c/\(vectors)v" }
    }
}
