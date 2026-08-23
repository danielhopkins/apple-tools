# /// script
# requires-python = "==3.12.*"
# dependencies = ["torch==2.7.0", "transformers==4.48.3", "coremltools>=8.3", "numpy<2.4", "sentence-transformers==3.4.1"]
# ///
"""Bake off every converted Core ML model against sentence-transformers.

🛑 Two models do not share a vector space, so "close enough" is not a judgement
call. This measures the distance and prints it. The gate is in the doc:
median cosine >= 0.999 against PyTorch, compared AFTER the int8 quantisation
that actually gets stored.

  uv run bakeoff.py --sample 2000 --units ALL,CPU_AND_GPU,CPU_ONLY
"""
import argparse, glob, json, os, re, sqlite3, sys, time

import numpy as np
import coremltools as ct
from transformers import AutoTokenizer
from sentence_transformers import SentenceTransformer

REPO = "intfloat/e5-small-v2"
DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/apple-tools/lab-index.db")
UNITS = {
    "ALL": ct.ComputeUnit.ALL,
    "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
    "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE,
    "CPU_ONLY": ct.ComputeUnit.CPU_ONLY,
}


def quantise(vectors):
    """Exactly what embed_oss.py stores: unit-normalise, scale to int8."""
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return np.clip(np.rint(vectors / norms * 127.0), -127, 127).astype(np.int8)


def load_chunks(db_path, sample, seed):
    db = sqlite3.connect(db_path)
    db.row_factory = sqlite3.Row
    lo, hi = db.execute("SELECT MIN(cid), MAX(cid) FROM chunk").fetchone()
    rng = np.random.default_rng(seed)
    # Sample across the whole cid range: the first N cids are one source, and a
    # sample taken from the head measures that source rather than the corpus.
    wanted = rng.choice(np.arange(lo, hi + 1), size=min(sample * 3, hi - lo + 1),
                        replace=False)
    rows = []
    for start in range(0, len(wanted), 900):
        ids = [int(c) for c in wanted[start:start + 900]]
        marks = ",".join("?" * len(ids))
        rows += db.execute(
            "SELECT cid, text FROM chunk WHERE cid IN (%s) AND text IS NOT NULL"
            % marks, ids).fetchall()
        if len(rows) >= sample:
            break
    rows = rows[:sample]
    return [int(r["cid"]) for r in rows], [r["text"] or " " for r in rows]


def spec_of(path):
    """Return (sequence lengths, batch, precision).

    A fixed model has one length; an enumerated one carries several in a single
    package, and each is timed separately so the two are comparable.
    """
    name = os.path.basename(path)
    m = re.search(r"-s(\d+)-b(\d+)-(fp16|fp32|int8)", name)
    if m:
        return [int(m.group(1))], int(m.group(2)), m.group(3)
    m = re.search(r"-e([\d_]+)-b(\d+)-(fp16|fp32|int8)", name)
    return ([int(x) for x in m.group(1).split("_")], int(m.group(2)),
            m.group(3) + "/enum")


