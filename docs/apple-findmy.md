# Apple Find My

**Nothing here reads Find My, and people are the hardest half.** The caches on
disk are encrypted, the daemon's databases are encrypted, the app ships no
AppleScript dictionary, its App Intents bundle is empty, and the XPC services
are gated by four `com.apple.*` entitlements that no signed CLI can carry. This
file records what was measured, so the question does not have to be re-opened.

Measured on macOS 27.0 (build `26A5416b`, 2026-08-21), with Find My.app
running and its caches freshly written.

Same shape as [`apple-health.md`](apple-health.md): the wall is at Apple's end,
not at ours.

## 🛑 The caches exist and are encrypted

Two directories hold everything the app renders:

```
~/Library/Caches/com.apple.findmy.fmfcore/    people
~/Library/Caches/com.apple.findmy.fmipcore/   devices, items, family, safe locations
```

| File | Bytes |
|---|---|
| `fmfcore/FriendCacheData.data` | 10,660 |
| `fmipcore/Devices.data` | 30,944 |
| `fmipcore/Items.data` | 14,634 |
| `fmipcore/ItemGroups.data` | 13,298 |
| `fmipcore/SafeLocations.data` | 6,458 |
| `fmipcore/FamilyMembers.data` | 541 |
| `fmipcore/Owner.data` | 430 |

**`FriendCacheData.data` is the people file.** It is the only one. There is no
`Friends.data` and no `Locations.data` on this build.

Every one of the seven is a binary plist with exactly two keys:

```
$ head -c 48 ~/Library/Caches/com.apple.findmy.fmfcore/FriendCacheData.data | xxd
00000000: 6270 6c69 7374 3030 d201 0203 0459 7369  bplist00.....Ysi
00000010: 676e 6174 7572 655d 656e 6372 7970 7465  gnature]encrypte
00000020: 6444 6174 614f 1040 5b3f f85a 27e4 58f1  dDataO.@[?.Z'.X.
```

`signature` is 64 bytes. `encryptedData` is the rest. **No handle, no name, no
coordinate and no timestamp survives in plaintext.**

⚠️ **`strings` on these files is not empty, and that means nothing.** It returns
150 runs from `FriendCacheData.data` and 366 from `Devices.data`. Every one is
ciphertext that happens to be printable. The longest run in the people file is
nine characters: `C|n\N5i,U`. Do not read a hit as a decode.

⚠️ **Do not read an old blog post as current.** Earlier writeups treat these
paths as plaintext JSON. On this build they are not. Check the first 48 bytes
before believing any of them.

🛑 **The key is not ours to take.** It lives in the keychain, behind a
restricted access group that belongs to the daemon. Reaching it is a bypass,
not a read path, and this repo does not do that.

## 🛑 The daemon's databases are encrypted SQLite

Two group containers hold Core Data stores:

```
~/Library/Group Containers/group.com.apple.findmy.findmylocateagent/Library/Application Support/
~/Library/Group Containers/group.com.apple.icloud.findmydeviced/Library/Application Support/
    CloudStorage.db  LocalStorage.db  CloudStorage_CKRecordCache.db
```

All six answer the same way:

```
$ sqlite3 CloudStorage.db ".tables"
Error: file is not a database
```

The header is random bytes, not `SQLite format 3`:

```
00000000: d504 7fe7 7772 1ebe 9945 94ae 33d6 5342  ....wr...E..3.SB
```

`findmylocateagent` carries `com.apple.private.sqlite.sqlite-encryption`. That
entitlement is what makes the file unreadable to everything else. Full Disk
Access does not help; the bytes are encrypted, not protected.

## 🛑 No AppleScript

```
$ sdef /System/Applications/FindMy.app
sdef: couldn't get sdef for /System/Applications/FindMy.app (error -192)
```

Find My ships no dictionary at all. Same answer Maps.app gives — see
[`apple-maps-store.md`](apple-maps-store.md).

## 🛑 No App Intents, and no Shortcuts actions

`FindMyIntentsExtension.appex` exists and ships a metadata bundle. The bundle
is empty:

```
$ cat /System/Library/ExtensionKit/Extensions/FindMyIntentsExtension.appex/\
Contents/Resources/Metadata.appintents/extract.actionsdata
{"actions":{},"assistantEntities":[],"assistantIntentNegativePhrases":[],
 "assistantIntents":[],"autoShortcuts":[],"entities":{},"enums":[],
 "generator":{"name":"xcode-tools","version":"27A200c"},"negativePhrases":[],
 "queries":{},"shortcutTileColor":14,"version":1}

(one line on disk; wrapped here)
```

```
$ ./util/appintents-dump/appintents-dump \
    /System/Library/ExtensionKit/Extensions/FindMyIntentsExtension.appex
App: FindMyIntentsExtension.appex  (com.apple.findmy.FindMyIntents)
metadata v-1  •  0 actions
```

