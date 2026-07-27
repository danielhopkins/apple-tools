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
| Update a contact | `apple contacts edit <id> --company "New Co"` |

**Every tool supports `--json`.** Prefer it — the plain output is for humans and
its shape is not stable. Use `apple --which` to see which binary each name
resolves to.

## Rules

1. **`--json` for anything you parse.** Plain-text layouts change; JSON keys don't.
2. **Reads are free, writes are not.** `notes export`, `mail search`, `contacts
   search/get/list`, `calendar events`, `reminders show*` only read. Anything
   that creates, edits, completes, or deletes touches the user's real data —
   confirm with them first unless they clearly asked for the write. Contacts
   writes sync to every device and there is no undo.
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
apple mail accounts [--json]      # names, addresses, mailboxes, enabled
apple mail search QUERY [--account NAME] [--mailbox NAME] [--field subject|sender|content|all]
                        [--since DAYS] [--before DAYS] [--limit N]
                        [--flagged] [--unread] [--has-attachment] [--all] [--json]
apple mail export MESSAGE-ID [--account NAME]

apple mail draft --to ADDR [--to ...] [--cc ADDR] [--bcc ADDR]
                 --subject TEXT [--body TEXT | --body-file FILE|-]
                 [--from ACCOUNT-ADDRESS] [--html] [--attach FILE]... [--json]
apple mail send  <same flags> --confirm
```

**Picking the account.** `accounts` reports each account's `addresses` as well
as its name — those addresses are exactly what `--from` accepts. `--from` also
takes an account *name*, which matters here because the names are emoji and are
not themselves valid senders. Run `accounts --json` rather than guessing.

**Drafting.** `draft` writes to the Drafts mailbox of whichever account matches
`--from` (your default account otherwise) and never sends. `--body-file -`
reads the body from stdin, which is the easiest way to pass long or generated
text. Attachments are validated before anything is composed.

`send` refuses to run without `--confirm`, because sending is immediate and
irreversible. **Prefer `draft` and let the user send it themselves** — only use
`send` when they have explicitly asked you to send, in that turn.

⚠️ Mail's compose surface is unusually buggy. These are all verified on
macOS 27 and pinned by `tests/test_mail_draft.py`:

- **Only one route removes a draft.** `delete` silently does nothing, `move`
  errors, and `set deleted status` fails with "Connection is invalid".
  Reassigning `mailbox of <message>` to the account's trash **does** work. The
  trash mailbox is named differently per account type (`Deleted Messages`,
  `Trash`, `Deleted Items`), so try each. Two traps: the Drafts enumeration is
  stale within a single script run, so collect message ids first and move each
  once rather than re-scanning after every move; and a move occasionally
  reports success without taking effect, so re-check and retry.
- **Reading recipients back is broken.** `to recipients`, `cc recipients` and
  `bcc recipients` on a saved draft all return the last-added recipient. The
  RFC822 `source` is the only trustworthy read. The headers written are correct.
- **The body is always wrapped in `<blockquote type="cite">`.** Mail does this
  to any programmatically set body — `content`, `html content` and visible
  compose windows alike. The quote styling is neutralised inline, so it renders
  normally, but the markup is there and some clients may treat it as quoted.
- **The `text/plain` alternative is empty.** The body lives only in the
  `text/html` part, so a plain-text-only reader sees nothing. Mail may
  regenerate the MIME on send; this is what the stored draft contains.
- **A draft's sender is frozen once saved.** `set sender` works only on an
  outgoing message before `save`; afterwards it errors. Moving a draft to
  another account's Drafts *does* work, but the sender does not follow, leaving
  a message filed under one account that would send from another. So choose the
  account with `--from` at creation time; there is no correct after-the-fact
  move short of rebuilding the message.
- **Text comes back NFD.** Mail decomposes unicode, so `ü` sent as one
  codepoint returns as `u` + combining diaeresis. Normalise before comparing.

`--field` defaults to `subject`; use `--field all` when the user describes
content rather than a subject line. `--all` widens the search to trash and junk,
which are excluded by default. Account names can contain emoji and spaces — get
exact strings from `apple mail accounts` rather than guessing.

⚠️ **An empty result may be a timeout.** AppleScript's event timeout is ~120s;
when it trips, `search` prints `[]` and exits 0, which is indistinguishable from
"no matches". A search that takes about two minutes and returns nothing has
failed — don't report it as an empty inbox. Keep searches cheap (`--mailbox
inbox`, tight `--since`, small `--limit`); an empty query combined with
`--field all` greps every message body in every mailbox and will not finish.

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
apple calendar show ID [--occurrence DATE] [--json]
apple calendar add "TITLE" --start DATE [--end DATE | --duration MINUTES]
                          [--calendar NAME] [--all-day] [--location TEXT]
                          [--notes TEXT] [--url URL] [--json]
apple calendar edit ID [--title T] [--start DATE] [--end DATE] [--location L]
                       [--notes N] [--occurrence DATE | --series] [--future] [--json]
apple calendar delete ID [--occurrence DATE | --series] [--future]
apple calendar status [--json]                # report permission state, never prompts
```

