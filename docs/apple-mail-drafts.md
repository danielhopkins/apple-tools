# Why `apple-mail` never writes a message body

`apple mail` has `compose`, `reply` and `forward` — and **none of them write the
body**. They open a Mail compose window with everything else filled in, put the
body on the pasteboard, and stop. You press ⌘V.

The reason, in one line: **Mail wraps any body a script writes in
`<blockquote type="cite">`, and no amount of fixing the file afterwards makes
that stick.** A draft the tool wrote looked right on disk, looked right in macOS
Mail, and reached the recipient rendered as a quotation.

The history matters, because the obvious fix looks like it works:

- **26.810.0** removed `draft`, `reply`, `forward` and `send` outright, after the
  `.emlx` rewrite they depended on was measured and found not to survive the
  draft being opened.
- **26.810.1** brought `compose`/`reply`/`forward` back in the shape below, once
  pasting into the native editor was measured and *did* survive.

`send` did not come back and will not: it composes without a window, so there is
nowhere to paste. Send from Mail.app.

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

It exits **0 if something became reachable**, 1 if nothing changed, and 3 if the
database is present but not yet populated — so it can be run from a cron or a
release check. Pair it with `util/appintents-dump` for the parameter schema of
anything that opens up.

🛑 **An OS upgrade wipes this database, and the empty state reads as "still
gated".** Checked on **macOS 27.0 (26A5406e)**: the upgrade bumped the schema
version in the filename (`v78-<UUID>` → `v79-<UUID>`) and left **every table at
zero rows** — so the first run after upgrading reported "unchanged" from an index
that had no Mail actions in it to gate. That is the exact moment you would run
this check, and it is a false negative. `check-mail-intents` now reads
`count(*)` and exits **3** rather than 1 in that state. Repopulate with
`open -g -j -a Shortcuts`, wait ~1 min, then re-run.

⚠️ **Pair the live file with its `-wal` and you get zero rows too**, for a
different reason: the indexer is writing concurrently, and a copied
`db`+`wal`(+stale `shm`) triple replays to an earlier empty state. Copy the main
database *alone* when snapshotting it, or read it in place.

**Filed as FB24254597** (2026-08-10, Shortcuts / Suggestion): asks for Mail's
draft-composition intents to be made Shortcuts-visible, on the evidence below —
that Mail declares them discoverable and the withholding is applied system-side.
Distinct from **FB11734014**, the AppleScript cite-blockquote bug; that one is
why this route matters, this one is the route. If either is ever answered, the
pasteboard handoff can be revisited.

### Result: macOS 27.0 (26A5406e), 2026-08-10 — no change

Index repopulated (2248 tools). Every compose route still gated; nothing has the
`& 4` bit:

| Action | visibilityFlags |
|---|---|
| `ComposeMessageIntent`, `ReplyMessageIntent`, `ForwardMessageIntent` | 3 |
| `SaveDraftIntent`, `SendDraftIntent`, `SendMail`, `DeleteDraftIntent` | 3 |
| `UpdateDraftIntent`, `OpenDraftComposerIntent` | 0 |
| all five `SiriMailFlowTools` (`Create`/`Reply`/`Forward`/`Update`/`SendDraftMailTool`) | 2 |

Mail's bundle metadata is unchanged too — still **23 actions**, with
`ComposeMessageIntent` still taking `body` as an `AttributedString`
(`Metadata.appintents` rebuilt at toolsVersion `27A200c`). The only signable Mail
entries are `MailMessageEntity` and `MailFocusConfigurationAction` (7), which
carry no body.

⚠️ **Unexplored: `is.workflow.actions.sendemail` is signable (`visibilityFlags=15`).**
That is the *legacy* Shortcuts "Send Email" action, not an App Intent, and it is
not covered by the dead-ends list above. Whether its body survives review
un-blockquoted is unmeasured — it would need the by-hand matched-pair method,
since it is a different code path from both AppleScript and App Intents.

## What was built instead: the pasteboard handoff

Measured on 2026-08-10, by hand, in matched pairs — the method described above.

**The design.** Everything Mail is good at is left to Mail; the one thing it gets
wrong is left to a keystroke:

