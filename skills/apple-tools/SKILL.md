---
name: apple-tools
description: Read and write the user's local Apple app data — Notes, Mail, Reminders, Calendar, Contacts — through the `apple` CLI. Use whenever the user refers to their own notes, email, reminders, todos, calendar, meetings, schedule, or contacts ("what's on my calendar", "find that email from", "remind me to", "look up their number", "search my notes"). Everything runs locally against real data, so writes need care.
---

# apple-tools

`apple` is a local CLI over the user's real Apple app data. No network, no sync
service, no API keys — it reads the same SQLite stores and EventKit databases
the Apple apps use.

Check availability with `apple --version`. If the command is missing, say so
rather than falling back to AppleScript or `osascript` by hand; the point of
these tools is that the edge cases are already handled.

## The five tools

| Tool | Reads | Writes |
|------|-------|--------|
| `apple notes` | titles, folders, note bodies as Markdown | no |
| `apple mail` | accounts, message search, message bodies | **drafts** (send is guarded) |
| `apple reminders` | lists, items, due dates | **yes** |
| `apple calendar` | calendars, events | **yes** |
| `apple contacts` | names, emails, phones, addresses, notes | **yes** (except notes) |

## Rules

1. **Always pass `--json` when you will parse the output.** Plain text is for
   humans and its layout is not stable. (`contacts` is JSON by default; pass
   `--plain` there for human output.)
2. **Confirm before writing.** `reminders add/edit/complete/delete`,
   `calendar add/edit/delete`, `contacts add/edit/delete`, and
   `reminders new-list` all touch real data that syncs to the user's other
   devices. If the user did not clearly ask for the write, describe what you are
   about to do and wait. Contact deletion in particular has no undo.
3. **Never guess an identifier.** Run the corresponding `show`/`search`/`events`
   command first and use what it returns.
4. **Report empty results as empty.** "No events today" is a real answer. Do not
   pad it with invented plausible items.

## Getting the surface

Each tool documents itself. Prefer this over guessing flags:

```bash
apple --help              # the five tools
apple calendar --help     # subcommands
apple calendar add --help # every flag, with defaults
```

## Common recipes

```bash
# Notes — title search only; there is no full-text search over bodies
apple notes search "budget" --json
apple notes export 261                    # body as Markdown

# Mail — bound every search; see the timeout trap below
apple mail accounts --json
apple mail draft --to a@b.com --subject "Re: Q3" --body-file -   # body on stdin
apple mail search "invoice" --mailbox inbox --since 30 --limit 20 --json
apple mail export <message-id>

# Reminders
apple reminders show-lists --json
apple reminders show-all --due-date today --include-overdue --json
apple reminders add Inbox "Buy milk" --due-date "tomorrow 9am"

# Calendar
apple calendar calendars --writable --json
apple calendar events --days 7 --json
apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45

# Contacts — JSON by default; add/edit/delete are real writes
apple contacts search "smith"
apple contacts edit <id> --company "New Co" --phone "mobile:+15551234567"
apple contacts edit <id> --relation "daughter:Margot Hopkins"
apple contacts edit <id> --birthday 1980-04-12 --date "death:2020-05-01"
apple contacts groups                          # list groups with counts
apple contacts groups add "Family" <contact-id>
```

## Traps that will bite you

**Reminders indices shift.** `complete`/`edit`/`delete` take a *position within
a list*, not a stable ID, and that position changes as items are added or
completed. Always re-run `show` immediately before acting on an index.

**Calendar IDs identify a series, not an occurrence.** For a recurring event,
`events --json` includes an `occurrence` field — pass it back as `--occurrence`.
`edit` and `delete` refuse to run on a recurring event without either
`--occurrence` or an explicit `--series`, so if you see that error, do not
retry with `--series` unless the user meant the whole series.

**Notes with attachments are effectively read-only.** Writing a note's body
destroys every attachment on it, unrecoverably. These tools do not expose note
writing at all, which is deliberate — do not reach for AppleScript to work
around it.

**Mail search defaults to subject only.** Use `--field all` when the user is
describing content rather than a subject line. Trash and junk are excluded
unless you pass `--all`.

**Drafting email is where you are most useful.** `apple mail draft` writes to
Drafts and never sends. Pass long bodies via `--body-file -` on stdin.

