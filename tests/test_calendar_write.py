"""Live write-path tests for apple-calendar: add, edit, delete.

Every event created here is prefixed and swept; see harness.py for the safety
model. Run with ./tests/run-tests.
"""

import calendar as calendar_module
import datetime

from harness import (
    near_future,
    near_window,
    TEST_YEAR,
    LiveCalendarTest,
    find_test_events,
    run,
    run_json,
)


class TestAdd(LiveCalendarTest):
    def test_add_minimal_defaults_to_one_hour(self):
        event = self.add("minimal", "--start", f"{TEST_YEAR}-03-01 09:00")

        self.assertTrue(event["title"].endswith("minimal"))
        self.assertEqual(event["calendar"], self.calendar)
        self.assertTrue(event["start"].startswith(f"{TEST_YEAR}-03-01T09:00"))
        self.assertTrue(event["end"].startswith(f"{TEST_YEAR}-03-01T10:00"))
        self.assertFalse(event["allDay"])
        # A one-off must not advertise an occurrence field.
        self.assertIsNone(event.get("occurrence"))
        self.assertFalse(event["recurring"])

    def test_add_with_duration(self):
        event = self.add(
            "duration", "--start", f"{TEST_YEAR}-03-02 14:00", "--duration", "45"
        )
        self.assertTrue(event["end"].startswith(f"{TEST_YEAR}-03-02T14:45"))

    def test_add_with_explicit_end(self):
        event = self.add(
            "explicit-end",
            "--start", f"{TEST_YEAR}-03-03 08:00",
            "--end", f"{TEST_YEAR}-03-03 11:30",
        )
        self.assertTrue(event["end"].startswith(f"{TEST_YEAR}-03-03T11:30"))

    def test_add_all_day(self):
        event = self.add("all-day", "--start", f"{TEST_YEAR}-03-04", "--all-day")
        self.assertTrue(event["allDay"])

    def test_add_round_trips_metadata(self):
        event = self.add(
            "metadata",
            "--start", f"{TEST_YEAR}-03-05 10:00",
            "--location", "Room 12",
            "--notes", "agenda line one",
            "--url", "https://example.com/meeting",
        )
        fetched = self.get(event["id"])
        self.assertEqual(fetched["location"], "Room 12")
        self.assertEqual(fetched["notes"], "agenda line one")
        self.assertEqual(fetched["url"], "https://example.com/meeting")

    def test_added_event_is_listed(self):
        event = self.add("listed", "--start", f"{TEST_YEAR}-03-06 12:00")
        self.assertTrue(self.exists(event["id"]))

    def test_search_matches_created_event(self):
        self.add("searchable-needle", "--start", f"{TEST_YEAR}-03-07 12:00")
        found = run_json(
            "events",
            "--from", f"{TEST_YEAR}-01-01",
            "--to", f"{TEST_YEAR}-12-31",
            "--search", "searchable-needle",
        )
        self.assertEqual(len(found), 1)


