# Writing notes: the Shortcuts path, the picker trap, and delete

`CLAUDE.md` keeps the rules. This file keeps the evidence. The Shortcuts build
scripts and the AppIntents route are in
[`apple-notes-shortcuts.md`](apple-notes-shortcuts.md); the AppleScript API and
its verified bugs are in [`apple-notes-api.md`](apple-notes-api.md); the Markdown
capability matrix is generated into
[`apple-notes-markdown-support.md`](apple-notes-markdown-support.md).

## Why writes go through Shortcuts

⚠️ **The AppleScript write path is the wrong tool for most writes.** It cannot
create a checklist at all, and its only body write is a full replace that destroys
attachments and flattens checklists. **Shortcuts can do all of it** — a genuine
append that preserves attachments and checklist state, and Markdown interpreted
into native structure, in ~0.3s. It costs a one-time install and a permission
grant per shortcut.

`append` is pinned by `notes/tests/test_append.py`, which checks that a checklist
keeps its checked state across an append.

## The picker trap

🛑 **No target means no append.** The shortcut matches the note by *Name*, and a
name matching nothing does **not** fail — Shortcuts lists every note in a picker
and waits, then writes the text to whatever the human picks. Measured: four queued
appends all landed on a note chosen minutes later, while the note the caller named
sat in Recently Deleted.

⚠️ **Nothing after the fact reveals this.** `shortcuts run` returns in ~2s with
exit 0 while the picker is still open. Timing cannot distinguish a picker from a
permission dialog either. So `append` refuses **before** running: the target must
be a live note, outside Recently Deleted, whose title matches it and nothing else.
It also refuses an ambiguous title rather than appending to every match.

## Installed is not the same as allowed

🛑 **An unallowed shortcut fails silently.** `shortcuts run` against a shortcut
with no permission grant **exits 0, prints nothing, writes nothing, and raises no
dialog** — so every layer above it read success. Observed on macOS 27.0 build
26A5406e with `ZACCESSRESOURCEPERMISSION` empty for both shortcuts; the docs' write
path was verified on build 26A5388g.

Three things reported success for a write that did nothing, all now fixed:

- **`status` said "shortcuts installed (2)"** and called the write path available.
  It now reads the grants out of `ZACCESSRESOURCEPERMISSION` and reports
  `unauthorized` per shortcut. ⚠️ An unreadable Shortcuts library is **unknown**,
  not denied — it must not invent a refusal.
- **`create` exited 0** having created nothing, with the only signal a `"created":
  false` field nobody checks. Both `create` and `append` now exit non-zero and name
  the likely cause.
- **`create`/`append` ran the shortcut at all.** They refuse up front when no grant
  exists, since running is pure loss.

⚠️ **`shortcuts run`'s exit code proves nothing about whether the shortcut did
anything.** Confirm every write by re-reading the store, the way `apple calendar`
and `apple contacts` do.

`APPLE_NOTES_SHORTCUTS_DB` points the grant reader at a different library, which is
how `notes/tests/test_write_path.py` covers all of this offline. 14 tests; 13 of
them fail against the code before this fix.

## The Markdown capability matrix

🛑 **What the write path supports is measured, generated, and checked — never
assumed.**

```
./notes/capability-report            # measure and rewrite the doc
./notes/capability-report --check    # exit 1 if any answer moved
```

**Run `--check` after every macOS update.** `notes/run-tests` runs it too, so a
change in Apple's interpreter fails the suite. It reports two independent columns
per construct — what **Apple stored** (the API surface) and what our **reader gives
back** — because a construct can survive the write and be lost on the read. That is
exactly what happened to italic and strikethrough.

Measured on 26A5406e: everything works except **`==highlight==`** and
**`` `code` ``**, which Apple ignores, plus **`- [X]`** and **`* [x]`**, which do
not make checklists. ⚠️ **`#` becomes the *title* style, not a heading.** ⚠️ **Apple
drops bold inside link text.**

🛑 **A pipe table destroys the last item of the list directly above it.** The item
becomes a plain paragraph. It applies to bullets and checklists alike, whatever the
checked state. Put one paragraph between the list and the table.

⚠️ **Do not hand-probe these answers.** Three wrong conclusions came out of doing
that.

## `delete`

**It moves a note to Recently Deleted, and needs no Shortcut.** AppleScript
`delete` has always worked, and the test harness has used it since the suite was
written — so this costs no build, no signing step and no third permission dialog.
It does need **Automation → Notes** for the calling terminal, and it **launches
Notes.app** if the app is closed. Reads need neither.

🛑 **It addresses the note by primary key, not by name.** An AppleScript note id is
`x-coredata://<Z_METADATA.Z_UUID>/ICNote/p<Z_PK>`, and that UUID is in the same
file the reader already opens — verified equal to the id Notes reports. So `delete`
never hands Notes a name to match, and the picker trap that governs `append` cannot
arise here at all.

