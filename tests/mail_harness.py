"""Harness for the live apple-mail draft tests.

Creating messages is the least reliable corner of Mail's AppleScript interface,
so the checks here go through the RFC822 `source` of each draft rather than the
scripting properties. That is not fussiness — reading `to recipients`,
`cc recipients` and `bcc recipients` off a saved draft returns the *last-added
recipient for all three lists*, so a property-based test would pass while the
message was wrong, or fail while it was right.

Cleanup has exactly one working route. Tried against real drafts:

    delete <message>                    silently does nothing
    move <message> to mailbox "..."     errors
    set deleted status to true          "Connection is invalid"
    set mailbox of <message> to ...     WORKS

Trash mailboxes are named differently per account type, hence TRASH_NAMES.

Two things make the working route look broken if you get them wrong, and both
cost real debugging time here:

  1. The Drafts enumeration is stale within a single script run. A loop that
     re-scans after each move keeps finding messages it already moved, so it
     burns its iteration budget re-moving them and leaves the rest behind — it
     reports dozens of "moves" and clears nothing. SWEEP collects ids first and
     moves each exactly once.
  2. A move occasionally reports success without taking effect. With a batch of
     eight, seven cleared instantly and one needed another pass, so sweep()
     repeats until the count reaches zero.

Even so, sweep() is best effort and no test asserts on a global draft count —
tests scope assertions to their own unique marker.

Keep the Apple Event volume down. Mail stops responding under sustained
scripting load: a run that swept after every test wedged it so thoroughly that
`count of accounts` timed out (-1712) for minutes afterwards. Sweep once per
class, not once per test.
"""

import unicodedata

import email
import json
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TEST_PREFIX = "__claude_mail_test__"
ENV_FLAG = "RUN_LIVE_MAIL_TESTS"

# Mailboxes Mail uses for deleted items, which differ per account type
# (IMAP / Exchange / Google).
TRASH_NAMES = ["Deleted Messages", "Trash", "Deleted Items", "Bin"]


def binary(name):
    for candidate in (ROOT / "swift/.build/release" / name, ROOT / "swift/.build/debug" / name):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    from shutil import which

    found = which(name)
    if not found:
        raise RuntimeError(f"{name} not built; run 'make build'")
    return found


