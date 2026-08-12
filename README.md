# apple-tools

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Homebrew](https://img.shields.io/badge/install-brew-FBB040?logo=homebrew&logoColor=white)](#install)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Local only](https://img.shields.io/badge/network%20calls-none-2ea44f)](#)

Command-line access to local Apple app data — **Notes, Mail, Messages, Phone,
Reminders, Calendar, Contacts** — built so an agent (or a shell) can work with
real data without an intermediary service. Everything is local: no network
calls, no API keys, no sync layer.

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
apple-mail accounts       # → Full Disk Access; Automation → Mail to write
apple-messages chats      # → Full Disk Access for your terminal
apple-phone recents       # → Full Disk Access for your terminal
apple-notes search        # → Full Disk Access for your terminal
```

`apple status` reports all seven at once without prompting, so start there
rather than running each tool to see which one errors.

The first three grants belong to **the tools themselves**, not to your terminal,
so `reminders`, `apple-calendar` and `apple-contacts` work the same from
Terminal, iTerm, Ghostty, VS Code, or a multiplexer, and appear by name in
System Settings. That takes a deliberate trick — see
[Permissions](#permissions).

`mail`, `messages`, `phone` and `notes` are different: Full Disk Access and
Automation are attributed to **whatever terminal launched the tool**, so those
four really do depend on where you run them.

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

Installs zsh completions for `apple` and all seven tools. The dispatcher delegates
after the tool name, so `apple calendar events --<TAB>` offers exactly what
`apple-calendar events --<TAB>` does. `reminders show <TAB>` completes list
names and `apple calendar --calendar <TAB>` completes calendar names, both live
from your data.

Homebrew installs these automatically.

## Usage

One dispatcher fronts all seven tools:

```
apple notes search "budget" --json
apple mail search "invoice" --json
apple mail search "budget" --field content --json      # full-text over bodies
apple messages search "dinner" --since 30 --json       # whole chat history
apple phone recents --missed --since 7                 # who called while I was out
apple reminders show-all --due-date today --include-overdue
apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45
apple contacts search "smith"
apple contacts export --group "Family" -o family.vcf
```

Each is also installed under its own name (`apple-notes`, `apple-mail`,
`apple-messages`, `apple-phone`, `reminders`, `apple-calendar`, `apple-contacts`). Run
`apple <tool> --help` for
full options, or `apple --which` to see what resolves where.

`apple status` reports every tool's permission state in one table, never
prompts, and exits non-zero if anything is unusable — the fastest way to find
out which grant is missing:

```
$ apple status
TOOL       PERMISSION                     OK
notes      Full Disk Access               ✓
mail       Full Disk Access + Automation  ✓
messages   Full Disk Access               ✓
phone      Full Disk Access               ✓
reminders  Reminders                      ✓
calendar   Calendars                      ✓
contacts   Contacts                       ✓

All tools have the access they need.
```

Anything marked ✗ gets a line underneath naming the exact state and what to do
about it — `denied`, `writeOnly` ("Add Only", which looks granted but cannot
read), `notDetermined`, and so on. `--json` reports the same detail per tool.

**Every tool accepts `--json`.** Plain-text output is for humans and its shape
isn't guaranteed; JSON is.

## What each tool does

| Tool | Backed by | Capability |
|------|-----------|------------|
| 📝 `notes` | `NoteStore.sqlite` + protobuf (reads), Shortcuts (writes) | Search titles, list folders, export notes as Markdown, deep links. `create` and `append` write through Shortcuts, which turns Markdown into native structure and preserves attachments and checklist state — see [`docs/apple-notes-shortcuts.md`](docs/apple-notes-shortcuts.md). |
| ✉️ `mail` | `Envelope Index` + `.emlx` (reads), AppleScript + pasteboard (compose) | Search by subject, sender, or full body text with date and flag filters; export a message; save its attachments. `compose`/`reply`/`forward` open a Mail window with everything but the body — including any `--attach` files — and put the body on the clipboard. **The tool never writes a body**, see [`docs/apple-mail-drafts.md`](docs/apple-mail-drafts.md). |
| 💬 `messages` | `chat.db` | Search and export iMessage/SMS/RCS history, list conversations, save attachments. Read-only. |
| ☎️ `phone` | `CallHistory.storedata` + AddressBook | Recent calls with callers resolved to names, missed/unknown filters, talk-time stats, blocked list. Read-only apart from `dial`, which hands a `tel:` URL to Phone.app for you to confirm. |
| ✅ `reminders` | EventKit | Full CRUD: add, edit, complete, delete, lists, priorities, recurrence, natural-language dates. |
| 📅 `calendar` | EventKit, plus private `EKAttendee` for invitee writes | List and search events, create, edit, delete; full recurrence (`--repeat`, plus `--on-the "4th monday"`); recurring-event spans. Reads invitees with their RSVP status, and can invite or uninvite people — which sends real mail, so `invite --dry-run` first. See [`docs/apple-calendar-invitees.md`](docs/apple-calendar-invitees.md). |
| 👤 `contacts` | Contacts framework, with a legacy `AddressBook` fallback | Search by name, company, email, or phone; create, edit, delete. Notes are read-only, and a contact that has one can only be written through the fallback. |

The Notes reader decodes Apple's gzipped-protobuf note bodies directly rather
than going through AppleScript, so it preserves highlights, headings, lists, and
checklists that the scripting interface flattens.

Mail reads work the same way — straight off Mail's own SQLite index and the
`.emlx` files on disk. On a 41,000-message store the same subject search takes
**0.04s** that way and **154s** through AppleScript, and it works with Mail.app
closed. It also makes `--field content` a real full-text search over decoded
message bodies (~9s worst case across the whole store), which the AppleScript
path could not finish at all. See
[`docs/apple-mail-store.md`](docs/apple-mail-store.md).

Messages is read the same way, from `~/Library/Messages/chat.db`. The catch
there is that about 4% of a long-lived store keeps its body not in the `text`
column but in an archived `NSAttributedString` — 1,921 ordinary messages on a
103,250-message store, which a plain `SELECT text` drops without any error.
`apple-messages` decodes that NeXT typedstream format directly; the decoder is
verified against the 99,023 rows that carry both columns, matching 99,022 of
them. See [`docs/apple-messages-store.md`](docs/apple-messages-store.md).
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

- **The grant is per-binary.** `reminders`, `apple-calendar` and
  `apple-contacts` each get their own row in System Settings, under their own
  name. An upgrade sometimes asks again and sometimes doesn't — 26.727.8 → .9
  re-prompted, .9 → .10 did not, both landing in a new Cellar directory — so
  treat a fresh prompt after upgrading as expected. Rebuilding in place has
  never re-prompted.
- **An existing terminal-keyed grant still works.** The re-execution is skipped
  whenever access already succeeds, so nobody who has already approved their
  terminal is disturbed, and no extra process is spawned.

This also needs the usage description (`NSContactsUsageDescription` and
friends) to be in the binary. A CLI has no bundle, so `Package.swift` embeds a
plist into `__TEXT,__info_plist` at link time — and `make build` re-signs
afterwards, because macOS ignores a plist that isn't covered by the signature.
`make dist` verifies the binding and fails the build if it is missing.

`apple-mail`, `apple-messages`, `apple-phone` and `apple-notes` are the
exceptions, and all four are attributed to the calling terminal rather than the
binary. `apple-notes`, `apple-messages` and `apple-phone` need Full Disk Access —
they read `NoteStore.sqlite`, `chat.db` and `CallHistory.storedata` directly.
`apple-phone` in particular *cannot* be made to disclaim: doing so would make it
its own responsible process and lose the terminal's Full Disk Access, which is
the grant it depends on. `apple-mail` needs Full Disk Access to read — search, export, attachments,
accounts — and Automation → Mail to open a compose window for `compose`, `reply`
and `forward`. `apple mail status` reports both separately.

## Layout

```
bin/apple        dispatcher
swift/           one Swift package → reminders, apple-mail, apple-messages, apple-phone,
                 apple-calendar, apple-contacts
notes/           Python: apple-notes, notestore.py decoder, live Notes.app tests
skills/          Claude skills (apple-tools, daily-brief, meeting-prep, inbox-triage)
completions/     zsh completions
tests/           live suites: calendar and contacts writes (gated), mail read guards
docs/            Notes API, Mail store and Calendar invitee references, prior art
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
./tests/run-tests              # calendar writes (58) + mail read guards (40)
./tests/run-tests --backends   # + every backend: Exchange, calDAV (Google, iCloud)
./tests/run-tests --contacts   # + contacts writes          (60)
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

## Prior art

Other projects covering the same ground — MCP servers, EventKit CLIs, Swift
bridges — are catalogued in [`docs/prior-art.md`](docs/prior-art.md), with what
each one verifiably does and doesn't handle. Worth a look before adding a
feature; several of them have already met the wall you're about to.

## Credits

- `reminders` is a fork of [keith/reminders-cli](https://github.com/keith/reminders-cli), with editing and recurrence added.
- Notes protobuf definitions from [apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser) (MIT).

## License

MIT — see [LICENSE](LICENSE).
