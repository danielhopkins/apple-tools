"""
Pure unit tests for the table decoder. These build a MergeableData blob by
hand, so they touch neither Notes.app nor the user's store and run without the
RUN_LIVE_NOTES_TESTS gate.

Each test pins one of the four traps that made a real table decode wrongly
rather than fail:

  1. a table blob is gzipped; an audio blob is not
  2. a table blob has two extra wrapper levels; an audio blob has none
  3. a cell key is a reference to an NSUUID object, keyed `UUIDIndex`
  4. row/column UUIDs live in a different UUID space from the cell keys, and
     `ordering.contents` is the map between them

Traps 2 and 4 are the dangerous ones: each produces a plausible empty result
instead of an error.
"""

import gzip
import unittest

import mergeable
import notestore
from tests import harness as h

cli = h.cli  # the loaded apple-notes CLI module


# --------------------------------------------------------------------------- #
# A minimal protobuf writer, just enough to build a table blob.
# --------------------------------------------------------------------------- #


def _varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def _tag(field, wire):
    return _varint((field << 3) | wire)


def _delimited(field, payload):
    return _tag(field, 2) + _varint(len(payload)) + payload


def _number(field, value):
    return _tag(field, 0) + _varint(value)


def _object_id(field, *, ref=None, index=None):
    """An ObjectID: field 6 is an entry reference, field 2 a UUID-table index."""
    inner = _number(6, ref) if ref is not None else _number(2, index)
    return _delimited(field, inner)


class TableBlob:
    """Builds a com.apple.notes.table ZMERGEABLEDATA1 blob."""

    def __init__(self):
        self.entries = []
        self.keys = ["UUIDIndex", "cellColumns", "crRows", "crColumns"]
        self.types = ["com.apple.CRDT.NSUUID", "com.apple.notes.ICTable"]
        self.uuids = []

    def _key(self, name):
        return self.keys.index(name)

    def add_uuid(self):
        """A fresh UUID, as an NSUUID entry. Returns (entry index, bytes)."""
        index = len(self.uuids)
        raw = bytes([index]) * 16
        self.uuids.append(raw)
        body = (_number(1, self.types.index("com.apple.CRDT.NSUUID"))
                + _delimited(3, _number(1, self._key("UUIDIndex"))
                             + _object_id(2, index=index)))
        return self._append(_delimited(13, body)), raw

    def add_note(self, text):
        return self._append(_delimited(10, _delimited(2, text.encode("utf-8"))))

    def add_dictionary(self, pairs):
        body = b"".join(
            _delimited(1, _object_id(1, ref=k) + _object_id(2, ref=v))
            for k, v in pairs)
        return self._append(_delimited(6, body))

    def add_ordered_set(self, order, alias, live):
        """order: [entry idx]; alias: {entry idx: entry idx}; live: [entry idx]."""
        array = b"".join(
            _delimited(2, _number(1, position) + _delimited(2, self._uuid_of(entry)))
            for position, entry in enumerate(order))
        contents = b"".join(
            _delimited(1, _object_id(1, ref=k) + _object_id(2, ref=v))
            for k, v in alias.items())
        elements = b"".join(
            _delimited(1, _object_id(1, ref=e) + _object_id(2, ref=e)) for e in live)
        ordering = _delimited(1, array) + _delimited(2, contents)
        return self._append(_delimited(16, _delimited(1, ordering)
                                       + _delimited(2, elements)))

    def add_table(self, cells, rows, columns):
        body = (_number(1, self.types.index("com.apple.notes.ICTable"))
                + _delimited(3, _number(1, self._key("cellColumns"))
                             + _object_id(2, ref=cells))
                + _delimited(3, _number(1, self._key("crRows"))
                             + _object_id(2, ref=rows))
                + _delimited(3, _number(1, self._key("crColumns"))
                             + _object_id(2, ref=columns)))
        return self._append(_delimited(13, body))

    def _uuid_of(self, entry):
        return self.uuids[self._uuid_index[entry]]

    def _append(self, payload):
        self.entries.append(payload)
        return len(self.entries) - 1

    def build(self, *, gzipped=True, wrapped=True):
        data = (b"".join(_delimited(3, e) for e in self.entries)
                + b"".join(_delimited(4, k.encode()) for k in self.keys)
                + b"".join(_delimited(5, t.encode()) for t in self.types)
                + b"".join(_delimited(6, u) for u in self.uuids))
        blob = _delimited(2, _number(2, 1) + _delimited(3, data)) if wrapped else data
        return gzip.compress(blob) if gzipped else blob


