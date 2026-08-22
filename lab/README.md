# lab/ — a semantic index over the apple-tools readers

**Experimental. Nothing here ships.** The root `Makefile` does not build it,
`make test` does not run it, and `make dist` copies named files only, so this
directory stays out of the tarball. Delete it and the tool is unchanged.

## Why it exists

Today an agent answering "find that thing about the budget" runs six commands
and merges the output by hand. The user does not know which app holds the
answer, so every source gets queried. This is an experiment in replacing that
fan-out with one query.

## What it borrows from Apple, and what it cannot

Apple's semantic index is not readable from here. `util/check-spotlight`
measures that: the CoreSpotlight index is per app bundle, a CLI has no bundle,
and both query APIs return **0 items and no error**.

The *design* is readable. macOS 27 ships
`_CoreSpotlight_FoundationModels.framework`, and its `.swiftinterface` spells
out Apple's search tool in public types. Five ideas came from there:

1. **One flat record for every app.** `CSSearchableItem` plus an attribute set.
   Here that is the `record` table.
2. **Content domains map app fields onto shared roles.** Apple's
   `Communications` domain has `authors`, `recipients`, `sent`, `received`,
   `topic`; its `Calendar` domain has `organizer`, `attendees`, `location`,
   `date`. Here every adapter emits the same `people[]` with a `role`.
3. **Matching is hybrid, and each half is a switch.** Apple's `GuidanceProfile`
   carries `textMatch`, `similarityMatch`, `numericMatch`, `dates`, `people`,
   `contentType`, and `CSUserQuery.disableSemanticSearch` has existed since
   macOS 15. Here FTS5 and the vector scan run separately and fuse.
4. **Results carry a score.** Apple's `ScoredSearchableItem`.
5. **Resolving "me" is an injected dependency.** Apple's `ContactResolver`.
   Not built yet. See "Not done".

Apple's embedding model, its ranker and Private Cloud Compute stay out of
reach.

## Layout

```
index.py          the driver: ingest, chunk, FTS5, fusion, output. Stdlib only.
vec/              Swift: the embedding model and the dot products.
Makefile          build, demo, clean
index.db          created by `./index.py init`. Not committed.
```

**The two halves split on one line.** `vec` owns the `vector` table and nothing
else. Python owns the rest of the schema. They meet only through `chunk.cid`.

`vec` exists because the system `python3` has no numpy, so scoring 290k vectors
in Python would be far too slow. It uses Accelerate.

## The boundary with apple-tools

`index.py` calls the installed `apple` CLI as a subprocess and reads `--json`.
It shares no code with `swift/` or `notes/`. Three consequences:

1. The main tool needs no change.
2. The readers stay the single source of truth.
3. **The index stores ids. It never replaces the reader.** A hit gives you a
   `uid` and a `native_id`; read the record back with `apple <tool> export`.
   A stale body in the index must never become the answer.

## Running it

```
make build                                  # build vec
./index.py init
./index.py ingest --source notes --limit 40
./index.py embed
./index.py search "where can I take the kids to play outside"
```

`make demo` runs exactly that.

Sources: `notes`, `mail`, `messages`, `calendar`, `contacts`, `maps`. Pass
several with `--source notes,calendar`.

## Geography

Two commands ask where things happened, rather than what they say.

```
./index.py near "Costco" --radius 2 --past
./index.py nearby --since 8 --past --radius 0.3
```

`near` lists everything within a radius of a place. `nearby` groups records
that sit close to each other. The value is the join across sources: a maps
visit says the user went to Stem Ciders on 16 August, and the calendar says
"Chad bday dinner" was that evening. Neither tool alone puts those together.

🛑 **Only a record that already carries a coordinate can be placed, and nothing
geocodes a location string after the fact.** Not this index, not EventKit, not
Calendar.app. That is why `apple calendar --at` exists: it resolves the place
at WRITE time, because nothing can do it later.

| Source | Records | Placeable |
|---|---|---|
| maps places | 197 | 197 |
| maps visits | 450 | 450 |
| calendar events | 11,379 | **617 (5%)** |
| mail, messages, notes, contacts | 47,852 | 0 |

⚠️ **So "nothing near X" means "nothing indexed with a coordinate is near X".**
It is never evidence the user was not there. Both commands print the gap, and
`--json` carries `placed_records` and `total_records`.

🛑 **A maps VISIT is deliberately not chunked, and this was measured.** Its
title and body are copied from the place it is a visit to, so 37 arrivals at
one gym become 37 identical chunks. Adding maps to the index sent the eval case
"Frequent Flyers address" from rank 1 to a miss, because the top ten filled
with visits that do not carry the address the question asks for. The place
record answers every text question; a visit carries a date and a coordinate,
which `near` and `nearby` read off the record directly.

