#!/usr/bin/env python3
"""Offline checks for where the `files` source keeps its configuration.

🛑 THE BUG THIS PINS DESTROYED CONFIGURATION SILENTLY. `FILES_CONFIG` was
`dirname(DEFAULT_DB)/files.json`, and that path follows the encrypted vault:
it is `<support>/mnt/files.json` whenever AppleTools has the image mounted. So
a folder added while the app was running was written inside the volume, was
unreadable the moment the app quit, and `apple-index forget` deleted it with
the index. Nothing reported any of that — the folder simply stopped being
indexed.

⚠️ None of it is visible in the output either. A configuration that was lost
looks exactly like one that was never written.

No index, no app, no network. Run it directly:

    ./test-files.py
"""
import json
import os
import subprocess
import sys
import tempfile

import index

FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


# --------------------------------------------------------------------------
# where it lives
# --------------------------------------------------------------------------

# 🛑 THE WHOLE POINT. `mnt` is the vault mount, and nothing the user typed may
# live inside something an unmount takes away.
check("the config is not inside the vault mount",
      os.sep + "mnt" + os.sep in index.FILES_CONFIG, False)
check("the config sits beside the other app state",
      os.path.dirname(index.FILES_CONFIG),
      os.path.expanduser("~/Library/Application Support/apple-tools"))

# ⚠️ An explicit APPLE_INDEX_DB still wins, because `lab/bench` relies on it to
# keep its own configuration away from the real one.
#
# 🛑 RUN IN A CHILD, WITH THE VARIABLE SET. Asserting it against THIS process
# proves nothing: the variable is unset here, so the claim passes without ever
# reaching the branch it names. A review caught exactly that.
_probe = subprocess.run(
    [sys.executable, "-c",
     "import index, os; print(os.path.dirname(index.FILES_CONFIG))"],
    cwd=os.path.dirname(os.path.abspath(__file__)),
    env=dict(os.environ, APPLE_INDEX_DB="/tmp/apple-index-test/x.db"),
    capture_output=True, text=True)
check("an explicit APPLE_INDEX_DB moves the config with the database",
      _probe.stdout.strip(), "/tmp/apple-index-test")


# --------------------------------------------------------------------------
# reading, writing, and the copy left at the old path
# --------------------------------------------------------------------------

def with_paths(current, legacy, run):
    """Swap the two module constants for one check and put them back."""
    was = (index.FILES_CONFIG, index.FILES_CONFIG_LEGACY)
    index.FILES_CONFIG, index.FILES_CONFIG_LEGACY = current, legacy
    try:
        return run()
    finally:
        index.FILES_CONFIG, index.FILES_CONFIG_LEGACY = was


with tempfile.TemporaryDirectory() as home:
    current = os.path.join(home, "support", "files.json")
    legacy = os.path.join(home, "mnt", "files.json")
    os.makedirs(os.path.dirname(current))
    os.makedirs(os.path.dirname(legacy))

    check("nothing anywhere reads as no roots",
          with_paths(current, legacy, lambda: index.read_files_config()),
          {"roots": []})

    # An install that configured folders before the fix keeps them.
    with open(legacy, "w") as handle:
        json.dump({"roots": [{"path": "/tmp/vault", "name": "vault"}]}, handle)
    check("the old path is still read",
          with_paths(current, legacy,
                     lambda: index.read_files_config()["roots"][0]["name"]),
          "vault")

    # 🛑 WRITES GO TO THE NEW PATH ONLY. Writing back to the old one is what
    # made the loss survive the fix.
    with_paths(current, legacy,
               lambda: index.write_files_config({"roots": [{"path": "/tmp/a"}]}))
    check("a write lands at the new path", os.path.exists(current), True)
    check("a write leaves the old path alone",
          json.load(open(legacy))["roots"][0]["name"], "vault")
    check("the new path wins once it exists",
          with_paths(current, legacy,
                     lambda: index.read_files_config()["roots"][0]["path"]),
          "/tmp/a")

    # ⚠️ 0600, like every other file here. The roots name folders whose
    # contents are about to be read into the index.
    check("the config is not world readable",
          oct(os.stat(current).st_mode & 0o777), "0o600")

    # A file that is not JSON is not a crash, and not a silent empty either —
    # it falls through to the next candidate.
    with open(current, "w") as handle:
        handle.write("{not json")
    check("unreadable JSON falls back rather than raising",
          with_paths(current, legacy,
                     lambda: index.read_files_config()["roots"][0]["name"]),
          "vault")


# --------------------------------------------------------------------------
# what `files_roots` hands the ingester
# --------------------------------------------------------------------------

