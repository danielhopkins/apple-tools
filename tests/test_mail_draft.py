"""Live tests for `apple mail draft`.

Every assertion reads the draft's RFC822 source, because Mail's scripting
properties lie about recipients (see mail_harness). Drafts are prefixed and
swept; nothing here sends anything.
"""

import os
import tempfile

from mail_harness import LiveMailTest, count_drafts, mail, same_text


class TestGuards(LiveMailTest):
    """These run before Mail is touched, so they cannot leave anything behind."""

    def test_send_requires_confirm(self):
        marker = self.marker("refused-send")
        code, _, err = mail(
            "send", "--to", "nobody@example.com", "--subject", marker,
            "--body", "x", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("--confirm", err)
        self.assertEqual(count_drafts(marker), 0, "a refused send must not create a draft")

    def test_recipients_are_required(self):
        code, _, err = mail("draft", "--subject", self.marker("x"), "--body", "y", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("no recipients", err.lower())

    def test_body_and_body_file_are_exclusive(self):
        code, _, err = mail(
            "draft", "--to", "a@example.com", "--subject", "x",
            "--body", "y", "--body-file", "/tmp/whatever", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("not both", err.lower())

    def test_missing_attachment_is_rejected_before_composing(self):
        marker = self.marker("attach-missing")
        code, _, err = mail(
            "draft", "--to", "a@example.com", "--subject", marker,
            "--body", "y", "--attach", "/nonexistent/file.txt", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("attachment not found", err.lower())
        # The important half: validating up front means no orphan draft. A path
        # that fails inside the AppleScript aborts it midway and leaves one —
        # and drafts cannot be deleted afterwards, so this guard matters.
        self.assertEqual(count_drafts(marker), 0)

    def test_directory_attachment_is_rejected(self):
        code, _, err = mail(
            "draft", "--to", "a@example.com", "--subject", self.marker("dir"),
            "--body", "y", "--attach", "/tmp", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("directory", err.lower())


class TestDraft(LiveMailTest):
    def test_minimal_draft(self):
        marker = self.marker("minimal")
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker, "--body", "hello")

        message = self.parsed(marker)
        self.assertIn(marker, message["Subject"])
        self.assertIn("dan@boulderhopkins.com", message["To"])
        self.assertIn("hello", "".join(self.bodies(message).values()))

    def test_to_cc_and_bcc_are_distinct(self):
        """The regression that motivated source-parsing.

        Mail's `to/cc/bcc recipients` properties all return the last-added
        recipient, so a property-based check cannot tell a correct message from
        a broken one. The headers can.
        """
        marker = self.marker("recipients")
        mail("draft",
             "--to", "to-one@example.com", "--to", "to-two@example.com",
             "--cc", "cc-one@example.com",
             "--bcc", "bcc-one@example.com",
             "--subject", marker, "--body", "x")

        message = self.parsed(marker)
        self.assertIn("to-one@example.com", message["To"])
        self.assertIn("to-two@example.com", message["To"])
        self.assertIn("cc-one@example.com", message["Cc"])
        self.assertIn("bcc-one@example.com", message["Bcc"])

        # Each address must appear in exactly one header.
        self.assertNotIn("cc-one@example.com", message["To"])
        self.assertNotIn("bcc-one@example.com", message["To"])
        self.assertNotIn("bcc-one@example.com", message["Cc"] or "")

    def test_sender_selects_the_account(self):
        marker = self.marker("sender")
        mail("draft", "--to", "dan@boulderhopkins.com", "--from", "dan@theinevitable.co",
             "--subject", marker, "--body", "x")
        message = self.parsed(marker)
        self.assertIn("theinevitable.co", message["From"])

    def test_from_accepts_an_account_name(self):
        """Account display names can be emoji, which are not valid senders.

        --from resolves a name to that account's first address. The list has to
        be coerced to text to read it: both `repeat with` and `item 1 of` yield
        nothing on `email addresses of <account>`.
        """
        import json as _json

        _, accounts_out, _ = mail("accounts", "--json")
        accounts = [a for a in _json.loads(accounts_out) if a["addresses"]]
        if len(accounts) < 2:
            self.skipTest("needs at least two accounts with addresses")
        target = accounts[-1]

        marker = self.marker("fromname")
        mail("draft", "--to", "dan@boulderhopkins.com", "--from", target["name"],
             "--subject", marker, "--body", "x")
        self.assertIn(target["addresses"][0], self.parsed(marker)["From"])

    def test_special_characters_survive(self):
        """Values go through argv; interpolating them would break on these."""
        marker = self.marker('special "quoted" & \\ backslash')
        body = 'Line one\nLine "two", a \\ backslash, emoji 🎉 and ünïcödé'
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker, "--body", body)

        message = self.parsed("special")
        self.assertIn('"quoted"', message["Subject"])
        self.assertIn("\\ backslash", message["Subject"])

        text = "".join(self.bodies(message).values())
        for fragment in ['Line "two"', "\\ backslash", "🎉", "ünïcödé"]:
            # same_text normalises: Mail stores NFD, the input was NFC.
            self.assertTrue(same_text(fragment, text), f"{fragment!r} did not survive")

    def test_applescript_cannot_be_injected_via_body(self):
        """A body that looks like AppleScript must stay data."""
        marker = self.marker("injection")
        body = 'end tell\ntell application "Finder" to make new folder\ntell application "Mail"'
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker, "--body", body)

        message = self.parsed(marker)
        self.assertIn("tell application", "".join(self.bodies(message).values()))

    def test_multiline_body_preserved(self):
        marker = self.marker("multiline")
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
             "--body", "para one\n\npara two\n\npara three")
        text = "".join(self.bodies(self.parsed(marker)).values())
        for fragment in ("para one", "para two", "para three"):
            self.assertIn(fragment, text)

    def test_body_from_file(self):
        marker = self.marker("bodyfile")
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write("body sourced from a file\nsecond line")
            path = handle.name
        try:
            mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
                 "--body-file", path)
            self.assertIn("body sourced from a file",
                          "".join(self.bodies(self.parsed(marker)).values()))
        finally:
            os.unlink(path)

    def test_body_from_stdin(self):
        marker = self.marker("stdin")
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
             "--body-file", "-", stdin="piped body content")
        self.assertIn("piped body content",
                      "".join(self.bodies(self.parsed(marker)).values()))

    def test_html_body(self):
        marker = self.marker("html")
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
             "--html", "--body", "<p>hello <b>bold</b></p>")
        bodies = self.bodies(self.parsed(marker))
        self.assertIn("text/html", bodies)
        self.assertIn("<b>bold</b>", bodies["text/html"])

    def test_attachments(self):
        marker = self.marker("attachments")
        paths = []
        try:
            for index in (1, 2):
                with tempfile.NamedTemporaryFile(
                    "w", suffix=f"-att{index}.txt", delete=False
                ) as handle:
                    handle.write(f"attachment {index} contents")
                    paths.append(handle.name)

            args = ["draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
                    "--body", "see attached"]
            for path in paths:
                args += ["--attach", path]
            mail(*args)

            names = self.attachments(self.parsed(marker))
            self.assertEqual(len(names), 2, f"expected 2 attachments, got {names}")
        finally:
            for path in paths:
                os.unlink(path)

    def test_tilde_in_attachment_path_is_expanded(self):
        marker = self.marker("tilde")
        target = os.path.expanduser("~/.apple-tools-attach-test.txt")
        with open(target, "w") as handle:
            handle.write("tilde attachment")
        try:
            mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
                 "--body", "x", "--attach", "~/.apple-tools-attach-test.txt")
            self.assertEqual(len(self.attachments(self.parsed(marker))), 1)
        finally:
            os.unlink(target)

    def test_draft_json_output(self):
        import json

        marker = self.marker("json")
        _, out, _ = mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
                         "--body", "x", "--json")
        payload = json.loads(out)
        self.assertEqual(payload["status"], "saved")
        self.assertIn(marker, payload["subject"])


