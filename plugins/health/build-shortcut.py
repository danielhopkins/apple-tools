#!/usr/bin/env python3
"""Build "Apple Tools Health Export.shortcut", the iPhone half of the plugin.

🛑 THERE IS NO HEALTH DATA ON A MAC (docs/apple-health.md), so the plugin
reads a text file, and this shortcut is what writes it. It runs on the
iPhone, asks Health for the last few days of a fixed set of types, one line
per day per type, and saves the result to iCloud Drive, where the Mac reads
it. Nothing here leaves the phone except into the user's own iCloud Drive.

The serialization is not documented. Every action shape here was read out of
a real iOS shortcut export (a heart-rate exporter from the public
My-Siri-Shortcuts repository) and the iOS 27 ActionKit binary in the
simulator runtime, which carries the picker labels and the parameter keys:

  is.workflow.actions.filter.health.quantity   Find Health Samples
    WFContentItemFilter   `Type is <label>` (Operator 4) and
                          `Start Date is in the last N days` (Operator 1001,
                          Unit 16 = day)
    WFHKSampleFilteringGroupBy   "Day" gives Health's OWN daily totals, the
                          number the Health app shows, deduplicated across
                          the iPhone and the Watch. Raw samples double-count.
    WFHKSampleFilteringFillMissing   false; a day with no data is no line
  is.workflow.actions.properties.health.quantity   Get Details of Health Sample
    WFContentItemPropertyName   Type, Value, Unit, Start Date, End Date,
                          Duration, Source — the seven the content item has
  is.workflow.actions.format.date   Custom, ICU pattern
  is.workflow.actions.documentpicker.save   Save File

⚠️ WORKOUTS ARE NOT REACHABLE THIS WAY. WFHKSampleContentItem wraps an
HKQuantitySample or an HKCategorySample and nothing else; the picker has no
"Workouts" row (the iOS 27 ActionKit list was read in full). Workouts come
from the Health export archive, which `apple health import` reads.

⚠️ The type labels are the readable names ActionKit maps HealthKit
identifiers to, not the Health app's display names. "Active Calories" is the
label for ActiveEnergyBurned, and "Exercise Time" for AppleExerciseTime.
"Sleep" is the one label not in that table: Sleep Analysis is special-cased
in ActionKit, and "Sleep" is what a real iOS export carried.

    ./build-shortcut.py                # writes the unsigned and the signed file
    ./build-shortcut.py --days 14      # a longer window

The file format the shortcut writes is the one `apple-plugin-health` parses;
FORMAT below is the single description of it, and the plugin imports it.
"""
import argparse
import os
import plistlib
import subprocess
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "Apple Tools Health Export"

# Grouped by day: one line per day per type, Health's own total or average.
# (label in the Find Health Samples picker, key the plugin stores it under)
DAILY = [
    ("Steps", "steps"),
    ("Walking + Running Distance", "walk_run_distance"),
    ("Cycling Distance", "cycling_distance"),
    ("Swimming Distance", "swimming_distance"),
    ("Active Calories", "active_energy"),
    ("Exercise Time", "exercise_minutes"),
    ("Stand Time", "stand_minutes"),
    ("Flights Climbed", "flights"),
    ("Resting Heart Rate", "resting_heart_rate"),
    ("Heart Rate Variability", "hrv"),
    ("Walking Heart Rate Average", "walking_heart_rate"),
    ("Oxygen Saturation", "oxygen_saturation"),
    ("VO2 Max", "vo2_max"),
    ("Weight", "weight"),
]
# Raw samples: a night is many samples with a stage each, and the plugin
# adds them up per wake-up day. Grouping by day would put a night that
# starts at 23:00 on the wrong day.
RAW = [
    ("Sleep", "sleep"),
]

DATE_FORMAT = "yyyy-MM-dd HH:mm:ss Z"     # 2026-09-15 07:25:44 -0600
FILE_DATE_FORMAT = "yyyy-MM-dd"
FOLDER = "apple-tools/health"             # under iCloud Drive
FORMAT_VERSION = "1"


def uid():
    return str(uuid.uuid4()).upper()


