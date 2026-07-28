import Foundation

/// Pulling files back out of a message.
///
/// What counts as an attachment is Mail's rule, checked against its own index
/// on a real store: **a part with a filename**. Content-Disposition does not
/// decide it — 546 of 1085 attachment-ish parts sampled were `inline`, and
/// Mail counts the named ones. Nor does Content-ID: a message with two
/// nameless tracking pixels reports zero attachments, while one with seven
/// named inline images reports seven. Matching that rule keeps this command
/// agreeing with `export --json` and with what Mail shows the user.

public struct MailAttachment: Sendable {
  /// Decoded and made safe to write to disk.
  public let name: String
  /// The filename exactly as the message gave it, before sanitising.
  public let originalName: String
  public let contentType: String
  public let data: Data
  /// Carries a Content-ID, so it is probably referenced from the HTML body
  /// rather than shown as a paperclip.
  public let isInline: Bool

  public var byteCount: Int { data.count }
}

/// Every named part of an RFC 822 message, decoded.
public func attachments(inRFC822 data: Data) -> [MailAttachment] {
  let (headerData, body) = splitHeaders(data)
  let headers = parseHeaders(headerData)
  var found: [MailAttachment] = []
  collectAttachments(
    body: body,
    contentType: headers.first("Content-Type") ?? "text/plain",
    encoding: headers.first("Content-Transfer-Encoding") ?? "7bit",
    disposition: headers.first("Content-Disposition") ?? "",
    contentID: headers.first("Content-ID"),
    into: &found)
  return disambiguate(found)
}

private func collectAttachments(
  body: Data, contentType: String, encoding: String, disposition: String,
  contentID: String?, into found: inout [MailAttachment], depth: Int = 0
) {
  guard depth < 12 else { return }
  let type = contentType.components(separatedBy: ";").first?
    .trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"

  if type.hasPrefix("multipart/") {
    guard let boundary = parameter("boundary", in: contentType) else { return }
    for range in splitMultipart(body, boundary: boundary) {
      let (partHeaderData, partBody) = splitHeaders(body[range])
      let partHeaders = parseHeaders(partHeaderData)
      collectAttachments(
        body: partBody,
        contentType: partHeaders.first("Content-Type") ?? "text/plain",
        encoding: partHeaders.first("Content-Transfer-Encoding") ?? "7bit",
        disposition: partHeaders.first("Content-Disposition") ?? "",
        contentID: partHeaders.first("Content-ID"),
        into: &found, depth: depth + 1)
    }
    return
  }

  // The filename is the whole test. `Content-Disposition: filename` first,
  // then the older `Content-Type: name`.
  guard
    let raw = attachmentFilename(disposition: disposition, contentType: contentType),
    !raw.isEmpty
  else { return }

  found.append(
    MailAttachment(
      name: safeFilename(raw, fallback: "attachment-\(found.count + 1)"),
      originalName: raw,
      contentType: type,
      data: decodeTransferEncoding(body, encoding: encoding),
      isInline: contentID != nil))
}

/// `filename` from Content-Disposition, else `name` from Content-Type.
/// Handles RFC 2047 encoded words and RFC 2231 `filename*=` — both turn up in
/// real mail, rarely (8 and 2 occurrences per 3000 messages sampled), and both
/// produce mojibake filenames if ignored.
func attachmentFilename(disposition: String, contentType: String) -> String? {
  for (header, key) in [(disposition, "filename"), (contentType, "name")] {
    guard !header.isEmpty else { continue }
    if let extended = parameter("\(key)*", in: header),
      let decoded = decodeRFC2231(extended)
    {
      return decoded
    }
    if let plain = parameter(key, in: header) {
      return decodeEncodedWords(plain)
    }
  }
  return nil
}

/// `UTF-8''Invoice%20March.pdf` — charset, optional language, percent-encoded.
func decodeRFC2231(_ value: String) -> String? {
  let parts = value.components(separatedBy: "'")
  guard parts.count >= 3 else {
    // No charset prefix; still percent-encoded.
    return value.removingPercentEncoding ?? value
  }
  let charset = parts[0].isEmpty ? "utf-8" : parts[0]
  let encoded = parts.dropFirst(2).joined(separator: "'")

  var bytes = Data()
  var rest = Substring(encoded)
  while let index = rest.firstIndex(of: "%") {
    bytes.append(contentsOf: Array(rest[rest.startIndex..<index].utf8))
    let after = rest.index(after: index)
    guard
      let end = rest.index(after, offsetBy: 2, limitedBy: rest.endIndex),
      let byte = UInt8(rest[after..<end], radix: 16)
    else {
      bytes.append(contentsOf: Array(rest[index...].utf8))
      rest = rest[rest.endIndex...]
      break
    }
    bytes.append(byte)
    rest = rest[end...]
  }
  bytes.append(contentsOf: Array(rest.utf8))
  return decodeBytes(bytes, charset: charset)
}

/// Make a message-supplied filename safe to join onto a directory.
///
/// The name comes from whoever sent the mail, so it is hostile input: a
/// `filename` of `../../.ssh/authorized_keys` must not escape the target
/// directory. Only the last path component survives, and separators are
/// stripped rather than trusted.
///
/// Names containing dots are *not* rejected — `3360 Mitchell Ln..pdf` is a
/// real filename in this store, and treating "contains .." as traversal would
/// mangle it. Only a name that is entirely dots is refused.
public func safeFilename(_ raw: String, fallback: String) -> String {
  var name = raw
  // Strip both separators: HFS+ used ':' as one, and a Windows sender may send
  // a backslashed path.
  for separator in ["/", "\\", ":"] {
    if let last = name.components(separatedBy: separator).last { name = last }
  }
  name = name.replacingOccurrences(of: "\0", with: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)

  if name.isEmpty || name.allSatisfy({ $0 == "." }) { return fallback }
  // Leading dots would hide the file; a sender should not get to do that.
  while name.hasPrefix(".") { name.removeFirst() }
  if name.isEmpty { return fallback }

  // Keep well clear of filesystem limits, preserving the extension.
  if name.utf8.count > 200 {
    let ext = (name as NSString).pathExtension
    let stem = String((name as NSString).deletingPathExtension.prefix(150))
    name = ext.isEmpty ? stem : "\(stem).\(ext)"
  }
  return name
}

/// Two parts can carry the same filename; writing both would silently keep one.
private func disambiguate(_ items: [MailAttachment]) -> [MailAttachment] {
  var seen: [String: Int] = [:]
  return items.map { item in
    let count = (seen[item.name.lowercased()] ?? 0) + 1
    seen[item.name.lowercased()] = count
    guard count > 1 else { return item }
    let ext = (item.name as NSString).pathExtension
    let stem = (item.name as NSString).deletingPathExtension
    let unique = ext.isEmpty ? "\(stem)-\(count)" : "\(stem)-\(count).\(ext)"
    return MailAttachment(
      name: unique, originalName: item.originalName, contentType: item.contentType,
      data: item.data, isInline: item.isInline)
  }
}
