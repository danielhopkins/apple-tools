"""What `apple notes delete` actually does, against live Notes.app.

🛑 **A delete is the one write here that removes something the user made.** It
is recoverable — the note moves to Recently Deleted and purges itself in about
30 days — but nothing in this repo, and no Apple API, can pull it back or empty
that folder. So the assertions are as much about the refusals as the delete.

⚠️ **The store settles a delete over minutes, not seconds.** Measured on this
machine while building the command: one delete showed in sqlite in 3.5s, and
another was still listed in `Notes` more than a minute later. AppleScript and
sqlite disagree in BOTH directions during that window. So the tests here assert
that an unconfirmed delete still exits 0, and they never assert that a delete
landed within a fixed time.

Gated behind RUN_LIVE_NOTES_TESTS: it creates real notes in iCloud and sweeps
them afterwards.
"""

import os
import time
import unittest

from tests import harness as h

cli = h.cli
LIVE = os.environ.get("RUN_LIVE_NOTES_TESTS") == "1"


UUID = None


def uuid():
    """The store UUID, read once. Every AppleScript note id is built from it."""
    global UUID
    if UUID is None:
        UUID = cli.store_uuid()
    return UUID


def is_deleted(pk):
    """Ask Notes.app whether a note is in Recently Deleted.

    🛑 **Never assert on the sqlite store here.** It lags an unbounded amount:
    measured on this machine, a note Notes.app already had in Recently Deleted
    still showed `ZFOLDER` = `Notes` more than ten minutes later. A test that
    waits for the store is a test that fails for a delete that worked.
    """
    return cli.applescript_note_deleted(pk, uuid()) == "deleted"


