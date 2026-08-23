# The app that owns the grants, the index and the schedule

**Status: phases 1 and 2 of [`docs/todo-index-app.md`](../docs/todo-index-app.md)
are built.** It indexes on a schedule and it owns the search endpoint. It is not
notarized, it does not carry the CLIs inside itself, and the index is not
encrypted. Those are phases 4 to 6.

```
cd app
make build      # release build, signed with Developer ID
make install    # replace /Applications/AppleTools.app and launch it
make grant      # open the Full Disk Access pane — you toggle it by hand
make logs       # the search endpoint's log, and the app's
make stop       # quit it properly
```

## 🛑 Step 0 is answered, and the answer is yes

The whole design rested on one claim nobody had measured:

> A child process spawned by the app inherits the app's TCC identity, so one
> Full Disk Access grant on the app covers `apple-mail`, `apple-notes`,
> `apple-messages`, `apple-phone` and `apple-maps` when the app runs them.

**Measured on 2026-08-23, in a matched pair, on macOS 27.0 (26A5416b).** The app
ran one indexing cycle before the grant and one after it. Nothing else changed.

| Source | Before the grant | After |
|---|---|---|
| notes | `sqlite3.OperationalError: unable to open database file` | ✅ |
| mail | refused to fall back to AppleScript | ✅ |
| messages | `Cannot read chat.db … needs Full Disk Access` | ✅ |
| maps | `Cannot read MapsSync_0.0.1 … needs Full Disk Access` | ✅ |
| calendar | `calendar access was not granted` | ✅ once Calendar was granted |
| contacts | `contacts access was not granted: Access Denied` | ✅ once Contacts was granted |

So the app can index, and a launchd agent never could. That is the whole reason
the app exists.

⚠️ **A probe run from a terminal proves nothing**, because the terminal carries
its own Full Disk Access. This one ran inside the app.

⚠️ **The tools still do not share the grant with a TERMINAL.** `apple mail
search` typed into Ghostty is attributed to Ghostty, exactly as before. Only
children the app itself spawns inherit. Route B in the design doc — an XPC proxy
— is the only thing that changes that, and it is not built.

## 🛑 An unnotarized app cannot get a TCC prompt, and TCC fails closed

**Full Disk Access works, because the user grants it by hand. The three grants
that need a PROMPT do not.** Measured on macOS 27.0 (26A5416b), with the app
signed `Developer ID Application`, hardened runtime, **not notarized**:

| Grant | What the request returned | State afterwards |
|---|---|---|
| calendar | `false`, no error, in under a second | still `notDetermined` |
| reminders | **never returned at all** | still `notDetermined` |
| contacts | `CNErrorDomain 100 "Access Denied"` | **`denied`** |

⚠️ **No dialog appeared for any of them**, and the app was frontmost with a Dock
tile at the time. TCC recorded a **denial the user never made** for contacts.

**It is not this app's structure.** A 30-line app — regular activation policy,
its own bundle id, the same Developer ID identity — reproduced it exactly. An
ad-hoc signed copy was worse: neither request returned. Nothing is stale either;
`tccutil reset Calendar/Reminders/AddressBook` and a relaunch changed nothing.
There is no MDM and no configuration profile on this machine.

**The remaining difference is notarization**, which every one of these builds
lacks and which `spctl` rejects them for. That is the next thing to test, and it
is on the roadmap anyway.

⚠️ **The app spun forever waiting.** `requestFullAccessToReminders` never called
back, and the process logged `TCCAccessRequest() IPC` **every two seconds for as
long as it ran**, while the two grants queued behind it were never asked for.

🛑 **A deadline for it must be a plain timer.** Two versions raced the request
against `Task.sleep`, on the main actor and off it, and **the sleep never
fired** — the request occupies a cooperative thread without suspending, so the
timer beside it was never scheduled. `DispatchQueue.main.asyncAfter` does not
care. ⚠️ Losing the race cancels nothing: there is no cancel API, so the retry
runs inside EventKit until the process exits.

