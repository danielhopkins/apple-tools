# Rendering a note body as Markdown

`CLAUDE.md` keeps the rules. This file keeps the measurements behind them. The
protobuf and the AppleScript API are in [`apple-notes-api.md`](apple-notes-api.md);
table cells are in [`apple-notes-tables.md`](apple-notes-tables.md).

`notestore.py` ungzips the protobuf note body directly and renders `**bold**`,
`_italic_`, `==highlight==`, `~~strike~~`, `[text](url)`, headings, lists,
checklists and tables.

## `font_weight` is an enum, not a weight

🛑 **1 is bold, 2 is italic, 3 is both.** A reader testing `== 1` for bold loses it
on every weight-3 run.

## Links: three mechanisms, all of which used to break

- **A URL on text** (`AttributeRun.link`) — 297 runs in bodies, 264 in cells.
  ⚠️ 88 body links have the URL as their own text, so those stay bare rather than
  becoming `[url](url)`.
- **A note link** as an inline attachment — 126 in bodies, 15 in cells, with the
  target in `ZTOKENCONTENTIDENTIFIER`. 🛑 Both mechanisms are in use for note
  links; handling one alone leaves most of them broken.
- **A hashtag, mention or inline calculation** — 101 more. 🛑 None is an attachment
  in any useful sense, and `[attachment: #trips]` was wrong for all 227. They
  render as their own text now.

🛑 **Not every link value is a link the user made.** `x-apple-data-detectors` is
Notes recognising a date or an address, and `x-coredata` is an internal row
reference. Both are refused. ⚠️ `ZTOKENCONTENTIDENTIFIER` is likewise not always a
URI — a hashtag stores a bare word — so only values that parse as one become links.

## Escaping

Source text is escaped so it cannot read as a marker: `\` and `*` always; `=` only
beside another `=`; `_` only outside a word. 🛑 `[` and `]` are deliberately left
alone — they only form a link beside a `](`, which no note in the store contains.

## Line breaks a renderer honours

🛑 **`split("\n")` misses them.** Notes writes U+2028 for Shift-Return (254 here)
and `\r` survives in pasted text, so a bold span crossing one used to be
unbalanced on both halves. Every marker now closes at each of them and reopens
after. Over the whole store, split the way a renderer splits: **58 unbalanced bold
lines before this work, 0 after.**

## Tables

**A table's contents are not in the note body at all** — the body holds one U+FFFC
and the cells live in the attachment row's `ZMERGEABLEDATA1` blob, the same column
call recordings use. Measured: 76 of 76 tables on this store decode, and the one
that comes out empty really is an empty 2×2 in Notes.app.

- ⚠️ **Notes has no header row and Markdown demands one, so row 1 is promoted.**
  For a table whose first row is data that changes the meaning, and the output
  alone cannot tell you which happened.
- ⚠️ **A newline inside a cell collapses to a space**, and a `|` is escaped. Both
  are needed to keep the pipe table parseable, and both are lossy.
- 🛑 **A note link inside a cell has an attachment row with a NULL `ZNOTE`**, so
  nothing joins it to the note it visibly sits in. `get_note_tables` decodes once
  to learn which identifiers the cells use, then looks them up and decodes again.
- **A cell renders like a paragraph**: `**bold**`, `==highlight==` and
  `[text](url)`. Reading only the cell's text made `export` call a bold cell plain
  while calling a bold paragraph bold. ⚠️ Highlight in a cell is covered by a unit
  test only — all 40 coloured runs in cells here are link blue or near-black.
- **What is not read**: column widths and `crTableColumnDirection`.

## Locked notes

A password-protected note has no readable body (`ZDATA` is NULL) and no decrypt
path. `search`/`folders` omit them and say so on stderr; `--include-locked` lists
them as `locked: true`. `export` refuses with **exit 2** (distinct from 1, "not
found"); `get-url` still works, since Notes.app prompts for the password itself.

## Search is title-only

There is no full-text search over note bodies. To search content, export
candidates and grep them. The SQLite reader **can see Recently Deleted notes**;
filter them out if the user asked for live notes.
