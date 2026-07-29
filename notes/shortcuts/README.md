# Driving Notes' AppIntents from the CLI

AppleScript's Notes vocabulary is tiny — two commands, four classes — and it
cannot express a checklist, cannot delete an attachment, and its only write to a
note body is a full replace that destroys attachments and flattens checklists.

The Shortcuts surface is a different story: **51 actions**, read out of
`/System/Applications/Notes.app/Contents/Resources/Metadata.appintents`. Among
them:

| Action | Intent | Why it matters |
|---|---|---|
| Append to Note | `Notes.AppendToNoteIntent` | a real **append**, not a body replace — takes `interpretAsMarkdown` |
| Create Note | `Notes.CreateNoteIntent` | takes `interpretAsMarkdown` |
| Append Checklist Item | `Notes.CreateChecklistItemIntent` | the checklist write AppleScript cannot do |
| Set Checklist Items Checked | `Notes.SetChecklistItemsCheckedIntent` | toggle checked state |
| Delete Attachments | `Notes.DeleteAttachmentsIntent` | AppleScript has no safe route to this |

`/usr/bin/shortcuts` can `run` a shortcut headlessly and pipe input to it, but it
can only `run`, `list`, `view` and `sign` — **it cannot author one**. So reaching
those intents means shipping a `.shortcut` file the user installs once.

## The file format, learned empirically

Not documented. Read out of existing shortcuts in
`~/Library/Shortcuts/Shortcuts.sqlite` (`ZSHORTCUTACTIONS.ZDATA` is a plist —
a bare *list* of actions). An AppIntents-backed action looks like:

```python
{"WFWorkflowActionIdentifier": "com.apple.Notes.CreateNoteLinkAction",
 "WFWorkflowActionParameters": {
     "AppIntentDescriptor": {"TeamIdentifier": "0000000000",
                             "BundleIdentifier": "com.apple.Notes",
                             "AppIntentIdentifier": "CreateNoteLinkAction",
                             "Name": "Notes"},
     "contents": <shortcut input>,
     "interpretAsMarkdown": True}}
```

The action identifier is `<BundleIdentifier>.<AppIntentIdentifier>`, where the
identifier is the **key** in the app's `extract.actionsdata` — not the
`fullyQualifiedTypeName`. `Notes.CreateNoteIntent`'s key is
`CreateNoteLinkAction`.

"Shortcut Input" bound to a text parameter is a `WFTextTokenString` whose single
U+FFFC maps to an `ExtensionInput` attachment.

A `.shortcut` file is that plist wrapped in the workflow envelope
(`WFWorkflowActions`, `WFWorkflowClientVersion`, icon, input classes …).
`shortcuts sign --mode anyone` turns it into the AEA1 archive Shortcuts accepts.

## Building

```
python3 build-shortcut.py "Claude Notes Markdown.shortcut"
shortcuts sign --mode anyone \
    --input  "Claude Notes Markdown.shortcut" \
    --output "Claude Notes Markdown.signed.shortcut"
```

## Installing (one time, needs a human)

Shortcuts has no headless install path, and writing to `Shortcuts.sqlite`
directly would fight CloudKit sync. So:

```
open "Claude Notes Markdown.signed.shortcut"
```

and accept the prompt. After that it runs headlessly:

```
shortcuts run "Claude Notes Markdown" --input-path note.md
```

## Status: ✅ works, verified end to end

`shortcuts run` from the CLI creates a note whose structures are **genuinely
native**, which AppleScript cannot do at all:

| Markdown in | Result in the store |
|---|---|
| `- [ ] first task` | `style_type: 103`, `checklist: {done: 0}` |
| `- [x] done task` | `style_type: 103`, `checklist: {done: 1}` |
| `- plain bullet` | `style_type: 101` |
| a pipe table | a real `com.apple.notes.table` object |
| `**bold**` | rendered bold, markers consumed |

**Second run: 0.246s, exit 0, no prompt.** So it is genuinely headless once set
up — comfortably faster than the AppleScript write path.

