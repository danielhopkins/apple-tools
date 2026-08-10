"""Live tests for the guards that keep `apple mail` from wedging Mail.app.

Mail's scripting interface has one failure mode that matters more than all the
others: driven hard enough it stops servicing Apple Events, does not recover on
its own, and takes every other AppleScript client down with it. Three code paths
used to be able to cause that from a plain read command —

  1. a search without Full Disk Access silently fell back to AppleScript, which
     *launched* Mail and handed a cold app a whole-mailbox predicate;
  2. `--field content` asked Mail to materialise every body in the mailbox, and
     was a stderr warning rather than a refusal;
  3. every osascript ran without a deadline, so a Mail that had already stopped
     answering hung the CLI indefinitely and left an orphan osascript behind
     when the caller gave up.

These tests pin the guards that closed those. They are **read-only**: nothing
here creates, edits or deletes mail, so unlike the draft suite there is nothing
to sweep. The most expensive thing any of them does is one bounded health probe.

Two seams make this testable without breaking anything:

    APPLE_MAIL_INDEX_PATH     point the index reader at a path that does not
                              exist, to get the no-Full-Disk-Access behaviour
                              without touching a real grant
    APPLE_MAIL_PROBE_TIMEOUT  shrink the health probe's deadline so a *healthy*
                              Mail trips it, which is the only safe way to
                              exercise the give-up-and-kill path

Several tests need Mail *not* running (that is the state where launching it is
the bug) and several need it running; each skips in the wrong one, so the suite
is meaningful either way and complete over both.
"""

import json
import os
import subprocess
import time
import unittest
from pathlib import Path

from mail_harness import binary, mail_running

ENV_FLAG = "RUN_LIVE_MAIL_READ_TESTS"

# A path that cannot exist, to stand in for "the index is unreadable".
NO_INDEX = "/nonexistent/apple-tools-test/Envelope Index"

# Every osascript this suite could provoke carries the probe's source in its
# argv, which is how an orphan is spotted.
PROBE_FRAGMENT = "count of every mailbox of account 1"

# A refusal must be a decision, not a round trip. Anything that reaches Mail and
# comes back takes longer than this even when Mail is healthy.
NO_APPLE_EVENT_SECONDS = 2.0

# ArgumentParser's exit code for a ValidationError.
EXIT_VALIDATION = 64


def apple_mail():
    """The binary under test.

    `binary()` prefers the release build, which is normally right — but these
    tests assert on guard behaviour, so running them against a stale release
    build silently tests the old code and (worse) lets the unguarded AppleScript
    paths loose on Mail. Set APPLE_MAIL_BIN to test a specific build.
    """
    return os.environ.get("APPLE_MAIL_BIN") or binary("apple-mail")


