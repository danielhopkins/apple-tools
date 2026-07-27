"""
Attachment behavior tests.

These lock in the observed behavior of the AppleScript attachment API on this
macOS version, including the known double-insertion bug. If Apple changes the
behavior, the relevant test fails and that is a signal to update docs/apple-notes-api.md.
"""

import os
import tempfile
import unittest

from tests import harness as h


def setUpModule():
    h.ensure_live_or_skip()
    h.sweep_test_notes()  # clear any leftovers from a crashed prior run


def tearDownModule():
    h.sweep_test_notes()


class AttachmentTests(unittest.TestCase):
    def _temp_file(self, content: bytes = b"hello from the attachment test\n", suffix=".txt") -> str:
        fd, path = tempfile.mkstemp(prefix="claude_attach_", suffix=suffix)
        with os.fdopen(fd, "wb") as f:
            f.write(content)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def test_attach_file_succeeds(self):
        """A file can be attached and is reported on the note."""
        path = self._temp_file()
        with h.temp_note() as note_id:
            attach_id = h.add_attachment(note_id, path)
            self.assertIn("ICAttachment", attach_id)
            self.assertGreaterEqual(h.count_attachments(note_id), 1)

    def test_attachment_metadata_is_readable(self):
        """Attachment exposes name, content-id, and shared flag (all read-only)."""
        path = self._temp_file(suffix=".txt")
        with h.temp_note() as note_id:
            h.add_attachment(note_id, path)
            infos = h.attachment_info(note_id)
            self.assertTrue(infos)
            first = infos[0]
            self.assertTrue(first["name"].endswith(".txt"))
            self.assertTrue(first["cid"].startswith("cid:"))
            self.assertFalse(first["shared"])

    def test_attachment_properties_are_read_only(self):
        """There is no write path for attachment properties (add-only API)."""
        path = self._temp_file()
        with h.temp_note() as note_id:
            attach_id = h.add_attachment(note_id, path)
            with self.assertRaises(h.AppleScriptError):
                h.osascript(
                    f'tell application "Notes" to set name of attachment id '
                    f'{h._as_str(attach_id)} of note id {h._as_str(note_id)} to "renamed"'
                )

    def test_make_attachment_double_inserts(self):
        """KNOWN BUG: one `make new attachment` call inserts the file twice.

        Verified two ways: AppleScript reports 2 attachments, and the decoded
        note text contains 2 object-replacement chars. If this starts returning
        1, Apple fixed the bug — update the docs and this assertion.
        """
        path = self._temp_file()
        with h.temp_note() as note_id:
            h.add_attachment(note_id, path)
            self.assertEqual(
                h.count_attachments(note_id), 2,
                "expected the known double-insertion; behavior may have changed",
            )

            # The second placeholder syncs to SQLite with a lag, so poll for it.
            pk = h.pk_from_note_id(note_id)

            def two_placeholders():
                t = h.sqlite_note_text(pk)
                return t is not None and h.object_replacement_count(t) == 2

            self.assertTrue(
                h.poll(two_placeholders, timeout=20),
                "SQLite view should also settle on two inline attachment placeholders",
            )

    def test_attachment_visible_via_sqlite_read_path(self):
        """The CLI's SQLite/protobuf read path surfaces attachments as U+FFFC placeholders."""
        path = self._temp_file()
        with h.temp_note(body_html="<div>body before attachment</div>") as note_id:
            h.add_attachment(note_id, path)
            pk = h.pk_from_note_id(note_id)
            text = h.poll(lambda: h.sqlite_note_text(pk))
            self.assertIsNotNone(text)
            self.assertGreaterEqual(h.object_replacement_count(text), 1)

    def test_export_renders_attachment_not_bare_placeholder(self):
        """The exporter renders an attachment as [attachment: ...], never a bare U+FFFC."""
        path = self._temp_file()
        with h.temp_note(body_html="<div>body before attachment</div>") as note_id:
            h.add_attachment(note_id, path)
            pk = h.pk_from_note_id(note_id)
            md = h.poll(lambda: (h.export_markdown(pk) or "") if "[attachment:" in (h.export_markdown(pk) or "") else "")
            self.assertTrue(md, "attachment never rendered into the export")
            self.assertNotIn("￼", md)

    def test_editing_body_destroys_attachments(self):
        """DATA-LOSS BUG: `body` is lossy for attachments, so any write to it
        (even an "append" that round-trips the body) deletes every attachment.

        The first body edit drops the count to 0; it is not gradual. If this
        starts preserving attachments, Apple fixed it — update the docs.
        """
        path = self._temp_file()
        with h.temp_note(body_html="<div>original</div>") as note_id:
            h.add_attachment(note_id, path)
            self.assertGreaterEqual(h.count_attachments(note_id), 1)

            # The body HTML does not even reference the attachment.
            self.assertNotIn("￼", h.get_body(note_id))

            # A single body round-trip edit wipes all attachments.
            h.append_body(note_id, "<div>an edit</div>")
            self.assertEqual(
                h.count_attachments(note_id), 0,
                "editing body unexpectedly preserved attachments — behavior may have changed",
            )

    def test_export_renders_divider_as_thematic_break(self):
        """An HR/divider exports as `---`, padded so it is not parsed as a setext heading."""
        title = h.unique_title("hr")
        body = f"<div><h1>{title}</h1></div><div>line before</div><div><hr></div><div>line after</div>"
        with h.temp_note(body_html=body) as note_id:
            pk = h.pk_from_note_id(note_id)
            md = h.poll(lambda: (h.export_markdown(pk) or "") if "---" in (h.export_markdown(pk) or "") else "")
            self.assertTrue(md, "divider never rendered into the export")
            self.assertNotIn("￼", md)
            # blank line before the rule prevents "line before\n---" -> setext H2
            self.assertIn("line before\n\n---", md)


if __name__ == "__main__":
    unittest.main()
