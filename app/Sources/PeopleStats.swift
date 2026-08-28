// Who you talk to, read in one call.
//
// ⚠️ SEPARATE FROM `IndexStats`, and on its own timer. `stats` runs every
// thirty seconds and answers "is the index healthy". This one reads every
// indexed body and shells out to Contacts and call history — about three
// seconds — and answers nothing the app needs in order to work. So it is
// fetched when the window is open and not otherwise, and a failure here shows
// as an empty panel rather than as a broken index.

import Foundation

struct MonthCount: Equatable {
    let month: String        // "2026-08"
    let date: Date           // the first of that month, UTC
    let count: Int
}

struct Person: Identifiable, Equatable {
    let id: String
    let name: String
    let handle: String
    /// True when a card in Contacts claims one of this person's handles.
    let known: Bool
    /// 🛑 DAYS ON WHICH SOMETHING PASSED BETWEEN YOU, and the only number
    /// this view ranks or sizes by. A count of items cannot be compared
    /// across sources — one mail record is one email, one messages record is
    /// a block of ten texts — and adding them together reported a spouse of
    /// twenty years at 9,059 of nothing in particular.
    let days: Int
    /// Items per channel, each in its OWN unit: emails, texts, events, calls.
    /// ⚠️ NEVER SUM THESE. They do not share a unit.
    let channels: [String: Int]
    /// Days per channel. This is the comparable one.
    let channelDays: [String: Int]
    /// The same items, counted only when nobody else was on them. 🛑 PER
    /// CHANNEL, like `channels`. A single figure came out at 17,201 for one
    /// person — texts wearing a number that reads like emails.
    let alone: [String: Int]
    /// Events and reminders dated in the FUTURE. 🛑 NOT contact, and never in
    /// `days` — the calendar adapter fetches a year ahead, so a recurring
    /// swimming lesson otherwise gave its organiser contact every week until
    /// next August.
    let upcoming: Int
    /// Things you were both on without talking. ⚠️ NOT contact, and never in
    /// `days` — a newsletter to forty parents is not a conversation with any
    /// of them. It is kept because it is what the web's lines are made of.
    ///
    /// ⚠️ TWO KINDS SHARE THIS COUNT: an email a third party wrote to you
    /// both, and a day whose every photograph came from somebody else's
    /// camera. Both are co-occurrence rather than contact, which is why they
    /// are counted together — but they are not the same evidence, and this
    /// number cannot say which it holds.
    let sameList: Int
    let first: Date?
    let last: Date?
    let months: [MonthCount]

    /// The channel you use on the most DAYS. 🛑 Not the one with the most
    /// items: texts are counted one at a time and emails one at a time, so
    /// texting wins that comparison whatever the truth is.
    var dominantChannel: String {
        channelDays.max { $0.value < $1.value }?.key ?? "mail"
    }
}

struct PeopleEdge: Equatable {
    let a: String
    let b: String
    let weight: Int
}

struct EmojiCount: Identifiable, Equatable {
    var id: String { emoji }
    let emoji: String
    let count: Int
}

struct EmojiYear: Identifiable, Equatable {
    var id: String { year }
    let year: String
    let emoji: String
    let count: Int
    let total: Int
}

/// One emoji released since 2020, and when the user first sent it.
///
/// 🛑 `released` IS UNICODE'S DATE, NOT APPLE'S. It is the `# Date:` header on
/// that Emoji version's own data file at unicode.org, fetched by
/// `lab/emoji-versions`. A vendor ships the glyph some months later, so the
/// lag is measured from publication, which is the only date with a source.
struct EmojiArrival: Identifiable, Equatable {
    var id: String { emoji }
    let emoji: String
    let version: String
    let released: Date
    /// Nil when the user has never sent it. ⚠️ ABSENT, NOT ZERO: never used
    /// and used on the day of release are opposite answers.
    let first: Date?
    let lagDays: Int?
}

struct EmojiAdoption: Equatable {
    var released = 0
    var used = 0
    var medianLagDays: Int? = nil
    /// 🛑 SENT BEFORE UNICODE PUBLISHED IT. A record with a wrong date makes
    /// one, and so does a vendor that shipped early. Counted rather than
    /// clamped, because the count is the only sign the dates are off.
    var early = 0
    var items: [EmojiArrival] = []
}

struct EmojiReport: Equatable {
    var total = 0
    var distinct = 0
    var fromMessages = 0
    var fromMail = 0
    var top: [EmojiCount] = []
    var byYear: [EmojiYear] = []
    /// The least-used emoji of each year. ⚠️ Something the user really did
    /// type, once — an emoji never sent belongs to no year at all.
    var rarest: [EmojiYear] = []
    /// Nil when `emoji-versions.txt` was not shipped beside `index.py`.
    var adoption: EmojiAdoption? = nil
}

