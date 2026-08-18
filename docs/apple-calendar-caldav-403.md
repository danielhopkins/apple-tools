# `add` reports success for a write the server rejected

**Status:** open bug in `apple-calendar add` / `edit`. Reproduced 2026-08-18.
**Severity:** high. The tool tells the caller an event exists when it does not.

## The failure

`apple-calendar add` returns a full, populated JSON event record — id, calendar,
start, end, geo — for a write that the CalDAV server refuses with **HTTP 403**.
The event lands in the local EventKit store and never reaches the server.

macOS Calendar.app surfaces the failure hours later, as a modal:

> Your event couldn't be refreshed.
> Access to "BVSD Board of Education Worksession" in "Family" in account
> "Google" is not permitted.

By then the caller has already told the user the event is on their calendar.

## Reproduction (2026-08-18, Google CalDAV, account `danielhopkins@gmail.com`)

```
08:58:02  apple calendar add "BVSD Board of Education Worksession" \
            --start "2026-08-25 15:00" --end "2026-08-25 17:00" \
            --calendar Family --at "6500 Arapahoe Rd, Boulder, CO 80303" \
            --url "https://www.bvsd.org/..." --notes "..." --json
          → exit 0, full JSON record returned, no warning
```

Server state afterwards, via the Google Calendar API:

```
gws calendar events list --params '{"calendarId":"0cu7...@group.calendar.google.com",
  "timeMin":"2026-08-25T00:00:00-06:00","timeMax":"2026-08-26T00:00:00-06:00",
  "singleEvents":true}'
→ Steph Spanish, Organo-Lawn.  The BVSD event is absent.
```

Two independent local signals contradicted the tool's own success report.

### Signal 1 — the `Error` table

```sql
-- ~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb
SELECT e.ROWID, e.error_code, e.store_owner_id, e.calendar_owner_id,
       e.calendaritem_owner_id, ci.summary, c.title
FROM Error e
LEFT JOIN CalendarItem ci ON ci.ROWID = e.calendaritem_owner_id
LEFT JOIN Calendar c      ON c.ROWID  = ci.calendar_id;
```

`user_info` is an `NSKeyedArchiver` plist. Decode it:

```python
import sqlite3, plistlib, os
db = os.path.expanduser("~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb")
c  = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
b  = c.execute("SELECT user_info FROM Error WHERE ROWID=?", (rid,)).fetchone()[0]
p  = plistlib.loads(b)
for o in p["$objects"]:
    if isinstance(o, dict) and "NSCode" in o:
        print(o["NSCode"])          # 403
```

Observed:

```
NSCode  = 403
NSDomain = CoreDAVHTTPStatusErrorDomain
```

`error_code` names the scope of the failure, and all three scopes appeared:

| `error_code` | populated column | meaning |
|---|---|---|
| 3 | `calendaritem_owner_id` | one event failed to push |
| 4 | `calendar_owner_id` | the whole calendar failed to sync |
| 5 | `store_owner_id` | the whole account failed to sync |

### Signal 2 — an empty `external_mod_tag`

`CalendarItem.external_mod_tag` holds the server ETag. **Empty means the server
never stored the item.** This is the cheapest possible check.

```sql
SELECT ci.ROWID, ci.summary, c.title,
       CASE WHEN ci.external_mod_tag IS NULL OR ci.external_mod_tag = ''
            THEN 'NOT SYNCED' ELSE 'synced' END
FROM CalendarItem ci JOIN Calendar c ON c.ROWID = ci.calendar_id
WHERE ci.ROWID = ?;
```

Caveat: recurrence exceptions also carry an empty `external_mod_tag` under
normal operation, so treat empty as authoritative only for a newly created
non-recurring event, and pair it with the `Error` table.

## What the cause is NOT

I chased two wrong theories. Both are worth recording so nobody repeats them.

**Not a permission problem.** `EKCalendar.allowsContentModifications` reported
`true`, and it was telling the truth. The Google API confirms the account is an
**owner** of the calendar:

