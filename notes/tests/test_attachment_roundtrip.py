"""
Attachment round-trip tests — whether an attachment-preserving edit is possible.

CLAUDE.md long said a note's `body` "doesn't include attachments at all", so any
body write destroys them and there is no attachment-preserving edit path. That
is true for *file* attachments and false for *images*: Notes serialises an image
attachment into the body as a base64 `data:` URI, which means it can be
harvested before a write and restored after one.

The technique comes from antoniorodr/memo (see docs/prior-art.md). These tests
establish which half of it is real on this macOS version, and pin the two
seductive variants that silently lose data:

- writing a data URI back *inline*, which produces an attachment `body` can
  never return; and
- the double-insert guard, which is safe for images and **destroys a PDF**.

⚠️ Everything here is per-attachment-type. PDFs behave differently from images
at every step, so a test that passes for a PNG proves nothing about a PDF —
that mistake is exactly how the guard got documented as working.
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


class AttachmentRoundTripTests(unittest.TestCase):
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

    def _pdf(self) -> str:
        """A minimal but genuinely valid one-page PDF."""
        objs = [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] "
            b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            b"<< /Length 62 >>\nstream\nBT /F1 18 Tf 20 100 Td (test pdf) Tj ET\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        out = bytearray(b"%PDF-1.4\n")
        offsets = []
        for i, body in enumerate(objs, start=1):
            offsets.append(len(out))
            out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
        xref = len(out)
        out += b"xref\n0 %d\n" % (len(objs) + 1) + b"0000000000 65535 f \n"
        for off in offsets:
            out += b"%010d 00000 n \n" % off
        out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
            len(objs) + 1, xref
        )
        fd, path = tempfile.mkstemp(prefix="claude_pdf_", suffix=".pdf")
        with os.fdopen(fd, "wb") as f:
            f.write(bytes(out))
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

    def test_guarded_add_defeats_double_insert_for_images(self):
        """Deleting the surplus attachment right after the add fixes the count.

        test_make_attachment_double_inserts pins the bug; this pins the remedy.

        ⚠️ **Images only.** See test_guard_destroys_a_pdf — the identical script
        deletes a PDF outright. Do not generalise this test.
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

    def test_guard_destroys_a_pdf(self):
        """🛑 The double-insert guard is IMAGE-ONLY. On a PDF it deletes everything.

        Same script that lands a PNG on exactly 1 attachment leaves a PDF note
        with **zero** attachments and **two orphaned U+FFFC placeholders** in the
        note text — the file is gone and the note is left visibly broken.
        Reproduced 4/4, and adding a settle delay before the count does not help,
        so it is deterministic rather than a race.

        This is why `notes attach` must branch on attachment type rather than
        applying the guard universally.
        """
        with h.temp_note(body_html="<div>X</div>", label="pdfguard") as note_id:
            self._add_guarded(note_id, self._pdf(), expected=1)

            self.assertEqual(
                h.count_attachments(note_id), 0,
                "expected the known PDF-destroying behaviour; if this is now 1, "
                "Apple fixed it — re-test and update docs/apple-notes-api.md",
            )
            pk = h.pk_from_note_id(note_id)
            text = h.poll(
                lambda: (t := h.sqlite_note_text(pk)) and h.object_replacement_count(t) >= 1 and t
            )
            self.assertTrue(text)
            self.assertGreaterEqual(
                h.object_replacement_count(text), 1,
                "the note text keeps placeholders for the attachment that no longer exists",
            )

    def test_pdf_attach_cannot_read_back_its_id(self):
        """Attaching a PDF creates it but errors (-1728) when asked for the id.

        `make new attachment` succeeds; `id of` the result fails with
        "Can't get attachment id x-coredata://…". The id is recoverable from the
        error text, which is what macnotesapp's parse_id_from_error does.
        """
        with h.temp_note(body_html="<div>X</div>", label="pdfid") as note_id:
            with self.assertRaises(h.AppleScriptError) as ctx:
                h.add_attachment(note_id, self._pdf())
            msg = str(ctx.exception)
            self.assertIn("-1728", msg)
            # the attachment id we could not read is nonetheless in the error
            self.assertRegex(msg, r"ICAttachment/p\d+")

    def test_inline_data_uri_is_not_image_only(self):
        """The inline-write path accepts any MIME type, not just images.

        A PDF or a text file written as `<img src="data:…">` also lands as a real
        attachment at the chosen position. Same trap applies to all of them, so
        the warning cannot be scoped to images.
        """
        with open(self._pdf(), "rb") as f:
            pdf_b64 = base64.b64encode(f.read()).decode()
        txt_b64 = base64.b64encode(b"hello inline text\n").decode()

        for label, mime, payload in (
            ("pdf", "application/pdf", pdf_b64),
            ("txt", "text/plain", txt_b64),
        ):
            with self.subTest(kind=label):
                with h.temp_note(body_html="<div>x</div>", label=f"inl{label}") as note_id:
                    title_div = h.get_body(note_id).split("</div>")[0] + "</div>"
                    h.set_body(
                        note_id,
                        title_div
                        + "<div>ABOVE</div>"
                        + f'<div><img src="data:{mime};base64,{payload}"/></div>'
                        + "<div>BELOW</div>",
                    )
                    self.assertEqual(h.count_attachments(note_id), 1)
                    pk = h.pk_from_note_id(note_id)
                    text = h.poll(lambda: h.sqlite_note_text(pk))
                    self.assertRegex(text, r"ABOVE\s*￼\s*BELOW")
                    # ...and it is just as unharvestable as the image case
                    self.assertEqual(data_uris(h.get_body(note_id)), [])

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
