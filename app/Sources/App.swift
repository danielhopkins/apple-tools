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

    @Published private(set) var facts = IndexFacts()
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
        search.refreshPing()
        grants.read()
        loginItem.read()
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

    func quit() {
        indexer.saveState()
        search.stop()
        // ⚠️ Unmount AFTER the daemon is down. Detaching a volume a process
        // still holds a file on fails, and the index would stay readable by
        // anything on the machine until the next reboot.
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