```
gws calendar calendarList get --params '{"calendarId":"0cu7...@group.calendar.google.com"}'
→ {"accessRole": "owner", "dataOwner": "bouldersteph@gmail.com", "summary": "Family"}
```

**Not calendar-specific.** A minimal control event written to the user's own
primary calendar (`Personal`, same store id 6) failed with the same 403. An
`error_code = 5` row named the store itself.

## What the cause IS: an intermittent 403, plus no retry

Two minimal probes went out seconds apart, to two calendars in the same account:

| probe | calendar | result |
|---|---|---|
| `__claude_probe_family__` | Family | **synced** after a retry, confirmed present on Google |
| `__claude_probe_personal__` | Personal | 403, stuck, never retried |

Same account, same credential, same minute, opposite outcomes. The 403 is
transient. This is consistent with Google CalDAV rate limiting, which returns a
bare 403 that CoreDAV does not distinguish from a real authorization denial.

**The damaging part is the recovery behavior.** Once EventKit writes an `Error`
row for an item, it stops retrying that item and shows the modal instead. The
item stays in the local store forever, visible in Calendar.app and returned by
`apple-calendar events`, while absent from the server. `add` has no way to
notice because it returns long before the sync attempt happens.

The write also cannot be repaired in place. Deleting the local copy and writing
the event server-side through the Google API was the only route that worked.

## Requested changes

1. **`add` and `edit` must not report bare success.** The push is asynchronous.
   At minimum, print a warning that the write is not yet confirmed on the server.
2. **Add a `--confirm-sync` flag** (or make it the default). After the write,
   poll `external_mod_tag` for the new item until it is non-empty, and poll the
   `Error` table for a row naming that item, its calendar, or its store. Give up
   after a bounded wait and report the real outcome. A 403 must exit non-zero.
3. **Add an `apple-calendar sync-errors` subcommand.** It should decode the
   `Error` table, resolve `store_owner_id` / `calendar_owner_id` /
   `calendaritem_owner_id` to names, and print the `NSCode` and domain. Right now
   this needs hand-written SQL plus a plist decode, which is why the failure went
   undiagnosed for an hour.
4. **Consider a `--retry` or `repair` path** that clears the stuck `Error` row and
   re-pushes, so the local copy does not have to be deleted and rebuilt elsewhere.
5. **Document the ETag check** in the calendar docs, so callers verifying an
   outward-facing write know where to look.

## Related

The same class of bug is already recorded for invitations. `apple-calendar
invite` reports success against Exchange, passes a fresh-store read-back, and
reverts minutes later. The lesson generalizes: **the local EventKit store is not
evidence that a write reached the server, in either direction.** Verify against
a second, independent signal — the ETag, the `Error` table, or the server's own
API.

---

# Second failure mode: the local copy is deleted, with no `Error` row

**Observed 2026-08-18, same day, different session.** Google CalDAV,
calendar `Columbine PTA Shared` (owned by `columbineptaboulder@gmail.com`,
shared into `danielhopkins@gmail.com`, store id 6).

The section above describes a write that **sticks locally and never reaches the
server**, leaving an `Error` row behind. This is the opposite outcome from the
same root cause, and a caller cannot tell them apart at write time.

## What happened

A script created 22 events on one calendar in a single burst, one
`apple-calendar add` process each, over roughly 25 seconds. Every call exited 0
and returned a full JSON record. A read-back seconds later returned all 22.

**Three synced. Nineteen were gone within minutes** — not stuck, *gone*. The ids
`add` had returned now failed:

```
$ apple calendar show "F290AE57-...:6FC52EE1-..."
Error: no event with id 'F290AE57-...:6FC52EE1-...'
```

They were not moved to another calendar. A search across all 14 calendars for the
date range found nothing.

**The `Error` table was empty.** No 403, no `error_code` 3/4/5 row, nothing to
decode. So the diagnostic path documented above finds nothing in this mode, and
the only trace is the absence of the item.

Survivors were creation positions 1, 11, and 16 of 22 — no pattern in content,
shape, or spacing.

## `external_id` is easier to read, but carries the SAME caveat

`CalendarItem.external_id` holds the server's `.ics` URL. Like the ETag, it is
empty until the server accepts the item:

```sql
SELECT summary,
       CASE WHEN external_id IS NULL OR external_id = ''
            THEN 'PENDING' ELSE 'SYNCED' END
FROM CalendarItem
WHERE calendar_id = ? AND orig_item_id = 0;   -- normal items only; see below
```

⚠️ **An earlier draft of this section claimed `external_id` escapes the
recurrence-exception caveat above. That was wrong.** Corrected 2026-08-18 after
the apple-tools session measured the whole store:

```
store type | store  | kind     | external_id | rows
2 (CalDAV) | Google | normal   | set         | 6352
2 (CalDAV) | Google | detached | EMPTY       |  329
2 (CalDAV) | Google | detached | set         |    1
1 (EAS)    | 🏫     | detached | set         |   23
```

**329 of 330 detached occurrences on Google CalDAV have an empty `external_id`,
and every one is a healthy, long-synced item.** A bare "empty means unsynced"
check flags all 329 on this machine alone.

**The caveat is backend-specific**, which neither column's documentation says.
Exchange populates `external_id` on all 23 of its detached occurrences. Google
CalDAV populates it on 1 of 330. So the hole is in the same place as
`external_mod_tag`'s, on the backend that actually failed here.

**What survives:** for **normal** items on Google the column is 6352/6352
populated, so absence really is diagnostic. Any check must therefore either
exclude detached occurrences (keep only `orig_item_id = 0`) or restrict itself to newly
created non-recurring events — exactly the constraint already placed on
`external_mod_tag`. With that filter `external_id` is still the easier column to
read, and it is the one signal present in both failure modes.

⚠️ **`external_id` is not a discriminator between the two failure modes.** Its
presence tracks backend and item kind generally, so it separates Exchange from
Google whether or not anything failed. See **What actually discriminates** below.

🛑 **`orig_item_id` is `0` for a normal item, not `NULL`.** Testing
`orig_item_id IS NOT NULL` reports every item as detached.

⚠️ **Join `Store` before drawing conclusions.** The clean pairing of
`status`/`external_id`/`external_mod_tag` holds only for CalDAV events. 1120
rows store-wide have `external_id` set, `external_mod_tag` empty and `status`
0 — Reminders (835), Exchange (165), Subscribed Calendars (120). A query with no
`Store` join picks all of them up.

🛑 **Read the live database read-only. Do not `cp` it first.** A file copy misses
whatever is still in the WAL, so a freshly written item reads as `ABSENT` and an
already-synced one reads as `PENDING`. This produced two rounds of wrong
conclusions here before it was caught.

```python
sqlite3.connect("file:%s?mode=ro" % db, uri=True)   # correct
```

This is not a new trap. The repo already documents it for the AddressBook stores
and for MapsSync, with the same rule: open plain read-only first, and reach for
`immutable=1` only as a fallback, because both a `cp` and an immutable open miss
the WAL and go stale in either direction.

## Measurements

Every number below is from this machine, this account, 2026-08-18.

**Push latency is about 4 seconds.** Six trials, local create to
`external_id` populated, polled every 2s:

| arm | trials | result |
|---|---|---|
| write only | 3 | SYNCED at 4s, 4s, 4s |
| write, then `reload calendars` | 3 | SYNCED at 4s, 4s, 4s |

So a `--confirm-sync` poll needs a very short budget. **30 seconds is generous**;
anything still pending after that is a real failure, not slowness.

⚠️ **That number is the push path only, and `--confirm-sync` should not
generalize it.** The pull direction is far slower: an event created server-side
through the Google API took **over two minutes** to appear in the local store,
observed the same day. Confirming a *local* write can budget 30s. Waiting for an
event that originated on the server needs minutes, and the two must not share a
timeout.

**A manual sync trigger neither helps nor harms.**

```bash
osascript -e 'tell application "Calendar" to reload calendars'
```

It exits 0 and does not require Calendar.app to be running. It gave **no
speedup** (table above). It also **does not wipe pending writes**: five events
were created and a reload fired while all five were still `PENDING`; all five
survived and synced.

