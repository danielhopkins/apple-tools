// Starting at login, so the index does not go stale while the app is closed.
//
// 🛑 `SMAppService.mainApp`, NOT a launchd plist. The app already unloaded and
// disabled `com.boulderhopkins.apple-index`, and adding a second plist of our
// own would put the machine back where it started: two things that both want
// the socket, kept in sync by hand.
//
// ⚠️ Registering opens no dialog and asks nothing. The user sees the app in
// System Settings → General → Login Items, and can turn it off there. A
// `.requiresApproval` status means they did exactly that, and the app must not
// keep re-registering over their decision.

import Foundation
import ServiceManagement

@MainActor
final class LoginItem: ObservableObject {
    enum State: String {
        case enabled          // registered, and macOS will launch it
        case disabled         // not registered
        case needsApproval    // the user switched it off in System Settings
        case unavailable      // SMAppService refused, and said why
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var failure: String? = nil

    private var service: SMAppService { .mainApp }

    func read() {
        readStatus()
        write()
    }

    /// 🛑 The app writes this down, because nothing outside it can ask.
    /// `sfltool dumpbtm` lists a registration only after it succeeds, so a
    /// registration that THREW leaves no trace anywhere on the system.
    private func write() {
        let body: [String: Any] = [
            "checked": ISO8601DateFormatter().string(from: Date()),
            "state": state.rawValue,
            "bundle_path": Bundle.main.bundlePath,
            "failure": failure ?? "",
        ]
        let path = Paths.supportDirectory
            .appendingPathComponent("app-login-item.json")
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: path, options: .atomic)
    }

    private func readStatus() {
        switch service.status {
        case .enabled: state = .enabled
        case .notRegistered: state = .disabled
        case .requiresApproval: state = .needsApproval
        case .notFound: state = .unavailable
        @unknown default: state = .unavailable
        }
    }

    /// ⚠️ Registering an app that is not in `/Applications` fails. A build run
    /// straight out of `build/` is exactly that case, and the error says so
    /// rather than leaving the toggle looking broken.
    func set(_ wanted: Bool) {
        failure = nil
        do {
            if wanted {
                guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                    failure = "Move the app to /Applications first. macOS will "
                        + "not start a login item from \(Bundle.main.bundlePath)."
                    read()
                    return
                }
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failure = "\(error.localizedDescription)"
        }
        read()
    }

    /// Turn it on once, the first time the app runs from `/Applications`.
    ///
    /// ⚠️ ONCE. `requiresApproval` means the user turned it off by hand, and
    /// re-registering every launch would overrule them silently.
    func enableOnFirstRun() {
        readStatus()
        let key = "loginItemOffered"
        // ⚠️ `.unavailable` too, not just `.disabled`. `SMAppService.mainApp`
        // reports `.notFound` before it has ever been registered on some
        // systems, which is indistinguishable from a real refusal until you
        // try. Guarding on `.disabled` alone meant the first run never called
        // `register()` at all, and nothing said so.
        guard state == .disabled || state == .unavailable,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
