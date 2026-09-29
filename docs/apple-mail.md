# mail — `apple mail`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple mail`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

🛑 **This tool never writes a message body, and that is the whole design.**
Setting a body through AppleScript wraps it in `<blockquote type="cite">` (Apple
FB11734014) — invisible to the sender, rendered as a quotation by iOS Mail and
Gmail. It cannot be fixed after the fact: rewriting the `.emlx` corrects the file,
and the file is not what the composer opens. A whole compose surface was built on
that rewrite and removed in 26.810.0 when it was measured. Full record in
[`docs/apple-mail-drafts.md`](apple-mail-drafts.md).

So `compose`, `reply` and `forward` **open a Mail window with everything filled in
except the body**, put the body on the pasteboard, and stop. The user presses ⌘V
and ⌘S.

Reads go to Mail's own SQLite index and the `.emlx` files on disk, so they work
with Mail.app closed and return in milliseconds. Schema and traps in
[`docs/apple-mail-store.md`](apple-mail-store.md); the AppleScript deadlines
and the wedge they exist to prevent are in
[`docs/apple-mail-wedge.md`](apple-mail-wedge.md).

```
apple mail accounts [--json]      # names, addresses, mailboxes, enabled
apple mail search QUERY [--account NAME] [--mailbox NAME] [--field subject|sender|content|all]
                        [--since DAYS] [--before DAYS] [--limit N]
                        [--flagged] [--unread] [--has-attachment] [--attachment-names]
                        [--all] [--json]
apple mail export MESSAGE-ID [--account NAME] [--json] [--raw]
apple mail attachments MESSAGE-ID [--save DIR] [--skip-inline] [--account NAME] [--json]

apple mail compose --to ADDR [--cc ADDR] [--bcc ADDR] [--subject TEXT]
                   [--from|--account ACCOUNT-ADDRESS] [--body TEXT | --body-file FILE|-]
                   [--markdown | --html] [--attach FILE]... [--json]
apple mail reply MESSAGE-ID [--all] [--body TEXT | --body-file FILE|-]
                 [--markdown | --html] [--attach FILE]... [--account NAME] [--json]
apple mail forward MESSAGE-ID --to ADDR [<same flags as reply>]

apple mail move MESSAGE-ID... --to MAILBOX [--from MAILBOX] [--account NAME]
                [--dry-run] [--mark-read] [--json]     # `-` reads ids from stdin

apple mail delete-draft MESSAGE-ID [--account NAME] [--json]
apple mail status [--json]
```

**Composing hands off to the user, and that is not a failure.** Each command
opens the window, loads the pasteboard and prints `press ⌘V, then ⌘S`. It never
saves a draft itself, so there is no `message_id` to report — the JSON says
`status: "awaiting_paste"`. Tell the user to paste; do not describe the mail as
sent or saved.

**Mail does everything except the body**: recipients, subject, sending account,
`In-Reply-To`/`References`, the quoted original, and **attachments carried over by
a forward** — the last of which is why forwarding is left to Mail rather than
rebuilt. Verified: a forwarded message came out 184 KB with its attachment intact.

⚠️ **`send` does not exist and will not.** It composed without a window, so there
is nowhere to paste, and every message it ever sent carried the wrapper. When the
user wants mail sent, draft the text and let them send it from Mail.app.

**Bodies may be `--markdown` or `--html`; both become RTF on the pasteboard.**
Markdown gives real bold, italic, links and bullets. 🛑 RTF is deliberate: **HTML
on the pasteboard makes Mail insert the body twice.** A plain `--body` is taken
literally, so prose containing `*` or `_` survives as written.

**`--attach FILE` is the one part of a draft the tool writes itself.** Repeatable,
on all three commands. The files are **already in the window** when it opens — only
the body is left to ⌘V — so the JSON reports them under `attachments` (`name`,
`path`, `bytes`) while `status` stays `awaiting_paste`.

It is allowed where the body is not because the cite-blockquote wrapper comes from
*assigning* to `content`; `make new attachment` adds an element without assigning.
🛑 **Do not seed `content` with a newline first** — that is the usual recipe and it
is exactly the wrapper.

- 🛑 **`count of mail attachments` cannot verify this.** On an outgoing message it
  fails with **-1728** rather than returning 0. What works is counting **U+FFFC**
  in `content`, one per attachment, and asserting the **delta** across the attach.
- ⚠️ **A mismatch is a hard error naming the shortfall**, because a window is
  already open in front of the user.
- **Every path is checked before any Apple Event** — missing file, directory,
  unreadable, or the same file twice all exit 64 with nothing opened. They are
  checked *before the body reaches the pasteboard*, so a bad `--attach` cannot
  silently replace what the user had copied.
