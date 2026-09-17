# AppleTools Health — the iPhone half of the `health` plugin

🛑 **There is no Health data on a Mac** ([`docs/apple-health.md`](../../../docs/apple-health.md)),
so this app runs on the iPhone, reads Health, and writes text files into
its own iCloud container. The Mac plugin, `../apple-plugin-health`, reads
them from

```
~/Library/Mobile Documents/iCloud~com~boulderhopkins~apple-tools~health/Documents/health/
```

Nothing here talks to anything but Health and iCloud Drive. It never writes
to Health (`toShare: []`).

## What it does

- **Export the last 8 days** → `health-<today>.txt`. One `day` row per day
  per metric (Health's own totals, via `HKStatisticsCollectionQuery`), raw
  `sample` rows for sleep, one `workout` row per workout with the route's
  first point.
- **Export everything** → `health-<year>.txt` per year, from the earliest
  step sample. The full history in one tap; the export archive is no longer
  needed for it.
- **Export daily in the background** → an `HKObserverQuery` on steps with
  daily background delivery, plus a `BGAppRefreshTask`. Either runs the
  8-day export when the last one is over 20 h old. ⚠️ iOS decides the
  moment. Read the log before concluding it did not run.
- **The log** — every run, every count, every error by name — in the app
  and mirrored to `log.txt` beside the files, so `apple health log` shows
  the same lines on the Mac.

The file format is defined once, on the Mac side, in
`apple-plugin-health` (`METRICS`, `SLEEP_STAGES`, `parse_workout_row`).
`Sources/Format.swift` writes those labels and units verbatim.

## Build and install

```
brew install xcodegen          # once
xcodegen generate
xcodebuild -project AppleToolsHealth.xcodeproj -scheme AppleToolsHealth \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl list devices   # the phone's identifier
xcrun devicectl device install app --device <id> \
    ~/Library/Developer/Xcode/DerivedData/AppleToolsHealth-*/Build/Products/Debug-iphoneos/AppleToolsHealth.app
```

- `-allowProvisioningUpdates` registers the App ID with HealthKit and the
  iCloud container on the developer account and makes the profile. It
  worked first time here (2026-09-17, Xcode 27.0, team 25RCAA3JLJ).
- **The phone must be unlocked** for `devicectl … install`; a locked phone
  fails with error 10003 and the loop in the session just retries.
- A development-signed build expires with its profile (a year on a paid
  account, a week on a free one). Rebuild and reinstall; the container and
  the log survive.
- ⚠️ It is not in `make dist` or the app bundle. It is source, built by
  hand for one phone.