def mail(*args, check=True, stdin=None):
    proc = subprocess.run(
        [binary("apple-mail"), *args], capture_output=True, text=True, input=stdin
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"apple-mail {' '.join(args)} failed ({proc.returncode})\n"
            f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc.returncode, proc.stdout, proc.stderr


class MailWedged(AssertionError):
    """Mail stopped servicing Apple Events and needs restarting."""


# Every osascript call gets a deadline. Without one, a single Apple Event to a
# wedged Mail blocks forever: a suite that normally takes 26s ran for eleven
# minutes before it was killed, having produced no output at all.
OSASCRIPT_TIMEOUT = 20

# Mail rarely hangs outright — it *degrades*, and a generous timeout sails
# straight past that. With a 45s deadline a suite once crawled for ten minutes
# with every call slow but none slow enough to trip. A healthy call here is
# ~0.2s, so seconds mean trouble, and trouble that repeats means Mail is on its
# way down and the run should stop while it can still say so.
SLOW_CALL_SECONDS = 5
SLOW_CALLS_BEFORE_GIVING_UP = 3
_consecutive_slow = 0


def osascript(source, *args, timeout=OSASCRIPT_TIMEOUT):
    global _consecutive_slow
    started = time.monotonic()
    try:
        proc = subprocess.run(
            ["/usr/bin/osascript", "-e", source, *args],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        _consecutive_slow = 0
        raise MailWedged(
            f"Mail did not answer an Apple Event within {timeout}s.\n{WEDGED_ADVICE}"
        ) from None

    elapsed = time.monotonic() - started
    if elapsed >= SLOW_CALL_SECONDS:
        _consecutive_slow += 1
        if _consecutive_slow >= SLOW_CALLS_BEFORE_GIVING_UP:
            _consecutive_slow = 0
            raise MailWedged(
                f"{SLOW_CALLS_BEFORE_GIVING_UP} Apple Events in a row took over "
                f"{SLOW_CALL_SECONDS}s (last: {elapsed:.0f}s). Mail is going under; "
                f"stopping before it locks up.\n{WEDGED_ADVICE}")
    else:
        _consecutive_slow = 0

    if proc.returncode != 0:
        # -1712 is the Apple Event timeout; Mail raises it once it is far
        # enough behind that it cannot service the request at all.
        if "-1712" in proc.stderr or "timed out" in proc.stderr.lower():
            raise MailWedged(f"Mail returned an Apple Event timeout.\n{WEDGED_ADVICE}")
        raise AssertionError(f"osascript failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


WEDGED_ADVICE = (
    "Mail.app's scripting interface is wedged — it stops servicing Apple Events\n"
    "under sustained volume and does not recover on its own. Quit and reopen\n"
    "Mail.app, then re-run. If it will not quit:\n"
    "    kill -9 $(pgrep -f 'Mail.app/Contents/MacOS/Mail') && open -a Mail"
)


def mail_running():
    # `comm` is the full executable path, so match on that rather than the
    # process name — `pgrep -x Mail` does not match a running Mail.app.
    return subprocess.run(
        ["/usr/bin/pgrep", "-f", "Mail.app/Contents/MacOS/Mail"],
        capture_output=True,
    ).returncode == 0


# A wedged Mail still answers trivial requests: `tell application "Mail" to
# return name` came back instantly from an app macOS was reporting as "not
# responding". The probe therefore has to touch a mailbox, which is the thing
# a wedged Mail cannot do.
HEALTH_PROBE = """
tell application "Mail" to return (count of messages of mailbox "Drafts" of account 1) as string
"""


def mail_responsive(timeout=20):
    """Whether Mail can still do real work, not just answer static properties."""
    if not mail_running():
        return False
    try:
        proc = subprocess.run(
            ["/usr/bin/osascript", "-e", HEALTH_PROBE],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False
    # A wedged Mail returns success with empty output as readily as it errors.
    return proc.returncode == 0 and proc.stdout.strip() != ""


FIND_SOURCE = """
on run argv
  set needle to item 1 of argv
  tell application "Mail"
    repeat with acct in every account
      try
        repeat with m in messages of (mailbox "Drafts" of acct)
          if subject of m contains needle then return source of m
        end repeat
      end try
    end repeat
  end tell
  return ""
end run
"""

COUNT_DRAFTS = """
on run argv
  set needle to item 1 of argv
  set n to 0
  tell application "Mail"
    repeat with acct in every account
      try
        repeat with m in messages of (mailbox "Drafts" of acct)
          if subject of m contains needle then set n to n + 1
        end repeat
      end try
    end repeat
  end tell
  return n as string
end run
"""

# `delete` no-ops on drafts and `move` errors; reassigning `mailbox` works.
SWEEP = """
on run argv
  set needle to item 1 of argv
  set n to 0
  tell application "Mail"
    repeat with acct in every account
      try
        -- Collect every match FIRST, then move each exactly once. Re-scanning
        -- after each move burns iterations: the moved message keeps appearing
        -- in the enumeration within the same script run, so a rescanning loop
        -- can exhaust its budget on messages it already handled and leave the
        -- rest behind.
        set doomed to {}
        repeat with m in messages of (mailbox "Drafts" of acct)
          if subject of m contains needle then set end of doomed to (id of m)
        end repeat
        repeat with mid in doomed
          try
            set m to (first message of (mailbox "Drafts" of acct) whose id is mid)
            set moved to false
            repeat with tn in {TRASH_LIST}
              if not moved then
                try
                  set mailbox of m to mailbox tn of acct
                  set moved to true
                  set n to n + 1
                end try
              end if
            end repeat
          end try
        end repeat
      end try
    end repeat
  end tell
  return n as string
end run
""".replace("TRASH_LIST", ", ".join(f'"{name}"' for name in TRASH_NAMES))


# Reads go through the file-system engine, writes through AppleScript.
#
# Mail's scripting interface has a hard ceiling on Apple Event volume: past it
# the app stops answering and has to be force-quit. Enumerating Drafts is among
# the most expensive things to ask for, and the read helpers below are called
# by nearly every test, so on AppleScript they dominated the suite's event
# budget — enough that adding six tests wedged Mail three times.
#
# The index carries the same information for a fraction of the cost (0.03s vs
# 0.19s) and is *fresher*: a new draft appears immediately, while a moved one
# lingers in the scripting enumeration for ~135s waiting on the IMAP expunge.
# Both helpers fall back to AppleScript when the index cannot be read, so a
# machine without Full Disk Access still runs the suite — slowly.


def _index_drafts():
    """Draft summaries from Mail's own index. None if it cannot be read."""
    code, out, _ = mail(
        "search", "", "--mailbox", "drafts", "--limit", "999", "--json",
        "--engine", "filesystem", check=False)
    if code != 0:
        return None
    try:
        return json.loads(out or "[]")
    except ValueError:
        return None


def find_draft_source(marker):
    """RFC822 source of the newest draft whose subject contains `marker`."""
    drafts = _index_drafts()
    if drafts is None:
        return osascript(FIND_SOURCE, marker)
    for draft in drafts:
        if marker in draft["subject"]:
            code, out, _ = mail(
                "export", draft["id"], "--raw", "--engine", "filesystem", check=False)
            if code == 0:
                return out
            # In the index but not yet on disk; Mail can still produce it.
            return osascript(FIND_SOURCE, marker)
    return ""


def count_drafts(marker=TEST_PREFIX):
    drafts = _index_drafts()
    if drafts is None:
        return int(osascript(COUNT_DRAFTS, marker))
    return sum(1 for draft in drafts if marker in draft["subject"])


def sweep(marker=TEST_PREFIX, passes=2):
    """Move matching drafts to trash. Returns the number moved.

    Repeated because a move occasionally reports success without taking
    effect — with a batch of 8, seven cleared instantly and one needed another
    pass. Still best effort: never assert on the result.
    """
    moved = 0
    for _ in range(passes):
        try:
            moved += int(osascript(SWEEP, marker))
        except AssertionError:
            break
        if count_drafts(marker) == 0:
            break
        time.sleep(1)
    return moved


def same_text(left, right):
    """Compare ignoring unicode normalisation form.

    Mail stores message text as NFD, so text sent as NFC ("ü") comes back
    decomposed ("u" + combining diaeresis) — equal to a reader, unequal to ==.
    """
    return unicodedata.normalize("NFC", left) in unicodedata.normalize("NFC", right)


class LiveMailTest(unittest.TestCase):
    """Base class: enforces the gate and sweeps drafts around every test."""

    @classmethod
    def setUpClass(cls):
        if os.environ.get(ENV_FLAG) != "1":
            raise unittest.SkipTest(
                f"live mail tests are gated; run ./tests/run-tests --mail (sets {ENV_FLAG}=1)"
            )
        if not mail_running():
            raise unittest.SkipTest("Mail.app is not running")
        # Check before spending anything. A wedged Mail cannot be tested
        # against, and every call made to one blocks until its timeout — so
        # starting anyway turns a fast failure into a very slow one.
        if not mail_responsive():
            raise unittest.SkipTest(
                f"Mail.app is not answering Apple Events.\n{WEDGED_ADVICE}")
        sweep()

    @classmethod
    def tearDownClass(cls):
        try:
            sweep()
        except MailWedged:
            pass
        # A green suite that leaves Mail unusable is not a pass. Reported
        # rather than raised: unittest swallows tearDownClass errors into a
        # confusing traceback, and this needs to be the last thing read.
        if not mail_responsive():
            print(f"\n\n*** THIS SUITE WEDGED MAIL.APP ***\n{WEDGED_ADVICE}\n", file=sys.stderr)

    # Deliberately NO per-test tearDown sweep. Each sweep is several Apple
    # Events, and Mail stops answering entirely under sustained load — a
    # per-test sweep across 19 tests wedged it badly enough that even
    # `count of accounts` timed out for minutes afterwards. Sweeping once per
    # class keeps the event volume an order of magnitude lower; tests scope
    # their assertions to their own marker, so they do not need a clean
    # mailbox between cases.

    # -- helpers ----------------------------------------------------------- #

    def marker(self, suffix):
        return f"{TEST_PREFIX} {suffix}"

    def parsed(self, marker):
        """Parse a created draft from its RFC822 source."""
        raw = find_draft_source(marker)
        self.assertTrue(raw, f"no draft found matching {marker!r}")
        return email.message_from_string(raw)

    def bodies(self, message):
        """{content_type: decoded text} for the non-attachment parts."""
        out = {}
        for part in message.walk():
            if part.get_content_maintype() == "multipart" or part.get_filename():
                continue
            payload = part.get_payload(decode=True) or b""
            out[part.get_content_type()] = payload.decode("utf-8", "replace")
        return out

    def attachments(self, message):
        return [p.get_filename() for p in message.walk() if p.get_filename()]
