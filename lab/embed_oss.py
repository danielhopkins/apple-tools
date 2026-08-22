# /// script
# dependencies = ["sentence-transformers"]
# ///
"""Embed and search with an open model, mirroring `vec`'s interface.

`vec` (Swift) owns Apple's two models. This owns the open ones, because they
need PyTorch. Both write the same `vector` table and both record `model`, so an
index can hold several and a search never mixes them.

🛑 PREFIXES ARE LOAD-BEARING. E5 is trained asymmetrically: a query gets
"query: " and a passage gets "passage: ". Omitting them makes a strong model
score like a weak one, which is the same class of error that put Apple's
feature-layer embedding into this index in the first place.

  uv run embed_oss.py embed  --db PATH [--model e5-base] [--batch 256]
  uv run embed_oss.py search --db PATH --query TEXT [--limit 50]
"""
import argparse, json, sqlite3, sys, time
import numpy as np
from sentence_transformers import SentenceTransformer

MODELS = {
    # name -> (repo, query prefix, passage prefix, dimensions)
    "e5-base":   ("intfloat/e5-base-v2",  "query: ", "passage: ", 768),
    "e5-small":  ("intfloat/e5-small-v2", "query: ", "passage: ", 384),
    "minilm":    ("sentence-transformers/all-MiniLM-L6-v2", "", "", 384),
}


def connect(path, read_only=False):
    # 🛑 Never `immutable=1`: these stores are WAL and it does not replay the log.
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout = 10000")
    if not read_only:
        db.execute("PRAGMA journal_mode = WAL")
    return db


def quantise(vectors):
    """Unit-normalise, scale to int8. One row is `dim` bytes."""
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    scaled = np.clip(np.rint(vectors / norms * 127.0), -127, 127)
    return scaled.astype(np.int8)


def cmd_embed(opts):
    repo, _, passage_prefix, dim = MODELS[opts.model]
    name = "%s-v1" % opts.model
    db = connect(opts.db)
    pending = db.execute("""
        SELECT COUNT(*) FROM chunk c
        LEFT JOIN vector v ON v.cid = c.cid AND v.model = ?
        WHERE v.cid IS NULL""", (name,)).fetchone()[0]
    if not pending:
        print(json.dumps({"embedded": 0, "pending": 0}))
        return

    sys.stderr.write("loading %s ...\n" % repo)
    model = SentenceTransformer(repo)
    sys.stderr.write("%d chunks to embed as %s (dim %d)\n" % (pending, name, dim))

    started, done = time.time(), 0
    while True:
        rows = db.execute("""
            SELECT c.cid, c.text FROM chunk c
            LEFT JOIN vector v ON v.cid = c.cid AND v.model = ?
            WHERE v.cid IS NULL
            ORDER BY c.cid LIMIT ?""", (name, opts.batch)).fetchall()
        if not rows:
            break
        texts = [passage_prefix + (r["text"] or " ") for r in rows]
        vectors = model.encode(texts, batch_size=64, show_progress_bar=False,
                               convert_to_numpy=True)
        packed = quantise(vectors)
        db.executemany("INSERT OR REPLACE INTO vector (cid, model, dim, v) VALUES (?,?,?,?)",
                       [(rows[i]["cid"], name, dim, packed[i].tobytes())
                        for i in range(len(rows))])
        db.commit()
        done += len(rows)
        rate = done / max(time.time() - started, 0.001)
        sys.stderr.write("  %d/%d  %.0f chunks/sec\n" % (done, pending, rate))
        sys.stderr.flush()

    elapsed = time.time() - started
    print(json.dumps({"embedded": done, "model": name, "seconds": round(elapsed, 1),
                      "per_second": round(done / max(elapsed, 0.001), 1)}))


def cmd_search(opts):
    repo, query_prefix, _, dim = MODELS[opts.model]
    name = "%s-v1" % opts.model
    db = connect(opts.db, read_only=True)
    rows = db.execute("SELECT cid, v FROM vector WHERE model = ? AND dim = ?",
                      (name, dim)).fetchall()
    if not rows:
        print("[]")
        return
    started = time.time()
    cids = np.fromiter((r["cid"] for r in rows), dtype=np.int64, count=len(rows))
    matrix = np.frombuffer(b"".join(r["v"] for r in rows), dtype=np.int8).reshape(len(rows), dim)

    model = SentenceTransformer(repo)
    q = model.encode(query_prefix + opts.query, convert_to_numpy=True)
    q = q / (np.linalg.norm(q) or 1.0)

    scores = matrix.astype(np.float32) @ q.astype(np.float32) / 127.0
    top = np.argpartition(-scores, min(opts.limit, len(scores) - 1))[:opts.limit]
    top = top[np.argsort(-scores[top])]
    sys.stderr.write("oss: scanned %d vectors in %.3fs\n"
                     % (len(rows), time.time() - started))
    print(json.dumps([{"cid": int(cids[i]), "score": round(float(scores[i]), 6)}
                      for i in top if scores[i] > 0]))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    for name in ("embed", "search"):
        q = sub.add_parser(name)
        q.add_argument("--db", required=True)
        q.add_argument("--model", default="e5-base", choices=sorted(MODELS))
        if name == "embed":
            q.add_argument("--batch", type=int, default=2000)
            q.set_defaults(func=cmd_embed)
        else:
            q.add_argument("--query", required=True)
            q.add_argument("--limit", type=int, default=50)
            q.set_defaults(func=cmd_search)
    opts = p.parse_args()
    opts.func(opts)


if __name__ == "__main__":
    main()
