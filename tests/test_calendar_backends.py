"""The same behaviour, asserted against every calendar backend on this Mac.

Exchange, calDAV (Google, iCloud, and anything else CalDAV-shaped) and a local
store are meant to be indistinguishable through this tool's abstractions. They
have not always been: the EKSpan bugs fixed in 26.812.1 and 26.812.3 behaved
identically everywhere, but *what the server does afterwards* does not —
Google rewrites an attendee's role and status where Exchange leaves both
`unknown`, and the two format invitation mail differently.

So this module runs one shared set of assertions per backend and reports which
backend failed, rather than testing whichever calendar happened to be default.

🛑 **Nothing here writes an invitee.** That would mail a real person once per
backend. Invitee behaviour across backends is measured by hand and recorded in
docs/apple-calendar-invitees.md.

Gated separately from the main calendar suite because it writes to *every*
writable calendar rather than one:

    ./tests/run-tests --backends
"""

import calendar as calendar_module
import datetime
import os
import unittest

from harness import (
    TEST_PREFIX,
    BACKENDS_ENV,
    find_test_events,
    near_future,
    near_window,
    run,
    run_json,
    sweep,
    writable_backends,
)

BASE = near_future(month_offset=2)


def _fourth_monday(year, month):
    days = [
        datetime.date(year, month, d)
        for d in range(1, calendar_module.monthrange(year, month)[1] + 1)
    ]
    return [d for d in days if d.weekday() == 0][3]


