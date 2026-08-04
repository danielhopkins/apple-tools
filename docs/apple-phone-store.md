# Apple Phone: the call history store

Everything learned reading macOS's call history, and why `apple phone` is
read-only apart from `dial`.

Verified on macOS 27.0 (build 26A5388g) against a 290-row store. Where a number
appears below it came from that machine; re-measure before trusting it.

## There is no scripting surface. At all.

This is the first thing to establish, because every other Apple app in this repo
has *some* AppleScript or Shortcuts path and Phone.app has neither:

| Probe | Result |
|---|---|
| `sdef /System/Applications/Phone.app` | `error -192` |
| `NSAppleScriptEnabled` in Info.plist | absent |
| `OSAScriptingDefinition` in Info.plist | absent |
| `Metadata.appintents` in the bundle | absent |
| `*.intentdefinition` anywhere in the bundle | none |
| Shortcuts actions | none |
| `sdef /System/Applications/FaceTime.app` | `error -192` |

Phone.app answers only the implicit Standard Suite (`activate`, `quit`,
`get version` — it reports `1.0`, which every unscriptable Cocoa app does). So
reading `CallHistory.storedata` is the only route to call history, and there is
no AppleScript fallback to degrade to the way `apple mail export` has one.

Its menu bar is Apple / Phone / Edit / **Audio** / Window / Help — no Call menu,
no Answer, no End. `Audio → Mute` is the only call control exposed anywhere. The
window's accessibility tree is a Catalyst shell: a toolbar with an `Edit` menu
button, a `filter` menu button, a `keypad` button, and otherwise opaque
`AXGroup`s. Nothing worth automating.

## The store

`~/Library/Application Support/CallHistoryDB/CallHistory.storedata` — a Core
Data SQLite database. Read directly, read-only, needs Full Disk Access for the
calling terminal. Works with Phone.app closed.

Tables: `ZCALLRECORD`, `ZHANDLE`, `Z_2REMOTEPARTICIPANTHANDLES`,
`ZCALLDBPROPERTIES`, `ZEMERGENCYMEDIAITEM`, plus Core Data's `Z_PRIMARYKEY` /
`Z_METADATA` / `Z_MODELCACHE`.

⚠️ **It is a relay mirror, not the whole history.** Four months of calls here
against an iPhone that keeps years. It holds whatever continuity has synced
since Phone.app arrived. Call it "recents"; never present it as a complete
record.

### Columns worth reading on `ZCALLRECORD`

| Column | Notes |
|---|---|
| `ZDATE` | Apple-epoch **seconds**, stored `REAL`. See the two traps below. |
| `ZDURATION` | `FLOAT`, seconds. `0` means never connected. |
| `ZORIGINATED` | `1` = you placed it. |
| `ZANSWERED` | `1` = **you** answered it. Always `0` on an outgoing call. |
| `ZCALLTYPE` | `1` phone, `8` FaceTime audio, `16` FaceTime video. |
| `ZADDRESS` | The handle. **Not normalised** — see below. |
| `ZNAME` | Effectively always empty: 1 row of 289. |
| `ZLOCATION` | Carrier-side geography, e.g. `"Denver, CO"`. Populated on every telephony row. |
| `ZSERVICE_PROVIDER` | `com.apple.Telephony` or `com.apple.FaceTime`. |
| `ZREAD` | The missed-call badge. `1` on all 290 rows here. |
| `ZJUNKCONFIDENCE`, `ZJUNKIDENTIFICATIONCATEGORY`, `ZFILTERED_OUT_REASON` | Spam scoring. All zero/null on this store. |
| `ZBLOCKEDBYEXTENSIONNAME` | Which Call Directory extension blocked it. |
| `ZORIGINATINGDEVICENAME` | Which device placed it. Empty here throughout. |
| `ZWASEMERGENCYCALL` | |
| `ZHASMESSAGE` | `0` on every row. See "voicemail" below. |

`ZHANDLE` (525 rows here) maps handles to `ZNORMALIZEDVALUE`, and
`Z_2REMOTEPARTICIPANTHANDLES` joins calls to handles for group FaceTime.
`ZCALLRECORD.ZADDRESS` is sufficient for one-to-one calls, which is all a recents
list needs.

### 🛑 Trap 1: `ZDATE` is seconds, and `chat.db` is nanoseconds

