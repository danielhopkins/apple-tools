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

    # 🛑 VAULT QUESTIONS, added 2026-08-24. Without these the evaluation could
    # measure only what a change COSTS the mail-heavy cases and nothing about
    # what it BUYS a small source — which is how a retrieval quota that fixed a
    # real failure looked purely harmful. Every locator below was checked to
    # resolve to a handful of records, and the first three to `files` alone.
    # 🛑 THIS CASE WAS WRONG WHEN IT WAS WRITTEN, and it nearly steered a
    # retrieval change. Its first locator was "conflict with the National PTA
    # Bylaws", picked out of the COPTA Bylaws note because the words matched.
    # That passage is about bylaws conflicting with EACH OTHER. The bylaws note
    # contains no "conflict of interest", no "business relationship" and no
    # "prohibit" — it does not answer the question at all, so the search was
    # right to leave it out and the harness was scoring the correct behaviour a
    # miss. Same failure as the gymnastics case above.
    #
    # The real answer: COPTA RESCINDED its Conflict of Interest Policy on
    # 2025-07-20 and adopted a Code of Conduct, recorded in the retreat minutes.
    ("do our COPTA bylaws prohibit business relationships",
                                               "RESCIND the Conflict of Interest Policy", "vault"),
    ("how should meeting minutes be written",   "Colorado PTA Meeting Minutes Style Guide", "vault"),
    ("who runs marketing for Colorado PTA",     "Marketing Director Christy Carter", "vault"),
    ("which company did Global Founders back",  "Global Founders Capital",          "vault"),
    ("who is president of COPTA",               "President Burnham",                "vault"),

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

    # 🛑 Recency cases, added after a field test during a real board meeting.
    # Both correct answers are days old and use generic vocabulary, which is
    # the shape that loses to years-old records on wording alone. The first
    # returned a 2020 market commentary at rank 1 with no recency arm.
    ("Michelle July financial statements uploaded",
                                               "uploaded the July financial statements", "recent"),
    ("who filed the health and safety report for the board",
                                               "Report - Health, Wellness & Safety.docx", "recent"),

    # 🛑 Twelve cases contributed by a field session, 2026-08-22, and they are
    # the most valuable ones here for a reason about METHOD. Every one was
    # chosen by starting from a record already verified through the `apple`
    # tools, then writing the query a person would type. NONE was chosen by
    # running a search and keeping what came back.
    #
    # ⚠️ That is the bias that put a WRONG label in the gymnastics case for
    # several runs, where the harness punished the right answer. Ten of these
    # twelve were untested against the index when they were written, so they
    # cannot have been selected for passing.
    #
    # ⚠️ The spread is deliberate. This index is 68% mail by record count, so a
    # mail-heavy set keeps reporting that mail is fine. Eight of the twelve sit
    # outside mail. Four (marked `no-overlap`) share NO content word with their
    # correct record, which is the only shape where the semantic arm has to
    # earn its weight — and none of them was in the sweep that chose 4:1.
    ("where is the October board meeting",      "3475 Holly Street",          "recent"),
    ("which Hope Center is it, Holly or Elizabeth",
                                                "or the one on Elizabeth Street", "descriptive"),
    ("did Michelle upload the July financials",
                                 "I have uploaded the July financial statements", "recent"),
    ("why is the finance chair missing the board meeting",
                                 "I will be at my mom\u2019s memorial service", "no-overlap"),
    # ⚠️ TWO right answers, in different words and different towns.
    ("where do the kids swim",   ("Ocean First", "Goldfish Swim School"), "no-overlap"),
    # ⚠️ "4877 Hopkins Pl" is the user's own address and matches 1,615
    # records. Anchored on the event title, which is unique to it.
    ("where is the piano lesson",   "Weekly Dan/Margot Piano with Elizabeth", "descriptive"),
    ("when is the PTA fundraiser at the ice cream place",
                                                "Sweet Cow, 2628 Broadway",   "no-overlap"),
    ("who is my new doctor",                    "Boulder Medical Center",     "no-overlap"),
    # ⚠️ Anchored on the surrounding phrase, NOT the code itself, so a live
    # door code never lands in a checked-in eval file.
    # 🛑 THIS QUERY HAS SEVERAL CORRECT ANSWERS, and the first anchor named only
    # one of them. It pointed at a 2026 message where the code is incidental to
    # a request about the bins. A field test then scored a genuine rank-1 hit as
    # a miss: the retrieved record was a 2022 message that states the code
    # plainly, which answers the question BETTER than the anchor did. This is
    # the same failure as the gymnastics label. The locator now accepts any of
    # the 7 records that state it.
    ("what is the garage door code",            "garage code is",             "descriptive"),
    # ⚠️ A case was REMOVED here: "did I send anyone my home address", anchored
    # on "My address is 4877 Hopkins Pl". The address appears in dozens of
    # messages, so the query has no single correct answer and MRR against it
    # measures nothing. Withdrawn rather than re-anchored. Write a replacement
    # only if it has one unambiguous answer.
    ("how many people are on the COPTA board",
                                 "Board of 26 people, but now we\u2019re down to 14", "descriptive"),
    ("who do I know at MIT Technology Review",  "MIT Technology Review",      "descriptive"),

    # Replacements for the two cases a field tester and I got wrong, written by
    # the field tester and anchor-checked before being added. Each resolves to
    # EXACTLY ONE record — the check that both withdrawn cases failed.
    #
    # ⚠️ The rejection list matters more than the cases. Anchors turned down for
    # naming too many records: "Wellington Lake" (56), "Frequent Flyers" (49),
    # "Wegmans" (33), "Kathmandu Restaurant" (22), "Epic Mountain Gear" (12),
    # "Rayback Collective" (9). Anything above about 5 is a case waiting to be
    # withdrawn. Count before you write:
    #     apple-index search "<anchor>" --limit 60 --json
    ("where did I take the car for service",
                            "Dan drop the car off at Hoshi Motors",        "descriptive"),
    # 🛑 The first case anchored on `maps`. NO-OVERLAP: the query says "hair
    # cut" and the record says "Barber Shop", category "Beauty Service".
    ("where do I get my hair cut",              "Welcome Stranger Barber Shop", "no-overlap"),

    # 🛑 VOCABULARY SPLIT, added 2026-08-25 after a real question failed. This
    # is a DIFFERENT class from `no-overlap`, and conflating the two sent one
    # session's recommendation the wrong way for a whole turn.
    #
    # `no-overlap` means the answer shares no content word with the query, so
    # only the embedding can reach it. A vocabulary split is the opposite
    # problem: BOTH words are in the corpus, in different documents, written by
    # different people. The exec committee minutes say "air conditioning" and
    # never once say "HVAC". The mail thread says "HVAC" and never says "air
    # conditioning". A search for either word retrieves a plausible-looking
    # result set and silently drops the other half.
    #
    # ⚠️ THAT IS WHY IT IS WORTH ITS OWN KIND. The failure returns confident,
    # on-topic results, so nothing about the output says half the record set is
    # missing. Measured on the real question: `COPTA HVAC` put the committee
    # minutes nowhere in the top 300, while `office air conditioning` put them
    # at rank 1 and 2 of the `files` source.
    #
    # ⚠️ The vector arm does NOT bridge this on its own. `HVAC` and `air
    # conditioning` embed at cosine 0.9257, which looks close until you see
    # `HVAC`/`bicycle` at 0.8003 — e5-small's whole usable range here is 0.17
    # wide. Ranked against all 251,949 vectors, a query of `HVAC` alone puts
    # the minutes outside the top 2000 chunks. The default pool is 60.
    #
    # ⚠️ Two of these four already pass at rank 1. They are kept as regression
    # guards, not as demonstrations: a change that fixes the split must not
    # break the queries whose wording already matched.
    ("what did the committee decide about the office HVAC",
             "The office air conditioning has failed and requires an emergency repair",
                                                              "vocabulary"),
    ("who gave us an air conditioning estimate",
             "forwarding estimates for the repair/replacement of the HVAC units",
                                                              "vocabulary"),
    ("what will the HOA charge us to fix the air conditioner seal on the roof",
             "the seal around the HVAC unit where it attaches to the roof",
                                                              "vocabulary"),
    ("can we repair the office air conditioner instead of replacing it",
             "flushed with sealant in the hopes it would hold", "vocabulary"),
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
    # 🛑 A LOCATOR MAY BE SEVERAL STRINGS, because a question may have several
    # right answers in different words. "where do the kids swim" is answered by
    # BOTH `Ocean First` in Boulder and `Goldfish Swim School` in Superior, and
    # anchoring on one scored a correct rank-1 hit as a miss — which is how the
    # adaptive fusion rule looked useless on the very query it was built for.
    # Third time this file has been wrong that way; see the gymnastics case.
    locators = [locator] if isinstance(locator, str) else list(locator)
    uids = []
    for one in locators:
        rows = db.execute("""
            SELECT DISTINCT r.uid FROM chunk c JOIN record r ON r.rid = c.rid
            WHERE c.text LIKE ?""", ("%" + one + "%",)).fetchall()
        uids.extend(r[0] for r in rows)
    uids = list(dict.fromkeys(uids))
    if not uids or len(uids) > cap:
        return None
    return uids