def build_table(grid, *, deleted_column=False, **kwargs):
    """A blob for `grid`, optionally carrying one deleted column."""
    b = TableBlob()
    b._uuid_index = {}

    def uuid_entry():
        entry, _raw = b.add_uuid()
        b._uuid_index[entry] = len(b.uuids) - 1
        return entry

    height, width = len(grid), len(grid[0])
    cell_rows = [uuid_entry() for _ in range(height)]
    cell_cols = [uuid_entry() for _ in range(width + (1 if deleted_column else 0))]
    # 🛑 The ordering UUIDs are a SEPARATE space from the cell UUIDs.
    order_rows = [uuid_entry() for _ in range(height)]
    order_cols = [uuid_entry() for _ in range(len(cell_cols))]

    columns = []
    for x in range(width):
        pairs = [(cell_rows[y], b.add_note(grid[y][x])) for y in range(height)]
        columns.append(b.add_dictionary(pairs))
    cells = b.add_dictionary(list(zip(cell_cols, columns)))

    rows_set = b.add_ordered_set(
        order_rows, dict(zip(order_rows, cell_rows)), order_rows)
    # A deleted column stays in `contents` and drops out of `elements`.
    cols_set = b.add_ordered_set(
        order_cols, dict(zip(order_cols, cell_cols)), order_cols[:width])

    b.add_table(cells, rows_set, cols_set)
    return b.build(**kwargs)


# --------------------------------------------------------------------------- #


GRID = [["Quarter", "Result"], ["Q1", "up"], ["Q2", "down"]]


class TableDecodeTests(unittest.TestCase):
    def test_decodes_a_grid(self):
        table = mergeable.table_from_blob(build_table(GRID))
        self.assertEqual(table.grid, GRID)
        self.assertEqual((table.rows, table.columns), (3, 2))

    def test_gzipped_blob_is_sniffed(self):
        """🛑 Trap 1: every table blob is gzipped, no audio blob is."""
        plain = mergeable.table_from_blob(build_table(GRID, gzipped=False))
        self.assertEqual(plain.grid, GRID)

    def test_wrapper_is_descended(self):
        """🛑 Trap 2: entries sit at root.2.3, not root.3.

        Reading the audio shape here yields zero entries and no error, so the
        table would read as absent rather than as a parse failure.
        """
        bare = mergeable.MergeableData(build_table(GRID, wrapped=False))
        wrapped = mergeable.MergeableData(build_table(GRID))
        self.assertEqual(len(bare.entries), len(wrapped.entries))
        self.assertTrue(wrapped.entries)

    def test_deleted_column_is_dropped(self):
        """⚠️ `ordering.contents` keeps deleted columns; `elements` does not."""
        table = mergeable.table_from_blob(build_table(GRID, deleted_column=True))
        self.assertEqual(table.columns, 2)
        self.assertEqual(table.grid, GRID)

    def test_cell_uuids_are_not_the_ordering_uuids(self):
        """🛑 Trap 4: the two UUID spaces are disjoint.

        Reading the ordering UUIDs as cell keys gives a table of the right
        SIZE whose every cell is empty — which looks like an empty table in
        the note, not like a bug.
        """
        data = mergeable.MergeableData(build_table(GRID))
        index, fields = None, None
        for i in range(len(data.entries)):
            name, found = data._raw_map(i)
            if name == mergeable.TABLE:
                index, fields = i, found
                break
        self.assertIsNotNone(index)
        ordered = data.ordered_cell_uuids(fields["crRows"][1])
        self.assertEqual(len(ordered), 3)
        # The resolved cell UUIDs must not be the ordering UUIDs themselves.
        ordering_set = data.entries[fields["crRows"][1]].message(16)
        raw = [a._fields[2][0]
               for a in ordering_set.message(1).message(1).messages(2)]
        self.assertFalse(set(ordered) & set(raw))

    def test_non_table_blob_returns_none(self):
        self.assertIsNone(mergeable.table_from_blob(b"\x0a\x02hi"))

    def test_empty_blob_returns_none(self):
        self.assertIsNone(mergeable.table_from_blob(b""))