🛑 **`near` collapsed nothing, so `--limit` hid the real neighbours.** A field
tester computed the separations independently and asked for
`near "Ocean First" --radius 1`. It returned 50 rows, every one of them true,
and **dropped two places 0.585 km and 0.705 km away** — because 50 occurrences
of one weekly class sit at 0.000 km and filled every slot. **The output looked
correct.** `near` now collapses on (tool, title) BEFORE applying the limit and
prints `(xN)`.

🛑 **A count on a collapsed line counts occurrences, not records.** A maps
**place** row summarises other rows, so counting it inflates every visit tally
by exactly one. The Elks Lodge printed `(x5)` from 4 visits plus 1 place record
and read as five trips. `near` and `nearby` now exclude it and label the number:
`(4 visits)` for maps, `(x105)` for a recurring event. Verified against
`apple maps places`: Ocean First 30, Deli Zone 2, Elks Lodge 4.

🛑 **A counting question needs both sources, and they disagree.** "How many
times did we go to the Elks Lodge this summer" gets **4** from maps arrivals and
**7** from calendar events at that address. Only two dates appear in both. A
calendar event is a plan, not an attendance record; Visited Places is a
heuristic that misses arrivals. Report the range and name both sources.

⚠️ **A shared street address is not a shared coordinate.** "Village Shopping
Center Boulder" and "Epic Mountain Gear" both read `2525 Arapahoe Avenue`, and
Apple pins them **110 m apart**. A test written from the addresses expected them
inside `--radius 0.1` and they are not. Trust the coordinate, never the address
string.

⚠️ **A visit has a start time and NOTHING ELSE.** There is no end time in the
store, so this index cannot say how long the user stayed anywhere.

⚠️ **This is Maps' "Visited Places", not Significant Locations.** Significant
Locations belongs to `routined` under `/var/db/locationd/`, which no
unprivileged process can read. Never report one as the other.

## Measurements

All on macOS 27.0 (26A5416b), M-series, 14 cores.

**Checking for new data is nearly free.**

| Store | Watermark query | Time |
|---|---|---|
| `chat.db` | `MAX(ROWID)` → 104,239 | 0.01s |
| `Envelope Index` | `MAX(ROWID)` → 113,011 over 41,827 messages | 0.02s |
| `NoteStore.sqlite` | `MAX(ZMODIFICATIONDATE1)` | 0.08s |

So a full "did anything change" sweep costs about 0.1s. **A daemon is not
needed to start.** `search` can catch up first, and a poll every five minutes
costs nothing.

**Embedding is the expensive half, and the rate depends on chunk length.**

| Input | Rate |
|---|---|
| a 180-word paragraph | 24.5 ms/chunk, **41 chunks/sec** |
| real note chunks (143 of them) | 13.9 ms/chunk, **71.9 chunks/sec** |

Both numbers are single-threaded. **Parallel scaling is not measured.** The
process already ran at 125% CPU, so eight workers will not give eight times the
rate. At 41 chunks/sec a 290k-chunk first build takes about two hours.

**Storage.** Vectors are int8: L2-normalised, scaled by 127. That is 512 bytes
per chunk. Each row records which model produced it, because two models do not
share a vector space and scoring across both returns confident nonsense.

## The model

**`intfloat/e5-small-v2`**, adopted after measuring six candidates. MRR 0.786,
661 MB resident, 9 minutes to index the corpus. The full comparison, the
prefixes each model needs, and the two wrong turns are in
[MODELS.md](MODELS.md).

## 🛑 The model: I picked the wrong one, and retrieval hid it

The first version used `NLContextualEmbedding` with mean-pooled token vectors.
It retrieved badly, and nothing showed that until a real question exposed it:
*"what is the HOA code for the bathroom door?"*. Six phrasings all missed the
note. A SQL `LIKE` found it in one try.

Measured directly, for the query "bathroom code":

| text | NLContextual (cosine) | NLEmbedding.sentence (distance, lower = closer) |
|---|---|---|
| the bathroom door code | 0.9461 | **0.4123** |
| Bathroom code | 0.9735 | 0.5466 |
| Bathroom code 3384 | 0.8173 | 0.8082 |
| Hub open house | 0.8977 | 1.0763 |
| Showroom appointment | 0.8955 | 1.1046 |
| Junkyard social | **0.9020** | 1.1674 |

