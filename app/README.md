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

## 🛑 Two entitlements decide whether this app can hold a grant at all

**`com.apple.security.personal-information.calendars` and `.addressbook`.**
They read as App Sandbox entitlements. They are not. On macOS 26+ a
**non-sandboxed, Developer ID signed, notarized** app cannot obtain Calendar or
Contacts without them, and it fails **silently**.

Measured here, changing nothing but those two lines in `project.yml`:

| | Without | With |
|---|---|---|
| calendar | `refused`, status stays `notDetermined` | **`granted`** |
| contacts | `CNErrorDomain 100: Access Denied` | **`granted`** |
| dialog shown | none, ever | none needed |

**The design doc ruled them out as sandbox-only, and the doc was wrong.** The
answer came from [`psychquant/che-ical-mcp`](https://github.com/psychquant/che-ical-mcp)
by way of `docs/prior-art.md`, which reports them as load-bearing and warns that
"ad-hoc signed binaries cannot trigger Calendar / Reminders TCC permission
dialogs".

**With them, the app holds all four grants and every tool works as its child:**

```
calendar  fullAccess    contacts  authorized    mail   readOnly
reminders fullAccess    messages  authorized    notes  authorized
maps      authorized    phone     authorized
app Full Disk Access: True      child Full Disk Access: True
```

That is the "one TCC identity" the design set out to get.

### ⚠️ What it cost to find, and the four bad checks along the way

Before the entitlements, no dialog ever appeared for Calendar or Contacts. Each
of these was measured and ruled out first:

| Suspect | Result |
|---|---|
| Not notarized | Notarized, stapled, `spctl` accepts. No change. |
| Stale `tccd` cache | Rebooted. No change. SIP refuses `launchctl kickstart -k gui/<uid>/com.apple.tccd`. |
| Stale bundle id | A fresh bundle id got the same answers. |
| Asking too early | A 5s delay after launch changed nothing. |
| Asking in the wrong order | Reordering the chain changed nothing. |
| A reused `EKEventStore` | A fresh store per request changed nothing. |
| Missing legacy Info.plist keys | Added every one beside the split keys. No change. |

Four of the wrong turns were bad checks rather than bad ideas:

1. 🛑 **`make install` rebuilds, and a rebuild re-signs and destroys the
   notarization ticket.** The app was notarized once and every `make install`
   after it quietly installed an unnotarized build, which invalidated a whole
   run of measurements. **`make release` notarizes, staples and then installs**;
   `make install` now warns when `stapler validate` fails.
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

### 🛑 The marker stops the disclaim, it does not start it

`reminders`, `apple-calendar` and `apple-contacts` re-execute themselves
**disclaimed**, which makes each one its own responsible process. That is right
from a terminal and wrong here: it throws away the app's grants, and a
disclaimed child also loses the app's **Full Disk Access** — costing `apple
contacts` its `has_photo` column and `apple calendar` its sync tables.
`Child.environment()` sets `APPLE_TOOLS_OWN_TCC_IDENTITY` so they skip it.

⚠️ **That is only correct because the app now holds the three grants.** While it
did not, running them as the app broke calendar and contacts outright, and
letting them disclaim was the working answer. If the entitlements ever stop
working, that is the fallback.

### One TCC dialog at a time, and it waits for a person

🛑 **A permission request does not return until the user answers**, and macOS
shows **one dialog at a time**. Asking for the next grant while a dialog is up
gets the next one **denied** — measured, `Access Denied` from Contacts with the
reminders dialog still on screen, and **TCC recorded that denial** as though the
user had made it. That record survived `tccutil reset` and a reboot.

⚠️ **A deadline on a prompt is a person's deadline.** A 20 second one was wrong
and caused the failure it was written to diagnose. It is ten minutes now.

🛑 **That deadline must be a plain timer.** Two versions raced the request
against `Task.sleep`, on the main actor and off it, and **the sleep never
fired** — the request occupies a cooperative thread without suspending.
`DispatchQueue.main.asyncAfter` does not care.

⚠️ The app switches its activation policy to `.regular` while asking, so a
prompt belongs to a process the user can see. That was **not** what fixed
anything here, and it is still correct — `che-ical-mcp` reached the same
conclusion for its `--setup` flow.

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

🛑 **`APPLE_TOOLS_OWN_TCC_IDENTITY` STOPS the disclaim, it does not start it.**
The name reads as the opposite of what it does here. See above for why setting
it is correct only while the app holds the three framework grants.

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
- The XPC proxy that would let a terminal borrow the app's grant.
- Encryption at rest, the container placement probe, per-source opt-in and
  revocation detection.
- `SMAppService.mainApp.register()` for launch at login.

## Releasing the app

```
make dmg     # build, notarize the app, build the DMG, notarize and staple it
```

⚠️ **Two notarizations, and both are needed.** The app inside is one artifact
and the DMG is another. Gatekeeper checks the one the user downloads.

🛑 **SIGN THE DMG ITSELF, before submitting it.** Notarizing and stapling an
UNSIGNED disk image succeeds at every step and then fails the only check that
matters: `spctl -a -t open` reports *"no usable signature"*. A staple is not a
signature. Measured — the first DMG came back `Accepted`, stapled cleanly, and
was still rejected.

⚠️ **A `notarytool` failure can be a keychain prompt you cannot see.** "No
Keychain password item found for profile" was reported here for a profile that
existed: macOS was waiting for the user to approve access to it, off screen.
The same class of mistake as the TCC dialog above. **Do not conclude a
credential is gone until a human has looked at the screen.**

Then attach the DMG to a GitHub release at `v<VERSION>` and update
`Casks/apple-tools-app.rb`.

**The app is self-contained**, 290 MB:

```
Contents/Helpers/          the 8 Mach-O CLIs and the `apple` dispatcher
Contents/Resources/notes/  apple-notes + its stdlib-only Python modules
Contents/Resources/index/  index.py, vec, models/, shortcuts/
```

`app/stage.sh` assembles it from the repo's own build outputs, and a build
phase copies it in and signs it. 🛑 **Nothing falls through to Homebrew any
more**, and `codesign --verify --deep --strict` passes.

🛑 **Only EXECUTABLES may live in `Contents/Helpers`.** `codesign` treats every
file there as CODE, so `notestore.proto` sitting beside `apple-notes` failed the
outer verify with *"code object is not signed at all — In subcomponent:
.../notestore.proto"*. The Notes payload moved under `Resources`, which is
sealed as resources instead, and the app puts that directory on `PATH` so the
dispatcher still finds `apple-notes`.

🛑 **Shell scripts in `Helpers` need signing too.** The `apple` dispatcher is a
script, and skipping it because it is not Mach-O produced the same failure.

🛑 **A post-build phase breaks the outer seal.** Xcode signs the app at the end
of the build, before the phase adds anything, so the script re-signs the wrapper
itself — **without `--deep`**, which would strip the hardened runtime from every
helper it had just given one.

🛑 **The cask neither depends on nor conflicts with the formula.** The design
doc calls for `conflicts_with`, and that is wrong here. The cask puts **no**
binary on `PATH` deliberately: a tool typed into a terminal is attributed to the
terminal, and the three disclaiming tools key their grant to the **binary
path** — so exposing the bundled copies would ask the user to grant Calendar,
Reminders and Contacts again, at a new path, while the formula's copies already
hold them.

🛑 **`brew zap` deletes the index AND its Keychain key.** Leaving an encrypted
image and a key behind after an uninstall is worse than deleting them.

⚠️ **The notarytool credential is a keychain profile named `MiniMusic`**, after
the first app it was stored for. Restore it with:

```
xcrun notarytool store-credentials "MiniMusic" \
  --key ~/.appstoreconnect/private_keys/AuthKey_G5JB79H867.p8 \
  --key-id G5JB79H867 --issuer <UUID from App Store Connect>
```

## Lending the app's grants to a terminal

**Off by default.** Turn it on in the window, or:

```
defaults write com.boulderhopkins.apple-tools toolProxy -bool true
```

A tool typed into a terminal is attributed to the **terminal**, so it needs that
terminal's own Full Disk Access. With this on, `bin/apple` hands the command to
the app, the app runs the real tool as its own child, and one grant covers every
terminal, IDE and agent. This is Route B in the design doc.

```
APPLE_TOOLS_PROXY=always apple maps places --limit 2   # force the proxy path
APPLE_TOOLS_PROXY=never  apple maps places --limit 2   # force the direct path
```

⚠️ **Direct first, always.** A terminal that can read the stores does the work
itself, with no socket and no dependency on the app running. The proxy is a
fallback: `bin/apple` probes `~/Library/Mail` and only asks the app when that
read fails.

### 🛑 What the code-signature check does and does not buy

The daemon reads the peer's **audit token** — never the pid, which is racy — and
requires a Mach-O signed by this developer under
`com.boulderhopkins.apple-tools.proxy`. Measured:

```
signed client     -> serves the command, exit 0
unsigned client   -> refused: the peer is not the signed AppleTools client
```

- ✅ A program cannot speak the protocol directly.
- ✅ The identity in the audit log is trustworthy, not self-reported.
- 🛑 **It is not a boundary.** Anything running as this user can simply execute
  the signed client and read its output. Within one user account macOS offers
  no boundary, and nothing available changes that. **The real control is the
  switch, and every proxied command is logged.**

⚠️ **A Python or shell client would make the check meaningless.** Its code
identity is `/usr/bin/python3` or `/bin/bash`, signed by Apple and shared by
every script on the machine. That is why the client is a separate signed target.

### 🛑 The app process cannot own a socket other processes reach

Measured, and it cost hours:

| socket | bound by | a shell connecting |
|---|---|---|
| `index.sock` | `vec daemon`, a **child** of the app | ✅ connects |
| `tools.sock` | the **app process** itself | ❌ `ECONNREFUSED` |

Same directory, same 0600 mode, same owner. The app could connect to its own
socket; nothing else could. So the proxy runs as a child, `apple-proxy --serve`,
exactly as the search endpoint already does.

⚠️ **The TCC identity is unaffected.** Responsibility runs down the whole
process tree, so a tool the daemon spawns is still attributed to the app.

⚠️ **`lsof` cannot see either socket** and reports zero for the working one too,
so it could not tell them apart. Two wrong conclusions came out of trusting it.

🛑 **An append-only log, never "open, seek, write" with an atomic-write
fallback.** Two threads that both find the file missing both write atomically,
and the second replaces the first. The line that vanished was the one proving
the accept loop had started, which sent this whole investigation the wrong way.
