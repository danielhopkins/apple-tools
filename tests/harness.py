"""Shared harness for the live apple-tools integration suites.

These tests drive the real binaries against the user's real data. The safety
model mirrors notes/tests/harness.py:

  * nothing runs unless RUN_LIVE_CALENDAR_TESTS=1 (set by ./tests/run-tests)
  * every object the suite creates is named with TEST_PREFIX
  * teardown refuses to delete anything that lacks that prefix

The prefix is the *only* thing keeping the sweep off real data, so never relax
that check. Fixtures are dated in TEST_YEAR to keep them out of the way, but
note that is cosmetic, not isolation: open-ended recurring series project
arbitrarily far into the future, so the fixture window is full of real events
too (~600 on this machine).
"""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Every artifact these tests create carries this prefix. The sweep will not
# touch anything without it.
TEST_PREFIX = "__claude_calendar_test__"

# Keeps fixtures out of the current agenda. This is tidiness only — real
# recurring events also project into this year, so filtering is by prefix.
TEST_YEAR = 2099

ENV_FLAG = "RUN_LIVE_CALENDAR_TESTS"
CALENDAR_ENV = "APPLE_CALENDAR_TEST_CALENDAR"


def binary(name):
    """Prefer the release build, fall back to debug, then PATH."""
    for candidate in (
        ROOT / "swift/.build/release" / name,
        ROOT / "swift/.build/debug" / name,
    ):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)

    from shutil import which

    found = which(name)
    if not found:
        raise RuntimeError(f"{name} not built; run 'make build'")
    return found


CALENDAR = None  # resolved lazily so import doesn't fail on a clean checkout


def calendar_bin():
    global CALENDAR
    if CALENDAR is None:
        CALENDAR = binary("apple-calendar")
    return CALENDAR


def run(*args, check=True):
    """Invoke apple-calendar and return (returncode, stdout, stderr)."""
    proc = subprocess.run(
        [calendar_bin(), *args],
        capture_output=True,
        text=True,
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"apple-calendar {' '.join(args)} failed ({proc.returncode})\n"
            f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc.returncode, proc.stdout, proc.stderr


def run_json(*args):
    _, out, _ = run(*args, "--json")
    return json.loads(out)


def target_calendar():
    """The calendar fixtures are created in.

    Defaults to the store's default calendar for new events. Override with
    APPLE_CALENDAR_TEST_CALENDAR to keep test traffic off a shared calendar.
    """
    override = os.environ.get(CALENDAR_ENV)
    if override:
        return override

    writable = run_json("calendars", "--writable")
    if not writable:
        raise RuntimeError("no writable calendars available for testing")

    # Calendar titles are not unique, and --calendar matches by name: a title
    # shared with a read-only calendar makes every assertion here ambiguous.
    # Prefer a writable calendar whose title nothing else claims.
    titles = [c["title"].lower() for c in run_json("calendars")]
    unique = [c for c in writable if titles.count(c["title"].lower()) == 1]
    return (unique or writable)[0]["title"]


def window():
    """A --from/--to pair spanning the whole fixture year."""
    return [f"{TEST_YEAR}-01-01", f"{TEST_YEAR}-12-31"]


def find_test_events(calendar=None):
    """Every fixture event this suite owns, in the fixture year."""
    start, end = window()
    args = ["events", "--from", start, "--to", end]
    if calendar:
        args += ["--calendar", calendar]
    events = run_json(*args)
    return [e for e in events if e["title"].startswith(TEST_PREFIX)]


def sweep(calendar=None):
    """Delete every fixture event. Refuses anything without TEST_PREFIX."""
    removed = 0
    for event in find_test_events(calendar):
        if not event["title"].startswith(TEST_PREFIX):
            raise AssertionError(
                f"refusing to delete unprefixed event: {event['title']!r}"
            )
        args = ["delete", event["id"]]
        if event.get("recurring"):
            args.append("--series")
        code, _, err = run(*args, check=False)
        if code != 0:
            print(f"warning: could not delete {event['title']!r}: {err}", file=sys.stderr)
        else:
            removed += 1
    return removed


class LiveCalendarTest(unittest.TestCase):
    """Base class: enforces the gate and sweeps fixtures around every test."""

    @classmethod
    def setUpClass(cls):
        if os.environ.get(ENV_FLAG) != "1":
            raise unittest.SkipTest(
                f"live calendar tests are gated; run ./tests/run-tests "
                f"(sets {ENV_FLAG}=1)"
            )
        cls.calendar = target_calendar()
        sweep(cls.calendar)

    @classmethod
    def tearDownClass(cls):
        sweep(cls.calendar)

    def tearDown(self):
        sweep(self.calendar)

    # -- helpers ----------------------------------------------------------- #

    def title(self, suffix):
        return f"{TEST_PREFIX} {suffix}"

    def add(self, suffix, *extra):
        """Create a fixture event and return its JSON."""
        return run_json(
            "add", self.title(suffix), "--calendar", self.calendar, *extra
        )

    def get(self, event_id):
        return run_json("show", event_id)

    def exists(self, event_id):
        return any(e["id"] == event_id for e in find_test_events(self.calendar))
