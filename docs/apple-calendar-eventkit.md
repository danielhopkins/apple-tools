# EventKit: what it hides, what it clamps, and what it rebuilds

`CLAUDE.md` keeps the operative rules for `apple calendar`. This file keeps the
measurements behind them. The two calDAV/Exchange sync failures have their own
file, [`apple-calendar-caldav-403.md`](apple-calendar-caldav-403.md); writing
invitees has [`apple-calendar-invitees.md`](apple-calendar-invitees.md).

## Confirming that a write reached the server

🛑 **`add` and `edit` used to report success for a write the server refused.**
EventKit saving is local; the push happens afterwards, so `store.save` returning
says nothing about the server. Measured 2026-08-18: `add` returned a full,
populated event record and exit 0 for a write Google CalDAV refused with **HTTP
403**. The event sat in the local store forever and never reached the server.
Calendar.app surfaced it hours later, by which time the caller had told the user
it was on their calendar.

Both commands now confirm the server took the write before printing anything.
Measured round trip: **4.2s on calDAV, 3.1s on Exchange.**

🛑 **`external_mod_tag` is the obvious signal and it is wrong.** Exchange never
populates the ETag — **172 of 172 items**, including one written and confirmed
synced during this work. A check keyed on it calls a healthy Exchange account
100% broken. `external_id` is the only column that works on both backends.

🛑 **A bare "empty `external_id`" scan reports 468 healthy events.** Three filters
close that, each measured:

| filter | rows it drops | why they are not unsynced |
|---|---|---|
| `orig_item_id = 0` | 329 | detached CalDAV occurrences never get an `external_id` |
| store type in (1,2) | 139 | generated stores have no server — 138 Birthdays, 1 Siri |
| `disabled = 0` | 0 today | 10 of 16 stores here are switched-off accounts |

⚠️ **`orig_item_id` is `0` for a normal item, not NULL.** `IS NOT NULL` matches
every row and reports the whole store as detached occurrences.

🛑 **An edit cannot be confirmed by `external_id`** — the create already set one,
so a presence check returns `synced` instantly for an edit the server never saw.
`edit` snapshots before it saves. On calDAV the ETag moves (`"63922751442"` →
`"63922751478"` at t+4s). ⚠️ **On Exchange nothing moves at all**: no ETag,
`external_id` byte-identical, `sequence_num` and `modified_properties`
unchanged. So an Exchange edit reports **`unknown` with the reason**, never
`synced` — and its unconfirmable case is exit 0 with a note, not the exit 75
`pending` that only `add` can produce.

🛑 **The join is `(unique_identifier, calendar_id)`.** `unique_identifier` alone
is not unique — 64 values are shared here, one naming three rows, because an
Exchange meeting syncs into several Google calendars. ⚠️ A detached occurrence
carries `/RID=<seconds>` in **both** the EventKit id and the store column, so it
must not be stripped.

⚠️ **`Error` rows are transient.** The table is empty on this machine, yet
`sqlite_sequence` puts its high-water mark at **1304** — they are written and
then cleaned up. So `sync-errors` only helps inside a window, and an empty result
is not proof everything synced.

## `resync`

EventKit stops retrying an item once it records an `Error` row, and re-saving
does not re-push it; the only repair that worked was rebuilding. Verified on a
real event: coordinate, notes, URL, start and end all came across, the copy
synced in 4.1s, the original went, and no duplicate was left.

- 🛑 **The copy is created BEFORE the original is deleted**, so a failure leaves
  two events rather than none. Same rule `apple contacts move` follows.
- 🛑 **Build a fresh `EKStructuredLocation`; never assign the original's.** One
  belongs to a single event, and reusing it fails the save with "Object not
  found. It may have been deleted." Measured — the copy was never created, and
  only the create-first ordering kept it from losing the event.
- ⚠️ **`resync` stops on `pending`** where `add` and `edit` do not, because its
  next step deletes the original. Two copies are recoverable in Calendar.app;
  zero are not.
