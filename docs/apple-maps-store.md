# The Apple Maps store

Where Maps keeps visited places and guides, what the columns mean, and the
traps in reading them. Everything below was measured against a real store on
macOS 27 (2026-08-16): 440 visits, 314 location rows, 18 guides.

## The file

```
~/Library/Containers/com.apple.Maps/Data/Maps/MapsSync_0.0.1
```

A Core Data SQLite database, 19 MB here, in WAL mode. Reading it needs Full
Disk Access for the calling terminal. Three sibling files matter:

| File | What it is |
|---|---|
| `MapsSync_0.0.1` | the store |
| `MapsSync_0.0.1-wal` | 2.8 MB here, and it holds the newest visits |
| `MapsSync_0.0.1_deviceLocalCache.db` | a per-device copy with the same table names |

There are two more stores in that directory. `ReviewedPlaceCache` holds one
`reviewedplace` table. `com.apple.Maps.Suggestions/` holds a
`MapsSuggestionsManager_Maps.storage`. Neither is read by `apple maps`.

## Why there is no fallback

**Maps.app ships no AppleScript dictionary.** `sdef
/System/Applications/Maps.app` prints nothing and exits 0. Same as Phone.app.

**Its App Intents only drive navigation.** `util/appintents-dump` reports five
actions, and none of them reads history:

| Intent | Title | Opens app |
|---|---|---|
| `StartNavigationIntent` | Start Navigation in Maps | no |
| `UpdateNavigationIntent` | Add stops | yes |
| `MapsShowPlacesInAppIntent` | Shows List of Places | yes |
| `TestStartNavigationIntent` | Test: Drive to Apple Park | no |
| `TestUpdateNavigationIntent` | Test: Update Navigation Waypoints | no |

So reading the file is the only route to visits and guides.

## 🛑 Never write to this store

CloudKit mirrors it. The store carries 1,936 `NSCKRecordMetadata` rows, 1,241
`NSCKEvent` rows and 6 record zones. It also carries Core Data triggers that
maintain denormalised counters:

- `Z_DA_Z_7PLACES_Collection_placesCount_*` keeps `ZCOLLECTION.ZPLACESCOUNT`
  in step with the join table.
- `Z_DA_ZVISIT_VisitedLocation_latestVisitDate_*` keeps
  `ZVISITEDLOCATION.ZLATESTVISITDATE` in step with `ZVISIT`.

A direct write would fight the sync engine and desynchronise those counters.
`MapsDatabase` opens read-only and sets `PRAGMA query_only`.

## ⚠️ This is not Significant Locations

Significant Locations belongs to `routined`, not to Maps. On this Mac:

- `/var/db/locationd/` returns **permission denied**.
- `~/Library/Caches/com.apple.routined/` does not exist.
- `~/Library/Containers/com.apple.routined/Data/` holds only the empty sandbox
  skeleton, no store.

Apple Maps "Visited Places" is a different, newer feature with its own
retention. Never report one as the other.

## Tables

`Z_PRIMARYKEY` maps every entity id to its name. The ones with data here:

| Entity | Table | Rows | What it is |
|---|---|---|---|
| Visit | `ZVISIT` | 440 | one arrival |
| VisitedLocation | `ZVISITEDLOCATION` | 314 | one place |
| Collection | `ZCOLLECTION` | 18 | a guide |
| CollectionItem | `ZCOLLECTIONITEM` | 126 | a saved place |
| — | `Z_7PLACES` | 115 | the guide-to-place join |
| HistoryItem | `ZHISTORYITEM` | 32 | searches, directions, dropped pins |
| ReviewedPlace | `ZREVIEWEDPLACE` | 56 | places rated |
| UserRoute | `ZUSERROUTE` | 3 | custom hikes, with geometry |
| FavoriteItem | `ZFAVORITEITEM` | 14 | Home, work, airports |
| IncidentReport | `ZINCIDENTREPORT` | 32 | incidents reported |
| MixinMapItem | `ZMIXINMAPITEM` | 147 | the place blob behind a favorite or history item |

