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
| Write a contact note | `apple contacts edit <id> --note "text"` |
| ...without losing the old one | `apple contacts edit <id> --append-note "line"` |
| Record a death | `apple contacts edit <id> --died 2020-04-30` |
| ...when only the year is known | `apple contacts edit <id> --died 2020` |
| Who has died | `apple contacts deceased --json` |
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
Markdown. Stdlib only — no virtualenv is involved. Writes go through Shortcuts;
`delete` goes through AppleScript.

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

`ID` accepts a numeric note ID, a note title, or an `applenotes://` URL.

**Search is title-only.** There is no full-text search over note bodies; to search
content, export candidates and grep them. **Locked notes are skipped by default** —
`export` refuses one with **exit 2**, distinct from 1, "not found".

**`export` renders `**bold**`, `_italic_`, `==highlight==`, `~~strike~~`, links,
headings, lists, checklists and tables**, and it reads table cells rather than
emitting a placeholder. Measured: 76 of 76 tables on this store decode. The rules
that make that correct are in
[`docs/apple-notes-rendering.md`](docs/apple-notes-rendering.md), and the traps in
the blob itself — all four of which produce a wrong table rather than an error —
are in [`docs/apple-notes-tables.md`](docs/apple-notes-tables.md). Three worth
knowing at the call site:

- 🛑 **`font_weight` is an enum, not a weight**: 1 bold, 2 italic, **3 both**. A
  reader testing `== 1` for bold loses it on every weight-3 run.
- ⚠️ **Notes has no header row and Markdown demands one, so row 1 is promoted.**
  The output alone cannot tell you whether that row was data.
- 🛑 **Three separate mechanisms carry a link** — a URL on text, a note link as an
  inline attachment, and a hashtag or mention. Handling one leaves most broken.

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
since note titles are all "Call Recording" and search is title-only. It scans every
mergeable-data attachment and keeps the ones that decode as audio, so it finds
voice memos and imported files too; `--calls-only` narrows to real calls. A bare
listing **skips the per-word decode**, which is most of the cost.

**Search matches handles, titles and summaries — not what was said.** Add
`--transcripts` to search the words too (0.36s for this whole store). A query is an
AND of substring terms, the same semantics as `mail search`.

🛑 **LENGTH is the recording, not the call, and the gap can be large.** Recording is
started by hand at any point. Measured here: a 29-minute outgoing call produced a
14m53s recording that began 14 minutes in, whose **first transcribed word is 1:33
into the recording** because the rest was hold. Call length, recording length and
speech length are three different numbers. ⚠️ Hold time and IVR leave no segments at
all — the first segment's timestamp is the only sign, and it is not zero.

- ⚠️ **Direction is not recorded.** `callType` is reported raw and nothing infers
  incoming/outgoing from it. That is why the columns are `YOU`/`OTHER PARTY`.
- ⚠️ **Segments are per-word** (2,228 for a 15-minute call) and stored in **CRDT
  insertion order, not reading order** — the decoder sorts on timestamp. `--words
  --json` exposes the raw segments; the default groups them into turns.
- **Speaker attribution is Apple's**, per word, so overlapping speech renders as
  genuine interruption. `You` is resolved from `callLocalSpeakerHandle`.
- ⚠️ **Only call recordings have speakers.** A voice memo transcribes with no
  speaker on any segment and gets no name prefix — that is correct, not a failed
  lookup. `is_call` in the JSON says which you have.
- ⚠️ **A recording with no transcript is normal**, not a decode failure:
  transcription is on-device Apple Intelligence. Both commands say so and exit 1.
- **`summary` is often absent while `topLineSummary` is present.** The JSON carries
  both; the plain output prints whichever exist.
- 🛑 **The audio bytes are not reachable through any command here.** To get the
  `.m4a`, copy it out of `~/Library/Group
  Containers/group.com.apple.notes/Accounts/<uuid>/Media/`.

Full record — the 0-based indices, the undocumented `ObjectID` double field, the
Unix-epoch start time, and the two incompatible word tokenizations — in
[`docs/apple-notes-transcripts.md`](docs/apple-notes-transcripts.md).

**Writes go through Shortcuts, and the CLI hides that.** `create` and `append` take
a body as `--body`, `--body-file FILE`, `--body-file -`, or a bare pipe. Markdown
becomes native structure: `- [ ]` and `- [x]` are real checklists with their
checked state, pipe tables are real tables. `append` is a genuine append — it
**preserves attachments and existing checklists**, unlike the AppleScript body
write. The full write story is in
[`docs/apple-notes-writes.md`](docs/apple-notes-writes.md); the AppIntents route
and build scripts are in
[`docs/apple-notes-shortcuts.md`](docs/apple-notes-shortcuts.md).

🛑 **No target means no append.** The shortcut matches the note by *Name*, and a
name matching nothing does **not** fail — Shortcuts opens a picker and waits, then
writes to whatever the human eventually picks. Measured: four queued appends all
landed on a note chosen minutes later. Nothing after the fact reveals this, so
`append` refuses **before** running unless the target is a live note whose title
matches it and nothing else.

**Writes need `install-shortcuts` first.** `apple notes status` reports whether the
write path is available and names anything missing; until then Notes is read-only.

🛑 **Installed is not the same as allowed, and an unallowed shortcut fails
silently** — `shortcuts run` exits 0, prints nothing and writes nothing. `status`
reads the grants out of `ZACCESSRESOURCEPERMISSION` and reports `unauthorized` per
shortcut; `create` and `append` refuse up front when no grant exists. ⚠️ **A
`shortcuts run` exit code proves nothing about whether the shortcut did anything.**
Confirm every write by re-reading the store.

🛑 **What the Markdown write path supports is measured, generated, and checked —
never assumed.** The matrix lives in
[`docs/apple-notes-markdown-support.md`](docs/apple-notes-markdown-support.md),
generated from `notes/tests/markdown_cases.py`:

```
./notes/capability-report            # measure and rewrite the doc
./notes/capability-report --check    # exit 1 if any answer moved
```

**Run `--check` after every macOS update.** Measured on 26A5406e: everything works
except **`==highlight==`** and **`` `code` ``**, which Apple ignores, plus
**`- [X]`** and **`* [x]`**, which do not make checklists. ⚠️ **`#` becomes the
*title* style, not a heading.** ⚠️ **Apple drops bold inside link text.** 🛑 **A pipe
table destroys the last item of the list directly above it** — put one paragraph
between them. ⚠️ **Do not hand-probe these answers.** Three wrong conclusions came
out of doing that.

**`delete` moves a note to Recently Deleted, and needs no Shortcut.** It needs
**Automation → Notes** for the calling terminal and **launches Notes.app** if the
app is closed; reads need neither.

- 🛑 **It addresses the note by primary key, not by name**, so the picker trap that
  governs `append` cannot arise.
- 🛑 **A partial title is refused, unlike `export`.** A title must match in **full**,
  must name a **live** note, and more than one match is refused listing the ids.
- ⚠️ **It asks before it deletes**, and refuses without a tty unless given `--yes`.
- 🛑 **Confirmation goes through Notes.app, not the store.** The sqlite store lags an
  **unbounded** amount — measured, one delete appeared in 3.5s and another was still
  in its folder more than ten minutes later. **`confirmed` is Notes.app's answer and
  is the field to read**; `store_confirmed` is sqlite's, and `--wait` gives it
  longer.
- ⚠️ **A locked note is refused with exit 2**, since the user cannot be shown what
  they are about to destroy.
- ⚠️ **`apple notes search` still lists a deleted note**, because the reader can see
  Recently Deleted. That is not a failure. Deletion is recoverable for about 30
  days, and **there is no API to empty that folder**.

🛑 **The AppleScript write path is the wrong tool for most writes**, and its traps
are the reason `create`/`append` do not use it. Each is locked by a live test in
`notes/tests/`; the full list is in
[`docs/apple-notes-writes.md`](docs/apple-notes-writes.md) and
[`docs/apple-notes-api.md`](docs/apple-notes-api.md). The two that matter most:

