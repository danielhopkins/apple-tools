#!/usr/bin/env python3
"""Build an evaluation corpus and case set from EnronQA.

🛑 THE HARNESS COULD NOT MEASURE WHAT A MODEL SWAP WOULD BUY. `eval.py` ships
29 cases written by hand against this machine's real data. That is enough to
catch a broken fusion rule and far too few to separate MRR 0.78 from 0.80 — a
swap decided on 29 cases is decided by noise. It is also unshareable: every
case names something private.

EnronQA fixes both. 103,638 real emails from 150 real inboxes, with 528,304
question/answer pairs, released publicly for exactly this purpose
(arXiv 2505.00263, `MichaelR207/enron_qa_0922`). It is the dataset LEANN —
the one real peer in `docs/prior-art.md` — evaluates against.

    ./bench/enronqa.py fetch --user germany-c          # 1,257 emails
    ./bench/enronqa.py build                           # index them, separately
    ./bench/enronqa.py score --limit 250               # measure

🛑 IT NEVER TOUCHES THE REAL INDEX. `APPLE_INDEX_DB` moves the database AND
`files.json` with it, because the latter is derived from the former's
directory — so a benchmark run cannot add a root to the user's own config or
put a single Enron email in their own index. That is checked, not assumed:
`build` refuses if the target database resolves anywhere near the real one.

⚠️ WHAT THIS MEASURES, AND WHAT IT DOES NOT. Corporate email from 2001, one
mailbox at a time, with questions written by an LLM from the answer. So it
measures the mail arm on English prose. It does NOT measure cross-source
fusion, short keyword lookups, or anything about notes, calendar or places.
Keep the 29 hand-written cases: they are the ones that look like real use.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
DATASET = "MichaelR207/enron_qa_0922"
API = "https://datasets-server.huggingface.co/filter"
PAGE = 100                      # the API's maximum


def die(message):
    sys.exit("enronqa: " + message)


def corpus_dir(out):
    return os.path.join(out, "corpus")


def fetch_rows(user, split, limit=None):
    """Every row for one inbox, paged.

    ⚠️ `strict=False`, because the bodies carry raw control characters — real
    mail from 2001, with form feeds and vertical tabs in it. The default
    parser rejects the whole document over one byte in one email.
    """
    rows, offset = [], 0
    while True:
        query = urllib.parse.urlencode({
            "dataset": DATASET, "config": "default", "split": split,
            "where": '"user"=\'%s\'' % user,
            "offset": offset, "limit": PAGE})
        for attempt in range(6):
            try:
                with urllib.request.urlopen(API + "?" + query, timeout=120) as body:
                    payload = json.loads(body.read().decode("utf-8"), strict=False)
                break
            except Exception as error:              # noqa: BLE001
                # ⚠️ The first request warms an index server-side and answers
                # `{"error": "the dataset index is loading"}` until it is ready.
                if attempt == 5:
                    die("cannot reach the dataset: %s" % error)
                time.sleep(15)
        if "rows" not in payload:
            if attempt == 5:
                die(payload.get("error", "no rows"))
            time.sleep(15)
            continue
        batch = payload["rows"]
        rows.extend(row["row"] for row in batch)
        total = payload.get("num_rows_total", 0)
        sys.stderr.write("\r  %d / %d" % (len(rows), total))
        sys.stderr.flush()
        offset += PAGE
        if offset >= total or not batch or (limit and len(rows) >= limit):
            break
    sys.stderr.write("\n")
    return rows[:limit] if limit else rows


def cmd_fetch(opts):
    rows = fetch_rows(opts.user, opts.split, opts.limit)
    if not rows:
        die("no rows for user %r in split %r" % (opts.user, opts.split))

    where = corpus_dir(opts.out)
    os.makedirs(where, exist_ok=True)
    for stale in os.listdir(where):
        os.remove(os.path.join(where, stale))

    cases, skipped = [], 0
    for number, row in enumerate(rows):
        path = (row.get("path") or "").strip()
        email = row.get("email") or ""
        # 🛑 THE PATH IS THE LOCATOR, and it only works because the dataset
        # writes it into the body as `File: germany-c/sent_items/4.`. That
        # makes it a substring `eval.py` can resolve against the index without
        # this script having to know anything about record ids.
        if not path or path not in email:
            skipped += 1
            continue
        with open(os.path.join(where, "%05d.txt" % number), "w") as handle:
            handle.write(email)
        # ⚠️ ONE QUESTION PER EMAIL. Some carry five, and taking them all
        # weights long emails five times as heavily as short ones for no
        # reason a reader would endorse.
        for question in (row.get("questions") or [])[:opts.questions_per_email]:
            question = question.strip()
            if question:
                cases.append([question, path, "descriptive"])

    manifest = {
        "dataset": DATASET, "user": opts.user, "split": opts.split,
        "emails": len(rows) - skipped, "cases": len(cases),
        "fetched": time.time(),
    }
    with open(os.path.join(opts.out, "cases.json"), "w") as handle:
        json.dump({"manifest": manifest, "cases": cases}, handle, indent=1)
    print("%d emails -> %s" % (manifest["emails"], where))
    print("%d cases   -> %s" % (len(cases), os.path.join(opts.out, "cases.json")))
    if skipped:
        # ⚠️ Reported, never silent. A row whose path is not in its own body
        # cannot be located, and dropping it quietly would shrink the case set
        # for a reason nobody could see.
        print("%d rows skipped: the path is not inside the email text" % skipped)


def bench_db(out):
    return os.path.abspath(os.path.join(out, "enron.db"))


def guard(db):
    """🛑 NEVER THE REAL INDEX. One Enron email in it would be indistinguishable
    from a real one in every search and every people report from then on."""
    real = os.path.expanduser("~/Library/Application Support/apple-tools")
    if os.path.abspath(db).startswith(os.path.abspath(real)):
        die("refusing to build inside %s — that is the real index's directory" % real)


def run(args, env=None, **kw):
    merged = dict(os.environ, **(env or {}))
    result = subprocess.run(args, env=merged, **kw)
    if result.returncode != 0:
        die("%s exited %d" % (" ".join(args[:3]), result.returncode))
    return result


def cmd_build(opts):
    db = bench_db(opts.out)
    guard(db)
    where = corpus_dir(opts.out)
    if not os.path.isdir(where) or not os.listdir(where):
        die("no corpus yet. Run: ./bench/enronqa.py fetch --user <inbox>")
    os.makedirs(opts.out, exist_ok=True)

    # 🛑 ONE VARIABLE MOVES BOTH. `FILES_CONFIG` is derived from the database's
    # directory, so pointing `APPLE_INDEX_DB` at the bench directory also moves
    # the file-roots config there. Without that, `files add` would write a root
    # into the user's own config and their next real refresh would index Enron.
    env = {"APPLE_INDEX_DB": db}
    index = os.path.join(LAB, "index.py")
    run([sys.executable, index, "init"], env=env)
    run([sys.executable, index, "files", "add", where, "--name", "enron"], env=env)
    # 🛑 `--accept-risk` IS CORRECT HERE AND NOWHERE ELSE. The consent gate
    # exists because indexing copies the plaintext of the user's own mail into
    # one unprotected file. This database holds 1,257 public Enron emails and
    # nothing of the user's — it is a benchmark fixture in the repo, not an
    # index of their life. `guard()` above is what keeps that true.
    run([sys.executable, index, "ingest", "--source", "files", "--accept-risk"],
        env=env)
    run([sys.executable, index, "embed", "--model", opts.model], env=env)
    print("built %s" % db)
    print("score it:  ./bench/enronqa.py score --limit 250")


def cmd_score(opts):
    db = bench_db(opts.out)
    if not os.path.exists(db):
        die("no bench index. Run: ./bench/enronqa.py build")
    cases = os.path.join(opts.out, "cases.json")
    if not os.path.exists(cases):
        die("no cases. Run: ./bench/enronqa.py fetch --user <inbox>")
    args = [sys.executable, os.path.join(LAB, "eval.py"),
            "--db", db, "--cases", cases]
    if opts.limit:
        args += ["--limit", str(opts.limit)]
    if opts.model:
        args += ["--model", opts.model]
    if opts.compare:
        args += ["--compare"]
    # ⚠️ The bench index holds only `files` records, so a daemon warmed on the
    # real index would answer from the wrong vectors. `eval.py` passes --db
    # through and index.py declines a mismatched daemon, which is why that
    # guard exists.
    os.execv(sys.executable, args)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", default=os.path.join(HERE, "enron"),
                        help="where the corpus, cases and index live")
    sub = parser.add_subparsers(dest="command", required=True)

    f = sub.add_parser("fetch", help="download one inbox and write the cases")
    f.add_argument("--user", default="germany-c",
                   help="which mailbox (default germany-c, 1,257 emails)")
    f.add_argument("--split", default="test", choices=["train", "dev", "test"])
    f.add_argument("--limit", type=int, default=None, help="stop after N emails")
    f.add_argument("--questions-per-email", type=int, default=1)
    f.set_defaults(func=cmd_fetch)

    b = sub.add_parser("build", help="index the corpus into its own database")
    b.add_argument("--model", default="e5-small-coreml")
    b.set_defaults(func=cmd_build)

    s = sub.add_parser("score", help="run eval.py against the bench index")
    s.add_argument("--limit", type=int, default=250,
                   help="sample this many cases (default 250)")
    s.add_argument("--model", default=None)
    s.add_argument("--compare", action="store_true")
    s.set_defaults(func=cmd_score)

    opts = parser.parse_args()
    opts.func(opts)


if __name__ == "__main__":
    main()