🛑 **Under NLContextual, "Junkyard social" beat the literal answer.** The
sentence model ordered every candidate correctly.

⚠️ **Mean-centering the vectors did NOT fix it**, so this is not the usual
anisotropy problem. Apple documents `NLContextualEmbedding` as a **feature
layer** for training a model with CreateML. Pooling its token vectors and
comparing them by cosine is a use it was never built for.

The reasoning that chose it was "the sentence model is static, so a word gets
the same vector regardless of its sentence". That is a fact about the model's
design, not a measurement of retrieval quality, and it was the wrong basis for
the decision.

`vec --model sentence|contextual` selects one. `sentence` is the default. The
sentence model is also **4× faster on short text**.

## Chunking

🛑 **A fixed-width window buries a short answer.** "Bathroom code 3384" sat one
line inside a 900-character window of unrelated HOA text. Mean-pooling that
diluted it until nothing found it.

Three changes took that chunk from 900 characters to **82**:

1. **Split on structure**, not width: headings and blank lines. Blocks are
   packed only while they share a heading and stay under 420 characters.
2. **Strip URLs.** 145 of the first 213 characters were an `applenotes://` link
   with a UUID in it. The signal was outnumbered 2 to 1 by a meaningless string.
3. **Drop repeated breadcrumbs.** A note whose first heading equals its title
   produced "X > X > Research".

⚠️ **Strip quoted reply text from mail.** 95,097 of 251,127 mail chunks carried
it, and a reply chain repeats the same paragraph once per level. One thread here
held the same sentence at five quote depths. Removing them cut mail 18%.

**`./index.py rechunk` rebuilds chunks from the bodies already stored**, so
changing the chunker costs 4.9 seconds rather than re-fetching 40,351 mail
bodies.

**The vector arm earns its place.** Query: *"where can I take the kids to play
outside"*. The lexical arm in `and` mode returns nothing useful. The vector arm
puts a note titled **"Park notes"** first, and that note contains no word from
the query.

## Findings from the first runs

Recorded here so nobody re-derives them.

- 🛑 **A recurring calendar event returns the same series id for every
  occurrence.** 30 events produced 4 uid collisions. The `occurrence` field is
  what separates them, so the uid is `calendar:<id>@<occurrence>`.
- ⚠️ **`apple mail search` can return the same `(id, account, mailbox)` twice.**
  Measured: 150 rows, 148 distinct, one Google DMARC message duplicated inside
  a single mailbox. This is Mail's index, not a bug in the reader. The `rev`
  check absorbs it, so no fix was applied.
- ⚠️ **A Message-ID alone is not unique across mailboxes**, so the mail uid
  carries the account and mailbox too.
- 🛑 **`apple mail search` with no `--limit` returns 20 rows, not everything.**
  The adapter passed no limit and meant "all". Combined with `--full` that
  deleted 128 indexed records and printed it as reconciliation. The adapter now
  asks for `1000000` explicitly.
- 🛑 **A source answering with a slice looks exactly like a source whose records
  were deleted.** `--full` now refuses to delete more than 20% of a tool's
  records and names the shortfall. `--force` overrides it. ⚠️ **That guard is
  not yet exercised by a test.**
- 🛑 **Changing a uid scheme silently doubles the index.** Old rows keep their
  old uid and nothing matches them. Ingest is not a migration. After any change
  to how a uid is built, delete `index.db` or run `ingest --full`.
- 🛑 **`subprocess.run(capture_output=True)` holds a child's progress output
  until the child exits.** `embed` looked silent for 60 minutes on a 223k-chunk
  run, and a log monitor watching for progress reported nothing. `cmd_embed`
  now lets stderr inherit, so it streams. Silence is not the same as stalled,
  and neither is visible from the outside.
- 🛑 **A WAL database cannot be opened with `SQLITE_OPEN_READONLY` when no
  `-shm` file exists.** A reader has to create that file, and a read-only
  handle cannot, so `vec search` failed with "unable to open database file".
  ⚠️ **It worked when driven through `index.py`**, because Python opened the
  database read-write first and left the `-shm` behind. So the bug was
  invisible from the normal path and only appeared when `vec` ran alone. It now
  opens read-write and sets `PRAGMA query_only = 1`.
- 🛑 **`cmd_search` discarded the embedder's stderr on success**, so `--verbose`
  showed nothing and a failing vector arm would have looked like "no semantic
  matches". Fixed.
