#!/usr/bin/env python3
"""Test that every source's change signal is reliable.

Two phases.

  Phase A (read-only, always runs) — CONVERGENCE.
    Run each source twice. The second run must report +0 ~0 -0.
    This catches the bug class that cost 474 phantom updates per run: a source
    returning one uid twice with different field values, so each run rewrites
    the other's revision and the two never agree. Nothing about that looks
    wrong from the outside.

  Phase B (--writes, opt-in) — DETECTION.
    Create a fixture, ingest, assert it appears. Edit it, ingest, assert the
    new text is found and the old text is gone. Delete it, ingest --full,
    assert it leaves. Runs only for sources with a safe write path.

🛑 Phase B writes to the user's real data. Every fixture is named with the
FIXTURE prefix, and the sweep refuses to touch anything else. Contacts writes
sync to every device and cannot be undone, so that rule is load-bearing.

  ./test-incremental.py                          # phase A, every source
  ./test-incremental.py --source mail,calendar   # phase A, narrowed
  ./test-incremental.py --writes                 # phase A + B
  ./test-incremental.py --sweep                  # delete leftover fixtures only
"""

import argparse
import json
import re
import subprocess
import sys
import time

# 🛑 No Markdown characters in this marker, and no underscores in particular.
# `__text__` is Markdown bold, and the Notes write path converts Markdown, so a
# note created as "__claude_index_test__ x" is STORED as "claude_index_test x".
# `apple notes append` then matches the note by Name, matches nothing, and
# Shortcuts opens a picker and waits for a human — which writes the body to
# whatever they eventually choose. Measured: it happened, and it interrupted
# the user. Keep this marker to letters, digits and hyphens.
FIXTURE = "CLAUDE-INDEX-TEST"
INGEST_LINE = re.compile(r"^(\w+)\s+\+(\d+) ~(\d+) -(\d+)")

PASS, FAIL = [], []


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append(name)
    # Only a failure gets the detail. On a pass the detail reads as an
    # accusation, which is how the first run of this harness looked.
    print("  %s %s%s" % ("PASS" if ok else "FAIL", name,
                         ("  — " + detail) if (detail and not ok) else ""))
    return ok


def ingest(source, *extra):
    """Run one source and return (added, updated, removed, seconds, raw)."""
    started = time.time()
    proc = run([sys.executable, "index.py", "ingest", "--source", source] + list(extra))
    elapsed = time.time() - started
    for line in proc.stdout.splitlines():
        m = INGEST_LINE.match(line)
        if m and m.group(1) == source:
            return (int(m.group(2)), int(m.group(3)), int(m.group(4)), elapsed, proc)
    return (None, None, None, elapsed, proc)


def found(query, needle):
    """Does a search for `query` return a record whose text contains `needle`?"""
    proc = run([sys.executable, "index.py", "search", query, "--limit", "5", "--json"])
    if proc.returncode != 0:
        return False
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return False
    blob = json.dumps(rows).lower()
    return needle.lower() in blob


def embed():
    run([sys.executable, "index.py", "embed"])


# --------------------------------------------------------------------------
# Phase A — convergence
# --------------------------------------------------------------------------

# A per-source budget for a run that finds nothing. One shared threshold let
# contacts pass at 331s beside mail at 0.9s, which hid the whole finding this
# harness exists to report. Each number is the measured cost plus headroom.
BUDGET_SECONDS = {
    "notes": 5,       # measured 0.1s — NoteStore.ZMODIFICATIONDATE1
    "messages": 5,    # measured 0.2s — last_message + message_count
    "mail": 5,        # measured 0.9s — one call returns every header
    "contacts": 10,   # measured 1.5s — AddressBook.ZMODIFICATIONDATE
    "calendar": 10,   # measured 3.1s — one call returns every event
    "maps": 5,        # measured 0.1s — 647 records, two calls read all of them
}

# Sources with no cheap change signal. Empty, and that is the finding: an
# earlier version listed contacts here on a measurement taken with
# `immutable=1`, which does not replay the WAL. See INCREMENTAL.md.
KNOWN_SLOW = set()

SOURCE_ARGS = {
    "mail":     ["--with-bodies"],
    "calendar": ["--since", "3650"],
    "messages": ["--chat-limit", "1331", "--limit", "2000", "--message-block", "10"],
    "notes":    [],
    "contacts": ["--limit", "100000"],
    # ⚠️ maps takes no --since here on purpose. The whole store is 647 records,
    # so a bounded window would leave the convergence test blind to the tail.
    "maps":     [],
}


def phase_a(sources):
    print("\n=== Phase A: convergence (each source run twice) ===")
    for source in sources:
        extra = SOURCE_ARGS[source]
        a_add, a_upd, a_rem, a_sec, proc = ingest(source, *extra)
        if a_add is None:
            check("%s: first run parses" % source, False, proc.stderr.strip()[:200])
            continue
        b_add, b_upd, b_rem, b_sec, _ = ingest(source, *extra)
        print("    run 1: +%d ~%d -%d in %.1fs   run 2: +%d ~%d -%d in %.1fs"
              % (a_add, a_upd, a_rem, a_sec, b_add, b_upd, b_rem, b_sec))
        check("%s: converges" % source,
              (b_add, b_upd, b_rem) == (0, 0, 0),
              "second run reported +%d ~%d -%d; a source is contradicting itself"
              % (b_add, b_upd, b_rem))
        budget = BUDGET_SECONDS[source]
        label = "%s: no-change run within %ds" % (source, budget)
        if source in KNOWN_SLOW:
            label += "  [KNOWN SLOW: no change signal, see INCREMENTAL.md]"
        check(label, b_sec < budget, "took %.1fs against a %ds budget" % (b_sec, budget))


