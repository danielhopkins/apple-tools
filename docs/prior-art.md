# Prior art

Other people solving the same problem — local CLI/agent access to Apple's apps.
Kept so that when we add a feature we check whether someone has already hit the
wall we're about to walk into.

**Metrics gathered 2026-07-27** and not maintained automatically; re-run the
commands at the bottom before trusting them. Everything below distinguishes what
was verified by reading code from what is only inferred from metadata — the
whole value of this file is that it doesn't guess.

## The field

| Project | Lang | ★ | Created | Last push | Notes |
|---|---|---|---|---|---|
| [supermemoryai/apple-mcp](https://github.com/supermemoryai/apple-mcp) | TypeScript | 3127 | 2025-02-19 | 2025-08-11 | **archived 2026-01-01** |
| [omarshahine/apple-pim](https://github.com/omarshahine/apple-pim) | Swift | 7 | 2026-01-22 | 2026-07-20 | largest codebase here |
| [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | TypeScript | 172 | 2025-02-14 | 2026-07-07 | Swift EventKit backend |
| [BRO3886/ical](https://github.com/BRO3886/ical) | Go | 68 | 2026-02-11 | 2026-06-21 | calendar only |
| [schappim/ekctl](https://github.com/schappim/ekctl) | Swift | 55 | 2026-01-21 | 2026-06-10 | no license |
| [more-io/claude-apple-bridges](https://github.com/more-io/claude-apple-bridges) | Swift | 29 | 2026-02-22 | 2026-07-03 | closest peer |

## Per project

### apple-mcp — the popular one, and dead

MCP server over Messages, Notes, Contacts, Mail, Reminders, Calendar, Maps.
By far the most adopted (3.1k stars) and **archived on 2026-01-01**, last pushed
2025-08-11. Treat as a museum piece, not a dependency.

Worth it for: **Maps**, now the only surface nothing here covers. Messages was
the other one until we built it — `chat.db` is readable the same way
`NoteStore.sqlite` is, and [`apple-messages-store.md`](apple-messages-store.md)
records what that took. Its per-app implementation is still unread, so whether
it decodes `attributedBody` at all is unknown; a Messages reader that does not
is missing ~4% of a long-lived store without saying so.

*Not verified:* its per-app implementation. The README doesn't say and the file
listing (`utils/{calendar,contacts,mail,maps,message,notes,reminders}.ts`)
doesn't either. If it turns out to be AppleScript throughout, assume it carries
every trap in [CLAUDE.md](../CLAUDE.md) — the Mail compose bugs, the 120s
AppleScript timeout that returns `[]`, the CardDAV `removeMember` no-op — none
of which are visible without testing writes against real data.

### apple-pim — the most substantial peer

300 files, ~40 test files, SwiftPM package plus a `helper/Info.plist`, pushed
2026-07-20. Spawns native Swift binaries (calendar, reminders, contacts, mail)
against EventKit and the Contacts framework — the same architecture as this
repo.

The `helper/` bundle is worth reading if we ever revisit TCC: an app bundle is
the other way to get a stable TCC identity, versus the disclaim trick we use.

*Verified by reading `swift/Sources/MailCLI/` — and we took the idea:*

- **Its mail reads do not use AppleScript.** `EnvelopeIndex.swift` opens
  `~/Library/Mail/V*/MailData/Envelope Index` read-only and joins
  `messages`/`message_global_data`/`subjects`/`addresses`/`mailboxes`;
  `EmlxReader.swift` parses bodies off disk. A `--engine auto|sqlite|jxa` flag
  runs SQLite first and falls back to JXA on any throw. This is a better idea
  than anything we had for mail and **we now do the same** — see
  [`apple-mail-store.md`](apple-mail-store.md). Their `emlxSubpath` digit
  scheme is correct; we re-derived it against a real store and it matches.
- **No `responsibility_spawnattrs_setdisclaim`** anywhere in the repo, so its
  Full Disk Access is terminal-attributed, same as ours.

Where we went further, having hit these on real data:

- **Content search.** They punt `--field content` back to JXA because the index
  has no bodies (`SQLiteEngine.swift:154`). We scan the `.emlx` files instead,
  concurrently and newest-first with early exit — full-text over a 41k store in
  ~9s worst case. This was the biggest win available and they left it.
- **WAL staleness.** Opening the index with `immutable=1` silently hides
  everything in the write-ahead log, which on this machine was 2.2 MB of the
  most recent mail. We open `mode=ro` so SQLite replays it, treat `immutable=1`
  as a fallback, and report the result as stale when we use it.
- **Account names.** They read `ZACCOUNTDESCRIPTION` from the child account row
  in `Accounts4.sqlite`; on this machine that is empty for every IMAP account
  and the real name lives on `ZPARENTACCOUNT`. Without the join you get UUIDs
  where the user expects names.
- **Trash/junk spellings.** Theirs lists junk names only; trash is
  `Deleted Messages` / `Deleted Items` / `[Gmail]/Trash` depending on account
  type, and missing one leaks deleted mail into results.

*Still not verified:* its calendar, reminders and contacts behaviour.

### claude-apple-bridges — closest to us in intent

Swift CLIs over Reminders, Calendar, Contacts, Notes, Mail, plus a `tmux-bridge`
we have no equivalent of. Ships a Claude skill, like we do. Solo project (54 of
55 commits by one person), but disciplined: 28 tagged releases in five months.

*Verified by reading the source and Makefile:*

- Compiles each single-file `.swift` with `swiftc`, embeds an `Info.plist` via
  `-sectcreate`, and codesigns with its own identifier
  (`com.claude.contacts-bridge`). **Independently arrived at the same usage-
  description approach we did** — good corroboration that it's correct.
- **No `responsibility_spawnattrs_setdisclaim`.** Its grants are still
  attributed to the calling terminal, so it has the failure we fixed in
  26.727.9: works in one terminal, silently denied in another.
- **No contacts groups at all** — no `CNGroup`, `addMember` or `removeMember` —
  so it never met the CardDAV silent no-op.
- Testing is one 188-line `test.sh`, ~13 assertions.

**Idea worth taking:** its newest commit is `fix(contacts): update appends
instead of replacing + add remove command`. That is the opposite of our
semantics — we document "multi-value flags replace, they don't append" as a
sharp edge. Theirs is arguably the safer default: ours means an agent that
passes `--email` without reading the contact first silently destroys the other
addresses. Changing it would break existing behaviour, so it needs a decision,
not a drive-by.

### mcp-server-apple-events

MCP server for Reminders and Calendar with a standalone Swift EventKit backend;
108 files, ~37 test-ish, `scripts/event-Info.plist`. Actively pushed
2026-07-07. Same embedded-plist approach again.

### ical

Go, EventKit via cgo, calendar only, 85 files with ~14 test files. Full CRUD,
natural-language dates, recurrence, and **import/export** — relevant now that we
have vCard export but no import. Claims ~3000× faster than AppleScript, which
matches why we moved off AppleScript for Calendar.

### ekctl

Small Swift CLI for Calendar and Reminders over EventKit with JSON output; 17
files, one test file. Same `Info.plist` + `Package.swift` shape as ours.
**No license file** — don't copy code from it.

## Notes specifically — the write side

**Gathered 2026-07-28.** The survey above is about the suite as a whole; this
section is about one question: *has anyone solved writing to Apple Notes better
than we have?* Notes has its own ecosystem, separate from the six-app projects
above, and it splits cleanly in two: **forensic readers** that decode
`NoteStore.sqlite` and never write, and **AppleScript wrappers** that write and
carry every trap we documented.

| Project | Lang | ★ | Last push | License | Writes? |
|---|---|---|---|---|---|
| [threeplanetssoftware/apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser) | Ruby | 537 | 2026-07-25 | MIT | no — forensic reader |
| [antoniorodr/memo](https://github.com/antoniorodr/memo) | Python | 316 | 2026-07-28 | Apache-2.0 | **yes, incl. image-preserving edit** |
| [RhetTbull/macnotesapp](https://github.com/RhetTbull/macnotesapp) | Python | 268 | 2026-01-29 | MIT | yes — ScriptingBridge |
| [dunhamsteve/notesutils](https://github.com/dunhamsteve/notesutils) | Python | 250 | 2022-12-06 | MIT | no — the original protobuf write-up |
| [RhetTbull/apple-notes-parser](https://github.com/RhetTbull/apple-notes-parser) | Python | — | 2026 | MIT | no — but has version-pinned fixtures |
| [xwmx/notes-app-cli](https://github.com/xwmx/notes-app-cli) | Shell | 83 | 2025-09-16 | GPL-2.0 | yes — thin AppleScript |
| [JaviSoto/apple-notes-cli](https://github.com/JaviSoto/apple-notes-cli) | Rust | 1 | 2025-12-23 | MIT | yes + backup, snapshot-tested |

A dozen more `apple-notes-cli` repos exist with 0–17 stars, mostly written in
2026 as Claude/agent adapters. Spot-checked several: all are `osascript`
wrappers around `make new note` / `set body`, none engage with attachments. Not
worth reading individually.

### memo — the one idea worth taking

**It has an attachment-preserving edit, and we document that as impossible.**
CLAUDE.md says "there is no attachment-preserving edit path"; `memo` has a
partial one. Verified by reading `src/memo_helpers/edit_memo.py` and
`md_converter.py`:

1. Read the note's `body` HTML over AppleScript. Inline images come back as
   `<div><img src="data:image/png;base64,…"/></div>`.
2. Swap each `<img>` block for a `[MEMO_IMG_N]` placeholder, convert to Markdown
   (`html2text`), open in `$EDITOR`.
3. Placeholders the user kept are the surviving images; strip them from the
   Markdown, convert back to HTML (`mistune`), `set body`.
4. `set body` has now wiped the attachments, so **delete every remaining
   attachment and re-add the survivors** by base64-decoding each data URI to a
   temp file and running `make new attachment`.

**We ran it. Both halves hold** — see `notes/tests/test_attachment_roundtrip.py`,
10 tests, all passing on macOS 27:

- **The premise is true, and our docs were wrong.** CLAUDE.md said a note's
  `body` "doesn't include attachments at all". That is true for a **text file**
  — which is what `test_editing_body_destroys_attachments` attaches, and why we
  generalised wrongly — and false for images, tables, drawings and Paper docs.
  Measured against the real store, there are three classes, not two:

  | Object type | In `body` as | Survives a body edit? |
  |---|---|---|
  | table | `<table>` markup | **yes, for free** — keep the markup |
  | image | `<img src="data:…">` | yes, but must be harvested and re-added |
  | drawing / Paper doc | `<img>`, a flat PNG render | picture only, flattens to `public.png` |
  | PDF / text file / scan | nothing | no |

  memo only handles the image row. Tables are the better find: they need no
  harvesting at all, just markup that survives the rewrite — and **45% of a real
  store (427 of 939 notes) carries some embedded object**, so this is the common
  case, not an edge case.

- **The full round trip works.** Harvest → `set body` (attachments drop to 0) →
  decode each data URI to a file → re-attach. Two distinct images came back with
  matching SHA-256s, in the original order, with the body edit applied.
- **The countermeasure works for images, and is a no-op for PDFs.**
  `if (count of attachments of n) > EXPECTED then delete last attachment of n`
  lands an image on 1 then 2 across two adds. For a PDF the count it tests is
  always 0 — AppleScript cannot see PDF attachments at all — so the guard never
  fires. Guarded and unguarded PDF adds are identical: two placeholders in the
  text, one byte-exact file on disk. The duplicate is unfixable through
  AppleScript, since you cannot delete a reference you cannot enumerate.

Verified costs, worth surfacing to a user rather than claiming a clean edit:
non-image attachments are destroyed silently with nothing to restore from;
original filenames do not survive, since the attachments are rebuilt from temp
files; and every restored image lands at the **end** of the note, because
`make new attachment` cannot place one mid-text. Their AppleScript also
f-string-interpolates the note body, so a body containing a `"` breaks the
script — take the technique, not the code.

**🛑 And the obvious improvement stores nothing.** Neither memo nor macnotesapp
tried writing the data URI back *inline* — `set body` with an
`<img src="data:…"/>` between two paragraphs. It creates an attachment row and
puts the placeholder at the **correct position** (`ABOVE\n￼\nBELOW`), the one
thing `make new attachment` cannot do, so it reads as strictly better. The row
is empty: `ZFILENAME = NULL, ZFILESIZE = 0, ZTYPEUTI = 'public.data'`, and no
file is ever written (polled 30s). The payload is discarded — for images, PDFs
and text alike. So **there is no way to place an attachment mid-note**;
everything appends to the end. Pinned by
`test_inline_data_uri_write_discards_the_payload`.

### macnotesapp — the mature one

By RhetTbull (of `osxphotos`). Rewritten from AppleScript to **ScriptingBridge**
and it's the most careful Notes write path in the field. Verified by reading
`macnotesapp/notesapp.py`, `macnotesapp.applescript` and the issue tracker:

- **Everything we documented, it hit independently.** [#42](https://github.com/RhetTbull/macnotesapp/issues/42):
  appending means `note.body = note.body + "…"`, which loses formatting *and
  attachments* — same conclusion, same screenshots. [#13](https://github.com/RhetTbull/macnotesapp/issues/13):
  the first line becomes the title and can't be styled from AppleScript; an
  empty name silently becomes "Notes". [#64](https://github.com/RhetTbull/macnotesapp/issues/64):
  attachments "sometimes fail and sometimes result in the attachment being added
  twice" on Sequoia and Tahoe. Good corroboration that the trap list is real and
  not a quirk of this machine.
- **Two ideas worth taking.**
  - *Write-then-verify-then-fall-back.* Every setter writes over ScriptingBridge,
    reads the value back, and re-issues over AppleScript if it didn't take:
    ```python
    self._note.setValue_forKey_(body, "body")
    if self.body != body:
        self._run_script("noteSetBody", body)
    ```
    That is the same discipline we already apply to mail drafts and contacts
    group removal — worth applying to notes writes too.
  - *NSPredicate filtering.* `plaintext contains[cd] %@` gets **full-text body
    search** for free, in one Apple Event. We say "search is title-only". We
    shouldn't copy the mechanism (it needs Notes.app running, and Apple Events
    are what we moved off), but it shows content search is table stakes — and we
    already decode every body for `export`, so doing it over SQLite is a small
    job.
- **Where we're ahead — though they were half right.** They suspect the
  duplication is a *read* artifact and dedupe `.attachments()` by id rather than
  fixing the write. We tested it: the two entries **do** share one
  `ICAttachment` id, so their diagnosis of the listing is correct. But the body
  carries two `<img>` tags and the decoded text two `￼`, so it is **one
  attachment record referenced twice** and the user really does see the file
  twice. Deduping the listing reports 1 and hides a visible defect; deleting the
  surplus reference fixes it. Their benchmark is still
  useful: AppleScript ~300ms per attachment vs ScriptingBridge ~80ms, and they
  stayed on AppleScript because ScriptingBridge duplicated *more* often and
  mangled the spacing between multiple attachments.
- Their test suite is **human-prompted** — `assert prompt("Was a new note named
  X created?")`. 30-odd tests, none runnable unattended. Ours is worse in
  needing live iCloud and better in being automated.

### apple_cloud_notes_parser — the reference for what a body can contain

537 stars, 9 years old, still pushed weekly; the forensic tool, MIT. Read-only,
so nothing to borrow for writes, but two things matter:

- **It enumerates every embedded object type**: tables, drawings, galleries,
  PDFs, vCards, calendar events, audio, hashtags, mentions, inline links, and
  the Calculate expression/result objects. Our renderer handles a subset. Its
  class list is the checklist for "what can appear in a note we're asked to
  export".
- **It decrypts password-protected notes** given a password list
  (`AppleDecrypter.rb`), and documents that iOS 16+ device-passcode-protected
  notes cannot be decrypted. We don't mention locked notes anywhere — we don't
  know what our reader emits for one.

Also credits `dunhamsteve/notesutils` as the origin of the embedded-table
analysis; that repo's `notes.md` is the best single write-up of the format and
is what to read before extending the protobuf decoder.

### The checklist write problem — nobody has solved it in AppleScript

A body write flattens every checklist into a plain bulleted list and discards
which items were ticked (see [`apple-notes-api.md`](apple-notes-api.md)). Asked
whether anyone had beaten this:

**Nobody has, and the reason is structural.** `Notes.sdef` — the app's own
scripting dictionary — contains **zero** occurrences of `checklist`, `checkbox`,
`checked` or `todo`, while containing `attachment` 16 times and `note` 35. The
vocabulary simply does not exist, so no amount of AppleScript cleverness reaches
it.

- **[macnotesapp #29](https://github.com/RhetTbull/macnotesapp/issues/29)** is
  open since 2022. RhetTbull, who has done more with Notes scripting than
  anyone surveyed: *"I've not figured out how to access checklists from Notes
  programmatically."* The one suggestion in the thread is SiriKit's Lists and
  Notes domain, never followed up.
- **No markup works.** We tried 13 candidates — `<input type="checkbox">`
  (checked and unchecked), `class="Apple-checklist"`, `class="checklist"`,
  `li class="checked"`, `data-apple-notes-checklist`, `list-style-type:none`,
  ARIA `role="checkbox"`, `<ol>`, unicode ballot boxes, and literal `- [ ]`
  text. Every one lands as `style_type: -1` (plain paragraph) instead of the
  `style_type: 103` + `checklist: {done: n}` a real checklist carries.
- ⚠️ **`- [ ]` looked like a win and was not.** Our exporter renders a real
  checklist as `- [ ]`, so writing that literal text made the exporter echo it
  back and the test appeared to pass. Checking the paragraph style rather than
  the rendered Markdown showed it was plain text all along. If you re-test this,
  assert on `style_type`, never on exported Markdown.
- ⚠️ **A web search claimed `applescript-mcp` had `add_checklist` /
  `toggle_checklist` / `remove_checklist`.** It does not — reading
  `src/categories/notes.ts` shows `create`, `createRawHtml` and `list`, and a
  code search across the repo returns nothing for "checklist". The summary was
  wrong; the source is the authority.

**Shortcuts is the one route that works.** The Shortcuts app has an **"Append
checklist item"** action that adds genuinely interactive checklist items to a
new or existing note — doing through Notes' own intents what the scripting
interface cannot express. `/usr/bin/shortcuts` can `run` a shortcut from the
command line and pipe input to it.

The catch is shipping: `shortcuts` has `run`, `list`, `view` and `sign` — **no
way to author an action**. So a Shortcuts backend means distributing a
`.shortcut` file the user installs once, which is a real packaging and trust
cost for a tool that currently installs as a symlink. It is the same lead left
open for attachment appends, and it is now the single highest-value unknown in
this whole survey: it is the only known path to both a checklist write *and* an
attachment-preserving append.

### Test-case ideas worth stealing

Our 24 live tests in `notes/tests/` are stronger than anything surveyed at
checking *behaviour*, and weaker at *coverage* and *portability*. Concretely:

**Fixture corpora instead of live Notes.app.** Both parsers check binary
fixtures into the repo and test offline:

- `apple_cloud_notes_parser/spec/data/exported_blobs/` — gzipped protobuf bodies
  named for what they exercise: `block_quotes`, `color_formatting`,
  `emoji_formatting_{1,2,3}`, `list_indents`, `right_to_left_table`,
  `table_formats`, `text_decorations`, `url`, `wide_characters`.
- `apple-notes-parser/tests/data/` — whole `NoteStore.sqlite` files **per macOS
  version**, Monterey through Tahoe, with a test module per version.

Every notes test we have needs live Notes.app and writes to real iCloud, which
is why the suite is gated behind `notes/run-tests`. A checked-in fixture corpus
would make the *rendering* half fast, offline, and safe to run in CI — and the
per-version DBs are the only way to catch a schema change before a user does.

**Done — `notes/tests/test_attachment_roundtrip.py`, 10 tests, written
from this survey and all passing:** images appear in `body` as data URIs and text files do
not; the double-insert is one record referenced twice; the guarded add defeats
it; the full harvest-edit-re-attach round trip is byte-exact and order-
preserving; filenames are lost; and the inline-data-URI write is a silent
data-loss trap.

**Still not covered:**

1. **A password-protected note.** What does the SQLite reader emit — garbage,
   an error, or a clean "locked"? Untested and user-visible.
2. **Rendering gaps** named by the fixture list: block quotes, nested list
   indents, strikethrough/underline/colour, right-to-left tables, and
   emoji/wide characters. We test dividers, headings, tables and attachments.
3. **Empty note name.** macnotesapp #13 says Notes silently titles it "Notes".
   We assert the first line becomes the title but not the empty case.
4. **Body containing a double quote or backslash.** Every AppleScript wrapper
   surveyed, ours included, interpolates the body into a script string.

**Untested lead: Shortcuts.** The Shortcuts app ships an **"Append to Note"**
action, runnable headlessly as `shortcuts run "…"` with stdin. It goes through
Notes' own internals rather than AppleScript's `set body`, so it may append
*without* destroying attachments — which no AppleScript path can do. Nobody
surveyed uses it. Unverified and it needs a pre-installed shortcut, which is
awkward to ship, but if it works it is the real fix for the one data-loss bug in
this tool.

## What we have that they don't

Recorded so we don't "discover" it again, and so it's obvious what's actually
load-bearing here:

- **TCC identity that follows the tool, not the terminal**
  (`responsibility_spawnattrs_setdisclaim`). Nothing surveyed does this.
- **The CardDAV group-removal workaround.** `CNSaveRequest.removeMember` is a
  silent no-op for iCloud groups and works for local ones; the legacy
  `AddressBook` framework handles both. No surveyed project implements contact
  groups at all.
- **Verified write paths.** 37 contacts + 25 calendar + 19 mail + 27 unit tests
  against real data. The nearest peer has ~13 assertions.
- **A decoder checked against ground truth.** 99,023 messages carry both a
  plain-text and an archived body, so the archived reader could be validated
  row by row rather than spot-checked: 99,022 exact matches.
- **The trap list in [CLAUDE.md](../CLAUDE.md)** — every entry cost a real
  debugging session and is pinned by a test.

## Open ideas sourced from here

- **vCard import** — we export, `ical` shows import is expected.
- **Append-vs-replace for multi-value fields** — see claude-apple-bridges above.
- **App-bundle TCC identity** — `apple-pim`'s `helper/` as an alternative to
  disclaiming.
- ~~**Read mail from the store rather than AppleScript**~~ — done, taken from
  `apple-pim`. This is the file's one clear payoff so far: reading a peer's
  source turned a 154s search into a 0.04s one.
- ~~**Messages** (`chat.db`)~~ — done. The payoff was not the SQLite reading,
  which is routine, but the two things only visible against real data: the
  `attributedBody` typedstream holding 1,921 otherwise-invisible messages, and
  the fact that searching two body sources under one `LIMIT` silently returns
  the wrong answer.
- **Maps** — the last surface apple-mcp covered that we do not.
- **An image-preserving `notes edit`** — from `memo`. The mechanism is now
  verified end-to-end; what's left is the command itself, which must refuse (or
  loudly warn) when the note carries a non-image attachment, since those are
  destroyed with nothing to restore from.
- ~~**A countermeasure for the attachment double-insert**~~ — verified from
  `memo`, documented in [`apple-notes-api.md`](apple-notes-api.md). Wire it into
  any future `notes attach`.
- **Full-text search over note bodies** — `macnotesapp` gets it from an
  NSPredicate; we'd do it by decoding bodies we already decode for `export`.
- **Offline rendering fixtures** — a corpus of gzipped protobuf bodies, as in
  `apple_cloud_notes_parser/spec/data`, so rendering tests stop needing live
  iCloud. Plus per-macOS-version `NoteStore.sqlite` files as in
  `apple-notes-parser`.
- **Locked notes** — we have no idea what our reader does with one.
- **Shortcuts' "Append to Note"** — the only surveyed route that might append
  without destroying attachments. Unverified.
- **A body index.** Content search re-reads and re-decodes 3.4 GB every time.
  Mail's own `Protected Index Journals` may already hold something usable; if
  not, a local SQLite FTS table over decoded bodies would make it instant, at
  the cost of staleness and a cache to invalidate.

## Refreshing this

```
for r in supermemoryai/apple-mcp more-io/claude-apple-bridges \
         omarshahine/apple-pim FradSer/mcp-server-apple-events \
         schappim/ekctl BRO3886/ical \
         threeplanetssoftware/apple_cloud_notes_parser antoniorodr/memo \
         RhetTbull/macnotesapp RhetTbull/apple-notes-parser \
         dunhamsteve/notesutils xwmx/notes-app-cli; do
  gh api "repos/$r" --jq '"\(.full_name)\t★\(.stargazers_count)\tpushed \(.pushed_at[0:10])\tarchived=\(.archived)"'
done
```

To check whether a project handles something before we build it:

```
gh api "repos/OWNER/REPO/git/trees/HEAD?recursive=1" --jq '.tree[]|select(.type=="blob")|.path'
```

Read the source before concluding anything from a name. Several claims in this
file were wrong on the first pass precisely because they were inferred from
filenames and shebangs rather than checked.
