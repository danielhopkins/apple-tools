# apple-tools

Command-line access to local Apple app data — **Notes, Mail, Reminders,
Calendar, Contacts** — built so an agent (or a shell) can work with real data
without an intermediary service. Everything is local: no network calls, no API
keys, no sync layer.

```
$ apple calendar events --days 3
Mon Jul 27, 9:00 AM–9:30 AM  Standup  [Work]
Mon Jul 27, 2:00 PM–3:00 PM  1:1  [Work]
Tue Jul 28, 6:00 PM–8:00 PM  Piano recital @ Boulder Public Library  [Family]

$ apple contacts search "rivera" --plain
Sam Rivera (Northwind Labs)
  email  sam@example.com  [work]
  phone  +15551234567  [mobile]
```

## Install

```
brew install danielhopkins/formulae/apple-tools
```

No runtime dependencies: the Swift binaries ship universal (arm64 + x86_64) and
the Python tools use only the standard library, so the system `python3` is
enough.

Or from source — requires Xcode:

```
git clone https://github.com/danielhopkins/apple-tools ~/src/apple-tools
cd ~/src/apple-tools
make install          # builds Swift binaries, symlinks everything into ~/bin
```

Either way, run each tool once **from your terminal** to approve its macOS
permission prompt — an agent can't click through those dialogs:

```
reminders show-lists      # → Reminders access
apple-calendar calendars  # → Calendar access
apple-contacts list       # → Contacts access
apple-mail accounts       # → Automation access for Mail
apple-notes search        # → needs Full Disk Access for your terminal
```

