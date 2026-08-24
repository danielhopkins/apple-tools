// Where everything lives, and how the app finds it.
//
// Three layouts have to work, and they are found in this order:
//
//   1. inside the bundle      Contents/Resources/index/   (the shipping build)
//   2. a Homebrew install     /opt/homebrew/opt/apple-tools/libexec/index/
//   3. a checkout             <repo>/lab/                 (development)
//
// ⚠️ Nothing here guesses a repo path. Development points at a checkout through
// a defaults key, because a guessed path that happens to exist on one machine
// is the kind of thing that ships and then fails silently on another.

import Foundation

enum Paths {
    /// `~/Library/Application Support/apple-tools`
    ///
    /// 🛑 The same directory `lab/` already uses, on purpose. Moving the index
    /// into a container is phase 4 of the design doc and it is a migration, not
    /// a path change: `apple-index` on the user's PATH reads this one.
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("apple-tools", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return base
    }()

    /// The index, wherever it currently lives.
    ///
    /// 🛑 COMPUTED, NOT A CONSTANT. It moves into the encrypted vault, and
    /// every caller must follow it. A cached copy sends `vec daemon` at the old
    /// plaintext file, which then answers searches out of a stale index that
    /// nobody is updating any more.
    static var database: URL {
        let inVault = Vault.databaseInVault
        if FileManager.default.fileExists(atPath: inVault.path) { return inVault }
        return plainDatabase
    }

    /// The unencrypted location, which is where `lab/` has always put it.
    static let plainDatabase = supportDirectory
        .appendingPathComponent("lab-index.db")
    /// 🛑 The socket stays OUTSIDE the vault. It is a rendezvous point, not
    /// data, and putting it on a volume that unmounts would break every client
    /// the moment the app quit.
    static let socket = supportDirectory.appendingPathComponent("index.sock")
    static let logDirectory: URL = {
        let dir = supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// An override for a development checkout, read once at launch:
    ///
    ///     defaults write com.boulderhopkins.apple-tools toolsRoot ~/src/apple-tools/lab
    ///
    /// It must hold `index.py` and `vec` (or `vec/.build/release/vec`).
    private static var override: URL? {
        UserDefaults.standard.string(forKey: "toolsRoot").map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The directory holding `index.py`, `vec` and `models/`.
    static let toolsRoot: URL? = {
        var candidates: [URL] = []
        if let explicit = override { candidates.append(explicit) }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("index", isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath:
            "/opt/homebrew/opt/apple-tools/libexec/index"))
        candidates.append(URL(fileURLWithPath:
            "/usr/local/opt/apple-tools/libexec/index"))
        return candidates.first { exists($0.appendingPathComponent("index.py")) }
    }()

    static var indexScript: URL? { toolsRoot?.appendingPathComponent("index.py") }

    /// The Core ML embedder and search daemon.
    ///
    /// ⚠️ A checkout builds it into `vec/.build/release/vec`; an install puts it
    /// beside `index.py`. Both are checked, install first.
    static var vec: URL? {
        guard let root = toolsRoot else { return nil }
        let installed = root.appendingPathComponent("vec")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: installed.path, isDirectory: &isDirectory),
           !isDirectory.boolValue { return installed }
        let built = root.appendingPathComponent("vec/.build/release/vec")
        return exists(built) ? built : nil
    }

    /// The Core ML packages. `vec` walks up looking for these; the app tells it
    /// instead, through `VEC_COREML_DIR`, so a bundle layout needs no walking.
    static var modelsDirectory: URL? {
        guard let root = toolsRoot else { return nil }
        for candidate in ["models", "coreml/build"] {
            let url = root.appendingPathComponent(candidate)
            if exists(url.appendingPathComponent("vocab.txt")) { return url }
            if exists(url) { return url }
        }
        return nil
    }

    /// The directory holding the `apple` dispatcher and the eight tools.
    static let helpersDirectory: URL? = {
        var candidates: [URL] = []
        if let key = UserDefaults.standard.string(forKey: "helpersDir") {
            candidates.append(URL(fileURLWithPath:
                NSString(string: key).expandingTildeInPath))
        }
        // ⚠️ Built from `bundleURL`, NOT from `builtInPlugInsURL`. That
        // property is nil when the bundle has no `Contents/PlugIns`, which this
        // one does not, so the whole candidate silently disappeared and the app
        // fell through to Homebrew even when it carried its own helpers.
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin"))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin"))
        return candidates.first { exists($0.appendingPathComponent("apple")) }
    }()

    /// `apple-notes` and its stdlib-only Python modules, which must stay in one
    /// directory because it imports them as siblings.
    ///
    /// ⚠️ Under `Resources`, not `Helpers`. See `app/stage.sh`.
    static var notesDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let bundled = resources.appendingPathComponent("notes", isDirectory: true)
        return exists(bundled.appendingPathComponent("apple-notes")) ? bundled : nil
    }

    static var python: URL { URL(fileURLWithPath: "/usr/bin/python3") }

    /// Every tool `apple status` reports on. ⚠️ NOT the same list as the index
    /// sources: `phone` and `reminders` have grants but nothing ingests them.
    static let toolNames = ["mail", "messages", "notes", "calendar",
                            "contacts", "reminders", "phone", "maps"]

    /// ⚠️ A FALLBACK ONLY, for an `index.py` too old to answer `sources`. The
    /// live list comes from `index.py sources --json`, because the per-source
    /// arguments live there and two copies of them drift.
    static let indexSources = ["notes", "mail", "messages",
                               "calendar", "contacts", "maps", "reminders",
                               "files"]
}
