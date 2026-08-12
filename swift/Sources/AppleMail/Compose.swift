import ArgumentParser
import Foundation
import MailLibrary

// MARK: - Why these commands stop where they do

/// `compose`, `reply` and `forward` open a Mail compose window with everything
/// filled in **except the body**, put the body on the pasteboard, and stop.
///
/// 🛑 **The tool must never write a body, and this is the whole design.**
/// Setting `content` or `html content` on an outgoing message wraps it in
/// `<blockquote type="cite">` (Apple FB11734014). That wrapper cannot be
/// removed afterwards: rewriting the `.emlx` fixes the file, and the file is not
/// what the composer opens — Mail keeps a separate editable document, and
/// re-saves from *that*, so the wrapper comes back the moment the user opens the
/// draft to review it. A whole compose surface was built on the rewrite and
/// removed in 26.810.0 when that was measured. See `docs/apple-mail-drafts.md`.
///
/// Pasting into the native editor is the one channel that authors the editable
/// document without wrapping. Verified end to end: a scripted-open reply, body
/// pasted, saved, reopened, hand-edited and saved again came back with no
/// wrapper, `In-Reply-To`/`References` intact and the caller's text above the
/// quotation.
///
/// So everything Mail is good at — recipients, subject, threading, the quoted
/// original, carried-over attachments — is left to Mail, and the one thing it
/// gets wrong is left to a keystroke. The failure mode is a correctly addressed
/// compose window with an empty body, which is useful rather than wrong.

// MARK: - Shared body options

struct ComposeBodyOptions: ParsableArguments {
  @Option(name: .long, help: "Message body. Goes on the pasteboard, not into Mail.")
  var body: String?

  @Option(
    name: .long,
    help: "Read the body from a file, or '-' for stdin.")
  var bodyFile: String?

  @Flag(name: .long, help: "Interpret the body as Markdown (bold, italic, links, lists).")
  var markdown = false

  @Flag(name: .long, help: "Interpret the body as HTML. Converted to RTF for the pasteboard.")
  var html = false

  func resolved() throws -> (text: String, format: ComposeBody.Format) {
    if markdown && html {
      throw ValidationError("--markdown and --html are mutually exclusive.")
    }
    let format: ComposeBody.Format = markdown ? .markdown : (html ? .html : .plain)

    if let body, bodyFile != nil {
      _ = body
      throw ValidationError("Pass --body or --body-file, not both.")
    }
    if let body { return (body, format) }

    if let bodyFile {
      if bodyFile == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return (String(decoding: data, as: UTF8.self), format)
      }
      let url = URL(fileURLWithPath: (bodyFile as NSString).expandingTildeInPath)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw ValidationError("Could not read --body-file '\(bodyFile)'.")
      }
      return (text, format)
    }

    // A bare pipe is the same as --body-file -, matching `apple notes`.
    if !isatty(FileHandle.standardInput.fileDescriptor).boolValue {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      if !data.isEmpty { return (String(decoding: data, as: UTF8.self), format) }
    }

    throw ValidationError(
      "No body. Pass --body TEXT, --body-file FILE, --body-file - for stdin, or pipe it in.")
  }
}

extension Int32 {
  fileprivate var boolValue: Bool { self != 0 }
}

// MARK: - Attachments

/// ⚠️ **Attachments are the one part of a draft this tool does write**, and the
/// reason it can is narrow: `make new attachment` inserts an element into the
/// message's content without ever *assigning* to `content`, and assignment is
/// what produces the cite-blockquote wrapper. Verified on an empty body — no
/// need to seed `content` with a newline first, which is the usual recipe and
/// would reintroduce the wrapper.
struct AttachmentOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "File to attach. Repeat for several. Attached by Mail, unlike the body.",
    completion: .file())
  var attach: [String] = []

  func resolved() throws -> [ComposeAttachments.Resolved] {
    do {
      return try ComposeAttachments.resolve(attach)
    } catch let failure as ComposeAttachments.Failure {
      throw ValidationError(failure.description)
    }
  }
}