struct PeopleStats: Equatable {
    var loaded = false
    var error: String? = nil
    var generated: Date? = nil
    /// Every handle counted as the user, and the subset that was inferred
    /// rather than read from Mail. 🛑 SHOWN IN THE WINDOW: a wrong guess here
    /// deletes a real person from their own graph, so it must be visible.
    var me: [String] = []
    var detectedMe: [String] = []
    /// Addresses taken as the user because they sign themselves with the name
    /// on the user's own contact card. Reported, never absorbed silently.
    var meByName: [String] = []
    var records = 0
    var peopleSeen = 0
    var calls = 0
    /// Everyone left out, and why. 🛑 REPORTED, NEVER SILENT. Each rule can
    /// be wrong about somebody, and a person who has quietly vanished from
    /// their own social graph is exactly what nobody would notice.
    var excludedCount = 0
    var excludedReasons: [(String, Int)] = []
    var excludedExamples: [(name: String, reason: String)] = []
    var totalDays = 0
    var phoneFirst: Date? = nil
    var phoneLast: Date? = nil
    var people: [Person] = []
    /// Everybody, for the search box — without the month series, which is what
    /// makes a record big. ⚠️ These carry no `months`, so nothing that draws a
    /// timeline may read one from here.
    var directory: [Person] = []
    var directoryOmitted = 0
    /// When the report was actually computed, and whether this reading came
    /// from the stored copy rather than from a fresh run.
    var computed: Date? = nil
    var fromCache = false
    var edges: [PeopleEdge] = []
    var emoji = EmojiReport()

    static func == (a: PeopleStats, b: PeopleStats) -> Bool {
        a.generated == b.generated && a.error == b.error
            && a.people.count == b.people.count && a.edges.count == b.edges.count
            && a.emoji == b.emoji && a.excludedCount == b.excludedCount
    }

    /// The people worth drawing: everyone with a name and some history.
    var named: [Person] { people.filter { $0.days > 0 } }

    var span: (Date, Date)? {
        let firsts = people.compactMap(\.first)
        let lasts = people.compactMap(\.last)
        guard let low = firsts.min(), let high = lasts.max() else { return nil }
        return (low, high)
    }
}

enum PeopleReader {
    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// ⚠️ UTC AND `en_US_POSIX`, like `month` above. `index.py` writes a bare
    /// `YYYY-MM-DD`, and a device set to a non-Gregorian calendar parses that
    /// into a date centuries away without erroring.
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func day(_ text: String?) -> Date? {
        text.flatMap { dayFormat.date(from: $0) }
    }

    /// 🛑 CHEAP UNLESS ASKED. Without `refresh` this reads the stored report —
    /// 80 ms against 3.6 s — and `index.py` recomputes it only when the stored
    /// one is a day old.
    static func read(refresh: Bool = false) -> PeopleStats {
        var stats = PeopleStats()
        guard let script = Paths.indexScript else {
            stats.error = "no index.py found"
            return stats
        }
        let result = Child.run(
            Paths.python,
            [script.path, "--db", Paths.database.path, "people"]
                + (refresh ? ["--refresh"] : []),
            timeout: 600)
        guard result.ok, let data = result.out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            // The last stderr line, for the same reason `StatsReader` takes it:
            // a traceback's first line names the file rather than the failure.
            stats.error = result.err.split(separator: "\n").last.map(String.init)
                ?? "people failed (exit \(result.status))"
            return stats
        }

        stats.generated = (root["generated"] as? Double).map(Date.init(timeIntervalSince1970:))
        stats.computed = (root["computed"] as? Double).map(Date.init(timeIntervalSince1970:))
        stats.fromCache = root["cached"] as? Bool ?? false
        let me = root["me"] as? [String: Any] ?? [:]
        stats.me = me["handles"] as? [String] ?? []
        stats.detectedMe = me["detected"] as? [String] ?? []
        stats.meByName = me["by_name"] as? [String] ?? []
        let counts = root["counts"] as? [String: Any] ?? [:]
        stats.records = counts["records"] as? Int ?? 0
        stats.peopleSeen = counts["people"] as? Int ?? 0
        stats.calls = counts["calls"] as? Int ?? 0
        stats.excludedCount = counts["excluded"] as? Int ?? 0
        stats.excludedReasons = (root["excluded"] as? [String: Int] ?? [:])
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
        stats.excludedExamples = (root["excluded_examples"] as? [[String: Any]] ?? [])
            .compactMap {
                guard let name = $0["name"] as? String,
                      let reason = $0["reason"] as? String else { return nil }
                return (name, reason)
            }
        stats.totalDays = (root["people"] as? [[String: Any]] ?? [])
            .reduce(0) { $0 + (($1["days"] as? Int) ?? 0) }
        if let window = root["phone_window"] as? [String: Any] {
            stats.phoneFirst = (window["first"] as? Double).map(Date.init(timeIntervalSince1970:))
            stats.phoneLast = (window["last"] as? Double).map(Date.init(timeIntervalSince1970:))
        }