def output(uuid_str, name):
    """An earlier action's output, as a non-text parameter value."""
    return {"Value": {"OutputUUID": uuid_str, "Type": "ActionOutput", "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}


def repeat_item():
    return {"Value": {"Type": "Variable", "VariableName": "Repeat Item"},
            "WFSerializationType": "WFTextTokenAttachment"}


def text(parts):
    """A WFTextTokenString from literal strings and (uuid, name) outputs.

    Each output becomes one U+FFFC in the string, and `attachmentsByRange`
    maps its position to the action it came from.
    """
    string = ""
    ranges = {}
    for part in parts:
        if isinstance(part, str):
            string += part
        else:
            ranges["{%d, 1}" % len(string)] = {
                "OutputUUID": part[0], "Type": "ActionOutput", "OutputName": part[1]}
            string += "￼"
    value = {"string": string}
    if ranges:
        value["attachmentsByRange"] = ranges
    return {"Value": value, "WFSerializationType": "WFTextTokenString"}


def action(identifier, params):
    return {"WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": params}


def find_samples(label, days, group_by_day):
    """Find Health Samples: `Type is <label>`, `Start Date is in the last N
    days`, oldest first, no limit."""
    params = {
        "UUID": uid(),
        "WFContentItemFilter": {
            "Value": {
                "WFActionParameterFilterPrefix": 1,
                "WFContentPredicateBoundedDate": False,
                "WFActionParameterFilterTemplates": [
                    {"Bounded": True, "Operator": 4, "Property": "Type",
                     "Removable": False,
                     "Values": {"Enumeration": {
                         "Value": label,
                         "WFSerializationType": "WFStringSubstitutableState"}}},
                    {"Bounded": True, "Operator": 1001, "Property": "Start Date",
                     "Removable": False,
                     "Values": {"Number": days, "Unit": 16}},
                ],
            },
            "WFSerializationType": "WFContentPredicateTableTemplate",
        },
        "WFContentItemSortProperty": "Start Date",
        "WFContentItemSortOrder": "Oldest First",
        "WFContentItemLimitEnabled": False,
        "WFContentItemLimitNumber": 20,
        "WFHKSampleFilteringFillMissing": False,
    }
    if group_by_day:
        params["WFHKSampleFilteringGroupBy"] = "Day"
    return action("is.workflow.actions.filter.health.quantity", params)


def detail(name, custom=None):
    params = {"UUID": uid(), "WFContentItemPropertyName": name, "WFInput": repeat_item()}
    if custom:
        params["CustomOutputName"] = custom
    return action("is.workflow.actions.properties.health.quantity", params)


def format_date(source_uuid, source_name, pattern):
    return action("is.workflow.actions.format.date", {
        "UUID": uid(),
        "WFDate": text([(source_uuid, source_name)]),
        "WFDateFormatStyle": "Custom",
        "WFDateFormat": pattern,
        "WFTimeFormatStyle": "Short",
    })


def get_text(parts):
    return action("is.workflow.actions.gettext", {"UUID": uid(), "WFTextActionText": text(parts)})


def puid(act):
    return act["WFWorkflowActionParameters"]["UUID"]


def block(kind, label, days, group_by_day):
    """One Find, one loop, one line per sample. Returns (actions, results uuid).

    The line is  <kind> TAB <label> TAB <start> TAB <end> TAB <value> TAB <unit>
    """
    find = find_samples(label, days, group_by_day)
    group = uid()
    start = detail("Start Date", "Start")
    start_f = format_date(puid(start), "Start", DATE_FORMAT)
    end = detail("End Date", "End")
    end_f = format_date(puid(end), "End", DATE_FORMAT)
    value = detail("Value", "Value")
    unit = detail("Unit", "Unit")
    line = get_text([kind, "\t", label, "\t",
                     (puid(start_f), "Formatted Date"), "\t",
                     (puid(end_f), "Formatted Date"), "\t",
                     (puid(value), "Value"), "\t",
                     (puid(unit), "Unit")])
    end_repeat_uuid = uid()
    combined = action("is.workflow.actions.text.combine", {
        "UUID": uid(), "WFTextSeparator": "New Lines",
        "text": output(end_repeat_uuid, "Repeat Results")})
    actions = [
        find,
        action("is.workflow.actions.repeat.each", {
            "GroupingIdentifier": group, "WFControlFlowMode": 0,
            "WFInput": {
                "Value": {"OutputUUID": puid(find), "Type": "ActionOutput",
                          "OutputName": "Health Samples",
                          "Aggrandizements": [{"CoercionItemClass": "WFHKSampleContentItem",
                                               "Type": "WFCoercionVariableAggrandizement"}]},
                "WFSerializationType": "WFTextTokenAttachment"}}),
        start, start_f, end, end_f, value, unit, line,
        action("is.workflow.actions.repeat.each", {
            "GroupingIdentifier": group, "WFControlFlowMode": 2, "UUID": end_repeat_uuid}),
        combined,
    ]
    return actions, puid(combined)


def build(days):
    actions = []
    sections = []
    for label, _ in DAILY:
        acts, result = block("day", label, days, True)
        actions += acts
        sections.append(result)
    for label, _ in RAW:
        acts, result = block("sample", label, days, False)
        actions += acts
        sections.append(result)

    now = action("is.workflow.actions.date", {"UUID": uid(), "WFDateActionMode": "Current Date"})
    now_f = format_date(puid(now), "Date", DATE_FORMAT)
    file_f = format_date(puid(now), "Date", FILE_DATE_FORMAT)
    parts = ["apple-tools health ", FORMAT_VERSION, "\n",
             "generated\t", (puid(now_f), "Formatted Date"), "\n",
             "window\t", str(days), "\n"]
    for result in sections:
        parts += [(result, "Combined Text"), "\n"]
    body = get_text(parts)
    save = action("is.workflow.actions.documentpicker.save", {
        "UUID": uid(),
        "WFInput": output(puid(body), "Text"),
        "WFAskWhereToSave": False,
        "WFSaveFileOverwrite": True,
        "WFFileDestinationPath": text(["/", FOLDER, "/health-", (puid(file_f), "Formatted Date"), ".txt"]),
    })
    actions += [now, now_f, file_f, body, save]

    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "3100.0.4.2",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4292093695,
                           "WFWorkflowIconGlyphNumber": 59843},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowNoInputBehavior": {"Name": "WFWorkflowNoInputBehaviorShowError",
                                      "Parameters": {}},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--days", type=int, default=8,
                        help="how many days back each run reads (default 8)")
    parser.add_argument("--out", default=HERE, help="directory to write into")
    parser.add_argument("--no-sign", action="store_true")
    opts = parser.parse_args()

    unsigned = os.path.join(opts.out, NAME + ".unsigned.shortcut")
    signed = os.path.join(opts.out, NAME + ".shortcut")
    with open(unsigned, "wb") as f:
        plistlib.dump(build(opts.days), f)
    print("wrote %s (%d actions)" % (unsigned, len(build(opts.days)["WFWorkflowActions"])))
    if opts.no_sign:
        return 0
    # `--mode anyone` is what lets a phone that never saw this Mac import it.
    proc = subprocess.run(["shortcuts", "sign", "--mode", "anyone",
                           "--input", unsigned, "--output", signed],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print("sign failed: %s" % (proc.stderr.strip() or proc.stdout.strip()), file=sys.stderr)
        return 1
    print("signed %s" % signed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
