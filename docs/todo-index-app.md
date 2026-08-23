# Planned: a notarized app that owns the index and the grants

**Status: phases 0, 1 and 2 are built.** The app indexes on a schedule and owns
the search endpoint. It lives in [`app/`](../app/), and [`app/README.md`](../app/README.md)
records what it does and the traps found building it. Phases 4 to 6 — the
container, encryption, the CLI proxy, notarization and a cask — are still
design only.

## What this is for

`lab/` works and cannot ship, for one reason that is already measured:

> ⚠️ **`apple-index refresh` only works from a terminal, and nothing runs it
> for you.** A launchd agent has **no Full Disk Access**, measured: `apple
> mail`, `apple notes` and `apple messages` all fail from one.

So the index goes stale unless a human opens a terminal. Every other gap in
`lab/SECURITY.md` — no opt-in, no encryption, no revocation — has the same
shape: a CLI has no identity that macOS will grant anything to, and no place to
put a file that macOS will protect.

**An app bundle has both.** That is the whole argument for building one. The app
is not a nicer front end for the index. It is the only container that can hold
the grants the index needs and the file the index produces.

Four things the app must deliver:

1. **One TCC identity** that covers every store, held by the app, not by
   whichever terminal happened to launch a tool.
2. **A real container** for the index, protected as well as its inputs are.
3. **Indexing that runs on its own**, on a schedule, with visible status.
4. **The CLIs installed**, so `apple` and `apple-index` keep working.

## 🛑 The decision that governs every other one

**The app cannot be sandboxed, so it cannot go in the Mac App Store.**

The App Sandbox denies reads outside the container regardless of TCC. Full Disk
Access does not lift it. `~/Library/Mail`, `chat.db`, `NoteStore.sqlite` and
`MapsSync_0.0.1` are all outside. There is no entitlement, temporary or
otherwise, that gets a sandboxed app into them.

So the shape is fixed:

| | |
|---|---|
| Sandbox | **off** |
| Hardened Runtime | **on** (required to notarize) |
| Signing | Developer ID Application — `Dan Hopkins (25RCAA3JLJ)`, already in the keychain |
| Notarization | `notarytool` + `stapler` |
| Distribution | signed DMG or zip, and a Homebrew **cask** |
| Mac App Store | **impossible** |

⚠️ **Do not name the product "Apple …" for public distribution.** Notarization
does not check the name, but Apple's trademark guidelines forbid it and a cask
in a public tap is public use. `AppleTools.app` is fine on this machine and is
the wrong name to ship. This doc writes `AppleTools.app` as a placeholder.

## ✅ Step 0: measured on 2026-08-23, and the answer is yes

**Children DO inherit the app's TCC identity.** One Full Disk Access grant on
the app covered `apple-notes`, `apple-mail`, `apple-messages` and `apple-maps`
when the app spawned them. Measured in a matched pair on macOS 27.0 (26A5416b):
one indexing cycle before the grant and one after it, nothing else changed.

| Source | Before the grant | After |
|---|---|---|
| notes | `sqlite3.OperationalError: unable to open database file` | ✅ |
| mail | refused to fall back to AppleScript | ✅ |
| messages | `Cannot read chat.db … needs Full Disk Access` | ✅ |
| maps | `Cannot read MapsSync_0.0.1 … needs Full Disk Access` | ✅ |

🛑 **LAUNCHING THE APP BINARY FROM A TERMINAL MEASURES THE TERMINAL.** Running
`AppleTools.app/Contents/MacOS/AppleTools` from a shell makes the shell the
responsible process, so the app borrows the terminal's grants. That run reported
**no errors at all**, including calendar and contacts, while the same build
launched with `open` reported two failures. This is the same trap the paragraph
below warns about, and it caught this work anyway. **Launch with `open`.**

⚠️ **Calendar and Contacts are a separate question and they did NOT come free.**
They are framework grants, not Full Disk Access, and the app has to request them
itself. The app now does, at launch, before it spawns anything.

The original text of this step follows, because the reasoning is still what
makes the answer meaningful.

### The claim as it was written

Everything below rests on one claim:

> A child process spawned by the app inherits the app's TCC identity, so one
> Full Disk Access grant on `AppleTools.app` covers `apple-mail`, `apple-notes`,
> `apple-messages`, `apple-phone` and `apple-maps` when the app runs them.