        // 🛑 ONE SHARED AXIS. Each person's series is a list of positions
        // into it, so "2014-07" is stored once rather than nine thousand
        // times. That is what makes a month series affordable for everybody
        // rather than only for the few dozen the web draws.
        let axis: [Date] = (root["months_axis"] as? [String] ?? [])
            .compactMap { name in month.date(from: name).map { ($0, name) } }
            .map { $0.0 }
        let axisNames = root["months_axis"] as? [String] ?? []

        func person(_ entry: [String: Any]) -> Person {
            Person(
                id: entry["id"] as? String ?? "?",
                name: entry["name"] as? String ?? "?",
                handle: entry["handle"] as? String ?? "",
                known: entry["known"] as? Bool ?? false,
                days: entry["days"] as? Int ?? 0,
                channels: (entry["channels"] as? [String: Int]) ?? [:],
                channelDays: (entry["channel_days"] as? [String: Int]) ?? [:],
                alone: (entry["alone"] as? [String: Int]) ?? [:],
                upcoming: entry["upcoming"] as? Int ?? 0,
                sameList: entry["same_list"] as? Int ?? 0,
                first: (entry["first"] as? Double).map(Date.init(timeIntervalSince1970:)),
                last: (entry["last"] as? Double).map(Date.init(timeIntervalSince1970:)),
                months: (entry["months"] as? [[Int]] ?? []).compactMap { pair in
                    guard pair.count == 2, axis.indices.contains(pair[0]) else {
                        return nil
                    }
                    return MonthCount(month: axisNames[pair[0]],
                                      date: axis[pair[0]], count: pair[1])
                })
        }
        stats.people = (root["people"] as? [[String: Any]] ?? []).map(person)
        stats.directory = (root["directory"] as? [[String: Any]] ?? []).map(person)
        stats.directoryOmitted = root["directory_omitted"] as? Int ?? 0
        stats.edges = (root["edges"] as? [[String: Any]] ?? []).compactMap {
            guard let a = $0["a"] as? String, let b = $0["b"] as? String,
                  let weight = $0["weight"] as? Int else { return nil }
            return PeopleEdge(a: a, b: b, weight: weight)
        }

        let emoji = root["emoji"] as? [String: Any] ?? [:]
        var report = EmojiReport()
        report.total = emoji["total"] as? Int ?? 0
        report.distinct = emoji["distinct"] as? Int ?? 0
        let sources = emoji["sources"] as? [String: Int] ?? [:]
        report.fromMessages = sources["messages"] ?? 0
        report.fromMail = sources["mail"] ?? 0
        report.top = (emoji["top"] as? [[String: Any]] ?? []).compactMap {
            guard let glyph = $0["emoji"] as? String else { return nil }
            return EmojiCount(emoji: glyph, count: $0["count"] as? Int ?? 0)
        }
        report.byYear = (emoji["by_year"] as? [[String: Any]] ?? []).compactMap {
            guard let year = $0["year"] as? String,
                  let glyph = $0["emoji"] as? String else { return nil }
            return EmojiYear(year: year, emoji: glyph,
                             count: $0["count"] as? Int ?? 0,
                             total: $0["total"] as? Int ?? 0)
        }
        report.rarest = (emoji["rarest"] as? [[String: Any]] ?? []).compactMap {
            guard let year = $0["year"] as? String,
                  let glyph = $0["emoji"] as? String else { return nil }
            return EmojiYear(year: year, emoji: glyph,
                             count: $0["count"] as? Int ?? 0,
                             total: $0["total"] as? Int ?? 0)
        }
        if let block = emoji["adoption"] as? [String: Any] {
            var adoption = EmojiAdoption()
            adoption.released = block["released"] as? Int ?? 0
            adoption.used = block["used"] as? Int ?? 0
            adoption.medianLagDays = block["median_lag_days"] as? Int
            adoption.early = block["early"] as? Int ?? 0
            adoption.items = (block["items"] as? [[String: Any]] ?? []).compactMap {
                guard let glyph = $0["emoji"] as? String,
                      let released = day($0["released"] as? String) else { return nil }
                return EmojiArrival(emoji: glyph,
                                    version: $0["version"] as? String ?? "?",
                                    released: released,
                                    first: day($0["first"] as? String),
                                    lagDays: $0["lag_days"] as? Int)
            }
            report.adoption = adoption
        }
        stats.emoji = report
        stats.loaded = true
        return stats
    }
}
