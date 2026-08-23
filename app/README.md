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

## 🛑 One TCC dialog at a time, and it waits for a person

**The app asks for Calendar, Reminders and Contacts itself.** Full Disk Access
is the one macOS has no API for, so the window carries the reason and opens the
pane instead.

🛑 **A permission request does not return until the user answers the dialog**,
and macOS shows **one dialog at a time**. So the three requests are chained:
each starts only when the one before it finishes. Asking for the next while a
dialog is up gets the next one **denied** — measured, `Access Denied` from
Contacts with the reminders dialog still on screen, and **TCC recorded that
denial** as though the user had made it.

⚠️ **A deadline on a prompt is a person's deadline, not a machine's.** A 20
second one was wrong, and it caused the failure it was written to diagnose. It
is now ten minutes, and it exists only so a request nobody will ever answer
cannot hold the chain for the life of the process.

### 🛑 Unresolved: Calendar and Contacts hold a state nothing can clear

**Reminders works. Calendar and Contacts do not, and the state behind them is
not reachable from this machine.** Measured 2026-08-23 with the notarized,
stapled app that `spctl` accepts:

```
reminders   granted [status 0]                          -> granted
calendar    refused [status 0]                          -> notDetermined
contacts    CNErrorDomain 100: Access Denied [status 2]  -> denied
```

Three facts that cannot all be true of a healthy TCC:

1. **`tccutil reset AddressBook <bundle-id>` prints "Successfully reset" and
   changes nothing.** The next launch reads `status 2` again, one second later.
2. **System Settings → Privacy & Security → Contacts does not list the app at
   all**, so there is no switch for the user to turn on either.
3. **Reminders returned `granted` immediately after its own reset, with no
   dialog**, which is only possible if the reset did not take.

⚠️ **So the reminders grant is real and the other two are stuck**, not denied by
the user. The contacts denial was first recorded by this app's own 20s deadline
bug (see above), and it has outlived the fix.

🛑 **A BRAND NEW BUNDLE ID GETS THE SAME THREE ANSWERS.** A copy of the app,
re-signed under `com.boulderhopkins.apple-tools-idtest` and launched clean,
reported reminders **already granted**, contacts **denied** and calendar
refused — with no dialog for any of them. An identity TCC has never seen cannot
hold a decision, so the answers come from a cache that outlives both the bundle
id and `tccutil`.

⚠️ **That test is not airtight.** The copy was made from the signed bundle, and
LaunchServices may still have associated the path with the original bundle id.
Re-register with `lsregister -f` before repeating it.

**Two things are ruled out**, both measured rather than assumed:

- **Notarization.** The app is notarized, stapled, and accepted by `spctl`.
  Nothing changed.
- **Restarting `tccd`.** System Integrity Protection refuses it:
  `launchctl kickstart -k gui/<uid>/com.apple.tccd` returns *"Operation not
  permitted while System Integrity Protection is engaged"*. Killing the process
  is ignored.

**What is left, in order:**

1. **Reboot.** The only remaining way to restart `tccd`, and it clears the
   LaunchServices cache as well. Untried.
2. **Change the bundle id for real**, through `project.yml` rather than by
   editing a signed copy. 🛑 It costs the Full Disk Access grant, which the user
   must then give again by hand — the reason the id is called load-bearing at
   the top of this file.

### ⚠️ How this was misdiagnosed, and how to avoid repeating it

The dialog belongs to **`UserNotificationCenter`, which is a BACKGROUND
process**. A check of "visible processes" does not list it, so the prompt looked
absent when it was on screen the whole time. That produced a confident wrong
conclusion — *an unnotarized app cannot get a TCC prompt at all* — supported by
a 30-line reproduction and a control app, and it took a round trip through
Apple's notary service to disprove. **Notarizing changed nothing.** The dialog
had simply been waiting, unanswered, on the other side of the screen.

To see whether one is up:

```
osascript -e 'tell application "System Events" to tell process \
  "UserNotificationCenter" to get value of every static text of window 1'
```

⚠️ **`pgrep -x AppleTools` does not match this app either**, and reading that as
"the app died" wasted a second stretch of this work. Use `pgrep -f
MacOS/AppleTools`.

### Notarization, which is needed anyway

`make notarize` submits the built app, staples the ticket and checks `spctl`.
🛑 **`xcodebuild build` does not add a secure timestamp** — only `archive`
does — so a plain build is rejected with *"The signature does not include a
secure timestamp"*. `OTHER_CODE_SIGN_FLAGS: --timestamp` fixes it.

⚠️ The notarytool keychain profile is named `MiniMusic`, after the first app it
was stored for. It holds this developer's App Store Connect API key.

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

- A DMG and a cask. The app itself is notarized and stapled (`make notarize`),
  and `spctl` accepts it.
- The CLIs inside `Contents/Helpers/`, signed with the app.
- The XPC proxy that would let a terminal borrow the app's grant.
- Encryption at rest, the container placement probe, per-source opt-in and
  revocation detection.
- `SMAppService.mainApp.register()` for launch at login.
