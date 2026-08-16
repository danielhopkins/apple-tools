import AppleToolsStyle
import ArgumentParser
import EventKit
import Foundation
import TCCResponsibility

private let Store = EKEventStore()
private let dateFormatter = RelativeDateTimeFormatter()
private func formattedDueDate(from reminder: EKReminder) -> String? {
    return reminder.dueDateComponents?.date.map {
        dateFormatter.localizedString(for: $0, relativeTo: Date())
    }
}

private extension EKReminder {
    var mappedPriority: EKReminderPriority {
        UInt(exactly: self.priority).flatMap(EKReminderPriority.init) ?? EKReminderPriority.none
    }
}

private func isOverdue(_ reminder: EKReminder) -> Bool {
    guard let due = reminder.dueDateComponents?.date else { return false }
    return !reminder.isCompleted && due < Date()
}

/// Notes are frequently several paragraphs. Inline they swamp the list, so
/// they go on their own dimmed line, collapsed and clipped.
private func notesLine(_ reminder: EKReminder) -> String? {
    guard let notes = reminder.notes else { return nil }
    let collapsed = notes
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }

    let limit = 100
    let clipped = collapsed.count > limit
        ? String(collapsed.prefix(limit)) + "…"
        : collapsed
    return clipped
}

private func format(_ reminder: EKReminder, at index: Int?, listName: String? = nil) -> String {
    // The index is what complete/edit/delete take, so it is styled like other
    // copyable identifiers. Overdue dates are red rather than merely relative.
    let indexString = index.map { Style.identifier("\($0)") + ": " } ?? ""
    let listString = listName.map { Style.dim("\($0): ") } ?? ""
    let title = Style.title(reminder.title ?? "<unknown>")

    var suffix = ""
    if let due = formattedDueDate(from: reminder) {
        suffix += "  " + (isOverdue(reminder) ? Style.warning("(\(due))") : Style.time("(\(due))"))
    }
    if let priority = Priority(fromInt: reminder.priority) {
        let text = "(priority: \(priority))"
        suffix += "  " + (priority == .high ? Style.warning(text) : Style.label(text))
    }
    if let rule = reminder.recurrenceRules?.first {
        suffix += "  " + Style.dim("(repeats: \(humanRecurrence(rule)))")
    }
    // Rendered the way Reminders.app writes one, so it reads as a tag rather
    // than as another parenthesised attribute.
    let tags = TagCache.tags(for: reminder.calendarItemExternalIdentifier)
    if !tags.isEmpty {
        suffix += "  " + Style.label(tags.map { "#\($0)" }.joined(separator: " "))
    }

    var line = "\(listString)\(indexString)\(title)\(suffix)"
    if let notes = notesLine(reminder) {
        line += "\n    " + Style.dim(notes)
    }
    return line
}

private let recurrenceEndDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

private func humanRecurrence(_ rule: EKRecurrenceRule) -> String {
    let unit: String
    switch rule.frequency {
    case .daily:   unit = "day"
    case .weekly:  unit = "week"
    case .monthly: unit = "month"
    case .yearly:  unit = "year"
    @unknown default: unit = "interval"
    }

    let interval = rule.interval
    let base = interval == 1 ? "every \(unit)" : "every \(interval) \(unit)s"

    guard let end = rule.recurrenceEnd else { return base }
    if let endDate = end.endDate {
        return "\(base) until \(recurrenceEndDateFormatter.string(from: endDate))"
    }
    let count = end.occurrenceCount
    return count == 1 ? "\(base) for 1 occurrence" : "\(base) for \(count) occurrences"
}

public enum OutputFormat: String, ExpressibleByArgument {
    case json, plain
}

public enum DisplayOptions: String, Decodable {
    case all
    case incomplete
    case complete
}

public enum Priority: String, ExpressibleByArgument {
    case none
    case low
    case medium
    case high

    var intValue: Int {
        switch self {
            case .none: return 0
            case .low: return Int(EKReminderPriority.low.rawValue)
            case .medium: return Int(EKReminderPriority.medium.rawValue)
            case .high: return Int(EKReminderPriority.high.rawValue)
        }
    }

