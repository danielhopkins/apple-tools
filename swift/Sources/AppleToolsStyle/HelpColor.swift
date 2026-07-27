import ArgumentParser
import Foundation

/// Colourised `--help` for the Swift tools.
///
/// Python 3.14's argparse colours help automatically, which is why apple-notes
/// looks the way it does. swift-argument-parser has no equivalent, so its help
/// text is generated as usual and then styled here, and the tools print that
/// instead of letting ArgumentParser print its own.
///
/// Styling mirrors argparse's scheme so the tools look like one family:
/// section headings bold blue, the command name magenta, flags and subcommand
/// names green.
public enum HelpColor {
    /// Returns colourised help when the arguments ask for it, else nil.
    ///
    /// Walks the subcommand path first, so `tool sub --help` shows help for
    /// `sub` rather than the root.
    public static func requested(
        root: ParsableCommand.Type, arguments: [String]
    ) -> String? {
        let args = Array(arguments.dropFirst())
        guard args.contains(where: { $0 == "-h" || $0 == "--help" || $0 == "help" }) else {
            return nil
        }

        // Descend as far as the named subcommands go.
        var current = root
        var path: [ParsableCommand.Type] = []
        for argument in args {
            guard !argument.hasPrefix("-"), argument != "help" else { continue }
            guard let next = current.configuration.subcommands.first(where: {
                $0._commandName == argument
            }) else { break }
            path.append(next)
            current = next
        }

        let help = path.isEmpty
            ? root.helpMessage(columns: nil)
            : root.helpMessage(for: current, columns: nil)
        return colorize(help)
    }

    /// Style ArgumentParser's help text. Purely presentational — the text is
    /// unchanged, so anything scraping help still sees the same words.
    public static func colorize(_ help: String) -> String {
        guard Style.enabled else { return help }

        var section = ""
        var output: [String] = []

        for line in help.components(separatedBy: "\n") {
            // Section headings: OVERVIEW:, USAGE:, OPTIONS:, SUBCOMMANDS:, ...
            if let match = line.range(of: "^[A-Z][A-Z ]*:", options: .regularExpression) {
                section = String(line[match]).replacingOccurrences(of: ":", with: "")
                let heading = Style.heading(String(line[match]))
                var rest = String(line[match.upperBound...])
                // USAGE: <command> ... — highlight the command name itself.
                if section == "USAGE" {
                    let trimmed = rest.drop(while: { $0 == " " })
                    if let end = trimmed.firstIndex(of: " ") {
                        let command = String(trimmed[trimmed.startIndex..<end])
                        rest = " " + Style.command(command) + String(trimmed[end...])
                    }
                }
                output.append(heading + rest)
                continue
            }

            // Entries sit at exactly two spaces of indent. Anything deeper is
            // a wrapped continuation of the previous description — colouring
            // that would put a stray highlight mid-sentence.
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 2, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                output.append(styleEntry(line, section: section))
                continue
            }

            output.append(line)
        }

        return output.joined(separator: "\n")
    }

    /// Colour the left-hand column of an indented help entry, leaving the
    /// description alone. The two are separated by a run of spaces.
    private static func styleEntry(_ line: String, section: String) -> String {
        let indentCount = line.prefix(while: { $0 == " " }).count
        let indent = String(repeating: " ", count: indentCount)
        let rest = String(line.dropFirst(indentCount))

        // Split on the first run of two or more spaces: the description column.
        let name: String
        let remainder: String
        if let gap = rest.range(of: " {2,}", options: .regularExpression) {
            name = String(rest[rest.startIndex..<gap.lowerBound])
            remainder = String(rest[gap.lowerBound...])
        } else {
            name = rest
            remainder = ""
        }

        switch section {
        case "OPTIONS", "ARGUMENTS", "FLAGS":
            return indent + Style.flag(name) + remainder
        case "SUBCOMMANDS":
            return indent + Style.subcommand(name) + remainder
        default:
            // Examples and discussion text: leave as written.
            return line
        }
    }
}
