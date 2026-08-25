---
name: apple-index
description: Search across ALL of the user's Apple data at once — mail, messages, notes, calendar, contacts, reminders, visited places and their own files (an Obsidian vault, for example) — with one query, and ask where things happened, using a local semantic index (`apple-index`). Use when the user asks for something but does not say which app holds it ("find that thing about the budget", "where did I see the door code", "what do I know about X", "did anyone tell me about Y", "look up that address someone sent me"), when the question is about PROXIMITY ("what was near the dentist", "which of these places are close together", "what else did I do while I was there"), or when a normal `apple` search over one tool has already failed. It searches meaning as well as words, so it finds a note about "Director of Development" from a query about "fundraising". EXPERIMENTAL and read-only.
---

# apple-index

One query across every source, instead of six commands and a manual merge.

```
apple-index search "the greenhouse budget"
```

It combines a keyword search with a semantic one, so it finds records whose
words do not match the query. Results come back in 70 to 300 ms.

## When to use this instead of `apple`

**Use `apple-index` when you do not know which app holds the answer.** That is
the whole reason it exists.

**Use the `apple` tools directly when you do know**, or when you need the full
record. `apple mail search --since 7` is the right tool for "my mail this week".

## Where things happened

`near` lists everything indexed within a radius of a place. `nearby` groups
records that sit close to each other, which is how you answer "which of these
were at the same place".

```
apple-index near "Costco" --radius 2 --past      # what happened near there
apple-index nearby --since 8 --past --radius 0.3 # where I went, and what I did there
apple-index nearby --tool calendar --past --radius 0.5 --min-size 3
```

The value is the JOIN. A visit says the user went to Stem Ciders on 16 August;
the calendar says "Chad bday dinner" was that evening. Neither tool alone puts
those together.

🛑 **ONLY a record that already carries a coordinate can be placed.** Nothing
geocodes a stored location string after the fact — not this index, not
EventKit, not Calendar.app. So:

- **Every `apple maps` record has a coordinate.** All 647 here.
- **A calendar event has one only if it was written with `apple calendar add
  --at`.** Measured on this index: **617 of 11,379 events, 5%.** An event whose
  location was typed as text has none.
- **Mail, messages, notes, contacts and most reminders have none at all.**

## Files, and the Obsidian vault

`files` indexes folders the user has configured, and understands an Obsidian
vault natively: frontmatter, wikilinks and `obsidian://` deep links.

```
apple-index files                    # which folders are indexed
apple-index files add ~/path/vault   # add one
apple-index search "…" --tool files  # search only those files
```

- 🛑 **The FOLDER PATH is the description, and it is stored as `container`.**
  A note in `11 - 🤝 Volunteering/COPTA/LEC/Research` is filed there by the
  user, which is a real fact about it. Nothing writes a description of what a
  folder means, because that is a second thing to keep true and it goes stale.
- **Frontmatter is searchable text.** `type: person` is in the indexed body, so
  "type person directory" finds the people notes. The word "person" appears
  nowhere else in them.
- **A `files` hit carries a real `obsidian://` URL**, which most sources here
  cannot offer. Open it rather than describing the path.
- ⚠️ **A vault loses on volume in an unfiltered search.** 996 files against
  40,455 emails, so a general question tends to surface mail. **Pass `--tool
  files` when the question is about the user's own notes**: "what books have I
  been reading" returns nothing from the vault without it, and returns the
  reading notes with it.

⚠️ **So "nothing near X" means "nothing INDEXED WITH A COORDINATE is near X".**
It is not evidence the user was not there. Both commands print how many records
they could place, and `--json` reports `placed_records` and `total_records`.
Quote that gap rather than reporting an empty result as an answer.

⚠️ **`--since N` alone means "from N days ago ONWARD"**, and a calendar holds
recurring events years ahead. Add `--past` whenever the question is about what
the user DID.

🛑 **A count on a collapsed line counts OCCURRENCES, not records.** `near` and
`nearby` collapse repeats and print `(4 visits)` for maps or `(x105)` for a
recurring event. A maps **place** record is a summary row, not an arrival, so it
is excluded from the count. Before that exclusion the Elks Lodge printed
`(x5)` from 4 visits plus 1 place record, and read as five trips. ⚠️ The count
obeys `--since` / `--past`, so it is "visits in this window", never a lifetime
total. `apple maps places` reports the lifetime figure.

🛑 **A COUNTING QUESTION NEEDS BOTH SOURCES, AND THEY DISAGREE.** "How many
times did we go to the Elks Lodge this summer" has two answers here:

```
apple maps visits --limit 100000 --json   # 4 arrivals: Jun 1, Jun 15, Jun 22, Jul 20
apple calendar events --from … --json     # 7 events at that address
```

