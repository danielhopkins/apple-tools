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
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import zipfile

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


# --------------------------------------------------------------------------
# reading the formats that are not text
# --------------------------------------------------------------------------
#
# ⚠️ Fixtures are BUILT here, never checked in. A .docx is a zip of XML, so
# writing one is three lines, and a binary fixture is a thing nobody can read
# in a diff when it starts failing.

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
P = "http://schemas.openxmlformats.org/presentationml/2006/main"


def build_docx(path, paragraphs):
    body = "".join(
        "<w:p>%s</w:p>" % "".join("<w:r><w:t>%s</w:t></w:r>" % run
                                  for run in runs)
        for runs in paragraphs)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("word/document.xml",
                         '<?xml version="1.0"?>'
                         '<w:document xmlns:w="%s"><w:body>%s</w:body>'
                         '</w:document>' % (W, body))
    return path


def build_pptx(path, slides):
    with zipfile.ZipFile(path, "w") as archive:
        for number, lines in slides:
            body = "".join("<a:p><a:r><a:t>%s</a:t></a:r></a:p>" % line
                           for line in lines)
            archive.writestr(
                "ppt/slides/slide%d.xml" % number,
                '<?xml version="1.0"?>'
                '<p:sld xmlns:a="%s" xmlns:p="%s">'
                '<p:cSld><p:spTree>%s</p:spTree>'
                '</p:cSld></p:sld>' % (A, P, body))
    return path


work = tempfile.mkdtemp(prefix="apple-index-files-")

check("a Word paragraph comes back as a line",
      index.office_text(build_docx(os.path.join(work, "a.docx"),
                                   [["Hello"], ["World"]])),
      "Hello\nWorld")

# ⚠️ Word splits a sentence across runs whenever formatting changes, so a
# reader that takes one run per line breaks every bold word onto its own.
check("runs inside one paragraph join without a break",
      index.office_text(build_docx(os.path.join(work, "b.docx"),
                                   [["Big ", "Daddy", " Bagels"]])),
      "Big Daddy Bagels")

# 🛑 The reason this uses ElementTree and not a regex over the XML.
check("an XML entity is un-escaped",
      index.office_text(build_docx(os.path.join(work, "c.docx"),
                                   [["Ben &amp; Jerry&apos;s"]])),
      "Ben & Jerry's")

check("an empty paragraph does not become a blank line",
      index.office_text(build_docx(os.path.join(work, "d.docx"),
                                   [["One"], [""], ["Two"]])),
      "One\nTwo")

# 🛑 THE BUG THIS PINS REORDERS EVERY DECK OF TEN OR MORE SLIDES. Sorted as
# strings, `slide10.xml` comes before `slide2.xml`, so the text reads as
# nonsense and nothing in the output says why.
check("slides sort numerically, not alphabetically",
      index.office_text(build_pptx(os.path.join(work, "e.pptx"),
                                   [(10, ["ten"]), (2, ["two"]),
                                    (1, ["one"])])),
      "one\ntwo\nten")

# ⚠️ Every unreadable shape is one answer, because the caller handles exactly
# one: there is nothing to index.
not_a_zip = os.path.join(work, "f.docx")
with open(not_a_zip, "w") as handle:
    handle.write("this is not a zip")
check("something that is not a zip reads as nothing",
      index.office_text(not_a_zip), None)

empty_zip = os.path.join(work, "g.docx")
zipfile.ZipFile(empty_zip, "w").close()
check("a zip with no document.xml reads as nothing",
      index.office_text(empty_zip), None)

check("a format this does not read is not guessed at",
      index.office_text(os.path.join(work, "h.rtf")), None)


# --------------------------------------------------------------------------
# the Obsidian deep link
# --------------------------------------------------------------------------
#
# 🛑 THE EXTENSION IS DROPPED ONLY FOR A NOTE. Obsidian addresses markdown
# without its extension, and everything else WITH it. Stripping `.pdf` yields a
# link that resolves to nothing and opens the vault at whatever Obsidian
# decides — a failure with no error and no clue in the output.

root = {"path": "/x/y/work", "name": "work"}
check("a note loses its extension",
      index.obsidian_url(root, "notes/Plan.md"),
      "obsidian://open?vault=work&file=notes/Plan")
check("a PDF keeps its extension",
      index.obsidian_url(root, "notes/Budget.pdf"),
      "obsidian://open?vault=work&file=notes/Budget.pdf")
check("a Word file keeps its extension",
      index.obsidian_url(root, "Agenda.docx"),
      "obsidian://open?vault=work&file=Agenda.docx")
# ⚠️ A dot in the name is not an extension. `2026.04.13 Agenda.docx` is a real
# file in this vault, and `splitext` on the wrong half loses half the name.
check("only the last dot is the extension",
      index.obsidian_url(root, "2026.04.13 Agenda.docx"),
      "obsidian://open?vault=work&file=2026.04.13%20Agenda.docx")


# --------------------------------------------------------------------------
# which extensions are read at all
# --------------------------------------------------------------------------

check("Word and PowerPoint are read", 
      sorted(index.FILE_OFFICE_EXTENSIONS), [".docx", ".pptx"])
# ⚠️ Deliberate. A spreadsheet's shared strings are labels and codes, not
# prose, and 6 files here would add 1.22M characters of them.
check("a spreadsheet is not", ".xlsx" in index.FILE_EXTENSIONS, False)
check("PDF is read", ".pdf" in index.FILE_EXTENSIONS, True)
# 🛑 The cap counts EXTRACTED TEXT. A PDF's bytes are mostly pictures: 30 of
# the 159 here exceed 2 MB on disk while holding ordinary amounts of text.
check("the byte guard is far above the text cap",
      index.FILE_MAX_BYTES > index.FILE_MAX_TEXT * 10, True)