**The failure is not content-dependent.** 33 probe events across six batches all
synced, covering every shape the lost events had:

| shape tested | result |
|---|---|
| bare timed event, 5 written back to back | 5/5 synced |
| bare timed event, 3 written 25s apart | 3/3 synced |
| location + notes | synced |
| multi-day all-day (`--start` … `--end` … `--all-day`) | synced |
| `&` in the title | synced |
| email addresses in `--notes` | synced |
| two events sharing one title | 2/2 synced |

**The failure did not reproduce.** 33 of 33 probes synced. Only the original
22-event burst lost anything. This matches the "intermittent" finding above and
argues against pacing as a fix — the paced arm has no advantage.

**Retry converges.** Re-adding the 19 missing events, waiting, re-reading, and
re-adding whatever was still absent brought the calendar to 22/22, each with a
populated `external_id` and `external_mod_tag`.

## What this adds to the requested changes

The five requests above still stand. Two need widening:

- **Request 2 (`--confirm-sync`) must treat *disappearance* as a failure, not
  just an `Error` row.** In this mode the item is gone and the `Error` table is
  empty, so a check that only decodes `Error` reports success. Poll for the item
  by id: absent is a failure, present-with-empty-`external_id` past the deadline
  is a failure, present-with-`external_id` is the only success. Budget ~30s.

- **Request 3 (`sync-errors`) will print nothing in this mode.** Worth saying so
  in its help text, and worth pairing it with something like
  `apple calendar unsynced --calendar X`, which lists items whose `external_id`
  is empty **among normal items only** (`orig_item_id = 0`). That is the check
  that actually catches both modes. Without the filter it reports 329 false
  positives on this machine — see the caveat section above.

One new request:

6. **A `--verify` or `converge` mode for bulk writes.** Writing N events is the
   case that failed, and the working recovery was mechanical: read what is on the
   calendar, diff against what was asked for, re-add the difference, wait, repeat.
   Doing that by hand needs a purpose-built script every time.

# Telling the two failure modes apart

⚠️ **An earlier version of this analysis claimed `external_id` distinguishes the
two modes — that Exchange assigns one and Google does not. That was wrong, and it
was told to the user before it was checked.** Corrected 2026-08-18.

It came from two items: a stuck Exchange event that had an `external_id`, and a
stuck Google event that did not. Two observations, generalised into a rule. That
is the same mistake the `external_id` section above corrects, and both are
recorded here so the pattern is visible rather than looking like two unrelated
slips.

**`external_id` presence tracks backend and item kind, not failure mode.** The
measured table above shows why: Google populates it on 6352/6352 normal items and
1/330 detached occurrences, Exchange on 23/23 detached. A stuck item's
`external_id` tells you which store and what kind of item it is. It does not tell
you how the write failed.

## What actually discriminates

**The `Error` row: its `NSCode`, and which owner column it names.**

| | mode 1 — rejected write | mode 2 — vanished item |
|---|---|---|
| item in local store | present | **absent** |
| `Error` row | present, `NSCode` 403 | **none** |
| `error_code` scope | 3 item / 4 calendar / 5 store | n/a |
| `external_id` | empty | n/a, item is gone |
| what `add` reported | success | success |

🛑 **Neither discriminator fires in mode 2.** There is no `Error` row to decode
and no item to inspect. **The absence of the item is the only signal.**

So the `Error` table is authoritative in mode 1 and empty in mode 2. **Anything
built on it alone is blind half the time.** This is the core constraint on
requested change 2: `--confirm-sync` must poll for the item *by id* and treat
absence as a failure, not merely decode `Error` and report success when it finds
nothing.

## Provenance of the two modes

- **Mode 1** (rejected write, 403, `Error` row) — reproduced first-hand in this
  session against Google CalDAV, with the server-side absence confirmed through
  the Google Calendar API.
- **Mode 2** (vanished item, empty `Error` table) — **reported by the
  11-Volunteering session, not reproduced here.** Their 22-event burst ran before
  this session was involved and cannot be re-observed. Their own follow-up probes
  ran 33 of 33 clean, which is not evidence against the original loss. Recorded as
  reported-not-reproduced.
