// The fifth question: who is in all this data?
//
// The four panels above answer whether the index works. This one answers what
// it is made of, and it is the only part of the window a person opens for
// pleasure rather than to fix something.
//
//   the web       who turns up alongside whom
//   the emoji     what you type when you are not typing words
//   the journey   when each person arrived, and whether they are still here
//
// 🛑 EVERY NUMBER HERE IS A COUNT OF RECORDS, NOT OF MESSAGES. A messages
// record is a block of consecutive texts, a mail record is one email, and a
// calendar record is one event. So "8,390" is a number of encounters, not a
// number of things said, and the panel says so rather than implying a
// precision the index does not have.

import SwiftUI

extension People {
    /// The plain word for each exclusion rule.
    static func reason(_ key: String, _ count: Int) -> String {
        switch key {
        case "marked":        return "you called " + (count == 1 ? "a business"
                                                         : "businesses")
        case "never-answered": return "you never wrote back to"
        case "bulk-mail":      return count == 1 ? "newsletter" : "newsletters"
        case "bounce":         return "bounce " + (count == 1 ? "path" : "paths")
        case "company":       return count == 1 ? "company" : "companies"
        case "short-code":    return "SMS short " + (count == 1 ? "code" : "codes")
        case "no-reply":      return "automated " + (count == 1 ? "address" : "addresses")
        case "calendar-feed": return "calendar " + (count == 1 ? "feed" : "feeds")
        case "list":          return "mailing " + (count == 1 ? "list" : "lists")
        default:              return key
        }
    }
}

enum Channel {
    static let all = ["mail", "messages", "phone", "calendar"]

    static func color(_ name: String) -> Color {
        switch name {
        case "messages": return .green
        case "phone":    return .orange
        case "calendar": return .purple
        default:         return .blue
        }
    }

    /// 🛑 EACH CHANNEL'S OWN UNIT. "5,183" meant a different thing in every
    /// column, and the columns sat side by side as if they matched.
    static func unit(_ name: String, _ count: Int) -> String {
        switch name {
        case "messages": return count == 1 ? "text" : "texts"
        case "phone":    return count == 1 ? "call" : "calls"
        case "calendar": return count == 1 ? "event" : "events"
        default:         return count == 1 ? "email" : "emails"
        }
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "messages": return "message.fill"
        case "phone":    return "phone.fill"
        case "calendar": return "calendar"
        default:         return "envelope.fill"
        }
    }
}

// MARK: - the section

struct People: View {
    @ObservedObject var model: AppModel
    /// 🛑 OWNED HERE, NOT BY THE SEARCH BOX. Typing a name filters the
    /// timeline below as well as listing matches: "show me both Meyers" is one
    /// question, and answering half of it in one panel is what made the search
    /// feel like a dead end.
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Panel("Who you talk to", trailing: {
                HStack(spacing: 10) {
                    // ⚠️ SAY HOW OLD IT IS. A stored answer that cannot be told
                    // from a fresh one cannot be told from a stale one either,
                    // and this one is a day old by design.
                    if let computed = model.people.computed {
                        Text("computed \(Format.ago(computed))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(model.peopleBusy ? "Recalculating…" : "Recalculate") {
                        model.refreshPeople(force: true)
                    }
                    .disabled(model.peopleBusy)
                    .controlSize(.small)
                }
            }) {
                let stats = model.people
                if let failure = stats.error {
                    PeopleNote("Could not read it: \(failure)", tint: .red)
                } else if !stats.loaded {
                    PeopleNote("Reading it…")
                } else {
                    Summary(stats: stats)
                    ContactWeb(stats: stats)
                }
            }
            if model.people.loaded, model.people.error == nil {
                Lookup(stats: model.people, query: $query)
                Journey(stats: model.people, query: query)
                EmojiPanel(report: model.people.emoji)
            }
        }
        .onAppear { model.refreshPeople() }
    }
}

