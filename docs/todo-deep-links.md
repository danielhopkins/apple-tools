# TODO: a `url` on every entity

**Goal.** Every tool that names a thing should also hand back a link that opens
that thing in its app. If we edit a contact, the caller should be able to open
the contact; if we edit a note, the note.

**Why it's worth doing properly.** Two payoffs beyond convenience:

- **Cross-linking.** A briefing that pulls a calendar event, the attendees from
  Contacts, and a related note can link all three. That is only free if the URL
  rides along in the result the caller already has.
- **Verification by a human.** An agent that reports "I updated the note" is much
  easier to trust when the report carries a link the user can click to check.

**Status.** Contacts already does this (`contact_url`). Nothing else does, though
notes has the machinery behind a separate command. So this is consistency work,
not invention.

## What is actually available

Scheme registration verified against LaunchServices (`lsregister -dump`) on
macOS 27.0 — no apps were launched:

| Tool | Scheme | Granularity | Have the id? | State |
|---|---|---|---|---|
| contacts | `addressbook://<uuid>:ABPerson` | contact | yes | ✅ ships as `contact_url` |
| notes | `applenotes://note/<uuid>` | note | yes (`ZIDENTIFIER`) | ⚠️ only via `get-url` |
| mail | `message://%3C<Message-ID>%3E` | message | yes | ❌ not emitted |
| reminders | `x-apple-reminderkit://REMCDReminder/<uuid>` | reminder | yes (`externalId`) | ❌ unverified |
| calendar | `ical:` is registered | **unknown** | yes (EventKit id) | ❌ unverified |
| messages | `imessage://<handle>` | **conversation only** | yes (handle) | ❌ not emitted |

Registered: `applenotes:`, `message:`, `addressbook:`, `x-apple-reminderkit:`,
`ical:`, `webcal:`, `imessage:`, `sms:`.
**Not** registered: `calshow:`, `x-apple-calevent:`.

## Design

1. **A `url` key on every JSON object representing an openable entity** — in
   list results too, not only in `get`/`show`. The point is that a caller which
   already has the object does not need a second call per item.
2. **Standardise the key on `url`.** Contacts currently says `contact_url`; keep
   that as an alias rather than breaking anything already parsing it.
3. **Never emit a URL that does not open the thing named.** Where only coarser
   granularity exists, say so in the key rather than pretending:
   - messages → **`chat_url`**, because `imessage://` opens a conversation, not
     a message. Calling it `url` would imply a precision that does not exist.
   - calendar → if no per-event scheme works, emit **nothing**. A link that
     opens the app on the wrong thing is worse than no link.
4. **Omit the key when there is no id**, rather than emitting `null` — matching
   the existing contacts convention for unlabelled fields.

## Work, roughly in order of confidence

- [ ] **notes** — put `url` in `search`, `folders` and `export --json` output.
      The identifier and the format are already there in `get-url`; this is
      plumbing. Lowest risk, do it first.
- [ ] **mail** — `message://` with the Message-ID percent-encoded, including the
      angle brackets (`%3C` … `%3E`). Needs a live check that Mail opens it, and
      a decision on what to do for a message that is in the index but not on
      disk.
- [ ] **reminders** — verify `x-apple-reminderkit://REMCDReminder/<externalId>`
      actually opens the reminder before shipping it. The scheme is registered;
      the path form is inferred and **untested**.
- [ ] **messages** — `chat_url` as `imessage://<handle>`. Decide what a group
      chat with no single handle should produce; likely nothing.
- [ ] **calendar** — research whether any per-event URL works. Try
      `ical://ekevent/<id>`. If nothing does, document that and emit no key.
- [ ] **contacts** — add `url` alongside `contact_url`, no behaviour change.

## Open questions

- **Does `ical://ekevent/<id>` work?** Undocumented. If not, calendar is the one
  tool that cannot participate, which is worth stating plainly in CLAUDE.md
  rather than leaving a reader to wonder.
- **Recurring calendar events** would need the occurrence, not just the series
  id — the same trap CLAUDE.md already documents for `edit`/`delete`.
- **Do these URLs work when the app is closed?** Presumably they launch it, but
  that is a real cost for a field that appears in every list result. Untested.
- **Locked notes** — `get-url` already returns a URL and flags `locked: true`.
  That is the right shape: the link works, Notes prompts for the password.

## Verifying

Testing these means actually opening the apps, which is disruptive, so it wants
a deliberate moment rather than being folded into a test run. `open -g` opens
without stealing focus and is the least invasive way in.

## Scope

**Its own PR.** This touches all six tools and is unrelated to the Notes write-path
work in the branch where it was written up.