enum AttachmentHandoff {
  /// 🛑 **`count of mail attachments` cannot verify this** — on an *outgoing*
  /// message it fails outright with -1728 ("Can't get every mail attachment of
  /// outgoing message id N"), the same blindness `apple notes` hits counting
  /// PDF attachments. So the scripts count U+FFFC (the object-replacement
  /// character Mail leaves in `content` per attachment) before and after, and
  /// the delta is the confirmation.
  ///
  /// The delta, not the absolute count: a reply or forward starts with the
  /// quoted original already in `content`, and that can carry U+FFFC of its own
  /// from the original's inline images.
  static func verify(_ scriptResult: String, expected: [ComposeAttachments.Resolved]) throws {
    guard !expected.isEmpty else { return }

    let parts = scriptResult.split(separator: " ").compactMap { Int($0) }
    guard parts.count == 2 else {
      throw ValidationError(
        "Mail did not report how many attachments it took (got '\(scriptResult)').")
    }
    let attached = parts[1] - parts[0]
    guard attached == expected.count else {
      throw ValidationError("""
        Mail took \(attached) of \(expected.count) attachments. The compose window is open; \
        add the missing files by hand before sending.
        """)
    }
  }

  static func report(_ files: [ComposeAttachments.Resolved]) {
    guard !files.isEmpty else { return }
    print("")
    print("Attached by Mail (already in the window, not on the clipboard):")
    for file in files {
      print("  \(file.name)  (\(file.humanSize))")
    }
  }

  static func warnIfOversize(_ files: [ComposeAttachments.Resolved]) {
    guard let warning = ComposeAttachments.oversizeWarning(files) else { return }
    FileHandle.standardError.write(Data((warning + "\n").utf8))
  }
}

// MARK: - Putting the body on the pasteboard and telling the user

enum ComposeHandoff {
  /// Everything the caller needs to finish the message by hand.
  struct Result {
    let window: String
    let bodyCharacters: Int
    let format: ComposeBody.Format
    let account: String?
    let subject: String?
    let threaded: Bool?
    var attachments: [ComposeAttachments.Resolved] = []
  }

  static func loadPasteboard(text: String, format: ComposeBody.Format) throws {
    let rtf = try ComposeBody.rtf(from: text, format: format)
    let wrote = ComposePasteboard.write(rtf: rtf, plainText: text)
    // The pasteboard is the whole delivery mechanism, so a failed write is fatal
    // rather than a warning: the compose window would be there with nothing to
    // put in it, and the user would paste whatever they had copied before.
    guard wrote, ComposePasteboard.containsRTF() else {
      throw ComposeBodyError.conversionFailed("the pasteboard rejected the body")
    }
  }

  static func report(_ result: Result, json: Bool) {
    if json {
      var payload: [String: Any] = [
        "status": "awaiting_paste",
        "window": result.window,
        "body_on_pasteboard": true,
        "body_characters": result.bodyCharacters,
        "format": result.format.rawValue,
        "next": "press ⌘V in Mail, then ⌘S to save as a draft",
      ]
      payload["account"] = result.account
      payload["subject"] = result.subject
      if let threaded = result.threaded { payload["threaded"] = threaded }
      // Attachments are already in the window, so they are reported as done
      // rather than as something the user still has to do.
      payload["attachments"] = result.attachments.map {
        ["name": $0.name, "path": $0.path, "bytes": $0.bytes] as [String: Any]
      }
      let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      print(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
      return
    }

    print("Mail is open with a \(result.window) window.")
    if let subject = result.subject, !subject.isEmpty {
      print("  subject: \(subject)")
    }
    if let account = result.account, !account.isEmpty {
      print("  account: \(account)")
    }
    if result.threaded == true {
      print("  threading and the quoted original come from Mail")
    }
    AttachmentHandoff.report(result.attachments)
    print("")
    print("The body (\(result.bodyCharacters) characters) is on your clipboard.")
    print("  Press ⌘V to insert it, then ⌘S to save the draft.")
    print("")
    print("This tool does not write the body itself — a scripted body reaches")
    print("recipients as a quotation. See docs/apple-mail-drafts.md.")
  }
}

// MARK: - compose

struct Compose: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "compose",
    abstract: "Open a Mail compose window with the body on the clipboard",
    discussion: """
      Fills in recipients, subject and sending account, then leaves the body to
      you: it goes on the clipboard, and you press ⌘V and ⌘S.

      The tool never writes the body. A body set by AppleScript is wrapped in
      <blockquote type="cite"> and reaches recipients rendered as a quotation,
      invisibly to the sender — see docs/apple-mail-drafts.md.

      Examples:
        apple-mail compose --to a@b.com --subject "Q3" --body "text"
        apple-mail compose --to a@b.com --subject "Q3" --markdown --body-file notes.md
      """)

  @Option(name: .long, help: "Recipient address. Repeat for several.")
  var to: [String] = []

  @Option(name: .long, help: "Cc address. Repeat for several.")
  var cc: [String] = []

  @Option(name: .long, help: "Bcc address. Repeat for several.")
  var bcc: [String] = []

  @Option(name: .long, help: "Subject line")
  var subject: String = ""

  /// `--account` is accepted as a synonym because every other command here
  /// spells this `--account`, and reaching for it first is the obvious mistake.
  @Option(
    name: [.customLong("from"), .customLong("account")],
    help: "Send from this account address; defaults to your default account")
  var from: String?

  @OptionGroup var bodyOptions: ComposeBodyOptions

  @OptionGroup var attachmentOptions: AttachmentOptions

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else {
      throw ValidationError("A message needs at least one --to, --cc or --bcc.")
    }
    let (text, format) = try bodyOptions.resolved()
    let files = try attachmentOptions.resolved()

    try MailPreflight.check("Opening a compose window")
    try ComposeHandoff.loadPasteboard(text: text, format: format)
    AttachmentHandoff.warnIfOversize(files)

    var argv = [
      subject, from ?? "", String(to.count), String(cc.count), String(bcc.count),
      String(files.count),
    ]
    argv += to + cc + bcc + files.map(\.path)
    let result = try runAppleScript(
      composeWindowScript, arguments: argv, deadline: MailDeadline.reply)
    try AttachmentHandoff.verify(result, expected: files)

    ComposeHandoff.report(
      .init(
        window: "new message", bodyCharacters: text.count, format: format,
        account: from, subject: subject, threaded: nil, attachments: files),
      json: json)
  }
}