- 🛑 **Editing `body` destroys attachments** — and **45% of a real store (427 of 939
  notes) carries one**. Tables survive for free, images only if you harvest and
  re-add them, and **PDFs, text files and scans are unrecoverable**.
- 🛑 **A body write flattens every checklist into a plain bulleted list**, losing
  which items were ticked, unrecoverably and invisibly. 7% of notes here have one.

### mail — `apple mail`

🛑 **This tool never writes a message body, and that is the whole design.**
Setting a body through AppleScript wraps it in `<blockquote type="cite">` (Apple
FB11734014) — invisible to the sender, rendered as a quotation by iOS Mail and
Gmail. It cannot be fixed after the fact: rewriting the `.emlx` corrects the file,
and the file is not what the composer opens. A whole compose surface was built on
that rewrite and removed in 26.810.0 when it was measured. Full record in
[`docs/apple-mail-drafts.md`](docs/apple-mail-drafts.md).

So `compose`, `reply` and `forward` **open a Mail window with everything filled in
except the body**, put the body on the pasteboard, and stop. The user presses ⌘V
and ⌘S.

Reads go to Mail's own SQLite index and the `.emlx` files on disk, so they work
with Mail.app closed and return in milliseconds. Schema and traps in
[`docs/apple-mail-store.md`](docs/apple-mail-store.md); the AppleScript deadlines
and the wedge they exist to prevent are in
[`docs/apple-mail-wedge.md`](docs/apple-mail-wedge.md).

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

⚠️ **`send` does not exist and will not.** It composed without a window, so there
is nowhere to paste, and every message it ever sent carried the wrapper. When the
user wants mail sent, draft the text and let them send it from Mail.app.

**Bodies may be `--markdown` or `--html`; both become RTF on the pasteboard.**
Markdown gives real bold, italic, links and bullets. 🛑 RTF is deliberate: **HTML
on the pasteboard makes Mail insert the body twice.** A plain `--body` is taken
literally, so prose containing `*` or `_` survives as written.

**`--attach FILE` is the one part of a draft the tool writes itself.** Repeatable,
on all three commands. The files are **already in the window** when it opens — only
the body is left to ⌘V — so the JSON reports them under `attachments` (`name`,
`path`, `bytes`) while `status` stays `awaiting_paste`.

It is allowed where the body is not because the cite-blockquote wrapper comes from
*assigning* to `content`; `make new attachment` adds an element without assigning.
🛑 **Do not seed `content` with a newline first** — that is the usual recipe and it
is exactly the wrapper.

- 🛑 **`count of mail attachments` cannot verify this.** On an outgoing message it
  fails with **-1728** rather than returning 0. What works is counting **U+FFFC**
  in `content`, one per attachment, and asserting the **delta** across the attach.
- ⚠️ **A mismatch is a hard error naming the shortfall**, because a window is
  already open in front of the user.
- **Every path is checked before any Apple Event** — missing file, directory,
  unreadable, or the same file twice all exit 64 with nothing opened. They are
  checked *before the body reaches the pasteboard*, so a bad `--attach` cannot
  silently replace what the user had copied.
- Attachments totalling over 20 MB get a stderr note, not a refusal.
- **Verified in a matched pair (26.812.0):** attaching first does not degrade the
  pasted formatting. ⚠️ Mail does wrap the *attachment placeholder* in a
  style-neutralised cite blockquote, with the body entirely outside it — that is
  Mail's layout structure, not FB11734014.

🛑 **You cannot reply to a draft** — a draft has no sender, and handing one to
Mail's `reply` verb wedged Mail during development. Refused off the index, before
any Apple Event, along with an unknown Message-ID, a forward with no recipients,
and a missing body. Each refuses in under 0.25s.

**Searching is cheap — search widely.** No `--limit`/`--since` discipline is
required, and there is no timeout to trip. The default covers every mailbox except
trash and junk (`--all` adds those, and `--mailbox trash` is honoured by name).

**A query is an AND of terms.** `budget review` matches messages containing both
words anywhere, in any order — not the literal string. Double-quote to require
adjacency: on a real store `budget review` → 346 results, `"budget review"` → 0.
⚠️ **Matching is substring, not word-boundary**: `quarter` matches inside
`quarterly` and `headquarters`. There is no stemming, no ranking (order is by
date), and no boolean operators beyond the implicit AND.

**`--field content` is real full-text search** over decoded message bodies, and is
the one mode that opens files. It finds text inside base64 and quoted-printable
parts that a raw `grep` over `~/Library/Mail` cannot see. `--field all` means
subject, sender *and* body; `--field` defaults to `subject`.

It walks newest-first and stops as soon as `--limit` is filled — but a term with
**fewer matches than `--limit`** has to read everything. On a 40k-message store:

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
scan depth is always reported on stderr — a full scan is never silent.

**Attachments are not searched at all by default** — not their contents, and not
their filenames. A search for "invoice" should find messages *about* invoices, not
every message carrying an `invoice.pdf`. `--attachment-names` also matches
filenames, free off the index. Attachment **contents are never searched**: a
`text/*` part marked as an attachment is skipped, non-text parts are never
decoded, and there is no PDF text extraction.

**Getting the files out.** `export` reports attachment *names*; `attachments` gets
the bytes. `export --raw` writes the RFC 822 source; `export --json` gives
structured headers, recipients, attachment names and body.

⚠️ **Attachment bytes are not in the `.emlx`.** Mail strips them out, leaving the
MIME part with an empty body and an `X-Apple-Content-Length` header, and writes
the file *already decoded* to
`Data/<digits>/Attachments/<rowid>/<mime-part>/<filename>`. Parsing the message
alone yields zero-byte attachments — the command reads the directory and falls
back to embedded bytes only for messages that really carry them.

**What counts as an attachment is Mail's rule: a part with a filename.** Verified
against its index — a message with two nameless tracking pixels reports zero
attachments, one with seven named inline images reports seven. `--skip-inline`
drops images the HTML body references.

🛑 **`attachments` and `export --json` do *not* always agree, and a draft built by
`--attach` is where they part.** Mail references a scripted attachment from the
HTML by `cid:`, so it reads back as *inline*: `apple mail attachments` reports
`1 … (inline)` while `export --json` gives `[]` and the index says `0`, for a draft
that really does carry the file. **Use `apple mail attachments` when the question
is "did the file make it".**

`--save` never overwrites: a name that already exists gets `-2` before the
extension. Filenames come from the sender, so they are sanitised to a bare
basename before being joined onto `DIR`.

**`move` files received mail into another mailbox, and it is the one write path
here that touches real mail.** Built for sweeps: filing what arrived before a
filter rule existed, or rescuing what was filed wrongly. `-` reads ids from stdin,
so it is the tail of a pipeline:

```
apple mail search "receipt" --mailbox inbox --json | jq -r '.[].id' \
  | apple mail move - --to Receipts --dry-run
```

- **`--dry-run` sends Mail nothing at all.** It resolves and prints the plan off
  the index alone. Run it first; these moves sync to every device.
- **Every message is resolved against the index and handed to Mail as an exact
  id** — never a mailbox walk, which is what wedges Mail. 0.9s per message on a
  37k mailbox regardless of age.
- **Partial failure never aborts the batch.** Each message reports `{id, moved,
  confirmed, error}`; the exit code is 1 if any failed. A whole chunk lost to a
  timeout is charged to every message in it.
- **Every move is confirmed by the copy *appearing in the destination*** — not by
  it leaving the source, which takes minutes. `confirmed: false` with `moved:
  true` means Mail reported success the index could not corroborate.
- **`--mark-read`** matches what a server-side filter rule does when it files
  something. **Drafts are refused** — a draft's Message-ID changes when it is
  edited. Use `delete-draft`.