EXTRA = []          # set from --model / --no-daemon, applied to every search
GLOBAL = []         # 🛑 flags that must precede the SUBCOMMAND, i.e. --db


def search(query, extra):
    # 🛑 `--db` is a GLOBAL option on index.py and has to come BEFORE the
    # subcommand. It used to be appended with the rest, where argparse rejects
    # it as an unrecognised argument -- and `search()` swallows a non-zero exit
    # by returning [], so EVERY case scored a miss and the run printed
    # `MRR 0.000` with no error. A whole comparison against a second index read
    # as "the new index retrieves nothing".
    #
    # ⚠️ That is the same shape as the result_cache bug below: a broken harness
    # that answers confidently. Any run reporting 0.000 across the board is a
    # harness failure, not a search failure. Check the subprocess first.
    cmd = ([sys.executable, os.path.join(HERE, "index.py")] + GLOBAL
           + ["search", query, "--limit", "10", "--json"] + EXTRA + extra)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write("search failed (exit %d): %s\n"
                         % (proc.returncode, (proc.stderr or "").strip()[:300]))
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
# ⚠️ The baseline follows the shipped default, which moved from 4:1 to 2:1.
W = ["--w-recency", "0", "--w-lexical", "2", "--w-semantic", "1"]
# 🛑 EVERY ROW HERE WAS MEASURED, INCLUDING THE ONES THAT LOST. Run
# `./eval.py --compare` to reproduce. Two dead ends are kept in the table on
# purpose, because both looked obviously right beforehand:
#
#   --pool     widening the candidate pool. 60, 120, 200, 300 and 500 give
#              IDENTICAL hit@1, hit@3, hit@10 and MRR. Three failing cases had
#              their correct record at global semantic ranks 16, 4 and 1
#              already. They lose at fusion, not at retrieval depth.
#   --min-chunk  scaling down very short chunks, so a bare calendar title
#              "Hair cut" stops outranking the barber shop that answers "where
#              do I get my hair cut". It DOES fix that case, and it costs more
#              elsewhere than it gains: MRR 0.586 -> 0.530 at 20, 0.540 at 60,
#              0.459 at 100. Shipped at 0.
STRATEGIES = {
    "default":          W + ["--adaptive-threshold", "4"],
    # 🛑 Does a per-tool retrieval quota help or dilute? Mail is 81.3% of the
    # chunks here and took 54 of 60 candidates for one real query, so a small
    # source never reached the ranker. The quota fixes that; the question is
    # what it costs the queries that legitimately belong to mail.
    "per-tool 0":       W + ["--per-tool", "0"],
    "per-tool 5":       W + ["--per-tool", "5"],
    "per-tool 10":      W + ["--per-tool", "10"],
    "per-tool 20":      W + ["--per-tool", "20"],
    "per-tool 40":      W + ["--per-tool", "40"],
    "adaptive off":     W + ["--no-adaptive"],
    "adaptive t=2":     W + ["--adaptive", "--adaptive-threshold", "2"],
    "adaptive t=3":     W + ["--adaptive", "--adaptive-threshold", "3"],
    "adaptive t=4":     W + ["--adaptive", "--adaptive-threshold", "4"],
    "t=3":              W + ["--adaptive-threshold", "3"],
    "t=5":              W + ["--adaptive-threshold", "5"],
    "pool 300":         W + ["--adaptive-threshold", "4", "--pool", "300"],
    "min-chunk 60":     W + ["--adaptive-threshold", "4", "--min-chunk", "60"],
    "8:1":             ["--w-recency", "0", "--w-lexical", "8", "--w-semantic", "1"],
    "6:1":             ["--w-recency", "0", "--w-lexical", "6", "--w-semantic", "1"],
    "5:1":             ["--w-recency", "0", "--w-lexical", "5", "--w-semantic", "1"],
    "3:1":             ["--w-recency", "0", "--w-lexical", "3", "--w-semantic", "1"],
    "2:1":             ["--w-recency", "0", "--w-lexical", "2", "--w-semantic", "1"],
    "2.5:1":           ["--w-recency", "0", "--w-lexical", "2.5", "--w-semantic", "1"],
    "1.75:1":          ["--w-recency", "0", "--w-lexical", "1.75", "--w-semantic", "1"],
    "1.5:1":           ["--w-recency", "0", "--w-lexical", "1.5", "--w-semantic", "1"],
    "1.25:1":          ["--w-recency", "0", "--w-lexical", "1.25", "--w-semantic", "1"],
    "1:1":             ["--w-recency", "0", "--w-lexical", "1", "--w-semantic", "1"],
    "1:2":             ["--w-recency", "0", "--w-lexical", "1", "--w-semantic", "2"],
    "1:3":             ["--w-recency", "0", "--w-lexical", "1", "--w-semantic", "3"],
    "0:1":             ["--w-recency", "0", "--w-lexical", "0", "--w-semantic", "1"],
}