That is how TCC is documented to work — a privacy request is attributed to the
**responsible process**, and for a child that is the app rather than the child's
own binary. It is also exactly the mechanism `TCCResponsibility.claimOwnIdentity`
exists to *break*.

**It has not been measured here, and every schedule in this doc is worthless if
it is false.** Measure it before writing any app code. Half a day:

1. Build a bare `.app` with `LSUIElement`, sign it ad-hoc, put it in
   `/Applications`.
2. Grant it Full Disk Access by hand in System Settings.
3. From that app, `posix_spawn` the installed `apple-mail search "" --limit 1`
   and log the exit status.
4. Repeat with `apple-messages`, `apple-notes`, `apple-maps`, `apple-phone`, and
   with `/usr/bin/python3 lab/index.py status`.

⚠️ **The terminal already has Full Disk Access, so a probe run from a terminal
proves nothing.** Launch the test app from Finder or `launchctl`, never from a
shell that carries its own grant. This is the same trap that produced the wrong
answer about contacts in `lab/INCREMENTAL.md`.

If the claim is false, the fallback is worse but not fatal: every reader gets
compiled into the app process, and the CLIs stay terminal-attributed forever.
That is a rewrite of the ingest path, not a tweak.

## 🛑 Step 0b was WRONG, and the app proved it

**Measured 2026-08-23: the disclaiming tools must KEEP disclaiming inside the
app.** The section below argued the opposite, and following it broke calendar
and contacts for a whole day.

The argument was that disclaiming "throws away the app's grants". It does — but
only the ones the app actually holds. The app holds **Full Disk Access**, which
`apple-calendar` and `apple-contacts` barely need. What they need is Calendar
and Contacts, and **each binary already has its own grant**, given long ago from
a terminal.

With `APPLE_TOOLS_OWN_TCC_IDENTITY` set, so the three ran as the app:

```
calendar   Error: calendar access was not granted
contacts   Error: contacts access was not granted: Access Denied
```

Without it, all six sources index and the cycle reports `errors: NONE`.

🛑 **The app could not obtain those two grants for itself, and no dialog ever
appeared.** Notarization, a reboot, a fresh bundle id, a delay, a reorder, a
fresh store and every legacy Info.plist key were each measured and each changed
nothing. Full record in [`app/README.md`](../app/README.md).

⚠️ **The cost of disclaiming is real and small.** `apple contacts` loses
`has_photo` and `apple calendar` loses the sync tables, because both read those
from disk. The index uses neither. The five tools that DO need Full Disk Access
never disclaim, so they keep the app's grant.

The original section follows.

### The argument as it was written

### Step 0b: the disclaiming tools must stop disclaiming inside the app

`reminders`, `apple-calendar` and `apple-contacts` re-execute themselves
disclaimed, which makes each one **its own** responsible process. Inside the app
that is precisely wrong: it throws away the app's grants and asks for three more
of its own, from a background process that may have no window to show a dialog
in.

**The escape hatch already exists and costs nothing.** `TCCResponsibility`
skips the re-exec when `APPLE_TOOLS_OWN_TCC_IDENTITY` is set in the environment:

```swift
public static var isDisclaimed: Bool {
    ProcessInfo.processInfo.environment[marker] != nil
}
```

So the app sets that variable on every child it spawns, and all eight tools run
under the app's identity. Add a clearer alias (`APPLE_TOOLS_TCC_HOST=app`) and
document it, rather than leaning on a variable whose name says the opposite of
what it means in this context.

**This is the part the user asked for as "a shared TCC", and it is real:** the
app requests Calendar, Contacts and Reminders itself through the public APIs
(which *can* prompt), and holds Full Disk Access (which cannot be requested at
all — see below). One identity, five grants.

⚠️ **It also retires a constraint in `lab/README.md`.** "When a daemon is added
it must be two processes: the disclaiming tools lose Full Disk Access." Under
the app that is no longer true, because nothing disclaims. One process tree
serves both halves.

## The grants, and who holds each one

| Grant | Requestable in code? | Held by | Needed for |
|---|---|---|---|
| Full Disk Access | 🛑 **no** | the app | mail, messages, notes, phone, maps, contacts `has_photo`, calendar sync tables |
| Calendar | yes (`EKEventStore`) | the app | `apple calendar` |
| Reminders | yes (`EKEventStore`) | the app | `reminders` |
| Contacts | yes (`CNContactStore`) | the app | `apple contacts` |
| Automation → Mail / Notes / Contacts | yes, on first Apple Event | the app | compose, `notes delete`, contact notes |