private struct Summary: View {
    let stats: PeopleStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 26) {
                Stat("people", Format.count(stats.peopleSeen))
                Stat("shown", Format.count(stats.people.count))
                Stat("records read", Format.count(stats.records))
                if let span = stats.span {
                    Stat("years", "\(Calendar.current.dateComponents([.year], from: span.0, to: span.1).year ?? 0)")
                }
                Spacer()
            }
            // 🛑 SAY WHAT THE NUMBER IS. Everything below is ranked and sized
            // by DAYS on which something passed between you, because a count
            // of items cannot be compared across sources: one email is one
            // record and ten texts are also one record. Adding them reported
            // a spouse of twenty years at "9,059 encounters", which is what
            // made this panel worth doubting.
            //
            // ⚠️ IT IS BACKGROUND, NOT NEWS. It was four grey paragraphs under
            // the numbers, and four paragraphs of standing explanation is a
            // wall people scroll past — including the one line that is about
            // a mistake they can fix.
            HStack(spacing: 12) {
                ExplainLabel("Counted in days", "How this is counted", """
                             Everything here is ranked and sized by the number \
                             of days on which something passed between you — \
                             not by how many things. Forty texts in one \
                             evening is one day.

                             🛑 A count of items cannot be compared across \
                             sources. One email is one record, and a block of \
                             ten texts is also one record. Adding them \
                             together reported a marriage of twenty years as \
                             "9,059 encounters", which is a number of nothing \
                             in particular.

                             Days spent on somebody else's mailing list are \
                             not contact and are counted separately. Calendar \
                             events dated in the future are not contact \
                             either.
                             """)
                meExplanation
                excludedExplanation
                Spacer()
            }
            if stats.excludedCount > 0 {
                let reasons = stats.excludedReasons
                    .map { "\(Format.count($0.1)) \(People.reason($0.0, $0.1))" }
                    .joined(separator: ", ")
                PeopleNote("\(Format.count(stats.excludedCount)) left out: \(reasons).")
            }
        }
    }

    /// 🛑 WHO WAS TREATED AS YOU, and it stays on screen in short form. One
    /// wrong address here deletes a real person from their own graph, and
    /// nothing else in the window would show it.
    ///
    /// ⚠️ THE CERTAIN ONES FIRST. Sorted plainly, the line opened with a bare
    /// phone number, which reads as a mistake rather than as "these are your
    /// mail accounts".
    private var meExplanation: some View {
        let guessed = stats.detectedMe + stats.meByName
        let inferred = Set(guessed)
        let mine = stats.me.filter { $0 != "me" }
            .sorted { a, b in
                let (ai, bi) = (inferred.contains(a), inferred.contains(b))
                if ai != bi { return !ai }
                if a.contains("@") != b.contains("@") { return a.contains("@") }
                return a < b
            }
        var text = "Every handle counted as you, rather than as somebody you "
            + "talk to:\n\n" + mine.joined(separator: "\n")
        if !guessed.isEmpty {
            text += "\n\n⚠️ \(guessed.count) of those were worked out rather "
                + "than read from Mail — an old address that signs itself with "
                + "your name, or the address most of your mail is sent to. "
                + "Those are the ones that can be wrong:\n\n"
                + guessed.sorted().joined(separator: "\n")
                + "\n\nA wrong one here deletes a real person from this "
                + "picture. Correct it with `apple-index people --me <handle>`."
        }
        return ExplainLabel("\(mine.count) handles are you", "You, in this data", text)
    }

    /// 🛑 NAME BOTH ESCAPE HATCHES. A business the rules miss is not a bug to
    /// report; it is one command. Which command depends on whether it has a
    /// contact card at all — Mint ranked 17th here and has none.
    @ViewBuilder
    private var excludedExplanation: some View {
        if stats.excludedCount > 0 {
            ExplainLabel("Businesses left out", "What was left out, and how to change it", """
                         Five rules keep businesses out of a picture of who \
                         you talk to. Every exclusion is reported with its \
                         reason rather than dropped silently, because a rule \
                         that is wrong about somebody removes a real person \
                         and nobody would notice.

                         A business still in the list? If it has a contact \
                         card, tick "Company" on it, or run:
                           apple contacts edit <id> --company-card

                         If it has no card:
                           apple-index people --not-a-person <address>

                         Either one drops it at the next refresh. \
                         `--is-a-person` puts anybody back, and it beats \
                         every rule.
                         """)
        }
    }
}

// MARK: - the web

private struct ContactWeb: View {
    let stats: PeopleStats
    @Environment(\.colorScheme) private var scheme
    @State private var selected: String? = nil
    @AppStorage("webSize") private var size = 46

