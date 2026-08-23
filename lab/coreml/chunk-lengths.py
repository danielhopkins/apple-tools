# /// script
# requires-python = "==3.12.*"
# dependencies = ["transformers", "numpy"]
# ///
"""Token length distribution of the real chunks, to choose a sequence length.

A fixed-shape Core ML model pays for every padded token, so this decides how
much of the corpus one shape covers and how much gets truncated.
"""
import argparse, json, os, sqlite3, sys
import numpy as np
from transformers import AutoTokenizer

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/apple-tools/lab-index.db")

p = argparse.ArgumentParser()
p.add_argument("--db", default=DEFAULT_DB)
p.add_argument("--sample", type=int, default=20000)
opts = p.parse_args()

db = sqlite3.connect(opts.db)
rows = db.execute(
    "SELECT text FROM chunk WHERE text IS NOT NULL "
    "ORDER BY cid LIMIT ?", (opts.sample,)).fetchall()
total = db.execute("SELECT COUNT(*) FROM chunk").fetchone()[0]

tokenizer = AutoTokenizer.from_pretrained("intfloat/e5-small-v2")
lengths = np.array([len(tokenizer("passage: " + (r[0] or " "))["input_ids"])
                    for r in rows])

out = {
    "chunks_total": total,
    "sampled": len(lengths),
    "mean": round(float(lengths.mean()), 1),
    "percentiles": {str(q): int(np.percentile(lengths, q))
                    for q in (50, 75, 90, 95, 99, 100)},
    "covered_at": {str(s): round(float((lengths <= s).mean()) * 100, 2)
                   for s in (64, 96, 128, 192, 256, 384, 512)},
    "padding_waste_at": {
        str(s): round(float(np.minimum(lengths, s).sum() / (s * len(lengths))), 3)
        for s in (64, 96, 128, 192, 256, 384, 512)},
}
print(json.dumps(out, indent=2))
