import ArgumentParser
import EventKit
import Foundation

// MARK: - Recurrence
//
// The flag surface here deliberately mirrors `apple reminders` — `--repeat`,
// `--repeat-interval`, `--repeat-until`, `--repeat-count`, with `-r` as the
// short form and the same validation rules and wording — so that knowing one
// tool means knowing the other.
//
// It is a **parallel implementation, not shared code**, and that is a choice
// rather than an oversight: `RemindersLibrary` expresses dates as
// `DateComponents` while this tool expresses them as `DateArg` (which accepts
// "next friday"), so the only genuinely common part is the frequency enum and
// four validation rules. Importing the reminders library to share those would
// couple a calendar binary to the whole reminders surface. If a third tool ever
// needs recurrence, extract a module then.

/// Recurrence frequency. Case names match `apple reminders --repeat` exactly.
enum RepeatFrequency: String, ExpressibleByArgument, CaseIterable {
  case none, daily, weekly, monthly, yearly

  var ekFrequency: EKRecurrenceFrequency? {
    switch self {
    case .none: return nil
    case .daily: return .daily
    case .weekly: return .weekly
    case .monthly: return .monthly
    case .yearly: return .yearly
    }
  }
}

// MARK: - "the 4th monday of each month"

/// Which day within the month a monthly series lands on.
///
/// ⚠️ **`--repeat monthly` alone cannot express this**, and that is not a gap in
/// the flag surface — it is what `EKRecurrenceRule`'s simple initializer means.
/// A plain monthly rule repeats on *the start date's day number*, so a series
/// starting Mon 28 Sep recurs on the 28th, not on the fourth Monday. The two
/// coincide for exactly one month and then diverge silently, which is the kind
/// of wrong nobody notices until someone misses a meeting.
///
/// Reminders has no equivalent, so this is the one place the two tools' flag
/// surfaces deliberately differ.
enum MonthlyPattern: Equatable {
  /// "4th monday", "last friday" — an ordinal weekday. `-1` is last.
  case weekday(EKWeekday, ordinal: Int)
  /// "15", "last" — a day number. `-1` is the last day of the month.
  case dayOfMonth(Int)

  private static let weekdays: [String: EKWeekday] = [
    "sunday": .sunday, "sun": .sunday,
    "monday": .monday, "mon": .monday,
    "tuesday": .tuesday, "tue": .tuesday, "tues": .tuesday,
    "wednesday": .wednesday, "wed": .wednesday,
    "thursday": .thursday, "thu": .thursday, "thur": .thursday, "thurs": .thursday,
    "friday": .friday, "fri": .friday,
    "saturday": .saturday, "sat": .saturday,
  ]

  private static let ordinals: [String: Int] = [
    "1st": 1, "first": 1, "2nd": 2, "second": 2, "3rd": 3, "third": 3,
    "4th": 4, "fourth": 4, "5th": 5, "fifth": 5, "last": -1,
  ]

  static func parse(_ raw: String) -> MonthlyPattern? {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty else { return nil }

    let words = text.split(separator: " ").map(String.init)

    if words.count == 2, let ordinal = ordinals[words[0]], let day = weekdays[words[1]] {
      return .weekday(day, ordinal: ordinal)
    }
    // A bare weekday means the first one, matching how people say "on mondays".
    if words.count == 1, let day = weekdays[words[0]] {
      return .weekday(day, ordinal: 1)
    }
    if words.count == 1 {
      if words[0] == "last" { return .dayOfMonth(-1) }
      if let number = Int(words[0]), (1...31).contains(number) {
        return .dayOfMonth(number)
      }
    }
    return nil
  }