- ⚠️ **The new event gets a new identifier.**

🛑 **The 403 could not be reproduced, and that is the limit of this work.** 90
writes here and 33 in another session all synced:

| burst | calendar | result |
|---|---|---|
| 25 sequential in 2s | Personal (owned) | 25/25 synced in 5s |
| 40 parallel in 1s | Personal (owned) | 40/40 synced in 5s |
| 25 parallel in 1s | Family (delegated) | 25/25 synced in 10s |

So `resync` is verified on healthy events only. Whether a rebuilt item escapes a
poisoned account is **untested**. A second reported failure mode — the local copy
*deleted* with an empty `Error` table — was not reproduced either, and is why
`unsynced` matters alongside `sync-errors`.

⚠️ **A calendar's owner is readable and did not explain the bug.**
`Calendar.external_id` holds the CalDAV path, so a path carrying another
account's address is a delegated calendar; `self_identity_email` is the user's
own address on every row and distinguishes nothing. 7 of 9 enabled calDAV
calendars here are delegated. Writing to one syncs fine.

## The live suite outruns what one calendar will confirm

A lone write syncs in 5–6s on both Exchange and calDAV here. Writing ~70 in a
burst is a different regime, and the numbers moved a long way in one day:

| run | `--sync-timeout` | writes not confirmed |
|---|---|---|
| 71 tests in 322s | 30s | 3 |
| 71 tests in 928s | 30s | **26** |
| 71 tests in 1064s | 120s | 7 |

🛑 **Every one of those writes reached the server.** `unsynced` reported
"Everything has reached its server" straight afterwards, and no fixture leaked.
So the failure is always *this caller could not confirm it in time*, never *the
write failed* — and the failing tests differ every run, which is how you tell it
from a defect.

`tests/harness.py` passes `--sync-timeout 120` to `add`, `edit` and `resync`,
which cut it from 26 to 7. **The tool's own default stays at 30s**, because a
person writing one event should not wait two minutes to be told something went
wrong. Override with `APPLE_CALENDAR_TEST_SYNC_TIMEOUT`.

🛑 **The remaining 7 are a steady rate limit, not a passing throttle, and an
earlier version of this note said the opposite.** Two runs a day apart, at 120s,
both returned **exactly 7** — and the *failing tests* differed almost completely,
sharing one of seven. So about one write in ten exceeds 120s whatever else is
true, and waiting a day changes nothing. Raising the deadline further trades wall
clock for a signal that is already unambiguous.

**Pin a quieter calendar with `APPLE_CALENDAR_TEST_CALENDAR` if you need a clean
run.** `Personal` is calDAV here and a lone write syncs there in 5s. That path is
untested against the full suite.

## The four-year fetch clamp

🛑 **EventKit clamps one fetch to four years from the start, silently.**
`predicateForEvents` does not error, does not warn, and returns a result that
reads as complete. Measured on 26.819.0:

| asked | returned |
|---|---|
| 2022-01-01 → 2026-01-01 | 2022-01-01 → 2025-12-31 (full, exactly 4y) |
| 2021-12-31 → 2026-01-01 | 2021-12-31 → **2025-12-30** |
| 2008-01-01 → 2026-12-31 | 2008-01-05 → **2011-12-31**, 1,138 of 14,616 events |

That last row is how it was found: an 18-year search for a wedding came back
empty and looked like an answer. ⚠️ **A caller cannot detect the clamp**, because
an empty tail is indistinguishable from a quiet stretch of calendar.

`events` splits the range into four-year windows and reports the count on stderr.
Nothing else needed it — every other predicate here spans a day or two years.

- 🛑 **The de-duplication key is `(identifier, start, calendar)`.** Windows
  overlap, so an event is returned by each one it touches. `eventIdentifier`
  alone is not unique twice over: every occurrence of a series shares it, **and
  one event visible through two calendars comes back once per calendar with the
  same identifier and start**. Keying on identifier plus start alone dropped 6 of
  4,755 events on a range that needed no paging at all — a fix worse than the bug.

