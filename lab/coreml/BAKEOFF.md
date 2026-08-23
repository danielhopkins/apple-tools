# Core ML e5-small-v2: the conversion, and what it cost

**Measured 2026-08-22, macOS 27.0 (26A5416b), M-series, 14 cores.** Reproduce
with `./run-convert.sh` then `uv run bakeoff.py`.

## The answer

**The conversion works and it is faster than PyTorch.** The whole corpus —
237,971 chunks — re-embedded in **270.9 seconds at 878 chunks/sec**, against
272.6 chunks/sec for `sentence-transformers` on MPS. Parity against PyTorch is
**0.999999 median cosine**, well inside the 0.999 gate that
`docs/todo-index-app.md` set.

So an app can ship this. No PyTorch, no `uv`, no 661 MB resident model.

⚠️ **Two things are NOT done yet**: the tokenizer still comes from
`transformers`, and nothing runs the model from Swift. Both are ports of a known
quantity, not open questions.

## 🛑 The bug that only one backend showed

The first conversion looked fine. It scored **0.999999** on the GPU and shipped
quietly wrong vectors everywhere else:

| Backend | first build | after the fix |
|---|---|---|
| Neural Engine (`ALL`) | **0.911821** | 0.999974 |
| GPU (`CPU_AND_GPU`) | 0.999999 | 0.999999 |
| CPU (`CPU_ONLY`) | **0.972870** | 0.999969 |

**The cause is the additive attention mask.** `transformers` fills masked
positions with `torch.finfo(float32).min`, which is `-3.4e38`. That overflows to
`-inf` in fp16. coremltools even warns about it during conversion:

```
elementwise_unary.py:889: RuntimeWarning: overflow encountered in cast
```

The GPU absorbs it. The Neural Engine and the CPU do not.

**The fix needs TWO changes, and either one alone does nothing:**

1. Override `get_extended_attention_mask` to use `-1e4`.
2. 🛑 **Force `attn_implementation="eager"`.** With the default `sdpa` path
   `BertModel` never calls `get_extended_attention_mask`, so the override is
   dead code and the numbers do not move. That cost one wasted build.

⚠️ **The failure was invisible from a single backend.** A bake-off run on the
GPU alone — the fastest and the obvious default — would have reported perfect
parity for a model that was wrong on the other two. Measure every backend.

⚠️ **It was also invisible at batch 1.** The first build scored 0.999973 on the
Neural Engine at batch 1 and 0.911821 at batch 32. A parity check on single
inputs passes a model that fails on the batches it will actually run.

## Speed and parity, by shape

1,500 chunks sampled across the whole `cid` range, `passage: ` prefix, fp16
weights, clamped mask. `xtorch` is against `sentence-transformers` on `mps:0` at
272.6 chunks/sec.

| shape | precision | backend | chunks/s | xtorch | median cosine | min cosine |
|---|---|---|---|---|---|---|
| 32×64 | fp16 | **GPU** | **1953.6** | 7.17 | 0.999999 | 0.999997 |
| 32×64 | fp16 | ANE | 1570.6 | 5.76 | 0.999974 | 0.999946 |
| 32×64 | fp16 | CPU | 1436.2 | 5.27 | 0.999971 | 0.999919 |
| 32×128 | fp16 | **GPU** | **1041.0** | 3.82 | 0.999999 | 0.999997 |
| 32×128 | fp16 | ANE | 736.6 | 2.70 | 0.999974 | 0.999943 |
| 32×128 | fp16 | CPU | 674.0 | 2.47 | 0.999969 | 0.999919 |
| 32×256 | fp16 | **GPU** | **517.7** | 1.90 | 0.999999 | 0.999996 |
| 32×256 | fp16 | ANE | 288.6 | 1.06 | 0.999974 | 0.999945 |
| 32×384 | fp16 | **GPU** | **334.4** | 1.23 | 0.999999 | 0.999996 |
| 32×512 | fp16 | **GPU** | **241.5** | 0.89 | 0.999999 | 0.999996 |
| 32×128 | int8 | GPU | 1018.9 | 3.74 | 0.999742 | 0.999277 |
| 32×256 | int8 | GPU | 500.1 | 1.83 | 0.999740 | 0.999277 |

