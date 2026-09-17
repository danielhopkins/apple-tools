#!/usr/bin/env python3
"""Offline checks for apple-plugin-health.

Nothing here touches iCloud Drive, plugins.json or the real store: the
plugin is pointed at a temp folder and a temp store, a daily file is written
in the shape the shortcut writes, and an export.zip is built with the
element shapes from docs/apple-health.md. The shortcut itself is rebuilt
unsigned and checked against the plugin's own label table, so the phone
half and the Mac half cannot drift apart.

    ./test-health.py
"""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "apple-plugin-health")
BUILDER = os.path.join(HERE, "build-shortcut.py")

FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


def run(args, env, expect=0):
    proc = subprocess.run([PLUGIN] + args, capture_output=True, text=True, env=env)
    if proc.returncode != expect:
        FAILED.append("%s exited %d (want %d)\n%s" % (" ".join(args), proc.returncode, expect,
                                                      proc.stderr.strip()))
    return proc


DAILY = """apple-tools health 1
generated\t2026-09-16 07:02:11 -0600
window\t8
day\tSteps\t2026-09-14 00:00:00 -0600\t2026-09-15 00:00:00 -0600\t8,412\tcount
day\tSteps\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t10,015\tcount
day\tSteps\t2026-09-16 00:00:00 -0600\t2026-09-17 00:00:00 -0600\t612\tcount
day\tWalking + Running Distance\t2026-09-14 00:00:00 -0600\t2026-09-15 00:00:00 -0600\t3.2\tmi
day\tCycling Distance\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t12.5\tmi
day\tActive Calories\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t612\tkcal
day\tExercise Time\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t48\tmin
day\tResting Heart Rate\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t57\tcount/min
day\tHeart Rate Variability\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t41\tms
day\tWeight\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t181.2\tlb
day\tFlights Climbed\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t9\tcount
sample\tSleep\t2026-09-14 22:40:00 -0600\t2026-09-14 23:10:00 -0600\tAsleep Core\tcount
sample\tSleep\t2026-09-14 23:10:00 -0600\t2026-09-15 00:40:00 -0600\tAsleep Deep\tcount
sample\tSleep\t2026-09-15 00:40:00 -0600\t2026-09-15 05:40:00 -0600\tAsleep Core\tcount
sample\tSleep\t2026-09-15 05:40:00 -0600\t2026-09-15 06:00:00 -0600\tAwake\tcount
sample\tSleep\t2026-09-15 06:00:00 -0600\t2026-09-15 06:30:00 -0600\tAsleep REM\tcount
day\tSteps\t2026-09-13 00:00:00 -0600\t2026-09-14 00:00:00 -0600\tnot a number\tcount
day\tOxygen Saturation\t2026-09-15 00:00:00 -0600\t2026-09-16 00:00:00 -0600\t97\tfurlongs
"""