- Attachments totalling over 20 MB get a stderr note, not a refusal.
- **Verified in a matched pair (26.812.0):** attaching first does not degrade the
  pasted formatting. ⚠️ Mail does wrap the *attachment placeholder* in a
  style-neutralised cite blockquote, with the body entirely outside it — that is
  Mail's layout structure, not FB11734014.

🛑 **You cannot reply to a draft** — a draft has no sender, and handing one to
Mail's `reply` verb wedged Mail during development. Refused off the index, before
any Apple Event, along with an unknown Message-ID, a forward with no recipients,
and a missing body. Each refuses in under 0.25s.

**Searching is cheap — search widely.** No `--limit`/`--since` discipline is
required, and there is no timeout to trip. The default covers every mailbox except
trash and junk (`--all` adds those, and `--mailbox trash` is honoured by name).

**A query is an AND of terms.** `budget review` matches messages containing both
words anywhere, in any order — not the literal string. Double-quote to require
adjacency: on a real store `budget review` → 346 results, `"budget review"` → 0.
⚠️ **Matching is substring, not word-boundary**: `quarter` matches inside
`quarterly` and `headquarters`. There is no stemming, no ranking (order is by
date), and no boolean operators beyond the implicit AND.

**`--field content` is real full-text search** over decoded message bodies, and is
the one mode that opens files. It finds text inside base64 and quoted-printable
parts that a raw `grep` over `~/Library/Mail` cannot see. `--field all` means
subject, sender *and* body; `--field` defaults to `subject`.

It walks newest-first and stops as soon as `--limit` is filled — but a term with
**fewer matches than `--limit`** has to read everything. On a 40k-message store:

| Search | Bodies read | Time |
|---|---|---|
| any `--field subject` / `sender` | **0** | 0.04s |
| `--field content invoice --limit 20` | 768 | 0.2s |
| `--field content <no matches>` | 39,976 | 9.8s |
| ...`--since 90` | 1,521 | 0.39s |
| ...`--mailbox inbox` | 15 | 0.03s |

`--since`, `--mailbox`, `--account`, `--unread`, `--flagged` and
`--has-attachment` all narrow the candidate set **in SQL, before any file is
opened**, so they are the lever for a body search that is taking too long. The
scan depth is always reported on stderr — a full scan is never silent.

**Attachments are not searched at all by default** — not their contents, and not
their filenames. A search for "invoice" should find messages *about* invoices, not
every message carrying an `invoice.pdf`. `--attachment-names` also matches
filenames, free off the index. Attachment **contents are never searched**: a
`text/*` part marked as an attachment is skipped, non-text parts are never
decoded, and there is no PDF text extraction.

**Getting the files out.** `export` reports attachment *names*; `attachments` gets
the bytes. `export --raw` writes the RFC 822 source; `export --json` gives
structured headers, recipients, attachment names and body.

⚠️ **Attachment bytes are not in the `.emlx`.** Mail strips them out, leaving the
MIME part with an empty body and an `X-Apple-Content-Length` header, and writes
the file *already decoded* to
`Data/<digits>/Attachments/<rowid>/<mime-part>/<filename>`. Parsing the message
alone yields zero-byte attachments — the command reads the directory and falls
back to embedded bytes only for messages that really carry them.

**What counts as an attachment is Mail's rule: a part with a filename.** Verified
against its index — a message with two nameless tracking pixels reports zero
attachments, one with seven named inline images reports seven. `--skip-inline`
drops images the HTML body references.

🛑 **`attachments` and `export --json` do *not* always agree, and a draft built by
`--attach` is where they part.** Mail references a scripted attachment from the
HTML by `cid:`, so it reads back as *inline*: `apple mail attachments` reports
`1 … (inline)` while `export --json` gives `[]` and the index says `0`, for a draft
that really does carry the file. **Use `apple mail attachments` when the question
is "did the file make it".**

`--save` never overwrites: a name that already exists gets `-2` before the
extension. Filenames come from the sender, so they are sanitised to a bare
basename before being joined onto `DIR`.

**`move` files received mail into another mailbox, and it is the one write path
here that touches real mail.** Built for sweeps: filing what arrived before a
filter rule existed, or rescuing what was filed wrongly. `-` reads ids from stdin,
so it is the tail of a pipeline:

```
apple mail search "receipt" --mailbox inbox --json | jq -r '.[].id' \
  | apple mail move - --to Receipts --dry-run
```

- **`--dry-run` sends Mail nothing at all.** It resolves and prints the plan off
  the index alone. Run it first; these moves sync to every device.
