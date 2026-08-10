# The Messages store

What `apple messages` reads, and the traps in reading it. Everything here was
verified against a real 103,250-message store on macOS 27, not inferred from the
schema.

## Layout

```
~/Library/Messages/
  chat.db                  the index and every message body
  chat.db-wal              write-ahead log — routinely 600 KB of recent messages
  chat.db-shm
  Attachments/<xx>/<yy>/<guid>/<filename>    the files, already decoded
```

`chat.db` is plain SQLite. Reading it needs **Full Disk Access for the calling
terminal** — it is not covered by the disclaim trick that binds reminders,
calendar and contacts to the tool, so the grant follows whatever launched it.
Same as `apple notes` and mail's read path.

### Open it read-only, and let SQLite replay the WAL

```
file:///Users/you/Library/Messages/chat.db?mode=ro
```

`immutable=1` is **not** equivalent. It skips the write-ahead log, silently
serving a view from the last checkpoint — on this machine that hid the most
recent messages. `ChatDatabase` uses `mode=ro`, falls back to `immutable=1` only
when that fails, and sets `isStale` so the staleness is reported rather than
hidden. This is the same trap `apple mail` hit with the Envelope Index.

## Tables that matter

| Table | Use |
|---|---|
| `message` | one row per message; body, dates, flags |
| `handle` | phone numbers and email addresses; `handle.id` is the identifier |
| `chat` | conversations; `style` 45 = direct, 43 = group |
| `chat_message_join` | message → chat |
| `chat_handle_join` | chat → participants |
| `attachment` | file metadata, including the on-disk path |
| `message_attachment_join` | message → attachment |

## ⚠️ The body is in two places, and `text` is not always the one

This is the trap that matters most. On a 103,250-message store:

| | count |
|---|---|
| total messages | 103,250 |
| `text IS NULL` | 4,227 |
| ...of those, carrying an `attributedBody` | 2,526 |
| ...of those, **ordinary messages with real words** | 1,921 |

A reader that does `SELECT text` drops those 1,921 messages with no error at
all. It looks like gaps in the user's history, not a bug.

The rest of the NULL-text rows are not text to begin with:

| kind | n |
|---|---|
| group/system events (`item_type != 0`) — joins, leaves, renames | 1,517 |
| tapbacks and edits (`associated_message_type != 0`) | 259 |
| app messages (`balloon_bundle_id` set) — links, ScreenTime, Find My | 218 |
| attachment-only | 178 |
| genuinely empty (no text, no archive) | 134 |

`apple messages` classifies each of these rather than printing a blank line, and
excludes system events unless `--include-events` is passed.

### `attributedBody` is a typedstream, not a plist

It is the old **NSArchiver** format — the byte string `04 0B "streamtyped"` —
not `NSKeyedArchiver`. So:

- `NSKeyedUnarchiver` cannot read it.
- `NSUnarchiver` could, but is unavailable to Swift and deprecated besides.
- `PropertyListSerialization` cannot read it; some app-message rows *do* hold a
  bplist in this column, which is why the decoder checks the magic and declines
  anything else.

The layout, from a real row:

```
04 0B "streamtyped" 81 E8 03 84 01 40 84 84 84
"NSAttributedString" 00 84 84 "NSObject" 00 85 92 84 84 84 08
"NSString" 01 94 84 01 2B 21 "There is a drop off line of bikes" 86 ...
                            ^^ ^^
                            |  length (0x21 = 33 bytes)
                            '+' — a length-prefixed byte string follows
```

Lengths are variable-width: a byte below `0x81` is the value itself, `0x81`
introduces a little-endian `uint16`, `0x82` a `uint32`. **Getting this wrong is
invisible on short messages** — every body under 129 bytes uses the single-byte
form — and truncates everything longer. `0x84` and above are stream control
tokens, never lengths.

`TypedStream.decode` reads exactly this one field and stops. The attribute runs
that follow (`__kIMMessagePartAttributeName` and friends) are not needed, and
every byte of parser is a byte that can be wrong.

### How the decoder was verified

99,023 rows carry **both** `text` and `attributedBody`, which makes them a
free ground-truth corpus. Decoding every one and comparing:

| | |
|---|---|
| exact match | **99,022 / 99,023 (99.999%)** |
| mismatch | 1 |

Before normalising, 60 more differed only by `U+FFFC` OBJECT REPLACEMENT
CHARACTER — the archived string keeps one per inline attachment and the `text`
column strips them. The decoder strips them too.

The single remaining mismatch is not a decoding error: that blob literally
stores `U+FFFD` where `text` preserved the original emoji. **The column is the
better source**, which is why `text` takes precedence and the archive is only a
fallback — so this case cannot arise in practice.

## ⚠️ Searching the two body sources needs two queries

Not an optimisation — a correctness bug, and a silent one.

`message.text` can be matched in SQL. An archived body cannot: whether it
matches is only knowable *after* decoding, so every archived row is a candidate
for every query. Match both in one statement with a single `ORDER BY date DESC
LIMIT n` and the two populations compete for the same window.

Measured, searching `trusting` on a real store:

| | |
|---|---|
| rows matching in the `text` column | 6 |
| archived candidates **newer** than the newest of them | 1,796 |

With any limit below 1,796 the window fills entirely with archived rows the
decoder then rejects, and all six real matches fall off the end. The search
returns a confident "no messages found" with the answer sitting just past the
cut. Over-fetching a multiple of the limit does not fix it; it only moves the
threshold.

So the two are queried separately, each limited on its own terms, and merged by
date afterwards. The archived side stays cheap because it is bounded by how many
such rows exist at all (4,227) rather than by the size of the store. Pinned by
`testTextMatchesSurviveAFloodOfNewerArchivedCandidates`, which was confirmed to
fail against the single-query version.

## Dates are Apple-epoch nanoseconds, except when they are seconds

`message.date` counts from 2001-01-01, in **nanoseconds** on anything written by
macOS 10.13 or later:

```sql
datetime(date/1000000000 + 978307200, 'unixepoch', 'localtime')
```

Rows written before that used whole **seconds**, and both spellings coexist in a
long-lived store. `AppleEpoch.date(from:)` sniffs the magnitude rather than
assuming — a nanosecond value is ~10^18, a second value ~10^8.

`date_read`, `date_delivered`, `date_edited` and `date_retracted` use the same
encoding. Zero means unset, not 2001.

## Attachments are already on disk

Unlike Mail — where the `.emlx` keeps an empty MIME part and the bytes live
elsewhere — `attachment.filename` is the real path to the real file, already
decoded. No MIME parsing.

Two things to handle:

- **The path starts with a literal `~`**, which no file API expands. It has to
  be joined onto the home directory by hand.
- **The file may not exist.** iCloud offloads attachments, and one that was
  never downloaded leaves the row behind with nothing at the path. `apple
  messages attachments` reports these as `missing` rather than saving a
  zero-byte file.

Filenames come from the sender, so they are reduced to a bare basename before
being joined onto a `--save` directory.

## Services

`handle.service` and `message.service` distinguish the transports. A real store:

| service | handles |
|---|---|
| SMS | 1,074 |
| iMessage | 420 |
| RCS | 179 |
| SatelliteSMS | 1 |

RCS is present on macOS 27 and is neither SMS nor iMessage; code that branches
on `service == 'iMessage' ? ... : 'SMS'` mislabels it.

## Group chats are usually unnamed

`chat.display_name` is the user-set group name and is **empty for most groups** —
2 of every 3 on a real store. Falling back to the participant list is what makes
a listing readable; falling back to `chat_identifier` gives `chat761561030201699253`.

## What is *not* here

- **Contact names.** `handle.id` is a phone number or email. Resolving it to a
  person means Contacts, which is a separate tool and a separate grant, so
  `apple messages` reports the raw handle.
- **A write path.** Messages' AppleScript dictionary exposes `send` (direct
  parameter `text|file`, `to` a `participant` or `chat`) and essentially nothing
  else — no read access to history worth having. Sending is not implemented yet;
  when it is, it needs Automation → Messages and the same `--confirm` discipline
  as the removed `apple mail send` did.
- **Deleted messages.** `chat.db` has `deleted_messages` and
  `chat_recoverable_message_join` tables backing Recently Deleted. Not read
  today; a user asking for their history probably does not mean those.
