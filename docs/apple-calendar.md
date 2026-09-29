# calendar — `apple calendar`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple calendar`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

Swift + EventKit. Read and write events. The measurements behind every rule
below — the four-year fetch clamp, the recurrence spans, the sync join, the
`resync` rebuild — are in
[`docs/apple-calendar-eventkit.md`](apple-calendar-eventkit.md).

```
apple calendar calendars [--writable] [--json]
apple calendar events [--from DATE] [--to DATE | --days N] [--calendar NAME]
                      [--search TEXT] [--json]         # default: next 7 days
apple calendar show ID [--occurrence DATE] [--json]
apple calendar add "TITLE" --start DATE [--end DATE | --duration MINUTES]
                          [--calendar NAME] [--all-day] [--location TEXT]
                          [--at PLACE] [--notes TEXT] [--url URL] [--invitee ADDR]...
                          [--availability busy|free|tentative|unavailable]
                          [-r FREQ] [--on-the "4th monday"] [--months 1,2,3,4] [--json]
apple calendar edit ID [--title T] [--start DATE] [--end DATE] [--all-day | --timed]
                       [--location L] [--notes N] [--url URL|""]
                       [--availability busy|free|tentative|unavailable]
                       [--occurrence DATE | --series] [--future] [--json]
apple calendar invitees ID [--occurrence DATE | --series] [--json]   # read-only
apple calendar invite ID [--add ADDR]... [--remove ADDR]...
                       [--occurrence DATE | --series] [--future] [--dry-run] [--json]
apple calendar delete ID [--occurrence DATE | --series] [--future]
apple calendar status [--json]                # report permission state, never prompts

apple calendar sync-status ID [--json]        # did this one write reach the server
apple calendar unsynced [--calendar NAME] [--json]   # everything that did not
apple calendar sync-errors [--json]           # what Calendar recorded and hid
apple calendar resync ID [--dry-run] [--force] [--json]   # rebuild a stuck event
```

Dates accept natural language (`tomorrow 2pm`) or `YYYY-MM-DD [HH:MM]`. Default
event length is 1 hour. `--calendar` must match a name from `calendars` exactly
(case-insensitive); subscribed and holiday calendars are read-only.

⚠️ **Calendar titles are not unique.** A subscribed read-only "Birthdays" can sit
alongside a writable one of the same name, so `--calendar NAME` matches *every*
calendar with that name when reading and prefers a writable one when writing.
When it matters which one you got, read the `calendar` field on each event.

**Every write is confirmed twice: against a fresh store, then against the
server.** 🛑 `EKEventStore.save` returning true is not evidence the change
persisted, and a local save says nothing about the server — `add` once returned
exit 0 and a full event record for a write Google CalDAV refused with **HTTP
403**. So `edit` re-reads and compares each field it changed, retrying once and
exiting non-zero naming any mismatch; both commands then wait for the push.
Measured round trip on an idle account: **4.2s on calDAV, 3.1s on Exchange.**
`--no-confirm-sync` opts out, `--sync-timeout` defaults to 30s.

⚠️ **Those numbers are for ONE write, and a burst is a different regime.** Three
bursts on a Google calendar, 2026-08-21: a run of 20 adds had a median of 19s, a
run of 30 add+edit pairs had a median of **156s**, and a repeat of that run had
30s. 11 to 19 of every 30 writes miss a 30s deadline under load. So read a
timeout as "this caller could not confirm it", never "the write failed".

- **Read `sync.state`.** `synced` means the server has it. `notApplicable` means
  there is no server. `unknown` means the tool could not check, which is **never**
  a failure. An Exchange *edit* is always `unknown`, because Exchange records
  nothing locally when an edit lands.
- 🛑 **`pending` at the deadline exits 75, and that is not a failure.**
  `EX_TEMPFAIL` — the write is saved and the event record is still printed. A
  **refusal** — a *terminal* status such as 400, with EventKit recording an
  `Error` row — still exits 1. The two need opposite responses. ⚠️ Until 26.820.1
  both threw `ValidationError`: exit 64, and **no event printed at all**, so a
  `--json` caller had no id to check with.
- 🛑 **An HTTP 403 from Google is a RATE LIMIT far more often than a refusal, and
  treating it as terminal was wrong.** Measured in one burst of 30 add+edit
  pairs: **16 items recorded a 403, and all 16 synced anyway**, together at
  ~156s. EventKit retried and cleared 15 of the 16 rows itself. So a 403 no
  longer exits 1. The wait keeps polling and **extends its own deadline** to
  `--throttle-timeout` (default 180s) once a retryable error appears, saying so
  once on stderr. At that deadline it reports `pending` and exit 75, naming the
  status.
  - **Read `errors[].retryable` in the JSON**, never `http_status` yourself.
    403, 408, 429 and 5xx are retryable; 400, 401, 404, 405, 409 and 412 are
    terminal; **no status at all is retryable**, because nothing said the server
    refused anything.
  - ⚠️ **Retryable is not a promise the write landed.** The 2026-08-18 incident
    was a 403 that never cleared. CoreDAV cannot tell a throttle from a denial,
    and neither can this tool — so it waits rather than announcing a refusal it
    cannot support.
