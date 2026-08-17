# Reading a table out of Apple Notes

Everything learned decoding `com.apple.notes.table` blobs. Verified on
**macOS 27.0**, against the 76 tables in the development store. Nothing here is
documented by Apple.

## Where a table lives

Not in the note body. The body holds a single **U+FFFC** with an attribute run
naming an attachment; the cells sit in that attachment row's
**`ZMERGEABLEDATA1`** — the same column call recordings use, read by the same
`mergeable.py`.

```sql
SELECT Z_PK, ZIDENTIFIER, ZMERGEABLEDATA1
  FROM ZICCLOUDSYNCINGOBJECT
 WHERE ZTYPEUTI = 'com.apple.notes.table';
```

The wire format is already written down in
[`../notes/notestore.proto`](../notes/notestore.proto) — `OrderedSet`,
`OrderedSetOrdering`, `Dictionary`, `MergeableDataObjectEntry`. The schema was
never the hard part. Every trap below is a place where a *plausible* reading
parses cleanly and gives the wrong table.

## The object graph

```
com.apple.notes.ICTable
  .crRows        -> OrderedSet   row order
  .crColumns     -> OrderedSet   column order
  .cellColumns   -> Dictionary   column UUID -> (Dictionary: row UUID -> Note)
```

🛑 **`cellColumns` is column-major.** The grid has to be transposed on the way
out. A reader that treats the outer key as a row silently produces the
transpose of the real table, which for a square table is not obviously wrong.

## 🛑 The four traps

Each one returns a clean, believable result rather than an error.

### 1. A table blob is gzipped; an audio blob is not

All 76 table blobs on this store start `1f 8b`. All 3 audio blobs are raw
protobuf. Both arrive through the same column, so the reader sniffs the magic
rather than trusting the UTI.

### 2. A table blob carries two more wrapper levels

| Blob | Entries live at |
|---|---|
| audio (`ICTTAudioRecording`) | `root.3` |
| table (`ICTable`) | `root.2.3` |

`MergableDataProto → MergableDataObject → MergeableDataObjectData`. Reading the
audio shape on a table blob yields **zero entries and no exception**, which
reads as "this note has no table" rather than as a parse failure.

⚠️ An audio blob carries **both** field 2 and field 3, so the sniff keys off
*field 3 being absent*, not on field 2 being present. Sniffing the other way
misreads every recording.

### 3. A cell key is a reference to an NSUUID object, keyed `UUIDIndex`

A dictionary key is not a UUID and not an index into the UUID table. It is
`("ref", n)` — an entry index — and that entry is a
`com.apple.CRDT.NSUUID` custom map whose scalar sits under **`UUIDIndex`**, an
index into the blob's UUID table.

⚠️ `MergeableData._custom_map` unwraps a CRDT scalar by looking under `self`,
so it returns **None** for one of these. The table path therefore reads raw
ObjectIDs (`_raw_map`, `_raw_dictionary`) instead of going through it.

### 4. 🛑 Row/column UUIDs are a different UUID space from the cell keys

This is the expensive one. `crRows` and `crColumns` order a set of UUIDs that
**do not appear as cell keys at all**. On one real table the ordering side used
UUID-table indices 9–16 while the cells used 3–8 — disjoint.

`ordering.contents` is the map between them:

```
OrderedSet
  .ordering.array.attachment   [(position, ordering UUID)]  display order
  .ordering.contents           ordering UUID -> CELL UUID   the alias
  .elements                    which ordering UUIDs are live
```

Skipping `contents` gives a table of exactly the **right size** whose every
cell is empty. In a note that renders as an empty table, not as a bug.

⚠️ **`contents` also keeps deleted rows and columns.** One table here lists
three columns in `contents` and one in `elements`. Reading `contents` alone
invents columns the user cannot see in Notes.app — the same orphan-row pattern
`apple maps` hits in `ZVISITEDLOCATION`.

## 🛑 A fifth trap, in the note body rather than the blob

**An `AttributeRun.length` counts UTF-16 code units. Python indexes code
points.** Every astral character — every 🎢-style emoji — is 2 units and 1 code
point, so each one shifts every later run one character left.

Measured on a real note: 40 astral characters, run lengths summing to **6692**
against **6652** code points. The consequence was not subtle formatting drift.
The table's own run had drifted off its U+FFFC entirely, so a 46-row table
rendered as a bare `[attachment]`.

This predates table support and affected bold, highlight and heading placement
on every emoji-bearing note. `utf16_length` in `notes/apple-notes` fixes it.

## Rendering

`Table.markdown()` emits a GitHub pipe table. Three lossy conversions, all
forced by the target format:

1. **Row 1 becomes the header.** Notes has no header row; Markdown requires
   one. Not reversible from the output.
2. **A newline inside a cell becomes a space.** A pipe table is line-based.
3. **A `|` inside a cell is escaped** to `\|`.

🛑 **That attachment row has a NULL `ZNOTE`**, so nothing joins it to the note
it visibly belongs to. `get_note_tables` therefore decodes **twice**: once to
learn which identifiers the cells use, then again with those labels resolved.

Not read at all: column widths and `crTableColumnDirection`.

## Cell contents

A cell carries the same `AttributeRun` attributes a note paragraph does, so it
must render the same way. Reading only `note_text` made `export` report a bold
cell as plain while reporting a bold paragraph as bold — one command giving two
answers for one attribute.

`cell_text` walks the runs and emits `**bold**`, `==highlight==` and
`[text](url)`. Measured on the development store: 1,723 non-empty cells, of
which 330 are bold and 264 carry a URL.

