# Choosing the embedding model

**Adopted: `intfloat/e5-small-v2`.** Every number below is measured on this
machine against the real index: 59,227 records, 239,498 chunks.

🛑 **The first model was chosen by reasoning about how the models were built,
not by measuring what they retrieved.** It was wrong, and nothing showed it
until a real question failed. That is why this file exists and why every claim
in it carries a number.

## The decision

| | e5-small | e5-base | Apple `NLEmbedding` |
|---|---|---|---|
| **MRR, hybrid 3:1** | **0.786** | 0.774 | 0.738 |
| MRR, vector arm alone | 0.631 | **0.729** | **0.250** |
| hit@1 / hit@3 | 0.71 / 0.86 | 0.71 / 0.86 | 0.64 / 0.86 |
| Search, daemon warm | 296 ms | **212 ms** | 160 ms |
| Daemon resident memory | **661 MB** | 948 MB | n/a |
| Vector matrix | **92 MB** | 184 MB | 123 MB |
| Index the corpus | **9 min** (511/s) | 30 min (133/s) | 66 min (60/s) |
| Parameters | **33.4M** | 109.5M | undisclosed |
| Dimensions | 384 | 768 | 512 |

⚠️ **e5-base has the better vector arm and still loses the hybrid.** At 3:1
weighting the lexical arm dominates, so base's stronger vectors never reach the
final ranking. The 0.012 hybrid gap is under one case in fourteen. **Read the
quality as a tie and let the resources decide.** e5-small uses 287 MB less RAM
and indexes 3.3× faster.

## 🛑 What went wrong first: NLContextualEmbedding

The index shipped for most of a day on `NLContextualEmbedding` with mean-pooled
token vectors. Measured, for the query "bathroom code":

| text | NLContextual | NLEmbedding.sentence (distance) |
|---|---|---|
| the bathroom door code | 0.9461 | **0.4123** |
| Bathroom code | 0.9735 | 0.5466 |
| Bathroom code 3384 | 0.8173 | 0.8082 |
| Hub open house | 0.8977 | 1.0763 |
| Junkyard social | **0.9020** | 1.1674 |

**"Junkyard social" beat the literal answer.**

⚠️ **Mean-centering did NOT fix it**, so this was not the usual anisotropy
problem. Apple documents `NLContextualEmbedding` as a **feature layer** for
training a model with CreateML. Pooling its token vectors and comparing them by
cosine is a use it was never built for.

The reasoning that chose it was *"the sentence model is static, so a word gets
the same vector regardless of its sentence"*. True about the design, and
irrelevant to retrieval quality.

## The bake-off

Six real cases against 120 distractors drawn from the actual index.

| Model | Ranks | MRR |
|---|---|---|
| all-MiniLM-L6-v2 | 1, 1, 2, 1, 34, 1 | 0.755 |
| all-MiniLM-L12-v2 | 1, 1, 1, 3, 11, 1 | 0.737 |
| bge-small-en-v1.5 | 1, 1, 1, 3, 35, 1 | 0.727 |
| **e5-small-v2** | 1, 1, 1, 1, 37, 1 | **0.838** |
| **e5-base-v2** | 1, 1, 1, 1, 8, 1 | **0.854** |
| Qwen3-Embedding-0.6B | 1, 1, 1, 3, 72, 1 | 0.725 |

🛑 **Qwen3-0.6B is not worth its size here.** Ten times the parameters of
MiniLM, four times slower, and it scored **worse**. Bigger did not win.

⚠️ **A five-year-old 90 MB MiniLM beats Apple's on-device model**, which is the
more useful finding than any ranking among the open models.

## 🛑 Prefixes are load-bearing

These models are trained asymmetrically. A query and a passage get different
prefixes, and omitting them makes a strong model score like a weak one.

| Model | Query prefix | Passage prefix |
|---|---|---|
| e5-small, e5-base | `query: ` | `passage: ` |
| bge-small | `Represent this sentence for searching relevant passages: ` | none |
| Qwen3-Embedding | `Instruct: ...\nQuery: ` | none |
| MiniLM | none | none |

`embed_oss.py` holds them in one table so a model cannot be added without one.

## 🛑 Two models never share a vector space

`vector` is keyed on `(cid, model)`, and every search filters on `model`.
Scoring across two models returns confident nonsense.

⚠️ **The daemon bypassed that guard and it took an evaluation to notice.** It
served whatever model it had loaded, ignoring the client's request, so
`--model sentence`, `--model e5-base` and `--model e5-small` all returned
e5-small results and printed identical scores. The daemon now declines:

```
daemon declined: daemon holds e5-small, not e5-base
```

A mismatch now costs latency, not correctness.

## What no model solves

Two of the fourteen cases still miss, and both are vocabulary gaps:

- *"who works in fundraising for a hospice organisation"* → the record says
  **"Director of Development"** at **"Hospicare"**.
- *"what address do we go to for swimming lessons"* → the record says
  **"Ocean First"**.

⚠️ One case was wrong for several runs. It expected "Frequent Flyers" for a
gymnastics query when a calendar event says **CATS Gym**. e5 returned the
correct record and the harness scored it a miss. **A wrong label is worse than
a missing case: it punishes the right answer.**

## 🛑 The evidence here is 29 hand-written cases, and that is not enough

Every number above comes from cases written by hand against this machine's real
data. They caught a badly wrong model — `NLContextualEmbedding` — and they are
the reason this file exists. They cannot do the next job.

**They cannot separate 0.78 from 0.80.** The e5-small / e5-base decision above
turned on 0.012 MRR, "under one case in fourteen", and was correctly read as a
tie. A newer model claiming a two-point gain would be indistinguishable from
noise on this harness. They are also unshareable: every case names something
private, so no result here can be reproduced by anyone.

**[`bench/`](bench/README.md) is the answer to both.** EnronQA — 103,638 real
emails, 528,304 question/answer pairs, public — scored by this same `eval.py`
against a separate index. 1,254 cases in two minutes:

| e5-small-coreml, inbox `germany-c` | |
|---|---|
| hit@1 | 0.68 |
| hit@3 | 0.87 |
| hit@10 | 0.94 |
| **MRR** | **0.780** |

**What it has already shown.** All 29 fusion strategies against 1,254 cases:
the best weighting is **6:1 lexical:semantic at MRR 0.795**, the shipped default
scores **0.780**, and **vectors alone score 0.690**. So the lexical arm is worth
ten points there, which agrees with the vector-arm-alone numbers above.
🛑 **1.5 points on one source is not a reason to move the shipped weighting** —
see the rule below. Full table and the caveats in
[`bench/README.md`](bench/README.md).

⚠️ **It complements these cases, it does not replace them.** Every EnronQA case
is a long, well-formed `descriptive` question written by an LLM from the answer.
There is not one short keyword lookup, and nothing about calendar, places or
cross-source fusion. **A model that wins there and loses here has not won.**

## Changing the model

```
./index.py embed --model e5-base        # ~30 min; vectors sit beside the others
./index.py daemon stop && ./index.py daemon start --model e5-base
./eval.py --compare                     # never adopt one without this
```

Old vectors are kept rather than dropped. `sentence-v1` and `e5-base-v1` cost
about 300 MB together and take 66 and 30 minutes to rebuild, which is a poor
trade against disk on this machine. Drop them with:

```sql
DELETE FROM vector WHERE model IN ('sentence-v1', 'e5-base-v1');
```
