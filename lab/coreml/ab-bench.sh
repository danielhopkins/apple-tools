#!/bin/zsh
# Fair A/B: the same chunks, the same moment, one embedder each.
#
# ⚠️ Absolute rates on this machine move by 2-3x with background load
# (`mediaanalysisd` alone took 294% CPU during one run). Run this back to back
# and read the RATIO, never a number from one run against a number from another.
set -e
LAB=${0:a:h:h}
SRC="$HOME/Library/Application Support/apple-tools/lab-index.db"
N=${1:-20000}
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

for side in py swift; do
  sqlite3 "$TMP/$side.db" "
    CREATE TABLE chunk (cid INTEGER PRIMARY KEY, text TEXT);
    CREATE TABLE vector (cid INTEGER, model TEXT, dim INT, v BLOB, PRIMARY KEY(cid, model));
    ATTACH '$SRC' AS src;
    INSERT INTO chunk SELECT cid, text FROM src.chunk ORDER BY cid LIMIT $N;
    DETACH src;"
done

echo "== python (coreml_embed.py) =="
/usr/bin/time -p uv run "$LAB/coreml/coreml_embed.py" embed --db "$TMP/py.db" 2>&1 | tail -3
echo "== swift (vec) =="
/usr/bin/time -p "$LAB/vec/.build/release/vec" embed --db "$TMP/swift.db" \
  --model e5-small-coreml 2>&1 | tail -4