- A Message-ID with copies in several mailboxes moves **all** of them. Narrow with
  `--from` or `--account`.
- Destinations are per-account and **nothing is created**. `--to trash` resolves to
  `Deleted Messages` on IMAP, `Deleted Items` on Exchange and `[Gmail]/Trash` on
  Gmail, so one command works across accounts. 🛑 A nested mailbox needs its full
  path (`[Gmail]/All Mail`), which `move` resolves for you.

**`delete-draft` only ever moves a draft to trash.** It enumerates Drafts alone,
re-reads the mailbox afterwards rather than trusting the move, and it is a move to
**trash, not a purge**. 🛑 **Re-resolve the Message-ID first** — a draft's changes
when it is edited, and an `export` of a stale one silently produces an *empty
file*. Look it up by subject: `apple mail search "" --mailbox drafts --json`.

⚠️ **A mailbox move is copy-then-expunge**, so the source copy survives until the
server expunges it (~2 min on IMAP). Both commands say so on stderr; a re-listing
before then still shows the message in its old mailbox, and that is not a failure.

**Mailbox names are not unique** — three accounts can each have an `Archive`.
Every result carries both `account` and `mailbox`; use the pair. Account names can
contain emoji and spaces — get exact strings from `apple mail accounts`.

⚠️ **`accounts` is the one read command that still prefers Mail.app**, because
only Mail knows whether an account is `enabled`. It asks Mail when Mail is already
running and reads the store otherwise — including when Mail is running but *not
answering*, so a wedged Mail costs you the `enabled` field rather than hanging the
command. Consequence: **the file-system answer has no `enabled` key**, so read it
as `account.get("enabled", True)`. It also lists the local "On My Mac" store,
which the AppleScript path omits.

⚠️ **A message can be in the index but not on disk** when Mail hasn't downloaded
the body. `export` says so explicitly, and `auto` falls back to AppleScript — but
only when Mail is already running and answering.

**All three read commands take `--engine auto|filesystem|applescript`. Leave it
alone.** 🛑 The AppleScript engine is what wedges Mail, so `auto` no longer drifts
into it: `search` never falls back, no read command launches Mail, and every
AppleScript read is bounded by a wall-clock deadline *and* an inner `with
timeout`. `--engine filesystem` fails loudly instead of falling back, which is what
you want when diagnosing.

**`apple mail status` answers "is Mail wedged?"** — `mail_app.running` and
`mail_app.responsive` in the JSON. `responsive` is only present when Automation is
already authorized and Mail is up, because probing otherwise would trigger the
consent dialog `status` exists to avoid. 🛑 Read `automation: "unknown"` as "Mail
is wedged", not as a grant problem — the permission API itself blocks for minutes
against a wedged Mail and then answers wrongly.

🛑 **Custom IMAP keywords are not on this Mac**, and no tool here can expose them.
Mail discards them on sync. Anything keying off one has to run server-side.

**`APPLE_MAIL_INDEX_PATH`** points the index reader at a specific file, or at a
path that doesn't exist to see what a command does without Full Disk Access. The
error names the variable, so an unreadable override never masquerades as a missing
grant.

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

Reads `CallHistory.storedata` directly, the same way messages reads `chat.db`, and
resolves caller names out of the AddressBook stores under the same grant. Works
with Phone.app closed. **Read-only except `dial`.** Schema and the six store traps
are in [`docs/apple-phone-store.md`](docs/apple-phone-store.md), each pinned by a
test in `swift/Tests/PhoneTests/`.

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
every caller is resolved against Contacts and reported with a `name` and a `known`
flag. `--unknown` narrows to callers you have not saved, which is the short path
from "who called me yesterday" to `apple contacts add`.

- **Contact resolution has three states, not a boolean**: `available`,
  `noAddressBook` (nothing to read — correct and silent), and `unreadable` (a grant
  problem). `--unknown` **refuses** in the last case, because with an unreadable
  address book every caller would match and the whole store would come back looking
  like an answer. `--json` **omits `known` entirely** there rather than emitting
  `false`, and sets `contacts_unavailable: true`.
- **A missing address book is not an error.** Call history still reads; only names
  go missing.

⚠️ **This is a relay mirror, not full history.** Four months here against an iPhone
that keeps years. Say "recents", never "all calls".

🛑 **`ZANSWERED` means "answered by me", so it is `0` on every outgoing call.**
Treating it as "connected" reports everything you dialled as missed. Connected is
`ZDURATION > 0`, which is orthogonal to direction. This is the one store trap worth
knowing at the call site; the rest — the Apple-epoch **seconds** against `chat.db`'s
nanoseconds, the `REAL` column that never matches a text comparison, the
unnormalised `ZADDRESS`, the write-ahead log that `immutable=1` will not replay,
and the fact that sqlite treats a 1-byte file as a valid empty database — are in
the doc.

🛑 **Blocking a caller is impossible, and the API lies about it.** The
`CommunicationsFilter` C functions are reachable by `dlopen` and *appear* to work,
but the XPC to `cmfsyncagent` needs `com.apple.private.communicationsfilter` and is
**denied silently**: `CMFBlockListIsItemBlocked` returns `false` for a number that
is demonstrably on the list. So there is no `block` command; one would report
success and change nothing. `blocked` reads the list, and `recents` flags callers
already on it. Signing and notarising would not change this. Block in Phone.app or
System Settings; the iPhone is what filters relayed calls anyway.

🛑 **Voicemail is not on this Mac at all.** No local store exists (`ZHASMESSAGE` is
`0` on every row), `vmd` does not exist on macOS, and `vmshow://` needs a UUID
nothing local can enumerate. `voicemail-*.m4a` files under
`~/Library/Messages/Attachments` are ones people *forwarded over iMessage*, not an
inbox. There is nothing to list and nothing to mark read.

🛑 **Call recordings are not here either — they belong to `apple notes`.** `apple
phone recordings` (alias `transcripts`) is a **signpost that prints where to go and
exits**, deliberately, so it can never imply a call and a recording are the same
object. An iPhone call recording syncs as a *note*. ⚠️ **The two stores do not join
cleanly**: recording is started by hand partway through a call, so neither timestamp
nor duration matches, and a number dialled repeatedly makes even an interval match
ambiguous. Do not report a call and a recording as the same object without saying
how the match was made.

**`dial` hands a `tel:` URL to Phone.app and Phone.app always asks you to confirm**
— skipping the prompt needs `com.apple.FaceTime.NoPrompt`, an Apple-internal
entitlement. That prompt is the gate, so there is no `--confirm` flag, and the tool
will never click the panel for you. `--dry-run` shows the URL without placing
anything. `TARGET` may be a number, an Apple ID, or a contact name — a name resolves
against the address book, prefers the number that person most recently used, and an
ambiguous name is an error rather than a guess.

`--json` keys: `status` (`outgoing`/`incoming`/`missed`), `kind`, `handle`,
`number`, `duration`, `connected`, `known`, `blocked`, `name`, `contact_id`,
`location`, plus `call_type` so an unrecognised type is visible rather than hidden
behind `kind: "unknown"`.

### maps — `apple maps`

Reads `MapsSync_0.0.1` directly, the same way phone reads `CallHistory.storedata`.
Works with Maps.app closed. **Read-only, and it will stay that way.** Schema and
the store traps are in [`docs/apple-maps-store.md`](docs/apple-maps-store.md);
`APPLE_MAPS_DB_PATH` overrides the path, and the test suite builds its own store so
it runs offline.

```
apple maps places [--since DAYS] [--before DAYS] [--search TEXT]
                  [--min-visits N] [--limit N] [--json]   # default subcommand
apple maps visits [--since DAYS] [--before DAYS] [--search TEXT] [--limit N] [--json]
apple maps guides [GUIDE] [--search TEXT] [--places] [--json]
apple maps geocode PLACE [--local-only] [--network-only] [--near TEXT] [--json]
apple maps status [--json]
```