Messages stores the same conceptual column as Apple-epoch **nanoseconds**; call
history stores **seconds**. Reusing one converter across the two is wrong by a
factor of 10⁹, and the result still looks like a plausible date, so nothing
crashes.

`CallHistoryEpoch` is deliberately a separate type from
`MessagesLibrary.AppleEpoch` to make that impossible to do by accident.

### 🛑 Trap 2: `ZDATE` is a `REAL`, so a text comparison matches nothing

This one cost real time. The obvious `--since` implementation is wrong:

```sql
-- Returns ZERO rows against a store with calls from yesterday.
SELECT * FROM ZCALLRECORD WHERE ZDATE > strftime('%s', 'now', '-4 days');
```

`strftime` returns **text**, `ZDATE` holds a **float**, and SQLite does not
coerce across storage classes in a comparison. There is no error — just an empty
result, which is indistinguishable from "you had no calls". Bind a `double`, or
cast:

```sql
WHERE ZDATE > CAST(strftime('%s','now','-4 days') AS REAL) - 978307200
```

Pinned by `testSinceFiltersInsteadOfSilentlyMatchingNothing`.

### ⚠️ Trap 3: `ZADDRESS` is unnormalised

A single real store holds all of these at once:

```
8005551212          bare 10 digits
18005551212         11 digits, no plus
+13035551212        E.164
name@example.com    a FaceTime call to an Apple ID
```

Every comparison has to go through a key. `PhoneNumber.matchKey` takes the
trailing 10 digits of anything with at least 10, and keys shorter handles (short
codes like `611`) on all their digits. That is correct for NANP and could in
principle collide between countries; nothing stricter works, because the store
spells the *same* number several ways and a strict comparison fails to match a
contact against the call it placed.

### ⚠️ Trap 4: `ZANSWERED` does not mean "connected"

It means "answered by me", so it is `0` on every outgoing call. Deriving status
from it directly reports everything you dialled as missed. The rules are:

```
ZORIGINATED = 1              -> outgoing
ZORIGINATED = 0, ZANSWERED=1 -> incoming
ZORIGINATED = 0, ZANSWERED=0 -> missed
ZDURATION   > 0              -> actually connected  (orthogonal to the above)
```

An outgoing call that rang out and a connected one differ only in `ZDURATION`.

## Names come from the AddressBook stores, not the Contacts framework

`ZNAME` is empty, so every row needs resolving. Two options, and the second is
the wrong one:

`CNContactStore` would need its own TCC grant. `apple-contacts` gets a
tool-bound grant by re-executing itself disclaimed — and a disclaimed process
becomes its own responsible process, which is exactly what Full Disk Access is
attributed to. **A disclaiming `apple-phone` would lose the terminal's Full Disk
Access and stop being able to read call history at all.**

So names are read from the AddressBook SQLite stores, which sit under the *same*
grant. `apple phone` stays a single-grant tool, like `apple messages`:

```
~/Library/Application Support/AddressBook/AddressBook-v22.abcddb          (usually empty)
~/Library/Application Support/AddressBook/Sources/<uuid>/AddressBook-v22.abcddb
```

Join `ZABCDPHONENUMBER.ZOWNER` / `ZABCDEMAILADDRESS.ZOWNER` to
`ZABCDRECORD.Z_PK`. 893 phone numbers across two sources here, 1365 handles
indexed once emails are included (1367 before the WAL fix below — the immutable
snapshot was showing two handles that had since been deleted). Emails matter: a FaceTime call's handle is an
Apple ID, so without them those rows never resolve. `ZLASTFOURDIGITS` is indexed
if a lookup ever needs to be cheaper than a full scan.

Read-only, for the same reason `NoteStore` is: writing these would desynchronise
Core Data change tracking and CloudKit sync state.

### 🛑 Trap 5: `immutable=1` on the address book hides recent contacts

`NoteStore` opens the AddressBook stores with `immutable=1`, and copying that
here was wrong. Contacts leaves a large write-ahead log behind — **3 MB against a
35 MB main file** on a live machine — and `immutable=1` promises sqlite the file
cannot change, so it does **not replay the WAL**.

A contact added minutes ago lives only in that log. The reader missed it entirely
and reported the caller as plainly `unknown`, with no warning and nothing to
distinguish it from a caller who really was unsaved.

Found by adding a contact and watching resolution fail to see it:

```
sqlite3 AddressBook-v22.abcddb          "SELECT COUNT(*) … ZFIRSTNAME='Ahmed'"  -> 1
sqlite3 "file:AddressBook-v22.abcddb?immutable=1"  same query                   -> 0
```

