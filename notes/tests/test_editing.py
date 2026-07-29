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
        # 30s rather than the 10s default: the move to Recently Deleted lands in
        # SQLite well behind the AppleScript call, and the lag grows with how
        # busy Notes.app is — this flaked under the full suite while passing in
        # isolation. The assertion is unchanged; only the patience is.
        moved = h.poll(
            lambda: h.sqlite_folder_name(pk) == "Recently Deleted", timeout=30.0)
        self.assertTrue(moved, "note never moved to Recently Deleted in the SQLite view")


    def test_written_list_is_a_plain_bullet_not_a_checklist(self):
        """🛑 DATA LOSS: a body round trip flattens checklists into plain lists.

        A real Notes checklist comes back from `body` as a bare `<ul><li>` with
        **no** checkbox signal — no class, no data attribute, no checked state,
        no marker character. Verified by inspecting real checklist notes.

        This test pins the other half: HTML we write back as `<ul><li>` renders
        as a plain bullet (`- alpha`), never a checklist (`- [ ] alpha`). Put
        together, any body write turns every checklist on the note into a plain
        bulleted list and discards which items were ticked — invisibly, since
        the note still looks like a list.

        It applies to the innocuous-looking append pattern too, and there is no
        recovery: the state was never in the body to begin with. 7% of the notes
        on this machine (48 of 672) contain a checklist.
        """
        with h.temp_note(body_html="<div>X</div><ul><li>alpha</li><li>beta</li></ul>",
                         label="checklist") as note_id:
            pk = h.pk_from_note_id(note_id)
            md = h.poll(lambda: h.export_markdown(pk))
            self.assertTrue(md)
            self.assertIn("- alpha", md)
            self.assertNotRegex(
                md, r"- \[[ x]\] alpha",
                "if a written <ul><li> now produces a real checklist, Apple "
                "changed this — re-test and update docs/apple-notes-api.md",
            )


if __name__ == "__main__":
    unittest.main()
