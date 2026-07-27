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
| 🛑 **editing `body` destroys attachments** | `body` omits attachments entirely, so the first write to it deletes them all. See §3. | `test_attachments::test_editing_body_destroys_attachments` |

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

**Workarounds:** add once then delete the surplus attachment; or drive
attachments through Shortcuts instead of AppleScript; or verify
`count of attachments` afterward and reconcile.

Locked by `tests/test_attachments.py::test_make_attachment_double_inserts`. If
that test starts seeing **1**, Apple fixed the bug — update this section.

### 🛑 Data-loss bug: editing `body` destroys all attachments

Reading a note's `body` returns **only its text/HTML — attachments are not
represented in it at all** (no `<object>`, no `￼` placeholder). Therefore *any*
write to `body` replaces the note with attachment-free content, so **the first
body edit deletes every attachment on the note.** This is not gradual; one write
wipes them all. Confirmed on macOS 26 and 27. `set body` full-replace and the
read-modify-write "append" pattern both trigger it.

**There is no attachment-preserving edit path through `body`.** Treat a note with
attachments as effectively read-only via AppleScript body editing. If you must
edit such a note, plan to re-add the attachments afterward (and remember the
double-insertion bug when you do), or edit it by hand in the UI.

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