`apple maps` reads the first five. The rest are documented in `CLAUDE.md` as
future commands.

## Visits

```sql
CREATE TABLE ZVISIT (
  Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZHIDDEN INTEGER,
  ZVISITCLASSIFICATION INTEGER, ZLOCATION INTEGER, ZCREATETIME TIMESTAMP,
  ZMODIFICATIONTIME TIMESTAMP, ZSTARTDATE TIMESTAMP, ZIDENTIFIER BLOB);
```

`ZLOCATION` is the `Z_PK` of a `ZVISITEDLOCATION` row.

### ⚠️ A visit has a start and no end

`ZSTARTDATE` is the only time-shaped column. The store cannot say how long you
stayed anywhere. Do not report a duration from it.

### ⚠️ `ZVISITCLASSIFICATION` is undocumented

Two values appear: `1` on 389 visits and `3` on 51. The `3` visits sit at places
that also have `1` visits, so it is a property of the arrival rather than of the
place. Nothing in the schema says what it means. `apple maps` reports the number
raw rather than inventing a name for it.

## Places

```sql
CREATE TABLE ZVISITEDLOCATION (
  Z_PK INTEGER PRIMARY KEY, ..., ZHIDDEN INTEGER, ZMAPITEMTOPLEVELCATEGORY INTEGER,
  ZMUID INTEGER, ZCREATETIME TIMESTAMP, ZLATESTVISITDATE TIMESTAMP,
  ZLATITUDE FLOAT, ZLONGITUDE FLOAT, ..., ZMAPITEMADDRESS VARCHAR,
  ZMAPITEMCATEGORY VARCHAR, ZMAPITEMCITY VARCHAR, ZMAPITEMNAME VARCHAR,
  ZIDENTIFIER BLOB, ZMAPITEMSTORAGE BLOB);
```

Every row here has a name and a real coordinate. 22 of 314 have no city, and 1
has no address.

### 🛑 123 of 314 location rows carry no visit

They are duplicates. Three separate rows say "Ocean First"; two say "Frequent
Flyers". Each has a NULL `ZLATESTVISITDATE`, so they never held a visit that was
later pruned. They look like ordinary places.

Counting `ZVISITEDLOCATION` therefore reports **314 places where the honest
answer is 191** — a 64% overcount, in the direction that flatters. A place is a
row that has at least one `ZVISIT`. Nothing else is.

`apple maps status` prints the orphan count so the gap is visible rather than
inferred.

### 🛑 `ZHIDDEN` is NULL, not 0

On this store it is NULL on **440 of 440** visits and **314 of 314** locations.
So the obvious predicate matches nothing:

```sql
WHERE ZHIDDEN = 0     -- returns zero rows on a full store
WHERE ZHIDDEN IS NOT 1 -- correct: covers NULL and 0 together
```

The failure mode is an empty result that reads exactly like "you have never been
anywhere". SQLite's `IS NOT` is the only spelling that covers both.

### Categories are `||`-joined, most specific first

```
Dining||American Cuisine||New American Cuisine||Breakfast and Brunch Restaurant||Restaurant
```

Not splitting turns a category filter into a substring grep across unrelated
category names. `ZMAPITEMTOPLEVELCATEGORY` is a separate integer enum (values 0
through 9 here); nothing local names it, so it is reported raw.

### `ZIDENTIFIER` is a 16-byte UUID blob

Not text. `ZMUID` is Apple's own place id, and two `ZVISITEDLOCATION` rows for
one real place share it.

## Guides