class CellStyleTests(unittest.TestCase):
    """Bold and highlight inside a cell, rendered the way the body renders them."""

    def _wrap(self, pieces):
        """(text, bold, highlight[, url]) -> the real (text, marks) shape."""
        out = []
        for piece in pieces:
            text, bold, highlight = piece[0], piece[1], piece[2]
            url = piece[3] if len(piece) > 3 else None
            out.append((text, (bold, False, highlight, False, url)))
        return mergeable._wrap_runs(out)

    def test_bold_run_gets_markers(self):
        self.assertEqual(self._wrap([("Ride", True, False)]), "**Ride**")

    def test_highlight_run_gets_markers(self):
        self.assertEqual(self._wrap([("due", False, True)]), "==due==")

    def test_bold_and_highlight_nest(self):
        self.assertEqual(self._wrap([("x", True, True)]), "**==x==**")

    def test_plain_run_is_untouched(self):
        self.assertEqual(self._wrap([("4.5", False, False)]), "4.5")

    def test_bold_space_between_bold_words_stays_one_phrase(self):
        """🛑 Notes stores the space inside a bold phrase as its own bold run.

        Treating a whitespace-only run as unstyled splits the phrase into
        `**Hyperspace** **Mountain**`. Nine real cells came out that way.
        """
        out = self._wrap([("Hyperspace", True, False), (" ", True, False),
                          ("Mountain", True, False)])
        self.assertEqual(out, "**Hyperspace Mountain**")

    def test_unbolded_space_keeps_two_phrases(self):
        out = self._wrap([("Rated:", True, False), (" ", False, False),
                          ("Submitted:", True, False)])
        self.assertEqual(out, "**Rated:** **Submitted:**")

    def test_markers_never_wrap_only_whitespace(self):
        """`** **` renders as literal asterisks, so the marker moves off it."""
        self.assertEqual(self._wrap([("  ", True, False)]), "  ")

    def test_surrounding_space_stays_outside_the_markers(self):
        self.assertEqual(self._wrap([(" hi ", True, False)]), " **hi** ")

    def test_empty_run_is_dropped(self):
        self.assertEqual(self._wrap([("", True, False), ("a", False, False)]), "a")


class CellLinkTests(unittest.TestCase):
    """Links inside a cell, inline — `[text](url)`."""

    def _wrap(self, pieces):
        return mergeable._wrap_runs(
            [(t, (b, False, h, False, u)) for t, b, h, u in pieces])

    def test_link_run_becomes_a_markdown_link(self):
        out = self._wrap([("Anna Karenina", False, False, "https://gr.com/15823480")])
        self.assertEqual(out, "[Anna Karenina](https://gr.com/15823480)")

    def test_link_split_across_runs_stays_one_link(self):
        """⚠️ 26 adjacent run pairs share one URL; `[a](u)[b](u)` is two links."""
        url = "https://gr.com/1"
        out = self._wrap([("Anna", False, False, url), (" Karenina", False, False, url)])
        self.assertEqual(out, "[Anna Karenina](https://gr.com/1)")

    def test_bold_link_puts_the_link_inside(self):
        out = self._wrap([("Title", True, False, "https://x.com")])
        self.assertEqual(out, "**[Title](https://x.com)**")

    def test_two_urls_stay_two_links(self):
        out = self._wrap([("a", False, False, "https://x.com"),
                          ("b", False, False, "https://y.com")])
        self.assertEqual(out, "[a](https://x.com)[b](https://y.com)")


