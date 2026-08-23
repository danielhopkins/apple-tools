// The app: a menu bar item, one window, and two jobs.
//
//   1. It indexes on a schedule, because it holds Full Disk Access and a
//      launchd agent does not.
//   2. It owns the search endpoint, so `apple-index search` answers whether or
//      not anyone has opened a terminal.
//
// LSUIElement, so there is no Dock icon. A background indexer with a Dock tile
// is noise.

import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    // 🛑 A singleton, and deliberately. In an LSUIElement app the window and
    // the menu may never be built, so a @StateObject on the App struct is not
    // guaranteed to exist — and the two jobs must start whether or not anyone
    // opens anything.
    static let shared = AppModel()

    let indexer = Indexer()
    let search = SearchService()
    let diagnostics = Diagnostics()
    let grants = Grants()

    @Published private(set) var facts = IndexFacts()
    private var ticker: Timer?

    func start() {
        // 🛑 Ask FIRST, before anything spawns a tool. A child asking instead
        // gets the same dialog attributed to the app, but only when the state
        // is `notDetermined` — and a background child that is denied leaves the
        // state at `denied`, which asking again can never undo.
        grants.requestAndRead()
        search.start()
        indexer.startScheduling()
        diagnostics.check()
        reread()
        // One second while a cycle runs, ten while it does not. The window is
        // the only reader and it is usually closed.
        ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reread() }
        }
        // ⚠️ Give the endpoint a moment to bind before asking it anything. A
        // ping straight after launch races the bind and reports it dead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.search.refreshPing()
        }
        // Index once at launch, so opening the app is itself a refresh.
        if indexer.automatic {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.indexer.refresh()
            }
        }
    }

    func reread() {
        facts = IndexReader.read()
        search.refreshPing()
        grants.read()
    }

    func quit() {
        indexer.saveState()
        search.stop()
        NSApp.terminate(nil)
    }

    /// A one line answer for the menu bar.
    var glance: String {
        switch indexer.phase {
        case .ingesting(let source): return "indexing \(source)…"
        case .embedding: return "embedding…"
        case .reloading: return "reloading…"
        case .idle: break
        }
        if case .failed = search.state { return "search endpoint down" }
        if facts.backlog > 0 { return "\(facts.backlog) chunks to embed" }
        guard let when = indexer.lastCycleFinished else { return "not indexed yet" }
        return "indexed " + Format.ago(when)
    }

    var healthy: Bool {
        if case .running = search.state {} else { return false }
        if !grants.entries.allSatisfy(\.settled) { return false }
        return indexer.lastCycleError == nil && diagnostics.latest.blocked.isEmpty
    }
}

/// Starting the work does not wait for a window. ⚠️ In an LSUIElement app the
/// user may never open one, and both jobs still have to run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Take the search endpoint down with the app. Leaving it bound to the
        // socket after a quit is how two daemons end up racing it.
        MainActor.assumeIsolated {
            AppModel.shared.indexer.saveState()
            AppModel.shared.search.stop()
        }
    }
}

@main
struct AppleToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // ⚠️ A template image, so it follows the menu bar in both themes.
            Image(systemName: model.healthy
                  ? "magnifyingglass.circle" : "magnifyingglass.circle.fill")
        }

        Window("Index", id: "status") {
            StatusView(model: model)
                .frame(minWidth: 620, minHeight: 520)
        }
        .defaultSize(width: 700, height: 640)
        .windowResizability(.contentSize)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.glance)
        Divider()
        Button("Open Index…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "status")
        }
        Button(model.indexer.isRunning ? "Indexing…" : "Refresh Now") {
            model.indexer.refresh()
        }
        .disabled(model.indexer.isRunning)
        Toggle("Index Automatically", isOn: Binding(
            get: { model.indexer.automatic },
            set: { model.indexer.automatic = $0; model.indexer.saveState() }))
        Divider()
        Button("Quit") { model.quit() }
    }
}

enum Format {
    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
