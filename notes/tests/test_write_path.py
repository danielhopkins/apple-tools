"""
Guards on the Notes write path. Offline: nothing here runs a shortcut, so
nothing here can create a note.

🛑 **This file's first version created real notes in the user's iCloud.** It ran
`apple-notes create` in a subprocess to check the exit code, believing a
missing permission grant would stop the shortcut. It did not — two notes
titled `x` landed in the real account. **Never invoke `create` or `append` from
a test.** The exit path is tested by calling the function that implements it,
with the shortcut runner replaced.

🛑 **Two claims that turned out to be false, recorded so nobody re-derives
them:**

  - *"An unauthorized shortcut runs and writes nothing."* It writes. Every run
    during that investigation created a note.
  - *"`ZACCESSRESOURCEPERMISSION` holds the grants."* It does not. It stayed
    empty after a dialog was answered "Always Allow". No known local state
    reports whether a shortcut may run.

What was really wrong: `create` confirmed the write by matching the **title it
sent**, and Apple rewrites that title because the body is interpreted as
Markdown. The fixture prefix `__claude_notes_test__` is Markdown for bold, so
Apple stored `claude_notes_test…` and the match failed on every single run.
"""

import os
import time
import unittest

from tests import harness as h

cli = h.cli


class TitleVerificationTests(unittest.TestCase):
    """🛑 A create must be confirmed by creation time, never by title.

    Apple interprets the body as Markdown, so the first line is rewritten
    before it becomes the title. Matching the title we sent reported
    `created: false` for notes that were created correctly.
    """

    def test_markdown_in_the_first_line_changes_the_stored_title(self):
        """The exact input that produced a whole false diagnosis."""
        sent = "__claude_notes_test__ probe"
        # `__x__` is bold; Apple consumes the underscores and keeps the words.
        self.assertNotEqual(sent, "claude_notes_test probe")
        self.assertTrue(sent.startswith("__") and sent.count("__") >= 2,
                        "the old fixture prefix really was bold syntax")

    def test_the_test_prefix_carries_no_markdown(self):
        """🛑 The fixture prefix must survive the Markdown interpreter."""
        for ch in "_*#[]`~":
            self.assertNotIn(ch, h.TEST_PREFIX,
                             "%r in the test prefix is Markdown syntax" % ch)

    def test_legacy_prefixes_are_still_swept(self):
        """Notes written under the old prefix lost their underscores."""
        self.assertIn("__claude_notes_test__", h.LEGACY_TEST_PREFIXES)
        self.assertIn("claude_notes_test", h.LEGACY_TEST_PREFIXES)

    def test_note_created_since_is_the_confirmation_path(self):
        """It must query creation time, not title."""
        self.assertTrue(hasattr(cli, "note_created_since"))
        self.assertEqual(cli.APPLE_EPOCH_OFFSET, 978307200)


class ConfirmationStrategyTests(unittest.TestCase):
    """🛑 A write is confirmed by what CHANGED, never by what we sent.

    Apple rewrites the Markdown before storing it, so nothing we sent is
    reliably present afterwards:

        `__name__`      -> the title `name`      (bold consumed)
        `- [x] item`    -> the text `item`       (marker consumed)
        `## head`       -> the text `head`       (marker consumed)
        a pipe table    -> a single U+FFFC       (an attachment)

    `create` matched on the title it sent and reported `created: false` for
    every note it made. `append` matched on the first line it sent and reported
    failure for six working appends. Both now compare before and after.

    These read the source, because the alternative is writing to real iCloud.
    """

    def source(self):
        import inspect
        return inspect.getsource(cli)

    def test_create_confirms_by_creation_time(self):
        self.assertTrue(hasattr(cli, "note_created_since"))
        body = self.source()
        start = body.index("def cmd_create")
        end = body.index("def cmd_append")
        self.assertIn("note_created_since", body[start:end])

    def test_create_does_not_match_on_the_title_it_sent(self):
        body = self.source()
        start = body.index("def cmd_create")
        end = body.index("def cmd_append")
        self.assertNotIn("note_pks_titled(title)", body[start:end],
                         "cmd_create is matching a title Apple may rewrite")

    def test_append_confirms_by_comparing_before_and_after(self):
        body = self.source()
        start = body.index("def cmd_append")
        end = body.index("def sqlite_text_for")
        section = body[start:end]
        self.assertIn("before_text", section)
        self.assertIn("!= before_text", section)

    def test_append_does_not_match_on_the_text_it_sent(self):
        body = self.source()
        start = body.index("def cmd_append")
        end = body.index("def sqlite_text_for")
        section = body[start:end]
        self.assertNotIn("marker in text", section,
                         "cmd_append is matching text Apple may rewrite")


