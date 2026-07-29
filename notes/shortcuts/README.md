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

## Next: the append

`AppendToNoteIntent` is the real prize — a genuine append that should sidestep
both the attachment destruction and the checklist flattening of `set body`. It
needs the target note resolved to an entity at runtime, which means a
`is.workflow.actions.filter.notes` lookup ahead of it. Both halves now have
working examples to copy from in `Shortcuts.sqlite`: that filter action, and
`DeleteNotesLinkAction` showing how a filter's output is passed into an intent
as a `WFTextTokenAttachment` carrying the upstream `OutputUUID`.