shutil.rmtree(work, ignore_errors=True)


# --------------------------------------------------------------------------
# nesting a folder's contents under the folder
# --------------------------------------------------------------------------
#
# 🛑 THE ROOT COMES OUT OF THE `uid`, NOT THE CONTAINER. A record's container
# is its path RELATIVE to whichever folder holds it, so two configured folders
# that each hold a `Reading` folder are one row and nothing says which is
# which. Drawing that under a configured folder would attribute somebody
# else's files to it. The uid is `files:<name>:<relative>` and carries both.

def store(rows):
    """An in-memory index holding just what `files_by_root` reads."""
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    db.execute("CREATE TABLE record (rid INTEGER PRIMARY KEY, uid TEXT, "
               "tool TEXT, kind TEXT)")
    db.execute("CREATE TABLE chunk (cid INTEGER PRIMARY KEY, rid INTEGER)")
    for rid, (uid, kind, chunks) in enumerate(rows, start=1):
        db.execute("INSERT INTO record VALUES (?,?,?,?)",
                   (rid, uid, "files", kind))
        for _ in range(chunks):
            db.execute("INSERT INTO chunk (rid) VALUES (?)", (rid,))
    return db


def shape(rows):
    """{root: {folder: records}}, which is what the window draws."""
    return {r["name"]: {c["name"]: c["records"] for c in r["containers"]}
            for r in index.files_by_root(store(rows))}


check("a file in a subfolder is filed under its top folder",
      shape([("files:work:Reading/a.md", "note", 1),
             ("files:work:Reading/deep/b.md", "note", 1)]),
      {"work": {"Reading": 2}})

# 🛑 THE WHOLE POINT. Both roots have a `Reading`, and the flat list merged
# them into one row of 3.
check("two folders with the same subfolder stay apart",
      shape([("files:work:Reading/a.md", "note", 1),
             ("files:legal:Reading/b.md", "note", 1),
             ("files:legal:Reading/c.md", "note", 1)]),
      {"work": {"Reading": 1}, "legal": {"Reading": 2}})

# 🛑 THE AMBIGUITY THE CONTAINER CANNOT SETTLE. A file directly in root `work`
# and a file in a SUBFOLDER named `work` inside it both carry the container
# `work`. In the uid they differ by one slash, so they are two rows.
check("loose files are not merged with a subfolder of the same name",
      shape([("files:work:a.md", "note", 1),
             ("files:work:work/b.md", "note", 1)]),
      {"work": {"": 1, "work": 1}})

# ⚠️ "" IS A REAL ROW, not a missing one, and the window labels it.
check("a folder of nothing but loose files has one empty-named row",
      shape([("files:legal:a.pdf", "pdf", 1),
             ("files:legal:b.pdf", "pdf", 1)]),
      {"legal": {"": 2}})

roots = index.files_by_root(store([
    ("files:work:Reading/a.md", "note", 3),
    ("files:work:Reading/b.pdf", "pdf", 7),
    ("files:work:c.docx", "docx", 2),
]))
check("a folder totals its own records", roots[0]["records"], 3)
# ⚠️ Chunks, not records. They are what the index actually costs, and one long
# document can outweigh a hundred short ones.
check("and its own chunks", roots[0]["chunks"], 12)
# 🛑 THE COUNTS ARE PER FORMAT, which is the summary the window draws under
# each folder. It is the only place the new formats are visible as such.
check("and says what formats are in there",
      roots[0]["kinds"], {"note": 1, "pdf": 1, "docx": 1})

# ⚠️ Ties break on the name. Ordered by size alone, two folders of equal size
# swap places between refreshes, which reads as data changing.
check("equal folders sort by name, not at random",
      [c["name"] for c in index.files_by_root(store([
          ("files:w:b/1.md", "note", 1), ("files:w:a/1.md", "note", 1),
          ("files:w:c/1.md", "note", 1)]))[0]["containers"]],
      ["a", "b", "c"])

check("bigger folders come first",
      [c["name"] for c in index.files_by_root(store([
          ("files:w:small/1.md", "note", 1),
          ("files:w:big/1.md", "note", 1), ("files:w:big/2.md", "note", 1)
      ]))[0]["containers"]],
      ["big", "small"])

# 🛑 THE CUT IS PER FOLDER AND AFTER THE FOLD. Cutting first and folding what
# survives reports a folder short by everything past the cut — a wrong number,
# where a missing row is only a missing row. `truncated` says it happened.
many = index.files_by_root(store(
    [("files:w:f%02d/1.md" % n, "note", 1) for n in range(5)]), limit=3)[0]
check("the cut keeps the largest", len(many["containers"]), 3)
check("and says it cut", many["truncated"], True)
check("and stays quiet when it did not",
      index.files_by_root(store([("files:w:a/1.md", "note", 1)]))[0]["truncated"],
      False)

# ⚠️ A record whose uid predates the colon guard is charged to `(unknown)`
# rather than to the wrong folder. `files add` refuses such a name now.
check("an unparseable id is not charged to a real folder",
      shape([("files:nocolonhere", "note", 1)]),
      {"(unknown)": {"": 1}})


if FAILED:
    print("%d failed\n" % len(FAILED))
    for line in FAILED:
        print("  ✗ " + line)
    sys.exit(1)
print("files: all checks passed")