- ⚠️ **`sync-status`, `unsynced`, `sync-errors` and `resync` read
  `Calendar.sqlitedb`, which needs Full Disk Access** — a different grant from the
  Calendar one. Without it the answer is `unknown`, and a good write must not be
  called broken.
- 🛑 **An `Error` row is only evidence about the write that made it.** Rows are
  matched on `CalendarItem.ROWID`, and only rows created *since* the save count —
  a stale row once made a healthy calendar fail every write. See
  [`docs/apple-calendar-caldav-403.md`](apple-calendar-caldav-403.md).
- **`resync` rebuilds an event the server never accepted.** ⚠️ **Reach for it
  only after a *terminal* error**, or after `unsynced` still lists the event long
  after the fact. A retryable 403 does not need it, and rebuilding mints a new
  identifier for an event that was about to sync on its own. It creates the copy
  **before** deleting the original, refuses a recurring event even with
  `--force`, refuses one with invitees without `--force`.
- **`sync-errors` labels each row `retryable` or `terminal`.** ⚠️ **A row there is
  a report, not a verdict** — EventKit clears a retryable one when the item
  lands. `unsynced` is the command that says what is actually still missing.

🛑 **EventKit clamps one fetch to four years from the start, silently** — no
error, no warning, and an empty tail reads exactly like a quiet stretch of
calendar. An 18-year search returned 1,138 of 14,616 events and looked complete.
`events` splits the range into four-year windows and says so on stderr.

**Recurring events.** An event ID identifies the *series*, not the instance you
saw — EventKit resolves it to the first occurrence, often years earlier. So:

- `events --json` sets an **`occurrence`** field on recurring events. Pass it
  straight back as `--occurrence` to act on that instance.
- `edit` and `delete` **refuse to run** on a recurring event unless you pass
  either `--occurrence DATE` or `--series`. They will not guess.
- `show` without `--occurrence` returns the series master and says so on stderr.
- **`--series` means the whole series**, and it never detaches one. `--future`
  applies a change to this occurrence and all later ones.
- ⚠️ **Rescheduling one occurrence detaches it.** `edit ID --occurrence <date>
  --start <new>` works, including onto a different day, and the instance stops
  being part of the series: `recurring` goes false and its id gains a
  `/RID=<seconds>` suffix. From then on it is an ordinary event — `edit` and
  `delete` it by its **own** id.
- 🛑 **A `--series` write destroys detached occurrences**, because EventKit
  rebuilds the series from the rule. `edit --series` and `invite --series` refuse
  when the series has exceptions, name each one, and require `--reset-exceptions`.
  ⚠️ Per-occurrence work converts a clean series into all exceptions, which is a
  one-way door.

**Recurrence flags** match `apple reminders`: `--repeat
none|daily|weekly|monthly|yearly` (`-r`), `--repeat-interval N`,
`--repeat-until DATE`, `--repeat-count N`. `events --json` reports a
`recurrence` object (`frequency`, `interval`, `until`, `count`, `on_the`,
`months`).

**`--on-the` is the one flag reminders has no equivalent for**, because
`--repeat monthly` alone cannot say "the 4th Monday": a plain monthly rule
repeats on *the start date's day number*, so a series starting Mon 28 Sep recurs
on the 28th. The two coincide for exactly one month and then diverge silently.

```
apple calendar add "Board" --start "2026-09-28 10:00" \
    --repeat monthly --on-the "4th monday"
```

Takes `4th monday`, `last friday`, a bare weekday (means the first), a day number
like `15`, or `last`. ⚠️ A `--start` that does not match the pattern is a
**warning, not an error**. **Changing how an event repeats requires `--series`**,
since a rule belongs to the series; `--repeat none` removes recurrence entirely.

🛑 **`--on-the` is not valid on the same frequencies in both forms, because
EventKit is not.** A weekday form works on `--repeat monthly` **and `--repeat
yearly`**; a bare day number works on `monthly` only. EventKit *ignores* the part
it cannot carry rather than refusing it, so the CLI refuses instead.

**`--months` restricts a yearly rule to a set of months** — `BYMONTH`, which
EventKit honours only on a yearly rule.

```
apple calendar add "LEC Meeting" --start "2027-01-25 18:30" \
    --repeat yearly --on-the "4th monday" --months 1,2,3,4
```

