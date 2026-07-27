import AppleToolsVersion
import ArgumentParser
import Foundation

private let reminders = Reminders()

/// Shared output-format flags. `--json` is the portable spelling used by every
/// tool in apple-tools; `--format` is kept for backwards compatibility.
struct FormatOptions: ParsableArguments {
    @Option(
        name: .shortAndLong,
        help: "format, either of 'plain' or 'json'")
    var format: OutputFormat = .plain

    @Flag(name: .long, help: "Output as JSON (shorthand for --format json)")
    var json = false

    var resolved: OutputFormat { self.json ? .json : self.format }
}

private struct ShowLists: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the name of lists to pass to other commands")
    @OptionGroup var formatOptions: FormatOptions

    func run() {
        reminders.showLists(outputFormat: formatOptions.resolved)
    }
}

private struct ShowAll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print all reminders")

    @Flag(help: "Show completed items only")
    var onlyCompleted = false

    @Flag(help: "Include completed items in output")
    var includeCompleted = false

    @Flag(help: "When using --due-date, also include items due before the due date")
    var includeOverdue = false

    @Option(
        name: .shortAndLong,
        help: "Show only reminders due on this date")
    var dueDate: DateComponents?

    @OptionGroup var formatOptions: FormatOptions

    func validate() throws {
        if self.onlyCompleted && self.includeCompleted {
            throw ValidationError(
                "Cannot specify both --show-completed and --only-completed")
        }
    }

    func run() {
        var displayOptions = DisplayOptions.incomplete
        if self.onlyCompleted {
            displayOptions = .complete
        } else if self.includeCompleted {
            displayOptions = .all
        }

        reminders.showAllReminders(
            dueOn: self.dueDate, includeOverdue: self.includeOverdue,
            displayOptions: displayOptions, outputFormat: formatOptions.resolved)
    }
}

private struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the items on the given list")

    @Argument(
        help: "The list to print items from, see 'show-lists' for names",
        completion: .custom(listNameCompletion))
    var listName: String

    @Flag(help: "Show completed items only")
    var onlyCompleted = false

    @Flag(help: "Include completed items in output")
    var includeCompleted = false

    @Flag(help: "When using --due-date, also include items due before the due date")
    var includeOverdue = false

    @Option(
        name: .shortAndLong,
        help: "Show the reminders in a specific order, one of: \(Sort.commaSeparatedCases)")
    var sort: Sort = .none

    @Option(
        name: [.customShort("o"), .long],
        help: "How the sort order should be applied, one of: \(CustomSortOrder.commaSeparatedCases)")
    var sortOrder: CustomSortOrder = .ascending

    @Option(
        name: .shortAndLong,
        help: "Show only reminders due on this date")
    var dueDate: DateComponents?

    @OptionGroup var formatOptions: FormatOptions

    func validate() throws {
        if self.onlyCompleted && self.includeCompleted {
            throw ValidationError(
                "Cannot specify both --show-completed and --only-completed")
        }
    }

    func run() {
        var displayOptions = DisplayOptions.incomplete
        if self.onlyCompleted {
            displayOptions = .complete
        } else if self.includeCompleted {
            displayOptions = .all
        }

        reminders.showListItems(
            withName: self.listName, dueOn: self.dueDate, includeOverdue: self.includeOverdue,
            displayOptions: displayOptions, outputFormat: formatOptions.resolved, sort: sort, sortOrder: sortOrder)
    }
}

private struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a reminder to a list")

    @Argument(
        help: "The list to add to, see 'show-lists' for names",
        completion: .custom(listNameCompletion))
    var listName: String

    @Argument(
        parsing: .remaining,
        help: "The reminder contents")
    var reminder: [String]

    @Option(
        name: .shortAndLong,
        help: "The date the reminder is due")
    var dueDate: DateComponents?

    @Option(
        name: .shortAndLong,
        help: "The priority of the reminder")
    var priority: Priority = .none

    @Option(
        name: [.customShort("r"), .customLong("repeat")],
        help: "Recurrence frequency: none/daily/weekly/monthly/yearly")
    var repeatFrequency: RepeatFrequency = .none

    @Option(
        name: .customLong("repeat-interval"),
        help: "Recurrence interval (every N units), default 1")
    var repeatInterval: Int?

    @Option(
        name: .customLong("repeat-until"),
        help: "End the recurrence on this date")
    var repeatUntil: DateComponents?

    @Option(
        name: .customLong("repeat-count"),
        help: "End the recurrence after this many occurrences")
    var repeatCount: Int?

    @OptionGroup var formatOptions: FormatOptions

    @Option(
        name: .shortAndLong,
        help: "The notes to add to the reminder")
    var notes: String?

    func validate() throws {
        try validateRecurrenceFlags(
            frequency: repeatFrequency,
            interval: repeatInterval,
            until: repeatUntil,
            count: repeatCount)
    }

    func run() {
        reminders.addReminder(
            string: self.reminder.joined(separator: " "),
            notes: self.notes,
            toListNamed: self.listName,
            dueDateComponents: self.dueDate,
            priority: priority,
            recurrence: makeRecurrenceConfig(
                frequency: repeatFrequency,
                interval: repeatInterval,
                until: repeatUntil,
                count: repeatCount),
            outputFormat: formatOptions.resolved)
    }
}

private struct Complete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Complete a reminder")

    @Argument(
        help: "The list to complete a reminder on, see 'show-lists' for names",
        completion: .custom(listNameCompletion))
    var listName: String

    @Argument(
        help: "The index or id of the reminder to delete, see 'show' for indexes")
    var index: String

    func run() {
        reminders.setComplete(true, itemAtIndex: self.index, onListNamed: self.listName)
    }
}

