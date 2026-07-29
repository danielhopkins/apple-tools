"""
Attachment round-trip tests — whether an attachment-preserving edit is possible.

CLAUDE.md long said a note's `body` "doesn't include attachments at all", so any
body write destroys them and there is no attachment-preserving edit path. That
is true for *file* attachments and false for *images*: Notes serialises an image
attachment into the body as a base64 `data:` URI, which means it can be
harvested before a write and restored after one.

The technique comes from antoniorodr/memo (see docs/prior-art.md). These tests
establish which half of it is real on this macOS version, and pin the traps
around it.

⚠️ **Two measurement rules, both learned by getting them wrong here.**

1. **Verify through the store, not through AppleScript.** `count of attachments`
   returns 0 for a note that demonstrably holds a PDF — the file is on disk,
   byte-exact, and AppleScript cannot see it. A count of 0 therefore proves
   nothing about whether an attachment exists, and reading it as evidence of
   deletion is how a wrong claim got into the docs.
2. **Let the decoded text settle.** The placeholder count passes through a
   transient (1) before reaching its settled value (2). `h.poll` returns the
   first non-empty decode, which is mid-write — use `settled_placeholders()`.

Everything here is per-attachment-type: a result for a PNG proves nothing about
a PDF.
"""

import os
import re
import time
import base64
import hashlib
import sqlite3
import struct
import zlib
import uuid
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


