---
name: apple-tools
description: Read and write the user's local Apple app data — Notes, Mail, Messages, Phone calls, Reminders, Calendar, Contacts — through the `apple` CLI. Use whenever the user refers to their own notes, email, texts, iMessages, phone calls, missed calls, voicemail, reminders, todos, calendar, meetings, schedule, or contacts ("what's on my calendar", "find that email from", "what did they text me", "who called me", "call Alice", "remind me to", "look up their number", "search my notes"). Everything runs locally against real data, so writes need care.
---

# apple-tools

`apple` is a local CLI over the user's real Apple app data. No network, no sync
service, no API keys — it reads the same SQLite stores and EventKit databases
the Apple apps use.

Check availability with `apple --version`. If the command is missing, say so
rather than falling back to AppleScript or `osascript` by hand; the point of
these tools is that the edge cases are already handled.

## The seven tools

| Tool | Reads | Writes |
|------|-------|--------|
| `apple notes` | titles, folders, note bodies as Markdown | **yes**, once shortcuts are installed |
| `apple mail` | accounts, message search, message bodies, attachments | no — see below |
| `apple messages` | conversations, message search, attachments | no |
| `apple phone` | call history with names, blocked list, stats | **`dial` only** (you confirm in Phone.app) |
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
apple --help              # the six tools
apple calendar --help     # subcommands
apple calendar add --help # every flag, with defaults
```

## Common recipes

```bash
# Notes — title search only; there is no full-text search over bodies
apple notes search "budget" --json
apple notes export 261                    # body as Markdown
apple notes create --title "Trip" --body-file -            # Markdown on stdin
apple notes append 261 --body "- [ ] pack charger"         # real checklist item

# Mail — reads Mail's own store; fast, and works with Mail.app closed
apple mail accounts --json
apple mail search "invoice" --json                       # whole store, ~0.04s
apple mail search "budget review" --field content --json # full text of bodies
apple mail export <message-id>
apple mail attachments <message-id>                      # list what it carries
apple mail attachments <message-id> --save ~/Downloads   # get the files

# Messages — reads chat.db; works with Messages.app closed. Read-only.
apple messages chats --json                      # conversations, recent first
apple messages chats "boulder" --json            # find one by name or handle
apple messages search "dinner" --since 30 --json # whole history, ~0.1s
apple messages search "bikes" --chat 8 --json    # within one conversation
apple messages export 8 --limit 50               # transcript, oldest first
apple messages attachments 8 --save ~/Downloads