Dates accept natural language (`tomorrow 2pm`) or `YYYY-MM-DD [HH:MM]`. Default
event length is 1 hour.

`--calendar` must match a name from `calendars` exactly (case-insensitive).
Subscribed and holiday calendars are read-only — `calendars --writable` shows
which ones accept writes.

⚠️ **Calendar titles are not unique.** A subscribed read-only "Birthdays" can
sit alongside a writable one of the same name. `--calendar NAME` therefore
matches *every* calendar with that name when reading, and prefers a writable
one when writing — otherwise `calendars --writable` would offer a name that
`add` then rejected as read-only. When it matters which one you got, use the
`calendar` field on each event rather than assuming the name is unambiguous.

**Recurring events.** An event ID identifies the *series*, not the instance you
saw — EventKit resolves it to the first occurrence, often years earlier. So:

- `events --json` sets an **`occurrence`** field on recurring events. Pass it
  straight back as `--occurrence` to act on that instance.
- `edit` and `delete` **refuse to run** on a recurring event unless you pass
  either `--occurrence DATE` or `--series`. They will not guess.
- `show` without `--occurrence` returns the series master and says so on stderr.
- `--series` targets the master deliberately; combined with `--future` that
  rewrites the whole series.
- `--future` applies a change to this and all later occurrences; without it only
  the single occurrence changes.

`apple calendar add` cannot create recurring events — use Reminders'
`--repeat`, or create the series in Calendar.app.

### contacts — `apple contacts`

Swift + Contacts framework (`CNContactStore`). Full CRUD.

```
apple contacts search TERM [--limit N] [--plain]   # default limit 25
apple contacts get ID [--plain]
apple contacts list [--limit N] [--plain]          # default limit 100
apple contacts add [FIELDS] [--container NAME] [--json]
apple contacts edit ID [FIELDS] [--json]
apple contacts delete ID
apple contacts status [--json]                     # permission state, never prompts

apple contacts groups                              # list, with member counts
apple contacts groups create NAME [--container ID]
apple contacts groups rename GROUP NEW-NAME
apple contacts groups delete GROUP
apple contacts groups members GROUP [--plain]
apple contacts groups add GROUP CONTACT-ID
apple contacts groups remove GROUP CONTACT-ID
```

`GROUP` accepts a group id **or** an unambiguous group name.

FIELDS, shared by `add` and `edit`:

```
--first --middle --last --name-prefix --name-suffix --nickname
--company --department --job-title
--birthday YYYY-MM-DD|--MM-DD
--anniversary YYYY-MM-DD|--MM-DD
--email    [LABEL:]ADDRESS   repeatable
--phone    [LABEL:]NUMBER    repeatable
--url      [LABEL:]URL       repeatable
--relation LABEL:NAME        repeatable
--date     LABEL:DATE        repeatable
```

Labels are friendly names: `home`, `work`, `school`, `other`, plus `mobile`,
`iphone`, `main`, `pager` for phones. `--email work:a@b.com`. Unlabelled values
are accepted for email/phone/url.

**Relations.** `--relation father:"Robert Hopkins"`. All 216 relation labels the
Contacts SDK defines are accepted — `father`, `mother`, `son`, `daughter`,
`brother`, `sister`, `spouse`, `partner`, `grandfather`, `niece`, `colleague`,
and so on, including in-law and step variants. Matching ignores case, spaces and
hyphens, so `younger-sister` and `youngerSister` both work. An unrecognised
label is still stored, as a custom label, with a note on stderr suggesting near
matches — so a typo like `fathr` is visible rather than silent.

**Dates.** `--birthday` and `--anniversary` are the two Contacts models
natively. Everything else is a labelled date: `--date death:2020-05-01`,
`--date graduation:--06-15`. There is no death-date constant in the SDK — only
`anniversary` — so a death date is stored as a custom label, which is what
Contacts.app does for user-created date labels too. `--MM-DD` records a day with
no year.

Search matches first/middle/last/nickname/company/department/job title/full name,
email addresses, and phone numbers (digits only, so `7205551234` finds
`+1 (720) 555-1234`). **JSON is the default**; pass `--plain` for human output.

**Output shapes.** `get`, `add` and `edit` return a single JSON **object**;
`search`, `list` and `groups members` return **arrays**. An unlabelled email,
phone or URL omits the `label` key rather than emitting `null`. The JSON keys
for the name affixes are `prefix` and `suffix`, though the flags are
`--name-prefix` / `--name-suffix`.

⚠️ **`--MM-DD` needs `=`.** `--birthday --04-13` fails, because the parser reads
the value as the next flag. Write `--birthday=--04-13`, and likewise for
`--anniversary` and `--date`.