    init?(_ priority: EKReminderPriority) {
        switch priority {
            case .none: return nil
            case .low: self = .low
            case .medium: self = .medium
            case .high: self = .high
        @unknown default:
            return nil
        }
    }

    init?(fromInt priority: Int) {
        switch priority {
            case 0: return nil
            case 1...4: self = .high
            case 5: self = .medium
            case 6...9: self = .low
            default: return nil
        }
    }
}

public enum RepeatFrequency: String, ExpressibleByArgument, CaseIterable {
    case none, daily, weekly, monthly, yearly

    var ekFrequency: EKRecurrenceFrequency? {
        switch self {
        case .none:    return nil
        case .daily:   return .daily
        case .weekly:  return .weekly
        case .monthly: return .monthly
        case .yearly:  return .yearly
        }
    }
}

public struct RecurrenceConfig {
    public let frequency: RepeatFrequency
    public let interval: Int
    public let endDate: DateComponents?
    public let occurrences: Int?

    public init(frequency: RepeatFrequency, interval: Int, endDate: DateComponents?, occurrences: Int?) {
        self.frequency = frequency
        self.interval = interval
        self.endDate = endDate
        self.occurrences = occurrences
    }
}

private func makeRecurrenceRule(_ config: RecurrenceConfig) -> EKRecurrenceRule? {
    guard let ekFrequency = config.frequency.ekFrequency else { return nil }
    let end: EKRecurrenceEnd?
    if let date = config.endDate?.date {
        end = EKRecurrenceEnd(end: date)
    } else if let count = config.occurrences {
        end = EKRecurrenceEnd(occurrenceCount: count)
    } else {
        end = nil
    }
    return EKRecurrenceRule(recurrenceWith: ekFrequency, interval: config.interval, end: end)
}

