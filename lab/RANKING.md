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
| chunk cap | **200 for `files`, 20 elsewhere** (was 20 everywhere) |

MRR **0.535**, hit@1 0.46, hit@3 0.57, hit@10 0.70, over **37** cases.

⚠️ **Two things moved on 2026-08-25 and BOTH changed this number.** Read it as
a new baseline, not as a regression:

1. **The case set grew.** Four `vocabulary` cases were added; three older cases
   are broken and skipped. Comparisons before that date were scored over 33
   usable cases. At 33 cases the same settings scored 0.539.
2. **The `files` chunk cap went from 20 to 200**, which costs 0.006 MRR on this
   suite and buys 5,375 chunks the vector arm could not previously reach. 🛑
   **The suite cannot measure that gain** — see the chunk-cap section for why,
   and for the separate measurement that does.

At 37 cases: cap 20 scored 0.541, the shipped cap scores 0.535. **Do not read
0.006 as a change in the search.**

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

## 🛑 Four dead ends, all of which looked obviously right

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

### 4. Dropping high-frequency query terms (`--rare-only`)

**The problem is real, and a real question failed on it.** "COPTA HVAC" against
this index: `copta` matches **1,988** records and `hvac` matches **72**. The
common term contributes almost nothing and drags in every board-meeting thread
the organisation ever sent. The flag already existed, off by default.

It rescues the failing query and costs the suite at every threshold:

| | baseline | 100 | 200 | 500 | 1000 | 2000 |
|---|---|---|---|---|---|---|
| MRR | **0.539** | 0.491 | 0.476 | 0.458 | 0.397 | 0.437 |

`--drop-stopwords` scores 0.528, also below baseline.

At `--rare-only 500` the record that was **not in the top 300** moves to rank
52. The suite loses 0.081 MRR to buy that. It stays as a flag, off.

⚠️ **Scored over the 33-case set, before the `vocabulary` cases existed.**
Re-measure before quoting these against a newer number.

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

1. ~~**Query expansion**, in the SKILL rather than the index.~~ **Measured on
   2026-08-25. It does NOT fix this class** — see the next section. All four
   `no-overlap` cases stay missed under every fusion variant tried. Expansion
   fixes a different class, and conflating the two sent one session's
   recommendation the wrong way for a full turn.
2. **Re-test `e5-base` at 2:1.** ⚠️ The model comparison in
   [`MODELS.md`](MODELS.md) was run at 3:1, where the lexical arm dominated.
   e5-base's **vector arm alone scores 0.729 against e5-small's 0.631** — a
   0.098 gap that never reached the final ranking at that weighting. The
   balance has moved. The size decision deserves one re-measurement, not
   because 33M is too small, but because the conditions changed.


## 🛑 The vocabulary split: a class that is NOT `no-overlap`

Found 2026-08-25, from a real question that returned a confident wrong answer.

`no-overlap` means the answer shares no content word with the query, so only
the embedding can reach it. A **vocabulary split** is the opposite problem:
both words are in the corpus, in different documents, written by different
people. The COPTA exec committee minutes say "air conditioning" and never once
say "HVAC". The mail thread says "HVAC" and never says "air conditioning".

🛑 **The failure returns plausible, on-topic results.** A search for `COPTA
HVAC` returned five real HVAC emails and looked complete. Six meeting records
on the same subject, going back ten months, were never retrieved at all — one
sat at rank 54 and the rest were **outside the top 300**. Nothing in the output
distinguished that from "there is nothing else". An empty result set would have
been safer.

### ⚠️ The vector arm does not bridge it, and the cosine says why

`e5-small-v2`, query prefix, measured with the shipped Core ML models:

| pair | cosine |
|---|---|
| `HVAC` ↔ `air conditioning` | 0.9257 |
| `HVAC` ↔ `heating and cooling` | 0.8963 |
| `HVAC` ↔ `rooftop unit` | 0.8282 |
| **`HVAC` ↔ `meeting minutes`** | **0.8142** |
| **`HVAC` ↔ `bicycle`** | **0.8003** |

