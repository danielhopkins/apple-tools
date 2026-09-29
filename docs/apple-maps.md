# maps — `apple maps`

CLAUDE.md keeps the guardrails and points here. This file is the working reference for `apple maps`: the commands, the flags, and every trap measured on real data. The deeper measurements live in the docs it links to.

Reads `MapsSync_0.0.1` directly, the same way phone reads `CallHistory.storedata`.
Works with Maps.app closed. **Read-only, and it will stay that way.** Schema and
the store traps are in [`docs/apple-maps-store.md`](apple-maps-store.md);
`APPLE_MAPS_DB_PATH` overrides the path, and the test suite builds its own store so
it runs offline.

```
apple maps places [--since DAYS] [--before DAYS] [--search TEXT]
                  [--min-visits N] [--limit N] [--json]   # default subcommand
apple maps visits [--since DAYS] [--before DAYS] [--search TEXT] [--limit N] [--json]
apple maps guides [GUIDE] [--search TEXT] [--places] [--json]
apple maps geocode PLACE [--local-only] [--network-only] [--near TEXT] [--json]
apple maps status [--json]
```

`places` is the default subcommand, so `apple maps` alone lists where the user
goes, most-visited first. `visits` is the same data one arrival at a time.

🛑 **`--limit` DEFAULTS LOW, and counting the rows you get back is how you get a
wrong answer.** `places` defaults to 40 against 197, and `visits` to **50
against 450**. Both now print `showing 50 of 450 visits` on **stderr** when they
cut, and stay silent when they do not. ⚠️ **Before the warning existed, "how
many times did we go to the Elks Lodge this summer" answered `1`. The true
answer was `4`**, and the three older arrivals sat past the cut. Nothing in the
output distinguished that from "you went there once". **Pass `--limit 100000`
whenever you intend to count anything**, and read stderr when you do not.

⚠️ **This is Maps' "Visited Places", not Significant Locations.** Significant
Locations belongs to `routined`, under `/var/db/locationd/`, which no unprivileged
process can read. They are different features with different retention. **Never
report one as the other.**

🛑 **Nothing here writes, and nothing here should.** CloudKit mirrors this store —
1,936 `NSCKRecordMetadata` rows — and Core Data triggers maintain denormalised
counters on it. A direct write would fight the sync engine. There is also no
fallback: Maps.app ships **no AppleScript dictionary at all** (`sdef` prints
nothing), and its five App Intents only drive navigation.

🛑 **A place is a location row that has a visit, and the raw table overcounts
badly.** 123 of the 314 `ZVISITEDLOCATION` rows here carry **no `ZVISIT` at all** —
duplicates of places that already have a visited row. Counting that table reports
**314 places where the honest answer is 191**, a 64% overcount in the flattering
direction. `places` joins through `ZVISIT`; `status` prints the orphan count so the
gap is visible rather than inferred.

⚠️ **A visit records a start time and nothing else.** There is no end time in the
schema, so this store **cannot say how long the user stayed** anywhere. Do not
report a duration from it. ⚠️ `ZVISITCLASSIFICATION` is undocumented and reported
raw, with no label.

**Guides are the richest thing in the store.** 18 here, holding 126 saved places:
`Boulder Playgrounds` with 21 named parks and street addresses, plus one trip guide
per work trip since 2020.

- 🛑 **Places come through `Z_7PLACES`, never off `ZCOLLECTIONITEM`.** 12 of the 126
  item rows belong to no guide, so listing that table invents saved places the user
  cannot see in Maps.app. The join is genuinely many-to-many.
- ⚠️ **An ambiguous guide name is an error naming the candidates**, not a guess.
  Same rule `apple messages` uses for a chat reference.
- **A renamed place keeps both names.** `ZCUSTOMNAME` is set on 122 of 126 items and
  wins; `map_item_name` appears in JSON only when the two differ.

**Categories are `||`-joined, most specific first** —
`Dining||American Cuisine||Restaurant` — and `--json` reports both the split
`categories` array and `category` for the first.

**`geocode` turns a name into a coordinate, and answers locally first.**

```
apple maps geocode "costco"                      # a place you have been: no network
apple maps geocode "Union Station Denver"        # falls through to Apple Maps
apple maps geocode "costco" --local-only         # refuse the network
apple maps geocode "costco" --network-only       # skip your own places
```

- **The local answer is usually the better one**, not just the cheaper one.
  "costco" means the branch the user goes to, not whichever branch Apple ranks
  first. A visited place already carries a coordinate, so nothing is geocoded.
- 🛑 **The network fallback is the only part of apple-tools that leaves the
  machine.** It lives in its own `Geocoding` target so a dependency on it is a
  decision. `--local-only` refuses it.
- **A Maps search is biased to where the user has recently been**, taken from the
  **median** of their own visit coordinates — a mean would be dragged into the ocean
  by one trip abroad. Nothing asks Location Services where they are. Measured:
  `geocode costco --network-only` returns Superior, Longmont and Thornton; the same
  query `--near "Seattle, WA"` returns Seattle and Kirkland.
- **`--json` carries `at`**, a `"Name@lat,lon"` string ready to hand to `apple
  reminders --at` or `apple calendar --at`. That is the composed path, and it is
  what keeps the place's name on the reminder.
- **`source` and `network` say where an answer came from**: `visited-place`,
  `guide-place`, `maps-search`, `address-lookup` or `coordinate`. Read `network`,
  never infer it from `source`.

**Every place carries a real coordinate**, unlike a `--location` written by `apple
calendar`. So `apple maps` is the one tool here that can hand you a latitude and
longitude for a place the user has actually been, without touching the network.

**Six tables are read; five more hold data nothing reads yet**: `ZHISTORYITEM` (32
rows: searches, directions, dropped pins — and Maps prunes it, 189 created against
32 kept), `ZUSERROUTE` (3 custom hikes with geometry), `ZFAVORITEITEM` (14),
`ZREVIEWEDPLACE` (56) and `ZINCIDENTREPORT` (32).
