// The window's frame: a rail on the left, one pane at a time on the right.
//
// 🛑 PANELS BECAME A RAIL IN 26.828, AND THE REASON IS NOT DECORATION. The
// window was seven stacked boxes in one scroll view — permissions, sources,
// growth, storage, advanced, people, places — and every one of them was on
// screen whether or not it was the thing being asked about. Two costs came out
// of that:
//
//   1. Expanding one source row pushed the four sections below it off the
//      bottom, which reads as the rest of the window disappearing.
//   2. The map and the contact web are the two most expensive things here, and
//      they were built on a window opened to check whether mail indexed.
//
// A rail fixes both by construction. One pane is on screen, so nothing below
// it can be displaced, and a pane nobody selects is never built.
//
// ⚠️ ONE QUESTION PER PANE, and the order is the order a person asks them:
//
//   Sources      can it read my data, and what did it read
//   Index size   how is it growing, what does it cost, what can I delete
//   Advanced     the search endpoint and the proxy switch
//   ---
//   Relationships / Places / Emoji    who and where is in all this
//
// 🛑 THE SECOND GROUP IS NOT A DIAGNOSTIC, and the divider says so. Nothing in
// the first group depends on it, each costs seconds of subprocess to build,
// and each is fetched only when its pane is opened.

import SwiftUI

/// 🛑 `String`-backed, because `@AppStorage` stores it directly. Changing a
/// case's raw value orphans whatever a person had selected.
enum Pane: String, CaseIterable, Identifiable {
    case sources, size, advanced, people, places, emoji

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources:  return "Sources"
        case .size:     return "Index size"
        case .advanced: return "Advanced"
        case .people:   return "Your relationships"
        case .places:   return "Your places"
        case .emoji:    return "Your emoji"
        }
    }

    /// ⚠️ The second group is drawn under a STATISTICS heading, because a
    /// reader who takes "Your places" for a diagnostic reads a missing map as
    /// a fault rather than as a library with no located photos in it.
    var isStatistic: Bool {
        switch self {
        case .people, .places, .emoji: return true
        default: return false
        }
    }

    static let diagnostics: [Pane] = [.sources, .size, .advanced]
    static let statistics: [Pane] = [.people, .places, .emoji]
}

struct StatusView: View {
    @ObservedObject var model: AppModel
    // 🛑 `AppStorage`, NOT `SceneStorage`. This is an LSUIElement app whose one
    // window is closed far more often than the app is quit — and re-opening it
    // onto Sources every time is what makes a rail feel worse than a scroll
    // view. Scene storage rides the window's restoration state, which macOS
    // drops whenever the app is replaced; a defaults key survives an upgrade.
    // 🛑 THE STORAGE IS THE SELECTION. `@AppStorage` takes a
    // `RawRepresentable` whose `RawValue` is `String`, which `Pane` already is,
    // so the List binds straight to it.
    //
    // ⚠️ IT USED TO BE A `String` KEY WITH A HAND-BUILT `Binding<Pane?>` OVER
    // IT, rebuilt on every pass of `body`. A `List` holds the binding it was
    // given and writes through it on a click; handing it a fresh closure pair
    // each pass is the kind of thing that works until it does not, and it was
    // one of two suspects for a sidebar that would not respond to the mouse.
    // There is no reason to have the indirection, so it is gone.
    @AppStorage("pane") private var pane: Pane = .sources
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Rail(model: model, selection: $pane)
                .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 260)
        } detail: {
            Detail(model: model, pane: pane)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { model.reread(); model.folders.read() }
    }
}

// MARK: - the rail

