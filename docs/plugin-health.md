# health — `apple health` (plugin)

CLAUDE.md points here. This file is the working reference for the `health` plugin. The plugin contract is in [`apple-plugins.md`](apple-plugins.md).

🛑 **There is no Health data on a Mac** — HealthKit refuses every call, no
signing changes it, no local store exists
([`docs/apple-health.md`](apple-health.md)). So this plugin reads two
files the **iPhone** puts in iCloud Drive, keeps them in its own SQLite
store, and makes no connection at all. Python, stdlib only, in
`plugins/health/`; tested offline by `plugins/health/test-health.py`.

```
apple health sync [--json]             # read new files the iPhone app wrote
apple health samples --type T [--since DAYS | --from DATE --to DATE] [--limit N] [--json]
apple health trend METRIC [--by day|week|month|year] [--since DAYS | --from DATE --to DATE] [--json]
apple health clinical [--type labs|vaccines|medications|conditions|allergies|procedures|vitals|coverage]
                      [--search TEXT] [--since DAYS] [--fhir] [--json]
apple health sql "SELECT …" [--limit N] [--json]     # read-only; --schema prints the tables
apple health log [--tail N] [--json]   # the iPhone app's own log, as it wrote it
apple health import export.zip         # the Health export archive, the optional route
apple health shortcut [--to DIR]       # the fallback shortcut, into iCloud Drive
apple health days [--since DAYS | --from DATE --to DATE] [--json]
apple health workouts [--since DAYS | --from DATE --to DATE] [--type TEXT] [--json]
apple health status [--json]
apple health index [--since DAYS]      # what apple-index calls; runs sync first
```

- 🛑 **The files come from the AppleTools Health app on the iPhone**,
  `plugins/health/ios/`, a SwiftUI app with the HealthKit entitlement that
  the Mac cannot hold. It writes `health-<date>.txt` (last 8 days) and
  `health-<year>.txt` (everything) into its own iCloud container, plus a
  `log.txt` that `apple health log` prints. Built with xcodegen, installed
  over the pairing with `devicectl`; the phone must be unlocked. Nothing on
  a Mac can trigger a run; the app's background toggle runs one a day.
- ⚠️ **A shortcut was built first and is kept as a fallback**
  (`build-shortcut.py`, `apple health shortcut`). Its one run produced no
  file and no error, which is why the app exists. No shortcut can read
  workouts at all: the Shortcuts health sample wraps a quantity or a
  category sample and nothing else (picker list read in full from the iOS
  27 binary). The export archive (`apple health import export.zip`) is the
  third route and is now optional.
- 🛑 **A day's steps in the export are NOT the sum of its step records.**
  The iPhone and the Watch both count the same walk. `import` sums per
  source per day and takes the largest source; the shortcut's number is
  Health's own total and always wins for a day it covers.
- **A night belongs to the morning.** A sleep sample is filed under the
  date of its end shifted six hours forward — Health's 18:00-to-18:00 sleep
  day — so a stage ending at 23:10 joins the night that ends at 06:30.
  `asleep` is every asleep stage together; `in_bed` and `awake` sit beside
  it. The export keeps one source per night, the one with the most sleep.
- ⚠️ **Units follow the phone.** `mi` here, `km` elsewhere; the plugin
  stores metres, kcal, minutes, bpm, ms and kg, and a unit it does not know
  fails the line naming it. A number arrives in the phone's locale
  (`8,412`) and commas are stripped.
- ⚠️ **Today is partial** until tomorrow's file replaces it; the record
  body says "day not over when written". `sync` names every type a file
  carried no line for, which is how a wrong picker label shows up on the Mac.
- 🛑 **THE RAW STORE IS THE PLACE TO ANSWER A HEALTH QUESTION, not the
  index.** `~/Library/Application Support/apple-tools/health/health.sqlite`
  holds five tables: `day` (Health's own daily figures, one row per day
  per metric), `sleep` (one row per night), `workout`, `sample` (every raw
  reading — heart rate, HRV, SpO2, respiratory rate, blood pressure, weight,
  body fat, glucose, temperature; measured here 2015–2026), and `clinical`
  (labs, immunizations, medications, conditions, allergies, procedures,
  vitals, coverage, each as its FHIR resource). `trend` averages a metric
  per week, month or year; `samples` lists readings; `clinical` summarises
  a record from its FHIR (value, reference range, vaccine, dose); `sql`
  takes any SELECT, opens the store read-only, and refuses anything else.
  ⚠️ `trend hrv` reads the DAILY figure; pass the HealthKit identifier
  (`HKQuantityTypeIdentifierHeartRateVariabilitySDNN`) for the raw readings.
- **Every dated JSON record carries `date`**, in both plugins: a workout's and
  a sample's equal `start`, a visit's `started`, a point's `at`. The source's
  own names stay beside it. A caller's `jq '.[].date'` on workouts once read
  `null` for all 327 and reported "workouts have no dates". Each subcommand's
  `--help` ends with its JSON fields and units — keep those in step with the
  output (`JSON_FIELDS` in each plugin).
- **Units in the store are canonical**: metres, kcal, minutes, count/min,
  ms, kg, mmHg, mg/dL, degC, and `%` as Health returns it — oxygen
  saturation is a fraction (0.95), body fat too. Say the unit.
- **Clinical records exist only when a provider is connected in the
  Health app**, and the entitlement is US-only. An empty `clinical` table
  means no provider, not no health. The app's log says how many came.
- **Index kinds**: `day`, `workout`, and one per clinical kind (`lab`,
  `immunization`, `medication`, …), so "tetanus shot" is searchable. Raw
  samples are never indexed. 🛑 **A workout with a route IS PRESENCE**:
  `whereabouts` reads `workout` records as a source at weight 0.90 (the
  user's own watch, a GPS route, a time), and `places` counts workouts that
  started within 250 m of a place in `<tool>_workouts` — a fifth unit,
  never added to days, arrivals or stays. Measured: 1,596 of 1,707 workouts
  land on a known place, 1,156 of them at home.