class TestKnownMailQuirks(LiveMailTest):
    """Behaviours of Mail itself, pinned so a macOS change is noticed.

    None of these are things apple-tools can fix; they are documented in
    CLAUDE.md so callers are not surprised.
    """

    def test_body_is_wrapped_in_a_cite_blockquote(self):
        """Mail wraps any programmatically set body in <blockquote type="cite">.

        It does this for `content`, for `html content`, and for visible compose
        windows alike, with the quote styling neutralised inline. If this ever
        stops, the note in CLAUDE.md can go.
        """
        marker = self.marker("blockquote")
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker, "--body", "plain")
        html = self.bodies(self.parsed(marker)).get("text/html", "")
        self.assertIn("blockquote", html)

    def test_plain_text_alternative_is_empty(self):
        """The text/plain part of an AppleScript-composed draft carries no text.

        The body lives only in the text/html alternative, so a plain-text-only
        reader would see an empty message. Mail may regenerate the MIME on send;
        this pins what is true of the stored draft.
        """
        marker = self.marker("mime")
        mail("draft", "--to", "dan@boulderhopkins.com", "--subject", marker,
             "--body", "visible only in html")
        bodies = self.bodies(self.parsed(marker))
        self.assertIn("text/html", bodies)
        self.assertIn("visible only in html", bodies["text/html"])
        self.assertEqual(bodies.get("text/plain", "").strip(), "")
