# Reminders tags: where they actually live

Reminders tags — the `#PTA` chips you get by typing `#PTA` into a reminder —
have **no public API of any kind**. Not EventKit, not AppleScript, not
Shortcuts' modern App Intents surface. This is the record of what was ruled out,
what works, and what it costs.

Everything below was measured on macOS 27.0 (build 26A5406e), SDK 27.0, against
a real store.

## What does not work

### EventKit has no tag surface

Not an oversight in the search. The public headers contain **zero** tag
references — the only hit in the whole framework's headers is a comment about
tagged pointers in `EventKitDefines.h`. A runtime dump of `EKReminder`,
`EKCalendarItem`, `EKEvent`, `EKCalendar` and `EKSource` finds only:

```
-[EKCalendarItem externalModificationTag] / setExternalModificationTag:
-[EKCalendar    externalIDTag] / externalModificationTag
-[EKSource      externalModificationTag]
```

Those are **HTTP ETags for sync**, unrelated to user-facing tags. There is
nothing to set.

🛑 **A `#PTA` written into an EventKit title stays literal text.** It does not
become a tag, because a tag is a separate record (see below) and nothing about
assigning `title` creates one.

### AppleScript has no tag surface

Reminders.app's scripting definition declares three classes — `account`, `list`,
`reminder` — and twelve reminder properties:

```
name  id  creation date  modification date  body  completed  completion date
due date  allday due date  remind me date  priority  flagged
```

The string `tag` appears in the entire sdef **zero times**.

### App Intents describes tags but the actions do not resolve

This one is a trap worth naming, because the metadata is convincing.
`/System/Library/PrivateFrameworks/RemindersAppIntents.framework` really does
ship an `AddOrRemoveTagsAppIntent`:

```
title:       "Add or Remove Tags"
description: "Add tags to or remove tags from reminders."
operation:   enum { add, remove }
reminders:   [ReminderEntity]
tags:        [String]
visibility:  isDiscoverable: true, assistantOnly: false
availability: LNPlatformNameWildcard, no required capabilities
```

`TTRCreateReminderAppIntent` likewise takes a `tags: [String]` parameter
alongside `list`, `dueDate`, `priorityLevel` and the rest, with
`openAppWhenRun: false`.

🛑 **Building a shortcut around either fails.** Shortcuts rejects the import with
**"not supported on this device"**, because the action identifiers do not
resolve. `<bundle>.<intentIdentifier>` — the convention that works for Notes —
is not what Shortcuts is looking for here, and neither `com.apple.reminders` nor
the framework's own `com.apple.RemindersAppIntents` produces a usable action.

⚠️ **`WFActionRegistry` cannot be asked from a CLI.** The obvious way to get the
real identifier is `+[WFActionRegistry sharedRegistry]` then
`-actionsForAppWithIdentifier:`, but the registry is lazy and
`fillActionProviders:` **crashes (SIGTRAP)** in an unsigned process.
`actionsForAppWithIdentifier:@"com.apple.reminders"` returns 0 before the fill.

## What works: Shortcuts' legacy content-item setter

Read out of a shortcut built by hand in the Shortcuts UI — which is the only
reliable way to learn these serializations, and is what
`notes/shortcuts/build-shortcut.py` already says:

```
WFWorkflowActionIdentifier: is.workflow.actions.setters.reminders
WFWorkflowActionParameters:
    WFInput:                   <the reminder(s)>
    WFContentItemPropertyName: "Tags"
    Mode:                      "Set"
    WFReminderContentItemTags: "chicken"
```

No `AppIntentDescriptor` at all. `Tags` is a first-class settable content-item
property. Paired with `is.workflow.actions.filter.reminders` (Property `Name`,
Operator 99 — the same predicate shape as the proven `filter.notes`) it
resolves, imports and runs.

**Verified end to end.** Baseline 0 tags across all four stores; after one run a
`ClaudeTagProof` label and a matching hashtag record bound to the target
reminder, in 5.3s.

Two reasons this is *not* what the tool ships:

- ⚠️ **It can only find a reminder by title.** The filter matches on `Name`, so
  two reminders sharing a title are indistinguishable — it tags the wrong one,
  or both.
- ⚠️ **It needs a one-time shortcut install**, which needs a human to click
  "Add Shortcut". Same cost as the Notes write path, but here there is a better
  option.

It remains the documented fallback if the private API below ever stops working.

## What the tool ships: private ReminderKit

`/System/Library/PrivateFrameworks/ReminderKit.framework` is what Reminders.app
itself uses, and it is reachable from an **unsigned** binary with no entitlement
and no extra grant — the Reminders TCC grant `apple reminders` already holds is
enough. Verified: `REMStore` instantiates, reads and saves.

```objc
store   = [[REMStore alloc] init];
reminder = [store fetchReminderWithDACalendarItemUniqueIdentifier:extId inList:nil error:&e];
sr      = [[REMSaveRequest alloc] initWithStore:store];
ci      = [sr updateReminder:reminder];          // REMReminderChangeItem
ctx     = [ci hashtagContext];                   // REMReminderHashtagContextChangeItem
[ctx addHashtagWithType:0 name:@"PTA"];          // also removeHashtag:, removeAllHashtags
[sr saveSynchronouslyWithError:&e];
```

🛑 **`fetchReminderWithExternalIdentifier:` is the wrong selector.** It is a
different identifier space and returns `-3000 "No such object"` for the
identifier EventKit gives you. The right one is
`fetchReminderWithDACalendarItemUniqueIdentifier:` — "DA" for DataAccess — and
it takes exactly the value EventKit reports as
`calendarItemExternalIdentifier`. That join is what makes this route
unambiguous where the Shortcuts one is not.

Implementation is in `swift/Sources/ReminderKitBridge/`. Every class and
selector is resolved at runtime and checked in one place, so a future macOS that
moves them produces a clean "tags are not available on this system" refusal
rather than a crash — and reading reminders keeps working.

## The store

Reminders are **not** in `~/Library/Calendars/Calendar.sqlitedb` (that file does
not exist on macOS 27). They are in a per-account Core Data store:

```
~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite
```

⚠️ **Entity IDs are per-store.** `Z_PRIMARYKEY` differs between the files; read
the entity map from the store you are querying, not from a sibling.

⚠️ **Reminders are in their own table, not the shared one.** `ZREMCDREMINDER`
holds them; `ZREMCDOBJECT` is the single-table-inheritance table that holds
hashtags, alarms and much else. A query for reminders in `ZREMCDOBJECT` returns
zero rows and looks like an empty store.

A tag is two records:

| Table | Role |
|---|---|
| `ZREMCDHASHTAGLABEL` | the label — `ZNAME` (display), `ZCANONICALNAME` (lowercased), recency for autocomplete |
| `ZREMCDOBJECT` where `Z_ENT` = `REMCDHashtag` | the occurrence — `ZNAME1`, `ZHASHTAGLABEL` → label, `ZREMINDERIDENTIFIER1` → reminder |

`ZREMINDERIDENTIFIER1` is a raw 16-byte UUID, and it equals the reminder's
`ZDACALENDARITEMUNIQUEIDENTIFIER`, which equals EventKit's
`calendarItemExternalIdentifier`. That is the whole join.

`ZCKSERVERRECORDDATA` on the hashtag carries a CloudKit record of type
`Hashtag` in the `Reminders` zone — **tags sync**, like the reminder itself.

⚠️ **A deleted tag lingers as a tombstone.** `ZMARKEDFORDELETION = 1` with the
row still present is normal and clears on the next CloudKit sync; it is not a
failed delete.

## Reading tags in bulk

🛑 **Fetch reminders with the plural selector, not in a loop.** The cost of a tag
read is the round trip to `remindd`, not the tag decode — so a loop of
`fetchReminderWithDACalendarItemUniqueIdentifier:` pays it once per reminder,
and that is what made a 1,191-reminder listing take **4.3s** in 26.813.0.

```objc
// returns NSDictionary: identifier → REMReminder
[store fetchRemindersWithDACalendarItemUniqueIdentifiers:ids inList:nil error:&e];
```