`places` is the default subcommand, so `apple maps` alone lists where the user
goes, most-visited first. `visits` is the same data one arrival at a time.

⚠️ **This is Maps' "Visited Places", not Significant Locations.** Significant
Locations belongs to `routined`, under `/var/db/locationd/`, which no unprivileged
process can read. They are different features with different retention. **Never
report one as the other.**

🛑 **Nothing here writes, and nothing here should.** CloudKit mirrors this store —
1,936 `NSCKRecordMetadata` rows — and Core Data triggers maintain denormalised
counters on it. A direct write would fight the sync engine. There is also no
fallback: Maps.app ships **no AppleScript dictionary at all** (`sdef` prints
nothing), and its five App Intents only drive navigation.

🛑 **A place is a location row that has a visit, and the raw table overcounts
badly.** 123 of the 314 `ZVISITEDLOCATION` rows here carry **no `ZVISIT` at all** —
duplicates of places that already have a visited row. Counting that table reports
**314 places where the honest answer is 191**, a 64% overcount in the flattering
direction. `places` joins through `ZVISIT`; `status` prints the orphan count so the
gap is visible rather than inferred.

⚠️ **A visit records a start time and nothing else.** There is no end time in the
schema, so this store **cannot say how long the user stayed** anywhere. Do not
report a duration from it. ⚠️ `ZVISITCLASSIFICATION` is undocumented and reported
raw, with no label.

**Guides are the richest thing in the store.** 18 here, holding 126 saved places:
`Boulder Playgrounds` with 21 named parks and street addresses, plus one trip guide
per work trip since 2020.

- 🛑 **Places come through `Z_7PLACES`, never off `ZCOLLECTIONITEM`.** 12 of the 126
  item rows belong to no guide, so listing that table invents saved places the user
  cannot see in Maps.app. The join is genuinely many-to-many.
- ⚠️ **An ambiguous guide name is an error naming the candidates**, not a guess.
  Same rule `apple messages` uses for a chat reference.
- **A renamed place keeps both names.** `ZCUSTOMNAME` is set on 122 of 126 items and
  wins; `map_item_name` appears in JSON only when the two differ.

**Categories are `||`-joined, most specific first** —
`Dining||American Cuisine||Restaurant` — and `--json` reports both the split
`categories` array and `category` for the first.

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
- **A Maps search is biased to where the user has recently been**, taken from the
  **median** of their own visit coordinates — a mean would be dragged into the ocean
  by one trip abroad. Nothing asks Location Services where they are. Measured:
  `geocode costco --network-only` returns Superior, Longmont and Thornton; the same
  query `--near "Seattle, WA"` returns Seattle and Kirkland.
- **`--json` carries `at`**, a `"Name@lat,lon"` string ready to hand to `apple
  reminders --at` or `apple calendar --at`. That is the composed path, and it is
  what keeps the place's name on the reminder.
- **`source` and `network` say where an answer came from**: `visited-place`,
  `guide-place`, `maps-search`, `address-lookup` or `coordinate`. Read `network`,
  never infer it from `source`.

**Every place carries a real coordinate**, unlike a `--location` written by `apple
calendar`. So `apple maps` is the one tool here that can hand you a latitude and
longitude for a place the user has actually been, without touching the network.

**Six tables are read; five more hold data nothing reads yet**: `ZHISTORYITEM` (32
rows: searches, directions, dropped pins — and Maps prunes it, 189 created against
32 kept), `ZUSERROUTE` (3 custom hikes with geometry), `ZFAVORITEITEM` (14),
`ZREVIEWEDPLACE` (56) and `ZINCIDENTREPORT` (32).

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
                                [--tag TAG]... [--at PLACE] [--on arrive|leave] [--radius M]
apple reminders edit LIST INDEX ["NEW TEXT"] [--due-date DATE] [--priority P] [--notes TEXT]
                                [--tag TAG]... [--add-tag TAG]... [--remove-tag TAG]...
                                [--at PLACE] [--clear-location]
