"""
Locked (password-protected) note handling.

A locked note keeps its `ZICCLOUDSYNCINGOBJECT` row but its body is encrypted:
`ZICNOTEDATA.ZDATA` is NULL, so there is nothing for the reader to decode. The
key comes from the user's note password (or the device passcode on iOS 16+),
which we neither hold nor should ask for — so these are detected and skipped
rather than surfaced as notes that mysteriously fail to parse.

Before this, `export` on a locked note printed "Failed to parse note content",
which blames the parser for content that was never there.

These tests build a **temporary copy** of the real store and flip
`ZISPASSWORDPROTECTED` on a throwaway row, so they run whether or not the user
happens to own a locked note, and never write to the real database.
"""

import os
import json
import shutil
import sqlite3
import tempfile
import subprocess
import unittest

from tests import harness as h

CLI = str(h.ROOT / "apple-notes")


def _sqlite_available():
    return os.path.exists(h.DB_PATH)


class LockedNoteTests(unittest.TestCase):
    """Runs against a copy of the store with a synthetic locked note."""

    @classmethod
    def setUpClass(cls):
        if not _sqlite_available():
            raise unittest.SkipTest("no NoteStore.sqlite on this machine")
        cls.tmpdir = tempfile.mkdtemp(prefix="claude_locked_")
        cls.db = os.path.join(cls.tmpdir, "NoteStore.sqlite")
        # Copy the store (plus WAL/SHM if present) so the fixture is consistent.
        for suffix in ("", "-wal", "-shm"):
            src = h.DB_PATH + suffix
            if os.path.exists(src):
                shutil.copy2(src, cls.db + suffix)

        conn = sqlite3.connect(cls.db)
        try:
            conn.execute("PRAGMA journal_mode=DELETE")
            row = conn.execute(
                "SELECT n.Z_PK FROM ZICCLOUDSYNCINGOBJECT n "
                "JOIN ZICNOTEDATA nd ON nd.ZNOTE = n.Z_PK "
                "WHERE n.ZTITLE1 IS NOT NULL AND n.ZMARKEDFORDELETION = 0 "
                "AND COALESCE(n.ZISPASSWORDPROTECTED,0) = 0 "
                "AND nd.ZDATA IS NOT NULL LIMIT 1"
            ).fetchone()
            if not row:
                raise unittest.SkipTest("no readable note to use as a fixture")
            cls.pk = row[0]
            cls.title = conn.execute(
                "SELECT ZTITLE1 FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK=?", (cls.pk,)
            ).fetchone()[0]
            # Make it look exactly like a real locked note: flagged, body gone.
            conn.execute(
                "UPDATE ZICCLOUDSYNCINGOBJECT SET ZISPASSWORDPROTECTED=1 WHERE Z_PK=?",
                (cls.pk,))
            conn.execute("UPDATE ZICNOTEDATA SET ZDATA=NULL WHERE ZNOTE=?", (cls.pk,))
            conn.commit()
        finally:
            conn.close()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmpdir", ""), ignore_errors=True)

    def run_cli(self, *args):
        """Run the real CLI against the fixture store."""
        env = dict(os.environ, HOME=self.tmpdir)
        # The CLI resolves the store under $HOME, so lay it out where it looks.
        target = os.path.join(
            self.tmpdir, "Library", "Group Containers", "group.com.apple.notes")
        os.makedirs(target, exist_ok=True)
        dest = os.path.join(target, "NoteStore.sqlite")
        if not os.path.exists(dest):
            for suffix in ("", "-wal", "-shm"):
                if os.path.exists(self.db + suffix):
                    shutil.copy2(self.db + suffix, dest + suffix)
        return subprocess.run(
            ["python3", CLI, *args], capture_output=True, text=True, env=env)

    # ------------------------------------------------------------------ #
    def test_export_refuses_with_a_specific_reason(self):
        """`export` names the lock instead of blaming the parser."""
        proc = self.run_cli("export", str(self.pk))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("password-protected", proc.stderr)
        self.assertNotIn(
            "Failed to parse note content", proc.stderr,
            "a locked note must not be reported as a parse failure",
        )

    def test_export_uses_a_distinct_exit_code(self):
        """Locked exits 2, so a caller can tell it from 'not found' (1)."""
        locked = self.run_cli("export", str(self.pk))
        missing = self.run_cli("export", "99999999")
        self.assertEqual(locked.returncode, 2)
        self.assertEqual(missing.returncode, 1)

    def test_search_skips_locked_notes_by_default(self):
        proc = self.run_cli("search", "--limit", "1000", "--json")
        ids = [n["id"] for n in json.loads(proc.stdout)]
        self.assertNotIn(self.pk, ids, "a locked note must not appear by default")

    def test_search_warns_that_something_was_skipped(self):
        """The omission is announced on stderr — never a silent gap."""
        proc = self.run_cli("search", "--limit", "1000", "--json")
        self.assertIn("password-protected", proc.stderr)
        self.assertIn("--include-locked", proc.stderr)

    def test_include_locked_lists_it_flagged(self):
        proc = self.run_cli("search", "--limit", "1000", "--include-locked", "--json")
        hits = [n for n in json.loads(proc.stdout) if n["id"] == self.pk]
        self.assertEqual(len(hits), 1, "--include-locked should list it")
        self.assertTrue(hits[0].get("locked"))

    def test_include_locked_suppresses_the_warning(self):
        proc = self.run_cli("search", "--limit", "1000", "--include-locked", "--json")
        self.assertNotIn("skipped", proc.stderr)

    def test_folder_listing_skips_locked_notes(self):
        proc = self.run_cli("folders", "--json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # the note is gone from its folder's contents, so no folder can list it
        for folder in json.loads(proc.stdout):
            listing = self.run_cli("folders", folder["title"], "--limit", "1000", "--json")
            if listing.returncode != 0:
                continue
            try:
                notes = json.loads(listing.stdout)
            except json.JSONDecodeError:
                continue
            self.assertNotIn(
                self.pk, [n.get("id") for n in notes],
                f"locked note leaked into folder {folder['title']!r}",
            )

    def test_get_url_still_works_and_flags_it(self):
        """A deep link is safe — Notes.app prompts — so it is reported, not refused."""
        proc = self.run_cli("get-url", str(self.pk), "--json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertTrue(payload.get("locked"))
        self.assertTrue(payload["url"].startswith("applenotes://"))

    def test_unlocked_notes_are_unaffected(self):
        """The filter must not cost us any ordinary note."""
        proc = self.run_cli("search", "--limit", "1000", "--json")
        notes = json.loads(proc.stdout)
        self.assertGreater(len(notes), 1)
        self.assertTrue(all(not n.get("locked") for n in notes))


if __name__ == "__main__":
    unittest.main()