There is no `apple mail delete`, so a draft you create is the user's to remove.
Get the content right and write it once rather than iterating in their Drafts
folder.

`apple mail send` exists but refuses to run without `--confirm`. Default to
drafting and let the user send. Only use `send` if they asked you to send in
that same turn — it is immediate and irreversible.

Two things to tell the user rather than be surprised by: the body is wrapped in
a `<blockquote type="cite">` by Mail itself (styling neutralised, renders
normally), and the `text/plain` alternative is empty so plain-text-only readers
see nothing until Mail regenerates the MIME on send.

**Mail search can time out and look like an empty result.** AppleScript's event
timeout is ~120 seconds, and when it trips, the search returns `[]` with exit
status 0 — indistinguishable from "no matches". So: if a mail search takes about
two minutes and comes back empty, treat it as *failed*, not as an empty inbox.
Keep searches cheap — `--mailbox inbox`, a tight `--since`, a small `--limit`,
and never an empty query with `--field all` (that greps every body in every
mailbox and will not finish).

**Note search is title-only.** To search note *content*, export candidates and
grep them.

**Contact multi-value flags replace, they don't append.** `contacts edit --email`
replaces every email on that contact. Read it first with `get`, then re-pass the
addresses to keep alongside the new one. Same for `--phone` and `--url`.

**Relations and dates.** `--relation father:"Robert Hopkins"` accepts any of the
216 relation labels Contacts defines (father/mother/son/daughter/spouse/niece/
colleague/in-law and step variants); case, spaces and hyphens are ignored. An
unknown label is stored as a custom one with a note on stderr — if you see that
note, check for a typo before moving on. Dates: `--birthday` and `--anniversary`
are built in; anything else is `--date LABEL:DATE`, e.g. `--date death:2020-05-01`.
There is no standard death-date label, so it is stored as a custom one. A
year-less date must be passed with `=`: `--birthday=--04-13`, never
`--birthday --04-13`, which the parser reads as a missing value.

`get`, `add` and `edit` return a single JSON object; `search`, `list` and
`groups members` return arrays. Unlabelled emails and phones have no `label`
key at all.

**Groups are managed separately.** `apple contacts groups` lists them with member
counts; `groups add/remove GROUP CONTACT-ID` changes membership; `GROUP` takes an
id or an unambiguous name. Deleting a group does not delete its contacts, and
removing a member does not either — say so if the user seems to expect otherwise.
Only `get` reports a contact's group membership; `search` and `list` omit it.

**Contact notes cannot be written.** They are readable, but writing needs an
Apple-granted entitlement no CLI can hold, so `--note` is rejected. Tell the user
to edit the note in Contacts.app rather than trying another route.

## Permission errors

macOS only shows a permission prompt the first time; after that a request
returns silently. So an access error is never something to retry — it needs the
user to change a setting.

- `apple calendar status` reports Calendar's real state without prompting.
  Watch for `writeOnly` ("Add Only"): it looks granted but cannot read events,
  and macOS will never offer to upgrade it.
- `apple contacts status` does the same for Contacts.
- Notes reads SQLite directly, so it needs Full Disk Access for the calling
  terminal. Contacts needs its own grant, plus Full Disk Access if you want
  contact notes.
- Mail needs Automation access and Mail.app running.
- `apple contacts groups remove` may need Automation access for Contacts. The
  Contacts framework's remove-member call silently does nothing for an iCloud
  group (it works for a local "On My Mac" one), so the command falls back to
  driving Contacts.app, launching it hidden and quitting it again. It always
  confirms the removal before reporting success. Every other contacts command
  uses the framework directly.

Reminders, Calendar and Contacts hold their **own** grants, independent of the
terminal — they re-execute themselves so macOS attributes the request to the
binary rather than to whatever launched it. So look for `apple-contacts` in the
System Settings pane, not the user's terminal app, and never suggest switching
terminals to fix one of those three. A `brew upgrade` sometimes asks for the
grant again — treat that as normal, not as something broken.

Notes (Full Disk Access) and Mail (Automation) are the exceptions: those two are
still granted to the calling terminal.

When a tool reports an access problem, tell the user which System Settings pane
to open. You cannot click through the dialog for them.
