import Foundation

/// Files to hang off a compose window.
///
/// Unlike the body, an attachment **can** safely be written by AppleScript:
/// `make new attachment` inserts into the message's content without ever
/// assigning to `content`, and it is assignment that triggers the
/// `<blockquote type="cite">` wrapper (FB11734014). So attachments are the one
/// part of a draft this tool fills in itself — see `docs/apple-mail-drafts.md`.
public enum ComposeAttachments {
  /// A file that has been checked and is ready to hand to Mail.
  public struct Resolved {
    public let path: String
    public let name: String
    public let bytes: Int

    public var humanSize: String {
      let units = ["B", "KB", "MB", "GB"]
      var value = Double(bytes)
      var unit = 0
      while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
      }
      return unit == 0
        ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
  }

  public struct Failure: Error, CustomStringConvertible {
    public let description: String
  }

  /// Mail accepts larger, but a message this size will be refused by most
  /// receiving servers, so say so rather than letting the user find out from a
  /// bounce. A warning, not a refusal — the limit is the recipient's, not ours.
  public static let warnAboveBytes = 20 * 1024 * 1024

  /// Checks every path **before** any Apple Event is sent.
  ///
  /// A compose window that opened and then failed halfway through attaching
  /// leaves the user with a half-built draft and no clear way to tell which
  /// files made it, so a bad path has to be fatal while nothing has happened
  /// yet.
  public static func resolve(_ paths: [String]) throws -> [Resolved] {
    var seen = Set<String>()
    return try paths.map { raw in
      let expanded = (raw as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded).standardizedFileURL
      let path = url.path

      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw Failure(description: "--attach '\(raw)': no such file.")
      }
      guard !isDirectory.boolValue else {
        throw Failure(
          description: "--attach '\(raw)' is a directory. Mail attaches files; zip it first.")
      }
      guard FileManager.default.isReadableFile(atPath: path) else {
        throw Failure(description: "--attach '\(raw)': not readable.")
      }

      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0

      // Two copies of one file is a mistake far more often than an intention,
      // and Mail will happily attach it twice.
      guard seen.insert(path).inserted else {
        throw Failure(description: "--attach '\(raw)' was given twice.")
      }

      return Resolved(path: path, name: url.lastPathComponent, bytes: bytes)
    }
  }

  public static func oversizeWarning(_ files: [Resolved]) -> String? {
    let total = files.reduce(0) { $0 + $1.bytes }
    guard total > warnAboveBytes else { return nil }
    let combined = Resolved(path: "", name: "", bytes: total)
    return """
      note: \(files.count == 1 ? "this attachment is" : "these attachments total") \
      \(combined.humanSize), which many mail servers reject. Mail will let you send it anyway.
      """
  }
}