    // 🛑 THE LAYOUT DOES NOT RE-RUN WHILE IT PLAYS, and that is the whole
    // trick. Re-simulating per frame makes the graph swim about, and a viewer
    // reads that movement as meaning — people "drifting apart" who did nothing
    // of the kind. Only `presence` changes, so a circle appearing really is
    // somebody arriving.
    @State private var throughTime = false
    @State private var playing = false
    @State private var frame = 0
    /// person id -> activity per month, aligned to `axis`.
    @State private var activity: [String: [Int]] = [:]
    @State private var axis: [Date] = []
    @State private var busiest = 1

    /// ⚠️ A ROLLING YEAR, not one month. A month at a time flickers: most
    /// people here have contact in some months of a year and not others, and
    /// the eye reads the gaps as leaving rather than as a quiet fortnight.
    private let windowMonths = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ForEach(Channel.all, id: \.self) { channel in
                    HStack(spacing: 5) {
                        Circle().fill(Channel.color(channel)).frame(width: 8, height: 8)
                        Text(channel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Through time", isOn: $throughTime)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: throughTime) { _, on in
                        if on { frame = max(axis.count - 1, 0) } else { playing = false }
                    }
                Picker("", selection: $size) {
                    Text("30").tag(30)
                    Text("46").tag(46)
                    Text("70").tag(70)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                // 🛑 THE TWO KINDS OF LINE MEAN DIFFERENT THINGS, and nothing
                // about the drawing says so. Reading a shared mailing list as
                // a friendship is the mistake this paragraph exists to stop.
                Explain("How to read this", """
                        You are the circle in the middle. The faint spokes are \
                        yours — everyone drawn here is connected to you by \
                        construction, so a spoke carries no information. Every \
                        other circle is sized by the number of days you were \
                        in contact, and coloured by the channel you use most.

                        ⚠️ A LINE BETWEEN TWO OTHER PEOPLE IS A DIFFERENT \
                        QUESTION. It means they turned up on the same email, \
                        text or invitation. A shared mailing list makes one, \
                        so it is not evidence that they know each other.

                        ⚠️ Those lines are all-time. The index records that \
                        two people shared something, not when — so while \
                        "Through time" plays, the circles are the part that \
                        moves with the year and the lines are not.
                        """)
            }

            if throughTime, axis.count > 1 {
                HStack(spacing: 10) {
                    Button {
                        playing.toggle()
                        // Starting from the end would play one frame and stop.
                        if playing, frame >= axis.count - 1 { frame = 0 }
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Slider(value: Binding(
                        get: { Double(frame) },
                        set: { frame = Int($0.rounded()) }),
                           in: 0...Double(axis.count - 1))
                    Text(caption)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 152, alignment: .trailing)
                }
            }

            ContactWebView(payload: payload) { id in
                selected = (selected == id) ? nil : id
            }
            // ⚠️ Taller than the Canvas version was. Seventy discs that may not
            // overlap need the room, and 380 points packed them into a band.
            .frame(height: 440)
            .background(Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 9))

            if let chosen = stats.people.first(where: { $0.id == selected }) {
                Detail(person: chosen)
            } else if throughTime {
                PeopleNote("Playing a rolling year. A circle grows with how "
                           + "much passed between you in that year and fades "
                           + "to an outline when nothing did.")
            } else {
                PeopleNote("Click a circle for the breakdown. Drag to move it, "
                           + "scroll to zoom, drag the background to pan.")
            }
        }
        .onAppear { buildAxis() }
        .onChange(of: stats.generated) { _, _ in buildAxis() }
        // ⚠️ The timer runs only while it is playing AND the toggle is on, so
        // a window left open does not redraw a chart nobody is watching.
        .onReceive(Timer.publish(every: 0.11, on: .main, in: .common)
                    .autoconnect()) { _ in
            guard playing, throughTime, axis.count > 1 else { return }
            frame += 1
            if frame >= axis.count { frame = 0 }
        }
    }

    // MARK: - what the page is told

    private struct Payload: Encodable {
        struct Node: Encodable {
            let id: String
            let name: String
            let channel: String
            let radius: Double
            let presence: Double
            let rank: Int
        }
        struct Link: Encodable {
            let source: String
            let target: String
            let weight: Double
        }
        let theme: String
        let selected: String?
        let scaled: Bool
        /// 🛑 WHAT MAKES THE PAGE RE-SIMULATE. It changes when the data or the
        /// number of people changes, and at no other time — so moving the time
        /// slider redraws without disturbing a single position.
        let layoutKey: String
        let nodes: [Node]
        let links: [Link]
    }

    private var payload: String {
        let chosen = Array(stats.people.prefix(size))
        let biggest = chosen.map(\.days).max() ?? 1
        let ids = Set(chosen.map(\.id))
        let heaviest = stats.edges.filter { ids.contains($0.a) && ids.contains($0.b) }
            .map(\.weight).max() ?? 1

        let nodes = chosen.enumerated().map { rank, person in
            Payload.Node(
                id: person.id, name: person.name,
                channel: person.dominantChannel,
                radius: 5 + 13 * sqrt(Double(person.days) / Double(biggest)),
                presence: presence(of: person), rank: rank)
        }
        let links = stats.edges
            .filter { ids.contains($0.a) && ids.contains($0.b) }
            .map { edge in
                // A log scale, because an edge here runs from 2 to 2,321.
                // Scaled straight, every real edge pulls at full strength and
                // the graph is one blob.
                Payload.Link(source: edge.a, target: edge.b,
                             weight: 0.08 + 0.92 * log(1 + Double(edge.weight))
                                             / log(1 + Double(heaviest)))
            }
        let body = Payload(
            theme: scheme == .dark ? "dark" : "light",
            selected: selected, scaled: throughTime,
            layoutKey: "\(stats.generated?.timeIntervalSince1970 ?? 0)-\(size)",
            nodes: nodes, links: links)
        guard let data = try? JSONEncoder().encode(body),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// How present this person is right now: 1 all-time, otherwise their share
    /// of the busiest rolling year anybody had.
    private func presence(of person: Person) -> Double {
        guard throughTime, let row = activity[person.id], !row.isEmpty else { return 1 }
        let end = min(frame, row.count - 1)
        let count = row[max(0, end - windowMonths + 1)...end].reduce(0, +)
        if count == 0 { return 0 }
        return min(1, 0.25 + 0.75 * sqrt(Double(count) / Double(busiest)))
    }

    // MARK: - the month axis

    private func buildAxis() {
        // 🛑 UTC, BECAUSE THAT IS WHAT PARSED THE MONTHS. `PeopleReader` reads
        // "2026-08" with a UTC formatter, so a month start is midnight UTC.
        // Stepping from one with `Calendar.current` adds a month in LOCAL
        // time, which lands seven hours off and matches nothing — every
        // lookup missed, every node read as absent, and the whole web played
        // back as empty outlines.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dates = stats.people.flatMap { $0.months.map(\.date) }
        guard let low = dates.min(), let high = dates.max() else { return }
        var months: [Date] = []
        var cursor = low
        while cursor <= high, months.count < 600 {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor)
            else { break }
            cursor = next
        }
        var index: [Date: Int] = [:]
        for (offset, date) in months.enumerated() { index[date] = offset }
        var table: [String: [Int]] = [:]
        for person in stats.people {
            var row = [Int](repeating: 0, count: months.count)
            for month in person.months {
                if let at = index[month.date] { row[at] = month.count }
            }
            table[person.id] = row
        }
        axis = months
        activity = table
        frame = max(months.count - 1, 0)
        // One scale for the whole run. Rescaling per frame makes a quiet year
        // look as busy as a loud one.
        busiest = max(table.values.map { row in
            (0..<row.count).map { end in
                row[max(0, end - windowMonths + 1)...end].reduce(0, +)
            }.max() ?? 0
        }.max() ?? 1, 1)
    }

    private var caption: String {
        guard axis.indices.contains(frame) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let end = axis[frame]
        let start = axis[max(0, frame - windowMonths + 1)]
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

private struct Detail: View {
    let person: Person

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(person.name).font(.body.weight(.medium))
                if !person.known {
                    Text("not in Contacts").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(Format.count(person.days)) days in contact")
                    .font(.caption.weight(.medium)).monospacedDigit()
                Spacer()
                if let first = person.first, let last = person.last {
                    Text("\(Format.year(first)) – \(Format.year(last))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            // 🛑 EVERY FIGURE CARRIES ITS UNIT, and the parenthesis is the one
            // that answers "surely not". For a spouse of twenty years: 2,598
            // emails, of which 1,351 had nobody else on them. Both are true
            // and they answer different questions.
            FlowRow(spacing: 12) {
                ForEach(Channel.all, id: \.self) { channel in
                    if let count = person.channels[channel], count > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: Channel.symbol(channel))
                            Text("\(Format.count(count)) \(Channel.unit(channel, count))")
                                .monospacedDigit()
                            if let alone = person.alone[channel], alone < count {
                                Text("(\(Format.count(alone)) just the two of you)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption).foregroundStyle(Channel.color(channel))
                    }
                }
                if person.upcoming > 0 {
                    // ⚠️ NOT CONTACT. It has not happened yet.
                    Text("\(Format.count(person.upcoming)) still to come")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if person.sameList > 0 {
                    Text("+\(Format.count(person.sameList)) more where somebody "
                         + "else wrote to you both")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - looking one person up

/// 🛑 THE WEB DRAWS A FEW DOZEN PEOPLE; THIS FINDS ANY OF THE FOUR THOUSAND.
/// "Who is this person" is a fair question about somebody in 300th place, and
/// before this the only answer was to re-run the command with a bigger --top.
private struct Lookup: View {
    let stats: PeopleStats
    @Binding var query: String
    @State private var chosen: Person? = nil

    var body: some View {
        Panel("Look someone up", trailing: {
            Explain("Who is in here", """
                    Everyone you have exchanged something with, ranked by days \
                    in contact. The web above draws the busiest few dozen; \
                    everyone else is here.

                    ⚠️ Somebody who only ever appeared beside you on \
                    somebody else's mail is not in this list. Being on the \
                    same mailing list is not contact.

                    Typing a name filters the timeline below as well.
                    """)
        }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("name, email address or phone number",
                          text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""; chosen = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 7))

            if let chosen {
                Detail(person: chosen)
            }

            if query.count >= 2 {
                let hits = matches
                if hits.isEmpty {
                    PeopleNote("Nobody by that name.")
                } else {
                    ForEach(hits.prefix(12)) { person in
                        Button { chosen = person } label: { Row(person: person) }
                            .buttonStyle(.plain)
                    }
                    if hits.count > 12 {
                        PeopleNote("\(hits.count - 12) more. Type a little more.")
                    }
                }
            } else {
                PeopleNote("\(Format.count(stats.directory.count)) people."
                           + (stats.directoryOmitted > 0
                              ? " \(Format.count(stats.directoryOmitted)) more "
                                + "never exchanged anything with you."
                              : ""))
            }
        }
    }

    /// ⚠️ Name AND handle, because half of what a person is called in this data
    /// is an address. Ranked by days, so the busiest match comes first.
    private var matches: [Person] {
        let needle = query.lowercased()
        return stats.directory.filter {
            $0.name.lowercased().contains(needle)
                || $0.handle.lowercased().contains(needle)
        }
    }

    private struct Row: View {
        let person: Person
        var body: some View {
            HStack(spacing: 10) {
                Text(person.name).font(.callout)
                    .lineLimit(1).truncationMode(.middle)
                if !person.known {
                    Text(person.handle).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                ForEach(Channel.all, id: \.self) { channel in
                    if let count = person.channels[channel], count > 0 {
                        Image(systemName: Channel.symbol(channel))
                            .font(.caption2).foregroundStyle(Channel.color(channel))
                    }
                }
                Text("\(Format.count(person.days)) days")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
    }
}

// MARK: - emoji

private struct EmojiPanel: View {
    let report: EmojiReport

    var body: some View {
        Panel("Your emoji", trailing: {
            // 🛑 The rule, out loud. Counting every emoji in the store
            // measures what other people type at you, and the two answers
            // look alike.
            Explain("What is counted", """
                    Only what you sent: texts you wrote, and mail from your \
                    own accounts with the quoted replies stripped out.

                    🛑 Counting every emoji in the index instead would measure \
                    what other people type at you. The two answers look alike \
                    and are not the same question.
                    """)
        }) {
            if report.top.isEmpty {
                PeopleNote("None found in anything you sent.")
            } else {
                let biggest = report.top.first?.count ?? 1
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(report.top.prefix(10)) { entry in
                        VStack(spacing: 4) {
                            Text(entry.emoji).font(.system(size: 34))
                            Text(Format.count(entry.count))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Capsule().fill(.tint.opacity(0.5))
                                .frame(width: 26,
                                       height: 3 + 30 * CGFloat(entry.count) / CGFloat(biggest))
                        }
                    }
                    Spacer()
                }

                if report.top.count > 10 {
                    Divider().opacity(0.3)
                    // The tail, small. It is the long list people scan for one
                    // they had forgotten they use.
                    FlowRow(spacing: 9) {
                        ForEach(report.top.dropFirst(10)) { entry in
                            HStack(spacing: 3) {
                                Text(entry.emoji).font(.system(size: 15))
                                Text("\(entry.count)").font(.caption2)
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }

                if !report.byYear.isEmpty {
                    Divider().opacity(0.3)
                    Text("EMOJI OF THE YEAR").font(.caption2.weight(.semibold))
                        .kerning(0.7).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(report.byYear) { year in
                                VStack(spacing: 2) {
                                    Text(year.emoji).font(.system(size: 21))
                                    Text(year.year).font(.caption2).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 26) {
                    Stat("used", Format.count(report.total))
                    Stat("different ones", Format.count(report.distinct))
                    Stat("in texts", Format.count(report.fromMessages))
                    Stat("in mail", Format.count(report.fromMail))
                    Spacer()
                }
            }
        }
    }
}

/// A wrapping row. `LazyVGrid` cannot do this, because each item here is a
/// different width and a grid gives every column the widest one.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        // 🛑 AN UNSPECIFIED PROPOSAL IS NOT A WIDTH, and neither is an infinite
        // one. Returning `proposal.width` unchecked returned `.infinity` on one
        // of SwiftUI's sizing passes, which made this row infinitely wide — and
        // with it the whole window's content. Every panel then drew past the
        // right edge of the window and was clipped, which read as a chart
        // missing its last ten years.
        let proposed = proposal.width ?? .infinity
        let width = proposed.isFinite ? proposed : 600
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - the journey

private struct Journey: View {
    let stats: PeopleStats
    /// The search box's text. Empty means "the busiest few".
    let query: String
    @AppStorage("journeyRows") private var rows = 24

    var body: some View {
        Panel(filtering ? "People, over time — \u{201c}\(query)\u{201d}"
                        : "People, over time", trailing: {
            // 🛑 THE DATES ARE THE SOURCES' DATES, NOT THE FRIENDSHIP'S. Call
            // history is a four-month mirror of the iPhone, so a friend of
            // thirty years can appear to arrive this spring.
            Explain("How to read this", """
                    One row per person, ordered by when they first appear. A \
                    darker block is a month with more days of contact in it — \
                    31 is the most any month can hold.

                    ⚠️ IT SHOWS WHEN A SOURCE HAS A RECORD, NOT WHEN YOU MET. \
                    Mail here goes back to 2005 and texts to 2012. Call \
                    history is a mirror of the iPhone covering only the last \
                    few months, so somebody you have phoned for thirty years \
                    can look like a new arrival.

                    Type a name in the box above to filter this to one \
                    person, or to everybody who matches.
                    """)
            if !filtering {
                Picker("", selection: $rows) {
                    Text("12").tag(12)
                    Text("24").tag(24)
                    Text("40").tag(40)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
        }) {
            let shown = candidates
                .filter { $0.first != nil }
                .sorted { ($0.first ?? .distantPast) < ($1.first ?? .distantPast) }
            if shown.isEmpty {
                PeopleNote(filtering
                           ? "Nobody by that name has a dated record."
                           : "Not enough dated records yet.")
            } else if shown.count == 1, let only = shown.first {
                // One row is a chart of nothing. Say the numbers instead.
                Detail(person: only)
            } else if let span = span(of: shown) {
                JourneyChart(people: shown, from: span.0, to: span.1)
                    .frame(height: CGFloat(shown.count) * 17 + 26)
                if filtering {
                    PeopleNote("\(shown.count) people matching "
                               + "\u{201c}\(query)\u{201d}. Clear the search box "
                               + "to go back to the busiest few.")
                }
            }
        }
    }

    private var filtering: Bool { query.count >= 2 }

    /// 🛑 THE DIRECTORY WHEN FILTERING, NOT THE DRAWN SET. Both Meyers here
    /// are in the directory and only one is in the top eighty, so filtering
    /// the drawn list would answer "show me both" with one of them.
    private var candidates: [Person] {
        guard filtering else { return Array(stats.people.prefix(rows)) }
        let needle = query.lowercased()
        return Array(stats.directory.filter {
            $0.name.lowercased().contains(needle)
                || $0.handle.lowercased().contains(needle)
        }.prefix(40))
    }

    private func span(of people: [Person]) -> (Date, Date)? {
        guard let low = people.compactMap(\.first).min(),
              let high = people.compactMap(\.last).max() else { return nil }
        return (low, high)
    }
}

private struct JourneyChart: View {
    let people: [Person]
    let from: Date
    let to: Date

    private let gutter: CGFloat = 132
    private let rowHeight: CGFloat = 17

    var body: some View {
        Canvas { context, size in
            let plotLeft = gutter
            let plotWidth = max(size.width - gutter - 8, 10)
            let total = max(to.timeIntervalSince(from), 1)
            func x(_ date: Date) -> CGFloat {
                plotLeft + plotWidth * CGFloat(date.timeIntervalSince(from) / total)
            }

            // Year gridlines first, so every block sits on top of them.
            var year = Calendar.current.component(.year, from: from)
            let lastYear = Calendar.current.component(.year, from: to)
            let step = (lastYear - year) > 14 ? 5 : ((lastYear - year) > 7 ? 2 : 1)
            let bottom = CGFloat(people.count) * rowHeight
            while year <= lastYear {
                if let mark = Calendar.current.date(from: DateComponents(year: year)) {
                    let at = x(mark)
                    if at >= plotLeft {
                        var line = Path()
                        line.move(to: CGPoint(x: at, y: 0))
                        line.addLine(to: CGPoint(x: at, y: bottom))
                        context.stroke(line, with: .color(.primary.opacity(0.07)),
                                       lineWidth: 1)
                        context.draw(context.resolve(
                            Text(String(year)).font(.system(size: 9))
                                .foregroundStyle(.secondary)),
                                     at: CGPoint(x: at, y: bottom + 10))
                    }
                }
                year += step
            }

            for (row, person) in people.enumerated() {
                let middle = CGFloat(row) * rowHeight + rowHeight / 2
                // ⚠️ TRIMMED TO THE GUTTER. A long one ran off the left edge
                // of the panel and "Entire NorthCreek Neighborhood" was drawn
                // as "orthCreek Neighborhood".
                context.draw(context.resolve(
                    Text(Self.fit(person.name)).font(.system(size: 10))
                        .foregroundStyle(.primary)),
                             at: CGPoint(x: gutter - 8, y: middle), anchor: .trailing)

                // The track: from first sighting to last, faint. It is what
                // makes a gap in the middle legible as a gap.
                if let first = person.first, let last = person.last {
                    let track = Path(roundedRect: CGRect(x: x(first), y: middle - 1.5,
                                                         width: max(x(last) - x(first), 2),
                                                         height: 3),
                                     cornerRadius: 1.5)
                    context.fill(track,
                                 with: .color(Channel.color(person.dominantChannel)
                                                .opacity(0.18)))
                }

                let busiest = person.months.map(\.count).max() ?? 1
                let width = max(plotWidth / CGFloat(max(monthsAcross, 1)), 1.4)
                for month in person.months {
                    let heat = 0.22 + 0.78 * log(1 + Double(month.count))
                                / log(1 + Double(busiest))
                    let block = CGRect(x: x(month.date), y: middle - 5.5,
                                       width: width, height: 11)
                    context.fill(Path(roundedRect: block, cornerRadius: 1),
                                 with: .color(Channel.color(person.dominantChannel)
                                                .opacity(heat)))
                }
            }
        }
    }

    /// The name gutter holds about 24 characters at 10 points.
    private static func fit(_ name: String) -> String {
        name.count <= 24 ? name : String(name.prefix(23)) + "\u{2026}"
    }

    /// How many months the axis covers, so one month's block is one month wide.
    private var monthsAcross: Int {
        max(Calendar.current.dateComponents([.month], from: from, to: to).month ?? 1, 1)
    }
}

// MARK: - small pieces

/// ⚠️ A copy of the `Note` in `StatusView`, which is `private` to that file.
/// Two eight-line views beat making a shared one public and having every
/// caller reach for it.
private struct PeopleNote: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