class LinkHelperTests(unittest.TestCase):
    def test_pasted_link_is_not_wrapped_twice(self):
        """⚠️ 88 body links have the URL as their own text; `[url](url)` is noise."""
        url = "https://example.com/x"
        self.assertEqual(notestore.markdown_link(url, url), url)

    def test_anchor_text_is_wrapped(self):
        self.assertEqual(notestore.markdown_link("docs", "https://example.com"),
                         "[docs](https://example.com)")

    def test_space_stays_outside_the_brackets(self):
        self.assertEqual(notestore.markdown_link(" docs ", "https://e.com"),
                         " [docs](https://e.com) ")

    def test_data_detector_is_not_a_link(self):
        """🛑 Notes made this one itself, from a date or an address in the text."""
        self.assertIsNone(notestore.usable_link("x-apple-data-detectors://2"))

    def test_coredata_reference_is_not_a_link(self):
        self.assertIsNone(notestore.usable_link("x-coredata://ABC/NOTE/p1"))

    def test_real_schemes_pass(self):
        for url in ("https://x.com", "http://x.com", "mailto:a@b.com", "tel:123",
                    "applenotes:note/abc", "obsidian://open?vault=v",
                    "message://%3Cabc%3E"):
            self.assertEqual(notestore.usable_link(url), url)

    def test_a_bare_word_is_not_a_uri(self):
        """A hashtag's token is `TRIPS`; a mention's is an account id."""
        self.assertFalse(notestore.looks_like_uri("TRIPS"))
        self.assertFalse(notestore.looks_like_uri("_6986b1cff8e5a709a2897491"))
        self.assertTrue(notestore.looks_like_uri("applenotes:note/abc"))


class EscapingTests(unittest.TestCase):
    """A literal `*` or `==` in a note must not read as a marker we emit."""

    def test_asterisk_is_escaped(self):
        self.assertEqual(notestore.escape_markdown("a * b"), r"a \* b")

    def test_double_asterisk_is_escaped(self):
        self.assertEqual(notestore.escape_markdown("ONE ** two"), r"ONE \*\* two")

    def test_backslash_is_escaped_so_escaping_stays_reversible(self):
        self.assertEqual(notestore.escape_markdown(r"a\b"), r"a\\b")

    def test_double_equals_is_escaped(self):
        self.assertEqual(notestore.escape_markdown("a !== b"), r"a !\=\= b")

    def test_single_equals_is_left_alone(self):
        """⚠️ A lone `=` is never a marker, and it is common in URLs."""
        self.assertEqual(notestore.escape_markdown("?a=1&b=2"), "?a=1&b=2")

    def test_intraword_underscore_is_left_alone(self):
        """⚠️ CommonMark ignores it, and 183 of 196 here are intraword."""
        self.assertEqual(notestore.escape_markdown("snake_case_name"),
                         "snake_case_name")

    def test_standalone_underscore_is_escaped(self):
        self.assertEqual(notestore.escape_markdown("_hi_"), r"\_hi\_")

    def test_brackets_are_not_escaped(self):
        """🛑 They only form a link next to `](`, which no note contains."""
        self.assertEqual(notestore.escape_markdown("see [1] and [2]"),
                         "see [1] and [2]")

    def test_char_and_string_escapers_agree(self):
        """They are two implementations of one rule, so pin them together."""
        sample = r"a*b \c == d _e_ f_g [1] ?x=1"
        by_char = "".join(
            notestore.escape_markdown_char(
                ch,
                sample[i - 1] if i else "",
                sample[i + 1] if i + 1 < len(sample) else "")
            for i, ch in enumerate(sample))
        self.assertEqual(by_char, notestore.escape_markdown(sample))

    def test_body_escapes_a_literal_asterisk_but_not_its_own_marker(self):
        runs = [ApplyRun.run(3, bold=True), ApplyRun.run(4)]
        out = cli.apply_formatting("abc * d", runs)
        self.assertEqual(out, r"**abc** \* d")

    def test_cell_escapes_a_literal_asterisk(self):
        """⚠️ A cell can carry text with no attribute run at all."""
        table = mergeable.table_from_blob(build_table([["2 * 3", "b"]]))
        self.assertEqual(table.grid[0][0], r"2 \* 3")


