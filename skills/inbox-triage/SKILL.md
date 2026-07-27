---
name: inbox-triage
description: Work through the user's mail, identify what genuinely needs action, and turn those into reminders after they approve — via the `apple` CLI. Use when the user asks to triage or process their inbox, "what needs my attention", "turn my email into todos", "what am I on the hook for", or "go through my unread mail".
---

# Inbox triage

Read mail, separate what needs action from what does not, propose reminders, and
create them **only after the user approves**.

Requires the `apple` CLI; see the `apple-tools` skill for the tool surface.

> This skill creates reminders — real data that syncs to the user's devices.
> The approval step below is not optional. Read it before doing anything.

## 1. Read

Mail.app must be running. Bound every search; large mailboxes are slow.

```bash
apple mail search "" --mailbox inbox --unread --since 7 --limit 30 --json
```

⚠️ **Never combine an empty query with `--field all`.** That greps every message
body in every mailbox and will not finish. Keep triage scoped to `--mailbox
inbox` with a tight `--since`.

⚠️ **A search that takes ~120s and returns `[]` timed out.** That is
AppleScript's event timeout, and the empty result is indistinguishable from "no
matches". Never report a clear inbox on the strength of one — say the search
timed out and suggest a narrower `--since`.

Variations worth using:

- `--flagged` — the user already marked these as needing attention; start here
  if they mention flagged mail.
- `--since 2` for a daily pass, `--since 14` for catching up after time away.
- `--account "<name>"` to scope to one account — get exact names from
  `apple mail accounts --json`, since they can contain emoji and spaces.

Reading a body is a second AppleScript round trip and is slow, so do it only
where it changes the answer:

```bash
apple mail export <message-id>
```

Subject lines lie. Don't classify something as actionable, or dismiss it, on a
subject alone when the body is available and the call is close.

## 2. Sort

Put each message in one of three buckets:

**Needs action** — the user has to *do* something: a direct question, a request,
a deadline, a commitment they made, something blocked on them.

**Needs a read** — genuinely informational but relevant. Worth mentioning; not
worth a reminder.

**Noise** — newsletters, receipts, automated notifications, marketing. Do not
list these individually. A count is enough.

Judging actionability:

- Addressed directly to the user beats a mass CC.
- A human sender beats an automated one.
- An explicit ask or date beats a vague FYI.
- Being unread does not make something actionable, and being read does not mean
  it was handled.

When you cannot tell, put it in "needs a read" and let the user decide. Guessing
wrong toward action creates reminder clutter, which is the failure mode that
makes people stop trusting this.

## 3. Propose

Show the proposed reminders **before creating any of them**:

```
Needs action (5) — proposed reminders:

  1. Reply to Alice re: Q3 contract terms        due tomorrow    [Inbox]
  2. Send the revised deck to Marketing          due Friday      [Work]
  ...

Needs a read (3):
  - Ops weekly update — Tue
  ...

Noise: 14 messages (newsletters, receipts)

Create these 5 reminders? Say which to skip, or adjust list/dates.
```

Then wait. Do not create anything until the user responds. If they approve a
subset, create only that subset.

Before proposing, check what lists exist so the target is real:

```bash
apple reminders show-lists --json
```

Writing a good reminder:

- **Start with the verb.** "Reply to Alice re: contract terms", not "Alice
  email". The user should not need to re-open the mail to know what to do.
- **Only set a due date the mail justifies.** An explicit deadline, yes.
  Otherwise leave it off — inventing due dates manufactures false urgency.
- **Put context in `--notes`**, including the sender and subject, so the
  reminder survives without the inbox.

## 4. Create

Only after approval:

```bash
apple reminders add Inbox "Reply to Alice re: Q3 contract terms" \
  --due-date "tomorrow 9am" \
  --notes "From: alice@example.com — 'Q3 contract terms', received Mar 3"
```

One command per reminder. Report exactly what was created.

If a list does not exist, ask before `apple reminders new-list` — do not invent
organisational structure the user did not ask for.

## What this skill will not do

- **It cannot modify mail.** `apple mail` is read-only: no archiving, no
  deleting, no marking as read, no replying. If the user wants that, tell them
  it is not supported rather than reaching for AppleScript.
- **It does not create reminders unprompted.** Always propose first.
- **It does not complete or delete existing reminders** as part of triage. That
  is a separate request, and reminder indices shift — re-run
  `apple reminders show <list>` immediately before acting on one.
