---
name: apple-tools
description: Read and write the user's local Apple app data — Notes, Mail, Messages, Phone calls, Maps, Reminders, Calendar, Contacts — through the `apple` CLI. Also turns a place name into a coordinate, for location reminders ("remind me when I get to the store") and calendar events with a real map pin. Use whenever the user refers to their own notes, email, texts, iMessages, phone calls, missed calls, voicemail, reminders, todos, calendar, meetings, schedule, contacts, or places they have been ("what's on my calendar", "find that email from", "what did they text me", "who called me", "call Alice", "remind me to", "look up their number", "search my notes", "where have I been", "when was I last at", "what's in my Maps guide"). Everything runs locally against real data, so writes need care.
---

# apple-tools

`apple` is a local CLI over the user's real Apple app data. No network, no sync
service, no API keys — it reads the same SQLite stores and EventKit databases
the Apple apps use.

Check availability with `apple --version`. If the command is missing, say so
rather than falling back to AppleScript or `osascript` by hand; the point of
these tools is that the edge cases are already handled.

## The eight tools

| Tool | Reads | Writes |
|------|-------|--------|
| `apple notes` | titles, folders, note bodies as Markdown | **yes** — create/append once shortcuts are installed; delete needs only Automation |
| `apple mail` | accounts, message search, message bodies, attachments | **opens a compose window** (you paste the body; `--attach` files are already in it); **`move` refiles messages** |
| `apple messages` | conversations, message search, attachments | no |
| `apple phone` | call history with names, blocked list, stats | **`dial` only** (you confirm in Phone.app) |
| `apple maps` | visited places with coordinates, visits, saved guides | no, and never |
| `apple reminders` | lists, items, due dates | **yes** |
| `apple calendar` | calendars, events, **invitees with RSVP status** | **yes** — and `invite` **emails real people** |
| `apple contacts` | names, emails, phones, addresses, notes | **yes** (except notes) |

## Rules

1. **Always pass `--json` when you will parse the output.** Plain text is for
   humans and its layout is not stable. (`contacts` is JSON by default; pass
   `--plain` there for human output.)
2. **Confirm before writing.** `reminders add/edit/complete/delete`,
   `calendar add/edit/delete`, `contacts add/edit/delete/move`, `reminders new-list`
   and `mail move` all touch real data that syncs to the user's other
   devices. If the user did not clearly ask for the write, describe what you are
   about to do and wait. Contact deletion in particular has no undo; `mail move`
   has `--dry-run`, so show that first.
   🛑 **`calendar invite` and `calendar add --invitee` are a category worse:
   they make the server email a real invitation to a real person, and removing
   an invitee emails a cancellation. Neither is undoable and neither is
   visible to the user until it has already been sent. Always show
   `invite --dry-run` output and get an explicit yes first — and note only the
   organizer can change invitees, so it refuses on someone else's event.**
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
apple notes delete 261                    # -> Recently Deleted; asks first

# Mail — reads Mail's own store; fast, and works with Mail.app closed
apple mail accounts --json
apple mail search "invoice" --json                       # whole store, ~0.04s
apple mail search "budget review" --field content --json # full text of bodies
apple mail export <message-id>
apple mail attachments <message-id>                      # list what it carries
apple mail attachments <message-id> --save ~/Downloads   # get the files
apple mail compose --to a@b.com --subject "Q3" --body "…"  # opens window; user pastes
apple mail compose --to a@b.com --body "…" --attach ~/q3.pdf  # files go in for you
apple mail reply <message-id> --body "…"                 # Mail builds the threading

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

# Maps — reads MapsSync; works with Maps.app closed. Read-only, always.
apple maps places --json                         # where they go, most-visited first
apple maps places --min-visits 5 --json          # the regular places only
apple maps places --search "costco" --json       # when were they last there
apple maps visits --since 14 --json              # individual arrivals, newest first
apple maps guides --json                         # saved guides with place counts
apple maps guides "Boulder Playgrounds" --json   # the places in one guide
apple maps geocode "costco" --json               # coordinate; local first, then network
apple maps geocode "costco" --local-only         # never touch the network

# Reminders
apple reminders show-lists --json
apple reminders show-all --due-date today --include-overdue --json
apple reminders add Inbox "Buy milk" --due-date "tomorrow 9am"
apple reminders add Errands "Milk" --at "costco, superior co"   # when I arrive
apple reminders add Errands "Call" --at "39.96,-105.17" --on leave --radius 250