/// Recipients are added one at a time from argv rather than interpolated, so an
/// address containing a quote or a backslash cannot become AppleScript.
private let composeWindowScript = """
  on run argv
    set theSubject to item 1 of argv
    set theSender to item 2 of argv
    set toCount to (item 3 of argv) as integer
    set ccCount to (item 4 of argv) as integer
    set bccCount to (item 5 of argv) as integer
    set attachCount to (item 6 of argv) as integer

    tell application "Mail"
      -- visible:true is the point: the window is where the user pastes.
      set msg to make new outgoing message with properties {subject:theSubject, visible:true}
      if theSender is not "" then set sender of msg to theSender

      set i to 7
      repeat with n from 1 to toCount
        tell msg to make new to recipient at end of to recipients ¬
          with properties {address:(item i of argv)}
        set i to i + 1
      end repeat
      repeat with n from 1 to ccCount
        tell msg to make new cc recipient at end of cc recipients ¬
          with properties {address:(item i of argv)}
        set i to i + 1
      end repeat
      repeat with n from 1 to bccCount
        tell msg to make new bcc recipient at end of bcc recipients ¬
          with properties {address:(item i of argv)}
        set i to i + 1
      end repeat

      set markersBefore to my markerCount(content of msg)
      repeat with n from 1 to attachCount
        -- No `set content` anywhere: assigning content is what wraps the body
        -- in <blockquote type="cite">. Making an attachment element does not,
        -- and works on an empty body without seeding it first.
        tell msg to make new attachment with properties ¬
          {file name:(POSIX file (item i of argv))} at after the last paragraph of content
        set i to i + 1
      end repeat
      set markersAfter to my markerCount(content of msg)

      activate
    end tell
    return (markersBefore as text) & " " & (markersAfter as text)
  end run

  -- Counts U+FFFC, the object-replacement character Mail leaves in `content`
  -- for each attachment. Text item delimiters rather than a character loop:
  -- iterating a forwarded body character by character takes seconds.
  on markerCount(theText)
    -- 🛑 The empty-string guard is load-bearing. `count of text items of ""` is
    -- 0, not 1, so the delimiter trick returns -1 for an empty body and every
    -- attachment then appears to add two markers instead of one. A fresh
    -- compose window has exactly that empty body.
    if (length of theText) is 0 then return 0
    set saved to AppleScript's text item delimiters
    set AppleScript's text item delimiters to (character id 65532)
    set n to (count of text items of theText) - 1
    set AppleScript's text item delimiters to saved
    return n
  end markerCount
  """

// MARK: - reply and forward