Only **two dates appear in both**. Maps has two arrivals with no event, and the
calendar has five dates Maps never recorded.

- ⚠️ **A calendar event is a plan, not an attendance record.** Nothing says the
  user went.
- ⚠️ **Visited Places is not a complete log either.** It is a heuristic and it
  misses arrivals.
- 🛑 **`near` will not surface the calendar side**, because those events carry
  their address as text with no coordinate. Search for the place name as well
  as asking `near`.

**Report the range and name both sources.** Do not pick one and call it the
answer.

⚠️ **`nearby` groups by single link**, so a group can be wider than the radius
through a chain of overlapping pairs. Read `span_km` for the real width.

⚠️ **`near` may make ONE network call.** A place the user has visited resolves
locally from the index and touches nothing. Any other name goes to Apple Maps.
`--local-only` refuses that.

## 🛑 What this index cannot tell you about location

- **How long the user stayed anywhere.** A visit records a start time and
  nothing else. There is no end time in the store. Never report a duration.
- **Where the user was at a given moment.** This is Maps' "Visited Places", not
  Significant Locations. Significant Locations belongs to `routined` under
  `/var/db/locationd/`, which no unprivileged process can read. They are
  different features with different retention. Never report one as the other.
- **Anything about a place with no visit.** A place is a location row that HAS
  a visit.

## 🛑 The index stores ids. Always read the real record.

A hit gives you a `uid`, a `tool` and a native `id`. **Read the record back
through the `apple` tool before you rely on its contents.** The index holds a
copy that can lag, and its snippets are cut short.

```
apple-index search "board minutes" --json     # -> {"tool":"notes","id":"583", ...}
apple notes export 583                        # the truth
```

## Commands

```
apple-index search QUERY [--limit N] [--also "another phrasing"]...
            [--tool notes|mail|messages|calendar|contacts|maps|reminders|files]
                        [--since DAYS] [--json]
apple-index near PLACE  [--radius KM] [--tool T] [--since DAYS] [--past]
                        [--limit N] [--local-only] [--json]
apple-index nearby      [--radius KM] [--tool T] [--kind K] [--since DAYS] [--past]
                        [--min-size N] [--show N] [--json]
apple-index refresh                    # pull in new data (see the warning below)
apple-index status                     # what is indexed
apple-index daemon status              # is the warm process up
apple-index history [--limit N]        # past queries and what they returned
```

`--tool` really does search that one source. It filters INSIDE both
retrieval arms, not after them, so `--tool notes` ranks every note rather than
whichever notes survived a global ranking.

`--json` gives `uid`, `tool`, `kind`, `id`, `url`, `title`, `date`,
`container`, `score`, `similarity`, `snippet`, `from_chunk`, and
`lexical`/`semantic` flags saying which half matched. `kind` is `message`,
`note`, `event`, `contact`, `conversation`, `place` or `visit`, and is the quickest way to read a
result set at a glance.

🛑 **`score` orders results. It is not a confidence value, and no cutoff on it
means anything.** It is a sum of `weight / (60 + rank)` terms, so it encodes
rank position only. Every hit on this index lands between 0.045 and 0.075
whether the answer is there or not.

🛑 **`similarity` is arm coverage, not relevance.** It is `null` when the
semantic half never returned that record, and a cosine otherwise. Do not
threshold on it. Field-tested: on one real query the four WRONG hits scored
0.838 to 0.846 and the single correct hit had `similarity: null`, so any cutoff
drops the right answer first.

⚠️ **Nothing here tells you "no good match exists".** If the results look
wrong, they probably are, and you should fall back to an `apple` search over a
likely tool rather than trusting the top hit.

**It says on stderr when it cut the list**: `showing 10 of 100 results`. Silence
means you have everything. ⚠️ **A list exactly `--limit` long is the shape to
distrust** — read that line, or raise `--limit`, before you tell the user how
many of anything there are.

## 🛑 `--also`: the corpus may not use the user's word

**The people who wrote the records and the person asking are often two
different people, using two different words for one thing.** Measured on this
index: a committee's minutes say "air conditioning" and never once say "HVAC";
the mail thread about the same broken unit says "HVAC" and never says "air
conditioning".

🛑 **Searching one word returns a confident, on-topic, HALF-EMPTY answer.**
`COPTA HVAC` returned five real HVAC emails and looked complete. Six meeting
records on the same subject, going back ten months, were not retrieved at all.
Nothing in the output said so. This is the failure to fear, because it does not
look like a failure.

**`--also` takes another phrasing and fuses the lists.** Repeatable.

```
apple-index search "office HVAC" \
  --also "office air conditioning" \
  --also "rooftop unit repair estimate" --json
```