  /// Does `date` actually fall on this pattern? Used to warn when --start and
  /// --on-the disagree, because EventKit takes the rule and the start date at
  /// face value and produces a series whose first occurrence is the odd one out.
  func matches(_ date: Date) -> Bool {
    let calendar = Foundation.Calendar.current
    switch self {
    case .weekday(let day, let ordinal):
      guard calendar.component(.weekday, from: date) == day.rawValue else { return false }
      if ordinal == -1 {
        guard let next = calendar.date(byAdding: .day, value: 7, to: date) else { return false }
        return calendar.component(.month, from: next) != calendar.component(.month, from: date)
      }
      let weekOfMonth = (calendar.component(.day, from: date) - 1) / 7 + 1
      return weekOfMonth == ordinal
    case .dayOfMonth(let number):
      if number == -1 {
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return false }
        return calendar.component(.day, from: date) == range.count
      }
      return calendar.component(.day, from: date) == number
    }
  }

  var describe: String {
    switch self {
    case .weekday(let day, let ordinal):
      let names = [1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
                   5: "Thursday", 6: "Friday", 7: "Saturday"]
      let name = names[day.rawValue] ?? "?"
      let position = ordinal == -1 ? "last" : ["", "1st", "2nd", "3rd", "4th", "5th"][min(ordinal, 5)]
      return "the \(position) \(name)"
    case .dayOfMonth(let number):
      return number == -1 ? "the last day" : "day \(number)"
    }
  }
}

/// The recurrence flags, shared by `add` and `edit`.
struct RecurrenceOptions: ParsableArguments {
  /// Optional rather than defaulted to `.none`, unlike the reminders version.
  /// The CLI surface is identical, but `edit` has to tell "the user passed
  /// --repeat none, remove the rule" from "the user passed nothing, leave the
  /// rule alone" — and with a default of `.none` those are the same value.
  @Option(
    name: [.customShort("r"), .customLong("repeat")],
    help: "Recurrence frequency: none/daily/weekly/monthly/yearly")
  var repeatFrequency: RepeatFrequency?

  @Option(name: .customLong("repeat-interval"), help: "Recurrence interval (every N units), default 1")
  var repeatInterval: Int?

  @Option(name: .customLong("repeat-until"), help: "End the recurrence on this date")
  var repeatUntil: DateArg?

  @Option(name: .customLong("repeat-count"), help: "End the recurrence after this many occurrences")
  var repeatCount: Int?

  @Option(
    name: .customLong("on-the"),
    help: "Which day of the month, e.g. '4th monday', 'last friday', '15'. Needs --repeat monthly.")
  var onThe: String?

  /// True when the caller asked for recurrence at all. `--repeat none` is
  /// *specified* but not recurring, which is what makes removal expressible.
  var isRecurring: Bool { repeatFrequency != nil && repeatFrequency != RepeatFrequency.none }

  /// True when any recurrence flag was passed, including `--repeat none`.
  /// Distinguishes "leave the rule alone" from "remove the rule" on `edit`.
  var wasSpecified: Bool {
    repeatFrequency != nil || repeatInterval != nil || repeatUntil != nil
      || repeatCount != nil || onThe != nil
  }

  var monthlyPattern: MonthlyPattern? {
    onThe.flatMap(MonthlyPattern.parse)
  }

  /// Same rules and same wording as `apple reminders`, so an error learned in
  /// one tool reads identically in the other.
  func validate() throws {
    if !isRecurring && (repeatInterval != nil || repeatUntil != nil || repeatCount != nil) {
      throw ValidationError(
        "--repeat-interval, --repeat-until, and --repeat-count require --repeat with a "
          + "frequency (daily/weekly/monthly/yearly)")
    }
    if repeatUntil != nil && repeatCount != nil {
      throw ValidationError("--repeat-until and --repeat-count are mutually exclusive")
    }
    if let repeatInterval, repeatInterval < 1 {
      throw ValidationError("--repeat-interval must be >= 1")
    }
    if let repeatCount, repeatCount < 1 {
      throw ValidationError("--repeat-count must be >= 1")
    }
    if let onThe {
      guard MonthlyPattern.parse(onThe) != nil else {
        throw ValidationError(
          "--on-the '\(onThe)' is not a day of the month. Use '4th monday', 'last friday', "
            + "a bare weekday like 'monday', a day number like '15', or 'last'.")
      }
      // EventKit accepts an ordinal weekday only on a monthly (or yearly) rule;
      // attaching one to a daily or weekly rule produces a series that ignores
      // it, so refuse rather than silently dropping the flag.
      guard repeatFrequency == .monthly else {
        throw ValidationError(
          "--on-the needs --repeat monthly (got "
            + (repeatFrequency.map { "--repeat \($0.rawValue)" } ?? "no --repeat") + ").")
      }
    }
  }