It is not only a matter of missing new rows: the handle count went **1367 → 1365**
once the WAL was replayed, because the log carries deletions too. The immutable
snapshot was stale in both directions.

So: plain read-only open first (which replays the log), `immutable=1` only as a
fallback, `PRAGMA query_only` for safety, and a `staleSources` count when the
fallback was needed. Same order `CallHistoryDatabase` and `ChatDatabase` already
used.

Pinned by `testSeesContactsThatAreStillOnlyInTheWriteAheadLog`, which holds the
writer connection open so sqlite cannot checkpoint — the state a running
Contacts.app leaves the store in. Verified to fail against the old code.

### 🛑 Trap 6: opening a SQLite file proves nothing

`sqlite3_open_v2` does no I/O beyond the file handle. It never reads the header,
so it **succeeds on a file that is not a database** and fails only at the first
query. Worse, sqlite treats a **zero- or one-byte file as a valid empty
database**, so a truncated store answers `SELECT 1 FROM sqlite_master` happily.

Either way the address book looks like it opened and simply has no contacts —
and then every caller is reported as unknown, with no warning. Probing for the
expected schema (`SELECT 1 FROM ZABCDPHONENUMBER LIMIT 1`) is the only honest
check; a genuinely empty address book still has the table, since Core Data
creates it with the store.

This is why resolution has three states rather than a boolean:

| State | Meaning | Behaviour |
|---|---|---|
| `available` | at least one store opened *and* has the schema | names resolve |
| `noAddressBook` | no store on this Mac | every caller unknown — correct, silent |
| `unreadable` | stores exist, none usable | warn; `--unknown` **refuses** |

`--unknown` refuses in the last case because with an unreadable address book
*every* caller qualifies, so the command would return the whole store and read
as a complete, alarming answer. `--json` omits the `known` key entirely there
rather than emitting `false`, because a hardcoded `false` is a confident wrong
answer a consumer cannot distinguish from a real one.

`APPLE_PHONE_ADDRESSBOOK_DIR` points the reader elsewhere, which is how the
`unreadable` path is tested without revoking a real grant.

## Blocked callers: readable, and permanently unwritable

`~/Library/Preferences/com.apple.cmfsyncagent.plist`, a plain plist:

```
__kCMFBlockListStoreTopLevelKey
  __kCMFBlockListStoreArrayKey        [ { … } ]
  __kCMFBlockListStoreRevisionKey     25
  __kCMFBlockListStoreRevisionTimestampKey
  __kCMFBlockListStoreVersionKey      1
```

Each item: `__kCMFItemPhoneNumberUnformattedKey` (E.164),
`__kCMFItemPhoneNumberCountryCodeKey` (`"us"`), `__kCMFItemTypeKey` (`0` =
phone), `__kCMFItemVersionKey`.

### 🛑 Trap 7: the block-list API exists, works from an unsigned binary, and lies

`CommunicationsFilter.framework` exports exactly what you would want, and
`dlopen` reaches all of it:

```
CMFBlockListAddItemForAllServices
CMFBlockListRemoveItemFromAllServices
CMFBlockListIsItemBlocked
CMFBlockListGetBlockedStatusForItems
CMFItemCreateWithPhoneNumber / CreateCMFItemFromString
```

`CreateCMFItemFromString("+1…")` really works — it returns the same dictionary
shape the plist stores, country code derived. Then it dead-ends. Tested against a
number that was on the list in that very plist:

```
CMFBlockListIsItemBlocked(<blocked number>)  ->  false
CMFBlockListGetBlockedStatusForItems([...])  ->  { }
```

`CMFSyncAgent` is running. Its binary contains:

```
[WARN] Denying xpc connection, task does not have entitlement: %@
com.apple.private.communicationsfilter
```

Phone.app holds `com.apple.private.communicationsfilter` and is
`platform-application: true`. A `com.apple.private.*` entitlement cannot be
claimed by a Developer ID signature at any price — signing and notarising the
tool does not change this. **A `block` command would report success and change
nothing**, which is worse than not offering one.

Writing the plist directly is also wrong: `cmfsyncagent` owns it, caches it in
memory, and versions it with a revision counter it syncs. The two timestamps
disagree on a real machine (revision stamped 2025-06-12, file mtime 2026-05-08),
which is the tell that it is a synced cache and not the authority.