class TestEdit(LiveCalendarTest):
    def test_edit_title(self):
        event = self.add("edit-title", "--start", f"{TEST_YEAR}-04-01 09:00")
        new_title = self.title("edit-title renamed")
        run("edit", event["id"], "--title", new_title)
        self.assertEqual(self.get(event["id"])["title"], new_title)

    def test_edit_times(self):
        event = self.add("edit-times", "--start", f"{TEST_YEAR}-04-02 09:00")
        run(
            "edit", event["id"],
            "--start", f"{TEST_YEAR}-04-02 15:00",
            "--end", f"{TEST_YEAR}-04-02 16:30",
        )
        fetched = self.get(event["id"])
        self.assertTrue(fetched["start"].startswith(f"{TEST_YEAR}-04-02T15:00"))
        self.assertTrue(fetched["end"].startswith(f"{TEST_YEAR}-04-02T16:30"))

    def test_edit_location_and_notes(self):
        event = self.add("edit-meta", "--start", f"{TEST_YEAR}-04-03 09:00")
        run("edit", event["id"], "--location", "Moved", "--notes", "replaced")
        fetched = self.get(event["id"])
        self.assertEqual(fetched["location"], "Moved")
        self.assertEqual(fetched["notes"], "replaced")

    def test_edit_notes_replaces_rather_than_appends(self):
        event = self.add(
            "edit-notes", "--start", f"{TEST_YEAR}-04-04 09:00", "--notes", "original"
        )
        run("edit", event["id"], "--notes", "second")
        self.assertEqual(self.get(event["id"])["notes"], "second")

    def test_edit_with_no_changes_is_rejected(self):
        event = self.add("edit-noop", "--start", f"{TEST_YEAR}-04-05 09:00")
        code, _, err = run("edit", event["id"], check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("nothing to change", err.lower())

    def test_edit_rejects_end_before_start(self):
        event = self.add("edit-backwards", "--start", f"{TEST_YEAR}-04-06 09:00")
        code, _, err = run(
            "edit", event["id"], "--end", f"{TEST_YEAR}-04-06 08:00", check=False
        )
        self.assertNotEqual(code, 0)
        self.assertIn("end time", err.lower())


class TestDelete(LiveCalendarTest):
    def test_delete_removes_the_event(self):
        event = self.add("to-delete", "--start", f"{TEST_YEAR}-05-01 09:00")
        self.assertTrue(self.exists(event["id"]))

        run("delete", event["id"])
        self.assertFalse(self.exists(event["id"]))

    def test_delete_is_not_soft(self):
        """Unlike Notes, a deleted event is gone, not moved to a trash folder."""
        event = self.add("hard-delete", "--start", f"{TEST_YEAR}-05-02 09:00")
        run("delete", event["id"])
        code, _, _ = run("show", event["id"], check=False)
        self.assertNotEqual(code, 0)

    def test_delete_unknown_id_fails(self):
        code, _, err = run("delete", "no-such-event-id", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("no event", err.lower())


class TestValidation(LiveCalendarTest):
    def test_end_before_start_is_rejected(self):
        code, _, err = run(
            "add", self.title("backwards"),
            "--calendar", self.calendar,
            "--start", f"{TEST_YEAR}-06-01 10:00",
            "--end", f"{TEST_YEAR}-06-01 09:00",
            check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("end time", err.lower())

    def test_end_and_duration_are_mutually_exclusive(self):
        code, _, err = run(
            "add", self.title("both"),
            "--calendar", self.calendar,
            "--start", f"{TEST_YEAR}-06-02 10:00",
            "--end", f"{TEST_YEAR}-06-02 11:00",
            "--duration", "30",
            check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("not both", err.lower())

    def test_unknown_calendar_is_rejected(self):
        code, _, err = run(
            "add", self.title("bad-calendar"),
            "--calendar", "no-such-calendar-here",
            "--start", f"{TEST_YEAR}-06-03 10:00",
            check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("no calendar named", err.lower())

    def test_read_only_calendar_is_rejected(self):
        """Subscribed/holiday calendars must refuse writes rather than fail oddly."""
        all_calendars = run_json("calendars")
        # A read-only calendar that shares its title with a writable one is not
        # a valid fixture here: --calendar resolves such a name to the writable
        # instance, so the write is meant to succeed.
        writable_titles = {c["title"].lower()
                           for c in all_calendars if c["allowsModification"]}
        read_only = [c for c in all_calendars
                     if not c["allowsModification"]
                     and c["title"].lower() not in writable_titles]
        if not read_only:
            self.skipTest("no unambiguously read-only calendars on this machine")

        code, _, err = run(
            "add", self.title("read-only"),
            "--calendar", read_only[0]["title"],
            "--start", f"{TEST_YEAR}-06-04 10:00",
            check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("read-only", err.lower())


class TestRecurringSafety(LiveCalendarTest):
    """The occurrence-resolution guard, checked against real recurring events.

    apple-calendar cannot create recurring events, so these use whatever real
    series already exist. They only read and assert on refusals — nothing here
    modifies a real event.
    """

    def recurring_event(self):
        events = run_json("events", "--days", "60")
        for event in events:
            if event.get("recurring"):
                return event
        return None

    def test_recurring_events_expose_an_occurrence_field(self):
        event = self.recurring_event()
        if not event:
            self.skipTest("no recurring events in the next 60 days")
        self.assertIsNotNone(event.get("occurrence"))

    def test_edit_without_occurrence_is_refused(self):
        event = self.recurring_event()
        if not event:
            self.skipTest("no recurring events in the next 60 days")

        code, _, err = run(
            "edit", event["id"], "--title", "SHOULD NEVER BE APPLIED", check=False
        )
        self.assertNotEqual(code, 0)
        self.assertIn("recurring event", err.lower())

    def test_delete_without_occurrence_is_refused(self):
        event = self.recurring_event()
        if not event:
            self.skipTest("no recurring events in the next 60 days")

        code, _, err = run("delete", event["id"], check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("recurring event", err.lower())

    def test_occurrence_resolves_the_right_instance(self):
        event = self.recurring_event()
        if not event:
            self.skipTest("no recurring events in the next 60 days")

        resolved = run_json("show", event["id"], "--occurrence", event["occurrence"])
        self.assertEqual(resolved["start"], event["start"])

    def test_show_without_occurrence_returns_the_series_master(self):
        event = self.recurring_event()
        if not event:
            self.skipTest("no recurring events in the next 60 days")

        master = run_json("show", event["id"])
        # The master is the first occurrence, so it starts no later than the
        # instance we found.
        self.assertLessEqual(master["start"], event["start"])


class TestInvitees(LiveCalendarTest):
    """The invitee surface, exercised without sending a single invitation.

    🛑 **Nothing here saves an attendee change, deliberately.** Saving one makes
    the CalDAV server mail a real person, and removing one mails them a
    cancellation — neither is undoable and neither belongs in a suite that runs
    unattended. So everything below is either a refusal or a --dry-run.

    The send path was verified by hand instead, against a live Google account:
    the attendee survived `save`, synced, and Google delivered an
    "Invitation: …" mail to the invitee 40s later. See
    docs/apple-calendar-invitees.md for that measurement and for why the write
    needs private API at all.
    """

    def test_reading_attendees_yields_objects_not_names(self):
        # The shape changed in 26.812.0: attendees used to be bare strings.
        # Anything parsing them as strings breaks, so pin the new shape.
        event = self.add("no-invitees", "--start", f"{TEST_YEAR}-04-01 09:00")
        fetched = self.get(event["id"])
        # A fixture with no invitees reports none at all rather than [].
        self.assertIsNone(fetched.get("attendees"))
        self.assertIsNone(fetched.get("organizer"))
        self.assertIsNone(fetched.get("my_status"))

    def test_invite_needs_something_to_do(self):
        event = self.add("invite-noop", "--start", f"{TEST_YEAR}-04-02 09:00")
        code, _, err = run("invite", event["id"], check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("nothing to do", err.lower())

    def test_a_malformed_address_is_refused(self):
        event = self.add("invite-bad-address", "--start", f"{TEST_YEAR}-04-03 09:00")
        for bad in ("not-an-address", "@nodomain.com", "spaces in@it.com", "a@b"):
            with self.subTest(address=bad):
                code, _, err = run(
                    "invite", event["id"], "--add", bad, "--dry-run", check=False
                )
                self.assertNotEqual(code, 0, f"{bad!r} was accepted as an address")
                self.assertIn("is not an address", err.lower())

    def test_a_malformed_address_is_refused_on_add_too(self):
        # `add --invitee` parses before creating anything, so a typo must not
        # leave a stray event behind to be swept.
        code, _, err = run(
            "add", self.title("invite-parse-guard"),
            "--calendar", self.calendar,
            "--start", f"{TEST_YEAR}-04-04 09:00",
            "--invitee", "nonsense",
            check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("is not an address", err.lower())
        self.assertEqual(
            [e for e in find_test_events(self.calendar)
             if e["title"].endswith("invite-parse-guard")],
            [],
            "a rejected --invitee still created the event",
        )

    def test_display_name_forms_are_accepted(self):
        event = self.add("invite-name-forms", "--start", f"{TEST_YEAR}-04-05 09:00")
        for spec in (
            "plain@example.com",
            "Dana White <dana@example.com>",
            '"White, Dana" <dana@example.com>',
        ):
            with self.subTest(spec=spec):
                result = run_json(
                    "invite", event["id"], "--add", spec, "--dry-run"
                )
                self.assertTrue(result["dry_run"])
                self.assertEqual(result["changes"][0]["action"], "add")
                self.assertEqual(result["changes"][0]["email"], "dana@example.com"
                                 if "dana" in spec else "plain@example.com")

    def test_the_same_address_in_add_and_remove_is_refused(self):
        event = self.add("invite-clash", "--start", f"{TEST_YEAR}-04-06 09:00")
        code, _, err = run(
            "invite", event["id"], "--add", "a@b.com", "--remove", "A@B.COM",
            "--dry-run", check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("both --add and --remove", err.lower())

    def test_dry_run_changes_nothing(self):
        event = self.add("invite-dry-run", "--start", f"{TEST_YEAR}-04-07 09:00")
        result = run_json(
            "invite", event["id"], "--add", "someone@example.com", "--dry-run"
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(len(result["changes"]), 1)
        self.assertTrue(result["changes"][0]["changed"])
        # Nothing was saved, so the event still has no invitees at all.
        self.assertIsNone(self.get(event["id"]).get("attendees"))

    def test_removing_someone_never_invited_is_a_no_op_not_an_error(self):
        event = self.add("invite-absent", "--start", f"{TEST_YEAR}-04-08 09:00")
        result = run_json(
            "invite", event["id"], "--remove", "stranger@example.com", "--dry-run"
        )
        self.assertEqual(result["changes"][0]["action"], "not-invited")
        self.assertFalse(result["changes"][0]["changed"])

    def test_unknown_event_id_is_refused(self):
        code, _, err = run(
            "invite", "not-a-real-identifier", "--add", "a@b.com", "--dry-run",
            check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("no event", err.lower())


def _nth_weekday(year, month, weekday, nth):
    """Date of the nth `weekday` (0=Mon) of a month; nth=-1 means the last."""
    days = [
        datetime.date(year, month, d)
        for d in range(1, calendar_module.monthrange(year, month)[1] + 1)
    ]
    matching = [d for d in days if d.weekday() == weekday]
    return matching[nth if nth == -1 else nth - 1]


BASE = near_future(month_offset=2)


class TestRecurrence(LiveCalendarTest):
    """Creating and changing recurring events.

    The flag surface mirrors `apple reminders` on purpose — --repeat,
    --repeat-interval, --repeat-until, --repeat-count, same validation wording —
    with --on-the added for the one thing reminders cannot express.
    """

    def occurrences(self, needle):
        start, end = near_window()
        found = run_json("events", "--from", start, "--to", end, "--search", needle)
        return sorted(datetime.datetime.fromisoformat(e["start"]) for e in found)

    # -- reminders-parity flags ------------------------------------------- #

    def test_weekly_with_interval_and_count(self):
        event = self.add(
            "recur-weekly",
            "--start", f"{BASE:%Y-%m}-04 09:00",
            "--repeat", "weekly", "--repeat-interval", "2", "--repeat-count", "3",
        )
        self.assertTrue(event["recurring"])
        self.assertEqual(event["recurrence"]["frequency"], "weekly")
        self.assertEqual(event["recurrence"]["interval"], 2)
        self.assertEqual(event["recurrence"]["count"], 3)

        starts = self.occurrences("recur-weekly")
        self.assertEqual(len(starts), 3, "--repeat-count did not bound the series")
        self.assertEqual((starts[1] - starts[0]).days, 14)

    def test_repeat_until_bounds_the_series(self):
        event = self.add(
            "recur-until",
            "--start", f"{BASE:%Y-%m}-04 09:00",
            "--repeat", "daily", "--repeat-until", f"{BASE:%Y-%m}-08",
        )
        self.assertIsNotNone(event["recurrence"]["until"])
        for start in self.occurrences("recur-until"):
            self.assertLessEqual(start.date(), datetime.date(BASE.year, BASE.month, 8))

    def test_a_one_off_reports_no_recurrence(self):
        event = self.add("recur-none", "--start", f"{BASE:%Y-%m}-04 09:00")
        self.assertFalse(event["recurring"])
        self.assertIsNone(event.get("recurrence"))

    # -- the positional monthly case -------------------------------------- #

    def test_fourth_monday_of_each_month(self):
        start = _nth_weekday(BASE.year, BASE.month, weekday=0, nth=4)
        event = self.add(
            "recur-4th-mon",
            "--start", f"{start.isoformat()} 10:00",
            "--repeat", "monthly", "--on-the", "4th monday",
        )
        self.assertEqual(event["recurrence"]["on_the"], "the 4th Monday")

        starts = self.occurrences("recur-4th-mon")
        self.assertGreater(len(starts), 3, "series did not project forward")
        for moment in starts:
            self.assertEqual(moment.weekday(), 0, f"{moment} is not a Monday")
            self.assertEqual(
                (moment.day - 1) // 7 + 1, 4, f"{moment} is not the 4th Monday"
            )

    def test_last_friday_of_each_month(self):
        start = _nth_weekday(BASE.year, BASE.month, weekday=4, nth=-1)
        self.add(
            "recur-last-fri",
            "--start", f"{start.isoformat()} 10:00",
            "--repeat", "monthly", "--on-the", "last friday",
        )
        for moment in self.occurrences("recur-last-fri"):
            self.assertEqual(moment.weekday(), 4)
            last = calendar_module.monthrange(moment.year, moment.month)[1]
            self.assertGreater(moment.day, last - 7, f"{moment} is not the last Friday")

    def test_day_of_month(self):
        event = self.add(
            "recur-day-15",
            "--start", f"{BASE:%Y-%m}-15 10:00",
            "--repeat", "monthly", "--on-the", "15",
        )
        self.assertEqual(event["recurrence"]["on_the"], "day 15")
        for moment in self.occurrences("recur-day-15"):
            self.assertEqual(moment.day, 15)

    def test_a_start_date_off_the_pattern_warns(self):
        # Sunday cannot be the 4th Monday; the tool must say so rather than
        # silently produce a series whose first occurrence is the odd one out.
        start = _nth_weekday(BASE.year, BASE.month, weekday=6, nth=1)
        code, _, err = run(
            "add", self.title("recur-mismatch"),
            "--calendar", self.calendar,
            "--start", f"{start.isoformat()} 10:00",
            "--repeat", "monthly", "--on-the", "4th monday",
        )
        self.assertEqual(code, 0, "the mismatch should warn, not fail")
        self.assertIn("not the 4th Monday", err)

    # -- editing ----------------------------------------------------------- #

    def test_changing_recurrence_requires_series(self):
        start = _nth_weekday(BASE.year, BASE.month, weekday=0, nth=4)
        event = self.add(
            "recur-edit-guard",
            "--start", f"{start.isoformat()} 10:00",
            "--repeat", "monthly", "--on-the", "4th monday",
        )
        code, _, err = run("edit", event["id"], "--repeat", "weekly", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("--series", err)

    def test_editing_a_rule_does_not_silently_become_daily(self):
        """🛑 Regression: saving a changed rule with EKSpan.thisEvent rewrites it
        to FREQ=DAILY;INTERVAL=1 — no error, `save` reports success, and a
        4-times-a-year series quietly becomes 365. The fix is .futureEvents;
        this test is the thing standing between that bug and a user's calendar.
        """
        start = _nth_weekday(BASE.year, BASE.month, weekday=0, nth=4)
        event = self.add(
            "recur-span",
            "--start", f"{start.isoformat()} 10:00",
            "--repeat", "monthly", "--on-the", "4th monday",
        )
        updated = run_json(
            "edit", event["id"], "--series",
            "--repeat", "monthly", "--on-the", "2nd tuesday",
        )
        self.assertEqual(updated["recurrence"]["frequency"], "monthly")
        self.assertEqual(updated["recurrence"]["on_the"], "the 2nd Tuesday")

        # The count is the tell: daily over two years is hundreds.
        starts = self.occurrences("recur-span")
        self.assertLess(
            len(starts), 40,
            f"{len(starts)} occurrences — the rule collapsed to daily",
        )
        # Every occurrence after the anchor follows the new pattern.
        for moment in starts[1:]:
            self.assertEqual(moment.weekday(), 1, f"{moment} is not a Tuesday")

    def test_repeat_none_removes_the_series(self):
        event = self.add(
            "recur-remove",
            "--start", f"{BASE:%Y-%m}-04 09:00",
            "--repeat", "weekly",
        )
        self.assertTrue(event["recurring"])
        updated = run_json("edit", event["id"], "--series", "--repeat", "none")
        self.assertFalse(updated["recurring"])
        self.assertIsNone(updated.get("recurrence"))

    # -- validation, matching the reminders wording ------------------------ #

    def test_recurrence_flag_validation(self):
        base = ["add", self.title("recur-invalid"), "--calendar", self.calendar,
                "--start", f"{BASE:%Y-%m}-04 09:00"]
        cases = [
            (["--repeat-interval", "2"], "require --repeat"),
            (["--repeat-until", f"{BASE:%Y-%m}-28"], "require --repeat"),
            (["--repeat", "weekly", "--repeat-until", f"{BASE:%Y-%m}-28",
              "--repeat-count", "3"], "mutually exclusive"),
            (["--repeat", "weekly", "--repeat-interval", "0"], "must be >= 1"),
            (["--repeat", "weekly", "--repeat-count", "0"], "must be >= 1"),
            (["--repeat", "weekly", "--on-the", "4th monday"], "needs --repeat monthly"),
            (["--repeat", "monthly", "--on-the", "banana"], "is not a day of the month"),
        ]
        for extra, expected in cases:
            with self.subTest(flags=" ".join(extra)):
                code, _, err = run(*base, *extra, check=False)
                self.assertNotEqual(code, 0, f"{extra} was accepted")
                self.assertIn(expected, err)
        self.assertEqual(
            [e for e in find_test_events(self.calendar)
             if e["title"].endswith("recur-invalid")],
            [], "a rejected recurrence still created the event")


class TestMovingOneOccurrence(LiveCalendarTest):
    """Rescheduling a single instance of a series — the "this week only" case.

    Moving one occurrence *detaches* it: it stops being part of the series,
    gets its own identifier with a `/RID=<seconds>` suffix, reports
    `recurring: false`, and loses its `occurrence` field. The rest of the
    series is untouched.
    """

    def series(self, suffix, count=4):
        event = self.add(
            suffix,
            "--start", f"{BASE:%Y-%m}-07 09:00",
            "--repeat", "weekly", "--repeat-count", str(count),
        )
        return event["id"]

    def starts(self, needle):
        start, end = near_window()
        found = run_json("events", "--from", start, "--to", end, "--search", needle)
        return sorted(datetime.datetime.fromisoformat(e["start"]) for e in found)

    def test_moving_one_occurrence_leaves_the_rest_alone(self):
        event_id = self.series("move-one")
        before = self.starts("move-one")
        self.assertGreaterEqual(len(before), 3)
        target = before[1]

        run(
            "edit", event_id,
            "--occurrence", target.date().isoformat(),
            "--start", f"{target.date().isoformat()} 14:00",
            "--end", f"{target.date().isoformat()} 14:30",
        )

        after = self.starts("move-one")
        self.assertEqual(len(after), len(before), "moving one changed the series length")
        moved = [d for d in after if d.hour == 14]
        self.assertEqual(len(moved), 1, "exactly one occurrence should have moved")
        self.assertEqual(
            [d.hour for d in after if d.hour != 14], [9] * (len(before) - 1),
            "the other occurrences did not stay at 09:00",
        )

    def test_a_moved_occurrence_detaches(self):
        event_id = self.series("move-detach")
        target = self.starts("move-detach")[1]
        new_day = (target + datetime.timedelta(days=2)).date()
        run(
            "edit", event_id,
            "--occurrence", target.date().isoformat(),
            "--start", f"{new_day.isoformat()} 11:00",
            "--end", f"{new_day.isoformat()} 11:30",
        )

        start, end = near_window()
        found = run_json("events", "--from", start, "--to", end, "--search", "move-detach")
        detached = [e for e in found if e["start"].startswith(new_day.isoformat())]
        self.assertEqual(len(detached), 1)
        instance = detached[0]
        self.assertFalse(instance["recurring"], "a detached instance still claims to recur")
        self.assertIsNone(instance.get("occurrence"))
        self.assertIn("/RID=", instance["id"])

    def test_a_moved_occurrence_is_findable_by_its_new_date(self):
        """🛑 Regression: --occurrence matched identifiers exactly, and a detached
        instance's identifier carries a /RID= suffix the series id does not — so
        the instance you had just moved became unreachable by date, failing with
        "no occurrence on that day" for an event plainly listed in `events`.
        """
        event_id = self.series("move-refind")
        target = self.starts("move-refind")[1]
        new_day = (target + datetime.timedelta(days=2)).date()
        run(
            "edit", event_id,
            "--occurrence", target.date().isoformat(),
            "--start", f"{new_day.isoformat()} 11:00",
            "--end", f"{new_day.isoformat()} 11:30",
        )

        run("edit", event_id, "--occurrence", new_day.isoformat(),
            "--location", "found by new date")

        start, end = near_window()
        found = run_json("events", "--from", start, "--to", end, "--search", "move-refind")
        located = [e for e in found if e["start"].startswith(new_day.isoformat())]
        self.assertEqual(len(located), 1)
        self.assertEqual(located[0]["location"], "found by new date")

    def test_the_original_date_no_longer_resolves(self):
        event_id = self.series("move-gone")
        target = self.starts("move-gone")[1]
        new_day = (target + datetime.timedelta(days=2)).date()
        run(
            "edit", event_id,
            "--occurrence", target.date().isoformat(),
            "--start", f"{new_day.isoformat()} 11:00",
            "--end", f"{new_day.isoformat()} 11:30",
        )
        code, _, err = run(
            "edit", event_id, "--occurrence", target.date().isoformat(),
            "--location", "nope", check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("no occurrence", err.lower())