/// Shared resolution: a Message-ID to something AppleScript can address.
///
/// 🛑 Never enumerates a mailbox. See `MailStore.MessageReference`.
private func resolveOriginal(messageID: String, account: String?, verb: String)
  throws -> MailStore.MessageReference
{
  let store: MailStore
  do {
    store = try MailStore()
  } catch {
    throw MailUnavailable(message: """
      \(verb) needs Mail's index to find the original, and it could not be read: \
      \(error.localizedDescription)
      That needs Full Disk Access for this terminal.
      """)
  }

  let reference = try store.messageReference(messageID: messageID, account: account)

  // 🛑 A draft has no sender, so there is nothing to reply to — and handing one
  // to Mail's reply verb wedged Mail's scripting interface during development.
  // Decided off the index, before any Apple Event.
  guard !reference.isDraft else {
    throw ValidationError("""
      '\(messageID)' is a draft, and a draft cannot be replied to or forwarded — it has no \
      sender. Refusing before asking Mail, because doing it wedges Mail's scripting interface.
      """)
  }
  return reference
}

struct Reply: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "reply",
    abstract: "Open a Mail reply window with the body on the clipboard",
    discussion: """
      Mail builds the reply: recipients, subject, In-Reply-To/References and the
      quoted original. Your text goes on the clipboard, and you press ⌘V and ⌘S.

      The cursor lands above the quotation, which is where the text belongs.

      Examples:
        apple-mail reply <message-id> --body "Sounds good."
        apple-mail reply <message-id> --all --body-file -
      """)

  @Argument(help: "Message-ID of the message to reply to")
  var messageID: String

  @Flag(name: .long, help: "Reply to all recipients, not just the sender")
  var all = false

  @Option(name: .long, help: "Only look for the original in this account")
  var account: String?

  @OptionGroup var bodyOptions: ComposeBodyOptions

  @OptionGroup var attachmentOptions: AttachmentOptions

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    let (text, format) = try bodyOptions.resolved()
    let files = try attachmentOptions.resolved()
    let original = try resolveOriginal(messageID: messageID, account: account, verb: "Replying")

    try MailPreflight.check("Opening a reply window")
    try ComposeHandoff.loadPasteboard(text: text, format: format)
    AttachmentHandoff.warnIfOversize(files)

    var argv = [
      original.account, original.mailbox, String(original.rowid), all ? "yes" : "no",
      String(MailDeadline.inScript(under: MailDeadline.reply)), String(files.count),
    ]
    argv += files.map(\.path)
    let result = try runAppleScript(
      replyWindowScript, arguments: argv, deadline: MailDeadline.reply)
    try AttachmentHandoff.verify(result, expected: files)

    ComposeHandoff.report(
      .init(
        window: all ? "reply-all" : "reply", bodyCharacters: text.count, format: format,
        account: original.account, subject: original.subject, threaded: true, attachments: files),
      json: json)
  }
}

struct Forward: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "forward",
    abstract: "Open a Mail forward window with the body on the clipboard",
    discussion: """
      Mail builds the forward, including any attachments the original carried —
      which is why this is left to Mail rather than rebuilt. Your text goes on
      the clipboard, and you press ⌘V and ⌘S.

      A forward has no recipients of its own, so at least one --to is required.

      Example:
        apple-mail forward <message-id> --to a@b.com --body "FYI"
      """)

  @Argument(help: "Message-ID of the message to forward")
  var messageID: String

  @Option(name: .long, help: "Recipient address. Repeat for several.")
  var to: [String] = []

  @Option(name: .long, help: "Cc address. Repeat for several.")
  var cc: [String] = []

  @Option(name: .long, help: "Only look for the original in this account")
  var account: String?

  @OptionGroup var bodyOptions: ComposeBodyOptions

  @OptionGroup var attachmentOptions: AttachmentOptions

  @Flag(name: .long, help: "Output as JSON")
  var json = false

  func run() async throws {
    guard !to.isEmpty || !cc.isEmpty else {
      throw ValidationError("A forward has no recipients of its own: pass at least one --to.")
    }
    let (text, format) = try bodyOptions.resolved()
    let files = try attachmentOptions.resolved()
    let original = try resolveOriginal(messageID: messageID, account: account, verb: "Forwarding")

    try MailPreflight.check("Opening a forward window")
    try ComposeHandoff.loadPasteboard(text: text, format: format)
    AttachmentHandoff.warnIfOversize(files)

    var argv = [
      original.account, original.mailbox, String(original.rowid),
      String(MailDeadline.inScript(under: MailDeadline.reply)),
      String(to.count), String(cc.count), String(files.count),
    ]
    argv += to + cc + files.map(\.path)
    let result = try runAppleScript(
      forwardWindowScript, arguments: argv, deadline: MailDeadline.reply)
    try AttachmentHandoff.verify(result, expected: files)

    ComposeHandoff.report(
      .init(
        window: "forward", bodyCharacters: text.count, format: format,
        account: original.account, subject: original.subject, threaded: false, attachments: files),
      json: json)
  }
}

