"""
What the Markdown write path supports — asserted from the shared case matrix.

🛑 **The matrix lives in `markdown_cases.py`, and it is the only place these
answers are written down.** `notes/capability-report` renders the same cases
into `docs/apple-notes-markdown-support.md`. Do not hand-probe these questions
and do not record the answers anywhere else; three wrong conclusions came out
of hand-probing before this existed.

Two independent assertions per case, and they fail separately:

  store      what APPLE did with the Markdown. This is the API surface, and
             these are the assertions that move on a macOS update.
  roundtrip  what `apple notes export` gives back. A construct can survive the
             write and still be lost on the read.

Gated behind RUN_LIVE_NOTES_TESTS: it creates real notes in iCloud and sweeps
them afterwards.

Run `./notes/capability-report --check` after every macOS update. It fails when
any answer moves, which is the signal that Apple changed something.
"""

import os
import time
import unittest

from tests import harness as h
from tests import markdown_cases as mc

cli = h.cli
LIVE = os.environ.get("RUN_LIVE_NOTES_TESTS") == "1"


def _runs(pk):
    found = cli.find_note(str(pk))
    text, runs = cli.parse_note_content(found[3])
    raw = text.encode("utf-16-le")
    out, offset = [], 0
    for run in runs:
        length = run["length"]
        chunk = raw[offset * 2:(offset + length) * 2].decode("utf-16-le", "replace")
        offset += length
        out.append((chunk, run))
    return out


def _export(pk):
    found = cli.find_note(str(pk))
    text, runs = cli.parse_note_content(found[3])
    ids = [r["attachment"]["identifier"] for r in runs if r.get("attachment")]
    labels = cli.get_attachment_labels(ids)
    links = cli.get_attachment_links(ids)
    return cli.apply_formatting(text, runs, labels,
                                cli.get_note_tables(ids, labels, links), links)


class CaseMatrixShape(unittest.TestCase):
    """Offline guards on the matrix itself. These need no Notes.app."""

    def test_probes_are_unique(self):
        """Every case shares one note, so a duplicate probe measures the wrong run."""
        probes = [c.probe for c in mc.CASES]
        self.assertEqual(len(probes), len(set(probes)),
                         "duplicate probe words: %s"
                         % [p for p in probes if probes.count(p) > 1])

    def test_no_probe_is_markdown_syntax(self):
        """A probe carrying `*` or `_` would be rewritten before we look for it."""
        for case in mc.CASES:
            if case.attachment_uti:
                continue
            self.assertFalse(set(case.probe) & set("*_`~"),
                             "%s: probe %r contains Markdown syntax"
                             % (case.name, case.probe))

    def test_every_case_is_separated_by_a_spacer(self):
        """🛑 A pipe table eats the last item of the list above it."""
        body = mc.probe_body("title")
        self.assertEqual(body.count(mc.SPACER), len(mc.CASES))

    def test_the_matrix_covers_both_directions(self):
        supported = [c for c in mc.CASES if c.supported]
        lost = [c for c in mc.CASES if not c.supported]
        self.assertTrue(supported and lost,
                        "the matrix must record losses as well as wins")


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class MarkdownCapabilities(unittest.TestCase):
    """One write, then every case asserted against the same stored note."""

    @classmethod
    def setUpClass(cls):
        h.sweep_test_notes()
        cls.pk = h.create_note_markdown(mc.probe_body(h.unique_title("matrix")))
        time.sleep(2)
        cls.runs = _runs(cls.pk)
        cls.exported = _export(cls.pk)

    @classmethod
    def tearDownClass(cls):
        h.sweep_test_notes()

    def find(self, case):
        if case.attachment_uti:
            for _chunk, run in self.runs:
                if (run.get("attachment") or {}).get("type_uti") == case.attachment_uti:
                    return run
            return None
        for chunk, run in self.runs:
            if case.probe in chunk:
                return run
        return None

    def test_store_shape(self):
        """What Apple did. A failure here means the API surface moved."""
        for case in mc.CASES:
            with self.subTest(case=case.name):
                run = self.find(case)
                self.assertIsNotNone(run, "%r is not in the stored note" % case.probe)
                if case.attachment_uti:
                    continue
                style = (run["paragraph_style"] or {}).get("style_type", mc.PLAIN)
                self.assertEqual(
                    style, case.style,
                    "%s: stored as %s, expected %s"
                    % (case.name, mc.STYLE_NAMES.get(style, style),
                       mc.STYLE_NAMES.get(case.style, case.style)))
                for key, want in case.attrs.items():
                    self.assertEqual(run.get(key), want,
                                     "%s: %s was %r" % (case.name, key, run.get(key)))
                if case.checked is not None:
                    checklist = (run["paragraph_style"] or {}).get("checklist") or {}
                    self.assertEqual(checklist.get("done"), case.checked)

    def test_round_trip(self):
        """What our reader gives back. A failure here is ours, not Apple's."""
        for case in mc.CASES:
            with self.subTest(case=case.name):
                if case.roundtrip is None:
                    self.assertIn(case.probe, self.exported,
                                  "%s: even the text vanished" % case.name)
                    continue
                self.assertIn(case.roundtrip, self.exported,
                              "%s: expected %r in the export"
                              % (case.name, case.roundtrip))


@unittest.skipUnless(LIVE, "set RUN_LIVE_NOTES_TESTS=1 (creates real notes)")
class TableSwallowsLastListItem(unittest.TestCase):
    """🛑 A pipe table destroys the LAST item of the list directly above it.

    Isolated by elimination. Not about the checked state, not about checklists
    — plain bullets lose their last item too. One paragraph between the list
    and the table prevents it.

    This is what made `- [x]` look unsupported: the probe that "proved" it had
    a table on the next line.
    """

    @classmethod
    def setUpClass(cls):
        h.sweep_test_notes()
        cls.pk = h.create_note_markdown(
            mc.TABLE_EATS_BODY % h.unique_title("tableeats"))
        time.sleep(2)
        cls.runs = _runs(cls.pk)

    @classmethod
    def tearDownClass(cls):
        h.sweep_test_notes()

    def style(self, probe):
        for chunk, run in self.runs:
            if probe in chunk:
                return (run["paragraph_style"] or {}).get("style_type", mc.PLAIN)
        self.fail("%r missing from the stored note" % probe)

    def test_without_a_table_both_items_survive(self):
        self.assertEqual(self.style("aaone"), mc.CHECKLIST)
        self.assertEqual(self.style("aatwo"), mc.CHECKLIST)

    def test_a_following_table_eats_the_last_item(self):
        self.assertEqual(self.style("bbone"), mc.CHECKLIST)
        self.assertEqual(self.style("bbtwo"), mc.PLAIN,
                         "bbtwo kept its style — Apple fixed this. Drop the "
                         "spacer workaround and re-run capability-report.")

    def test_it_is_not_about_checklists(self):
        self.assertIn(self.style("ccone"), (mc.BULLET, mc.DASHED))
        self.assertEqual(self.style("cctwo"), mc.PLAIN)

    def test_a_paragraph_between_prevents_it(self):
        self.assertEqual(self.style("ddone"), mc.CHECKLIST)
        self.assertEqual(self.style("ddtwo"), mc.CHECKLIST)


if __name__ == "__main__":
    unittest.main()
