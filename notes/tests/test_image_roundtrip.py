"""
Image round-trip tests — whether an attachment-preserving edit is possible.

CLAUDE.md long said a note's `body` "doesn't include attachments at all", so any
body write destroys them and there is no attachment-preserving edit path. That
is true for *file* attachments and false for *images*: Notes serialises an image
attachment into the body as a base64 `data:` URI, which means it can be
harvested before a write and restored after one.

The technique comes from antoniorodr/memo (see docs/prior-art.md). These tests
establish which half of it is real on this macOS version, and pin the one
seductive variant that silently loses data.
"""

import os
import re
import base64
import hashlib
import struct
import zlib
import tempfile
import unittest

from tests import harness as h


def setUpModule():
    h.ensure_live_or_skip()
    h.sweep_test_notes()


def tearDownModule():
    h.sweep_test_notes()


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
IMG_RE = re.compile(r'<img[^>]*src="data:image/(\w+);base64,([^"]+)"[^>]*/?>')


def data_uris(body: str) -> list[tuple[str, str]]:
    """Return [(ext, base64), ...] for every inline image in a note body."""
    return IMG_RE.findall(body)


def digest(b64: str) -> str:
    return hashlib.sha256(base64.b64decode(b64)).hexdigest()


class ImageRoundTripTests(unittest.TestCase):
    def _png(self, rgb=(220, 40, 40), size=8) -> str:
        """Write a tiny solid-colour PNG. Distinct colours give distinct bytes."""
        raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))

        def chunk(tag, data):
            c = tag + data
            return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

        png = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b"")
        )
        fd, path = tempfile.mkstemp(prefix="claude_img_", suffix=".png")
        with os.fdopen(fd, "wb") as f:
            f.write(png)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def _text_file(self) -> str:
        fd, path = tempfile.mkstemp(prefix="claude_txt_", suffix=".txt")
        with os.fdopen(fd, "wb") as f:
            f.write(b"a text attachment\n")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def _add_guarded(self, note_id: str, path: str, expected: int) -> None:
        """Attach a file and immediately undo the known double-insertion.

        `make new attachment` references the file twice in the note text; this
        deletes the surplus reference so the count lands on `expected`.
        """
        h.osascript(
            'tell application "Notes"\n'
            f"set n to note id {h._as_str(note_id)}\n"
            f"make new attachment at end of n with data (POSIX file {h._as_str(path)})\n"
            f"if (count of attachments of n) > {expected} then\n"
            "  delete last attachment of n\n"
            "end if\n"
            "end tell"
        )

    # ------------------------------------------------------------------ #
    def test_image_attachment_appears_in_body_as_data_uri(self):
        """An *image* attachment IS represented in `body`, as a base64 data URI.

        This is the exception to "body does not include attachments" and the
        whole reason an image-preserving edit is possible.
        """
        with h.temp_note(body_html="<div>before</div>", label="imgbody") as note_id:
            h.add_attachment(note_id, self._png())
            body = h.get_body(note_id)
            uris = data_uris(body)
            self.assertTrue(uris, "expected an inline <img src='data:image/...'> in the body")
            self.assertEqual(uris[0][0], "png")
            # the payload is the real image, not a thumbnail placeholder
            self.assertTrue(base64.b64decode(uris[0][1]).startswith(b"\x89PNG"))

    def test_file_attachment_is_invisible_in_body(self):
        """A non-image attachment is NOT represented in `body` — nothing to restore.

        The contrast with the test above is what makes the rule "images are
        recoverable, files are not" rather than a blanket statement.
        """
        with h.temp_note(body_html="<div>before</div>", label="filebody") as note_id:
            h.add_attachment(note_id, self._text_file())
            body = h.get_body(note_id)
            self.assertEqual(data_uris(body), [])
            self.assertNotIn("base64", body)
            # ...even though the note really does carry the attachment
            self.assertGreaterEqual(h.count_attachments(note_id), 1)

    def test_guarded_add_defeats_double_insert(self):
        """Deleting the surplus attachment right after the add fixes the count.

        test_make_attachment_double_inserts pins the bug; this pins the remedy,
        so a future `notes attach` can rely on it.
        """
        with h.temp_note(label="guarded") as note_id:
            self._add_guarded(note_id, self._png(rgb=(220, 40, 40)), expected=1)
            self.assertEqual(h.count_attachments(note_id), 1)

            self._add_guarded(note_id, self._png(rgb=(40, 40, 220)), expected=2)
            self.assertEqual(h.count_attachments(note_id), 2)

            # and the note text carries exactly two inline objects, not four
            self.assertEqual(len(data_uris(h.get_body(note_id))), 2)
            pk = h.pk_from_note_id(note_id)
            text = h.poll(
                lambda: (t := h.sqlite_note_text(pk)) and h.object_replacement_count(t) == 2 and t
            )
            self.assertTrue(text, "SQLite should settle on exactly two placeholders")

    def test_double_insert_is_one_attachment_referenced_twice(self):
        """The duplicate shares an attachment id — one record, two references.

        Worth pinning because the obvious "fix" (dedupe the attachments listing
        by id, as macnotesapp does) reports 1 and hides the fact that the user
        sees the image twice in the note.
        """
        with h.temp_note(label="dupeid") as note_id:
            h.add_attachment(note_id, self._png())
            ids = [
                line
                for line in h.osascript(
                    'tell application "Notes"\n'
                    f"set n to note id {h._as_str(note_id)}\n"
                    'set acc to ""\n'
                    "repeat with a in attachments of n\n"
                    "  set acc to acc & (id of a) & linefeed\n"
                    "end repeat\n"
                    "return acc\n"
                    "end tell"
                ).splitlines()
                if line.strip()
            ]
            self.assertEqual(len(ids), 2, "expected the known double-insertion")
            self.assertEqual(len(set(ids)), 1, "the two entries should share one id")
            # but the body really does show the image twice
            self.assertEqual(len(data_uris(h.get_body(note_id))), 2)

    def test_image_roundtrip_preserves_bytes_and_order(self):
        """The full recipe: harvest data URIs, rewrite the body, re-attach.

        Establishes that an image-preserving edit is genuinely possible — the
        restored images are byte-identical and in the original order.
        """
        red, blue = self._png(rgb=(220, 40, 40)), self._png(rgb=(40, 40, 220))
        with h.temp_note(body_html="<div>original</div>", label="roundtrip") as note_id:
            self._add_guarded(note_id, red, expected=1)
            self._add_guarded(note_id, blue, expected=2)

            before = h.get_body(note_id)
            harvested = data_uris(before)
            self.assertEqual(len(harvested), 2)
            before_digests = [digest(b64) for _ext, b64 in harvested]
            self.assertEqual(len(set(before_digests)), 2, "fixtures must be distinguishable")

            # the edit — a full body replace, which wipes every attachment
            title_div = before.split("</div>")[0] + "</div>"
            h.set_body(note_id, title_div + "<div>EDITED BODY</div>")
            self.assertEqual(h.count_attachments(note_id), 0)

            # restore each harvested image by decoding it back to a file
            for i, (ext, b64) in enumerate(harvested, start=1):
                fd, path = tempfile.mkstemp(prefix=f"claude_restore{i}_", suffix=f".{ext}")
                with os.fdopen(fd, "wb") as f:
                    f.write(base64.b64decode(b64))
                self.addCleanup(lambda p=path: os.path.exists(p) and os.remove(p))
                self._add_guarded(note_id, path, expected=i)

            after = h.get_body(note_id)
            after_digests = [digest(b64) for _ext, b64 in data_uris(after)]
            self.assertEqual(before_digests, after_digests, "images must survive byte-exact, in order")
            self.assertIn("EDITED BODY", after)

    def test_roundtrip_loses_original_filenames(self):
        """Known cost of the recipe: attachments are rebuilt, so names are lost.

        Callers should surface this rather than claim a clean round trip.
        """
        with h.temp_note(body_html="<div>x</div>", label="names") as note_id:
            h.add_attachment(note_id, self._png())
            original = {a["name"] for a in h.attachment_info(note_id)}
            self.assertTrue(any(n.endswith(".png") for n in original))

            harvested = data_uris(h.get_body(note_id))
            title_div = h.get_body(note_id).split("</div>")[0] + "</div>"
            h.set_body(note_id, title_div + "<div>edited</div>")

            ext, b64 = harvested[0]
            fd, path = tempfile.mkstemp(prefix="claude_renamed_", suffix=f".{ext}")
            with os.fdopen(fd, "wb") as f:
                f.write(base64.b64decode(b64))
            self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
            self._add_guarded(note_id, path, expected=1)

            restored = {a["name"] for a in h.attachment_info(note_id)}
            self.assertNotEqual(original, restored, "the original filename does not survive")

    def test_inline_data_uri_write_creates_unharvestable_attachment(self):
        """🛑 TRAP: writing an <img data:...> inline looks better and loses data.

        `set body` with an inline data URI *does* create a real attachment, and
        unlike `make new attachment` it lands at the right position in the text
        rather than at the end — so it looks like the superior technique.

        But the resulting attachment is nameless and the body never renders it
        back as an <img>. The next harvest finds nothing, so the following edit
        destroys the image silently. Use the delete-and-re-add recipe instead.
        """
        # harvest a data URI Notes itself produced
        with h.temp_note(label="src") as src_id:
            self._add_guarded(src_id, self._png(), expected=1)
            ext, b64 = data_uris(h.get_body(src_id))[0]

        with h.temp_note(body_html="<div>placeholder</div>", label="inline") as note_id:
            title_div = h.get_body(note_id).split("</div>")[0] + "</div>"
            h.set_body(
                note_id,
                title_div
                + "<div>ABOVE</div>"
                + f'<div><img src="data:image/{ext};base64,{b64}"/></div>'
                + "<div>BELOW</div>",
            )

            # the good half: a real attachment, positioned between the paragraphs
            self.assertEqual(h.count_attachments(note_id), 1)
            pk = h.pk_from_note_id(note_id)
            text = h.poll(lambda: h.sqlite_note_text(pk))
            self.assertIsNotNone(text)
            self.assertRegex(text, r"ABOVE\s*￼\s*BELOW")

            # the trap: it is nameless, and the body will not give it back
            self.assertTrue(
                any(a["name"] in ("", "missing value") for a in h.attachment_info(note_id)),
                "inline-written attachments come back nameless",
            )
            self.assertEqual(
                data_uris(h.get_body(note_id)), [],
                "if this starts returning the image, the inline path became safe — "
                "re-test the round trip and update docs/prior-art.md",
            )


if __name__ == "__main__":
    unittest.main()
