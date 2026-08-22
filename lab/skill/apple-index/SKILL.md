---
name: apple-index
description: Search across ALL of the user's Apple data at once — mail, messages, notes, calendar, contacts and visited places — with one query, and ask where things happened, using a local semantic index (`apple-index`). Use when the user asks for something but does not say which app holds it ("find that thing about the budget", "where did I see the door code", "what do I know about X", "did anyone tell me about Y", "look up that address someone sent me"), when the question is about PROXIMITY ("what was near the dentist", "which of these places are close together", "what else did I do while I was there"), or when a normal `apple` search over one tool has already failed. It searches meaning as well as words, so it finds a note about "Director of Development" from a query about "fundraising". EXPERIMENTAL and read-only.
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
- **Mail, messages, notes and contacts have none at all.**

⚠️ **So "nothing near X" means "nothing INDEXED WITH A COORDINATE is near X".**
It is not evidence the user was not there. Both commands print how many records
they could place, and `--json` reports `placed_records` and `total_records`.
Quote that gap rather than reporting an empty result as an answer.

⚠️ **`--since N` alone means "from N days ago ONWARD"**, and a calendar holds
recurring events years ahead. Add `--past` whenever the question is about what
the user DID.

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
apple-index search QUERY [--limit N] [--tool notes|mail|messages|calendar|contacts|maps]
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
  over a likely tool.
- ⚠️ **Anything added since the last refresh.** Run `refresh` first.
- **Attachment contents.** Never indexed, same as `apple mail`.

## Status

**Experimental.** It lives in `lab/` inside the apple-tools repo and is not part
of the shipped `apple` command. It is read-only: it never writes to Notes, Mail,
Calendar or Contacts.
