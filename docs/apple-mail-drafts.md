# Why `apple-mail` does not compose

`apple mail` reads. It has no `draft`, `reply`, `forward` or `send`, and the
`draft` it used to have was removed in **26.810.0**.

The reason, in one line: **Mail wraps any body a script writes in
`<blockquote type="cite">`, and there is no way to make that stick fixed.** A
draft the tool wrote looked right on disk, looked right in macOS Mail, and
reached the recipient rendered as a quotation. Every route to fixing it has been
tried and measured; the one that works is behind an entitlement no third-party
binary can hold.

Verified on **macOS 27, Mail 16.0 (3897.100.8.1.1)**.

---

## The bug

Mail wraps **any** body set through AppleScript in its share-sheet template:

```html
<html aria-label="message body"><head></head><body dir="auto" style="…">
  <div class="Apple-Mail-URLShareUserContentTopClass"><br></div>
  <div class="Apple-Mail-URLShareWrapperClass" style="position: relative !important;">
    <blockquote type="cite" style="border-left-style: none; color: inherit;
                                   padding: inherit; margin: inherit;">
      …your body…
    </blockquote>
  </div>
</body></html>
```

This is Apple **FB11734014**, filed October 2023 against Mail 16.0 on Ventura,
still open, never answered. The class names are the tell: the scripting `content`
setter is routed through the same compose-insert template the Share Sheet uses,
which renders inserted foreign content as a citation.

🛑 **It is not cosmetic, and the sender cannot see it.** The inline styles
neutralise the quote *in macOS Mail*, so the draft looks right locally. iOS Mail,
the Gmail app and other clients honour `type="cite"` over those overrides and
render the whole message as a quotation — indented, greyed, or collapsed behind
"⋯". On the `text/plain` downgrade every line is prefixed with `> `. Recipients
seeing `>`-quoted mail is reported independently on the Apple Developer Forums,
MacRumors, and by three separate projects.

## Seven routes tested, all wrapped

| Route | Result |
|---|---|
| `content:` in the `make new outgoing message` properties | wrapped |
| `set content of msg to …` after the make | wrapped |
| `set html content of msg to "<p>…</p>"` | wrapped |
| `set html content` with a **complete** `<html>` document | wrapped |
| `set html content` twice | wrapped |
| `tell content of msg to make new paragraph …` (rich-text element API) | wrapped, **plus** `<font face="Helvetica">` markup |
| body containing `</blockquote></div>` to close the wrapper early | wrapped |

The last one is the decisive one. Mail **parses and re-serialises the HTML
through WebKit**: the premature close tag is dropped and the trailing open tag is
balanced *inside* the blockquote. So no string-level escape exists, and reading
the body back to strip it is not possible either — reading `html content` off a
live outgoing message errors with **-1723**.

⚠️ Mail's own `sdef` documents `html content` as *"Does nothing at all
(deprecated)"*. On this build it does work — it is the only route that preserves
tags at all — but do not rely on the description.

## What the `.emlx` rewrite did, and why it was not enough

The shipped approach was: write the draft with AppleScript — which gets headers,
account placement, IMAP registration and the index entry right — then **rewrite
the body in the `.emlx`** afterwards, replacing Mail's wrapped HTML with clean
markup and filling the empty `text/plain` half.

That part genuinely worked, and still would:

- the file on disk holds the clean body;
- Mail serves that same clean body back through `source of`;
- it survives a Mail restart untouched;
- the corrected body is re-uploaded to the IMAP server (its `remote-id` changes),
  so the fix reached the account rather than living in a local file. Other
  projects reported that editing the `.emlx` "gets overwritten"; that is not what
  happens.

🛑 **And none of it survives the draft being opened.** The moment the draft is
opened in Mail's composer and saved, Mail re-imports the body into the
`URLShareWrapperClass` / `<blockquote type="cite">` template and re-empties
`text/plain`. Which means the fix held only for a draft nobody looked at — and
reviewing before sending is the entire reason to write a draft rather than send.

## The experiments that settled it

Run 2026-08-10. Method note, because it is what made the results trustworthy:

⚠️ **The composer was driven by hand, not by `osascript`.** Scripted `open m` /
`close w saving yes` is both a confound — it is itself a scripted insertion, so it
cannot distinguish "the composer re-wraps" from "scripted opening re-wraps" — and
destructive, because it wedges Mail's scripting interface. Every result below
that involves a composer came from a human opening the draft, typing one
character, pressing ⌘S and ⌘W. Always as a **matched pair**: one draft typed by
hand as the control, one written by the tool, through identical steps.