Measured on the same 1,191 reminders: the batched fetch is **0.20s**, and
walking `hashtagContext` on the already-fetched objects afterwards is **under a
millisecond** — it is in-process, with no further XPC. End to end the listing
went **4.3s → 0.48s**.

⚠️ **It returns a dictionary, not an array.** Iterating it directly yields the
identifier *strings*, so a loop written for an array of reminders throws
`unrecognized selector sent to __NSCFString`.

⚠️ **Identifiers that resolve to nothing are simply absent from the dictionary**,
which is the wanted behaviour — a listing should not fail because one reminder
was deleted mid-run.

### Why not read the SQLite store directly

Because `apple reminders` **cannot**. It re-executes itself *disclaimed* to own
its TCC identity, and disclaiming makes the process its own responsible process —
which is exactly what Full Disk Access is attributed to. So it holds the
Reminders grant and has no FDA, and the store under
`~/Library/Group Containers/group.com.apple.reminders/` is unreadable to it. The
same constraint, in mirror image, is why `apple phone` may *not* disclaim.

This is only a constraint on the tool. Reading the store by hand, as in the
tables above, is fine from a terminal that has FDA.

⚠️ **A `mode=ro` SQLite open does not replay the write-ahead log.** The reminders
store keeps a multi-megabyte `-wal`, so a read-only URI open can return a stale
snapshot — the same trap `apple contacts` hit with `immutable=1`. Open the file
plainly, and cross-check anything surprising before believing it.

## Traps

🛑 **A tag containing a space is silently rewritten, not refused.** Measured:
adding `two words` stored a tag named **`twowords`**, canonical `twowords`, and
the save reported success.
`REMReminderHashtagContextChangeItem` even has
`nameWithDisallowedCharactersReplaced:` for the purpose. `apple reminders`
refuses these up front and names the substitute, rather than storing something
the user did not type.

🛑 **A tag is invisible to EventKit, and the title does not change.** Measured:
after tagging, the reminder's title came back byte-identical, with no `#PTA`
appended. So:

- nothing in the EventKit half of this tool can see a tag — they are read
  through `ReminderKitBridge` and cached per listing;
- a title prefix like `PTA: ` and a real tag are **not** interchangeable, and
  nothing converts one into the other.

⚠️ **This corrects a plausible-looking inference.** `ReminderKit` has
`REMMutableCRMergeableStringDocument addHashtag:range:` / `removeHashtagInRange:`,
which suggests tags live as annotated ranges inside the title text. That is how
the *app* handles inline typing; it is **not** how a programmatically set tag is
stored. Trust the measurement.

⚠️ **`removeAllHashtags` churns tags that are not changing.** Using it to
implement a whole-set replace destroys and recreates the tags that are staying —
tombstoning a CloudKit record and resetting the tag's creation date for a tag
that never moved. Measured: `--tag PTA` on a reminder already tagged `PTA` left
a deleted `PTA` row behind and created a new one. The bridge therefore removes
only the tags actually leaving; verified afterwards that an unchanged tag keeps
its original row.

⚠️ **Matching is case-insensitive; display case is preserved.** Reminders keys
tags on the lowercased `canonicalName`, so `pta` and `PTA` are one tag. Adding
`pta` to a reminder already tagged `PTA` is a no-op that keeps `PTA`.

🛑 **A save reporting success is not evidence anything persisted.** Consistent
with `apple calendar` and `apple contacts` in this repo,
`saveSynchronouslyWithError:` returning `YES` is not trusted: every write
re-reads from a **fresh** store and fails, naming the tags that did not land,
rather than echoing the request back as the result.

⚠️ **A newly created reminder is not instantly visible to ReminderKit.**
EventKit and ReminderKit are two views of the same daemon and do not commit in
lockstep, so `add --tag` retries the *lookup* — only the lookup — for up to 2s
before giving up.

⚠️ **Tagging is a second write, through a different framework.** On `add` the
reminder already exists by the time tagging can fail, so the failure message
says so explicitly: the reminder was created and is untagged. Do not read
"tagging failed" as "nothing happened".
