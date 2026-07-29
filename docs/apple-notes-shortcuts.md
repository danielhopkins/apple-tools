# Driving Apple Notes through Shortcuts

Everything learned making `shortcuts run` a usable write path for Notes.
Verified on **macOS 27.0 (build 26A5388g)**. Nothing here is documented by
Apple; all of it was read out of system files or reverse-engineered from working
shortcuts, and every claim below was tested against the live store.

## Why bother

AppleScript's Notes vocabulary is two commands and four classes. It cannot
express a checklist, cannot delete an attachment, and its only body write is a
full replace that destroys every attachment and flattens every checklist. See
[`apple-notes-api.md`](apple-notes-api.md).

Notes' Shortcuts surface has **51 actions**. Read them yourself:

```bash
python3 - <<'PY'
import json, pathlib
d = json.loads(pathlib.Path("/System/Applications/Notes.app/Contents/Resources/"
                            "Metadata.appintents/extract.actionsdata").read_bytes())
acts = d.get("actions") or next(v for v in d.values() if isinstance(v, dict) and len(v) > 20)
for k, a in sorted(acts.items()):
    print(f"{(a.get('title') or {}).get('key',''):<36} {a.get('fullyQualifiedTypeName')}")
PY
```

The ones that matter: `Append to Note`, `Create Note` (both take
`interpretAsMarkdown`), `Append Checklist Item`, `Set Checklist Items Checked`,
`Delete Checklist Items`, `Add File to Note`, `Delete Attachments`,
`Add Table to Note`, `Set Paragraph Style`, `Add or Remove Note Lock`.

## What it buys, measured

Appending to a note that carried both an attachment and a checklist — the two
things `set body` annihilates:

| | before | after append |
|---|---|---|
| attachment (`public.png`) | 1 | **1, survived** |
| checklist items | 2 | 4 (originals kept, new one added) |
| checked state | `[done 0, done 1]` | **preserved** |
| appended `- [x] item` | — | a **real** checklist item, checked |

Markdown is interpreted into native structures, not text that resembles them:

| Markdown | Store |
|---|---|
| `- [ ] task` | `style_type: 103`, `checklist: {done: 0}` |
| `- [x] task` | `style_type: 103`, `checklist: {done: 1}` |
| `- bullet` | `style_type: 101` |
| pipe table | a real `com.apple.notes.table` |
| `**bold**` | bold, markers consumed |

Steady-state run time is **0.25–0.45s**, faster than the AppleScript write path.

## The file format

A `.shortcut` is a plist. `shortcuts sign --mode anyone -i in -o out` wraps it in
the AEA1 archive Shortcuts accepts. The envelope needs `WFWorkflowActions`,
`WFWorkflowClientVersion`, `WFWorkflowIcon`, `WFWorkflowTypes`,
`WFWorkflowInputContentItemClasses` and friends — see
[`../notes/shortcuts/build-shortcut.py`](../notes/shortcuts/build-shortcut.py).

Each action:

```python
{"WFWorkflowActionIdentifier": "is.workflow.actions.appendnote",
 "WFWorkflowActionParameters": {"UUID": "<uuid>", ...params}}
```

App-backed actions additionally carry an `AppIntentDescriptor`:

```python
{"TeamIdentifier": "0000000000", "BundleIdentifier": "com.apple.mobilenotes",
 "AppIntentIdentifier": "AppendToNoteLinkAction", "Name": "Notes"}
```

### Wiring values between actions

- **A whole value** (entity, dictionary, list) — `WFTextTokenAttachment`:
  ```python
  {"Value": {"OutputUUID": "<earlier action UUID>", "Type": "ActionOutput",
             "OutputName": "Note"},
   "WFSerializationType": "WFTextTokenAttachment"}
  ```
- **Inside a text field** — `WFTextTokenString`, where each U+FFFC in `string`
  maps to an attachment by character range:
  ```python
  {"Value": {"string": "￼",
             "attachmentsByRange": {"{0, 1}": {"OutputUUID": "...",
                                               "Type": "ActionOutput",
                                               "OutputName": "text"}}},
   "WFSerializationType": "WFTextTokenString"}
  ```
- **The shortcut's own input** — the same shapes with `{"Type": "ExtensionInput"}`
  in place of the `OutputUUID`/`Type` pair.

## 🛑 The five traps

Each of these cost a build-sign-install-test cycle.

### 1. The intent metadata lies about names

`extract.actionsdata` gives you an action's *conceptual* parameters. The
*serialized* names are frequently different, and the action identifier usually
is too:

| Action | Metadata says | Plist actually needs |
|---|---|---|
| Create Note | `com.apple.Notes.CreateNoteLinkAction`, `contents` | `com.apple.mobilenotes.SharingExtension`, **`WFCreateNoteInput`** |
| Append to Note | `com.apple.Notes.AppendToNoteLinkAction`, `entity`, `text` | `is.workflow.actions.appendnote`, **`WFNote`**, **`WFInput`** |
| Delete Notes | — | `com.apple.Notes.DeleteNotesLinkAction`, `entities` |

