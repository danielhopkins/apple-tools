import Foundation

/// Escape a string for embedding in an AppleScript double-quoted literal that
/// will be handed to `osascript -e`.
///
/// **Prefer passing values as `argv`.** Everything that composes a message
/// already does, which is why the compose script needs no escaping at all: a
/// body containing quotes, backslashes, newlines or emoji survives verbatim and
/// cannot be parsed as AppleScript. This helper exists for the one construct
/// that cannot take its value from `argv` — the `whose` predicate in the
/// AppleScript search, where the term is part of the query expression Mail
/// compiles.
///
/// **Two characters, and only two.** Measured against `osascript -e` on
/// macOS 27, not copied from another project's escape list:
///
/// | In the literal | `length of "a?b"` |
/// |---|---|
/// | `\` | **syntax error (-2741)** |
/// | `"` | **syntax error (-2741)** |
/// | raw newline | 3 |
/// | raw tab | 3 |
/// | raw U+2028 / U+2029 | 3 |
///
/// A backslash was the live bug: the old escaping handled `"` and not `\`, so
/// `apple mail search 'back\slash' --engine applescript` died with
/// `Expected “"” but found unknown token`. Backslash is escaped **first**, or
/// the backslash the quote pass introduces gets escaped in turn.
///
/// 🛑 **Do not add the others "defensively".** Peer projects escape newline,
/// tab and the Unicode separators U+2028/U+2029 — reasonable for message
/// *bodies*, wrong for a search term. `osascript -e` takes the script as an
/// argv string rather than a parsed file, so all four are legal inside a
/// literal, and rewriting them changes what the user searched for:
/// `character id` of the second character of `"a\nb"` is 10, of a raw U+2028
/// it is 8232. Escaping a working character is a silently wrong query, which
/// is worse than the syntax error it was meant to prevent.
public func escapedForAppleScriptLiteral(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
