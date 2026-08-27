# The Photos library: what is in it, and what is worth taking

Everything here was measured on one real library on macOS 27.0 (26A5378i):
**36,547 assets, 27,603 with a coordinate, 64 named faces, 21,889 stored
reverse geocodes.** Every number below came off that store.

`lab/photos.py` is the reader. `lab/index.py`'s `ingest_photos` is the adapter.

---

## The short version

Two things in this library are worth having, and they are the two no other
source in this repo can supply:

| | |
|---|---|
| **who you were with** | 64 tagged faces, 47 of them joined to a Contacts card **by id** |
| **everywhere you have been** | 27,603 located photos over 21 years, against 450 arrivals in the Maps store |

Everything else — the pictures, the OCR, Apple's scene labels — was measured and
left behind. The measurements are in "What is deliberately not taken", below.

---

## Why not `osxphotos`

`osxphotos` is excellent and it is installed on this machine. It is not used
here, for three reasons.

1. **It cannot tell a person from a dog.** `PhotoInfo.persons` returns pets
   mixed in with people and exposes no flag to separate them. On this library
   that puts **Emma — a dog — fourth by tagged days**, above every human but
   three. `ZDETECTEDFACE.ZDETECTIONTYPE` says which is which: `1` is a human
   face, `3` a dog, `4` a cat. Seven pets are named here.
2. **It is wrong about this library on macOS 27.** It looks for
   `database/search/psi.sqlite`; the file is now `database/search/leo.sqlite`.
   It warns once on stderr and then reports **zero labels for every photo**,
   which reads exactly like a library that has none.
3. **Nothing else in this repo takes a third-party dependency.** `chat.db`,
   `CallHistory.storedata`, `MapsSync` and `NoteStore.sqlite` are all read
   directly. This is the same job.

---

## Opening the store

`~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite`, with
`mode=ro`. `APPLE_PHOTOS_LIBRARY` overrides the library path.

🛑 **Never `immutable=1`.** The store is in WAL mode with a live
multi-megabyte log and `immutable=1` does not replay it. This is the same
mistake that once made the AddressBook store report a contact as absent
seconds after it was created.

⚠️ **Full Disk Access is needed**, for whatever process calls — the same wall
`messages`, `phone` and `maps` hit. The reader raises `Unavailable` and names
the grant rather than reporting a corrupt library.

---

## People

### A person is a row that has a face

🛑 **The raw table overcounts by 66%.** `ZPERSON` holds **188 named rows**
carrying **106 distinct names**, but only **64 of those names have a single
detected face attached**. The rest are merge sources, shared-library
suggestions and rows synced from another device.

```sql
SELECT p.Z_PK, p.ZFULLNAME, p.ZPERSONURI, MIN(f.ZDETECTIONTYPE)
  FROM ZPERSON p JOIN ZDETECTEDFACE f ON f.ZPERSONFORFACE = p.Z_PK
 WHERE p.ZFULLNAME IS NOT NULL AND p.ZFULLNAME != ''
 GROUP BY p.Z_PK
```

This is the same shape as the rule `apple maps places` exists to enforce: a
place is a location row that **has a visit**, and counting the raw table there
reports 314 places where the honest answer is 191. Same error, same direction,
same fix.

### `ZPERSONURI` is the prize

It holds `UUID:ABPerson` — the exact identifier `apple contacts get` takes.
**47 of the 63 named people carry one.** A tagged face therefore joins to a
contact card **by id**, never by name.

⚠️ **It survives a name change, which nothing else here does.** This library
calls one person "Keith Hopkins". The index calls him "Keith Van Norstrand",
from his mail. Both carry `9BD5F395-6861-4555-9C4E-F074D8875BBE:ABPerson`. The
id join merges them; no name match ever could, and the
`--previous-family-name` workaround was not needed.

⚠️ **The row with the faces is not always the row with the id.** Several names
have three to eight `ZPERSON` rows. Group by `Z_PK` and take the row that has
faces, as above.

### 16 faces carry no id, and three of them had cards all along

🛑 **`ZPERSONURI` is only set when the user confirmed a name against a contact
inside Photos.app.** 16 of the 63 named faces here have none. Those people
arrive under a `photos:<name>` handle and read as strangers — even when a card
for them is sitting in Contacts. Measured: **Natalie Hasson, Kate Auda and Mary
Hopkins all had cards, all three were reported as unknown**, and Natalie's card
has carried her birthday since 2017.