🛑 **The GPU wins at every shape, so `ComputeUnit.ALL` is the wrong default.**
It is the name that sounds safest and it is slower than naming the GPU at every
sequence length measured. It is also less exact.

⚠️ **A long sequence is where PyTorch catches up.** At 32×512 the Core ML model
is *slower* than MPS (0.89×). The corpus is short — median 73 tokens — so this
does not decide anything here, and it would on a corpus of long documents.

## 🛑 One model with five shapes dies on the Neural Engine

Five fixed-shape packages hold five copies of the same 33M weights: **539 MB**.
One `EnumeratedShapes` package holding the same five lengths is **66.6 MB**. An
app wants the second.

It works on the GPU and it collapses on the Neural Engine:

| shape | enumerated, ANE | fixed, ANE | enumerated, GPU | fixed, GPU |
|---|---|---|---|---|
| 32×64 | **85.9** | 1570.6 | 1930.2 | 1953.6 |
| 32×128 | **38.4** | 736.6 | 1010.1 | 1041.0 |
| 32×256 | **14.6** | 288.6 | 514.6 | 517.7 |
| 32×384 | **5.8** | 198.7 | 334.9 | 334.4 |
| 32×512 | **3.2** | 191.9 | 242.1 | 241.5 |

**60× slower at 32×512, and 18× at 32×64.** The Neural Engine appears to
recompile per shape rather than hold five plans. On the GPU the enumerated model
is indistinguishable from the fixed one, at 1/8th the size.

**So the app ships ONE enumerated model and runs it on the GPU.** Parity is
identical either way (0.999999).

## int8 buys size, not speed

| | fp16 | int8 |
|---|---|---|
| package, 32×128 | 69.4 MB | **35.0 MB** |
| chunks/s on GPU | 1041.0 | 1018.9 |
| median cosine | 0.999999 | **0.999742** |

Weight quantisation halves the file and changes nothing about the speed, because
the compute stays fp16. It costs a little parity. It still passes the gate.

⚠️ **Reach for it only if the bundle size matters.** An enumerated int8 package
would be about 33 MB against 67 MB, and both are small next to a 661 MB PyTorch
environment.

## The full corpus

```
$ ./index.py embed --model e5-small-coreml
237971/237971  879 chunks/sec
{"embedded": 237971, "model": "e5-small-coreml-v1", "seconds": 270.9,
 "per_second": 878.3}
```

Bucketed: each chunk goes to the smallest of 64/128/256/384/512 that holds it,
on the GPU. The measured 878/sec sits close to the 913/sec projected from the
per-shape rates and the length histogram, so the bucketing costs little.

**Length distribution over 20,000 chunks** (`chunk-lengths.py`), which is what
makes bucketing worth doing:

| ≤ tokens | share of corpus |
|---|---|
| 64 | 50.1% |
| 128 | 68.1% |
| 256 | 95.7% |
| 384 | 99.9% |

Half the corpus fits in 64 tokens, where the model runs at 1954/sec. A single
fixed 512-shape would have paid 241/sec for every one of them.

## Retrieval quality did not move

The parity number says the vectors are the same. `eval.py` says the search that
uses them behaves the same. Both models scored over the same 27 usable cases,
with `--no-daemon` so neither ran against a warm daemon holding the other model.

| | hit@1 | hit@3 | hit@10 | MRR |
|---|---|---|---|---|
| `e5-small-v1` (PyTorch) | 0.52 | 0.62 | 0.72 | 0.586 |
| `e5-small-coreml-v1` | 0.55 | 0.62 | 0.72 | **0.604** |

⚠️ **Read that as "no change", not as "better".** Exactly two cases moved, each
by one rank:

```
where do the kids swim     rank 2  ->  rank 1
who is my new doctor       rank 6  ->  rank 5
```