The grants belong to **the tools themselves**, not to your terminal, so they
work the same from Terminal, iTerm, Ghostty, VS Code, or a multiplexer. That
takes a deliberate trick — see [Permissions](#permissions) — and it is why
`reminders`, `apple-calendar` and `apple-contacts` appear by name in System
Settings.

macOS only shows a prompt the first time; after that the request returns
silently. Calendar has a third state worth knowing about — "Add Only"
(`writeOnly`), which looks granted but cannot read events and is never offered
an upgrade prompt. `apple calendar status` reports the real state without
prompting; the fix is a manual toggle to "Full Access" in System Settings.
`apple contacts status` does the same for Contacts.

`apple-contacts` reads contact *notes* straight from the AddressBook SQLite
store, because `CNContactNoteKey` needs an Apple-granted entitlement no CLI can
hold — so it wants Full Disk Access too, but only for that one field.

## Claude skills

Four skills teach Claude to use these tools, installable into any Claude Code
instance:

| Skill | What it does |
|-------|--------------|
| `apple-tools` | The tool surface, safety rules, and every trap. The others build on it. |
| `daily-brief` | Today's calendar, due/overdue reminders, and mail worth reading. Read-only. |
| `meeting-prep` | For an upcoming meeting: attendees from Contacts, recent mail, related notes. Read-only. |
| `inbox-triage` | Turns actionable mail into reminders — proposes first, creates only on approval. |

```
make install-skills      # symlinks skills/ into every Claude config dir found
make uninstall-skills
```

Claude reads one config dir per session, chosen by `CLAUDE_CONFIG_DIR`, and a
machine can have several profiles. `install-skills` targets every one it finds
(`~/.claude-personal`, `~/.claude-inevitable`, `~/.claude`) so the skills are
there whichever profile the session runs under. Override with:

```
make install-skills CLAUDE_DIRS="$HOME/.claude-work"
```

They are symlinks, so edits in the repo take effect in the next Claude session.

## Shell completion

```
make install-completions
```

Installs zsh completions for `apple` and all five tools. The dispatcher delegates
after the tool name, so `apple calendar events --<TAB>` offers exactly what
`apple-calendar events --<TAB>` does. `reminders show <TAB>` completes list
names and `apple calendar --calendar <TAB>` completes calendar names, both live
from your data.

Homebrew installs these automatically.

## Usage

One dispatcher fronts all five tools:

```
apple notes search "budget" --json
apple mail search "invoice" --field all --since 30 --json
apple reminders show-all --due-date today --include-overdue
apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45
apple contacts search "smith"
```

Each is also installed under its own name (`apple-notes`, `apple-mail`,
`reminders`, `apple-calendar`, `apple-contacts`). Run `apple <tool> --help` for
full options, or `apple --which` to see what resolves where.

**Every tool accepts `--json`.** Plain-text output is for humans and its shape
isn't guaranteed; JSON is.

## What each tool does

| Tool | Backed by | Capability |
|------|-----------|------------|
| `notes` | `NoteStore.sqlite` + protobuf | Search titles, list folders, export notes as Markdown, deep links. Read-only. |
| `mail` | AppleScript / Mail.app | Search by subject, sender, or content with date and flag filters; export a message. Read-only. |
| `reminders` | EventKit | Full CRUD: add, edit, complete, delete, lists, priorities, recurrence, natural-language dates. |
| `calendar` | EventKit | List and search events, create, edit, delete; recurring-event spans. |
| `contacts` | Contacts framework | Search by name, company, email, or phone; create, edit, delete. Notes are read-only. |

The Notes reader decodes Apple's gzipped-protobuf note bodies directly rather
than going through AppleScript, so it preserves highlights, headings, lists, and
checklists that the scripting interface flattens.
[`docs/apple-notes-api.md`](docs/apple-notes-api.md) documents the schema and the
verified behaviors and bugs behind that, including a data-loss bug where editing
a note's body destroys its attachments.

## Permissions

macOS attributes a privacy request not to the process that makes it but to the
**responsible process** — and for a command-line tool that is the terminal app
that launched it, not the tool. Left alone, this produces a genuinely confusing
failure: the grant lands on Terminal.app or Ghostty, the same binary works in
one terminal and is denied in another, and in the terminal that lacks the grant
`requestAccess` returns "Access Denied" *immediately* — no dialog, and no entry
in System Settings to switch on, because no record was ever created.

The tools take responsibility for themselves instead. On first use, if access
isn't already working, each one re-executes itself via `posix_spawn` with
`responsibility_spawnattrs_setdisclaim`, which makes the new process its own
responsible process. TCC then keys the grant to *that binary* and shows *its*
usage description — the same mechanism browsers use to give helper processes
distinct permissions. The SPI is resolved with `dlsym`, so if it ever
disappears the tools quietly fall back to the old behaviour.

Two consequences worth knowing:

- **The grant is per-binary and per-path.** `reminders`, `apple-calendar` and
  `apple-contacts` each get their own row in System Settings, under their own
  name. Because TCC keys ad-hoc-signed binaries by path, a `brew upgrade`
  installs into a new Cellar directory and prompts once more. Rebuilding in
  place does not re-prompt.
- **An existing terminal-keyed grant still works.** The re-execution is skipped
  whenever access already succeeds, so nobody who has already approved their
  terminal is disturbed, and no extra process is spawned.

This also needs the usage description (`NSContactsUsageDescription` and
friends) to be in the binary. A CLI has no bundle, so `Package.swift` embeds a
plist into `__TEXT,__info_plist` at link time — and `make build` re-signs
afterwards, because macOS ignores a plist that isn't covered by the signature.
`make dist` verifies the binding and fails the build if it is missing.

`apple-mail` is the exception: it drives Mail.app over AppleScript, so it needs
Automation access, which is still attributed to the calling terminal.
`apple-notes` reads the SQLite store directly and needs Full Disk Access for
the terminal.

## Layout

```
bin/apple        dispatcher
swift/           one Swift package → reminders, apple-mail, apple-calendar, apple-contacts
notes/           Python: apple-notes, notestore.py decoder, live Notes.app tests
skills/          Claude skills (apple-tools, daily-brief, meeting-prep, inbox-triage)
completions/     zsh completions
tests/           live write-path suites: calendar, mail drafts, contacts (gated)
docs/            Notes API reference and behavior notes
Formula/         Homebrew formula, mirrored into the tap on release
VERSION          single source of truth, stamped into every tool
CLAUDE.md        the same surface, written for an agent
```

`apple-notes` is the one remaining Python tool and is stdlib-only:
`notes/notestore.py` decodes Apple's protobuf note bodies directly rather than
depending on the `protobuf` package, which is what lets it run on a stock macOS
`python3`.

## Development

```
make build     # release binaries
make debug     # debug binaries
make check     # smoke-test every tool
make test      # Swift unit tests
make clean
```

Releases use CalVer, `YY.MMDD.Patch`:

```
make bump      # next version for today, stamped into every tool
make dist      # universal tarball for the tap + its sha256
make tag       # git tag vYY.MMDD.Patch
```

The live suites drive real data and are gated behind their own runners, each
opting in to one more surface:

```
./tests/run-tests              # calendar write paths       (25 tests)
./tests/run-tests --mail       # + mail drafts              (19)
./tests/run-tests --contacts   # + contacts writes          (28)
./notes/run-tests              # live Notes.app
```

All are self-cleaning: every artifact is created with a `__claude_*_test__`
prefix and the sweep refuses to delete anything without it. The calendar suite
creates real events on a writable calendar, which syncs to your other devices;
pick where with `APPLE_CALENDAR_TEST_CALENDAR="Personal"`.

The contacts suite is the sharpest of them — contact writes sync everywhere and
have no undo — so its fixtures must carry `__claude_contacts_test__` as their
*exact* first name, not merely start with it. TCC grants are per binary path, so
the build you just made may not be the approved one; point the suite at a
granted copy with `APPLE_CONTACTS_BIN="$(command -v apple-contacts)"`. None of
these is a casual command.

## Credits

- `reminders` is a fork of [keith/reminders-cli](https://github.com/keith/reminders-cli), with editing and recurrence added.
- Notes protobuf definitions from [apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser) (MIT).

## License

MIT — see [LICENSE](LICENSE).