class SoftLineBreakTests(unittest.TestCase):
    """🛑 Characters a renderer breaks on that `split("\\n")` does not."""

    def test_bold_closes_around_u2028(self):
        runs = [ApplyRun.run(7, bold=True)]
        out = cli.apply_formatting("ab cd", runs)
        self.assertEqual(out, "**ab** **cd**")

    def test_bold_closes_around_carriage_return(self):
        """A bold run holding `'\\r\\n'` is what exposed this."""
        runs = [ApplyRun.run(6, bold=True)]
        out = cli.apply_formatting("ab\rcd", runs)
        self.assertEqual(out, "**ab**\r**cd**")

    def test_every_break_leaves_balanced_markers(self):
        for ch in notestore.SOFT_LINE_BREAKS:
            runs = [ApplyRun.run(2 + len("ab") + len("cd"), bold=True)]
            out = cli.apply_formatting("ab%scd" % ch, runs)
            for line in out.splitlines():
                self.assertEqual(line.count("**") % 2, 0,
                                 "unbalanced across %r: %r" % (ch, out))

    def test_link_closes_around_a_soft_break(self):
        url = "https://e.com"
        runs = [ApplyRun.run(5, link=url)]
        out = cli.apply_formatting("ab cd", runs)
        self.assertEqual(out, "[ab](%s) [cd](%s)" % (url, url))


class ApplyRun:
    """A run dict shaped the way `parse_note_content` emits one."""

    @staticmethod
    def run(length, attachment=None, link=None, bold=False, highlight=False):
        return {
            "length": length, "highlight": highlight, "bold": bold, "link": link,
            "italic": False, "strikethrough": 0, "underlined": 0,
            "attachment": attachment,
            "paragraph_style": {"style_type": -1, "indent": 0, "checklist": None},
        }


class InlineAttachmentTests(unittest.TestCase):
    """🛑 An inline text attachment is text, not a file."""

    def test_hashtag_renders_as_its_own_text(self):
        self.assertEqual(
            mergeable.inline_attachment_markdown(
                "h", "com.apple.notes.inlinetextattachment.hashtag",
                {"h": "#trips"}, {"h": "TRIPS"}),
            "#trips")

    def test_mention_renders_as_its_own_text(self):
        self.assertEqual(
            mergeable.inline_attachment_markdown(
                "m", "com.apple.notes.inlinetextattachment.mention",
                {"m": "@Dan"}, {"m": "_6986b1cff8e5"}),
            "@Dan")

    def test_note_link_becomes_a_link(self):
        self.assertEqual(
            mergeable.inline_attachment_markdown(
                "n", mergeable.INLINE_LINK_UTI,
                {"n": "2024 Yearly note"}, {"n": "applenotes:note/abc"}),
            "[2024 Yearly note](applenotes:note/abc)")

    def test_note_link_without_a_target_stays_plain(self):
        self.assertEqual(
            mergeable.inline_attachment_markdown(
                "n", mergeable.INLINE_LINK_UTI, {"n": "Some note"}, {}),
            "Some note")

    def test_unknown_identifier_falls_back(self):
        self.assertEqual(
            mergeable.inline_attachment_markdown("z", mergeable.INLINE_LINK_UTI),
            "attachment")


