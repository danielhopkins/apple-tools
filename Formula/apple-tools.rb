class AppleTools < Formula
  desc "Local CLIs for Notes, Mail, Messages, Phone, Maps, Reminders, Calendar, Contacts"
  homepage "https://github.com/danielhopkins/apple-tools"
  url "https://github.com/danielhopkins/apple-tools/releases/download/v26.827.1/apple-tools-26.827.1.tar.gz"
  sha256 "cd7fe8f32c6717192fc8afcb1d99642ca26691e6625abcaf9e51dedbc913fc77"
  license "MIT"

  depends_on :macos

  def install
    # apple-notes imports its Python modules as siblings, so they must all stay
    # in the same directory. bin/apple-notes is a symlink and the script
    # realpath()s itself, so the imports still resolve.
    #
    # Dir["*.py"], never a literal list: mergeable.py was added in v26.812.9 and
    # a named list would have installed apple-notes without it, giving an
    # ImportError on every invocation while the checkout worked fine.
    libexec.install "apple-notes", "notestore.proto", *Dir["*.py"]
    bin.install_symlink libexec/"apple-notes"

    bin.install "apple", "apple-contacts", "apple-mail", "apple-messages",
                "apple-phone", "apple-maps", "apple-calendar", "reminders"

    doc.install "README.md", "CLAUDE.md", "docs"

    zsh_completion.install Dir["completions/_*"]

    # Claude skills. `apple-tools --skills-dir` is not a thing; point users at
    # the install path in caveats and let them symlink what they want.
    (pkgshare/"skills").install Dir["skills/*"]

    # 🛑 The apple-index skill ships INSIDE the index payload, at
    # `index/skill/apple-index`, so `Dir["skills/*"]` above never saw it. The
    # caveats tell people to symlink `share/apple-tools/skills/*`, and that line
    # silently installed four skills out of five — the one for the newest
    # feature was the one missing.
    #
    # 🛑 COPY IT, DO NOT SYMLINK IT. `install_symlink opt_libexec/...` looks
    # version-proof and is not: Homebrew RELATIVIZES a symlink inside the
    # prefix, so `opt` was rewritten to the concrete Cellar path and the link
    # dangled the moment the next version replaced it. Shipped broken in
    # 26.824.2 — `share/apple-tools/skills/apple-index` pointed at 26.824.1.
    # The skill is a few kilobytes; a copy cannot dangle.
    # ⚠️ `cp_r`, not `install`. Homebrew's `install` MOVES the path, so it would
    # take the skill out of `index/skill/` before `libexec.install "index"`
    # ships that directory — leaving the payload silently short one file.
    cp_r "index/skill/apple-index", pkgshare/"skills"

    # The signed Shortcuts that provide the Notes write path. apple-notes finds
    # them by walking up from its own location to share/apple-tools/shortcuts,
    # so this path is load-bearing — see `shortcuts_dir()` in apple-notes.
    (pkgshare/"shortcuts").install Dir["shortcuts/*"]

    # apple-index: the semantic index across every source.
    #
    # 🛑 It all stays in ONE directory. `apple-index` finds index.py beside
    # itself, index.py finds `vec` beside itself, and `vec` finds the Core ML
    # weights in `models/` beside itself. Splitting them breaks the lookup.
    #
    # ⚠️ Installing builds no index and reads nothing. `apple-index refresh`
    # asks for consent first, once, and records it. See index/SECURITY.md for
    # what the index holds and why it is not encrypted.
    libexec.install "index"
    bin.install_symlink libexec/"index/apple-index"
  end

  def caveats
    <<~EOS
      apple-index builds a searchable copy of your own data. It asks for
      consent the first time and records it. Nothing is read until you run:
        apple-index refresh

      🛑 That index is NOT encrypted unless you also install the app, which
      moves it into an AES-256 disk image keyed to your Keychain:
        brew install --cask danielhopkins/formulae/apple-tools-app
      The app also refreshes the index on its own, every five minutes. Without
      it, `apple-index refresh` is a job you run by hand.
      Detail: #{HOMEBREW_PREFIX}/opt/apple-tools/libexec/index/SECURITY.md
      Remove the index at any time with: apple-index forget

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

      apple-notes, apple-mail, apple-messages, apple-phone and apple-maps read
      Apple's SQLite stores directly, which requires Full Disk Access for your
      terminal:
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

      apple-maps is read-only and needs nothing beyond that Full Disk Access. It
      reads Maps' visited places and guides out of MapsSync_0.0.1. Maps.app is
      not scriptable, and the store is mirrored by CloudKit, so the tool never
      writes. Note that visited places is not Significant Locations: that store
      belongs to routined and no unprivileged process can read it.

      apple-contacts also reads that store for contact notes, which the Contacts
      framework cannot expose without an Apple-granted entitlement.

      Writing a note is the one contacts command that needs a second grant.
      It goes through Contacts.app over AppleScript, because that entitlement is
      granted only to signed apps by request. So `apple contacts edit --note`
      needs Automation -> Contacts for your terminal, and it launches
      Contacts.app. Every other field, and every read, needs neither.
      `apple contacts status` reports both grants.

      Note that `--died` writes the marker into the note as well as the date, so
      it needs that grant too. Pass --no-mark to record the date alone.

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
    assert_match version.to_s, shell_output("#{bin}/apple-maps --version")

    # 🛑 THE ONE PLACE THAT EXERCISES BREW'S RELATIVE SYMLINK. `bin/apple-index`
    # is a link into libexec, and v26.822.1 shipped a wrapper that resolved it
    # wrongly — working perfectly from the tarball's flat layout and failing on
    # every install. `selfcheck` is also the only command that imports the
    # payload's sibling modules: `--version` and `sources` pass without them,
    # because the photos adapter imports inside itself.
    assert_match "ok", shell_output("#{bin}/apple-index selfcheck")

    # The dispatcher must find each tool as a sibling in bin.
    assert_match "apple-notes", shell_output("#{bin}/apple --which")

    # --help must work without any TCC grant, so it is safe in a sandbox.
    calendar_help = shell_output("#{bin}/apple-calendar --help")
    assert_match "events", calendar_help

    # The sync-visibility commands. `add` reported success for a write the
    # server refused with a 403 until these existed, so an unregistered one is
    # a silent regression back to that.
    assert_match "unsynced", calendar_help
    assert_match "sync-errors", calendar_help
    assert_match "resync", calendar_help

    # The recurrence parts EventKit will hold. `--months` is the only way to
    # say "yearly, but only these months" (FREQ=YEARLY;BYMONTH); without it the
    # substitute is a bounded monthly series that expires, which is what lapsed
    # three times before 26.821.1. Both flags refuse the frequencies EventKit
    # would ignore them on, so a missing flag is not a smaller feature — it is
    # a rule the user cannot write at all.
    calendar_add_help = shell_output("#{bin}/apple-calendar add --help")
    assert_match "on-the", calendar_add_help
    assert_match "months", calendar_add_help

    # A Google 403 is a rate limit far more often than a refusal: 16 of 16 such
    # writes synced ~156s later, while `add` called them REFUSED and exited 1.
    # --throttle-timeout is what lets the wait outlast the throttle window, so
    # losing the flag restores a hard failure on writes that succeed.
    assert_match "throttle-timeout", calendar_add_help

    # `move` is the one mail command that writes to real mailboxes, and an
    # unregistered subcommand fails silently: apple-mail prints root help and
    # exits 0 for any word it does not recognise, so "it ran" proves nothing.
    # Assert it appears in the subcommand list instead.
    assert_match "move", shell_output("#{bin}/apple-mail --help")

    # Same for the contacts move, which relocates a record between accounts
    # through private AddressBook API. If those symbols ever go missing the
    # command refuses at runtime rather than disappearing, so this only checks
    # it is registered at all.
    contacts_help = shell_output("#{bin}/apple-contacts --help")
    assert_match "move", contacts_help

    # `get` returned an addresses array that `edit` could not write until
    # 26.818.1, and the skill claimed otherwise. An unregistered flag is a
    # silent regression back to that.
    contacts_edit_help = shell_output("#{bin}/apple-contacts edit --help")
    assert_match "address", contacts_edit_help

    # Contact notes were unwritable before 26.821.0: --note was refused,
    # because CNContactNoteKey needs an entitlement no CLI can hold. The write
    # goes through Contacts.app instead, so a flag going missing here is the
    # difference between writing a note and refusing to write one.
    assert_match "append-note", contacts_edit_help
    assert_match "clear-note", contacts_edit_help

    # --died also marks the note. --no-mark is the opt-out, and it is the only
    # way to record a death when Automation -> Contacts is unavailable.
    assert_match "no-mark", contacts_edit_help

    # Relationship helpers. `link` appends where `edit --relation` replaces, so
    # losing it silently sends callers back to a command that deletes relations.
    assert_match "relations", contacts_help
    assert_match "link", contacts_help

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

    # `delete` is the one Notes command that removes something the user made.
    # It is soft — the note goes to Recently Deleted — but nothing here can
    # bring it back, so it must never go missing silently from a build.
    assert_match "delete", notes_help

    # Call-recording commands. These live in mergeable.py, a sibling module
    # added after notestore.py — the one file a literal install list would have
    # dropped. apple-notes imports it at module scope, so every assertion above
    # would fail too; this one names what is actually missing.
    assert_match "recordings", notes_help
    assert_match "transcript", notes_help

    # The phone-side signpost. It reads nothing, so it is safe without a grant,
    # and it is the only cross-reference telling someone looking in call history
    # that recordings live in Notes.
    assert_match "recordings", shell_output("#{bin}/apple-phone --help")

    # apple-maps is read-only by construction, so the assertion that matters is
    # that both read commands are registered. --help needs no grant.
    maps_help = shell_output("#{bin}/apple-maps --help")
    assert_match "places", maps_help
    assert_match "guides", maps_help

    # apple-index ships as ONE directory and each part finds the next one
    # beside itself: the wrapper finds index.py, index.py finds `vec`, and
    # `vec` finds the Core ML weights in models/. Any of those moving breaks
    # the lookup at runtime, not at install time.
    assert_path_exists libexec/"index/vec"
    assert_path_exists libexec/"index/models/vocab.txt"

    # --help needs no grant and touches no index.
    index_help = shell_output("#{bin}/apple-index --help")
    assert_match "refresh", index_help

    # `forget` is the revocation path: it deletes the index, the logs and the
    # recorded consent. lab/SECURITY.md calls it non-optional for a release,
    # so a build without it is one that cannot be undone.
    assert_match "forget", index_help
  end
end
