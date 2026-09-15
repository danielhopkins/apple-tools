# Plugins: sources that are not Apple's

apple-tools reads the stores on this Mac. A plugin reads something else — the
first one, `dawarich`, reads a self-hosted location server — and joins the
tools on equal terms: `apple <name> …` runs it, `apple status` reports it, and
`apple-index` indexes what it returns. This file is the contract, the reasons
behind each rule, and what was measured writing the first one.

## What a plugin is

An executable named `apple-plugin-<name>`, in any language, that answers four
calls. Everything else about it is its own business.

| Call | Must return |
|---|---|
| `manifest --json` | one JSON object, described below |
| `status --json` | `{status, usable, advice, …}`, the shape every tool's `status --json` has; **exit 0 whether or not it is usable** |
| `index [--since DAYS]` | NDJSON: one record per line, in the index record shape |
| anything else | its own subcommands, with `--json` on every read |

It runs **out of process**. `bin/apple` execs it, `apple status` runs it with
`status --json`, and `index.py` runs it with `index` and reads stdout. Nothing
imports plugin code, which is why a plugin can be Python, Swift, or a shell
script, and why one that crashes takes nothing else with it.

### The manifest

```json
{
  "name": "dawarich",
  "version": "26.903.0",
  "description": "Visits with a duration, places, and the GPS track …",
  "network": {"hosts": ["the configured url"], "writes": false},
  "commands": ["status", "visits", "places", "points", "index"],
  "index": {"kinds": ["visit", "suggested", "place"],
            "refresh_args": ["--since", "3650"]},
  "config": [
    {"key": "url",     "required": true, "secret": false, "help": "…"},
    {"key": "api_key", "required": true, "secret": true,  "help": "…"}
  ]
}
```

- **`network`** is the field the whole system exists for. The header of
  CLAUDE.md promises that nothing leaves the machine without saying so. A
  plugin that declares `network` is shown with its hosts by `apple plugins
  list`, by `apple plugins enable`, and as its "permission" in `apple status`.
  A plugin that omits it is claiming it makes no connection.
- **`index`** is optional. Without `kinds`, the plugin is a CLI only and never
  a source. `refresh_args` are passed by `apple-index refresh` to `ingest` in
  **index.py's vocabulary** (`--since`, `--limit`), not the plugin's — the
  adapter turns `--since` into the plugin's `--since`.
- **`config`** declares every key the plugin reads. `apple plugins config`
  refuses a key that is not declared, so a typo is an error rather than a
  plugin that is configured and never works. A `secret` key goes to the
  Keychain; a `required` one blocks `enable` until it is set.

### The record

Every line `index` prints must carry all fifteen fields, and the adapter
checks each one before it becomes a record:

```
uid        "<name>:<kind>:<id>"  — must start with "<name>:"
tool       "<name>"              — must equal the plugin's name
kind       a short noun: place, visit, suggested, …
native_id  the id the plugin's own commands take
url        a link that opens the thing, or null
title      what a search result shows
container  see below
created, modified, occurred     Unix seconds or null; never a string
latitude, longitude             numbers or null
people     a list, [] when none
body       the searchable text
rev        anything that changes when the record changes
```

🛑 **A plugin that indexes places must put the COUNTRY in `container`.** The
`places` report reads `container` as a country for every source except
`maps`, which puts the place category there — the trap that once listed
"Dining" and "Transportation" as countries. A plugin is held to the `photos`
rule, not the `maps` one.

### What the adapter refuses

Measured against a fake plugin in `lab/test-plugins.py`, each of these fails
the ingest naming the line, and nothing is written:

| Emitted | Error |
|---|---|
| a record missing `occurred` | `record 2 lacks occurred` |
| `"tool": "maps"` from plugin `fakeloc` | `record 2 claims tool 'maps'` |
| `"latitude": "39.95"` | `record 2 latitude is not a number` |
| a line that is not JSON | `line 1 of index is not JSON` |
| exit 69 with a message on stderr | `index exited 69` and the message |

⚠️ **A record that fails is a whole ingest that fails**, not a skipped line.
The alternative — index the good ones and drop the bad — would let a plugin
that breaks on one field silently lose a fraction of its data every run.

🛑 **A plugin cannot take a built-in source's name.** `maps` means Maps. One
that tries is ignored with a line on stderr.

## Enabling is a decision, not a side effect

`apple plugins list` shows every plugin found on the machine. **None of them
runs until `apple plugins enable <name>`.** A plugin that is installed and not
enabled is invisible everywhere:

