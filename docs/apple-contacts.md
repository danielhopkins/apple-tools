# contacts — `apple contacts`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple contacts`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

Swift + Contacts framework (`CNContactStore`). Full CRUD. The measurements,
failure histories and framework traps behind every rule below are in
[`docs/apple-contacts-writes.md`](apple-contacts-writes.md); moving a
contact between accounts is in
[`docs/apple-contacts-move.md`](apple-contacts-move.md).

```
apple contacts search TERM [--limit N] [--plain]   # default limit 25
apple contacts get ID [--plain]
apple contacts list [--limit N] [--plain]          # default limit 100
apple contacts add [FIELDS] [--container NAME] [--json]
apple contacts edit ID [FIELDS] [--clear-dates] [--json]
apple contacts move ID --to CONTAINER [--dry-run] [--json]
apple contacts delete ID
apple contacts export ID... [--group GROUP] [-o FILE]   # vCard 3.0, notes included
apple contacts deceased [--json]                   # everyone recorded as having died
apple contacts relations ID [--json]               # who this contact links to, resolved
apple contacts link A B --relation LABEL [--inverse LABEL] [--no-inverse]
                        [--name-only] [--dry-run]
apple contacts unlink A B [--relation LABEL] [--no-inverse] [--dry-run]
apple contacts containers [--json]                 # accounts, and which is default
apple contacts status [--json]                     # permission state, never prompts

apple contacts groups                              # list, with member counts
apple contacts groups create NAME [--container ID]
apple contacts groups rename GROUP NEW-NAME
apple contacts groups delete GROUP
apple contacts groups members GROUP [--plain]
apple contacts groups add GROUP CONTACT-ID [--json]
apple contacts groups remove GROUP CONTACT-ID [--json]
```

`GROUP` accepts a group id **or** an unambiguous group name.

FIELDS, shared by `add` and `edit`:

```
--first --middle --last --name-prefix --name-suffix --nickname
--previous-family-name NAME  --company-card | --person-card
--company --department --job-title
--birthday YYYY-MM-DD|--MM-DD
--anniversary YYYY-MM-DD|--MM-DD
--died YYYY-MM-DD|YYYY|--MM-DD
--email    [LABEL:]ADDRESS   repeatable
--phone    [LABEL:]NUMBER    repeatable
--url      [LABEL:]URL       repeatable
--address  [LABEL:]ADDRESS   repeatable
--relation LABEL:NAME        repeatable
--date     LABEL:DATE        repeatable
--note TEXT | --append-note TEXT | --clear-note
--photo FILE | --clear-photo
```

**Person or company.** `--company-card` marks a card as a business,
`--person-card` marks it as a person, and `get`/`search`/`list --json` report
`is_company` (absent, never `false`).

```
apple contacts edit <id> --company-card
```

🛑 **It is the "Company" tick box in Contacts.app**, and the only reliable way
to tell PayPal from a person: a company card carries emails, phones and an
address exactly like anyone else. 71 of the 694 cards here have it set.
`apple-index people` uses it to keep businesses out of the social graph.

**A name someone used before.** `--previous-family-name` writes it, and
`get`/`search`/`list --json` report `previous_family_name`.

```
apple contacts edit <id> --previous-family-name Anderson
```

- 🛑 **Contacts.app labels this field "Maiden Name". This tool does not**, and
  the difference is deliberate: the same field carries a name changed by a
  second marriage, a divorce, an adoption or a deed poll. `CNContact` calls it
  `previousFamilyName`, which is the accurate word.
- **`search` matches it, whole**: "Steph Anderson" finds the card that now
  reads "Stephanie Hopkins". The two halves live in different fields, so
  neither matches on its own.
- 🛑 **`apple-index people` uses it to fold one person's two lives together.**
  Without it a name change is two people in the data, and no amount of address
  matching finds them. See [`lab/README.md`](../lab/README.md).

**Pictures.** `--photo FILE` sets the contact's picture, `--clear-photo` removes
it, and `get`/`search`/`list --json` report **`has_photo`** (present only when
true, like every other optional key here).

