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

## Status

⚠️ **Unverified.** The plist is hand-built from a schema reverse-engineered out
of other shortcuts; `shortcuts sign` accepts it, but that only proves it parses.
Whether Shortcuts accepts the action, whether the parameters bind, and whether
`shortcuts run` executes without prompting are all untested until it is
installed once.

`build-shortcut.py` currently emits the **Create Note** variant, deliberately:
it needs no note-entity resolution, so it is the smallest thing that proves the
whole pipeline. The **Append** variant needs the target note resolved at
runtime — a lookup step ahead of `AppendToNoteIntent` — and is worth building
only once the simple case is confirmed to work.
