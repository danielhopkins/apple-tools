# Apple Notes API reference & behavior notes

This documents the two ways to get at Apple Notes data, the behaviors and bugs
this project has verified, and how the test suite locks them in. Findings were
verified on **macOS 27 (Darwin 27.0.0)**. Where a behavior is version-sensitive
it is called out, because Apple changes these between releases.

There are two completely separate access paths:

| Path | Direction | Used by | Notes |
|------|-----------|---------|-------|
| **SQLite** (`NoteStore.sqlite`) | **read-only** | the `apple-notes` CLI | Fast, no UI, decodes the protobuf note body. **Never write to it** — it desyncs iCloud. |
| **AppleScript** (`tell application "Notes"`) | **read/write** | the test suite, any editing | The only supported way to create/edit/delete/attach. Slower; mutations sync to iCloud and all your devices. |

---

## 1. SQLite read path

Database: `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`

Key tables/columns the CLI relies on (all present and unchanged on macOS 27):

- `ZICCLOUDSYNCINGOBJECT` — the catch-all entity table (215 columns). Notes and
  folders are both rows here.
  - `ZTITLE1` — note title; `ZTITLE2` — folder title.
  - `ZIDENTIFIER` — note UUID (used for `applenotes://` URLs).
  - `ZFOLDER` — FK to the folder row's `Z_PK`.
  - `ZMODIFICATIONDATE1`, `ZMARKEDFORDELETION`.
- `ZICNOTEDATA` — `ZNOTE` (FK to note `Z_PK`) and `ZDATA` (gzipped protobuf body).

The note body in `ZDATA` is a gzipped protobuf; see `proto/notestore.proto`
(a trimmed subset of the upstream
[apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser)
schema).

### Known gap: Recently Deleted is visible to the reader