```
apple contacts edit <id> --photo ~/Downloads/face.jpg
apple contacts edit <id> --clear-photo
```

- **The file is decoded before anything is written.** A missing path, a
  directory, an empty file, or something that is not an image exits without
  touching the contact — the same rule `apple mail` applies to `--attach`. Over
  5 MB gets a stderr note, not a refusal.
- 🛑 **`setImageData:` throws `CNPropertyNotFetchedException` unless
  `CNContactImageDataKey` was in the FETCH**, and `imageDataAvailable` does not
  satisfy it. It is an Objective-C exception, so it **terminates the process** —
  a crash dump, not an error a caller can act on. So a picture edit re-fetches
  its contact with the image key, and `list`/`search` keep the cheap key set.
  Measured here: 341 cards carry an image averaging ~100 KB, so putting the blob
  in the read keys would drag ~34 MB through every listing.
- 🛑 **`has_photo` does NOT come from `imageDataAvailable`, and that matters.**
  That flag is true only for `ZIMAGEDATA`, the full-size copy. A card whose
  picture lives in `ZTHUMBNAILIMAGEDATA` alone reads back as having **no
  picture**, while Contacts.app shows it perfectly well. Measured: **103 of the
  444 picture-bearing cards here are thumbnail-only.** Worse, a card written by
  `--photo` lands in the full column and macOS moves it to the thumbnail column
  soon after — so a write confirmed as present starts reporting absent minutes
  later. Six real contacts did exactly that, and every write had been correct.
  Presence is read from the AddressBook store instead: ids only, never a blob.
- ⚠️ **That store read needs Full Disk Access**, like the note reader. Without it
  `has_photo` falls back to `imageDataAvailable`, which under-reports rather
  than over-reports.
- **The write is read back and confirmed** against both sources, like every
  other field.
- ⚠️ **There is no flag for social-profile rows.** A LinkedIn or Facebook link
  can live in `ZABCDSOCIALPROFILE` rather than in a URL field, and nothing here
  reads or writes those. `--url` only touches the URL field.

🛑 **Multi-value flags replace; `--add-*` appends.** Passing `--email` on `edit`
replaces *every* existing email on that contact, and prints `Updated '<name>'`
either way. The name reads as additive: `edit --url X` looks like "set the URL",
not "delete every URL, then set X".

```
apple contacts edit <id> --add-url "wiki:https://c.example.com"    # keeps the rest
apple contacts edit <id> --remove-url "https://b.example.com"      # drops just that one
apple contacts edit <id> --url "only:https://d.example.com"        # deletes the rest
```

⚠️ **Agents are the caller this hurts most.** One told to "add the school
website" has no reason to read the card first. A peer session nearly destroyed a
real contact's URLs that way — the card happened to hold exactly one, so the
replace was indistinguishable from an update.

- `--add-email`, `--add-phone`, `--add-url` and `--add-address` keep what is
  there. The plain flags still replace, so nothing that relied on them breaks.
- ⚠️ **Re-adding an existing value is a reported no-op, not a duplicate row** —
  the shape `link` and `groups add` use. Phones compare on **digits**, so
  `+1 (555) 000-0001` does not land twice beside `+15550000001`. The same value
  under a *different* label is a new entry.
- ⚠️ **Mixing `--email` with `--add-email` is refused**, since "replace then add"
  and "add to what was set" differ and one reading loses a value. `apple
  reminders` refuses `--tag` alongside `--add-tag` for the same reason.
- 🛑 **The AddressBook fallback writes the whole multivalue at once**, so an
  append reads the existing entries back first. A replace does not need to. That
  is the path where getting it wrong deletes the values it was meant to keep, and
  it is the normal path for the 52 note-bearing contacts here.

🛑 **`--remove-*` is how you delete ONE value.** Before it existed the only route
was the plain flag: read the card, then re-pass everything except the entry to
drop. That makes the caller reconstruct each remaining label exactly, so one typo
turns a deletion into a silent loss of something else.