| Piece | Who does it |
|---|---|
| recipients, subject, sending account | AppleScript on the outgoing message |
| threading (`In-Reply-To`, `References`) | Mail's `reply` verb |
| the quoted original | Mail's `reply`/`forward` verb |
| attachments carried from the original | Mail's `forward` verb |
| **the body** | **⌘V, by the user** |

The old design fought exactly one of those and lost. Cut it out and the rest was
never in question.

**Verified end to end.** A scripted-open reply, body pasted, saved, then reopened
and hand-edited: no wrapper, `In-Reply-To`/`References` intact, the caller's text
above the quotation, Markdown rendered as real `<b>`, `<i>`, a live `<a href>` and
bullets. A scripted forward of a message with an attachment came out 184 KB with
`filename=image.jpeg` intact — the case the old rebuild path had to refuse.

**The pasteboard carries RTF, deliberately one rich flavour.** HTML on the
pasteboard makes Mail insert the body **twice** — found by
`patrickfreyer/apple-mail-mcp` in v3.1.8/v3.2.0, fixed there the same way. Our own
first spike used `public.html` and would have shipped the double insertion. A
plain-text flavour is written alongside, which is what any native app does; Mail
takes the richest offered.

🛑 **Markdown needs rebuilding, not just parsing.** `AttributedString(markdown:)`
is the right parser, but its output cannot go straight to `.rtf(from:)`:

- **The parsed string contains no line breaks at all.** Block structure lives in
  `presentationIntent` runs, so `"first para\n\nsecond para"` comes back as
  `"first parasecond para"` and every paragraph runs together.
- **Emphasis is semantic, not visual.** Bold arrives as
  `inlinePresentationIntent == .stronglyEmphasized`, never as a font trait, and
  RTF has nowhere to put an intent — so a `**bold**` body converts with no bold
  in it.

`ComposeBody.markdownAttributed` walks the runs, inserts a real break at each
block change, prefixes list items, and converts each inline intent to an actual
font. Both failures are pinned by tests.

⚠️ **Assert on the font, not on the RTF text.** Grepping RTF for `\b` also matches
`\brdrhair` and friends, so the obvious test passes whether or not the bold is
really there. That test was written, passed, and was wrong.

**What the tool still refuses, off the index, before any Apple Event:** a
Message-ID it cannot find, a forward with no recipients, a body it was not given,
`--markdown` together with `--html`, and 🛑 **replying to a draft** — a draft has
no sender, and handing one to Mail's `reply` verb wedged Mail during development.
Each refuses in under 0.25s.

⚠️ **`send` is deliberately absent.** It composed without saving, so there was
never a file to rewrite and there is no window to paste into. Every message it
ever sent carried the wrapper.

## Attachments: the one part of a draft the tool does write

Added 26.812.0. `--attach FILE` on `compose`, `reply` and `forward`.

**Why this is allowed when the body is not.** The wrapper comes from
*assignment* — `set content` / `set html content`. `make new attachment … at
after the last paragraph of content` creates an element inside the content
without ever assigning to it, so it never touches the code path that wraps.

🛑 **No need to seed `content` first, and seeding it is the trap.** Every recipe
on the web sets the body to a string before attaching:

```applescript
set content to "text here" & return & return   -- ← this is the wrapper
tell content
    make new attachment with properties {file name: theFile} at after the last paragraph
end tell
```

That first line is exactly what this tool exists to avoid. Verified instead
against a **brand-new outgoing message with an empty body**: `make new
attachment` succeeds on it directly, and `content` afterwards is a single
U+FFFC. No seeding required.

### Verifying the attachment landed

🛑 **`count of mail attachments` cannot do it.** On an *outgoing* message it does
not return zero — it fails outright:

```
-1728: Mail got an error: Can't get every mail attachment of outgoing message id 17.
```

Same shape as `apple notes`' blindness to PDF attachments, and the same lesson:
never treat the count as evidence. `attachments of msg` is no better.

**What works is counting U+FFFC in `content`** — Mail leaves one
object-replacement character per attachment. Two files attached, two markers.
The scripts count **before and after**, and assert the delta:

```applescript
on markerCount(theText)
    if (length of theText) is 0 then return 0
    set saved to AppleScript's text item delimiters
    set AppleScript's text item delimiters to (character id 65532)
    set n to (count of text items of theText) - 1
    set AppleScript's text item delimiters to saved
    return n
end markerCount
```

Three things in that handler are load-bearing:

- 🛑 **The empty-string guard.** `count of text items of ""` is **0, not 1**, so
  without it the handler returns `-1` for an empty body and every attachment
  appears to add two markers. That is exactly a fresh compose window, and it
  produced `Mail took 3 of 2 attachments` on the first run — a *counting* bug
  that looked precisely like Notes' `make new attachment` double-insert bug.
  The delta check is what surfaced it.
- ⚠️ **The delta, not the absolute count.** A reply or forward starts with the
  quoted original already in `content`, and a forward carries the original's own
  attachments — all of which are U+FFFC too. Only the difference is ours.
- ⚠️ **Text item delimiters, not a character loop.** Iterating `characters of` a
  forwarded body takes seconds; the delimiter split is instant.

### The refusals

Every path is checked **before any Apple Event**, because a window that opened
and then failed part-way through attaching leaves a half-built draft with no way
to tell which files made it in. Missing file, directory, unreadable file, and
the same file given twice each refuse with exit 64.

⚠️ **Attachments are resolved before the body reaches the pasteboard**, so a bad
`--attach` cannot silently replace whatever the user had copied. Pinned by a
test.

**What the user still does:** paste and save. Attachments are already in the
window when it opens, so the JSON reports them as done (`attachments: [{name,
path, bytes}]`) rather than as pending work, while `status` stays
`awaiting_paste` for the body.

### The hand verification (2026-08-12)

Measured the way this document insists on: **a matched pair, driven by hand.**
Two compose windows, the same body, one clipboard load serving both — one window
opened with `--attach report.txt`, the other with nothing attached. Both pasted
with ⌘V and saved with ⌘S, then the two `.emlx` files compared.

| | with `--attach` | control |
|---|---|---|
| `To:` | `Dan Hopkins <dan@boulderhopkins.com>` | same |
| body | `Bold check: <b>pasted</b> and <i>italic</i>.` | **identical** |
| bullets | `•&nbsp;bullet two` in `<p>` | **identical** |
| `blockquote type="cite"` **around the body** | **0** | 0 |
| attachment part | `report.txt`, 18 bytes | — |

**The conclusion: `--attach` neither wraps the body nor degrades the pasted
formatting.** Markdown came through as real `<b>` and `<i>` in *both*, so
attaching first does not put Mail's editor into a plain-text paste mode.

⚠️ **Mail does wrap the attachment placeholder in a cite blockquote, and that is
not FB11734014.** The saved HTML contains exactly one:

```html
<div class="Apple-Mail-URLShareWrapperClass" style="position: relative !important;">
  <blockquote type="cite" style="border-left-style: none; color: inherit; padding: inherit; margin: inherit;">
    <span class="Apple-string-attachment">
      <object type="application/x-apple-msg-attachment" width="66" data="cid:…"></object>
    </span>
  </blockquote>
</div>
```

Three things separate it from the wrapper this whole document is about: it
contains **only the attachment placeholder** — the body text sits entirely above
it and outside it; its styles are **explicitly neutralised**
(`border-left-style: none`, everything else `inherit`), where FB11734014's
wrapper carries none; and `application/x-apple-msg-attachment` is Apple
proprietary, so non-Apple clients ignore the object entirely. It is Mail's own
layout structure for a positioned attachment, not a quotation.

🛑 **Still unverified at the receiving end.** Nothing here measured how a
*recipient* renders that blockquote, because sending is not something this tool
does. If it ever matters, send one to yourself and read it in Gmail's web UI.

### 🛑 The compose window steals focus, and it will corrupt your test

The first hand test produced two anomalies — a saved draft whose body was plain
text (literal `**pasted**`) and whose header read `To: dop`. Neither reproduced
in the matched pair, and reading the recipient straight back off a fresh compose
gives `dan@boulderhopkins.com|Dan Hopkins` with and without an attachment.

