# Calendar invitees: why reading is free and writing is private API

Everything here was measured on this machine against a live Google account in
August 2026, macOS 27 (Darwin 27.0.0). Three throwaway events were created,
inspected and deleted; the invitations and cancellations they generated were
real and were delivered.

## The short version

| | |
|---|---|
| Read invitees | Public EventKit. Free. |
| Write invitees | **No public API exists.** Private `EKAttendee` + `EKCalendarItem.addAttendee:`. |
| Send the invitation | Not ours to do — the CalDAV server does it on sync. |
| Undo | None. |

## Reading

`EKCalendarItem.attendees` is a public, get-only `[EKParticipant]?`, and
`EKEvent.organizer` is a public `EKParticipant?`. Between them they carry
everything worth reporting:

| Field | Source |
|---|---|
| `name` | `EKParticipant.name` |
| `email` | `EKParticipant.url`, which is a `mailto:` URL for a person |
| `status` | `participantStatus` — pending / accepted / declined / tentative / … |
| `role` | `participantRole` — required / optional / chair / non-participant |
| `type` | `participantType` — person / room / resource / group |
| `is_me` | `EKParticipant.isCurrentUser` |
| `organizer` | the attendee whose address matches `event.organizer` |

⚠️ **Read the address off `url.absoluteString`, not `url.host`.** `URL.host` for
`mailto:dan@example.com` drops the local part and yields `example.com`, so a
comparison built on it matches every attendee at a domain. Swift's `URL` also
has no `resourceSpecifier` (that is `NSURL`), so the tool strips the `mailto:`
prefix from `absoluteString` directly.

⚠️ **The organizer is often not in the attendee list.** On real invitations here
the organizer appeared only as `event.organizer`, so a UI that lists attendees
alone silently omits the person who called the meeting. `apple calendar events
--json` reports `organizer` as its own object for this reason.

## Writing: the wall, and the way through it

**There is no public way to name someone you want to invite.** `attendees` has
no setter and `EKParticipant` has no public initializer. Calendar.app's
scripting dictionary is no better — its `attendee` class declares every property
read-only:

```xml
<class name="attendee" code="wrea">
    <property name="display name" access="r" .../>
    <property name="email" access="r" .../>
    <property name="participation status" access="r" .../>
</class>
```

So `make new attendee` cannot be given an address, and AppleScript is out.

What does exist, privately, on macOS 27:

```
EKAttendee (class methods)
  +attendeeWithName:emailAddress:
  +attendeeWithEmailAddress:name:
  +attendeeWithName:emailAddress:phoneNumber:url:
  +attendeeWithName:phoneNumber:
  +attendeeWithName:url:

EKCalendarItem (instance methods)
  addAttendee:
  removeAttendee:
  setAttendees:
```

`AttendeeAPI` in `swift/Sources/AppleCalendar/Attendees.swift` resolves all of
these through the Objective-C runtime at call time, and
`AttendeeAPI.isAvailable` gates every write.

🛑 **Resolve with `class_getInstanceMethod`, not `class_getMethodImplementation`.**
The latter returns `_objc_msgForward` for a selector that does not exist, so a
macOS that drops these symbols would turn "unavailable" into a crash at the call
site instead of a clean refusal.

## What actually happens on save

Measured, creating an event with one attendee on a Google calendar:

```
[1] before save, in memory
      dan@boulderhopkins.com   status=pending
      organizer: nil

[2] save: OK

[3] same object, after save
      dan@boulderhopkins.com   status=unknown
      danielhopkins@gmail.com  status=accepted  isMe=true
      organizer: Daniel Hopkins <danielhopkins@gmail.com>

[5] fresh store, 20s later (after the server round trip)
      danielhopkins@gmail.com  status=accepted   role=required  isMe=true
      dan@boulderhopkins.com   status=pending    role=required
      organizer: danielhopkins@gmail.com
```

Three things to take from that:

- 🛑 **EventKit adds the organizer and a self-attendee itself, on save.** You do
  not call `addOrganizerAndSelfAttendeeForNewInvitation` — it happens for you,
  and calling it as well would double the entry. The tool therefore reports the
  attendee list the event *ended up with* rather than the one that was asked
  for.
- 🛑 **The server rewrites names and roles.** `Dan Hopkins` came back as
  `dan@boulderhopkins.com`, and role went from `unknown` to `required`. **Match
  invitees on the email address only** — it is the one field that survives a
  round trip unchanged. Matching on name or role produces a check that passes
  locally and fails after sync.
- **The invitation is real.** 40 seconds after the save, a Google
  `Invitation: __claude_invitee_probe__ @ …` mail was sitting in the invitee's
  inbox, found with `apple mail search`. Nothing in this tool sends it; saving to
  a synced calendar is what triggers it.

Removal round-trips the same way, and is selective: on an event with two
invitees, `removeAttendee:` on one left the other and the self-attendee intact,
before and after sync.

⚠️ **Removing the *last* invitee also removes the auto-added self-attendee.**
The attendee list comes back completely empty, not down to one. That is correct
— EventKit has a `removeLastExtraneousOrganizerAndSelfAttendee` for exactly this
— but a confirmation that expects "one fewer" will read it as a failure.

## Refusals, and why each one is there

`apple calendar invite` refuses before saving when:

- **The private API is missing.** Reading still works; the error says so and
  points at Calendar.app.
- 🛑 **You are not the organizer.** Only the organizer may change an invitee
  list. A local change on someone else's event *appears to succeed* and is then
  reverted by the server — worse than a refusal, because the user believes the
  person was invited. Checked against `event.organizer.isCurrentUser`.
- **The calendar is read-only**, or `allowsAttendeesModifications` is false.
- **The address is malformed**, or the same address is in both `--add` and
  `--remove`.
- **The event is recurring and neither `--occurrence` nor `--series` was given**
  — the same guard `edit` and `delete` use.

And after saving, every change is **confirmed against a fresh `EKEventStore`**,
by the address being present (for an add) or absent (for a remove). The private
calls return nothing, so a save that reports success without taking effect is
precisely the failure mode worth catching; `confirmed: false` in the JSON and a
non-zero exit report it.

## What is deliberately not built

- **No RSVP.** Responding to an invitation is `EKEvent.participationStatus`,
  which is writable — but it belongs to a different verb than "manage invitees"
  and was out of scope here.
- **No role or optional/required control.** `EKAttendee` has
  `setParticipantRole:`, but the server overwrote the role we set, so exposing
  it would be a flag that silently does nothing.
- **No rooms or resources.** `attendeeWithName:url:` suggests they are
  reachable, but nothing here was tested against a resource-booking server.

## Testing

The suite in `tests/test_calendar_write.py::TestInvitees` covers parsing, every
refusal, and `--dry-run` — and **saves nothing**, because a test that ran
unattended would mail real people. The send path is verified by hand, which is
what this document records.

## Recurrence, added 26.812.1

Two interactions worth knowing, both found while wiring `--repeat` up:

- **Inviting someone to a recurring event invites them to the whole series.**
  There is no per-occurrence invitation here — the invitee list lives on the
  event, and for a series that means every occurrence. `add --repeat` with
  `--invitee` says so on stderr rather than letting it be a surprise.
- 🛑 **A recurrence-rule change must be saved with `EKSpan.futureEvents`.**
  Saving a changed rule on the series master with `.thisEvent` silently rewrites
  it to `FREQ=DAILY;INTERVAL=1`. No error, `save` reports success, and a meeting
  that happened four times a year now happens 365 times — with an invitation
  already sent to everyone on it. Measured both ways:

  | span | resulting rule |
  |---|---|
  | `.thisEvent` | `FREQ=DAILY;INTERVAL=1` |
  | `.futureEvents` | `FREQ=MONTHLY;INTERVAL=1;BYDAY=2TU` |

  This is the most dangerous thing found in this whole surface, precisely
  because it is silent and because invitations amplify it.

