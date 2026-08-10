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
    That is the same discipline we already apply to contacts
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

**macOS 27 changes the picture: Markdown import produces real checklists.**
Notes 27.0 ships "Markdown Export & Import" (strings in the app binary:
`importMarkdown:`, `initWithPlainMarkdown:error:`, `Interpret as Markdown`,
`ICMarkdownFlavor`). Importing a `.md` file was tested end to end and the
structures are **genuinely native**, not text that looks like them:

| Markdown written | Result in the store |
|---|---|
| `- [ ] unchecked task` | `style_type: 103`, `checklist: {done: 0}` |
| `- [x] checked task` | `style_type: 103`, `checklist: {done: 1}` |
| `- plain bullet` | `style_type: 101` (bulleted list) |
| a pipe table | a real `com.apple.notes.table` object |

So the checklist write **is** solvable on macOS 27, including checked state —
the thing macnotesapp #29 has wanted since 2022.

🛑 **But it is not headless.** `open -a Notes file.md` pops a GUI confirmation
the user must click; the import does not proceed without it. It also lands the
note in an **"Imported Notes"** folder with no way to choose the destination,
and it always creates a *new* note — there is no import-into-existing, so it is
a `create` path, never an `edit` one.

⚠️ A note imported this way then deleted via AppleScript disappeared from
Notes.app but **kept `ZFOLDER` = "Imported Notes" and `ZMARKEDFORDELETION = 0`
in SQLite**, so our reader still lists it. Imported notes may not follow the
normal soft-delete path; treat their delete state as unverified.

**The Shortcuts surface is far richer than AppleScript** — 51 actions, from
`/System/Applications/Notes.app/Contents/Resources/Metadata.appintents`:

- `Append Checklist Item` (`CreateChecklistItemIntent`) and
  `Set Checklist Items Checked` — the checklist write and its checked state.
- `Create Note` and `Append to Note` both take an **`interpretAsMarkdown`**
  parameter. `Append to Note` is described as *"Adds text to the end of a
  note"* — a genuine append rather than a body replace, which is exactly what
  our attachment- and checklist-destroying `set body` is not.
- `Add File to Note`, `Delete Attachments` — attachment removal, which
  AppleScript cannot do safely at all.
- `Add Table to Note`, `Set Paragraph Style`, `Add or Remove Note Lock`, tags,
  mentions, note links.

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

## Mail specifically — the search side

**Gathered 2026-08-03.** The same question the Notes section asks about writes,
asked about mail search: *has anyone solved this better than we have?* Since the
July survey the field went from a handful of general Apple-app projects to
**~25 mail-specific ones**, nearly all created in 2026 and nearly all **MCP
servers rather than CLIs**. The CLI niche this repo occupies is close to
uncontested; the crowd went to MCP.

**The architecture argument is over and we are on the winning side.** Every
serious 2026 entrant reads the Envelope Index and `.emlx` directly, and most say
so in their README while naming AppleScript timeouts as the reason. When we took
that idea from `apple-pim` it was a minority position; it is now the default.

### The field

