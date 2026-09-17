# Apple Health

**There is no Health data on this Mac, and no signing trick changes that.**
HealthKit links on macOS and refuses every call. This file records what was
measured, why the obvious routes are closed, which routes remain, and what
the `health` plugin built on two of them (2026-09-17).

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

## The route that was built: an iPhone app

`plugins/health/ios/` is **AppleTools Health**, a small SwiftUI app with the
HealthKit entitlement, built with xcodegen and installed on the phone over
the Mac's pairing (`xcrun devicectl device install app`). It is the phone
half of the plugin; the routes below are what it replaced or kept.

- **It has the entitlement a Mac cannot**, so the section above stops
  mattering on the phone: `HKStatisticsCollectionQuery` gives Health's own
  daily totals, `HKSampleQuery` gives sleep stages and workouts,
  `HKWorkoutRouteQuery` gives a route's first point.
- **It writes into its own iCloud container**, a fixed path on the Mac
  (`iCloud~com~boulderhopkins~apple-tools~health/Documents/health/`), where
  the shortcut's Save File could land in two places or, measured
  2026-09-17, nowhere visible.
- **It keeps a log** in the app and in `log.txt` beside the files, which is
  the thing a shortcut cannot do: the one run of the shortcut here "ran, no
  error, no file", and nothing could say why.
- **Full history in one tap**, one file per year, so the export archive
  (route B) is optional rather than required.
- `-allowProvisioningUpdates` registered the App ID with HealthKit and the
  iCloud container on the first build. The install needs the phone
  unlocked.

## The four remaining routes

None of these reads a local store, because there is none. Each one moves data
from the iPhone to a file this Mac can read.

### A. An iPhone Shortcut writes a file — BUILT, then superseded

⚠️ **Kept as a fallback for a phone that cannot take the app.** Its one run
here produced no file and no error, and nothing about it can be measured
from a Mac. The app above is the route.

`plugins/health/build-shortcut.py` builds and signs **Apple Tools Health
Export.shortcut**. On the phone, "Find Health Samples" reads a fixed set of
types for the last eight days, grouped by day, and Save File writes one
tab-separated text file into iCloud Drive → `apple-tools/health/`. The Mac
reads it with `apple health sync`, which `index` runs first.

- Covers 14 daily types (steps, walking/cycling/swimming distance, active
  calories, exercise and stand minutes, flights, resting and walking heart
  rate, HRV, oxygen saturation, VO2 max, weight) plus raw Sleep samples.
- 🛑 **The Mac cannot trigger the refresh.** There is no API to run a shortcut
  on another device. The user runs it, or sets a Personal Automation.
- 🛑 **No shortcut can read workouts.** See "What the shortcut can read".

#### What the shortcut can read, and how that was found

Nothing on a Mac runs the Health actions, so the serialization was read
from three sources rather than measured here:

1. A real iOS export of a heart-rate shortcut (public,
   `suliveevil/My-Siri-Shortcuts`, `Heart Rate Data.txt`): the
   `filter.health.quantity` → `repeat.each` → `properties.health.quantity`
   → `format.date` → `gettext` → `text.combine` chain, copied shape for
   shape.
2. The **iOS 27 simulator runtime** on this Mac
   (`/Library/Developer/CoreSimulator/Volumes/iOS_24A5390f/…/RuntimeRoot/
   System/Library/PrivateFrameworks/ActionKit.framework/ActionKit`), which
   is a real file rather than a dyld-cache stub. `strings` on it gives the
   parameter keys (`WFHKSampleFilteringGroupBy`, `…FillMissing`, `…Unit`),
   the group-by values (Minute, Hour, Day, Week, Month, 3 Months, Year), the
   seven detail names of `WFHKSampleContentItem` (Type, Value, Unit, Start
   Date, End Date, Duration, Source) and the **full picker label list**.
3. `viticci/shortcuts-playground-plugin`'s HealthKit reference, from
   anonymised iOS 26.2 exports: the `Type is …` row uses `Values.Enumeration`
   with `WFStringSubstitutableState`, and the label for Sleep Analysis is
   **`Sleep`**.

What those settled:

- 🛑 **`WFHKSampleContentItem` wraps an `HKQuantitySample` or an
  `HKCategorySample` and nothing else.** The two constructors in ActionKit
  take exactly those, and the picker list — read in full — has no "Workouts"
  row. `WFHKWorkoutContentItem` exists for *logging* a workout. So workouts
  come from the export archive only.