with tempfile.TemporaryDirectory() as home:
    current = os.path.join(home, "files.json")
    real = os.path.join(home, "notes")
    os.makedirs(real)
    with open(current, "w") as handle:
        json.dump({"roots": [
            {"path": real},
            {"path": os.path.join(home, "gone")},
            {"path": ""},
        ]}, handle)
    roots = with_paths(current, current, lambda: index.files_roots())
    # ⚠️ An empty path is dropped; a MISSING one is not. A folder on an
    # unmounted disk must still be reported, because dropping it silently is
    # how a configured root turns into "you never added one".
    check("an empty path is dropped", len(roots), 2)
    check("the name defaults to the folder name", roots[0]["name"], "notes")
    check("a missing folder is still a configured root",
          os.path.basename(roots[1]["path"]), "gone")


# --------------------------------------------------------------------------
# what the window shows for a folder
# --------------------------------------------------------------------------
#
# 🛑 A VAULT'S CONTAINERS ARE PATHS, NOT NAMES. Every other source files a
# record under an account, a mailbox, a calendar or a list — one flat name. A
# file is filed under its whole relative folder, so `files` alone produced 49
# rows, most of them a subfolder of another row, ordered by size. That answers
# "which folder is biggest", which is not the question. The question is what
# the top level holds.

def fold(parts, limit=None):
    return index.top_level_containers(
        [{"name": n, "records": r, "chunks": c} for n, r, c in parts], limit)


check("a nested path folds to its first segment",
      fold([("Reading/Books", 222, 400), ("Reading/Works", 82, 90)]),
      [{"name": "Reading", "records": 304, "chunks": 490}])

check("a folder with no children keeps its name",
      fold([("Directory", 265, 300)]),
      [{"name": "Directory", "records": 265, "chunks": 300}])

# ⚠️ A FOLDER AND ITS OWN SUBFOLDERS ARE ONE ROW. `01 - Current Work` holds 79
# files itself and `01 - Current Work/Meeting Notes` holds 48. Reported apart,
# neither number is the answer to "how big is Current Work".
check("a folder's own files join its subfolders",
      fold([("Work", 79, 100), ("Work/Meeting Notes", 48, 60)]),
      [{"name": "Work", "records": 127, "chunks": 160}])

check("depth beyond two segments still folds to the first",
      fold([("A/B/C/D", 5, 6)]),
      [{"name": "A", "records": 5, "chunks": 6}])

# Biggest first, so the eye lands on the folder that matters.
check("rows come back biggest first",
      [p["name"] for p in fold([("A", 1, 1), ("B", 9, 9), ("C", 5, 5)])],
      ["B", "C", "A"])

# ⚠️ TIES BREAK ON NAME, not on whichever order sqlite happened to return. A
# listing that reshuffles between two refreshes reads as data changing.
check("a tie breaks on the name",
      [p["name"] for p in fold([("Z", 4, 4), ("A", 4, 4)])],
      ["A", "Z"])

# 🛑 THE LIMIT APPLIES AFTER THE FOLD, NEVER BEFORE. Cutting the largest PATHS
# first and folding what survives reports a top-level folder short by
# everything past the cut — a wrong number, where a missing row is only a
# missing row.
#
# ⚠️ This case is built so the two orders disagree. `A` holds three files
# across three subfolders and `B` holds two. Folded first, `A` wins at 3.
# Cut first, the biggest single PATH is `B` at 2 and `A` arrives as 1.
check("the limit counts folded rows, not paths",
      fold([("A/1", 1, 1), ("A/2", 1, 1), ("A/3", 1, 1), ("B", 2, 2)], 1),
      [{"name": "A", "records": 3, "chunks": 3}])
check("nothing below the limit is lost",
      fold([("A/1", 1, 1), ("A/2", 1, 1), ("A/3", 1, 1)], 1),
      [{"name": "A", "records": 3, "chunks": 3}])

# ⚠️ A record with no container at all is not a folder called "(none)". It is
# left exactly as the caller wrote it.
check("a source with no container is left alone",
      fold([("(none)", 7, 8)]),
      [{"name": "(none)", "records": 7, "chunks": 8}])

# A trailing or doubled separator is a path, not a new folder.
check("a leading separator does not make an empty folder",
      fold([("/A/B", 2, 2)]),
      [{"name": "A", "records": 2, "chunks": 2}])

check("nothing in, nothing out", fold([]), [])


if FAILED:
    print("%d failed\n" % len(FAILED))
    for line in FAILED:
        print("  ✗ " + line)
    sys.exit(1)
print("files: all checks passed")