🛑 **There is no API that asks for Full Disk Access.** No prompt, no
`requestAccess`, no entitlement. The user adds the app in System Settings by
hand, and the app is relaunched by the system when they do. So onboarding has to
be a screen that:

1. States plainly what the app will read, in the user's words, not the
   filesystem's.
2. Opens the pane directly:
   `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`
3. Detects the grant by **attempting a protected read** and reporting the
   result, not by asking TCC.

`apple status` already does the detection for all eight tools and returns JSON.
The app should call it rather than growing a second implementation.

## Architecture

```
AppleTools.app
├── Contents/MacOS/AppleTools           SwiftUI, LSUIElement, menu bar + window
├── Contents/Helpers/                   the eight CLIs, signed with the app
│     apple  apple-mail  apple-notes  apple-messages  apple-phone
│     apple-maps  apple-calendar  apple-contacts  reminders
├── Contents/Resources/
│     index.py  *.py  notestore.proto   the ingest driver, unchanged
│     e5-small-v2.mlpackage             the embedder (see below)
│     shortcuts/*.shortcut              the Notes write path
└── Contents/Library/LoginItems/        nothing — SMAppService.mainApp instead
```

Four moving parts inside the app process:

- **Indexer** — spawns `Contents/Helpers/apple <tool> --json`, folds the results
  into SQLite. This is `index.py` today, driven by `/usr/bin/python3` as a child.
- **Embedder** — Core ML, in-process. See below.
- **Search service** — replaces `lab/daemon.py`. Same Unix socket, same
  protocol, so `apple-index search` keeps working unchanged.
- **Scheduler** — `NSBackgroundActivityScheduler`, plus wake and unlock
  notifications.

**Keep `index.py` as a child process for phase one.** It is stdlib-only, it
already works, and rewriting 2,338 lines of ingest logic in Swift on day one
puts the risk in the wrong place. Spawning `/usr/bin/python3` from a hardened
app is allowed — library validation governs what the app *loads*, not what it
*spawns*. Port it to Swift later, source by source, if it earns it.

## 🛑 The trap: shipping the CLIs does not share the grant with them

The user's phrasing — "all the CLI apps installed so they have access to the
data and a shared TCC" — hides a real problem.

**A tool run from a terminal is attributed to the terminal, wherever the binary
lives.** Putting `apple-mail` inside `AppleTools.app/Contents/Helpers` and
symlinking it onto `PATH` changes nothing about that. Typed into Ghostty, it
needs *Ghostty's* Full Disk Access, exactly as today. The app's grant applies
only to children the app itself spawns.

Three routes, and only one of them delivers what was asked for:

| Route | The user grants | Cost |
|---|---|---|
| **A. Symlink and accept it** | app **and** each terminal | none; today's behaviour |
| **B. Proxy through the app** | app only | an XPC service and a shim |
| **C. App only, no CLIs** | app only | breaks every skill and script |

**Recommend B, with A as the fallback path.** The `apple` dispatcher becomes a
shim that checks whether the calling process can read a protected path; if it
can, it execs the real tool exactly as now, and if it cannot, it hands the
argument vector to the app over XPC and streams stdout, stderr and the exit code
back. The user grants once, to the app, and `apple mail search` works from any
terminal, any IDE, any agent.

🛑 **Route B is a genuine security decision, not a convenience.** The app becomes
a service that will read the user's mail on behalf of any process running as the
user, with no prompt. `lab/SECURITY.md` already concedes that the index file has
this property; the proxy extends it from one file to every store. It must be a
setting, default **off**, and the setting must be in the same screen as the
consent copy — not buried.

⚠️ **Automation grants do not transfer either, and they are per-pair.**
"Ghostty may control Mail" and "AppleTools may control Mail" are separate rows.
Anything routed through the proxy asks as the app, which is a *different* prompt
the user has not seen before.

## The embedder has to leave PyTorch behind

Today: `uv run`, `sentence-transformers`, PyTorch, **661 MB resident**. That
cannot go inside a notarized bundle in any form worth defending — the download
size, the unsigned C extensions against library validation, and a toolchain the
user has to already have installed.

**Route: convert `intfloat/e5-small-v2` to Core ML and run it in-process.**

- 33M parameters. fp16 ≈ 66 MB in the bundle; int8 ≈ 33 MB.
- Tokenizer: BERT WordPiece, 30,522 tokens. Either implement it in Swift or take
  `swift-transformers` (Apache 2.0). It must match Python's tokenization
  **exactly**; a different split is a different vector.
