# /// script
# requires-python = "==3.12.*"
# dependencies = ["transformers==4.48.3", "coremltools>=8.3", "numpy<2.4"]
# ///
"""Embed the index with Core ML, mirroring embed_oss.py's interface.

🛑 NO PYTORCH. That is the whole point: this is the path an app can ship. It
needs `transformers` only for the WordPiece tokenizer, which the Swift port
replaces later.

🛑 The vectors go in under their OWN model name, `e5-small-coreml-v1`. Two
models never share a vector space, and scoring across both returns confident
nonsense, so this is a migration and not a setting.

A fixed-shape Core ML model pays for every padded token, so chunks are sorted
into length buckets and each bucket runs on its own model.

  uv run coreml_embed.py embed  --db PATH [--precision fp16] [--units ALL]
  uv run coreml_embed.py search --db PATH --query TEXT [--limit 50] [--tool NAME]
"""
import argparse, glob, json, os, re, sqlite3, sys, time

import numpy as np
import coremltools as ct
from transformers import AutoTokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "intfloat/e5-small-v2"
MODEL_NAME = "e5-small-coreml-v1"
DIM = 384
QUERY_PREFIX = "query: "
PASSAGE_PREFIX = "passage: "
UNITS = {"ALL": ct.ComputeUnit.ALL, "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
         "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE, "CPU_ONLY": ct.ComputeUnit.CPU_ONLY}


def connect(path, read_only=False):
    # 🛑 Never `immutable=1`: these stores are WAL and it does not replay the log.
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout = 10000")
    if not read_only:
        db.execute("PRAGMA journal_mode = WAL")
    return db


def quantise(vectors):
    """Exactly what embed_oss.py stores: unit-normalise, scale to int8."""
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return np.clip(np.rint(vectors / norms * 127.0), -127, 127).astype(np.int8)


class Buckets:
    """One Core ML model per sequence length, chosen per chunk."""

    def __init__(self, directory, precision, unit, batch):
        self.unit = UNITS[unit]
        self.batch = batch
        self.paths = {}
        pattern = os.path.join(directory, "e5-small-v2-s*-b%d-%s.mlpackage"
                               % (batch, precision))
        for path in sorted(glob.glob(pattern)):
            seq = int(re.search(r"-s(\d+)-", os.path.basename(path)).group(1))
            self.paths[seq] = path
        if not self.paths:
            sys.exit("no models matched %s" % pattern)
        self.sizes = sorted(self.paths)
        self.loaded = {}

    def model(self, seq):
        if seq not in self.loaded:
            self.loaded[seq] = ct.models.MLModel(self.paths[seq],
                                                 compute_units=self.unit)
        return self.loaded[seq]

    def bucket_for(self, length):
        for size in self.sizes:
            if length <= size:
                return size
        return self.sizes[-1]          # longer than every bucket: truncate

    def encode(self, tokenizer, texts):
        """Return one L2-normalised float32 vector per text, in order."""
        lengths = [len(ids) for ids in
                   tokenizer(texts, truncation=True,
                             max_length=self.sizes[-1])["input_ids"]]
        out = np.zeros((len(texts), DIM), dtype=np.float32)
        by_bucket = {}
        for position, length in enumerate(lengths):
            by_bucket.setdefault(self.bucket_for(length), []).append(position)

        for seq, positions in sorted(by_bucket.items()):
            model = self.model(seq)
            encoded = tokenizer([texts[p] for p in positions],
                                padding="max_length", truncation=True,
                                max_length=seq, return_tensors="np")
            ids = encoded["input_ids"].astype(np.int32)
            mask = encoded["attention_mask"].astype(np.int32)
            for start in range(0, len(positions), self.batch):
                stop = min(start + self.batch, len(positions))
                real = stop - start
                # The shape is fixed, so a short final group is padded with
                # repeats of its own last row and the extras are discarded.
                ids_batch = np.zeros((self.batch, seq), dtype=np.int32)
                mask_batch = np.zeros((self.batch, seq), dtype=np.int32)
                ids_batch[:real] = ids[start:stop]
                mask_batch[:real] = mask[start:stop]
                if real < self.batch:
                    ids_batch[real:] = ids[stop - 1]
                    mask_batch[real:] = mask[stop - 1]
                result = model.predict({"input_ids": ids_batch,
                                        "attention_mask": mask_batch})
                vectors = np.asarray(result["embedding"], dtype=np.float32)[:real]
                for offset in range(real):
                    out[positions[start + offset]] = vectors[offset]
        norms = np.linalg.norm(out, axis=1, keepdims=True)
        norms[norms == 0] = 1.0
        return out / norms


def cmd_embed(opts):
    db = connect(opts.db)
    # ⚠️ `--model-name` exists so this path can write a REFERENCE set under a
    # different name. `vec verify` compares the Swift port against it. Without
    # a separate name the check compares the Swift port to itself and passes
    # for the wrong reason.
    global MODEL_NAME
    MODEL_NAME = opts.model_name
    pending = db.execute("""
        SELECT COUNT(*) FROM chunk c
        LEFT JOIN vector v ON v.cid = c.cid AND v.model = ?
        WHERE v.cid IS NULL""", (MODEL_NAME,)).fetchone()[0]
    if opts.limit:
        pending = min(pending, opts.limit)
    if not pending:
        print(json.dumps({"embedded": 0, "pending": 0}))
        return

    tokenizer = AutoTokenizer.from_pretrained(REPO)
    buckets = Buckets(opts.models_dir, opts.precision, opts.units, opts.batch)
    sys.stderr.write("%d chunks to embed as %s (buckets %s, %s, %s)\n"
                     % (pending, MODEL_NAME, buckets.sizes, opts.precision,
                        opts.units))

    started, done = time.time(), 0
    while done < pending:
        rows = db.execute("""
            SELECT c.cid, c.text FROM chunk c
            LEFT JOIN vector v ON v.cid = c.cid AND v.model = ?
            WHERE v.cid IS NULL
            ORDER BY c.cid LIMIT ?""",
            (MODEL_NAME, min(opts.window, pending - done))).fetchall()
        if not rows:
            break
        texts = [PASSAGE_PREFIX + (r["text"] or " ") for r in rows]
        packed = quantise(buckets.encode(tokenizer, texts))
        db.executemany(
            "INSERT OR REPLACE INTO vector (cid, model, dim, v) VALUES (?,?,?,?)",
            [(rows[i]["cid"], MODEL_NAME, DIM, packed[i].tobytes())
             for i in range(len(rows))])
        db.commit()
        done += len(rows)
        rate = done / max(time.time() - started, 1e-6)
        sys.stderr.write("  %d/%d  %.0f chunks/sec\n" % (done, pending, rate))
        sys.stderr.flush()

    elapsed = time.time() - started
    print(json.dumps({"embedded": done, "model": MODEL_NAME,
                      "seconds": round(elapsed, 1),
                      "per_second": round(done / max(elapsed, 1e-6), 1)}))


def cmd_search(opts):
    global MODEL_NAME
    MODEL_NAME = opts.model_name
    db = connect(opts.db, read_only=True)
    if opts.tool:
        rows = db.execute("""
            SELECT v.cid, v.v FROM vector v
            JOIN chunk c ON c.cid = v.cid
            JOIN record r ON r.rid = c.rid
            WHERE v.model = ? AND v.dim = ? AND r.tool = ?""",
            (MODEL_NAME, DIM, opts.tool)).fetchall()
    else:
        rows = db.execute("SELECT cid, v FROM vector WHERE model = ? AND dim = ?",
                          (MODEL_NAME, DIM)).fetchall()
    if not rows:
        print("[]")
        return
    started = time.time()
    cids = np.fromiter((r["cid"] for r in rows), dtype=np.int64, count=len(rows))
    matrix = np.frombuffer(b"".join(r["v"] for r in rows),
                           dtype=np.int8).reshape(len(rows), DIM)

    tokenizer = AutoTokenizer.from_pretrained(REPO)
    buckets = Buckets(opts.models_dir, opts.precision, opts.units, 1)
    query = buckets.encode(tokenizer, [QUERY_PREFIX + opts.query])[0]

    scores = matrix.astype(np.float32) @ query.astype(np.float32) / 127.0
    top = np.argpartition(-scores, min(opts.limit, len(scores) - 1))[:opts.limit]
    top = top[np.argsort(-scores[top])]
    sys.stderr.write("coreml: scanned %d vectors in %.3fs\n"
                     % (len(rows), time.time() - started))
    print(json.dumps([{"cid": int(cids[i]), "score": round(float(scores[i]), 6)}
                      for i in top if scores[i] > 0]))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    for name in ("embed", "search"):
        q = sub.add_parser(name)
        q.add_argument("--db", required=True)
        q.add_argument("--models-dir", default=os.path.join(HERE, "build"))
        q.add_argument("--precision", default="fp16",
                       choices=["fp16", "fp32", "int8"])
        # 🛑 CPU_AND_GPU, not ALL. Measured in BAKEOFF.md: the Neural Engine is
        # slower at every shape, and it is 300x slower on an enumerated-shape
        # model. It is not the safe default it looks like.
        q.add_argument("--units", default="CPU_AND_GPU", choices=sorted(UNITS))
        if name == "embed":
            q.add_argument("--batch", type=int, default=32)
            q.add_argument("--model-name", default=MODEL_NAME,
                           help="the name to store vectors under")
            q.add_argument("--limit", type=int, default=0,
                           help="stop after N chunks (0 = everything)")
            q.add_argument("--window", type=int, default=4096,
                           help="rows read from sqlite per commit")
            q.set_defaults(func=cmd_embed)
        else:
            q.add_argument("--query", required=True)
            q.add_argument("--limit", type=int, default=50)
            q.add_argument("--model-name", default=MODEL_NAME)
            q.add_argument("--tool", help="restrict the scan to one source")
            q.set_defaults(func=cmd_search)
    opts = p.parse_args()
    opts.func(opts)


if __name__ == "__main__":
    main()
