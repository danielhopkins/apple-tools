---
name: meeting-prep
description: Prepare the user for an upcoming meeting by pulling the calendar event, looking up attendees in Contacts, and finding recent mail and notes related to them or the topic — via the `apple` CLI. Use when the user asks to prep for a meeting or call, "who am I meeting with", "what do I need to know before my 2pm", "brief me on this call", or "what's the background on this meeting".
---

# Meeting prep

Given an upcoming meeting, assemble the context the user needs walking in: who
is attending, what was recently discussed with them, and any notes on the topic.

This is **entirely read-only**. Prepping should never modify a calendar event.

Requires the `apple` CLI; see the `apple-tools` skill for the tool surface.

## 1. Find the meeting

```bash
apple calendar events --days 1 --json
```

Match against what the user said — a time ("my 2pm"), a title fragment, or a
person's name. If several could match, ask rather than guessing; prepping for
the wrong meeting wastes the whole exercise.

Widen with `--days 7` or `--search` if it is not today. For a specific event you
already have an ID for, use `apple calendar show ID --json`, adding
`--occurrence` if it is recurring.

The event JSON gives you `title`, `start`, `location`, `notes`, `url`, and
`attendees` when the invite carried them.

## 2. Resolve the attendees

`attendees` holds display names or email addresses. Look each one up:

```bash
apple contacts search "alice@example.com"
apple contacts search "Alice Chen"
```

Search matches names, companies, emails, and phone numbers, so either form
works. Useful output: company and job title (who they are), and phone (in case
the user needs to call in).

Skip the user themselves. If an attendee is not in Contacts, that is worth
mentioning — it usually means an external participant.

## 3. Find recent context

For each significant attendee, look for recent correspondence:

```bash
apple mail search "alice@example.com" --field sender --since 60 --limit 10 --json
apple mail search "<topic from the event title>" --since 90 --limit 10 --json
```

`--field sender` and the default `--field subject` are free — they are indexed,
so they cost milliseconds no matter how wide you cast. If subject search finds
nothing, follow up with `--field content`, which searches message bodies; it
opens files, so it is the slower one, but with `--since 90` already applied it
is a fraction of a second. That is often where the real context is — the topic
gets discussed in a thread whose subject line never mentions it.

Remember a query is an AND of terms: `budget review` needs both words present.
Prefer two distinctive words over a whole phrase from the event title.

And any notes on the subject:

```bash
apple notes search "<topic>" --json
apple notes export <id>        # only for the ones that actually look relevant
```

Note search is **title-only**, so try a couple of phrasings of the topic. Do not
export every result — read titles first, export the two or three that matter.

⚠️ An empty mail result establishes there is no correspondence *only if stderr
is quiet*. Without Full Disk Access this falls back to AppleScript, which hits a
~120s event timeout and returns `[]` with exit status 0. If you see `note:
falling back to AppleScript` and an empty result after a long wait, say the
search failed rather than reporting "no recent email with them", and continue
the prep without it.

## 4. Present

A prep brief should be readable in under a minute:

- **The meeting** — title, time, location or link.
- **Who's there** — name, role, company. One line each. Flag anyone not in
  Contacts as likely external.
- **Recent threads** — what was last discussed with these people, with dates.
  Summarise the thread; don't paste message bodies.
- **Relevant notes** — link or name them, with a one-line gist.
- **Open loops** — anything that looks unresolved: a question they asked that
  was never answered, a commitment the user made, a decision left pending.

Guidelines:

- **Distinguish found from inferred.** If you are guessing that a thread is
  related, say so.
- **Say when there is nothing.** "No recent email with them" is a real and
  useful finding.
- **Don't summarise the whole relationship.** Recent and relevant only.
- **Be careful with private detail.** Surface what bears on the meeting, not
  everything you happened to read while searching.
