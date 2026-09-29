# notes — `apple notes`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple notes`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

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
[`docs/apple-notes-rendering.md`](apple-notes-rendering.md), and the traps in
the blob itself — all four of which produce a wrong table rather than an error —
are in [`docs/apple-notes-tables.md`](apple-notes-tables.md). Three worth
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
[`docs/apple-notes-transcripts.md`](apple-notes-transcripts.md).

**Writes go through Shortcuts, and the CLI hides that.** `create` and `append` take
a body as `--body`, `--body-file FILE`, `--body-file -`, or a bare pipe. Markdown
becomes native structure: `- [ ]` and `- [x]` are real checklists with their
checked state, pipe tables are real tables. `append` is a genuine append — it
**preserves attachments and existing checklists**, unlike the AppleScript body
write. The full write story is in
[`docs/apple-notes-writes.md`](apple-notes-writes.md); the AppIntents route
and build scripts are in
[`docs/apple-notes-shortcuts.md`](apple-notes-shortcuts.md).

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
[`docs/apple-notes-markdown-support.md`](apple-notes-markdown-support.md),
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
[`docs/apple-notes-writes.md`](apple-notes-writes.md) and
[`docs/apple-notes-api.md`](apple-notes-api.md). The two that matter most:

- 🛑 **Editing `body` destroys attachments** — and **45% of a real store (427 of 939
  notes) carries one**. Tables survive for free, images only if you harvest and
  re-add them, and **PDFs, text files and scans are unrecoverable**.
- 🛑 **A body write flattens every checklist into a plain bulleted list**, losing
  which items were ticked, unrecoverably and invisibly. 7% of notes here have one.
