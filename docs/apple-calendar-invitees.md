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
