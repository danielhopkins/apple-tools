import Foundation

/// Reading a message body off disk. Mail stores each message as an `.emlx`:
///
///     <decimal byte count>\n
///     <RFC 822 message, exactly that many bytes>
///     <XML plist of Mail's own flags>
///
/// The byte count matters — the trailer is not part of the message, and a
/// parser that reads to EOF ends up with Mail's plist glued to the body.

public enum EmlxError: Error, LocalizedError {
  case unreadable(String)
  case malformed(String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let message): return message
    case .malformed(let message): return message
    }
  }
}

public struct MailHeaders: Sendable {
  public let raw: String
  public let fields: [(name: String, value: String)]

  public func first(_ name: String) -> String? {
    fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  public func all(_ name: String) -> [String] {
    fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
  }
}

public struct EmlxMessage: Sendable {
  public let headers: MailHeaders
  /// Best-effort plain text: the text/plain part if there is one, otherwise
  /// text/html with its markup stripped.
  public let text: String
  /// The RFC 822 bytes, without Mail's trailer.
  public let source: Data
}

// MARK: - Container

/// The RFC 822 payload of an .emlx, using the leading byte count.
public func emlxPayload(_ data: Data) throws -> Data {
  guard let newline = data.firstIndex(of: 0x0A) else {
    throw EmlxError.malformed("No byte-count line")
  }
  guard let text = String(data: data[data.startIndex..<newline], encoding: .utf8),
    let count = Int(text.trimmingCharacters(in: .whitespaces)), count > 0
  else {
    throw EmlxError.malformed("Unparseable byte-count line")
  }
  let start = data.index(after: newline)
  let end =
    data.index(start, offsetBy: count, limitedBy: data.endIndex) ?? data.endIndex
  return Data(data[start..<end])
}

public func readEmlx(at url: URL) throws -> EmlxMessage {
  guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
    throw EmlxError.unreadable("Cannot read \(url.path)")
  }
  return parseRFC822(try emlxPayload(data))
}

// MARK: - RFC 822

public func parseRFC822(_ data: Data) -> EmlxMessage {
  let (headerData, bodyData) = splitHeaders(data)
  let headers = parseHeaders(headerData)
  let text = extractText(body: bodyData, headers: headers)
  return EmlxMessage(headers: headers, text: text, source: data)
}

/// Headers end at the first blank line. Both CRLF and bare LF appear in real
/// mail, sometimes in the same message.
///
/// Returns slices, and scans at most `maxHeaderBytes` looking for the break.
/// Both matter: a MIME part is frequently a multi-megabyte base64 attachment,
/// and copying it — or walking all of it to find where its headers stop — is
/// most of the cost of deciding to ignore it. Real MIME headers are a few
/// hundred bytes; a part with 64 KB of them is malformed, and treating it as
/// all-headers drops a part we could not have read anyway.
func splitHeaders(_ data: Data, maxHeaderBytes: Int = 1 << 16) -> (Data, Data) {
  let limit =
    data.index(data.startIndex, offsetBy: min(data.count, maxHeaderBytes))
  var index = data.startIndex
  while index < limit {
    if data[index] == 0x0A {
      let next = data.index(after: index)
      if next < data.endIndex, data[next] == 0x0A {
        return (data[data.startIndex..<index], data[data.index(after: next)...])
      }
      if next < data.endIndex, data[next] == 0x0D {
        let third = data.index(after: next)
        if third < data.endIndex, data[third] == 0x0A {
          return (data[data.startIndex..<index], data[data.index(after: third)...])
        }
      }
    }
    index = data.index(after: index)
  }
  return (data, Data())
}

func parseHeaders(_ data: Data) -> MailHeaders {
  let raw = decodeBytes(data, charset: "utf-8")
  var fields: [(name: String, value: String)] = []
  var currentName: String?
  var currentValue = ""

  func flush() {
    if let name = currentName {
      fields.append((name, decodeEncodedWords(currentValue.trimmingCharacters(in: .whitespaces))))
    }
    currentName = nil
    currentValue = ""
  }

  for line in raw.components(separatedBy: "\n") {
    let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
    // A line starting with whitespace continues the previous header ("folding").
    if line.first == " " || line.first == "\t" {
      currentValue += " " + line.trimmingCharacters(in: .whitespaces)
      continue
    }
    flush()
    guard let colon = line.firstIndex(of: ":") else { continue }
    currentName = String(line[line.startIndex..<colon])
    currentValue = String(line[line.index(after: colon)...])
  }
  flush()
  return MailHeaders(raw: raw, fields: fields)
}

// MARK: - MIME

