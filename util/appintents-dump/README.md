# appintents-dump

A **development-only** reader for an app's App Intents action schema. Not built,
installed, or shipped by the `apple` CLI — it exists to make writing Notes (and
other) shortcut payloads less of a guessing game.

## What it's for

When building a `.shortcut` by hand (see
[`../../docs/apple-notes-shortcuts.md`](../../docs/apple-notes-shortcuts.md)) the
expensive trap is that the intent's *conceptual* parameter names and its
*serialized* plist names differ, with no rule connecting them — `Create Note`
reads as `contents` conceptually but the plist wants `WFCreateNoteInput`.

This tool prints the **conceptual** side straight from the source of truth:
each action's real identifier, Swift type, output type, and every parameter's
real name, type, and optionality. Pair it with reading a working shortcut out of
`~/Library/Shortcuts/Shortcuts.sqlite` (the serialized side) and the mapping
between the two stops being guesswork.

It reads the same `Metadata.appintents` bundle Shortcuts does, but shows more
than the `extract.actionsdata` Python one-liner in the docs: real parameter
names, types, enum identifiers, and which parameters are optional.

## How it works — and why it only reads

It `dlopen`s the private **LinkMetadata** framework and calls
`-[LNBundleMetadata initWithBundle:usingEffectiveBundleIdentifier:error:]`. That
path is pure parse: no XPC to the target app, no TCC prompt, **no entitlement,
no permission of any kind.**

Executing an action is deliberately out of scope. The client-side executor
chain exists and is reachable — `LNBundleMetadata` → `LNAction` →
`LNApplicationConnection` → `LNActionExecutor` — but `-[LNActionExecutor perform]`
opens an XPC connection to the app that fails with:

```
LNConnectionErrorDomain Code=2700 "LNConnectionErrorCodeMissingConnectionEntitlement"
```

The gate is the restricted entitlement **`com.apple.private.appintents.connection`**
(it sits alongside `com.apple.linkd.registry` on Shortcuts'
`BackgroundShortcutRunner.xpc`). AMFI **SIGKILLs at launch** any binary that
carries a restricted entitlement without being Apple-signed or provisioned —
verified: self-signing with it gives exit 137, versus exit 0 for a harmless
entitlement. No third-party certificate can hold it. So `shortcuts run` remains
the only way to *execute* an intent; this tool only *reads* the schema. That's
why the write path in `notes/shortcuts/` still goes through Shortcuts.

## Build & use

```
make                                   # clang, ~1s; needs Xcode CLT
./appintents-dump                      # all of Notes' 51 actions (default)
./appintents-dump --action AppendToNote   # one action (substring match)
./appintents-dump --json               # machine-readable
./appintents-dump com.apple.reminders  # any app: bundle id ...
./appintents-dump /System/Applications/Notes.app   # ... or a path
```

Example:

```
$ ./appintents-dump --action AppendToNoteLinkAction
AppendToNoteLinkAction
  type:    Notes.AppendToNoteIntent  (5Notes18AppendToNoteIntentV)
  title:   Append to Note
  opens app: no
  output:  Entity<NoteEntity>
  parameters:
    operation              Enum<AppendOperation> (required)
    entity                 Entity<NoteEntity>   (required, dynamic)
    text                   AttributedString     (required)
    section                String               (optional)
    ignoreWhitespace       Bool                 (required)
    interpretAsMarkdown    Bool                 (required)
```

## Caveats

- **Private frameworks, undocumented, unversioned.** Class and property names
  can change between macOS releases; if a property accessor goes missing the
  tool will throw an unrecognized-selector exception rather than misreport.
  It is pinned to nothing and makes no stability promise — it's a workbench tool.
- The parameter names shown are the intent's own (what the app's Swift declares).
  The `.shortcut` plist may serialize some of them under different keys; confirm
  against a working shortcut before trusting a name on the wire.
- Verified on macOS 27.0. Requires the Xcode Command Line Tools for `clang`.
