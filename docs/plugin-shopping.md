# shopping — `apple shopping` (plugin)

CLAUDE.md points here. This file is the working reference for the `shopping` plugin. The plugin contract is in [`apple-plugins.md`](apple-plugins.md).

Shopping lists, what is on them, and how often each thing goes on a list.
🛑 **The commands and the JSON name no app.** A *backend* finds the store,
reads it, and knows how to make it current; `backend` in the config picks
one. Python, stdlib only, in `plugins/shopping/`; tested offline by
`plugins/shopping/test-shopping.py`, which builds its own store and runs a
fake WebDAV server on 127.0.0.1.

| Backend | Reads | Made current by |
|---|---|---|
| `milkforus-server` | its own replay of Milk for Us's sync server | `sync`, or the agent every 2 minutes |
| `milkforus` | the Milk for Us app's store on this Mac | `sync`, which runs the app |

The default is `milkforus`. `setup` sets `milkforus-server`.

```
apple shopping status [--json]
apple shopping setup [--no-pull]           # once: the login, into the Keychain
apple shopping agent [install [--every MINUTES] | remove | status]
apple shopping sync [--keep-running] [--restart] [--timeout SECONDS] [--json]
apple shopping lists [--sync] [--json]
apple shopping items [LIST] [--checked | --all] [--search TEXT] [--sync] [--json]
apple shopping history [--list LIST] [--since DAYS] [--search TEXT] [--most] [--limit N] [--json]
apple shopping index [--since DAYS]        # what apple-index calls
```

A LIST is a name or an id. The match ignores case, the trailing space the
app keeps on some names, and the curly apostrophe in `Trader Joe’s`.

## Backend: `milkforus`

[Milk for Us](https://milkforus.com) 1.6.1 (`de.danielrinser.milkforus`),
the iPhone app, installed on this Mac from the App Store as a wrapped iOS
app in `/Applications/Milk for Us.app`. It keeps plain Core Data SQLite in
`~/Library/Group Containers/group.de.danielrinser.milkforus/db.sqlite`.

| Table | Read for |
|---|---|
| `ZSHOPPINGLIST` | a list: `ZNAME`, `ZSORTORDER`, `ZCOLORSTRING` |
| `ZSHOPPINGLISTITEM` | a thing on a list: `ZPRODUCT`, `ZSHOPPINGLIST`, `ZCHECKED`, `ZNOTE` |
| `ZPRODUCT`, `ZPRODUCTCATEGORY` | what it is, and its aisle (`ZDEFAULTSORTORDER`) |
| `ZPRODUCTUSAGE` | per product per list: `ZLASTUSED`, `ZTIMESUSED` |

What was measured on the first run, 2026-11-02, and what it decided:

- 🛑 **THE MAC COPY IS ONLY AS NEW AS THE LAST TIME THE APP RAN HERE.** The
  store on disk was from 2026-07-14, the last time the Mac app was opened;
  the phone had been in use every day since. The app syncs through its own
  server, `sync.milkforus.com` (Ensembles over WebDAV, `WebDAVSyncBaseURL`
  in its preferences), and only while it runs. Every read warns on stderr
  when the last sync is more than six hours old and the app is not running;
  `status --json` carries `stale`.
- **`sync` starts the app hidden** (`open -g -j -b`), waits, and stops it
  again. Measured: a cold start with 3.5 months to pull wrote the first
  changes at +23 s and settled at +54 s; a cold start with nothing new took
  20 s; with the app already running, 10 s. `--keep-running` leaves it
  running hidden.
- 🛑 **`store.plist` in the sync engine's folder is rewritten each time the
  app checks the server**: at launch, and then every ~16 s while it runs.
  Its mtime is `last_sync`. `sync` waits for two such checks after a launch
  (one when the app was already running), then for the data files to stay
  quiet for 5 s.
- 🛑 **A running hidden app keeps the copy current by itself.** Measured
  2026-11-02 with `sync --keep-running`: "Tea" added on the phone at
  09:21:17 was downloaded at 09:21:22 and 09:21:38 and read by `items` at
  09:21:39, 22 s later. The same change set carried the phone's "clear
  checked items", which deleted 20 checked rows. So the way to keep the
  lists current with no `--sync` is to leave the app running: `sync
  --keep-running`, or Milk for Us in Login Items. The index then follows
  within one 5-minute AppleTools refresh.
- ⚠️ **A second `open` of a running app does nothing**: no fetch, no write.
  A running app is left to its own timer, and `--restart` stops it first.
- 🛑 **AppleScript `quit` does not work.** The wrapped iPhone app never
  answers it; `osascript` waits two minutes for `AppleEvent timed out
  (-1712)`. `sync` stops the app with SIGTERM, which ends it in about a
  second, and the store passes `PRAGMA quick_check` after.
- ⚠️ **An item row has no date.** `last_added` is
  `ZPRODUCTUSAGE.ZLASTUSED` for the same product and list: the last time
  that product was put on that list. `times_added` is `ZTIMESUSED`.
- ⚠️ **A product can have two usage rows for one list** (1 of 1,386 here).
  The join returns the item twice; the newest row wins. The test pins it.
- **`ZCHECKED` 1 is checked off.** A checked item stays on the list until it
  is cleared in the app, which is why `items` shows open ones by default.
- **`ZSIMPERIUMKEY` is the stable id** — a UUID, or 32 hex digits on a list
  made by an older version. A list name can carry a trailing space; every
  name is stripped.
- 🛑 **Read the WAL.** The store opens `mode=ro`, never `immutable=1`. The
  test builds a store whose newest item exists only in the WAL.
- **Index kind**: `list`, one record per list, holding what is to buy and
  what was checked off. `occurred` is the newest `last_added` on the list.
  `refresh_args` is `["--full"]`. The index does not sync: it is as new as
  the last `apple shopping sync`.
- With this backend the plugin connects nowhere. The manifest declares
  `sync.milkforus.com` because `sync` starts an app that does, and because
  `milkforus-server` connects itself.

## Backend: `milkforus-server`

Pulls from `sync.milkforus.com` into
`~/Library/Application Support/apple-tools/shopping/milkforus/`, and never
needs the app to run. 🛑 **Not a public API**: the shapes below were read
off the wire on 2026-11-02, and an app update can change them.

- **Ensembles over WebDAV.** Under the account's folder, `milkforus/` holds
  `baselines/` (one file: every object, at one global count), `events/`
  (one JSON file per change set after it), `stores/` (one file per device
  that ever synced, back to 2018) and an empty `data/`. A file name starts
  with its global count: `20994_<store id>_<revision>.cdeevent`.
- **A change set** is `changesByEntity` → entity → changes, each
  `{globalIdentifier, type, properties}`. Change type 100 inserts, 200
  updates (only the properties listed), 300 deletes. Property type 0 is an
  attribute (`value`; absent is null), 1 a to-one (`relatedIdentifier`), 2
  a to-many, which the replay skips: the to-one on the other side holds the
  same link. A date is `["date", <milliseconds since 1970>]`. The
  `globalIdentifier` is the object's `simperiumKey`, so ids match the app.
- 🛑 **Replayed in order, it matches the app.** The baseline (20897, 2.0 MB)
  plus 102 change sets gave the same 8 row counts, the same 6 lists and the
  same 114 items as the app's `db.sqlite`; `items`, `lists`, `history` and
  `index` print the same JSON on both backends.
- **The replay is written in the app's schema** (`Z<ENTITY>`, `Z<PROPERTY>`,
  `Z_PK`), so both backends run the same queries. A date is stored as Core
  Data's seconds since 2001. The file is written beside and renamed over.
