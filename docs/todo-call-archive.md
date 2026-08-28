# Planned: an archive for call history

**Status: scoped, not built.** Every number here was measured on this Mac on
2026-08-28.

## The problem

`CallHistory.storedata` is a **relay mirror of the iPhone, not the whole
history**. Measured: **372 calls over 141 days**, 2026-04-08 to 2026-08-27,
against years on the phone. Old calls fall off the front at about **18.5 per
week**.

Nothing on this Mac keeps them. The `people` report reads calls live and caches
a single overwritten row, so the window it describes slides forward and the
calls behind it are gone.

Three consequences, all measured:

- **109 people have no channel but phone.** Their entire span is a window
  artefact.
- **11 of the 137 people with a phone first-date sat within a fortnight of the
  mirror's edge**, and a spouse of twenty years landed exactly on it. That is
  why `WINDOWED_CHANNELS` now omits a phone first-date entirely.
- The degradation is **silent**. As the window slides, a reported date walks
  forward and nothing says it moved.

## What this would buy

One thing: **the index becomes the only long-term record of call history on
this machine.** Not search — there is nothing to search, and that is settled
below.

## 🛑 The trap that would have corrupted it

**`Z_PK` is recycled, and `apple phone recents --json` reports it as `id`.**

```
Z_PK  1  ->  2026-05-04 20:07
Z_PK  5  ->  2026-04-10 22:22
Z_PK 39  ->  2026-04-08 12:42   (the oldest call in the store)
```

**132 of 372 rows rank differently by primary key than by date.** The store
reuses low keys as old rows age out. An archive keyed on `id` would let a new
call land on a recycled key and **overwrite a different, older call** — silently,
and in the one table whose whole purpose is not to lose anything.

## The key that works

`ZCALLRECORD.ZUNIQUE_ID`, a UUID under a `UNIQUE` index:

```
rows  with_uid  distinct_uid
 372       372           372
```

100% populated, 100% distinct.

⚠️ **`apple phone` does not expose it today.** That is prerequisite one: add
`unique_id` to the `recents` JSON. Nothing else in the repo needs it, so it is
a small, isolated change.

## Design: an archive, not a source

🛑 **Do not make this a ninth `record` source.** Two reasons, both already
measured:

1. **There is nothing to search.** A call's entire text is a name, a number and
   a city — `'Boulder Dental Center (303) 442-5000 Denver, CO'`. **12,969
   characters across all 372 calls**, 35 per call, every one of them already in
   Contacts and already indexed through mail, messages and maps. Searching
   "Boulder Dental Center" today returns three hits without it.
2. **`--full` would eat it.** The weekly sweep deletes any uid the source no
   longer returns. About **5% of the store ages out per week** — comfortably
   under the 20% guard that stops a bad adapter emptying a source, so the
   deletions would look legitimate and the archive would track the same sliding
   window it exists to escape.

A separate `call` table sidesteps both. `cmd_ingest` does not know about it, so
`--full` cannot touch it, and nothing chunks or embeds it.

```sql
CREATE TABLE IF NOT EXISTS call (
  unique_id   TEXT PRIMARY KEY,   -- ZUNIQUE_ID, never Z_PK
  occurred    REAL,
  handle      TEXT,
  contact_id  TEXT,
  name        TEXT,
  status      TEXT,               -- incoming / outgoing / missed
  kind        TEXT,               -- phone / facetime-audio / facetime-video
  duration    REAL,
  connected   INTEGER,
  first_seen  REAL NOT NULL       -- when this archive first saw it
);
```

`INSERT … ON CONFLICT(unique_id) DO NOTHING`. Append-only by construction.

## Who writes it, and when

The `people` report already reads calls live and runs daily under the app. It
is the natural writer: archive on every compute, then read the archive instead
of the live store.

⚠️ **The app must keep running.** If nothing computes the report for longer
than the mirror holds — about 4.6 months — those calls are lost with no way to
notice. Worth a staleness line in the report.

## Bootstrap: what is already gone

The archive would seed with **372 calls back to 2026-04-08**. Everything before
that date is already gone from this Mac and **cannot be recovered** — not by
this feature, not by any other. The archive starts accumulating from the day it
is switched on and is only as good as its age.

That should be said in the report, not just here: a `since` field naming the
archive's own start, so nobody reads a two-month archive as a life history.

## Cost

| Horizon | Calls | Size |
|---|---:|---:|
| 1 year | 962 | 0.3 MB |
| 5 years | 4,810 | 1.3 MB |
| 20 years | 19,240 | 5.0 MB |

262 bytes per call. Against a 776 MB index this is free.

## What changes in the `people` report

- `phone` leaves `WINDOWED_CHANNELS` — but only for spans **inside the
  archive's own window**. A first-date before `archive.since` is still
  unknowable, and must still be omitted rather than clamped.
- `channel_first["phone"]` becomes reportable, qualified by `since`.
- `channel_days` and `channel_spoke_days` for phone stop being capped at 141
  days of history.

## Open questions

- **Corrections.** Append-only means a mis-ingested call can never be fixed,
  only added to. Is `ON CONFLICT DO NOTHING` right, or should a later read
  update the mutable fields (`name`, `contact_id`) while keeping `first_seen`?
  A contact renamed after the call would otherwise keep the old name forever.
- **3 of 372 rows carry no date.** Archive them, or drop them? They cannot be
  placed on a timeline.
- **`apple-index forget` deletes the index.** It would delete the archive with
  it — correct for a privacy command, and catastrophic for the one table that
  cannot be rebuilt. It needs saying out loud in the consent text.
- Does the archive belong in the encrypted vault with the index, or beside it?
  The vault is right for mail plaintext; a call log is less sensitive but not
  nothing.

## What this explicitly does not do

- It does not make calls searchable. See "there is nothing to search".
- It does not recover history from before it was switched on.
- It does not read voicemail. There is none on a Mac — see
  [`apple-phone-store.md`](apple-phone-store.md).