🛑 **A run's `length` counts UTF-16 code units here too**, so the text is sliced
as UTF-16. See the fifth trap above.

🛑 **Merge runs before wrapping them.** Notes splits one styled phrase across
several runs, and wrapping each separately gives `**a****b**` or `[a](u)[b](u)`
— two spans where the user made one. 26 adjacent run pairs here share a single
URL.

🛑 **Merge on the run's real style.** Notes stores the space inside a bold
phrase as its own *bold* run. Treating a whitespace-only run as unstyled — so
a marker always sits against a word — splits the phrase into `**Hyperspace**
**Mountain**` instead. Nine cells came out that way. The markers are moved off
the whitespace afterwards, where it costs nothing.

⚠️ **Highlight in a cell is unexercised by real data.** All 40 coloured runs in
cells here are link blue or near-black, and none is the yellow highlight. Only
the unit test covers it.

Still not read: font and colour.

## Links, in bodies and in cells

Three separate mechanisms carry a link, and each needed its own handling.

### 1. A URL on text — `AttributeRun.link`, field 9

297 runs across 107 note bodies, and 264 runs across 6 tables. The body parser
always read this into `run["link"]`; nothing rendered it, so links vanished
from paragraphs as well as from cells.

⚠️ **Two shapes want two outputs.** 88 body runs have text equal to the URL,
which is a link the user pasted; `[url](url)` is noise, so the bare URL is
emitted. The other 209 are real anchors and become `[text](url)`.

🛑 **Not every field-9 value is a link the user made.** `x-apple-data-detectors`
is Notes recognising a date or an address in typed text, and `x-coredata` is an
internal row reference. Rendering either invents a link that was never there.
Both are refused by `usable_link`.

⚠️ **A link may not span a line in Markdown**, and 9 link runs here contain a
newline. One is closed at the line break and reopened on the next line.

⚠️ **Markers close in the reverse of their opening order** — link, then
highlight, then bold — so a bold link reads `**[text](url)**`. Closing in the
opening order gives `**==text**==`, which no parser reads as nested.

### 2. A note link, as an inline attachment

126 in bodies, 15 in cells. A U+FFFC whose UTI is
`com.apple.notes.inlinetextattachment.link`; the target sits in
`ZTOKENCONTENTIDENTIFIER` as `applenotes:note/<uuid>` and the display text in
`ZALTTEXT`.

🛑 **Your store uses both mechanisms for note links** — 50 field-9 runs carry an
`applenotes:` URL and 126 inline attachments do. Handling one alone leaves most
note links broken.

### 3. Other inline text attachments

| Kind | Count | Was | Now |
|---|---|---|---|
| hashtag | 92 | `[attachment: #trips]` | `#trips` |
| calculateresult | 8 | `[attachment: ‎ = 201.163]` | `= 201.163` |
| mention | 1 | `[attachment: @Dan]` | `@Dan` |

🛑 **None of these is an attachment in any useful sense.** They are text Notes
stores out of line.

🛑 **`ZTOKENCONTENTIDENTIFIER` is not always a URI.** A hashtag stores a bare
word (`TRIPS`) and a mention stores an account id. Only a value that parses as
a URI may become a link, which is what `looks_like_uri` guards.

## Escaping the source text

⚠️ **A literal `*` in a note used to come back mixed with real bold markers.**
219 asterisks live in these notes. `escape_markdown` escapes what could be read
as a marker this tool emits, and nothing else:

| Character | Escaped | Why |
|---|---|---|
| `\` | always | otherwise escaping is not reversible |
| `*` | always | 198 single, 9 double, 1 triple here |
| `=` | only beside another `=` | a lone `=` is never a marker and is common in URLs |
| `_` | only when not inside a word | CommonMark ignores an intraword one, and 183 of 196 here are intraword |
| `[` `]` | **never** | they only form a link beside a `](`, and **no note in the store contains that sequence** |

🛑 **Escape the source character, never the markers.** In the body the escape
happens as each character is appended, after the markers are placed. In a cell
it happens before the U+FFFC substitution, so a rendered link's own brackets
survive.

⚠️ **A cell can carry text with no attribute run at all**, and the early return
for that case skipped escaping. Found by a test, not by the sweep.

## 🛑 Line breaks `split("\n")` does not see

`apply_formatting` splits on `\n`. A renderer splits on more than that, so a
marker span crossing one of the others is unbalanced on both halves.

Two occur here. Notes writes **U+2028** for Shift-Return — 254 of them, 239 in
plain paragraphs. And **`\r`** survives in pasted text; a bold run holding
`'\r\n'` is what exposed the whole class.

`SOFT_LINE_BREAKS` covers every character `str.splitlines()` breaks on and
`split("\n")` does not. Each one closes every open marker and lets the next
character reopen. The character itself passes through unchanged, so no
paragraph structure moves.

Measured over the whole store, splitting the way a renderer does:

| | unbalanced bold lines | unbalanced highlight lines |
|---|---|---|
| at `HEAD`, before this work | 58 | 1 |
| after escaping and `SOFT_LINE_BREAKS` | **0** | **0** |

## Tests

[`../notes/tests/test_tables.py`](../notes/tests/test_tables.py) builds table
blobs with a small protobuf writer, so it touches neither Notes.app nor the
user's store and needs no `RUN_LIVE_NOTES_TESTS` gate. It pins all five traps,
including a fixture carrying a deleted column.
