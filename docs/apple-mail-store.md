# The on-disk Mail store

How `apple mail` reads mail without talking to Mail.app: the SQLite index at
`~/Library/Mail/V10/MailData/Envelope Index` for metadata, and the `.emlx`
files under `~/Library/Mail/V10/<account-uuid>/` for bodies.

Everything here was verified against a real store (41,306 messages, 3.4 GB) on
macOS 27 and is pinned by `swift/Tests/MailTests/`. Re-check before trusting it
on a new macOS version — none of this is API, and Apple owes us nothing.

## Why

The AppleScript path is not slow at the margin, it is slow by orders of
magnitude. Same binary, same query (`search invoice --field subject --limit 5`),
Mail.app running, 41k messages:

| Engine | Wall clock |
|---|---|
| `--engine filesystem` | **0.04 s** |
| `--engine applescript` | **154 s** |

The AppleScript run did return the right answer — it just took two and a half
minutes, past the ~120s Apple Event timeout that in other runs produces an empty
list and exit 0. Reading the files directly is ~3,500× faster and cannot fail
that way.

It also unlocks a capability the AppleScript path never had. `--field content`
greps decoded message bodies across the entire store in **8.7 s** worst case
(every one of 39,972 candidate bodies read, decoded and searched, nothing
found); a typical hit-early search returns in under a second. The old
implementation could not finish this at all.

## Layout

```
~/Library/Mail/V10/
├── MailData/
│   ├── Envelope Index          the SQLite index (WAL mode)
│   ├── Envelope Index-wal      ← must be replayed; see "Staleness"
│   └── Envelope Index-shm
└── <ACCOUNT-UUID>/
    └── <Mailbox>.mbox/
        └── <STORE-UUID>/
            └── Data/
                └── <digits>/Messages/<rowid>.emlx
```

`V10` is the store-format version; discover the highest `V<n>` rather than
hardcoding it.

## Envelope Index schema

Only the parts we use. Message metadata is normalised across five tables:

```sql
SELECT m.ROWID, g.message_id_header, a.address, a.comment,
       m.subject_prefix, s.subject, m.date_received, m.read, m.flagged, b.url
FROM messages m
JOIN message_global_data g ON m.global_message_id = g.ROWID
JOIN mailboxes b           ON m.mailbox           = b.ROWID
LEFT JOIN subjects  s      ON m.subject           = s.ROWID
LEFT JOIN addresses a      ON m.sender            = a.ROWID
WHERE m.deleted = 0
```

Traps, each one a wrong answer rather than an error:

- **`messages.deleted = 0` is not optional.** Deleted messages stay in the
  table. Omit the filter and you resurrect mail the user deleted.
- **The subject is split in two.** `messages.subject_prefix` holds `"Re: "` /
  `"Fwd: "`, `subjects.subject` holds the rest. Neither alone is what the user
  saw; concatenate them.
- **`message_global_data.message_id_header` can be NULL.** Such a row cannot be
  addressed by `export`, so it is filtered out.
- **`recipients.type`** is 0 for To, 1 for Cc, ordered by `position`.
- **Dates are INTEGER unix epoch seconds**, not Core Data's 2001 epoch.
- **There is no body anywhere in this database.** Content search has to read
  files.

Useful indexes already exist (`messages_date_received_index`,
`messages_mailbox_date_received_index`), which is why an unbounded
`ORDER BY date_received DESC` over 41k rows is free.

### Mailbox URLs

`mailboxes.url` encodes the account and path:

```
imap://F0B7E186-…/Sent%20Messages
imap://3CB7FB07-…/%5BGmail%5D/Trash        → ["[Gmail]", "Trash"]
local://66C76001-…/Recovered%20Messages%20(%F0%9F%8C%88)
ews://4061B1C3-…/Deleted%20Items
```

Percent-decode each path component. The scheme (`imap`, `ews`, `local`) is the
account type. The last component is the display name; **all** components are
needed to find the `.mbox` directory.

⚠️ **Mailbox names are not unique.** Three accounts here have an `Archive`.
Resolve a message's `.emlx` by its mailbox *URL*, never by name.

⚠️ **Trash and junk are named differently per account type** — `Deleted
Messages` (IMAP), `Deleted Items` (Exchange), `[Gmail]/Trash`, and `Junk` /
`Junk Email` / `Spam`. Excluding "trash" by one spelling silently leaves the
other two in the results.

### Account display names

The mailbox URL gives an account UUID; the names users recognise (here: emoji)
live in `~/Library/Accounts/Accounts4.sqlite`.

⚠️ **The mail account row usually has no name of its own.** It carries a
`ZPARENTACCOUNT` pointing at the row that does. Reading only the child yields
blank names:

```sql
SELECT child.ZIDENTIFIER,
       COALESCE(NULLIF(child.ZACCOUNTDESCRIPTION, ''), parent.ZACCOUNTDESCRIPTION),
       COALESCE(NULLIF(child.ZUSERNAME, ''), parent.ZUSERNAME)
FROM ZACCOUNT child
LEFT JOIN ZACCOUNT parent ON child.ZPARENTACCOUNT = parent.Z_PK
WHERE child.ZIDENTIFIER IS NOT NULL
```

Verified to produce **the same names Mail's own AppleScript reports** — on this
machine both engines return `🏫`, `🌈`, `☀️` for the three remote accounts.

