# whatsapp — `apple whatsapp` (plugin)

CLAUDE.md points here. This file is the working reference for the `whatsapp` plugin. The plugin contract is in [`apple-plugins.md`](apple-plugins.md).

Reads WhatsApp Desktop's store in
`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/`: plain
SQLite, Core Data style. 🛑 **Read-only, no connection, and nothing is
written anywhere.** Python, stdlib only, in `plugins/whatsapp/`; tested
offline by `plugins/whatsapp/test-whatsapp.py`, which builds its own store.

```
apple whatsapp status [--json]
apple whatsapp chats [SEARCH] [--limit N] [--json]
apple whatsapp search QUERY [--chat REF] [--since DAYS] [--before DAYS] [--limit N]
                            [--from-me | --to-me] [--include-events] [--json]
apple whatsapp export CHAT [--limit N] [--include-events] [-o FILE] [--json]
apple whatsapp calls [--since DAYS] [--missed] [--limit N] [--json]
apple whatsapp index [--since DAYS]        # what apple-index calls
```

- 🛑 **THE MAC HOLDS WHAT ARRIVED SINCE WHATSAPP DESKTOP WAS LINKED.**
  Measured on the first run, 2026-09-25: 157 messages in 20 chats, 138 of
  them from the month it was linked, 19 a thin sample back to 2022. The
  full history is on the phone, and nothing on a Mac reads it. Say "not on
  this Mac", never "never said".
- 🛑 **A person has two kinds of id.** `<number>@s.whatsapp.net` carries a
  phone; `<n>@lid` carries none. `ContactsV2.sqlite` maps an `@lid` to its
  number for everyone in the phone's address book (314 of 314 here). A
  handle is `+digits` when a number is known and the raw id when not. It is
  treated as content: a number on a Contacts card matches, anything else is
  never guessed into a person.
- 🛑 **A card can claim an `@lid`**, for someone whose number WhatsApp hides:
  `apple contacts edit <id> --add-url "WhatsApp:whatsapp-lid:<n>"`. The URL
  opens nothing — `wa.me` needs a number — it is a claim. The plugin reads
  every card through `apple contacts list` (1.5s for 712 cards) and gives a
  claimed id the card's name, and the card's first phone or else its first
  email as the handle. `WHATSAPP_CARDS` stands in for the address book in
  tests. ⚠️ **Never create a card just to link someone**; WhatsApp-only
  people stay content.
- ⚠️ **An unmapped `@lid` chat is titled with the number**, because WhatsApp
  lists a stranger under it. The plugin reads the number back out of the
  title. **WhatsApp wraps names in invisible bidi controls** (U+202A …
  U+202C, U+200E); every name is stripped of them.
- 🛑 **The newest messages are in the write-ahead log.** Every file opens
  `mode=ro` through SQLite, never `immutable=1`, which skips the WAL and
  reads as a quiet chat. The test pins it with a WAL-only message.
- ⚠️ **A caption lives in the media row (`ZTITLE`) or in `ZTEXT`,
  depending on the type**, and both are read. Media is folded into the text
  as `[image] caption`, `[voice note 0:42]`, `[link: title]`. **Group
  events and system notices are left out** unless `--include-events`, the
  `apple messages` rule. ⚠️ WhatsApp's own chat carries a year-4000
  last-message date; it reads as no date.
- **Index kinds**: `conversation`, one record per block of ten messages cut
  from the start of the chat (the `apple messages` shape), and `call`. The
  `people` report does not read it yet.