private struct Uncomplete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Uncomplete a reminder")

    @Argument(
        help: "The list to uncomplete a reminder on, see 'show-lists' for names",
        completion: .custom(listNameCompletion))
    var listName: String

    @Argument(
        help: "The index or id of the reminder to delete, see 'show' for indexes")
    var index: String

    func run() {
        reminders.setComplete(false, itemAtIndex: self.index, onListNamed: self.listName)
    }
}

private struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a reminder")

    @Argument(
        help: "The list to delete a reminder on, see 'show-lists' for names",
        completion: .custom(listNameCompletion))
    var listName: String

    @Argument(
        help: "The index or id of the reminder to delete, see 'show' for indexes")
    var index: String

    func run() {
        reminders.delete(itemAtIndex: self.index, onListNamed: self.listName)
    }
}

func listNameCompletion(_ arguments: [String]) -> [String] {
    // NOTE: A list name with ':' was separated in zsh completion, there might be more of these or
    // this might break other shells
    return reminders.getListNames().map { $0.replacingOccurrences(of: ":", with: "\\:") }
}

private func validateRecurrenceFlags(
    frequency: RepeatFrequency?,
    interval: Int?,
    until: DateComponents?,
    count: Int?
) throws {
    let hasRecurrence = frequency != nil && frequency != RepeatFrequency.none
    if !hasRecurrence && (interval != nil || until != nil || count != nil) {
        throw ValidationError("--repeat-interval, --repeat-until, and --repeat-count require --repeat with a frequency (daily/weekly/monthly/yearly)")
    }
    if until != nil && count != nil {
        throw ValidationError("--repeat-until and --repeat-count are mutually exclusive")
    }
    if let interval, interval < 1 {
        throw ValidationError("--repeat-interval must be >= 1")
    }
    if let count, count < 1 {
        throw ValidationError("--repeat-count must be >= 1")
    }
}

private func makeRecurrenceConfig(
    frequency: RepeatFrequency,
    interval: Int?,
    until: DateComponents?,
    count: Int?
) -> RecurrenceConfig {
    return RecurrenceConfig(
        frequency: frequency,
        interval: interval ?? 1,
        endDate: until,
        occurrences: count
    )
}

private struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit the text of a reminder")

    @Argument(
        help: "The list to edit a reminder on, see 'show-lists' for names",
        completion: .custom(listNameCompletion))
    var listName: String

    @Argument(
        help: "The index or id of the reminder to delete, see 'show' for indexes")
    var index: String

    @Option(
        name: .shortAndLong,
        help: "The notes to set on the reminder, overwriting previous notes")
    var notes: String?

    @Option(
        name: .shortAndLong,
        help: "The date the reminder is due")
    var dueDate: DateComponents?

    @Option(
        name: .shortAndLong,
        help: "The priority of the reminder")
    var priority: Priority?

    @Option(
        name: [.customShort("r"), .customLong("repeat")],
        help: "Recurrence frequency: none/daily/weekly/monthly/yearly. 'none' clears existing recurrence.")
    var repeatFrequency: RepeatFrequency?

    @Option(
        name: .customLong("repeat-interval"),
        help: "Recurrence interval (every N units), default 1")
    var repeatInterval: Int?

    @Option(
        name: .customLong("repeat-until"),
        help: "End the recurrence on this date")
    var repeatUntil: DateComponents?

    @Option(
        name: .customLong("repeat-count"),
        help: "End the recurrence after this many occurrences")
    var repeatCount: Int?

    @Argument(
        parsing: .remaining,
        help: "The new reminder contents")
    var reminder: [String] = []

    func validate() throws {
        if self.reminder.isEmpty
            && self.notes == nil
            && self.dueDate == nil
            && self.priority == nil
            && self.repeatFrequency == nil
            && self.repeatInterval == nil
            && self.repeatUntil == nil
            && self.repeatCount == nil
        {
            throw ValidationError("Must specify either new reminder content, new notes, new due date, new priority, or new recurrence")
        }

        try validateRecurrenceFlags(
            frequency: repeatFrequency,
            interval: repeatInterval,
            until: repeatUntil,
            count: repeatCount)
    }

    func run() {
        let newText = self.reminder.joined(separator: " ")
        reminders.edit(
            itemAtIndex: self.index,
            onListNamed: self.listName,
            newText: newText.isEmpty ? nil : newText,
            newNotes: self.notes,
            newDueDate: self.dueDate,
            newPriority: self.priority,
            newRecurrence: repeatFrequency.flatMap { freq in
                makeRecurrenceConfig(
                    frequency: freq,
                    interval: repeatInterval,
                    until: repeatUntil,
                    count: repeatCount)
            }
        )
    }
}


private struct NewList: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new list")

    @Argument(
        help: "The name of the new list")
    var listName: String

    @Option(
        name: .shortAndLong,
        help: "The name of the source of the list, if all your lists use the same source it will default to that")
    var source: String?

    func run() {
        reminders.newList(with: self.listName, source: self.source)
    }
}

public struct CLI: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Interact with macOS Reminders from the command line",
        discussion: """
          Indexes come from `show` and SHIFT as items are added or completed.
          Always re-run `show` immediately before complete/edit/delete.

          Examples:
            reminders show-lists --json
            reminders show-all --due-date today --include-overdue --json
            reminders add Inbox "Buy milk" --due-date "tomorrow 9am"
            reminders add Home "Bins out" --repeat weekly --priority high
            reminders show Inbox && reminders complete Inbox 0
          """,
        version: appleToolsVersion,
        subcommands: [
            Add.self,
            Complete.self,
            Uncomplete.self,
            Delete.self,
            Edit.self,
            Show.self,
            ShowLists.self,
            NewList.self,
            ShowAll.self,
        ]
    )

    public init() {}
}
