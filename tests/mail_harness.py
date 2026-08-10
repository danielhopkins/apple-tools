"""Shared helpers for the live apple-mail tests.

This used to be the harness for a draft-composition suite, with machinery for
creating drafts, reading them back through their RFC822 `source`, and sweeping
them to trash afterwards. All of that went when composing was removed in
26.810.0 — see `docs/apple-mail-drafts.md` for why.

What remains is what the read-guard suite needs: locating the built binary and
answering whether Mail is up and whether it is still servicing Apple Events.

⚠️ **`mail_running` matches on the executable path, not the process name.**
`pgrep -x Mail` does not match a running Mail.app; `pgrep -f
Mail.app/Contents/MacOS/Mail` does. A check that silently never matches reads as
"Mail is closed" and quietly voids every assertion conditioned on it.
"""

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def binary(name):
    for candidate in (ROOT / "swift/.build/release" / name, ROOT / "swift/.build/debug" / name):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    from shutil import which

    found = which(name)
    if not found:
        raise RuntimeError(f"{name} not built; run 'make build'")
    return found


def mail(*args, check=True, stdin=None):
    proc = subprocess.run(
        [binary("apple-mail"), *args], capture_output=True, text=True, input=stdin
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"apple-mail {' '.join(args)} failed ({proc.returncode})\n"
            f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
        )
    return proc.returncode, proc.stdout, proc.stderr


def mail_running():
    # `comm` is the full executable path, so match on that rather than the
    # process name — `pgrep -x Mail` does not match a running Mail.app.
    return subprocess.run(
        ["/usr/bin/pgrep", "-f", "Mail.app/Contents/MacOS/Mail"],
        capture_output=True,
    ).returncode == 0


# A wedged Mail still answers trivial requests: `tell application "Mail" to
# return name` came back instantly from an app macOS was reporting as "not
# responding". The probe therefore has to touch a mailbox, which is the thing
# a wedged Mail cannot do.
HEALTH_PROBE = """
tell application "Mail" to return (count of messages of mailbox "Drafts" of account 1) as string
"""


def mail_responsive(timeout=20):
    """Whether Mail can still do real work, not just answer static properties."""
    if not mail_running():
        return False
    try:
        proc = subprocess.run(
            ["/usr/bin/osascript", "-e", HEALTH_PROBE],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False
    # A wedged Mail returns success with empty output as readily as it errors.
    return proc.returncode == 0 and proc.stdout.strip() != ""
