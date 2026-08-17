"""
Pure unit tests for the embedded-object renderer. These exercise the CLI's
markdown logic directly and do NOT touch Notes.app, so they run without the
RUN_LIVE_NOTES_TESTS gate.
"""

import unittest

from tests import harness as h

cli = h.cli  # the loaded apple-notes CLI module


class EmbeddedObjectMarkdownTests(unittest.TestCase):
    def test_divider_renders_as_rule(self):
        att = {"type_uti": cli.DIVIDER_UTI, "identifier": "x"}
        self.assertEqual(cli.embedded_object_markdown(att, {}), "---")

    def test_named_attachment_uses_label(self):
        att = {"type_uti": "public.jpeg", "identifier": "abc"}
        self.assertEqual(
            cli.embedded_object_markdown(att, {"abc": "vacation.jpg"}),
            "[attachment: vacation.jpg]",
        )

    def test_table_without_label_falls_back_to_type(self):
        att = {"type_uti": "com.apple.notes.table", "identifier": "t"}
        self.assertEqual(cli.embedded_object_markdown(att, {}), "[attachment: table]")

    def test_inline_text_attachment_uses_short_type(self):
        att = {"type_uti": "com.apple.notes.inlinetextattachment.hashtag", "identifier": "h"}
        self.assertEqual(cli.embedded_object_markdown(att, {}), "[attachment: hashtag]")

    def test_missing_attachment_info_is_generic(self):
        self.assertEqual(cli.embedded_object_markdown(None, {}), "[attachment]")


class ApplyFormattingEmbeddedTests(unittest.TestCase):
    def _run(self, length, attachment=None, style_type=-1):
        return {
            "length": length,
            "highlight": False,
            "bold": False,
            "italic": False,
            "link": None,
            "strikethrough": 0,
            "underlined": 0,
            "paragraph_style": {"style_type": style_type, "indent": 0, "checklist": None},
            "attachment": attachment,
        }

    def test_divider_line_gets_blank_line_before(self):
        # "before\n￼\nafter" with the ￼ run flagged as a divider.
        text = "before\n￼\nafter"
        runs = [
            self._run(len("before\n")),
            self._run(1, attachment={"type_uti": cli.DIVIDER_UTI, "identifier": "d"}),
            self._run(len("\nafter")),
        ]
        out = cli.apply_formatting(text, runs)
        self.assertIn("before\n\n---", out)
        self.assertNotIn("￼", out)

    def test_attachment_placeholder_is_replaced(self):
        text = "see ￼ here"
        runs = [
            self._run(len("see ")),
            self._run(1, attachment={"type_uti": "public.jpeg", "identifier": "p"}),
            self._run(len(" here")),
        ]
        out = cli.apply_formatting(text, runs, {"p": "photo.jpg"})
        self.assertIn("[attachment: photo.jpg]", out)
        self.assertNotIn("￼", out)


if __name__ == "__main__":
    unittest.main()