**The cause was focus theft, not Mail.** `compose` ends in `activate`, which
pulls Mail to the front — and the user was mid-keystroke in another app, so
`dop` was *their* typing, captured by a To field that had just appeared under
the cursor.

This is a property of every command here that opens a window, and it cuts both
ways: it corrupts whatever the user was doing, and it plants evidence that looks
exactly like a tool bug. Time was spent proving the recipient path correct
before the real explanation surfaced. So:

- **Warn before a window appears**, and batch window-opening into as few moments
  as possible.
- **Use `visible:false` for any probe that does not need a window.** Only the
  window someone is actually asked to type into needs to be on screen.
- **Suspect focus theft first** when a hand test shows stray or truncated text in
  an input field.
- **One hand test is a data point, not a result.** The matched pair is what
  separated a real finding (the neutralised blockquote, which recurred) from an
  artefact (`To: dop`, which did not).

### 🛑 A scripted attachment reads back as *inline*, and the counts disagree

Consequence of attaching at a content position: Mail references the part from
the HTML by `cid:`, so every reader here classifies it as an inline attachment.
On a saved draft carrying one real `report.txt`:

| Reader | Reports |
|---|---|
| `apple mail attachments` | **1** — `report.txt  text/plain, 18 bytes (inline)` |
| `apple mail export --json` | `[]` |
| the Envelope Index (`search`) | `attachments: 0` |

The file is genuinely there — a `report.txt` MIME part with the right 18 bytes.
This is a classification difference, not a lost attachment, and it means the
older claim that `attachments` and `export --json` *always* agree does not hold
for a draft built this way. Use `apple mail attachments` when the question is
"did the file make it".

## The spike this grew out of

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

It has since been tested for review durability too, and survives — that is what
the shipped design rests on.

🛑 **What is *not* shipped is pressing ⌘V for the user.** Automating the keystroke
needs an **Accessibility** grant — the ability to drive the whole machine — steals
focus, and cannot run unattended. The keystroke surface is genuinely dangerous:
during testing a stray `pri` was leaked into one body, and a paste with the wrong
focus landed **in the subject field**, replacing it. `patrickfreyer` polls
`frontmost of process "Mail"` before every keystroke for exactly this reason. The
user pressing their own ⌘V costs one keystroke and removes all of it.

⚠️ **`text/plain` comes out empty**, and that is not a defect of this route: a
draft *typed by hand* in Mail has an empty `text/plain` too. It is what Mail does
for every draft however the body arrived. The claim in `prior-art.md` that pasting
populates it is wrong — measured empty five times.

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
  - ✅ **What the gate actually is: conformance to an assistant schema.** The
    ToolKit index carries a `SystemToolProtocols` table, and joining it against
    `Tools` explains the split that `visibilityMetadata` could not:

    | Action | vf | protocols |
    |---|---|---|
    | `ComposeMessageIntent` | 3 | `appIntent, assistantInvocable, sideEffect, appIntentSchema.mail.CreateDraftIntent` |
    | `SaveDraftIntent` | 3 | `appIntent, assistantInvocable, appIntentSchema.mail.SaveDraftIntent` |
    | `SendMail` | 3 | `appIntent, sendMail, batchable` |
    | `MailFocusConfigurationAction` | **7** | `appIntent, focusConfiguration, batchable` |

    Actions marked `assistantInvocable` are signable in **38 of 386** cases
    (~10%) against **756 of 2248** (~34%) overall, and within Mail the *only*
    signable action is the one action that conforms to no assistant schema.
    `SendMail` is gated by a second, separate rule — it carries no
    `assistantInvocable` but its own `sendMail` system protocol.

    ⚠️ **This is applied system-side at index time, not declared by Mail.** Every
    gated action reports `visibilityMetadata: {assistantOnly: false,
    isDiscoverable: true}` in its own bundle metadata — the app is not asking to
    be hidden. And ordinary third-party App Intents get the bit routinely
    (forScore 84/86, BetterDisplay 40/40, Ghostty 13/13, Tailscale 12/12), so it
    is not a first-party privilege wall either. **It is policy, and therefore
    reversible by Apple without any change to the intents themselves.**
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