apple reminders complete LIST INDEX
apple reminders uncomplete LIST INDEX
apple reminders delete LIST INDEX
apple reminders new-list NAME
```

`--due-date` takes natural language: `today`, `tomorrow 9am`, `next friday`,
`2026-12-25`. `--format json` still works as a synonym for `--json`.

⚠️ `INDEX` is the position shown by `show`, and it **shifts** as items complete or
get added. Always `show` immediately before `complete`/`edit`/`delete`.

**Location reminders — "remind me when I get there" — go on `add` and `edit`.**

```
apple reminders add Errands "Buy milk" --at "Costco, Superior CO"
apple reminders add Errands "Call back" --at "39.96,-105.17" --on leave --radius 250
apple reminders edit Errands 3 --clear-location
```

`--at` takes a place name, an address, a `"lat,lon"` pair, or the `"Name@lat,lon"`
form that `apple maps geocode --json` emits as `at`. `--on` is `arrive` (default) or
`leave`. `--radius` is metres, default 100. `--near` biases the Maps search.

- 🛑 **A name or address means a network call**, the only one `reminders` makes. A
  `"lat,lon"` pair touches nothing.
- 🛑 **`reminders` cannot read the Maps store, so it cannot resolve a place from the
  user's own history.** It re-executes itself disclaimed so the Reminders grant
  follows the binary, and **a disclaimed process loses the terminal's Full Disk
  Access**. To pin a reminder to the branch the user actually goes to, compose the
  two tools:

  ```
  AT=$(apple maps geocode costco --json | jq -r '.[0].at')
  apple reminders add Errands "Buy milk" --at "$AT"
  ```

  That resolves locally, with no network call, and carries the name through.
- ⚠️ **A structured location with no coordinate triggers nothing**, while still
  showing a name in Reminders.app. So a failed lookup refuses rather than saving a
  location that looks right and never fires. Ambiguity is refused too: a shop name
  matching branches more than 250 m apart is an error listing them.
- **The location alarm sits alongside a time alarm** rather than replacing it, so
  "at 9am, or when I get there" is one reminder. `--clear-location` removes only the
  location alarms.
- ⚠️ **`show --json` reports `locationTitle` and `location`.** `location` is the
  coordinate pair as a string, not an address.

**Tags — the `#PTA` chips — have no public API, and this is the one place the tool
reaches past EventKit.** Not EventKit (every "tag" symbol there is a sync ETag), not
AppleScript (the string appears in Reminders' sdef zero times). Writes go through
private `ReminderKit`, resolved at runtime, needing no grant beyond the Reminders
one. Full record in
[`docs/apple-reminders-tags.md`](docs/apple-reminders-tags.md).

- `--tag` on **`add`** sets the tags; on **`edit`** it **replaces** the whole set,
  matching how multi-value flags behave in `apple contacts`. `--add-tag` /
  `--remove-tag` change them one at a time, and combining the two styles is refused.
- **`--tag` on `show`/`show-all` filters instead.** Repeating it is an **AND**, and
  matching is case-insensitive.
- ⚠️ **The index survives filtering.** What `show --tag PTA` prints is each
  reminder's position in the whole list, not 1..n of the filtered view, so it stays
  valid for `edit`/`complete`/`delete`.
- **There is no `search` subcommand**, and `--tag` is the only content filter. To
  match on title text, pipe `--json` through `jq`.
- 🛑 **A tag is invisible to EventKit and does not touch the title.** A tagged
  reminder's title comes back byte-identical, with no `#PTA` in it. So a `PTA: `
  title prefix and a real tag are **not** interchangeable, and nothing converts one
  to the other. `show`/`show-all` report them as `tags` in JSON (absent when there
  are none) and as `#tag` in plain output.
- 🛑 **A tag containing a space is silently rewritten, not rejected.** `two words`
  stores as `twowords`, and the save reports success. Refused up front, naming the
  substitute. A leading `#` is refused too — it is punctuation the app adds when
  rendering, so storing it yields `##PTA`.
- ⚠️ **Matching is case-insensitive, display case is kept.** Adding `pta` to
  something already tagged `PTA` is a reported no-op.
- ⚠️ **Tagging is a second write through a different framework.** On `add` the
  reminder exists before tagging can fail, so read "tagging failed" as "created but
  untagged", not as "nothing happened". Every tag write is read back from a fresh
  store and fails naming what did not land.
- ⚠️ If macOS ever moves the private API, tags degrade to unavailable — `--tag`
  refuses with an explanation and everything else keeps working.

### calendar — `apple calendar`

Swift + EventKit. Read and write events. The measurements behind every rule
below — the four-year fetch clamp, the recurrence spans, the sync join, the
`resync` rebuild — are in
[`docs/apple-calendar-eventkit.md`](docs/apple-calendar-eventkit.md).

```
apple calendar calendars [--writable] [--json]
apple calendar events [--from DATE] [--to DATE | --days N] [--calendar NAME]
                      [--search TEXT] [--json]         # default: next 7 days
apple calendar show ID [--occurrence DATE] [--json]
apple calendar add "TITLE" --start DATE [--end DATE | --duration MINUTES]
                          [--calendar NAME] [--all-day] [--location TEXT]
                          [--at PLACE] [--notes TEXT] [--url URL] [--invitee ADDR]... [--json]
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

Dates accept natural language (`tomorrow 2pm`) or `YYYY-MM-DD [HH:MM]`. Default
event length is 1 hour. `--calendar` must match a name from `calendars` exactly
(case-insensitive); subscribed and holiday calendars are read-only.

⚠️ **Calendar titles are not unique.** A subscribed read-only "Birthdays" can sit
alongside a writable one of the same name, so `--calendar NAME` matches *every*
calendar with that name when reading and prefers a writable one when writing.
When it matters which one you got, read the `calendar` field on each event.

**Every write is confirmed twice: against a fresh store, then against the
server.** 🛑 `EKEventStore.save` returning true is not evidence the change
persisted, and a local save says nothing about the server — `add` once returned
exit 0 and a full event record for a write Google CalDAV refused with **HTTP
403**. So `edit` re-reads and compares each field it changed, retrying once and
exiting non-zero naming any mismatch; both commands then wait for the push.
Measured round trip: **4.2s on calDAV, 3.1s on Exchange.** `--no-confirm-sync`
opts out, `--sync-timeout` defaults to 30s.

- **Read `sync.state`.** `synced` means the server has it. `notApplicable` means
  there is no server. `unknown` means the tool could not check, which is **never**
  a failure. An Exchange *edit* is always `unknown`, because Exchange records
  nothing locally when an edit lands.
- 🛑 **`pending` at the deadline exits 75, and that is not a failure.**
  `EX_TEMPFAIL` — the write is saved and the event record is still printed. A
  **refusal** — the server answering 403 or 400, EventKit recording an `Error`
  row — still exits 1. The two need opposite responses. ⚠️ Until 26.820.1 both
  threw `ValidationError`: exit 64, and **no event printed at all**, so a `--json`
  caller had no id to check with.
- ⚠️ **`sync-status`, `unsynced`, `sync-errors` and `resync` read
  `Calendar.sqlitedb`, which needs Full Disk Access** — a different grant from the
  Calendar one. Without it the answer is `unknown`, and a good write must not be
  called broken.
- 🛑 **An `Error` row is only evidence about the write that made it.** Rows are
  matched on `CalendarItem.ROWID`, and only rows created *since* the save count —
  a stale row once made a healthy calendar fail every write. See
  [`docs/apple-calendar-caldav-403.md`](docs/apple-calendar-caldav-403.md).
- **`resync` rebuilds an event the server never accepted**, because EventKit
  stops retrying once it records an `Error` row. It creates the copy **before**
  deleting the original, refuses a recurring event even with `--force`, refuses
  one with invitees without `--force`, and mints a new identifier.

🛑 **EventKit clamps one fetch to four years from the start, silently** — no
error, no warning, and an empty tail reads exactly like a quiet stretch of
calendar. An 18-year search returned 1,138 of 14,616 events and looked complete.
`events` splits the range into four-year windows and says so on stderr.

**Recurring events.** An event ID identifies the *series*, not the instance you
saw — EventKit resolves it to the first occurrence, often years earlier. So:

- `events --json` sets an **`occurrence`** field on recurring events. Pass it
  straight back as `--occurrence` to act on that instance.
- `edit` and `delete` **refuse to run** on a recurring event unless you pass
  either `--occurrence DATE` or `--series`. They will not guess.
- `show` without `--occurrence` returns the series master and says so on stderr.
- **`--series` means the whole series**, and it never detaches one. `--future`
  applies a change to this occurrence and all later ones.
- ⚠️ **Rescheduling one occurrence detaches it.** `edit ID --occurrence <date>
  --start <new>` works, including onto a different day, and the instance stops
  being part of the series: `recurring` goes false and its id gains a
  `/RID=<seconds>` suffix. From then on it is an ordinary event — `edit` and
  `delete` it by its **own** id.
- 🛑 **A `--series` write destroys detached occurrences**, because EventKit
  rebuilds the series from the rule. `edit --series` and `invite --series` refuse
  when the series has exceptions, name each one, and require `--reset-exceptions`.
  ⚠️ Per-occurrence work converts a clean series into all exceptions, which is a
  one-way door.

**Recurrence flags** match `apple reminders`: `--repeat
none|daily|weekly|monthly|yearly` (`-r`), `--repeat-interval N`,
`--repeat-until DATE`, `--repeat-count N`. `events --json` reports a
`recurrence` object (`frequency`, `interval`, `until`, `count`, `on_the`).

**`--on-the` is the one flag reminders has no equivalent for**, because
`--repeat monthly` alone cannot say "the 4th Monday": a plain monthly rule
repeats on *the start date's day number*, so a series starting Mon 28 Sep recurs
on the 28th. The two coincide for exactly one month and then diverge silently.

```
apple calendar add "Board" --start "2026-09-28 10:00" \
    --repeat monthly --on-the "4th monday"
```

Takes `4th monday`, `last friday`, a bare weekday (means the first), a day number
like `15`, or `last`. Requires `--repeat monthly`. ⚠️ A `--start` that does not
match the pattern is a **warning, not an error**. **Changing how an event repeats
requires `--series`**, since a rule belongs to the series; `--repeat none`
removes recurrence entirely.

🛑 **`--location` is text and gets no map pin; `--at` is the flag that does.**
EventKit keeps the coordinate on a separate `EKStructuredLocation`, and only that
coordinate produces a map thumbnail or a travel-time alert.

```
apple calendar add "Bagels" --start "tomorrow 9am" \
    --at "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO"
```

`--at` resolves the place through Apple Maps and sets the coordinate itself, then
sets `location` to the resolved address. **This is a network call** — the only one
`apple-calendar` makes. `--pin-radius` sets the geofence size, `--near` biases the
search, `--clear-pin` removes the coordinate and leaves the text.

- ⚠️ **`--location` never geocodes, deliberately.** A location that is not a
  place — "Zoom", "my desk", a room name — must not be silently turned into a
  coordinate somewhere else in the world.
- **Nothing geocodes a string after the fact**, not EventKit, not the server, not
  Calendar.app. That is why `--at` has to do it at write time.
- ⚠️ **Ambiguity is refused, not guessed.** A shop name matching branches more
  than 250 m apart is an error listing them. Narrow with `--near`, or pass
  `"lat,lon"`.
- **`events`/`show --json` report `geo`** (`title`, `latitude`, `longitude`,
  `radius`, `has_coordinate`), and omit the key entirely when there is no
  structured location. **`has_coordinate` is how you check a `--at` write landed**
  — `location` alone cannot tell a geocoded address from a typed one.

**`--url` is writable on `add` and `edit`, and `--url ""` clears it.** An event's
`url` is a separate field from `location` and `notes`, and calendar clients turn
it into the join button — so a synced event can carry a **stale** meeting link
there while `location` holds the current one, and the stale one wins.

- **`--url ""` reaches `nil`**, not an empty URL, and the read-back check treats a
  cleared URL as absent.
- **A string that is not a URL is refused**, naming it. A scheme is required:
  `example.com` is rejected, `https://example.com` and `zoommtg://…` are taken.
- A URL in `--location` is fine and stays verbatim, but prefer `--url`.

**Invitees.** `events --json` reports `attendees` (objects, with `name`, `email`,
`status`, `role`, `type`, `organizer`, `is_me`), a separate `organizer`, and
`my_status` — the user's own response, which is what "have I accepted this?"
actually asks. ⚠️ **`attendees` is an array of objects, not name strings**; read
`.attendees[].name`. ⚠️ **The organizer is usually *not* in the attendee list.**

🛑 **`apple calendar invitees ID` is the read path, and `invite` is the write
path.** Reading the guest list must never require changing it. ⚠️ `invitees
--json` always carries `attendees` (`[]` when empty) and `count`, so emptiness is
never inferred from an absent key — `events --json` omits the key entirely, and a
careful reader once concluded the field had been dropped from the build.

🛑 **Writing invitees sends real mail, and there is no undo.** `add --invitee`
and `invite --add` make the server email an invitation; `invite --remove` and
deleting the event email a cancellation. **Run `invite --dry-run` first** — it
resolves and prints the plan without contacting the server at all. Both backends
send genuine iTIP mail; Google delivers in ~40s, Exchange under a minute. Full
record in
[`docs/apple-calendar-invitees.md`](docs/apple-calendar-invitees.md).

- 🛑 **There is no public API for this.** Writes go through private
  `EKAttendee.attendeeWithName:emailAddress:` + `addAttendee:`/`removeAttendee:`,
  resolved at runtime. If a future macOS drops them, reading still works.
- 🛑 **Only the organizer can change who is invited.** On someone else's event a
  local change *appears to succeed* and is then reverted by the server, so
  `invite` refuses up front. **`edit` refuses an invitation you received** for the
  same reason; the test is "am I an attendee", not "am I the organizer", because
  a delegated calendar has neither. `--force` overrides it.
- 🛑 **On Exchange an invitee change can be discarded after it is confirmed.**
  Five of nine per-occurrence invites on one real series survived and three
  reverted. So `invite` waits `APPLE_CALENDAR_INVITE_SETTLE` seconds (default 12),
  re-reads, and **fails naming the addresses that did not survive**.
- ⚠️ **Local attendees and delivered mail disagree in both directions** — a
  reverted change still mailed people, and an event that kept its attendees never
  mailed anyone. "invitees: 8" is not evidence anyone was invited, and an empty
  list is not evidence nobody was. Check OWA or the web UI when it matters.
- 🛑 **Match invitees on the email address, never the name or role** — the server
  rewrites both. `Dan Hopkins`/role `unknown` came back as
  `dan@boulderhopkins.com`/role `required` after one round trip.
- 🛑 **EventKit adds the organizer and a self-attendee itself on save.** Don't
  call `addOrganizerAndSelfAttendeeForNewInvitation`. ⚠️ Removing the last invitee
  empties the list entirely, because the self-attendee goes with it.
- Addresses take `a@b.com` or `Name <a@b.com>`. Matching is case-insensitive, and
  re-adding someone already invited is a reported no-op.

🛑 **There is no "propose a new time" and no way to build one** — it is a
Calendar.app feature with no API anywhere. Tell the user to use Calendar.app; do
not offer an `edit` instead, which is a different thing that does not work.

### contacts — `apple contacts`

Swift + Contacts framework (`CNContactStore`). Full CRUD. The measurements,
failure histories and framework traps behind every rule below are in
[`docs/apple-contacts-writes.md`](docs/apple-contacts-writes.md); moving a
contact between accounts is in
[`docs/apple-contacts-move.md`](docs/apple-contacts-move.md).

```
apple contacts search TERM [--limit N] [--plain]   # default limit 25
apple contacts get ID [--plain]
apple contacts list [--limit N] [--plain]          # default limit 100
apple contacts add [FIELDS] [--container NAME] [--json]
apple contacts edit ID [FIELDS] [--clear-dates] [--json]
apple contacts move ID --to CONTAINER [--dry-run] [--json]
apple contacts delete ID
apple contacts export ID... [--group GROUP] [-o FILE]   # vCard 3.0, notes included
apple contacts deceased [--json]                   # everyone recorded as having died
apple contacts relations ID [--json]               # who this contact links to, resolved
apple contacts link A B --relation LABEL [--inverse LABEL] [--no-inverse]
                        [--name-only] [--dry-run]
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
--died YYYY-MM-DD|YYYY|--MM-DD
--email    [LABEL:]ADDRESS   repeatable
--phone    [LABEL:]NUMBER    repeatable
--url      [LABEL:]URL       repeatable
--address  [LABEL:]ADDRESS   repeatable
--relation LABEL:NAME        repeatable
--date     LABEL:DATE        repeatable
--note TEXT | --append-note TEXT | --clear-note
```

🛑 **Multi-value flags replace; `--add-*` appends.** Passing `--email` on `edit`
replaces *every* existing email on that contact, and prints `Updated '<name>'`
either way. The name reads as additive: `edit --url X` looks like "set the URL",
not "delete every URL, then set X".

```
apple contacts edit <id> --add-url "wiki:https://c.example.com"    # keeps the rest
apple contacts edit <id> --remove-url "https://b.example.com"      # drops just that one
apple contacts edit <id> --url "only:https://d.example.com"        # deletes the rest
```

⚠️ **Agents are the caller this hurts most.** One told to "add the school
website" has no reason to read the card first. A peer session nearly destroyed a
real contact's URLs that way — the card happened to hold exactly one, so the
replace was indistinguishable from an update.

- `--add-email`, `--add-phone`, `--add-url` and `--add-address` keep what is
  there. The plain flags still replace, so nothing that relied on them breaks.
- ⚠️ **Re-adding an existing value is a reported no-op, not a duplicate row** —
  the shape `link` and `groups add` use. Phones compare on **digits**, so
  `+1 (555) 000-0001` does not land twice beside `+15550000001`. The same value
  under a *different* label is a new entry.
- ⚠️ **Mixing `--email` with `--add-email` is refused**, since "replace then add"
  and "add to what was set" differ and one reading loses a value. `apple
  reminders` refuses `--tag` alongside `--add-tag` for the same reason.
- 🛑 **The AddressBook fallback writes the whole multivalue at once**, so an
  append reads the existing entries back first. A replace does not need to. That
  is the path where getting it wrong deletes the values it was meant to keep, and
  it is the normal path for the 52 note-bearing contacts here.

🛑 **`--remove-*` is how you delete ONE value.** Before it existed the only route
was the plain flag: read the card, then re-pass everything except the entry to
drop. That makes the caller reconstruct each remaining label exactly, so one typo
turns a deletion into a silent loss of something else.

- ⚠️ **The VALUE identifies the entry; a label only narrows it.** Same shape
  `unlink` uses. `--remove-url https://b` drops it under any label;
  `--remove-url "blog:https://b"` drops only the labelled one.
- 🛑 **A removal matching nothing is an ERROR**, and the message names what the
  card does hold. A no-op would let `--remove-email a@x.con` read as done. That
  is deliberately the opposite of `--add-*`, where re-adding an existing value
  already achieves the intent.
- ⚠️ **Removal runs before the append**, so `--remove-x A --add-x A` ends with A
  present. The other order would delete what was just added.
- 🛑 **An address is nameable by its street or its full structured form**, and
  the pre-flight check must accept exactly what the write removes. Checking only
  one form refused `--remove-address "work:1 Main St"` for an address the write
  would have taken.

⚠️ **A plain flag now says what it discards**, and still replaces:

```
warning: --url replaces every url on this contact. Discarding 2 (work, blog).
         Use --add-url to keep them, or --remove-url to drop just one.
``` `--clear-dates` empties the labelled-date set (the
birthday is a separate field and survives); it is refused alongside
`--date`/`--anniversary`, allowed alongside `--died`.

⚠️ **`--MM-DD` needs `=`.** `--birthday --04-13` fails, because the parser reads
the value as the next flag. Write `--birthday=--04-13`, and likewise for
`--anniversary`, `--date` and `--died`.

**Every write is read back and checked.** `add` and `edit` re-read the contact
and confirm each labelled value asked for is really there, failing loudly
otherwise. It is a subset check, because `get` returns the unified contact and a
linked card can contribute values this edit never mentioned.

⚠️ **`delete` is permanent.** Unlike Notes there is no Recently Deleted, and the
deletion syncs everywhere. Always confirm with the user first. Deleting a
*group* keeps its contacts; removing a member keeps the contact too.

**Labels.** Friendly names: `home`, `work`, `school`, `other`, plus `mobile`,
`iphone`, `main`, `pager`, `applewatch` for phones, `icloud` for email and
`homepage` for URLs. Unlabelled values are accepted for email/phone/url. **Any
other label is kept as a custom label, with its case** — `--url
"LinkedIn:https://…"` reads back as `LinkedIn`. That is what makes the "read it
first, re-pass what you want to keep" workflow safe: **`get` → `edit` → `get` is
a no-op** for every multi-value field, pinned by a test.

⚠️ **`--url` splits on the first colon and has to decide whether the prefix is a
label or a scheme.** A built-in label wins; otherwise a prefix is a scheme when
the rest starts `//` or is one unbroken token with no scheme of its own.
`LinkedIn:https://x.com` stays a label, `webcal:cal.example.com/f.ics` is a URL,
and the genuinely ambiguous `LinkedIn:example.com` is read as a URL with a note
on stderr. 🛑 The older allowlist stripped schemes silently.

**Postal addresses.** `--address` takes free text or exact fields:

```
apple contacts edit ID --address "home:500 W Madison St, Chicago, IL 60661"
apple contacts edit ID --address "home:street=500 W Madison St;city=Chicago;state=IL;zip=60661"
```

⚠️ **Free text is a guess, and the tool prints what it decided** on stderr before
writing. It knows one shape, `street, city, STATE ZIP, country`, and nothing
about any other country's conventions. When it gets one wrong, use the
`key=value` form; `zip` and `postalCode` are both accepted, so what `get` prints
can be passed straight back. A typo'd key is a hard error, not a dropped field.

**Deaths.** `--died` on `add`/`edit` writes one, `deceased` lists them.

```
apple contacts edit <id> --died 2020-04-30     # a full date
apple contacts edit <id> --died 2020           # only the year is known
apple contacts edit <id> --died=--04-30        # the day, but not the year
```

🛑 **Apple defines no death field**, so it is a custom date label — `death`, or
`death-year` when only the year is known. Contacts refuses a date with no month
and day, so **a year-only death stores a placeholder `2020-01-01`** and the label
is the only disclosure.

- **Read `died`, never the raw `dates` array**, which still shows the
  placeholder. **`died_precision`** is `date`, `year` or `day-only`.
- **`deceased` is absent, never `false`**, like every other optional key here.
- 🛑 **`--died` merges; `--date` replaces.** That is the whole reason it is its
  own flag. Restating `--died` at a different precision replaces the old entry.
- 🛑 **`--died` also marks the note with `«†»`**, because on this address book
  recording a death and marking the card are one act. `--no-mark` records the
  date alone, and is the escape hatch when Automation → Contacts is missing.
- ⚠️ **Written as `«†»`, detected as a bare `†`.** A card marked by hand or on
  another device counts as marked and is never marked twice. The marker goes on
  top, then a blank line, then whatever the note already held.
- **`--clear-note` with a marking `--died` is refused**, and so is `--no-mark`
  on its own. Neither combination has one meaning.
- **`marked_without_date`** lists cards whose *note* carries a dagger and which
  record no date. That marker is never the record and never makes anyone
  deceased. Resolve one with `edit --died`.

**Relations.** `--relation father:"Robert Hopkins"`. All 216 SDK relation labels
are accepted; matching ignores case, spaces and hyphens. An unrecognised label is
still stored, as a custom label, with near matches on stderr.

```
apple contacts relations <id>                       # both directions
apple contacts link <id> <id> --relation spouse     # writes both cards
apple contacts link A B --relation father --inverse son
apple contacts link A "David M. Merritt" --relation spouse --name-only
apple contacts unlink A B --relation friend
```

- 🛑 **A relation stores a NAME, not a reference.** Renaming a contact silently
  breaks every link to it, a relation can name nobody, and a relation can name
  several people. `matches` in the JSON says which you have.
- 🛑 **`link` appends; `edit --relation` replaces.** Adding one relation through
  `edit` means re-passing every existing one, and forgetting one deletes it.
- ⚠️ **`link` writes the other card too**, so it states a fact about someone else.
  **The label describes the SECOND contact**: `link A B --relation manager` reads
  "B is A's manager", and gives B an `assistant` relation naming A.
- 🛑 **A gendered label inverts to the neutral term** — `father` → `child`,
  `brother` → `sibling`. Pass `--inverse son` for the specific one. Seven labels
  have no neutral inverse and refuse, naming what to pass instead.
- 🛑 **`--name-only` is the one way to name somebody who has no card**, and it is
  opt-in so a typo in a real name is still refused.
- **Both arguments take an id or a name.** An ambiguous name is refused listing
  the candidates. Re-linking is a reported no-op, not a duplicate. Every write is
  confirmed against a fresh store. `--dry-run` prints the plan without writing.

**Dates.** `--birthday` and `--anniversary` are the two Contacts models natively.
Everything else is a labelled date: `--date graduation:--06-15`.

**Search** matches first/middle/last/nickname/company/department/job title/full
name, email addresses, and phone numbers (digits only, so `7205551234` finds
`+1 (720) 555-1234`). **JSON is the default**; pass `--plain` for human output.

**Output shapes.** `get`, `add` and `edit` return a single JSON **object**;
`search`, `list` and `groups members` return **arrays**. An unlabelled email,
phone or URL omits the `label` key rather than emitting `null`. The JSON keys for
the name affixes are `prefix` and `suffix`, though the flags are `--name-prefix`
/ `--name-suffix`.

**Groups, and the account rule.** 🛑 **A contact can only join a group in its own
account**, and one save cannot span two containers. `groups add` detects the
mismatch before saving, names both accounts, and points at `move`:

```
Error: cannot add 'Kyle Zehner' to 'Recruiters': they are in different accounts,
and one save cannot span two.
  contact: On My Mac (local)
  group:   🌈 (cardDAV)
Move the contact into the group's account, then retry:
  apple contacts move <id> --to "_local:ABAccount" --dry-run
```

- ⚠️ **`changed` is the field to read on `groups add`/`groups remove`, not the
  exit code.** Both return `{group, contact_id, member, changed}`: `member` is
  the state after the call, re-read to confirm it; `changed` says whether *this*
  invocation did it. Both fail loudly if a save reports success without taking
  effect.
- 🛑 **`groups remove` silently does nothing on an iCloud group** through
  `CNSaveRequest`, and falls back to the legacy AddressBook framework.
- 🛑 **A contact has two identifiers**, unified and container-backed, and a
  membership check must accept both. Never hand `addMember` a *unified* contact.
- ⚠️ **An unrecognised `--container` is a hard error**, not a silent default.
  Names work as well as ids: `--container "On My Mac"`.

**`move` changes a contact's account and keeps its identifier.** There is no
public API for it; the legacy `importPeople:intoAccount:createNewUIDs:false` is
the only route that preserves the id and the note.

```
apple contacts move ID --to CONTAINER [--dry-run] [--json]
```

- 🛑 **The obvious private call lies.** `nts_MoveIntoAddressBook:account:error:`
  returned `YES` for a record still in the source store. So `move` re-reads the
  container from a fresh store and exits non-zero on a mismatch.
- 🛑 **A contact that carries a note cannot be moved** — copying the note faults
  it, and Core Data *raises* there rather than returning. Refused up front. Move
  those in Contacts.app.
- ⚠️ **A move always drops every group membership in the account it leaves.**
  `--dry-run` lists them first; the result carries `groups_left` either way.
- If the removal fails, the import is **rolled back**; if the copy cannot be
  named precisely, nothing is deleted and the duplicate is reported.
- ⚠️ Only `local` ↔ `cardDAV` has been exercised. The **"me" card** is untested.

🛑 **A note blocks *every* `CNContactStore` write to that contact**, not just the
note, and it fails as a bare `NSCocoaErrorDomain 134092` naming nothing. **52 of
669 contacts here carry one.** `edit`, `groups add`, `link` and `unlink` catch it
and rewrite through the legacy AddressBook framework, which needs no extra grant.

**Writing the note is the one thing that leaves the Contacts framework.**
`CNContactNoteKey` needs `com.apple.developer.contacts.notes`, which no CLI can
hold, so `--note` goes through Contacts.app over AppleScript. Full record in
[`docs/apple-contacts-writes.md`](docs/apple-contacts-writes.md).

```
apple contacts edit <id> --note "text"          # replaces the whole note
apple contacts edit <id> --append-note "line"   # keeps it, adds a line
apple contacts edit <id> --clear-note           # deletes it
```

- 🛑 **The legacy AddressBook framework is NOT a second route, despite being the
  fallback for every other field.** Measured: `ABPerson` + `kABNoteProperty` read
  **0 notes across 683 contacts**, raising the same 134092 on every one, while
  `get` reported 52 off SQLite at that moment. It gets *past* the wall, not
  *through* it.
- ⚠️ **`--note` replaces the whole note**, and warns naming the characters and
  lines it discards. **`--append-note` keeps it** and adds a line. Mixing the two
  is refused, as is `--clear-note` with either. Same rule as `--email` /
  `--add-email`.
- ⚠️ **A note write needs Automation → Contacts and launches Contacts.app.**
  Reads need neither. `apple contacts status` reports it as `automation` /
  `note_writes`; `usable` stays keyed to the Contacts grant, so a missing
  Automation grant costs one field rather than the tool.
- 🛑 **On `add` the note is a second write**, and the contact exists before it can
  fail. Read "the note did not land" as *created but un-noted*.
- **Every write is confirmed twice**: Contacts.app returns what it wrote, and
  `NoteStore` re-reads the SQLite store. Multi-line notes, emoji, quotes,
  backslashes and tabs all round-trip byte-identical.
- ⚠️ **`--clear-note` is idempotent** and makes `get` omit the `note` key
  entirely, never report `""`.

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
                          NoteWriter.swift (🛑 the one write that leaves the
                          Contacts framework — a note needs an entitlement no
                          CLI can hold, so it goes through Contacts.app),
                          Move.swift (the private cross-account move)
  Sources/ContactsLibrary/  PostalAddress.swift — the --address parser,
                          RelationGraph.swift — which relation labels invert and
                          which must never be guessed, and DeathDate.swift —
                          🛑 how a death is spelled, and why a year-only one
                          stores a day it never had. Its own target so all three
                          are testable without writing a contact
  Sources/ObjCExceptions/ @try/@catch for Swift — the move raises rather
                          than returning when it hits the note wall
  Tests/RemindersTests/ MailTests/ MessagesTests/ PhoneTests/ MapsTests/
        GeocodingTests/ CalendarSyncTests/ ContactsTests/
notes/                    Python; apple-notes, notestore.py, notestore.proto,
                          mergeable.py (ZMERGEABLEDATA1 reader — recordings,
                          transcripts, summaries, and table cells),
                          tests/ (live Notes.app suite +
                          test_markdown_capabilities.py and test_delete.py;
                          plus offline test_rendering.py, test_tables.py,
                          test_write_path.py)
notes/capability-report   measures the Markdown matrix, writes the doc, and
                          `--check`s it — the alarm for a macOS update moving
                          the API surface
notes/shortcuts/          .shortcut build scripts + signed files to install
util/check-mail-intents   is Mail's ComposeMessageIntent reachable yet? (exit 0
                          if something changed)