🛑 **0.93 is not "close" here. The floor is 0.80.** The whole usable range is
0.17 wide, so an absolute cosine from this model carries almost no information.

Ranked against all 251,949 vectors, the semantic arm alone puts the correct
records at:

| query | best COPTA-minutes chunk |
|---|---|
| `HVAC` | **not in the top 2000** |
| `COPTA HVAC` | rank 368 |
| `office air conditioning` | rank 143 |

The default pool is **60**. The score curve explains it: rank 1 scores 0.9478,
rank 60 scores 0.8510, rank 3000 scores 0.8260. **Ranks 60 to 3000 span 0.025**
— narrower than the gap between a relevant sentence and an unrelated one.

⚠️ **Adding the organisation's own name made the semantic arm worse too**, not
just the lexical one. Against the same passages, `COPTA HVAC` scored 0.03 to
0.07 BELOW plain `HVAC`. The owner's name selects most of the corpus.

## Query expansion: what it fixes, and what it must not do

Caller-side only. Run several phrasings, fuse the result lists. The index is
unchanged. Scored over the 37-case set.

⚠️ **Two measurement rounds, and the second is the one that counts.** The first
used a caller-side harness at cap 20; the numbers below are the SHIPPED `--also`
flag against the shipped cap. The pattern is identical and the absolute values
moved, because the chunk cap moved the baseline from 0.541 to 0.535.

| strategy | hit@1 | hit@3 | hit@10 | MRR |
|---|---|---|---|---|
| plain | 0.46 | 0.57 | 0.70 | 0.535 |
| `--also` on every query | 0.46 | 0.57 | **0.76** | 0.546 |
| **`--also` on questions only** | 0.46 | **0.59** | **0.76** | **0.553** |

🛑 **The CLI does not apply the conditional rule itself.** It cannot tell a
keyword lookup from a question reliably enough to spend a caller's recall on a
guess, and the caller already knows which it typed. The rule is in the skill.

### 🛑 Use `max`, never `sum`

RRF **sum** rewards a record appearing in MANY lists over one ranking FIRST in
one list. For expansion that is backwards: the original query is the only
phrasing known to be the user's question, and the paraphrases are guesses.
Measured on the 33-case set: three cases went from **rank 1 to a miss**.

⚠️ **Weighting the original query higher does NOT fix it.** It was the obvious
repair and it is wrong, monotonically:

| weight on original | 1 | 2 | 3 | 5 |
|---|---|---|---|---|
| MRR | 0.521 | 0.501 | 0.498 | 0.487 |

Taking each record's **best** reciprocal rank across phrasings does fix it.
Under `max`, **no case fell out of the top 10**; the worst regression was
3 → 9.

### 🛑 Expand a question. Never expand a keyword lookup.

The effect splits cleanly, and this is the actionable result:

| kind | n | plain | `--also` | |
|---|---|---|---|---|
| **vocabulary** | 4 | 0.562 | **0.667** | helps most |
| vault | 5 | 0.113 | 0.162 | helps |
| descriptive | 13 | 0.588 | 0.599 | helps |
| **no-overlap** | 4 | 0.000 | 0.000 | **no effect at all** |
| recent | 4 | 0.833 | 0.800 | hurts |
| keyword | 7 | 0.857 | 0.821 | hurts |

A keyword query is already the right words; paraphrasing only adds noise. The
runtime rule — four or more words, or a leading wh-word — agrees with the hand
labels on 28 of 33 cases and is what `conditional` above uses.

⚠️ **Read the whole-suite gain honestly: +0.024 MRR is inside the noise the
weight plateau established.** The defensible signal is hit@10 0.70 → 0.78 and
the `vocabulary` row. Do not quote the MRR as the reason.

### ⚠️ Two things expansion does NOT do

- **It does not fix `no-overlap`.** All four cases stay missed under every
  variant. One — "who is my new doctor" — flipped to rank 3 under exactly one
  variant and nowhere else. That is the same one-case-with-a-story shape this
  file rejects the adaptive rule for, and it is not counted.
