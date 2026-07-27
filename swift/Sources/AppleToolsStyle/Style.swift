import Foundation

/// Terminal styling for human-readable output.
///
/// Colour is only ever emitted when stdout is a terminal, so piping to a file,
/// `jq`, or another program yields clean text. `--json` output must never be
/// styled — machine-readable output stays byte-identical either way.
///
/// Honours the https://no-color.org convention, plus CLICOLOR/CLICOLOR_FORCE
/// which are the BSD/macOS spelling.
public enum Style {
    public static let enabled: Bool = {
        let environment = ProcessInfo.processInfo.environment

        // Explicit opt-out wins over everything.
        if environment["NO_COLOR"] != nil { return false }
        if environment["CLICOLOR"] == "0" { return false }
        if environment["TERM"] == "dumb" { return false }

        // Explicit opt-in, for piping into something that renders ANSI.
        if let force = environment["CLICOLOR_FORCE"], force != "0" { return true }

        return isatty(FileHandle.standardOutput.fileDescriptor) == 1
    }()

    private static func wrap(_ text: String, _ code: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    /// Primary identifiers — note titles, contact names, event titles.
    public static func title(_ text: String) -> String { wrap(text, "1") }

    /// Secondary detail — labels, mailbox names, calendar names.
    public static func dim(_ text: String) -> String { wrap(text, "2") }

    /// Dates and times.
    public static func time(_ text: String) -> String { wrap(text, "36") }

    /// Ids the user is expected to copy.
    public static func identifier(_ text: String) -> String { wrap(text, "35") }

    /// Field labels: email, phone, addr.
    public static func label(_ text: String) -> String { wrap(text, "33") }

    /// Something needing attention — overdue, read-only, disabled.
    public static func warning(_ text: String) -> String { wrap(text, "31") }

    /// Confirmation of a completed write.
    public static func success(_ text: String) -> String { wrap(text, "32") }
}