- ⚠️ **The VALUE identifies the entry; a label only narrows it.** Same shape
  `unlink` uses. `--remove-url https://b` drops it under any label;
  `--remove-url "blog:https://b"` drops only the labelled one.
- 🛑 **A removal matching nothing is an ERROR**, and the message names what the
  card does hold. A no-op would let `--remove-email a@x.con` read as done. That
  is deliberately the opposite of `--add-*`, where re-adding an existing value
  already achieves the intent.
- ⚠️ **Removal runs before the append**, so `--remove-x A --add-x A` ends with A
  present. The other order would delete what was just added.
- 🛑 **An address is nameable by its street or its full structured form**, and
  the pre-flight check must accept exactly what the write removes. Checking only
  one form refused `--remove-address "work:1 Main St"` for an address the write
  would have taken.

⚠️ **A plain flag now says what it discards**, and still replaces:

```
warning: --url replaces every url on this contact. Discarding 2 (work, blog).
         Use --add-url to keep them, or --remove-url to drop just one.
``` `--clear-dates` empties the labelled-date set (the
birthday is a separate field and survives); it is refused alongside
`--date`/`--anniversary`, allowed alongside `--died`.

⚠️ **`--MM-DD` needs `=`.** `--birthday --04-13` fails, because the parser reads
the value as the next flag. Write `--birthday=--04-13`, and likewise for
`--anniversary`, `--date` and `--died`.

**Every write is read back and checked.** `add` and `edit` re-read the contact
and confirm each labelled value asked for is really there, failing loudly
otherwise. It is a subset check, because `get` returns the unified contact and a
linked card can contribute values this edit never mentioned.

⚠️ **`delete` is permanent.** Unlike Notes there is no Recently Deleted, and the
deletion syncs everywhere. Always confirm with the user first. Deleting a
*group* keeps its contacts; removing a member keeps the contact too.

**Labels.** Friendly names: `home`, `work`, `school`, `other`, plus `mobile`,
`iphone`, `main`, `pager`, `applewatch` for phones, `icloud` for email and
`homepage` for URLs. Unlabelled values are accepted for email/phone/url. **Any
other label is kept as a custom label, with its case** — `--url
"LinkedIn:https://…"` reads back as `LinkedIn`. That is what makes the "read it
first, re-pass what you want to keep" workflow safe: **`get` → `edit` → `get` is
a no-op** for every multi-value field, pinned by a test.

⚠️ **`--url` splits on the first colon and has to decide whether the prefix is a
label or a scheme.** A built-in label wins; otherwise a prefix is a scheme when
the rest starts `//` or is one unbroken token with no scheme of its own.
`LinkedIn:https://x.com` stays a label, `webcal:cal.example.com/f.ics` is a URL,
and the genuinely ambiguous `LinkedIn:example.com` is read as a URL with a note
on stderr. 🛑 The older allowlist stripped schemes silently.

**Postal addresses.** `--address` takes free text or exact fields:

```
apple contacts edit ID --address "home:500 W Madison St, Chicago, IL 60661"
apple contacts edit ID --address "home:street=500 W Madison St;city=Chicago;state=IL;zip=60661"
```

⚠️ **Free text is a guess, and the tool prints what it decided** on stderr before
writing. It knows one shape, `street, city, STATE ZIP, country`, and nothing
about any other country's conventions. When it gets one wrong, use the
`key=value` form; `zip` and `postalCode` are both accepted, so what `get` prints
can be passed straight back. A typo'd key is a hard error, not a dropped field.

**Deaths.** `--died` on `add`/`edit` writes one, `deceased` lists them.

```
apple contacts edit <id> --died 2020-04-30     # a full date
apple contacts edit <id> --died 2020           # only the year is known
apple contacts edit <id> --died=--04-30        # the day, but not the year
```

🛑 **Apple defines no death field**, so it is a custom date label — `death`, or
`death-year` when only the year is known. Contacts refuses a date with no month
and day, so **a year-only death stores a placeholder `2020-01-01`** and the label
is the only disclosure.