**Write the alternates yourself, from the question.** You know that HVAC, air
conditioning, furnace and rooftop unit name one thing; the index does not. The
vector arm will not bridge it for you — `HVAC` and `air conditioning` embed at
cosine 0.926, but `HVAC` and `bicycle` embed at 0.800, so the whole usable
range is 0.17 wide and a synonym does not separate from noise.

### ⚠️ Expand a QUESTION. Never expand a keyword lookup.

Measured across the eval suite, by query kind:

| kind | plain | with `--also` | |
|---|---|---|---|
| vocabulary split | 0.562 | **0.667** | expand |
| vault / documents | 0.113 | **0.162** | expand |
| descriptive question | 0.588 | **0.599** | expand |
| **short keyword lookup** | 0.857 | **0.821** | **do not** |
| **"what happened recently"** | 0.833 | **0.800** | **do not** |

Whole suite: MRR 0.535 plain, 0.546 with `--also` everywhere, **0.553** expanding
questions only. hit@10 rises 0.70 to 0.76 — two more answers found at all.

A keyword query is already the right words. Paraphrasing it only adds noise.
Use `--also` when the user asked a question in their own words, and skip it when
they named a thing.

- **Two or three alternates is enough.** Vary the vocabulary, not the grammar —
  "office air conditioning" helps, "what about the office HVAC" does not.
- **Fusion is `max`, and the tool does it.** Do not run several searches and
  merge them yourself: summing ranks sends good hits from rank 1 to a miss.
- ⚠️ **`score` becomes a fused score and `fused_over` appears in the JSON.**
  Do not compare it to a plain search's score.
- 🛑 **It does not help when the answer shares NO word with the question.**
  "where do the kids swim" still will not find "Ocean First". Fall back to an
  `apple` search over a likely tool.

### ⚠️ It fixes retrieval, not rank

On the real question above, `--also` brought all six meeting records back —
**at ranks 26 to 53**, because mail is 81% of the index and fills the head of
the list. So when the question belongs to a particular source, say so:

```
apple-index search "office air conditioning" --tool files --limit 10
```

That put the two right meeting records at **rank 1 and 2**. `--tool` filters
inside both retrieval arms, so a small source is ranked against itself.

## ⚠️ Refresh needs a terminal, and nothing runs it automatically

**`apple-index refresh` only works from a terminal session.** The background
agent that serves searches has no Full Disk Access, so it cannot read Mail,
Notes or Messages. It serves fine; it cannot ingest.

Nothing refreshes on a schedule. **If the user asks about something from the
last few minutes, run `apple-index refresh` first.** It takes about 8 seconds.

`apple-index status` shows the record counts, so you can tell whether a source
looks stale.

## 🛑 The index holds the plaintext of every email

About 105 MB of decoded mail bodies, plus every message, note and contact, in
one unencrypted file. **Never copy results anywhere that leaves the machine.**
Do not paste them into a web request, an issue tracker, or a pull request.

Every search is logged with its results, so a query is not private either.
`apple-index purge --logs-only` clears that log.

## ⚠️ It has no sense of time

**Ranking never reads a date.** A three-year-old record and a three-day-old one
compete on wording alone, and the older one often wins because a long archive
holds more near-misses.

**When the user means something recent, pass `--since`.** It is a filter, so it
does not fight the ranking:

```
apple-index search "board meeting agenda" --since 14
```

Measured: "where is the October board meeting" returned records from 2023, 2025
and 2015, and the correct answer was 5 days old and absent. `--since 14`
surfaced it at once.

## What it is bad at

- ⚠️ **A fact stated only by a name it does not share with the query.** "Where
  do the kids swim" does not find "Ocean First". Fall back to `apple` searches
  over a likely tool. ⚠️ **`--also` does NOT fix this one** — measured, all
  four such cases stay missed however the query is rephrased.
- ⚠️ **A word the corpus spells differently.** Use `--also`; see above.
- ⚠️ **Ranking a small source above mail.** Mail is 81% of the index and fills
  the head of a global list. Use `--tool` when the question belongs somewhere.
- ⚠️ **Enumerating a thread.** It finds a conversation; it does not list every
  message in one. Subject search over one real mail thread returned 5 messages
  and `apple mail search --field content` returned 43. When the question is
  "what do we know about X", use the index to LOCATE and the `apple` tool to
  ENUMERATE.
- ⚠️ **Anything added since the last refresh.** Run `refresh` first.
- **Attachment contents.** Never indexed, same as `apple mail`.

## Status

**Experimental.** It lives in `lab/` inside the apple-tools repo and is not part
of the shipped `apple` command. It is read-only: it never writes to Notes, Mail,
Calendar or Contacts.