That is "the 4th Monday of January through April, every year, forever". Without
it the only expressible substitute is a **bounded** monthly series, which expires
and has to be recreated by hand. One real series here lapsed three times — 2021,
2023, 2025 — for exactly that reason.

- Takes numbers or names, in any case, comma-separated or repeated: `1,2,3,4`,
  `jan,feb --months March`. Sorted and de-duplicated.
- Reported as `recurrence.months`, an array of integers, **absent rather than
  `[]`** when the rule has no filter.
- ⚠️ A `--start` in a month outside `--months` is a **warning, not an error**.
- **There is no `--rrule` escape hatch and there will not be one.** A raw RRULE
  hands EventKit combinations it drops in silence, which is what every refusal
  here exists to prevent.

🛑 **A `--series` edit is measured against the SERIES ANCHOR** — the first
occurrence, often years back — not against the next occurrence you can see. So
`--start`/`--end` with a full date move the whole series to that date. **Pass a
bare time to change the time and leave the anchor day alone:**

```
apple calendar edit <id> --series --start "18:30" --end "20:30"
```

⚠️ **A bare time used to mean *today*.** `NSDataDetector` reads `20:30` as this
evening, so a series anchored in 2023 would have jumped three years with nothing
printed. `edit` now re-hangs a bare time on the event's own day and says on
stderr which day that was. **`add` does not** — a new event has no day to hang a
time on, and today is the right reading there.

🛑 **An all-day event and a timed one are different shapes, and `--start`
alone cannot cross between them.** EventKit keeps `isAllDay` and pins the dates
back to midnight and 23:59:59, so the save reports success while nothing moves.
Measured 2026-08-31: the read-back caught it and reported `start is
2026-09-25T00:00:00, expected 18:30`, which names the symptom and not the cause.

```
apple calendar edit <id> --start "18:30"     # all-day -> 18:30, one hour long
apple calendar edit <id> --timed --start "18:30" --end "21:00"
apple calendar edit <id> --all-day           # the other direction
```

- **A `--start` carrying a clock time on an all-day event converts it**, because
  it can mean nothing else, and it says so on stderr. `--timed` and `--all-day`
  state it outright.
- ⚠️ **Midnight reads as "no time given".** A bare date parses to 00:00 and
  nothing afterwards can tell `2026-09-25` from `2026-09-25 00:00`, so moving an
  all-day event to another day keeps it all day. An event that really starts at
  midnight needs `--timed`.
- **A conversion with no `--end` runs one hour**, the same default `add` uses.
  ⚠️ An all-day event's end is 23:59:59, which is the end of the day rather than
  an end time; carrying it over would make a 5-hour event out of a 6:30 start.
- 🛑 **`--timed` with nothing to hang a time on is refused.** An all-day event's
  start is midnight, and inventing a midnight event nobody asked for is worse
  than an error.
- **`--start` on its own now keeps the event's length**, the way dragging one in
  any calendar app does, and reports the new end on stderr. ⚠️ Before 26.831.0
  the old end stayed put, so moving an event later failed with "end time must be
  at or after the start time" for a request that named no end at all. Moving an
  all-day event to the next day failed every time.

🛑 **`--location` is text and gets no map pin; `--at` is the flag that does.**
EventKit keeps the coordinate on a separate `EKStructuredLocation`, and only that
coordinate produces a map thumbnail or a travel-time alert.

```
apple calendar add "Bagels" --start "tomorrow 9am" \
    --at "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO"
```

`--at` resolves the place through Apple Maps and sets the coordinate itself, then
sets `location` to the resolved address. **This is a network call** — the only one
`apple-calendar` makes. `--pin-radius` sets the geofence size, `--near` biases the
search, `--clear-pin` removes the coordinate and leaves the text.

- ⚠️ **`--location` never geocodes, deliberately.** A location that is not a
  place — "Zoom", "my desk", a room name — must not be silently turned into a
  coordinate somewhere else in the world.
- **Nothing geocodes a string after the fact**, not EventKit, not the server, not
  Calendar.app. That is why `--at` has to do it at write time.
- ⚠️ **Ambiguity is refused, not guessed.** A shop name matching branches more
  than 250 m apart is an error listing them. Narrow with `--near`, or pass
  `"lat,lon"`.
- **`events`/`show --json` report `geo`** (`title`, `latitude`, `longitude`,
  `radius`, `has_coordinate`), and omit the key entirely when there is no
  structured location. **`has_coordinate` is how you check a `--at` write landed**
  — `location` alone cannot tell a geocoded address from a typed one.

