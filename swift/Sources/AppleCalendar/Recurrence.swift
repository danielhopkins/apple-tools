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

/// Which day within the month a monthly or yearly series lands on.
///
/// ⚠️ **`--repeat monthly` alone cannot express this**, and that is not a gap in
/// the flag surface — it is what `EKRecurrenceRule`'s simple initializer means.
/// A plain monthly rule repeats on *the start date's day number*, so a series
/// starting Mon 28 Sep recurs on the 28th, not on the fourth Monday. The two
/// coincide for exactly one month and then diverge silently, which is the kind
/// of wrong nobody notices until someone misses a meeting.
///
/// 🛑 **The two cases are NOT valid on the same set of frequencies**, and the
/// SDK header is explicit about it. `daysOfTheWeek` — the `.weekday` case — is
/// "valid for all recurrence types except daily". `daysOfTheMonth` — the
/// `.dayOfMonth` case — is "valid only for monthly recurrences. **Ignored**
/// otherwise." So `--on-the "4th monday"` works on a yearly rule and
/// `--on-the 15` does not, and the second one fails by being dropped rather
/// than by erroring. `frequencies` below is what keeps that from shipping.
///
/// Reminders has no equivalent, so this is the one place the two tools' flag
/// surfaces deliberately differ.
enum DayPattern: Equatable {
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