/// ⚠️ The `with timeout` covers the lookup, which is the part that hangs against
/// a degraded Mail. Opening the window is not a save, so there is nothing
/// half-written to leave behind if it expires.
private let replyWindowScript = """
  on run argv
    set acct to item 1 of argv
    set box to item 2 of argv
    set theID to (item 3 of argv) as integer
    set replyAll to (item 4 of argv) is "yes"
    set budget to (item 5 of argv) as integer
    set attachCount to (item 6 of argv) as integer

    tell application "Mail"
      with timeout of budget seconds
        set m to first message of mailbox box of account acct whose id is theID
        if replyAll then
          set r to reply m with opening window and reply to all
        else
          set r to reply m with opening window without reply to all
        end if

        set markersBefore to 0
        set markersAfter to 0
        if attachCount > 0 then
          -- The quoted original is already in `content` and may carry U+FFFC of
          -- its own from inline images, so the delta is what counts.
          set markersBefore to my markerCount(content of r)
          set i to 7
          repeat with n from 1 to attachCount
            tell r to make new attachment with properties ¬
              {file name:(POSIX file (item i of argv))} at after the last paragraph of content
            set i to i + 1
          end repeat
          set markersAfter to my markerCount(content of r)
        end if

        activate
      end timeout
    end tell
    return (markersBefore as text) & " " & (markersAfter as text)
  end run

  on markerCount(theText)
    -- 🛑 The empty-string guard is load-bearing. `count of text items of ""` is
    -- 0, not 1, so the delimiter trick returns -1 for an empty body and every
    -- attachment then appears to add two markers instead of one. A fresh
    -- compose window has exactly that empty body.
    if (length of theText) is 0 then return 0
    set saved to AppleScript's text item delimiters
    set AppleScript's text item delimiters to (character id 65532)
    set n to (count of text items of theText) - 1
    set AppleScript's text item delimiters to saved
    return n
  end markerCount
  """

private let forwardWindowScript = """
  on run argv
    set acct to item 1 of argv
    set box to item 2 of argv
    set theID to (item 3 of argv) as integer
    set budget to (item 4 of argv) as integer
    set toCount to (item 5 of argv) as integer
    set ccCount to (item 6 of argv) as integer
    set attachCount to (item 7 of argv) as integer

    tell application "Mail"
      with timeout of budget seconds
        set m to first message of mailbox box of account acct whose id is theID
        set f to forward m with opening window

        set i to 8
        repeat with n from 1 to toCount
          tell f to make new to recipient at end of to recipients ¬
            with properties {address:(item i of argv)}
          set i to i + 1
        end repeat
        repeat with n from 1 to ccCount
          tell f to make new cc recipient at end of cc recipients ¬
            with properties {address:(item i of argv)}
          set i to i + 1
        end repeat

        set markersBefore to 0
        set markersAfter to 0
        if attachCount > 0 then
          -- ⚠️ A forward already carries the original's own attachments, which
          -- show up here as U+FFFC too. Counting the delta rather than the
          -- total is what keeps them from reading as ours.
          set markersBefore to my markerCount(content of f)
          repeat with n from 1 to attachCount
            tell f to make new attachment with properties ¬
              {file name:(POSIX file (item i of argv))} at after the last paragraph of content
            set i to i + 1
          end repeat
          set markersAfter to my markerCount(content of f)
        end if

        activate
      end timeout
    end tell
    return (markersBefore as text) & " " & (markersAfter as text)
  end run

  on markerCount(theText)
    -- 🛑 The empty-string guard is load-bearing. `count of text items of ""` is
    -- 0, not 1, so the delimiter trick returns -1 for an empty body and every
    -- attachment then appears to add two markers instead of one. A fresh
    -- compose window has exactly that empty body.
    if (length of theText) is 0 then return 0
    set saved to AppleScript's text item delimiters
    set AppleScript's text item delimiters to (character id 65532)
    set n to (count of text items of theText) - 1
    set AppleScript's text item delimiters to saved
    return n
  end markerCount
  """