- **Read `died`, never the raw `dates` array**, which still shows the
  placeholder. **`died_precision`** is `date`, `year` or `day-only`.
- **`deceased` is absent, never `false`**, like every other optional key here.
- 🛑 **`--died` merges; `--date` replaces.** That is the whole reason it is its
  own flag. Restating `--died` at a different precision replaces the old entry.
- 🛑 **`--died` also marks the note with `«†»`**, because on this address book
  recording a death and marking the card are one act. `--no-mark` records the
  date alone, and is the escape hatch when Automation → Contacts is missing.
- ⚠️ **Written as `«†»`, detected as a bare `†`.** A card marked by hand or on
  another device counts as marked and is never marked twice. The marker goes on
  top, then a blank line, then whatever the note already held.
- **`--clear-note` with a marking `--died` is refused**, and so is `--no-mark`
  on its own. Neither combination has one meaning.
- **`marked_without_date`** lists cards whose *note* carries a dagger and which
  record no date. That marker is never the record and never makes anyone
  deceased. Resolve one with `edit --died`.

**Relations.** `--relation father:"Robert Hopkins"`. All 216 SDK relation labels
are accepted; matching ignores case, spaces and hyphens. An unrecognised label is
still stored, as a custom label, with near matches on stderr.

```
apple contacts relations <id>                       # both directions
apple contacts link <id> <id> --relation spouse     # writes both cards
apple contacts link A B --relation father --inverse son
apple contacts link A "David M. Merritt" --relation spouse --name-only
apple contacts unlink A B --relation friend
```

- 🛑 **A relation stores a NAME, not a reference.** Renaming a contact silently
  breaks every link to it, a relation can name nobody, and a relation can name
  several people. `matches` in the JSON says which you have.
- 🛑 **`link` appends; `edit --relation` replaces.** Adding one relation through
  `edit` means re-passing every existing one, and forgetting one deletes it.
- ⚠️ **`link` writes the other card too**, so it states a fact about someone else.
  **The label describes the SECOND contact**: `link A B --relation manager` reads
  "B is A's manager", and gives B an `assistant` relation naming A.
- 🛑 **A gendered label inverts to the neutral term** — `father` → `child`,
  `brother` → `sibling`. Pass `--inverse son` for the specific one. Seven labels
  have no neutral inverse and refuse, naming what to pass instead.
- 🛑 **`--name-only` is the one way to name somebody who has no card**, and it is
  opt-in so a typo in a real name is still refused.
- **Both arguments take an id or a name.** An ambiguous name is refused listing
  the candidates. Re-linking is a reported no-op, not a duplicate. Every write is
  confirmed against a fresh store. `--dry-run` prints the plan without writing.

**Dates.** `--birthday` and `--anniversary` are the two Contacts models natively.
Everything else is a labelled date: `--date graduation:--06-15`.

**Search** matches first/middle/last/nickname/company/department/job title/full
name, email addresses, and phone numbers (digits only, so `7205551234` finds
`+1 (720) 555-1234`). **JSON is the default**; pass `--plain` for human output.

**Output shapes.** `get`, `add` and `edit` return a single JSON **object**;
`search`, `list` and `groups members` return **arrays**. An unlabelled email,
phone or URL omits the `label` key rather than emitting `null`. The JSON keys for
the name affixes are `prefix` and `suffix`, though the flags are `--name-prefix`
/ `--name-suffix`.

**Groups, and the account rule.** 🛑 **A contact can only join a group in its own
account**, and one save cannot span two containers. `groups add` detects the
mismatch before saving, names both accounts, and points at `move`:

```
Error: cannot add 'Kyle Zehner' to 'Recruiters': they are in different accounts,
and one save cannot span two.
  contact: On My Mac (local)
  group:   🌈 (cardDAV)
Move the contact into the group's account, then retry:
  apple contacts move <id> --to "_local:ABAccount" --dry-run
```