## Exchange sends invitations too (verified 26.812.2)

The Google measurement above was repeated against an Exchange account on the
same machine. **Both backends send genuine iTIP mail**; the differences are
cosmetic except for one that matters.

The Exchange invitation carries a `text/calendar; method=REQUEST` part:

```
METHOD:REQUEST
BEGIN:VEVENT
ORGANIZER;CN=Dan Hopkins:mailto:…@copta.org
ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=…
SUMMARY;LANGUAGE=en-US:__claude_exchange_probe__
DTSTART;TZID=Mountain Standard Time:20260821T150000
```

| | Google (calDAV) | Exchange |
|---|---|---|
| invitation subject | `Invitation: <title> @ <when>` | `<title>`, no prefix |
| cancellation subject | yes | `Canceled: <title>` |
| sender's copy | — | filed in **Sent Items** |
| role after sync | rewritten to `required` | left `unknown` |
| status after sync | rewritten to `pending` | left `unknown` |

🛑 **The normalisation differs by backend**, which is the reason the "match on
the email address, never the name or role" rule is not merely Google-specific.
A confirmation keyed to role or status would pass on Exchange and fail on
Google, or vice versa, for the same correct write.

⚠️ **Deleting an event with invitees emails a cancellation**, on both backends —
it is not only `invite --remove` that notifies people. On Exchange, Outlook then
moved the original invitation into the invitee's Deleted Messages on its own.

⚠️ **Reading the `.ics` back needs `apple mail attachments`, not `export --raw`.**
Mail strips attachment bytes out of the `.emlx`, so the `text/calendar` part
parses as empty; the `method=REQUEST` parameter is still on the Content-Type
header, but the calendar body itself has to be read off disk.

## Rescheduling one occurrence

`edit ID --occurrence <date> --start <new>` moves a single instance, including
to a different day, and leaves the rest of the series alone. The moved instance
**detaches**: `recurring` goes false, its `occurrence` field disappears, and its
identifier gains a `/RID=<seconds>` suffix. It is then an ordinary event —
editable and deletable by its own id, and deleting it removes only that
instance.

🛑 **`--occurrence` must match on the *base* identifier for this to work.** An
exact-match filter stops finding the instance the caller just moved, because the
detached instance's id carries a suffix the series id does not — so
`--occurrence <the new date>` failed with "no occurrence on that day" for an
event plainly listed in `events`. Fixed, and pinned by a test.

## 🛑 A `--series` write destroys detached occurrences (26.812.5)

The worst-consequence behaviour in this surface, found by a field report on a
live committee series.

`--series` saves with `EKSpan.futureEvents`, and EventKit rebuilds the series
from its recurrence rule. An occurrence that had been **moved** — detached, with
a `/RID=` identifier — is therefore rebuilt back into the pattern, reverting the
move. Silently: exit 0, no error, and the only sign is the date.

Measured on Exchange, reproducing a real setup: a monthly 4th-Wednesday series
with its November instance moved a week early to clear a holiday.

```
before   … Oct 28 · Nov 18 (detached) · Dec 23 …
invite --series --add …
after    … Oct 28 · Nov 25            · Dec 23 …      ← the move is gone
```

⚠️ **It is not deterministic.** A second run, with more elapsed time between the
move and the invite, preserved the exception. That looks like a race between the
detach reaching the server and the series save rebuilding from the rule — which
makes it worse, not better: it cannot be steered around by timing, and it will
pass a casual test.

`edit --series` and `invite --series` now refuse when the series has detached
occurrences, naming each one and its date, and require `--reset-exceptions` to
proceed.

**The safe path is per-occurrence**, which never touches the master:

```
apple calendar invite <id> --occurrence 2026-08-26 --add a@b.com
```

