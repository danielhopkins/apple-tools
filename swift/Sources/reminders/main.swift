import AppleToolsStyle
import Darwin
import Foundation
import RemindersLibrary

/// Arguments that only print something and never touch the store. Asking for
/// TCC access for these is wrong: it makes `--help` prompt on a fresh machine,
/// and makes completion-script generation fail wherever access isn't granted
/// (a build box, or `make completions` before the user has approved anything).
private let infoOnlyArguments: Set<String> = [
    "-h", "--help", "help",
    "--version",
    "--generate-completion-script",
]

private let wantsInfoOnly = CommandLine.arguments.dropFirst().contains {
    infoOnlyArguments.contains($0)
}

if let help = HelpColor.requested(root: CLI.self, arguments: CommandLine.arguments) {
    print(help)
    exit(0)
} else if wantsInfoOnly {
    CLI.main()
} else {
    switch Reminders.requestAccess() {
    case (true, _):
        CLI.main()
    case (false, let error):
        FileHandle.standardError.write(
            Data("error: you need to grant reminders access\n".utf8))
        if let error {
            FileHandle.standardError.write(
                Data("error: \(error.localizedDescription)\n".utf8))
        }
        FileHandle.standardError.write(
            Data("Grant it in System Settings → Privacy & Security → Reminders.\n".utf8))
        exit(1)
    }
}