```sql
CREATE TABLE ZCOLLECTION (
  Z_PK INTEGER PRIMARY KEY, ..., ZPLACESCOUNT INTEGER, ZPOSITIONINDEX INTEGER,
  ZCREATETIME TIMESTAMP, ZMODIFICATIONTIME TIMESTAMP,
  ZCOLLECTIONDESCRIPTION VARCHAR, ZIMAGEURL VARCHAR, ZTITLE VARCHAR,
  ZIDENTIFIER BLOB, ZIMAGE BLOB);
CREATE TABLE Z_7PLACES (
  Z_7COLLECTIONS INTEGER, Z_8PLACES INTEGER, PRIMARY KEY (...));
```

`Z_7COLLECTIONS` is a `ZCOLLECTION.Z_PK`; `Z_8PLACES` is a
`ZCOLLECTIONITEM.Z_PK`.

### 🛑 12 of 126 saved-place rows belong to no guide

Same orphan pattern as the locations. Listing `ZCOLLECTIONITEM` directly invents
saved places the user cannot see in Maps.app. Places must come through
`Z_7PLACES`.

### The join is genuinely many-to-many

One item here sits in two guides. A query that assumes one guide per item drops
the second.

### `ZPLACESCOUNT` is trigger-maintained and agreed

It summed to 115 against 115 join rows. `apple maps` still counts the join and
reports `declared_places_count` in JSON **only when the two disagree** — a
disagreement would mean the store is inconsistent, which is worth seeing.

### `ZCUSTOMNAME` is usually set

122 of 126 items carry one. It is the name as saved, and it wins over
`ZMAPITEMNAME`. When the two differ the user renamed the place, and both are
reported: dropping either loses the ability to find the place again.

`ZPLACEITEMNOTE` exists but is empty on every item here. Six items carry a
`ZDROPPEDPINCOORDINATE` blob, meaning a pin rather than a real place.

## Dates

Every `TIMESTAMP` column is **seconds** since the Apple epoch (2001-01-01),
stored as a `REAL`.

- 🛑 `chat.db` uses **nanoseconds** for the same conceptual column, and
  `CallHistory.storedata` uses seconds. Sharing one converter across all three
  is wrong by 10⁹ for one of them and still yields a plausible date.
  `MapsEpoch` is deliberately its own type.
- 🛑 Because the column is a `REAL`, comparing it against the *text* that
  `strftime('%s', ...)` returns matches nothing. No error, just an empty
  result. Bind a double.

## The place blob

`ZMAPITEMSTORAGE` (on `ZVISITEDLOCATION`, `ZMIXINMAPITEM` and `ZREVIEWEDPLACE`)
is a GeoServices protobuf. `strings` already pulls readable text out of it —
phone number, website, timezone, the full category list, and a display template
such as `Airport Terminal · {s:s}Denver International Airport{/s:s}`.

Nothing decodes it today. The columns `apple maps` reads are all denormalised
onto the row itself, so the blob is not needed for visits or guides. A proper
decoder would work the way `notestore.py` does for Notes bodies.

## Opening the file

- **Never open with `immutable=1` by default.** The WAL holds the newest visits,
  and `immutable=1` does not replay it. A plain read-only open does. This is the
  same trap that made `apple phone` report a freshly added contact as unknown.
  `MapsDatabase` falls back to `immutable=1` only when the plain open fails, and
  sets `isStale` so the command can warn.
- **Opening a SQLite file validates nothing.** `sqlite3_open_v2` never reads the
  header, and sqlite treats a 0- or 1-byte file as a valid empty database. A
  truncated store would read as "opened fine, you have never been anywhere", so
  `MapsDatabase` probes for `ZVISIT`, `ZVISITEDLOCATION` and `ZCOLLECTION`
  before returning.

## Seams for testing

`APPLE_MAPS_DB_PATH` points the reader at a specific file, or at a path that
does not exist to see what a command does without Full Disk Access. The error
names the variable, so an unreadable override never masquerades as a missing
grant. Same seam as `APPLE_PHONE_DB_PATH` and `APPLE_MAIL_INDEX_PATH`.

`swift/Tests/MapsTests/` builds a store from scratch with this schema, so the
suite runs offline, with Maps.app closed, on a Mac with no history at all.
