# messages — `apple messages`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple messages`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

Reads `~/Library/Messages/chat.db` directly, the same way mail reads the
Envelope Index. Works with Messages.app closed; a whole-store search over
103k messages takes ~0.1s. **Read-only today** — there is no send path yet.

```
apple messages chats [SEARCH] [--limit N] [--json]   # conversations, recent first
apple messages search QUERY [--chat REF] [--handle H] [--since DAYS] [--before DAYS]
                            [--limit N] [--from-me] [--to-me] [--has-attachment]
                            [--include-events] [--json]
apple messages export CHAT [--limit N] [--include-events] [-o FILE] [--json]
apple messages attachments CHAT [--save DIR] [--skip-stickers] [--limit N] [--json]
apple messages status [--json]
```

`CHAT` accepts a numeric id from `chats`, a chat GUID, a group name, a phone
number, or an email. **An ambiguous reference is an error, not a guess** — it
lists the candidate ids and exits, because exporting the wrong conversation is
a mistake you notice much later.

**Search semantics are identical to mail's**, deliberately: a query is an AND of
substring terms, `dinner friday` matches both words in any order, double quotes
require adjacency. No stemming, no ranking, no boolean operators.

🛑 **The body is in two columns, and `text` is not always the one.** About 4% of
a long-lived store has `text IS NULL` and keeps the body in `attributedBody` as
an archived `NSAttributedString`. On a 103,250-message store that is 4,227 rows,
of which **1,921 are ordinary messages with real words in them**. A reader doing
`SELECT text` drops them silently — it looks like gaps in the history, not a
bug. `apple messages` decodes them and marks the result `text_from_archive` in
JSON.

The format is a NeXT **typedstream** (`04 0B "streamtyped"`), not
`NSKeyedArchiver`, so `NSKeyedUnarchiver` cannot read it and `NSUnarchiver` is
unavailable to Swift. The decoder was verified against the 99,023 rows that
carry *both* columns: **99,022 exact matches (99.999%)**. The one difference is
a `U+FFFD` stored in the blob where `text` kept the real emoji — which is why
`text` wins when present.

⚠️ **Not every text-less row is a message.** The rest are group/system events
(1,517), tapbacks and edits (259), app messages such as link previews and
ScreenTime (218), and attachment-only messages (178). Each is classified in the
`kind` field rather than printed as a blank line. **System events are excluded
by default**; `--include-events` adds joins, leaves and renames.

⚠️ **Handles are phone numbers and emails, never names.** Resolving a person
means Contacts, which is a separate tool and a separate grant. Cross-reference
with `apple contacts search` yourself; `apple messages` reports the raw handle.

⚠️ **Group chats are usually unnamed** — 2 of every 3 on a real store. The
`title` falls back to the participant list, so it is a display string, not an
identifier. Use the numeric `id` to refer to a conversation.

⚠️ **RCS is a third service**, alongside `SMS` and `iMessage` (plus
`SatelliteSMS`). Code that treats anything non-iMessage as SMS mislabels it.

**Attachments are already decoded on disk**, unlike mail's — `attachments
--save DIR` copies them, no MIME parsing involved. But iCloud offloads them, and
a row whose file is gone is reported `missing` rather than saved empty. `--save`
never overwrites; a clashing name gets `-2` before the extension.

Dates are Apple-epoch **nanoseconds** in modern rows and whole **seconds** in
pre-10.13 ones; both coexist and the reader sniffs the magnitude. Timestamps of
`0` mean unset, not 2001.

See [`docs/apple-messages-store.md`](apple-messages-store.md) for the
schema, the typedstream layout, and why searching the two body sources needs two
queries rather than one.