One case moving from rank 2 to rank 1 is worth 0.017 MRR over 27 cases. That is
the whole difference. A conversion measured at 0.999999 cosine cannot improve
retrieval, and claiming it did would be reading noise as a result.

⚠️ **2 of the 29 cases are broken in both runs** — the `Meeting Password 802959`
locator is listed twice and matches nothing now. That is a stale case, not a
model problem, and it hits both runs identically.

## 🛑 The vectors go in under a new name

`e5-small-coreml-v1`, alongside `e5-small-v1`, never replacing it. Two models do
not share a vector space, and the `vector` table records which model wrote each
row, so both can sit in one index and no search mixes them.

Undo the whole experiment with one statement:

```sql
DELETE FROM vector WHERE model = 'e5-small-coreml-v1';
```

## Reproduce

```
cd lab/coreml
./run-convert.sh                 # every model, all with --mask-clamp
uv run chunk-lengths.py          # the length histogram
uv run bakeoff.py --sample 1500 --units ALL,CPU_AND_GPU,CPU_ONLY \
                  --models 'build*/*-b32-*.mlpackage' -o bakeoff-final.json
cd .. && ./index.py embed --model e5-small-coreml
./eval.py --model e5-small-coreml --no-daemon
```

⚠️ **`build/` and its siblings are not committed.** 736 MB of converted weights
rebuild in about a minute.

## The Swift port — no Python at runtime

**Done, 2026-08-22.** `vec` now embeds and searches with Core ML and its own
WordPiece tokenizer. `index.py --model e5-small-coreml` calls the binary, not
`uv run`. No PyTorch, no virtualenv, nothing to install.

| | |
|---|---|
| tokenizer | `vec/Sources/vec/WordPiece.swift` |
| runner | `vec/Sources/vec/CoreMLEmbedder.swift` |
| gate | `vec verify --db DB` |

**Parity: 19,999 of 20,000 chunks byte-identical** to rows written by the Python
path. The one that differs is a single unit in one component, at cosine
0.999970. An earlier 60,000-chunk run scored 99.99% with every token id
matching.

🛑 **`verify` must compare against a set the PYTHON path wrote, under its own
name.** Comparing against `e5-small-coreml-v1` after `vec embed` has written it
compares the port to itself, reports 100%, and proves nothing. That happened
here. Write the reference first:

```
uv run coreml/coreml_embed.py embed --db DB \
    --model-name e5-small-coreml-py-v1 --limit 20000
vec verify --db DB                       # defaults to that name
```

### 🛑 Three tokenizer bugs the gate caught. Every one was silent.

1. **`String.split(separator: " ")` splits on grapheme CLUSTERS.** A combining
   mark binds to the space in front of it, so a run of `SPACE U+034F` holds no
   `Character` equal to `" "` and the split never fires. One real mail
   preheader produced **82 spurious `[UNK]` tokens**; Python produced none.
   Python splits on scalars, so the port works on `Unicode.Scalar` throughout.
2. **`AutoTokenizer` returns the RUST tokenizer, not the Python one.** They
   disagree about unassigned code points: Python's `_is_control` tests
   `category.startswith("C")` and drops them, and Rust keeps them. A chunk
   holding `U+FFFF` (category Cn) proved it — the fast tokenizer emitted
   `[UNK]`, the port emitted nothing. **The stored vectors came from the fast
   tokenizer, so the fast tokenizer is the specification.**
3. **Private use (Co) must be dropped.** Word and Outlook emit `U+F0B7` and
   `U+F04A` for Symbol-font bullets. Keeping them added one `[UNK]` per bullet.

So the control rule is Cc, Cf, Co and Cs — every *assigned* C category — and
**not Cn**, which is exactly what a table of assigned categories can express.

### Speed: the same as Python, on half the CPU

