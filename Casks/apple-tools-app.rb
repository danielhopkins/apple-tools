cask "apple-tools-app" do
  version "26.823.1"
  sha256 :no_check

  url "https://github.com/danielhopkins/apple-tools/releases/download/v#{version}/AppleTools-#{version}.dmg"
  name "AppleTools"
  desc "Menu bar app that indexes your Apple data on a schedule and serves searches"
  homepage "https://github.com/danielhopkins/apple-tools"

  # 🛑 DEPENDS ON THE FORMULA, it does NOT conflict with it.
  #
  # The design doc calls for `conflicts_with formula: "apple-tools"`, on the
  # grounds that both would install an `apple` and a `reminders`. That will be
  # right once the app carries the CLIs in `Contents/Helpers`. It does not yet:
  # `Paths.toolsRoot` looks in the bundle first and then falls through to
  # `/opt/homebrew/opt/apple-tools/libexec/index`, and `Paths.helpersDirectory`
  # falls through to `/opt/homebrew/bin`. Without the formula the app has no
  # `apple` dispatcher, no `index.py`, no `vec` and no Core ML packages.
  depends_on formula: "apple-tools"
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
    wake and on unlock, and answers `apple-index search`.

    The index holds the decoded plaintext of your mail. It lives in an AES-256
    disk image that only this app mounts, and it is readable by anything running
    as you WHILE THE APP IS OPEN. "Delete the Index" in the window removes it
    and its key.
  EOS
end