public final class Reminders {
    /// Takes ownership of this process's TCC identity, unless Reminders already
    /// works.
    ///
    /// Without this, macOS attributes the request to whichever terminal
    /// launched us, so the grant lands on the terminal app rather than this
    /// binary and the tool is denied under any terminal that has not itself
    /// been granted. Re-executing disclaimed keys the grant here instead.
    ///
    /// Skipped when access already works, so an existing grant is untouched.
    /// Does not return when it re-executes.
    public static func claimOwnTCCIdentity() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        TCCResponsibility.claimOwnIdentity(
            unless: status == .fullAccess || status == .authorized)
    }

    public static func requestAccess() -> (Bool, Error?) {
        claimOwnTCCIdentity()

        let semaphore = DispatchSemaphore(value: 0)
        var grantedAccess = false
        var returnError: Error? = nil
        if #available(macOS 14.0, *) {
            Store.requestFullAccessToReminders { granted, error in
                grantedAccess = granted
                returnError = error
                semaphore.signal()
            }
        } else {
            Store.requestAccess(to: .reminder) { granted, error in
                grantedAccess = granted
                returnError = error
                semaphore.signal()
            }
        }

        semaphore.wait()
        return (grantedAccess, returnError)
    }

    func getListNames() -> [String] {
        return self.getCalendars().map { $0.title }
    }

    func showLists(outputFormat: OutputFormat) {
        switch (outputFormat) {
        case .json:
            print(encodeToJson(data: self.getListNames()))
        default:
            for name in self.getListNames() {
                print(Style.title(name))
            }
        }
    }

    func showAllReminders(dueOn dueDate: DateComponents?, includeOverdue: Bool,
        displayOptions: DisplayOptions, outputFormat: OutputFormat, tagFilter: [String] = []
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        let calendar = Calendar.current

        self.reminders(on: self.getCalendars(), displayOptions: displayOptions) { reminders in
            var matchingReminders = [(EKReminder, Int, String)]()
            for (i, reminder) in reminders.enumerated() {
                let listName = reminder.calendar.title
                guard let dueDate = dueDate?.date else {
                    matchingReminders.append((reminder, i, listName))
                    continue
                }

                guard let reminderDueDate = reminder.dueDateComponents?.date else {
                    continue
                }

                let sameDay = calendar.compare(
                    reminderDueDate, to: dueDate, toGranularity: .day) == .orderedSame
                let earlierDay = calendar.compare(
                    reminderDueDate, to: dueDate, toGranularity: .day) == .orderedAscending

                if sameDay || (includeOverdue && earlierDay) {
                    matchingReminders.append((reminder, i, listName))
                }
            }

            // One batch lookup for the whole listing; both branches read it.
            TagCache.populate(for: matchingReminders.map { $0.0 })
            // Filtering after the index is assigned keeps the printed index the
            // one `edit`/`complete`/`delete` take — it is a position in the
            // whole list, not in the filtered view.
            let visibleReminders = TagCache.filter(
                matchingReminders, by: tagFilter,
                externalId: { $0.0.calendarItemExternalIdentifier })

            switch outputFormat {
            case .json:
                print(encodeToJson(data: visibleReminders.map { $0.0 }))
            case .plain:
                for (reminder, i, listName) in visibleReminders {
                    print(format(reminder, at: i, listName: listName))
                }
            }

            semaphore.signal()
        }

        semaphore.wait()
    }

    func showListItems(withName name: String, dueOn dueDate: DateComponents?, includeOverdue: Bool,
        displayOptions: DisplayOptions, outputFormat: OutputFormat, sort: Sort, sortOrder: CustomSortOrder,
        tagFilter: [String] = [])
    {
        let semaphore = DispatchSemaphore(value: 0)
        let calendar = Calendar.current

        self.reminders(on: [self.calendar(withName: name)], displayOptions: displayOptions) { reminders in
            var matchingReminders = [(EKReminder, Int?)]()
            let reminders = sort == .none ? reminders : reminders.sorted(by: sort.sortFunction(order: sortOrder))
            for (i, reminder) in reminders.enumerated() {
                let index = sort == .none ? i : nil
                guard let dueDate = dueDate?.date else {
                    matchingReminders.append((reminder, index))
                    continue
                }

                guard let reminderDueDate = reminder.dueDateComponents?.date else {
                    continue
                }

                let sameDay = calendar.compare(
                    reminderDueDate, to: dueDate, toGranularity: .day) == .orderedSame
                let earlierDay = calendar.compare(
                    reminderDueDate, to: dueDate, toGranularity: .day) == .orderedAscending

                if sameDay || (includeOverdue && earlierDay) {
                    matchingReminders.append((reminder, index))
                }
            }

            // One batch lookup for the whole listing; both branches read it.
            TagCache.populate(for: matchingReminders.map { $0.0 })
            // Filtering after the index is assigned keeps the printed index the
            // one `edit`/`complete`/`delete` take — it is a position in the
            // whole list, not in the filtered view.
            let visibleReminders = TagCache.filter(
                matchingReminders, by: tagFilter,
                externalId: { $0.0.calendarItemExternalIdentifier })

            switch outputFormat {
            case .json:
                print(encodeToJson(data: visibleReminders.map { $0.0 }))
            case .plain:
                for (reminder, i) in visibleReminders {
                    print(format(reminder, at: i))
                }
            }

            semaphore.signal()
        }

        semaphore.wait()
    }

    func newList(with name: String, source requestedSourceName: String?) {
        let store = EKEventStore()
        let sources = store.sources
        guard var source = sources.first else {
            print("No existing list sources were found, please create a list in Reminders.app")
            exit(1)
        }

        if let requestedSourceName = requestedSourceName {
            guard let requestedSource = sources.first(where: { $0.title == requestedSourceName }) else
            {
                print("No source named '\(requestedSourceName)'")
                exit(1)
            }

            source = requestedSource
        } else {
            let uniqueSources = Set(sources.map { $0.title })
            if uniqueSources.count > 1 {
                print("Multiple sources were found, please specify one with --source:")
                for source in uniqueSources {
                    print("  \(source)")
                }

                exit(1)
            }
        }

        let newList = EKCalendar(for: .reminder, eventStore: store)
        newList.title = name
        newList.source = source

        do {
            try store.saveCalendar(newList, commit: true)
            print("Created new list '\(newList.title)'!")
        } catch let error {
            print("Failed create new list with error: \(error)")
            exit(1)
        }
    }

    func edit(itemAtIndex index: String, onListNamed name: String, newText: String?, newNotes: String?, newDueDate: DateComponents?, newPriority: Priority? = nil, newRecurrence: RecurrenceConfig? = nil, newLocationAlarm: EKAlarm? = nil, clearLocation: Bool = false, tagsToSet: [String]? = nil, tagsToAdd: [String] = [], tagsToRemove: [String] = []) {
        let calendar = self.calendar(withName: name)
        let semaphore = DispatchSemaphore(value: 0)

        self.reminders(on: [calendar], displayOptions: .incomplete) { reminders in
            guard let reminder = self.getReminder(from: reminders, at: index) else {
                print("No reminder at index \(index) on \(name)")
                exit(1)
            }

            do {
                reminder.title = newText ?? reminder.title
                reminder.notes = newNotes ?? reminder.notes
                if let dueDate = newDueDate {
                    reminder.dueDateComponents = dueDate
                }
                if let priority = newPriority {
                    reminder.priority = priority.intValue
                }
                if let recurrence = newRecurrence {
                    if let rule = makeRecurrenceRule(recurrence) {
                        reminder.recurrenceRules = [rule]
                    } else {
                        reminder.recurrenceRules = nil
                    }
                }
                // Setting a new location replaces the old one. Removing only
                // the location alarms leaves any due-date alarm intact — a
                // blanket `alarms = nil` would silently cancel the time
                // reminder too.
                if clearLocation || newLocationAlarm != nil {
                    reminder.removeLocationAlarms()
                }
                if let newLocationAlarm {
                    reminder.addAlarm(newLocationAlarm)
                }
                try Store.save(reminder, commit: true)

                // Tags go through ReminderKit, not EventKit, so this is a
                // separate write that can fail on its own after the rest of the
                // edit has already landed.
                if tagsToSet != nil || !tagsToAdd.isEmpty || !tagsToRemove.isEmpty {
                    guard let externalId = reminder.calendarItemExternalIdentifier else {
                        print("Updated reminder '\(reminder.title!)', but it has no external "
                            + "identifier, so its tags could not be changed.")
                        exit(1)
                    }
                    do {
                        let applied = try ReminderTags.apply(
                            externalId: externalId,
                            add: tagsToSet ?? tagsToAdd,
                            remove: tagsToRemove,
                            replaceAll: tagsToSet != nil)
                        TagCache.set(applied, for: externalId)
                    } catch {
                        print("Updated reminder '\(reminder.title!)', but changing its tags "
                            + "failed: \(error.localizedDescription)")
                        exit(1)
                    }
                }

                let tags = TagCache.tags(for: reminder.calendarItemExternalIdentifier)
                let tagSuffix = tags.isEmpty
                    ? ""
                    : " (tags: \(tags.map { "#\($0)" }.joined(separator: " ")))"
                print("Updated reminder '\(reminder.title!)'\(tagSuffix)")
            } catch let error {
                print("Failed to update reminder with error: \(error)")
                exit(1)
            }

            semaphore.signal()
        }

        semaphore.wait()
    }

    func setComplete(_ complete: Bool, itemAtIndex index: String, onListNamed name: String) {
        let calendar = self.calendar(withName: name)
        let semaphore = DispatchSemaphore(value: 0)
        let displayOptions = complete ? DisplayOptions.incomplete : .complete
        let action = complete ? "Completed" : "Uncompleted"

        self.reminders(on: [calendar], displayOptions: displayOptions) { reminders in
            print(reminders.map { $0.title! })
            guard let reminder = self.getReminder(from: reminders, at: index) else {
                print("No reminder at index \(index) on \(name)")
                exit(1)
            }

            do {
                reminder.isCompleted = complete
                try Store.save(reminder, commit: true)
                print("\(action) '\(reminder.title!)'")
            } catch let error {
                print("Failed to save reminder with error: \(error)")
                exit(1)
            }

            semaphore.signal()
        }

        semaphore.wait()
    }

    func delete(itemAtIndex index: String, onListNamed name: String) {
        let calendar = self.calendar(withName: name)
        let semaphore = DispatchSemaphore(value: 0)

        self.reminders(on: [calendar], displayOptions: .incomplete) { reminders in
            guard let reminder = self.getReminder(from: reminders, at: index) else {
                print("No reminder at index \(index) on \(name)")
                exit(1)
            }

            do {
                try Store.remove(reminder, commit: true)
                print("Deleted '\(reminder.title!)'")
            } catch let error {
                print("Failed to delete reminder with error: \(error)")
                exit(1)
            }

            semaphore.signal()
        }

        semaphore.wait()
    }

    func addReminder(
        string: String,
        notes: String?,
        toListNamed name: String,
        dueDateComponents: DateComponents?,
        priority: Priority,
        recurrence: RecurrenceConfig?,
        locationAlarm: EKAlarm? = nil,
        tags: [String] = [],
        outputFormat: OutputFormat)
    {
        let calendar = self.calendar(withName: name)
        let reminder = EKReminder(eventStore: Store)
        reminder.calendar = calendar
        reminder.title = string
        reminder.notes = notes
        reminder.dueDateComponents = dueDateComponents
        reminder.priority = priority.intValue
        if let dueDate = dueDateComponents?.date, dueDateComponents?.hour != nil {
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
        // A location alarm sits alongside a time alarm rather than replacing
        // it: "at 9am, or when I get there, whichever comes first" is a real
        // and useful reminder.
        if let locationAlarm {
            reminder.addAlarm(locationAlarm)
        }
        if let recurrence, let rule = makeRecurrenceRule(recurrence) {
            reminder.recurrenceRules = [rule]
        }

        do {
            try Store.save(reminder, commit: true)
        } catch let error {
            print("Failed to save reminder with error: \(error)")
            exit(1)
        }

        // Tags are a second write, through a different framework, so the
        // reminder already exists by the time this can fail. Say so explicitly
        // rather than letting "add failed" imply nothing was created.
        if !tags.isEmpty {
            let created = "Added '\(reminder.title!)' to '\(calendar.title)'"
            guard let externalId = reminder.calendarItemExternalIdentifier else {
                let message = "\(created), but it has no external identifier, so the tags "
                    + "could not be applied.\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
            do {
                let applied = try ReminderTags.applyToNewReminder(
                    externalId: externalId, tags: tags)
                TagCache.set(applied, for: externalId)
            } catch {
                let message = "\(created), but tagging it failed: "
                    + "\(error.localizedDescription)\n"
                    + "The reminder exists and is untagged; add the tags in Reminders.app.\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
        }

        switch (outputFormat) {
        case .json:
            print(encodeToJson(data: reminder))
        default:
            print("Added '\(reminder.title!)' to '\(calendar.title)'")
        }
    }

    // MARK: - Private functions

    private func reminders(
        on calendars: [EKCalendar],
        displayOptions: DisplayOptions,
        completion: @escaping (_ reminders: [EKReminder]) -> Void)
    {
        let predicate = Store.predicateForReminders(in: calendars)
        Store.fetchReminders(matching: predicate) { reminders in
            let reminders = reminders?
                .filter { self.shouldDisplay(reminder: $0, displayOptions: displayOptions) }
            completion(reminders ?? [])
        }
    }

    private func shouldDisplay(reminder: EKReminder, displayOptions: DisplayOptions) -> Bool {
        switch displayOptions {
        case .all:
            return true
        case .incomplete:
            return !reminder.isCompleted
        case .complete:
            return reminder.isCompleted
        }
    }

    private func calendar(withName name: String) -> EKCalendar {
        if let calendar = self.getCalendars().find(where: { $0.title.lowercased() == name.lowercased() }) {
            return calendar
        } else {
            print("No reminders list matching \(name)")
            exit(1)
        }
    }

    private func getCalendars() -> [EKCalendar] {
        return Store.calendars(for: .reminder)
                    .filter { $0.allowsContentModifications }
    }

    private func getReminder(from reminders: [EKReminder], at index: String) -> EKReminder? {
        precondition(!index.isEmpty, "Index cannot be empty, argument parser must be misconfigured")
        if let index = Int(index) {
            return reminders[safe: index]
        } else {
            return reminders.first { $0.calendarItemExternalIdentifier == index }
        }
    }

}

private func encodeToJson(data: Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try! encoder.encode(data)
    return String(data: encoded, encoding: .utf8) ?? ""
}