- 🛑 **`--tool` was a POST-FILTER, so it did not search one source.** It ran
  after fusion, over candidates ranked globally, so `--tool notes --limit 30`
  returned **4 rows** out of 681 notes. On an index that is 68% mail, one
  source's records barely survive a global ranking. The filter now runs inside
  **both** arms: the lexical arm joins `record` in SQL, and the vector arm
  masks the matrix before scoring. The same query now returns 30. ⚠️ The
  post-filter is still there as a backstop, because an OLDER daemon ignores the
  `tool` key and answers globally.
- 🛑 **Widening the candidate pool fixes nothing, and I predicted it would.** I
  told a field tester that three failing cases would be fixed by a deeper pool.
  Measured across pools of 60, 120, 200, 300 and 500: **hit@1, hit@3, hit@10
  and MRR are identical at every size.** The correct records already sat at
  global semantic ranks 16, 4 and 1. They lose at FUSION, not at retrieval
  depth. `--pool` exists now so the next person can re-measure this in one
  command instead of believing me.
- ⚠️ **A query with several correct answers cannot be anchored on one of
  them.** "what is the garage door code" was anchored on a 2026 message where
  the code is incidental. A field test retrieved a 2022 message that states the
  code plainly, at rank 1, and the eval scored it a MISS. This is the second
  time a wrong label made a correct answer look like a failure. The locator now
  accepts any of the 7 records that state it.
- 🛑 **`--min-chunk` fixes the case it was built for and loses overall.** A bare
  calendar title "Hair cut" scores 0.869 against "where do I get my hair cut",
  beating "Welcome Stranger Barber Shop" at 0.848 — and the calendar events
  carry no location, so they do not answer the question. Scaling short chunks
  down fixes that one case. Measured on 29 cases: MRR **0.586 -> 0.530** at 20,
  0.540 at 60, 0.459 at 100. Shipped at 0, with the sweep left in `eval.py`.
- 🛑 **A source that is 0.17% of the index gets buried, however well it
  matches.** `maps` is 394 chunks of 237,971. "where do I get my hair cut" puts
  the right barber shop at semantic rank **1 within maps** and **outside the
  global top 60**. `--tool maps` finds it instantly. Nothing else does.
- ⚠️ **A case was WITHDRAWN, not re-anchored**: "did I send anyone my home
  address". The address appears in dozens of messages, so the query has no
  single correct answer and MRR against it measures nothing. Deleting a bad
  case is better than averaging over it.
- **Embedding runs faster than the paragraph benchmark on real data**: 58 to 83
  chunks/sec across notes, mail, calendar and messages, against 41 on a
  180-word paragraph. Short chunks are cheap.

## Design choices worth arguing with

These are the experiment. Change them and see what happens.

- **Messages are indexed in blocks, not one per message.** One SMS is too short
  to embed well. `--message-block 10` sets the window. This is the single
  biggest open question in the ingest path.
- **The lexical arm defaults to `OR`, not `AND`.** `apple mail search` ANDs.
  Here fusion re-ranks afterwards, so the lexical arm should favour recall.
  `--fts-mode and` switches it back.
- **The title gets its own chunk**, and it is also prefixed onto every body
  chunk so a mid-body window keeps its subject.
- **Reciprocal Rank Fusion with k=60.** No weighting between the two arms yet.
- **bm25 column weights are 4.0 title, 1.0 body, 2.0 people.** Guessed, not
  measured.
- **Blocks pack to 420 characters and split on structure.** A block longer
  than 900 characters still gets a sliding window, because a wall of prose has
  no structure to split on.

## Not done

- **A people resolver.** Handles are phone numbers and emails, never names.
  Apple injects a `ContactResolver`. Until that exists here, "what did Sarah
  say" only works when the name appears in the text.
- **Watermarks.** `source_state` has the column and nothing writes it. Ingest
  re-reads everything and skips unchanged records by `rev` hash. That is
  correct but not cheap.
- **Deletion detection** only runs with `--full`, which does a full id-set
  sweep. There is no incremental path.
- **URLs.** Only mail and contacts emit one. `docs/todo-deep-links.md` is the
  prerequisite.
- **Chunk texts are not deduplicated.** 42,322 of 239,056 chunks (18%) are
  exact duplicates, mostly recurring calendar events: "Margot Daycare" appears
  460 times. Keying vectors by a content hash instead of a chunk id would save
  18% of the embed time and storage. This is the next improvement.
- **No daemon.** See the measurements above for why that is a deliberate order,
  not an omission. When one is added it must be **two** processes: the
  disclaiming tools (calendar, contacts, reminders) lose Full Disk Access, so
  they cannot share a process with the tools that need it.
- **Mail bodies are opt-in** (`--with-bodies`) because they cost one subprocess
  per message.