🛑 **`merge_by_name` could not fix it, and the reason is not obvious.** It
builds its table of claimable names out of the people **already in the
report**, so a card only becomes claimable once some mail, message, call or
event has already named that person. A child who has never sent anything has a
card and no records, so the card is invisible to it. `adopt_photo_cards` builds
the table from every card in Contacts instead.

⚠️ **Why this is safe for a face and would not be for an address.** A tagged
face's name was typed by the user, in their own library, onto a face they
recognised. A display name on an email is typed by the sender. Widening
`merge_by_name` to every card would let a stranger signing themselves "John
Smith" adopt a real John Smith's card.

Three fences: the entry's only channel is photos; exactly one card answers to
that name; the card is not marked as a business.

⚠️ **THE NAME MUST AGREE IN FULL, and that is not a shortcoming.** Photos holds
four rows for one child here — `Ryan`, `Ryan Montgomery`, `Ryan` again, and
`Ryan Mcgomery` — and the two rows that carry faces are the bare first name and
the misspelling. Creating a correctly spelled card linked neither, and should
not have. The fix is renaming the person in Photos.app, which no CLI can do.

### Two traps in wiring this into the people report

🛑 **A Contacts id is not a mail handle, and `handle_key` destroyed it.**
`split_handle` lowercases, so `…-F074D8875BBE:ABPerson` arrived as
`…:abperson`, fell past the address branch, and `phone_key` reduced the UUID's
digits to a plausible ten-digit "number": **5940748875**. That is not a near
miss. It merged one real contact into whoever owns that number. The id must be
tested **before** the split, and its case kept.

🛑 **The user's own face lands on a card with nothing to match on.** Photos
tagged this user's face against a bare local card: the right name, **no email,
no phone**. No handle rule could ever claim it, so the user was drawn **sixth
in his own list of people**, with 3,005 photographs of himself.

- ⚠️ Photos cannot settle it. `ZPERSON.ZISMECONFIDENCE` exists and is **empty
  on every row** of this library. There is no "me" flag to read.
- The card is claimed by the same **stem** rule `is_me_by_name` already uses —
  the real card reads "Dan Hopkins", the Photos one "Daniel Hopkins" — and
  only when the card carries no address and no number of its own. Every card
  taken this way is reported in `me.by_card`.

### Shared libraries

⚠️ **`ZVISIBILITYSTATE` splits the library in two, and the split is not
"hidden".** 29,087 assets are state 0, the personal library. **7,460 are state
2**: the iCloud Shared Library and shared albums, other people's cameras
pointed at the same events. They carry 5,713 coordinates and many tagged faces.

For "who was I with" they are often the best evidence there is, because they
are the photos somebody else took **of the user**. But a day whose *every*
photo came from a shared camera may be a day the user was not at. Those days
are marked `alongside` rather than `subject`, and counted the way a mailing
list is: an edge in the graph, never a day of contact.

⚠️ 22 assets are in the trash (`ZTRASHEDSTATE != 0`) and are excluded.

---

## Places

### The coordinate

`ZASSET.ZLATITUDE` / `ZLONGITUDE`.

🛑 **`-180.0` is a sentinel, not a coordinate.** An asset with no location
stores `-180.0` in both columns rather than `NULL`. Read as a number it is a
real point in the Pacific, and **8,733 photos** pile up there.

### The names are already in the store

🛑 **This settled the naming question the wrong way round.** The first attempt
named each photo cluster after the nearest place in the Maps store. It named
this user's **home** after a charity's office 180 m away — the largest cluster
in the library, 1,574 days of photographs, labelled with a stranger's name —
and only **184 of 1,480** clusters got any name at all.

`ZADDITIONALASSETATTRIBUTES.ZREVERSELOCATIONDATA` holds Apple's own reverse
geocode, computed at import and stored. **21,889 of the 27,603 located photos
carry one.** No network call, and never a guess about which nearby thing was
meant. With it, **1,171 of 1,480** clusters are named, and home is "4877
Hopkins Pl, Boulder".

