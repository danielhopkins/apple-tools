# Choosing and switching the embedding model

**What this settles:** how `apple-index` shows which embedding model it is
using, how a user changes it, and why the light option is a second model
rather than a smaller quantisation of the one already shipped.

[`lab/MODELS.md`](../lab/MODELS.md) settles *which* model was adopted and what
it scored. This file settles the *machinery* around that choice. Read
[`lab/coreml/BAKEOFF.md`](../lab/coreml/BAKEOFF.md) for the conversion itself.

## The state before this change

Three bugs, all silent, all reachable today.

1. 🛑 **`vec daemon` accepts `--model` and ignores it.** `commandDaemon`
   unconditionally builds the Core ML embedder, whatever the flag said. That is
   the same class of bug `BAKEOFF.md` already records: it once made
   `--model sentence` and `--model e5-base` score identically, because both
   were served e5-small.
2. 🛑 **A search against a model with no vectors answers lexically, in
   silence.** `vec search` filters `WHERE dim = N AND model = 'X'`, matches
   nothing, prints `[]` and exits 0. `index.py` discards the stderr unless
   `--verbose`. ⚠️ **The results look fine.** Lexical-only scores MRR 0.674
   against 0.771 for the hybrid, so nothing on screen says the vector arm
   contributed nothing.
3. ⚠️ **Nothing anywhere names the model in use.** `stats --json` reports
   vector counts per model name. The app reads them, computes `mixedModels`,
   and prints a red fault without ever showing which models it found.

⚠️ **`--model` offers six names and a shipped install can run two.**
`e5-base`, `e5-small` and `minilm` need `uv`, PyTorch and a Hugging Face
download, and `Makefile` states plainly that none of them ship. `contextual`
needs a separate Apple asset download. Nothing tells the user this.

## The measurement that reframed "lighter"

🛑 **The 210 MB of shipped weights is three copies of a 67 MB model.** Core ML
holds an execution plan per shape, so `ship-models.sh` builds one package per
sequence bucket. A smaller model therefore saves far less than its parameter
count suggests.

| Configuration | Size | Speed | Parity |
|---|---|---|---|
| 5 fixed buckets, fp16 | 539 MB | 968 chunks/s | byte-identical |
| **3 fixed buckets, fp16 — shipped** | **210 MB** | 663 chunks/s | byte-identical |
| 3 fixed buckets, int8 | **106 MB** | **682 chunks/s** | cosine ≥ 0.9967 |
| 1 enumerated | 67 MB | 878 chunks/s | 🛑 1369 MB resident |

Source: `lab/coreml/ship-models.sh:5-8`, measured on this corpus.

⚠️ **The chunker targets ~200 tokens.** `CHUNK_CHARS = 900`. Measured on this
corpus: **50% of chunks fit in 64 tokens and 96% fit in 256.** So the 512
bucket serves a 4% tail, and a model with a 256-token window truncates that
4% rather than a large fraction.

### 🛑 int8 was rejected, and it was the cheaper answer

int8 is half the size, measured **faster**, keeps all three buckets and the
512-token window, needs no download, no second directory and no new parity
gate. It was not adopted.

The reason is that it is not a different model. It is the same weights at lower
precision, so it cannot answer the question "is there a model that suits this
machine better". A second model can. ⚠️ **This decision cost a 90 MB download,
a hosted release asset, a second models directory, a second parity gate, and a
third network call in a tool whose stated promise is that it runs locally.**
Recorded here so that a future reader does not rediscover int8 and assume it
was overlooked.

## What a switch is

🛑 **A switch replaces the vector set. It re-embeds every chunk.** Two models
never share a vector space, so there is no cheaper form of this.

- **Embed the new set first, count it, then delete the old one.** The old
  vectors keep answering searches for the whole window, and a failed switch
  leaves the working model intact. Peak disk is two vector sets, about 184 MB
  for two 384-dim models. This is the rule `apple contacts move` already uses:
  create the copy before deleting the original.
- **The CLI asks on a tty**, and refuses without one unless given `--yes`. The
  prompt names the chunk count and the estimated minutes before asking. Same
  rule as `apple notes delete`.
- ⚠️ **A search mid-switch warns that the index is not complete**, on stderr
  *and* as `vectors: {model, embedded, total}` in `--json`. 🛑 The JSON field is
  not decoration. `apple maps places` warned about truncation on stderr alone
  and a caller reading JSON never saw it, which is how "how many times did we
  go there" answered 1 when the true answer was 4.

## Where the current model is recorded

A JSON file in `~/Library/Application Support/apple-tools`, beside
`files.json` and `people.json`.

- 🛑 **Not beside the index.** `files.json` followed `dirname(DEFAULT_DB)` until
  26.827.0, which is inside the encrypted vault whenever the app has it
  mounted. A folder added from the app disappeared with the volume, and
  `apple-index forget` destroyed the configuration along with the index. The
  model config must survive `forget`.
