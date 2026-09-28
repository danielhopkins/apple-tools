# dawarich — `apple dawarich` (plugin)

CLAUDE.md points here. This file is the working reference for the `dawarich` plugin. The plugin contract is in [`apple-plugins.md`](apple-plugins.md).

Reads a self-hosted [Dawarich](https://dawarich.app) server over its REST
API. 🛑 **Every request goes to the one configured `url` with the configured
`api_key`, and nothing is ever posted.** Python, stdlib only, in
`plugins/dawarich/`; tested against a fake server in
`plugins/dawarich/test-dawarich.py`.

```
apple dawarich status [--json]
apple dawarich visits [--since DAYS | --from DATE --to DATE] [--status all|confirmed|suggested]
                      [--limit N] [--json]
apple dawarich places [--search TEXT] [--limit N] [--json]
apple dawarich points [--since DAYS | --from DATE --to DATE] [--limit N] [--json]
apple dawarich index  [--since DAYS]        # what apple-index calls
```

What it adds over `apple maps`, and the traps:

- **A visit has an END.** `visits --json` reports `started`, `ended` and
  `duration_seconds`. `apple maps` cannot say how long the user stayed
  anywhere; this is the tool that can. ⚠️ Dawarich's own `duration` field is
  in **minutes** and is computed once at creation; the plugin recomputes it
  from the two timestamps and never reports the raw one.
- 🛑 **A visit has three statuses, and `suggested` is the server's GUESS.**
  `visits` reports both `confirmed` and `suggested` by default with `status`
  on each row; `--status confirmed` narrows. A `declined` visit is one the
  user said did not happen and is **never** reported. In the index the two
  are separate kinds, `visit` and `suggested`.
- **Points are the GPS track**, the thing Maps never has. `--limit` defaults
  to 2000 and a cut is said on stderr. They are a CLI command and **not an
  index kind**: a GPS fix is not a document.
- ⚠️ **Nothing here knows Maps' visits.** The same afternoon can be a Maps
  arrival and a Dawarich visit; the `places` report keeps them in separate
  columns and nothing joins them.
- **`status` distinguishes `unconfigured`, `unreachable`, `unauthorized` and
  `ok`**, and `--json` always exits 0 like every tool's status does.
- 🛑 **On this server every visit is `suggested`** — 6,126 of 6,126, back to
  2017 — because nobody confirms visits in Dawarich's UI. `--status
  confirmed` returns nothing here. **28% of visits have no coordinate**
  (`Unknown Location`); they are in the index by date and duration and
  absent from `places` and `near`.
- 🛑 **A suggested visit never anchors a `places` merge.** Dawarich named
  the user's home `3313`, a house number, and 1,651 guesses out-weighed
  1,649 photo days on the first ingest. Confirmed visits weigh; suggested
  ones are counted in `dawarich_suggested` and size nothing.
- 🛑 **"No route to host" from the APP is the Local Network grant, not the
  server.** The host is a LAN address, and macOS 15+ refuses one with
  `EHOSTUNREACH` until the app holds the grant. The terminal has it; the app
  asks on first use now that it carries `NSLocalNetworkUsageDescription`.
  `apple dawarich status` in a terminal cannot see the app's state.
