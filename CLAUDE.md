# apple-tools

CLIs for reading and writing local Apple app data: Notes, Mail, Messages, Phone,
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
| Recent calls | `apple phone recents --json` |
| Who called while out | `apple phone recents --missed --since 7 --json` |
| Callers not in Contacts | `apple phone recents --unknown --since 30 --json` |
| Blocked callers | `apple phone blocked --json` |
| Place a call | `apple phone dial "Alice"` |
| Today's reminders | `apple reminders show-all --due-date today --include-overdue --json` |
| Add a reminder | `apple reminders add Soon "Buy milk" --due-date "tomorrow 9am"` |
| This week's events | `apple calendar events --days 7 --json` |
| Add an event | `apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45` |
| Find a person | `apple contacts search "smith" --json` |
| Update a contact | `apple contacts edit <id> --company "New Co"` |
| Export contacts | `apple contacts export --group "Family" -o family.vcf` |
| List contact accounts | `apple contacts containers --json` |

**Every tool supports `--json`.** Prefer it — the plain output is for humans and
its shape is not stable. Use `apple --which` to see which binary each name
resolves to.

**Check permissions before diagnosing an access failure.** `apple status`
reports all seven in one table, never prompts, and exits non-zero if anything is
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
   clearly asked for the write. Contacts writes sync to every device and there is
   no undo. `phone dial` places a real, billable call: Phone.app will ask the
   user to confirm, and that panel is theirs to click, never yours.
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
apple notes create [--title T] [--body TEXT | --body-file FILE|-] [--json]
apple notes append ID  [--body TEXT | --body-file FILE|-] [--json]
apple notes install-shortcuts [--force]          # install the write path
apple notes status [--json]                      # access + write-path state
```

**Writes go through Shortcuts, and the CLI hides that.** `create` and `append`
take a body the same way `mail draft` does — `--body`, `--body-file FILE`,
`--body-file -`, or a bare pipe — and the tool picks the payload shape and file
extension the underlying shortcut needs. Markdown becomes native structure:
`- [ ]` and `- [x]` are real checklists with their checked state, pipe tables
are real tables.

`append` is a genuine append: it **preserves attachments and existing
checklists**, unlike the AppleScript body write. It refuses when the title
matches more than one note rather than appending to all of them.

`ID` accepts a numeric note ID, a note title, or an `applenotes://` URL.

**Search is title-only.** There is no full-text search over note bodies; to
search content, export candidates and grep them.

**Writes need `install-shortcuts` first.** `apple notes status` reports whether
the write path is available and names anything missing; until then Notes is
read-only.

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
  Composing has *no* deadline on purpose: killing a save half-written is worse
  than waiting.
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
the consent dialog `status` exists to avoid. `responsive: false` means drafting
and sending will not work until Mail is restarted.

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
what it used to do. It also reads the store when Mail is running but *not
answering*, so a wedged Mail costs you the `enabled` field rather than hanging
the command. Consequence: **the file-system answer has no `enabled`
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

⚠️ **The timeout trap applied only to `--engine applescript`, and is now an
error rather than a silent one.** AppleScript's event timeout is ~120s, and the
script swallowed it, so `search` printed `[]` and exited 0 — indistinguishable
from "no matches". A timeout now fails loudly instead, whether it is Mail's
-1712 or our own deadline, including one that hits partway through a multi-account
walk (a short list from a half-finished search is a wrong answer, not a small one).
The file-system engine never had this mode: it either answers or errors.

⚠️ **Mailbox names are not unique** — three accounts can each have an `Archive`.
Every result carries both `account` and `mailbox`; use the pair.

⚠️ **A message can be in the index but not on disk** when Mail hasn't downloaded
the body. `export` says so explicitly rather than reporting the message missing,
and `auto` falls back to AppleScript, which can still fetch it — provided Mail is
already running and answering. With Mail closed it reports that instead of
launching it.

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

**`dial` hands a `tel:` URL to Phone.app and Phone.app always asks you to
confirm** — skipping the prompt needs `com.apple.FaceTime.NoPrompt`, an
Apple-internal entitlement. That prompt is the gate, so unlike `mail send` there
is no `--confirm` flag; and the tool will never click the panel for you. Use
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
  `AppleContacts` still uses `immutable=1` for the same files — fine for notes
  today, but the same latent staleness.)
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
```

**There is no move.** `CNSaveRequest`'s entire mutation surface is add / update /
delete for contacts and groups plus add / remove member — the container is fixed
at `addContact:toContainerWithIdentifier:` and `updateContact:` cannot change it.
Copying into the target container and deleting the original would mint a **new
identifier** (breaking every stored reference and its group memberships) and
**drop the note**, since notes are unwritable here. So the fix is to create the
contact in the right account, or move the card in Contacts.app.

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
swift/                    one Swift package, six binaries
  Sources/reminders/      + RemindersLibrary/
  Sources/AppleMail/      + MailLibrary/ (Envelope Index reader, .emlx/MIME)
  Sources/AppleMessages/  + MessagesLibrary/ (chat.db reader, typedstream decoder)
  Sources/ApplePhone/     + PhoneLibrary/ (CallHistory reader, AddressBook resolver)
  Sources/AppleCalendar/
  Sources/AppleContacts/  + Notes.swift (SQLite note reader)
  Tests/RemindersTests/ MailTests/ MessagesTests/
notes/                    Python; apple-notes, notestore.py, notestore.proto,
                          tests/ (live Notes.app suite)
docs/apple-notes-api.md   NoteStore schema, AppleScript API, verified bugs
docs/apple-notes-shortcuts.md  driving Notes' AppIntents from the CLI —
                          the only route to checklist writes and a real append
notes/shortcuts/          .shortcut build scripts + signed files to install
docs/apple-mail-store.md  Envelope Index schema, .emlx layout, verified traps
docs/apple-messages-store.md  chat.db schema, the typedstream body, verified traps
docs/apple-phone-store.md  CallHistory schema, the entitlement walls, verified traps
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
make build      # swift build -c release → all six binaries
make install    # symlink dispatcher + tools into ~/bin
make dev        # debug build, shaded ahead of the installed copy — see below
make check      # smoke-test that every tool responds
make test       # Swift unit tests (mail, messages, phone, reminders — all offline)
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
./tests/run-tests              # calendar writes (25) + mail wedge guards (21)
./tests/run-tests --mail       # + mail drafts (19)
./tests/run-tests --contacts   # + contacts writes (60)
```

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
| mail | Full Disk Access to read; Automation → Mail to draft/send |
| messages | Full Disk Access for the calling terminal (reads chat.db directly) |
| phone | Full Disk Access for the calling terminal (reads CallHistory + AddressBook) |
| contacts | Privacy & Security → Contacts |
| notes | Full Disk Access for the calling terminal (reads sqlite directly) |

`mail` needs **two different grants for two different halves**. Full Disk Access
lets it read the index and message files — that covers `search`, `export` and
`accounts`. Automation → Mail is only for `draft` and `send`. `apple mail
status` reports both and counts the tool usable if either is present, so "mail
✓" can mean reads work and sending does not. Check the detail line before
concluding which half is broken.

`apple status` reports all seven at once without prompting — start there rather
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

`mail`, `messages`, `phone` and `notes` are *not* covered by this: Automation and
Full Disk Access are still attributed to the calling terminal, so those four
really do depend on which terminal is running. This now covers mail's read path
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