class AppendRefusesWithoutALiveTarget(unittest.TestCase):
    """🛑 No target means no append. Never run the shortcut on a guess.

    The shortcut matches the note by Name. A name that matches nothing does
    NOT fail — Shortcuts opens a note picker listing every note and waits for
    a human. Whatever they choose receives the text.

    Measured on the real store: four queued appends all landed on one note
    picked minutes later, while the note the caller named sat in Recently
    Deleted. `shortcuts run` returned in ~2s each time, so neither the exit
    code nor the elapsed time showed anything wrong.

    ⚠️ These call `cmd_append` directly with `run_shortcut` replaced, so the
    refusal is proved without any possibility of a write.
    """

    class Args:
        def __init__(self, identifier):
            self.identifier = identifier
            self.body = "text"
            self.body_file = None
            self.json = False

    def setUp(self):
        self._patched = {}
        for name in ("require_shortcuts", "find_note", "note_pks_titled",
                     "run_shortcut", "sqlite_text_for"):
            self._patched[name] = getattr(cli, name)
        cli.require_shortcuts = lambda: None
        self.ran = []
        cli.run_shortcut = lambda *a, **k: self.ran.append(a)
        cli.sqlite_text_for = lambda pk: "before"

    def tearDown(self):
        for name, original in self._patched.items():
            setattr(cli, name, original)

    def _append(self, found, live_pks):
        cli.find_note = lambda ident: found
        cli.note_pks_titled = lambda title: live_pks
        with self.assertRaises(SystemExit) as caught:
            cli.cmd_append(self.Args("7"))
        return caught.exception.code

    def test_a_target_in_recently_deleted_is_refused(self):
        """The exact case that redirected a write onto a real note."""
        code = self._append((7, "gone-note", "id", b"", False), live_pks=[])
        self.assertNotEqual(code, 0)
        self.assertEqual(self.ran, [], "the shortcut must not run without a target")

    def test_a_title_that_now_names_a_different_note_is_refused(self):
        """The note was renamed between lookup and write."""
        code = self._append((7, "some-title", "id", b"", False), live_pks=[99])
        self.assertNotEqual(code, 0)
        self.assertEqual(self.ran, [])

    def test_an_ambiguous_title_is_still_refused(self):
        code = self._append((7, "dupe", "id", b"", False), live_pks=[7, 8])
        self.assertNotEqual(code, 0)
        self.assertEqual(self.ran, [])

    def test_a_locked_note_is_refused_with_exit_2(self):
        code = self._append((7, "locked", "id", b"", True), live_pks=[7])
        self.assertEqual(code, 2)
        self.assertEqual(self.ran, [])

    def test_a_note_with_no_title_is_refused(self):
        code = self._append((7, "", "id", b"", False), live_pks=[7])
        self.assertNotEqual(code, 0)
        self.assertEqual(self.ran, [])

    def test_a_live_unique_target_does_run_the_shortcut(self):
        """The guard must not refuse the good case."""
        cli.find_note = lambda ident: (7, "good", "id", b"", False)
        cli.note_pks_titled = lambda title: [7]
        # The confirmation loop compares before and after; keep them different
        # so it reports success and returns instead of exiting.
        seen = iter(["before"] + ["after"] * 40)
        cli.sqlite_text_for = lambda pk: next(seen)
        # The success path prints; keep the suite's output clean.
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            cli.cmd_append(self.Args("7"))
        self.assertEqual(len(self.ran), 1, "the shortcut should have run once")


class NoGrantIntrospectionTests(unittest.TestCase):
    """🛑 The removed permission check must not come back without evidence."""

    def test_no_shortcut_permission_reader_exists(self):
        self.assertFalse(
            hasattr(cli, "shortcuts_authorized"),
            "ZACCESSRESOURCEPERMISSION is NOT the grant store — it stayed "
            "empty after a dialog was answered Always Allow")

    def test_status_does_not_claim_to_know_authorization(self):
        sc = cli.shortcuts_status()
        self.assertNotIn("unauthorized", sc,
                         "nothing local reports whether a shortcut may run")


class FailWriteTests(unittest.TestCase):
    """A write the store cannot confirm must exit non-zero.

    ⚠️ Called directly. Running the real `create` would write to iCloud, which
    is exactly the mistake this file was written to stop repeating.
    """

    def test_fail_write_exits_non_zero(self):
        with self.assertRaises(SystemExit) as caught:
            cli.fail_write("no new note appeared", "some title")
        self.assertNotEqual(caught.exception.code, 0)

    def test_shortcut_exit_code_is_documented_as_worthless(self):
        self.assertIn("exits 0", cli.fail_write.__doc__)


class NoLiveWriteTests(unittest.TestCase):
    """🛑 A structural guard: no test in this directory may run a write."""

    def test_no_test_spawns_a_write_command(self):
        """Parsed, not grepped, so this guard does not flag its own prose."""
        import ast
        import glob

        writes = {"create", "append", "install-shortcuts"}
        here = os.path.dirname(os.path.abspath(__file__))
        offenders = []

        for path in glob.glob(os.path.join(here, "test_*.py")):
            tree = ast.parse(open(path, encoding="utf-8").read(), path)
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                func = node.func
                name = getattr(func, "attr", getattr(func, "id", ""))
                if name not in ("run", "Popen", "check_output", "call"):
                    continue
                for arg in node.args:
                    if not isinstance(arg, ast.List):
                        continue
                    words = {e.value for e in arg.elts
                             if isinstance(e, ast.Constant) and isinstance(e.value, str)}
                    if words & writes:
                        offenders.append(
                            (os.path.basename(path), node.lineno,
                             sorted(words & writes)))

        self.assertEqual(offenders, [],
                         "a test spawns a Notes write command; it would create "
                         "real notes in the user's iCloud")


if __name__ == "__main__":
    unittest.main()