- **Every message is resolved against the index and handed to Mail as an exact
  id** — never a mailbox walk, which is what wedges Mail. 0.9s per message on a
  37k mailbox regardless of age.
- **Partial failure never aborts the batch.** Each message reports `{id, moved,
  confirmed, error}`; the exit code is 1 if any failed. A whole chunk lost to a
  timeout is charged to every message in it.
- **Every move is confirmed by the copy *appearing in the destination*** — not by
  it leaving the source, which takes minutes. `confirmed: false` with `moved:
  true` means Mail reported success the index could not corroborate.
- **`--mark-read`** matches what a server-side filter rule does when it files
  something. **Drafts are refused** — a draft's Message-ID changes when it is
  edited. Use `delete-draft`.
- A Message-ID with copies in several mailboxes moves **all** of them. Narrow with
  `--from` or `--account`.
- Destinations are per-account and **nothing is created**. `--to trash` resolves to
  `Deleted Messages` on IMAP, `Deleted Items` on Exchange and `[Gmail]/Trash` on
  Gmail, so one command works across accounts. 🛑 A nested mailbox needs its full
  path (`[Gmail]/All Mail`), which `move` resolves for you.

**`delete-draft` only ever moves a draft to trash.** It enumerates Drafts alone,
re-reads the mailbox afterwards rather than trusting the move, and it is a move to
**trash, not a purge**. 🛑 **Re-resolve the Message-ID first** — a draft's changes
when it is edited, and an `export` of a stale one silently produces an *empty
file*. Look it up by subject: `apple mail search "" --mailbox drafts --json`.

⚠️ **A mailbox move is copy-then-expunge**, so the source copy survives until the
server expunges it (~2 min on IMAP). Both commands say so on stderr; a re-listing
before then still shows the message in its old mailbox, and that is not a failure.

**Mailbox names are not unique** — three accounts can each have an `Archive`.
Every result carries both `account` and `mailbox`; use the pair. Account names can
contain emoji and spaces — get exact strings from `apple mail accounts`.

⚠️ **`accounts` is the one read command that still prefers Mail.app**, because
only Mail knows whether an account is `enabled`. It asks Mail when Mail is already
running and reads the store otherwise — including when Mail is running but *not
answering*, so a wedged Mail costs you the `enabled` field rather than hanging the
command. Consequence: **the file-system answer has no `enabled` key**, so read it
as `account.get("enabled", True)`. It also lists the local "On My Mac" store,
which the AppleScript path omits.

⚠️ **A message can be in the index but not on disk** when Mail hasn't downloaded
the body. `export` says so explicitly, and `auto` falls back to AppleScript — but
only when Mail is already running and answering.

**All three read commands take `--engine auto|filesystem|applescript`. Leave it
alone.** 🛑 The AppleScript engine is what wedges Mail, so `auto` no longer drifts
into it: `search` never falls back, no read command launches Mail, and every
AppleScript read is bounded by a wall-clock deadline *and* an inner `with
timeout`. `--engine filesystem` fails loudly instead of falling back, which is what
you want when diagnosing.

**`apple mail status` answers "is Mail wedged?"** — `mail_app.running` and
`mail_app.responsive` in the JSON. `responsive` is only present when Automation is
already authorized and Mail is up, because probing otherwise would trigger the
consent dialog `status` exists to avoid. 🛑 Read `automation: "unknown"` as "Mail
is wedged", not as a grant problem — the permission API itself blocks for minutes
against a wedged Mail and then answers wrongly.

🛑 **`mail_app.probe_killed: true` means something OUTSIDE killed `osascript`,
and says nothing about Mail.** `responsive` is then absent, not `false`. Measured
2026-09-23 on macOS 27.2 beta 2: an `osascript` started in a **cmux** pane checks
in to LaunchServices under cmux's bundle id the moment it reaches Mail's object
model, and cmux's single-instance guard SIGTERMs it ~7 ms later — while `get
name` still works. Every AppleScript path now names a signal it did not send
instead of exiting 1 with an empty message, which is how `compose` failed
silently. Confirm with `/usr/bin/log show --last 5m --predicate 'eventMessage
CONTAINS "Killing process"'` (zsh's `log` builtin shadows the real one).

🛑 **Custom IMAP keywords are not on this Mac**, and no tool here can expose them.
Mail discards them on sync. Anything keying off one has to run server-side.

**`APPLE_MAIL_INDEX_PATH`** points the index reader at a specific file, or at a
path that doesn't exist to see what a command does without Full Disk Access. The
error names the variable, so an unreadable override never masquerades as a missing
grant.
