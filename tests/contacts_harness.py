"""Shared harness for the live apple-contacts write suite.

These tests create and delete real contacts, and a contact write syncs to every
device on the account with no undo. The safety model is therefore stricter than
the calendar suite's:

  * nothing runs unless RUN_LIVE_CONTACTS_TESTS=1 (set by ./tests/run-tests)
  * every contact the suite creates has TEST_PREFIX as its *first name*
  * the sweep re-reads each contact and refuses to delete one whose first name
    is not exactly TEST_PREFIX — not "starts with", exactly
  * fixtures are found by searching for TEST_PREFIX, so the suite never
    enumerates, and never touches, the rest of the address book

The prefix check is the only thing standing between this suite and real
contacts. Never relax it to a prefix match or a name-contains match.

Groups get the same treatment: created with the prefix, deleted only when the
name matches exactly. Deleting a group keeps its members, so a missed group
sweep leaves clutter but never loses data.
"""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Every contact and group this suite creates carries this exact value in its
# first name / group name. The sweep will not delete anything else.
TEST_PREFIX = "__claude_contacts_test__"

ENV_FLAG = "RUN_LIVE_CONTACTS_TESTS"
BINARY_ENV = "APPLE_CONTACTS_BIN"

# Contacts writes go through contactsd over XPC and are not instant; a couple of
# these calls (notably the first after a permission grant) can take a while.
TIMEOUT = 90


def binary():
    """Resolve apple-contacts, preferring an explicit override.

    APPLE_CONTACTS_BIN exists because TCC grants are per binary path: a source
    build and an installed copy hold separate grants, so the one you just built
    may not be the one that has been approved. Both can be granted at once —
    they do not contend — but a binary without a grant fails slowly and badly
    (contactsd can wedge and leave calls hanging on XPC rather than returning a
    clean error), so point the suite at whichever copy is actually approved.
    """
    override = os.environ.get(BINARY_ENV)
    if override:
        return override

    for candidate in (
        ROOT / "swift/.build/release/apple-contacts",
        ROOT / "swift/.build/debug/apple-contacts",
    ):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)

    from shutil import which

    found = which("apple-contacts")
    if not found:
        raise RuntimeError("apple-contacts not built; run 'make build'")
    return found


CONTACTS = None


def contacts_bin():
    global CONTACTS
    if CONTACTS is None:
        CONTACTS = binary()
    return CONTACTS


def run(*args, check=True):
    """Invoke apple-contacts and return (returncode, stdout, stderr)."""
    try:
        proc = subprocess.run(
            [contacts_bin(), *args],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        raise AssertionError(
            f"apple-contacts {' '.join(args)} timed out after {TIMEOUT}s. "
            "A hung contactsd XPC connection usually means this binary has no "
            f"Contacts grant — check '{contacts_bin()} status', or set "
            f"{BINARY_ENV} to a copy that does."
        )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"apple-contacts {' '.join(args)} failed ({proc.returncode})\n"
            f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc.returncode, proc.stdout, proc.stderr


def run_json(*args):
    _, out, _ = run(*args)
    return json.loads(out)


def access_granted():
    """True when this binary can actually read contacts."""
    code, out, _ = run("status", "--json", check=False)
    if code != 0:
        return False
    try:
        return json.loads(out).get("usable") is True
    except (ValueError, AttributeError):
        return False


def find_test_contacts():
    """Every fixture contact this suite owns.

    Searches rather than lists, so the rest of the address book is never even
    read, let alone considered for deletion.
    """
    code, out, _ = run("search", TEST_PREFIX, "--limit", "200", check=False)
    if code != 0:
        return []
    try:
        found = json.loads(out)
    except ValueError:
        return []
    # Belt and braces: the search matches substrings across many fields, so
    # filter down to contacts whose first name is exactly the prefix.
    return [c for c in found if c.get("first_name") == TEST_PREFIX]


def find_test_groups():
    """Every fixture group, matched on an exact name."""
    code, out, _ = run("groups", "list", "--json", check=False)
    if code != 0:
        return []
    try:
        groups = json.loads(out)
    except ValueError:
        return []
    return [g for g in groups if g.get("name", "").startswith(TEST_PREFIX)]


def sweep():
    """Delete every fixture contact and group. Refuses anything unprefixed."""
    removed = 0

    for group in find_test_groups():
        if not group.get("name", "").startswith(TEST_PREFIX):
            raise AssertionError(f"refusing to delete unprefixed group: {group!r}")
        code, _, err = run("groups", "delete", group["id"], check=False)
        if code != 0:
            print(f"warning: could not delete group {group['name']!r}: {err}",
                  file=sys.stderr)

    for contact in find_test_contacts():
        # The single most important line in this file. Exact match only: a
        # startswith() here would put every real contact one bad search away
        # from deletion.
        if contact.get("first_name") != TEST_PREFIX:
            raise AssertionError(f"refusing to delete unprefixed contact: {contact!r}")
        code, _, err = run("delete", contact["id"], check=False)
        if code != 0:
            print(f"warning: could not delete {contact.get('name')!r}: {err}",
                  file=sys.stderr)
        else:
            removed += 1

    return removed


class LiveContactsTest(unittest.TestCase):
    """Base class: enforces the gate and sweeps fixtures around every test."""

    @classmethod
    def setUpClass(cls):
        if os.environ.get(ENV_FLAG) != "1":
            raise unittest.SkipTest(
                f"live contacts tests are gated; run ./tests/run-tests --contacts "
                f"(sets {ENV_FLAG}=1)"
            )
        if not access_granted():
            raise unittest.SkipTest(
                f"{contacts_bin()} has no Contacts grant. Run it once from a "
                f"terminal and approve the dialog, or set {BINARY_ENV} to a "
                "copy that already has one."
            )
        sweep()

    @classmethod
    def tearDownClass(cls):
        sweep()

    def tearDown(self):
        sweep()

    # -- helpers ----------------------------------------------------------- #

    def add(self, last, *extra):
        """Create a fixture contact and return its JSON."""
        return run_json(
            "add", "--first", TEST_PREFIX, "--last", last, *extra, "--json"
        )

    def get(self, contact_id):
        return run_json("get", contact_id)

    def edit(self, contact_id, *extra):
        return run_json("edit", contact_id, *extra, "--json")

    def exists(self, contact_id):
        return any(c["id"] == contact_id for c in find_test_contacts())

    def labelled(self, entries, key):
        """{label: value} from a list of {"label": ..., key: ...} dicts."""
        return {e["label"]: e[key] for e in entries}
