# Notes Shortcuts — build scripts

**The findings live in [`../../docs/apple-notes-shortcuts.md`](../../docs/apple-notes-shortcuts.md)** — the file format, the five traps, the permission model and how to debug. This file is just how to build and install.



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
python3 build-shortcut.py out.shortcut [create|append|generic-append]
shortcuts sign --mode anyone --input out.shortcut --output out.signed.shortcut
open out.signed.shortcut          # one-time install, needs a human
```

Three variants:

| Variant | What it does |
|---|---|
| `create` | note from Markdown on stdin-path |
| `append` | appends to a **fixed** note — the minimal proof |
| `generic-append` | appends to **any** note, named at call time |

## Using the generic append

Input is JSON — but it **must be written to a `.txt` file**, because
`--input-path` types the input by extension and `.json` is dropped silently:

```bash
printf '{"note":"My Note","text":"line\n\n- [ ] a task"}' > payload.txt
shortcuts run "ClaudeNotesAppendAny.signed" --input-path payload.txt
```

Verified: appends to the named note only, leaves other notes untouched,
preserves attachments and existing checklists, interprets Markdown, 0.43s.
