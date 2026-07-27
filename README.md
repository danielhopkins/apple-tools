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
apple-mail accounts       # → Automation access for Mail
apple-notes search        # → needs Full Disk Access for your terminal
```

macOS only shows a prompt the first time; after that the request returns
silently. Calendar has a third state worth knowing about — "Add Only"
(`writeOnly`), which looks granted but cannot read events and is never offered
an upgrade prompt. `apple calendar status` reports the real state without
prompting; the fix is a manual toggle to "Full Access" in System Settings.

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
| `contacts` | AddressBook sqlite | Search by name, company, email, or phone. Opened read-only. |

The Notes reader decodes Apple's gzipped-protobuf note bodies directly rather
than going through AppleScript, so it preserves highlights, headings, lists, and
checklists that the scripting interface flattens.
[`docs/apple-notes-api.md`](docs/apple-notes-api.md) documents the schema and the
verified behaviors and bugs behind that, including a data-loss bug where editing
a note's body destroys its attachments.

## Layout

```
bin/apple        dispatcher
swift/           one Swift package → reminders, apple-mail, apple-calendar
notes/           Python: apple-notes, notestore.py decoder, live Notes.app tests
contacts/        Python: apple-contacts
tests/           live calendar write-path suite (gated)
docs/            Notes API reference and behavior notes
Formula/         Homebrew formula, mirrored into the tap on release
VERSION          single source of truth, stamped into every tool
CLAUDE.md        the same surface, written for an agent
```

Both Python tools are stdlib-only. `notes/notestore.py` decodes Apple's
protobuf note bodies directly rather than depending on the `protobuf` package,
which is what lets the whole thing run on a stock macOS `python3`.

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

Two live suites drive real data and are gated behind their own runners:

```
./tests/run-tests        # calendar write paths: add / edit / delete
./notes/run-tests        # live Notes.app
```

Both are self-cleaning: every artifact is created with a `__claude_*_test__`
prefix and the sweep refuses to delete anything without it. The calendar suite
creates real events on a writable calendar, which syncs to your other devices;
pick where with `APPLE_CALENDAR_TEST_CALENDAR="Personal"`. Neither is a casual
command.

## Credits

- `reminders` is a fork of [keith/reminders-cli](https://github.com/keith/reminders-cli), with editing and recurrence added.
- Notes protobuf definitions from [apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser) (MIT).

## License

MIT — see [LICENSE](LICENSE).