EXPORT_XML = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE HealthData [ <!ELEMENT HealthData (ExportDate,Me,(Record|Workout|ActivitySummary)*)> ]>
<HealthData locale="en_US">
 <ExportDate value="2026-09-16 08:00:00 -0600"/>
 <Me HKCharacteristicTypeIdentifierBiologicalSex="HKBiologicalSexMale"/>
 <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Watch" unit="count" startDate="2026-09-10 07:00:00 -0600" endDate="2026-09-10 07:10:00 -0600" value="500"/>
 <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Watch" unit="count" startDate="2026-09-10 08:00:00 -0600" endDate="2026-09-10 08:10:00 -0600" value="700"/>
 <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-09-10 07:00:00 -0600" endDate="2026-09-10 07:10:00 -0600" value="450"/>
 <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2026-09-10 08:00:00 -0600" endDate="2026-09-10 08:10:00 -0600" value="650"/>
 <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Watch" unit="count" startDate="2026-09-15 07:00:00 -0600" endDate="2026-09-15 07:10:00 -0600" value="99999"/>
 <Record type="HKQuantityTypeIdentifierDistanceCycling" sourceName="Watch" unit="km" startDate="2026-09-10 17:00:00 -0600" endDate="2026-09-10 18:00:00 -0600" value="20.5"/>
 <Record type="HKQuantityTypeIdentifierRestingHeartRate" sourceName="Watch" unit="count/min" startDate="2026-09-10 12:00:00 -0600" endDate="2026-09-10 12:00:00 -0600" value="56"/>
 <Record type="HKQuantityTypeIdentifierRestingHeartRate" sourceName="Watch" unit="count/min" startDate="2026-09-10 18:00:00 -0600" endDate="2026-09-10 18:00:00 -0600" value="60"/>
 <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Scale" unit="lb" startDate="2026-09-10 06:00:00 -0600" endDate="2026-09-10 06:00:00 -0600" value="180"/>
 <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Scale" unit="lb" startDate="2026-09-10 20:00:00 -0600" endDate="2026-09-10 20:00:00 -0600" value="182"/>
 <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2026-09-09 23:00:00 -0600" endDate="2026-09-10 03:00:00 -0600" value="HKCategoryValueSleepAnalysisAsleepCore"/>
 <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Watch" startDate="2026-09-10 03:00:00 -0600" endDate="2026-09-10 06:00:00 -0600" value="HKCategoryValueSleepAnalysisAsleepDeep"/>
 <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="iPhone" startDate="2026-09-09 22:30:00 -0600" endDate="2026-09-10 06:30:00 -0600" value="HKCategoryValueSleepAnalysisInBed"/>
 <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Watch" unit="count/min" startDate="2026-09-10 12:00:00 -0600" endDate="2026-09-10 12:00:00 -0600" value="70"/>
 <Workout workoutActivityType="HKWorkoutActivityTypeCycling" duration="61.5" durationUnit="min" sourceName="Watch" startDate="2026-09-10 17:00:00 -0600" endDate="2026-09-10 18:01:30 -0600">
  <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceCycling" startDate="2026-09-10 17:00:00 -0600" endDate="2026-09-10 18:01:30 -0600" sum="20.5" unit="km"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" startDate="2026-09-10 17:00:00 -0600" endDate="2026-09-10 18:01:30 -0600" sum="612" unit="kcal"/>
  <WorkoutStatistics type="HKQuantityTypeIdentifierHeartRate" startDate="2026-09-10 17:00:00 -0600" endDate="2026-09-10 18:01:30 -0600" average="141" minimum="90" maximum="170" unit="count/min"/>
  <WorkoutRoute sourceName="Watch" startDate="2026-09-10 17:00:00 -0600" endDate="2026-09-10 18:01:30 -0600">
   <FileReference path="/workout-routes/route_2026-09-10_5.00pm.gpx"/>
  </WorkoutRoute>
 </Workout>
 <Workout workoutActivityType="HKWorkoutActivityTypeRunning" duration="30" durationUnit="min" totalDistance="3.1" totalDistanceUnit="mi" totalEnergyBurned="300" totalEnergyBurnedUnit="kcal" sourceName="Strava" startDate="2026-08-01 06:00:00 -0600" endDate="2026-08-01 06:30:00 -0600"/>
 <ActivitySummary dateComponents="2026-09-10" activeEnergyBurned="612"/>
</HealthData>
"""

GPX = """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Apple Health Export" xmlns="http://www.topografix.com/GPX/1/1">
 <trk><name>Route 2026-09-10 5:00pm</name><trkseg>
  <trkpt lon="-105.2705" lat="40.0150"><ele>1655</ele><time>2026-09-10T23:00:42Z</time></trkpt>
  <trkpt lon="-105.2710" lat="40.0155"><ele>1656</ele><time>2026-09-10T23:00:52Z</time></trkpt>
 </trkseg></trk>