⚠️ **Absolute rates on this machine move by 2 to 3 times with background load.**
`mediaanalysisd` took 294% CPU during one run and made the port look half as
fast as it is. A first measurement of "421 chunks/sec, Python is twice as
quick" was thrown away for that reason. `coreml/ab-bench.sh` runs both sides
back to back on the same chunks; read the ratio, never one run against another.

| run | Python | Swift |
|---|---|---|
| 1 | 43.9 s | 42.3 s |
| 2 | 45.5 s | 24.7 s |
| 3 | 27.1 s | 25.0 s |

20,000 chunks each. Swift used 8.3 s of user CPU against Python's 15.9 s.

⚠️ **Tokenising is not the cost.** Measured in one run: **0.27 s of tokenising
against 70.4 s of prediction** for 20,000 chunks. Parallelising the tokenizer
across 14 cores was worth almost nothing, and the guess that it was the
bottleneck cost a wasted change.

**Search, end to end, with no daemon:** 1.95 s cold and 1.0 s warm, of which the
scan over 238,697 vectors is **0.08 s**. The rest is process start and model
load. An app holding the model in memory answers in under 100 ms, which is what
retires `daemon.py` and its 661 MB of PyTorch.

## 🛑 The fusion rule is tuned to ONE embedding

The Core ML vectors match PyTorch at 0.999999 cosine and score **lower** on
`eval.py`: MRR 0.535 against 0.586. That is not a vector-quality difference, and
the Swift port is not the cause — the Python Core ML path scores the same 0.535
on the same index.

Every fusion strategy, Core ML vectors:

| strategy | hit@1 | hit@3 | hit@10 | MRR |
|---|---|---|---|---|
| default (adaptive, threshold 4) | 0.48 | 0.55 | 0.66 | 0.535 |
| **adaptive off** | **0.52** | **0.62** | 0.66 | **0.573** |
| threshold 3 | 0.48 | 0.59 | 0.69 | 0.553 |
| threshold 5 | 0.48 | 0.55 | 0.59 | 0.522 |
| pool 300 | 0.48 | 0.55 | 0.66 | 0.535 |
| min-chunk 60 | 0.41 | 0.55 | 0.62 | 0.491 |
| 3:1 | 0.48 | 0.55 | 0.69 | 0.542 |
| 1:1 | 0.45 | 0.62 | 0.69 | 0.537 |

The same eight strategies against the PyTorch vectors, same index, same cases:

| strategy | Core ML MRR | PyTorch MRR |
|---|---|---|
| default (adaptive, threshold 4) | 0.535 | **0.586** |
| **adaptive off** | **0.573** | **0.573** |
| threshold 3 | 0.553 | 0.569 |
| threshold 5 | 0.522 | 0.573 |
| pool 300 | 0.535 | 0.586 |
| min-chunk 60 | 0.491 | 0.540 |
| 3:1 | 0.542 | 0.586 |
| 1:1 | 0.537 | 0.547 |

🛑 **With the adaptive rule OFF the two embeddings score IDENTICALLY: 0.573 and
0.573.** That is what a cosine of 0.999999 predicts, and it is the strongest
evidence in this file that the conversion is sound.

**The rule is the entire difference.** It adds 0.013 to PyTorch and takes 0.038
away from Core ML, on vector sets that agree to one part in a million.

⚠️ **So its measured gain cannot be told apart from noise.** +0.013 over 29
cases is under half of one case moving one rank. The rule was tuned on eight
field queries, and it swings by three times its own benefit between two
embeddings that are the same embedding. **Recommend turning it off**, and
measuring any replacement against both vector sets rather than one.

⚠️ **The default is unchanged for now.** Changing a ranking default is a
separate decision from converting a model, and it deserves its own field test.

The rule is one line, `index.py:1515`. It counts how many of the top 5 fused
records the semantic arm never returned, and re-fuses semantic-heavy at 4 or
more. On the two swimming cases PyTorch counts 5 and re-fuses; Core ML counts 3
and does not. Nothing else about the two runs differs.

⚠️ **A threshold on a count of five is a knife edge.** A vector difference of one
part in a million moves one record in or out of the top five and switches the
whole fusion strategy. Read the MRR gap as evidence about the RULE, not about
the model.