util/check-spotlight      is CoreSpotlight readable from a CLI yet? (exit 0 if
                          something changed) — the answer to "why not Spotlight"
util/appintents-dump      dev-only reader for an app's App Intents schema
Formula/apple-tools.rb    Homebrew formula
VERSION                   CalVer YY.MMDD.Patch, stamped in by scripts/set-version
```

`apple-notes` is the only Python tool left; stdlib-only, runs on the system `python3`.

**`docs/` holds the measurements this file only summarises.** Read the one for the
tool you are changing before you change it — every claim in there was paid for.

| File | What it settles |
|---|---|
| `apple-notes-api.md` | NoteStore schema, the AppleScript API, verified bugs |
| `apple-notes-rendering.md` | how a note body becomes Markdown: the weight enum, the three link mechanisms, the escaping, the line breaks a renderer honours |
| `apple-notes-writes.md` | the Shortcuts write path, the picker trap, the silent unallowed shortcut, `delete`, and every AppleScript body-write gotcha |
| `apple-notes-shortcuts.md` | driving Notes' AppIntents from the CLI — the only route to checklist writes and a real append |
| `apple-notes-transcripts.md` | where call recordings store their transcript, and the four traps in decoding it |
| `apple-notes-tables.md` | where a table keeps its cells, and the UTF-16 run-length bug an emoji exposes |
| `apple-notes-markdown-support.md` | GENERATED by `notes/capability-report`. Never edit by hand |
| `apple-mail-store.md` | Envelope Index schema, `.emlx` layout, verified traps |
| `apple-mail-drafts.md` | why apple-mail never writes a body: the cite-blockquote wrapper, every route ruled out, and why `--attach` is the one exception |
| `apple-mail-wedge.md` | how Mail's scripting interface goes under, the deadlines that keep it up, and why `move` is allowed to exist |
| `apple-messages-store.md` | chat.db schema, the typedstream body, verified traps |
| `apple-phone-store.md` | CallHistory schema, the entitlement walls, verified traps |
| `apple-maps-store.md` | MapsSync schema, why the location table overcounts, and why nothing here writes |
| `apple-geocoding.md` | the one network call: what uses it, the local-first rule, and why reminders cannot read the Maps store |
| `apple-reminders-tags.md` | tags have no public API at all — the private call that works, and the store behind it |
| `apple-calendar-eventkit.md` | the four-year fetch clamp, the recurrence spans, the sync join, the `resync` rebuild, and the test-suite rate limit |
| `apple-calendar-invitees.md` | reading invitees is public API, writing them is not; what the server rewrites, and what it mails |
| `apple-calendar-caldav-403.md` | the two ways a calendar write reports success and never reaches the server. Neither is reproducible on demand |
| `apple-contacts-writes.md` | the note wall, the group/account rules, the `--url` split, the address parser, deaths, and relation inverses |
| `apple-contacts-move.md` | no public API changes a contact's container; the private call that lies, the one that works, and what a move costs |
| `apple-health.md` | 🛑 there is no Health data on a Mac: what was measured, why signing does not help, and the four routes off the iPhone |
| `prior-art.md` | other projects solving this; check before building |
| `todo-deep-links.md` | planned: a `url` on every entity, so anything we name can be opened and cross-linked |
| `todo-offline-tests.md` | planned: move the Notes suite off live Notes.app so it can run in CI at all |

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
| contacts | Privacy & Security → Contacts; Automation → Contacts to write a note |
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
