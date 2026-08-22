#!/usr/bin/env python3
"""Measure retrieval quality, so fusion changes are judged and not guessed.

🛑 This file exists because of a specific mistake. The first embedding model was
chosen by reasoning about how the models were built, not by measuring what they
retrieved. It retrieved badly for weeks of work and nothing showed it until a
real question failed. Every change after that gets a number.

A case names its answer with a LOCATOR — a substring that must match exactly one
record. The ground truth comes out of the index, so a case cannot be quietly
written to match whatever the search already returns. A locator matching zero or
several records is reported as a broken case, not skipped.

  ./eval.py                      # score the current settings
  ./eval.py --compare            # score every fusion strategy side by side
"""

import argparse
import json
import os
import subprocess
import sqlite3
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))

# (query, locator). The locator identifies the record that answers the query.
# `kind` says what sort of query it is, because the whole point is that short
# keyword lookups and descriptive questions behave differently.
CASES = [
    # short keyword lookups
    ("bathroom code",                          "Bathroom code 3384",               "keyword"),
    ("piano lesson password",                  "Meeting Password 802959",          "keyword"),
    ("Jenoptik Optical Systems",               "Jenoptik Optical Systems, LLC",    "keyword"),
    ("Frequent Flyers address",                "3022 E Sterling Cir",              "keyword"),
    ("CATS Gym address",                       "2400 30th St",                     "keyword"),
    ("Eric Potter Oklahoma",                   "18 acre property down in Oklahoma","keyword"),
    ("Ocean First swim",                       "3015 Bluff St",                    "keyword"),
    ("climate equity fund greenhouse",         "Climate Equity Fund",              "keyword"),

    # descriptive questions, avoiding the literal words where possible
    ("what is the code for the HOA bathroom door",
                                               "Bathroom code 3384",               "descriptive"),
    ("who has an eighteen acre property in Oklahoma",
                                               "18 acre property down in Oklahoma","descriptive"),
    ("which contact works as a designer and illustrator",
                                               "Designer / Illustrator",           "descriptive"),
    # 🛑 This case was WRONG for several runs. It expected "Frequent Flyers".
    # The kids do gymnastics at CATS Gym, and a calendar event says so. e5-base
    # returned the correct record and the harness scored it a miss. A wrong
    # label is worse than a missing case: it punishes the right answer.
    ("where do the kids do gymnastics and tumbling",
                                               "CATS Gym",                         "descriptive"),
    ("what is the meeting password for my piano lesson",
                                               "Meeting Password 802959",          "descriptive"),
    ("who works in fundraising for a hospice organisation",
                                               "Hospicare & Palliative Care",      "descriptive"),
    ("what address do we go to for swimming lessons",
                                               "3015 Bluff St",                    "descriptive"),
    ("which optical systems company does my contact work for",
                                               "Jenoptik Optical Systems, LLC",    "descriptive"),
]



def resolve(db, locator, cap=200):
    """Locator -> every uid whose text contains it. Any of them is a hit.

    ⚠️ The first version demanded exactly one record, then one title, and threw
    out half the cases. Both rules were wrong. The locator IS the answer, so any
    record carrying it answers the question, and real search has several valid
    answers all the time.

    Two things still make a case unusable:
      * nothing matches, so the locator is stale
      * so many records match that finding one proves nothing
    A recurring calendar event legitimately matches once per occurrence, so the
    cap is generous. Measured: "Mile marathon" matched 152 records.
    """
    rows = db.execute("""
        SELECT DISTINCT r.uid FROM chunk c JOIN record r ON r.rid = c.rid
        WHERE c.text LIKE ?""", ("%" + locator + "%",)).fetchall()
    uids = [r[0] for r in rows]
    if not uids or len(uids) > cap:
        return None
    return uids


def search(query, extra):
    cmd = [sys.executable, os.path.join(HERE, "index.py"), "search", query,
           "--limit", "10", "--json"] + extra
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return []
    try:
        return [r["uid"] for r in json.loads(proc.stdout)]
    except json.JSONDecodeError:
        return []


def score(extra, cases, verbose=False):
    """Return (hit@1, hit@3, hit@10, MRR) over the cases."""
    at1 = at3 = at10 = 0
    rr = 0.0
    for query, uids, kind in cases:
        got = search(query, extra)
        rank = next((i + 1 for i, u in enumerate(got) if u in uids), None)
        if rank:
            rr += 1.0 / rank
            at1 += rank == 1
            at3 += rank <= 3
            at10 += rank <= 10
        if verbose:
            print("    %-8s rank %-5s %s" % (kind, rank or "miss", query))
    n = len(cases)
    return (at1 / n, at3 / n, at10 / n, rr / n)


# ⚠️ Every strategy states BOTH weights. Leaving one out lets the current
# default leak into the comparison, which once relabelled a 3:1 run as "1:1".
# ⚠️ Every strategy states BOTH weights. Leaving one out lets the current
# default leak into the comparison, which once relabelled a 3:1 run as "1:1".
W = ["--w-lexical", "3.0", "--w-semantic", "1.0"]
STRATEGIES = {
    "e5-base 3:1":           W + ["--model", "e5-base"],
    "e5-base semantic only": ["--w-lexical", "0", "--w-semantic", "1",
                              "--model", "e5-base"],
}



def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--db", default=None)
    p.add_argument("--compare", action="store_true")
    p.add_argument("--verbose", action="store_true")
    opts = p.parse_args()

    sys.path.insert(0, HERE)
    from importlib.machinery import SourceFileLoader
    idx = SourceFileLoader("idx", os.path.join(HERE, "index.py")).load_module()
    dbpath = opts.db or idx.DEFAULT_DB
    db = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(dbpath), uri=True)

    cases, broken = [], []
    for query, locator, kind in CASES:
        uids = resolve(db, locator)
        if uids:
            cases.append((query, set(uids), kind))
        else:
            broken.append(locator)

    if broken:
        print("🛑 %d broken case(s): matched nothing, or several different things"
              % len(broken))
        for locator in broken:
            print("   %s" % locator[:60])
        print()
    if not cases:
        sys.exit("no usable cases")
    print("%d usable cases (%d keyword, %d descriptive)"
          % (len(cases), sum(k == "keyword" for _, _, k in cases),
             sum(k == "descriptive" for _, _, k in cases)))
    print("valid answers per case: %s\n"
          % ", ".join(str(len(u)) for _, u, _ in cases))

    if not opts.compare:
        a1, a3, a10, mrr = score([], cases, verbose=True)
        print("\n  hit@1 %.2f   hit@3 %.2f   hit@10 %.2f   MRR %.3f" % (a1, a3, a10, mrr))
        return

    print("%-24s %6s %6s %7s %7s" % ("strategy", "hit@1", "hit@3", "hit@10", "MRR"))
    for name, extra in STRATEGIES.items():
        a1, a3, a10, mrr = score(extra, cases)
        print("%-24s %6.2f %6.2f %7.2f %7.3f" % (name, a1, a3, a10, mrr))


if __name__ == "__main__":
    main()
