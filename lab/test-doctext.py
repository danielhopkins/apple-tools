#!/usr/bin/env python3
"""Offline checks for `doctext`, the PDF reader.

🛑 THE THING THIS PINS HARDEST IS A REFUSAL. `doctext` measures how much prose
each page carries and reports the pages that carry little, and it NEVER DROPS
ONE. That restraint was not the first design; it is what the measurement forced.
An earlier version dropped low-prose pages as wreckage, and on 159 real PDFs
the pages it wanted to delete included a plant list and a page headed CONTACT
LIST holding the HOA's insurer, animal control and the police. Those are the
most retrievable pages in the file. See vec/Sources/doctext/Quality.swift.

⚠️ So `chars` must always equal the WHOLE text. A future change that starts
filtering will fail here rather than quietly losing somebody's phone numbers.

Fixtures are BUILT, never checked in: a valid one-page PDF is about 600 bytes
of ASCII, and a binary fixture is a thing nobody can read in a diff when it
starts failing. No index, no app, no network.

    ./test-doctext.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import index

FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


# --------------------------------------------------------------------------
# building a PDF by hand
# --------------------------------------------------------------------------
#
# ⚠️ THE OFFSETS IN THE xref TABLE MUST BE REAL. PDFKit is tolerant of much,
# but a test that leans on that tolerance stops testing what it claims to.
# Every offset here is measured from the bytes actually written.

def build_pdf(path, pages):
    """A PDF of `pages`, each a list of lines set in Helvetica."""
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)          # 1-based object number

    font = add(b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
    page_numbers, content_numbers = [], []
    for lines in pages:
        text = [b"BT /F1 11 Tf 54 738 Td 13 TL"]
        for line in lines:
            escaped = (line.replace("\\", r"\\").replace("(", r"\(")
                           .replace(")", r"\)"))
            text.append(b"(" + escaped.encode("latin-1", "replace") + b") Tj T*")
        text.append(b"ET")
        stream = b"\n".join(text)
        content_numbers.append(
            add(b"<</Length %d>>\nstream\n" % len(stream) + stream
                + b"\nendstream"))
        page_numbers.append(None)    # reserved: filled in below

    pages_number = len(objects) + len(pages) + 1
    for position, content in enumerate(content_numbers):
        page_numbers[position] = add(
            b"<</Type/Page/Parent %d 0 R/MediaBox[0 0 612 792]"
            b"/Contents %d 0 R/Resources<</Font<</F1 %d 0 R>>>>>>"
            % (pages_number, content, font))
    kids = b" ".join(b"%d 0 R" % n for n in page_numbers)
    add(b"<</Type/Pages/Kids[" + kids + b"]/Count %d>>" % len(pages))
    catalog = add(b"<</Type/Catalog/Pages %d 0 R>>" % pages_number)

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    start = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += (b"trailer\n<</Size %d/Root %d 0 R>>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, catalog, start))
    with open(path, "wb") as handle:
        handle.write(bytes(out))
    return path


def run(*paths, **kwargs):
    """`doctext` over these paths, as a list of parsed records."""
    args = [index.DOCTEXT]
    if kwargs.get("no_text"):
        args.append("--no-text")
    args.append("-")
    proc = subprocess.run(args, input="\n".join(paths),
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True)
    return [json.loads(line) for line in proc.stdout.splitlines()]


if not os.path.isfile(index.DOCTEXT):
    print("doctext is not built. Run: make -C %s" % os.path.dirname(index.DOCTEXT))
    sys.exit(1)

work = tempfile.mkdtemp(prefix="apple-index-doctext-")

PROSE = ["The board will meet on the first Monday of the month to review the",
         "budget and to decide what should be done about the fence, which has",
         "not been repaired since the storm and is now a hazard to the people",
         "who walk past it on their way to the school at the end of the road."]
LIST = ["YELLOW NIPPLE CACTUS Coryphantha missouriensis",
        "PLAINS YUCCA Yucca glauca",
        "ROCKY MOUNTAIN MAPLE Acer glabrum",
        "PINYON PINE Pinus edulis",
        "COLORADO BLUE SPRUCE Picea pungens",
        "ARNICA Arnica cordifolia",
        "LUPINE SILVER LUPINE Lupinus argenteus",
        "PEARLY EVERLASTING Anaphalis margaritacea",
        "GOLDEN BANNER Thermopsis divaricarpa",
        "FRINGED SAGE Artemisia frigida"]

# --------------------------------------------------------------------------
# it reads a PDF at all
# --------------------------------------------------------------------------

one = run(build_pdf(os.path.join(work, "one.pdf"), [PROSE]))[0]
check("a one-page PDF reads", one["ok"], True)
check("its format is named", one["format"], "pdf")
check("its page count is right", one["pages"], 1)
check("the text comes back", "hazard to the people" in one["text"], True)

# ⚠️ A single page has no siblings to be an outlier among, so there is no
# evidence either way and nothing is judged. A one-page flyer in another
# language is exactly the case this protects.
check("one page is never judged", one.get("judged"), False)
check("one page is never called low-prose", one.get("low_prose_pages"), None)

# --------------------------------------------------------------------------
# 🛑 nothing is ever dropped
# --------------------------------------------------------------------------

mixed = run(build_pdf(os.path.join(work, "mixed.pdf"),
                      [PROSE, PROSE, PROSE, LIST]))[0]
check("a list among prose is reported", mixed.get("low_prose_pages"), [4])
check("and the document was judged", mixed.get("judged"), True)
# 🛑 THE CHECK THAT MATTERS. The reported page is still in the text.
check("the reported page is NOT dropped",
      "PINYON PINE" in mixed["text"], True)
check("neither is anything else", "hazard to the people" in mixed["text"], True)
check("chars counts the whole text", mixed["chars"], len(mixed["text"]))

# ⚠️ A document that is ALL list has no healthy level to be measured against,
# so nothing in it is an outlier. This is the same protection the Spanish
# flyer gets, arrived at from the other direction.
all_list = run(build_pdf(os.path.join(work, "list.pdf"),
                         [LIST, LIST, LIST]))[0]
check("a document of nothing but lists reports no page",
      all_list.get("low_prose_pages"), None)
check("and says it could not judge", all_list.get("judged"), False)

# --------------------------------------------------------------------------
# the ways it declines
# --------------------------------------------------------------------------

missing = run(os.path.join(work, "nope.pdf"))[0]
check("a missing file is named as missing", missing["reason"], "missing")
check("and is not ok", missing["ok"], False)

other = os.path.join(work, "notes.md")
open(other, "w").write("# hello")
check("a format it does not read says so", run(other)[0]["reason"], "unsupported")

broken = os.path.join(work, "broken.pdf")
open(broken, "wb").write(b"%PDF-1.4\nthis is not a pdf\n")
check("something unreadable says so", run(broken)[0]["reason"], "unreadable")

# 🛑 A SCAN IS NOT A FAILURE AND NOT A DOCUMENT. 20 of the 159 PDFs on this
# machine are scans, and nothing here does OCR. Indexing one as an empty
# document would put a record in that looks indexed and can never match.
blank = run(build_pdf(os.path.join(work, "blank.pdf"), [[]]))[0]
check("a page with no text layer is named", blank["reason"], "no-text-layer")
check("and its page count still comes back", blank["pages"], 1)

# --------------------------------------------------------------------------
# the shape of a batch
# --------------------------------------------------------------------------
#
# ⚠️ ONE BAD FILE MUST NOT COST THE BATCH. 159 PDFs cost 5.3s in one process,
# which is the whole reason paths are read from stdin; a run that aborted on
# the first scan would be useless.

batch = run(os.path.join(work, "one.pdf"), os.path.join(work, "nope.pdf"),
            os.path.join(work, "mixed.pdf"))
check("every path gets a line", len(batch), 3)
check("in the order given",
      [os.path.basename(r["path"]) for r in batch],
      ["one.pdf", "nope.pdf", "mixed.pdf"])
check("a failure between two good files stops nothing",
      [r["ok"] for r in batch], [True, False, True])

# --no-text is for scoring a corpus, so it carries the numbers and no body.
scored = run(os.path.join(work, "mixed.pdf"), no_text=True)[0]
check("--no-text withholds the text", scored.get("text"), None)
check("and keeps the measurements", scored["chars"] > 0, True)
check("and exposes the per-page scores", len(scored["page_rates"]), 4)

shutil.rmtree(work, ignore_errors=True)

if FAILED:
    print("%d failed\n" % len(FAILED))
    for line in FAILED:
        print("  ✗ " + line)
    sys.exit(1)
print("doctext: all checks passed")
