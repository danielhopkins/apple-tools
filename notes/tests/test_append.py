"""What `apple notes append` actually does.

🛑 **`append` had no test of any kind before this file.** It is the one write
that claims to *preserve* things — attachments and checklist state — which is
the whole reason it exists instead of an AppleScript body write. Nothing
checked that claim.

Two classes of assertion here:

  preservation   the note's existing content survives. This is the claim.
  interpretation the appended Markdown becomes native structure.

Gated behind RUN_LIVE_NOTES_TESTS: it creates real notes in iCloud and sweeps
them afterwards.
"""

import os
import time
import unittest

from tests import harness as h
from tests import markdown_cases as mc

cli = h.cli
LIVE = os.environ.get("RUN_LIVE_NOTES_TESTS") == "1"


def styles_by_probe(pk):
    """{probe word: (style_type, done)} for every run in the note."""
    found = cli.find_note(str(pk))
    text, runs = cli.parse_note_content(found[3])
    raw = text.encode("utf-16-le")
    out, offset = [], 0
    for run in runs:
        length = run["length"]
        chunk = raw[offset * 2:(offset + length) * 2].decode("utf-16-le", "replace")
        offset += length
        style = (run["paragraph_style"] or {}).get("style_type", mc.PLAIN)
        checklist = (run["paragraph_style"] or {}).get("checklist") or {}
        out.append((chunk, style, checklist.get("done"), run))
    return out


def find(rows, probe):
    for chunk, style, done, run in rows:
        if probe in chunk:
            return style, done, run
    return None, None, None