🛑 **A partial title is refused, unlike `export`.** `find_note` falls through to
`LIKE '%term%'` and returns the **first** row it finds, which is right for a read
and destructive for a delete: `delete budget` would remove whichever note sqlite
happened to return first, silently. A title here must match in **full**, must name
a **live** note, and **more than one match is refused** listing the ids.

⚠️ **It asks before it deletes.** Without a tty it refuses unless you pass `--yes`,
because a pipe is not consent. Answering anything but `y` exits non-zero, so a
cancel never reads as a delete.

🛑 **Confirmation goes through Notes.app, not the store — the opposite of every
other write here.** The sqlite store lags an **unbounded** amount: measured on this
machine, one delete appeared in sqlite in **3.5s** and another was still sitting in
`ZFOLDER` = `Notes` **more than ten minutes** after Notes.app already listed it in
Recently Deleted. A store read alone cannot tell a slow delete from a failed one,
so it must not decide.

- **`confirmed` is Notes.app's answer**, in about 0.7s, and it is the field to
  read. **`store_confirmed` is sqlite's**, reported separately for a caller that
  goes on to read the store; `--wait` gives it longer, and defaults to 0.
- ⚠️ **`container of note id …` distinguishes nothing.** It fails with **-1728**
  for a deleted note *and* for a live one. Enumerating the Recently Deleted folder
  and asking for the id is what works.
- **A note still in its folder afterwards is a hard failure.** `osascript` exiting
  0 is not evidence the note moved.
- ⚠️ **The folder moves; `ZMARKEDFORDELETION` stays 0.** Measured on every delete
  here. Both are checked, since the reverse can appear mid-sync.

⚠️ **A locked note is refused with exit 2.** Its body cannot be read, so the user
cannot be shown what they are about to destroy. Delete it in Notes.app.

⚠️ **`apple notes search` still lists a deleted note**, because the reader can see
Recently Deleted. A search straight after a delete therefore looks like a failure
and is not; the command says so on stderr. Deletion is recoverable for about 30
days, and **there is no API to empty that folder**.

## The AppleScript gotchas, in full

Each is locked by a live test in `notes/tests/`; full detail in
[`apple-notes-api.md`](apple-notes-api.md).

- 🛑 **Editing `body` destroys attachments.** What survives depends entirely on the
  embedded object's type — **45% of a real store (427 of 939 notes) carries one**:
  - **tables** (`com.apple.notes.table`) survive **for free** — they live in the
    HTML, so keep the `<table>` markup in the body you write. Dropping it deletes
    the table.
  - **images** survive only if you **harvest and re-add** them: they appear as
    `<img src="data:image/png;base64,…"/>`, and re-attaching the decoded bytes is
    byte-exact. Costs: filenames are lost, images move to the end.
  - **drawings** and **Paper docs** appear as flat PNGs, so the picture can be
    recovered but flattens to `public.png` — the strokes are gone.
  - **PDFs, text files and scans** are invisible in `body` and **unrecoverable**.
- 🛑 **A body write flattens every checklist into a plain bulleted list**, losing
  which items were ticked. A real checklist comes back from `body` as a bare
  `<ul><li>` with no checkbox information at all, so it cannot be written back —
  unrecoverable, invisible, and it applies to the innocuous append pattern too. 7%
  of notes here (48 of 672) have one.
- ⚠️ **Writes need a second grant**: **Automation → Notes** for the calling
  terminal, and they **launch Notes.app** if it is closed.
- ⚠️ **A shared note pushes to other people**, not just your other devices, and
  there is no undo. Check `ZSERVERSHAREDATA` before writing.
- `set body` is a **full replace**, never a merge, and the **first line becomes the
  title**, silently, on every body write.
- `make new attachment` **double-inserts** on macOS 27 — one attachment record,
  referenced twice. Deleting the surplus immediately (`if (count of attachments of
  n) > EXPECTED then delete last attachment of n`) fixes it **for images**. For a
  PDF it is a no-op and the duplicate is unfixable.
- 🛑 **`count of attachments` is blind to PDFs** — it returns 0 for a note that
  holds one, and `attachments of n` enumerates nothing, while the file sits on disk
  byte-exact. Never treat a count of 0 as "no attachments". **Verify writes through
  the SQLite store**, not through AppleScript.
- **Attaching a PDF errors on reading the id back** (`-1728, Can't get attachment
  id`). The attachment is created; only the id read fails, and the id is in the
  error text.
- 🛑 **Writing a `data:` URI into `body` stores nothing** — it creates an empty
  `public.data` attachment (0 bytes, no file) at the right position. There is no way
  to place an attachment mid-note; everything lands at the end.
