# Prior art

Other people solving the same problem — local CLI/agent access to Apple's apps.
Kept so that when we add a feature we check whether someone has already hit the
wall we're about to walk into.

**Metrics gathered 2026-07-27** and not maintained automatically; re-run the
commands at the bottom before trusting them. Everything below distinguishes what
was verified by reading code from what is only inferred from metadata — the
whole value of this file is that it doesn't guess.

## The field

| Project | Lang | ★ | Created | Last push | Notes |
|---|---|---|---|---|---|
| [supermemoryai/apple-mcp](https://github.com/supermemoryai/apple-mcp) | TypeScript | 3127 | 2025-02-19 | 2025-08-11 | **archived 2026-01-01** |
| [omarshahine/apple-pim](https://github.com/omarshahine/apple-pim) | Swift | 7 | 2026-01-22 | 2026-07-20 | largest codebase here |
| [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | TypeScript | 172 | 2025-02-14 | 2026-07-07 | Swift EventKit backend |
| [BRO3886/ical](https://github.com/BRO3886/ical) | Go | 68 | 2026-02-11 | 2026-06-21 | calendar only |
| [schappim/ekctl](https://github.com/schappim/ekctl) | Swift | 55 | 2026-01-21 | 2026-06-10 | no license |
| [more-io/claude-apple-bridges](https://github.com/more-io/claude-apple-bridges) | Swift | 29 | 2026-02-22 | 2026-07-03 | closest peer |

## Per project

### apple-mcp — the popular one, and dead

MCP server over Messages, Notes, Contacts, Mail, Reminders, Calendar, Maps.
By far the most adopted (3.1k stars) and **archived on 2026-01-01**, last pushed
2025-08-11. Treat as a museum piece, not a dependency.

Worth it for: **Messages** and **Maps**, the two surfaces nothing here covers.
Messages is the interesting one — `chat.db` is readable the same way
`NoteStore.sqlite` is.

*Not verified:* its per-app implementation. The README doesn't say and the file
listing (`utils/{calendar,contacts,mail,maps,message,notes,reminders}.ts`)
doesn't either. If it turns out to be AppleScript throughout, assume it carries
every trap in [CLAUDE.md](../CLAUDE.md) — the Mail compose bugs, the 120s
AppleScript timeout that returns `[]`, the CardDAV `removeMember` no-op — none
of which are visible without testing writes against real data.

### apple-pim — the most substantial peer

300 files, ~40 test files, SwiftPM package plus a `helper/Info.plist`, pushed
2026-07-20. Spawns native Swift binaries (calendar, reminders, contacts, mail)
against EventKit and the Contacts framework — the same architecture as this
repo.

The `helper/` bundle is worth reading if we ever revisit TCC: an app bundle is
the other way to get a stable TCC identity, versus the disclaim trick we use.

*Verified by reading `swift/Sources/MailCLI/` — and we took the idea:*

- **Its mail reads do not use AppleScript.** `EnvelopeIndex.swift` opens
  `~/Library/Mail/V*/MailData/Envelope Index` read-only and joins
  `messages`/`message_global_data`/`subjects`/`addresses`/`mailboxes`;
  `EmlxReader.swift` parses bodies off disk. A `--engine auto|sqlite|jxa` flag
  runs SQLite first and falls back to JXA on any throw. This is a better idea
  than anything we had for mail and **we now do the same** — see
  [`apple-mail-store.md`](apple-mail-store.md). Their `emlxSubpath` digit
  scheme is correct; we re-derived it against a real store and it matches.
- **No `responsibility_spawnattrs_setdisclaim`** anywhere in the repo, so its
  Full Disk Access is terminal-attributed, same as ours.

Where we went further, having hit these on real data:

- **Content search.** They punt `--field content` back to JXA because the index
  has no bodies (`SQLiteEngine.swift:154`). We scan the `.emlx` files instead,
  concurrently and newest-first with early exit — full-text over a 41k store in
  ~9s worst case. This was the biggest win available and they left it.
- **WAL staleness.** Opening the index with `immutable=1` silently hides
  everything in the write-ahead log, which on this machine was 2.2 MB of the
  most recent mail. We open `mode=ro` so SQLite replays it, treat `immutable=1`
  as a fallback, and report the result as stale when we use it.
- **Account names.** They read `ZACCOUNTDESCRIPTION` from the child account row
  in `Accounts4.sqlite`; on this machine that is empty for every IMAP account
  and the real name lives on `ZPARENTACCOUNT`. Without the join you get UUIDs
  where the user expects names.
- **Trash/junk spellings.** Theirs lists junk names only; trash is
  `Deleted Messages` / `Deleted Items` / `[Gmail]/Trash` depending on account
  type, and missing one leaks deleted mail into results.

*Still not verified:* its calendar, reminders and contacts behaviour.

### claude-apple-bridges — closest to us in intent

Swift CLIs over Reminders, Calendar, Contacts, Notes, Mail, plus a `tmux-bridge`
we have no equivalent of. Ships a Claude skill, like we do. Solo project (54 of
55 commits by one person), but disciplined: 28 tagged releases in five months.

*Verified by reading the source and Makefile:*

- Compiles each single-file `.swift` with `swiftc`, embeds an `Info.plist` via
  `-sectcreate`, and codesigns with its own identifier
  (`com.claude.contacts-bridge`). **Independently arrived at the same usage-
  description approach we did** — good corroboration that it's correct.
- **No `responsibility_spawnattrs_setdisclaim`.** Its grants are still
  attributed to the calling terminal, so it has the failure we fixed in
  26.727.9: works in one terminal, silently denied in another.
- **No contacts groups at all** — no `CNGroup`, `addMember` or `removeMember` —
  so it never met the CardDAV silent no-op.
- Testing is one 188-line `test.sh`, ~13 assertions.

**Idea worth taking:** its newest commit is `fix(contacts): update appends
instead of replacing + add remove command`. That is the opposite of our
semantics — we document "multi-value flags replace, they don't append" as a
sharp edge. Theirs is arguably the safer default: ours means an agent that
passes `--email` without reading the contact first silently destroys the other
addresses. Changing it would break existing behaviour, so it needs a decision,
not a drive-by.

### mcp-server-apple-events

MCP server for Reminders and Calendar with a standalone Swift EventKit backend;
108 files, ~37 test-ish, `scripts/event-Info.plist`. Actively pushed
2026-07-07. Same embedded-plist approach again.

### ical

Go, EventKit via cgo, calendar only, 85 files with ~14 test files. Full CRUD,
natural-language dates, recurrence, and **import/export** — relevant now that we
have vCard export but no import. Claims ~3000× faster than AppleScript, which
matches why we moved off AppleScript for Calendar.

### ekctl

Small Swift CLI for Calendar and Reminders over EventKit with JSON output; 17
files, one test file. Same `Info.plist` + `Package.swift` shape as ours.
**No license file** — don't copy code from it.

## What we have that they don't

Recorded so we don't "discover" it again, and so it's obvious what's actually
load-bearing here:

- **TCC identity that follows the tool, not the terminal**
  (`responsibility_spawnattrs_setdisclaim`). Nothing surveyed does this.
- **The CardDAV group-removal workaround.** `CNSaveRequest.removeMember` is a
  silent no-op for iCloud groups and works for local ones; the legacy
  `AddressBook` framework handles both. No surveyed project implements contact
  groups at all.
- **Verified write paths.** 37 contacts + 25 calendar + 19 mail + 11 unit tests
  against real data. The nearest peer has ~13 assertions.
- **The trap list in [CLAUDE.md](../CLAUDE.md)** — every entry cost a real
  debugging session and is pinned by a test.

## Open ideas sourced from here

- **Messages** (`chat.db`) — the clearest gap; apple-mcp covers it, we don't.
- **vCard import** — we export, `ical` shows import is expected.
- **Append-vs-replace for multi-value fields** — see claude-apple-bridges above.
- **App-bundle TCC identity** — `apple-pim`'s `helper/` as an alternative to
  disclaiming.
- ~~**Read mail from the store rather than AppleScript**~~ — done, taken from
  `apple-pim`. This is the file's one clear payoff so far: reading a peer's
  source turned a 154s search into a 0.04s one.
- **A body index.** Content search re-reads and re-decodes 3.4 GB every time.
  Mail's own `Protected Index Journals` may already hold something usable; if
  not, a local SQLite FTS table over decoded bodies would make it instant, at
  the cost of staleness and a cache to invalidate.

## Refreshing this

```
for r in supermemoryai/apple-mcp more-io/claude-apple-bridges \
         omarshahine/apple-pim FradSer/mcp-server-apple-events \
         schappim/ekctl BRO3886/ical; do
  gh api "repos/$r" --jq '"\(.full_name)\t★\(.stargazers_count)\tpushed \(.pushed_at[0:10])\tarchived=\(.archived)"'
done
```

To check whether a project handles something before we build it:

```
gh api "repos/OWNER/REPO/git/trees/HEAD?recursive=1" --jq '.tree[]|select(.type=="blob")|.path'
```

Read the source before concluding anything from a name. Several claims in this
file were wrong on the first pass precisely because they were inferred from
filenames and shebangs rather than checked.