  /// Nil when the event should not recur.
  func rule() -> EKRecurrenceRule? {
    guard let frequency = repeatFrequency?.ekFrequency else { return nil }
    let end: EKRecurrenceEnd?
    if let until = repeatUntil {
      end = EKRecurrenceEnd(end: until.date)
    } else if let count = repeatCount {
      end = EKRecurrenceEnd(occurrenceCount: count)
    } else {
      end = nil
    }

    guard let pattern = monthlyPattern else {
      return EKRecurrenceRule(
        recurrenceWith: frequency, interval: repeatInterval ?? 1, end: end)
    }

    // The long initializer is the only one that can express a positional day.
    var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
    var daysOfTheMonth: [NSNumber]?
    switch pattern {
    case .weekday(let day, let ordinal):
      daysOfTheWeek = [EKRecurrenceDayOfWeek(dayOfTheWeek: day, weekNumber: ordinal)]
    case .dayOfMonth(let number):
      daysOfTheMonth = [NSNumber(value: number)]
    }

    return EKRecurrenceRule(
      recurrenceWith: frequency,
      interval: repeatInterval ?? 1,
      daysOfTheWeek: daysOfTheWeek,
      daysOfTheMonth: daysOfTheMonth,
      monthsOfTheYear: nil,
      weeksOfTheYear: nil,
      daysOfTheYear: nil,
      setPositions: nil,
      end: end)
  }

  /// ⚠️ EventKit takes the start date and the rule at face value, so a series
  /// starting on a day the pattern does not describe has a first occurrence
  /// that is the odd one out — and nothing errors. Warn instead of guessing.
  func startDateWarning(start: Date) -> String? {
    guard let pattern = monthlyPattern, !pattern.matches(start) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d yyyy"
    return """
      note: --start is \(formatter.string(from: start)), which is not \(pattern.describe) \
      of that month. The first occurrence will sit on the start date and later ones will \
      follow \(pattern.describe).
      """
  }
}

// MARK: - Reporting

/// A recurrence rule in a form worth printing.
///
/// ⚠️ `recurring: true` on its own never said *how* an event repeats, so this
/// is reported alongside it rather than replacing it.
struct RecurrenceInfo: Encodable {
  let frequency: String
  let interval: Int
  let until: String?
  let count: Int?
  /// "the 4th Monday" — present only for a positional monthly rule.
  let onThe: String?

  enum CodingKeys: String, CodingKey {
    case frequency, interval, until, count
    case onThe = "on_the"
  }

  init?(_ rule: EKRecurrenceRule?) {
    guard let rule else { return nil }

    if let day = rule.daysOfTheWeek?.first, day.weekNumber != 0 {
      onThe = MonthlyPattern.weekday(day.dayOfTheWeek, ordinal: day.weekNumber).describe
    } else if let day = rule.daysOfTheMonth?.first {
      onThe = MonthlyPattern.dayOfMonth(day.intValue).describe
    } else {
      onThe = nil
    }
    switch rule.frequency {
    case .daily: frequency = "daily"
    case .weekly: frequency = "weekly"
    case .monthly: frequency = "monthly"
    case .yearly: frequency = "yearly"
    @unknown default: frequency = "unknown"
    }
    interval = rule.interval
    until = rule.recurrenceEnd?.endDate.map { ISO8601DateFormatter().string(from: $0) }
    // occurrenceCount is 0 when the end is a date or the series is open-ended,
    // so report nil rather than a misleading zero.
    let occurrences = rule.recurrenceEnd?.occurrenceCount ?? 0
    count = occurrences > 0 ? occurrences : nil
  }

  /// "every 2 weeks, until Dec 25" — for the human output.
  var describe: String {
    let unit: String
    switch frequency {
    case "daily": unit = interval == 1 ? "day" : "days"
    case "weekly": unit = interval == 1 ? "week" : "weeks"
    case "monthly": unit = interval == 1 ? "month" : "months"
    case "yearly": unit = interval == 1 ? "year" : "years"
    default: unit = frequency
    }
    var text = interval == 1 ? "every \(unit)" : "every \(interval) \(unit)"
    if let onThe { text += " on \(onThe)" }
    if let until, let date = ISO8601DateFormatter().date(from: until) {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d, yyyy"
      text += ", until \(formatter.string(from: date))"
    } else if let count {
      text += ", \(count) times"
    }
    return text
  }
}