def run_coreml(path, unit, ids_matrix, mask_matrix, batch):
    model = ct.models.MLModel(path, compute_units=UNITS[unit])
    n = len(ids_matrix)
    out = np.zeros((n, 384), dtype=np.float32)

    # One warm batch first: the first prediction pays for compiling and for
    # loading the model onto the Neural Engine, and charging that to the corpus
    # rate would flatter or damn a model for the wrong reason.
    model.predict({"input_ids": ids_matrix[:batch].copy(),
                   "attention_mask": mask_matrix[:batch].copy()})

    started = time.time()
    done = 0
    for start in range(0, n - batch + 1, batch):
        stop = start + batch
        result = model.predict({"input_ids": ids_matrix[start:stop].copy(),
                                "attention_mask": mask_matrix[start:stop].copy()})
        out[start:stop] = result["embedding"]
        done = stop
    elapsed = time.time() - started
    del model
    return out[:done], done, elapsed


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--sample", type=int, default=2000)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--models", default="build/*.mlpackage")
    p.add_argument("--units", default="ALL")
    p.add_argument("-o", "--out", default="bakeoff.json")
    opts = p.parse_args()

    paths = sorted(glob.glob(opts.models))
    if not paths:
        sys.exit("no models matched %s" % opts.models)

    cids, texts = load_chunks(opts.db, opts.sample, opts.seed)
    sys.stderr.write("%d chunks sampled\n" % len(texts))
    passages = ["passage: " + t for t in texts]

    tokenizer = AutoTokenizer.from_pretrained(REPO)
    true_lengths = np.array([len(tokenizer(t)["input_ids"]) for t in passages])

    sys.stderr.write("reference: sentence-transformers ...\n")
    reference_model = SentenceTransformer(REPO)
    # ⚠️ sentence-transformers picks a device itself. On this machine that is
    # MPS, not CPU, so the baseline is already GPU-accelerated. Recording it
    # stops a later reader comparing these numbers against a CPU-only run.
    reference_device = str(reference_model.device)
    started = time.time()
    reference = reference_model.encode(passages, batch_size=64,
                                       convert_to_numpy=True,
                                       show_progress_bar=False)
    reference_seconds = time.time() - started
    reference /= np.linalg.norm(reference, axis=1, keepdims=True)
    reference_int8 = quantise(reference).astype(np.float32) / 127.0
    reference_int8 /= np.linalg.norm(reference_int8, axis=1, keepdims=True)
    del reference_model

    results = []
    plans = [(path, seq) + spec_of(path)[1:]
             for path in paths for seq in spec_of(path)[0]]
    for path, seq, batch, precision in plans:
        encoded = tokenizer(passages, padding="max_length", truncation=True,
                            max_length=seq, return_tensors="np")
        ids_matrix = encoded["input_ids"].astype(np.int32)
        mask_matrix = encoded["attention_mask"].astype(np.int32)
        fits = true_lengths <= seq

        for unit in opts.units.split(","):
            sys.stderr.write("  %s  %s ...\n" % (os.path.basename(path), unit))
            try:
                vectors, done, elapsed = run_coreml(path, unit, ids_matrix,
                                                    mask_matrix, batch)
            except Exception as error:            # noqa: BLE001 - report, don't stop
                results.append({"model": os.path.basename(path), "unit": unit,
                                "error": str(error)[:200]})
                continue

            vectors /= np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-12)
            cosine = (vectors * reference[:done]).sum(axis=1)
            candidate_int8 = quantise(vectors).astype(np.float32) / 127.0
            candidate_int8 /= np.linalg.norm(candidate_int8, axis=1, keepdims=True)
            cosine_int8 = (candidate_int8 * reference_int8[:done]).sum(axis=1)
            whole = fits[:done]

            results.append({
                "model": os.path.basename(path)[:34],
                "shape": "%dx%d" % (batch, seq),
                "unit": unit,
                "seq": seq, "batch": batch, "precision": precision,
                "chunks": int(done),
                "seconds": round(elapsed, 2),
                "per_second": round(done / max(elapsed, 1e-6), 1),
                "speedup_vs_pytorch": round(
                    (done / max(elapsed, 1e-6)) /
                    (len(passages) / max(reference_seconds, 1e-6)), 2),
                "fits_pct": round(float(whole.mean()) * 100, 2),
                "cosine_fp32": {
                    "median": round(float(np.median(cosine[whole])), 6),
                    "min": round(float(cosine[whole].min()), 6),
                    "p01": round(float(np.percentile(cosine[whole], 1)), 6),
                    "below_0999": int((cosine[whole] < 0.999).sum()),
                },
                "cosine_int8_stored": {
                    "median": round(float(np.median(cosine_int8[whole])), 6),
                    "min": round(float(cosine_int8[whole].min()), 6),
                },
                "cosine_truncated_only": (
                    None if whole.all() else
                    round(float(np.median(cosine[~whole])), 6)),
            })
            print(json.dumps(results[-1]))
            sys.stdout.flush()

    summary = {
        "sample": len(passages),
        "reference": {
            "model": REPO,
            "device": reference_device,
            "seconds": round(reference_seconds, 2),
            "per_second": round(len(passages) / max(reference_seconds, 1e-6), 1),
        },
        "token_lengths": {
            "median": int(np.median(true_lengths)),
            "p95": int(np.percentile(true_lengths, 95)),
            "max": int(true_lengths.max()),
        },
        "results": results,
    }
    with open(opts.out, "w") as handle:
        json.dump(summary, handle, indent=2)
    sys.stderr.write("\nwrote %s\n" % opts.out)


if __name__ == "__main__":
    main()
