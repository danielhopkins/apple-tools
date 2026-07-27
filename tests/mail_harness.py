"""Harness for the live apple-mail draft tests.

Creating messages is the least reliable corner of Mail's AppleScript interface,
so the checks here go through the RFC822 `source` of each draft rather than the
scripting properties. That is not fussiness — reading `to recipients`,
`cc recipients` and `bcc recipients` off a saved draft returns the *last-added
recipient for all three lists*, so a property-based test would pass while the
message was wrong, or fail while it was right.

Cleanup cannot be automated. Every route was tried against a real draft:

    delete <message>                    silently does nothing
    move <message> to mailbox "..."     errors
    set deleted status to true          "Connection is invalid"
    set mailbox of <message> to ...     reports success, moves nothing

The last one worked once early on and then stopped, which is worse than a
clean failure. So sweep() is best-effort only and nothing asserts on a global
draft count — tests scope their assertions to their own unique marker instead.
**Drafts created by this suite accumulate and have to be deleted by hand in
Mail.app.** That is called out in tests/run-tests before anything runs.
"""

import unicodedata

import email
import os
import subprocess
import sys
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


def osascript(source, *args):
    proc = subprocess.run(
        ["/usr/bin/osascript", "-e", source, *args], capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise AssertionError(f"osascript failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def mail_running():
    # `comm` is the full executable path, so match on that rather than the
    # process name — `pgrep -x Mail` does not match a running Mail.app.
    return subprocess.run(
        ["/usr/bin/pgrep", "-f", "Mail.app/Contents/MacOS/Mail"],
        capture_output=True,
    ).returncode == 0


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
        repeat 50 times
          set doomed to missing value
          repeat with m in messages of (mailbox "Drafts" of acct)
            if subject of m contains needle then
              set doomed to m
              exit repeat
            end if
          end repeat
          if doomed is missing value then exit repeat
          set moved to false
          repeat with tn in {TRASH_LIST}
            if not moved then
              try
                set mailbox of doomed to mailbox tn of acct
                set moved to true
                set n to n + 1
              end try
            end if
          end repeat
          if not moved then exit repeat
        end repeat
      end try
    end repeat
  end tell
  return n as string
end run
""".replace("TRASH_LIST", ", ".join(f'"{name}"' for name in TRASH_NAMES))


def find_draft_source(marker):
    """RFC822 source of the first draft whose subject contains `marker`."""
    return osascript(FIND_SOURCE, marker)


def count_drafts(marker=TEST_PREFIX):
    return int(osascript(COUNT_DRAFTS, marker))


def sweep(marker=TEST_PREFIX):
    """Best effort. Mail may report success and move nothing; see the module
    docstring. Never assert on the result."""
    try:
        return int(osascript(SWEEP, marker))
    except AssertionError:
        return 0


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
        sweep()

    @classmethod
    def tearDownClass(cls):
        sweep()

    def tearDown(self):
        sweep()

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
