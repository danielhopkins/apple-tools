"""
Editing behavior tests — lock in the AppleScript note-editing quirks so that a
future macOS change to any of them is caught.
"""

import unittest

from tests import harness as h


def setUpModule():
    h.ensure_live_or_skip()
    h.sweep_test_notes()


def tearDownModule():
    h.sweep_test_notes()


class EditingTests(unittest.TestCase):
    def test_set_body_is_full_replace(self):
        """Setting `body` replaces the whole note, it does not merge."""
        title = h.unique_title("replace")
        with h.temp_note(body_html=f"<div><h1>{title}</h1></div><div>original</div>") as note_id:
            h.set_body(note_id, f"<div><h1>{title}</h1></div><div>brand new</div>")
            self.assertIn("brand new", h.get_plaintext(note_id))
            self.assertNotIn("original", h.get_plaintext(note_id))

    def test_first_line_becomes_title(self):
        """The first line of the body silently becomes the note's name/title."""
        title = h.unique_title("titleline")
        with h.temp_note(body_html=f"<div>{title}</div><div>second line</div>") as note_id:
            self.assertEqual(h.get_name(note_id), title)

    def test_append_via_concatenation_works(self):
        """`set body to (body) & extra` appends to the existing content."""
        with h.temp_note() as note_id:
            h.append_body(note_id, "<div>APPENDED MARKER</div>")
            self.assertIn("APPENDED MARKER", h.get_plaintext(note_id))

    def test_plaintext_body_is_wrapped_in_div(self):
        """Setting a plain-text body wraps it in <div> rather than keeping it raw."""
        title = h.unique_title("plain")
        with h.temp_note() as note_id:
            h.set_body(note_id, f"{title} just plain text")
            self.assertIn("<div>", h.get_body(note_id))

    def test_h1_heading_roundtrip_loses_semantic_tag(self):
        """An <h1> comes back as font/size styling, not as an <h1> element."""
        title = h.unique_title("heading")
        with h.temp_note(body_html=f"<div><h1>{title}</h1></div><div>body</div>") as note_id:
            body = h.get_body(note_id)
            self.assertNotIn("<h1>", body.lower())
            self.assertTrue("font" in body.lower() or "px" in body.lower())

    def test_delete_moves_to_recently_deleted(self):
        """AppleScript `delete` is a soft delete: the note survives in Recently Deleted.

        Verified via SQLite because AppleScript refuses `container of` a
        soft-deleted note (-1728).
        """
        note_id = h.create_note(f"<div><h1>{h.unique_title('softdel')}</h1></div>")
        pk = h.pk_from_note_id(note_id)
        h.delete_note(note_id)
        moved = h.poll(lambda: h.sqlite_folder_name(pk) == "Recently Deleted")
        self.assertTrue(moved, "note never moved to Recently Deleted in the SQLite view")


if __name__ == "__main__":
    unittest.main()
