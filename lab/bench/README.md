# bench/ — measuring retrieval on somebody else's mail

**`eval.py` ships 29 cases.** They are hand-written against this machine's real
data. That is enough to catch a broken fusion rule and **far too few to decide a
model swap** — separating MRR 0.78 from 0.80 on 29 cases is separating noise.
They are also unshareable: every one names something private.

**EnronQA fixes both.** 103,638 real emails from 150 real inboxes with 528,304
question/answer pairs, released for exactly this purpose
([arXiv 2505.00263](https://arxiv.org/abs/2505.00263),
`MichaelR207/enron_qa_0922`). It is what
[LEANN](../../docs/prior-art.md) — the one real peer in the survey, from the
Berkeley Sky Lab — evaluates against.

```
./bench/enronqa.py fetch --user germany-c    # 1,257 emails, 1,254 cases
./bench/enronqa.py build                     # its own index: 7,936 chunks, 11s
./bench/enronqa.py score --limit 0           # 2 min
./bench/enronqa.py score --compare --limit 0 # every fusion strategy, ~16 min
```

## The baseline

`e5-small-coreml`, inbox `germany-c`, all 1,254 cases:

| | |
|---|---|
| hit@1 | 0.68 |
| hit@3 | 0.87 |
| hit@10 | 0.94 |
| **MRR** | **0.780** |

Sample 250 with `--limit 250` for a 30-second run; the sample is seeded, so two
runs compare.

## Every fusion strategy, on 1,254 cases

`--compare`, 16 minutes. The ratios are **lexical : semantic**.

| strategy | hit@1 | hit@3 | hit@10 | MRR |
|---|---|---|---|---|
| **6:1** | **0.70** | **0.89** | 0.95 | **0.795** |
| 5:1 | 0.69 | 0.89 | 0.95 | 0.794 |
| 3:1 | 0.69 | 0.88 | 0.95 | 0.793 |
| **default (shipped)** | 0.68 | 0.87 | 0.94 | **0.780** |
| 1:1 | 0.67 | 0.87 | 0.95 | 0.778 |
| 1:3 | 0.65 | 0.84 | 0.93 | 0.756 |
| **0:1 — vectors alone** | 0.58 | 0.78 | 0.89 | **0.690** |

Three things fall out of it.

**The lexical arm is worth ten points of MRR.** Vectors alone score 0.690; the
best hybrid scores 0.795. ⚠️ These are LLM-written questions that quote the
answer's own words, so this flatters the lexical arm — but the direction agrees
with [`../MODELS.md`](../MODELS.md), where the vector arm alone also lost.

**The shipped weighting is 1.5 points off the best here.** 🛑 **That is not a
reason to change it.** Fifteen cases in 1,254, on one source, from questions
nobody phrased the way a person would. `MODELS.md` records the rule: never adopt
a setting without `--compare` **on the real corpus**. This bench narrows what is
worth testing there; it does not decide it.

**🛑 Every structural knob is inert — exactly 0.780.** Per-tool quotas at 0, 5,
10, 20 and 40; adaptive fusion on, off, and at three thresholds; pool 300;
min-chunk 60. Not one moves a digit.

That is a **limit of the bench, not a finding about the knobs.** They exist to
stop one big source crowding out a small one — mail is 81% of the real index's
chunks and took 54 of 60 candidates for one real query. This corpus has exactly
one source, so a per-tool quota has nothing to balance and an adaptive rule has
nothing to adapt to. ⚠️ **Do not read these rows as evidence against them.**

## 🛑 It never touches the real index

`APPLE_INDEX_DB` moves the database **and** `files.json` with it, because the
latter is derived from the former's directory. Without that, `files add` would
write a root into the user's own config and their next real refresh would index
Enron into their own life. `guard()` refuses to build anywhere under
`~/Library/Application Support/apple-tools`, so this is checked rather than
assumed.

⚠️ **`--accept-risk` is passed here and is correct here only.** The consent gate
exists because indexing copies the plaintext of the user's own mail into one
unprotected file. This database holds public Enron mail and nothing of theirs.

## 🛑 The path is the locator, and it only works by luck

`eval.py` resolves a case by finding records whose text contains the locator.
EnronQA writes each email's own path into its body:

```
Subject: FW: Ameren
Sender: stephanie.panus@enron.com
File: phanis-s/sent_items/4.
==================================
```

So `germany-c/sent_items/4.` is a substring of exactly one record, and this
script never has to know anything about record ids. ⚠️ A row whose path is not
inside its own body is **reported and skipped**, never dropped silently — 3 of
1,257 here.

## ⚠️ What it measures, and what it does not

- **Corporate email from 2001**, one mailbox at a time. Not personal mail.
- **Questions written by an LLM from the answer.** They are long, specific and
  well-formed. Real questions are three words and a half-remembered name.
- **All 1,254 cases are `descriptive`.** There is not a single short keyword
  lookup, which is the *other* half of what this index is for and the half the
  hand-written cases cover.
- **One source.** No cross-source fusion, no calendar, no places, no contacts.

🛑 **So this does not replace the 29 hand-written cases. It complements them.**
It measures the mail arm on English prose, at a scale where a 2-point difference
is real. The hand-written ones measure what actual use looks like. A model that
wins here and loses there has not won.

## Picking an inbox

`--user` takes any of the 150. Sizes in the `test` split:

| inbox | emails |
|---|---|
| dasovich-j | 5,485 |
| kaminski-v | 3,912 |
| shackleton-s | 3,120 |
| taylor-m | 2,671 |
| mann-k | 2,484 |
| jones-t | 2,255 |
| nemec-g | 1,610 |
| **germany-c** (default) | **1,257** |
| symes-k | 688 |

⚠️ **EnronQA's setting is per-inbox**, and mixing several changes the task: the
questions are about one person's mail, retrieved from that person's mail. Use a
bigger inbox for more distractors, not several small ones.

## What this is for

The next question is whether a newer embedding model is worth adopting — see
[`../MODELS.md`](../MODELS.md). Qwen3-Embedding-0.6B was already measured here
and **lost** to e5-small on the hand-written cases. Before believing any
leaderboard, run it against this.