Verified: it changed only that occurrence, left a pre-existing exception intact,
and left every other occurrence alone. Costs one invitation per occurrence, and
each occurrence you touch becomes detached.

## 🛑 `invite` reported a roster for a save that never happened

Same defect class as the `edit` bug in 26.812.3, and more damaging. The
confirmation looked right but had a precise hole:

```swift
let persisted = freshStore().event(withIdentifier: match.eventIdentifier ?? id)
let confirmed = changes.map { change in
    guard change.changed, persisted != nil else { return change }   // ← nil → confirmed stays nil
    …
}
report(event: persisted ?? match, …)                                 // ← falls back to in-memory
```

When the event could not be re-read, every change kept `confirmed: nil`, the
exit check (`contains { $0.confirmed == false }`) read that as "nothing failed",
and the report fell back to `match` — the in-memory object holding the *request*.
So a rejected save printed a full `Invitees now:` block with eight names and
exited 0. A real committee was reported invited and the server held nobody.

It now fails loudly when the event cannot be read back, and never reports from
the in-memory object. **A lost calendar edit is recoverable; a caller who
believes people were invited stops telling them any other way.**

## 🛑 On Exchange, an invitee change can be discarded *after* it is confirmed

The most important thing measured in this whole surface, and it defeats the
obvious guard.

`invite` saves, a fresh-store read confirms the attendees are on the event, and
the server then **discards the change** — the attendees disappear tens of
seconds later. The confirmation is reading state that is locally committed but
not yet server-accepted, and for the one operation whose entire purpose is
server-side mail those are different things.

**It is intermittent.** Of nine per-occurrence invites issued against one real
series, five survived and three reverted. In isolated pairs here, one reverted
and one held at 60s. So a single check at any instant can be wrong.

⚠️ **Local state and delivered mail disagree in both directions.**

| Observed | Local attendees | Invitation mailed |
|---|---|---|
| the common case | kept | yes |
| reverted | **lost** | **yes, still sent** |
| the other way | **kept** | **never sent** |

So "invitees: 8" is not evidence anyone was invited, and an empty list is not
evidence nobody was. Both were seen on the same series within one minute.

`invite` therefore waits `APPLE_CALENDAR_INVITE_SETTLE` seconds (default 12)
after the immediate confirmation, re-reads, and **fails naming the addresses
that did not survive** — while saying explicitly that mail may have gone out
anyway, because it may have.

⚠️ **What this does not fix:** the tool still cannot verify delivery, and a
change that reverts after the settle window is still missed. The only
authoritative store is the server; OWA is the check that settles an argument.

### Create-with-invitees looks more reliable than invite-after-the-fact

Not proven, but worth knowing. `add --invitee` persisted through sync every time
it was tried (four events, Exchange and Google). `invite` on an event that
already existed is where every reversion was seen. If that holds, creating an
event with its invitee list is the safer construction on Exchange, and the
workaround for a series whose invitations will not stick is to recreate it with
`--invitee` rather than to keep retrying `invite`.

### The per-occurrence path converts a clean series into all exceptions

Worth knowing before choosing it. Inviting occurrence-by-occurrence detaches
every occurrence it touches, so a nine-meeting series handled that way ends up
with **nine exceptions and no un-detached instance left**. Every later `--series`
operation on it then hits the exception guard above.

That is correct behaviour rather than damage — the guard is protecting real
moved occurrences — but it is a one-way door in practice, and it surprises
people. `edit --series --title …` on such a series will refuse until someone
passes `--reset-exceptions`, which would flatten the very moves the
per-occurrence path was chosen to protect.

### Exception invitations are well-formed (verified)

Confirmed against the `.ics` copies filed in Sent Items for a real series with
two moved occurrences:

```
RECURRENCE-ID=20261125T173000  ->  DTSTART=20261118T173000
RECURRENCE-ID=20261223T173000  ->  DTSTART=20261216T173000
```

