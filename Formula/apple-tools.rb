class AppleTools < Formula
  desc "Local CLIs for Notes, Mail, Messages, Phone, Reminders, Calendar, Contacts"
  homepage "https://github.com/danielhopkins/apple-tools"
  url "https://github.com/danielhopkins/apple-tools/releases/download/v26.812.2/apple-tools-26.812.2.tar.gz"
  sha256 "da5a565d9e88cec5515356f145c58403c6ecafe482c485d2c7bae2e71a73451c"
  license "MIT"

  depends_on :macos

  def install
    # apple-notes imports notestore.py as a sibling module, so the two must stay
    # in the same directory. bin/apple-notes is a symlink and the script
    # realpath()s itself, so the import still resolves.
    libexec.install "apple-notes", "notestore.py", "notestore.proto"
    bin.install_symlink libexec/"apple-notes"

    bin.install "apple", "apple-contacts", "apple-mail", "apple-messages",
                "apple-phone", "apple-calendar", "reminders"

    doc.install "README.md", "CLAUDE.md", "docs"

    zsh_completion.install Dir["completions/_*"]

    # Claude skills. `apple-tools --skills-dir` is not a thing; point users at
    # the install path in caveats and let them symlink what they want.
    (pkgshare/"skills").install Dir["skills/*"]

    # The signed Shortcuts that provide the Notes write path. apple-notes finds
    # them by walking up from its own location to share/apple-tools/shortcuts,
    # so this path is load-bearing — see `shortcuts_dir()` in apple-notes.
    (pkgshare/"shortcuts").install Dir["shortcuts/*"]
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
        apple-contacts list        # Contacts access

        apple-mail compose --help  # no grant needed, but composing needs
                                   # Automation -> Mail on first real use

      reminders, apple-calendar and apple-contacts hold their own grants rather
      than borrowing the terminal's, so they work from any terminal and appear
      in System Settings under their own names. Upgrading this formula
      occasionally asks for a grant again; that is expected, not a fault.

      apple-notes, apple-mail, apple-messages and apple-phone read Apple's
      SQLite stores directly, which requires Full Disk Access for your terminal:
      System Settings -> Privacy & Security -> Full Disk Access

      For apple-mail that covers search, export, attachments and accounts —
      they read Mail's own index and message files, so they are fast and work
      with Mail.app closed.

      apple-mail also has compose, reply and forward. They open a Mail window
      with recipients, subject, threading and attachments filled in, put the body
      on your clipboard, and stop — you press Cmd-V then Cmd-S. The tool never
      writes a body: one written by a script is wrapped in a citation blockquote
      and reaches recipients rendered as a quotation. That needs the Automation
      grant below. There is no send; send from Mail.app.

      apple-mail move refiles received messages into another mailbox, in batches,
      for filing mail a filter rule missed. It needs both grants: Full Disk
      Access to find each message and Automation to move it. Run it with
      --dry-run first — that resolves everything from Mail's index without
      touching Mail, and these moves sync to all your devices.

      Run `apple mail status` for the grant detail.

      apple-messages is read-only and needs nothing beyond that Full Disk
      Access; it reads ~/Library/Messages/chat.db and never drives Messages.app.

      apple-phone needs nothing beyond it either, and covers both halves of what
      it does: the call history store and the address book it resolves callers
      against. Phone.app is not scriptable at all, so there is no Automation
      grant to give it. `apple phone dial` hands a tel: URL to Phone.app, which
      always asks you to confirm before it dials.

      apple-contacts also reads that store for contact notes, which the Contacts
      framework cannot expose without an Apple-granted entitlement.

      Writing to Notes needs one extra step. AppleScript cannot create a
      checklist and its only body write destroys every attachment on the note,
      so writes go through Notes' own Shortcuts actions instead. Install them
      once:

        apple notes install-shortcuts

      That opens two shortcuts for you to add; the first run of each then asks
      "Allow ... to save a note?". Choose Always Allow for unattended use, or
      Allow Once to review every individual write. Until they are installed,
      apple-notes is read-only — `apple notes status` reports which are missing.
      Details in #{HOMEBREW_PREFIX}/share/doc/apple-tools/apple-notes-shortcuts.md
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apple --version")
    assert_match version.to_s, shell_output("#{bin}/apple-notes --version")
    assert_match version.to_s, shell_output("#{bin}/apple-contacts --version")
    assert_match version.to_s, shell_output("#{bin}/reminders --version")
    assert_match version.to_s, shell_output("#{bin}/apple-mail --version")
    assert_match version.to_s, shell_output("#{bin}/apple-calendar --version")
    assert_match version.to_s, shell_output("#{bin}/apple-messages --version")
    assert_match version.to_s, shell_output("#{bin}/apple-phone --version")

    # The dispatcher must find each tool as a sibling in bin.
    assert_match "apple-notes", shell_output("#{bin}/apple --which")

    # --help must work without any TCC grant, so it is safe in a sandbox.
    assert_match "events", shell_output("#{bin}/apple-calendar --help")

    # `move` is the one mail command that writes to real mailboxes, and an
    # unregistered subcommand fails silently: apple-mail prints root help and
    # exits 0 for any word it does not recognise, so "it ran" proves nothing.
    # Assert it appears in the subcommand list instead.
    assert_match "move", shell_output("#{bin}/apple-mail --help")

    # The Notes write path is the signed shortcuts plus the commands that drive
    # them. `make dist` cannot know this formula's install list, so a shortcut
    # added to the repo can ship inside the tarball and never be installed —
    # the same trap that silently unlinked apple-messages in v26.728.5.
    assert_path_exists pkgshare/"shortcuts/Apple Tools Create Note.shortcut"
    assert_path_exists pkgshare/"shortcuts/Apple Tools Append Note.shortcut"

    # And the commands must be reachable. --help needs no grant.
    notes_help = shell_output("#{bin}/apple-notes --help")
    assert_match "install-shortcuts", notes_help
    assert_match "append", notes_help
  end
end