### What was ruled out

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Mail's live compose back-end holds a stale pre-rewrite copy | **no** | Quit Mail, confirmed `outgoing messages = 0`, reopened, opened the draft — still wrapped |
| A stale copy on the IMAP server or in Mail's parsed store | **no** | Disk and Mail's own `source of` both clean, before *and* after a restart, byte-identical bar a trailing newline |
| Scripted `open`/`close` was the trigger | **no** | Hand-driven open/edit/save wrapped it just the same |
| Mail wraps every draft on save | **no** | A hand-typed draft, opened, edited and saved by hand, stayed clean |
| The body's markup shape | **no** | See below |

### The shape attempt, and its refutation

The one hypothesis with a mechanism behind it. Mail's own hand-typed draft is:

```html
<html aria-label="message body"><head></head><body dir="auto"
 style="overflow-wrap: break-word; -webkit-nbsp-mode: space;
 line-break: after-white-space;">…
```

and the rewrite emitted a bare `<html><head><meta charset="utf-8"></head><body>`.
Since Mail visibly *builds a fresh native body and inserts ours inside it* —
the user's typed text lands outside the blockquote, as a sibling — the guess was
that Mail fails to recognise a foreign-shaped document as its own.

`minimalDocument` was changed to emit Mail's shape byte-for-byte and the pair was
re-run. **The tool's draft came back wrapped exactly as before.** The change was
reverted; the negative result is recorded as a comment on `minimalDocument` so
nobody re-tries it.

### The Siri result, which explains it

Siri was asked to draft a mail. It composes through Mail's App Intents
(`SiriMailFlowTools.CreateDraftMailTool` → an `AttributedString` body run through
Cocoa HTML Writer), never touching the AppleScript `content` setter.

That draft was **clean as composed, and still clean after a hand open/edit/save**
— and the edit merged *into* the content flow rather than landing outside a
quotation:

```html
<body dir="auto" style="…">
  <div dir="auto" style="…">                                  ← one benign container
    <div>
      <meta name="Generator" content="Cocoa HTML Writer">
      <p class="p1"><span class="s1">Hi Dan,</span></p>
      <p class="p1"><span class="s1">An update</span></p>     ← the hand edit, inline
```

Crucially, that draft and ours are **equivalent in every byte-level respect we
control**: both `Content-Transfer-Encoding: 7bit`, both with an empty
`text/plain`, both carrying the identical `<html aria-label="message body">` /
`<body dir="auto" style="…">` shell, neither carrying `X-Apple-Mail-Signature`.

⚠️ Two hypotheses died here for free: **transfer encoding** and the
**`X-Apple-Mail-Signature` header**. Both had been on the list to try; Siri's
draft matches ours on both and behaves oppositely.

## The conclusion: provenance, not bytes

**Mail's decision is not made from the message bytes.** Two drafts that are
equivalent on disk behave differently, and the difference tracks only how the
message was created. Mail persists that provenance outside the `.emlx` — which is
why the rewrite survives a restart untouched and still loses the moment the
composer opens the draft.

So no amount of rewriting the file can fix it. That line of attack is closed, and
the compose surface was removed rather than left shipping a body that silently
reaches recipients as a quotation.

Three consequences worth stating plainly:

- **`send` was affected too, and always had been.** It composes without saving,
  so there was never an `.emlx` to rewrite — every message it sent carried the
  wrapper.
- ⚠️ **A draft's Message-ID is not stable.** It changes when the draft is edited
  and saved, and was also observed changing with no edit at all, on IMAP sync
  alone. Anything keyed on the id returned at creation has a shelf life measured
  in minutes — this is very likely why the old reply path orphaned throwaway
  drafts, since it trashed them by Message-ID. `delete-draft` re-resolves by
  subject for this reason; do the same.
- **The empty `text/plain` half is normal.** A hand-typed draft has one too, so
  it was never a scripting defect. Filling it was an enhancement over Mail's own
  behaviour, not a bug fix.

## The route that works, and why we cannot have it

Mail exposes 23 App Intents, including `ComposeMessageIntent`
(to/cc/bcc/subject/**body as AttributedString**/account/attachments),
`SaveDraftIntent`, `SendDraftIntent`, `DeleteDraftIntent`, plus a separate
`SiriMailFlowTools` family (`CreateDraftMailTool`, `ReplyDraftMailTool`,
`SendDraftMailTool`, `UpdateDraftMailTool`) that is what Siri actually drives.

This is the route that produces a clean, review-durable draft. Every way in is
blocked:

- 🛑 **Calling the intent directly.** `-[LNActionExecutor perform]` connects to
  the app over XPC and fails with `LNConnectionErrorDomain` code **2700
  (MissingConnectionEntitlement)** without `com.apple.private.appintents.connection`
  — a restricted entitlement **AMFI SIGKILLs any non-Apple-signed binary for
  carrying**. Signing and notarising do not help; restricted entitlements need
  `platform-application`. Same class of wall as
  `com.apple.private.communicationsfilter` for call blocking.
- 🛑 **Building a Shortcut around it.** The Mail draft actions do **not appear in
  the Shortcuts action picker**, and `shortcuts sign` refuses any shortcut
  containing one, in both modes. Unsigned import is refused outright and
  `shortcuts` has no install verb — so there is no way in but hand-building in
  the GUI, with actions that are not in the picker to build with.
- ⚠️ **Editing the visibility bit.** `~/Library/Shortcuts/ToolKit/Tools-active`
  is a user-owned, unprotected sqlite whose `Tools.visibilityFlags` column gates
  signing (**an action signs iff `flags & 4`**). Flipping the bit is mechanically
  possible and was deliberately **not** built on: the file is a rebuilt cache
  (note the `v78-<UUID>` naming and the `ToolKitIndexingLog` beside it), so the
  bit is expected to revert on reindex or OS update — and a feature that requires
  having patched a system database locally cannot ship to anyone else.
- ⚠️ **Driving Siri.** Works, but means keystroke-automating Type to Siri:
  an Accessibility grant, stolen focus, and a natural-language layer between the
  caller and the body text. For a mail tool, not being able to guarantee the
  message says what was asked is disqualifying.

### Re-checking whether this has opened up

macOS 27 is still gaining betas and these flags may change. **`util/check-mail-intents`
answers it in one command** — it reads the ToolKit database and reports whether any
Mail compose intent has become signable:

```
./util/check-mail-intents          # table + verdict
./util/check-mail-intents --json   # machine-readable
```

It exits **0 if something became reachable** and 1 if nothing changed, so it can
be run from a cron or a release check. Pair it with `util/appintents-dump` for
the parameter schema of anything that opens up.

## The alternative that might still work: paste

Answering an open question nobody in the field had run (che-apple-mail-mcp #306,
which assumed rich text was "structurally impossible" wrapper-free): **HTML
pastes into Mail's native editor clean.**

Put HTML on the pasteboard as `public.html` (`set the clipboard to «data
HTML<hex>»`), create a **visible** outgoing message with **no body set at all**,
and paste. Everything else — recipients, subject, sender, and the `save` — goes
through AppleScript, so `⌘V` is the only keystroke. Result:

```html
<p style="font-size: medium;">…<b>bold</b>, <i>italic</i> and a
<a href="https://example.com/">real link</a>.</p>
<ul style="font-size: medium;" class="MailOutline"><li>first</li><li>second</li></ul>
```

No wrapper, markup intact.

⚠️ **It has never been tested for review durability**, which is the property that
killed everything else — only for whether it composes clean. The provenance
conclusion above predicts it *should* survive, since paste is the only method
that gets content in through the native editor, but that is a prediction and not
a measurement.

Not shipped because it needs an **Accessibility** grant, steals focus, and cannot
run unattended — and the keystroke surface is genuinely dangerous: during testing
a stray `pri` was leaked into one body, and a paste with the wrong tab count
landed **in the subject field**, replacing it. If it is ever shipped, guard it by
re-reading the subject after the paste. It also leaves `text/plain` empty.

## Dead ends

- 🛑 **Shortcuts / App Intents** — see above; the `visibilityFlags & 4` mechanism
  is the gate.
  - ⚠️ **A nonexistent identifier signs fine** (`com.apple.mail.TotallyFakeIntent`
    → exit 0). So a signing failure means "known and non-shareable", not
    "unknown" — the opposite of the natural reading. Notes' shortcuts sign
    because `com.apple.mobilenotes.SharingExtension` happens to be `15`.
  - ⚠️ **`isDiscoverable` / `assistantOnly` in `appintents-dump` do not predict
    Shortcuts availability.** `ComposeMessageIntent` is `isDiscoverable: true,
    assistantOnly: false` and is absent from the picker; `ArchiveMessageIntent`
    has a proper title and is also absent. The only reliable oracle is the
    picker, or the `visibilityFlags` bit. Apple Intelligence is **not** the gate:
    every one of the 23 has `requiredCapabilities: []`.
- 🛑 **IMAP APPEND.** Byte-exact and shipped by `apple-mail-fast-mcp`, but needs
  per-account credentials (an OAuth2 Gmail account cannot provide one), the draft
  does not appear in Mail's Drafts pane for minutes, it cannot create drafts in
  "On My Mac" accounts, and it makes the tool a network client with per-account
  secrets — against this repo's whole premise.