/// Pull the text out of a message body, following multipart structure.
func extractText(body: Data, headers: MailHeaders) -> String {
  let contentType = headers.first("Content-Type") ?? "text/plain"
  let encoding = headers.first("Content-Transfer-Encoding") ?? "7bit"
  var plain: [String] = []
  var html: [String] = []
  collectText(body: body, contentType: contentType, encoding: encoding, plain: &plain, html: &html)

  // Test the joined *text*, not the array. A message can carry a text/plain
  // part that is empty — Mail writes exactly that for every draft it composes,
  // and 2.2% of a real 40k-message store looks the same — which gives
  // `plain == [""]`: a non-empty array holding nothing. Preferring it on that
  // basis discards the HTML and reports the message as having no body at all,
  // which also makes it unfindable by a content search.
  let joinedPlain = plain.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
  if !joinedPlain.isEmpty { return joinedPlain }
  return html.map(strippingHTML).joined(separator: "\n\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Depth is bounded because a malformed message can nest boundaries forever.
func collectText(
  body: Data, contentType: String, encoding: String,
  plain: inout [String], html: inout [String], depth: Int = 0
) {
  guard depth < 12 else { return }
  let type = contentType.components(separatedBy: ";").first?
    .trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"

  if type.hasPrefix("multipart/") {
    guard let boundary = parameter("boundary", in: contentType) else { return }
    var alternativePlain: [String] = []
    var alternativeHTML: [String] = []
    for range in splitMultipart(body, boundary: boundary) {
      let (headerData, partBody) = splitHeaders(body[range])
      let partHeaders = parseHeaders(headerData)
      // An attachment is not body text, even when it happens to be text/plain.
      // Checked before the body is touched, so a 20 MB PDF costs only its
      // header scan.
      let disposition = partHeaders.first("Content-Disposition")?.lowercased() ?? ""
      if disposition.hasPrefix("attachment") { continue }
      collectText(
        body: partBody,
        contentType: partHeaders.first("Content-Type") ?? "text/plain",
        encoding: partHeaders.first("Content-Transfer-Encoding") ?? "7bit",
        plain: &alternativePlain, html: &alternativeHTML, depth: depth + 1)
    }
    // In multipart/alternative the parts are the same content twice; taking
    // both would duplicate every message body that ships plain text and HTML.
    // The plain half only wins if it actually says something — an empty
    // text/plain alongside real HTML is common, and dropping the HTML for it
    // loses the whole body.
    let plainHasText = alternativePlain.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if type == "multipart/alternative", plainHasText {
      plain.append(contentsOf: alternativePlain)
    } else {
      plain.append(contentsOf: alternativePlain)
      html.append(contentsOf: alternativeHTML)
    }
    return
  }

  guard type.hasPrefix("text/") else { return }
  let decoded = decodeTransferEncoding(body, encoding: encoding)
  let charset = parameter("charset", in: contentType) ?? "utf-8"
  let string = decodeBytes(decoded, charset: charset)
  if type == "text/html" {
    html.append(string)
  } else {
    plain.append(string)
  }
}

/// `name="value"` or `name=value` out of a header value.
func parameter(_ name: String, in header: String) -> String? {
  for piece in header.components(separatedBy: ";").dropFirst() {
    let piece = piece.trimmingCharacters(in: .whitespaces)
    guard let equals = piece.firstIndex(of: "=") else { continue }
    let key = piece[piece.startIndex..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    guard key == name.lowercased() else { continue }
    var value = String(piece[piece.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
      value = String(value.dropFirst().dropLast())
    }
    return value
  }
  return nil
}

/// Split on `--boundary` lines, dropping the preamble and the closing marker.
///
/// Yields ranges rather than copies: most of a mail store by volume is
/// attachment parts that the caller immediately discards, and materialising
/// them first was the single largest avoidable cost in a body search.
func splitMultipart(_ data: Data, boundary: String) -> [Range<Data.Index>] {
  guard let marker = "--\(boundary)".data(using: .utf8) else { return [] }
  var parts: [Range<Data.Index>] = []
  var searchStart = data.startIndex
  var partStart: Int?

  while searchStart < data.endIndex,
    let found = data.range(of: marker, in: searchStart..<data.endIndex)
  {
    // Only a boundary at the start of a line counts; the same bytes can appear
    // inside a body.
    let atLineStart = found.lowerBound == data.startIndex
      || data[data.index(before: found.lowerBound)] == 0x0A
    if atLineStart {
      if let start = partStart {
        var end = found.lowerBound
        // Drop the CRLF that belongs to the boundary, not to the part.
        if end > start, data[data.index(before: end)] == 0x0A { end = data.index(before: end) }
        if end > start, data[data.index(before: end)] == 0x0D { end = data.index(before: end) }
        parts.append(start..<end)
      }
      // `--boundary--` closes the multipart.
      let afterMarker = found.upperBound
      if afterMarker < data.endIndex,
        data[afterMarker] == 0x2D,
        data.index(after: afterMarker) < data.endIndex,
        data[data.index(after: afterMarker)] == 0x2D
      {
        return parts
      }
      var next = afterMarker
      while next < data.endIndex, data[next] != 0x0A { next = data.index(after: next) }
      if next < data.endIndex { next = data.index(after: next) }
      partStart = next
      searchStart = next
      continue
    }
    searchStart = found.upperBound
  }
  if let start = partStart, start < data.endIndex {
    parts.append(start..<data.endIndex)
  }
  return parts
}

// MARK: - Transfer encodings

public func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
  switch encoding.trimmingCharacters(in: .whitespaces).lowercased() {
  case "base64":
    let text = String(decoding: data, as: UTF8.self)
      .components(separatedBy: .whitespacesAndNewlines).joined()
    return Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? data
  case "quoted-printable":
    return decodeQuotedPrintable(data)
  default:
    return data
  }
}

public func decodeQuotedPrintable(_ data: Data) -> Data {
  var output = Data(capacity: data.count)
  let bytes = [UInt8](data)
  var index = 0
  while index < bytes.count {
    let byte = bytes[index]
    guard byte == 0x3D else {  // '='
      output.append(byte)
      index += 1
      continue
    }
    // "=\r\n" and "=\n" are soft line breaks and vanish.
    if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
      index += 2
      continue
    }
    if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
      index += 3
      continue
    }
    if index + 2 < bytes.count,
      let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
    {
      output.append(high << 4 | low)
      index += 3
      continue
    }
    // A stray '=' that decodes to nothing is literal.
    output.append(byte)
    index += 1
  }
  return output
}

private func hexValue(_ byte: UInt8) -> UInt8? {
  switch byte {
  case 0x30...0x39: return byte - 0x30
  case 0x41...0x46: return byte - 0x41 + 10
  case 0x61...0x66: return byte - 0x61 + 10
  default: return nil
  }
}

// MARK: - Charsets

/// Decode bytes using an IANA charset name, falling back rather than failing:
/// an undecodable body is still worth searching, and a nil here would drop the
/// whole message.
public func decodeBytes(_ data: Data, charset: String) -> String {
  let name = charset.trimmingCharacters(in: .whitespaces).lowercased()
  if name == "utf-8" || name == "utf8" || name.isEmpty {
    if let text = String(data: data, encoding: .utf8) { return text }
  }
  let raw = CFStringConvertIANACharSetNameToEncoding(name as CFString)
  if raw != kCFStringEncodingInvalidId {
    let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(raw))
    if let text = String(data: data, encoding: encoding) { return text }
  }
  if let text = String(data: data, encoding: .utf8) { return text }
  if let text = String(data: data, encoding: .isoLatin1) { return text }
  return String(decoding: data, as: UTF8.self)
}