## What it does

**It indexes.** `NSBackgroundActivityScheduler` every 5 minutes with 60 seconds
of tolerance, plus on wake and on unlock, plus once at launch. It runs
`index.py ingest` per source and then `index.py embed`, as children, so they
inherit the grant. A full deletion sweep runs weekly, not every cycle.

**It owns the search endpoint.** It runs `vec daemon` as a child on the same
Unix socket, so `apple-index search` and the skill work unchanged.

🛑 **It boots the launchd agent out first, and disables it.** They bind the same
socket path, the second one wins the file, and the first keeps a socket nobody
reaches. Two daemons raced this socket twice during development and one search
took 10.7 seconds.

⚠️ **Bootout alone is not enough.** The plist stays in `~/Library/LaunchAgents`
with `RunAtLoad`, so the agent returns at the next login and the two race in
whatever order they start. `launchctl disable` is recorded in launchd's override
database and survives a reboot. **`make uninstall` re-enables it** — without
that, removing the app would leave the machine with no search endpoint at all.

**It shows status**: per source records, chunks, last read and last error; the
embed backlog with a rate; permission state per store; the index size; and the
model, with a warning when rows exist under more than one model name.

## Things that are easy to get wrong here

🛑 **Sign with Developer ID even for a local build.** An ad-hoc signature keys
the TCC grant to the cdhash, so every rebuild would drop Full Disk Access and
the user would approve it again by hand. A stable Developer ID signature
survives `make install`.

🛑 **The bundle id is load-bearing.** TCC keys the grant to
`com.boulderhopkins.apple-tools` and the signing identity. Renaming the id makes
the user grant Full Disk Access again. The **display name** is free to change,
which matters because nothing public may be called "Apple ..." — see the design
doc.

🛑 **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`.** Otherwise Xcode adds
`get-task-allow`, which lets any process running as this user attach a debugger
to an app holding Full Disk Access. Notarization rejects it as well.

🛑 **`APPLE_TOOLS_OWN_TCC_IDENTITY` stops the disclaim, it does not start it.**
`reminders`, `apple-calendar` and `apple-contacts` re-execute themselves
disclaimed so a terminal's grant is not what TCC keys on. Inside the app that is
exactly wrong: disclaiming makes each tool its own responsible process, throwing
away the app's grants. `Child.environment()` sets the marker so they skip it.

⚠️ **Report the whole of a failure, not its last line.** An argument parser ends
its usage message with `See 'apple-calendar --help'`, which names nothing. A
first version reported exactly that for two sources and hid a permission error
behind a help pointer. `Indexer.summarise` keeps the last three meaningful
lines, and the full text goes to `logs/ingest-<source>.log`.

🛑 **`rangeAtIndex:` past the last capture group RAISES**, and an Objective-C
exception terminates the process rather than returning nil. Asking for group 6
of a five-group pattern killed the app **the first time a source succeeded**, and
only then — so it survived every run where everything failed.

## Development

The app finds `index.py`, `vec` and the Core ML packages in this order: inside
its own bundle, then a Homebrew install, then whatever `toolsRoot` names.

```
defaults write com.boulderhopkins.apple-tools toolsRoot ~/src/apple-tools/lab
```

⚠️ **A Homebrew `index.py` older than 26.823.2 has no `sources` command**, so the
app falls back to a fixed source list with no per-source arguments — which means
mail **without** bodies. The window says the list is a guess.

## What is not built

- Notarization, a DMG and a cask. `spctl` rejects the bundle today: signed with
  Developer ID, not notarized.
- The CLIs inside `Contents/Helpers/`, signed with the app.
- The XPC proxy that would let a terminal borrow the app's grant.
- Encryption at rest, the container placement probe, per-source opt-in and
  revocation detection.
- `SMAppService.mainApp.register()` for launch at login.