**`--url` is writable on `add` and `edit`, and `--url ""` clears it.** An event's
`url` is a separate field from `location` and `notes`, and calendar clients turn
it into the join button — so a synced event can carry a **stale** meeting link
there while `location` holds the current one, and the stale one wins.

- **`--url ""` reaches `nil`**, not an empty URL, and the read-back check treats a
  cleared URL as absent.
- **A string that is not a URL is refused**, naming it. A scheme is required:
  `example.com` is rejected, `https://example.com` and `zoommtg://…` are taken.
- A URL in `--location` is fine and stays verbatim, but prefer `--url`.

**`--availability` is the "Show As" field**, on `add` and `edit`. It takes
`busy`, `free`, `tentative` or `unavailable`, and `events`/`show --json` report
it as `availability`.

```
apple calendar add "Focus block" --start "tomorrow 9am" --availability free
apple calendar edit <id> --availability free
```

- 🛑 **A calendar does not carry every value, and EventKit accepts one it does
  not carry.** Measured 2026-09-02 on a Google calDAV calendar carrying `busy,
  free`: writing `tentative` reported success and read back as `tentative` from
  the local store, for a state the account does not hold. It would be right on
  this Mac and absent everywhere else. So `add` and `edit` refuse a value
  outside the calendar's set, naming what it carries.
- **`calendars --json` reports `availabilities` per calendar.** Measured here:
  Exchange carries all four, calDAV carries `busy, free`, and a birthday or
  subscribed calendar carries none.
- ⚠️ **An absent `availability` key means the calendar carries none**, which
  EventKit reports as `notSupported`. Never read the missing key as `busy`.

**Invitees.** `events --json` reports `attendees` (objects, with `name`, `email`,
`status`, `role`, `type`, `organizer`, `is_me`), a separate `organizer`, and
`my_status` — the user's own response, which is what "have I accepted this?"
actually asks. ⚠️ **`attendees` is an array of objects, not name strings**; read
`.attendees[].name`. ⚠️ **The organizer is usually *not* in the attendee list.**

🛑 **`apple calendar invitees ID` is the read path, and `invite` is the write
path.** Reading the guest list must never require changing it. ⚠️ `invitees
--json` always carries `attendees` (`[]` when empty) and `count`, so emptiness is
never inferred from an absent key — `events --json` omits the key entirely, and a
careful reader once concluded the field had been dropped from the build.

🛑 **Writing invitees sends real mail, and there is no undo.** `add --invitee`
and `invite --add` make the server email an invitation; `invite --remove` and
deleting the event email a cancellation. **Run `invite --dry-run` first** — it
resolves and prints the plan without contacting the server at all. Both backends
send genuine iTIP mail; Google delivers in ~40s, Exchange under a minute. Full
record in
[`docs/apple-calendar-invitees.md`](apple-calendar-invitees.md).

- 🛑 **There is no public API for this.** Writes go through private
  `EKAttendee.attendeeWithName:emailAddress:` + `addAttendee:`/`removeAttendee:`,
  resolved at runtime. If a future macOS drops them, reading still works.
- 🛑 **Only the organizer can change who is invited.** On someone else's event a
  local change *appears to succeed* and is then reverted by the server, so
  `invite` refuses up front. **`edit` refuses an invitation you received** for the
  same reason; the test is "am I an attendee", not "am I the organizer", because
  a delegated calendar has neither. `--force` overrides it.
- 🛑 **On Exchange an invitee change can be discarded after it is confirmed.**
  Five of nine per-occurrence invites on one real series survived and three
  reverted. So `invite` waits `APPLE_CALENDAR_INVITE_SETTLE` seconds (default 12),
  re-reads, and **fails naming the addresses that did not survive**.
- ⚠️ **Local attendees and delivered mail disagree in both directions** — a
  reverted change still mailed people, and an event that kept its attendees never
  mailed anyone. "invitees: 8" is not evidence anyone was invited, and an empty
  list is not evidence nobody was. Check OWA or the web UI when it matters.
- 🛑 **Match invitees on the email address, never the name or role** — the server
  rewrites both. `Dan Hopkins`/role `unknown` came back as
  `dan@boulderhopkins.com`/role `required` after one round trip.
- 🛑 **EventKit adds the organizer and a self-attendee itself on save.** Don't
  call `addOrganizerAndSelfAttendeeForNewInvitation`. ⚠️ Removing the last invitee
  empties the list entirely, because the self-attendee goes with it.
- Addresses take `a@b.com` or `Name <a@b.com>`. Matching is case-insensitive, and
  re-adding someone already invited is a reported no-op.

🛑 **There is no "propose a new time" and no way to build one** — it is a
Calendar.app feature with no API anywhere. Tell the user to use Calendar.app; do
not offer an `edit` instead, which is a different thing that does not work.
