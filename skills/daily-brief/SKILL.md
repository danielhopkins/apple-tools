---
name: daily-brief
description: Assemble a morning briefing from the user's own data — today's calendar events, reminders due or overdue, and mail needing attention — using the `apple` CLI. Use when the user asks "what's my day look like", "daily brief", "catch me up", "what do I have today", "what's on deck", or asks for a summary of their schedule and todos.
---

# Daily brief

Pull today's picture from Calendar, Reminders, and Mail and present it as one
short briefing. This is **read-only** — never create, complete, or delete
anything while assembling a brief.

Requires the `apple` CLI; see the `apple-tools` skill for the tool surface and
its traps.

## Gather

Run these together, they are independent:

```bash
apple calendar events --days 1 --json
apple reminders show-all --due-date today --include-overdue --json
apple mail search "" --mailbox inbox --unread --since 2 --limit 15 --json
```

Notes on each:

- **Calendar** — `--days 1` covers from now to this time tomorrow. If the user
  asks about "the rest of today" specifically, that is close enough; do not try
  to be clever with `--to`.
- **Reminders** — `--include-overdue` is essential. Overdue items are the whole
  point of a brief and are omitted without it.
- **Mail** — the slow one, and the one that lies. Scope it: `--mailbox inbox`
  plus a tight `--since`. **Never** combine an empty query with `--field all`;
  that searches every message body across every mailbox and will not finish.
  Add `--flagged` if the user only cares about flagged mail.

  ⚠️ **A mail search that takes ~120s and returns `[]` timed out — it did not
  find an empty inbox.** AppleScript's event timeout is two minutes and the
  result is indistinguishable from no matches. If a search takes that long,
  report mail as unavailable and give the rest of the brief. Do not tell the
  user their inbox is clear on the strength of an empty result that took two
  minutes to arrive.

If the user names a different day ("what's tomorrow look like"), use
`--from`/`--to` on calendar and `--due-date` on reminders instead.

## Present

Lead with what constrains the day, in this order:

1. **Overdue** — anything past due, called out first. This is the highest-signal
   item and burying it defeats the purpose.
2. **Today's schedule** — chronological, with times. Note gaps if the user is
   deciding when to fit something in.
3. **Due today** — reminders not yet overdue.
4. **Mail worth a look** — only genuinely actionable messages, grouped by sender
   or thread. Skip newsletters and automated notifications unless the user has
   said they care.

Guidelines:

- **Be brief.** A briefing is scannable. Prefer a short list over prose;
  don't restate every field the JSON gave you.
- **Say when something is empty.** "Nothing overdue" is useful information.
  Never invent items to make the brief look fuller.
- **All-day events are not time blocks.** Birthdays and holidays should not be
  presented as if they occupy the calendar.
- **Don't editorialise about the user's workload.** Report it; skip the
  commentary about how busy they look.

## Following up

The brief often prompts a next step — rescheduling something, completing a
reminder, replying to mail. Those are writes: confirm before acting, and re-run
`apple reminders show <list>` first, because reminder indices shift.