- `apple <name>` refuses, and says how to enable it (exit 1, not "unknown
  tool")
- `apple status` and `apple --which` do not list it
- `apple-index sources` does not list it, and `ingest --source <name>` is an
  unknown source

That is the reason `bin/apple-plugins` exists at all instead of `bin/apple`
scanning PATH. The first plugin talks to a server, and the moment a plugin
runs is the moment data may leave the machine. `enable` refuses while a
`required` key is unset, so a plugin cannot be enabled half-configured and
fail on its first use.

### Where a plugin is found

First hit wins:

1. `$APPLE_TOOLS_PLUGINS` — colon-separated directories, for tests and for a
   plugin being written
2. `~/Library/Application Support/apple-tools/plugins/<name>/apple-plugin-<name>`
   — where an externally installed plugin goes
3. beside `apple-plugins` itself
4. `<root>/plugins/<name>/apple-plugin-<name>` — the plugins in this repo,
   from a checkout or the release tarball
5. `<root>/libexec/plugins/<name>/apple-plugin-<name>` — the same, where brew
   puts them
6. `$PATH`

A candidate must be a regular executable **file**. A directory named
`apple-plugin-foo` passes `os.access(X_OK)` and is not a plugin.

### Where the configuration is

`~/Library/Application Support/apple-tools/plugins.json`, beside `files.json`
and `people.json`, mode 0600, written atomically:

```json
{"dawarich": {"enabled": true, "url": "https://dawarich.example.com"}}
```

🛑 **Secrets never go in that file.** A key the manifest marks `secret` is
written to the login Keychain under service `apple-tools.<name>`, account
`<key>`, with `security add-generic-password -U`. `apple plugins config <name>
--json` prints it as `•••`; `--reveal` prints it, and that is how the plugin
reads its own key back. Removing a secret with `--unset` deletes the Keychain
item. The test suite sets `APPLE_PLUGINS_KEYCHAIN_FILE` to keep secrets in a
temp file, because a test must never touch the user's Keychain — and a
Keychain read from a non-interactive shell can hang on a dialog.

⚠️ **The plugin reads its config through the manager, not the file.** That is
one subprocess per invocation (`apple-plugins config <name> --json --reveal`),
measured at 85 ms — two Python starts, since the manager asks the plugin for its manifest to learn which keys are secret — and it means the plugin never learns where the file
or the Keychain item is. `DAWARICH_URL` / `DAWARICH_API_KEY` and `--url` /
`--api-key` override it, for tests and one-off commands.

## The index side

`index.py` asks `apple-plugins enabled` once per process and treats every
enabled plugin with `index.kinds` as a source after the built-in ones. One
adapter, `ingest_plugin`, serves all of them. `sources --json` lists them, so
the app's Sources panel shows a plugin row without any Swift change.

`--full` reconciliation works as for any source: a record the plugin did not
return this run is deleted. ⚠️ **Disabling a plugin does not remove its
records.** They stay until `apple-index ingest --source <name> --full` — which
is refused for a disabled plugin, since it is no longer a source. Re-enable,
run `--full` with the plugin returning nothing, or `apple-index purge`. The
`places` report reads plugin tools **from the index**, not the enabled list,
for the same reason: a report that hid records the index holds would be lying.

### The `places` report

A plugin that indexes `place` records joins `maps` and `photos` there, with
its own columns:

| Column | Counts |
|---|---|
| `visits` | Maps arrivals |
| `photo_days` | days a camera was there |
| `<plugin>_visits` | the plugin's confirmed arrivals |
| `<plugin>_suggested` | arrivals the plugin's server guessed and nobody confirmed |

🛑 **Never added across columns.** A Maps visit and a dawarich visit on the
same afternoon are one afternoon detected twice. Dot size takes the
**maximum** across columns, for the same reason it always did. `counts`
carries `from_<plugin>` beside `from_maps` and `from_photos`.

## Dawarich, the first plugin

[Dawarich](https://dawarich.app) is a self-hosted location-history server fed
by a phone app. What it adds over `apple maps`, from its own source
(`app/serializers/api/*.rb`, `app/controllers/api/v1/*.rb`):

- **Visits with an end time.** `GET /api/v1/visits` returns `started_at`,
  `ended_at`, `duration`, `name`, `status`, `confidence` and a `place` with a
  coordinate. Maps records a start and nothing else, so `apple maps` cannot
  say how long anyone stayed anywhere. This can.
- **Places with a city and a country.** `GET /api/v1/places?filter=all`.
- **The GPS track.** `GET /api/v1/points`, paged up to 10,000 a call. Maps
  sees only where Maps was running.

Auth is one API key as `Authorization: Bearer <key>`. `X-Dawarich-Version` on
every response is where `status` reads the server version.

What was measured or read, and what it decided:

- ⚠️ **`/api/v1/visits` requires `start_at` and `end_at`.** `Visits::FindInTime`
  calls `Time.zone.parse` on both and raises on nil. Every visits call sends a
  window; `--since` defaults to 30 days on the CLI and 3650 for `index`.
- ⚠️ **The server paginates only when `page` is sent**, and then reports
  `X-Total-Pages`. Without it a collection comes back whole. Every collection
  is asked for by page, 500 a page for visits and places (the server's cap),
  10,000 for points.
- ⚠️ **`duration` is in MINUTES**, computed at creation (`Visits::Create`,
  `((ended_at - started_at) / 60).to_i`). The plugin recomputes it from the
  two timestamps and reports `duration_seconds`, so an edited visit cannot
  carry a stale one and every tool here keeps one unit.
- 🛑 **A visit has three statuses: `suggested`, `confirmed`, `declined`.** A
  suggested one is the server's guess from the track. A declined one is a
  guess the user said was wrong, and it is **never reported**, whatever
  `--status` asks. Confirmed and suggested are the same unit at two
  confidences, so they are two index **kinds** (`visit`, `suggested`) rather
  than one kind with a flag the record has no column for.
- **Points are a CLI command and not an index kind.** A GPS fix is not a
  document, and a decade of them is hundreds of thousands of rows that no
  search would answer with. `apple dawarich points --since 1` is for "where
  was I at three", and its default `--limit` is 2000 with the cut said on
  stderr, the `apple maps` rule.
- **Every `status --json` exits 0**, including `unconfigured`, `unreachable`
  and `unauthorized`, because `apple status` reads a non-zero exit as "did not
  answer" and would print `status unavailable` in place of the real state.
  The plain form exits 1 when not usable, for a script gate.
- **`status` makes two calls**: `/api/v1/health` needs no key and proves the
  host is reachable; `/api/v1/users/me` proves the key. A 401 on the second is
  reported as `unauthorized`, distinct from `unreachable`.

**Measured on the real server, 2026-09-14** (Dawarich 1.14.2, fed by the
iOS app since 2017-05-21):

- **6,126 visits and 920 places** came back in 7.3 s at ~1,000 records/s,
  and embedded in 8.3 s. `--since 3650` reaches the first visit, so the
  window is not cutting anything here.
- 🛑 **Every one of the 6,126 visits is `suggested`.** This user has never
  confirmed a visit in Dawarich's UI, and most users will not. A default of
  `--status confirmed` would have returned nothing and looked like an empty
  server. That is why `all` is the default and `status` is on every row.
- ⚠️ **1,731 visits — 28% — have no coordinate and no place.** Dawarich
  names them `Unknown Location`. They index with `latitude: null`, so they
  are searchable by date and duration and invisible to `places` and `near`.
- 🛑 **Dawarich names a place by reverse geocoding, and the result can be a
  house number.** The user's home is `Sentinel Drive, 3313, Boulder,
  Colorado` on 1,602 visits and `3313` on the newer ones. On the first
  ingest that name **won the merge anchor in `places`** — 1,651 suggested
  visits against 1,649 photo days — and renamed the largest place in the
  library after a street number. The fix is in `cmd_places`: a
  `<plugin>_suggested` count is carried and never weighs the anchor. Pinned
  in `lab/test-plugins.py`.
- **`status` makes two requests and returns in under a second** over
  Tailscale; `visits --since 14` in about the same.
- 🛑 **THE APP COULD NOT REACH IT, AND THE TERMINAL COULD.** The server
  resolves to a LAN address. On macOS 15+ a connection to the local network
  needs the Local Network privacy grant, and a refused one fails with
  `[Errno 65] No route to host` — a routing error, naming no grant. The
  terminal held the grant; `AppleTools.app` had never asked, so its first
  two scheduled ingests failed while `apple dawarich status` in a terminal
  passed. The app now carries `NSLocalNetworkUsageDescription` so it can
  ask. ⚠️ **A plugin's `status` cannot see this**: it runs in the caller's
  process and reports the caller's grant. When an ingest inside the app
  fails with "No route to host", look in System Settings → Privacy &
  Security → Local Network before looking at the server.

The plugin is Python, stdlib only, on `/usr/bin/python3`, like `apple-notes`.
`plugins/dawarich/test-dawarich.py` runs it against a fake server on
127.0.0.1 with the shapes taken from the serializers above, and runs the
manager against a temp config and temp Keychain file. Nothing in it reaches
the network or the user's configuration.

## Writing one

1. Make `apple-plugin-<name>` executable and answer `manifest --json`.
2. Answer `status --json` with `{status, usable, advice}` and exit 0.
3. If it indexes: print NDJSON records from `index`, honour `--since`, put the
   country in `container` for a place, and start every `uid` with `<name>:`.
4. Declare `network` if it makes any connection.
5. Put it under `~/Library/Application Support/apple-tools/plugins/<name>/`,
   or on PATH, or in `plugins/` here.
6. `apple plugins list` → `apple plugins config <name> …` → `apple plugins
   enable <name>` → `apple-index ingest --source <name>`.

`lab/test-plugins.py` is the reference for what the adapter accepts;
`plugins/dawarich/` is the reference for the rest.

## Not done

- The app's Sources panel labels a plugin's breakdown "By account" — the
  default heading — because it cannot know what a plugin's `container` means.
  A `container_label` in the manifest, carried through `sources --json`, is
  the fix.
- A plugin has no `people`. Dawarich's family feature
  (`/api/v1/families/…`) could name who was there, but nothing joins its
  members to Contacts yet.
- `apple plugins` has no `install <url>`. A plugin is put in place by hand or
  by its own installer.
