# Ranking: what was measured, and what it cost to learn

Every number here comes from `./eval.py --compare` against the real index on
this machine. 🛑 **Nothing in this file was reasoned about and then written
down.** That distinction is the whole point of the file: three separate times, a
change that was obviously right beforehand turned out to be measuring a broken
test rather than a broken search.

## The state that ships

| | |
|---|---|
| lexical : semantic | **2 : 1** (was 4:1) |
| adaptive re-fuse | **off** |
| per-tool retrieval quota | **off** |
| recency arm | off (`--w-recency 0`) |

MRR 0.539, hit@1 0.45, hit@3 0.61, hit@10 0.70, over 36 cases.

## The weights: a plateau, not a peak

Swept lexical:semantic with everything else fixed.

| | MRR | | MRR |
|---|---|---|---|
| 8:1 | 0.474 | 2.5:1 | **0.542** |
| 6:1 | 0.491 | 2:1 | **0.539** |
| 5:1 | 0.521 | 1.75:1 | **0.539** |
| 4:1 *(was default)* | 0.509 | 1.5:1 | **0.539** |
| 3:1 | 0.533 | 1.25:1 | 0.504 |
| | | 1:1 | 0.496 |

**2:1 ships.** ⚠️ 2.5:1 scores 0.003 higher, which is one case moving one rank.
2:1 sits in the MIDDLE of the plateau rather than at its edge, and the cliff
below 1.5:1 is steep.

🛑 **A PLATEAU IS WHY THIS IS TRUSTWORTHY.** Four consecutive points agree to
0.003 and the curve is smooth on both sides. Compare the adaptive rule below,
which is a threshold on a count of five — a knife edge.

## 🛑 Three dead ends, all of which looked obviously right

### 1. A per-tool retrieval quota

**The problem is real.** Mail is 81.3% of the chunks here. For "what books have
I been reading" it took **54 of the 60** semantic candidates; the Obsidian vault
got 2. A source that is never retrieved cannot be ranked, and the whole point of
this index is not having to name the app first.

A quota in both arms fixes the retrieval and costs more than it earns:

| per-tool | 0 | 5 | 10 | 20 | 40 |
|---|---|---|---|---|---|
| MRR | **0.539** | 0.436 | 0.313 | 0.212 | 0.149 |

Monotonically worse. The quota admits a weak candidate from every source — a
calendar entry called "Book camping" — and those displace good ones. It stays
as `--per-tool K`, off.

### 2. Adaptive re-fusing

Re-fuse semantic-heavy when 4+ of the top 5 are records the semantic arm never
returned. At 4:1 it *lost* 0.038 MRR. At 2:1 it *gains* 0.006.

🛑 **Both numbers are noise, and the per-case view proves it.** At 2:1, exactly
**one case in 36** changes: "how many people are on the COPTA board", miss → 5.
The whole measured effect is one case with a story attached. It stays off.

⚠️ **Its value depends on the weights**, which is itself a reason to distrust
it: a rule whose sign flips when another knob moves is not measuring what its
name says.

### 3. A wider candidate pool

`--pool` 60, 120, 200, 300 and 500 gave identical scores. Failing cases have
their correct record at global semantic rank 16, 4 and 1 already. **They lose at
fusion, not at retrieval depth.**

## 🛑 The bug that hid all of this for one run

`search_settings` builds the `result_cache` key, and **`pool` and `per_tool`
were missing from it**. Changing either returned the PREVIOUS answer from cache.

A comparison of six `--per-tool` values scored all six identically — 0.237
across the board — because the harness read one cached result six times. It
looked like a flat response curve. It was one number, printed six times.

**Every flag that changes a result belongs in the cache key.** ⚠️ This also
invalidates the `--pool` row of every comparison run before 26.824.7.

## 🛑 THE REAL LESSON: three cases were mislabelled, not three searches broken

Each of these punished correct behaviour, and each was found only by reading the
record instead of the score.

| case | the wrong label | what was true |
|---|---|---|
| where do the kids do gymnastics | expected `Frequent Flyers` | the kids go to CATS Gym; e5-base returned the right record and was scored a miss |
| do our COPTA bylaws prohibit business relationships | expected `conflict with the National PTA Bylaws` | that passage is about bylaws conflicting with EACH OTHER. The note has no "conflict of interest", no "business relationship", no "prohibit" — it does not answer the question. COPTA **rescinded** its Conflict of Interest Policy on 2025-07-20 and adopted a Code of Conduct |
| where do the kids swim | expected `Ocean First` only | **two** right answers: Ocean First in Boulder AND Goldfish Swim School in Superior. The search returned Goldfish at rank 1 and the harness called it a miss |

⚠️ **The swim case is the sharpest.** It is the query the adaptive rule was
built for, and the case its own source comment cites. The rule looked useless on
it — because the harness was wrong, not the rule. Correcting the label made the
case pass with the rule OFF.

**A locator may now be a tuple of strings**, because a question can have several
right answers in different words. That should have been true from the start.

🛑 **The common thread: every wrong label was chosen by matching WORDS in a
record, not by checking the record ANSWERS THE QUESTION.** A locator picked
because it looks like the query is a locator selected for the same bias the
search has.

## What still fails, and why it is not a ranking problem

Four `no-overlap` cases — the query shares no content word with its answer:

```
why is the finance chair missing the board meeting    miss
when is the PTA fundraiser at the ice cream place     miss
who is my new doctor                                  miss
where do I get my hair cut                            miss
```

For "do our COPTA bylaws prohibit business relationships" the correct record is
**not in the top 500 semantic hits**. That is the embedding, not the fusion.

Two leads, both measurable against these cases:

1. **Query expansion**, in the SKILL rather than the index. An `apple-index`
   search is almost always run by an agent, so the caller can rewrite the
   question or search twice and merge. Costs the index nothing.
2. **Re-test `e5-base` at 2:1.** ⚠️ The model comparison in
   [`MODELS.md`](MODELS.md) was run at 3:1, where the lexical arm dominated.
   e5-base's **vector arm alone scores 0.729 against e5-small's 0.631** — a
   0.098 gap that never reached the final ranking at that weighting. The
   balance has moved. The size decision deserves one re-measurement, not
   because 33M is too small, but because the conditions changed.
