import AppKit
import Foundation

/// Turning a caller's body into something Mail's editor will accept cleanly.
///
/// 🛑 **The body never goes near AppleScript.** Setting `content` or `html
/// content` on an outgoing message makes Mail wrap the whole thing in
/// `<blockquote type="cite">` (Apple FB11734014) — invisible to the sender,
/// rendered as a quotation by iOS Mail and Gmail, and impossible to remove
/// afterwards because the wrapper lives in Mail's editable document rather than
/// in the `.emlx`. See `docs/apple-mail-drafts.md`.
///
/// So the body reaches Mail through the pasteboard and a ⌘V into the native
/// editor, which is the one channel that authors that document without wrapping.
public enum ComposeBody {
  public enum Format: String, CaseIterable, Sendable {
    case plain
    case markdown
    case html
  }

  /// RTF for the pasteboard.
  ///
  /// 🛑 **RTF, not HTML, and deliberately one flavour.** Putting HTML on the
  /// pasteboard makes Mail insert the body **twice** — found by
  /// `patrickfreyer/apple-mail-mcp` in v3.1.8/v3.2.0 and fixed there the same
  /// way: convert to an `NSAttributedString` and write it back as RTF, "a single
  /// unambiguous rich-text flavor". Our own first spike used `public.html` and
  /// would have shipped the double-insertion.
  ///
  /// HTML and Markdown are still accepted *as input*; they are converted here,
  /// so what lands on the pasteboard is always RTF.
  public static func rtf(from text: String, format: Format) throws -> Data {
    let attributed = try attributedString(from: text, format: format)
    guard
      let data = attributed.rtf(
        from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])
    else {
      throw ComposeBodyError.conversionFailed(
        "the body could not be converted to RTF (\(attributed.length) characters)")
    }
    return data
  }

  static func attributedString(from text: String, format: Format) throws -> NSAttributedString {
    switch format {
    case .plain:
      // A plain body is taken literally: no Markdown is interpreted, so a stray
      // `*` or `_` in prose survives as itself.
      return NSAttributedString(string: text, attributes: [.font: bodyFont])

    case .markdown:
      return try markdownAttributed(text)

    case .html:
      guard let data = text.data(using: .utf8) else {
        throw ComposeBodyError.conversionFailed("the body is not valid UTF-8")
      }
      guard
        let attributed = NSAttributedString(
          html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue],
          documentAttributes: nil)
      else {
        throw ComposeBodyError.conversionFailed("the body could not be parsed as HTML")
      }
      return attributed
    }
  }

  /// 12pt Helvetica, matching what Mail's own composer and Siri's drafts use, so
  /// a pasted body does not arrive visibly different from a typed one.
  static let bodyFont = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)

  static let codeFont = NSFont(name: "Menlo", size: 12)
    ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

  /// Markdown, rebuilt into something RTF can actually carry.
  ///
  /// `AttributedString(markdown:)` is the right parser to use — it is Apple's,
  /// and it gets the syntax right — but its output cannot be handed to
  /// `.rtf(from:)` as-is, for two separate reasons, each of which silently
  /// mangles the message:
  ///
  /// 🛑 **The parsed string contains no line breaks at all.** Block structure
  /// lives in `presentationIntent` runs, not in the characters, so
  /// `"first para\n\nsecond para"` comes back as `"first parasecond para"`.
  /// Converting that to RTF runs every paragraph together, which reads as the
  /// tool having eaten the formatting.
  ///
  /// 🛑 **Emphasis is semantic, not visual.** Bold arrives as
  /// `inlinePresentationIntent == .stronglyEmphasized`, never as a font trait,
  /// and RTF has nowhere to put an intent — so a `**bold**` body converts to
  /// RTF with no bold in it.
  ///
  /// So this walks the runs, inserts a real break whenever the block changes,
  /// prefixes list items, and turns each inline intent into an actual font.
  /// Both failures are pinned by tests.
  static func markdownAttributed(_ text: String) throws -> NSAttributedString {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .full
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard let parsed = try? AttributedString(markdown: normalized, options: options) else {
      throw ComposeBodyError.conversionFailed("the body is not valid Markdown")
    }

    let out = NSMutableAttributedString()
    var previousBlock: Int?

    for run in parsed.runs {
      let intent = run.presentationIntent
      let blockID = intent?.components.first?.identity

      if let blockID, blockID != previousBlock {
        if previousBlock != nil {
          out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        }
        let prefix = listPrefix(intent)
        if !prefix.isEmpty {
          out.append(NSAttributedString(string: prefix, attributes: [.font: bodyFont]))
        }
        previousBlock = blockID
      }

      var attributes: [NSAttributedString.Key: Any] = [.font: font(for: run, intent: intent)]
      if let link = run.link { attributes[.link] = link }
      out.append(
        NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
    }

    return out
  }

  /// `- item` becomes a real bullet, `1. item` a real number. Without this the
  /// marker is dropped by the parser and the list reads as running prose.
  private static func listPrefix(_ intent: PresentationIntent?) -> String {
    guard let intent else { return "" }
    let ordered = intent.components.contains { if case .orderedList = $0.kind { return true }
      return false
    }
    for component in intent.components {
      if case .listItem(let ordinal) = component.kind {
        return ordered ? "\(ordinal).\u{00A0}" : "•\u{00A0}"
      }
    }
    return ""
  }

  private static func font(for run: AttributedString.Runs.Run, intent: PresentationIntent?)
    -> NSFont
  {
    let inline = run.inlinePresentationIntent ?? []
    if inline.contains(.code) { return codeFont }

    var base = bodyFont
    if let intent, intent.components.contains(where: {
      if case .header = $0.kind { return true }
      return false
    }) {
      base = NSFont(name: "Helvetica-Bold", size: 14) ?? NSFont.boldSystemFont(ofSize: 14)
    }

    var traits: NSFontTraitMask = []
    if inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
    if inline.contains(.emphasized) { traits.insert(.italicFontMask) }
    guard !traits.isEmpty else { return base }
    return NSFontManager.shared.convert(base, toHaveTrait: traits)
  }
}

public enum ComposeBodyError: LocalizedError {
  case conversionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .conversionFailed(let detail): return "Could not prepare the body: \(detail)."
    }
  }
}

/// Writing the body to the pasteboard for the user to paste.
public enum ComposePasteboard {
  /// Replaces the pasteboard with the body.
  ///
  /// ⚠️ **This clobbers whatever the user had copied, deliberately** — the whole
  /// point is that ⌘V inserts the message. Callers say so on stdout rather than
  /// trying to restore it afterwards, which would defeat the purpose.
  ///
  /// Both flavours are written: RTF for Mail's editor, and plain text so a paste
  /// into a plain-text field is not silently empty. That pairing is what a native
  /// app puts on the pasteboard when you copy from TextEdit, and Mail takes the
  /// richest flavour offered. It is **not** the HTML+RTF pairing that caused the
  /// double insertion.
  @discardableResult
  public static func write(rtf: Data, plainText: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let wroteRTF = pasteboard.setData(rtf, forType: .rtf)
    let wroteText = pasteboard.setString(plainText, forType: .string)
    return wroteRTF && wroteText
  }

  /// What the pasteboard actually holds, for verifying the write took.
  public static func containsRTF() -> Bool {
    NSPasteboard.general.data(forType: .rtf) != nil
  }
}