- **It fixes retrieval, not rank.** On the real question all five meeting
  records went from absent to retrieved, at ranks 34 to 81. **At a limit of 10
  none of them appear**, because mail holds 81% of the chunks and takes the
  head of the list. Per-tool interleaving is the obvious answer and fails the
  same way the retrieval quota did: MRR 0.457–0.460 against 0.541.

## 🛑 The chunk cap: raised for `files` to 200, left at 20 everywhere else

Changed 2026-08-25. Chunks are 900 characters with 150 overlap, and the cap
takes them **from the front**, so a capped record embedded its first ~15,000
characters and nothing else.

**What that was costing.** `COPTA Bylaws.md` produces 162 chunks uncapped; the
index held 20. Sections 5, 6 and 7 of a live governance document were
unreachable. `COPTA Standing Rules.md`: 142 chunks, 122 of them missing. One
112 KB meeting transcript had **13%** of its text embedded. Across `files`,
**5,375 chunks were unreachable** — 39% of the source.

⚠️ **`record_fts` holds the FULL body, so only the SEMANTIC arm was blinded.**
That is the arm a paraphrase needs. A lexical hit still returned something
plausible, which is why this was invisible for so long.

### 🛑 Raising it globally is WORSE than leaving it alone

| | chunks | MRR | re-embed |
|---|---|---|---|
| cap 20 everywhere *(was)* | 254,995 | **0.541** | — |
| **`files` 200, rest 20** *(ships)* | 260,464 | **0.535** | **23s** |
| 200 everywhere | 284,016 | **0.511** | 334s |

Mail is 81% of the chunks and **1,608 mail records sit at the cap**. Letting
each contribute ten times as many candidates dilutes every other query, for a
0.030 MRR loss. Same failure mode as the per-tool retrieval quota.

### The value barely matters, which is why it is trustworthy

Sweeping the `files` cap alone, everything else fixed:

| files cap | 40 | 60 | 100 | **200** | 400 |
|---|---|---|---|---|---|
| files chunks | 10,837 | 11,823 | 12,864 | **13,837** | 14,092 |
| MRR | 0.535 | 0.531 | 0.536 | **0.535** | 0.535 |

**A plateau, 0.005 wide, against a 0.541 baseline.** 200 captures 98% of the
text that no cap at all would, so it ships. The 0.006 cost is inside the noise
the weight plateau established.

### 🛑 THE SUITE CANNOT SEE THE BENEFIT, BY CONSTRUCTION

`eval.py`'s `resolve()` reads `chunk.text`. A locator past the cap does not
resolve, so the case is **unwritable at the low cap** — not merely hard. Every
number above therefore measures only what the change COSTS.

The benefit was measured separately, against text that exists in one index and
not the other:

| question, answered only past chunk 20 | cap 20 | files 200 |
|---|---|---|
| can a paid employee of the PTA vote on its board | **miss** | **1** |
| who has to approve using Colorado PTA letterhead | **miss** | **1** |
| what is the status of our CANPO membership | 8 | 5 |

⚠️ **Do not write these into `CASES`.** They would resolve against the new
index and silently become unusable if the cap is ever lowered, which reads as
three broken cases rather than as a regression.

### Operating notes

- **`rechunk` cascades every vector it deletes**, so changing a cap means a
  re-embed of that source. `--source files` is 23s; all sources is 334s.
- The cap lives in `MAX_CHUNKS_BY_SOURCE`, read through `max_chunks_for(tool)`.
  `INDEX_MAX_CHUNKS` overrides every source and is how the sweep was run.
- Index size: 707 MB → 716 MB.

## 🛑 The harness bug that printed `MRR 0.000` and meant nothing

Found while measuring the cap. `eval.py --db PATH` appended `--db` **after**
the subcommand, where `index.py` rejects it as an unrecognised argument —
`--db` is a global option and must precede the subcommand. `search()` swallowed
the non-zero exit and returned `[]`, so **every case scored a miss** and the
run printed `MRR 0.000` with no error.

⚠️ **The first reading was "the new index retrieves nothing."** That is the
same shape as the `result_cache` bug above: a broken harness answering
confidently. **A run reporting 0.000 across the board is a harness failure, not
a search failure.** `search()` now writes the subprocess stderr out.