  static func parse(_ raw: String) -> DayPattern? {
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

  /// Which `--repeat` frequencies EventKit actually honours this case on.
  /// Anything else is *ignored* by the framework, never rejected, so the CLI
  /// has to refuse it here or the flag disappears without a word.
  var frequencies: [RepeatFrequency] {
    switch self {
    case .weekday: return [.monthly, .yearly]
    case .dayOfMonth: return [.monthly]
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

// MARK: - "every year, but only in January through April"

/// The months a yearly rule is restricted to — `BYMONTH` in iCalendar,
/// `monthsOfTheYear` in EventKit.
///
/// 🛑 **Without this a yearly rule cannot say "only some months of the year"**,
/// and the only expressible substitute is a *bounded* monthly series that has
/// to be recreated by hand every year. That is not a hypothetical cost: one
/// committee series on this calendar was rebuilt and allowed to lapse three
/// separate times, in 2021, 2023 and 2025, for exactly this reason.
///
/// ⚠️ **`monthsOfTheYear` is "valid only for yearly recurrences. Ignored
/// otherwise"** per the SDK header, so `--months` on any other frequency is
/// refused rather than dropped.
enum MonthSet {
  private static let names: [String: Int] = [
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6,
    "jul": 7, "july": 7, "aug": 8, "august": 8,
    "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
    "nov": 11, "november": 11, "dec": 12, "december": 12,
  ]

  /// Parses one token: a number 1-12, or a month name in any case.
  /// Nil means "not a month", which the caller turns into an error naming it.
  static func parse(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty else { return nil }
    if let number = Int(text) { return (1...12).contains(number) ? number : nil }
    return names[text]
  }

  /// Parses the whole flag. `--months` is repeatable *and* comma-separated, so
  /// `--months 1,2 --months apr` and `--months 1,2,4` mean the same thing.
  /// Sorted and de-duplicated, because a rule listing March twice is the same
  /// rule and reading it back should not suggest otherwise.
  static func parseAll(_ raw: [String]) throws -> [Int]? {
    let tokens = raw
      .flatMap { $0.split(separator: ",") }
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }
    var months: Set<Int> = []
    for token in tokens {
      guard let month = parse(token) else {
        throw ValidationError(
          "--months '\(token)' is not a month. Use a number 1-12 or a name like "
            + "'jan' or 'january'.")
      }
      months.insert(month)
    }
    return months.sorted()
  }

  private static let short = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  static func describe(_ months: [Int]) -> String {
    months.map { short[$0] }.joined(separator: ", ")
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
    help: """
      Which day of the month, e.g. '4th monday', 'last friday', '15'. \
      Needs --repeat monthly, or --repeat yearly for the weekday forms.
      """)
  var onThe: String?

  @Option(
    name: .customLong("months"),
    help: """
      Restrict a yearly rule to these months: '1,2,3,4' or 'jan,feb,mar,apr'. \
      Repeatable. Needs --repeat yearly.
      """)
  var months: [String] = []

  /// True when the caller asked for recurrence at all. `--repeat none` is
  /// *specified* but not recurring, which is what makes removal expressible.
  var isRecurring: Bool { repeatFrequency != nil && repeatFrequency != RepeatFrequency.none }

  /// True when any recurrence flag was passed, including `--repeat none`.
  /// Distinguishes "leave the rule alone" from "remove the rule" on `edit`.
  var wasSpecified: Bool {
    repeatFrequency != nil || repeatInterval != nil || repeatUntil != nil
      || repeatCount != nil || onThe != nil || !months.isEmpty
  }

  var dayPattern: DayPattern? {
    onThe.flatMap(DayPattern.parse)
  }

  /// Nil when `--months` was not passed. Throws when a token is not a month.
  func monthsOfTheYear() throws -> [Int]? {
    try MonthSet.parseAll(months)
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
      guard let pattern = DayPattern.parse(onThe) else {
        throw ValidationError(
          "--on-the '\(onThe)' is not a day of the month. Use '4th monday', 'last friday', "
            + "a bare weekday like 'monday', a day number like '15', or 'last'.")
      }
      // 🛑 EventKit *ignores* a day pattern on a frequency that does not carry
      // it — no error, and the series comes back repeating on the start date's
      // day number instead. So the refusal has to happen here, and it has to be
      // per-case: an ordinal weekday is valid monthly and yearly, a bare day
      // number only monthly.
      let allowed = pattern.frequencies
      guard let repeatFrequency, allowed.contains(repeatFrequency) else {
        let want = allowed.map { "--repeat \($0.rawValue)" }.joined(separator: " or ")
        let got = repeatFrequency.map { "--repeat \($0.rawValue)" } ?? "no --repeat"
        var message = "--on-the '\(onThe)' needs \(want) (got \(got))."
        if case .dayOfMonth = pattern, repeatFrequency == .yearly {
          message += """
             EventKit carries a day number on monthly rules only, and ignores it \
            on a yearly one. For a yearly rule use a weekday form like '4th monday', \
            or pin the day with --start and --months.
            """
        }
        throw ValidationError(message)
      }
    }

    // ⚠️ `monthsOfTheYear` is "valid only for yearly recurrences. Ignored
    // otherwise" (EKRecurrenceRule.h). Silently dropping --months would give
    // back a rule that fires all twelve months, which is the failure this flag
    // exists to prevent.
    if let months = try monthsOfTheYear(), !months.isEmpty {
      guard repeatFrequency == .yearly else {
        throw ValidationError(
          "--months needs --repeat yearly (got "
            + (repeatFrequency.map { "--repeat \($0.rawValue)" } ?? "no --repeat")
            + "). A rule that fires in some months of every year is FREQ=YEARLY;BYMONTH=…; "
            + "--repeat monthly already means every month.")
      }
    }
  }

  /// Nil when the event should not recur.
  ///
  /// Throws only for a `--months` token `validate()` would already have
  /// rejected; the parse is repeated here rather than cached so there is one
  /// definition of what the flag means.
  func rule() throws -> EKRecurrenceRule? {
    guard let frequency = repeatFrequency?.ekFrequency else { return nil }
    let end: EKRecurrenceEnd?
    if let until = repeatUntil {
      end = EKRecurrenceEnd(end: until.date)
    } else if let count = repeatCount {
      end = EKRecurrenceEnd(occurrenceCount: count)
    } else {
      end = nil
    }

    let months = try monthsOfTheYear()

    guard dayPattern != nil || months != nil else {
      return EKRecurrenceRule(
        recurrenceWith: frequency, interval: repeatInterval ?? 1, end: end)
    }

    // The long initializer is the only one that can express a positional day or
    // a months filter. It is also the only one that can express both at once,
    // which is the whole point: FREQ=YEARLY;BYMONTH=1,2,3,4;BYDAY=4MO.
    var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
    var daysOfTheMonth: [NSNumber]?
    switch dayPattern {
    case .weekday(let day, let ordinal):
      daysOfTheWeek = [EKRecurrenceDayOfWeek(dayOfTheWeek: day, weekNumber: ordinal)]
    case .dayOfMonth(let number):
      daysOfTheMonth = [NSNumber(value: number)]
    case nil:
      break
    }

    return EKRecurrenceRule(
      recurrenceWith: frequency,
      interval: repeatInterval ?? 1,
      daysOfTheWeek: daysOfTheWeek,
      daysOfTheMonth: daysOfTheMonth,
      monthsOfTheYear: months?.map { NSNumber(value: $0) },
      weeksOfTheYear: nil,
      daysOfTheYear: nil,
      setPositions: nil,
      end: end)
  }

  /// ⚠️ EventKit takes the start date and the rule at face value, so a series
  /// starting on a day the pattern does not describe has a first occurrence
  /// that is the odd one out — and nothing errors. Warn instead of guessing.
  func startDateWarning(start: Date) -> String? {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d yyyy"
    var notes: [String] = []

    if let pattern = dayPattern, !pattern.matches(start) {
      notes.append("""
        note: --start is \(formatter.string(from: start)), which is not \(pattern.describe) \
        of that month. The first occurrence will sit on the start date and later ones will \
        follow \(pattern.describe).
        """)
    }

    // Same trap, one level up: a start month outside --months makes the first
    // occurrence the odd one out and every later one follow the filter.
    let month = Foundation.Calendar.current.component(.month, from: start)
    if let months = try? monthsOfTheYear(), !months.contains(month) {
      notes.append("""
        note: --start is \(formatter.string(from: start)), whose month is not in \
        --months \(MonthSet.describe(months)). The first occurrence will sit on the start \
        date and later ones will fall in \(MonthSet.describe(months)) only.
        """)
    }

    return notes.isEmpty ? nil : notes.joined(separator: "\n")
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
  /// "the 4th Monday" — present only for a positional monthly or yearly rule.
  let onThe: String?
  /// `[1, 2, 3, 4]` — present only on a yearly rule restricted by --months.
  /// Absent, never `[]`, matching every other optional key in this tool.
  let months: [Int]?

  enum CodingKeys: String, CodingKey {
    case frequency, interval, until, count, months
    case onThe = "on_the"
  }

  init?(_ rule: EKRecurrenceRule?) {
    guard let rule else { return nil }

    if let day = rule.daysOfTheWeek?.first, day.weekNumber != 0 {
      onThe = DayPattern.weekday(day.dayOfTheWeek, ordinal: day.weekNumber).describe
    } else if let day = rule.daysOfTheMonth?.first {
      onThe = DayPattern.dayOfMonth(day.intValue).describe
    } else {
      onThe = nil
    }
    let monthNumbers = rule.monthsOfTheYear?.map { $0.intValue }.sorted()
    months = (monthNumbers?.isEmpty ?? true) ? nil : monthNumbers
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
    if let months { text += " in \(MonthSet.describe(months))" }
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
