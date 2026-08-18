# apple-tools

CLIs for reading and writing local Apple app data: Notes, Mail, Messages, Phone,
Maps, Reminders, Calendar, Contacts. Everything runs locally against the user's real data — no
sync service, no API keys.

🛑 **One exception, and it is opt-in: geocoding.** `apple maps geocode`,
`apple reminders --at` and `apple calendar --at` resolve a place name through
Apple Maps, which is a network call. Nothing else in the repo makes one. It
lives in its own `Geocoding` target so the dependency stays visible, and
`apple maps geocode --local-only` refuses it outright.

## Quick reference

All tools are reachable through the `apple` dispatcher, or directly by name if
installed via `make install`.

| Task | Command |
|------|---------|
| Search notes | `apple notes search "budget" --json` |
| Read a note | `apple notes export 261` |
| Delete a note | `apple notes delete 261` |
| List note folders | `apple notes folders --json` |
| List call recordings | `apple notes recordings --json` |
| Find a recording by what was said | `apple notes recordings "apple watch" --transcripts` |
| Transcript of a call recording | `apple notes transcript 11426` |
| Summary of a recording | `apple notes summary 11426 --json` |
| Search mail | `apple mail search "invoice" --json` |
| Full-text mail search | `apple mail search "budget" --field content --json` |
| Read an email | `apple mail export <message-id>` |
| Save an attachment | `apple mail attachments <message-id> --save ~/Downloads` |
| Start an email (user pastes) | `apple mail compose --to a@b.com --subject "…" --body "…"` |
| File mail into a mailbox | `apple mail move <message-id>… --to Receipts --dry-run` |
| Reply to an email | `apple mail reply <message-id> --body "…"` |
| Draft with a file attached | `apple mail compose --to a@b.com --attach ~/r.pdf --body "…"` |
| List mail accounts | `apple mail accounts --json` |
| List conversations | `apple messages chats --json` |
| Search messages | `apple messages search "dinner" --json` |
| Read a conversation | `apple messages export 8 --limit 50` |
| Recent calls | `apple phone recents --json` |
| Who called while out | `apple phone recents --missed --since 7 --json` |
| Callers not in Contacts | `apple phone recents --unknown --since 30 --json` |
| Blocked callers | `apple phone blocked --json` |
| Place a call | `apple phone dial "Alice"` |
| Where do I actually go | `apple maps places --min-visits 5 --json` |
| When was I last there | `apple maps places --search "costco" --json` |
| Recent arrivals | `apple maps visits --since 14 --json` |
| List saved guides | `apple maps guides --json` |
| Places in one guide | `apple maps guides "Boulder Playgrounds" --json` |
| Coordinate for a place | `apple maps geocode "costco" --json` |
| Remind me when I get there | `apple reminders add Errands "Milk" --at "costco, superior co"` |
| Event with a real map pin | `apple calendar add "Lunch" --start … --at "4800 Baseline Rd, Boulder"` |
| Today's reminders | `apple reminders show-all --due-date today --include-overdue --json` |
| Add a reminder | `apple reminders add Soon "Buy milk" --due-date "tomorrow 9am"` |
| Tag a reminder | `apple reminders add Inbox "Bake sale" --tag PTA` |
| Retag an existing one | `apple reminders edit Inbox 3 --add-tag PTA` |
| Everything tagged PTA | `apple reminders show-all --tag PTA --json` |
| What did I finish? | `apple reminders show Inbox --only-completed --json` |
| This week's events | `apple calendar events --days 7 --json` |
| Add an event | `apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45` |
| Recurring meeting | `apple calendar add "Board" --start … --repeat monthly --on-the "4th monday"` |
| Fix a stale meeting link | `apple calendar edit <id> --url ""` |
| See who is invited | `apple calendar events --days 7 --json` → `attendees`, `organizer`, `my_status` |
| Did that write reach the server | `apple calendar sync-status <id>` |
| Everything the server never took | `apple calendar unsynced` |
| See the guest list (read-only) | `apple calendar invitees <id>` |
| Invite someone (sends mail) | `apple calendar invite <id> --add a@b.com --dry-run` |
| Move one occurrence | `apple calendar edit <id> --occurrence 2026-09-21 --start "2026-09-21 14:00"` |
| Find a person | `apple contacts search "smith" --json` |
| Update a contact | `apple contacts edit <id> --company "New Co"` |
| Who is this person linked to | `apple contacts relations <id>` |
| Link two contacts | `apple contacts link <id> <id> --relation spouse` |
| Move a contact between accounts | `apple contacts move <id> --to "iCloud" --dry-run` |
| Export contacts | `apple contacts export --group "Family" -o family.vcf` |
| List contact accounts | `apple contacts containers --json` |

**Every tool supports `--json`.** Prefer it — the plain output is for humans and
its shape is not stable. Use `apple --which` to see which binary each name
resolves to.

**Check permissions before diagnosing an access failure.** `apple status`
reports all eight in one table, never prompts, and exits non-zero if anything is
unusable:

```
apple status            # table, plus advice for anything broken
apple status --json     # {tool: {status, usable, advice, pane, granted_to}}
```

The table is a ✓/✗ per tool; anything failing gets a line naming the exact state
(`denied`, `writeOnly`, `notDetermined`, `mailNotRunning`) and the fix. The JSON
carries that per tool, plus `granted_to`: `tool` means the grant follows the
binary and works from any terminal, `terminal` means it belongs to whatever
launched it — so never suggest switching terminals for a `tool` one. Each tool
also answers `status` on its own.

## Rules

1. **`--json` for anything you parse.** Plain-text layouts change; JSON keys don't.
2. **Reads are free, writes are not.** `notes export`, `mail search`, `contacts
   search/get/list`, `calendar events`, `reminders show*`, and every `phone`
   subcommand except `dial` only read. Anything that creates, edits, completes,
   or deletes touches the user's real data — confirm with them first unless they
   clearly asked for the write. `notes delete` asks the user itself and refuses
   without a tty unless given `--yes`; do not reach for `--yes` to skip a
   conversation the user has not had. Contacts writes sync to every device and there is
   no undo. `phone dial` places a real, billable call: Phone.app will ask the
   user to confirm, and that panel is theirs to click, never yours. `mail move`
   refiles real mail and syncs everywhere — show the user `--dry-run` output
   before running it for real.
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
Markdown: `**bold**`, `_italic_`, `==highlight==`, `~~strike~~`,
`[text](url)`, headings, lists, checklists, and **tables**.

🛑 **`font_weight` is an enum, not a weight**: 1 bold, 2 italic, **3 both**. A
reader testing `== 1` for bold loses it on every weight-3 run.

**`export` reads table cells, not just a placeholder.** A table's contents are
not in the note body at all — the body holds one U+FFFC and the cells live in
the attachment row's `ZMERGEABLEDATA1` blob, the same column call recordings
use. `export` decodes it and emits a GitHub pipe table. Measured: 76 of 76
tables on this store decode, and the one that comes out empty really is an
empty 2×2 in Notes.app.

- ⚠️ **Notes has no header row and Markdown demands one, so row 1 is
  promoted.** For a table whose first row is data that changes the meaning, and
  the output alone cannot tell you which happened.
- ⚠️ **A newline inside a cell collapses to a space**, and a `|` is escaped.
  Both are needed to keep the pipe table parseable, and both are lossy.
- 🛑 A note link inside a cell has an attachment row with a **NULL `ZNOTE`**, so
  nothing joins it to the note it visibly sits in. `get_note_tables` decodes
  once to learn which identifiers the cells use, then looks them up and decodes
  again.
- **What is not read**: column widths and `crTableColumnDirection`.

**A cell renders like a paragraph**: `**bold**`, `==highlight==` and
`[text](url)`. Reading only the cell's text made `export` call a bold cell plain
while calling a bold paragraph bold. ⚠️ Highlight in a cell is covered by a unit
test only — all 40 coloured runs in cells here are link blue or near-black.

**Links now render inline, everywhere.** Three mechanisms carry one, and all
three used to be dropped or mangled:

- **A URL on text** (`AttributeRun.link`) — 297 runs in bodies, 264 in cells.
  ⚠️ 88 body links have the URL as their own text, so those stay bare rather
  than becoming `[url](url)`.
- **A note link** as an inline attachment — 126 in bodies, 15 in cells, with
  the target in `ZTOKENCONTENTIDENTIFIER`. 🛑 Both mechanisms are in use for
  note links; handling one alone leaves most of them broken.
- **A hashtag, mention or inline calculation** — 101 more. 🛑 None is an
  attachment in any useful sense, and `[attachment: #trips]` was wrong for all
  227. They render as their own text now.

🛑 **Not every link value is a link the user made.** `x-apple-data-detectors` is
Notes recognising a date or an address, and `x-coredata` is an internal row
reference. Both are refused. ⚠️ `ZTOKENCONTENTIDENTIFIER` is likewise not always
a URI — a hashtag stores a bare word — so only values that parse as one become
links.