- ⚠️ **`changed` is the field to read on `groups add`/`groups remove`, not the
  exit code.** Both return `{group, contact_id, member, changed}`: `member` is
  the state after the call, re-read to confirm it; `changed` says whether *this*
  invocation did it. Both fail loudly if a save reports success without taking
  effect.
- 🛑 **`groups remove` silently does nothing on an iCloud group** through
  `CNSaveRequest`, and falls back to the legacy AddressBook framework.
- 🛑 **A contact has two identifiers**, unified and container-backed, and a
  membership check must accept both. Never hand `addMember` a *unified* contact.
- ⚠️ **An unrecognised `--container` is a hard error**, not a silent default.
  Names work as well as ids: `--container "On My Mac"`.

**`move` changes a contact's account and keeps its identifier.** There is no
public API for it; the legacy `importPeople:intoAccount:createNewUIDs:false` is
the only route that preserves the id and the note.

```
apple contacts move ID --to CONTAINER [--dry-run] [--json]
```

- 🛑 **The obvious private call lies.** `nts_MoveIntoAddressBook:account:error:`
  returned `YES` for a record still in the source store. So `move` re-reads the
  container from a fresh store and exits non-zero on a mismatch.
- 🛑 **A contact that carries a note cannot be moved** — copying the note faults
  it, and Core Data *raises* there rather than returning. Refused up front. Move
  those in Contacts.app.
- ⚠️ **A move always drops every group membership in the account it leaves.**
  `--dry-run` lists them first; the result carries `groups_left` either way.
- If the removal fails, the import is **rolled back**; if the copy cannot be
  named precisely, nothing is deleted and the duplicate is reported.
- ⚠️ Only `local` ↔ `cardDAV` has been exercised. The **"me" card** is untested.

🛑 **A note blocks *every* `CNContactStore` write to that contact**, not just the
note, and it fails as a bare `NSCocoaErrorDomain 134092` naming nothing. **52 of
669 contacts here carry one.** `edit`, `groups add`, `link` and `unlink` catch it
and rewrite through the legacy AddressBook framework, which needs no extra grant.

**Writing the note is the one thing that leaves the Contacts framework.**
`CNContactNoteKey` needs `com.apple.developer.contacts.notes`, which no CLI can
hold, so `--note` goes through Contacts.app over AppleScript. Full record in
[`docs/apple-contacts-writes.md`](apple-contacts-writes.md).

```
apple contacts edit <id> --note "text"          # replaces the whole note
apple contacts edit <id> --append-note "line"   # keeps it, adds a line
apple contacts edit <id> --clear-note           # deletes it
```

- 🛑 **The legacy AddressBook framework is NOT a second route, despite being the
  fallback for every other field.** Measured: `ABPerson` + `kABNoteProperty` read
  **0 notes across 683 contacts**, raising the same 134092 on every one, while
  `get` reported 52 off SQLite at that moment. It gets *past* the wall, not
  *through* it.
- ⚠️ **`--note` replaces the whole note**, and warns naming the characters and
  lines it discards. **`--append-note` keeps it** and adds a line. Mixing the two
  is refused, as is `--clear-note` with either. Same rule as `--email` /
  `--add-email`.
- ⚠️ **A note write needs Automation → Contacts and launches Contacts.app.**
  Reads need neither. `apple contacts status` reports it as `automation` /
  `note_writes`; `usable` stays keyed to the Contacts grant, so a missing
  Automation grant costs one field rather than the tool.
- 🛑 **On `add` the note is a second write**, and the contact exists before it can
  fail. Read "the note did not land" as *created but un-noted*.
- **Every write is confirmed twice**: Contacts.app returns what it wrote, and
  `NoteStore` re-reads the SQLite store. Multi-line notes, emoji, quotes,
  backslashes and tabs all round-trip byte-identical.
- ⚠️ **`--clear-note` is idempotent** and makes `get` omit the `note` key
  entirely, never report `""`.

`get` reports a contact's `groups`; `search` and `list` don't, because Contacts
has no reverse lookup and it would mean scanning every group per contact.
