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

import datetime
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


# Subcommands that carry SyncConfirmationOptions. Anything else rejects the flag.
_SYNC_AWARE = {"add", "edit", "resync"}

# ⚠️ **The suite outruns what one Exchange calendar will confirm in 30s.**
# The tool's own default is 30, and for a person writing one event that is
# generous: six timed trials put create-to-`external_id` at 4 seconds, and a
# single write by hand still syncs in 6.
#
# 🛑 A burst is a different regime, and the numbers moved a long way in one day:
#
#   322s run, 71 tests   ->  3 writes timed out
#   928s run, 71 tests   -> 26 writes timed out
#
# Every one of those 26 was a healthy write the server simply had not confirmed
# yet, so the suite reported 26 failures for a tool that was working. Raising the
# wait here — not the tool's default — keeps the interactive experience unchanged
# while letting the suite give a clean signal.
#
# ⚠️ This does NOT weaken the sync-confirmation tests. They still assert that a
# write reaches the server; they simply get longer to find out.
SYNC_TIMEOUT = os.environ.get("APPLE_CALENDAR_TEST_SYNC_TIMEOUT", "120")


def _with_sync_timeout(args):
    """Give sync-aware subcommands a longer deadline, unless the caller set one."""
    if not args or args[0] not in _SYNC_AWARE:
        return args
    if any(a in ("--sync-timeout", "--no-confirm-sync") for a in args):
        return args
    return (*args, "--sync-timeout", SYNC_TIMEOUT)


def run(*args, check=True, env=None):
    """Invoke apple-calendar and return (returncode, stdout, stderr).

    `env` adds variables on top of the inherited environment — used only to set
    APPLE_CALENDAR_SIMULATE_LOST_WRITE, the seam that stands in for a save that
    reports success and changes nothing.
    """
    environment = None
    if env:
        environment = {**os.environ, **env}
    args = _with_sync_timeout(args)
    proc = subprocess.run(
        [calendar_bin(), *args],
        capture_output=True,
        text=True,
        env=environment,
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


def near_window():
    """The near-future range recurrence fixtures have to live in.

    🛑 **EventKit does not expand a recurring series 70-odd years out**, so a
    TEST_YEAR fixture cannot be used to assert on occurrences. Measured on this
    machine: an identical "every 2 weeks, 3 times" series reports **3**
    occurrences starting in 2026 and **1** starting in 2099, on both a Google
    and an iCloud calendar — the year is the only variable.

    So any test that checks where occurrences actually land must use real
    near-future dates, and those must be swept too or they leak into the user's
    live calendar. This window is what makes that safe.
    """
    today = datetime.date.today()
    return [today.isoformat(), (today + datetime.timedelta(days=800)).isoformat()]


def near_future(month_offset=2, day=1):
    """A date a couple of months out, for fixtures that need real expansion."""
    today = datetime.date.today()
    month = today.month + month_offset
    year = today.year + (month - 1) // 12
    return datetime.date(year, (month - 1) % 12 + 1, day)


def find_test_events(calendar=None):
    """Every fixture event this suite owns.

    Scans two ranges — the fixture year and the near-future window — because
    recurrence fixtures cannot live in TEST_YEAR (see near_window). Missing the
    second range would leave real events on a real calendar forever.
    """
    found = {}
    for start, end in (window(), near_window()):
        args = ["events", "--from", start, "--to", end]
        if calendar:
            args += ["--calendar", calendar]
        for event in run_json(*args):
            if event["title"].startswith(TEST_PREFIX):
                # Collapse occurrences of one series to its master, so the
                # sweep deletes the series rather than one instance at a time.
                found.setdefault(event["id"].split("/RID=")[0], event)
    return list(found.values())


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
            # --series removes the whole series. It used to need --future too,
            # because --series saved with EKSpan.thisEvent and deleted only the
            # first occurrence — fixed in 26.812.3.
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

# One writable calendar per distinct backend, so the same assertions can be run
# against each. Behaviour is *supposed* to be identical through the abstraction;
# these exist because it has not always been (see BACKENDS below).
BACKENDS_ENV = "RUN_LIVE_CALENDAR_BACKEND_TESTS"


BACKEND_CALENDARS_ENV = "APPLE_CALENDAR_TEST_CALENDARS"


def writable_backends():
    """[(label, calendar_title)] — one calendar per (source, type) pair.

    Deduped so the suite writes to as few real calendars as possible, and
    preferring a calendar whose title nothing else claims, since --calendar
    resolves by name.

    ⚠️ **The automatic pick can land on a shared calendar.** Nothing in EventKit
    says whether a calendar is shared with other people, so "first writable one
    per backend" can choose a team calendar whose members would briefly see the
    fixtures. Set APPLE_CALENDAR_TEST_CALENDARS to a comma-separated list to pin
    the choice, and note that ./tests/run-tests --backends prints what it picked
    before it writes anything.
    """
    override = os.environ.get(BACKEND_CALENDARS_ENV)
    if override:
        wanted = [name.strip() for name in override.split(",") if name.strip()]
        everything = {c["title"]: c for c in run_json("calendars")}
        chosen = []
        for name in wanted:
            calendar = everything.get(name)
            if calendar is None:
                raise RuntimeError(
                    f"{BACKEND_CALENDARS_ENV} names '{name}', which is not a calendar")
            if not calendar["allowsModification"]:
                raise RuntimeError(f"'{name}' is read-only")
            chosen.append(
                (f"{calendar.get('source','?')}/{calendar.get('type','?')}", name))
        return chosen

    everything = run_json("calendars")
    titles = [c["title"].lower() for c in everything]
    chosen = {}
    for calendar in everything:
        if not calendar["allowsModification"]:
            continue
        key = (calendar.get("source", "?"), calendar.get("type", "?"))
        unique = titles.count(calendar["title"].lower()) == 1
        # First unique-titled calendar wins; fall back to any.
        if key not in chosen or (unique and not chosen[key][1]):
            chosen[key] = (calendar["title"], unique)
    return [
        (f"{source}/{kind}", title)
        for (source, kind), (title, _) in sorted(chosen.items())
    ]