A soft-deleted note (see §2) keeps `ZMARKEDFORDELETION = 0`; it is moved into the
special **"Recently Deleted"** folder (`ZTITLE2 = 'Recently Deleted'`, `Z_PK = 3`
on this machine) instead. The CLI's queries filter only on
`ZMARKEDFORDELETION = 0`, so **Recently Deleted notes still show up in
`search`/`folders`/`export`** as if they were live. To exclude them, also filter
out the Recently Deleted folder, e.g. `AND f.ZTITLE2 != 'Recently Deleted'`
(better: by the trash folder's id).

Locked by `tests/test_reading.py::test_recently_deleted_is_visible_to_reader`.

### Locked (password-protected) notes

A locked note keeps its `ZICCLOUDSYNCINGOBJECT` row, flagged
`ZISPASSWORDPROTECTED = 1`, but **its body is not present at all**:
`ZICNOTEDATA.ZDATA` is `NULL`. There is nothing to decode and no read path — the
key derives from the user's note password, or the device passcode on iOS 16+,
which the CLI neither holds nor should ask for. The related columns
(`ZCRYPTOSALT`, `ZCRYPTOWRAPPEDKEY`, `ZCRYPTOITERATIONCOUNT`,
`ZPASSWORDHINT`, `ZLOCKEDNOTESMODE`) are all on the same table.

⚠️ **A locked row may also have `ZTITLE1 = NULL` and `ZMODIFICATIONDATE1 =
NULL`.** Both were true of the only locked note on this machine, which matters
twice: a `WHERE ZTITLE1 IS NOT NULL` filter hides it *incidentally* rather than
deliberately, and `ORDER BY ZMODIFICATIONDATE1 DESC` sorts it dead last, so a
listing with a small `--limit` will not reach it.

The CLI detects the flag and **skips locked notes by default** across `search`,
`folders` and folder listings, announcing the omission on stderr so the gap is
never silent:

```
note: skipped 1 password-protected note (contents are encrypted; pass
      --include-locked to list them)
```

- `--include-locked` lists them with `locked: true`, and relaxes the title
  filter so a title-less locked note still appears (shown as `<locked note>`).
- `export` **refuses with exit code 2** and names the reason. It previously
  printed "Failed to parse note content", blaming the parser for content that
  was never there. Exit 2 is distinct from exit 1 ("not found") so a caller can
  tell the two apart.
- `get-url` still works and sets `locked: true` — a deep link is harmless, since
  Notes.app prompts for the password itself.

Locked by `tests/test_locked_notes.py` (9 tests). Those tests copy the store to
a temp directory and flip the flag on a throwaway row, so they run whether or
not the machine owns a locked note — and they are the **only notes tests that
need neither Notes.app nor iCloud**, running in ~3s.

### Unknown protobuf fields

Our trimmed `.proto` omits many fields that real notes carry; parsing leaves them
as protobuf "unknown fields" (harmless — 663/663 notes parse). The notable one is
`AttributeRun` field **#13**, a varint that decodes to Unix timestamps
(per-run authorship / edit-time metadata for collaboration). Others seen:
`AttributeRun` #14 (small enum), `ParagraphStyle` #3 (near-ubiquitous flag `1`),
`ParagraphStyle` #7/#8 (rare enums), and benign `#1 = 0` version flags on the
root/document. None are required to read note text or formatting today.

---

## 2. AppleScript read/write path

`Notes.app`'s scripting dictionary lives at
`/System/Applications/Notes.app/Contents/Resources/Notes.sdef`
(reading it via `sdef` needs full Xcode; read the file directly otherwise).

### `note` properties

`name` (rw — but see below), `body` (rw, HTML), `plaintext` (r), `id` (r),
`container` (r, folder), `creation date` / `modification date` (r),
`password protected` (r), `shared` (r). Elements: `attachment`.

### `attachment` properties — all read-only

`name`, `id`, `container`, `content identifier` (the `cid:` referenced in the
note HTML), `creation date`, `modification date`, `URL` (for URL attachments),
`shared`. There is a **hidden** `contents` (file) property used only to feed
`make new attachment with data <file>`; you cannot read it back or mutate any
attachment property after creation. The API is **add-only**.

### Behavior & gotchas (each is locked by a test)

| Behavior | Detail | Test |
|----------|--------|------|
| `set body` is a **full replace** | Writing `body` discards all prior content; it never merges. | `test_editing::test_set_body_is_full_replace` |
| **First line becomes the title** | Whatever ends up as the first line silently becomes `name`. Setting body re-derives the title every time. | `test_editing::test_first_line_becomes_title` |
| **Append** via concatenation | `set body to (body) & "<extra>"` appends. The `as text` coercion is optional/defensive — plain `&` works (an earlier "requires `as text`" belief was wrong; the `-1700` came from `length of body`, not the concat). | `test_editing::test_append_via_concatenation_works` |
| **Plain text gets wrapped** | Setting a non-HTML body wraps it in `<div>…</div>`. | `test_editing::test_plaintext_body_is_wrapped_in_div` |
| **`<h1>` loses its semantics** | A heading round-trips as `<font face=".AppleSystemUIFontBold">` / `<span style="font-size:24px">`, not `<h1>`. | `test_editing::test_h1_heading_roundtrip_loses_semantic_tag` |
| **`delete` is a soft delete** | Moves the note to Recently Deleted; it is **not** gone. There is no AppleScript API to empty that folder; it auto-purges in ~30 days. After soft delete, `container of note` raises **-1728**, so check the folder via SQLite. | `test_editing::test_delete_moves_to_recently_deleted` |
| 🛑 **editing `body` destroys attachments** | The first write deletes every attachment. What survives is per-type: tables ride along in the markup, images must be harvested and re-added, PDFs/text/scans are unrecoverable. See §3. | `test_attachments::test_editing_body_destroys_attachments` |

---

## 3. Attachments

### How to attach a file

```applescript
tell application "Notes"
  set n to note id "x-coredata://…/ICNote/p123"
  make new attachment at end of n with data (POSIX file "/path/to/file")
end tell
```

`make new attachment … with data <file>` is the only way to add an attachment;
Notes copies the file into its own private storage. You can then read the
attachment's `name`, `content identifier`, dates, `URL`, and `shared` — but not
change them.

### ⚠️ Known bug: `make new attachment` double-inserts

On macOS 27, a **single** `make new attachment` call inserts the file **twice**.
Confirmed two independent ways:

- AppleScript reports `count of attachments` = **2** after one call.
- The decoded note body contains **two** U+FFFC (`￼`) object-replacement chars
  (one per inline attachment).

This reproduces with both `at end of <note>` and the plain
`tell <note> to make new attachment` form, so it is not a placement-syntax
artifact. This is very likely the source of past attachment problems.

**It is one attachment record referenced twice, not two records.** Both entries
report the *same* `ICAttachment` id, while the body carries two `<img>` tags and
the decoded text two `￼`. So the user really does see the file twice — but
"dedupe the attachments listing by id", which is what macnotesapp does, reports
1 and hides the visible defect rather than fixing it.

**Workaround for images only** — add, then immediately delete the surplus:

```applescript
make new attachment at end of n with data (POSIX file "…")
if (count of attachments of n) > EXPECTED then delete last attachment of n
```

For an **image** this lands the count on `EXPECTED` with exactly one `￼` per
attachment. Locked by
`tests/test_attachment_roundtrip.py::test_guarded_add_defeats_double_insert_for_images`.

**For a PDF the guard is a no-op**, because the count it tests is always 0 (see
below). Guarded and unguarded adds are indistinguishable: **two placeholders in
the text, one file on disk**. The PDF is intact and the user sees it twice, and
there is no AppleScript route to fix that — you cannot delete a reference you
cannot enumerate. Locked by
`tests/test_attachment_roundtrip.py::test_pdf_double_inserts_and_the_guard_cannot_fix_it`.

For a **text file** the count lands on 1 but the placeholder count is unstable
across runs. Any `notes attach` must branch on attachment type; there is no
universal guard.

### 🛑 `count of attachments` is blind to PDFs

A note with a PDF reports `count of attachments` = **0**, and `attachments of n`
enumerates nothing — while the file sits on disk under
`Accounts/<uuid>/Media/…`, byte-exact. AppleScript simply cannot see PDF
attachments.

Consequences, all load-bearing for a write path:

- **A count of 0 does not mean "no attachments."** It never proves an attachment
  was deleted, which is exactly the false conclusion this repo drew once.
- **Verify writes through the store**, not through AppleScript: count `￼` in the
  decoded note text and check for the file under `Accounts/`. The CLI already
  has that read path; use it.
- Any per-type reconciliation keyed on `count of attachments` silently does
  nothing for PDFs.

Locked by `tests/test_attachment_roundtrip.py::test_applescript_count_is_blind_to_pdf_attachments`.

### ⚠️ The decoded placeholder count has a transient

After an attachment write the decoded note text briefly shows **one** `￼` before
settling on **two**. Any assertion that reads the first non-empty decode (which
is what the test harness's `poll` returns) gets the mid-write value. Use
`settled_placeholders()`, which waits for the count to stop changing. Locked by
`tests/test_attachment_roundtrip.py::test_placeholder_count_has_a_transient`.

Locked by `tests/test_attachments.py::test_make_attachment_double_inserts` and
`tests/test_attachment_roundtrip.py::test_double_insert_is_one_attachment_referenced_twice`.
If either starts seeing **1**, Apple fixed the bug — update this section.

### ⚠️ Attaching a PDF errors when you read back its id

`make new attachment` with a PDF creates the attachment but fails on `id of` the
result:

```
Notes got an error: Can't get attachment id "x-coredata://…/ICAttachment/p3594". (-1728)
```

The attachment exists; only the id read fails, and the id itself is in the error
text. macnotesapp handles this with a `parse_id_from_error` helper, which is the
right shape: catch the error, recover the id from the message. Locked by
`tests/test_attachment_roundtrip.py::test_pdf_attach_cannot_read_back_its_id`.

### 🛑 Data-loss bug: a body write flattens checklists

A Notes checklist is a paragraph style, not an embedded object, and **`body`
carries none of it**. A real checklist reads back as:

```html
<ul><li>·</li><li>·</li></ul>
```

with no class, no `data-` attribute, no `<input type="checkbox">`, no checked
state, no marker character — verified by inspecting real checklist notes on this
machine. Writing that HTML back produces a **plain bulleted list**: the CLI
renders a written `<ul><li>` as `- alpha`, never `- [ ] alpha`.

So any body write converts every checklist on the note into a plain list and
discards which items were ticked. It is unrecoverable (the state was never in
the body), invisible (the note still looks like a list), and it applies to the
append pattern as much as to a full rewrite. **48 of 672 live notes here (7%)
contain a checklist.**

Locked by `tests/test_editing.py::test_written_list_is_a_plain_bullet_not_a_checklist`.

**There is no AppleScript fix, structurally.** `Notes.sdef` contains zero
occurrences of `checklist`, `checkbox`, `checked` or `todo` (against 16 for
`attachment`, 35 for `note`) — the vocabulary does not exist. 13 candidate
markups were tried and all land as `style_type: -1` instead of `103`; see
[`prior-art.md`](prior-art.md). The Shortcuts action **"Append checklist item"**
is the only known working route, at the cost of shipping a `.shortcut` file,
since `/usr/bin/shortcuts` can run but not author.

⚠️ When re-testing this, assert on the **paragraph style**, not on exported
Markdown: the exporter renders a checklist as `- [ ]`, so a note containing that
literal text makes a naive check pass.

Bold, italic, highlights, links and ordinary bullet lists *do* survive a round
trip — checklists are the exception.

### 🛑 Data-loss bug: editing `body` destroys all attachments

*Any* write to `body` deletes **every attachment on the note**. This is not
gradual; one write wipes them all. Confirmed on macOS 26 and 27. `set body`
full-replace and the read-modify-write "append" pattern both trigger it.

**But `body` is not uniformly blind, and what it carries decides recoverability.
There are three classes, not two** — measured against the real store by picking
notes where one object type is the only type present, so attribution is
unambiguous:

| Object type | UTI | In `body` as | Survives a body edit? |
|---|---|---|---|
| **table** | `com.apple.notes.table` | `<object><table>…` markup | **yes, for free** — keep the markup |
| image | `public.png` / `jpeg` / `tiff` / `heic` | `<img src="data:…">` | yes, but must be **harvested and re-added** |
| drawing | `com.apple.drawing.2` | `<img>` — a flat PNG render | picture only; **flattens to `public.png`** |
| Paper doc | `com.apple.paper` | `<img>` — a flat PNG render | picture only; flattens |
| scan | `com.apple.paper.doc.scan` | *nothing* | **no** |
| PDF | `com.adobe.pdf` | *nothing* | **no** |
| text file | `public.plain-text` | *nothing* | **no** |

**Tables are the one type a body edit preserves for free.** Their content travels
in the HTML, so writing back a body that still contains the `<table>` markup
keeps the table and all its cells. Drop the markup and the table is deleted.
Locked by `test_table_survives_a_body_roundtrip` and
`test_table_is_destroyed_when_its_markup_is_dropped`.

⚠️ Markup round-tripping is **type-specific and does not generalise**: putting
`<table>` HTML in a written body creates a real table, but putting
`<img src="data:…">` in one creates an *empty* attachment (see below). Images
must go back as files, not as markup.

⚠️ **A drawing is not an image**, though `body` renders it as one. Recovering it
through the harvest-and-re-add path necessarily produces a `public.png` — the
picture survives, the editable strokes do not. *(Inferred from the UTI change;
not tested against a real drawing, because that would mean writing to a real
note.)*

⚠️ **Each body round-trip leaks orphaned table rows**, and how many is not
deterministic (2 in isolation, 3 under the full suite). The note still shows one
table, but `ZICCLOUDSYNCINGOBJECT` gains rows, so a row count is not a valid way
to count a note's tables. Locked by
`test_table_roundtrip_leaves_orphaned_object_rows`.

For attachments there is a partial preserving path, for images only.
Harvest every data URI from `body` before the write, then decode each back to a
file and re-attach it afterwards. Verified byte-exact and order-preserving by
`tests/test_attachment_roundtrip.py::test_image_roundtrip_preserves_bytes_and_order`.
The technique is from [antoniorodr/memo](https://github.com/antoniorodr/memo);
see [`prior-art.md`](prior-art.md).

Its costs, all verified: non-image attachments are still destroyed silently;
original filenames do not survive (the attachments are rebuilt, so they take the
name of the temp file); and every restored image lands at the **end** of the
note, because `make new attachment` cannot place one mid-text.

🛑 **Do not "improve" this by writing the data URI inline. It stores nothing.**

`set body` with an `<img src="data:image/png;base64,…"/>` creates an attachment
row and puts the placeholder at the **correct position** in the text rather than
at the end — the only thing that can place an attachment mid-note, so it looks
strictly better than `make new attachment`. It is pure data loss. The row is
empty:

```
ZFILENAME = NULL   ZFILESIZE = 0   ZTYPEUTI = 'public.data'
```

and **no file is ever written** — polled 30s, and nothing appears under
`Accounts/`. The bytes are discarded. True for `image/png`, `application/pdf`
and `text/plain` alike, via `<img src>` or `<object data>`, so there is no safe
variant. (`<embed>` is ignored entirely; `<a href="data:…">` keeps the base64 in
the body as a link and creates no attachment at all — the one form that does
preserve the payload, though only as link text.)

**There is therefore no way to place an attachment mid-note.** Everything lands
at the end. Locked by
`tests/test_attachment_roundtrip.py::test_inline_data_uri_write_discards_the_payload`.

Locked by `tests/test_attachments.py::test_editing_body_destroys_attachments`. If
it starts preserving attachments, Apple fixed it — update this section.

### How attachments appear to the SQLite reader

Each embedded object is a single U+FFFC (`￼`) object-replacement char in the
decoded note text. The run covering it carries `attachment_info.type_uti` and
`attachment_info.attachment_identifier` in the protobuf, and the matching
`ZICCLOUDSYNCINGOBJECT` row (keyed by `ZIDENTIFIER`) holds the human name
(`ZFILENAME` / `ZTITLE` / `ZURLSTRING` / `ZALTTEXT`).

The exporter resolves these rather than printing bare `￼`:

- A **divider** (`type_uti = com.apple.notes.inlinetextattachment.dividerline`)
  becomes a markdown thematic break `---`, padded with a leading blank line so
  `text\n---` is not parsed as a setext heading.
- Any other embedded object becomes `[attachment: <name>]`, using the DB name
  when available and otherwise falling back to a type-derived label
  (`[attachment: table]`, `[attachment: hashtag]`, or the raw UTI).

See `embedded_object_markdown` / `get_attachment_labels` in the `apple-notes`
script. Behavior is locked by `tests/test_rendering.py` (pure unit tests, no live
Notes needed) and `tests/test_attachments.py::test_export_renders_*` (live).

---

## 4. The test suite

The suite drives **live Notes.app** and verifies via both paths, so it cannot run
in CI and it briefly creates/deletes notes in your iCloud account.

```sh
./run-tests                 # full suite, verbose
./run-tests test_attachments  # one module
```

Safety model:

- The suite is **gated** behind `RUN_LIVE_NOTES_TESTS=1` (the `run-tests` script
  sets it); a plain `python -m unittest` skips everything.
- Every test note is named with the prefix `__claude_notes_test__`. `delete_note`
  and `sweep_test_notes` **refuse to touch** any note lacking that prefix, so the
  suite can never delete your real notes.
- `temp_note()` guarantees deletion in teardown even on failure; each module
  sweeps before and after. Because soft delete + a second sweep permanently
  removes test notes, nothing is left in Recently Deleted either.
- SQLite assertions `poll()` for a few seconds, since local AppleScript edits
  reach `NoteStore.sqlite` with a short lag.

Files: `tests/harness.py` (AppleScript + read-only SQLite helpers),
`tests/test_attachments.py`, `tests/test_editing.py`, `tests/test_reading.py`.
