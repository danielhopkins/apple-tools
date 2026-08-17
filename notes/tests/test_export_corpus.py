"""Run the whole export pipeline over every note in the real store.

🛑 **This exists because the title-duplication bug reached a commit.** Teaching
the renderer to emit `# ` for the TITLE paragraph style broke
`format_as_markdown`'s check for the body's own title line, so **every note
exported with its title printed twice**. Nothing caught it: the unit tests
exercise `apply_formatting`, and nothing asserted on the finished output of a
real note. It surfaced only because the packaged binary was run by hand.

Unit tests check one construct against a fixture. This checks the **finished
output of every note the user actually has**, against invariants that must hold
whatever the note contains. That is the shape of bug the unit tests miss: not a
wrong answer for one construct, but a wrong interaction between two correct
parts.

**Read-only.** It creates nothing and writes nothing, so it needs no
RUN_LIVE_NOTES_TESTS gate. It skips when the store cannot be read.

Runs in about a second over ~680 notes.
"""

import os
import re
import sqlite3
import unittest

from tests import harness as h

cli = h.cli

LINK = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
# A marker that is not escaped. `\*` in the text is a literal, not emphasis.
UNESCAPED = {mark: re.compile(r"(?<!\\)" + re.escape(mark))
             for mark in ("**", "==", "~~")}


def strip_markers(line):
    """A line reduced to its words, so a title can be compared to a heading."""
    return line.strip().lstrip("#").strip().strip("*").strip("_").strip()


def load_corpus():
    """[(pk, title, raw_text, export)] for every readable, unlocked note."""
    if not os.path.exists(h.DB_PATH):
        return None
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % h.DB_PATH, uri=True)
        pks = [r[0] for r in conn.execute(
            "SELECT n.Z_PK FROM ZICCLOUDSYNCINGOBJECT n "
            "JOIN ZICNOTEDATA nd ON nd.ZNOTE = n.Z_PK "
            "WHERE n.ZMARKEDFORDELETION = 0 AND nd.ZDATA IS NOT NULL")]
        conn.close()
    except sqlite3.Error:
        return None

    out = []
    for pk in pks:
        found = cli.find_note(str(pk))
        if not found or found[4]:          # missing, or locked
            continue
        text, runs = cli.parse_note_content(found[3])
        if not text:
            continue
        ids = [r["attachment"]["identifier"] for r in runs if r.get("attachment")]
        labels = cli.get_attachment_labels(ids)
        links = cli.get_attachment_links(ids)
        tables = cli.get_note_tables(ids, labels, links)
        body = cli.apply_formatting(text, runs, labels, tables, links)
        out.append((pk, found[1], text, cli.format_as_markdown(found[1], body)))
    return out


CORPUS = load_corpus()


@unittest.skipIf(CORPUS is None, "the Notes store is not readable here")
@unittest.skipIf(CORPUS is not None and not CORPUS, "the Notes store is empty")
class ExportCorpus(unittest.TestCase):
    """Invariants that must hold for every note, whatever it contains."""

    def test_the_title_is_never_added_a_second_time(self):
        """🛑 The regression. The renderer must not ADD a copy of the title.

        Compared against the source rather than asserted absolutely, because
        four real notes type their own title twice in the body. That is
        content, and dropping it would be data loss. The rule is only that the
        export carries one fewer than the body — the line `format_as_markdown`
        removes — and never more.
        """
        for pk, title, raw, export in CORPUS:
            if not title.strip():
                continue
            with self.subTest(pk=pk, title=title[:30]):
                in_body = sum(1 for line in raw.split("\n")
                              if line.strip() == title.strip())
                after_header = export.split("\n", 1)[1] if "\n" in export else ""
                in_export = sum(1 for line in after_header.split("\n")
                                if strip_markers(line) == title.strip())
                self.assertEqual(in_export, max(0, in_body - 1),
                                 "note %d renders its title %d times; the body "
                                 "has it %d times" % (pk, in_export, in_body))

    def test_the_export_starts_with_the_title_as_a_heading(self):
        """⚠️ A title can hold a U+FFFC, which the heading renders like the body."""
        for pk, title, _raw, export in CORPUS:
            if not title.strip():
                continue
            with self.subTest(pk=pk):
                expected = title.replace("\ufffc", "[attachment]")
                self.assertEqual(export.split("\n", 1)[0], "# %s" % expected)

    def test_every_inline_marker_is_balanced(self):
        """Split the way a renderer does, so U+2028 and \\r count as breaks."""
        for pk, _title, _raw, export in CORPUS:
            for line in export.splitlines():
                for mark, pattern in UNESCAPED.items():
                    with self.subTest(pk=pk, mark=mark):
                        self.assertEqual(
                            len(pattern.findall(line)) % 2, 0,
                            "note %d has an unbalanced %s: %r"
                            % (pk, mark, line[:80]))

    def test_no_link_is_left_dangling(self):
        for pk, _title, _raw, export in CORPUS:
            for line in export.split("\n"):
                with self.subTest(pk=pk):
                    self.assertNotIn("](", LINK.sub("", line),
                                     "note %d has an unclosed link: %r"
                                     % (pk, line[:80]))

    def test_no_note_renders_a_bare_object_replacement_char(self):
        """Every U+FFFC must become a table, a divider, or a named attachment."""
        for pk, _title, _raw, export in CORPUS:
            with self.subTest(pk=pk):
                self.assertNotIn("￼", export,
                                 "note %d leaked an unrendered placeholder" % pk)

    def test_a_table_row_is_always_followed_by_a_separator_or_another_row(self):
        """A pipe table needs its header separator, or it renders as text."""
        for pk, _title, _raw, export in CORPUS:
            lines = export.split("\n")
            for i, line in enumerate(lines):
                if not line.startswith("| "):
                    continue
                if i + 1 < len(lines) and lines[i + 1].startswith("|"):
                    break          # the separator or the next row is there
                with self.subTest(pk=pk):
                    self.assertTrue(
                        i + 1 < len(lines) and lines[i + 1].startswith("|"),
                        "note %d has a one-line table: %r" % (pk, line[:70]))
                break

    def test_the_corpus_is_big_enough_to_mean_something(self):
        """A guard on the guard: an empty corpus must not read as a pass."""
        self.assertGreater(len(CORPUS), 20,
                           "only %d notes were read; these invariants prove "
                           "little at that size" % len(CORPUS))


if __name__ == "__main__":
    unittest.main()