# Phone — reads CallHistory; works with Phone.app closed. Read-only except dial.
apple phone recents --json                       # recent calls, callers named
apple phone recents --missed --since 7 --json    # who called while they were out
apple phone recents --unknown --since 30 --json  # callers not in Contacts
apple phone search "denver" --json               # by name, number, or place
apple phone stats --since 90                     # counts, talk time, top callers
apple phone blocked --json                       # read-only, cannot be written
apple phone dial "Alice"                         # Phone.app asks them to confirm

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
apple contacts containers --json               # accounts; which is default
```

## Writing notes

`apple notes create` and `apple notes append` take a body as `--body TEXT`,
`--body-file FILE`, `--body-file -`, or a bare pipe. Markdown becomes **native structure**: `- [ ]` and `- [x]` are real
checklists carrying their checked state, and pipe tables are real tables.

`append` is a genuine append — it **preserves attachments and existing
checklists**. Prefer it over reconstructing a note. It refuses when the title
matches more than one note rather than appending to all of them.

⚠️ **It needs a one-time setup the user must do**, because macOS has no headless
way to install a Shortcut:

```
apple notes install-shortcuts
```

Check `apple notes status` before a write; it reports whether the write path is
available and names anything missing. If it is unavailable, tell the user to run
that command — you cannot do it for them, and the first run of each shortcut
also raises a permission dialog only they can answer.

🛑 **Never edit a note by exporting and re-writing the body.** That path
destroys every attachment on the note and flattens every checklist into a plain
bulleted list, losing which items were ticked. Both are silent and
unrecoverable, and 45% of a real store carries an embedded object. Use `append`,
or leave the note alone.

Notes cannot be *edited* in place, only appended to. If the user wants existing
text changed, say so rather than reaching for the destructive path.

⚠️ **A password-protected note cannot be read or written at all.** Its body is
encrypted and simply absent. `search` and `folders` skip locked notes and say so
on stderr; `export` exits 2 naming the reason.

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

**Mail search defaults to subject only.** Use `--field content` when the user is
describing what an email *said*, or `--field all` for subject, sender and body
together. Both are cheap enough to reach for — see below. Trash and junk are
excluded unless you pass `--all`.

**Messages is read-only and searches the whole history.** `apple messages
search` uses the same AND-of-substrings rule as mail, so the advice above
applies: two or three distinctive words, not a sentence.

Refer to a conversation by the numeric `id` from `apple messages chats`, not by
its title — **most group chats are unnamed**, so the title is a fallback list of
participants and is not stable. An ambiguous reference errors and lists the
candidates rather than guessing.

**Handles are phone numbers and emails, never names.** Messages has no contact
lookup. If the user asks "what did Sarah text me", find her number with `apple
contacts search "Sarah" --json` first, then pass it as `--handle`.

**Phone is the exception: it resolves names itself.** Unlike messages, every call
comes back with a `name` and a `known` flag, so "who called me yesterday" is one
command. `--unknown` lists callers not in Contacts, which is the natural first
step for "add whoever called me to my contacts" — take the number from there and
pass it to `apple contacts add`.

⚠️ **Three things `phone` cannot do, and none are worth retrying:**

- **Blocking.** There is no `block` command, by design. The system API is walled
  behind an Apple-internal entitlement and *fails silently*, so a command would
  claim success and change nothing. Tell the user to block in Phone.app or
  System Settings. `apple phone blocked` reads the list.
- **Voicemail.** Nothing is stored on the Mac — no list, no transcripts, nothing
  to mark read. It lives on the iPhone.
- **Answering, ending, or muting a live call.** No API exists.

**`dial` places a real call.** Phone.app always shows a confirmation panel, which
is the user's to click — never try to click it for them. Only run `dial` when the
user asked for the call in that turn, and prefer telling them the number
otherwise. `--dry-run` shows the URL without dialing.

Not every row is a text: check the `kind` field, which is `message`, `tapback`,
`systemEvent`, or `appMessage`. Group joins and renames are excluded unless you
pass `--include-events`. A message with no `text` but a populated `attachments`
list is a photo or video, not an empty message.

**A mail query is an AND of terms.** `budget review` finds messages containing
both words anywhere, in any order. Double-quote to require adjacency:
`"budget review"`. So prefer two or three distinctive words over one, and do not
paste a whole sentence — every word has to appear.

🛑 **You cannot send or draft email. Do not try.** `apple mail` has no `draft`,
`reply`, `forward` or `send` — they were removed in 26.810.0. Mail re-wraps any
body written by a script in `<blockquote type="cite">` the moment the draft is
opened, so every message the tool composed reached the recipient rendered as a
quotation, while looking perfectly normal to the sender. There is no workaround
from the CLI; the full investigation is in `docs/apple-mail-drafts.md`.

When the user asks you to write an email: **draft the text for them in your
reply** and tell them to paste it into Mail.app. Do not offer to send it, do not
reach for AppleScript or `osascript` to do it yourself, and do not suggest some
other tool will manage it. Writing the words is the useful part; putting them in
Mail is one paste.

`apple mail delete-draft <message-id>` still exists — it only moves a draft to
trash, and only ever looks in Drafts, so it cannot touch sent or received mail.
🛑 **Re-resolve the id first**: a draft's Message-ID changes when it is edited
and saved, and a stale one makes `export` return an *empty file* rather than an
error. Get the current id from `apple mail search "" --mailbox drafts --json`.

**Mail search is fast now — search widely.** It reads Mail's own index and
message files rather than driving Mail.app, so a whole-store subject search is
~0.04s, it covers every mailbox rather than a handful, and it works with Mail
closed. The old advice to bound every search with `--mailbox inbox` and a tight
`--since` no longer applies; narrow because the *user's question* is narrow, not
out of fear.

`--field content` is the one mode that opens files. It stops as soon as
`--limit` is filled, so it usually reads a small slice of the store — but a
term with fewer matches than `--limit` has to read all of it (~9s on a 40k
store). It prints `note: scanned N message bodies of M candidates` on stderr, so
you can always see how deep it went. If that is too slow, add `--since` or
`--mailbox`: those filter in SQL *before* any file is opened.

**An empty search result now means what it says.** Both engines either answer or
error — the AppleScript path's old silent-empty mode (a ~120s Apple Event timeout
that returned `[]` with exit status 0) is an error now, so you no longer have to
read stderr to know whether a short list was real.

**Never reach for `--engine applescript` to work around a search problem.** That
path drives Mail.app, and driving Mail with a whole-mailbox query is what makes
Mail's scripting interface stop answering — for every client on the machine,
until the user restarts it. The tool guards itself here (it refuses to launch
Mail, refuses `--field content` / `--field all` / `--has-attachment` on that
engine, and gives up on a deadline instead of hanging), so an error from those
guards is the tool working. Do not route around it with `osascript` by hand.

**A missing Full Disk Access grant is a permissions problem, not a search
problem.** `search` reports it and stops rather than falling back. The fix is for
the *user* to grant it — say so, and don't try the AppleScript engine instead.

**If Mail seems broken, ask before piling on.** `apple mail status --json` reports
`mail_app.responsive`. `false` means Mail is running but wedged: nothing that
drives it will work until the user quits and reopens Mail.app. Reads from the
index still work fine, so answer from those and tell them what is stuck.

**Note search is title-only.** To search note *content*, export candidates and
grep them.

**Attachment contents are never searched, and you cannot read one directly.**
`--field content` covers message bodies only; there is no PDF text extraction.
If the user asks what is *in* an attachment, save it with `apple mail
attachments <id> --save <dir>` and read the file yourself — do not report on it
from the filename alone.

`--save` never overwrites (a clash gets `-2` before the extension) and writes
only inside the directory you name, so it is safe to point at a real folder.
Prefer a scratch directory over `~/Downloads` unless the user asked for a
specific place.

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

**Exporting.** `apple contacts export <id>... [--group NAME] [-o file.vcf]`
writes vCard 3.0 — use it when the user wants to share, back up, or move
contacts rather than read them. It includes notes, which a plain vCard export
would drop. Without `-o` the vCard goes to stdout.

**Groups are managed separately.** `apple contacts groups` lists them with member
counts; `groups add/remove GROUP CONTACT-ID` changes membership; `GROUP` takes an
id or an unambiguous name. Deleting a group does not delete its contacts, and
removing a member does not either — say so if the user seems to expect otherwise.
Only `get` reports a contact's group membership; `search` and `list` omit it.

Both take `--json` and return `{group, contact_id, member, changed}`. **Read
`changed`, not the exit code**: `member` is the membership state afterwards
(re-read to confirm), while `changed` says whether this call did it. Adding
someone already in the group, or removing someone who was never in it, exits 0
with `changed: false` — so don't report an addition that did not happen.

⚠️ **Don't compare contact ids you got from different commands.** A contact has
both a unified id and a container-backed one, and they are different strings for
the same person. Match on the id a single command gave you, or re-read with `get`.

🛑 **A contact can only join a group in its own account.** If `groups add` fails
saying the two are in different accounts, the contact is in the wrong container
and no retry will help — **there is no move API**. Create it in the group's
account instead (`apple contacts add --container "<id from containers>"`), or
tell the user to drag the card between accounts in Contacts.app. `add` reports
which container it used, and `get`/`groups` report theirs, so you can check
before writing rather than after failing.

**Contact notes cannot be written.** They are readable, but writing needs an
Apple-granted entitlement no CLI can hold, so `--note` is rejected. Tell the user
to edit the note in Contacts.app rather than trying another route.

## Permission errors

macOS only shows a permission prompt the first time; after that a request
returns silently. So an access error is never something to retry — it needs the
user to change a setting.

**Run `apple status --json` first.** It reports all six tools at once, never
prompts, and exits non-zero if anything is unusable. Each entry carries the
System Settings `pane` to send the user to, and `granted_to`: `tool` means the
grant works from any terminal, `terminal` means it may not.

- `apple calendar status` reports Calendar's real state without prompting.
  Watch for `writeOnly` ("Add Only"): it looks granted but cannot read events,
  and macOS will never offer to upgrade it.
- `apple contacts status` does the same for Contacts.
- Notes and Messages read SQLite directly, so both need Full Disk Access for
  the calling terminal. Contacts needs its own grant, plus Full Disk Access if
  you want contact notes.
- Mail needs Automation access and Mail.app running.
- `apple contacts groups add` / `remove` need no extra permission. The Contacts
  framework's remove-member call silently does nothing for an iCloud group (it
  works for a local "On My Mac" one), so `remove` falls back to the legacy
  AddressBook framework, which does work. Both confirm the change by re-reading
  before reporting success, so trust the result rather than re-checking yourself.

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