- ⚠️ **The picker labels are ActionKit's readable names for HealthKit
  identifiers, not the Health app's display names.** `Active Calories` for
  ActiveEnergyBurned, `Exercise Time` for AppleExerciseTime, `Heart Rate
  Variability` for HeartRateVariabilitySDNN. The full list is in the binary,
  in HealthKit-identifier order; the plugin's `METRICS` table carries the
  ones used.
- **`Group by Day` returns Health's own daily totals**, deduplicated across
  the iPhone and the Watch, which raw samples are not. The action's own help
  string: "grouping by day gives you only the daily totals". Sleep is left
  raw because a night starting at 23:00 would land on the wrong day.
- **The date filter row** is `Operator 1001` ("is in the last"), `Unit 16`
  (day), `Number` N — from the real export, which used exactly that for
  "in the last 2 days".
- **`Format Date` with the ICU pattern `yyyy-MM-dd HH:mm:ss Z`** writes
  `2026-09-15 07:25:44 -0600`, the same shape `export.xml` uses, so the
  plugin has one date parser.
- ⚠️ **A number coerced to text is in the phone's locale.** `8,412` on an
  en_US phone. The plugin strips commas and nothing else.
- ⚠️ **The unit follows the phone's settings.** `mi` here, `km` elsewhere.
  The plugin converts to metres, kcal, minutes, bpm, ms and kg, and a unit it
  does not know fails that line naming it rather than storing a number with
  no unit.

⚠️ **Not yet measured on a phone:** whether iOS 27 accepts `"Day"` as the
group-by value as serialized, and whether `Sleep` is still the label. The
first run on the phone is the test; a wrong label shows as an empty Type in
the editor and produces no lines for that type, and the plugin's `sync`
report names every type it did not see.

The file format, version 1:

```
apple-tools health 1
generated	2026-09-16 07:02:11 -0600
window	8
day	Steps	2026-09-15 00:00:00 -0600	2026-09-16 00:00:00 -0600	10,015	count
day	Cycling Distance	2026-09-15 00:00:00 -0600	2026-09-16 00:00:00 -0600	12.5	mi
sample	Sleep	2026-09-14 23:10:00 -0600	2026-09-15 00:40:00 -0600	Asleep Deep	count
```

A `day` row spans the phone's local day; a `sample` row is one raw sample.
A day is `partial` when the file was generated before the day ended, and
the next run's file replaces it. `plugins/health/test-health.py` rebuilds
the shortcut unsigned and checks every label in it against the plugin's
table, so the two halves cannot drift.

### B. The Health export archive — BUILT

Health app → profile → Export All Health Data → `export.zip`, containing
`export.xml`. AirDrop it to the Mac and `apple health import export.zip`.

- Complete history in one file, fully local. **The only route to workouts.**
- One snapshot. It goes stale immediately; route A keeps it current.
- ⚠️ **Nothing here has been measured on a real archive.** No export exists
  on this Mac yet, so the file size, the record count and the parse time are
  unknown. The reader is exercised on a synthetic archive only. Replace this
  line when a real one is imported.

How `import` reads it:

- 🛑 **A day's steps are not the sum of every step record.** The iPhone and
  the Watch both count the same walk; Health shows one of them, the export
  carries both. A cumulative type is summed per source per day and the day
  takes the **largest source's** total — near what Health shows, never
  twice it. A discrete type (resting heart rate, HRV, SpO2, VO2 max) is the
  day's mean; weight is the last reading of the day.
- **A day the shortcut wrote is kept**, because the shortcut's number *is*
  what Health shows. The export fills only the days it does not have.
- **Sleep takes one source per night**, the one with the most asleep
  minutes, so a Watch and a sleep app do not double a night. A night is
  filed under its wake-up day: the date of the sample's end shifted six
  hours forward, which is Health's own 18:00-to-18:00 sleep day.
- **Workouts, both shapes.** Before iOS 16 `totalDistance` and
  `totalEnergyBurned` were attributes; since then they are
  `<WorkoutStatistics>` children with a `sum`. Both are read, the child
  wins. Average heart rate comes from the HeartRate statistics child. The
  first `<trkpt>` of the route's GPX gives the workout a coordinate.
- **The same archive imported twice changes nothing.** Workouts key on
  type, start and source; days and nights on their date.

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

**B loads the history. A keeps it current.** That is what the plugin does:
`import` for B, `sync` for A, one store for both. D would be A with the
shortcut already written, for money; nothing reads its format.

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