</gpx>
"""


def main():
    tmp = tempfile.mkdtemp(prefix="apple-health-test-")
    folder = os.path.join(tmp, "health")
    os.makedirs(folder)
    env = dict(os.environ, APPLE_HEALTH_STORE=os.path.join(tmp, "store.sqlite"),
               APPLE_HEALTH_FOLDER=folder, APPLE_PLUGINS_BIN="/usr/bin/false")

    # -- the manifest and an empty status ------------------------------------
    manifest = json.loads(run(["manifest"], env).stdout)
    check("manifest name", manifest["name"], "health")
    check("manifest has no hosts", manifest["network"]["hosts"], [])
    check("manifest kinds", manifest["index"]["kinds"], ["day", "workout"])
    status = json.loads(run(["status", "--json"], env).stdout)
    check("empty status", (status["status"], status["usable"]), ("unconfigured", False))
    run(["status"], env, expect=1)

    # -- the shortcut and the plugin agree on every label ---------------------
    out = subprocess.run([sys.executable, BUILDER, "--out", tmp, "--no-sign"],
                         capture_output=True, text=True)
    check("builder exits 0", out.returncode, 0)
    with open(os.path.join(tmp, "Apple Tools Health Export.unsigned.shortcut"), "rb") as f:
        shortcut = plistlib.load(f)
    labels = []
    for act in shortcut["WFWorkflowActions"]:
        if act["WFWorkflowActionIdentifier"] == "is.workflow.actions.filter.health.quantity":
            rows = act["WFWorkflowActionParameters"]["WFContentItemFilter"]["Value"]["WFActionParameterFilterTemplates"]
            labels.append(rows[0]["Values"]["Enumeration"]["Value"])
            check("date row is 'in the last N days'", (rows[1]["Operator"], rows[1]["Values"]["Unit"]), (1001, 16))
    src = open(PLUGIN).read()
    for label in labels:
        check("plugin knows label %r" % label, ('"%s"' % label) in src, True)
    check("Sleep is a raw block", "Sleep" in labels, True)
    grouped = [a for a in shortcut["WFWorkflowActions"]
               if a["WFWorkflowActionIdentifier"] == "is.workflow.actions.filter.health.quantity"
               and a["WFWorkflowActionParameters"].get("WFHKSampleFilteringGroupBy") == "Day"]
    check("every block but Sleep groups by day", len(grouped), len(labels) - 1)
    saves = [a for a in shortcut["WFWorkflowActions"]
             if a["WFWorkflowActionIdentifier"] == "is.workflow.actions.documentpicker.save"]
    check("one Save File", len(saves), 1)
    check("save does not ask", saves[0]["WFWorkflowActionParameters"]["WFAskWhereToSave"], False)
    # Every output reference names an action that exists before it.
    uuids = set()
    for act in shortcut["WFWorkflowActions"]:
        params = act["WFWorkflowActionParameters"]
        text = json.dumps(params, default=str)
        for ref in set(__import__("re").findall(r'"OutputUUID": "([0-9A-F-]+)"', text)):
            check("reference %s is to an earlier action" % ref, ref in uuids, True)
        if "UUID" in params:
            uuids.add(params["UUID"])

    # -- a daily file ----------------------------------------------------------
    with open(os.path.join(folder, "health-2026-09-16.txt"), "w") as f:
        f.write(DAILY)
    with open(os.path.join(folder, "health-notes.txt"), "w") as f:
        f.write("not a health file\n")
    report = json.loads(run(["sync", "--json"], env).stdout)
    check("one file read", len(report["files"]), 1)
    check("three days", report["files"][0]["days"], 3)   # 14, 15, 16; the 13th has only a bad line
    check("one night", report["nights"], 1)
    problems = "\n".join(report["problems"])
    check("bad number is named", "not a number" in problems, True)
    check("bad unit is named", "furlongs" in problems, True)
    check("stray file is named", "health-notes.txt" in problems, True)
    check("absent types are named", "no lines for: Swimming Distance, Stand Time" in problems, True)

    days = {d["date"]: d for d in json.loads(run(["days", "--from", "2026-09-01", "--to", "2026-09-30", "--json"], env).stdout)}
    check("steps read with a thousands comma", days["2026-09-15"]["steps"], 10015.0)
    check("miles to metres", days["2026-09-15"]["cycling_distance"], round(12.5 * 1609.344, 2))
    check("pounds to kg", days["2026-09-15"]["weight"], round(181.2 * 0.453592, 2))
    check("bpm kept", days["2026-09-15"]["resting_heart_rate"], 57.0)
    check("today is partial", days["2026-09-16"]["partial"], True)
    check("yesterday is not", days["2026-09-15"]["partial"], False)
    night = days["2026-09-15"]["sleep"]
    check("asleep = core + deep + rem", night["asleep"], 30 + 90 + 300 + 30.0)
    check("awake is separate", night["awake"], 20.0)
    check("night ends on the 15th", night["end"][:10], "2026-09-15")
    check("bad steps line dropped, day 13 has no steps", "steps" in days.get("2026-09-13", {}), False)

    # A second run reads nothing; a changed file is read again.
    report = json.loads(run(["sync", "--json"], env).stdout)
    check("nothing new", report["files"], [])
    with open(os.path.join(folder, "health-2026-09-16.txt"), "a") as f:
        f.write("day\tSteps\t2026-09-16 00:00:00 -0600\t2026-09-17 00:00:00 -0600\t4,000\tcount\n")
    report = json.loads(run(["sync", "--json"], env).stdout)
    check("changed file re-read", len(report["files"]), 1)
    days = {d["date"]: d for d in json.loads(run(["days", "--since", "30", "--json"], env).stdout)}
    check("later line wins", days["2026-09-16"]["steps"], 4000.0)

    # -- the export archive ----------------------------------------------------
    archive = os.path.join(tmp, "export.zip")
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("apple_health_export/export.xml", EXPORT_XML)
        z.writestr("apple_health_export/export_cda.xml", "<ClinicalDocument/>")
        z.writestr("apple_health_export/workout-routes/route_2026-09-10_5.00pm.gpx", GPX)
    report = json.loads(run(["import", archive, "--json"], env).stdout)
    check("records counted", report["records"], 14)
    check("two workouts", report["workouts"], 2)
    check("one night from the export", report["nights"], 1)
    check("day 15 kept from the shortcut", report["days_kept_from_shortcut"] > 0, True)

    days = {d["date"]: d for d in json.loads(run(["days", "--from", "2026-09-01", "--to", "2026-09-30", "--json"], env).stdout)}
    check("steps: largest source, not the sum", days["2026-09-10"]["steps"], 1200.0)
    check("shortcut day outranks the export", days["2026-09-15"]["steps"], 10015.0)
    check("resting HR is a mean", days["2026-09-10"]["resting_heart_rate"], 58.0)
    check("weight is the last of the day", days["2026-09-10"]["weight"], round(182 * 0.453592, 2))
    check("cycling km to m", days["2026-09-10"]["cycling_distance"], 20500.0)
    night = days["2026-09-10"]["sleep"]
    check("export night: watch stages win over phone in-bed", night["asleep"], 420.0)
    check("in bed from the watch source only", night["in_bed"], None)

    workouts = json.loads(run(["workouts", "--from", "2026-01-01", "--to", "2026-12-31", "--json"], env).stdout)
    check("workouts sorted", [w["type"] for w in workouts], ["Running", "Cycling"])
    ride = workouts[1]
    check("statistics child distance", ride["distance"], 20500.0)
    check("statistics energy", ride["energy"], 612.0)
    check("average heart rate", ride["heart_rate"], 141.0)
    check("duration in seconds", ride["duration"], 61.5 * 60)
    check("route first point", (ride["latitude"], ride["longitude"]), (40.015, -105.2705))
    run_ = workouts[0]
    check("attribute distance in miles", run_["distance"], round(3.1 * 1609.344, 10))
    check("no route, no coordinate", run_["latitude"], None)
    only = json.loads(run(["workouts", "--from", "2026-01-01", "--to", "2026-12-31", "--type", "cycl", "--json"], env).stdout)
    check("--type filters", len(only), 1)

    # Importing the same archive twice does not double anything.
    run(["import", archive, "--json"], env)
    workouts = json.loads(run(["workouts", "--from", "2026-01-01", "--to", "2026-12-31", "--json"], env).stdout)
    check("import is idempotent", len(workouts), 2)

    # -- index -----------------------------------------------------------------
    lines = [json.loads(l) for l in run(["index"], env).stdout.splitlines() if l.strip()]
    fields = ["uid", "tool", "kind", "native_id", "url", "title", "container", "created",
              "modified", "occurred", "latitude", "longitude", "people", "body", "rev"]
    for rec in lines:
        check("record %s has every field" % rec.get("uid"), sorted(rec), sorted(fields))
        check("tool is health", rec["tool"], "health")
    kinds = {}
    for rec in lines:
        kinds[rec["kind"]] = kinds.get(rec["kind"], 0) + 1
    check("day records", kinds.get("day"), 4)      # 10, 14, 15, 16
    check("workout records", kinds.get("workout"), 2)
    day15 = next(r for r in lines if r["uid"] == "health:day:2026-09-15")
    check("container is the year", day15["container"], "2026")
    check("title names the day", day15["title"].startswith("Tue 15 Sep 2026: 10,015 steps"), True)
    check("body carries the ride", "cycled 20.1 km (12.5 mi)" in day15["body"], True)
    check("body carries sleep", "slept 7h 30m" in day15["body"], True)
    ride = next(r for r in lines if r["kind"] == "workout" and "Cycling" in r["title"])
    check("workout has a coordinate", ride["latitude"], 40.015)
    check("workout title", ride["title"], "Cycling, 1h 02m, 20.5 km")
    since = [json.loads(l) for l in run(["index", "--since", "3"], env).stdout.splitlines() if l.strip()]
    check("--since narrows", len(since) < len(lines), True)

    status = json.loads(run(["status", "--json"], env).stdout)
    check("status ok", (status["status"], status["usable"]), ("ok", True))
    check("status counts workouts", status["workouts"], 2)

    if FAILED:
        print("FAILED %d:" % len(FAILED))
        for f in FAILED:
            print("  -", f)
        return 1
    print("apple-plugin-health: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