`grep -rl -i findmy /System/Applications/Shortcuts.app/Contents/Resources`
returns nothing. **macOS Shortcuts has no Find My action.** The Notes write
path in [`apple-notes-shortcuts.md`](apple-notes-shortcuts.md) has no
equivalent here.

⚠️ **`FindMy.app`'s `Info.plist` lists four intent names and they mislead.**

```
"NSUserActivityTypes" => ["LocateDeviceIntent", "LocateIntent",
                          "PlaySoundIntent", "ToggleLocationSharingIntent"]
```

Those are `NSUserActivity` type strings, not a callable surface. Nothing
outside the app can invoke one.

## 🛑 The XPC services are entitlement-gated

`findmylocateagent` publishes four services, and they are exactly the ones a
people reader would want:

```
$ launchctl print gui/$(id -u)/com.apple.findmy.findmylocateagent
    "com.apple.findmy.findmylocate.friendshipservice"
    "com.apple.findmy.findmylocate.locationservice"
    "com.apple.findmy.findmylocate.fenceservice"
    "com.apple.findmy.findmylocate.settings"
```

`FindMy.app` reaches them through **two** gates, not one. It holds each service
name as a top-level entitlement:

```
[Key] com.apple.findmy.findmylocate.friendshipservice   [Bool] true
[Key] com.apple.findmy.findmylocate.locationservice     [Bool] true
[Key] com.apple.findmy.findmylocate.fenceservice        [Bool] true
[Key] com.apple.findmy.findmylocate.settings            [Bool] true
```

and it repeats them as sandbox mach-lookup exceptions. It also holds
`com.apple.icloud.searchpartyd.securelocations.access`,
`com.apple.icloud.findmydeviced.access` and nine more `searchparty*` keys.
That is ten `searchparty*` entitlements in all.

🛑 **Xcode's portal capability cache names no Find My capability.**

```
/Applications/Xcode-beta.app/Contents/SharedFrameworks/DVTPortal.framework/
  Versions/A/Resources/DVTPortalCachedPortalCapabilities.json
```

No entry matches `find`. So no App ID can enable it, so no provisioning profile
can grant the entitlement, so a binary claiming one is killed by `taskgated`.
The chain closes at Apple's end. Signing and notarising change nothing, exactly
as with `CommunicationsFilter` in [`apple-phone-store.md`](apple-phone-store.md).

## What holds no location

Checked and empty, so nobody has to check again:

| Place | What it holds |
|---|---|
| `~/Library/Preferences/com.apple.findmy.plist` | window frames, onboarding flags, map style |
| `…findmy.fmfcore.notbackedup.plist` | an APS token, a precision flag |
| `…findmy.findmylocateagent.plist` | CloudKit boot state, a refresh date |
| `…icloud.findmydeviced.findmydevice-user-agent.plist` | daemon state |
| `~/Library/Containers/com.apple.findmy.FindMyWidgetPeople` | chrono placeholder timelines only |

No TCC service exists for Find My. There is no grant to ask for.

## The one thing that works

**`FindMy.app` registers five URL schemes**, so a command can hand off to the
app:

```
findmy://   fmf1://   findmyfriends://   fmip1://   grenada://
```

That opens a window. It returns no data, and it steals focus. The honest shape
for this repo is a signpost, like `apple phone recordings`: print where the
data lives, say why nothing reads it, and exit.

## The network route, and why not

`pyicloud` and `FindMy.py` read friend locations from `fmipmobile.icloud.com`
after signing in with the Apple ID. That works, and it is what every third-party
Find My tool does.

🛑 **It breaks this repo's one network rule.** Geocoding is the single network
call here, it lives in its own `Geocoding` target, and `--local-only` refuses
it. A Find My reader would need the user's Apple ID password, a 2FA prompt, and
a stored session token, for data that never touches this Mac in readable form.
That is a different kind of tool.

If it is ever built, it belongs in its own target with its own opt-in, and this
paragraph should say so with measurements rather than plans.

## Summary

| Route | Result |
|---|---|
| `fmfcore` / `fmipcore` caches | encrypted bplist, key in a restricted keychain group |
| daemon Core Data stores | encrypted SQLite, `sqlite-encryption` entitlement |
| AppleScript | no dictionary, error -192 |
| App Intents / Shortcuts | 0 actions, empty metadata |
| XPC to `findmylocateagent` | four private entitlements, ungrantable |
| preferences, widget containers | no locations |
| URL scheme | opens the app, returns nothing |
| iCloud web API | works, needs the Apple ID and the network |

**People are no more reachable than devices, and devices are not reachable
either.** `Devices.data` is 30,944 bytes and none of them are readable.
