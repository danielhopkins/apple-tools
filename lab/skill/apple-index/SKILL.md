---
name: apple-index
description: Search across ALL of the user's Apple data at once — mail, messages, notes, calendar and contacts — with one query, using a local semantic index (`apple-index`). Use when the user asks for something but does not say which app holds it ("find that thing about the budget", "where did I see the door code", "what do I know about X", "did anyone tell me about Y", "look up that address someone sent me"), or when a normal `apple` search over one tool has already failed. It searches meaning as well as words, so it finds a note about "Director of Development" from a query about "fundraising". EXPERIMENTAL and read-only.
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
apple-index search QUERY [--limit N] [--tool notes|mail|messages|calendar|contacts]
                        [--since DAYS] [--json]
apple-index refresh                    # pull in new data (see the warning below)
apple-index status                     # what is indexed
apple-index daemon status              # is the warm process up
apple-index history [--limit N]        # past queries and what they returned
```

`--json` gives `uid`, `tool`, `id`, `title`, `date`, `container`, `score`,
`snippet`, and `lexical`/`semantic` flags saying which half matched.

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