| Project | Lang | ★ | Pushed | License | Architecture | Body search |
|---|---|---|---|---|---|---|
| [patrickfreyer/apple-mail-mcp](https://github.com/patrickfreyer/apple-mail-mcp) | Python | 189 | 2026-07-05 | MIT | AppleScript | times out |
| [sweetrb/apple-mail-mcp](https://github.com/sweetrb/apple-mail-mcp) | TS | 56 | 2026-08-03 | MIT | AppleScript + **opt-in IMAP/SMTP** | server-side |
| [imdinu/apple-mail-mcp](https://github.com/imdinu/apple-mail-mcp) | Python | 51 | 2026-07-30 | **GPL-3.0** | index + `.emlx` + **FTS5** | full, ~28ms |
| [like-a-freedom/rusty_apple_mail_mcp](https://github.com/like-a-freedom/rusty_apple_mail_mcp) | Rust | 8 | 2026-08-02 | **none** | index + `.emlx` | none |
| [PsychQuant/che-apple-mail-mcp](https://github.com/PsychQuant/che-apple-mail-mcp) | Swift | 7 | 2026-08-01 | MIT | index | none (despite the claim) |
| [BastianZim/apple-mail-mcp](https://github.com/BastianZim/apple-mail-mcp) | Python | 0 | 2026-06-23 | MIT | index + `.emlx` | capped at 5k newest |
| [fledgeling-co/sift-apple-mail-mcp](https://github.com/fledgeling-co/sift-apple-mail-mcp) | TS | 0 | 2026-08-03 | MIT | daemon + **FTS5** + PDF text | full, ~4ms claimed |
| [joargp/amcli](https://github.com/joargp/amcli) | Node | 0 | 2026-07-14 | MIT | index + `.emlx` | preview only |
| [macos-cli-tools/apple-mail-cli](https://github.com/macos-cli-tools/apple-mail-cli) | Bash | 0 | 2026-03-19 | MIT | AppleScript | — |
| [zenghao-stat/apple-mail-cli](https://github.com/zenghao-stat/apple-mail-cli) | Swift | 0 | 2026-08-03 | MIT | AppleScript | — |
| [smarzola/apple-mail-mcp](https://github.com/smarzola/apple-mail-mcp) | Rust | 1 | 2026-07-25 | MIT | AppleScript | — |

Star counts and dates are a snapshot; re-run the loop at the bottom of this file.
**Architecture and body-search columns are from READMEs and metadata** except
where a subsection below says the source was read.

### Somebody benchmarked the field, and it corroborates the wedge work

imdinu publishes a [head-to-head benchmark](https://imdinu.github.io/apple-mail-mcp/benchmarks/)
run at the MCP protocol level — subprocess per server, real tool calls over
JSON-RPC/stdio, 5 warmups then 10 measured runs, median with p5/p95, a 10s probe
screening out non-functional tools. **~73.5k messages, M4 Max, macOS 26.5,
2026-05-28.**

| Operation | index-based | patrickfreyer (AS) | sweetrb (AS) | titouancreach (AS) |
|---|---|---|---|---|
| List accounts | ~1 ms | ~150 ms+ | ~150 ms+ | ~150 ms+ |
| Fetch 50 emails | ~3–5 ms | **TIMEOUT** | **TIMEOUT** | **TIMEOUT** |
| Search subject | ~3–10 ms | ~570 ms | ~9 s+ | **TIMEOUT** |
| Search body | ~28 ms | **TIMEOUT** | n/a | n/a |

Their diagnosis is ours verbatim: *"body search via `whose body contains` lacks
OS-level indexing, causing timeouts at the 180-second osascript limit."* That is
independent confirmation of the 154s → 0.04s measurement in
[`apple-mail-store.md`](apple-mail-store.md), on someone else's mailbox and
hardware.

⚠️ **It is the author's own benchmark of their own competitors** and we have not
reproduced it. Treat the ranking as corroborated and the exact figures as
unverified. Two side notes from it worth keeping: a 78★ server broke entirely on
macOS 26 with AppleScript enumeration errors, and `pl-lyfx` ships hardcoded
placeholder paths.

### The two that go past us — a body index

Both solve the open idea below: *content search re-reads and re-decodes 3.4 GB
every time.*

**[imdinu](https://github.com/imdinu/apple-mail-mcp)** — 83 files, ~14 test
modules, GPL-3.0. *Verified by reading `index/watcher.py` and
`benchmarks/competitors.py`:* a persistent FTS5 index built by an explicit
`apple-mail-mcp index` run, plus an optional `--watch` using `watchfiles` on
`~/Library/Mail/V10/` with 500 ms debounce, a `MAX_PENDING_CHANGES` cap against
unbounded memory, a 200 ms retry for files Mail is still writing, and a path
regex that pulls account UUID and rowid out of the path — including
`(?:\.partial)?\.emlx`, matching our own handling at
`EnvelopeIndex.swift:537`. Has an `index/lock.py`, so concurrent builds were a
real problem for them too.

🛑 **GPL-3.0 against our MIT — ideas only, never code.**

**[sift](https://github.com/fledgeling-co/sift-apple-mail-mcp)** — created
2026-08-03, 30 commits, 0 stars, MIT. **Entirely unproven, and every number in
its README is self-reported.** But *verified by reading `src/index/build.ts` and
`src/index/schema.ts`*, the design is the most careful thing in this survey and
the reasoning is worth more than the code:

- **Contentless FTS5** — `content=''`, `contentless_delete=1`, `detail=full`,
  `prefix='2 3'`, `unicode61 remove_diacritics 2` so "resume" finds "résumé".
  They cite SQLite's own email-corpus measurement, 743 MiB for `detail=full`
  against 134 MiB for `detail=none`, and take the size for phrase search.
- 🛑 **The change fingerprint is four fields, not two** — `(inode, mtimeMs,
  ctimeMs, sizeBytes)`. Their note: `(mtime, size)` silently skips a
  size-preserving edit inside one mtime tick, and mistakes a reused path for an
  unchanged file. This is the trap we would have walked into.
- **Resume by fingerprint, sweep by stamp.** Every discovered path is stamped
  with the build id; unstamped occurrences are then deleted, then orphaned docs.
  That is what makes a moved or deleted message actually leave the index.
- 🛑 **Separate `docs` and `occurrences` tables** — one row per message, one per
  file on disk. Two copies of one message have different mtimes and different
  outcomes, so the ledger cannot live on the message. This is our "mailbox names
  are not unique, use the account/mailbox pair" problem in index form.
- **Publishes sealed generations mid-build**, so a first build answers queries
  while it is still running rather than being all-or-nothing.
- Refresh: a cheap counter plus `max(ROWID)` and row count to tell real arrival
  from a mark-as-read; full reconciliation every 15 minutes; builder detached.
- **PDF text extraction** — 342 of 400 PDFs, scanned ones marked
  `no-text-layer`. That is our documented non-feature.

If we ever build the index, read these two first.

### What the AppleScript camp independently discovered

*Verified by reading `plugin/apple_mail_mcp/core.py` and
`tests/test_orphan_watcher.py` in [patrickfreyer](https://github.com/patrickfreyer/apple-mail-mcp)*
— the most-adopted server in the field arrived at half of our Tier 1 on its own:

- Every in-flight `osascript` `Popen` goes into a lock-guarded set, killed from
  `atexit` and from chained SIGTERM/SIGHUP handlers (chained, not clobbered, so
  FastMCP's own handler survives). Same conclusion we reached: an orphaned
  `osascript` still driving Mail is the hazard.
- An orphan watcher exits the server when its PPID changes.
- **The idea we took:** every script is wrapped in `with timeout of max(N-5, 5)
  seconds`, sized just under the Python-side kill, so the interpreter abandons
  the Apple Event and exits cleanly instead of being killed mid-request. We had
  this on the export walk and *not* on the search script. Now we do — see below.

Good corroboration that the wedge is not a quirk of this machine. Note they have
no equivalent of the preflight, the no-launch rule, or `mail_app.responsive`.

### Verified dead ends

- 🛑 **`mdfind`/Spotlight cannot search mail, and Full Disk Access does not fix
  it.** Confirmed on [Apple's own forums](https://developer.apple.com/forums/thread/121187?page=2):
  Spotlight mail search works through neither `MDQueryRef` nor `mdfind` even
  with the grant. Not a permissions problem — don't spend time on it.
- **IMAP instead of Mail.app.** sweetrb ships this as an opt-in fast path
  (credentials in the Keychain), and it is what [himalaya](https://github.com/pimalaya/himalaya),
  notmuch and mu do generally. It works and gives server-side search, but it
  costs credentials, network round-trips and a second source of truth. Different
  product from "read the user's real local data"; not a direction for this repo.
- **`che-apple-mail-mcp`'s "millisecond search across 250K+ emails"** is
  subject/sender/recipient/date only. Its own comparison table says so two rows
  below the claim. A reminder to read the table, not the headline.

### What we took from this survey

Both landed on 2026-08-03, both pinned by tests:

1. **An in-script `with timeout` on the search path**, from patrickfreyer, at
   `MailDeadline.inScript(under:)` — sized 5s under the process deadline and
   floored at 5s so a shrunken `APPLE_MAIL_SCRIPT_TIMEOUT` cannot emit a
   `with timeout of 0`, which AppleScript rejects at compile time. It does not
   un-wedge Mail; it changes *how* we give up, from SIGKILL to a clean -1712.
   It required fixing the swallowing `try` at the same time: the handler now
   re-raises -1712 and swallows everything else, because a timeout inside a
   `try` that eats it returns a partial result that reads as complete.
2. **A real backslash escape**, found while checking their ` ` handling.

🛑 **And the borrowed escape list was wrong for us, which is the more useful
finding.** patrickfreyer escapes `\`, `"`, newline, tab and U+2028/U+2029. We
measured each against `osascript -e` on macOS 27 before copying:

| In a literal | `length of "a?b"` |
|---|---|
| `\` | **syntax error (-2741)** |
| `"` | **syntax error (-2741)** |
| raw newline, tab, U+2028, U+2029 | 3 — all legal |

Because `osascript -e` takes the script as an argv string rather than a parsed
file, only the two structural characters break a literal. Escaping the others
would have **silently changed the query**: `character id` of the second
character of `"a\nb"` is 10 where a raw U+2028 is 8232. A wrong query is worse
than the syntax error the escape was meant to prevent, so
`escapedForAppleScriptLiteral` handles exactly two characters and the tests pin
the omissions as deliberately as the inclusions.

The live bug this exposed was real and predated the survey: the search escaped
`"` and not `\`, so `apple mail search 'back\slash' --engine applescript` failed
with `Expected “"” but found unknown token`. Reproduced against 26.803.2 and
fixed. The same interpolation sites also passed `--mailbox` and the account name
through unescaped.

### Still not taken

- **A body index.** The open idea below, now with two worked designs to read.
- **PDF text extraction**, from sift — we say "there is no PDF text extraction".
- **An orphan watcher.** We kill the child on deadline expiry, but a SIGTERM to
  `apple mail` itself does not currently reach an in-flight `osascript`.

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
- **Guards against wedging Mail, and tests for them.** The preflight, the
  no-launch rule, the refusal of body-reading predicates on the AppleScript
  engine, and `tests/test_mail_wedge.py`'s 21 read-only assertions. Of the ~25
  mail projects surveyed, only patrickfreyer engages with the problem at all
  (in-flight child tracking, in-script timeouts) and none tests it. imdinu's
  harness is the only comparably serious testing in the field and it measures
  speed, not safety.
- **Two grants reported separately.** `apple mail status` distinguishes Full
  Disk Access from Automation → Mail and reports `mail_app.responsive`. Nothing
  surveyed tells a user which half is broken; `doctor` commands in amcli and
  sweetrb come closest.

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
  the cost of staleness and a cache to invalidate. **Two worked designs now
  exist** — see the mail section: imdinu's FTS5 index plus `watchfiles` watcher,
  and sift's four-field fingerprint, docs/occurrences split and mid-build
  generation publishing. Read both before starting.
- **PDF text extraction for `--field content`** — from sift, which reports 342
  of 400 PDFs extracted and marks scanned ones `no-text-layer`. We currently
  never decode a non-text part.
- **An orphan watcher / kill-on-own-exit** — from patrickfreyer. Our deadline
  kills the child when it expires, but a SIGTERM to `apple mail` itself leaves
  an in-flight `osascript` driving Mail.
- ~~**An in-script `with timeout` on the search path**~~ — done, from
  patrickfreyer, along with re-raising -1712 out of the swallowing `try`.
- ~~**Escaping the search term properly**~~ — done, but see the mail section:
  the borrowed escape list was wrong for `osascript -e` and copying it whole
  would have silently altered queries.

## Refreshing this

```
for r in supermemoryai/apple-mcp more-io/claude-apple-bridges \
         omarshahine/apple-pim FradSer/mcp-server-apple-events \
         schappim/ekctl BRO3886/ical \
         threeplanetssoftware/apple_cloud_notes_parser antoniorodr/memo \
         RhetTbull/macnotesapp RhetTbull/apple-notes-parser \
         dunhamsteve/notesutils xwmx/notes-app-cli \
         patrickfreyer/apple-mail-mcp sweetrb/apple-mail-mcp \
         imdinu/apple-mail-mcp like-a-freedom/rusty_apple_mail_mcp \
         PsychQuant/che-apple-mail-mcp BastianZim/apple-mail-mcp \
         fledgeling-co/sift-apple-mail-mcp joargp/amcli \
         macos-cli-tools/apple-mail-cli zenghao-stat/apple-mail-cli \
         smarzola/apple-mail-mcp jayvee6/apple-mail-mcp \
         abhinavag-svg/apple-ecosystem-mcp fatbobman/mail-mcp-bridge; do
  gh api "repos/$r" --jq '"\(.full_name)\t★\(.stargazers_count)\tpushed \(.pushed_at[0:10])\tarchived=\(.archived)"'
done
```

The mail half of the field turns over fast — most of those repos did not exist
in July 2026 — so re-run this before trusting the table, and search for new ones
rather than assuming the list is still the field:

```
gh search repos "apple mail mcp" --limit 30 --json fullName,stargazersCount,pushedAt
gh search repos "apple mail cli" --limit 30 --json fullName,stargazersCount,pushedAt
```

To check whether a project handles something before we build it:

```
gh api "repos/OWNER/REPO/git/trees/HEAD?recursive=1" --jq '.tree[]|select(.type=="blob")|.path'
```

Read the source before concluding anything from a name. Several claims in this
file were wrong on the first pass precisely because they were inferred from
filenames and shebangs rather than checked.

## Mail specifically — the compose side

Gathered 2026-08-06; **revised the same day** — the `.emlx` section below is a
retraction, and one table row was scored wrong. The search-side notes above say
nothing about composing, and that turned out to hide the single worst defect in
the field: **Mail wraps every scripted body in `<blockquote type="cite">`**
(Apple FB11734014). Full detail in [`apple-mail-drafts.md`](apple-mail-drafts.md).

Of ~25 projects surveyed on the search side, **exactly one was recorded as
relevant here, and its relevance was mis-scoped.** The two projects that engaged
hardest with the wrapper were absent.

| Project | Compose route | Engages with the wrapper? |
|---|---|---|
| [s-morgan-jeffries/apple-mail-fast-mcp](https://github.com/s-morgan-jeffries/apple-mail-fast-mcp) | **IMAP APPEND** to `\Drafts` | **best writeup in the field**, shipped v0.9.0 |
| [PsychQuant/che-apple-mail-mcp](https://github.com/PsychQuant/che-apple-mail-mcp) | `mailto:` + GUI ⌘S; clipboard paste for reply/forward | **deepest engagement**; A/B/C/D disproof matrix |
| [patrickfreyer/apple-mail-mcp](https://github.com/patrickfreyer/apple-mail-mcp) (189★) | **clipboard paste** — `NSAttributedString` → RTF, ⌘V into the composer | **yes, five releases of it** — see below |
| [sweetrb/apple-mail-mcp](https://github.com/sweetrb/apple-mail-mcp) | SMTP direct (a *send* path, not a draft path) | yes, [#12](https://github.com/sweetrb/apple-mail-mcp/issues/12) — the wrapper in **sent** mail |
| [kcrt/dotfiles](https://github.com/kcrt/dotfiles) | loads the clipboard, **lets the human press ⌘V** | yes, and the most conservative about it |
| [parasxos/email-mcp](https://github.com/parasxos/email-mcp) | abandoned local Mail for Microsoft Graph | yes — probed it and gave up |
| [omarshahine/apple-pim](https://github.com/omarshahine/apple-pim) | `make new outgoing message` | **no** |
| [abhinavag-svg/apple-ecosystem-mcp](https://github.com/abhinavag-svg/apple-ecosystem-mcp) | `make new outgoing message` with `content:` (`tools/mail.py:947`) | **no** — no `blockquote`/`rtf`/`pasteboard` anywhere in the tree |
| [jayvee6/apple-mail-mcp](https://github.com/jayvee6/apple-mail-mcp) | `reply m` then `set content of` — 🛑 **destroys Mail's quotation** | **no** |
| [fatbobman/mail-mcp-bridge](https://github.com/fatbobman/mail-mcp-bridge) | read-only, no compose path at all | n/a |
| [Macuse](https://macuse.app/) (closed source) | undocumented | **unscoreable** — see below |

**The field has converged, and it converged on the clipboard.** Of the nine
projects with a compose path: **three set `content:` and ship the wrapper**
(omarshahine, abhinavag-svg, jayvee6), **three paste into Mail's own editor**
(che, kcrt, patrickfreyer), one uses IMAP APPEND, one SMTP, and one left local
Mail for Microsoft Graph. Setting `content:` is still the most popular single
answer, but it is the answer of the projects that never noticed the bug. **The
clipboard is the only route anyone has iterated on** rather than adopted and
abandoned — and **nobody except us rewrites the `.emlx`**.

Corrections to the search-side notes above, on these grounds:

- The dismissal of sweetrb's IMAP/SMTP as "not a direction for this repo" was
  written about *search*. It is also their **wrapper fix**, and that half deserved
  judging on its own merits. (It still loses — see the drafts doc — but for
  different reasons.)
- che is listed as "index, no body search", true of its read side. Its **compose**
  side is the most thorough treatment of this bug anywhere.
- ⚠️ **patrickfreyer was scored "no — ships the wrapper, zero engagement", and
  that is wrong.** It was written against an older release and used here as
  evidence that the field ignores this. By v3.2.0 it is one of the most
  engaged projects in the table. **Re-read release notes, not just `HEAD`, before
  scoring a moving project** — the star count made it the one row worth
  double-checking and it was the one row taken on trust.

### 🛑 The `.emlx` rewrite: che was right and we were wrong

**Revised 2026-08-06, the same day it was written, after watching it fail in the
user's hands.** The claim below is what this section said, and it is retracted:

> Editing the `.emlx` works — for a new draft, and only for a new draft. For a
> draft from `make new outgoing message` che are **wrong**; the draft survives
> being opened in the composer with its Message-ID and body intact. For a draft
> from Mail's `reply`/`forward` verb they are **right**.

That split decision does not exist. **There is one mechanism, and it applies to
every draft Mail composed:**

🛑 **Mail keeps its own copy of the message it composed, and that copy wins
whenever Mail re-saves the draft.** The rewrite lives only in the file. Opening
the draft can trigger a re-save; a re-save re-emits Mail's copy, discards the
file, and mints a new Message-ID. Proven by content, not inference — a rebuilt
reply that had been reviewed came back holding
`Apple-Mail-URLShareUserContentTopClass`, `Apple-Mail-URLShareWrapperClass`,
`blockquote type="cite"`, `<br>` line breaks and `Apple-converted-space` spans:
not a degraded rewrite but **Mail's pre-rewrite composition, verbatim**.

What that copy contains is the only thing the route changes, so each route loses
something different:

| Route | Mail's cached copy holds | A re-save costs |
|---|---|---|
| rewrite Mail's native `reply` draft (che's test, route 1) | quote + threading, **no body** | your text |
| rebuild via the new-draft path (route 2) | your text, wrapped | the quote, `In-Reply-To`/`References`, `text/plain` |
| plain `draft` | your text, wrapped | the wrapper returns; text survives |
| `draft --attach` | the attachment `<object>`, **empty body** | your text |

⚠️ **And it is nondeterministic, which is how it passed review.** The same
scripted open-and-close test reported `ok` at 14:43 and `FAIL` at 14:51 with no
code change between them. "Survives being opened" was **one observation of a coin
flip, generalised to a property** and then written into three documents. The
lesson is not about Mail: a live-system test that passes once is not a pinned
property, and a claim that a write survives an interaction needs the interaction
repeated, not passed.

So `reply`'s rebuild through the new-draft path is not the fix it was documented
as. It changes the failure mode from "loses your text" to "loses the quote and
the threading". See [`apple-mail-drafts.md`](apple-mail-drafts.md).

#### Superseded 2026-08-10 — the mechanism above is wrong, and compose is gone

The retraction was right that there is one mechanism and it applies to every
draft Mail composed. **The explanation was still wrong**, and the corrected one
is what ended the feature.

"Mail keeps its own copy and that copy wins" does not survive measurement:

- **Mail's stored copy is clean.** The `.emlx` on disk and Mail's own `source of`
  both hold the rewritten body — before *and* after a Mail restart,
  byte-identical bar a trailing newline. There is no stale copy lurking.
- **A cold compose cache changes nothing.** Quit Mail, confirm `outgoing messages
  = 0`, reopen, open the draft: still wrapped.
- **It is not nondeterministic.** Driven *by hand* rather than by `osascript`, it
  reproduced every time across four matched pairs — every tool-written draft
  wrapped, every hand-typed control stayed clean. The 14:43-`ok` / 14:51-`FAIL`
  coin flip was an artefact of scripting the composer, which is itself a scripted
  insertion and which wedges Mail besides.

What actually happens: Mail **re-imports** the stored body as foreign content
when the composer loads it, building a fresh native document and dropping ours
inside the Share-Sheet template — which is why a hand edit lands *outside* the
blockquote, as a sibling.

🛑 **And the discriminator is provenance, not bytes.** A draft Siri composed
through Mail's App Intents is clean, and stays clean through the same hand
open/edit/save — while being equivalent to ours in every byte-level respect we
control (both `7bit`, both with an empty `text/plain`, both carrying the same
`<html aria-label="message body">` / `<body dir="auto" style="…">` shell, neither
carrying `X-Apple-Mail-Signature`). Mail tracks how the message was created,
outside the `.emlx`, and no rewrite can reach it.

So the `.emlx` rewrite is not fixable, and `draft`/`reply`/`forward`/`send` were
**removed in 26.810.0**. This also retires the comparison table above as a
buyer's guide: the routes that lose are not losing for the reasons recorded
there. See [`apple-mail-drafts.md`](apple-mail-drafts.md) for the full record and
`util/check-mail-intents` for re-checking whether Apple has opened the one route
that works.

### One thing we established that nobody in the field had

- **Rich HTML pastes wrapper-free.** che [#306](https://github.com/PsychQuant/che-apple-mail-mcp/issues/306)
  is an explicitly unrun spike; their "rich text is structurally impossible" rule
  was inherited from `mailto:`'s plain-text limit. Tested here: `<p>`, `<b>`,
  `<i>`, `<a href>`, `<ul><li>` all survive a `public.html` paste into the native
  editor. ⚠️ But see patrickfreyer below — **`public.html` is the wrong flavour**,
  and they found that before we did.

### What patrickfreyer already solved, that we would have paid for twice

Their release notes are the most useful document in the field for anyone building
the paste route. Both of these are failures we had already hit or would have:

- **v3.1.5 — poll `frontmost of process "Mail"` before the keystroke**, in *both*
  the reply and new-message paths. This is exactly the hazard recorded in
  [`apple-mail-drafts.md`](apple-mail-drafts.md): during testing here a paste with
  the wrong focus **landed in the subject field and replaced it**. The fix is a
  wait, not cleverness.
- **v3.1.8 / v3.2.0 — put RTF on the pasteboard, not HTML.** *"HTML
  replies/compositions no longer paste the body twice… the body is now converted
  to an `NSAttributedString` and written back as RTF (a single unambiguous
  rich-text flavor) plus a rendered plain-text fallback."* Our verified paste used
  `public.html`, so we would have shipped the double-insertion bug.

⚠️ **Also worth crediting: pasting is the only route where Mail generates the
`multipart/alternative` itself**, so `text/plain` comes out populated. That is one
of the things our `.emlx` rewrite exists to hand-fix.

### Notes on the rest

- 🛑 **jayvee6's `reply.applescript` is the naive reply, and it loses the
  quotation silently.** `set replyMsg to reply m` then `set content of replyMsg to
  msgBody` — `content` is a full replace, so Mail's quoted original is discarded
  and the new body is wrapped. It also resolves the target with `first message of
  targetMbox whose message id = targetId`, **a whole-mailbox predicate**, which is
  the pattern that wedges Mail's scripting interface on a large mailbox; and it
  passes whatever it finds to `reply`, with no guard against replying to a draft
  (which wedged Mail here). Its skill blocks LLM-generated *sends* and requires
  manual dispatch from Mail — the same discipline as our `--confirm`.
- **abhinavag-svg's `docs/plans/mail-rework-plan.md` is a plan to build what we
  already ship**, from the same symptoms: AppleScript reads are slow, time out,
  and cannot answer chronological queries; the recommendation is a hybrid of local
  index for reads and AppleScript for actions. Independent confirmation of the
  architecture. The compose problem is not on their roadmap.
- ⚠️ **They read the Envelope Index by *snapshotting* it, and got the hard part
  right: `mail_store.py:138` copies `-wal` and `-shm` alongside the main file.**
  A copy without the write-ahead log is stale in both directions — the same trap
  as AddressBook `immutable=1` in [`apple-phone-store.md`](apple-phone-store.md).
  The cost they accept instead is a 900s snapshot TTL, so "any new mail?" can be
  fifteen minutes out of date. We read live in 0.04s and need neither.
- **fatbobman/mail-mcp-bridge is read-only and arrived at our read architecture
  independently**: Envelope Index → `ROWID` → locate the `.emlx` → parse. No
  compose path, so nothing on the wrapper.
- **Macuse is a signed, closed-source MCP app and cannot be scored.** It
  advertises "read, compose, send emails" and "reply to emails" over Full Disk
  Access, and publishes no mechanism — no tool names, no parameters, nothing on
  HTML or rich text. Being a signed app does not unlock a route we lack: the
  entitlement that would matter is MailKit's, and Apple documents that as unable
  to change a message body. To score it, install it and read the drafts it
  produces.

### And one dead end that looks promising and is not

🛑 **Shortcuts / App Intents is in nobody's candidate list, and should stay that
way.** Mail exposes `ComposeMessageIntent`, `SaveDraftIntent`, `SendDraftIntent`
and `DeleteDraftIntent` — which would have been strictly better than every
workaround above (clean body *plus* attachments *plus* account selection, no
credentials, no keystrokes). They are unreachable: absent from the Shortcuts
action picker, unsignable (`Tools.visibilityFlags & 4` is unset), and unsigned
import is refused. Apple Intelligence is **not** the gate. Do not spend the
afternoon we spent on it.