# --------------------------------------------------------------------------
# Phase B — detection
# --------------------------------------------------------------------------

def fixture_calendar():
    title = "%s calendar" % FIXTURE
    old, new = "Zorblatt hovercraft rehearsal", "Marmalade penguin rehearsal"
    proc = run(["apple", "calendar", "add", title,
                "--start", "2027-03-04 15:00", "--duration", "30",
                "--calendar", "Personal", "--notes", old, "--json"])
    if proc.returncode not in (0, 75):
        return None
    try:
        eid = json.loads(proc.stdout)["id"]
    except Exception:
        return None
    return {
        "source": "calendar", "id": eid, "old": old, "new": new,
        "edit": lambda: run(["apple", "calendar", "edit", eid, "--notes", new]),
        "delete": lambda: run(["apple", "calendar", "delete", eid]),
        "expect_removal": True,
    }


def fixture_notes():
    title = "%s notes" % FIXTURE
    old, new = "Zorblatt hovercraft rehearsal", "Marmalade penguin rehearsal"
    proc = run(["apple", "notes", "create", "--title", title, "--body", old, "--json"])
    if proc.returncode != 0:
        return None
    try:
        nid = json.loads(proc.stdout).get("id")
    except Exception:
        nid = None
    if not nid:
        return None
    return {
        "source": "notes", "id": nid, "old": old, "new": new,
        "edit": lambda: run(["apple", "notes", "append", str(nid), "--body", new]),
        "delete": lambda: run(["apple", "notes", "delete", str(nid), "--yes"]),
        # ⚠️ `apple notes delete` moves a note to Recently Deleted, and the
        # reader can still see that folder. So the record is EXPECTED to stay.
        "expect_removal": False,
    }


def fixture_contacts():
    old, new = "Quillfeather Antarctic Beekeeping", "Marmalade Hovercraft Repair Guild"
    proc = run(["apple", "contacts", "add", "--first", FIXTURE, "--last", "Zorblatt",
                "--company", old, "--json"])
    if proc.returncode != 0:
        return None
    try:
        cid = json.loads(proc.stdout)["id"]
    except Exception:
        return None
    return {
        "source": "contacts", "id": cid, "old": old, "new": new,
        "edit": lambda: run(["apple", "contacts", "edit", cid, "--company", new]),
        "delete": lambda: run(["apple", "contacts", "delete", cid]),
        "expect_removal": True,
    }


BUILDERS = {"calendar": fixture_calendar, "notes": fixture_notes,
            "contacts": fixture_contacts}


def phase_b(sources):
    print("\n=== Phase B: detection (writes real data) ===")
    for source in sources:
        if source not in BUILDERS:
            print("  skip %s — no safe write path" % source)
            continue
        extra = SOURCE_ARGS[source]
        print("  %s:" % source)

        fx = BUILDERS[source]()
        if not fx:
            check("%s: fixture created" % source, False, "the write failed")
            continue

        try:
            add, _, _, _, _ = ingest(source, *extra)
            embed()
            check("%s: create detected" % source, add == 1, "+%s" % add)
            check("%s: create is searchable" % source, found(fx["old"], FIXTURE))

            fx["edit"]()
            _, upd, _, _, _ = ingest(source, *extra)
            embed()
            check("%s: edit detected" % source, upd == 1, "~%s" % upd)
            check("%s: new text searchable" % source, found(fx["new"], FIXTURE))
            check("%s: old text gone" % source, not found(fx["old"], fx["old"]))
        finally:
            fx["delete"]()
            time.sleep(2)
            _, _, rem, _, _ = ingest(source, *(extra + ["--full", "--force"]))
            if fx["expect_removal"]:
                check("%s: delete detected" % source, rem == 1, "-%s" % rem)
            else:
                check("%s: delete leaves the record (Recently Deleted)" % source,
                      rem == 0, "-%s; the reader can still see the folder" % rem)


# --------------------------------------------------------------------------

def sweep():
    """Delete leftover fixtures. Refuses anything without the exact prefix."""
    print("\n=== Sweep ===")
    proc = run(["apple", "contacts", "search", FIXTURE])
    try:
        for c in json.loads(proc.stdout):
            if FIXTURE in (c.get("name") or ""):
                print("  contacts: deleting %s" % c["name"])
                run(["apple", "contacts", "delete", c["id"]])
    except Exception:
        pass
    proc = run(["apple", "notes", "search", FIXTURE, "--json"])
    try:
        for n in json.loads(proc.stdout):
            if (n.get("title") or "").startswith(FIXTURE):
                print("  notes: deleting %s" % n["title"])
                run(["apple", "notes", "delete", str(n["id"]), "--yes"])
    except Exception:
        pass
    proc = run(["apple", "calendar", "events", "--from", "2027-01-01",
                "--to", "2027-12-31", "--search", FIXTURE, "--json"])
    try:
        for e in json.loads(proc.stdout):
            if (e.get("title") or "").startswith(FIXTURE):
                print("  calendar: deleting %s" % e["title"])
                run(["apple", "calendar", "delete", e["id"]])
    except Exception:
        pass


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--source", help="comma separated; default all")
    p.add_argument("--writes", action="store_true", help="also run phase B")
    p.add_argument("--sweep", action="store_true", help="delete leftover fixtures and exit")
    opts = p.parse_args()

    if opts.sweep:
        sweep()
        return

    sources = opts.source.split(",") if opts.source else list(SOURCE_ARGS)
    for s in sources:
        if s not in SOURCE_ARGS:
            sys.exit("unknown source '%s'" % s)

    phase_a(sources)
    if opts.writes:
        phase_b(sources)

    print("\n%d passed, %d failed" % (len(PASS), len(FAIL)))
    for f in FAIL:
        print("  FAILED: %s" % f)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