def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--db", default=None)
    # 🛑 THE 29 CASES IN THIS FILE CANNOT SEPARATE 0.78 FROM 0.80. They are
    # hand-written against one machine's private data: enough to catch a broken
    # fusion rule, far too few to decide a model swap, and unshareable. An
    # external file is how a public case set — EnronQA, 1,257 of them — gets
    # scored by the same code. See `bench/enronqa.py`.
    p.add_argument("--cases", default=None, metavar="FILE",
                   help="score cases from a JSON file instead of the built-in "
                        "ones: {\"cases\": [[query, locator, kind], ...]}")
    p.add_argument("--limit", type=int, default=None, metavar="N",
                   help="sample N cases. ⚠️ A search is a subprocess, so 1,257 "
                        "cases across 8 strategies is an hour")
    p.add_argument("--seed", type=int, default=7,
                   help="the sample is deterministic, so two runs compare")
    p.add_argument("--compare", action="store_true")
    # ⚠️ `--db` used to steer only the CASE RESOLUTION. The search subprocess
    # never saw it, so evaluating a second index scored the default one and the
    # two runs looked identical for the wrong reason.
    p.add_argument("--model", default=None, help="embedding model to score")
    p.add_argument("--no-daemon", action="store_true",
                   help="never ask the warm daemon; it holds one model only")
    p.add_argument("--verbose", action="store_true")
    opts = p.parse_args()

    sys.path.insert(0, HERE)
    from importlib.machinery import SourceFileLoader
    idx = SourceFileLoader("idx", os.path.join(HERE, "index.py")).load_module()
    dbpath = opts.db or idx.DEFAULT_DB
    global EXTRA, GLOBAL
    GLOBAL = (["--db", dbpath] if opts.db else [])
    EXTRA = (["--model", opts.model] if opts.model else [])
    EXTRA += (["--no-daemon"] if opts.no_daemon else [])
    db = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(dbpath), uri=True)

    wanted = CASES
    if opts.cases:
        with open(opts.cases) as handle:
            loaded = json.load(handle)
        manifest = loaded.get("manifest", {}) if isinstance(loaded, dict) else {}
        wanted = [tuple(case) for case in
                  (loaded["cases"] if isinstance(loaded, dict) else loaded)]
        if manifest:
            print("cases from %s: %s inbox %s, %d emails"
                  % (os.path.basename(opts.cases), manifest.get("dataset", "?"),
                     manifest.get("user", "?"), manifest.get("emails", 0)))

    # ⚠️ SAMPLED BEFORE RESOLVING, not after. Resolving every one of 1,257
    # locators against the index costs a query each, and the run then throws
    # most of them away.
    if opts.limit and len(wanted) > opts.limit:
        import random
        random.Random(opts.seed).shuffle(wanted)
        wanted = wanted[:opts.limit]
        print("sampled %d cases (seed %d)" % (len(wanted), opts.seed))

    cases, broken = [], []
    for query, locator, kind in wanted:
        uids = resolve(db, locator)
        if uids:
            cases.append((query, set(uids), kind))
        else:
            broken.append(locator)

    if broken:
        print("🛑 %d broken case(s): matched nothing, or several different things"
              % len(broken))
        for locator in broken[:12]:
            print("   %s" % (locator if isinstance(locator, str) else " / ".join(locator))[:60])
        if len(broken) > 12:
            print("   ... and %d more" % (len(broken) - 12))
        print()
    if not cases:
        sys.exit("no usable cases")
    print("%d usable cases (%d keyword, %d descriptive)"
          % (len(cases), sum(k == "keyword" for _, _, k in cases),
             sum(k == "descriptive" for _, _, k in cases)))
    # ⚠️ Useful for 29 hand-written cases, where a locator matching six records
    # is worth seeing. For 1,254 it is a screen of the digit 1.
    spread = sorted({len(u) for _, u, _ in cases})
    if len(cases) <= 40:
        print("valid answers per case: %s\n"
              % ", ".join(str(len(u)) for _, u, _ in cases))
    else:
        print("valid answers per case: %d..%d\n" % (spread[0], spread[-1]))

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