## 🛑 The enumerated model costs 1.2 GB of RAM to save 470 MB of disk

This reverses the recommendation two sections above. Measured at load, before
any query:

| packages | disk | resident |
|---|---|---|
| one enumerated, 5 shapes | **66.6 MB** | **1369 MB** |
| five fixed, one per shape | 539 MB | **192 MB** |

Core ML appears to hold an execution plan per shape. The fixed set is also
**faster** on the whole corpus — 968 chunks/sec against 878 — and it loads
lazily, so a run that only sees short chunks never loads the long buckets.

**So `vec` defaults to the fixed packages in `coreml/build`.** Ship the
enumerated one only where disk matters more than 1.2 GB of RAM, which for a
background app it does not.

### 🛑 Two parsing bugs, both silent, both found by the parity gate

1. **A directory of fixed packages is a BUCKET SET, not a choice of one.** The
   first version took the first package matching the batch size and used it for
   every chunk. Parity fell to **68.11%** — which is exactly the share of this
   corpus that fits in 128 tokens. **The number named the bug**: every chunk was
   being truncated at 128.
2. **`stem.range(of: "-s")` finds the `-s` inside `e5-small`.** It read the
   sequence length out of `"mall-v2-s128"`, which parses as nil, and the `?? 128`
   fallback made every package look like 128. Shapes are now matched as whole
   `-` separated components.
3. ⚠️ **And then `e5` parsed as an enumerated shape list of `[5]`**, because the
   component starts with `e` and the rest is a number. The first prediction
   failed with `MultiArray shape (32 x 5) does not match (32 x 64)`. An
   enumerated component now has to contain an underscore.

⚠️ **Only the first of those three was visible as a wrong ANSWER.** The other two
crashed, which is the good case. The truncation ran to completion and wrote
238,697 vectors that looked fine.

## The Swift daemon

`vec daemon` replaces `daemon.py`. It speaks the same protocol on the same
socket, so `index.py` and `apple-index` cannot tell which one answered.

| | `daemon.py` (PyTorch) | `vec daemon` (Core ML) |
|---|---|---|
| resident, idle | 661 MB | 112 MB, **474 MB warm** |
| search, warm | ~50 ms | **5.3 ms** |
| end to end, warm | 212–296 ms | **140 ms** |
| first search | — | ~43 ms (loads the bucket) |

⚠️ **An earlier version of this table said 15 ms, and that was a best case
inside a burst reported as the median.** Measured properly — 12 requests
straight to the socket, no process start — the first implementation ran at
**52.6 ms median**. Two changes took it to 5.3 ms, and both are below.

### 🛑 The scan was 238,697 separate function calls

The first implementation converted one row at a time with `vDSP_vflt8` inside
the loop. The work is 92 MFLOP over 91 MB, which no machine should need 52 ms
for. Converting the whole matrix to `Float` once at load and running **one
`cblas_sgemv`** cut the request from 52.6 ms to 9.1 ms.

It costs memory: 366 MB of float instead of 91 MB of int8, so the daemon holds
474 MB warm. That is still well under the 661 MB it replaces.

Where a 9.1 ms request went afterwards:

| step | median | share |
|---|---|---|
| embed the query | 6.70 ms | 74% |
| `cblas_sgemv` over 238,697 vectors | 1.80 ms | 20% |
| pick the top 120 | 0.40 ms | 4% |

**So a GPU matrix multiply was never the answer.** It could save at most 1.8 ms
of 9.1, and Metal dispatch would take part of that back.

### 🛑 `.all` is not the Neural Engine

Forcing the ANE for the single-query path took the embed from 6.7 ms to
**0.9 ms**, and the whole request to **3.2 ms**.

| round | `.cpuAndGPU` | `.all` | `.cpuAndNeuralEngine` |
|---|---|---|---|
| 1 | 6.80 ms | 2.90 ms | **1.00 ms** |
| 2 | 3.70 ms | 6.40 ms | **0.90 ms** |
| 3 | 6.90 ms | 6.90 ms | **0.90 ms** |