class WeightAndMarkTests(unittest.TestCase):
    """`font_weight` is an enum, and 3 means BOTH."""

    class _Run:
        def __init__(self, weight=None, strike=None):
            self._w, self._s = weight, strike

        def int32(self, field, default=0):
            if field == 5:
                return default if self._w is None else self._w
            if field == 7:
                return default if self._s is None else self._s
            return default

        def message(self, field):
            return None

        def string(self, field, default=None):
            return default

        def has(self, field):
            return False

    def test_weight_1_is_bold(self):
        self.assertTrue(notestore.run_is_bold(self._Run(1)))
        self.assertFalse(notestore.run_is_italic(self._Run(1)))

    def test_weight_2_is_italic(self):
        self.assertTrue(notestore.run_is_italic(self._Run(2)))
        self.assertFalse(notestore.run_is_bold(self._Run(2)))

    def test_weight_3_is_bold_AND_italic(self):
        """🛑 `== 1` for bold dropped it on every weight-3 run."""
        self.assertTrue(notestore.run_is_bold(self._Run(3)))
        self.assertTrue(notestore.run_is_italic(self._Run(3)))

    def test_weight_0_and_absent_are_plain(self):
        for run in (self._Run(0), self._Run(None)):
            self.assertFalse(notestore.run_is_bold(run))
            self.assertFalse(notestore.run_is_italic(run))

    def test_strikethrough_reads_field_7(self):
        self.assertTrue(notestore.run_is_strikethrough(self._Run(strike=1)))
        self.assertFalse(notestore.run_is_strikethrough(self._Run(strike=0)))

    # -- nesting ---------------------------------------------------------- #

    def marks(self, bold=False, italic=False, highlight=False, strike=False,
              url=None):
        return (bold, italic, highlight, strike, url)

    def test_italic_uses_underscore_not_star(self):
        """🛑 With `*`, bold-italic followed by italic emits `***x****`.

        Two real notes did exactly that. `_` cannot collide with `**`.
        """
        out = notestore.mark_transition(notestore.NO_MARKS, self.marks(italic=True))
        self.assertEqual(out, "_")

    def test_bold_italic_to_italic_stays_unambiguous(self):
        """The exact transition that produced `***GCP****`."""
        opened = notestore.mark_transition(
            notestore.NO_MARKS, self.marks(bold=True, italic=True))
        moved = notestore.mark_transition(
            self.marks(bold=True, italic=True), self.marks(italic=True))
        self.assertEqual(opened, "**_")
        self.assertEqual(moved, "_**_")
        self.assertNotIn("****", opened + "GCP" + moved)

    def test_only_what_must_close_closes(self):
        """An italic span ending inside a bold one must not split the bold."""
        out = notestore.mark_transition(
            self.marks(bold=True, italic=True), self.marks(bold=True))
        self.assertEqual(out, "_")

    def test_nesting_order_is_bold_outermost(self):
        out = notestore.mark_transition(
            notestore.NO_MARKS,
            self.marks(bold=True, italic=True, highlight=True, strike=True,
                       url="https://e.com"))
        self.assertEqual(out, "**_==~~[")

    def test_closing_is_the_reverse(self):
        marks = self.marks(bold=True, italic=True, strike=True,
                           url="https://e.com")
        out = notestore.mark_transition(marks, notestore.NO_MARKS)
        self.assertEqual(out, "](https://e.com)~~_**")

    def test_no_change_emits_nothing(self):
        marks = self.marks(bold=True)
        self.assertEqual(notestore.mark_transition(marks, marks), "")


