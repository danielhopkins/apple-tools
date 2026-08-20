# How Mail's scripting interface goes under, and the guards that keep it up

`CLAUDE.md` keeps the rules. This file keeps the measurements. Mail's `.emlx`
and Envelope Index layout is in [`apple-mail-store.md`](apple-mail-store.md); why
nothing here writes a message body is in
[`apple-mail-drafts.md`](apple-mail-drafts.md).

## The failure

🛑 **Driving Mail with a whole-mailbox predicate is how Mail's scripting
interface stops answering** — permanently, until it is restarted, for every
client on the machine.

Measured on a 41k-message store, same binary, same query, Mail running:
`--engine filesystem` 0.04s, `--engine applescript` **154s**.

⚠️ **Killing our `osascript` does not call off the work Mail already started.**
The deadlines below stop *us* hanging and stop us queueing more events; they are
not a way to un-wedge Mail. Only restarting Mail.app does that.

## The guards

- **`search` never falls back.** Without Full Disk Access it reports the missing
  grant and stops. It used to warn on stderr and drive Mail anyway, which turned
  "grant missing" into "Mail wedged". Ask for the old path deliberately with
  `--engine applescript`.
- **`export` still falls back**, because reading a body Mail hasn't downloaded is
  a real reason to ask Mail — but only when Mail is *already running and
  answering*.
- **No read command launches Mail.** If Mail is closed, every AppleScript path
  refuses rather than cold-starting it and handing it a mailbox query.
- **Every AppleScript read is bounded twice.** A wall-clock deadline on the child
  process — one health probe (5s), searches 60s, the export walk 300s — after
  which `osascript` is killed rather than left driving Mail; and a `with timeout`
  *inside* the script, set 5s under that, so the interpreter abandons the Apple
  Event and exits on its own with a clean -1712 instead of being SIGKILLed
  mid-request. `APPLE_MAIL_PROBE_TIMEOUT` / `APPLE_MAIL_SCRIPT_TIMEOUT` override
  the outer one and the inner one follows.
- ⚠️ **A timeout is never swallowed into a short result.** The search script wraps
  its walk in `try` so that a missing mailbox — not every account has an
  `Archive` — is skipped rather than fatal. That handler re-raises -1712 and
  swallows everything else, because a timeout returning whatever it had
  accumulated reads as a complete search and is instead one that stopped partway
  against a Mail that is going under.
- **`--field content`, `--field all` and `--has-attachment` are refused on the
  AppleScript engine** (exit 64), because each makes Mail open every message body
  in the mailbox. They are free on the index — the refusal is about the engine.

⚠️ **The old timeout trap was silent.** AppleScript's event timeout is ~120s, and
the script used to swallow it, so `search` printed `[]` and exited 0 —
indistinguishable from "no matches". A timeout now fails loudly, whether it is
Mail's -1712 or our own deadline, including one that hits partway through a
multi-account walk. The file-system engine never had this mode.

## Reading the Automation grant without waking the bear

🛑 **`AEDeterminePermissionToAutomateTarget` blocks for minutes against a wedged
Mail, then answers wrongly** — and it is how the Automation grant is read without
side effects. Measured: `AECreateDesc` returned in 0.000013s, the permission call
returned **-600 (`procNotFound`) after 502 seconds**, with Mail running at a known
pid throughout. `askUserIfNeeded: false` stops it *prompting*, not *blocking*, and
it runs before any of the deadline machinery, so `APPLE_MAIL_PROBE_TIMEOUT` never
reached it.

It is bounded now (3s, on a detached queue, since the call cannot be cancelled)
and reports **`automation: "unknown"` with `responsive: false`** — a permission
check that will not answer is itself proof Mail is not servicing Apple Events, and
a more accurate answer than the one the API eventually gives. Read `automation:
"unknown"` as "Mail is wedged", not as a grant problem.

⚠️ `apple-messages status` makes the same call for Messages.app and is not
bounded yet; it has never been observed hanging, because nothing scripts Messages.

## Why `move` is allowed to exist

🛑 **`whose id is <rowid>` is the reason, and it must stay that way.** Every
message is resolved against the index first, and Mail is handed an exact id in a
named mailbox — never a walk over `messages of <mailbox>`. Measured on the
37,220-message Archive here: **0.9s, and identical for the newest and the oldest
message in the mailbox**, so Mail resolves it from an index rather than by
scanning. A batch of 8 moved in 0.9s end to end.

🛑 **Mail's AppleScript `id of message` *is* the Envelope Index ROWID.** Verified
against a live store — `first message of <mailbox> whose id is <rowid>` returned
the matching `message id` header every time, including for the oldest message in
a 37k mailbox. This is the join that makes an index-resolved move possible; the
Message-ID header would work as a predicate too, but nothing else gives Mail an
indexed integer to look up.

🛑 **A nested mailbox must be named by its full path, and `accounts` prints the
leaf.** Mail rejects `mailbox "All Mail"` outright (**-1728**) and accepts
`mailbox "[Gmail]/All Mail"`. `move` resolves a leaf name to the full path for
you — path match first, then leaf, then the alias table — but anything else
driving Mail has to know. Ambiguous leaves are refused rather than guessed.

**Only one route removes a draft**, and `delete-draft` implements it. Mail's
`delete` verb silently does nothing, its `move` verb errors, and `set deleted
status` fails with "Connection is invalid". Reassigning `mailbox of <message>` to
the account's trash **does** work — which is also what `apple mail move` uses for
received mail. The trash mailbox is named differently per account type
(`Deleted Messages`, `Trash`, `Deleted Items`), so it tries each.

🛑 **Re-resolve a draft's Message-ID before calling `delete-draft`.** It **changes
when the draft is edited and saved**, and has been observed changing with no edit
at all on IMAP sync. A stale id fails with exit 64, and an `export` of one
silently produces an *empty file* rather than an error.

## What is not there

🛑 **Custom IMAP keywords are not on this Mac, so no tool here can expose them.**
Searched for exhaustively: the `messages` table carries only
`flags`/`read`/`flagged`/`deleted`, the `labels` and `server_labels` tables are
Gmail labels-as-mailboxes (3 rows on this store), and the `.emlx` trailer plist
holds only Mail's own flag bitfield. A `grep -ril` for a keyword known to be set
server-side across all of `~/Library/Mail` returned **zero hits**. Mail discards
them on sync — this is not a gap in the reader. Anything keying off an IMAP
keyword has to run server-side.

## Testing this without wedging Mail

🛑 **Never verify Mail behaviour by scripting its composer.** `open <message>`
then `close <window> saving yes` wedges Mail's scripting interface — reproduced
twice during development, each costing a restart.

`tests/test_mail_wedge.py` is read-only and always runs. It pins the refusals, the
no-launch rule, the deadlines, and the fact that the child `osascript` really
dies. **Run it twice, once with Mail.app open and once closed.** Some assertions
only mean anything in one state, and each half skips in the other rather than
failing, so a single run silently covers about two thirds of it.

Two seams make that testable: `APPLE_MAIL_INDEX_PATH` pointed at a nonexistent
file stands in for a missing Full Disk Access grant, and
`APPLE_MAIL_PROBE_TIMEOUT` shrunk to 0.05s makes a *healthy* Mail trip the
give-up path — the only safe way to exercise it, since there is no way to wedge
Mail on purpose.
