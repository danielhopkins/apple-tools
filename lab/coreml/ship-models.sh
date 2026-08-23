#!/bin/zsh
# Build exactly the model set that ships, into build-ship/.
#
# 🛑 THREE BUCKETS, fp16, batch 32 — measured in BAKEOFF.md:
#   5 fixed buckets  539 MB  968 chunks/sec   byte-identical to PyTorch
#   3 fixed buckets  210 MB  663 chunks/sec   byte-identical to PyTorch
#   3 int8 buckets   106 MB  682 chunks/sec   cosine >= 0.9967, never identical
#   1 enumerated      67 MB  878 chunks/sec   1369 MB RESIDENT
# 64/256/512 covers the corpus with no truncation: 50% of chunks fit in 64 and
# 96% in 256. The batch-1 packages are not shipped; a single query padded into
# a 32-row batch costs about 15 ms, which is the daemon's whole latency.
set -e
cd "${0:a:h}"
rm -rf build-ship && mkdir build-ship
for seq in 64 256 512; do
  uv run convert.py --seq $seq --batch 32 --precision fp16 --mask-clamp -o build-ship
done
# ⚠️ convert.py saves a whole `tokenizer/` directory when the output holds no
# vocab.txt, and only vocab.txt is needed at runtime. Take the file and drop
# the rest, so the shipped models directory carries nothing dead.
[ -f build/vocab.txt ] || uv run convert.py --seq 64 --batch 1 --precision fp16 \
    --mask-clamp -o build >/dev/null
cp build/vocab.txt build-ship/vocab.txt
rm -rf build-ship/tokenizer
du -sh build-ship