- 🛑 **`NSSharingService`** — "always puts replies in blockquotes" (mothsoftware,
  author of Mail Archiver).
- 🛑 **MailKit.** `MEComposeSessionHandler` can validate recipients, add headers,
  show UI and veto a send, but per Apple's documentation "there's no extending
  the editor or changing the body of the message." Needs a signed app bundle
  besides. `MEMessageSecurityHandler` *does* take replacement MIME bytes, but
  only when signing/encryption is active, and it would not touch a stored draft.
- 🛑 **`.eml` / mbox import** produces received messages, not drafts.

## Findings kept from the removed compose path

Worth preserving even though the code is gone — they generalise to anything that
scripts Mail. The full implementation is in git history before 26.810.0.

- 🛑 **Never enumerate a mailbox from a script.** `repeat with m in messages of
  mailbox …` over a 41k-message store is the pattern that stops Mail servicing
  Apple Events, for every client on the machine, until it is restarted. Instead:
  **Mail's AppleScript numeric `id` is the Envelope Index `ROWID`** (and the
  `.emlx` filename), so the index resolves a Message-ID to an id Mail can address
  directly — `first message of mailbox X of account Y whose id is N` — in 0.13s
  on a small mailbox and 5.7s on a 37,194-message one.
- 🛑 **Mail's scripting interface degrades under compose volume** and then stops
  answering entirely. A live suite doing ~22 saves and 11 deletes in a few
  minutes wedged it. Anything driving Mail in a loop must throttle; there is no
  batching to be had.
- 🛑 **Replying to a draft wedges Mail.** A draft has no sender, so there is
  nothing to reply to.
- 🛑 **Driving Mail's composer wedges it too.** `open <message>` then `close
  <window> saving yes` — the scripted version of reviewing a draft — took Mail
  down twice during development. This is a second reason the experiments above
  were run by hand.
- **Only one route removes a draft.** `delete` silently does nothing, `move`
  errors, `set deleted status` fails with "Connection is invalid". Reassigning
  `mailbox of <message>` to the account's trash **does** work. Trash mailboxes
  are named differently per account type (`Deleted Messages`, `Trash`, `Deleted
  Items`), so try each. This is what `delete-draft` still does.
- **The Drafts enumeration is stale within a single script run**, so collect ids
  first and move each once rather than re-scanning after every move; and a move
  occasionally reports success without taking effect, so re-check and retry.
- **An outgoing message has no `message id`.** Asking errors with "Can't make
  «class meid» of «class bcke»" — Mail assigns one only once the message lands in
  Drafts.
- **Reading recipients back is broken.** `to recipients`, `cc recipients` and
  `bcc recipients` on a saved draft all return the last-added recipient. The
  RFC822 `source` is the only trustworthy read.
- **A draft's sender is frozen once saved.** `set sender` works only on an
  outgoing message before `save`.
- **Text comes back NFD.** Mail decomposes unicode, so `ü` sent as one codepoint
  returns as `u` + combining diaeresis. Normalise before comparing.
- 🛑 **The `.emlx` byte-count prefix is load-bearing.** It is how Mail finds the
  end of the message and the start of its own plist. A stale count silently glues
  the trailer onto the body or truncates the last part.
- 🛑 **Attachments are referenced from inside the HTML** by `cid:`, so replacing
  a part without carrying those references over detaches every attachment.

## Reading a signed `.shortcut` without installing it

Useful for learning action serialisations from a published shortcut. Profile 0 is
`hkdf_sha256_hmac__none__ecdsa_p256` — **signed, not encrypted** — and the
archive carries its own verification key:

1. Parse the `AEA1` header: `<I` at offset 8 is the auth-data length; the blob at
   offset 12 is a `bplist00` holding `SigningCertificateChain` (a per-machine
   leaf issued by *Apple System Integration CA 4*, ~13-month validity — so
   signing contacts Apple, it is not a local wrap).
2. `openssl x509 -inform der -pubkey -noout` on the leaf, then
   `openssl ec -pubin -outform DER`; take the 65-byte X9.63 point after the
   `0004` marker and write it as `hex:<…>`.
3. `aea decrypt -i in.shortcut -o p.aar -sign-pub pub.hex`
4. `aa extract -i p.aar -d x`, then `plutil -convert xml1 x/Shortcut.wflow`

## Sources

- Apple **FB11734014** (open since Ventura) — the scripting `content` setter
  wrapping bodies in `blockquote type="cite"`.
- che-apple-mail-mcp #306 — the "structurally impossible" claim the paste result
  answers.
- mothsoftware (Mail Archiver) on `NSSharingService` blockquotes.
