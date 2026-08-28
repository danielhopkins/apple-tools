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

## The window: a rail, and one pane at a time

🛑 **PANELS BECAME A RAIL IN 26.828, AND THE REASON IS NOT DECORATION.** The
window was seven stacked boxes in one scroll view — permissions, sources,
growth, storage, advanced, people, places — and every one of them was on screen
whether or not it was the thing being asked about. Two costs came out of that:

1. Expanding one source row pushed the four sections below it off the bottom,
   which reads as the rest of the window disappearing.
2. The map and the contact web are the two most expensive things here, and they
   were built on a window opened to check whether mail indexed.

A rail fixes both by construction. One pane is on screen, so nothing below it
can be displaced, and a pane nobody selects is never built.

⚠️ **ONE QUESTION PER PANE**, in the order a person asks them: **Sources** (can
it read my data, and what did it read), **Index size** (how is it growing, what
does it cost, what can I delete), **Advanced** (the search endpoint and the
proxy switch) — then, under a divider, **Your relationships**, **Your places**
and **Your emoji**.

🛑 **THE SECOND GROUP IS NOT A DIAGNOSTIC, AND THE DIVIDER SAYS SO.** Nothing in
the first group depends on it, each costs seconds of subprocess to build, and
each is fetched only when its pane is opened.

- **`@AppStorage`, not `@SceneStorage`.** This is an LSUIElement app whose one
  window is closed far more often than the app is quit, and re-opening it onto
  Sources every time is what makes a rail feel worse than a scroll view. Scene
  storage rides the window's restoration state, which macOS drops whenever the
  app is replaced; a defaults key survives an upgrade.
- **`PaneSection` is a heading and a hairline, not a box.** Seven tinted
  rounded rectangles on one window made every section look like a callout,
  which is how a window teaches people to skip the one section that really is a
  callout.
- ⚠️ **The header sits above every pane.** What is happening right now, and
  whether anything needs attention, outranks whatever the person came to look
  at. So does the Full Disk Access notice: with no grant nothing on any pane is
  true, and somebody who opened the window on Places would otherwise be shown
  an empty map and no reason for it.

## What it does

🛑 **It makes ONE network call, and until the Places pane it made none.** The
map is MapKit, and MapKit fetches its tiles from Apple every time it draws.
Before this panel existed, `apple maps geocode` and the `--at` flags were the
whole network surface of this repo — in their own `Geocoding` target, opt-in,
and refusable with `--local-only`.

- ⚠️ **The places themselves never leave the machine.** MapKit asks Apple for
  pictures of the world at a region and a zoom. It is not handed the user's
  coordinates as data, and nothing uploads a place, a date or a name. What an
  observer could infer is the **region being looked at**, which is weaker than
  the pin list but is not nothing.
- The map is built only while its pane is on screen, so a window whose Places
  pane is never opened makes no request at all. ⚠️ The rail made that stronger
  than it was: a scroll view built the map for anyone who scrolled far enough.
- **No CLI makes this call.** `apple-index places` is JSON off the index, and
  it touches nothing.

**It indexes.** `NSBackgroundActivityScheduler` every 5 minutes with 60 seconds
of tolerance, plus on wake and on unlock, plus once at launch. It runs
`index.py ingest` per source and then `index.py embed`, as children, so they
inherit the grant. A full deletion sweep runs weekly, not every cycle.

**It draws a world map of everywhere you have been.** The Places pane reads
`index.py places`, which merges Maps' visited places with clusters of located
photographs. 🛑 **The two carry different units and the panel never adds them**:
a `visit` is an arrival Maps recorded, a `photo day` is a day a picture was
taken there. The legend and the list say which is which, and the dot is sized
on `max` of the two — an ordering, never a measurement.

- ⚠️ **The map draws the top 400 places, not all 1,487.** MapKit draws every
  annotation it is given, and 1,487 pins at world zoom is a smear that says
  nothing. The badge always shows the full total, so the cap can never read as
  "this is everywhere".
- ⚠️ **Pins carry no labels.** Every pin showing its name is unreadable
  anywhere the user actually spends time, and the names are often street
  addresses. Tap a place to see it.

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

🛑 **ONE ROW PER SOURCE, NOT TWO PANELS.** "Permissions" and "Indexed" were the
same eight names in two lists a screen apart, and the question a person has
joins them: *mail says 40,000 records — is that everything, or is the grant half
broken?* Answering that meant scrolling between two panels and matching names by
eye. Each source is now one row carrying both, and the permission detail and its
fix appear inside the row rather than as a list of red lines under a grid of
green ticks.

- ⚠️ **A source with no permission of its own is not a broken one.** `files` has
  no grant; it reads the folders the user named. It gets a dashed mark, never a
  red one.
- ⚠️ **A permission with no source is not a broken one either.** `phone` is read
  for the people report and never indexed, so its row says so rather than
  leaving a blank line beside a green tick.