private struct Rail: View {
    @ObservedObject var model: AppModel
    /// ⚠️ NOT OPTIONAL. A sidebar `List` whose selection can be nil has a
    /// "nothing selected" state, and this window has no such state — closing
    /// the last pane would leave the detail column empty with no way back.
    @Binding var selection: Pane

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(Pane.diagnostics) { pane in
                    Row(pane: pane, dot: dot(for: pane)).tag(pane)
                }
            } header: {
                // 🛑 THE VERSION, IN THE RAIL. A stale build was diagnosed as
                // a code bug for an hour because nothing on screen said which
                // build was running. It sits here rather than in the header
                // because the header changes with the pane and this does not.
                VStack(alignment: .leading, spacing: 2) {
                    Text("AppleTools").font(.headline)
                    // ⚠️ THE ONE SELECTABLE THING IN THE RAIL, and it is safe
                    // here because a section header is not a selectable row.
                    // Nothing else in this column may have it: see `Detail`.
                    Text(model.appVersion)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(.bottom, 8)
                .textCase(nil)
            }

            Section("Statistics") {
                ForEach(Pane.statistics) { pane in
                    Row(pane: pane, dot: .secondary).tag(pane)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// Amber the moment a source cannot be read, so the rail says which pane
    /// to open without the pane being open. ⚠️ Only `Sources` can be amber:
    /// nothing else on this window has a state that needs attention.
    private func dot(for pane: Pane) -> Color {
        switch pane {
        case .sources:
            let diagnosis = model.diagnostics.latest
            if !diagnosis.appHasFullDiskAccess { return .orange }
            return diagnosis.blocked.isEmpty ? .green : .orange
        case .size:     return .green
        case .advanced: return .secondary
        default:        return .secondary
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            // ⚠️ THE LAST COMPLETED RUN, not the current phase. The header
            // shows what is happening now; this says when it last finished,
            // and the two differ for exactly the minute anyone is watching.
            Text(model.indexer.lastCycleFinished.map { "Indexed \(Format.ago($0))" }
                 ?? "Not indexed yet")
                .font(.caption).foregroundStyle(.secondary)
            Button(model.indexer.isRunning ? "Indexing…" : "Refresh Now") {
                model.indexer.refresh()
            }
            .disabled(model.indexer.isRunning)
            .frame(maxWidth: .infinity)
            Toggle("Automatic", isOn: Binding(
                get: { model.indexer.automatic },
                set: { model.indexer.automatic = $0; model.indexer.saveState() }))
            Toggle("Start at Login", isOn: Binding(
                get: { model.loginItem.state == .enabled },
                set: { model.loginItem.set($0) }))
            if let failure = model.loginItem.failure {
                Text(failure).font(.caption2).foregroundStyle(.red)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private struct Row: View {
        let pane: Pane
        let dot: Color

        var body: some View {
            HStack(spacing: 9) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(pane.title)
            }
        }
    }
}

// MARK: - the pane

private struct Detail: View {
    @ObservedObject var model: AppModel
    let pane: Pane

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PaneHeader(model: model)
                // 🛑 ABOVE EVERY PANE, not only Sources. With no Full Disk
                // Access nothing on any pane is true, and a person who opened
                // the window on Places would otherwise be shown an empty map
                // and no reason for it.
                if !model.diagnostics.latest.appHasFullDiskAccess { Onboarding() }
                body(for: pane)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // 🛑 ON THE PANE, NEVER ON THE WINDOW. Half of what is written here is
        // meant to be copied — a path, an address, a command, an error — and
        // `textSelection` travels down the environment, so one line covers
        // every `Text` below rather than the handful somebody remembered to
        // mark.
        //
        // 🛑 IT MUST NOT REACH THE RAIL, AND THAT COST A RELEASE. Applied to
        // the whole `NavigationSplitView` it reaches the sidebar `List` too,
        // and a selectable `Text` CONSUMES THE MOUSE EVENT before the row
        // under it sees one. Every rail row is a dot and a label, so the label
        // is most of the row: clicking a pane did nothing at all. It looked
        // like a broken sidebar, not like text selection.
        //
        // ⚠️ NOTHING ON SCREEN DISTINGUISHED THE TWO, and every check missed
        // it: the panes were set through a defaults key and read back in
        // screenshots, so no mouse ever went near a row. Accessibility's
        // `select row` sets the selection directly and worked perfectly, which
        // is what made the sidebar look innocent.
        //
        // ⚠️ It does not reach the contact web either. That is a `WKWebView`
        // drawing SVG, and its text is not text.
        .textSelection(.enabled)
        .navigationTitle(pane.title)
        // 🛑 THE FETCH BELONGS TO THE PANE, NOT TO A VIEW INSIDE IT. Each
        // statistics pane used to ask for its own data from `.onAppear` on its
        // root view — and that view is a branch of the `switch` below, inside a
        // `ScrollView`. Selecting the pane at RUNTIME never fired it, so all
        // three sat on "Reading it…" for ever while the three diagnostic panes
        // worked perfectly: those read data the model already holds and ask for
        // nothing.
        //
        // ⚠️ IT WAS INVISIBLE IN TESTING because every check set the pane and
        // RELAUNCHED, which builds the branch at first layout, where `onAppear`
        // does fire. Switching panes in a running window is the one path that
        // was never exercised.
        //
        // `.task(id:)` runs on first appearance AND on every change of `pane`,
        // which is exactly the rule: whoever opens a pane asks for its data.
        .task(id: pane) {
            switch pane {
            case .people, .emoji: model.refreshPeople()
            case .places:         model.refreshPlaces()
            case .sources, .size, .advanced: break
            }
        }
    }

    @ViewBuilder
    private func body(for pane: Pane) -> some View {
        switch pane {
        case .sources:  Sources(model: model)
        case .size:     IndexSize(model: model)
        case .advanced: Advanced(model: model)
        case .people:   People(model: model)
        case .places:   Places(model: model)
        case .emoji:    Emoji(model: model)
        }
    }
}

/// What is happening right now, and whether anything needs attention. ⚠️ The
/// same on every pane, deliberately: it is the one fact that outranks whatever
/// the person came to look at.
private struct PaneHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.system(size: 19, weight: .medium))
                        .foregroundStyle(model.indexer.lastCycleError == nil
                                         ? Color.primary : Color.red)
                    Text("every 5 minutes, on wake, on unlock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(model: model)
            }
            if let failure = model.indexer.lastCycleError {
                // ⚠️ THREE LINES, AND THE WHOLE THING ON HOVER. One stuck
                // lock fails every source in the cycle, so this string is the
                // same sentence ten times over — 400 words of red that push
                // the pane itself off the screen. The text is still
                // selectable, so the full message can be copied.
                Text(failure).font(.caption).foregroundStyle(.red)
                    .lineLimit(3).help(failure)
            }
            // The hairline the design uses instead of a box: accent at the
            // leading edge, fading out before the trailing one.
            // ⚠️ `separatorColor`, NOT `primary.opacity(...)`. At the opacity
            // that looks right in dark mode the flat part of this line is
            // invisible on a light window, so the rule read as a stray blue
            // dash rather than as a rule.
            LinearGradient(stops: [
                .init(color: .accentColor, location: 0),
                .init(color: Color(nsColor: .separatorColor), location: 0.05),
                .init(color: Color(nsColor: .separatorColor), location: 0.9),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
        }
    }

    private var headline: String {
        switch model.indexer.phase {
        case .ingesting(let source): return "Reading \(source)…"
        case .embedding:             return "Embedding new chunks…"
        case .reloading:             return "Reloading the search endpoint…"
        case .idle:
            guard let when = model.indexer.lastCycleFinished else {
                return "Not indexed yet"
            }
            return "Last indexed \(Format.ago(when))"
        }
    }
}

private struct StatusPill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let ok = model.healthy
        HStack(spacing: 7) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(ok ? "Healthy" : "Needs attention").font(.callout)
        }
    }
}

// MARK: - a section inside a pane

/// 🛑 A HEADING AND A HAIRLINE, NOT A BOX. Seven tinted rounded rectangles on
/// one window made every section look like a callout, which is how a window
/// teaches people to skip the one section that really is a callout. A pane
/// holds one or two of these, and the rail already says where you are.
struct PaneSection<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .kerning(0.9)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                trailing
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
