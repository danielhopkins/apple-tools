"""Live write-path tests for apple-calendar: add, edit, delete.

Every event created here is prefixed and swept; see harness.py for the safety
model. Run with ./tests/run-tests.
"""

from harness import TEST_YEAR, LiveCalendarTest, run, run_json


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
        read_only = [c for c in all_calendars if not c["allowsModification"]]
        if not read_only:
            self.skipTest("no read-only calendars on this machine")

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