# Calendar
apple calendar calendars --writable --json
apple calendar events --days 7 --json          # attendees, organizer, my_status
apple calendar add "Dentist" --start "tomorrow 2pm" --duration 45
apple calendar unsynced                   # did anything fail to reach the server
apple calendar add "Board" --start "2026-09-28 10:00" \
    --repeat monthly --on-the "4th monday"   # same --repeat flags as reminders
apple calendar edit <id> --series --repeat weekly    # rule changes need --series
apple calendar edit <id> --url ""                   # clear a stale meeting link
apple calendar invitees <id>                        # read-only: who is invited
apple calendar invite <id> --add a@b.com --dry-run   # ALWAYS dry-run first
apple calendar invite <id> --add "Dana White <d@x.com>"   # sends real mail

# Contacts — JSON by default; add/edit/delete are real writes
apple contacts search "smith"
apple contacts edit <id> --company "New Co" --phone "mobile:+15551234567"
apple contacts edit <id> --relation "daughter:Margot Hopkins"
apple contacts edit <id> --birthday 1980-04-12 --date "death:2020-05-01"
apple contacts groups                          # list groups with counts
apple contacts groups add "Family" <contact-id>
apple contacts move <id> --to "iCloud" --dry-run  # between accounts; keeps the id
apple contacts containers --json               # accounts; which is default
```

## Did that calendar write actually reach the server?

🛑 **`add` and `edit` used to say yes when the answer was no.** EventKit saving
is local; the push happens afterwards. Measured 2026-08-18: `add` returned a full
event record and exit 0 for a write Google refused with HTTP 403. The event never
reached the server, and the caller had already told the user it was on their
calendar.

Both commands now wait for the server before reporting success. On by default,
about 4 seconds. **Read `sync.state` in the JSON:**

| state | means |
|---|---|
| `synced` | the server has it |
| `pending` | it does not, and the command exits non-zero |
| `notApplicable` | there is no server — a local or generated calendar |
| `unknown` | the tool could not check. **Never report this as a failure.** |

⚠️ **An Exchange *edit* always reports `unknown`**, because Exchange records
nothing locally when an edit reaches the server. That is a real limit, not a
fault. Say so rather than claiming the edit landed.

Use `--no-confirm-sync` only when the user is writing many events and will check
afterwards with `unsynced`.

Three read commands, none of which write anything:

```
apple calendar sync-status <id>    # one event
apple calendar unsynced            # everything the server never took
apple calendar sync-errors         # what Calendar recorded and hid
```

🛑 **`sync-errors` printing nothing is not proof everything synced.** One of the
two known failure modes leaves no error row at all. Run `unsynced` too.

**`apple calendar resync <id>` rebuilds a stuck event.** EventKit stops retrying
an item once it records an error, so nothing fixes itself. Ask the user first:
the event gets a **new identifier**, and with `--force` on an event with guests
it mails everyone a fresh invitation. Run `--dry-run` first. A recurring event is
refused outright.

⚠️ **These four commands need Full Disk Access**, which the Calendar grant does
not carry. Without it they say so; they do not guess.

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

## Deleting a note

`apple notes delete ID` moves a note to Recently Deleted, where it stays for
about 30 days. It needs no Shortcut — it uses AppleScript — but it does need
**Automation → Notes** for the calling terminal, and it launches Notes.app.

🛑 **Ask the user before you run it, and do not reach for `--yes` to avoid
asking.** The command prompts on a tty and refuses without one unless given
`--yes`. That flag exists for a user who scripted it, not as a way past a
conversation you have not had. Nothing here can empty Recently Deleted.

- **A title must match in full.** `export` accepts a partial title; `delete`
  does not, and an ambiguous title is refused listing the ids. Prefer the id.
- **Read `confirmed` in the JSON, not `store_confirmed`.** `confirmed` is
  Notes.app's answer and is authoritative. `store_confirmed` is sqlite's, and
  the store lags by minutes — `false` there is normal, not a failure.
- ⚠️ **`apple notes search` still lists a deleted note**, because the reader can
  see Recently Deleted. Do not read that as the delete having failed.
- **A locked note is refused with exit 2.** Its body cannot be read, so the user
  cannot be shown what they would lose.

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

**`maps` answers "where have I been", and `places` is usually the command.**
`places` is one line per place with a visit count and a last-visited date;
`visits` is one line per arrival. Both take `--search`, which is an AND of
substring terms across name, address, city and category — the same rule mail and
messages use.

⚠️ **Four things to get right when reporting Maps data:**

- **This is Maps' "Visited Places", not Significant Locations.** Significant
  Locations belongs to `routined` and no unprivileged process can read it. Never
  call one the other.
- **A visit has no end time**, so the store cannot say how long the user stayed
  anywhere. Do not report a duration.
- **Coverage is about a year**, not all time. `apple maps status` prints the real
  window; quote that rather than implying the history is complete.
- **`classification` in the JSON is an undocumented number.** Two values appear
  and nothing names them. Do not interpret it.

**`guides` is the richer half.** These are lists the user built by hand — trip
guides, playground lists — so they carry intent that visit history does not. An
ambiguous guide name is an error listing the candidates; pass an id to resolve
it.

🛑 **Geocoding is the one thing here that touches the network.** Everything else
runs against local stores. Three flags use it:

- `apple maps geocode QUERY` — a coordinate for a place. It tries the user's own
  visited places and guides **first**, so the common case makes no network call,
  and the answer is better: "costco" means the branch they go to. Pass
  `--local-only` when the user should not be sent to the network at all.
- `apple reminders add|edit --at PLACE` — a location reminder. `--on arrive`
  (default) or `--on leave`, `--radius` in metres.
- `apple calendar add|edit --at PLACE` — an event with a real map pin, which is
  what gives a client a map thumbnail and a travel-time alert.

⚠️ **Four things to get right:**

- **`--location` never geocodes, and that is deliberate.** Use it for text that
  is not a place ("Zoom", a room name). Use `--at` when the user wants a pin.
- **`reminders` cannot resolve against the user's own Maps data**, only over the
  network, because it runs disclaimed and loses Full Disk Access. To pin a
  reminder to a place they actually go to, compose the tools:

  ```
  AT=$(apple maps geocode costco --json | jq -r '.[0].at')
  apple reminders add Errands "Buy milk" --at "$AT"
  ```

  The `at` field is a ready-made `"Name@lat,lon"` string. Use it rather than
  building one, so the place keeps its name.
- **An ambiguous place is refused, not guessed.** Branches more than 250 m apart
  produce an error listing them. Narrow with `--near`, or pass a coordinate.
- **Check `has_coordinate` in `apple calendar show --json`** to confirm a pin
  landed. `location` alone reads identically with or without one.

Not every row is a text: check the `kind` field, which is `message`, `tapback`,
`systemEvent`, or `appMessage`. Group joins and renames are excluded unless you
pass `--include-events`. A message with no `text` but a populated `attachments`
list is a photo or video, not an empty message.

**A mail query is an AND of terms.** `budget review` finds messages containing
both words anywhere, in any order. Double-quote to require adjacency:
`"budget review"`. So prefer two or three distinctive words over one, and do not
paste a whole sentence — every word has to appear.

**Writing email stops one keystroke short, by design.** `apple mail compose`,
`reply` and `forward` open a Mail window with recipients, subject, threading, the
quoted original and any carried-over attachments already filled in, put your text
on the clipboard, and stop. The user presses ⌘V and ⌘S.

```bash
apple mail compose --to a@b.com --subject "Q3" --body "text"
apple mail reply <message-id> --all --markdown --body-file -
apple mail forward <message-id> --to a@b.com --body "FYI"
```

🛑 **The tool never writes the body, and you must not try to.** A body set through
AppleScript is wrapped in `<blockquote type="cite">` and reaches recipients
rendered as a quotation while looking normal to the sender. Do not reach for
`osascript` to "finish the job" — that is the bug. See `docs/apple-mail-drafts.md`.

**Report it as waiting, not as done.** The JSON says `status: "awaiting_paste"`
and there is no `message_id`, because nothing was saved. Tell the user to press
⌘V then ⌘S. Never say the mail was sent or the draft saved.

**`--markdown` gives real formatting** — bold, italic, links, bullets. A plain
`--body` is literal, so `*` and `_` in prose survive.

⚠️ **There is no `send`.** When the user wants mail sent, use `compose` and let
them press send themselves.

🛑 **You cannot reply to a draft** — it has no sender. The tool refuses.

`apple mail delete-draft <message-id>` still exists — it only moves a draft to
trash, and only ever looks in Drafts, so it cannot touch sent or received mail.
🛑 **Re-resolve the id first**: a draft's Message-ID changes when it is edited
and saved, and a stale one makes `export` return an *empty file* rather than an
error. Get the current id from `apple mail search "" --mailbox drafts --json`.

**`apple mail move` refiles received mail, and it is the one mail command that
changes the user's mailboxes.** Use it for sweeps: filing mail that arrived
before a filter rule existed, or rescuing something filed wrongly.

```bash
apple mail search "receipt" --mailbox inbox --json | jq -r '.[].id' \
  | apple mail move - --to Receipts --dry-run
