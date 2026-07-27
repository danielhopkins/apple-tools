# apple-tools

CLIs for reading and writing local Apple app data: Notes, Mail, Reminders,
Calendar, Contacts. Everything runs locally against the user's real data — no
network, no sync service, no API keys.

## Quick reference

All tools are reachable through the `apple` dispatcher, or directly by name if
installed via `make install`.

| Task | Command |
|------|---------|
| Search notes | `apple notes search "budget" --json` |
| Read a note | `apple notes export 261` |
| List note folders | `apple notes folders --json` |
| Search mail | `apple mail search "invoice" --field all --since 30 --json` |
| Read an email | `apple mail export <message-id>` |
| List mail accounts | `apple mail accounts --json` |
| Today's reminders | `apple reminders show-all --due-date today --include-overdue --json` |
| Add a reminder | `apple reminders add Soon "Buy milk" --due-date "tomorrow 9am"` |
| This week's events | `apple calendar events --days 7 --json` |
| Add an event | `apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45` |
| Find a person | `apple contacts search "smith" --json` |

**Every tool supports `--json`.** Prefer it — the plain output is for humans and
its shape is not stable. Use `apple --which` to see which binary each name
resolves to.

## Rules

1. **`--json` for anything you parse.** Plain-text layouts change; JSON keys don't.
2. **Reads are free, writes are not.** `notes export`, `mail search`, `contacts
   search`, `calendar events`, `reminders show*` only read. Anything that
   creates, edits, completes, or deletes touches the user's real data — confirm
   with them first unless they clearly asked for the write.
3. **Never edit a note that has attachments.** See the Notes section; one body
   write destroys every attachment on the note. This is unrecoverable.
4. **IDs are per-tool and not interchangeable.** Notes use integer PKs, Mail uses
   message IDs, Calendar uses EventKit identifiers, Contacts uses
   `UUID:ABPerson`. Reminders use a *positional index within a list* that shifts
   when items are added or completed — re-run `show` before acting on an index.
5. **Search before you write.** Reminder lists, calendar names, and mail accounts
   must match existing names; `show-lists` / `calendars` / `accounts` tell you
   what exists.

## Tools

### notes — `apple notes`

Reads `NoteStore.sqlite` directly, ungzips the protobuf body, and renders
Markdown (preserves `==highlights==`, bold, headings, lists, checklists).

```
apple notes search [TERM] [--limit N] [--json]   # title search; lists recent if TERM omitted
apple notes folders [NAME] [--limit N] [--json]  # all folders, or notes in one folder
apple notes export ID [-o out.md]                # note body as Markdown
apple notes get-url ID [--json]                  # applenotes:// deep link
```

`ID` accepts a numeric note ID, a note title, or an `applenotes://` URL.

**Search is title-only.** There is no full-text search over note bodies; to
search content, export candidates and grep them.

**Gotchas** (each locked by a live test in `notes/tests/`, full detail in
[`docs/apple-notes-api.md`](docs/apple-notes-api.md)):

- 🛑 **Editing `body` destroys all attachments.** A note's `body` doesn't include
  attachments at all, so the first write wipes every one of them. There is no
  attachment-preserving edit path. Treat notes with attachments as read-only.
- `set body` is a **full replace**, never a merge.
- The **first line becomes the title**, silently, on every body write.
- `delete` is a **soft delete** — the note moves to Recently Deleted and
  auto-purges in ~30 days. There is no API to empty that folder.
- The SQLite reader **can see Recently Deleted notes**. Filter them out if the
  user asked for live notes.
- `make new attachment` **double-inserts** on macOS 27.

Stdlib only — `notestore.py` decodes the gzipped-protobuf note body directly,
so no virtualenv is involved.

### mail — `apple mail`

AppleScript against Mail.app. Mail must be running; large mailboxes are slow, so
always pass `--limit` and prefer `--since`.

```
apple mail accounts [--json]
apple mail search QUERY [--account NAME] [--mailbox NAME] [--field subject|sender|content|all]
                        [--since DAYS] [--before DAYS] [--limit N]
                        [--flagged] [--unread] [--has-attachment] [--all] [--json]
apple mail export MESSAGE-ID [--account NAME]
```

`--field` defaults to `subject`; use `--field all` when the user describes
content rather than a subject line. `--all` widens the search to trash and junk,
which are excluded by default. Account names in this setup include emoji — get
exact strings from `apple mail accounts`.

### reminders — `apple reminders`

Swift + EventKit. Full CRUD. Fork of `keith/reminders-cli` with editing and
recurrence added.

