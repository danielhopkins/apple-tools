# apple-tools

CLIs for reading and writing local Apple app data: Notes, Mail, Messages,
Reminders, Calendar, Contacts. Everything runs locally against the user's real data — no
network, no sync service, no API keys.

## Quick reference

All tools are reachable through the `apple` dispatcher, or directly by name if
installed via `make install`.

| Task | Command |
|------|---------|
| Search notes | `apple notes search "budget" --json` |
| Read a note | `apple notes export 261` |
| List note folders | `apple notes folders --json` |
| Search mail | `apple mail search "invoice" --json` |
| Full-text mail search | `apple mail search "budget" --field content --json` |
| Read an email | `apple mail export <message-id>` |
| List mail accounts | `apple mail accounts --json` |
| List conversations | `apple messages chats --json` |
| Search messages | `apple messages search "dinner" --json` |
| Read a conversation | `apple messages export 8 --limit 50` |
| Today's reminders | `apple reminders show-all --due-date today --include-overdue --json` |
| Add a reminder | `apple reminders add Soon "Buy milk" --due-date "tomorrow 9am"` |
| This week's events | `apple calendar events --days 7 --json` |
| Add an event | `apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45` |
| Find a person | `apple contacts search "smith" --json` |
| Update a contact | `apple contacts edit <id> --company "New Co"` |
| Export contacts | `apple contacts export --group "Family" -o family.vcf` |

**Every tool supports `--json`.** Prefer it — the plain output is for humans and
its shape is not stable. Use `apple --which` to see which binary each name
resolves to.

**Check permissions before diagnosing an access failure.** `apple status`
reports all six in one table, never prompts, and exits non-zero if anything is
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
apple notes search [TERM] [--limit N] [--json] [--include-locked]  # title search
apple notes folders [NAME] [--limit N] [--json]  # all folders, or notes in one folder
apple notes export ID [-o out.md]                # note body as Markdown
apple notes get-url ID [--json]                  # applenotes:// deep link
```

`ID` accepts a numeric note ID, a note title, or an `applenotes://` URL.

**Search is title-only.** There is no full-text search over note bodies; to
search content, export candidates and grep them.

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

**Reads go to the files, writes go through AppleScript.** `search`, `export` and
`accounts` read Mail's own SQLite index and the `.emlx` files on disk, so they
work with Mail.app closed and return in milliseconds. `draft` and `send` still
drive Mail.app.

```
apple mail accounts [--json]      # names, addresses, mailboxes, enabled
apple mail search QUERY [--account NAME] [--mailbox NAME] [--field subject|sender|content|all]
                        [--since DAYS] [--before DAYS] [--limit N]
                        [--flagged] [--unread] [--has-attachment] [--attachment-names]
                        [--all] [--json]
apple mail export MESSAGE-ID [--account NAME] [--json] [--raw]
apple mail attachments MESSAGE-ID [--save DIR] [--skip-inline] [--account NAME] [--json]

apple mail draft --to ADDR [--to ...] [--cc ADDR] [--bcc ADDR]
                 --subject TEXT [--body TEXT | --body-file FILE|-]
                 [--from ACCOUNT-ADDRESS] [--html] [--attach FILE]...
                 [--replace MESSAGE-ID] [--json]
apple mail delete-draft MESSAGE-ID [--account NAME] [--json]
apple mail send  <same flags> --confirm
```

All three read commands take `--engine auto|filesystem|applescript`. Leave it
alone; `auto` uses the files and falls back to AppleScript when it can't (no
Full Disk Access, or a message whose body Mail hasn't downloaded yet).
`--engine filesystem` fails loudly instead of falling back, which is what you
want when diagnosing.

Measured on a 41k-message store, same binary, same query, Mail running:
`--engine filesystem` 0.04s, `--engine applescript` 154s.

**Searching is now cheap — search widely.** No `--limit`/`--since` discipline is
required, and there is no timeout to trip. The default covers every mailbox
except trash and junk (`--all` adds those), not the handful the AppleScript path
managed.

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
back to embedded bytes only for messages that really carry them (anything Mail
composed locally).