def digest_file(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


CONTAINER = os.path.expanduser("~/Library/Group Containers/group.com.apple.notes")


def container_files() -> set:
    """Every file under the Notes group container, for before/after diffing."""
    out = set()
    for root, _dirs, files in os.walk(CONTAINER):
        for fn in files:
            out.add(os.path.join(root, fn))
    return out


def _new_under_accounts(before: set) -> list:
    return [p for p in container_files() - before if "/Accounts/" in p]


def new_account_files(before: set) -> int:
    return len(_new_under_accounts(before))


def files_matching(before: set, want_sha: str) -> int:
    """How many newly-created files under Accounts/ have this exact content.

    This is the only trustworthy check that an attachment really landed —
    `count of attachments` lies for PDFs.
    """
    n = 0
    for p in _new_under_accounts(before):
        try:
            if digest_file(p) == want_sha:
                n += 1
        except OSError:
            pass
    return n


def attachment_rows(pk: int) -> list:
    """(ZFILENAME, ZFILESIZE, ZTYPEUTI) for each child row of the note."""
    conn = sqlite3.connect(f"file:{h.DB_PATH}?mode=ro", uri=True, timeout=5)
    try:
        return conn.execute(
            "SELECT ZFILENAME, ZFILESIZE, ZTYPEUTI "
            "FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTE = ?", (pk,)
        ).fetchall()
    finally:
        conn.close()


def attach_plain(note_id: str, path: str) -> None:
    """`make new attachment` without reading the id back (a PDF errors -1728)."""
    h.osascript(
        'tell application "Notes"\n'
        f"set n to note id {h._as_str(note_id)}\n"
        f"make new attachment at end of n with data (POSIX file {h._as_str(path)})\n"
        "end tell"
    )


def settled_placeholders(pk: int, stable_for: float = 2.0, timeout: float = 15.0) -> int:
    """Placeholder count once it stops changing.

    The decoded text passes through a transient (1 placeholder) on its way to
    the settled value (2). Reading the first non-empty decode — which is what
    h.poll gives you — catches that transient and reports the wrong number.
    """
    deadline = time.time() + timeout
    last, since = None, time.time()
    while time.time() < deadline:
        text = h.sqlite_note_text(pk)
        now = h.object_replacement_count(text) if text else None
        if now != last:
            last, since = now, time.time()
        elif last is not None and time.time() - since >= stable_for:
            return last
        time.sleep(0.3)
    return last or 0


class AttachmentRoundTripTests(unittest.TestCase):
    def _png(self, rgb=(220, 40, 40), size=8) -> str:
        """Write a tiny solid-colour PNG, unique on every call.

        ⚠️ The uniqueness is load-bearing, not cosmetic. Several tests here ask
        "did a file with *these bytes* appear under Accounts/?" — and Notes
        flushes attachments to disk asynchronously, so another test's file can
        land inside this test's before/after window. When two tests generated
        byte-identical PNGs, that made
        test_inline_data_uri_write_discards_the_payload fail intermittently
        (~2 runs in 6) by finding someone else's copy.

        A per-call uuid in a tEXt chunk keeps the colour meaningful while making
        collisions impossible.
        """
        raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))

        def chunk(tag, data):
            c = tag + data
            return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

        nonce = uuid.uuid4().hex.encode()
        png = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"tEXt", b"claude-test-nonce\x00" + nonce)
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b"")
        )
        fd, path = tempfile.mkstemp(prefix="claude_img_", suffix=".png")
        with os.fdopen(fd, "wb") as f:
            f.write(png)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def _text_file(self) -> str:
        """Unique per call, for the same collision reason as the PNG nonce."""
        fd, path = tempfile.mkstemp(prefix="claude_txt_", suffix=".txt")
        with os.fdopen(fd, "wb") as f:
            f.write(b"a text attachment %s\n" % uuid.uuid4().hex.encode())
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return path

    def _pdf(self) -> str:
        """A minimal but genuinely valid one-page PDF."""
        objs = [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] "
            b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            # unique per call, for the same reason as the PNG nonce
            b"<< /Length 62 >>\nstream\nBT /F1 18 Tf 20 100 Td ("
            + uuid.uuid4().hex[:8].encode() + b") Tj ET\nendstream",
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

    def test_applescript_count_is_blind_to_pdf_attachments(self):
        """🛑 `count of attachments` reports 0 for a note that HAS a PDF.

        The file is attached and byte-exact on disk; AppleScript simply cannot
        see it. Enumerating `attachments of n` yields nothing either.

        This is the trap that matters most for a write path: any code that
        reasons about attachments through AppleScript's count is wrong for PDFs.
        It is also what made a count of 0 look like evidence of deletion when
        nothing had been deleted. **Verify through the store, not the count.**
        """
        pdf = self._pdf()
        want = digest_file(pdf)
        with h.temp_note(body_html="<div>X</div>", label="pdfblind") as note_id:
            before = container_files()
            attach_plain(note_id, pdf)

            self.assertEqual(
                h.count_attachments(note_id), 0,
                "AppleScript is expected to be blind to PDF attachments; if this "
                "is now 1, Apple fixed it — re-test and update docs/apple-notes-api.md",
            )
            # ...yet exactly one byte-exact copy really was stored
            self.assertEqual(
                files_matching(before, want), 1,
                "the PDF should be on disk exactly once, byte-exact",
            )

    def test_pdf_double_inserts_and_the_guard_cannot_fix_it(self):
        """A PDF is referenced twice in the text, and the guard is a no-op.

        Because `count of attachments` is 0 (see above), `if count > EXPECTED`
        never fires — so the guard neither helps nor harms a PDF. Guarded and
        unguarded adds are indistinguishable: two placeholders, one stored file.
        The user sees the PDF twice and there is no AppleScript route to fix it.
        """
        pdf = self._pdf()
        want = digest_file(pdf)
        for label, add in (("unguarded", attach_plain),
                           ("guarded", lambda n, p: self._add_guarded(n, p, 1))):
            with self.subTest(variant=label):
                with h.temp_note(body_html="<div>X</div>", label=f"pdf{label}") as note_id:
                    before = container_files()
                    add(note_id, pdf)
                    pk = h.pk_from_note_id(note_id)
                    self.assertEqual(
                        settled_placeholders(pk), 2,
                        "a PDF is referenced twice in the note text",
                    )
                    self.assertEqual(files_matching(before, want), 1,
                                     "but only one copy is stored")

    def test_placeholder_count_has_a_transient(self):
        """The decoded placeholder count is 1 before it settles to 2.

        Pinned because reading it too early is exactly how a wrong conclusion
        got into the docs. `h.poll` returns the FIRST non-empty decode, which
        for an attachment write is a mid-write state — assertions must settle.
        """
        with h.temp_note(body_html="<div>X</div>", label="transient") as note_id:
            pk = h.pk_from_note_id(note_id)
            attach_plain(note_id, self._pdf())
            first = h.poll(lambda: h.sqlite_note_text(pk))
            early = h.object_replacement_count(first) if first else 0
            settled = settled_placeholders(pk)
            self.assertEqual(settled, 2)
            self.assertLessEqual(
                early, settled,
                "the early read should be a prefix state, never larger than settled",
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

    def test_inline_data_uri_write_discards_the_payload(self):
        """🛑 The inline write stores NOTHING. It is pure data loss, any type.

        `set body` with `<img src="data:…;base64,…"/>` creates an attachment row
        and a correctly-positioned placeholder, so it looks like it worked — and
        it is the only thing that can place an attachment mid-note, which makes
        it tempting. But the row is empty:

            ZFILENAME = NULL, ZFILESIZE = 0, ZTYPEUTI = 'public.data'

        and **no file is ever written** (polled 30s). The bytes are discarded.
        True for images and PDFs alike, so there is no safe variant of this.
        """
        pdf, png = self._pdf(), self._png()
        with open(pdf, "rb") as f:
            pdf_b64 = base64.b64encode(f.read()).decode()
        with open(png, "rb") as f:
            png_b64 = base64.b64encode(f.read()).decode()

        for label, mime, payload, want_sha in (
            ("pdf", "application/pdf", pdf_b64, digest_file(pdf)),
            ("png", "image/png", png_b64, digest_file(png)),
        ):
            with self.subTest(kind=label):
                with h.temp_note(body_html="<div>x</div>", label=f"inl{label}") as note_id:
                    title_div = h.get_body(note_id).split("</div>")[0] + "</div>"
                    before = container_files()
                    h.set_body(
                        note_id,
                        title_div
                        + "<div>ABOVE</div>"
                        + f'<div><img src="data:{mime};base64,{payload}"/></div>'
                        + "<div>BELOW</div>",
                    )
                    # it looks like it worked: one attachment, placed correctly
                    self.assertEqual(h.count_attachments(note_id), 1)
                    pk = h.pk_from_note_id(note_id)
                    self.assertRegex(h.poll(lambda: h.sqlite_note_text(pk)),
                                     r"ABOVE\s*￼\s*BELOW")

                    # ...but the payload was thrown away.
                    #
                    # Checks for a file with *these bytes* rather than for any
                    # new file at all: Notes writes to the container in the
                    # background, so an unrelated file appearing between the two
                    # snapshots says nothing about this write.
                    self.assertEqual(
                        files_matching(before, want_sha), 0,
                        "the inline write must not store the payload; if it now "
                        "does, re-test — mid-note placement would become viable",
                    )
                    rows = attachment_rows(pk)
                    self.assertTrue(rows)
                    for filename, size, uti in rows:
                        self.assertIsNone(filename)
                        self.assertEqual(size, 0)
                        self.assertEqual(uti, "public.data")

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


TABLE_HTML = (
    "<table><tr><td>r1c1</td><td>r1c2</td></tr>"
    "<tr><td>r2c1</td><td>r2c2</td></tr></table>"
)


def object_utis(pk: int) -> dict:
    """{ZTYPEUTI: count} for the note's embedded objects."""
    conn = sqlite3.connect(f"file:{h.DB_PATH}?mode=ro", uri=True, timeout=5)
    try:
        rows = conn.execute(
            "SELECT ZTYPEUTI, COUNT(*) FROM ZICCLOUDSYNCINGOBJECT "
            "WHERE ZNOTE = ? AND ZTYPEUTI IS NOT NULL GROUP BY ZTYPEUTI", (pk,)
        ).fetchall()
        return {u: n for u, n in rows}
    finally:
        conn.close()


class EmbeddedObjectTests(unittest.TestCase):
    """Native tables behave unlike attachments, and unlike each other's docs.

    An attachment must be harvested and re-added around a body write. A **table
    round-trips as markup** — leave its `<table>` HTML in the body you write and
    it simply survives. That makes tables the one embedded object a body edit
    can preserve without doing anything special.
    """

    def test_table_html_creates_a_native_table(self):
        """`<table>` in a written body becomes a real com.apple.notes.table.

        Notably different from `<img src="data:…">`, which produces an empty
        `public.data` shell — so markup round-tripping is type-specific.
        """
        with h.temp_note(body_html=f"<div>ABOVE</div>{TABLE_HTML}<div>BELOW</div>",
                         label="tblnew") as note_id:
            pk = h.pk_from_note_id(note_id)
            self.assertEqual(object_utis(pk).get("com.apple.notes.table"), 1)
            self.assertIn("<table", h.get_body(note_id).lower())
            self.assertRegex(h.sqlite_note_text(pk), r"ABOVE\s*￼\s*BELOW")

    def test_table_survives_a_body_roundtrip(self):
        """Reading the body and writing it back preserves the table and its cells.

        This is the append pattern that destroys every attachment. A table is
        unaffected, because its content travels in the HTML rather than in a
        separate record.
        """
        with h.temp_note(body_html=f"<div>ABOVE</div>{TABLE_HTML}<div>BELOW</div>",
                         label="tblrt") as note_id:
            pk = h.pk_from_note_id(note_id)
            before = h.get_body(note_id)
            self.assertEqual(len(re.findall(r"<td", before.lower())), 4)

            h.set_body(note_id, before + "<div>APPENDED</div>")

            after = h.get_body(note_id)
            self.assertIn("<table", after.lower())
            self.assertEqual(len(re.findall(r"<td", after.lower())), 4,
                             "all four cells should survive the round trip")
            text = h.sqlite_note_text(pk)
            self.assertIn("APPENDED", text)
            self.assertEqual(h.object_replacement_count(text), 1,
                             "still exactly one embedded object in the text")

    def test_table_is_destroyed_when_its_markup_is_dropped(self):
        """Writing a body without the `<table>` markup removes the table.

        The failure mode is ordinary rather than surprising — but it means a
        Markdown round trip that cannot represent a table will silently delete
        one, which is the case `notes edit` has to refuse.
        """
        with h.temp_note(body_html=f"<div>ABOVE</div>{TABLE_HTML}<div>BELOW</div>",
                         label="tbldrop") as note_id:
            pk = h.pk_from_note_id(note_id)
            self.assertEqual(settled_placeholders(pk), 1)

            title_div = h.get_body(note_id).split("</div>")[0] + "</div>"
            h.set_body(note_id, title_div + "<div>TABLE DROPPED</div>")

            self.assertEqual(
                settled_placeholders(pk), 0,
                "the table should be gone from the note text",
            )
            self.assertNotIn("<table", h.get_body(note_id).lower())

    def test_table_roundtrip_leaves_orphaned_object_rows(self):
        """⚠️ A body round-trip leaks table rows that nothing references.

        The note still renders one table, but `ZICCLOUDSYNCINGOBJECT` gains rows.
        **How many is not deterministic** — 2 in isolation, 3 when the suite runs
        together — so this asserts only that the count grew while the note's own
        object count did not.

        The practical consequence: a row count is not a valid way to count a
        note's tables, and repeated edits accumulate garbage in the store.
        """
        with h.temp_note(body_html=f"<div>ABOVE</div>{TABLE_HTML}<div>BELOW</div>",
                         label="tblorphan") as note_id:
            pk = h.pk_from_note_id(note_id)
            before = object_utis(pk).get("com.apple.notes.table")
            self.assertEqual(before, 1)

            h.set_body(note_id, h.get_body(note_id) + "<div>APPENDED</div>")

            after = object_utis(pk).get("com.apple.notes.table")
            self.assertGreater(
                after, before,
                "expected the known orphan-row leak; if the count stays 1, "
                "Apple fixed it — update docs/apple-notes-api.md",
            )
            # ...while the note itself still shows exactly one table
            self.assertEqual(settled_placeholders(pk), 1)

    def test_image_can_be_dropped_while_a_table_is_kept(self):
        """The two classes are independent: strip the <img>, keep the <table>.

        This is the shape `notes edit` needs — tables ride along in the markup,
        images are harvested and re-added, and neither interferes with the other.
        """
        fd, png = tempfile.mkstemp(prefix="claude_tbl_", suffix=".png")
        os.close(fd)
        with open(png, "wb") as f:
            f.write(
                b"\x89PNG\r\n\x1a\n"
                + struct.pack(">I", 13) + b"IHDR" + struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
                + struct.pack(">I", zlib.crc32(b"IHDR" + struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) & 0xFFFFFFFF)
                + (lambda d: struct.pack(">I", len(d)) + b"IDAT" + d
                   + struct.pack(">I", zlib.crc32(b"IDAT" + d) & 0xFFFFFFFF))(
                       zlib.compress(b"\x00\x09\x82\x3c"))
                + struct.pack(">I", 0) + b"IEND" + struct.pack(">I", zlib.crc32(b"IEND") & 0xFFFFFFFF)
            )
        self.addCleanup(lambda: os.path.exists(png) and os.remove(png))

        with h.temp_note(body_html=f"<div>ABOVE</div>{TABLE_HTML}<div>BELOW</div>",
                         label="tblimg") as note_id:
            pk = h.pk_from_note_id(note_id)
            # The note already holds a table, so the double-insert guard's
            # threshold is "one more than what is already there" — not 1.
            # Hardcoding 1 here let the surplus reference survive and the
            # placeholder count settle on 3, failing intermittently.
            before_count = h.count_attachments(note_id)
            h.osascript(
                'tell application "Notes"\n'
                f"set n to note id {h._as_str(note_id)}\n"
                f"make new attachment at end of n with data (POSIX file {h._as_str(png)})\n"
                f"if (count of attachments of n) > {before_count + 1} then\n"
                "  delete last attachment of n\n"
                "end if\n"
                "end tell"
            )
            # settled_placeholders, not a raw read: the count passes through a
            # transient on its way to its final value.
            self.assertEqual(settled_placeholders(pk), 2,
                             "one table + one image")

            body = h.get_body(note_id)
            h.set_body(note_id, re.sub(r"<img[^>]*>", "", body) + "<div>IMAGE DROPPED</div>")

            after = h.get_body(note_id)
            self.assertIn("<table", after.lower(), "the table must survive")
            self.assertEqual(len(re.findall(r"<td", after.lower())), 4)
            self.assertEqual(
                settled_placeholders(pk), 1,
                "exactly the image should have been removed",
            )


if __name__ == "__main__":
    unittest.main()
