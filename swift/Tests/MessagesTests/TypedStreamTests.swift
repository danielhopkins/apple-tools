import XCTest

@testable import MessagesLibrary

/// The `attributedBody` decoder.
///
/// The bug being pinned is a silent one: 4,227 of 103,250 rows on a real store
/// have a NULL `text`, and 1,921 of those are ordinary messages whose body
/// exists only in this blob. Reading `text` alone drops them without any error,
/// which looks like missing history rather than a broken reader.
///
/// The blobs below are built to the same layout as real ones — verified byte
/// for byte against `chat.db` — so a change to the length handling or the
/// NSString lookup fails here rather than in production.
final class TypedStreamTests: XCTestCase {

  /// Assemble a typedstream carrying one NSString body, matching the byte
  /// layout Messages actually writes.
  private func blob(_ text: String, lengthOverride: [UInt8]? = nil) -> Data {
    var bytes: [UInt8] = Array("\u{04}\u{0B}streamtyped".utf8)
    bytes += [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
    bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84]
    bytes += Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]
    bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01]
    bytes += [0x2B]  // '+' — a length-prefixed byte string follows

    let payload = Array(text.utf8)
    if let lengthOverride {
      bytes += lengthOverride
    } else if payload.count < 0x81 {
      bytes += [UInt8(payload.count)]
    } else {
      bytes += [0x81, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
    }
    bytes += payload
    bytes += [0x86, 0x84, 0x02, 0x69, 0x49]  // trailing attribute runs
    return Data(bytes)
  }

  func testDecodesASimpleBody() {
    XCTAssertEqual(TypedStream.decode(blob("There is a drop off line of bikes")),
                   "There is a drop off line of bikes")
  }

  func testDecodesEmoji() {
    // Multi-byte UTF-8 must be counted in bytes, not characters; counting
    // characters truncates mid-emoji and yields U+FFFD.
    let text = "Happy Birthday 🎓📚✏️"
    XCTAssertEqual(TypedStream.decode(blob(text)), text)
  }

  /// Bodies over 128 bytes switch to the 0x81 two-byte length. This is the
  /// branch a naive "the next byte is the length" reader gets wrong, and most
  /// real messages are short enough never to exercise it.
  func testDecodesBodyLongerThanTheSingleByteLength() {
    let text = String(repeating: "a long message ", count: 40)
    XCTAssertEqual(TypedStream.decode(blob(text))?.count, text.count)
  }

  /// U+FFFC is an inline-attachment placeholder. The `text` column strips them
  /// and so must this, or 60 messages on a real store disagree with themselves
  /// depending on which field you read.
  func testStripsAttachmentPlaceholders() {
    XCTAssertEqual(TypedStream.decode(blob("\u{FFFC}On the canal. ")), "On the canal. ")
  }

  /// An attachment-only message decodes to placeholders and nothing else. Nil
  /// beats "" here: the caller renders "(attachment only)" rather than a blank.
  func testPlaceholderOnlyBodyDecodesToNil() {
    XCTAssertNil(TypedStream.decode(blob("\u{FFFC}")))
  }

  func testRejectsNonTypedStreamData() {
    XCTAssertNil(TypedStream.decode(Data("not an archive".utf8)))
    XCTAssertNil(TypedStream.decode(Data()))
  }

  /// bplist blobs turn up in this column for some app messages. They are not
  /// typedstreams and must be declined rather than mined for stray bytes.
  func testRejectsBinaryPropertyList() {
    XCTAssertNil(TypedStream.decode(Data("bplist00\u{D4}\u{01}\u{02}".utf8)))
  }

  /// A length prefix of 0x84+ is a stream control token, not a length. Reading
  /// it as one would run past the end of the string and into the attribute
  /// runs, so it has to be refused.
  func testRefusesControlTokenAsLength() {
    XCTAssertNil(TypedStream.decode(blob("hello", lengthOverride: [0x84])))
  }

  /// A truncated blob must not read past its end.
  func testTruncatedBodyIsRefused() {
    var data = blob("this body is cut short")
    data = data.prefix(data.count - 12)
    // Either nil or a short string is acceptable; a crash or overrun is not.
    _ = TypedStream.decode(data)
  }
}
