# reminders — `apple reminders`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple reminders`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

Swift + EventKit. Full CRUD. Fork of `keith/reminders-cli` with editing and
recurrence added.

```
apple reminders show-lists [--json]
apple reminders show LIST [--due-date DATE] [--include-overdue]
                          [--include-completed | --only-completed] [--tag TAG]...
                          [--sort none|creation-date|due-date] [--json]
apple reminders show-all [--due-date DATE] [--include-overdue]
                         [--include-completed | --only-completed] [--tag TAG]... [--json]
apple reminders add LIST "TEXT" [--due-date DATE] [--priority high|medium|low|none]
                                [--notes TEXT] [--repeat daily|weekly|monthly|yearly]
                                [--repeat-interval N] [--repeat-until DATE] [--repeat-count N]
                                [--tag TAG]... [--at PLACE] [--on arrive|leave] [--radius M]
apple reminders edit LIST INDEX ["NEW TEXT"] [--due-date DATE] [--priority P] [--notes TEXT]
                                [--tag TAG]... [--add-tag TAG]... [--remove-tag TAG]...
                                [--at PLACE] [--clear-location]
apple reminders complete LIST INDEX
apple reminders uncomplete LIST INDEX
apple reminders delete LIST INDEX
apple reminders new-list NAME
```

`--due-date` takes natural language: `today`, `tomorrow 9am`, `next friday`,
`2026-12-25`. `--format json` still works as a synonym for `--json`.

⚠️ `INDEX` is the position shown by `show`, and it **shifts** as items complete or
get added. Always `show` immediately before `complete`/`edit`/`delete`.

**Location reminders — "remind me when I get there" — go on `add` and `edit`.**

```
apple reminders add Errands "Buy milk" --at "Costco, Superior CO"
apple reminders add Errands "Call back" --at "39.96,-105.17" --on leave --radius 250
apple reminders edit Errands 3 --clear-location
```

`--at` takes a place name, an address, a `"lat,lon"` pair, or the `"Name@lat,lon"`
form that `apple maps geocode --json` emits as `at`. `--on` is `arrive` (default) or
`leave`. `--radius` is metres, default 100. `--near` biases the Maps search.

- 🛑 **A name or address means a network call**, the only one `reminders` makes. A
  `"lat,lon"` pair touches nothing.
- 🛑 **`reminders` cannot read the Maps store, so it cannot resolve a place from the
  user's own history.** It re-executes itself disclaimed so the Reminders grant
  follows the binary, and **a disclaimed process loses the terminal's Full Disk
  Access**. To pin a reminder to the branch the user actually goes to, compose the
  two tools:

  ```
  AT=$(apple maps geocode costco --json | jq -r '.[0].at')
  apple reminders add Errands "Buy milk" --at "$AT"
  ```

  That resolves locally, with no network call, and carries the name through.
- ⚠️ **A structured location with no coordinate triggers nothing**, while still
  showing a name in Reminders.app. So a failed lookup refuses rather than saving a
  location that looks right and never fires. Ambiguity is refused too: a shop name
  matching branches more than 250 m apart is an error listing them.
- **The location alarm sits alongside a time alarm** rather than replacing it, so
  "at 9am, or when I get there" is one reminder. `--clear-location` removes only the
  location alarms.
- ⚠️ **`show --json` reports `locationTitle` and `location`.** `location` is the
  coordinate pair as a string, not an address.

**Tags — the `#PTA` chips — have no public API, and this is the one place the tool
reaches past EventKit.** Not EventKit (every "tag" symbol there is a sync ETag), not
AppleScript (the string appears in Reminders' sdef zero times). Writes go through
private `ReminderKit`, resolved at runtime, needing no grant beyond the Reminders
one. Full record in
[`docs/apple-reminders-tags.md`](apple-reminders-tags.md).

- `--tag` on **`add`** sets the tags; on **`edit`** it **replaces** the whole set,
  matching how multi-value flags behave in `apple contacts`. `--add-tag` /
  `--remove-tag` change them one at a time, and combining the two styles is refused.
- **`--tag` on `show`/`show-all` filters instead.** Repeating it is an **AND**, and
  matching is case-insensitive.
- ⚠️ **The index survives filtering.** What `show --tag PTA` prints is each
  reminder's position in the whole list, not 1..n of the filtered view, so it stays
  valid for `edit`/`complete`/`delete`.
- **There is no `search` subcommand**, and `--tag` is the only content filter. To
  match on title text, pipe `--json` through `jq`.
- 🛑 **A tag is invisible to EventKit and does not touch the title.** A tagged
  reminder's title comes back byte-identical, with no `#PTA` in it. So a `PTA: `
  title prefix and a real tag are **not** interchangeable, and nothing converts one
  to the other. `show`/`show-all` report them as `tags` in JSON (absent when there
  are none) and as `#tag` in plain output.
- 🛑 **A tag containing a space is silently rewritten, not rejected.** `two words`
  stores as `twowords`, and the save reports success. Refused up front, naming the
  substitute. A leading `#` is refused too — it is punctuation the app adds when
  rendering, so storing it yields `##PTA`.
- ⚠️ **Matching is case-insensitive, display case is kept.** Adding `pta` to
  something already tagged `PTA` is a reported no-op.
- ⚠️ **Tagging is a second write through a different framework.** On `add` the
  reminder exists before tagging can fail, so read "tagging failed" as "created but
  untagged", not as "nothing happened". Every tag write is read back from a fresh
  store and fails naming what did not land.
- ⚠️ If macOS ever moves the private API, tags degrade to unavailable — `--tag`
  refuses with an explanation and everything else keeps working.
