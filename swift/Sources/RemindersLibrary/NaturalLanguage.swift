import ArgumentParser
import Foundation

private let calendar = Calendar.current
private let allComponents: Set<Calendar.Component> = [
    .era, .year, .yearForWeekOfYear, .quarter, .month,
    .weekOfYear, .weekOfMonth, .weekday, .weekdayOrdinal, .day,
    .hour, .minute, .second, .nanosecond,
    .calendar, .timeZone
]
let timeComponents: Set<Calendar.Component> = [
    .hour, .minute, .second, .nanosecond,
]

func calendarComponents(except removedComponents: Set<Calendar.Component> = []) -> Set<Calendar.Component> {
    return allComponents.subtracting(removedComponents)
}

private func components(from string: String) -> DateComponents? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
        fatalError("error: failed to create NSDataDetector")
    }

    let range = NSRange(string.startIndex..<string.endIndex, in: string)

    let matches = detector.matches(in: string, options: .anchored, range: range)
    guard matches.count == 1, let match = matches.first, let date = match.date else {
        return nil
    }

    var includeTime = true
    if match.responds(to: NSSelectorFromString("timeIsSignificant")) {
        includeTime = match.value(forKey: "timeIsSignificant") as? Bool ?? true
    } else {
        print("warning: timeIsSignificant is not available, please report this to keith/reminders-cli")
    }

    // Both branches must yield the same component set, otherwise callers (and
    // tests) see a DateComponents carrying dayOfYear in one case but not the
    // other. dateComponents(in:from:) returns *every* component, so ask for the
    // modelled set explicitly against a calendar pinned to the detected zone.
    var zonedCalendar = calendar
    zonedCalendar.timeZone = match.timeZone ?? .current

    let requested = includeTime
        ? calendarComponents()
        : calendarComponents(except: timeComponents)
    return zonedCalendar.dateComponents(requested, from: date)
}

extension DateComponents: @retroactive ExpressibleByArgument {
      public init?(argument: String) {
          if let components = components(from: argument) {
              self = components
          } else {
              return nil
          }
      }
}
