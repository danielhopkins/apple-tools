# Apple Health

**There is no Health data on this Mac, and no signing trick changes that.**
HealthKit links on macOS and refuses every call. This file records what was
measured, why the obvious routes are closed, and which three routes remain.

Measured on macOS 27.0 (build `26A5416b`, 2026-08-20), Xcode-beta SDK.

## 🛑 HealthKit is unavailable on macOS

`HealthKit.framework` ships on macOS and its headers declare
`API_AVAILABLE(… macos(13.0))`. A CLI compiles and links against it. It then
fails at run time:

```
isHealthDataAvailable: false
supportsHealthRecords: false
requestAuthorization ok=false err=Error Domain=com.apple.healthkit Code=1
  "Health data is unavailable on this device"
query samples=-1 err=Error Domain=com.apple.healthkit Code=1
  "Health data is unavailable on this device"
```

Code 1 is `HKErrorHealthDataUnavailable`. Both the authorization request and a
real `HKSampleQuery` return it.

⚠️ **The framework validates your `Info.plist` before it tells you it is
unavailable.** A probe with no `NSHealthShareUsageDescription` raises
`NSInvalidArgumentException` and dies, and so does one whose string is too
short ("probe" is rejected as invalid). Neither crash is evidence about
availability. Embed a real sentence with `-sectcreate __TEXT __info_plist`
before drawing any conclusion.

Apple confirms it. DTS engineer Ziqiao Chen, developer forum thread 798780
(September 2025):

> "It's right that your app can't read or write HealthKit data on macOS as of
> today. `isHealthDataAvailable()` will return you `false`, if you check with
> it."

The open feedback report asking for macOS support is **FB20316920**.

Supporting facts on this machine:

| Check | Result |
|---|---|
| Health app in `/System/Applications` | none |
| Fitness app | none |
| `HealthKit.framework` (public) | present |
| `HealthDaemon.framework` (private) | present, no daemon running |
| `launchctl list \| grep -i health` | nothing |
| `~/Library/Health`, any `healthdb*` | nothing |
| TCC service for Health | none |

## 🛑 Code signing does not unlock it