There is no rule. Delete really does use the `com.apple.Notes.*` prefix while
Create uses a legacy `com.apple.mobilenotes.*` one. **Always copy the
serialization from a working shortcut** (see Debugging), never derive it from
the metadata.

### 2. A wrong parameter name prompts instead of failing

This is what makes trap 1 expensive. Shortcuts does not error on an unrecognised
parameter — it falls back to **asking the user**, so:

- wrong text parameter → *"New note…"* text prompt
- wrong note parameter → a **note picker** listing every note

`shortcuts run` then blocks forever. From the CLI all you see is a hang, so
**always run with a timeout**, and read a hang as "a parameter did not bind",
not as "the action is broken".

### 3. Shortcuts silently normalises the action identifier but not the parameters

Import rewrites `com.apple.Notes.AppendToNoteLinkAction` to the canonical
`is.workflow.actions.appendnote` — while leaving your wrong parameter names
untouched. The action therefore *renders correctly in the editor* and fails only
at run time. Do not take "it looks right in Shortcuts" as evidence.

### 4. Import rewrites every UUID

Action UUIDs are regenerated on import, and references are rewired to match.
This is harmless — but it means the UUIDs in your source file are not the ones
at run time, so debug by reading back the stored plist, not your input.

### 5. Input arrives typed by file extension

`shortcuts run --input-path FILE` types the input from the **extension**, and a
type outside the shortcut's `WFWorkflowInputContentItemClasses` is dropped
silently — the shortcut runs, exits 0, and does nothing.

| Extension | Delivered as text? |
|---|---|
| `.md` | yes |
| `.txt` | yes |
| `.text` | yes |
| **`.json`** | **no — silently dropped** |

So a JSON payload must be written to a `.txt` file. The content is irrelevant;
only the extension matters.

## Permissions

Two human actions, both one-time, both **per shortcut**:

1. **Install.** `open X.signed.shortcut` and accept. There is no headless
   install — `shortcuts` has `run`, `list`, `view`, `sign` and nothing else.
   Writing `Shortcuts.sqlite` directly would fight CloudKit sync.
2. **Authorise.** The first run raises *"Allow «shortcut» to append 1 text item
   and 1 note to a note?"* with a preview of the data, and Don't Allow /
   Allow Once / **Always Allow**.

⚠️ **The grant is per-shortcut, not per-note**, despite the dialog listing
specific notes — that list is a preview of the run, not a scope. Verified: a
note created *after* the grant was appended to silently. "Always Allow" means
*this shortcut may write to Notes, unattended, forever*.

✅ **Which makes "Allow Once" a genuine human-in-the-loop gate.** Decline the
standing grant and every single write shows the user exactly what text is going
into which note, enforced by the OS rather than by our own code. For an
agent-driven write path that is a confirmation surface worth having on purpose.

Because grants are per-shortcut, N shortcuts cost N grants — an argument for one
general-purpose shortcut over several narrow ones.

## Debugging

**Read a working shortcut.** The library is a Core Data store at
`~/Library/Shortcuts/Shortcuts.sqlite`; `ZSHORTCUTACTIONS.ZDATA` is a plist
holding a bare *list* of actions.

```python
import sqlite3, plistlib, json
c = sqlite3.connect("file:" + DB + "?mode=ro", uri=True)
for name, data in c.execute("SELECT s.ZNAME, a.ZDATA FROM ZSHORTCUT s "
                            "JOIN ZSHORTCUTACTIONS a ON a.ZSHORTCUT = s.Z_PK"):
    for a in plistlib.loads(data):
        print(name, a["WFWorkflowActionIdentifier"],
              json.dumps(a["WFWorkflowActionParameters"], default=str)[:200])
```

Copy the file before reading it — the live one has a busy WAL.

**Verify your own shortcut after import** by reading it back the same way and
checking that every `OutputUUID` resolves to some action's `UUID`. A dangling
reference is a silent no-op.

**Isolate the failing stage** by feeding a payload to a shortcut already known to
work. That is how trap 5 was found: the known-good Create shortcut produced
nothing from a `.json` file, which located the fault in input typing rather than
anywhere in the five-action append.

## Remaining unknowns

- **Name matching is ambiguous.** `is.workflow.actions.filter.notes` matches on
  `Name`, and names are not unique — a permission dialog offering to append to
  *"2 note"* is what exposed it. Resolving by identifier, or refusing on multiple
  matches the way `apple messages` does, is unsolved here.
- No example anywhere in the sampled library puts a **variable inside a filter
  template**; the serialization used here was inferred and then confirmed to
  work, but it is the least-corroborated part of the schema.
- Notes written through Shortcuts, once deleted via AppleScript, keep
  `ZFOLDER` and `ZMARKEDFORDELETION = 0` in SQLite for at least ~35s, so the
  CLI's reader still lists them. Whether it ever settles is untested.
- Whether `Add File to Note` avoids the AppleScript double-insert, and whether
  `Delete Attachments` works at all, are both untested.