def run(*args, env=None, timeout=120):
    """Invoke apple-mail with optional environment overrides."""
    environment = dict(os.environ)
    environment.update(env or {})
    started = time.monotonic()
    proc = subprocess.run(
        [apple_mail(), *args],
        capture_output=True,
        text=True,
        env=environment,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout, proc.stderr, time.monotonic() - started


def orphaned_osascripts():
    """PIDs of any osascript still running our probe."""
    proc = subprocess.run(
        ["/usr/bin/pgrep", "-f", PROBE_FRAGMENT], capture_output=True, text=True
    )
    return [line for line in proc.stdout.split() if line]


def index_readable():
    _, out, _, _ = run("status", "--json")
    try:
        return json.loads(out)["filesystem"]["readable"]
    except (ValueError, KeyError):
        return False


class MailGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get(ENV_FLAG) != "1":
            raise unittest.SkipTest(
                f"live mail read tests are gated; run ./tests/run-tests (sets {ENV_FLAG}=1)"
            )

    def setUp(self):
        # Recorded per test: a guard that leaks a Mail launch is the bug these
        # tests exist to catch, and it can only be judged against the state
        # going in.
        self.mail_was_running = mail_running()

    def assertDidNotLaunchMail(self):
        # Vacuous when Mail was already up, and that must not cost the rest of
        # the test: skipping here would have hidden every refusal assertion
        # above it. The suite is run with Mail closed to make this bite.
        if self.mail_was_running:
            return
        self.assertFalse(
            mail_running(),
            "a read command launched Mail.app — that is the wedge this guard prevents",
        )

    def assertRefusedFast(self, elapsed):
        self.assertLess(
            elapsed,
            NO_APPLE_EVENT_SECONDS,
            f"refusal took {elapsed:.1f}s, which is long enough to have asked Mail",
        )


class TestExpensivePredicatesAreRefused(MailGuardTest):
    """The queries that make Mail open every message body in a mailbox.

    Refused rather than warned about. The warning went to stderr while the
    request went to Mail regardless, so it protected nobody.
    """

    def test_content_search_is_refused(self):
        code, _, err, elapsed = run(
            "search", "invoice", "--engine", "applescript", "--field", "content"
        )
        self.assertEqual(code, EXIT_VALIDATION)
        self.assertIn("refusing", err.lower())
        self.assertIn("--field content", err)
        # A refusal that does not say what to do instead just gets retried.
        self.assertIn("Full Disk Access", err)
        self.assertRefusedFast(elapsed)
        self.assertDidNotLaunchMail()

    def test_field_all_is_refused(self):
        code, _, err, elapsed = run(
            "search", "invoice", "--engine", "applescript", "--field", "all"
        )
        self.assertEqual(code, EXIT_VALIDATION)
        self.assertIn("--field all", err)
        self.assertRefusedFast(elapsed)

    def test_has_attachment_is_refused(self):
        code, _, err, elapsed = run(
            "search", "invoice", "--engine", "applescript", "--has-attachment"
        )
        self.assertEqual(code, EXIT_VALIDATION)
        self.assertIn("--has-attachment", err)
        self.assertRefusedFast(elapsed)

    def test_the_same_searches_are_allowed_on_the_index(self):
        """The refusal is about the engine, not the query.

        Without this the guard could be 'body search is banned', which would be
        a regression dressed as a fix — the index does this in ~0.2s.
        """
        if not index_readable():
            self.skipTest("no readable Envelope Index (Full Disk Access)")
        for extra in (["--field", "content"], ["--field", "all"], ["--has-attachment"]):
            with self.subTest(extra=extra):
                code, out, err, _ = run(
                    "search", "invoice", "--limit", "1", "--json", "--since", "30", *extra
                )
                self.assertEqual(code, 0, err)
                self.assertIsInstance(json.loads(out), list)

    def test_subject_search_is_not_refused(self):
        """--field subject is cheap in Mail, so the guard must leave it alone."""
        if self.mail_was_running:
            self.skipTest("would drive a running Mail; the point is the refusal text")
        code, _, err, _ = run("search", "zzz", "--engine", "applescript")
        self.assertNotEqual(code, 0)  # Mail is down, so this fails — but not as a refusal
        self.assertNotIn("refusing `--field", err)
        self.assertNotIn("--has-attachment", err)


class TestNoSilentFallback(MailGuardTest):
    """A missing grant must not silently become 'drive Mail instead'."""

    def test_auto_search_reports_the_missing_grant(self):
        code, out, err, elapsed = run(
            "search", "invoice", env={"APPLE_MAIL_INDEX_PATH": NO_INDEX}
        )
        self.assertNotEqual(code, 0)
        self.assertIn("Full Disk Access", err)
        # The old behaviour, and the whole bug: a stderr note followed by driving
        # Mail anyway. The new text says it is *not* falling back, so match the
        # note's own shape rather than the phrase.
        self.assertNotIn("note: falling back", err.lower())
        # It has to name the escape hatch, or the only way out is guesswork.
        self.assertIn("--engine applescript", err)
        # An error, not an empty result set that reads as "no matches".
        self.assertNotIn("[]", out)
        self.assertRefusedFast(elapsed)
        self.assertDidNotLaunchMail()

    def test_explicit_filesystem_engine_names_the_override(self):
        """The seam has to explain itself, or it becomes a mystery FDA error."""
        code, _, err, _ = run(
            "search", "invoice", "--engine", "filesystem",
            env={"APPLE_MAIL_INDEX_PATH": NO_INDEX},
        )
        self.assertNotEqual(code, 0)
        self.assertIn("APPLE_MAIL_INDEX_PATH", err)

    def test_export_without_an_index_does_not_launch_mail(self):
        """export keeps its AppleScript fallback — but not at that price.

        Reading a message Mail has not downloaded is a real reason to ask Mail,
        so unlike search this path survives. It just may not start Mail to do it.
        """
        if self.mail_was_running:
            self.skipTest("Mail is running, so the fallback legitimately engages")
        code, _, err, _ = run(
            "export", "<nothing@example.com>", env={"APPLE_MAIL_INDEX_PATH": NO_INDEX}
        )
        self.assertNotEqual(code, 0)
        self.assertIn("not running", err)
        self.assertDidNotLaunchMail()

    def test_attachments_without_an_index_fails_cleanly(self):
        code, _, err, _ = run(
            "attachments", "<nothing@example.com>",
            env={"APPLE_MAIL_INDEX_PATH": NO_INDEX},
        )
        self.assertNotEqual(code, 0)
        self.assertIn("APPLE_MAIL_INDEX_PATH", err)
        self.assertDidNotLaunchMail()


class TestPreflightWithMailDown(MailGuardTest):
    """`tell application "Mail"` starts Mail. No read command may do that."""

    def setUp(self):
        super().setUp()
        if self.mail_was_running:
            self.skipTest("these assert what happens when Mail is NOT running")

    def test_applescript_search_refuses_to_launch_mail(self):
        code, _, err, elapsed = run("search", "zzz", "--engine", "applescript")
        self.assertNotEqual(code, 0)
        self.assertIn("not running", err)
        self.assertIn("Refusing to launch", err)
        self.assertRefusedFast(elapsed)
        self.assertDidNotLaunchMail()

    def test_applescript_export_refuses_to_launch_mail(self):
        code, _, err, elapsed = run(
            "export", "<nothing@example.com>", "--engine", "applescript"
        )
        self.assertNotEqual(code, 0)
        self.assertIn("not running", err)
        self.assertRefusedFast(elapsed)
        self.assertDidNotLaunchMail()

    def test_applescript_accounts_refuses_to_launch_mail(self):
        code, _, err, elapsed = run("accounts", "--engine", "applescript")
        self.assertNotEqual(code, 0)
        self.assertIn("not running", err)
        self.assertRefusedFast(elapsed)
        self.assertDidNotLaunchMail()

    def test_accounts_still_answers_from_the_store(self):
        """Refusing to launch Mail must not mean refusing to answer."""
        if not index_readable():
            self.skipTest("no readable Envelope Index (Full Disk Access)")
        code, out, err, _ = run("accounts", "--json")
        self.assertEqual(code, 0, err)
        self.assertIsInstance(json.loads(out), list)
        self.assertDidNotLaunchMail()


class TestPreflightWithMailUp(MailGuardTest):
    """The give-up path, exercised against a healthy Mail with a tiny deadline.

    There is no safe way to wedge Mail on purpose, so instead the probe's
    deadline is shrunk until a *working* Mail cannot beat it. Every branch after
    that point — the refusal, the child kill, the fallback — is the same code
    that runs against a genuinely wedged one.
    """

    # Small enough that a healthy Mail (~0.2s) trips it, not zero: the child
    # still has to be spawned for there to be anything to kill.
    IMPATIENT = {"APPLE_MAIL_PROBE_TIMEOUT": "0.05"}

    def setUp(self):
        super().setUp()
        if not self.mail_was_running:
            self.skipTest("these need Mail running; the probe has nothing to ask otherwise")

    def test_status_always_answers_and_answers_quickly(self):
        """🛑 `status` is the command that answers "is Mail wedged?", and it used
        to hang forever on exactly that condition.

        `AEDeterminePermissionToAutomateTarget` — the side-effect-free way to read
        the Automation grant — **blocks for minutes against a wedged Mail and then
        answers wrongly**. Measured: `AECreateDesc` returned in 0.000013s, the
        permission call returned -600 (`procNotFound`) after **502 seconds**, with
        Mail running at a known pid throughout. It runs before any of the deadline
        machinery, so `APPLE_MAIL_PROBE_TIMEOUT` did not help. It is bounded now,
        and a timeout is reported as `automation: "unknown"` — not as
        `mailNotRunning`, which is what the API's own eventual answer would have
        produced.

        This asserts the bound, not the wedge — there is no safe way to wedge Mail
        on purpose. A healthy Mail answers in well under a second; the ceiling here
        catches the unbounded call coming back.
        """
        code, out, err, elapsed = run("status", "--json")
        self.assertEqual(code, 0, err)
        self.assertLess(elapsed, 20, "status took too long; is the permission check bounded?")
        payload = json.loads(out)
        # It must always produce an answer for both halves, whatever Mail is doing.
        self.assertIn("automation", payload)
        self.assertIn("readable", payload["filesystem"])

    def test_status_reports_mail_responsive(self):
        code, out, err, _ = run("status", "--json")
        self.assertEqual(code, 0, err)
        payload = json.loads(out)
        self.assertTrue(payload["mail_app"]["running"])
        if payload["automation"] == "unknown":
            self.skipTest("Mail is wedged — quit and reopen Mail.app, then re-run")
        if payload["automation"] != "authorized":
            self.skipTest("Automation → Mail not granted, so status must not probe")
        # A healthy Mail answers; if this fails Mail really is wedged and the
        # rest of the suite is not what is broken.
        self.assertTrue(
            payload["mail_app"]["responsive"],
            "Mail is not answering Apple Events — quit and reopen Mail.app, then re-run",
        )

    def test_search_gives_up_instead_of_hanging(self):
        code, out, err, elapsed = run(
            "search", "zzz", "--engine", "applescript", env=self.IMPATIENT
        )
        self.assertNotEqual(code, 0)
        self.assertIn("wedged", err.lower())
        # The failure has to be legible as a timeout, not as "no matches" — the
        # old path printed [] and exited 0 here.
        self.assertNotIn("No messages found", out)
        self.assertLess(elapsed, 30, "the deadline did not fire")

    def test_giving_up_kills_the_child(self):
        """An orphan osascript keeps driving Mail after we have walked away.

        Ctrl-C on the CLI never reached it, so the deadline has to.
        """
        run("search", "zzz", "--engine", "applescript", env=self.IMPATIENT)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if not orphaned_osascripts():
                return
            time.sleep(0.25)
        self.fail(f"osascript survived the deadline: pids {orphaned_osascripts()}")

    def test_accounts_falls_back_to_the_store_when_mail_is_unresponsive(self):
        """The one case where degrading is right: the store has the same answer."""
        if not index_readable():
            self.skipTest("no readable Envelope Index (Full Disk Access)")
        code, out, err, _ = run("accounts", "--json", env=self.IMPATIENT)
        self.assertEqual(code, 0, err)
        self.assertIsInstance(json.loads(out), list)
        self.assertIn("on-disk store", err)

    def test_index_search_never_probes_mail(self):
        """The fast path must not have picked up a dependency on Mail answering.

        Same impatient probe timeout: if the index path consulted Mail at all,
        this would fail the way the AppleScript one does.
        """
        if not index_readable():
            self.skipTest("no readable Envelope Index (Full Disk Access)")
        code, out, err, _ = run(
            "search", "invoice", "--limit", "1", "--json", env=self.IMPATIENT
        )
        self.assertEqual(code, 0, err)
        self.assertIsInstance(json.loads(out), list)


class TestFastPathStillWorks(MailGuardTest):
    """Guards are worthless if they broke the thing they were guarding."""

    def setUp(self):
        super().setUp()
        if not index_readable():
            self.skipTest("no readable Envelope Index (Full Disk Access)")

    def test_subject_search(self):
        code, out, err, elapsed = run("search", "invoice", "--limit", "5", "--json")
        self.assertEqual(code, 0, err)
        self.assertIsInstance(json.loads(out), list)
        self.assertLess(elapsed, 10, "an index subject search should be milliseconds")
        self.assertDidNotLaunchMail()

    def test_listing_a_mailbox(self):
        code, out, err, _ = run(
            "search", "", "--mailbox", "inbox", "--limit", "3", "--json"
        )
        self.assertEqual(code, 0, err)
        self.assertIsInstance(json.loads(out), list)

    def test_status_shape(self):
        code, out, err, _ = run("status", "--json")
        self.assertEqual(code, 0, err)
        payload = json.loads(out)
        self.assertIn("mail_app", payload)
        self.assertIsInstance(payload["mail_app"]["running"], bool)