`RECURRENCE-ID` names the original slot the exception replaces and `DTSTART`
carries the moved time — correct iCalendar, and recipients see the moved dates.
A wrong date in front of the invitees was the plausible failure here, and it does
not occur.

### What is still unproven

A live nine-occurrence series was completed successfully on 26.812.6, one
occurrence at a time with roughly 60s of quiet between writes. **That is not
evidence the reversion is fixed.** No reversion occurred, so the settle check
never fired — it would have *caught* a failure, not prevented one. The clean run
is equally consistent with Exchange simply behaving that hour, or with the
spacing helping despite contention having been ruled out as the cause.

The settle path remains untested against a real reversion outside a deliberate
local reproduction.

---

# Proposing a new time: there is no API, at all

Searched 2026-08-18, macOS 27.0. Calendar.app's **Propose New Time** is an
app-internal feature. Nothing outside Calendar.app can invoke it.

| where I looked | matches for "propos" / "counter" |
|---|---|
| EventKit public headers (`EventKit.framework/Headers/*.h`) | 0 |
| `EventKit.framework` binary | 0 |
| `CalendarDaemon.framework` binary | 0 |
| `iCalendar.framework` binary (`COUNTER`, `DECLINECOUNTER`) | 0 |
| Calendar.app `sdef` | 0 |
| **Calendar.app binary** | **all of it** |

The symbols that exist are all in `/System/Applications/Calendar.app/Contents/MacOS/Calendar`:

```
_supportsProposeNewTime
allowsProposeNewTime
shouldOfferToProposeNewTime
_proposeOrEditOrCancelProposeNewTimeAlertWithTitle:eventTitle:suggestedTime:
_bringUpMailComposeWindowWithProposalStart:withAttendee:withEvent:
acceptAlternateTimeProposalMessage:forNotificationAttendee:
declineAlternateTimeProposalMessage:forNotificationAttendee:
```

🛑 **`_bringUpMailComposeWindowWithProposalStart:withAttendee:withEvent:` names
the whole mechanism.** Calendar.app builds the iTIP counter-proposal and hands
it to Mail. It is not a calendar write, so no amount of EventKit work reaches
it — and `apple mail` deliberately sends nothing, so the mail half is closed
here too.

This is not the same wall as the invitee writes above. Those had a **private**
EventKit API (`EKAttendee.attendeeWithName:emailAddress:`) that could be
resolved at runtime. A proposal has no API of any kind, public or private,
outside the app.

## What this means for `edit`

`invite` has always refused an event organized by somebody else. `edit` did not,
so `apple calendar edit <invitation> --start …` wrote the new time locally and
reported success, while the server reverted or refused it. That is how the
HTTP 400 recorded in
[`docs/apple-calendar-caldav-403.md`](apple-calendar-caldav-403.md) was
produced by hand.

`edit` now refuses, and points at Calendar.app.

🛑 **The test is "am I an attendee", not "am I the organizer".** A delegated
calendar has somebody else as organizer and does not invite the user, and a
write there really does sync — 7 of 9 enabled calDAV calendars on this machine
are delegated. Surveyed over the next 30 days:

| what the event is | count | `edit` |
|---|---|---|
| no organizer (an ordinary event) | 71 | allowed |
| the user organizes it | 2 | allowed |
| an invitation to the user | 14 | **refused** |
| somebody else's, user not invited (delegated) | 1 | allowed |

An organizer-only check would have invented a refusal for that last one.
`--force` changes the local copy anyway.

⚠️ **The refusal prints the organizer's address, not just their name.** This
event's organizer name is stored as `bryce ambraziunas.com`, which names nobody
the user can recognise. Both go in the message.

Pinned by `TestInvitationsAreReadOnly` in `tests/test_calendar_write.py`. It
finds a real invitation in the next 90 days and **skips** when the machine has
none, the same way the read-only-calendar and recurring-event tests do.