class BackendMatrixTest(unittest.TestCase):
    """Runs every check against every writable backend."""

    @classmethod
    def setUpClass(cls):
        if os.environ.get(BACKENDS_ENV) != "1":
            raise unittest.SkipTest(
                f"backend matrix is gated; run ./tests/run-tests --backends"
            )
        cls.backends = writable_backends()
        if not cls.backends:
            raise unittest.SkipTest("no writable calendars")
        sweep()

    @classmethod
    def tearDownClass(cls):
        sweep()

    def tearDown(self):
        sweep()

    # -- helpers ----------------------------------------------------------- #

    def add(self, calendar, suffix, *extra):
        return run_json(
            "add", f"{TEST_PREFIX} {suffix}", "--calendar", calendar, *extra
        )

    def instances(self, needle):
        start, end = near_window()
        return run_json("events", "--from", start, "--to", end, "--search", needle)

    def starts(self, needle):
        return sorted(
            datetime.datetime.fromisoformat(e["start"]) for e in self.instances(needle)
        )

    # -- the shared contract ----------------------------------------------- #

    def test_create_and_read_back_round_trips(self):
        for label, calendar in self.backends:
            with self.subTest(backend=label, calendar=calendar):
                event = self.add(
                    calendar, f"rt-{label}",
                    "--start", f"{BASE:%Y-%m}-04 09:00",
                    "--location", "Room 1", "--notes", "agenda",
                )
                self.assertEqual(event["calendar"], calendar)
                fetched = run_json("show", event["id"])
                self.assertEqual(fetched["location"], "Room 1")
                self.assertEqual(fetched["notes"], "agenda")
                self.assertFalse(fetched["recurring"])
                run("delete", event["id"])

    def test_positional_monthly_recurrence(self):
        for label, calendar in self.backends:
            with self.subTest(backend=label, calendar=calendar):
                start = _fourth_monday(BASE.year, BASE.month)
                needle = f"pos-{label}".replace("/", "-")
                event = self.add(
                    calendar, needle,
                    "--start", f"{start.isoformat()} 10:00",
                    "--repeat", "monthly", "--on-the", "4th monday",
                )
                self.assertEqual(
                    event["recurrence"]["on_the"], "the 4th Monday",
                    f"{label} did not store a positional monthly rule")
                for moment in self.starts(needle):
                    self.assertEqual(moment.weekday(), 0, f"{label}: {moment} not a Monday")
                    self.assertEqual(
                        (moment.day - 1) // 7 + 1, 4,
                        f"{label}: {moment} is not the 4th Monday")
                run("delete", event["id"], "--series")

    def test_series_edit_reaches_every_occurrence(self):
        """🛑 The EKSpan bug: --series used to detach the first occurrence."""
        for label, calendar in self.backends:
            with self.subTest(backend=label, calendar=calendar):
                needle = f"series-{label}".replace("/", "-")
                event = self.add(
                    calendar, needle,
                    "--start", f"{BASE:%Y-%m}-07 09:00",
                    "--repeat", "weekly", "--repeat-count", "4",
                )
                run("edit", event["id"], "--series", "--location", "everywhere")
                found = self.instances(needle)
                self.assertGreaterEqual(len(found), 3, f"{label}: series did not expand")
                for instance in found:
                    self.assertEqual(
                        instance["location"], "everywhere",
                        f"{label}: {instance['start']} missed the series edit")
                    self.assertTrue(
                        instance["recurring"],
                        f"{label}: {instance['start']} was detached by a --series edit")
                    self.assertNotIn("/RID=", instance["id"], f"{label}: detached")
                run("delete", event["id"], "--series")

    def test_recurrence_rule_change_does_not_collapse_to_daily(self):
        """🛑 The 26.812.1 corruption, checked on every backend."""
        for label, calendar in self.backends:
            with self.subTest(backend=label, calendar=calendar):
                start = _fourth_monday(BASE.year, BASE.month)
                needle = f"rule-{label}".replace("/", "-")
                event = self.add(
                    calendar, needle,
                    "--start", f"{start.isoformat()} 10:00",
                    "--repeat", "monthly", "--on-the", "4th monday",
                )
                updated = run_json(
                    "edit", event["id"], "--series",
                    "--repeat", "monthly", "--on-the", "2nd tuesday")
                self.assertEqual(updated["recurrence"]["frequency"], "monthly", label)
                self.assertEqual(updated["recurrence"]["on_the"], "the 2nd Tuesday", label)
                self.assertLess(
                    len(self.starts(needle)), 40,
                    f"{label}: the rule collapsed to daily")
                run("delete", event["id"], "--series")

    def test_moving_one_occurrence_detaches_only_that_one(self):
        for label, calendar in self.backends:
            with self.subTest(backend=label, calendar=calendar):
                needle = f"move-{label}".replace("/", "-")
                event = self.add(
                    calendar, needle,
                    "--start", f"{BASE:%Y-%m}-07 09:00",
                    "--repeat", "weekly", "--repeat-count", "4",
                )
                before = self.starts(needle)
                target = before[1]
                run("edit", event["id"],
                    "--occurrence", target.date().isoformat(),
                    "--start", f"{target.date().isoformat()} 14:00",
                    "--end", f"{target.date().isoformat()} 14:30")
                after = self.starts(needle)
                self.assertEqual(len(after), len(before), f"{label}: series length changed")
                self.assertEqual(
                    len([d for d in after if d.hour == 14]), 1,
                    f"{label}: expected exactly one moved occurrence")
                run("delete", event["id"], "--series")

    def test_series_delete_removes_the_whole_series(self):
        for label, calendar in self.backends:
            with self.subTest(backend=label, calendar=calendar):
                needle = f"del-{label}".replace("/", "-")
                event = self.add(
                    calendar, needle,
                    "--start", f"{BASE:%Y-%m}-07 09:00",
                    "--repeat", "weekly", "--repeat-count", "4",
                )
                self.assertGreaterEqual(len(self.instances(needle)), 3)
                run("delete", event["id"], "--series")
                self.assertEqual(
                    self.instances(needle), [],
                    f"{label}: --series left occurrences behind")

    def test_a_lost_write_is_detected_on_every_backend(self):
        for label, calendar in self.backends:
            with self.subTest(backend=label, calendar=calendar):
                event = self.add(
                    calendar, f"lost-{label}", "--start", f"{BASE:%Y-%m}-04 09:00")
                code, _, err = run(
                    "edit", event["id"], "--location", "should not persist",
                    check=False, env={"APPLE_CALENDAR_SIMULATE_LOST_WRITE": "1"})
                self.assertNotEqual(code, 0, f"{label}: lost write reported success")
                self.assertIn("does not hold the change", err)
                run("delete", event["id"])