**Source text is escaped so it cannot read as a marker.** `\` and `*` always;
`=` only beside another `=`; `_` only outside a word. 🛑 `[` and `]` are
deliberately left alone — they only form a link beside a `](`, which no note in
the store contains.

🛑 **`split("\n")` misses the line breaks a renderer honours.** Notes writes
U+2028 for Shift-Return (254 here) and `\r` survives in pasted text, so a bold
span crossing one used to be unbalanced on both halves. Every marker now closes
at each of them and reopens after. Over the whole store, split the way a
renderer splits: **58 unbalanced bold lines before this work, 0 after.**

Traps in the blob itself are in
[`docs/apple-notes-tables.md`](docs/apple-notes-tables.md). All four produce a
wrong table rather than an error.

```
apple notes search [TERM] [--limit N] [--json] [--include-locked]  # title search
apple notes folders [NAME] [--limit N] [--json]  # all folders, or notes in one folder
apple notes export ID [-o out.md]                # note body as Markdown
apple notes get-url ID [--json]                  # applenotes:// deep link
apple notes recordings [TERM] [--calls-only] [--transcripts] [--limit N] [--json]
apple notes transcript ID [-o FILE] [--no-timestamps] [--words] [--json]
apple notes summary ID [--json]                  # Apple's generated summary
apple notes create [--title T] [--body TEXT | --body-file FILE|-] [--json]
apple notes append ID  [--body TEXT | --body-file FILE|-] [--json]
apple notes delete ID  [--yes] [--wait SECONDS] [--json]   # -> Recently Deleted
apple notes install-shortcuts [--force]          # install the write path
apple notes status [--json]                      # access + write-path state
```

**Writes go through Shortcuts, and the CLI hides that.** `create` and `append`
take a body as `--body`, `--body-file FILE`, `--body-file -`, or a bare pipe — and the tool picks the payload shape and file
extension the underlying shortcut needs. Markdown becomes native structure:
`- [ ]` and `- [x]` are real checklists with their checked state, pipe tables
are real tables.

`append` is a genuine append: it **preserves attachments and existing
checklists**, unlike the AppleScript body write. Pinned by
`notes/tests/test_append.py`, which checks that a checklist keeps its checked
state across an append.

🛑 **No target means no append.** The shortcut matches the note by *Name*, and
a name matching nothing does **not** fail — Shortcuts lists every note in a
picker and waits, then writes the text to whatever the human picks. Measured:
four queued appends all landed on a note chosen minutes later, while the note
the caller named sat in Recently Deleted.

⚠️ **Nothing after the fact reveals this.** `shortcuts run` returns in ~2s with
exit 0 while the picker is still open. Timing cannot distinguish a picker from
a permission dialog either. So `append` refuses **before** running: the target
must be a live note, outside Recently Deleted, whose title matches it and
nothing else. It also still refuses an ambiguous title rather than appending to
every match.

`ID` accepts a numeric note ID, a note title, or an `applenotes://` URL.

**Search is title-only.** There is no full-text search over note bodies; to
search content, export candidates and grep them.

**Call recordings and voice memos have their own two commands**, because none of
what you want is in the note body. 🛑 **`export` on a recording returns an
attachment placeholder and nothing else** — no transcript, no summary — and the
note's snippet and modification date never change when transcription lands, so
polling any of them waits forever. All of it lives in the attachment's
`ZMERGEABLEDATA1` blob.

```
apple notes recordings        # table: id, when, length, both handles, summary
apple notes transcript ID     # speaker-attributed, timestamped turns
apple notes summary ID        # the line Notes.app shows as "Preview"
```

**`recordings` is the discovery command** — there is no other way to find them,
since note titles are all "Call Recording" and search is title-only. It scans
every mergeable-data attachment and keeps the ones that decode as audio, so it
finds voice memos and imported files too; `--calls-only` narrows to real calls.
A bare listing **skips the per-word decode**, which is most of the cost.

**Search matches handles, titles and summaries — not what was said.** Add
`--transcripts` to search the words too (0.36s for this whole store, and it
scales with total recorded audio). A query is an AND of substring terms, the
same semantics as `mail search`.

🛑 **LENGTH is the recording, not the call, and the gap can be large.** Recording
is started by hand at any point. Measured here: a 29-minute outgoing call
produced a 14m53s recording that began 14 minutes in, whose **first transcribed
word is 1:33 into the recording** because the rest was hold. Call length,
recording length and speech length are three different numbers.

⚠️ **Hold time and IVR leave no segments at all** — not silence markers, simply
absent. The first segment's timestamp is the only sign, and it is not zero.

⚠️ **Direction is not recorded.** `callType` is reported raw (`0` on the one call
here) and nothing infers incoming/outgoing from it. That is why the columns are
`YOU`/`OTHER PARTY`, not `FROM`/`TO`. `apple phone recents` does know, but the
stores do not join cleanly: the recording starts mid-call, so neither start time
nor duration matches.

- ⚠️ **Segments are per-word** (2,228 for a 15-minute call) and stored in **CRDT
  insertion order, not reading order** — the decoder sorts on timestamp.
  `--words --json` exposes the raw segments; the default groups them into turns.
- **Speaker attribution is Apple's**, per word, so overlapping speech renders as
  genuine interruption. `You` is resolved from `callLocalSpeakerHandle`.
- ⚠️ **Only call recordings have speakers.** A voice memo or imported audio
  transcribes with no speaker on any segment and gets no name prefix — that is
  correct, not a failed lookup. `is_call` in the JSON says which you have.
- ⚠️ **A recording with no transcript is normal**, not a decode failure:
  transcription is on-device Apple Intelligence, and a device without it (or an
  unsupported language) records audio only. Both commands say so and exit 1.
- **`summary` is often absent while `topLineSummary` is present.** The JSON
  carries both; the plain output prints whichever exist.
- 🛑 **The audio bytes are not reachable through any command here.** `transcript`
  reads the store; to get the `.m4a` itself, copy it out of
  `~/Library/Group Containers/group.com.apple.notes/Accounts/<uuid>/Media/`.

Full record — the 0-based indices, the undocumented `ObjectID` double field, the
Unix-epoch start time, and the two incompatible word tokenizations — in
[`docs/apple-notes-transcripts.md`](docs/apple-notes-transcripts.md).

**`delete` moves a note to Recently Deleted, and needs no Shortcut.** AppleScript
`delete` has always worked, and the test harness has used it since the suite was
written — so this costs no build, no signing step and no third permission
dialog. It does need **Automation → Notes** for the calling terminal, and it
**launches Notes.app** if the app is closed. Reads need neither.

🛑 **It addresses the note by primary key, not by name.** An AppleScript note id
is `x-coredata://<Z_METADATA.Z_UUID>/ICNote/p<Z_PK>`, and that UUID is in the
same file the reader already opens — verified equal to the id Notes reports. So
`delete` never hands Notes a name to match, and the note-picker trap that
governs `append` cannot arise here at all.

🛑 **A partial title is refused, unlike `export`.** `find_note` falls through to
`LIKE '%term%'` and returns the **first** row it finds, which is right for a read
and destructive for a delete: `delete budget` would remove whichever note sqlite
happened to return first, silently. A title here must match in **full**, must
name a **live** note, and **more than one match is refused** listing the ids.

⚠️ **It asks before it deletes.** Without a tty it refuses unless you pass
`--yes`, because a pipe is not consent. Answering anything but `y` exits
non-zero, so a cancel never reads as a delete.

🛑 **Confirmation goes through Notes.app, not the store — the opposite of every
other write here.** The sqlite store lags an **unbounded** amount: measured on
this machine, one delete appeared in sqlite in **3.5s** and another was still
sitting in `ZFOLDER` = `Notes` **more than ten minutes** after Notes.app already
listed it in Recently Deleted. A store read alone cannot tell a slow delete from
a failed one, so it must not decide.

- **`confirmed` is Notes.app's answer**, in about 0.7s, and it is the field to
  read. **`store_confirmed` is sqlite's**, reported separately for a caller that
  goes on to read the store; `--wait` gives it longer, and defaults to 0.
- ⚠️ **`container of note id …` distinguishes nothing.** It fails with **-1728**
  for a deleted note *and* for a live one. Enumerating the Recently Deleted
  folder and asking for the id is what works.
- **A note still in its folder afterwards is a hard failure.** `osascript`
  exiting 0 is not evidence the note moved, the same way `shortcuts run` exiting
  0 is not evidence a note was written.
- ⚠️ **The folder moves; `ZMARKEDFORDELETION` stays 0.** Measured on every
  delete here. Both are checked, since the reverse can appear mid-sync.

⚠️ **A locked note is refused with exit 2.** Its body cannot be read, so the user
cannot be shown what they are about to destroy. Delete it in Notes.app.

⚠️ **`apple notes search` still lists a deleted note**, because the reader can
see Recently Deleted. A search straight after a delete therefore looks like a
failure and is not; the command says so on stderr. Deletion is recoverable for
about 30 days, and **there is no API to empty that folder**.

**Writes need `install-shortcuts` first.** `apple notes status` reports whether
the write path is available and names anything missing; until then Notes is
read-only.

🛑 **Installed is not the same as allowed, and an unallowed shortcut fails
silently.** `shortcuts run` against a shortcut with no permission grant **exits
0, prints nothing, writes nothing, and raises no dialog** — so every layer above
it read success. Observed on macOS 27.0 build 26A5406e with
`ZACCESSRESOURCEPERMISSION` empty for both shortcuts; the docs' write path was
verified on build 26A5388g.

Three things reported success for a write that did nothing, all now fixed:

- **`status` said "shortcuts installed (2)"** and called the write path
  available. It now reads the grants out of `ZACCESSRESOURCEPERMISSION` and
  reports `unauthorized` per shortcut. ⚠️ An unreadable Shortcuts library is
  **unknown**, not denied — it must not invent a refusal.
- **`create` exited 0** having created nothing, with the only signal a
  `"created": false` field nobody checks. Both `create` and `append` now exit
  non-zero and name the likely cause.
- **`create`/`append` ran the shortcut at all.** They refuse up front when no
  grant exists, since running is pure loss.

⚠️ **`shortcuts run`'s exit code proves nothing about whether the shortcut did
anything.** Confirm every write by re-reading the store, the way `apple
calendar` and `apple contacts` do.

`APPLE_NOTES_SHORTCUTS_DB` points the grant reader at a different library, which
is how `notes/tests/test_write_path.py` covers all of this offline. 14 tests;
13 of them fail against the code before this fix.

🛑 **What the Markdown write path supports is measured, generated, and
checked — never assumed.** The matrix lives in
[`docs/apple-notes-markdown-support.md`](docs/apple-notes-markdown-support.md),
generated from `notes/tests/markdown_cases.py`:

```
./notes/capability-report            # measure and rewrite the doc
./notes/capability-report --check    # exit 1 if any answer moved
```

**Run `--check` after every macOS update.** `notes/run-tests` runs it too, so a
change in Apple's interpreter fails the suite. It reports two independent
columns per construct — what **Apple stored** (the API surface) and what our
**reader gives back** — because a construct can survive the write and be lost
on the read. That is exactly what happened to italic and strikethrough.

Measured on 26A5406e: everything works except **`==highlight==`** and
**`` `code` ``**, which Apple ignores, plus **`- [X]`** and **`* [x]`**, which
do not make checklists. ⚠️ **`#` becomes the *title* style, not a heading.**
⚠️ **Apple drops bold inside link text.**

⚠️ **Do not hand-probe these answers.** Three wrong conclusions came out of
doing that.

🛑 **A pipe table destroys the last item of the list directly above it.** The
item becomes a plain paragraph. It applies to bullets and checklists alike,
whatever the checked state. Put one paragraph between the list and the table.

⚠️ **The gotchas below are about the AppleScript write path, which is the wrong
tool for most writes.** It cannot create a checklist at all, and its only body
write is a full replace that destroys attachments and flattens checklists.
**Shortcuts can do all of it** — a genuine append that preserves attachments and
checklist state, and Markdown interpreted into native structure, in ~0.3s. It
costs a one-time install and permission grant per shortcut. See
[`docs/apple-notes-shortcuts.md`](docs/apple-notes-shortcuts.md); build scripts
in `notes/shortcuts/`.

**Gotchas** (each locked by a live test in `notes/tests/`, full detail in
[`docs/apple-notes-api.md`](docs/apple-notes-api.md)):

- 🛑 **Editing `body` destroys attachments.** What survives depends entirely on
  the embedded object's type — **45% of a real store (427 of 939 notes) carries
  one**, so check before any edit:
  - **tables** (`com.apple.notes.table`) survive **for free** — they live in the
    HTML, so keep the `<table>` markup in the body you write. Dropping it
    deletes the table.
  - **images** survive only if you **harvest and re-add** them: they appear as
    `<img src="data:image/png;base64,…"/>`, and re-attaching the decoded bytes
    is byte-exact. Costs: filenames are lost, images move to the end.
  - **drawings** and **Paper docs** appear as flat PNGs, so the picture can be
    recovered but flattens to `public.png` — the strokes are gone.
  - **PDFs, text files and scans** are invisible in `body` and **unrecoverable**.
  🛑 Do not put a `data:` URI back in the body — see below.
- 🛑 **A body write flattens every checklist into a plain bulleted list**, losing
  which items were ticked. A real checklist comes back from `body` as a bare
  `<ul><li>` with no checkbox information at all, so it cannot be written back —
  unrecoverable, invisible (it still looks like a list), and it applies to the
  innocuous append pattern too. 7% of notes here (48 of 672) have one.
- ⚠️ **Writes need a second grant.** Reads use SQLite (Full Disk Access); every
  write goes through AppleScript, which needs **Automation → Notes** for the
  calling terminal and **launches Notes.app** if it is closed. `apple status`
  currently reports only the read grant.
- ⚠️ **A shared note pushes to other people**, not just your other devices, and
  there is no undo. Check `ZSERVERSHAREDATA` before writing.
- `set body` is a **full replace**, never a merge.
- The **first line becomes the title**, silently, on every body write.
- `delete` is a **soft delete** — the note moves to Recently Deleted and
  auto-purges in ~30 days. There is no API to empty that folder.
- The SQLite reader **can see Recently Deleted notes**. Filter them out if the
  user asked for live notes.
- **Locked notes are skipped by default.** A password-protected note has no
  readable body (`ZDATA` is NULL) and no decrypt path. `search`/`folders` omit
  them and say so on stderr; `--include-locked` lists them as `locked: true`.
  `export` refuses with **exit 2** (distinct from 1, "not found"); `get-url`
  still works, since Notes.app prompts for the password itself.
- `make new attachment` **double-inserts** on macOS 27 — one attachment record,
  referenced twice, so the user sees the file twice. Deleting the surplus
  immediately (`if (count of attachments of n) > EXPECTED then delete last
  attachment of n`) fixes it **for images**. For a PDF it is a no-op and the
  duplicate is unfixable.
- 🛑 **`count of attachments` is blind to PDFs** — it returns 0 for a note that
  holds one, and `attachments of n` enumerates nothing, while the file sits on
  disk byte-exact. Never treat a count of 0 as "no attachments". **Verify writes
  through the SQLite store** (count `￼` in the decoded text, check for the file
  under `Accounts/`), not through AppleScript.
- **Attaching a PDF errors on reading the id back** (`-1728, Can't get attachment
  id`). The attachment is created; only the id read fails, and the id is in the
  error text.
- 🛑 **Writing a `data:` URI into `body` stores nothing** — it creates an empty
  `public.data` attachment (0 bytes, no file) at the right position. There is no
  way to place an attachment mid-note; everything lands at the end.

Stdlib only — `notestore.py` decodes the gzipped-protobuf note body directly,
so no virtualenv is involved.

### mail — `apple mail`

🛑 **This tool never writes a message body, and that is the whole design.**
Setting a body through AppleScript wraps it in `<blockquote type="cite">` (Apple
FB11734014) — invisible to the sender, rendered as a quotation by iOS Mail and
Gmail. It cannot be fixed after the fact: rewriting the `.emlx` corrects the file,
and the file is not what the composer opens, so the wrapper returns the moment the
draft is reviewed. A whole compose surface was built on that rewrite and removed
in 26.810.0 when it was measured.

So `compose`, `reply` and `forward` **open a Mail window with everything filled in
except the body**, put the body on the pasteboard, and stop. The user presses ⌘V
and ⌘S. Full record in [`docs/apple-mail-drafts.md`](docs/apple-mail-drafts.md).

Reads go to Mail's own SQLite index and the `.emlx` files on disk, so they work
with Mail.app closed and return in milliseconds.

```
apple mail accounts [--json]      # names, addresses, mailboxes, enabled
apple mail search QUERY [--account NAME] [--mailbox NAME] [--field subject|sender|content|all]
                        [--since DAYS] [--before DAYS] [--limit N]
                        [--flagged] [--unread] [--has-attachment] [--attachment-names]
                        [--all] [--json]
apple mail export MESSAGE-ID [--account NAME] [--json] [--raw]
apple mail attachments MESSAGE-ID [--save DIR] [--skip-inline] [--account NAME] [--json]

apple mail compose --to ADDR [--cc ADDR] [--bcc ADDR] [--subject TEXT]
                   [--from|--account ACCOUNT-ADDRESS] [--body TEXT | --body-file FILE|-]
                   [--markdown | --html] [--attach FILE]... [--json]
apple mail reply MESSAGE-ID [--all] [--body TEXT | --body-file FILE|-]
                 [--markdown | --html] [--attach FILE]... [--account NAME] [--json]
apple mail forward MESSAGE-ID --to ADDR [<same flags as reply>]

apple mail move MESSAGE-ID... --to MAILBOX [--from MAILBOX] [--account NAME]
                [--dry-run] [--mark-read] [--json]     # `-` reads ids from stdin

apple mail delete-draft MESSAGE-ID [--account NAME] [--json]
apple mail status [--json]
```

**Composing hands off to the user, and that is not a failure.** Each command
opens the window, loads the pasteboard and prints `press ⌘V, then ⌘S`. It never
saves a draft itself, so there is no `message_id` to report — the JSON says
`status: "awaiting_paste"`. Tell the user to paste; do not describe the mail as
sent or saved.

**Mail does everything except the body**: recipients, subject, sending account,
`In-Reply-To`/`References`, the quoted original, and **attachments carried over by
a forward** — the last of which is why forwarding is left to Mail rather than
rebuilt. Verified: a forwarded message came out 184 KB with its attachment intact.

**`--attach FILE` is the one part of a draft the tool writes itself.** Repeatable,
on all three commands. The files are **already in the window** when it opens —
only the body is left to ⌘V — so the JSON reports them under `attachments`
(`name`, `path`, `bytes`) while `status` stays `awaiting_paste`.

It is allowed where the body is not because the cite-blockquote wrapper comes
from *assigning* to `content`; `make new attachment` adds an element without
assigning. 🛑 **Do not seed `content` with a newline first** — that is the usual
recipe and it is exactly the wrapper. Attaching to an empty body works directly.

- 🛑 **`count of mail attachments` cannot verify this.** On an outgoing message
  it fails with **-1728** ("Can't get every mail attachment of outgoing message
  id N") rather than returning 0 — same blindness `apple notes` has to PDFs.
  What works is counting **U+FFFC** in `content`, one per attachment, and
  asserting the **delta** across the attach — a forward already carries the
  original's attachments, and they are U+FFFC too.
- ⚠️ **A mismatch is a hard error naming the shortfall**, because a window is
  already open in front of the user: "Mail took 1 of 2 attachments … add the
  missing files by hand before sending."
- **Every path is checked before any Apple Event** — missing file, directory,
  unreadable, or the same file twice all exit 64 with nothing opened. They are
  also checked *before the body reaches the pasteboard*, so a bad `--attach`
  cannot silently replace what the user had copied.
- Attachments totalling over 20 MB get a stderr note, not a refusal; the limit
  belongs to the receiving server.

**Verified by hand in a matched pair (26.812.0):** two windows, same body, one
with `--attach` and one without, both pasted and saved. Identical output —
`<b>`/`<i>` intact in both, **no cite-blockquote around the body in either**. So
attaching first does not degrade the pasted formatting. ⚠️ Mail does wrap the
*attachment placeholder* in a cite blockquote, but a style-neutralised one
containing only the Apple-proprietary `<object>`, with the body entirely outside
it — that is Mail's layout structure, not FB11734014. How a recipient renders it
is untested, since nothing here sends.

**Bodies may be `--markdown` or `--html`; both become RTF on the pasteboard.**
Markdown gives real bold, italic, links and bullets. 🛑 RTF is deliberate: **HTML
on the pasteboard makes Mail insert the body twice.** A plain `--body` is taken
literally, so prose containing `*` or `_` survives as written.

⚠️ **`send` does not exist and will not.** It composed without a window, so there
is nowhere to paste, and every message it ever sent carried the wrapper. When the
user wants mail sent, draft the text and let them send it from Mail.app.

🛑 **You cannot reply to a draft** — a draft has no sender, and handing one to
Mail's `reply` verb wedged Mail during development. Refused off the index, before
any Apple Event, along with an unknown Message-ID, a forward with no recipients,
and a missing body. Each refuses in under 0.25s.

All three read commands take `--engine auto|filesystem|applescript`. Leave it
alone; `auto` uses the files. `--engine filesystem` fails loudly instead of
falling back, which is what you want when diagnosing.

Measured on a 41k-message store, same binary, same query, Mail running:
`--engine filesystem` 0.04s, `--engine applescript` 154s.

🛑 **The AppleScript engine is the thing that wedges Mail, so `auto` no longer
drifts into it.** Driving Mail with a whole-mailbox predicate is how Mail's
scripting interface stops answering — permanently, until it is restarted, for
every client on the machine. So:

- **`search` never falls back.** Without Full Disk Access it reports the missing
  grant and stops. It used to warn on stderr and drive Mail anyway, which turned
  "grant missing" into "Mail wedged". Ask for the old path deliberately with
  `--engine applescript` if you really want it.
- **`export` still falls back**, because reading a body Mail hasn't downloaded is
  a real reason to ask Mail — but only when Mail is *already running and
  answering*.
- **No read command launches Mail.** If Mail is closed, every AppleScript path
  refuses rather than cold-starting it and handing it a mailbox query.
- **Every AppleScript read is bounded twice.** A wall-clock deadline on the
  child process — one health probe (5s), searches 60s, the export walk 300s —
  after which `osascript` is killed rather than left driving Mail; and a
  `with timeout` *inside* the script, set 5s under that, so the interpreter
  abandons the Apple Event and exits on its own with a clean -1712 instead of
  being SIGKILLed mid-request. `APPLE_MAIL_PROBE_TIMEOUT` /
  `APPLE_MAIL_SCRIPT_TIMEOUT` override the outer one and the inner one follows.
- ⚠️ **A timeout is never swallowed into a short result.** The search script
  wraps its walk in `try` so that a missing mailbox — not every account has an
  `Archive` — is skipped rather than fatal. That handler re-raises -1712 and
  swallows everything else, because a timeout returning whatever it had
  accumulated reads as a complete search and is instead one that stopped
  partway against a Mail that is going under.
- **`--field content`, `--field all` and `--has-attachment` are refused on the
  AppleScript engine** (exit 64), because each makes Mail open every message body
  in the mailbox. They are free on the index — the refusal is about the engine,
  not the query.

⚠️ **Killing our `osascript` does not call off the work Mail already started.**
The deadlines stop *us* hanging and stop us queueing more events; they are not a
way to un-wedge Mail. Only restarting Mail.app does that.

**`apple mail status` answers "is Mail wedged?"** — `mail_app.running` and
`mail_app.responsive` in the JSON. `responsive` is only present when Automation
is already authorized and Mail is up, because probing otherwise would trigger
the consent dialog `status` exists to avoid. `responsive: false` means the
AppleScript export fallback will not work until Mail is restarted.

🛑 **`AEDeterminePermissionToAutomateTarget` blocks for minutes against a wedged
Mail, then answers wrongly** — and it is how the Automation grant is read without
side effects. Measured: `AECreateDesc` returned in 0.000013s, the permission call
returned **-600 (`procNotFound`) after 502 seconds**, with Mail running at a known
pid throughout. `askUserIfNeeded: false` stops it *prompting*, not *blocking*, and
it runs before any of the deadline machinery, so `APPLE_MAIL_PROBE_TIMEOUT` never
reached it.

It is bounded now (3s, on a detached queue, since the call cannot be cancelled)
and reports **`automation: "unknown"` with `responsive: false`** — a permission
check that will not answer is itself proof Mail is not servicing Apple Events, and
a more accurate answer than the one the API eventually gives. Read `automation:
"unknown"` as "Mail is wedged", not as a grant problem.
⚠️ `apple-messages status` makes the same call for Messages.app and is not
bounded yet; it has never been observed hanging, because nothing scripts
Messages.

**Searching is cheap — search widely.** No `--limit`/`--since` discipline is
required, and there is no timeout to trip. The default covers every mailbox
except trash and junk (`--all` adds those).

**`--field content` is real full-text search** over decoded message bodies, and
is the one mode that opens files. It finds text inside base64 and
quoted-printable parts that a raw `grep` over `~/Library/Mail` cannot see.
`--field all` means subject, sender *and* body.

It walks newest-first and stops as soon as `--limit` is filled, so a normal
search reads a small fraction of the store — but a term with **fewer matches
than `--limit`** has to read everything, because there is no way to know the
next match does not exist without looking. On a 40k-message store:

| Search | Bodies read | Time |
|---|---|---|
| any `--field subject` / `sender` | **0** | 0.04s |
| `--field content invoice --limit 20` | 768 | 0.2s |
| `--field content <no matches>` | 39,976 | 9.8s |
| ...`--since 90` | 1,521 | 0.39s |
| ...`--mailbox inbox` | 15 | 0.03s |

`--since`, `--mailbox`, `--account`, `--unread`, `--flagged` and
`--has-attachment` all narrow the candidate set **in SQL, before any file is
opened**, so they are the lever for a body search that is taking too long. The
scan depth is always reported on stderr (`note: scanned N message bodies of M
candidates`) — a full scan is never silent.

**A query is an AND of terms.** `budget review` matches messages containing
both words anywhere, in any order — not the literal string. Double-quote to
require adjacency: `"budget review"` is one phrase. On a real store the
difference is `budget review` → 346 results, `"budget review"` → 0. Terms may
land in different fields under `--field all`: one in the subject, another in the
body.

⚠️ **Matching is substring, not word-boundary.** `quarter` matches inside
`quarterly` and `headquarters`; there is no stemming, no relevance ranking (the
order is by date), and no boolean operators beyond the implicit AND.

**Attachments are not searched at all by default** — not their contents, and
not their filenames. A search for "invoice" should find messages *about*
invoices, not every message that happens to carry an `invoice.pdf`. Pass
`--attachment-names` to also match filenames; it comes from the index, so it
costs nothing. Attachment **contents are never searched**, with or without the
flag: a `text/*` part marked `Content-Disposition: attachment` is skipped, and
non-text parts (PDF, images) are never decoded. There is no PDF text
extraction. To read an attachment, save it with `apple mail attachments` and
open it yourself.

`export --raw` writes the RFC 822 source; `export --json` gives structured
headers, recipients, attachment names and body. Both need the file-system
engine.

**Getting the files out.** `export` reports attachment *names*; `attachments`
gets the bytes. Listing shows name, content type and size; `--save DIR` writes
them, creating the directory and printing each path. `--skip-inline` drops
images the HTML body references, leaving the paperclip ones.

⚠️ **Attachment bytes are not in the `.emlx`.** Mail strips them out, leaving
the MIME part with an empty body and an `X-Apple-Content-Length` header, and
writes the file *already decoded* to
`Data/<digits>/Attachments/<rowid>/<mime-part>/<filename>`. Parsing the message
alone yields zero-byte attachments — the command reads the directory and falls
back to embedded bytes only for messages that really carry them.

**What counts as an attachment is Mail's rule: a part with a filename.**
Verified against its index — a message with two nameless tracking pixels
reports zero attachments, one with seven named inline images reports seven.

🛑 **`attachments` and `export --json` do *not* always agree, and a draft built
by `--attach` is where they part.** Mail references a scripted attachment from
the HTML by `cid:`, so it reads back as *inline*: `apple mail attachments`
reports `1 … (inline)` while `export --json` gives `[]` and the index says `0`,
for a draft that really does carry the file. **Use `apple mail attachments` when
the question is "did the file make it".**

`--save` never overwrites: a name that already exists gets `-2` before the
extension. Filenames come from the sender, so they are sanitised to a bare
basename before being joined onto `DIR`, and a write that would land anywhere
else is refused.

See [`docs/apple-mail-store.md`](docs/apple-mail-store.md) for the schema, the
`.emlx` layout, and the traps in reading them.

⚠️ **`accounts` is the one read command that still prefers Mail.app**, because
only Mail knows whether an account is `enabled`. It asks Mail when Mail is
already running and reads the store when it is not — rather than launching Mail
just to list accounts. It also reads the store when Mail is running but *not
answering*, so a wedged Mail costs you the `enabled` field rather than hanging
the command. Consequence: **the file-system answer has no `enabled` key**, so
read it as `account.get("enabled", True)`. It also lists the local "On My Mac"
store, which the AppleScript path omits.

**`move` files received mail into another mailbox, and it is the one write path
here that touches real mail.** Built for sweeps: filing what arrived before a
filter rule existed, or rescuing what was filed wrongly. It takes many
Message-IDs at once, and `-` reads them from stdin, so it is the tail of a
pipeline:

```
apple mail search "receipt" --mailbox inbox --json | jq -r '.[].id' \
  | apple mail move - --to Receipts --dry-run
```

🛑 **`whose id is <rowid>` is why this command is allowed to exist, and it must
stay that way.** Every message is resolved against the index first, and Mail is
handed an exact id in a named mailbox — never a walk over `messages of
<mailbox>`, which is the pattern that wedges its scripting interface. Measured
on the 37,220-message Archive here: **0.9s, and identical for the newest and the
oldest message in the mailbox**, so Mail resolves it from an index rather than by
scanning. The AppleScript *search* engine takes 154s over the same store. A
batch of 8 moved in 0.9s end to end.

🛑 **Mail's AppleScript `id of message` *is* the Envelope Index ROWID.** Verified
against a live store — `first message of <mailbox> whose id is <rowid>` returned
the matching `message id` header every time, including for the oldest message in
a 37k mailbox. This is the join that makes an index-resolved move possible; the
Message-ID header would work as a predicate too, but nothing else gives Mail an
indexed integer to look up.

- **`--dry-run` sends Mail nothing at all.** It resolves and prints the plan off
  the index alone. Run it first; these moves sync to every device.
- **Partial failure never aborts the batch.** Each message reports `{id, moved,
  confirmed, error}`; the exit code is 1 if any failed. A whole chunk lost to a
  timeout is charged to every message in it, because Mail may have moved some
  before it stopped answering.
- **Every move is confirmed against the index**, by the copy *appearing in the
  destination* — not by it leaving the source, which takes minutes (see
  copy-then-expunge below). `confirmed: false` with `moved: true` means Mail
  reported success the index could not corroborate.
- **`--mark-read` marks each message read as it moves**, matching what a
  server-side filter rule does when it files something. Set before the move,
  while the reference is still valid.
- **Drafts are refused** — a draft's Message-ID changes when it is edited, so a
  sweep would act on the wrong message. Use `delete-draft`.
- A Message-ID with copies in several mailboxes moves **all** of them, each
  reported separately. Narrow with `--from` or `--account`.
- Destinations are per-account and **nothing is created**. `--to trash` resolves
  to `Deleted Messages` on IMAP, `Deleted Items` on Exchange and `[Gmail]/Trash`
  on Gmail, so one command works across accounts.

🛑 **A nested mailbox must be named by its full path, and `accounts` prints the
leaf.** Mail rejects `mailbox "All Mail"` outright (**-1728**) and accepts
`mailbox "[Gmail]/All Mail"`. `move` resolves a leaf name to the full path for
you — path match first, then leaf, then the alias table — but anything else
driving Mail has to know. Ambiguous leaves are refused rather than guessed, and
both errors quote paths.

🛑 **Custom IMAP keywords are not on this Mac, so no tool here can expose them.**
Searched for exhaustively: the `messages` table carries only `flags`/`read`/
`flagged`/`deleted`, the `labels` and `server_labels` tables are Gmail
labels-as-mailboxes (3 rows on this store), and the `.emlx` trailer plist holds
only Mail's own flag bitfield. A `grep -ril` for a keyword known to be set
server-side across all of `~/Library/Mail` returned **zero hits**. Mail discards
them on sync — this is not a gap in the reader. Anything keying off an IMAP
keyword has to run server-side.

**`delete-draft` only ever moves a draft to trash.** It enumerates Drafts alone, so it cannot touch sent or received mail
even if handed the Message-ID of some. It re-reads the mailbox afterwards and
fails loudly rather than trusting the move, and it is a move to **trash, not a
purge** — same as Notes' Recently Deleted, with no API to empty it.

- **Only one route removes a draft**, and `delete-draft` implements it. Mail's
  `delete` verb silently does nothing, its `move` verb errors, and `set deleted
  status` fails with "Connection is invalid". Reassigning `mailbox of <message>`
  to the account's trash **does** work — which is also what `apple mail move`
  uses for received mail. The trash mailbox is named differently per account type
  (`Deleted Messages`, `Trash`, `Deleted Items`), so it tries each.
- 🛑 **Re-resolve the Message-ID before calling it.** A draft's Message-ID
  **changes when the draft is edited and saved**, and has been observed changing
  with no edit at all on IMAP sync. A stale id fails with exit 64, and an
  `export` of one silently produces an *empty file* rather than an error. Look
  the draft up by subject first: `apple mail search "" --mailbox drafts --json`
  and use the `id` field.

⚠️ **A mailbox move is copy-then-expunge**, so the source copy survives until
the server expunges it (~2 min on IMAP). `delete-draft` and `move` both say so
on stderr; a re-listing before then still shows the message in its old mailbox,
and that is not a failure. It is also why both judge success on the copy
*arriving* rather than on the original leaving.

**Mailbox names are not unique** — three accounts can each have an `Archive`.
Every result carries both `account` and `mailbox`; use the pair. Account names
can contain emoji and spaces — get exact strings from `apple mail accounts`
rather than guessing.

⚠️ **A message can be in the index but not on disk** when Mail hasn't downloaded
the body. `export` says so explicitly rather than reporting the message missing,
and `auto` falls back to AppleScript, which can still fetch it — provided Mail is
already running and answering. With Mail closed it reports that instead of
launching it.

⚠️ **The timeout trap applies only to `--engine applescript`, and is an error
rather than a silent one.** AppleScript's event timeout is ~120s, and the script
used to swallow it, so `search` printed `[]` and exited 0 — indistinguishable
from "no matches". A timeout now fails loudly, whether it is Mail's -1712 or our
own deadline, including one that hits partway through a multi-account walk. The
file-system engine never had this mode: it either answers or errors.

`--field` defaults to `subject`; use `--field all` or `--field content` when the
user describes content rather than a subject line. `--all` widens the search to
trash and junk, which are excluded by default — except when `--mailbox trash`
asks for them by name, which is honoured.

**`APPLE_MAIL_INDEX_PATH`** points the index reader at a specific file, or at a
path that doesn't exist to see what a command does without Full Disk Access. The
error names the variable, so an unreadable override never masquerades as a
missing grant.

### messages — `apple messages`

Reads `~/Library/Messages/chat.db` directly, the same way mail reads the
Envelope Index. Works with Messages.app closed; a whole-store search over
103k messages takes ~0.1s. **Read-only today** — there is no send path yet.

```
apple messages chats [SEARCH] [--limit N] [--json]   # conversations, recent first
apple messages search QUERY [--chat REF] [--handle H] [--since DAYS] [--before DAYS]
                            [--limit N] [--from-me] [--to-me] [--has-attachment]
                            [--include-events] [--json]
apple messages export CHAT [--limit N] [--include-events] [-o FILE] [--json]
apple messages attachments CHAT [--save DIR] [--skip-stickers] [--limit N] [--json]
apple messages status [--json]
```

`CHAT` accepts a numeric id from `chats`, a chat GUID, a group name, a phone
number, or an email. **An ambiguous reference is an error, not a guess** — it
lists the candidate ids and exits, because exporting the wrong conversation is
a mistake you notice much later.

**Search semantics are identical to mail's**, deliberately: a query is an AND of
substring terms, `dinner friday` matches both words in any order, double quotes
require adjacency. No stemming, no ranking, no boolean operators.

🛑 **The body is in two columns, and `text` is not always the one.** About 4% of
a long-lived store has `text IS NULL` and keeps the body in `attributedBody` as
an archived `NSAttributedString`. On a 103,250-message store that is 4,227 rows,
of which **1,921 are ordinary messages with real words in them**. A reader doing
`SELECT text` drops them silently — it looks like gaps in the history, not a
bug. `apple messages` decodes them and marks the result `text_from_archive` in
JSON.

The format is a NeXT **typedstream** (`04 0B "streamtyped"`), not
`NSKeyedArchiver`, so `NSKeyedUnarchiver` cannot read it and `NSUnarchiver` is
unavailable to Swift. The decoder was verified against the 99,023 rows that
carry *both* columns: **99,022 exact matches (99.999%)**. The one difference is
a `U+FFFD` stored in the blob where `text` kept the real emoji — which is why
`text` wins when present.

⚠️ **Not every text-less row is a message.** The rest are group/system events
(1,517), tapbacks and edits (259), app messages such as link previews and
ScreenTime (218), and attachment-only messages (178). Each is classified in the
`kind` field rather than printed as a blank line. **System events are excluded
by default**; `--include-events` adds joins, leaves and renames.

⚠️ **Handles are phone numbers and emails, never names.** Resolving a person
means Contacts, which is a separate tool and a separate grant. Cross-reference
with `apple contacts search` yourself; `apple messages` reports the raw handle.

⚠️ **Group chats are usually unnamed** — 2 of every 3 on a real store. The
`title` falls back to the participant list, so it is a display string, not an
identifier. Use the numeric `id` to refer to a conversation.

⚠️ **RCS is a third service**, alongside `SMS` and `iMessage` (plus
`SatelliteSMS`). Code that treats anything non-iMessage as SMS mislabels it.

**Attachments are already decoded on disk**, unlike mail's — `attachments
--save DIR` copies them, no MIME parsing involved. But iCloud offloads them, and
a row whose file is gone is reported `missing` rather than saved empty. `--save`
never overwrites; a clashing name gets `-2` before the extension.

Dates are Apple-epoch **nanoseconds** in modern rows and whole **seconds** in
pre-10.13 ones; both coexist and the reader sniffs the magnitude. Timestamps of
`0` mean unset, not 2001.

See [`docs/apple-messages-store.md`](docs/apple-messages-store.md) for the
schema, the typedstream layout, and why searching the two body sources needs two
queries rather than one.

### phone — `apple phone`

Reads `CallHistory.storedata` directly, the same way messages reads `chat.db`,
and resolves caller names out of the AddressBook stores under the same grant.
Works with Phone.app closed. **Read-only except `dial`.**

```
apple phone recents [--limit N] [--since DAYS] [--before DAYS]
                    [--missed | --incoming | --outgoing] [--unknown] [--blocked-only]
                    [--kind phone|facetime-audio|facetime-video] [--handle H] [--json]
apple phone search QUERY  <same filters>            # name, number, or place
apple phone stats  <same filters> [--json]          # counts, talk time, top callers
apple phone blocked [--json]                        # read-only
apple phone recordings [--json]                     # signpost → `apple notes`
                                                    #   (alias: transcripts)
apple phone dial TARGET [--facetime-audio] [--dry-run] [--json]
apple phone status [--json]
```

`recents` is the default subcommand, so `apple phone` alone lists recent calls.

**Names are the whole point.** `ZNAME` in the store is empty (1 row of 289), so
every caller is resolved against Contacts and reported with a `name` and a
`known` flag. `--unknown` narrows to callers you have not saved, which is the
short path from "who called me yesterday" to `apple contacts add`.

🛑 **Blocking a caller is impossible, and the API lies about it.** The
`CommunicationsFilter` C functions are reachable by `dlopen` from an unsigned
binary and *appear* to work — `CreateCMFItemFromString` returns the right
dictionary — but the XPC to `cmfsyncagent` needs
`com.apple.private.communicationsfilter`, and it is **denied silently**:
`CMFBlockListIsItemBlocked` returns `false` for a number that is demonstrably on
the list. So there is no `block` command; one would report success and change
nothing. `blocked` reads the list, and `recents` flags callers already on it.
Signing and notarising the tool would not change this — private entitlements need
`platform-application`. Block in Phone.app or System Settings instead; the iPhone
is what filters relayed calls anyway.

🛑 **Voicemail is not on this Mac at all.** No local store exists (`ZHASMESSAGE`
is `0` on every row), `vmd` does not exist on macOS, and `vmshow://` needs a UUID
nothing local can enumerate. `voicemail-*.m4a` files under
`~/Library/Messages/Attachments` are ones people *forwarded over iMessage*, not
an inbox. There is nothing to list and nothing to mark read.

🛑 **Call recordings are not here either — they belong to `apple notes`.**
`apple phone recordings` (alias `transcripts`) is a **signpost that prints where
to go and exits** — it reads nothing and proxies nothing, deliberately, so it can
never imply a call and a recording are the same object. An
iPhone call recording syncs as a *note*, and its audio, transcript and summary
live in that note's attachment blob, so nothing in `CallHistory.storedata`
references one. Use `apple notes recordings`. ⚠️ **The two stores do not join
cleanly**: recording is started by hand partway through a call, so the recording
is shorter than the call and starts later, and neither timestamp nor duration
matches. A number dialled repeatedly makes even an interval match ambiguous.
Do not report a call and a recording as the same object without saying how the
match was made.

**`dial` hands a `tel:` URL to Phone.app and Phone.app always asks you to
confirm** — skipping the prompt needs `com.apple.FaceTime.NoPrompt`, an
Apple-internal entitlement. That prompt is the gate, so there is no `--confirm`
flag; and the tool will never click the panel for you. Use
`--dry-run` to see the URL without placing anything. `TARGET` may be a number, an
Apple ID, or a contact name — a name resolves against the address book, prefers
the number that person most recently used, and an ambiguous name is an error
rather than a guess.

⚠️ **This is a relay mirror, not full history.** Four months here against an
iPhone that keeps years. Say "recents", never "all calls".

**Traps** (each pinned by a test in `swift/Tests/PhoneTests/`, full detail in
[`docs/apple-phone-store.md`](docs/apple-phone-store.md)):

- 🛑 **`ZDATE` is Apple-epoch *seconds*; `chat.db` is nanoseconds.** Sharing a
  converter between the two is wrong by 10⁹ and still yields a plausible date.
- 🛑 **`ZDATE` is a `REAL`, so comparing it to `strftime('%s',…)` text matches
  nothing** — no error, just an empty result indistinguishable from "no calls".
  Bind a double. This broke `--since` on the first attempt.
- 🛑 **`ZANSWERED` means "answered by me", so it is `0` on every outgoing call.**
  Treating it as "connected" reports everything you dialled as missed. Connected
  is `ZDURATION > 0`, which is orthogonal to direction.
- ⚠️ **`ZADDRESS` is unnormalised** — `8005551212`, `18005551212`,
  `+13035551212` and an Apple ID all coexist. Match on trailing 10 digits.
- 🛑 **Never open the AddressBook stores with `immutable=1`.** Contacts leaves a
  3 MB write-ahead log, and `immutable=1` does not replay it — so a contact added
  minutes ago is invisible and its caller is reported as plainly `unknown`. The
  handle count also moved 1367 → 1365 once the log was replayed, because it
  carries deletions too: the immutable snapshot was stale in *both* directions.
  Plain read-only open first, `immutable=1` only as a fallback. (`NoteStore` in
  `AppleContacts` did the same thing until 26.812.8, and the latency was not
  theoretical: it could not see a note written seconds earlier, so `contacts
  move`'s "this contact has a note" refusal never fired. Fixed the same way,
  which also means `get --json` now reports a fresher note.)
- 🛑 **Opening a SQLite file validates nothing.** `sqlite3_open_v2` never reads
  the header, and sqlite treats a **0- or 1-byte file as a valid empty
  database** — so a truncated address book looks like "opened, no contacts" and
  silently reports every caller as unknown. Probe for the expected *schema*.
- **Contact resolution has three states, not a boolean**: `available`,
  `noAddressBook` (nothing to read — correct and silent), and `unreadable` (a
  grant problem). `--unknown` **refuses** in the last case, because with an
  unreadable address book every caller would match and the whole store would come
  back looking like an answer. `--json` **omits `known` entirely** there rather
  than emitting `false`, and sets `contacts_unavailable: true`.
- **A missing address book is not an error.** Call history still reads; only
  names go missing.

`--json` keys: `status` (`outgoing`/`incoming`/`missed`), `kind`, `handle`,
`number`, `duration`, `connected`, `known`, `blocked`, `name`, `contact_id`,
`location`, plus `call_type` so an unrecognised type is visible rather than
hidden behind `kind: "unknown"`.

### maps — `apple maps`

Reads `MapsSync_0.0.1` directly, the same way phone reads
`CallHistory.storedata`. Works with Maps.app closed. **Read-only, and it will
stay that way** — see below.

```
apple maps places [--since DAYS] [--before DAYS] [--search TEXT]
                  [--min-visits N] [--limit N] [--json]   # default subcommand
apple maps visits [--since DAYS] [--before DAYS] [--search TEXT] [--limit N] [--json]
apple maps guides [GUIDE] [--search TEXT] [--places] [--json]
apple maps status [--json]
```

`places` is the default subcommand, so `apple maps` alone lists where the user
goes, most-visited first. `visits` is the same data one arrival at a time.

⚠️ **This is Maps' "Visited Places", not Significant Locations.** Significant
Locations belongs to `routined`, under `/var/db/locationd/`, which no
unprivileged process can read (`~/Library/Caches/com.apple.routined/` does not
exist either). They are different features with different retention. **Never
report one as the other.**

🛑 **Nothing here writes, and nothing here should.** CloudKit mirrors this
store — 1,936 `NSCKRecordMetadata` rows — and Core Data triggers maintain
denormalised counters on it (`ZCOLLECTION.ZPLACESCOUNT`,
`ZVISITEDLOCATION.ZLATESTVISITDATE`). A direct write would fight the sync
engine. There is also no fallback to fall back *to*: Maps.app ships **no
AppleScript dictionary at all** (`sdef` prints nothing), and its five App
Intents only drive navigation — `StartNavigationIntent`,
`UpdateNavigationIntent`, `MapsShowPlacesInAppIntent` and two test intents.
Reading the file is the only route.

🛑 **A place is a location row that has a visit, and the raw table overcounts
badly.** 123 of the 314 `ZVISITEDLOCATION` rows here carry **no `ZVISIT` at
all** — duplicates of places that already have a visited row, three of them for
"Ocean First" alone, each with a NULL `ZLATESTVISITDATE`. Counting that table
reports **314 places where the honest answer is 191**, a 64% overcount in the
flattering direction. `places` joins through `ZVISIT`; `status` prints the
orphan count so the gap is visible rather than inferred.

🛑 **`ZHIDDEN` is NULL, not 0, on every row** — 440 of 440 visits and 314 of 314
locations. So `ZHIDDEN = 0` matches **nothing** and the command returns an empty
history, which reads exactly like "you have never been anywhere". Only
`IS NOT 1` covers NULL and 0 together. Pinned by a test.

⚠️ **A visit records a start time and nothing else.** There is no end time in
the schema, so this store **cannot say how long the user stayed** anywhere. Do
not report a duration from it.

⚠️ **`ZVISITCLASSIFICATION` is undocumented and reported raw.** Two values
appear — `1` on 389 visits and `3` on 51 — and the `3` visits sit at places that
also have `1` visits, so it belongs to the arrival rather than the place.
Nothing names it, so the JSON carries the number and no label.

**Guides are the richest thing in the store.** 18 here, holding 126 saved
places: `Boulder Playgrounds` with 21 named parks and street addresses,
`Kings Ridge Apple trees` with 19, plus one trip guide per work trip since 2020.

- 🛑 **Places come through `Z_7PLACES`, never off `ZCOLLECTIONITEM`.** 12 of the
  126 item rows belong to no guide — the same orphan pattern the locations show
  — so listing that table invents saved places the user cannot see in Maps.app.
- **The join is genuinely many-to-many.** One place here sits in two guides.
- ⚠️ **An ambiguous guide name is an error naming the candidates**, not a guess.
  `guides "chicago"` matches three on this store. Same rule `apple messages`
  uses for a chat reference.
- **A renamed place keeps both names.** `ZCUSTOMNAME` is set on 122 of 126
  items and wins; `map_item_name` appears in JSON only when the two differ.

**Categories are `||`-joined, most specific first** —
`Dining||American Cuisine||Restaurant` — and `--json` reports both the split
`categories` array and `category` for the first. `ZMAPITEMTOPLEVELCATEGORY` is a
separate integer enum that nothing local names, so it goes through raw.

**`geocode` turns a name into a coordinate, and answers locally first.**

```
apple maps geocode "costco"                      # a place you have been: no network
apple maps geocode "Union Station Denver"        # falls through to Apple Maps
apple maps geocode "costco" --local-only         # refuse the network
apple maps geocode "costco" --network-only       # skip your own places
```

- **The local answer is usually the better one**, not just the cheaper one.
  "costco" means the branch the user goes to, not whichever branch Apple ranks
  first. A visited place already carries a coordinate, so nothing is geocoded.
- 🛑 **The network fallback is the only part of apple-tools that leaves the
  machine.** It lives in its own `Geocoding` target so a dependency on it is a
  decision. `--local-only` refuses it.
- **A Maps search is biased to where the user has recently been**, taken from
  the median of their own visit coordinates. Nothing asks Location Services
  where they are. Measured: `geocode costco --network-only` returns Superior,
  Longmont and Thornton; the same query `--near "Seattle, WA"` returns Seattle
  and Kirkland.
  ⚠️ The **median**, not the mean — one trip abroad drags a mean into the ocean.
- **`--json` carries `at`**, a `"Name@lat,lon"` string ready to hand to
  `apple reminders --at` or `apple calendar --at`. That is the composed path,
  and it is what keeps the place's name on the reminder.
- **`source` and `network` say where an answer came from**: `visited-place`,
  `guide-place`, `maps-search`, `address-lookup` or `coordinate`. Read
  `network`, never infer it from `source`.

**Every place carries a real coordinate**, unlike a `--location` written by
`apple calendar`, which gets a structured location with no `geoLocation`. So
`apple maps` is the one tool here that can hand you a latitude and longitude for
a place the user has actually been, without touching the network.

Traps in the file itself — the Apple-epoch seconds (against `chat.db`'s
nanoseconds), the `REAL` column that never matches a text comparison, the WAL
that `immutable=1` will not replay, and the `ZMAPITEMSTORAGE` protobuf — are in
[`docs/apple-maps-store.md`](docs/apple-maps-store.md). `APPLE_MAPS_DB_PATH`
overrides the path, and the test suite builds its own store so it runs offline.

**Six tables are read; five more hold data nothing reads yet**:
`ZHISTORYITEM` (32 rows: searches, directions, dropped pins — and Maps prunes
it, 189 created against 32 kept), `ZUSERROUTE` (3 custom hikes with geometry),
`ZFAVORITEITEM` (14), `ZREVIEWEDPLACE` (56) and `ZINCIDENTREPORT` (32).

### reminders — `apple reminders`

Swift + EventKit. Full CRUD. Fork of `keith/reminders-cli` with editing and
recurrence added.

```
apple reminders show-lists [--json]
apple reminders show LIST [--due-date DATE] [--include-overdue]
                          [--include-completed | --only-completed] [--tag TAG]...
                          [--sort none|creation-date|due-date] [--json]
apple reminders show-all [--due-date DATE] [--include-overdue]
                         [--include-completed | --only-completed] [--tag TAG]... [--json]
apple reminders add LIST "TEXT" [--due-date DATE] [--priority high|medium|low|none]
                                [--notes TEXT] [--repeat daily|weekly|monthly|yearly]
                                [--repeat-interval N] [--repeat-until DATE] [--repeat-count N]
                                [--tag TAG]...
apple reminders edit LIST INDEX ["NEW TEXT"] [--due-date DATE] [--priority P] [--notes TEXT]
                                [--tag TAG]... [--add-tag TAG]... [--remove-tag TAG]...
apple reminders complete LIST INDEX
apple reminders uncomplete LIST INDEX
apple reminders delete LIST INDEX
apple reminders new-list NAME
```

`--due-date` takes natural language: `today`, `tomorrow 9am`, `next friday`,
`2026-12-25`.

**Location reminders — "remind me when I get there" — go on `add` and `edit`.**

```
apple reminders add Errands "Buy milk" --at "Costco, Superior CO"
apple reminders add Errands "Call back" --at "39.96,-105.17" --on leave --radius 250
apple reminders edit Errands 3 --clear-location
```

`--at` takes a place name, an address, a `"lat,lon"` pair, or the
`"Name@lat,lon"` form that `apple maps geocode --json` emits as `at`. `--on` is
`arrive` (default) or `leave`. `--radius` is metres, default 100. `--near`
biases the Maps search.

- 🛑 **A name or address means a network call**, the only one `reminders` makes.
  A `"lat,lon"` pair touches nothing.
- 🛑 **`reminders` cannot read the Maps store, so it cannot resolve a place from
  the user's own history.** It re-executes itself disclaimed so the Reminders
  grant follows the binary, and **a disclaimed process loses the terminal's Full
  Disk Access** — measured with a probe that read `MapsSync_0.0.1` fine as a
  plain process and got "you don't have permission" once disclaimed. To pin a
  reminder to the branch the user actually goes to, compose the two tools:

  ```
  AT=$(apple maps geocode costco --json | jq -r '.[0].at')
  apple reminders add Errands "Buy milk" --at "$AT"
  ```

  That resolves locally, with no network call, and carries the name through.
- ⚠️ **A structured location with no coordinate triggers nothing**, while still
  showing a name in Reminders.app. So a failed lookup refuses rather than
  saving a location that looks right and never fires.
- ⚠️ **Ambiguity is refused, not guessed.** A shop name matching branches more
  than 250 m apart is an error listing them.
- **The location alarm sits alongside a time alarm** rather than replacing it,
  so "at 9am, or when I get there" is one reminder. `--clear-location` removes
  only the location alarms and leaves any due-date alarm intact.
- ⚠️ **`show --json` reports `locationTitle` and `location`** on a reminder that
  has one. `location` is the coordinate pair as a string, not an address.

⚠️ `INDEX` is the position shown by `show`, and it **shifts** as items complete or
get added. Always `show` immediately before `complete`/`edit`/`delete`.

`--format json` still works as a synonym for `--json`.

**Tags — the `#PTA` chips — have no public API, and this is the one place the
tool reaches past EventKit.** Not EventKit (every "tag" symbol there is a sync
ETag), not AppleScript (the string appears in Reminders' sdef zero times). Writes
go through private `ReminderKit`, resolved at runtime, needing no extra grant
beyond the Reminders one. Full record in
[`docs/apple-reminders-tags.md`](docs/apple-reminders-tags.md).

- `--tag` on **`add`** sets the tags; on **`edit`** it **replaces** the whole set,
  matching how multi-value flags behave in `apple contacts`. `--add-tag` /
  `--remove-tag` change them one at a time, and combining the two styles is
  refused rather than guessed.
- **`--tag` on `show`/`show-all` filters instead** — the same flag name means
  "write this" on a write command and "match this" on a read one, as `--tag` has
  no other sensible reading there. Repeating it is an **AND**
  (`--tag PTA --tag urgent` is reminders carrying both), matching what multiple
  terms mean in `apple mail`. Matching is case-insensitive.
- ⚠️ **The index survives filtering.** Filtering happens *after* the index is
  assigned, so what `show --tag PTA` prints is each reminder's position in the
  whole list and stays valid for `edit`/`complete`/`delete`. The indices are not
  1..n of the filtered view.
- **There is no `search` subcommand**, and `--tag` is the only content filter.
  To match on title text, pipe `--json` through `jq`.
- 🛑 **A tag is invisible to EventKit and does not touch the title.** Measured: a
  tagged reminder's title comes back byte-identical, with no `#PTA` in it. So a
  `PTA: ` title prefix and a real tag are **not** interchangeable, and nothing
  converts one to the other. `show`/`show-all` read tags from the private store
  and report them as `tags` in JSON (absent when there are none) and as `#tag`
  in plain output.
- 🛑 **A tag containing a space is silently rewritten, not rejected.** `two words`
  stores as `twowords`, and the save reports success. Refused up front, naming
  the substitute. A leading `#` is refused too — it is punctuation the app adds
  when rendering, so storing it yields `##PTA`.
- ⚠️ **Matching is case-insensitive, display case is kept.** Reminders keys tags
  on a lowercased `canonicalName`, so adding `pta` to something already tagged
  `PTA` is a reported no-op.
- ⚠️ **Tagging is a second write through a different framework.** On `add` the
  reminder exists before tagging can fail, and the error says so — read
  "tagging failed" as "created but untagged", not as "nothing happened".
- Every tag write is **read back from a fresh store** and fails naming what did
  not land, the same discipline `apple calendar` and `apple contacts` use.
- ⚠️ If macOS ever moves the private API, tags degrade to unavailable — `--tag`
  refuses with an explanation and everything else keeps working. The documented
  fallback is Shortcuts' `is.workflow.actions.setters.reminders`, which works but
  can only find a reminder **by title**.

### calendar — `apple calendar`

Swift + EventKit. Read and write events.

```
apple calendar calendars [--writable] [--json]
apple calendar events [--from DATE] [--to DATE | --days N] [--calendar NAME]
                      [--search TEXT] [--json]         # default: next 7 days
apple calendar show ID [--occurrence DATE] [--json]
apple calendar add "TITLE" --start DATE [--end DATE | --duration MINUTES]
                          [--calendar NAME] [--all-day] [--location TEXT]
                          [--notes TEXT] [--url URL] [--invitee ADDR]... [--json]
apple calendar edit ID [--title T] [--start DATE] [--end DATE] [--location L]
                       [--notes N] [--url URL|""] [--occurrence DATE | --series] [--future] [--json]
apple calendar invitees ID [--occurrence DATE | --series] [--json]   # read-only
apple calendar invite ID [--add ADDR]... [--remove ADDR]...
                       [--occurrence DATE | --series] [--future] [--dry-run] [--json]
apple calendar delete ID [--occurrence DATE | --series] [--future]
apple calendar status [--json]                # report permission state, never prompts

apple calendar sync-status ID [--json]        # did this one write reach the server
apple calendar unsynced [--calendar NAME] [--json]   # everything that did not
apple calendar sync-errors [--json]           # what Calendar recorded and hid
apple calendar resync ID [--dry-run] [--force] [--json]   # rebuild a stuck event
```

🛑 **`add` and `edit` used to report success for a write the server refused.**
EventKit saving is local; the push happens afterwards, so `store.save` returning
says nothing about the server. Measured 2026-08-18: `add` returned a full,
populated event record and exit 0 for a write Google CalDAV refused with **HTTP
403**. The event sat in the local store forever and never reached the server.
Calendar.app surfaced it hours later, by which time the caller had told the user
it was on their calendar.

**Both commands now confirm the server took the write before printing anything.**
On by default. Measured round trip: **4.2s on calDAV, 3.1s on Exchange.**
`--no-confirm-sync` opts out, `--sync-timeout` defaults to 30s. `add --json` and
`edit --json` carry a `sync` object; `events --json` deliberately does not, since
the answer costs a SQLite lookup per event.

- **Read `confirmed`… read `sync.state`.** `synced` means the server has it.
  `pending` at the deadline exits non-zero. `notApplicable` means there is no
  server to reach. `unknown` means the tool could not check, which is **never**
  reported as a failure.
- ⚠️ **These four commands read `Calendar.sqlitedb`, which needs Full Disk
  Access** — a different grant from the Calendar one everything else uses. Without
  it the answer is `unknown`, and a good write must not be called broken.

🛑 **`external_mod_tag` is the obvious signal and it is wrong.** Exchange never
populates the ETag — **172 of 172 items**, including one written and confirmed
synced during this work. A check keyed on it calls a healthy Exchange account
100% broken. `external_id` is the only column that works on both backends.

🛑 **A bare "empty `external_id`" scan reports 468 healthy events.** Three filters
close that, each measured:

| filter | rows it drops | why they are not unsynced |
|---|---|---|
| `orig_item_id = 0` | 329 | detached CalDAV occurrences never get an `external_id` |
| store type in (1,2) | 139 | generated stores have no server — 138 Birthdays, 1 Siri |
| `disabled = 0` | 0 today | 10 of 16 stores here are switched-off accounts |

⚠️ **`orig_item_id` is `0` for a normal item, not NULL.** `IS NOT NULL` matches
every row and reports the whole store as detached occurrences.

🛑 **An edit cannot be confirmed by `external_id`** — the create already set one,
so a presence check returns `synced` instantly for an edit the server never saw.
`edit` snapshots before it saves. On calDAV the ETag moves (`"63922751442"` →
`"63922751478"` at t+4s). ⚠️ **On Exchange nothing moves at all**: no ETag,
`external_id` byte-identical, `sequence_num` and `modified_properties` unchanged.
So an Exchange edit reports **`unknown` with the reason**, never `synced`.

🛑 **The join is `(unique_identifier, calendar_id)`.** `unique_identifier` alone is
not unique — 64 values are shared here, one naming three rows, because an
Exchange meeting syncs into several Google calendars. ⚠️ A detached occurrence
carries `/RID=<seconds>` in **both** the EventKit id and the store column, so it
must not be stripped.

**`resync` rebuilds an event the server never accepted.** EventKit stops retrying
an item once it records an `Error` row, and re-saving does not re-push it; the
only repair that worked was rebuilding. Verified on a real event: coordinate,
notes, URL, start and end all came across, the copy synced in 4.1s, the original
went, and no duplicate was left.

- 🛑 **The copy is created BEFORE the original is deleted**, so a failure leaves
  two events rather than none. Same rule `apple contacts move` follows.
- 🛑 **Build a fresh `EKStructuredLocation`; never assign the original's.** One
  belongs to a single event, and reusing it fails the save with "Object not
  found. It may have been deleted." Measured — the copy was never created, and
  only the create-first ordering kept it from losing the event.
- **A recurring event is refused, even with `--force`** — a rebuild collapses
  every detached occurrence back onto the rule. An event with invitees is
  refused without `--force`, because a rebuild mails everyone a fresh invitation.
- ⚠️ **The new event gets a new identifier.**

⚠️ **`Error` rows are transient.** The table is empty on this machine, yet
`sqlite_sequence` puts its high-water mark at **1304** — they are written and
then cleaned up. So `sync-errors` only helps inside a window, and an empty result
is not proof everything synced.

🛑 **The 403 could not be reproduced, and that is the limit of this work.** 90
writes here and 33 in another session all synced:

| burst | calendar | result |
|---|---|---|
| 25 sequential in 2s | Personal (owned) | 25/25 synced in 5s |
| 40 parallel in 1s | Personal (owned) | 40/40 synced in 5s |
| 25 parallel in 1s | Family (delegated) | 25/25 synced in 10s |

So `resync` is verified on healthy events only. Whether a rebuilt item escapes a
poisoned account is **untested**. A second reported failure mode — the local copy
*deleted* with an empty `Error` table — was not reproduced either, and is why
`unsynced` matters alongside `sync-errors`.

⚠️ **A calendar's owner is readable and did not explain the bug.**
`Calendar.external_id` holds the CalDAV path, so a path carrying another
account's address is a delegated calendar; `self_identity_email` is the user's own
address on every row and distinguishes nothing. 7 of 9 enabled calDAV calendars
here are delegated. Writing to one syncs fine.

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

🛑 **`--location` is text and gets no map pin; `--at` is the flag that does.**
EventKit keeps the coordinate on a separate `EKStructuredLocation`, and only
that coordinate produces a map thumbnail or a travel-time alert. A location
written by `--location` gets a structured location carrying **the title and
nothing else**.

```
apple calendar add "Bagels" --start "tomorrow 9am" \
    --at "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO"
```

`--at` resolves the place through Apple Maps and sets the coordinate itself,
then sets `location` to the resolved address. **This is a network call** — the
only one `apple-calendar` makes. `--pin-radius` sets the geofence size,
`--near` biases the search, `--clear-pin` removes the coordinate while leaving
the location text alone.

⚠️ **`--location` still never geocodes, deliberately.** A location that is not a
place — "Zoom", "my desk", a room name — must not be silently turned into a
coordinate somewhere else in the world. Ask for a pin explicitly.

Measured on 2026-08-16, across 517 real events: 166 carry location text, all 166
carry a structured location, and only **68** carry a coordinate. 64 of those 68
are multi-line, which is Apple's picker format; three of the four single-line
ones end in `, USA`, which is Google's.

- **Nothing geocodes a string after the fact**, which is why `--at` has to do it
  at write time. Not EventKit on save, not the calDAV server on sync, and not
  Calendar.app on display — real street addresses have sat in this store for
  months with no coordinate. A probe event re-read at creation, from a fresh
  store, and after 150s of sync never gained one.
- **Verified in a matched pair on 2026-08-16**, same address, two events:
  `--location "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO 80303"` gave
  `has_coordinate: false`; `--at` on the same address gave `has_coordinate:
  true` at `39.9976725,-105.233365`, read back from a fresh store. Before `--at`
  existed the only route was Calendar.app's address picker.
- **`events`/`show --json` report `geo`** (`title`, `latitude`, `longitude`,
  `radius`, `has_coordinate`), and omit the key entirely when the event has no
  structured location. `location` alone cannot tell a geocoded address from a
  typed one; they read identically. **`has_coordinate` is how you check a
  `--at` write landed.**
- ⚠️ **Ambiguity is refused, not guessed.** A shop name matching branches more
  than 250 m apart is an error listing them, because pinning a meeting to the
  wrong branch is a mistake nobody notices until they drive there. Narrow it
  with `--near`, or pass `"lat,lon"`.
- A URL in `--location` is fine and stays verbatim. For a meeting link prefer
  `--url`, which clients turn into the join button.

**`--url` is writable on `add` and `edit`, and `--url ""` clears it.** An event's
`url` is a separate field from `location` and `notes`, and calendar clients turn
it into the join button — so a synced event can carry a **stale** meeting link
there while `location` holds the current one, and the stale one wins. `events
--json` has always reported `url`; nothing here could write it before, and the
only fallback was AppleScript against Calendar.app.

- **`--url ""` reaches `nil`**, not an empty URL. The read-back check treats a
  cleared URL as absent, so `--url ""` on an event that still holds one fails
  rather than reporting success.
- **A string that is not a URL is refused**, naming it. A scheme is required:
  `example.com` is rejected, `https://example.com` and `zoommtg://…` are taken.
  `add --url` used to drop an unparseable value silently and report success.
- `--occurrence` / `--series` / `--future` mean the same thing here as for every
  other field.
- ⚠️ **The AppleScript route is a trap worth avoiding.** `set url of e to missing
  value` fails with **-1700**; only an empty string works. And Calendar.app
  cannot be addressed by the EventKit id that `events --json` prints, so matching
  falls back to calendar name plus summary.

**Recurring events.** An event ID identifies the *series*, not the instance you
saw — EventKit resolves it to the first occurrence, often years earlier. So:

- `events --json` sets an **`occurrence`** field on recurring events. Pass it
  straight back as `--occurrence` to act on that instance.
- `edit` and `delete` **refuse to run** on a recurring event unless you pass
  either `--occurrence DATE` or `--series`. They will not guess.
- `show` without `--occurrence` returns the series master and says so on stderr.
- **`--series` means the whole series** — every occurrence, and it never
  detaches one. 🛑 It used to save with `EKSpan.thisEvent`, which *detached the
  first occurrence*, applied the change to that alone and left the rest
  untouched, while reporting success. Measured: `edit --series --location X`
  produced one detached instance carrying X and five unchanged occurrences.
  Fixed in 26.812.3; `delete --series` had the same bug and removed only the
  first occurrence.
- `--future` applies a change to this occurrence and all later ones; without it
  only the single occurrence changes. It is redundant with `--series`.

**Backends are meant to be indistinguishable, and are tested that way.**
`calendars --json` reports a `type` per calendar — `exchange`, `calDAV`,
`local`, `subscribed`, `birthdays` — and `./tests/run-tests --backends` runs one
shared set of assertions against a writable calendar from **every** backend
present, naming the backend when one fails. What genuinely differs is what the
*server* does afterwards, not the tool: Google rewrites an attendee's role and
status where Exchange leaves both `unknown`, and the two format invitation mail
differently.

⚠️ **The matrix writes to one real calendar per backend and cannot tell which
are shared** — nothing in EventKit exposes that — so it prints its choices
before writing and takes `APPLE_CALENDAR_TEST_CALENDARS="A,B,C"` to pin them.
It writes **no invitees**, so it never mails anyone.

🛑 **Every calendar write is read back from the store before it is reported.**
`EKEventStore.save` returning true is not evidence the change persisted — a
`--occurrence` move was observed returning exit 0 with JSON describing the moved
occurrence while the store still held the original date, and an identical retry
then worked. So `edit` re-reads a fresh store, compares each field it was asked
to change, **retries once** if nothing landed, and **exits non-zero naming the
mismatch** rather than reporting the request back as if it were the result.

- ⚠️ **The JSON from `edit` is what the store holds, not what you asked for.**
  If they differ, the command fails instead of printing either.
- `APPLE_CALENDAR_SIMULATE_LOST_WRITE=1` makes the save a no-op so that path can
  be tested; the real failure is intermittent and cannot be provoked.

**Recurrence.** `add` and `edit` take the same four flags as `apple reminders`
— `--repeat none|daily|weekly|monthly|yearly` (`-r`), `--repeat-interval N`,
`--repeat-until DATE`, `--repeat-count N` — with identical validation and
wording. `events --json` reports a `recurrence` object (`frequency`, `interval`,
`until`, `count`, `on_the`) alongside `recurring`, which never said *how*.

**`--on-the` is the one flag reminders has no equivalent for**, and it exists
because `--repeat monthly` alone cannot say "the 4th Monday": a plain monthly
rule repeats on *the start date's day number*, so a series starting Mon 28 Sep
recurs on the 28th. The two coincide for exactly one month and then diverge
silently.

```
apple calendar add "Board" --start "2026-09-28 10:00" \
    --repeat monthly --on-the "4th monday"
```

Takes `4th monday`, `last friday`, a bare weekday (means the first), a day
number like `15`, or `last`. Requires `--repeat monthly`; anything else is
refused rather than silently dropped. ⚠️ A `--start` that does not match the
pattern is a **warning, not an error** — the first occurrence sits on the start
date and later ones follow the pattern.

- 🛑 **A recurrence change must be saved with `EKSpan.futureEvents`.** Saving a
  changed rule on the series master with `.thisEvent` silently rewrites it to
  `FREQ=DAILY;INTERVAL=1` — no error, `save` reports success, and a
  4-times-a-year series becomes 365. Measured both ways; pinned by a test.
- **Changing how an event repeats requires `--series`**, because a rule belongs
  to the series and a single occurrence cannot carry one. `--repeat none`
  removes recurrence entirely.
- 🛑 **An id gains a `/RID=<seconds>` suffix once that occurrence is detached**,
  and then resolves to the detached instance, which has no rule of its own — so
  `--series` strips it to reach the master. Without that, `--series --repeat`
  fails with "The repeat field cannot be changed" *while naming the right
  event*, so it reads as the event refusing rather than the id being wrong.
**Rescheduling one occurrence** — the "this week only" case — is
`edit ID --occurrence <date> --start <new>`. It works, including moving to a
different day, and leaves the rest of the series untouched.

- ⚠️ **A moved occurrence *detaches*.** It stops being part of the series:
  `recurring` goes false, the `occurrence` field disappears, and its id gains a
  `/RID=<seconds>` suffix. From then on it is an ordinary event — `edit` and
  `delete` it by its **own** id, and deleting it removes only that instance.
- **`--occurrence` finds it by its new date**, not its old one. Matching is on
  the base identifier, so a detached instance is still reachable through the
  series id plus the date it moved to; the original date correctly reports "no
  occurrence".
- ⚠️ **EventKit does not expand a series far into the future.** An identical
  "every 2 weeks, 3 times" series reports 3 occurrences starting in 2026 and
  **1** starting in 2099, on both Google and iCloud calendars. Anything
  asserting on occurrences must use near-future dates — which is why the test
  suite sweeps a second, near-future window as well as its fixture year.

**`apple calendar invitees ID` is the read path, and `invite` is the write
path.** 🛑 Reading the guest list must never require changing it — before this
command existed the only place the roster appeared was the `Invitees now:`
block a *live* `invite` prints, so you had to mail somebody to find out who was
already invited.

⚠️ **It reports "no invitees" as an answer, not as a missing field.** `events
--json` omits `attendees` entirely when an event has none, and a careful reader
concluded from that omission that the field had been dropped from the build.
`invitees --json` always carries `attendees` (`[]` when empty) and `count`, so
emptiness is never inferred from an absent key.

**Invitees.** `events --json` reports `attendees` (objects, with `name`,
`email`, `status`, `role`, `type`, `organizer`, `is_me`), a separate
`organizer`, and `my_status` — the user's own response, which is what "have I
accepted this?" actually asks. ⚠️ **`attendees` used to be an array of bare
name strings and is now an array of objects**; read `.attendees[].name`.
⚠️ **The organizer is usually *not* in the attendee list**, so listing attendees
alone silently omits whoever called the meeting.

🛑 **On Exchange an invitee change can be discarded after it is confirmed.**
`invite` saves, a fresh-store read confirms it, and the server then throws the
change away seconds later. Intermittent: five of nine per-occurrence invites on
one real series survived and three reverted. So `invite` now waits
`APPLE_CALENDAR_INVITE_SETTLE` seconds (default 12), re-reads, and **fails
naming the addresses that did not survive**.

⚠️ **Local attendees and delivered mail disagree in both directions** — a
reverted change still mailed people, and an event that kept its attendees never
mailed anyone. "invitees: 8" is not evidence anyone was invited, and an empty
list is not evidence nobody was. The server is the only authority; check OWA or
the web UI when it matters.

🛑 **Writing invitees sends real mail, and there is no undo.** `add --invitee`
and `invite --add` make the server email an invitation; `invite --remove` and
deleting the event email a cancellation. **Run `invite --dry-run` first** — it
resolves and prints the plan without contacting the server at all.

**Verified on both backends here**, and both send genuine iTIP mail:

| | Google (calDAV) | Exchange |
|---|---|---|
| invitation | `Invitation: <title> @ …` | `<title>` (no prefix) |
| cancellation | yes | `Canceled: <title>` |
| payload | real invite | `text/calendar; method=REQUEST`, with `ORGANIZER`, `ATTENDEE;RSVP=TRUE` |
| delivery | ~40s | under a minute |

⚠️ **They normalise differently**, which is another reason to match on address
only: Google rewrote role `unknown` → `required` and status → `pending`, while
Exchange left both `unknown`. Exchange also files its own copy in Sent Items,
and on cancellation Outlook moved the original invitation to the invitee's
Deleted Messages by itself.

🛑 **There is no public API for this.** `EKCalendarItem.attendees` is get-only,
`EKParticipant` has no public initializer, and Calendar.app's `attendee` class
is read-only in the sdef — so writes go through private
`EKAttendee.attendeeWithName:emailAddress:` + `addAttendee:`/`removeAttendee:`,
resolved at runtime. If a future macOS drops them the command refuses cleanly
and reading still works. Full record in
[`docs/apple-calendar-invitees.md`](docs/apple-calendar-invitees.md).

🛑 **A `--series` write destroys detached occurrences, so it refuses.** `--series`
saves with `EKSpan.futureEvents` and EventKit rebuilds the series from the rule,
so an occurrence someone had moved is reverted to its original slot — silently,
no error. Measured on Exchange: a series with its November instance moved a week
early to clear a holiday came back with that instance on its original date and
nothing detached. ⚠️ **It is not deterministic** — a second run with more elapsed
time preserved the exception, which looks like a race between the detach syncing
and the series save. `edit --series` and `invite --series` now refuse when the
series has detached occurrences, name each one, and require `--reset-exceptions`
to proceed.

⚠️ **Per-occurrence work converts a clean series into all exceptions.** Every
occurrence you touch detaches, so a nine-meeting series invited that way ends up
with nine exceptions and no un-detached instance — and every later `--series`
operation on it hits the guard. Correct, but a one-way door worth knowing before
you start.

**The safe way to change a series that has exceptions is per-occurrence.**
`invite ID --occurrence DATE --add …` never touches the master, so nothing can be
rebuilt. Verified: it changed only that occurrence and left a pre-existing
exception intact. The cost is one invitation per occurrence, and each one you
touch becomes detached.

- 🛑 **Only the organizer can change who is invited.** On someone else's event a
  local change *appears to succeed* and is then reverted by the server, so
  `invite` refuses up front rather than lying. Reply to the invitation in
  Calendar.app instead.
- 🛑 **EventKit adds the organizer and a self-attendee itself on save.** Don't
  call `addOrganizerAndSelfAttendeeForNewInvitation`; report what the event
  ended up with, not what was asked for.
- 🛑 **Match invitees on the email address, never the name or role** — the
  server rewrites both. `Dan Hopkins`/role `unknown` came back as
  `dan@boulderhopkins.com`/role `required` after one round trip.
- ⚠️ **Removing the last invitee empties the list entirely**, because the
  auto-added self-attendee goes with it. That is correct, not a failure.
- Every change is **confirmed against a fresh store** by address; `confirmed:
  false` with a non-zero exit means the save reported success the store could
  not corroborate.
- Addresses take `a@b.com` or `Name <a@b.com>`. Matching is case-insensitive,
  and re-adding someone already invited is a reported no-op, not an error.

### contacts — `apple contacts`

Swift + Contacts framework (`CNContactStore`). Full CRUD.

```
apple contacts search TERM [--limit N] [--plain]   # default limit 25
apple contacts get ID [--plain]
apple contacts list [--limit N] [--plain]          # default limit 100
apple contacts add [FIELDS] [--container NAME] [--json]
apple contacts edit ID [FIELDS] [--json]
apple contacts move ID --to CONTAINER [--dry-run] [--json]
apple contacts delete ID
apple contacts export ID... [--group GROUP] [-o FILE]   # vCard 3.0
apple contacts relations ID [--json]               # who this contact links to, resolved
apple contacts link A B --relation LABEL [--inverse LABEL] [--no-inverse] [--dry-run]
apple contacts unlink A B [--relation LABEL] [--no-inverse] [--dry-run]
apple contacts containers [--json]                 # accounts, and which is default
apple contacts status [--json]                     # permission state, never prompts

apple contacts groups                              # list, with member counts
apple contacts groups create NAME [--container ID]
apple contacts groups rename GROUP NEW-NAME
apple contacts groups delete GROUP
apple contacts groups members GROUP [--plain]
apple contacts groups add GROUP CONTACT-ID [--json]
apple contacts groups remove GROUP CONTACT-ID [--json]
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
--address  [LABEL:]ADDRESS   repeatable
--relation LABEL:NAME        repeatable
--date     LABEL:DATE        repeatable
```

Labels are friendly names: `home`, `work`, `school`, `other`, plus `mobile`,
`iphone`, `main`, `pager`, `applewatch` for phones, `icloud` for email and
`homepage` for URLs. `--email work:a@b.com`. Unlabelled values are accepted for
email/phone/url.

**Any other label is kept as a custom label**, exactly as Contacts.app stores
one the user typed, and **with its case** — `--url "LinkedIn:https://…"` reads
back as `LinkedIn`, not `linkedin`. This is what makes the documented "read it
first, re-pass what you want to keep" workflow safe: **`get` → `edit` → `get` is
a no-op** for every multi-value field, pinned by a test.

⚠️ **A bare URL is fine; the scheme is not read as a label.** `--url
"https://x.com"` stores the whole thing — the split is on the first colon, but a
prefix that parses as a URI scheme followed by `//`, or one of `mailto` `tel`
`sms` `callto` `facetime` `facetime-audio` `skype` `xmpp`, is treated as part of
the value. The cost is that those words cannot be used as labels.

**Every write is read back and checked.** `add` and `edit` re-read the contact
and confirm each labelled value asked for is really there, failing loudly
otherwise. It is a subset check, because `get` returns the unified contact and a
linked card can contribute values this edit never mentioned.

**Postal addresses.** `--address` takes free text or exact fields:

```
apple contacts edit ID --address "home:500 W Madison St, Chicago, IL 60661"
apple contacts edit ID --address "home:street=500 W Madison St;city=Chicago;state=IL;zip=60661"
```

Labels are the four generic ones — `home`, `work`, `school`, `other`. There is no
address-specific constant in the SDK, unlike email's `icloud`.

⚠️ **Free text is a guess, and the tool prints what it decided** on stderr before
writing. It knows one shape, `street, city, STATE ZIP, country`, and nothing
about any other country's conventions. When it gets one wrong, use the
`key=value` form; `zip` and `postalCode` are both accepted, so what `get` prints
can be passed straight back.

🛑 **Three parse bugs were found by probing real addresses, and every one was
silent.** They are pinned by tests in `swift/Tests/ContactsTests/`:

| input | wrong result | why |
|---|---|---|
| `…, Cupertino, CA` | `country=CA` | a state abbreviation has no digits either |
| `SW1A 2AA` | `state=SW1A;zip=2AA` | a UK postcode is one token pair, not two fields |
| `ON M5H 2N2` | `state=ON M5H;zip=2N2` | a Canadian postcode is two tokens after a province |

🛑 **A typo'd key is an error, not a dropped field.** `citty=Chicago` used to
fall through to the free-text parser and land as a *street* reading
`citty=Chicago`, with exit 0 — the same silent-drop failure the label encoders
were fixed for. Anything of the form `word=` now goes to the structured parser,
where an unknown key is refused naming the valid ones.

🛑 **Never probe this parser by running `add`.** Seventeen contacts were created
in the user's real iCloud to see how strings parsed, and they synced to every
device before being deleted. `PostalAddress` lives in its own `ContactsLibrary`
target so every such question is answered offline.

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

**Relationships between contacts.** `relations` reads them, `link` and `unlink`
write them.

```
apple contacts relations <id>                       # both directions
apple contacts link <id> <id> --relation spouse     # writes both cards
apple contacts link A B --relation father --inverse son
apple contacts unlink A B --relation friend
```

🛑 **A relation stores a NAME, not a reference.** Contacts.app renders one as a
tappable link, which reads as though it holds the other card's id. It does not.
Measured: all 54 relation rows here carry a `ZUNIQUEID`, all 54 values are
distinct, and **none** matches any `ZABCDRECORD.ZUNIQUEID` — that column is the
relation row's own sync id. Three consequences:

- **Renaming a contact silently breaks every link to it.** Nothing updates.
- **A relation can name nobody.** Two do on this store, and that is not corruption.
- **A relation can name several people**, when two cards share a name. `matches`
  in the JSON says which of the three you have.

**`relations` reports both directions**, and the reverse half is the one people
want. `related_from` is a scan of every card for anyone naming this contact —
Contacts has no reverse index, so there is no cheaper way. 1.1s over 679
contacts. On this store Dan lists three brothers and **none of them lists him
back**; only his parents do.

🛑 **`link` appends; `edit --relation` replaces.** That is the whole reason
`link` exists. Adding one relation through `edit` means reading every existing
one and re-passing it, and forgetting one deletes it silently.

⚠️ **`link` writes the other card too, so it states a fact about someone else.**
The inverse is only inferred where it cannot be wrong: `spouse`, `friend`,
`cousin` and `sibling` are symmetric, and `parent`/`child`,
`grandparent`/`grandchild`, `manager`/`assistant` invert cleanly.
**`father`, `mother`, `son`, `daughter`, `brother` and `sister` are refused** —
the other side is son *or* daughter and Contacts records no gender. The refusal
names what to pass. `--no-inverse` writes one side only.

🛑 **Relation labels are stored in two spellings, and both are live here.** One
card holds `_$!<Father>!$_` and another a plain `Sibling`, and `Labels.decode`
passes an unrecognised bare word through unchanged, capitals and all. Comparing
raw labels misses real matches: `link` reported "would add" for a relation the
contact already had, and a second run would have written a duplicate. Compare
through `sameRelationLabel`, never on the raw string.

- **Both arguments take an id or a name.** An ambiguous name is refused listing
  the candidates; an exact full-name match beats a partial one.
- **Re-linking is a reported no-op**, not an error and not a duplicate row —
  the same shape `groups add` uses. Read `changed`, not the exit code.
- **Every write is confirmed against a fresh store** and fails loudly otherwise.
- `--dry-run` resolves and prints the plan without writing.

**Exporting.** `export` writes vCard 3.0 — what Contacts.app and every other
address book imports. Takes any number of ids, `--group NAME` for a whole group,
or both (a contact named twice is written once). Goes to stdout unless `-o`.

Unlike a plain Contacts-framework export it **includes notes**, read from the
AddressBook store and spliced in as a folded, escaped `NOTE` property — so it
needs Full Disk Access for that one field, and without it everything else still
exports. Verified by round-tripping a real 514-character note byte-for-byte.

**Output shapes.** `get`, `add` and `edit` return a single JSON **object**;
`search`, `list` and `groups members` return **arrays**. An unlabelled email,
phone or URL omits the `label` key rather than emitting `null`. The JSON keys
for the name affixes are `prefix` and `suffix`, though the flags are
`--name-prefix` / `--name-suffix`.

⚠️ **`--MM-DD` needs `=`.** `--birthday --04-13` fails, because the parser reads
the value as the next flag. Write `--birthday=--04-13`, and likewise for
`--anniversary` and `--date`.

🛑 **A contact can only join a group in its own account, and nothing in the API
says which account anything is in.** One `CNSaveRequest` cannot span two
containers: adding a contact from account A to a group in account B fails with
Core Data's `NSPersistentStoreIncompleteSaveError` (**`NSCocoaErrorDomain
134040`**, "one or more of the stores returned an error"), which names neither
store. The contact is simply in the wrong account, permanently — retrying, waiting
for sync, and deleting-and-recreating all change nothing.

`groups add` now detects this before saving and names both sides:

```
Error: cannot add 'Kyle Zehner' to 'Recruiters': they are in different accounts,
and one save cannot span two.
  contact: On My Mac (local)
  group:   🌈 (cardDAV)
Move the contact into the group's account, then retry:
  apple contacts move <id> --to "_local:ABAccount" --dry-run
```

**`move` is the way out of that, and it keeps the identifier.** There is no
public move — `CNSaveRequest`'s entire mutation surface is add / update / delete
for contacts and groups plus add / remove member, the container is fixed at
`addContact:toContainerWithIdentifier:`, and `updateContact:` cannot change it.
Copy-then-delete would mint a **new identifier** and **drop the note**, so it was
not shipped. The legacy AddressBook framework's
`importPeople:intoAccount:createNewUIDs:` with `createNewUIDs: false` copies the
record **keeping its unique id**, and `recordForUniqueId:inAccount:` then names
the original precisely enough to remove it.

```
apple contacts move ID --to CONTAINER [--dry-run] [--json]
```

- 🛑 **`ABRecord.nts_MoveIntoAddressBook:account:error:` is the obvious call and
  it lies.** It returned `YES`, `save` returned `YES`, and the record was still
  in the source store on disk. Third API in this repo to report success for a
  write that never happened. So `move` re-reads the container from a fresh store
  and exits non-zero on a mismatch.
- 🛑 **Between the import and the removal the contact exists twice under one
  id.** The removal is therefore resolved *by account* and the record's own
  account re-checked immediately before deleting — a lookup that fell through to
  the new copy would destroy the contact while reporting a successful move.
- ⚠️ **A move always drops every group membership in the account it leaves**, and
  that is inherent: a group belongs to one account. `--dry-run` lists the groups
  it will empty before anything is written, and the result carries `groups_left`
  either way.
- 🛑 **A contact that carries a note cannot be moved.** `importPeople:` copies the
  note, copying it faults it, and Core Data **raises** an uncaught
  `NSInternalInconsistencyException` there rather than returning — which in a
  two-step import-then-delete is how a contact ends up existing twice. Refused up
  front, and the private calls are additionally wrapped in an ObjC exception
  guard (`Sources/ObjCExceptions`) so an unforeseen raise is a clean refusal
  rather than a crash. Move those in Contacts.app.
- **Everything else survives**: the identifier, and every field (swept by a test,
  since a different framework carries the record across).
- If the removal fails, the import is **rolled back**. If the rollback cannot
  name the copy precisely, nothing is deleted and the duplicate is reported —
  two copies are recoverable in Contacts.app, zero are not.
- ⚠️ Only `local` ↔ `cardDAV` has been exercised; Exchange should behave the same
  way, but that is an expectation, not a measurement. The **"me" card** is not
  treated specially and moving it is untested.

Full record in [`docs/apple-contacts-move.md`](docs/apple-contacts-move.md).

⚠️ **`apple contacts containers` is how you find a valid `--container`**, and
`get`, `groups` and `add` all report a `container` now. `add` prints where it
landed, because the default is not always the account you expect — that is how a
contact ends up somewhere that can never join your groups.

⚠️ **An unrecognised `--container` used to be silently ignored.**
`add(_:toContainerWithIdentifier:)` treats an unknown identifier as nil and files
the record in the default container, reporting success. It is now a hard error
listing the valid containers. Names work as well as ids: `--container "On My Mac"`.

⚠️ **`groups remove` depends on which account the group lives in.**
`CNSaveRequest.removeMember` saves without error and changes *nothing* for a
**CardDAV-backed (iCloud) group**, while working correctly for a **local ("On My
Mac") group**. Same code, same objects — only the container differs, and nothing
at the call site distinguishes them:

| Container | Type | Member removed |
|-----------|------|----------------|
| `On My Mac` | local | yes |
| an iCloud account | cardDAV | **no, silently** |

So `groups remove` tries `CNSaveRequest` first and, when the membership
survives, falls back to the **legacy `AddressBook` framework**, which removes
iCloud members correctly. That framework is deprecated but still present, uses
the same `UUID:ABPerson` / `UUID:ABGroup` identifiers, and needs no permission
beyond the Contacts access the tool already has — so this costs nothing extra:
no Automation grant, no Contacts.app, no AppleScript.

Because the fallback is deprecated API that could eventually stop working, the
command re-reads the membership afterwards and fails loudly if the contact is
still in the group rather than trusting either call's return value. Don't report
a removal as done without that confirmation.

🛑 **A contact has two identifiers, and mixing them silently answers "no".**
The unified id (`BD00169D-…`) and the container-backed id (`D065726A-…:ABPerson`)
name the same person. Group membership work must use the backing record, so any
membership *check* has to accept both spellings — comparing a backing id against
a `unifiedContacts` fetch of the group made a **successful** add report *"the save
reported success but X is not in the group"*, and made `container` come back null
for exactly the linked contacts that need it. `memberIdentifiers(of:)` unions a
unified fetch with a non-unified enumeration for this reason.

⚠️ **`add` can return an identifier the store does not use.** Creating a contact
with an explicit `--container` handed back a bare `BD00169D-…` while the record
in the store was `D065726A-…:ABPerson`. Both resolve through `get`, so the id is
usable — but do not assume the string you got back is the one in the address
book, and never build a comparison on that assumption.

🛑 **Group membership must never be handed a *unified* contact.** This is what
made `groups add` fail for freshly created contacts with nothing but
`Save operation could not be completed.`. `unifiedContact(withIdentifier:)`
returns a synthetic merge of every linked record, and `CNSaveRequest.addMember`
needs the **container-backed** record — so both `groups add` and `groups remove`
fetch with `unifyResults = false`.

It presents as intermittent, which is the trap: a brand-new contact is usually
unlinked, so its unified form is indistinguishable from its backing record and
the add works. Once macOS links it to another card, the unified contact's
`identifier` can belong to a *different* linked record, the save is refused, and
it stays refused — through delete-and-recreate, because the linking happens
again. So "it worked the first time" is not evidence the path is sound.

⚠️ **`changed` is the field to read on `groups add` / `groups remove`, not the
exit code.** Both accept `--json` and return
`{group, contact_id, member, changed}`: `member` is the membership state after
the call, re-read to confirm it; `changed` says whether *this* invocation did
it. Adding someone already in the group, or removing someone who was never in
it, is a no-op the framework accepts silently and both used to report as an
action. Both also now fail loudly if the save reports success without taking
effect, rather than trusting the exit code.

⚠️ **A `CNSaveRequest` failure says only "Save operation could not be
completed."** That is `CNError`'s entire `localizedDescription` for every
failure mode. Everything diagnostic is in `userInfo` —
`CNErrorUserInfoKeyPathsKey`, `CNErrorUserInfoAffectedRecordIdentifiersKey`,
`CNErrorUserInfoValidationErrorsKey`, `NSUnderlyingErrorKey` — so the group
commands print all of it. If you add a new write path, do the same; the generic
string alone costs hours.

⚠️ **Multi-value flags replace, they don't append.** Passing `--email` on `edit`
replaces *every* existing email on that contact. Read the contact first and
re-pass the ones to keep.

⚠️ **`--note` is not writable, by construction.** Reading a note works, but
writing needs the `com.apple.developer.contacts.notes` entitlement, which Apple
grants only to signed apps on request — no CLI can hold it. Notes are read
straight from the AddressBook SQLite store instead. Note edits must happen in
Contacts.app.

🛑 **A note blocks *every* `CNContactStore` write to that contact, not just the
note.** The save faults the whole record, faulting reads the note attribute, and
reading it hits the same entitlement — so an unrelated `--company` change is
collateral damage. It fails as a bare `NSCocoaErrorDomain 134092` with an empty
`userInfo`, naming neither the contact nor the note, plus a raw `CoreData:
error: Unhandled error occurred during faulting` on stderr. **52 of 669 contacts
here carry a note**, so this was ~8% of a real address book that could not be
edited or added to a group at all.

`edit` and `groups add` now catch it and rewrite through the **legacy
`AddressBook` framework**, which writes the same records under the same
`UUID:ABPerson` identifiers, needs no permission beyond the Contacts access the
tool already has, and is not subject to the note wall for other properties.
Consequences worth knowing:

- ⚠️ **AddressBook's first save always fails and the second one works.**
  Faulting trips the wall once; afterwards the pending changes commit. So a lone
  failure means nothing there, and the write is confirmed by re-reading rather
  than by any return value.
- The fallback writes `kABBirthdayComponentsProperty` and
  `kABOtherDateComponentsProperty`, not the plain `NSDate` ones, because those
  cannot express a year-less `--MM-DD`.
- The note itself still cannot be written by either path, and is left untouched.
- The raw CoreData dump is suppressed (`com.apple.CoreData.Logging.stderr`, in
  the in-memory registration domain) since the tool now explains the failure
  itself. If the fallback also fails, the error names the contact, the note, and
  Contacts.app.

⚠️ **`delete` is permanent.** Unlike Notes there is no Recently Deleted, and the
deletion syncs everywhere. Always confirm with the user first. Deleting a
*group* keeps its contacts; removing a member keeps the contact too.

`get` reports a contact's `groups`; `search` and `list` don't, because Contacts
has no reverse lookup and it would mean scanning every group per contact.

## Layout

```
bin/apple                 dispatcher — routes to the tools below
swift/                    one Swift package, seven binaries
  Sources/reminders/      + RemindersLibrary/ (+ Tags.swift, the tag read/write
                          face and the per-listing tag cache)
  Sources/ReminderKitBridge/  private ReminderKit resolved at runtime — the only
                          route to Reminders tags, since EventKit has none
  Sources/AppleMail/      + MailLibrary/ (Envelope Index reader, .emlx/MIME,
                          mailbox-name resolution for move)
  Sources/AppleMessages/  + MessagesLibrary/ (chat.db reader, typedstream decoder)
  Sources/ApplePhone/     + PhoneLibrary/ (CallHistory reader, AddressBook resolver)
  Sources/AppleMaps/      + MapsLibrary/ (MapsSync reader — visits, places, guides,
                          and the local geocoder that needs no network)
  Sources/Geocoding/      🛑 the only target that touches the network: Apple Maps
                          search and CLGeocoder, behind `--at` and `maps geocode`
  Sources/AppleCalendar/    + Attendees.swift (the private invitee write path),
                          SyncCommands.swift (sync-status / unsynced /
                          sync-errors / resync, and the add/edit confirmation)
  Sources/CalendarSyncLibrary/  🛑 reads Calendar.sqlitedb, because EventKit
                          cannot say whether a write reached the server. Its own
                          target so it can be tested against a synthetic store
  Sources/AppleContacts/  + Notes.swift (SQLite note reader),
                          Move.swift (the private cross-account move)
  Sources/ContactsLibrary/  PostalAddress.swift — the --address parser, and
                          RelationGraph.swift — which relation labels invert and
                          which must never be guessed. Its own target so both
                          are testable without writing a contact
  Sources/ObjCExceptions/ @try/@catch for Swift — the move raises rather
                          than returning when it hits the note wall
  Tests/RemindersTests/ MailTests/ MessagesTests/ PhoneTests/ MapsTests/
        GeocodingTests/ CalendarSyncTests/ ContactsTests/
notes/                    Python; apple-notes, notestore.py, notestore.proto,
                          mergeable.py (ZMERGEABLEDATA1 reader — recordings,
                          transcripts, summaries, and table cells),
                          tests/ (live Notes.app suite +
                          test_markdown_capabilities.py, which measures what
                          the Markdown write path supports, and test_delete.py;
                          plus offline test_rendering.py, test_tables.py,
                          test_write_path.py)
docs/apple-notes-api.md   NoteStore schema, AppleScript API, verified bugs
docs/apple-notes-shortcuts.md  driving Notes' AppIntents from the CLI —
                          the only route to checklist writes and a real append
docs/apple-notes-transcripts.md  where call recordings actually store their
                          transcript, and the four traps in decoding it
docs/apple-notes-tables.md  where a table keeps its cells, the four traps that
                          each yield a wrong table rather than an error, and
                          the UTF-16 run-length bug an emoji exposes
docs/apple-notes-markdown-support.md  GENERATED. What Apple's Markdown
                          interpreter does with each construct, and what our
                          reader gives back. Regenerate with
                          `notes/capability-report`; never edit by hand
notes/capability-report   measures the matrix above, writes the doc, and
                          `--check`s it — the alarm for a macOS update moving
                          the API surface
notes/shortcuts/          .shortcut build scripts + signed files to install
docs/apple-mail-store.md  Envelope Index schema, .emlx layout, verified traps
docs/apple-mail-drafts.md why apple-mail never writes a body: the cite-blockquote
                          wrapper, every route ruled out, the pasteboard handoff,
                          and why --attach is the one exception
docs/apple-contacts-move.md  no public API changes a contact's container; the
                          private call that lies, the one that works, and what
                          a move costs
docs/apple-calendar-invitees.md  reading invitees is public API, writing them is
                          not; what the server rewrites, and what it mails
docs/apple-calendar-caldav-403.md  the two ways a calendar write reports success
                          and never reaches the server, and how to tell them
                          apart. Neither is reproducible on demand
docs/apple-reminders-tags.md  tags have no public API at all — what EventKit,
                          AppleScript and App Intents each fail to do, the
                          private call that works, and the store behind it
util/check-mail-intents   is Mail's ComposeMessageIntent reachable yet? (exit 0
                          if something changed)
util/check-spotlight      is CoreSpotlight readable from a CLI yet? (exit 0 if
                          something changed) — the answer to "why not Spotlight"
util/appintents-dump      dev-only reader for an app's App Intents schema
docs/apple-messages-store.md  chat.db schema, the typedstream body, verified traps
docs/apple-phone-store.md  CallHistory schema, the entitlement walls, verified traps
docs/apple-maps-store.md  MapsSync schema, why the location table overcounts,
                          and why nothing here writes
docs/apple-geocoding.md   the one network call: what uses it, the local-first
                          rule, and why reminders cannot read the Maps store
docs/prior-art.md         other projects solving this; check before building
docs/todo-deep-links.md   planned: a `url` on every entity, so anything we
                          name can be opened and cross-linked
docs/todo-offline-tests.md  planned: move the Notes suite off live Notes.app
                          so it can run in CI at all
Formula/apple-tools.rb    Homebrew formula
VERSION                   CalVer YY.MMDD.Patch, stamped in by scripts/set-version
```

`apple-notes` is the only Python tool left; stdlib-only, runs on the system `python3`.

## Building

```
make build      # swift build -c release → all seven binaries
make install    # symlink dispatcher + tools into ~/bin
make dev        # debug build, shaded ahead of the installed copy — see below
make check      # smoke-test that every tool responds
make test       # Swift unit tests (mail, messages, phone, maps, geocoding,
                #   reminders — all offline; the network geocoder is not exercised)
make bump       # next CalVer for today, stamped into every tool
make dist       # universal release tarball + sha256 for the Homebrew tap
```

**Iterating on a tool.** `~/bin` is normally *after* `/opt/homebrew/bin` on
PATH, so `make install` cannot override a Homebrew install. `make dev` builds
debug (~2s) into `.dev-bin/` and prints the line to put that dir first:

```
make dev && eval "$(make -s dev-path)"
```

It shades `apple-mail`, `apple-notes`, `apple-messages`, `apple-phone` and
`apple-maps` only, and symlinks the other three to the installed copies. That is
deliberate: reminders/calendar/contacts disclaim, so their TCC grant is bound to
the binary's path and a debug build at a new path re-prompts for permission. The
other five are attributed to the terminal, so shading them is free. To work on one of the others, `make dev
DEV_TOOLS="apple-contacts"` and accept the re-prompt. `make dev-off` removes it.

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
./tests/run-tests              # calendar writes (58) + mail wedge guards (40)
./tests/run-tests --backends   # + the same calendar assertions on every backend (7×N)
./tests/run-tests --contacts   # + contacts writes (60)
```

There is no `--mail` flag any more. `apple-mail` composes nothing as of
26.810.0, so the draft suite went with it; what is left of the mail tests is
read-only and always on.

🛑 **Never verify Mail behaviour by scripting its composer.** `open <message>`
then `close <window> saving yes` wedges Mail's scripting interface — reproduced
twice during development, each costing a restart. When a question genuinely needs
the composer, drive it **by hand** and measure the `.emlx`, in a matched pair
against a hand-typed control. That is how the compose removal was settled; see
[`docs/apple-mail-drafts.md`](docs/apple-mail-drafts.md).

`test_mail_wedge.py` is the exception to the flag rule: it is read-only — it
creates nothing and sweeps nothing — so it always runs. It pins the guards that
keep a read command from wedging Mail: the refusals, the no-launch rule, the
deadlines, and the fact that the child `osascript` really dies. **Run it twice,
once with Mail.app open and once closed.** Some assertions only mean anything in
one state, and each half skips in the other rather than failing, so a single run
silently covers about two thirds of it.

Two seams make that testable without breaking anything:
`APPLE_MAIL_INDEX_PATH` pointed at a nonexistent file stands in for a missing
Full Disk Access grant, and `APPLE_MAIL_PROBE_TIMEOUT` shrunk to 0.05s makes a
*healthy* Mail trip the give-up path — the only safe way to exercise it, since
there is no way to wedge Mail on purpose. Set `APPLE_MAIL_BIN` to test a
specific build; the default prefers `.build/release`, so a stale release binary
otherwise tests the old code — and lets the unguarded AppleScript paths loose on
Mail while doing it (8 minutes, once, here).

Contacts fixtures have `__claude_contacts_test__` as their **exact** first name
and the sweep refuses anything else — contact writes sync everywhere and cannot
be undone, so never loosen that to a prefix match. Set `APPLE_CONTACTS_BIN` to
run against a specific binary; TCC grants are per path, so the copy you just
built may not be the approved one, and an unapproved one hangs on XPC rather
than failing cleanly.

`NoteBearingContacts` is the one class in that suite with a dependency outside
the tool: it plants its fixture note through **Contacts.app AppleScript**,
because writing a note is exactly what the tool cannot do. Without Automation →
Contacts for the calling terminal it skips rather than fails.

## Permissions

Each tool needs a one-time TCC grant, prompted on first run **from a terminal**:

| Tool | Grant |
|------|-------|
| reminders | Privacy & Security → Reminders |
| calendar | Privacy & Security → Calendars |
| mail | Full Disk Access to read; Automation → Mail to open a compose window |
| messages | Full Disk Access for the calling terminal (reads chat.db directly) |
| phone | Full Disk Access for the calling terminal (reads CallHistory + AddressBook) |
| maps | Full Disk Access for the calling terminal (reads MapsSync) |
| contacts | Privacy & Security → Contacts |
| notes | Full Disk Access for the calling terminal (reads sqlite directly) |

`mail` needs **two grants for two halves**. Full Disk Access covers `search`,
`export`, `attachments` and `accounts`. Automation → Mail is what lets
`compose`/`reply`/`forward` open a window, and `delete-draft`/`move` refile a
message. ⚠️ **`move` needs both**: Full Disk Access to resolve each message
against the index, then Automation → Mail to move it — so it can fail for two
quite different reasons, and the error says which.
`apple mail status` reports both and counts the tool usable if either is present,
so "mail ✓" can mean reads work and composing does not; check the detail line
before concluding which half is broken.

`apple status` reports all eight at once without prompting — start there rather
than running each tool to see which one errors.

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

`mail`, `messages`, `phone`, `maps` and `notes` are *not* covered by this:
Automation and Full Disk Access are still attributed to the calling terminal, so
those five really do depend on which terminal is running. This now covers mail's read path
too — reading the Envelope Index needs Full Disk Access for whatever terminal
launched the tool.

⚠️ **`phone` cannot ever join the disclaiming group, and this is load-bearing.**
Disclaiming makes a process its own responsible process, which is exactly what
Full Disk Access is attributed to — so a disclaiming `apple-phone` would lose the
terminal's grant and stop being able to read call history at all. That is also
why it resolves caller names out of the AddressBook SQLite stores rather than
through `CNContactStore`: taking a Contacts grant would mean disclaiming, and
disclaiming would break the read the tool exists for.

⚠️ **macOS only prompts when the status is `notDetermined`.** Once it is anything
else the request returns silently and no dialog ever appears. The trap is
Calendar's `writeOnly` ("Add Only") state: it looks granted, but cannot read
events, and macOS will not offer to upgrade it. `apple calendar status` reports
the real state without prompting — run it before concluding a grant is missing.
The remedy is always a manual toggle in System Settings, never a retry.