```
apple reminders show-lists [--json]
apple reminders show LIST [--due-date DATE] [--include-overdue] [--include-completed]
                          [--sort none|creation-date|due-date] [--json]
apple reminders show-all [--due-date DATE] [--include-overdue] [--json]
apple reminders add LIST "TEXT" [--due-date DATE] [--priority high|medium|low|none]
                                [--notes TEXT] [--repeat daily|weekly|monthly|yearly]
                                [--repeat-interval N] [--repeat-until DATE] [--repeat-count N]
apple reminders edit LIST INDEX ["NEW TEXT"] [--due-date DATE] [--priority P] [--notes TEXT]
apple reminders complete LIST INDEX
apple reminders uncomplete LIST INDEX
apple reminders delete LIST INDEX
apple reminders new-list NAME
```

`--due-date` takes natural language: `today`, `tomorrow 9am`, `next friday`,
`2026-12-25`.

⚠️ `INDEX` is the position shown by `show`, and it **shifts** as items complete or
get added. Always `show` immediately before `complete`/`edit`/`delete`.

`--format json` still works as a synonym for `--json`.

### calendar — `apple calendar`

Swift + EventKit. Read and write events.

```
apple calendar calendars [--writable] [--json]
apple calendar events [--from DATE] [--to DATE | --days N] [--calendar NAME]
                      [--search TEXT] [--json]         # default: next 7 days
apple calendar show ID [--json]
apple calendar add "TITLE" --start DATE [--end DATE | --duration MINUTES]
                          [--calendar NAME] [--all-day] [--location TEXT]
                          [--notes TEXT] [--url URL] [--json]
apple calendar edit ID [--title T] [--start DATE] [--end DATE] [--location L]
                       [--notes N] [--future] [--json]
apple calendar delete ID [--future]
```

Dates accept natural language (`tomorrow 2pm`) or `YYYY-MM-DD [HH:MM]`. Default
event length is 1 hour.

`--calendar` must match a name from `calendars` exactly (case-insensitive).
Subscribed and holiday calendars are read-only — `calendars --writable` shows
which ones accept writes.

For recurring events, `--future` applies the change to this and all later
occurrences; without it only the single occurrence changes.

### contacts — `apple contacts`

Read-only Python over the AddressBook sqlite stores. Opens them with a read-only
URI, so it cannot modify contacts. Searches **every** source database and merges
results, so contacts from multiple accounts all appear.

```
apple contacts search TERM [--limit N] [--plain]   # default limit 25
apple contacts get ID [--plain]
apple contacts list [--limit N] [--plain]          # default limit 100
```

Matches against first/last/nickname/company/full name **and** email addresses and
phone numbers. Returns all emails, phones, and postal addresses with their
labels. **JSON is the default here**; pass `--plain` for human output.

## Layout

```
bin/apple                 dispatcher — routes to the tools below
swift/                    one Swift package, three binaries
  Sources/reminders/      + RemindersLibrary/
  Sources/AppleMail/
  Sources/AppleCalendar/
  Tests/RemindersTests/
notes/                    Python; apple-notes, notestore.py, notestore.proto,
                          tests/ (live Notes.app suite)
contacts/                 Python; apple-contacts
docs/apple-notes-api.md   NoteStore schema, AppleScript API, verified bugs
Formula/apple-tools.rb    Homebrew formula
VERSION                   CalVer YY.MMDD.Patch, stamped in by scripts/set-version
```

Both Python tools are stdlib-only and run on the system `python3`.

## Building

```
make build      # swift build -c release → all three binaries
make install    # symlink dispatcher + tools into ~/bin
make check      # smoke-test that every tool responds
make test       # Swift unit tests
make bump       # next CalVer for today, stamped into every tool
make dist       # universal release tarball + sha256 for the Homebrew tap
```

Every tool reports `--version`, and they all report the same one. If they
disagree, someone edited a version string by hand instead of running
`make set-version`.

The Notes test suite drives **live Notes.app** and creates real notes in iCloud.
It is gated behind `notes/run-tests`, prefixes every test note with
`__claude_notes_test__`, and refuses to delete anything else. Don't run it
casually.

## Permissions

Each tool needs a one-time TCC grant, prompted on first run **from a terminal**:

| Tool | Grant |
|------|-------|
| reminders | Privacy & Security → Reminders |
| calendar | Privacy & Security → Calendars |
| mail | Privacy & Security → Automation → Mail |
| notes, contacts | Full Disk Access for the calling terminal (reads sqlite directly) |

Grants are keyed to the binary path — rebuilding into a new location can
re-trigger the prompt. If a tool reports an access error, the fix is for the
**user** to run it once in their own terminal and approve the dialog; an agent
cannot click through it.