- 🛑 **`pane` from `apple status` is a HUMAN NAME, not a URL fragment.** It reads
  `Full Disk Access + Automation`. Handing that to `Grants.openPane` builds a
  settings URL that opens nothing, so it is mapped, and a pane not on the map
  gets no button rather than a dead one.

🛑 **`files` LISTS ITS TOP-LEVEL FOLDERS, NOT ITS BIGGEST ONES.** Every other
source files a record under one flat name — an account, a mailbox, a calendar, a
list. A file is filed under its whole relative folder, so this vault produced 49
rows, most of them a subfolder of another row, ordered by size. That answers
"which folder is biggest", which is nobody's question. `index.py`'s
`top_level_containers` folds them to the first path segment: 49 rows became 12,
and a folder now carries its own files plus everything beneath it.

- 🛑 **THE CUT APPLIES AFTER THE FOLD, NEVER BEFORE.** Taking the 60 largest
  paths first and folding what survives reports a top-level folder short by
  whatever fell past the cut. A wrong number is worse than a missing row, so the
  SQL `LIMIT` is dropped for this one source.
- 🛑 **Only `files` is folded.** Mail's container is `account/mailbox`, and
  folding that keeps the account and throws away the mailbox — the half that
  says what is indexed.
- **Records and chunks, both.** Records alone cannot say why one folder costs
  more of the index than another: 199 files in `Current Work` are 4,779 chunks,
  and 306 in `Reading` are 3,232.
- ⚠️ **Two roots with a folder of the same name merge.** They already did before
  the fold: a file sitting directly in a root is filed under the ROOT's name,
  which collides with a top-level folder of that name elsewhere.

**The folders the `files` source reads are edited in that row.** `Add Folder…`
opens an `NSOpenPanel`; the minus button removes one. Both call `index.py
files`, and `Sources/Folders.swift` is the model.

- 🛑 **ADDING A FOLDER DOES NOT INDEX IT, AND REMOVING ONE DOES NOT UNINDEX IT.**
  The next cycle reads an addition. A removal leaves every record already
  written, because `ingest` only ever adds — those go on the next full rebuild
  of that source. Neither is guessable from the button that was pressed, so both
  are printed after the press.
- 🛑 **`files.json` used to follow the vault.** `dirname(DEFAULT_DB)` is
  `<support>/mnt` whenever the encrypted image is mounted, so a folder added
  from the app landed inside the volume, vanished when the app quit, and
  `apple-index forget` destroyed it with the index. Same trap `people.json`
  recorded; fixed the same way in 26.827.0, and a copy still at the old path is
  moved on sight.

🛑 **A STANDING PARAGRAPH IS NOT A WARNING.** This window carried eight of them,
several in orange, on a machine with nothing wrong — which is how a reader
learns to scroll past the one line that is really about them. Everything
permanently true now sits behind an ⓘ button (`Sources/Explain.swift`); what
stays on the page is what is true right now. The test is: *would this line ever
go away?* If not, it is background.

- ⚠️ **A POPOVER, NOT A `.help()` TOOLTIP.** macOS draws a tooltip as one
  unselectable strip, and several of these paragraphs name a command the user is
  meant to copy. The button carries `.help()` as well, so hovering still works.
- **The whole window is `.textSelection(.enabled)`.** Half of what it prints is
  meant to be copied — a path, an address, a command, an error — and marking the
  handful somebody remembered is how the rest stays unselectable. ⚠️ It does not
  reach the contact web: that is a `WKWebView` drawing SVG, and its text is not
  text.

**It shows who is in the data.** The relationships pane draws a web of who turns
up alongside whom and one row per person across the years — who arrived, who
faded, who came back. It runs `index.py people`, which is described in
[`lab/README.md`](../lab/README.md).

- ⚠️ **The search box sits BESIDE the web, not under it.** As its own panel it
  scrolled out of sight exactly when the picture made somebody want it: the web
  draws a few dozen people and the question it provokes is about somebody in
  three-hundredth place.
- ⚠️ **The channel legend moved INSIDE the web.** Sharing a row with the lookup
  column, four channel names, a switch, a picker and a button no longer fit on
  one line — and SwiftUI kept them all by breaking "Through time" into one
  letter per line, which is worse than any of them being absent.

**The emoji are their own pane.** Top emoji, the most-used and least-used one of
each year, and how long the user takes to pick up an emoji after Unicode
publishes it. 🛑 **BOTH DATES IN THAT LAST ANSWER COME FROM unicode.org** —
`lab/emoji-versions` fetches them; see [`lab/README.md`](../lab/README.md).

**The web is d3, in a `WKWebView`.** `Resources/web/graph.html` plus a vendored
`d3.min.js`; `Sources/ContactWebView.swift` is the bridge. It replaced a
hand-written Fruchterman–Reingold layout that worked and was missing the force
that decides whether a graph is readable: a force-directed model places
**centres** and has no idea a node is a disc, so it settles two circles a
comfortable distance apart and draws them overlapping. `d3.forceCollide` is the
separate pass every real graph library ships for that. Dragging, panning and
zooming came with it.