- 🛑 **Every change set after the baseline is replayed on every change**,
  sorted by global count, then timestamp, then name. A phone that was
  offline can upload one with a count lower than one already applied;
  replaying all puts it in its place. The test pins it. A full replay takes
  about 0.1 s.
- 🛑 **The app makes a new baseline and deletes the change sets it covers**
  (one on 2026-10-22). A pull that finds a newer baseline downloads it,
  keeps only the change sets after its count, and drops the rest.
- **The login.** The app gets it from
  `api.milkforus.com/v1/users/webdav_sync_authorization`:
  `{webdav_base_url, webdav_username, webdav_password}`. Its HTTP cache
  (`Caches/de.danielrinser.milkforus/Cache.db`) keeps that answer, which is
  where `setup` reads it. `setup` proves it with one PROPFIND, stores the URL
  and user in `plugins.json` and the password in the Keychain, and sets the
  backend. A 401 later says to open the app once and run `setup` again.
- 🛑 **Send the login with the first request.** The server answers 401 with
  `WWW-Authenticate: Basic realm="Milk for Us Sync"`. A client that waits for
  the challenge pays a second round trip each time: 103 files took 130 s
  that way. One kept-alive connection with the header up front pulls a quiet
  check in two requests.
- 🛑 **Read-only.** PROPFIND and GET, nothing else; the fake server in the
  test fails on anything more. The plugin never adds a file to `stores/`,
  so the app does not count it as a device.
- **The agent** is a launchd agent, `com.boulderhopkins.apple-tools.shopping`,
  in `~/Library/LaunchAgents/`. It runs `/usr/bin/python3
  apple-plugin-shopping sync --agent` every 2 minutes and at login, and logs
  only failures and changes to `~/Library/Logs/apple-tools/shopping.log`.
  🛑 Under Homebrew it names `opt/apple-tools/…`, never the realpath
  `Cellar/apple-tools/<version>/…`, which the next upgrade deletes. The
  test pins it.
  `install` refuses while the plugin is not enabled, and `sync --agent` does
  nothing once it is disabled, so `apple plugins disable shopping` stops the
  network use at once. A lock file keeps two pulls from overlapping.
- **Stale after 15 minutes**, against six hours for the app backend: with
  the agent running, a quarter of an hour means several pulls failed.
- `index` never pulls; it reads the replay. The index follows within one
  5-minute AppleTools refresh of a pull.

## Not done

- **No writes.** Milk for Us has no URL scheme, no Shortcuts actions and
  no AppleScript. A write to `db.sqlite` would never reach the phone: the
  sync engine records changes the app itself makes, not rows written behind
  it.
- **No history of when an item was checked off.** The sync engine's
  `events.sqlite` holds about two weeks of changes (`ZCDEOBJECTCHANGE`,
  values in a keyed-archiver blob) and could answer "what did we buy this
  week". Not decoded yet.
- **No sync from `index`**, by design. The agent pulls; an index refresh
  must not connect or start an app.
- A second backend. The class contract is `lists()`, `items()`,
  `history()`, `freshness()`, `sync()` and `status()`, each returning the
  shapes in `--help`.
