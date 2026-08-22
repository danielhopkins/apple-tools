# Incremental update signals, measured per source

An index is only as good as its change detection. A signal that misses a change
leaves a stale answer in place, and nothing downstream can tell.

Measured on macOS 27.0 (26A5416b) against a real store: 59,000 records,
223,556 chunks.

## Summary

| Source | Change signal | No-change run | Was | Speedup |
|---|---|---|---|---|
| notes | `NoteStore.ZMODIFICATIONDATE1` | **0.1s** | 45s | 450× |
| messages | `last_message` + `message_count` from the chat listing | **0.2s** | 37s | 185× |
| mail | full headers from one call | **0.9s** | 38 min | 2500× |
| contacts | `AddressBook.ZMODIFICATIONDATE` | **1.5s** | 331s | 220× |
| calendar | full records from one call | **3.1s** | — | — |

**Every source has a reliable, cheap change signal.** An earlier version of this
file said contacts had none. That was wrong, and the correction is the most
useful thing in here.

## 🛑 The mistake: `immutable=1` does not replay the write-ahead log

I concluded, in writing, that contacts had no change signal at all. The
evidence looked airtight:

```
before edit:  707 rows, max mod 2026-08-21 18:09:41
apple contacts edit <id> --company "Marmalade Hovercraft Repair Guild"
  -> Updated '__claude_contacts_test__ Zorblatt'
after edit:   707 rows, max mod 2026-08-21 18:09:41
```

The timestamp did not move. The edited contact was not in the file at all. I
wrote that the store lags the live data by an unbounded amount.

**Every one of those queries used `?immutable=1`.** Both stores run in WAL mode
with a multi-megabyte log, and `immutable=1` does not replay it. The same
query, at the same moment, one flag apart:

```
immutable=1 : 707 rows, max mod 2026-08-21 18:09:41   (2.9 hours stale)
mode=ro     : 706 rows, max mod 2026-08-21 20:33:45   (30 min ago)
```

Redone correctly, the signal is immediate and per-record:

```
BEFORE create : 706 rows | max mod 20:33:45
AFTER create  : 707 rows | max mod 21:03:29   <- moved
AFTER edit    : 707 rows | max mod 21:03:32   <- moved again
row: __claude_index_test__ | mod=21:03:32 | org=Marmalade Hovercraft Repair Guild
```

Three things this cost, worth naming:

1. **The trap was already written down.** `CLAUDE.md` lists "the write-ahead log
   that `immutable=1` will not replay" among the phone store traps. Knowing a
   trap is not the same as checking for it.
2. **A wrong measurement reads exactly like a right one.** Nothing about the
   stale answer looked stale. It returned a plausible row count and a plausible
   timestamp.
3. **The user caught it, not the test.** The objection was "that data syncs to
   the cloud, and there's no way they're sending it all". Sync requires change
   tracking, so "no change signal" was implausible on its face. **Reason about
   whether a finding is plausible before writing it down.**

🛑 **Never open one of these stores with `immutable=1` to ask a question about
current state.** Use `?mode=ro`, which replays the log.

## Per source

### notes — `ZMODIFICATIONDATE1`, 0.1s

`apple notes search` returns an id and a title only. `NoteStore.sqlite` carries
a per-note modification date; 681 rows have one, for 680 notes. The revision
comes from the store, and the body export runs only for a note that changed.

### messages — the chat listing already carries a revision, 0.2s

🛑 **No store read is needed here at all.** `apple messages chats --json`
already returns `last_message` and `message_count` for every chat, which
identify a chat's state. One call describes all 1,331 chats in 0.15s;
exporting each costs 0.03s, or 40s for the lot.

⚠️ **475 of 1,331 chats hold zero messages.** They were each costing a
subprocess and returning nothing. They are skipped outright.

A per-chat revision lives in the `cursor` table, written only after every block
of that chat has been committed. A crash mid-chat leaves the cursor unset, so
the next run re-exports rather than skipping.

### mail — the headers are the revision, 0.9s

`apple mail search` returns subject, sender, date and mailbox for all 40,662
messages in **0.46s**, as 15.7 MB of JSON. A delivered message's body never
changes, so the headers identify a revision on their own.

🛑 **A revision hash must not depend on an expensive field.** Mail's revision
once included the body length, so the change check could not run until every
body had been exported: 38 minutes to discover that nothing had changed.

### contacts — `ZMODIFICATIONDATE`, 1.5s

`apple contacts list` returns an id and a name only, and a change to a company,
title, note or email leaves the name byte-identical. The AddressBook store
carries a per-record modification date, and `ZUNIQUEID` matches the CLI's
`UUID:ABPerson` id exactly. 724 of 727 rows carry both.

One `apple contacts get` costs 0.44s, of which only 0.07s is CPU; the rest is
process start, the disclaim re-exec, and the XPC wait. Skipping the unchanged
ones removes 686 of those calls.

### calendar — one call, 3.1s

`apple calendar events` returns every field for all 11,374 events in one call.
Nothing extra is needed.

## Reaching past the CLI

Notes and contacts are the only places this lab reads a store directly, and it
reads **nothing but the id and the modification date**. Everything else still
comes through `apple <tool> --json`.

**The right long-term fix is a `--modified-since` flag on the CLI**, which
would remove the need for this file to know any schema.

## The convergence test, and the bug it exists to catch

🛑 **A source can return the same uid more than once with different field
values.** Each run then writes one row's revision, and the next run computes
the other row's revision, sees a mismatch, and "updates" it back.

Measured on mail: **194 Message-IDs appear several times in one mailbox with
different received dates** — the same Google DMARC report delivered three
times. The result was **474 records reported as changed on every single run,
forever**, and 26 seconds of wasted body exports each time.

Nothing about that looks wrong from the outside. The run finishes, the counts
are plausible, and the index is correct. Only running the ingest twice and
comparing exposes it.

`test-incremental.py` runs every source **twice** and requires the second run
to report `+0 ~0 -0`. First occurrence of a uid wins, and the count of skipped
duplicates is printed rather than hidden.

⚠️ **The budget is per source.** One shared 400s threshold once let contacts
pass at 331s beside mail at 0.9s, and printed it as "cheap". A test that passes
the thing it exists to catch is worse than no test.

## 🛑 Do not put Markdown in a test fixture's name

The fixture marker was `__claude_index_test__`. `__text__` is Markdown bold,
and the Notes write path converts Markdown, so a note created with that title
is **stored** as `claude_index_test ...`.

`apple notes append` matches the note by *Name* through Shortcuts. The stored
name no longer equalled the string passed, so it matched nothing, and
**Shortcuts opened a picker and waited for a human** — which would have written
the body into whatever note they chose. It interrupted the user mid-session.

The marker is now `CLAUDE-INDEX-TEST`: letters, digits and hyphens only.

## Other traps already fixed

- 🛑 **Changing a revision formula makes every record look modified**, exactly
  like changing a uid. `migrate-mail-rev.py` rewrote 38,376 revisions in 8.4s
  from one header call, instead of re-exporting 41,000 bodies.
- 🛑 **A WAL database cannot be opened `SQLITE_OPEN_READONLY` when no `-shm`
  file exists.** `vec search` failed alone and worked through `index.py`, which
  had already created the `-shm`. It now opens read-write with
  `PRAGMA query_only = 1`.
