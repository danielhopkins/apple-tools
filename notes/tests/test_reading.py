"""
Reading behavior tests — covers both read paths (AppleScript and the CLI's
SQLite/protobuf parser) and the known Recently-Deleted visibility gap.
"""

import unittest

from tests import harness as h


def setUpModule():
    h.ensure_live_or_skip()
    h.sweep_test_notes()


def tearDownModule():
    h.sweep_test_notes()


class ReadingTests(unittest.TestCase):
    def test_applescript_reads_body_and_plaintext(self):
        marker = "READ-MARKER-XYZ"
        with h.temp_note(body_html=f"<div>{marker}</div>") as note_id:
            self.assertIn(marker, h.get_body(note_id))
            self.assertIn(marker, h.get_plaintext(note_id))

    def test_sqlite_read_matches_applescript(self):
        """The CLI's SQLite/protobuf parse sees the same content AppleScript wrote."""
        marker = "CROSSREAD-MARKER-7788"
        with h.temp_note(body_html=f"<div>{marker}</div>") as note_id:
            pk = h.pk_from_note_id(note_id)
            text = h.poll(lambda: (h.sqlite_note_text(pk) or "") and marker in (h.sqlite_note_text(pk) or ""))
            self.assertTrue(text, "marker never showed up via the SQLite read path")

    def test_recently_deleted_is_visible_to_reader(self):
        """KNOWN GAP: the CLI's `ZMARKEDFORDELETION = 0` filter does not exclude
        notes in Recently Deleted, so soft-deleted notes still read as live.

        If this changes (e.g. the reader learns to exclude the trash folder, or
        Apple flips ZMARKEDFORDELETION on soft delete), update the docs and the
        reader's queries.
        """
        note_id = h.create_note(f"<div><h1>{h.unique_title('gap')}</h1></div>")
        self.addCleanup(lambda: h._silent_delete(note_id))
        pk = h.pk_from_note_id(note_id)
        h.delete_note(note_id)  # -> Recently Deleted

        # Soft delete confirmed via SQLite (AppleScript can't read its container).
        moved = h.poll(lambda: h.sqlite_folder_name(pk) == "Recently Deleted")
        self.assertTrue(moved, "note never moved to Recently Deleted")

        # ...yet it is still readable through the CLI's SQLite/protobuf path.
        self.assertIsNotNone(
            h.sqlite_note_text(pk), "soft-deleted note unexpectedly absent from reader"
        )


if __name__ == "__main__":
    unittest.main()
