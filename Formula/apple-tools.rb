class AppleTools < Formula
  desc "CLIs for local Apple app data: Notes, Mail, Reminders, Calendar, Contacts"
  homepage "https://github.com/danielhopkins/apple-tools"
  url "https://github.com/danielhopkins/apple-tools/releases/download/v26.727.6/apple-tools-26.727.6.tar.gz"
  sha256 "8b4f29602b7a6352c5ad5979b9bc2d142274b5715a4c5547ff944e6d9e045806"
  license "MIT"

  depends_on :macos

  def install
    # apple-notes imports notestore.py as a sibling module, so the two must stay
    # in the same directory. bin/apple-notes is a symlink and the script
    # realpath()s itself, so the import still resolves.
    libexec.install "apple-notes", "notestore.py", "notestore.proto"
    bin.install_symlink libexec/"apple-notes"

    bin.install "apple", "apple-contacts", "apple-mail", "apple-calendar", "reminders"

    doc.install "README.md", "CLAUDE.md", "docs"

    zsh_completion.install Dir["completions/_*"]

    # Claude skills. `apple-tools --skills-dir` is not a thing; point users at
    # the install path in caveats and let them symlink what they want.
    (pkgshare/"skills").install Dir["skills/*"]
  end

  def caveats
    <<~EOS
      Claude skills are installed to:
        #{HOMEBREW_PREFIX}/share/apple-tools/skills

      Link them into whichever Claude config dir you use (CLAUDE_CONFIG_DIR
      selects one per session, and a machine may have several profiles):
        mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
        ln -sfn #{HOMEBREW_PREFIX}/share/apple-tools/skills/* \
                "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/"

      reminders-cli is superseded by this formula and ships the same `reminders`
      command. If it is still installed, linking will fail until you remove it:

        brew uninstall reminders-cli && brew link apple-tools

      Each tool needs a one-time macOS permission grant, prompted on first run
      from a terminal. Run these once and approve each dialog:

        reminders show-lists       # Reminders access
        apple-calendar calendars   # Calendar access
        apple-mail accounts        # Automation access for Mail

        apple-contacts status      # Contacts access

      apple-notes reads Apple's SQLite store directly, which requires Full Disk
      Access for your terminal app:
      System Settings -> Privacy & Security -> Full Disk Access

      apple-contacts also reads that store for contact notes, which the Contacts
      framework cannot expose without an Apple-granted entitlement.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apple --version")
    assert_match version.to_s, shell_output("#{bin}/apple-notes --version")
    assert_match version.to_s, shell_output("#{bin}/apple-contacts --version")
    assert_match version.to_s, shell_output("#{bin}/reminders --version")
    assert_match version.to_s, shell_output("#{bin}/apple-mail --version")
    assert_match version.to_s, shell_output("#{bin}/apple-calendar --version")

    # The dispatcher must find each tool as a sibling in bin.
    assert_match "apple-notes", shell_output("#{bin}/apple --which")

    # --help must work without any TCC grant, so it is safe in a sandbox.
    assert_match "events", shell_output("#{bin}/apple-calendar --help")
  end
end
