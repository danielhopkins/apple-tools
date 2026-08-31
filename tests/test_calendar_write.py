"""Live write-path tests for apple-calendar: add, edit, delete.

Every event created here is prefixed and swept; see harness.py for the safety
model. Run with ./tests/run-tests.
"""

import calendar as calendar_module
import datetime
import json

from harness import (
    near_future,
    near_window,
    TEST_PREFIX,
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

    def test_a_written_location_gets_no_map_pin(self):
        # 🛑 Measured on 2026-08-16, and the reason `geo` is reported at all.
        # EventKit wraps a written location string in an EKStructuredLocation
        # carrying the title and nothing else. Nothing geocodes it afterwards —
        # not EventKit, not the calDAV server, and not Calendar.app on display.
        # Confirmed in a matched pair: the same event, edited through
        # Calendar.app's address picker, came back with the text rewritten to
        # Apple's multi-line form and a real coordinate attached.
        #
        # So a location this tool writes is text. Nothing here can promise a map
        # pin or a travel-time alert, and this test fails if that ever changes.
        event = self.add(
            "geo",
            "--start", f"{TEST_YEAR}-03-08 09:00",
            "--location", "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO 80303",
        )
        fetched = self.get(event["id"])
        self.assertEqual(
            fetched["location"], "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO 80303"
        )
        self.assertIsNotNone(fetched.get("geo"), "a written location still gets a structuredLocation")
        self.assertFalse(fetched["geo"]["has_coordinate"])
        self.assertIsNone(fetched["geo"].get("latitude"))

    def test_an_event_without_a_location_reports_no_geo(self):
        # Absent, not an object full of nulls: `geo` present must mean the event
        # really carries a structured location.
        event = self.add("geo-absent", "--start", f"{TEST_YEAR}-03-09 09:00")
        self.assertIsNone(self.get(event["id"]).get("geo"))

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

    def test_edit_sets_url(self):
        event = self.add("edit-url", "--start", f"{TEST_YEAR}-04-07 09:00")
        run("edit", event["id"], "--url", "https://example.com/join")
        self.assertEqual(self.get(event["id"])["url"], "https://example.com/join")

    def test_edit_replaces_a_stale_url(self):
        event = self.add(
            "edit-url-replace",
            "--start", f"{TEST_YEAR}-04-08 09:00",
            "--url", "https://stale.example.com/1",
        )
        run("edit", event["id"], "--url", "https://fresh.example.com/2")
        self.assertEqual(self.get(event["id"])["url"], "https://fresh.example.com/2")

    def test_edit_empty_url_clears_the_field(self):
        # The reason this flag exists: a stale meeting link in `url` competes
        # with the real one in location/notes. Clearing must reach nil, not an
        # empty URL, so the key has to be absent from the JSON afterwards.
        event = self.add(
            "edit-url-clear",
            "--start", f"{TEST_YEAR}-04-09 09:00",
            "--url", "https://example.com/stale",
        )
        self.assertEqual(self.get(event["id"])["url"], "https://example.com/stale")
        run("edit", event["id"], "--url", "")
        self.assertIsNone(self.get(event["id"]).get("url"))

    def test_edit_rejects_a_url_that_does_not_parse(self):
        event = self.add("edit-url-bad", "--start", f"{TEST_YEAR}-04-10 09:00")
        code, _, err = run("edit", event["id"], "--url", "example.com", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("not a URL", err)
        self.assertIsNone(self.get(event["id"]).get("url"))

    def test_add_rejects_a_url_that_does_not_parse(self):
        code, _, err = run(
            "add", self.title("add-url-bad"),
            "--start", f"{TEST_YEAR}-04-11 09:00",
            "--calendar", self.calendar,
            "--url", "example.com",
            check=False,
        )
        self.assertNotEqual(code, 0)
        self.assertIn("not a URL", err)

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


class TestAllDayConversion(LiveCalendarTest):
    """Moving an event across the all-day boundary.

    🛑 EventKit refuses this in silence. Setting `--start 18:30` on an all-day
    event leaves `isAllDay` true and pins the dates back to midnight and
    23:59:59, so `save` reports success and the read-back names a start
    mismatch — a symptom that reads like a lost write. Measured 2026-08-31 on a
    real event, which had to be deleted and recreated by hand.
    """

    def test_a_start_time_converts_an_all_day_event(self):
        event = self.add("allday-to-timed", "--start", f"{TEST_YEAR}-04-12", "--all-day")
        self.assertTrue(event["allDay"])

        # 🛑 75 is EX_TEMPFAIL — the server did not confirm in time — and the
        # write still landed. Only the stderr note and the read-back are the
        # subject here.
        _, _, err = run("edit", event["id"], "--start", f"{TEST_YEAR}-04-12 18:30")
        # The conversion is never silent: it changes what the caller asked for.
        self.assertIn("all-day", err)

        fetched = self.get(event["id"])
        self.assertFalse(fetched["allDay"])
        self.assertTrue(fetched["start"].startswith(f"{TEST_YEAR}-04-12T18:30"))
        # ⚠️ An all-day end is 23:59:59, which is the end of the day and not an
        # end time. Carrying it over would make a 5-hour event out of a 6:30
        # start, so the conversion takes `add`'s one-hour default instead.
        self.assertTrue(fetched["end"].startswith(f"{TEST_YEAR}-04-12T19:30"))

    def test_an_explicit_end_survives_the_conversion(self):
        event = self.add("allday-to-timed-end", "--start", f"{TEST_YEAR}-04-13", "--all-day")
        run(
            "edit", event["id"],
            "--start", f"{TEST_YEAR}-04-13 18:30",
            "--end", f"{TEST_YEAR}-04-13 21:00",
        )
        fetched = self.get(event["id"])
        self.assertFalse(fetched["allDay"])
        self.assertTrue(fetched["end"].startswith(f"{TEST_YEAR}-04-13T21:00"))

    def test_all_day_flag_converts_a_timed_event(self):
        event = self.add("timed-to-allday", "--start", f"{TEST_YEAR}-04-14 09:00")
        self.assertFalse(event["allDay"])

        run("edit", event["id"], "--all-day")
        fetched = self.get(event["id"])
        self.assertTrue(fetched["allDay"])
        # The day it was on is the day it stays on.
        self.assertTrue(fetched["start"].startswith(f"{TEST_YEAR}-04-14"))

    def test_timed_takes_a_bare_time_on_the_events_own_day(self):
        # The bare-time rule still applies: '19:00' means this event's day, not
        # today, which is years away from TEST_YEAR.
        event = self.add("allday-bare-time", "--start", f"{TEST_YEAR}-04-15", "--all-day")
        run("edit", event["id"], "--timed", "--start", "19:00", "--end", "21:30")
        fetched = self.get(event["id"])
        self.assertFalse(fetched["allDay"])
        self.assertTrue(fetched["start"].startswith(f"{TEST_YEAR}-04-15T19:00"))
        self.assertTrue(fetched["end"].startswith(f"{TEST_YEAR}-04-15T21:30"))

    def test_timed_without_a_start_time_is_refused(self):
        # An all-day event's start is midnight, so there is no clock time to
        # keep. Refusing beats inventing a midnight event nobody asked for.
        event = self.add("timed-no-start", "--start", f"{TEST_YEAR}-04-16", "--all-day")
        code, _, err = run("edit", event["id"], "--timed", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("needs a start time", err)
        self.assertTrue(self.get(event["id"])["allDay"])

    def test_a_date_with_no_time_leaves_an_all_day_event_alone(self):
        # 🛑 Midnight reads as "no time given", so moving an all-day event to
        # another day must not quietly make it timed.
        event = self.add("allday-move", "--start", f"{TEST_YEAR}-04-17", "--all-day")
        run("edit", event["id"], "--start", f"{TEST_YEAR}-04-18")
        fetched = self.get(event["id"])
        self.assertTrue(fetched["allDay"])
        self.assertTrue(fetched["start"].startswith(f"{TEST_YEAR}-04-18"))

    def test_moving_an_all_day_event_keeps_it_all_day_and_one_day_long(self):
        # 🛑 This used to fail outright. The end stayed on the old day, landing
        # before the new start, so a request that named no end at all was
        # refused with "end time must be at or after the start time".
        event = self.add("allday-move-length", "--start", f"{TEST_YEAR}-04-20", "--all-day")
        run("edit", event["id"], "--start", f"{TEST_YEAR}-04-21")
        fetched = self.get(event["id"])
        self.assertTrue(fetched["allDay"])
        self.assertTrue(fetched["start"].startswith(f"{TEST_YEAR}-04-21"))
        self.assertTrue(fetched["end"].startswith(f"{TEST_YEAR}-04-21"))

    def test_moving_a_timed_event_keeps_its_length(self):
        event = self.add(
            "timed-move-length",
            "--start", f"{TEST_YEAR}-04-22 09:00",
            "--end", f"{TEST_YEAR}-04-22 11:00",
        )
        _, _, err = run("edit", event["id"], "--start", f"{TEST_YEAR}-04-22 15:00")
        self.assertIn("keeps its length", err)
        fetched = self.get(event["id"])
        self.assertTrue(fetched["start"].startswith(f"{TEST_YEAR}-04-22T15:00"))
        self.assertTrue(fetched["end"].startswith(f"{TEST_YEAR}-04-22T17:00"))

    def test_all_day_and_timed_together_are_refused(self):
        event = self.add("allday-both", "--start", f"{TEST_YEAR}-04-19 09:00")
        code, _, err = run("edit", event["id"], "--all-day", "--timed", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("--timed", err)


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
            # 🛑 EventKit carries a bare day number on monthly rules only, and
            # *ignores* it on a yearly one. Silently dropping it would give back
            # a rule that fires on the start date's day number every year.
            (["--repeat", "yearly", "--on-the", "15"], "needs --repeat monthly"),
            (["--repeat", "monthly", "--months", "1,2"], "needs --repeat yearly"),
            (["--repeat", "yearly", "--months", "banana"], "is not a month"),
            (["--repeat", "yearly", "--months", "13"], "is not a month"),
            (["--months", "1,2"], "needs --repeat yearly"),
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


class TestYearlyMonthsFilter(LiveCalendarTest):
    """`FREQ=YEARLY;BYMONTH=1,2,3,4;BYDAY=4MO` — the committee that sits in the
    first four months of every year and not for the rest of it.

    🛑 **Until --months existed this rule was not expressible**, and the only
    substitute was a *bounded* monthly series that expires. One real series on
    this calendar was rebuilt and left to lapse three times — 2021, 2023 and
    2025 — for exactly that reason.

    ⚠️ Google Calendar's own web editor cannot build this rule either, so a
    round trip through calDAV is worth asserting rather than assuming.
    """

    # Far enough out that the whole first-year run is inside near_window(), and
    # close enough that EventKit still expands the series (see near_window).
    YEAR = datetime.date.today().year + 1

    def occurrences(self, needle):
        start, end = near_window()
        found = run_json("events", "--from", start, "--to", end, "--search", needle)
        return sorted(datetime.datetime.fromisoformat(e["start"]) for e in found)

    def test_yearly_fourth_monday_in_four_months(self):
        start = _nth_weekday(self.YEAR, 1, weekday=0, nth=4)
        event = self.add(
            "recur-yearly-bymonth",
            "--start", f"{start.isoformat()} 18:30",
            "--repeat", "yearly", "--on-the", "4th monday", "--months", "1,2,3,4",
        )
        self.assertEqual(event["recurrence"]["frequency"], "yearly")
        self.assertEqual(event["recurrence"]["on_the"], "the 4th Monday")
        self.assertEqual(event["recurrence"]["months"], [1, 2, 3, 4])
        # Open-ended is the point — a bounded rule is what kept lapsing.
        self.assertIsNone(event["recurrence"].get("until"))
        self.assertIsNone(event["recurrence"].get("count"))

        starts = self.occurrences("recur-yearly-bymonth")
        self.assertGreaterEqual(
            len(starts), 4, "the yearly series did not project forward"
        )
        for moment in starts:
            self.assertEqual(moment.weekday(), 0, f"{moment} is not a Monday")
            self.assertEqual(
                (moment.day - 1) // 7 + 1, 4, f"{moment} is not the 4th Monday"
            )
            self.assertIn(moment.month, (1, 2, 3, 4), f"{moment} is outside --months")

        # The months really filter: four a year, not twelve.
        by_year = {}
        for moment in starts:
            by_year.setdefault(moment.year, []).append(moment)
        for year, moments in by_year.items():
            self.assertLessEqual(
                len(moments), 4, f"{year} has {len(moments)} occurrences, not four"
            )

    def test_month_names_and_numbers_mean_the_same_rule(self):
        start = _nth_weekday(self.YEAR, 2, weekday=1, nth=1)
        by_name = self.add(
            "recur-months-names",
            "--start", f"{start.isoformat()} 09:00",
            "--repeat", "yearly", "--on-the", "1st tuesday",
            "--months", "feb,MAR", "--months", "April",
        )
        self.assertEqual(by_name["recurrence"]["months"], [2, 3, 4])

    def test_months_alone_needs_no_day_pattern(self):
        event = self.add(
            "recur-months-only",
            "--start", f"{self.YEAR}-03-09 09:00",
            "--repeat", "yearly", "--months", "3,9",
        )
        self.assertEqual(event["recurrence"]["months"], [3, 9])
        self.assertIsNone(event["recurrence"].get("on_the"))

    def test_a_plain_yearly_rule_reports_no_months(self):
        event = self.add(
            "recur-yearly-plain",
            "--start", f"{self.YEAR}-03-09 09:00",
            "--repeat", "yearly",
        )
        # Absent, never [] — the rule for every optional key in this tool.
        self.assertIsNone(event["recurrence"].get("months"))

    def test_a_start_month_outside_months_warns(self):
        code, _, err = run(
            "add", self.title("recur-months-mismatch"),
            "--calendar", self.calendar,
            "--start", f"{self.YEAR}-07-06 09:00",
            "--repeat", "yearly", "--months", "1,2,3,4",
        )
        self.assertEqual(code, 0, "the mismatch should warn, not fail")
        self.assertIn("--months", err)
        self.assertIn("Jan, Feb, Mar, Apr", err)

    def test_editing_a_series_onto_a_months_filter(self):
        start = _nth_weekday(self.YEAR, 1, weekday=0, nth=4)
        event = self.add(
            "recur-months-edit",
            "--start", f"{start.isoformat()} 18:30",
            "--repeat", "monthly", "--on-the", "4th monday",
        )
        updated = run_json(
            "edit", event["id"], "--series",
            "--repeat", "yearly", "--on-the", "4th monday", "--months", "1,2,3,4",
        )
        self.assertEqual(updated["recurrence"]["frequency"], "yearly")
        self.assertEqual(updated["recurrence"]["months"], [1, 2, 3, 4])
        for moment in self.occurrences("recur-months-edit")[1:]:
            self.assertIn(moment.month, (1, 2, 3, 4), f"{moment} is outside --months")


class TestSeriesTimeEdit(LiveCalendarTest):
    """🛑 A bare `--start`/`--end` time means the event's own day, not today.

    `--series` resolves to the series *master* — the first occurrence, which can
    be years back. A bare time parsed as a date lands on TODAY, so
    `edit <series> --series --end "20:30"` silently dragged the anchor of a
    series anchored in 2023 forward three years. Nothing errored.
    """

    def test_a_bare_time_keeps_the_series_anchor_day(self):
        event = self.add(
            "series-bare-time",
            "--start", f"{BASE:%Y-%m}-04 09:00",
            "--repeat", "weekly",
        )
        anchor = datetime.datetime.fromisoformat(event["start"]).date()

        code, out, err = run("edit", event["id"], "--series", "--start", "11:30",
                             "--end", "13:00", "--json")
        self.assertIn(code, (0, 75), err)
        updated = json.loads(out)

        start = datetime.datetime.fromisoformat(updated["start"])
        end = datetime.datetime.fromisoformat(updated["end"])
        self.assertEqual(start.date(), anchor, "a bare time moved the series anchor")
        self.assertEqual((start.hour, start.minute), (11, 30))
        self.assertEqual(end.date(), anchor)
        self.assertEqual((end.hour, end.minute), (13, 0))
        self.assertNotEqual(
            start.date(), datetime.date.today(), "the bare time was read as today"
        )
        # The re-anchoring is announced; it is not something to discover later.
        self.assertIn("--start named a time and no date", err)

    def test_a_full_date_still_moves_the_anchor(self):
        event = self.add(
            "series-full-date",
            "--start", f"{BASE:%Y-%m}-04 09:00",
            "--repeat", "weekly",
        )
        moved = f"{BASE:%Y-%m}-11"
        updated = run_json(
            "edit", event["id"], "--series",
            "--start", f"{moved} 14:00", "--end", f"{moved} 15:00",
        )
        start = datetime.datetime.fromisoformat(updated["start"])
        self.assertEqual(start.date().isoformat(), moved)
        self.assertEqual((start.hour, start.minute), (14, 0))


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


class TestWritesAreReadBack(LiveCalendarTest):
    """🛑 A write is only reported as done if the store confirms it.

    Reported from a real session: `edit --occurrence` returned exit 0 and a JSON
    body describing the moved occurrence, while a re-read still showed the
    original date. The return value was built from the in-memory object — the
    one holding the *request* — so it could never fail. An identical retry then
    worked, making it intermittent and invisible.

    The failure cannot be provoked on demand, so APPLE_CALENDAR_SIMULATE_LOST_WRITE
    stands in for it: it makes the save a no-op and nothing else.
    """

    def test_a_lost_write_is_reported_as_a_failure(self):
        event = self.add("readback-lost", "--start", f"{BASE:%Y-%m}-04 09:00")
        code, out, err = run(
            "edit", event["id"], "--location", "should not persist",
            check=False, env={"APPLE_CALENDAR_SIMULATE_LOST_WRITE": "1"},
        )
        self.assertNotEqual(code, 0, "a save that changed nothing reported success")
        self.assertIn("does not hold the change", err)
        self.assertIn("location", err)
        self.assertEqual(out.strip(), "", "a failed write still printed a result")
        # And the store really is untouched.
        self.assertIsNone(self.get(event["id"]).get("location"))

    def test_a_successful_write_reports_what_the_store_holds(self):
        event = self.add("readback-ok", "--start", f"{BASE:%Y-%m}-04 09:00")
        updated = run_json("edit", event["id"], "--location", "persisted")
        self.assertEqual(updated["location"], "persisted")
        self.assertEqual(self.get(event["id"])["location"], "persisted")


class TestSeriesMeansTheWholeSeries(LiveCalendarTest):
    """🛑 --series must not touch a single occurrence.

    Saving with EKSpan.thisEvent under --series *detached the first occurrence*,
    applied the change to that alone, left the other occurrences untouched, and
    reported success. Measured: one detached instance carrying the new location
    and five unchanged occurrences.
    """

    def series(self, suffix):
        return self.add(
            suffix,
            "--start", f"{BASE:%Y-%m}-07 09:00",
            "--repeat", "weekly", "--repeat-count", "4",
        )["id"]

    def instances(self, needle):
        start, end = near_window()
        return run_json("events", "--from", start, "--to", end, "--search", needle)

    def test_series_edit_applies_to_every_occurrence(self):
        event_id = self.series("series-wide")
        run("edit", event_id, "--series", "--location", "series wide")

        found = self.instances("series-wide")
        self.assertGreaterEqual(len(found), 3)
        for instance in found:
            self.assertEqual(
                instance["location"], "series wide",
                f"{instance['start']} did not get the series-wide change")
            self.assertTrue(
                instance["recurring"],
                f"{instance['start']} was detached from the series by a --series edit")

    def test_series_edit_does_not_detach_anything(self):
        event_id = self.series("series-nodetach")
        run("edit", event_id, "--series", "--title", self.title("series-nodetach renamed"))
        for instance in self.instances("series-nodetach"):
            self.assertNotIn(
                "/RID=", instance["id"],
                "a --series edit detached an occurrence")

    def test_series_delete_removes_the_whole_series(self):
        event_id = self.series("series-delete")
        self.assertGreaterEqual(len(self.instances("series-delete")), 3)
        run("delete", event_id, "--series")
        self.assertEqual(
            self.instances("series-delete"), [],
            "--series left occurrences behind; it deleted only the first")


class TestInviteesIsReadOnly(LiveCalendarTest):
    """Reading the guest list must never require changing it.

    🛑 Before this command existed, the only way to see the current roster was
    the `Invitees now:` block a *live* `invite` prints — i.e. you had to mail
    somebody to find out who was already invited. A field report hit exactly
    that.

    It also reports emptiness positively. `events --json` omits `attendees`
    when an event has none, and a competent reader concluded from that omission
    that the field had been dropped entirely — so absent-means-empty is its own
    trap, and this command never leaves it to inference.
    """

    def test_no_invitees_is_stated_not_implied(self):
        event = self.add("invitees-empty", "--start", f"{BASE:%Y-%m}-04 09:00")
        code, out, _ = run("invitees", event["id"])
        self.assertEqual(code, 0)
        self.assertIn("No invitees", out)

    def test_json_always_carries_attendees_and_count(self):
        event = self.add("invitees-json", "--start", f"{BASE:%Y-%m}-04 09:00")
        payload = run_json("invitees", event["id"])
        # Present and empty, never absent — the whole point of the command.
        self.assertIn("attendees", payload)
        self.assertEqual(payload["attendees"], [])
        self.assertEqual(payload["count"], 0)
        self.assertEqual(payload["id"], event["id"])

    def test_it_writes_nothing(self):
        event = self.add(
            "invitees-readonly", "--start", f"{BASE:%Y-%m}-04 09:00",
            "--location", "unchanged")
        before = self.get(event["id"])
        run("invitees", event["id"])
        run("invitees", event["id"], "--json")
        after = self.get(event["id"])
        self.assertEqual(before, after, "a read command changed the event")

    def test_invite_with_nothing_to_do_points_at_the_read_command(self):
        event = self.add("invitees-pointer", "--start", f"{BASE:%Y-%m}-04 09:00")
        code, _, err = run("invite", event["id"], check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("invitees", err)


class TestInvitationsAreReadOnly(LiveCalendarTest):
    """🛑 An invitation you received belongs to whoever organized it.

    `edit` used to change one locally and report success. The server then
    reverts or refuses it, silently — the same failure `invite` has refused
    since it shipped. Measured 2026-08-18: Google answered HTTP 400 to a
    new-time proposal on an Outlook invite, and the Error row it wrote poisoned
    every later write on that calendar.

    ⚠️ The guard tests "am I an attendee", not "am I the organizer". On a
    delegated calendar the organizer is somebody else and the user is not
    invited, and a write there really does sync. Surveyed on this machine over
    30 days: 71 events with no organizer, 2 organized by the user, 14 real
    invitations, and 1 event on a shared calendar the user was not invited to.
    An organizer-only check would have wrongly refused that last one.
    """

    @staticmethod
    def _an_invitation():
        """A real invitation from somebody else, or None."""
        for event in run_json("events", "--days", "90"):
            organizer = event.get("organizer")
            if not organizer or organizer.get("is_me"):
                continue
            if any(a.get("is_me") for a in event.get("attendees") or []):
                return event
        return None

    def test_edit_refuses_an_invitation_from_somebody_else(self):
        event = self._an_invitation()
        if event is None:
            self.skipTest("no invitations from other people in the next 90 days")

        args = ["edit", event["id"], "--title", "should never be written"]
        if event.get("occurrence"):
            args += ["--occurrence", event["occurrence"]]

        code, _, err = run(*args, check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("invitation", err.lower())
        # The refusal must name the organizer, so the user knows who to ask.
        organizer = event["organizer"]
        self.assertIn(organizer.get("email") or organizer["name"], err)
        # And it must say what to do instead, since no API can propose a time.
        self.assertIn("Propose New Time", err)

        # Nothing was written.
        after = run_json("show", event["id"], *(
            ["--occurrence", event["occurrence"]] if event.get("occurrence") else []
        ))
        self.assertEqual(after["title"], event["title"])

    def test_the_guard_does_not_fire_on_an_event_you_organize(self):
        """A fixture event has no organizer at all, so `edit` must proceed."""
        event = self.add("guard-noop", "--start", f"{TEST_YEAR}-04-20 09:00")
        run("edit", event["id"], "--title", self.title("guard-noop-renamed"))
        self.assertTrue(
            self.get(event["id"])["title"].endswith("guard-noop-renamed"))


class LongRangeQueries(LiveCalendarTest):
    """Ranges longer than four years.

    🛑 **`predicateForEvents` clamps the end to exactly four years after the
    start, and says nothing.** No error, no warning, and a result that reads as
    complete. Measured on 26.819.0: `events --from 2008-01-01 --to 2026-12-31`
    returned 1,138 events and stopped in 2011.

    That is how it was found — an 18-year search for a wedding came back empty
    and looked like an answer. `events` now pages the range into windows EventKit
    will honour.
    """

    def test_a_range_over_four_years_reaches_the_far_end(self):
        """The fixture sits in the fifth year, which the clamp would cut off."""
        created = self.add("longrange", "--start", f"{TEST_YEAR}-06-15 09:00",
                           "--no-confirm-sync")
        _, out, _ = run("events",
                        "--from", f"{TEST_YEAR - 5}-01-01",
                        "--to", f"{TEST_YEAR}-12-31", "--json")
        titles = [e["title"] for e in json.loads(out)]
        self.assertIn(created["title"], titles,
                      "an event in the fifth year was lost to the four-year clamp")

    def test_it_says_when_it_paged(self):
        _, _, err = run("events",
                        "--from", f"{TEST_YEAR - 5}-01-01",
                        "--to", f"{TEST_YEAR}-12-31", "--json")
        self.assertIn("4 years", err)
        self.assertIn("windows", err)

    def test_a_short_range_is_not_paged_and_says_nothing(self):
        """⚠️ The note must not appear for a range that never needed splitting."""
        _, _, err = run("events",
                        "--from", f"{TEST_YEAR}-01-01",
                        "--to", f"{TEST_YEAR}-12-31", "--json")
        self.assertNotIn("windows", err)

    def test_paging_does_not_change_what_a_short_range_returns(self):
        """🛑 The guard that caught a real regression.

        The first version keyed its de-duplication on identifier plus start, and
        dropped 6 of 4,755 events on a range that needed no paging at all. One
        event visible through two calendars comes back once per calendar with the
        SAME identifier and start, so the calendar belongs in the key.
        """
        # ⚠️ --no-confirm-sync: these fixtures exist to be read back, and the
        # suite outruns what one Exchange calendar confirms in 30s.
        self.add("dedup-a", "--start", f"{TEST_YEAR}-04-01 09:00", "--no-confirm-sync")
        self.add("dedup-b", "--start", f"{TEST_YEAR}-04-01 09:00", "--no-confirm-sync")
        _, out, _ = run("events",
                        "--from", f"{TEST_YEAR}-04-01",
                        "--to", f"{TEST_YEAR}-04-02", "--json")
        mine = [e for e in json.loads(out) if e["title"].startswith(TEST_PREFIX)]
        self.assertEqual(len(mine), 2, "two distinct events must not collapse into one")


class UnconfirmedIsNotAFailure(LiveCalendarTest):
    """A write the server has not confirmed, versus one it refused.

    🛑 **These are different answers and the tool used to report both as
    failure.** The confirmation exists for a write a server REFUSES — Google
    answering 403, EventKit recording an `Error` row and never retrying. A write
    that is merely slow to confirm is not that.

    Measured: two full suite runs a day apart, both at a 120s deadline, each left
    7 of 71 writes unconfirmed — and `unsynced` reported "Everything has reached
    its server" straight afterwards, every time.

    ⚠️ Not a test-only condition. One `edit` on a real shared calendar hit it
    during ordinary use, printed a failure, and the change was already live.

    `--sync-timeout 0` forces the path deterministically. There is no way to make
    a healthy server slow on purpose.

    🛑 **These use `add`, never `edit`, and that is not arbitrary.** On Exchange
    an edit records nothing locally, so it resolves to `unknown` rather than
    `pending` and takes a different branch entirely — exit 0 with a note. A first
    draft of this class used `edit` and failed on exactly that.
    """

    def slow_add(self, suffix, *extra):
        """An add whose confirmation cannot possibly finish."""
        return run("add", self.title(suffix), "--calendar", self.calendar,
                   "--start", f"{TEST_YEAR}-08-01 09:00",
                   "--sync-timeout", "0", *extra, check=False)

    def test_an_unconfirmed_write_exits_75_not_64(self):
        """⚠️ 75 is EX_TEMPFAIL. 64 is EX_USAGE and claimed the command was
        typed wrong, which printed a usage block under a server problem."""
        code, _, _ = self.slow_add("tempfail")
        self.assertEqual(code, 75)

    def test_it_still_prints_the_event(self):
        """🛑 The concrete defect. A --json caller got a usage block and no id.

        With nothing printed there is no identifier to pass to `sync-status`, so
        the caller could not even find out whether the write landed.
        """
        _, out, _ = self.slow_add("tempfail-json", "--json")
        event = json.loads(out)
        self.assertTrue(event["id"])
        self.assertEqual(event["sync"]["state"], "pending")

    def test_the_message_does_not_claim_the_server_refused_it(self):
        _, _, err = self.slow_add("tempfail-words")
        self.assertIn("could not confirm", err)
        self.assertIn("sync-status", err, "the reader needs the command to check with")
        self.assertNotIn("has not accepted", err)
        # ⚠️ Nothing was typed wrong, so no usage block.
        self.assertNotIn("Usage:", err)

    def test_the_local_write_really_did_happen(self):
        """Exit 75 says nothing about the server, and everything about EventKit."""
        _, out, _ = self.slow_add("tempfail-local", "--json")
        created = json.loads(out)
        self.assertEqual(run_json("show", created["id"])["title"], created["title"])

    def test_a_confirmed_write_still_exits_zero(self):
        """The ordinary path must not have moved."""
        code, out, _ = run("add", self.title("tempfail-ok"),
                           "--calendar", self.calendar,
                           "--start", f"{TEST_YEAR}-08-05 09:00", "--json")
        self.assertEqual(code, 0)
        self.assertIn(json.loads(out)["sync"]["state"],
                      ("synced", "notApplicable", "unknown"))