- 🛑 **The prefixes stay load-bearing.** `"query: "` and `"passage: "`. `lab/`
  has already been burned once by an embedding used in a way it was not trained
  for.

**This is now measured, and it works.** Full record in
[`lab/coreml/BAKEOFF.md`](../lab/coreml/BAKEOFF.md).

| | PyTorch (`sentence-transformers`, MPS) | Core ML (GPU, bucketed) |
|---|---|---|
| whole corpus, 237,971 chunks | — | **270.9 s** |
| chunks/sec | 272.6 | **878.3** |
| median cosine vs PyTorch | — | **0.999999** |
| MRR over `eval.py` | 0.586 | 0.604 (two cases moved one rank: no change) |
| resident model | 661 MB | one 66.6 MB package |

🛑 **The conversion had a bug that only one backend showed.** The default
additive attention mask is `torch.finfo(float32).min`, which overflows to `-inf`
in fp16. The GPU absorbed it and scored 0.999999. The Neural Engine scored
**0.911821** and the CPU **0.972870**, both silently. The fix is a `-1e4` mask
*and* `attn_implementation="eager"`, because the `sdpa` path never calls the
method being overridden. **Measure every backend, and measure at the batch size
that will run.** At batch 1 the broken model scored 0.999973 and looked fine.

🛑 **`ComputeUnit.ALL` is the wrong default.** The GPU is faster than the Neural
Engine at every sequence length measured, and more exact.

🛑 **The app ships the FIVE FIXED packages, not the enumerated one.** This
reverses an earlier reading of the same measurements. One enumerated package is
66.6 MB on disk against 539 MB, and it costs **1369 MB resident against 192
MB**, because Core ML holds an execution plan per shape. The fixed set is also
faster (968 chunks/sec against 878) and loads lazily, so a short corpus never
touches the long buckets. ⚠️ On the Neural Engine the enumerated package runs
**60× slower** at 32×512 as well.

**int8 weight quantisation halves the package (35 MB) and changes no speed**,
because the compute stays fp16. It costs a little parity (0.999742) and still
passes. Take it only if the bundle size matters.

🛑 **The vectors go in under a new name**, `e5-small-coreml-v1`, so both models
sit in one index and no search mixes them. That is the migration, and it is
reversible with one `DELETE`.

**Both ports are done, 2026-08-22.** `vec` embeds and searches with Core ML and
its own WordPiece tokenizer, and `index.py` calls the binary rather than `uv
run`. No PyTorch and no virtualenv in the embedding path.

- **19,999 of 20,000 chunks byte-identical** to the Python path's vectors.
- **Same throughput, half the CPU.** 20,000 chunks: 25.0 s against 27.1 s, with
  8.3 s of user CPU against 15.9 s.
- 🛑 **Three tokenizer bugs, all silent, all caught by the byte comparison.**
  Swift's `split(separator: " ")` splits on grapheme clusters and a combining
  mark hides the space, which produced 82 spurious `[UNK]` tokens on one real
  mail preheader. `AutoTokenizer` returns the **Rust** tokenizer, which keeps
  unassigned code points where the Python one drops them. Private-use
  characters must be dropped, because Word emits them for bullets.
- 🛑 **The parity gate must compare against rows the PYTHON path wrote**, under
  their own model name. Comparing against the same name after the Swift path
  has written it compares the port to itself and always passes.

**The PyTorch daemon is retired.** `vec daemon` holds the model and the vectors
and answers the same socket: **5.3 ms per search against about 50 ms**, and
474 MB warm against 661 MB. End to end a warm search costs 140 ms.

⚠️ **Two measurement mistakes are worth carrying into the app.** A first version
of this line said 15 ms, which was a best case inside a burst. And the scan
looked like it needed a GPU until it was split: the query embedding was 74% of
the request and the matrix multiply 20%. **Split a latency before optimising
it.**

🛑 **It serves and it does not ingest.** Reading the index needs no grant;
reading Mail, Notes and Messages needs Full Disk Access, which a launchd agent
does not have. That split is the whole reason the app has to exist.

🛑 **One ranking rule is tuned to one embedding, and the app must not inherit
that.** `index.py:1515` re-fuses semantic-heavy when 4 or more of the top 5
records are missing from the semantic arm. With the rule OFF, the Core ML and
PyTorch vectors score **identically** (MRR 0.573 and 0.573). With it ON, PyTorch
gains 0.013 and Core ML loses 0.038. A threshold on a count of five is a knife
edge, and its gain is smaller than the swing it causes between two vector sets
that agree to one part in a million.