- 🛑 **It carries switch state, not just a name.** During a switch it holds the
  target model and a start time. Without that, the app cannot tell a switch in
  progress from a genuinely mixed index, and the two look identical in the
  database. The app's existing red fault — "Vectors exist under more than one
  model name" — is correct today and wrong during every switch.
- ⚠️ **Not inferred from the vector table.** Taking whichever model has the most
  rows makes the answer change silently part-way through a re-embed.

## Two models on disk

🛑 **`CoreMLEmbedder` takes every `.mlpackage` in the models directory and
parses only `bN` and `sN` from the filename.** The model identity in the name
is ignored, and there is exactly one `vocab.txt` slot. Two models in one
directory merge into one bucket set with **no error**: you get one model at
s64 and s512 and the other at s256, mixed into a single vector space.

The layout is therefore **one directory per model**, selected by
`VEC_COREML_DIR`, and `CoreMLEmbedder` **refuses a directory whose packages do
not all share one stem**. The refusal is the point: it turns a silent wrong
answer into an error.

`modelName`, `shortName` and the query and passage prefixes become instance
state. 🛑 **Two of the three candidate models use no prefixes at all**, and
`encodeQuery` currently hard-wires e5's. `vec verify` hard-codes the passage
prefix too, so the parity gate cannot check a prefix-free model as written.

**The tokenizer needs no change.** `WordPiece.swift` compiles in no vocab size,
looks its special tokens up by name, and takes the maximum length as a
parameter. Every candidate is BERT-base-uncased, so their `vocab.txt` files
drop in.

## The parity gate takes per-model rules

`vec verify` asserts **byte-identical** against the PyTorch reference. That is
right for an fp16 conversion of the same weights, and it caught three
tokenizer bugs. It is wrong for anything else.

So the gate takes a rule per model: byte-identical for fp16, a cosine floor
otherwise, and a configurable prefix. ⚠️ **A cosine floor everywhere would stop
the fp16 path catching what it exists to catch.**

## Choosing the second model

🛑 **Measured, never reasoned.** `MODELS.md` opens with what that cost: the
first model was chosen by reasoning about how the models were built, and it was
wrong, and nothing showed it until a real question failed.

Three candidates, all 384-dim so the compiled-in `DIM = 384` holds:

| Model | Params | Trained length | Est. 3 buckets |
|---|---|---|---|
| `e5-small-v2` (current) | 33.4M | 512 | 210 MB (measured) |
| `all-MiniLM-L6-v2` | 22.7M | **256** | ~135 MB |
| `snowflake-arctic-embed-xs` | 22.6M | 512 | ~135 MB |
| `bge-micro-v2` | 17.4M | 512 | ~105 MB |

⚠️ **Sizes are estimates from parameter counts at fp16.** The method predicts
e5-small's measured 67 MB per package exactly, which is why it is used, but
nothing here is weighed until it is built.

🛑 **The floor is hybrid MRR 0.738, and it was set before the numbers
existed.** That is Apple's `NLEmbedding`, which this repo measured and
rejected. A "light" model scoring below the one already thrown out is not
worth 105 MB and a network call. **If no candidate clears the floor, no second
model ships**, the numbers are reported, and the rest of this work lands with
one model in the roster.

## 🛑 The third network call

apple-tools names two, both deliberately visible: opt-in geocoding, and the
app's MapKit tiles. Downloading a converted model is a third.

- **It sends nothing about the user.** It is a fetch of a fixed asset, not a
  query carrying their data. That is a different shape of exposure from the
  other two, and a smaller one.
- **It breaks "everything runs locally" at install time**, which is written
  down in four places. That is why it is recorded here rather than absorbed.
- **The default model stays shipped**, at 210 MB, so a fresh install searches
  semantically with no network at all. Only the light option downloads.
- **A pinned sha256, verified after the download.** A mismatch refuses and
  leaves the current model in place. The digest lives in the code, so a model
  swap is a version bump and never a silent server-side change.
- **No second consent gate.** The switch already stops and asks, and that
  prompt names the URL and the byte count.
- **We host it**, as a GitHub Release asset beside the existing tarball. 🛑 Hugging
  Face cannot be the source: it hosts PyTorch weights, and converting them
  needs `coremltools` and PyTorch, which is exactly the toolchain that does not
  ship.

## The daemon

- **A switch restarts the daemon.** A switch that leaves it serving the old
  model is a half-switch the user cannot see: the daemon refuses every request
  for the new model, and the client silently falls back to a slower
  out-of-process search.
- 🛑 **When the app owns the socket, the CLI does not restart it.** The app
  unloads the launchd agent when it starts, so the two never both serve, and
  the app is the only process with Full Disk Access. The CLI switches the model
  and says the app serves the old one until it restarts. ⚠️ Running a daemon
  under `sudo` does not help and makes it worse: it loses the user's TCC grants
  and writes root-owned files into a directory the user owns.