**What counts as an attachment is Mail's rule: a part with a filename.**
Verified against its index — a message with two nameless tracking pixels
reports zero attachments, one with seven named inline images reports seven. So
`attachments` and `export --json` always agree.

`--save` never overwrites: a name that already exists gets `-2` before the
extension. Filenames come from the sender, so they are sanitised to a bare
basename before being joined onto `DIR`, and a write that would land anywhere
else is refused.

See [`docs/apple-mail-store.md`](docs/apple-mail-store.md) for the schema, the
`.emlx` layout, and the traps in reading them.

**Picking the account.** `accounts` reports each account's `addresses` as well
as its name — those addresses are exactly what `--from` accepts. `--from` also
takes an account *name*, which matters here because the names are emoji and are
not themselves valid senders. Run `accounts --json` rather than guessing.

⚠️ **`accounts` is the one read command that still prefers Mail.app**, because
only Mail knows whether an account is `enabled`, and its account names are what
`--from` matches. It asks Mail when Mail is already running and reads the store
when it is not — rather than launching Mail just to list accounts, which is
what it used to do. Consequence: **the file-system answer has no `enabled`
key**, so read it as `account.get("enabled", True)`. It also lists the local
"On My Mac" store, which the AppleScript path omits.

**Drafting.** `draft` writes to the Drafts mailbox of whichever account matches
`--from` (your default account otherwise) and never sends. `--body-file -`
reads the body from stdin, which is the easiest way to pass long or generated
text. Attachments are validated before anything is composed.

`draft --json` reports the new draft's `message_id`; that is what `delete-draft`
and `--replace` take. It is omitted rather than guessed when the save could not
be identified unambiguously.

**Revising a draft.** There is no in-place edit — Mail will not allow one (the
sender freezes on save, and reading recipients back is broken). `--replace
MESSAGE-ID` does the next best thing: it writes the new draft first, *then*
trashes the old one, so a failure leaves two drafts rather than none. It checks
the target exists before composing, so a bad id writes nothing at all. If the
removal fails it says so on stderr and sets `replaced_removed: false` — do not
report a replacement as clean without checking that.

`delete-draft` only ever enumerates Drafts, so it cannot delete sent or
received mail even if handed the Message-ID of some. It re-reads the mailbox
afterwards and fails loudly rather than trusting the move, and it is a move to
**trash, not a purge** — same as Notes' Recently Deleted, with no API to empty
it.

`send` refuses to run without `--confirm`, because sending is immediate and
irreversible. **Prefer `draft` and let the user send it themselves** — only use
`send` when they have explicitly asked you to send, in that turn.

⚠️ Mail's compose surface is unusually buggy. These are all verified on
macOS 27 and pinned by `tests/test_mail_draft.py`:

- **Only one route removes a draft**, and `delete-draft` implements it so you
  do not have to. `delete` silently does nothing, `move` errors, and `set
  deleted status` fails with "Connection is invalid". Reassigning `mailbox of
  <message>` to the account's trash **does** work. The trash mailbox is named
  differently per account type (`Deleted Messages`, `Trash`, `Deleted Items`),
  so try each. Two traps: the Drafts enumeration is stale within a single
  script run, so collect message ids first and move each once rather than
  re-scanning after every move; and a move occasionally reports success without
  taking effect, so re-check and retry.
- **An outgoing message has no `message id`.** Asking for one errors with
  "Can't make «class meid» of «class bcke»" — Mail assigns it only once the
  message lands in Drafts. `draft` therefore learns the id by diffing the
  Drafts Message-IDs across the save, in a *separate* `osascript` run, because
  the Drafts enumeration is stale within the run that saved.
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

`--field` defaults to `subject`; use `--field all` or `--field content` when the
user describes content rather than a subject line. `--all` widens the search to
trash and junk, which are excluded by default — except when `--mailbox trash`
asks for them by name, which is honoured. Account names can contain emoji and
spaces — get exact strings from `apple mail accounts` rather than guessing.

