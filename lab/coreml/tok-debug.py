# /// script
# requires-python = "==3.12.*"
# dependencies = ["transformers==4.48.3"]
# ///
"""Print HuggingFace's token ids for chunks, to diff against `vec tokens`.

🛑 This is the reference, and it is the FAST (Rust) tokenizer, because that is
what `AutoTokenizer` returns and what wrote the stored vectors. The Python
`BertTokenizer` disagrees with it about unassigned code points. Do not "fix" a
difference by switching this to the slow one.

  uv run coreml/tok-debug.py 784277 837377 | diff - <(vec tokens ...)
"""
import json, os, sqlite3, sys
from transformers import AutoTokenizer

DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/apple-tools/lab-index.db")

db = sqlite3.connect(os.environ.get("APPLE_INDEX_DB", DEFAULT_DB))
tokenizer = AutoTokenizer.from_pretrained("intfloat/e5-small-v2")
for cid in (int(x) for x in sys.argv[1:]):
    row = db.execute("SELECT text FROM chunk WHERE cid = ?", (cid,)).fetchone()
    if not row:
        print(json.dumps({"cid": cid, "error": "no such chunk"}))
        continue
    ids = tokenizer("passage: " + (row[0] or " "), truncation=True,
                    max_length=512)["input_ids"]
    print(json.dumps({"cid": cid, "count": len(ids), "ids": ids}))
