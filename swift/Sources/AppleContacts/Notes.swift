import Foundation
import SQLite3

/// Contact notes are deliberately walled off from the Contacts framework:
/// `CNContactNoteKey` has required the `com.apple.developer.contacts.notes`
/// entitlement since macOS 10.15, and Apple only grants that to signed apps by
/// request — an ad-hoc-signed CLI can never have it.
///
/// The AddressBook SQLite stores have no such restriction, so notes are read
/// from there. This is READ ONLY. Writing to these stores would desynchronise
/// Core Data's change tracking and CloudKit sync state; note edits have to
/// happen in Contacts.app.
enum NoteStore {
    private static let base = ("~/Library/Application Support/AddressBook" as NSString)
        .expandingTildeInPath

    /// Every AddressBook source database on this machine.
    private static func databases() -> [String] {
        let manager = FileManager.default
        var found: [String] = []

        let sources = (base as NSString).appendingPathComponent("Sources")
        if let entries = try? manager.contentsOfDirectory(atPath: sources) {
            for entry in entries.sorted() {
                let candidate = (sources as NSString)
                    .appendingPathComponent(entry)
                    .appending("/AddressBook-v22.abcddb")
                if manager.fileExists(atPath: candidate) { found.append(candidate) }
            }
        }

        let root = (base as NSString).appendingPathComponent("AddressBook-v22.abcddb")
        if manager.fileExists(atPath: root) { found.append(root) }

        return found
    }

    /// Map of contact identifier -> note text, across every source database.
    ///
    /// `CNContact.identifier` is a bare UUID; `ZABCDRECORD.ZUNIQUEID` is that
    /// UUID suffixed with ":ABPerson". Both forms are keyed so callers can look
    /// up with whichever they hold.
    static func allNotes() -> [String: String] {
        var notes: [String: String] = [:]

        for path in databases() {
            // 🛑 **`immutable=1` alone is wrong here, and it silently hid notes.**
            //
            // Contacts leaves a large write-ahead log behind — megabytes against
            // this store — and `immutable=1` tells sqlite the file cannot change,
            // so it does **not** replay it. A note written minutes ago lives only
            // in that log and is invisible; the log carries deletions too, so a
            // note removed minutes ago still reads as present. Stale in both
            // directions, with no error.
            //
            // Measured while building `move`: a note planted seconds earlier was
            // not seen here, so the up-front "this contact has a note" refusal
            // never fired and the move fell through to the exception guard
            // instead. `apple phone` hit the same trap resolving caller names
            // and fixed it the same way.
            //
            // So: a plain read-only open first, which replays the log, and
            // `immutable=1` only as a fallback for when that fails.
            var handle: OpaquePointer?
            var status = sqlite3_open_v2(
                "file:\(path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            if status != SQLITE_OK {
                sqlite3_close(handle)
                handle = nil
                status = sqlite3_open_v2(
                    "file:\(path)?immutable=1", &handle,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            }
            guard status == SQLITE_OK else {
                sqlite3_close(handle)
                continue
            }
            defer { sqlite3_close(handle) }
            // Belt and braces: never let a read path take a write lock on a
            // store that syncs to every one of the user's devices.
            sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)

            let sql = """
                SELECT r.ZUNIQUEID, n.ZTEXT
                FROM ZABCDNOTE n
                JOIN ZABCDRECORD r ON n.ZCONTACT = r.Z_PK
                WHERE n.ZTEXT IS NOT NULL AND n.ZTEXT != ''
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                continue
            }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idRaw = sqlite3_column_text(statement, 0),
                      let textRaw = sqlite3_column_text(statement, 1) else { continue }

                let uniqueId = String(cString: idRaw)
                let text = String(cString: textRaw)

                notes[uniqueId] = text
                // "UUID:ABPerson" -> "UUID", which is what CNContact reports.
                if let bare = uniqueId.split(separator: ":").first {
                    notes[String(bare)] = text
                }
            }
        }

        return notes
    }

    /// Every contact that carries a picture, by identifier.
    ///
    /// 🛑 **`CNContact.imageDataAvailable` is NOT the answer, and it is wrong in
    /// the flattering direction.** It reports true only for `ZIMAGEDATA`, the
    /// full-size copy. A card whose picture lives in `ZTHUMBNAILIMAGEDATA`
    /// alone reads back as having no picture at all — while Contacts.app shows
    /// the photo perfectly well.
    ///
    /// That is not a rare corner. Measured on this store: 444 cards carry a
    /// picture, 341 have `ZIMAGEDATA`, and **103 are thumbnail-only**. Worse,
    /// a card written through `--photo` lands in the full column and is moved
    /// to the thumbnail column soon after, so a write confirmed as present
    /// starts reporting absent minutes later. Six real contacts did exactly
    /// that, and the write had been correct every time.
    ///
    /// So presence is read from the store, the same way a note is. This reads
    /// ids only — never a blob — so it costs nothing next to the ~100 KB per
    /// picture a `CNContactImageDataKey` fetch would pull.
    static func contactsWithPhotos() -> Set<String> {
        var found: Set<String> = []

        for path in databases() {
            var handle: OpaquePointer?
            var status = sqlite3_open_v2(
                "file:\(path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            if status != SQLITE_OK {
                sqlite3_close(handle)
                handle = nil
                status = sqlite3_open_v2(
                    "file:\(path)?immutable=1", &handle,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            }
            guard status == SQLITE_OK else {
                sqlite3_close(handle)
                continue
            }
            defer { sqlite3_close(handle) }
            sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)

            // `IS NOT NULL` on a blob column does not read the blob, so this
            // stays a row scan rather than ~34 MB of pictures.
            let sql = """
                SELECT ZUNIQUEID FROM ZABCDRECORD
                WHERE ZUNIQUEID IS NOT NULL
                  AND (ZIMAGEDATA IS NOT NULL OR ZTHUMBNAILIMAGEDATA IS NOT NULL
                       OR ZIMAGEREFERENCE IS NOT NULL)
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                continue
            }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idRaw = sqlite3_column_text(statement, 0) else { continue }
                let uniqueId = String(cString: idRaw)
                found.insert(uniqueId)
                // "UUID:ABPerson" -> "UUID", which is what CNContact reports.
                if let bare = uniqueId.split(separator: ":").first {
                    found.insert(String(bare))
                }
            }
        }

        return found
    }
}