⚠️ **`groups remove` drives Contacts.app over AppleScript.**
`CNSaveRequest.removeMember` is a silent no-op on macOS 27 — it saves without
error and the membership is unchanged. That was verified three ways (unified
contact, identifier-predicate fetch at `unifyResults = false`, and the group's
own member objects); all three succeed and change nothing. Consequences for
this one subcommand, unlike every other contacts write:

- It **launches Contacts.app** in the background (`open -g -j`), hidden and
  without focus, and leaves it running. AppleScript's own `launch` verb is not
  enough — the event fails with `-600` before it takes effect.
- It may need **Automation access for Contacts**; the error says so if it does.
- It re-reads the membership afterwards and fails loudly if the contact is
  still in the group, rather than trusting the exit code.

⚠️ **Multi-value flags replace, they don't append.** Passing `--email` on `edit`
replaces *every* existing email on that contact. Read the contact first and
re-pass the ones to keep.

⚠️ **`--note` is not writable, by construction.** Reading a note works, but
writing needs the `com.apple.developer.contacts.notes` entitlement, which Apple
grants only to signed apps on request — no CLI can hold it. Notes are read
straight from the AddressBook SQLite store instead. Note edits must happen in
Contacts.app.

⚠️ **`delete` is permanent.** Unlike Notes there is no Recently Deleted, and the
deletion syncs everywhere. Always confirm with the user first. Deleting a
*group* keeps its contacts; removing a member keeps the contact too.

`get` reports a contact's `groups`; `search` and `list` don't, because Contacts
has no reverse lookup and it would mean scanning every group per contact.

## Layout

```
bin/apple                 dispatcher — routes to the tools below
swift/                    one Swift package, four binaries
  Sources/reminders/      + RemindersLibrary/
  Sources/AppleMail/
  Sources/AppleCalendar/
  Sources/AppleContacts/  + Notes.swift (SQLite note reader)
  Tests/RemindersTests/
notes/                    Python; apple-notes, notestore.py, notestore.proto,
                          tests/ (live Notes.app suite)
docs/apple-notes-api.md   NoteStore schema, AppleScript API, verified bugs
Formula/apple-tools.rb    Homebrew formula
VERSION                   CalVer YY.MMDD.Patch, stamped in by scripts/set-version
```

`apple-notes` is the only Python tool left; stdlib-only, runs on the system `python3`.

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

The `tests/` suites drive the real binaries against real data, each behind its
own flag:

```
./tests/run-tests              # calendar writes (25 tests)
./tests/run-tests --mail       # + mail drafts (19)
./tests/run-tests --contacts   # + contacts writes (28)
```

Contacts fixtures have `__claude_contacts_test__` as their **exact** first name
and the sweep refuses anything else — contact writes sync everywhere and cannot
be undone, so never loosen that to a prefix match. Set `APPLE_CONTACTS_BIN` to
run against a specific binary; TCC grants are per path, so the copy you just
built may not be the approved one, and an unapproved one hangs on XPC rather
than failing cleanly.

## Permissions

Each tool needs a one-time TCC grant, prompted on first run **from a terminal**:

| Tool | Grant |
|------|-------|
| reminders | Privacy & Security → Reminders |
| calendar | Privacy & Security → Calendars |
| mail | Privacy & Security → Automation → Mail |
| contacts | Privacy & Security → Contacts |
| notes | Full Disk Access for the calling terminal (reads sqlite directly) |

If a tool reports an access error, the fix is for the **user** to run it once in
their own terminal and approve the dialog; an agent cannot click through it.

**Grants belong to the tool, not the terminal** (reminders, calendar, contacts).
Each of those re-executes itself disclaimed — `posix_spawn` with
`responsibility_spawnattrs_setdisclaim` — so TCC attributes the request to the
binary rather than to the terminal that launched it. Practical consequences:

- They work identically from any terminal, IDE, or multiplexer. Don't suggest
  "try a different terminal"; that is not the variable it once was.
- Each appears in System Settings under its own name (`apple-contacts`, not
  `Ghostty`). Tell the user to look for the tool, not their terminal.
- A `brew upgrade` **may** re-prompt, and may not: 26.727.8 → .9 did, .9 → .10
  did not, at a new Cellar path both times. Rebuilding in place never has. Treat
  a fresh prompt after an upgrade as normal rather than as a bug, and don't
  promise either way.
- An already-working grant skips the re-exec entirely, so this is invisible when
  everything is set up.

`mail` and `notes` are *not* covered by this: Automation and Full Disk Access
are still attributed to the calling terminal, so those two really do depend on
which terminal is running.

⚠️ **macOS only prompts when the status is `notDetermined`.** Once it is anything
else the request returns silently and no dialog ever appears. The trap is
Calendar's `writeOnly` ("Add Only") state: it looks granted, but cannot read
events, and macOS will not offer to upgrade it. `apple calendar status` reports
the real state without prompting — run it before concluding a grant is missing.
The remedy is always a manual toggle in System Settings, never a retry.
