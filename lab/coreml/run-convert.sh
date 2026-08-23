#!/bin/zsh
# Every model here uses --mask-clamp. 🛑 Without it the fp16 attention mask
# overflows to -inf and the Neural Engine and CPU return quietly wrong vectors.
set -e
rm -rf build && mkdir -p build
for seq in 64 128 256 384 512; do
  uv run convert.py --seq $seq --batch 32 --precision fp16 --mask-clamp -o build
done
uv run convert.py --seq 64 --batch 1 --precision fp16 --mask-clamp -o build
uv run convert.py --enumerated 64,128,256,384,512 --batch 32 --precision fp16 --mask-clamp -o build-enum
uv run convert.py --enumerated 64,128,256,384,512 --batch 1  --precision fp16 --mask-clamp -o build-enum
uv run convert.py --seq 128 --batch 32 --precision int8 --mask-clamp -o build-int8
uv run convert.py --seq 256 --batch 32 --precision int8 --mask-clamp -o build-int8
