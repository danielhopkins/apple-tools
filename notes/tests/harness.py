"""
Test harness for exercising the Apple Notes APIs.

These tests drive the *live* Notes.app via AppleScript and verify results both
through AppleScript and through the read-only SQLite path that the `apple-notes`
CLI uses. They therefore mutate your real iCloud Notes (briefly) and cannot run
in CI.

Safety model
------------
- Every note created by the suite is named with TEST_PREFIX. `delete_note` and
  `sweep_test_notes` refuse to touch any note whose name does not start with it,
  so the suite can never delete your real notes.
- Use the `temp_note()` context manager so notes are always deleted in teardown,
  even on assertion failure.
- AppleScript `delete` only moves notes to "Recently Deleted" (a documented
  quirk); test notes land there and auto-purge after ~30 days. There is no
  AppleScript API to empty that folder.
- The suite is gated behind RUN_LIVE_NOTES_TESTS=1 (see ensure_live_or_skip) so
  it never runs by accident.
"""

import os
import re
import sys
import time
import sqlite3
import subprocess
import importlib.util
import contextlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEST_PREFIX = "__claude_notes_test__"

DB_PATH = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
)


# --------------------------------------------------------------------------- #
# Reuse the real CLI's protobuf parser so tests exercise shipping code.
# The CLI file is named `apple-notes` (no .py extension), so load it by path.
# Importing does not run main() because that is guarded by __name__.
# --------------------------------------------------------------------------- #
def _load_cli():
    # The CLI file has no .py extension, so name a SourceFileLoader explicitly.
    import importlib.machinery

    loader = importlib.machinery.SourceFileLoader("apple_notes_cli", str(ROOT / "apple-notes"))
    spec = importlib.util.spec_from_loader("apple_notes_cli", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


cli = _load_cli()


# --------------------------------------------------------------------------- #
# AppleScript plumbing
# --------------------------------------------------------------------------- #
class AppleScriptError(RuntimeError):
    pass


def osascript(script: str) -> str:
    """Run an AppleScript snippet and return trimmed stdout, raising on error."""
    proc = subprocess.run(
        ["osascript", "-"],
        input=script,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise AppleScriptError(proc.stderr.strip() or f"osascript exit {proc.returncode}")
    return proc.stdout.rstrip("\n")


def _as_str(s: str) -> str:
    """Quote a Python string as an AppleScript string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notes_available() -> bool:
    """True if we are on macOS and Notes is scriptable."""
    if sys.platform != "darwin":
        return False
    try:
        osascript('tell application "Notes" to count notes')
        return True
    except AppleScriptError:
        return False


def ensure_live_or_skip():
    """Raise unittest.SkipTest unless the suite is explicitly enabled and able to run."""
    import unittest

    if os.environ.get("RUN_LIVE_NOTES_TESTS") != "1":
        raise unittest.SkipTest(
            "live Notes tests are gated; set RUN_LIVE_NOTES_TESTS=1 to run "
            "(they mutate your real iCloud Notes)"
        )
    if not notes_available():
        raise unittest.SkipTest("Notes.app is not scriptable on this machine")


# --------------------------------------------------------------------------- #
# Note operations (AppleScript)
# --------------------------------------------------------------------------- #
def create_note(body_html: str) -> str:
    """Create a note and return its AppleScript id (an x-coredata:// URL)."""
    return osascript(
        f'tell application "Notes" to return id of '
        f"(make new note with properties {{body:{_as_str(body_html)}}})"
    )


def unique_title(label: str = "") -> str:
    """A collision-resistant, prefix-tagged title (also becomes the note's name)."""
    stamp = f"{time.time():.6f}".replace(".", "")
    return f"{TEST_PREFIX}{label}-{stamp}" if label else f"{TEST_PREFIX}{stamp}"


def get_name(note_id: str) -> str:
    return osascript(f'tell application "Notes" to return name of note id {_as_str(note_id)}')


def get_body(note_id: str) -> str:
    return osascript(f'tell application "Notes" to return body of note id {_as_str(note_id)}')


def get_plaintext(note_id: str) -> str:
    return osascript(f'tell application "Notes" to return plaintext of note id {_as_str(note_id)}')


def set_body(note_id: str, body_html: str) -> None:
    osascript(
        f'tell application "Notes" to set body of note id {_as_str(note_id)} '
        f"to {_as_str(body_html)}"
    )


def append_body(note_id: str, extra_html: str) -> None:
    """Append HTML by concatenating onto the current body. The `as text` coercion
    is defensive (plain `&` also works); it avoids the -1700 you hit if you later
    operate on `body` in a numeric context."""
    osascript(
        f'tell application "Notes" to set body of note id {_as_str(note_id)} '
        f"to ((body of note id {_as_str(note_id)}) as text) & {_as_str(extra_html)}"
    )


def folder_name(note_id: str) -> str:
    return osascript(
        f'tell application "Notes" to return name of container of note id {_as_str(note_id)}'
    )


def add_attachment(note_id: str, file_path: str) -> str:
    """Attach a file and return the new attachment's id."""
    return osascript(
        f'tell application "Notes" to return id of '
        f"(make new attachment at end of note id {_as_str(note_id)} "
        f"with data (POSIX file {_as_str(file_path)}))"
    )


def count_attachments(note_id: str) -> int:
    return int(
        osascript(f'tell application "Notes" to return count of attachments of note id {_as_str(note_id)}')
    )


def attachment_info(note_id: str) -> list[dict]:
    """Return [{name, cid, shared}, ...] for each attachment on the note."""
    out = osascript(
        'tell application "Notes"\n'
        "set AppleScript's text item delimiters to \"\"\n"
        f"set n to note id {_as_str(note_id)}\n"
        'set acc to ""\n'
        "repeat with a in attachments of n\n"
        '  set acc to acc & (name of a) & "\\t" & (content identifier of a) & "\\t" & (shared of a) & linefeed\n'
        "end repeat\n"
        "return acc\n"
        "end tell"
    )
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        name, cid, shared = (line.split("\t") + ["", "", ""])[:3]
        rows.append({"name": name, "cid": cid, "shared": shared == "true"})
    return rows


def delete_note(note_id: str) -> None:
    """Delete a note — refuses unless its name carries TEST_PREFIX (safety)."""
    name = get_name(note_id)
    if not name.startswith(TEST_PREFIX):
        raise AppleScriptError(
            f"refusing to delete note {note_id!r}: name {name!r} lacks test prefix"
        )
    osascript(f'tell application "Notes" to delete note id {_as_str(note_id)}')


def _silent_delete(note_id: str) -> None:
    """Best-effort delete used in addCleanup; never raises."""
    with contextlib.suppress(AppleScriptError):
        delete_note(note_id)


def sweep_test_notes() -> int:
    """Delete every note whose name starts with TEST_PREFIX. Returns count deleted."""
    return int(
        osascript(
            'tell application "Notes"\n'
            f"set victims to (notes whose name starts with {_as_str(TEST_PREFIX)})\n"
            "set n to count of victims\n"
            "repeat with v in victims\n"
            "  delete v\n"
            "end repeat\n"
            "return n\n"
            "end tell"
        )
    )


@contextlib.contextmanager
def temp_note(body_html: str | None = None, label: str = ""):
    """Create a prefixed throwaway note, yield its id, and always delete it."""
    title = unique_title(label)
    body = body_html if body_html is not None else f"<div><h1>{title}</h1></div>"
    if f"{TEST_PREFIX}" not in body:
        # Guarantee the safety prefix is the note's name (first line -> title).
        body = f"<div><h1>{title}</h1></div>" + body
    note_id = create_note(body)
    try:
        yield note_id
    finally:
        with contextlib.suppress(AppleScriptError):
            delete_note(note_id)


# --------------------------------------------------------------------------- #
# SQLite verification path (read-only — never writes to the live DB)
# --------------------------------------------------------------------------- #
def pk_from_note_id(note_id: str) -> int:
    """Extract the Core Data Z_PK from an x-coredata://.../ICNote/pNNNN id."""
    m = re.search(r"/p(\d+)$", note_id)
    if not m:
        raise ValueError(f"cannot parse Z_PK from note id: {note_id!r}")
    return int(m.group(1))


def _ro_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


def sqlite_note_text(pk: int) -> str | None:
    """Return decoded note text via the CLI's protobuf parser, or None if absent."""
    conn = _ro_conn()
    try:
        row = conn.execute(
            "SELECT ZDATA FROM ZICNOTEDATA WHERE ZNOTE = ? AND ZDATA IS NOT NULL", (pk,)
        ).fetchone()
    finally:
        conn.close()
    if not row or not row[0]:
        return None
    text, _runs = cli.parse_note_content(row[0])
    return text


def sqlite_folder_name(pk: int) -> str | None:
    conn = _ro_conn()
    try:
        row = conn.execute(
            "SELECT f.ZTITLE2 FROM ZICCLOUDSYNCINGOBJECT n "
            "LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK WHERE n.Z_PK = ?",
            (pk,),
        ).fetchone()
    finally:
        conn.close()
    return row[0] if row else None


def export_markdown(pk: int) -> str | None:
    """Run the CLI's full export pipeline for a note Z_PK and return its markdown."""
    res = cli.find_note(str(pk))
    if not res:
        return None
    _pk, title, _ident, zdata = res
    text, runs = cli.parse_note_content(zdata)
    labels = cli.get_attachment_labels(
        [r["attachment"]["identifier"] for r in runs if r.get("attachment")]
    )
    return cli.format_as_markdown(title, cli.apply_formatting(text, runs, labels))


def object_replacement_count(text: str) -> int:
    """Count U+FFFC object-replacement chars — each marks one inline attachment."""
    return text.count("￼")


def poll(fn, *, timeout: float = 10.0, interval: float = 0.3):
    """Poll fn() until it returns a truthy value or timeout; returns last value.

    Local AppleScript edits propagate to NoteStore.sqlite with a short lag, so
    SQLite assertions must wait rather than read immediately.
    """
    deadline = time.time() + timeout
    val = fn()
    while not val and time.time() < deadline:
        time.sleep(interval)
        val = fn()
    return val
