# Geocoding

Turning a place name into a coordinate: the only network call in this repo, why
it exists, where it is allowed, and the two constraints that shaped it.

Measured on macOS 27, 2026-08-16.

## What uses it

| Command | What it does | Network? |
|---|---|---|
| `apple maps geocode QUERY` | a coordinate for a place | only if nothing local matches |
| `apple reminders add\|edit --at` | a location reminder | always |
| `apple calendar add\|edit --at` | an event with a real map pin | always |

Everything else in apple-tools reads local stores and makes no network call.
The code lives in its own `Geocoding` target, with no other target's code in it,
so depending on it is a visible decision rather than an accident.

## Why it exists

Two gaps, both previously documented here as unfixable.

**A calendar event could not get a map pin.** `EKEvent.location` is plain text.
The coordinate lives on a separate `EKStructuredLocation`, and only that
produces a map thumbnail or a travel-time alert. Nothing geocodes the string
afterwards — not EventKit on save, not the calDAV server on sync, not
Calendar.app on display. Real street addresses sat in this store for months
without gaining a coordinate. Before `--at`, the only route was Calendar.app's
address picker.

Verified in a matched pair, same address, two events:

| Flag | `has_coordinate` | Coordinate |
|---|---|---|
| `--location "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO 80303"` | `false` | — |
| `--at "Big Daddy Bagels, 4800 Baseline Rd, Boulder, CO"` | `true` | `39.9976725,-105.233365` |

**A reminder could not have a location trigger.** `apple reminders` read one
(`EKReminder+Encodable.swift` reports `locationTitle` and `location`) but had no
flag to write one. The API is public — `EKAlarm.structuredLocation` plus
`EKAlarm.proximity` — it simply needed a coordinate to put in it.

## 🛑 The local answer is usually the better one

`apple maps geocode` tries the user's own visited places and guides **first**.
That is not only cheaper, it is more correct: a bare "costco" typed by this user
means the Superior branch they have been to eight times, not whichever branch
Apple ranks first globally. A visited place already carries a real coordinate,
so nothing is geocoded at all.

```
$ apple maps geocode costco
Costco Wholesale  39.959595,-105.174511
    600 Marshall Rd, Superior, CO  80027, United States  8 visits  visited-place
```

Ranking, in order:

1. An exact name match beats a partial one. "Safeway" must not lose to "Safeway
   Fuel Station" because the latter was visited more.
2. Among equals, more visits wins.
3. A visited place beats a guide place.

Duplicates are collapsed on coordinates rounded to 4 decimal places, because one
real shop can appear as both a visited place and a guide entry.

## The region bias, and why it is not Location Services

`MKLocalSearch` for "costco" with no region returns whatever Apple ranks
globally. The bias is what makes a bare name useful.

`apple maps geocode` derives it from the **median** latitude and longitude of
the user's visits in the last 120 days. Nothing asks `CLLocationManager` where
the user is, so this costs no Location Services grant.

⚠️ **The median, not the mean.** One trip abroad drags a mean into the ocean.

Measured:

```
$ apple maps geocode costco --network-only --limit 3
Costco Wholesale     39.959595,-105.174511   600 Marshall Rd, Superior, CO
Costco Food Court    40.150566,-105.087131   205 E Ken Pratt Blvd, Longmont, CO
Costco Wholesale     39.991118,-104.983784   16375 Washington St, Thornton, CO

$ apple maps geocode costco --network-only --near "Seattle, WA" --limit 2
Costco Wholesale     47.565436,-122.330232   4401 4th Ave S, Seattle, WA
Costco Wholesale     47.681120,-122.181630   8629 120th Ave NE, Kirkland, WA
```

## 🛑 `reminders` cannot read the Maps store

This is the constraint that split `Geocoding` out of `MapsLibrary`.

`reminders`, `apple-calendar` and `apple-contacts` re-execute themselves
**disclaimed** (`posix_spawn` with `responsibility_spawnattrs_setdisclaim`), so
TCC attributes their grant to the binary rather than to the calling terminal.
Full Disk Access is attributed to the responsible process, so a disclaimed
process **loses it**.

Probed directly rather than assumed:

```
  plain process:    YES (16 bytes, header: SQLite)
  disclaimed child: NO (You don't have permission to save the file
                        "MapsSync_0.0.1" in the folder "Maps".)
```

Same binary, same file, same terminal. So a geocoder that `reminders` can link
must not touch the Maps store, and `Geocoding` does not.

The composed path gets the local answer anyway:

```
AT=$(apple maps geocode costco --json | jq -r '.[0].at')
apple reminders add Errands "Buy milk" --at "$AT"
```

This is the same reason `apple phone` can never join the disclaiming group.

## The `Name@lat,lon` form

`geocode --json` emits an `at` field:

```json
{ "name": "Costco Wholesale", "latitude": 39.959595, "longitude": -105.174511,
  "source": "visited-place", "network": false, "visits": 8,
  "at": "Costco Wholesale@39.959595,-105.174511" }
```

Hand that straight to `--at`. Without the label the reminder's location reads
`39.96,-105.17`, which is correct and useless.

⚠️ Parsing splits on the **last** `@`, and only when the right-hand side really
parses as a coordinate pair. A place name may contain one, and treating
`Bar@Home, Boulder` as a labelled coordinate would send the lookup elsewhere.

## Traps

### 🛑 A semaphore deadlocks in a CLI

Both `MKLocalSearch` and `CLGeocoder` deliver their completion **on the main
queue**. A command-line tool runs its work on the main *thread* without entering
a run loop, so nothing drains that queue: blocking on a semaphore waits forever
for a callback that cannot be delivered.

Measured — the first version timed out at 15s on every network lookup while the
local path answered instantly. The fix is to start the request on the calling
thread and drive `RunLoop.main` by hand until the completion lands. After it,
the same lookup returns in 0.6s.

### 🛑 A swapped coordinate pair is plausible and wrong

`-105.23,40.03` is a longitude in the latitude slot. Every digit looks fine, and
accepting it puts the reminder in the Southern Ocean where nothing looks wrong
until it fails to fire. Latitude beyond ±90 is the signal that catches it, and
both ranges are checked.

### ⚠️ A structured location without a coordinate triggers nothing

It still shows a name in Reminders.app. So a failed lookup that saved anyway
would look exactly like a working location reminder and simply never fire. Every
path refuses instead.

### ⚠️ Ambiguity is refused, not guessed

A shop name matching branches more than 250 m apart is an error listing them.
Pinning a meeting to the wrong branch is a mistake nobody notices until they
drive there. Narrow with `--near`, or pass a coordinate.

Results *within* 250 m of the best one are treated as the same place, because
Maps often returns a store and its food court as separate items.

### ⚠️ `--location` never geocodes, deliberately

A location that is not a place — "Zoom", "my desk", a room name — must not be
silently turned into a coordinate somewhere else in the world. `--location` stays
a verbatim text write on both tools. Ask for a pin explicitly with `--at`.

### ⚠️ Resolve before writing

Both `reminders` and `calendar` geocode **before** touching the item, so a failed
lookup leaves nothing created and nothing half-edited. In `calendar edit` the
resolve also happens before the first save attempt, so the built-in retry applies
an identical change rather than asking Maps twice.

## Testing

`swift/Tests/GeocodingTests/` covers parsing, labelling and the source flags —
13 tests, all offline.

**`NetworkGeocoder` is deliberately not exercised by `swift test`.** Doing so
would make the suite depend on Apple's servers and on the machine having a
network, which no other suite here does. The network paths were verified by hand
against real queries, recorded above.