⚠️ **The timeout trap applies only to `--engine applescript`.** AppleScript's
event timeout is ~120s; when it trips, `search` prints `[]` and exits 0, which
is indistinguishable from "no matches". If you ever see a search take about two
minutes and return nothing, it failed — don't report it as an empty inbox. The
file-system engine has no such mode: it either answers or errors. If `auto`
fell back it says so on stderr, so read stderr before believing an empty result.

⚠️ **Mailbox names are not unique** — three accounts can each have an `Archive`.
Every result carries both `account` and `mailbox`; use the pair.

⚠️ **A message can be in the index but not on disk** when Mail hasn't downloaded
the body. `export` says so explicitly rather than reporting the message missing,
and `auto` falls back to AppleScript, which can still fetch it.

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
apple contacts export ID... [--group GROUP] [-o FILE]   # vCard 3.0
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
swift/                    one Swift package, five binaries
  Sources/reminders/      + RemindersLibrary/
  Sources/AppleMail/      + MailLibrary/ (Envelope Index reader, .emlx/MIME)
  Sources/AppleMessages/  + MessagesLibrary/ (chat.db reader, typedstream decoder)
  Sources/AppleCalendar/
  Sources/AppleContacts/  + Notes.swift (SQLite note reader)
  Tests/RemindersTests/ MailTests/ MessagesTests/
notes/                    Python; apple-notes, notestore.py, notestore.proto,
                          tests/ (live Notes.app suite)
docs/apple-notes-api.md   NoteStore schema, AppleScript API, verified bugs
docs/apple-mail-store.md  Envelope Index schema, .emlx layout, verified traps
docs/apple-messages-store.md  chat.db schema, the typedstream body, verified traps
docs/prior-art.md         other projects solving this; check before building
Formula/apple-tools.rb    Homebrew formula
VERSION                   CalVer YY.MMDD.Patch, stamped in by scripts/set-version
```

`apple-notes` is the only Python tool left; stdlib-only, runs on the system `python3`.

## Building

```
make build      # swift build -c release → all five binaries
make install    # symlink dispatcher + tools into ~/bin
make dev        # debug build, shaded ahead of the installed copy — see below
make check      # smoke-test that every tool responds
make test       # Swift unit tests
make bump       # next CalVer for today, stamped into every tool
make dist       # universal release tarball + sha256 for the Homebrew tap
```

**Iterating on a tool.** `~/bin` is normally *after* `/opt/homebrew/bin` on
PATH, so `make install` cannot override a Homebrew install. `make dev` builds
debug (~2s) into `.dev-bin/` and prints the line to put that dir first:

```
make dev && eval "$(make -s dev-path)"
```

It shades `apple-mail` and `apple-notes` only, and symlinks the other three to
the installed copies. That is deliberate: reminders/calendar/contacts disclaim,
so their TCC grant is bound to the binary's path and a debug build at a new path
re-prompts for permission. mail and notes are attributed to the terminal, so
shading them is free. To work on one of the others, `make dev
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
| mail | Full Disk Access to read; Automation → Mail to draft/send |
| messages | Full Disk Access for the calling terminal (reads chat.db directly) |
| contacts | Privacy & Security → Contacts |
| notes | Full Disk Access for the calling terminal (reads sqlite directly) |

`mail` needs **two different grants for two different halves**. Full Disk Access
lets it read the index and message files — that covers `search`, `export` and
`accounts`. Automation → Mail is only for `draft` and `send`. `apple mail
status` reports both and counts the tool usable if either is present, so "mail
✓" can mean reads work and sending does not. Check the detail line before
concluding which half is broken.

`apple status` reports all six at once without prompting — start there rather
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

`mail`, `messages` and `notes` are *not* covered by this: Automation and Full Disk Access
are still attributed to the calling terminal, so those two really do depend on
which terminal is running. This now covers mail's read path too — reading the
Envelope Index needs Full Disk Access for whatever terminal launched the tool.

⚠️ **macOS only prompts when the status is `notDetermined`.** Once it is anything
else the request returns silently and no dialog ever appears. The trap is
Calendar's `writeOnly` ("Add Only") state: it looks granted, but cannot read
events, and macOS will not offer to upgrade it. `apple calendar status` reports
the real state without prompting — run it before concluding a grant is missing.
The remedy is always a manual toggle in System Settings, never a retry.