⚠️ **It is an `NSKeyedArchiver` plist**, so `plistlib` reads the container but
not the object graph — the `$objects` table has to be walked by hand. The root
is `PLRevGeoLocationInfo`:

| Field | What it holds |
|---|---|
| `postalAddress` | a `CNPostalAddress`: `_street`, `_city`, `_state`, `_postalCode`, `_country`, `_ISOCountryCode` |
| `mapItem.sortedPlaceInfos` | place names, **sorted by area, smallest first** |
| `addressString` | the whole thing as one line |
| `isHome` | Apple's own flag |

🛑 **Do not read the strings in the order they appear.** The first string is a
street address on one photo and a museum's name on the next. Take
`sortedPlaceInfos[0].name`: entry zero is a point of interest or a street, the
last entry is the continent.

⚠️ **`isHome` is set on only 153 photos here**, so it is a hint and not a
reliable marker of the home cluster. The `sortedPlaceInfos` name is what
actually fixed the mislabel.

Measured coverage: **8 countries, 219 cities.** United States 21,357, Costa
Rica 193, France 115, United Kingdom 70, Netherlands 42, Mexico 29, British
Virgin Islands 22, Canada 1.

### Clustering

🛑 **250 metres, the same number `apple maps geocode` uses** to decide two
branches of a shop are different places. Two thresholds for "same place" in one
repo drift apart, and then a reminder fires somewhere the map does not draw.

Greedy single-link, seeded densest-first — a photo library is not evenly spread
and half of this one is inside one town, so seeding from the densest grid cell
keeps a home or an office as one place rather than smearing it into a chain.

| Radius | Places |
|---|---|
| 150 m | 1,796 |
| **250 m** | **1,480** |
| 500 m | 1,127 |
| 1000 m | 837 |

⚠️ **A cluster is not a visit.** `apple maps` records a genuine arrival with a
start time. This records that a camera was somewhere. Forty photos over one
afternoon are one occasion and forty rows, which is why every count is a count
of **days**.

### Two units that must never be added

🛑 A `maps` **visit** is an arrival. A `photos` **day** is a calendar day on
which a picture was taken. The same place usually has both — 98 of the 1,487
places here — and adding them produces a number with no unit. `apple-index
places` reports `visits` and `photo_days` side by side and never sums them.

⚠️ Neither is "everywhere you have been". Maps holds 450 arrivals; the photo
library holds 27,603 located pictures across 21 years. Photos reaches much
further back and misses everywhere no picture was taken. Say which one an
answer came from.

⚠️ **`container` means a different thing in each adapter.** `maps` puts the
place *category* there; `photos` puts a country. Reading it as a country for
both listed "Dining", "Transportation" and "Travel Accommodation" as
countries — **65 countries where the honest answer is 8**.

🛑 **A merged row keeps the name of the source that actually knows the place.**
Preferring the Maps name on the theory that Apple's directory names things
better re-introduced the exact mislabel above: home, 1,647 photo days, renamed
after an office with two recorded visits.

---

## What is deliberately not taken

### Written text: there is almost none

| Field | Photos carrying it |
|---|---|
| title | 295 (0.8%) |
| description | 100 (0.3%) |
| keywords | 783 (2.2%), **12 distinct** |
| **title + description, total** | **5,349 characters** |

0.15 characters per photo across 36,341. Most of the 12 keywords are a pet
photographer's watermark.

### Apple's generated terms: `leo.sqlite`

29,087 assets (80%) carry search terms, about 53 each, across 25 categories.
`items.lexeme_ids` is a little-endian `uint32` array indexing `lexicon`;
`items.identifier` is the asset UUID; `items.type` is 1 for an asset and 6 for
a moment.

| Category | What it is | Coverage |
|---|---|---|
| 4000 | scene labels | 97.9% |
| 2090 / 2050 | city / street | 74.7% / 67.6% |
| 3000 | named people | 50.6% |
| 4090 | activity | 15.7% |
| 3010 | **pets** | 6.8% |
| 4120 | **OCR text** | 5.9% |

Three reasons none of it is indexed:

1. 🛑 **OCR word order is destroyed.** The terms are a deduplicated bag of
   lowercased words. One real receipt reads
   `circa denver 1615 platte st co 80202 pay with express scan qr code time 12
   pm date 07 2026 ticket 106a0051799 pin 9516`. Findable by keyword,
   unreadable as a sentence — and an `e5` embedding over a scrambled bag is
   weak, which is the retrieval method this index uses.
2. ⚠️ **Much of it is numbers.** One photo's entire text is
   `11 3 22 57 53 54 345 271 152 100 175 14 52 73 0 10 9 2 68…`. 1,721 photos,
   211 KB, median 48 characters each.
3. ⚠️ **Scene labels are a vocabulary, not a description.** Synonym-inflated —
   one photo carries `Laugh, Laughed, Laughing, Laughter` — and generic:
   `Apparatus`, `Apparel`, `Art`, `Asphalts`. Every photo gets many, so they
   do not distinguish one photo from another.

🛑 **`leo.sqlite` is undocumented and was just renamed.** Apple broke
`osxphotos` with that rename this release. Anything built on it breaks the same
way. `ZPERSON` and `ZASSET` are the stable half, and they carry the people and
the coordinates — which is why `photos.py` reads those and not this.

⚠️ **The pet categories are confirmed twice.** `ZDETECTIONTYPE` says a dog, and
lexicon category 3010 reads `Emma, Mac, Pet, Pets` on the same photos.

### The privacy cost, if this ever changes

🛑 **Indexing the OCR would put receipts, boarding passes and PINs in the
index.** `pin 9516` was read out of one photo while measuring this.
[`lab/SECURITY.md`](../lab/SECURITY.md) records the decision not to encrypt,
and that decision was made about mail. This is a different class of secret and
would need deciding again rather than inheriting.

⚠️ **The place names are street addresses** — the user's home and their
friends' homes, since that is what a reverse geocode of a house returns. They
are in the index and on the map's labels.

---

## Detecting a new photo

There is no watermark. `survey()` reads the whole library every run — 2.9 s —
and the ingest compares a `rev` per record. A place's rev is its name, photo
count and day count. A day's rev is the date, the place, the photo count and
the names in it.

Measured by injecting one synthetic asset and diffing the emitted uids:

| A new photo… | What the ingest sees |
|---|---|
| at a known place, on a new day | **+1 day record** |
| at a known place, on a day that already has one | that day's **rev changes** → updated |
| somewhere the camera has never been | **+1 place, +1 day** |
| nothing changed at all | `+0 ~0 -0` in **3.1 s** |

⚠️ **A DELETED photo is only half-caught without `--full`.** If it changes a
surviving day's photo count, the rev catches it on the next ordinary run. If it
empties a day or a place entirely, that record lingers until the id-set sweep.
The app runs that sweep weekly, so a vanished place can persist up to 7 days.

### The uid drifts, a little

🛑 **A place's uid is its rounded cluster MEAN**, so adding photos moves it.
A large cluster barely shifts — one new photo moves a 7,823-photo mean by a
fraction of a metre. A small one can cross the 0.001° (≈111 m) rounding cell.

Measured with a deliberately adversarial case — 40 synthetic photos each placed
200 m from an existing cluster, which maximises the drag on a small mean:

```
baseline place uids                1480
after 40 nearby new photos         1483
  vanished (pruned by --full)         6
  new                                 9
```

**0.4% churn**, far inside the 20% guard that stops `--full` from emptying a
source. The cost of a churned uid is that the place record loses its `first`
date and starts again. Real photos mostly land *inside* an existing cluster,
where nothing moves; this number is an upper bound, not a typical run.

## Cost

| Step | Time |
|---|---|
| open the library | 1.1 s |
| every asset, with faces | 1.1 s |
| + 21,889 reverse-geocode decodes | 4.8 s |
| cluster 27,603 points | 0.3 s |
| **`photos.survey()`, all of it** | **2.9 s** |
| ingest 7,798 records | 6.9 s |
| embed 14,459 chunks | 9.3 s |

**7,798 records, not 36,547**, because the unit is a day and a place. A 4.7×
reduction, and it matches how people remember.

⚠️ **Retrieval quality is unchanged.** `eval.py`'s 34 cases score **MRR 0.538**
with photos in the index and **MRR 0.538** with every photo record deleted.
The source costs nothing and gains nothing on those cases, which is the honest
result: they are questions about mail and notes.