/// RFC 2047 `=?charset?B?…?=` / `=?charset?Q?…?=` in header values.
public func decodeEncodedWords(_ input: String) -> String {
  guard input.contains("=?") else { return input }
  var output = ""
  var rest = Substring(input)

  while let start = rest.range(of: "=?") {
    output += rest[rest.startIndex..<start.lowerBound]
    let afterStart = rest[start.upperBound...]
    // charset ? encoding ? text ?=
    guard let charsetEnd = afterStart.firstIndex(of: "?") else {
      output += rest[start.lowerBound...]
      return output
    }
    let charset = String(afterStart[afterStart.startIndex..<charsetEnd])
    let afterCharset = afterStart[afterStart.index(after: charsetEnd)...]
    guard let encodingEnd = afterCharset.firstIndex(of: "?") else {
      output += rest[start.lowerBound...]
      return output
    }
    let encoding = afterCharset[afterCharset.startIndex..<encodingEnd].lowercased()
    let afterEncoding = afterCharset[afterCharset.index(after: encodingEnd)...]
    guard let terminator = afterEncoding.range(of: "?=") else {
      output += rest[start.lowerBound...]
      return output
    }
    let payload = String(afterEncoding[afterEncoding.startIndex..<terminator.lowerBound])

    let decoded: Data?
    switch encoding {
    case "b":
      decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    case "q":
      // In encoded words '_' stands for a space, unlike normal QP.
      decoded = decodeQuotedPrintable(
        Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
    default:
      decoded = nil
    }
    output += decoded.map { decodeBytes($0, charset: charset) } ?? "=?\(charset)?\(encoding)?\(payload)?="
    rest = afterEncoding[terminator.upperBound...]
  }
  output += rest
  return output
}

// MARK: - HTML

/// Enough HTML stripping to make a body searchable and readable. Not a parser
/// and not trying to be one.
public func strippingHTML(_ html: String) -> String {
  var text = html
  for tag in ["script", "style", "head"] {
    while let open = text.range(of: "<\(tag)", options: .caseInsensitive),
      let close = text.range(
        of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<text.endIndex)
    {
      text.removeSubrange(open.lowerBound..<close.upperBound)
    }
  }
  // Block-level tags become newlines so paragraphs survive.
  for tag in ["</p>", "</div>", "<br>", "<br/>", "<br />", "</tr>", "</h1>", "</h2>", "</h3>"] {
    text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
  }
  text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
  let entities = [
    "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
    "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
  ]
  for (entity, replacement) in entities {
    text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
  }
  text = text.replacingOccurrences(
    of: "&#([0-9]+);", with: "$1", options: .regularExpression)
  // Collapse the blank-line runs that stripped markup leaves behind.
  text = text.replacingOccurrences(
    of: "[ \\t]*\\n[ \\t]*(\\n[ \\t]*)+", with: "\n\n", options: .regularExpression)
  return text.trimmingCharacters(in: .whitespacesAndNewlines)
}
