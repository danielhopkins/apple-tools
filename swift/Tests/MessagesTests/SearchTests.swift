import Foundation
import SQLite3
import XCTest

@testable import MessagesLibrary

/// Search against a synthetic `chat.db`.
///
/// These build a real SQLite file rather than mocking, because the bug worth
/// pinning here is about how two candidate populations interact under a LIMIT,
/// and that only reproduces against actual SQL.
final class SearchTests: XCTestCase {
  private var directory: URL!
  private var databasePath: URL!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("apple-messages-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databasePath = directory.appendingPathComponent("chat.db")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: Fixture

  /// The subset of Messages' schema this reader touches.
  private func createStore(_ populate: (OpaquePointer) -> Void) throws {
    var handle: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(
        databasePath.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
      SQLITE_OK)
    guard let handle else { return XCTFail("could not create the fixture database") }
    defer { sqlite3_close_v2(handle) }

    exec(
      handle,
      """
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
        chat_identifier TEXT, service_name TEXT, display_name TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
        attributedBody BLOB, date INTEGER, date_edited INTEGER DEFAULT 0,
        date_retracted INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0,
        is_read INTEGER DEFAULT 1, service TEXT, handle_id INTEGER,
        item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
        balloon_bundle_id TEXT, cache_has_attachments INTEGER DEFAULT 0);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT,
        mime_type TEXT, total_bytes INTEGER DEFAULT 0, is_sticker INTEGER DEFAULT 0);
      CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);

      INSERT INTO handle (ROWID, id, service) VALUES (1, '+15551234567', 'iMessage');
      INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
        VALUES (1, 'iMessage;-;+15551234567', 45, '+15551234567', 'iMessage', NULL);
      INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);
      """)
    populate(handle)
  }

  private func exec(_ handle: OpaquePointer, _ sql: String) {
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK, let error {
      XCTFail("fixture SQL failed: \(String(cString: error))")
      sqlite3_free(error)
    }
  }

  /// Apple-epoch nanoseconds, `daysAgo` days before now.
  private func timestamp(daysAgo: Int) -> Int64 {
    let seconds = Date().timeIntervalSince1970 - Double(daysAgo) * 86_400 - AppleEpoch.offset
    return Int64(seconds * 1_000_000_000)
  }

  /// A typedstream carrying `text`, laid out as Messages writes it.
  private func archived(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = Array("\u{04}\u{0B}streamtyped".utf8)
    bytes += [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
    bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84]
    bytes += Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]
    bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
    let payload = Array(text.utf8)
    bytes += payload.count < 0x81
      ? [UInt8(payload.count)]
      : [0x81, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
    return bytes + payload + [0x86]
  }

  private func insert(
    _ handle: OpaquePointer, rowid: Int64, text: String?, archivedText: String? = nil,
    daysAgo: Int
  ) {
    let body = text.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
    let blob = archivedText.map { "X'\(archived($0).map { String(format: "%02X", $0) }.joined())'" }
      ?? "NULL"
    exec(
      handle,
      """
      INSERT INTO message (ROWID, guid, text, attributedBody, date, handle_id, service)
        VALUES (\(rowid), 'guid-\(rowid)', \(body), \(blob), \(timestamp(daysAgo: daysAgo)),
                1, 'iMessage');
      INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, \(rowid));
      """)
  }

  private func store() throws -> MessageStore {
    MessageStore(database: try ChatDatabase(path: databasePath))
  }

  // MARK: Tests

  /// The regression this file exists for.
  ///
  /// Archived-body rows are candidates for *every* query, because whether they
  /// match is only knowable after decoding. When many of them are newer than
  /// the real text-column matches, a single query with one LIMIT returns them
  /// instead — the decoder rejects them all, and the search reports nothing
  /// while the answer sits just past the cut.
  ///
  /// Reproduced from a real store: searching "trusting" matched 6 rows in the
  /// text column, but 1,796 archived candidates were newer than all of them, so
  /// a 200-row window found only the single archived match and dropped all six.
  func testTextMatchesSurviveAFloodOfNewerArchivedCandidates() throws {
    try createStore { handle in
      // Old, and genuinely matching.
      insert(handle, rowid: 1, text: "I am trusting the forecast", daysAgo: 400)
      insert(handle, rowid: 2, text: "not trusting that at all", daysAgo: 380)
      // Newer, archived, and matching nothing — the flood.
      for index in 0..<300 {
        insert(
          handle, rowid: Int64(100 + index), text: nil,
          archivedText: "unrelated chatter number \(index)", daysAgo: 10)
      }
    }

    // limit 5 is deliberate: the implementation this replaced over-fetched
    // limit × 40 rows, so the flood has to exceed 200 to reproduce. A larger
    // limit here would pass against the bug and pin nothing.
    let results = try store().search(SearchRequest(query: "trusting", limit: 5))
    XCTAssertEqual(results.count, 2, "both text-column matches must survive the newer candidates")
    XCTAssertEqual(Set(results.map(\.rowid)), [1, 2])
  }

  /// The other half: an archived body is found even though SQL cannot see it.
  func testFindsBodyThatExistsOnlyInTheArchive() throws {
    try createStore { handle in
      insert(handle, rowid: 1, text: nil, archivedText: "the bikes are by the fence", daysAgo: 3)
      insert(handle, rowid: 2, text: "something else entirely", daysAgo: 2)
    }

    let results = try store().search(SearchRequest(query: "bikes", limit: 10))
    XCTAssertEqual(results.map(\.rowid), [1])
    XCTAssertTrue(results[0].textFromArchive, "provenance must be reported")
    XCTAssertEqual(results[0].text, "the bikes are by the fence")
  }

  /// Both sources merge into one date-ordered list rather than one being
  /// appended after the other.
  func testResultsFromBothSourcesInterleaveByDate() throws {
    try createStore { handle in
      insert(handle, rowid: 1, text: "budget one", daysAgo: 30)
      insert(handle, rowid: 2, text: nil, archivedText: "budget two", daysAgo: 20)
      insert(handle, rowid: 3, text: "budget three", daysAgo: 10)
    }

    let results = try store().search(SearchRequest(query: "budget", limit: 10))
    XCTAssertEqual(results.map(\.rowid), [3, 2, 1], "newest first, regardless of source")
  }

  /// Terms are ANDed, matching `apple mail search`.
  func testEveryTermMustAppear() throws {
    try createStore { handle in
      insert(handle, rowid: 1, text: "dinner on friday", daysAgo: 5)
      insert(handle, rowid: 2, text: "dinner on saturday", daysAgo: 4)
    }

    XCTAssertEqual(try store().search(SearchRequest(query: "dinner friday")).map(\.rowid), [1])
  }

  /// The limit is honoured after the merge, not per source — otherwise a
  /// `--limit 1` could return two rows.
  func testLimitAppliesToTheMergedResult() throws {
    try createStore { handle in
      insert(handle, rowid: 1, text: "report a", daysAgo: 5)
      insert(handle, rowid: 2, text: nil, archivedText: "report b", daysAgo: 4)
    }

    XCTAssertEqual(try store().search(SearchRequest(query: "report", limit: 1)).count, 1)
  }

  /// An empty query lists recent messages rather than matching everything twice.
  func testEmptyQueryListsRecentMessagesOnce() throws {
    try createStore { handle in
      insert(handle, rowid: 1, text: "one", daysAgo: 3)
      insert(handle, rowid: 2, text: nil, archivedText: "two", daysAgo: 2)
    }

    let results = try store().search(SearchRequest(query: "", limit: 10))
    XCTAssertEqual(results.count, 2, "no duplicates from the two-query split")
  }

  /// A LIKE metacharacter in the query is matched literally.
  func testPercentIsMatchedLiterally() throws {
    try createStore { handle in
      insert(handle, rowid: 1, text: "up 50% this quarter", daysAgo: 5)
      insert(handle, rowid: 2, text: "nothing relevant", daysAgo: 4)
    }

    XCTAssertEqual(try store().search(SearchRequest(query: "50%")).map(\.rowid), [1])
  }
}