One project ([Vitalink](https://github.com/RyanLisse/Vitalink)) claims a signed
macOS CLI reaches HealthKit, and blames `SIGKILL` / exit 137 on *missing*
signing. That is backwards. Measured, same binary, four signing states:

| Signing | Entitlement | Result |
|---|---|---|
| unsigned | — | runs, reports **unavailable** |
| Developer ID | none | runs, reports **unavailable** |
| Developer ID | `com.apple.developer.healthkit` | **SIGKILL, exit 137** |
| ad-hoc (`-s -`) | `com.apple.developer.healthkit` | **SIGKILL, exit 137** |
| Apple Development | `com.apple.developer.healthkit` | **SIGKILL, exit 137** |

So exit 137 is what carrying the entitlement *causes*, not what omitting it
causes. `taskgated` kills a binary claiming a restricted entitlement that no
provisioning profile grants.

🛑 **And no profile can grant it on macOS.** Xcode's own portal capability
cache says which SDKs the capability exists for:

```
/Applications/Xcode-beta.app/Contents/SharedFrameworks/DVTPortal.framework/
  Versions/A/Resources/DVTPortalCachedPortalCapabilities.json
```

```json
"name": "HealthKit",
"supportedSDKs": [{"name": "IOS"}, {"name": "VISION_OS"}, {"name": "WATCH_OS"}]
```

`MAC_OS` is absent. You cannot enable HealthKit on a macOS App ID, so you
cannot get a profile carrying the entitlement, so the binary is killed. The
chain is closed at Apple's end, not at ours.

Vitalink was created and last pushed on the same day (2026-01-05, 6 stars, no
license). Its README claim is untested here and is contradicted by the table
above.

## What Shortcuts knows

macOS Shortcuts carries the Health action *strings* — "Log Health Sample",
"Find Health Samples", "Get Details of Health Sample" — in
`WorkflowKit.framework/Resources/Localizable.loctable`. ⚠️ **That is not
evidence the actions run here.** They have no store to reach.

This user's synced shortcut **Record Drink** contains the action identifier
`is.workflow.actions.health.quantity.log`, read out of
`~/Library/Shortcuts/Shortcuts.sqlite` (`ZSHORTCUTACTIONS.ZDATA`, a binary
plist). It syncs to the Mac through iCloud and belongs to the iPhone.

## The four remaining routes

None of these reads a local store, because there is none. Each one moves data
from the iPhone to a file this Mac can read.

### A. An iPhone Shortcut writes a file

An iOS Personal Automation runs on a schedule. "Find Health Samples" reads the
types you choose. The shortcut writes JSON to iCloud Drive. The Mac reads that
file.

- Gives fresh data without a manual step after setup.
- Covers only the types the shortcut asks for, not everything.
- 🛑 **The Mac cannot trigger the refresh.** There is no API to run a shortcut
  on another device.
- Matches the Shortcuts write path this repo already uses for Notes.
- ⚠️ Unverified from this Mac. The iOS action list and its output shape were
  not measured here.

### B. The Health export archive

Health app → profile → Export All Health Data → `export.zip`, containing
`export.xml`. AirDrop it to the Mac and parse it.

- Complete history in one file, fully local.
- One snapshot. It goes stale immediately.
- ⚠️ **Nothing here has been measured.** No export exists on this Mac, so the
  file size, the record count and the parse time are all unknown. Do not quote
  a number until one is made.

### How the built-in export works

Every parser with adoption consumes this archive. The steps on the iPhone:

1. Open the **Health** app.
2. Tap the profile picture, top right.
3. Scroll to the bottom and tap **Export All Health Data**.
4. Confirm, then wait.
5. Share the resulting `export.zip` by AirDrop, or save it to Files.

⚠️ **The export runs on the phone and takes minutes to hours.** Reported times
range from five minutes on an iPhone 8 to several hours for a long Apple Watch
history. Nothing reports progress usefully.

The archive holds:

```
apple_health_export/
  export.xml            every Record, Workout and ActivitySummary
  export_cda.xml        the same data as a clinical CDA document
  workout-routes/*.gpx  one track per outdoor workout
  electrocardiograms/   CSV per ECG, when the watch recorded any
```

🛑 **Do not hardcode `apple_health_export/export.xml`.** The folder and file
names vary by locale and iOS version. `healthkit-to-sqlite` sniffs instead: it
takes any `.xml` one level deep whose first 1024 bytes contain
`<!DOCTYPE HealthData` or `<HealthData `. Copy that rule.

Three element types carry everything:

```xml
<Record type="HKQuantityTypeIdentifierStepCount" sourceName="…"
        startDate="2016-11-14 07:25:44 -0700" value="112" unit="count">
  <MetadataEntry key="…" value="…"/>
</Record>
<Workout workoutActivityType="…">
  <WorkoutEvent …/>
  <WorkoutRoute><FileReference path="/workout-routes/route_2019-06-11_3.00pm.gpx"/></WorkoutRoute>
</Workout>
<ActivitySummary …/>
```

🛑 **One archive carries two date formats.** `export.xml` writes
`2016-11-14 07:25:44 -0700`. The GPX files write ISO 8601,
`2019-06-11T22:00:42Z`. A reader that assumes one format drops every workout
route point, or every record.

🛑 **The XML is too big to load.** Reported sizes: 50–150 MB zipped, 200 MB to
2.5 GB unzipped. Stream it. `healthkit-to-sqlite` feeds 1 MB chunks to
`ET.XMLPullParser` and clears the root element on every event.

⚠️ **None of these numbers was measured here.** No export exists on this Mac.
They come from the parsers' own code and from user reports. Make one export,
then replace this paragraph with real figures.

### C. An encrypted local iPhone backup

`healthdb_secure.sqlite` lives inside an *encrypted* backup. An unencrypted
backup omits Health data entirely.

- Needs the backup password and a decryption step.
- ⚠️ **No backup exists on this Mac.**
  `~/Library/Application Support/MobileSync/Backup/` is absent.
- Heaviest of the three, and still a snapshot.

### D. A third-party app on a schedule

[Health Auto Export](https://apps.apple.com/us/app/health-auto-export-json-csv/id1115567069)
reads 150+ metrics on the iPhone and writes CSV, JSON or GPX. It can post to
iCloud Drive, Dropbox, a REST endpoint, MQTT or Home Assistant on a schedule.
Background export needs the paid tier. It is closed source; only its API
documentation is [public](https://github.com/Lybron/health-auto-export).

This is route A with the shortcut already written, and it costs money.

### Which to pick

**B loads the history. A or D keeps it current.** B gives every record ever,
once, and then goes stale. A and D give a chosen set of types on a schedule.
Run B once, then A or D, and one store holds both.

## What is already on this Mac

Two iCloud containers from third-party iPhone apps, **both empty**:

```
~/Library/Mobile Documents/iCloud~com~ifunography~HealthExport   (Health Export CSV)
~/Library/Mobile Documents/iCloud~com~lionheartsw~HealthImporter (Health Importer)
```

No `export.zip`, no `export.xml`, no CSV anywhere in Downloads, Desktop,
Documents or iCloud Drive.

## Prior art

Metrics from the GitHub API on **2026-08-20**. Not maintained automatically.

| Project | Lang | ★ | Created | Last push | License | Route |
|---|---|---|---|---|---|---|
| [markwk/qs_ledger](https://github.com/markwk/qs_ledger) | Notebook | 1073 | 2018-05-23 | 2022-08-18 | MIT | export.xml |
| [neiltron/apple-health-mcp](https://github.com/neiltron/apple-health-mcp) | TS | 564 | 2025-07-22 | 2026-08-18 | MIT | CSV export |
| [the-momentum/apple-health-mcp-server](https://github.com/the-momentum/apple-health-mcp-server) | Python | 253 | 2025-07-02 | 2026-07-09 | MIT | export + DuckDB |
| [dogsheep/healthkit-to-sqlite](https://github.com/dogsheep/healthkit-to-sqlite) | Python | 248 | 2019-07-20 | 2023-01-01 | Apache-2.0 | export.zip → SQLite |
| [alxdrcirilo/apple-health-parser](https://github.com/alxdrcirilo/apple-health-parser) | Python | 91 | 2024-06-27 | 2026-07-22 | MIT | export.xml |
| [fedecalendino/apple-health](https://github.com/fedecalendino/apple-health) | Python | 33 | 2020-04-24 | 2024-03-20 | MIT | export.xml |
| [RyanLisse/Vitalink](https://github.com/RyanLisse/Vitalink) | Swift | 6 | 2026-01-05 | 2026-01-05 | none | claims direct HealthKit |
| [PhilipAD/health-export-mcp](https://github.com/PhilipAD/health-export-mcp) | JS | 3 | 2026-06-27 | 2026-08-20 | MIT | export |
| [davidmosiah/apple-health-mcp](https://github.com/davidmosiah/apple-health-mcp) | TS | 2 | 2026-05-04 | 2026-08-15 | MIT | export.zip / .xml |

**Every project with real adoption parses the export archive.** That is route
B. Nobody reads a live local store, because none exists.

`healthkit-to-sqlite` is the closest match to how this repo works: it turns
`export.zip` into a SQLite file you then query. It has not been pushed since
2023-01-01.

*Not verified:* the parsing code in any of these. Only the route each one takes
was read, from its README and its file listing.

## The alarm

Re-run the probe after a macOS update. If `isHealthDataAvailable()` ever
returns `true`, every conclusion above is void.

```bash
cat > /tmp/hk.swift <<'EOF'
import HealthKit
print(HKHealthStore.isHealthDataAvailable())
EOF
xcrun swiftc -O /tmp/hk.swift -o /tmp/hk && /tmp/hk
```

Also re-check `supportedSDKs` for `HealthKit` in Xcode's
`DVTPortalCachedPortalCapabilities.json`. `MAC_OS` appearing there is the first
sign Apple has moved.