`accounts` still prefers Mail when Mail is already running, for two things the
store does not record: whether an account is `enabled`, and Mail's own ordering.
The file-system answer therefore has no `enabled` key (read it as
`.get("enabled", True)`), gains `id` and `type`, and additionally lists the
local "On My Mac" store that the AppleScript path omits.

### Staleness

The index is in **WAL mode**, and Mail leaves a multi-megabyte `-wal` behind
even when it is not running.

⚠️ **Do not open it with `immutable=1`.** That bypasses the WAL, so the read
silently returns a snapshot from the last checkpoint — missing exactly the
recent mail a search is most likely about. Open read-only (`mode=ro`) so SQLite
replays the WAL. `immutable=1` is a last-resort fallback only, and when it is
used `apple mail status` and every search report the result as possibly stale
rather than hiding it.

## Finding a message body

```
V10/<ACCOUNT-UUID>/<Comp1>.mbox/<Comp2>.mbox/<STORE-UUID>/Data/<digits>/Messages/<rowid>.emlx
```

- The filename **is** `messages.ROWID`.
- `<digits>` are the digits of `rowid / 1000`, **least-significant first**:
  `84 → Data/Messages/`, `12345 → Data/2/1/Messages/`,
  `105895 → Data/5/0/1/Messages/`.
- `<STORE-UUID>` is not recorded anywhere we can read, so glob the directories
  under the `.mbox`.
- The file may be `<rowid>.partial.emlx` — a partly-fetched body. It still
  parses and is better than reporting the message missing.
- A message in the index with **no file** has not been downloaded. That is the
  one case where the AppleScript engine can still do something the file-system
  engine cannot, and why `--engine auto` keeps the fallback.

## The .emlx format

```
<decimal byte count>\n
<RFC 822 message, exactly that many bytes>
<XML plist of Mail's own flags>
```

⚠️ **Use the byte count.** Reading to EOF glues Mail's plist onto the end of
the message body.

Then it is ordinary MIME, with the ordinary MIME hazards:

- Headers fold onto continuation lines starting with space or tab.
- Subjects are RFC 2047 encoded words (`=?UTF-8?B?…?=`, `=?UTF-8?Q?…?=`). In a
  Q-encoded word `_` means space — unlike plain quoted-printable.
- Bodies are base64 or quoted-printable more often than not. **This is why a
  raw `grep` over the corpus is not a content search**: it cannot see inside an
  encoded part. Decoding finds strictly more (175 messages vs grep's 173 raw
  hits for the same term, while also *excluding* trash and junk).
- `multipart/alternative` carries the same content twice; take the plain part
  or you duplicate every body.
- A part with `Content-Disposition: attachment` is a file, not body text, even
  when it is `text/plain`. Checked from the part's headers *before* its body is
  touched, so a 20 MB PDF costs only a header scan.
- Attachments are never searched by default — not contents, not filenames.
  `--attachment-names` opts into filenames, which come from the index rather
  than the files. Contents are never searched at all: non-text parts are not
  decoded, and there is no PDF text extraction.
- Only a boundary at the **start of a line** delimits a part; the same bytes
  appear in prose.

## Why not search the raw bytes instead

Tempting idea: skip MIME decoding by encoding the *search term* into base64 and
quoted-printable and scanning the raw `.emlx` bytes for those. Base64's 3-byte
alignment is solvable — encode the term at each of 3 offsets and keep the
alignment-independent core of each.

**Measured, it is not sound.** Against a 4,000-message sample, a raw-byte scan
using literal + all 3 base64 alignment variants missed real matches:

| Term | True matches | Missed by raw scan |
|---|---|---|
| `quarterly` | 17 | 0 (0.0%) |
| `reschedule` | 57 | 0 (0.0%) |
| `budget` | 116 | 1 (0.9%) |
| `attached` | 362 | 12 (3.3%) |
| `invoice` | 132 | 5 (3.8%) |

The dominant cause is **quoted-printable soft line breaks**, which can split a
word at any position: `invo=\r\nice`. Normalising those away before scanning
recovers most of it (3 of the 5 `invoice` misses), but not all — and at that
point the "cheap" scan is doing a decoding pass anyway.

That matters because the failure is *silent*: a 3% miss rate looks exactly like
a smaller result set. It is the same class of bug as the AppleScript timeout
returning `[]`, which is what this engine exists to eliminate. So the corpus is
decoded properly, and the raw-byte trick is not used.

Two useful measurements fell out of this, for whoever revisits it:

- Only **2.7% of text parts are base64** (43.9% unencoded, 37.5%
  quoted-printable, 13.9% 7bit). The base64 in a mail store is overwhelmingly
  attachments, not bodies.
- Decoded body text is **58% of total `.emlx` bytes**, so skipping attachment
  parts entirely caps out at a ~40% saving — worth having, not transformative.

The real fix for repeat searches is an index (SQLite FTS5 over decoded bodies,
keyed by message ROWID and updated incrementally), which would also bring word
boundaries and ranking. That is a cache with invalidation, so it is a bigger
decision than an optimisation.

## Permissions

Reading all of this needs **Full Disk Access**, granted to the calling terminal
— the same grant `apple notes` needs, and unlike reminders/calendar/contacts it
is *not* redirected to the binary by the disclaim trick. Automation → Mail is
now needed only for `draft` and `send`.

`apple mail status` reports both, and treats the tool as usable if either is in
place, because either one supports real work.
