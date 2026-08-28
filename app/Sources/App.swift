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
    let loginItem = LoginItem()
    let vault = Vault()
    let toolProxy = ToolProxy()
    /// ⚠️ Read when the window opens, and after every edit. Not on the
    /// ticker: it spawns python, and the answer changes only when a person
    /// presses a button.
    let folders = Folders()

    @Published private(set) var facts = IndexFacts()
    @Published private(set) var stats = IndexStats()
    private var statsRefreshed = Date.distantPast
    /// The social picture, on its own schedule. ⚠️ NOT part of `reread()`: it
    /// costs three seconds of subprocess and answers nothing the app needs in
    /// order to index or to search.
    @Published private(set) var people = PeopleStats()
    @Published private(set) var places = PlacesStats()
    private var placesBusy = false
    private var placesRefreshed = Date.distantPast
    @Published private(set) var peopleBusy = false
    private var peopleRefreshed = Date.distantPast

    /// 🛑 The RUNNING build, from the bundle. A stale build was diagnosed as a
    /// code bug for an hour because nothing on screen said which one it was.
    var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        return (short as? String) ?? "?"
    }
    private var ticker: Timer?
    @Published private(set) var vaultProgress: String? = nil
    @Published private(set) var vaultFailure: String? = nil

    func start() {
        // 🛑 READ, DO NOT ASK. The index does not need the app to hold Calendar,
        // Reminders or Contacts: `apple-calendar`, `reminders` and
        // `apple-contacts` disclaim, so each one carries its own grant, and
        // those grants already work. Asking cost a stuck `denied` record for
        // Contacts and a minute of stolen focus per launch, for nothing.
        // The window keeps an "Ask Again" button for a person who wants it.
        // ⚠️ Ask once, and only for what is still undetermined. It is cheap now
        // that the entitlements make the grants obtainable; before them every
        // request cost its full deadline and stole focus for nothing.
        grants.requestAndRead()
        // The index goes stale whenever the app is not running, so starting at
        // login is not a convenience. It is what makes the schedule mean
        // anything.
        loginItem.enableOnFirstRun()
        // 🛑 THE VAULT COMES BEFORE EVERYTHING THAT READS THE INDEX. The
        // database path moves when the vault mounts, and `vec daemon` is given
        // that path once, at launch. Starting it first points it at a
        // plaintext file that is about to be deleted.
        openVault { [weak self] in
            guard let self else { return }
            self.search.start()
            self.indexer.startScheduling()
            self.diagnostics.check()
            // 🛑 OFF unless the user turned it on. See ToolProxy.swift.
            self.toolProxy.apply()
            self.reread()
            self.beginTicking()
        }
    }

    /// Mount the encrypted index, moving a plaintext one in the first time.
    ///
    /// ⚠️ OFF THE MAIN THREAD. The move copies 812 MB on this machine, and a
    /// spinning menu bar is not the same thing as a hung one.
    private func openVault(then ready: @escaping () -> Void) {
        vault.read()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if FileManager.default.fileExists(atPath: Vault.image.path),
                   !(try Vault.mountedNow()) {
                    try Vault.mount()
                }
                _ = try Vault.migrateIfNeeded { line in
                    Task { @MainActor in self.vaultProgress = line }
                }
            } catch {
                // 🛑 Write it down. This runs before any window exists, so a
                // failure that lives only in a @Published property is a failure
                // nobody can read.
                let note = "\(Date()): \(error)\n"
                let path = Paths.logDirectory.appendingPathComponent("vault.log")
                if let handle = try? FileHandle(forWritingTo: path) {
                    handle.seekToEndOfFile()
                    handle.write(note.data(using: .utf8)!)
                    try? handle.close()
                } else {
                    try? note.write(to: path, atomically: true, encoding: .utf8)
                }
                Task { @MainActor in self.vaultFailure = "\(error)" }
            }
            Task { @MainActor in
                self.vault.read()
                self.vaultProgress = nil
                ready()
            }
        }
    }

    private func beginTicking() {
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
        // ⚠️ THROTTLED, because `stats` spawns python. The ticker runs every
        // two seconds; thirty python starts a minute to redraw a chart that
        // changes every five minutes is not a trade worth making.
        if Date().timeIntervalSince(statsRefreshed) > 30 { refreshStats() }
        search.refreshPing()
        grants.read()
        loginItem.read()
        toolProxy.readActivity()
    }

    /// Delete the index, its key, and the encrypted image.
    ///
    /// 🛑 THIS IS THE REVOCATION PATH `lab/SECURITY.md` ASKS FOR, and the key
    /// is what makes it real. Deleting an 812 MB plaintext file leaves it in
    /// every backup; deleting the key makes every one of those copies inert.
    /// So the key goes first, and it goes even if the rest fails.
    func forgetIndex() {
        indexer.automatic = false
        indexer.saveState()
        search.stop()
        Vault.destroyKey()
        Vault.unmount()
        for target in [Vault.image, Paths.plainDatabase,
                       URL(fileURLWithPath: Paths.plainDatabase.path + "-wal"),
                       URL(fileURLWithPath: Paths.plainDatabase.path + "-shm")] {
            try? FileManager.default.removeItem(at: target)
        }
        vault.read()
        reread()
    }

    /// Read the whole picture in one subprocess, off the main thread.
    func refreshStats() {
        statsRefreshed = Date()
        Task.detached(priority: .utility) {
            let fresh = StatsReader.read()
            await MainActor.run { if fresh.loaded || fresh.error != nil { self.stats = fresh } }
        }
    }

    /// Who you talk to, who overlaps with whom, and which emoji you use.
    ///
    /// ⚠️ IT READS A STORED REPORT. `index.py` computes it after an indexing
    /// cycle once a day and hands back the stored copy otherwise, so opening
    /// the window costs 80 ms rather than 3.6 s. `force` is the Recalculate
    /// button, and it is the only thing here that pays the full price.
    func refreshPeople(force: Bool = false) {
        guard !peopleBusy else { return }
        guard force || Date().timeIntervalSince(peopleRefreshed) > 60
                || !people.loaded else { return }
        peopleRefreshed = Date()
        peopleBusy = true
        Task.detached(priority: .utility) {
            let fresh = PeopleReader.read(refresh: force)
            await MainActor.run {
                self.peopleBusy = false
                if fresh.loaded || fresh.error != nil { self.people = fresh }
            }
        }
    }

    /// Everywhere you have been. ⚠️ Cheaper than `people` — it reads the
    /// index rather than every body — but it is still a subprocess, so it runs
    /// when the panel appears and not on the thirty-second timer.
    func refreshPlaces(force: Bool = false) {
        guard !placesBusy else { return }
        guard force || Date().timeIntervalSince(placesRefreshed) > 60
                || !places.loaded else { return }
        placesRefreshed = Date()
        placesBusy = true
        Task.detached(priority: .utility) {
            let fresh = PlacesReader.read()
            await MainActor.run {
                self.placesBusy = false
                if fresh.loaded || fresh.error != nil { self.places = fresh }
            }
        }
    }

    func quit() {
        indexer.saveState()
        search.stop()
        // ⚠️ Unmount AFTER the daemon is down. Detaching a volume a process
        // still holds a file on fails, and the index would stay readable by
        // anything on the machine until the next reboot.
        toolProxy.stop()
        Vault.unmount()
        // ⚠️ Compaction needs the image detached, so it belongs here and
        // nowhere else. It is best effort: a slow one must not hold a quit.
        DispatchQueue.global(qos: .utility).async { Vault.compact() }
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

/// Whether the app shows a Dock tile, which follows whether a window is open.
///
/// 🛑 `LSUIElement` IS AN INITIAL POLICY, NOT A LIFE SENTENCE. A background
/// indexer with a permanent Dock tile is noise, which is why the app is an
/// accessory — but a visible window belonging to an accessory app cannot be
/// switched back to. It is absent from the Dock, absent from ⌘-Tab, and once
/// another window covers it the only way back is the menu bar item. Raising
/// the policy while a window is open gives it a tile, a ⌘-Tab entry and a menu
/// bar, and lowering it again afterwards keeps the app out of the way.
@MainActor
enum DockPresence {
    /// ⚠️ COUNTED FROM THE WINDOWS THEMSELVES, never from a flag toggled on
    /// open and close. A flag drifts the first time a window closes by a route
    /// nobody thought of, and the app is then either stuck in the Dock or
    /// unreachable behind another window.
    static func follow() {
        let visible = NSApp.windows.contains {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
        }
        let wanted: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    /// ⚠️ ONE RUNLOOP LATER, ALWAYS. Both edges need it, for opposite reasons:
    /// `willCloseNotification` fires while the window is still in
    /// `NSApp.windows`, so counting there finds it and the tile never leaves;
    /// and SwiftUI runs a scene's `onAppear` before the window is on screen,
    /// so counting there finds nothing and the tile never arrives. Measured:
    /// the first version called this directly from `onAppear` and the app
    /// stayed background-only with its window wide open.
    static func followSoon() {
        DispatchQueue.main.async { follow() }
    }
}

/// Starting the work does not wait for a window. ⚠️ In an LSUIElement app the
/// user may never open one, and both jobs still have to run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.start() }
        for edge in [NSWindow.willCloseNotification,
                     NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(
                forName: edge, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { DockPresence.followSoon() }
                }
        }
    }


    func applicationWillTerminate(_ notification: Notification) {
        // Take the search endpoint down with the app. Leaving it bound to the
        // socket after a quit is how two daemons end up racing it.
        MainActor.assumeIsolated {
            AppModel.shared.indexer.saveState()
            AppModel.shared.search.stop()
            AppModel.shared.toolProxy.stop()
            Vault.unmount()
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
                // 🛑 THE LABEL, NOT THE MENU CONTENT. A MenuBarExtra's content
                // is not built until someone opens the menu, and an accessory
                // app never receives `applicationDidBecomeActive`, so neither
                // could open a window on first launch. The label is built at
                // launch, and `openWindow` is available to it.
                .onAppear {
                    let key = "hasShownWindow"
                    guard !UserDefaults.standard.bool(forKey: key) else { return }
                    UserDefaults.standard.set(true, forKey: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "status")
                    }
                }
        }

        Window("Index", id: "status") {
            StatusView(model: model)
                .frame(minWidth: 720, minHeight: 560)
                .onAppear { DockPresence.followSoon() }
        }
        .defaultSize(width: 860, height: 760)
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

    /// ⚠️ `.file` counts in the same units the Finder does, so the number here
    /// matches what the user sees in Get Info rather than being 7% smaller.
    static func bytes(_ value: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(value))
    }

    static func year(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }

    /// "Sep 2021". ⚠️ The formatter is built per call, which is wasteful, and
    /// the alternative — a `static let` — is what the rest of this enum does.
    /// It is called a few dozen times on one pane, so the waste is invisible
    /// and the locality is worth more.
    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    /// A span in days, said the way a person says it. ⚠️ "409 days" is a
    /// number nobody converts in their head; "13 months" is the answer.
    static func months(_ days: Int) -> String {
        if days < 0 { return "before it was published" }
        if days < 45 { return days == 1 ? "1 day" : "\(days) days" }
        let count = Int((Double(days) / 30.44).rounded())
        if count < 24 { return count == 1 ? "1 month" : "\(count) months" }
        let years = Double(days) / 365.25
        return String(format: "%.1f years", years)
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