class TableMarkdownTests(unittest.TestCase):
    def test_first_row_becomes_the_header(self):
        """⚠️ Notes has no header row; Markdown demands one, so row 1 is promoted."""
        out = mergeable.Table(GRID).markdown().splitlines()
        self.assertEqual(out[0], "| Quarter | Result |")
        self.assertEqual(out[1], "| --- | --- |")
        self.assertEqual(out[2], "| Q1 | up |")

    def test_pipe_in_a_cell_is_escaped(self):
        out = mergeable.Table([["a|b", "c"]]).markdown()
        self.assertIn(r"a\|b", out)

    def test_newline_in_a_cell_becomes_a_space(self):
        out = mergeable.Table([["one\ntwo", "c"]]).markdown()
        self.assertIn("| one two |", out)

    def test_short_row_is_padded(self):
        out = mergeable.Table([["a", "b"], ["c"]]).markdown().splitlines()
        self.assertEqual(out[-1], "| c |  |")

    def test_empty_grid_renders_nothing(self):
        self.assertEqual(mergeable.Table([]).markdown(), "")


class TitleLineTests(unittest.TestCase):
    """🛑 The note title must not be printed twice.

    `format_as_markdown` emits `# <title>` and then drops the body's own title
    line. Teaching the renderer to emit `# ` for the TITLE paragraph style
    broke that comparison, so **every export printed the title twice** until
    this was caught while checking the release.
    """

    def render(self, title, body):
        return cli.format_as_markdown(title, body)

    def test_a_plain_title_line_is_dropped(self):
        out = self.render("Recipe", "Recipe\n\nbody")
        self.assertEqual(out.count("Recipe"), 1)

    def test_a_hash_prefixed_title_line_is_dropped(self):
        """The regression: the renderer now prefixes a TITLE paragraph."""
        out = self.render("Recipe", "# Recipe\n\nbody")
        self.assertEqual(out.count("Recipe"), 1, out)

    def test_a_bold_title_line_is_dropped(self):
        """Notes makes a title bold, so the reader emits markers too."""
        out = self.render("Recipe", "# **Recipe**\n\nbody")
        self.assertEqual(out.count("Recipe"), 1, out)

    def test_a_title_after_a_blank_line_is_dropped(self):
        """⚠️ One real note opens with an empty line, putting its title on line 1."""
        out = self.render("Trip", "\nTrip\n\nbody")
        self.assertEqual(out.count("Trip"), 1, out)

    def test_a_body_that_repeats_the_title_keeps_the_second_copy(self):
        """⚠️ 4 real notes type their own title twice. That is content."""
        out = self.render("Banana Bread", "Banana Bread\n\nBanana Bread\n\nbody")
        self.assertEqual(out.count("Banana Bread"), 2, out)

    def test_a_different_first_line_is_kept(self):
        out = self.render("Recipe", "Ingredients\n\nbody")
        self.assertIn("Ingredients", out)


class TitleStyleTests(unittest.TestCase):
    """⚠️ An attachment-only line must not get a title prefix.

    A note that opens with an image takes its title FROM that image, so
    `# [attachment: clouds.png]` under `# clouds.png` reads as the same thing
    twice. Two real notes did that.
    """

    def _run(self, length, attachment=None, style_type=-1):
        return {
            "length": length, "highlight": False, "bold": False, "italic": False,
            "link": None, "strikethrough": 0, "underlined": 0,
            "attachment": attachment,
            "paragraph_style": {"style_type": style_type, "indent": 0,
                                "checklist": None},
        }

    def test_an_attachment_only_title_line_gets_no_hash(self):
        att = {"type_uti": "public.png", "identifier": "a"}
        out = cli.apply_formatting("￼", [self._run(1, attachment=att, style_type=0)],
                                   {"a": "clouds.png"})
        self.assertEqual(out, "[attachment: clouds.png]")

    def test_a_text_title_line_still_gets_a_hash(self):
        out = cli.apply_formatting("Heading", [self._run(7, style_type=0)])
        self.assertEqual(out, "# Heading")