def note_text(pk):
    found = cli.find_note(str(pk))
    text, _runs = cli.parse_note_content(found[3])
    return text


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class AppendPreserves(unittest.TestCase):
    """The claim `append` exists to make: it does not destroy what is there."""

    def setUp(self):
        h.sweep_test_notes()
        self.title = h.unique_title("append")
        self.pk = h.create_note_markdown(
            "%s\n\n"
            "keepone\n\n"
            "- [ ] keepopen\n"
            "- [x] keepdone\n\n"
            "spacer\n" % self.title)
        time.sleep(2)

    def tearDown(self):
        h.sweep_test_notes()

    def test_the_original_text_survives(self):
        code, payload = h.append_note_markdown(self.pk, "addedline\n")
        self.assertEqual(code, 0, payload.get("_stderr"))
        time.sleep(2)
        text = note_text(self.pk)
        self.assertIn("keepone", text)
        self.assertIn("addedline", text)

    def test_the_appended_text_goes_at_the_end(self):
        h.append_note_markdown(self.pk, "addedline\n")
        time.sleep(2)
        text = note_text(self.pk)
        self.assertLess(text.index("keepone"), text.index("addedline"))

    def test_an_existing_checklist_keeps_its_checked_state(self):
        """🛑 The headline claim. An AppleScript body write flattens both items."""
        code, payload = h.append_note_markdown(self.pk, "addedline\n")
        self.assertEqual(code, 0, payload.get("_stderr"))
        time.sleep(2)
        rows = styles_by_probe(self.pk)

        style, done, _ = find(rows, "keepopen")
        self.assertEqual(style, mc.CHECKLIST, "the unchecked item stopped being one")
        self.assertEqual(done, 0)

        style, done, _ = find(rows, "keepdone")
        self.assertEqual(style, mc.CHECKLIST, "the checked item stopped being one")
        self.assertEqual(done, 1, "the checked state was lost")

    def test_appending_twice_keeps_both(self):
        h.append_note_markdown(self.pk, "firstadd\n")
        time.sleep(2)
        code, payload = h.append_note_markdown(self.pk, "secondadd\n")
        self.assertEqual(code, 0, payload.get("_stderr"))
        time.sleep(2)
        text = note_text(self.pk)
        self.assertIn("firstadd", text)
        self.assertIn("secondadd", text)
        self.assertLess(text.index("firstadd"), text.index("secondadd"))

    def test_the_title_does_not_change(self):
        """⚠️ An AppleScript body write makes the first line the title."""
        before = cli.find_note(str(self.pk))[1]
        h.append_note_markdown(self.pk, "addedline\n")
        time.sleep(2)
        self.assertEqual(cli.find_note(str(self.pk))[1], before)


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class AppendPreservesAttachments(unittest.TestCase):
    """🛑 An AppleScript body write destroys every attachment. This must not."""

    def setUp(self):
        h.sweep_test_notes()
        self.title = h.unique_title("appendatt")
        self.pk = h.create_note_markdown("%s\n\nkeepone\n" % self.title)
        time.sleep(2)
        # A table is the attachment that is easiest to make through this path
        # and easiest to verify, since its cells are readable.
        code, _ = h.append_note_markdown(
            self.pk, "| ColA | ColB |\n| --- | --- |\n| attcell | two |\n")
        self.assertEqual(code, 0)
        time.sleep(2)

    def tearDown(self):
        h.sweep_test_notes()

    def _attachment_utis(self):
        found = cli.find_note(str(self.pk))
        _text, runs = cli.parse_note_content(found[3])
        return [(r.get("attachment") or {}).get("type_uti") for r in runs
                if r.get("attachment")]

    def test_the_table_arrived(self):
        import mergeable
        self.assertIn(mergeable.TABLE_UTI, self._attachment_utis())

    def test_a_later_append_does_not_destroy_it(self):
        import mergeable
        code, payload = h.append_note_markdown(self.pk, "afterthetable\n")
        self.assertEqual(code, 0, payload.get("_stderr"))
        time.sleep(2)
        self.assertIn(mergeable.TABLE_UTI, self._attachment_utis(),
                      "the append destroyed the table attachment")
        self.assertIn("afterthetable", note_text(self.pk))


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class AppendInterpretsMarkdown(unittest.TestCase):
    """Appended Markdown must become native structure, not literal text."""

    def setUp(self):
        h.sweep_test_notes()
        self.title = h.unique_title("appendmd")
        self.pk = h.create_note_markdown("%s\n\nkeepone\n" % self.title)
        time.sleep(2)

    def tearDown(self):
        h.sweep_test_notes()

    def append(self, body):
        code, payload = h.append_note_markdown(self.pk, body)
        time.sleep(2)
        return code, payload, styles_by_probe(self.pk)

    def test_appended_bold_is_bold(self):
        code, payload, rows = self.append("appendedbold is **boldedhere**\n")
        self.assertEqual(code, 0, payload.get("_stderr"))
        _style, _done, run = find(rows, "boldedhere")
        self.assertIsNotNone(run)
        self.assertTrue(run["bold"])

    def test_appended_checklist_is_native(self):
        code, payload, rows = self.append("- [x] appendeddone\n")
        self.assertEqual(code, 0, payload.get("_stderr"))
        style, done, _ = find(rows, "appendeddone")
        self.assertEqual(style, mc.CHECKLIST)
        self.assertEqual(done, 1)

    def test_appended_heading_is_native(self):
        code, payload, rows = self.append("## appendedheading\n")
        self.assertEqual(code, 0, payload.get("_stderr"))
        style, _done, _run = find(rows, "appendedheading")
        self.assertEqual(style, mc.HEADING)

    def test_a_markdown_first_line_still_reports_success(self):
        """🛑 The confirmation must not match on the raw Markdown.

        `cmd_append` confirms by looking for the first line of what it sent.
        Apple rewrites that line — `- [x] x` is stored as `x` — so a naive
        substring check reports failure for an append that worked. This is the
        same trap that made `create` report `created: false` for every note.
        """
        code, payload, rows = self.append("- [x] markerprobe\n")
        style, done, _ = find(rows, "markerprobe")
        self.assertEqual(style, mc.CHECKLIST, "the append did not land at all")
        self.assertEqual(code, 0,
                         "the append worked but the command reported failure: %s"
                         % payload.get("_stderr"))
        self.assertTrue(payload.get("appended"))


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class AppendRefuses(unittest.TestCase):
    """Every refusal must be loud and non-zero, never a silent no-op."""

    def setUp(self):
        h.sweep_test_notes()

    def tearDown(self):
        h.sweep_test_notes()

    def test_an_unknown_note_is_refused(self):
        code, payload = h.append_note_markdown(99999999, "x\n")
        self.assertNotEqual(code, 0)
        self.assertIn("not found", payload.get("_stderr", "").lower())

    def test_an_ambiguous_title_is_refused(self):
        """🛑 The shortcut matches on NAME, and names are not unique.

        Appending to every match would be a silent, unrecoverable mistake.
        """
        title = h.unique_title("dupe")
        first = h.create_note_markdown("%s\n\naaa\n" % title)
        time.sleep(2)
        second = h.create_note_markdown("%s\n\nbbb\n" % title)
        time.sleep(2)
        self.assertNotEqual(first, second)

        code, payload = h.append_note_markdown(first, "shouldnotland\n")
        self.assertNotEqual(code, 0, "an ambiguous title must be refused")
        stderr = payload.get("_stderr", "")
        self.assertIn("refusing", stderr.lower())
        # ⚠️ And it must not have written to either note.
        time.sleep(2)
        for pk in (first, second):
            self.assertNotIn("shouldnotland", note_text(pk))


if __name__ == "__main__":
    unittest.main()