apple mail move <id> <id> --to Receipts --mark-read --json
```

🛑 **Always run `--dry-run` first and show the user the result before moving
anything.** These moves sync to every device. `--dry-run` resolves entirely from
Mail's index and sends Mail nothing, so it is free — there is no reason to skip
it. Treat the plan as something the user approves, not something you act on.

- Takes many ids at once; `-` reads them from stdin, one per line.
- **Read `moved` and `confirmed` per message, not the exit code.** Each result is
  `{id, subject, account, from_mailbox, to_mailbox, moved, confirmed, error}`.
  One bad id does not abort the batch, so a sweep can be part success.
- Destinations are per-account and **nothing is created** — a name that does not
  exist is an error listing what does. `--to trash` works across account types.
- `--mark-read` marks each message read as it moves, matching what a server-side
  filter rule does.
- A Message-ID with copies in several mailboxes moves **all** of them. Narrow
  with `--from` or `--account` when that is not what you want.
- Drafts are refused; use `delete-draft`.

⚠️ **The source copy lingers for ~2 minutes on IMAP** (a move is
copy-then-expunge), so re-listing the old mailbox and still seeing the message is
normal, not a failed move. The tool says so on stderr. Judge by `confirmed`.

**Undo is just another move**, back to the original mailbox — `from_mailbox` in
the result tells you where each one came from.

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
and no retry will help. `apple contacts move <id> --to <container>` fixes it,
keeping the contact's id. `add` reports which container it used, and
`get`/`groups` report theirs, so you can check before writing rather than after
failing.

⚠️ **A move drops every group membership in the account it leaves** — a group
belongs to one account. Run `move --dry-run` first: it lists the groups the move
will empty and writes nothing. Say what those are before doing it for real.

🛑 **A contact carrying a note cannot be moved** and the command refuses, because
copying the record reads the note and that needs an entitlement no CLI can hold.
Tell the user to drag that card between accounts in Contacts.app instead —
don't try another route.

## Who is this contact connected to?

```
apple contacts relations <id> --json      # both directions
apple contacts link A B --relation spouse # writes BOTH cards
apple contacts unlink A B --relation friend
```

🛑 **A relation stores a NAME, not a link to the other card.** So a name can
match nobody, or several people. Read `matches` in the JSON before saying who
someone is related to — `1` means it resolved, `0` means the name matches no
contact, `2+` means it is ambiguous.

**`related_from` is the half people usually mean.** It scans every card for
anyone naming this contact. On a real store one person listed three brothers and
none of them listed him back, so the two directions genuinely differ.

⚠️ **`link` edits the other person's card too.** Confirm with the user before
running it. Use `--dry-run` first; it resolves and prints the plan without
writing. Contacts writes sync everywhere and have no undo.

⚠️ **A gendered relation is refused, and that is correct.** `--relation father`
cannot infer the other side, because it is son or daughter and Contacts records
no gender. Pass `--inverse son`, or `--no-inverse` to write one side only. Do
not guess the person's gender to pick one.

**Use `link`, never `edit --relation`, to add one relation.** `edit` replaces the
whole set, so it silently deletes every relation you did not re-pass.

**Postal addresses are writable now.** `--address` on `add` and `edit`, free
text or exact fields:

```
apple contacts edit ID --address "home:500 W Madison St, Chicago, IL 60661"
apple contacts edit ID --address "work:street=1 Radicle Way;city=Chicago;state=IL;zip=60601"
```

⚠️ **The free-text parse is a guess and the tool prints what it decided.** Read
that line. It handles `street, city, STATE ZIP, country` and knows nothing about
other countries' conventions. When it is wrong, use `key=value`. What `get`
prints can be passed straight back, since `zip` and `postalCode` both work.

⚠️ **Like every multi-value flag here, `--address` replaces the whole set.** Read
the contact first and re-pass the addresses you want to keep.

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