## The container, and finally protecting the file

Today the index is `~/Library/Application Support/apple-tools/lab-index.db`:
**820 MB on this machine**, mode 0600 in a 0700 directory, holding the decoded
plaintext of 40,351 emails. `lab/SECURITY.md` states the problem exactly: the
index inherits neither the TCC protection nor the directory modes of its inputs.

The app improves this in two ways, and only one of them is certain.

**Certain: encryption at rest, keyed to the app.**
- SQLCipher, with the key in the Keychain under an ACL bound to the app's
  signing identity.
- 🛑 **Encrypting the body column is not enough. An FTS5 index leaks its own
  terms.** Encrypt the whole file.
- Cost: a dependency, and a measurable hit on every query. Measure it against
  the current 70–300 ms before committing.
- Benefit: revocation becomes real. Delete the key and the file is inert, which
  is the closest thing to the `--forget` path `SECURITY.md` demands.

**Worth measuring: put the file where macOS protects it.** Since macOS 14, one
app reading another app's data container prompts the user
(`kTCCServiceSystemPolicyAppData`). A non-sandboxed app can still create and use
`~/Library/Containers/<bundle-id>/Data/`. ⚠️ **Whether that placement alone earns
the TCC protection for a non-sandboxed app is unverified.** Probe it the same way
as Step 0: write a file there, then try to read it from an unrelated unsigned
binary. If it holds, it is protection the CLI could never have had. If it does
not, encryption is carrying the whole load.

**Either way the app owes the user three controls `lab/` does not have:**

1. **Opt-in per source**, with mail bodies opt-in separately. They are 105 MB of
   the 111 MB of plaintext.
2. **Delete the index** — one button, wired to `index.py purge`.
3. **Notice revocation.** When Full Disk Access disappears, say so and offer to
   purge. A user who revokes the grant expects the mail to stop being readable,
   and today the index keeps answering.

## Scheduling the refresh

The measurements say this is easy, which is why it was left undone:

| Store | Watermark query | Time |
|---|---|---|
| `chat.db` | `MAX(ROWID)` | 0.01s |
| `Envelope Index` | `MAX(ROWID)` | 0.02s |
| `NoteStore.sqlite` | `MAX(ZMODIFICATIONDATE1)` | 0.08s |

A full "did anything change" sweep costs about 0.1s, and a no-change incremental
run is 0.1–3.1s per source.

- **`NSBackgroundActivityScheduler`**, interval 300s with generous tolerance,
  `.utility` QoS. It defers on battery and under thermal pressure, which a
  `StartInterval` launchd agent does not.
- **Also refresh on wake and on unlock** (`NSWorkspace.didWakeNotification`,
  `screensDidUnlockNotification`). Most staleness arrives while the lid is shut.
- **Run at login** with `SMAppService.mainApp.register()`, so there is no
  separate agent plist to keep in sync. This replaces
  `lab/com.boulderhopkins.apple-index.plist.in` entirely.
- **Never run two ingests at once.** One serial queue, and a lock in the
  database, because the user can also press Refresh.
- **Embedding is the long pole**, not ingest. Run it in chunks with a
  cancellation check between batches, so quitting the app is instant.

⚠️ **Deletion detection still only runs with `--full`**, which is a full id-set
sweep. Schedule that weekly, not every five minutes, and keep the guard that
refuses to delete more than 20% of a tool's records.

## What the status window has to show

The user asked for indexing status, and the useful version of that is not a
spinner. Five things, because each one has already been a source of a wrong
answer in `lab/`:

1. **Per source: records, chunks, last successful refresh, last error.** A source
   that has been failing for a week must look different from one that is quiet.
2. **Embed backlog** — chunks with no vector, and a rate. "223k chunks, silent
   for 60 minutes" was read as a hang once, and it was working.
3. **Permission state per store**, straight from `apple status --json`, naming
   the exact state (`denied`, `writeOnly`, `notDetermined`) and the fix.
4. **Index size on disk, and what it contains.** 820 MB of decoded mail should
   never be a surprise.
5. **Model and vector count**, with a warning when rows exist under more than one
   model name. That is the failure that returns confident nonsense.

Menu bar item for the glance, one window for the detail. `LSUIElement` so there
is no Dock icon; a Dock icon for a background indexer is noise.