### The one-time cost, in full

1. **Install** — `open ClaudeNotesMD2.signed.shortcut`, accept. No headless path.
2. **Authorise** — the *first* run raises *"Allow «shortcut» to save 1 text item
   in a note?"* with Don't Allow / Allow Once / **Always Allow**. Choosing
   Always Allow makes every later run silent. Until then each run blocks on the
   dialog, and a CLI caller just sees `shortcuts run` hang — a 45s timeout is
   worth having.

Both are per-shortcut, so shipping N shortcuts costs N grants. That argues for
one general-purpose shortcut over several narrow ones.

### Two traps found while proving this

- 🛑 **A wrong parameter name does not error — it prompts.** The first attempt
  used `contents` instead of `WFCreateNoteInput`; Shortcuts silently fell back
  to asking the user ("New note…") and `shortcuts run` hung until timeout. So a
  hang is the signature of a mis-named parameter, not of a broken action.
- ⚠️ **Notes created this way resist deletion in the SQLite view.** After
  AppleScript delete, Notes.app no longer sees them (`count` = 0) but their rows
  keep `ZFOLDER = 'Notes'` and `ZMARKEDFORDELETION = 0` for at least ~35s, so
  the CLI's reader still lists them. Same behaviour as markdown-imported notes.
  Whether it ever settles is unverified.

## The append: ✅ it preserves what `set body` destroys

Measured on a note carrying **both** an attachment and a checklist — the two
things an AppleScript body write annihilates:

| | before | after append |
|---|---|---|
| attachment (`public.png`) | 1 | **1 — survived** |
| checklist items | 2 | 4 (2 kept + appended) |
| checked state | `[done 0, done 1]` | `[done 0, done 1, …]` — **kept** |
| appended text | — | present |
| appended `- [ ] task three` | — | a **real** checklist item |

**Second run: 0.331s, exit 0, silent.** So this is a genuine append: additive,
attachment-safe, checklist-safe, Markdown-aware, and fast. Nothing in the
AppleScript surface can do any of that.

### The permission grant is per-shortcut, not per-note

The dialog lists the notes it is about to touch, which reads like a scope
picker. It is not — the list is a **preview of that run's data**. Tested: a note
created *after* "Always Allow" was granted was appended to silently (0.393s, no
prompt). Same for Create, which made several different notes after one grant.

So "Always Allow" means *this shortcut may write to Notes, unattended, forever*.

**That makes "Allow Once" a genuine human-in-the-loop gate**, and a useful one:
decline the standing grant and every single write shows the user exactly what
text is going into which note, with Don't Allow / Allow Once. For an agent-driven
write path that is a built-in confirmation surface we would otherwise have to
build — and it is enforced by the OS rather than by our own code. Worth exposing
as a deliberate choice rather than telling users to click Always Allow.

### ⚠️ Name matching is ambiguous

`is.workflow.actions.filter.notes` matches on `Name`, and two notes can share
one. The permission dialog gave it away — *"append 1 text item and 2 note to a
note"* — because a leftover from an earlier run had the same title. A real
implementation must resolve the target unambiguously (by identifier, or by
erroring on multiple matches the way `apple messages` does) rather than
appending to every match.

### 🛑 The parameter names are not the intent's parameter names

The metadata for `Notes.AppendToNoteIntent` lists `entity`, `text`,
`interpretAsMarkdown`. **Two of those three are wrong in the serialized form:**

| Metadata says | Plist actually needs |
|---|---|
| action `com.apple.Notes.AppendToNoteLinkAction` | `is.workflow.actions.appendnote` |
| `entity` | `WFNote` |
| `text` | `WFInput` |

Worse, Shortcuts **silently normalises the wrong action identifier to the right
one on import** while keeping the wrong parameter names — so the action renders
correctly in the editor and only fails at run time, by popping a note picker.
Always copy the serialization from a working shortcut in `Shortcuts.sqlite`;
never derive it from the intent metadata.
