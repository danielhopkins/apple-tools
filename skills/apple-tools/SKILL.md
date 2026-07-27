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
| `apple mail` | accounts, message search, message bodies | no |
| `apple reminders` | lists, items, due dates | **yes** |
| `apple calendar` | calendars, events | **yes** |
| `apple contacts` | names, emails, phones, addresses | no |

## Rules

1. **Always pass `--json` when you will parse the output.** Plain text is for
   humans and its layout is not stable. (`contacts` is JSON by default; pass
   `--plain` there for human output.)
2. **Confirm before writing.** `reminders add/edit/complete/delete`,
   `calendar add/edit/delete`, and `reminders new-list` all touch real data that
   syncs to the user's other devices. If the user did not clearly ask for the
   write, describe what you are about to do and wait.
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

# Contacts
apple contacts search "smith"             # JSON by default
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

**Mail search can time out and look like an empty result.** AppleScript's event
timeout is ~120 seconds, and when it trips, the search returns `[]` with exit
status 0 — indistinguishable from "no matches". So: if a mail search takes about
two minutes and comes back empty, treat it as *failed*, not as an empty inbox.
Keep searches cheap — `--mailbox inbox`, a tight `--since`, a small `--limit`,
and never an empty query with `--field all` (that greps every body in every
mailbox and will not finish).

**Note search is title-only.** To search note *content*, export candidates and
grep them.

## Permission errors

macOS only shows a permission prompt the first time; after that a request
returns silently. So an access error is never something to retry — it needs the
user to change a setting.

- `apple calendar status` reports Calendar's real state without prompting.
  Watch for `writeOnly` ("Add Only"): it looks granted but cannot read events,
  and macOS will never offer to upgrade it.
- Notes and Contacts read SQLite directly, so they need Full Disk Access for
  the calling terminal.
- Mail needs Automation access and Mail.app running.

When a tool reports an access problem, tell the user which System Settings pane
to open. You cannot click through the dialog for them.