## Reading back every write

🛑 **`EKEventStore.save` returning true is not evidence the change persisted.** A
`--occurrence` move was observed returning exit 0 with JSON describing the moved
occurrence while the store still held the original date, and an identical retry
then worked. So `edit` re-reads a fresh store, compares each field it was asked
to change, **retries once** if nothing landed, and **exits non-zero naming the
mismatch**.

- ⚠️ **The JSON from `edit` is what the store holds, not what you asked for.** If
  they differ, the command fails instead of printing either.
- `APPLE_CALENDAR_SIMULATE_LOST_WRITE=1` makes the save a no-op so that path can
  be tested; the real failure is intermittent and cannot be provoked.

🛑 **A recurring `add --json` used to report the wrong rule, and the store was
never wrong.** Waiting for the server invalidates the saved event's recurrence
rule — the daemon replaces the rule object once the round trip lands, and the old
one stops resolving, so the in-memory `EKEvent` answered from a dead reference.
Measured on 26.818.1, which shipped it: `add --repeat monthly --on-the "4th
monday" --json` printed `{"frequency": "daily", "interval": 0}` while a fresh
read of the same event gave `{"frequency": "monthly", "interval": 1, "on_the":
"the 4th Monday"}`. `EKCADErrorDomain 1010 "Object not found. It may have been
deleted."` on stderr was the only hint. ⚠️ A non-recurring `add` was never
affected, which is why it survived a release.

## Recurrence

- 🛑 **A recurrence change must be saved with `EKSpan.futureEvents`.** Saving a
  changed rule on the series master with `.thisEvent` silently rewrites it to
  `FREQ=DAILY;INTERVAL=1` — no error, `save` reports success, and a
  4-times-a-year series becomes 365. Measured both ways; pinned by a test.
- 🛑 **`--series` used to save with `EKSpan.thisEvent`**, which *detached the
  first occurrence*, applied the change to that alone and left the rest
  untouched, while reporting success. Measured: `edit --series --location X`
  produced one detached instance carrying X and five unchanged occurrences. Fixed
  in 26.812.3; `delete --series` had the same bug.
- 🛑 **An id gains a `/RID=<seconds>` suffix once that occurrence is detached**,
  and then resolves to the detached instance, which has no rule of its own — so
  `--series` strips it to reach the master. Without that, `--series --repeat`
  fails with "The repeat field cannot be changed" *while naming the right event*,
  so it reads as the event refusing rather than the id being wrong.
- ⚠️ **EventKit does not expand a series far into the future.** An identical
  "every 2 weeks, 3 times" series reports 3 occurrences starting in 2026 and
  **1** starting in 2099, on both Google and iCloud calendars. Anything asserting
  on occurrences must use near-future dates — which is why the test suite sweeps
  a second, near-future window as well as its fixture year.
- ⚠️ **A moved occurrence *detaches*.** It stops being part of the series:
  `recurring` goes false, the `occurrence` field disappears, and its id gains the
  `/RID=` suffix. From then on it is an ordinary event. **`--occurrence` finds it
  by its new date**, not its old one — matching is on the base identifier, so a
  detached instance is still reachable through the series id plus the date it
  moved to.

🛑 **A `--series` write destroys detached occurrences, so it refuses.** `--series`
saves with `EKSpan.futureEvents` and EventKit rebuilds the series from the rule,
so an occurrence someone had moved is reverted to its original slot — silently,
no error. Measured on Exchange: a series with its November instance moved a week
early to clear a holiday came back with that instance on its original date and
nothing detached. ⚠️ **It is not deterministic** — a second run with more elapsed
time preserved the exception, which looks like a race between the detach syncing
and the series save.