def is_live(pk):
    return cli.applescript_note_deleted(pk, uuid()) == "live"


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class DeleteRemovesTheNote(unittest.TestCase):
    """The claim: the note named, and only the note named, leaves the folder."""

    def setUp(self):
        h.sweep_test_notes()
        self.title = h.unique_title("del")
        self.note_id = h.create_note(
            "<div><h1>%s</h1></div><div>deleteme</div>" % self.title)
        self.pk = h.pk_from_note_id(self.note_id)

    def tearDown(self):
        h.sweep_test_notes()

    def test_the_note_leaves_its_folder(self):
        code, payload = h.delete_note_cli(self.pk)
        self.assertEqual(code, 0, payload.get("_stderr"))
        self.assertTrue(payload.get("deleted"))
        self.assertTrue(payload.get("confirmed"))
        self.assertTrue(is_deleted(self.pk), "the note is still in its folder")

    def test_it_reports_the_id_and_title_the_store_holds(self):
        code, payload = h.delete_note_cli(self.pk)
        self.assertEqual(code, 0, payload.get("_stderr"))
        self.assertEqual(payload.get("id"), self.pk)
        self.assertEqual(payload.get("title"), self.title)

    def test_a_lagging_store_does_not_fail_the_command(self):
        """🛑 The store is reported, never obeyed.

        `store_confirmed` is whatever sqlite said within --wait. The exit code
        must not depend on it, because the lag is unbounded: measured at 3.5s
        for one delete and over ten minutes for another.
        """
        code, payload = h.delete_note_cli(self.pk, extra=["--wait", "0"])
        self.assertEqual(code, 0, payload.get("_stderr"))
        self.assertTrue(payload.get("deleted"))
        self.assertTrue(payload.get("confirmed"),
                        "Notes.app should confirm even when sqlite has not")
        self.assertIn("store_confirmed", payload,
                      "the store's view must be reported separately")
        self.assertTrue(is_deleted(self.pk))

    def test_deleting_it_twice_is_refused(self):
        """The second call must not report a delete it did not do.

        ⚠️ The refusal reads the STORE, so it only fires once sqlite has caught
        up. Wait for that here rather than asserting on a fixed delay — this is
        the one test whose subject really is the store's own view.
        """
        code, _ = h.delete_note_cli(self.pk, extra=["--wait", "180"])
        self.assertEqual(code, 0)
        if cli.note_is_live(self.pk):
            self.skipTest("the sqlite store had not caught up within 180s")
        code, payload = h.delete_note_cli(self.pk)
        self.assertNotEqual(code, 0)
        self.assertIn("already in Recently Deleted", payload.get("_stderr", ""))

    def test_a_sibling_note_is_untouched(self):
        """⚠️ The delete is addressed by primary key, so nothing else moves."""
        other_id = h.create_note(
            "<div><h1>%s</h1></div><div>keepme</div>" % h.unique_title("keep"))
        other_pk = h.pk_from_note_id(other_id)
        code, _ = h.delete_note_cli(self.pk)
        self.assertEqual(code, 0)
        self.assertTrue(is_deleted(self.pk))
        self.assertTrue(is_live(other_pk),
                        "the delete took a note it was not given")


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class DeleteResolvesTargets(unittest.TestCase):
    """How a target is named, and which namings are refused."""

    def setUp(self):
        h.sweep_test_notes()

    def tearDown(self):
        h.sweep_test_notes()

    def _make(self, label="res"):
        title = h.unique_title(label)
        note_id = h.create_note("<div><h1>%s</h1></div><div>body</div>" % title)
        return title, h.pk_from_note_id(note_id)

    def test_an_exact_title_resolves(self):
        title, pk = self._make()
        code, payload = h.delete_note_cli(title)
        self.assertEqual(code, 0, payload.get("_stderr"))
        self.assertEqual(payload.get("id"), pk)

    def test_a_partial_title_is_refused(self):
        """🛑 `export` accepts a partial title. A delete must not.

        `find_note` falls through to `LIKE '%term%'` and returns the FIRST row,
        so a partial title on a delete would destroy whichever note sqlite
        happened to return first, silently.
        """
        title, pk = self._make()
        fragment = title[:-4]
        self.assertNotEqual(fragment, title)
        code, payload = h.delete_note_cli(fragment)
        self.assertNotEqual(code, 0, "a partial title must not name a target")
        self.assertIn("match in full", payload.get("_stderr", ""))
        self.assertTrue(is_live(pk), "it deleted the partial match")

    def test_an_ambiguous_title_is_refused_and_deletes_nothing(self):
        """Names are not unique, and deleting every match is unrecoverable."""
        title = h.unique_title("dupe")
        first = h.pk_from_note_id(h.create_note(
            "<div><h1>%s</h1></div><div>aaa</div>" % title))
        second = h.pk_from_note_id(h.create_note(
            "<div><h1>%s</h1></div><div>bbb</div>" % title))
        self.assertNotEqual(first, second)

        code, payload = h.delete_note_cli(title)
        self.assertNotEqual(code, 0)
        self.assertIn("refusing", payload.get("_stderr", "").lower())
        for pk in (first, second):
            self.assertTrue(is_live(pk),
                            "note %d was deleted despite the refusal" % pk)

    def test_an_unknown_id_is_refused(self):
        code, payload = h.delete_note_cli(99999999)
        self.assertNotEqual(code, 0)
        self.assertIn("not found", payload.get("_stderr", "").lower())


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class DeleteRequiresConsent(unittest.TestCase):
    """⚠️ A pipe is not consent. Without a tty, --yes is mandatory."""

    def setUp(self):
        h.sweep_test_notes()

    def tearDown(self):
        h.sweep_test_notes()

    def test_without_yes_and_without_a_tty_it_refuses(self):
        title = h.unique_title("consent")
        pk = h.pk_from_note_id(h.create_note(
            "<div><h1>%s</h1></div><div>body</div>" % title))
        code, payload = h.delete_note_cli(pk, yes=False)
        self.assertNotEqual(code, 0)
        self.assertIn("--yes", payload.get("_stderr", ""))
        self.assertTrue(is_live(pk),
                        "it deleted the note without being told to")


if __name__ == "__main__":
    unittest.main()
