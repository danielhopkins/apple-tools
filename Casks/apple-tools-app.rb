cask "apple-tools-app" do
  version "26.824.1"
  sha256 "f3d8fc9ff519cfd85fd35f055603fbe1a4bcd865f93c8d99c3f573a4d17e2088"

  url "https://github.com/danielhopkins/apple-tools/releases/download/v#{version}/AppleTools-#{version}.dmg"
  name "AppleTools"
  desc "Menu bar app that indexes your Apple data on a schedule and serves searches"
  homepage "https://github.com/danielhopkins/apple-tools"

  # 🛑 IT DOES NOT DEPEND ON THE FORMULA, AND IT DOES NOT CONFLICT WITH IT.
  #
  # The app carries everything it needs: the eight CLIs in `Contents/Helpers`,
  # `apple-notes` and its Python modules in `Contents/Resources/notes`, and
  # `index.py`, `vec` and the Core ML packages in `Contents/Resources/index`.
  # Nothing falls through to Homebrew any more.
  #
  # ⚠️ It deliberately puts NO binary on PATH, which is why the design doc's
  # `conflicts_with formula: "apple-tools"` is wrong here. A tool typed into a
  # terminal is attributed to the TERMINAL, and the three disclaiming tools key
  # their grant to the BINARY PATH — so exposing the bundled copies would ask
  # the user to grant Calendar, Reminders and Contacts all over again, at a new
  # path, while the formula's copies already hold them. Leave the formula to
  # serve the terminal and let the app serve itself.
  depends_on macos: :sonoma

  app "AppleTools.app"

  # ⚠️ The app registers itself as a login item on first run, and disables the
  # `com.boulderhopkins.apple-index` launchd agent so the two never both bind
  # the search socket. `zap` puts the agent back.
  uninstall launchctl: "com.boulderhopkins.apple-index",
            quit:      "com.boulderhopkins.apple-tools"

  # 🛑 `zap` DELETES THE INDEX AND ITS KEY. The index holds the decoded
  # plaintext of every email; leaving an encrypted image and a Keychain key
  # behind after an uninstall is worse than deleting them.
  zap delete: "~/Library/Preferences/com.boulderhopkins.apple-tools.plist",
      trash:  [
        "~/Library/Application Support/apple-tools/app-diagnostics.json",
        "~/Library/Application Support/apple-tools/app-grants.json",
        "~/Library/Application Support/apple-tools/app-login-item.json",
        "~/Library/Application Support/apple-tools/app-state.json",
        "~/Library/Application Support/apple-tools/index.sparsebundle",
        "~/Library/Application Support/apple-tools/lab-index.db",
        "~/Library/Application Support/apple-tools/logs",
      ]

  caveats <<~EOS
    AppleTools needs Full Disk Access, and macOS has no way for an app to ask
    for it. Add it by hand once:

      System Settings > Privacy & Security > Full Disk Access > +

    macOS restarts the app when you do. It then indexes every five minutes, on
    wake and on unlock, and answers searches on its socket.

    The app is self-contained. For the `apple` and `apple-index` commands in
    your own terminal, install the formula as well:

      brew install danielhopkins/formulae/apple-tools

    The index holds the decoded plaintext of your mail. It lives in an AES-256
    disk image that only this app mounts, and it is readable by anything running
    as you WHILE THE APP IS OPEN. "Delete the Index" in the window removes it
    and its key.
  EOS
end
