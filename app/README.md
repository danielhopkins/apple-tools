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

⚠️ **calendar and contacts are a different question**, and Full Disk Access was
never the answer for them. See the next section.

So the app can index, and a launchd agent never could. That is the whole reason
the app exists.

⚠️ **A probe run from a terminal proves nothing**, because the terminal carries
its own Full Disk Access. This one ran inside the app.

⚠️ **The tools still do not share the grant with a TERMINAL.** `apple mail
search` typed into Ghostty is attributed to Ghostty, exactly as before. Only
children the app itself spawns inherit. Route B in the design doc — an XPC proxy
— is the only thing that changes that, and it is not built.

## 🛑 Let the disclaiming tools keep disclaiming

**The app holds Full Disk Access. It does NOT hold Calendar, Reminders or
Contacts, and it does not need to.** `apple-calendar`, `reminders` and
`apple-contacts` each re-execute themselves **disclaimed**, which makes each one
its own responsible process, so TCC keys the grant to the **binary**. Those
grants already exist and already work.

🛑 **The design doc said the opposite, and the doc was wrong.** It reasoned that
disclaiming inside the app "throws away the app's grants". It does — but only
the ones the app actually holds, and the app holds Full Disk Access, which
those three barely need.

⚠️ **The cost is real and small.** A disclaimed child loses the app's Full Disk
Access, so `apple contacts` cannot read `has_photo` out of the AddressBook store
and `apple calendar` cannot read the sync tables. The index uses neither. The
five tools that DO need Full Disk Access — mail, notes, messages, maps, phone —
never disclaim, so they keep the app's grant.

**With `APPLE_TOOLS_OWN_TCC_IDENTITY` set, so the three ran as the app:**

```
calendar   Error: calendar access was not granted
contacts   Error: contacts access was not granted: Access Denied
```

**Without it:** all six sources index, `errors: NONE`.

### ⚠️ The day this cost, and every wrong turn in it

The app could not obtain Calendar or Contacts for itself. **No dialog ever
appeared**, and each of these was measured and ruled out:

| Suspect | Result |
|---|---|
| Not notarized | Notarized, stapled, `spctl` accepts. No change. |
| Stale `tccd` cache | Rebooted. No change. SIP refuses `launchctl kickstart -k gui/<uid>/com.apple.tccd`. |
| Stale bundle id | A fresh bundle id got the same three answers. |
| Asking too early | A 5s delay after launch changed nothing. |
| Asking in the wrong order | Reordering the chain changed nothing. |
| A reused `EKEventStore` | A fresh store per request changed nothing. |
| Missing Info.plist keys | Added every legacy key beside the split ones. No change. |

Meanwhile `apple calendar calendars` and `apple contacts search` answered
perfectly from a terminal, **under their own identity** — which was the answer
the whole time.

Four wrong turns are worth naming, because each was a bad check rather than a
bad idea:

1. 🛑 **`make install` rebuilds, and a rebuild re-signs and destroys the
   notarization ticket.** The app was notarized once and every `make install`
   after it quietly installed an unnotarized build, which invalidated a whole
   run of measurements. **`make release` is the target that notarizes, staples
   and then installs**, and `make install` now warns when the installed bundle
   fails `stapler validate`.
2. ⚠️ **A TCC dialog belongs to `UserNotificationCenter`, a BACKGROUND
   process.** A check of "visible processes" does not list it, so a prompt that
   was on screen looked absent. To see one:

   ```
   osascript -e 'tell application "System Events" to tell process \
     "UserNotificationCenter" to get value of every static text of window 1'
   ```
3. ⚠️ **`pgrep -x AppleTools` does not match this app.** Reading that as "the
   app died" wasted another stretch. Use `pgrep -f MacOS/AppleTools`.
4. 🛑 **`tccutil reset <service> <bundle-id>` prints "Successfully reset" and
   may change nothing.** Its output is not evidence.

### One TCC dialog at a time, and it waits for a person

The window keeps an **Ask Again** button, and it is the only thing that asks now.

🛑 **A permission request does not return until the user answers**, and macOS
shows **one dialog at a time**. Asking for the next grant while a dialog is up
gets the next one **denied** — measured, `Access Denied` from Contacts with the
reminders dialog still on screen, and **TCC recorded that denial** as though the
user had made it. That record survived `tccutil reset` and a reboot.

⚠️ **A deadline on a prompt is a person's deadline.** A 20 second one was wrong
and caused the failure it was written to diagnose. It is ten minutes now, and it
exists only so a request nobody will answer cannot hold the chain forever.

🛑 **That deadline must be a plain timer.** Two versions raced the request
against `Task.sleep`, on the main actor and off it, and **the sleep never
fired** — the request occupies a cooperative thread without suspending.
`DispatchQueue.main.asyncAfter` does not care.

### Notarization

`make notarize` submits, staples and checks `spctl`. 🛑 **`xcodebuild build`
does not add a secure timestamp** — only `archive` does — so a plain build is
rejected with *"The signature does not include a secure timestamp"*.
`OTHER_CODE_SIGN_FLAGS: --timestamp` fixes it.

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

🛑 **Do NOT set `APPLE_TOOLS_OWN_TCC_IDENTITY` on a child.** It STOPS the
disclaim rather than starting it, which reads as the opposite of what it does.
Setting it made `apple-calendar` and `apple-contacts` run as the app, and the
app has no Calendar or Contacts grant. See above.

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