class TableRenderingTests(unittest.TestCase):
    """The CLI side: a decoded table replaces the placeholder."""

    def test_rendered_table_wins_over_the_placeholder(self):
        att = {"type_uti": mergeable.TABLE_UTI, "identifier": "t"}
        self.assertEqual(
            cli.embedded_object_markdown(att, {}, {"t": "| a |"}), "| a |")

    def test_undecoded_table_still_falls_back(self):
        att = {"type_uti": mergeable.TABLE_UTI, "identifier": "t"}
        self.assertEqual(
            cli.embedded_object_markdown(att, {}, {}), "[attachment: table]")

    def _run(self, length, attachment=None, link=None, bold=False):
        return {
            "length": length, "highlight": False, "bold": bold, "link": link,
            "italic": False, "strikethrough": 0, "underlined": 0,
            "attachment": attachment,
            "paragraph_style": {"style_type": -1, "indent": 0, "checklist": None},
        }

    def test_astral_emoji_does_not_shift_later_runs(self):
        """🛑 A run's `length` counts UTF-16 units; Python indexes code points.

        One 🎢 is 2 units and 1 code point. Indexing by code point walks the
        format map one short per emoji, so the table's own run drifts off its
        U+FFFC and a real 46-row table renders as a bare `[attachment]`.
        """
        att = {"type_uti": mergeable.TABLE_UTI, "identifier": "t"}
        text = "a🎢b\n￼"
        runs = [
            self._run(5),   # "a🎢b\n" is 5 UTF-16 units, but 4 code points
            self._run(1, attachment=att),
        ]
        out = cli.apply_formatting(text, runs, {}, {"t": "| a |"})
        self.assertIn("| a |", out)
        self.assertNotIn("[attachment", out)

    def test_utf16_length_counts_code_units(self):
        self.assertEqual(cli.utf16_length("abc"), 3)
        self.assertEqual(cli.utf16_length("🎢"), 2)
        self.assertEqual(cli.utf16_length("a🎢b"), 4)
        self.assertEqual(cli.utf16_length("✈"), 1)

    def test_body_link_becomes_inline_markdown(self):
        runs = [self._run(4, link="https://example.com")]
        self.assertEqual(cli.apply_formatting("docs", runs),
                         "[docs](https://example.com)")

    def test_body_pasted_link_stays_bare(self):
        """⚠️ The text is the URL, so `[url](url)` would be noise."""
        url = "https://example.com/a"
        runs = [self._run(len(url), link=url)]
        self.assertEqual(cli.apply_formatting(url, runs), url)

    def test_body_link_split_across_runs_stays_one_link(self):
        url = "https://example.com"
        runs = [self._run(4, link=url), self._run(5, link=url)]
        self.assertEqual(cli.apply_formatting("docs page", runs),
                         "[docs page](https://example.com)")

    def test_body_link_closes_at_a_line_break(self):
        """⚠️ Markdown link text cannot span a line; 9 link runs contain one."""
        url = "https://example.com"
        runs = [self._run(9, link=url)]
        out = cli.apply_formatting("one\ntwo", runs)
        self.assertEqual(out, "[one](https://example.com)\n[two](https://example.com)")

    def test_body_bold_link_closes_in_reverse_order(self):
        """Closing in the opening order gives `**[a**](u)`, which no parser nests."""
        runs = [self._run(3, link="https://e.com", bold=True)]
        self.assertEqual(cli.apply_formatting("abc", runs),
                         "**[abc](https://e.com)**")

    def test_body_data_detector_is_not_linked(self):
        runs = [self._run(9, link="x-apple-data-detectors://3")]
        self.assertEqual(cli.apply_formatting("Wednesday", runs), "Wednesday")

    def test_table_line_is_padded_on_both_sides(self):
        """Without a blank line before, the row above is absorbed as the header."""
        att = {"type_uti": mergeable.TABLE_UTI, "identifier": "t"}
        text = "before\n￼\nafter"
        runs = [self._run(len("before\n")), self._run(1, attachment=att),
                self._run(len("\nafter"))]
        out = cli.apply_formatting(text, runs, {}, {"t": "| a |\n| --- |"})
        self.assertIn("before\n\n| a |\n| --- |\n\nafter", out)


if __name__ == "__main__":
    unittest.main()