🛑 **IT MAKES NO NETWORK REQUESTS, AND THAT IS ENFORCED THREE WAYS.** This app
holds Full Disk Access, so a web view that could reach the internet would be
that app phoning home with the user's social graph in memory.

1. d3 is vendored in the bundle — version and sha256 in
   [`Resources/web/VENDORED.md`](Resources/web/VENDORED.md).
2. The page declares `default-src 'none'` with `connect-src 'none'`.
3. `decidePolicyFor` cancels every navigation that is not the one file URL.

⚠️ Any two of those can be got wrong quietly. The third is the one that still
refuses. The web view also uses a **non-persistent** data store: nothing here
needs a cookie, and a store is one more place the graph could come to rest.

**Three things that were wrong at first, all invisible in the code:**

- 🛑 **`window.innerHeight` is not the view.** A `WKWebView` inside a SwiftUI
  frame does not resize its window object to match, so the centring forces
  pulled everything to a middle *below the bottom edge*: an empty panel with one
  circle stranded at the base. Measure the SVG's own rectangle, and observe it
  with a `ResizeObserver` — a window `resize` listener never fires, because the
  window never resizes.
- 🛑 **The clamp has to leave room for the LABEL, not the circle.** Names are
  centred under their node and run well past it, so "Christena Burnham" at the
  left edge was drawn as "istena Burnham".
- ⚠️ **The page decides when to re-simulate**, from a `layoutKey` Swift sends.
  Tracking it on the Swift side too means two places remembering what was last
  drawn, and they drift the first time a frame is skipped.

**It plays the web through time.** A toggle turns the contact web into a
rolling year that can be played or scrubbed, so people appear and fade as they
come and go. 🛑 **The positions never move while it plays.** Re-running the
simulation per frame makes the whole graph swim, and a viewer reads that
movement as meaning — people "drifting apart" who did nothing of the kind. The
layout is all-time and fixed; only presence changes.

**It looks one person up, and the search is a filter.** The web draws a few
dozen; the search box covers all 4,725, and typing a name redraws the timeline
below for everyone who matches. 🛑 It filters the DIRECTORY, not the drawn set:
"show me both Meyers" has one of them in 300th place, so filtering the drawn
list would answer with one.

🛑 **Everything there is ranked and sized by DAYS in contact**, never by a count
of items. One mail record is one email and one messages record is a block of
ten texts, so a sum across sources is meaningless — and the first version
printed one, reporting a spouse of twenty years at "9,059 encounters". The
per-channel counts are still shown, each labelled in its own unit.

🛑 **PRECOMPUTED, ONCE A DAY.** The app runs `index.py people --ensure` at the
end of every indexing cycle. That recomputes the report when the stored one is
a day old and otherwise costs 80 ms, so opening the window reads a stored
answer rather than paying 3.6 seconds. The **Recalculate** button forces a
fresh one.

⚠️ **The daily policy lives in `index.py`, not here.** The scheduler never has
to know how old anything is, and a second copy of "daily" in Swift is how two
schedules drift.

⚠️ **NOT A DIAGNOSTIC.** It answers nothing the app needs in order to index or
to search, its failure is ignored inside the cycle, and a broken report shows
as an empty panel rather than as a broken index.

## The icon, and the Dock

```
./make-icon.sh          # rebuilds Icon/AppleTools.icns
```

🛑 **The source is the website's artwork**, not a second drawing:
`~/src/websites/boulderhopkins-com/static/images/apple-tools-icon.png`. One
picture in one place; a hand-made copy here would drift the first time either
changed.

⚠️ **Apple's grid is 824 in 1024, and the artwork fills all 1024.** Dropped in
as-is the icon is 24% larger than every Apple icon beside it in the Dock, which
reads as a badly made app rather than as a big icon. `make-icon.sh` pads it.
⚠️ `CFBundleIconFile` names the file **without** the extension.

🛑 **`LSUIElement` is an initial policy, not a life sentence.** A background
indexer with a permanent Dock tile is noise — but a visible window belonging to
an accessory app cannot be switched back to. It is absent from the Dock, absent
from ⌘-Tab, and once another window covers it the only way back is the menu bar
item. `DockPresence` raises the activation policy while a window is open and
lowers it again afterwards.

- ⚠️ **One runloop later, on both edges.** `willCloseNotification` fires while
  the window is still in `NSApp.windows`, so counting there finds it and the
  tile never leaves; and SwiftUI runs a scene's `onAppear` **before** the window
  is on screen, so counting there finds nothing and the tile never arrives.
  Measured: the first version called it straight from `onAppear` and the app
  stayed background-only with its window wide open.
- ⚠️ **Counted from the windows themselves**, never from a flag toggled on open
  and close. A flag drifts the first time a window closes by a route nobody
  thought of, and the app is then either stuck in the Dock or unreachable.

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