## Signing, entitlements, notarization

Per the house rule for Swift apps: **xcodegen `project.yml` + `xcodebuild
archive` / `exportArchive`.** Keep `Package.swift` for `swift run` during
development. Never hand-assemble the bundle or call `codesign` on parts of it.

Entitlements — short, because a non-sandboxed app needs almost none:

```xml
<key>com.apple.security.automation.apple-events</key><true/>
```

🛑 **Do not add `com.apple.security.cs.disable-library-validation`** unless
something forces it. Spawning `/usr/bin/python3` does not; loading a
third-party dylib into the app would. If Core ML and a Swift tokenizer are the
whole ML story, nothing forces it.

Info.plist usage strings: `NSAppleEventsUsageDescription`,
`NSContactsUsageDescription`, `NSCalendarsFullAccessUsageDescription`,
`NSRemindersFullAccessUsageDescription`. There is no string for Full Disk
Access; that pane shows no reason text at all, which is why the onboarding
screen has to carry it.

⚠️ **Every helper in `Contents/Helpers/` gets signed with the app's identity and
the hardened runtime**, inside-out, before the outer signature. `codesign
--deep` is not the way to do this and Apple has said so for years; let
`xcodebuild` handle the order.

Release:

```
xcodebuild archive -scheme AppleTools -archivePath build/AppleTools.xcarchive
xcodebuild -exportArchive -archivePath … -exportOptionsPlist Developer-ID.plist
xcrun notarytool submit AppleTools.dmg --keychain-profile apple-tools --wait
xcrun stapler staple AppleTools.dmg
```

⚠️ **`notarytool` rejects a bundle whose helpers are not hardened-runtime
signed**, and the log names the file. Read the JSON log; the summary line does
not say which binary.

**Distribution.** A cask replaces the formula:

```ruby
cask "apple-tools" do
  app "AppleTools.app"
  binary "#{appdir}/AppleTools.app/Contents/Helpers/apple"
  conflicts_with formula: "apple-tools"
end
```

⚠️ **The cask must conflict with the existing formula**, which installs a
`reminders` and an `apple` of its own. Two copies on `PATH` with different TCC
identities is the worst possible state to debug.

**Updates.** Sparkle needs an appcast and an EdDSA key; the cask needs neither
and `brew upgrade` already exists here. Start with the cask.

## Order of work

Sized for one person, part time. The risk is front-loaded on purpose.

| Phase | Work | Days |
|---|---|---|
| **0** | ~~Probe TCC inheritance~~ **done, 2026-08-23 — yes.** Container placement still unprobed. | 0.5 |
| **1** | ~~xcodegen skeleton, menu bar + status window, reading today's SQLite read-only~~ **done, 2026-08-23.** Signed with Developer ID; **not notarized**. | 2–3 |
| **2** | ~~Ingest inside the app: spawn helpers with the TCC-host variable, scheduler, serial queue. Retire the launchd agent~~ **done, 2026-08-23.** | 3–4 |
| **3** | ~~Core ML embedder, parity-checked, Swift tokenizer and runner~~ **done, 2026-08-22** — see `lab/coreml/BAKEOFF.md`. | 0 |
| **4** | Container, encryption, onboarding consent, per-source opt-in, purge, revocation detection. | 3–4 |
| **5** | CLI hosting: helpers on `PATH`, the XPC proxy behind a default-off setting. | 3–5 |
| **6** | Cask, release notes, migration path off the formula. | 2 |

Phases 1 and 2 alone fix the thing that made this necessary: the index refreshes
itself, and the user can see that it did.

**Phase 3 landed early**, on 2026-08-22, because the conversion answered
cleanly. The risk it carried is gone: the model converts, matches PyTorch at
0.999999, runs 3.2× faster than PyTorch on this corpus, and changes no MRR.

## Open questions

1. **Does the app own all eight tools, or only the index?** This doc assumes all
   eight, because that is what "shared TCC" requires. The cost is that the app
   becomes the primary distribution and the formula is retired.
2. **What is it called?** Not "Apple" anything, for anything public.
3. **Is the XPC proxy worth its security cost?** It is the only route to one
   grant, and it is also a service that reads mail for any caller.
4. **Does encryption at rest survive the query budget?** 70–300 ms today.
   Measure before committing to SQLCipher.
5. **Does `index.py` stay Python?** Keeping it is right for phase 2 and probably
   wrong for phase 6.
