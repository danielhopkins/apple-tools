# phone — `apple phone`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple phone`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

Reads `CallHistory.storedata` directly, the same way messages reads `chat.db`, and
resolves caller names out of the AddressBook stores under the same grant. Works
with Phone.app closed. **Read-only except `dial`.** Schema and the six store traps
are in [`docs/apple-phone-store.md`](apple-phone-store.md), each pinned by a
test in `swift/Tests/PhoneTests/`.

```
apple phone recents [--limit N] [--since DAYS] [--before DAYS]
                    [--missed | --incoming | --outgoing] [--unknown] [--blocked-only]
                    [--kind phone|facetime-audio|facetime-video] [--handle H] [--json]
apple phone search QUERY  <same filters>            # name, number, or place
apple phone stats  <same filters> [--json]          # counts, talk time, top callers
apple phone blocked [--json]                        # read-only
apple phone recordings [--json]                     # signpost → `apple notes`
                                                    #   (alias: transcripts)
apple phone dial TARGET [--facetime-audio] [--dry-run] [--json]
apple phone status [--json]
```

`recents` is the default subcommand, so `apple phone` alone lists recent calls.

**Names are the whole point.** `ZNAME` in the store is empty (1 row of 289), so
every caller is resolved against Contacts and reported with a `name` and a `known`
flag. `--unknown` narrows to callers you have not saved, which is the short path
from "who called me yesterday" to `apple contacts add`.

- **Contact resolution has three states, not a boolean**: `available`,
  `noAddressBook` (nothing to read — correct and silent), and `unreadable` (a grant
  problem). `--unknown` **refuses** in the last case, because with an unreadable
  address book every caller would match and the whole store would come back looking
  like an answer. `--json` **omits `known` entirely** there rather than emitting
  `false`, and sets `contacts_unavailable: true`.
- **A missing address book is not an error.** Call history still reads; only names
  go missing.

⚠️ **This is a relay mirror, not full history.** Four months here against an iPhone
that keeps years. Say "recents", never "all calls".

🛑 **`ZANSWERED` means "answered by me", so it is `0` on every outgoing call.**
Treating it as "connected" reports everything you dialled as missed. Connected is
`ZDURATION > 0`, which is orthogonal to direction. This is the one store trap worth
knowing at the call site; the rest — the Apple-epoch **seconds** against `chat.db`'s
nanoseconds, the `REAL` column that never matches a text comparison, the
unnormalised `ZADDRESS`, the write-ahead log that `immutable=1` will not replay,
and the fact that sqlite treats a 1-byte file as a valid empty database — are in
the doc.

🛑 **Blocking a caller is impossible, and the API lies about it.** The
`CommunicationsFilter` C functions are reachable by `dlopen` and *appear* to work,
but the XPC to `cmfsyncagent` needs `com.apple.private.communicationsfilter` and is
**denied silently**: `CMFBlockListIsItemBlocked` returns `false` for a number that
is demonstrably on the list. So there is no `block` command; one would report
success and change nothing. `blocked` reads the list, and `recents` flags callers
already on it. Signing and notarising would not change this. Block in Phone.app or
System Settings; the iPhone is what filters relayed calls anyway.

🛑 **Voicemail is not on this Mac at all.** No local store exists (`ZHASMESSAGE` is
`0` on every row), `vmd` does not exist on macOS, and `vmshow://` needs a UUID
nothing local can enumerate. `voicemail-*.m4a` files under
`~/Library/Messages/Attachments` are ones people *forwarded over iMessage*, not an
inbox. There is nothing to list and nothing to mark read.

🛑 **Call recordings are not here either — they belong to `apple notes`.** `apple
phone recordings` (alias `transcripts`) is a **signpost that prints where to go and
exits**, deliberately, so it can never imply a call and a recording are the same
object. An iPhone call recording syncs as a *note*. ⚠️ **The two stores do not join
cleanly**: recording is started by hand partway through a call, so neither timestamp
nor duration matches, and a number dialled repeatedly makes even an interval match
ambiguous. Do not report a call and a recording as the same object without saying
how the match was made.

**`dial` hands a `tel:` URL to Phone.app and Phone.app always asks you to confirm**
— skipping the prompt needs `com.apple.FaceTime.NoPrompt`, an Apple-internal
entitlement. That prompt is the gate, so there is no `--confirm` flag, and the tool
will never click the panel for you. `--dry-run` shows the URL without placing
anything. `TARGET` may be a number, an Apple ID, or a contact name — a name resolves
against the address book, prefers the number that person most recently used, and an
ambiguous name is an error rather than a guess.

`--json` keys: `status` (`outgoing`/`incoming`/`missed`), `kind`, `handle`,
`number`, `duration`, `connected`, `known`, `blocked`, `name`, `contact_id`,
`location`, plus `call_type` so an unrecognised type is visible rather than hidden
behind `kind: "unknown"`.