Blocking is the iPhone's job anyway: an incoming call on the Mac is relayed from
the phone, and the phone filters. A working local write would not stop the phone
ringing. (That last step is inference from the relay architecture, not something
verified — it needs a real spam call to confirm.)

## Voicemail is not on the Mac

Searched `~/Library` to depth 6, `/var/db`, and `/var/folders`: no voicemail
store. In the call history store `ZHASMESSAGE` is `0` and `ZREAD` is `1` on
**every** row — there are no voicemail records to mark read.

`voicemail-*.m4a` files under `~/Library/Messages/Attachments` are a red herring:
those are voicemails other people forwarded over iMessage (2017–2022 here), not
an inbox.

Phone.app reaches voicemail through `com.apple.visualvoicemail.client` and the
`com.apple.voicemail.vmd` mach service. `vmd` does not exist on macOS and
`~/Library/CallServices` does not either. `vmshow://` takes a voicemail message
UUID (`"No VoiceMail message uuid in the url"`) that nothing local can
enumerate. It is relayed live from the iPhone and never lands on disk.

## Dialing: a URL, and a prompt you cannot skip

Phone.app registers `tel`, `telephony`, `facetime-audio`, `phoneapp`,
`phone-tel`, `phone-telephony`, `vmshow`, `mobilephone-recents`. Handing it a
`tel:` URL is the whole mechanism.

The prompt is not avoidable. Phone.app's binary carries
`shouldRestrictDialRequest:performSynchronously:`, `showAudioCallPrompt`,
`hideCallPrompts` and `"Has 'no prompt' entitlement? %s"` — and that entitlement
is `com.apple.FaceTime.NoPrompt`, which Phone.app holds and which is
`com.apple.private`-class in practice: grantable only to an Apple-signed
platform application.

That is treated as a feature. Every other irreversible write in this repo needs
an explicit `--confirm`; dialing gets a human gate from the OS that `mail send`
never had, so the CLI adds no second one. What it must never do is *click* that
panel — auto-confirming would turn one command into a real, billable, outward
phone call with no human in the loop. `--dry-run` prints the URL instead.

## What Catalyst and code signing would and would not buy

Both were investigated before scoping this tool. Neither changes anything above.

**CallKit is a zippered dylib.** `/System/Library/Frameworks/CallKit.framework`
reports `platform: zippered(macOS/Catalyst)` — one binary, both slices. The
headers say `API_AVAILABLE(ios, macCatalyst) API_UNAVAILABLE(macos)`, but that is
a compile-time gate with no runtime counterpart: a native macOS binary that
declares the interfaces by hand can `dlopen` CallKit and instantiate
`CXCallObserver` and `CXCallController` just as a `-target arm64-apple-ios-macabi`
build can. Both were built and run. So a Catalyst target buys no capability here,
only ceremony.

**Whether `CXCallObserver` reports anything is still open.** Both builds returned
`count=0` with no call active, which does not distinguish "works, nothing to
report" from "silently denied". `callservicesd` contains the string
`access-calls` and Phone.app holds
`com.apple.telephonyutilities.callservicesd: [modify-calls, access-calls, …]`,
which suggests a wall. Settling it needs the probe run *during* a live call. If
it does work, live call state is a feature nothing else in this repo can offer.

**Signing does not unlock any of this.** `com.apple.security.*` is self-asserted,
`com.apple.developer.*` needs a provisioning profile embedded in an app bundle,
and `com.apple.private.*` needs `platform-application` and is unobtainable.
Everything Phone gates — blocking, call control, voicemail, prompt-free dialing,
`CallHistory` writes — is in the last tier. Signing is still worth doing for TCC
stability and for `com.apple.developer.contacts.notes`, but it would not add one
command to this tool.

## Environment seams

| Variable | Effect |
|---|---|
| `APPLE_PHONE_DB_PATH` | Read a specific call history file, or a nonexistent one to see a command without Full Disk Access. Named in the error, so a bad override never looks like a missing grant. |
| `APPLE_PHONE_BLOCKLIST_PATH` | Read a specific block list plist. |
| `APPLE_PHONE_ADDRESSBOOK_DIR` | Read address books from elsewhere; how the `unreadable` state is tested. |

Tests are fully offline — `swift test --filter PhoneTests` builds a synthetic
`ZCALLRECORD` with the real column *types* (so the `REAL` `ZDATE` coercion rule
applies) and never touches the user's data.