⚠️ **`.all` lets Core ML place the model per load, and it placed it differently
between runs.** One measurement of `.all` looked like a 2× win and was noise; a
second run of the same flag was no faster than the GPU. `.cpuAndNeuralEngine`
forces it and repeats.

⚠️ **This mixes two numerics**: the corpus is embedded on the GPU and a query on
the ANE, which agree to about 1e-5. Differences that size have flipped the
adaptive fusion rule in this same tool, so it was checked: `eval.py` scores
**MRR 0.535 on either backend**.

**The rule is now: batch 32 on the GPU, batch 1 on the Neural Engine.** The
winner flips between them, and neither is a safe default for both.

### 🛑 launchd's `ProcessType` was worth more than every other change

The agent ran 10× slower than the same binary started by hand. One key decides
which cores it gets. Measured with one binary and one set of flags, changing
only this:

| ProcessType | embed | scan | total |
|---|---|---|---|
| `Background` | 24.40 ms | 17.55 ms | 43.50 ms |
| `Adaptive` | 2.55 ms | 17.90 ms | 21.75 ms |
| `Standard` | 1.15 ms | 2.55 ms | 4.60 ms |
| **`Interactive`** | **1.30 ms** | **2.10 ms** | **4.20 ms** |

⚠️ **`Adaptive` is documented as raising a job while it works, and it did not
raise this one.** Measure the key rather than reading about it.

The original plist said `Background` with `Nice 5`, chosen to keep a polling
daemon out of the way. That was right for a process that polls and wrong for
one that answers a person waiting at a prompt.

### Two numbers, because they differ by 3×

| | |
|---|---|
| one query after a 3 second pause | **16.1 ms** |
| the same query inside a burst | 4.6 ms |

The hardware powers down between requests. **16 ms is the number a person
actually gets**; every "4 ms" figure in this file came from a tight loop.

### ⚠️ The shipped model set has no batch-1 package

`models/` holds three batch-32 packages, so the daemon pads one query into a
32-row batch: **15.8 ms of embedding instead of 0.9 ms**. Adding an `s64-b1`
package would fix it and costs **66 MB** on a 185 MB download, to save about
15 ms of a ~140 ms end-to-end search that is dominated by Python process start.
Left out on purpose; the trade is written here so the next person can take it.

🛑 **It serves and it does not ingest**, for the reason `daemon.py` learned the
hard way: reading the index needs no grant, and reading Mail, Notes and Messages
needs Full Disk Access that a launchd agent does not have. A failing ingest
prints no change lines, which looks exactly like "nothing changed".

⚠️ **The protocol uses the SHORT model name**, `e5-small-coreml`, not the stored
`e5-small-coreml-v1`. A daemon comparing the stored name declines every request,
and a decline only prints under `--verbose`. That looked like "the daemon is not
running" for several minutes.

## The default model is now Core ML

`index.py embed`, `search` and `refresh` default to `e5-small-coreml`. So the
ordinary path runs the Swift binary and never starts PyTorch.

⚠️ **That costs interactive latency until a Swift daemon exists.** `daemon.py`
holds `e5-small`, so it declines every default query and says so:

```
daemon declined: daemon holds e5-small, not e5-small-coreml
vec: scanned 238697 vectors in 0.069s
```

A fresh search now takes **1.0 s**, against about 0.25 s when the warm daemon
answered. The scan is 0.069 s of it; the rest is starting a process and loading
the model. `--model e5-small` still uses the daemon, so the old path is one flag
away.

## What is left

1. ~~A Swift daemon~~ **done.** `daemon.py` is no longer on the default path.
2. **Settle the adaptive rule** against both embeddings before changing its
   default. Changing it to suit Core ML would trade PyTorch's score for it.
3. 🛑 **The `query: ` and `passage: ` prefixes stay load-bearing** wherever this
   code goes next. E5 is trained asymmetrically.