⚠️ **Per-occurrence work converts a clean series into all exceptions.** Every
occurrence you touch detaches, so a nine-meeting series invited that way ends up
with nine exceptions and no un-detached instance — and every later `--series`
operation on it hits the guard. Correct, but a one-way door worth knowing before
you start. The safe way to change a series that has exceptions is still
per-occurrence: `invite ID --occurrence DATE --add …` never touches the master,
so nothing can be rebuilt. Verified: it changed only that occurrence and left a
pre-existing exception intact.

## Map pins

Measured on 2026-08-16, across 517 real events: 166 carry location text, all 166
carry a structured location, and only **68** carry a coordinate. 64 of those 68
are multi-line, which is Apple's picker format; three of the four single-line
ones end in `, USA`, which is Google's.

- **Nothing geocodes a string after the fact**, which is why `--at` has to do it
  at write time. Not EventKit on save, not the calDAV server on sync, and not
  Calendar.app on display — real street addresses have sat in this store for
  months with no coordinate. A probe event re-read at creation, from a fresh
  store, and after 150s of sync never gained one.
- **Verified in a matched pair on 2026-08-16**, same address, two events:
  `--location "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO 80303"` gave
  `has_coordinate: false`; `--at` on the same address gave `has_coordinate: true`
  at `39.9976725,-105.233365`, read back from a fresh store. Before `--at`
  existed the only route was Calendar.app's address picker.

⚠️ **The AppleScript route to `url` is a trap worth avoiding.** `set url of e to
missing value` fails with **-1700**; only an empty string works. And Calendar.app
cannot be addressed by the EventKit id that `events --json` prints, so matching
falls back to calendar name plus summary.

## Who may edit what

🛑 **`edit` refuses an invitation you received.** The test is **"am I an
attendee"**, not "am I the organizer", and the difference is load-bearing. On a
delegated calendar the organizer is somebody else and the user is not invited,
and a write there really does sync. Surveyed over 30 days on this machine:

| what the event is | count | `edit` |
|---|---|---|
| no organizer (an ordinary event) | 71 | allowed |
| the user organizes it | 2 | allowed |
| an invitation to the user | 14 | **refused** |
| somebody else's, user not invited (delegated) | 1 | allowed |

An organizer-only check would have wrongly refused that last one. `--force`
changes the local copy anyway; the server will still undo it.

🛑 **There is no "propose a new time", and there is no way to build one.**
Counter-proposing a different time on somebody else's meeting is a Calendar.app
feature and nothing else can reach it. Searched 2026-08-18: no match for "propos"
or "counter" in EventKit's public headers, its framework binary, or
CalendarDaemon, and Calendar.app's `sdef` has no term for it. Every symbol lives
in the Calendar.app binary itself — `_supportsProposeNewTime`,
`_proposeOrEditOrCancelProposeNewTimeAlertWithTitle:eventTitle:suggestedTime:`,
and `_bringUpMailComposeWindowWithProposalStart:withAttendee:withEvent:`, which
shows the app builds the proposal and hands it to Mail. Tell the user to use
Calendar.app; do not offer an `edit` instead, which is a different thing that
does not work.

⚠️ **Rescheduling a meeting you DO organize is just `edit --start`.** The server
mails the attendees itself. That mail is expected rather than measured.

## Backends are meant to be indistinguishable

`calendars --json` reports a `type` per calendar — `exchange`, `calDAV`, `local`,
`subscribed`, `birthdays` — and `./tests/run-tests --backends` runs one shared
set of assertions against a writable calendar from **every** backend present,
naming the backend when one fails. What genuinely differs is what the *server*
does afterwards, not the tool: Google rewrites an attendee's role and status
where Exchange leaves both `unknown`, and the two format invitation mail
differently.

⚠️ **The matrix writes to one real calendar per backend and cannot tell which are
shared** — nothing in EventKit exposes that — so it prints its choices before
writing and takes `APPLE_CALENDAR_TEST_CALENDARS="A,B,C"` to pin them. It writes
**no invitees**, so it never mails anyone.
