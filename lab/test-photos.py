#!/usr/bin/env python3
"""Offline checks for the Photos reader and the people wiring around it.

🛑 EVERY CASE HERE PINS A BUG THAT PRODUCED A PLAUSIBLE WRONG ANSWER rather
than an error. None of them would have shown up as a crash.

  * A Contacts id reduced to a phone number. `split_handle` lowercases, so
    `…-F074D8875BBE:ABPerson` fell past the address branch and `phone_key`
    took the UUID's digits: 5940748875. One real contact merged into whoever
    owns that number.
  * A dog ranked fourth by tagged days, above every human but three.
  * 8,733 photos placed in the Pacific, because "no location" is stored as
    -180.0 rather than NULL.
  * A home renamed after a charity's office 180 m away.
  * Place names read out of the archive in the order they appear, which gives
    a street address on one photo and a museum on the next.

No index, no Photos library, no app, no network. Run it directly:

    ./test-photos.py
"""
import plistlib
import sys

import index
import photos

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append("%s\n     got:  %r\n     want: %r" % (name, got, want))


# --------------------------------------------------------------------------
# a Contacts id is a handle, and its case matters
# --------------------------------------------------------------------------

CARD = "9BD5F395-6861-4555-9C4E-F074D8875BBE:ABPerson"

check("a Contacts id survives handle_key intact",
      index.handle_key(CARD), (CARD, ""))
# 🛑 THE ACTUAL FAILURE. Lower-casing first made this a ten-digit "number".
check("...and is NOT reduced to the UUID's digits",
      index.handle_key(CARD)[0], CARD)
check("a Photos-only face keeps a name key and its case",
      index.handle_key("photos:Keith Hopkins"),
      ("photos:Keith Hopkins", "Keith Hopkins"))
# ⚠️ Everything else must behave exactly as before.
check("an address still normalises",
      index.handle_key("Ada <Ada@X.com>"), ("ada@x.com", "Ada"))
check("a number still goes through the digits",
      index.handle_key("+1 (303) 555-0123"), ("3035550123", ""))
check("a non-handle is still refused",
      index.handle_key("undisclosed-recipients:;"), ("", ""))


# --------------------------------------------------------------------------
# the reverse-geocode archive
# --------------------------------------------------------------------------

def archive(objects, root=1):
    """A minimal NSKeyedArchiver plist, the shape Photos writes."""
    return plistlib.dumps({
        "$version": 100000, "$archiver": "NSKeyedArchiver",
        "$top": {"root": plistlib.UID(root)}, "$objects": objects,
    }, fmt=plistlib.FMT_BINARY)


# Entry 0 is `$null`. The place infos are DELIBERATELY out of area order, and
# the smallest is listed last, because sorting is the whole point.
BLOB = archive([
    "$null",
    {"postalAddress": plistlib.UID(2), "mapItem": plistlib.UID(3),
     "addressString": plistlib.UID(11), "isHome": True},
    {"_city": plistlib.UID(8), "_state": plistlib.UID(9),
     "_country": plistlib.UID(10), "_ISOCountryCode": plistlib.UID(12)},
    {"sortedPlaceInfos": plistlib.UID(4)},
    {"NS.objects": [plistlib.UID(5), plistlib.UID(6), plistlib.UID(7)]},
    {"name": plistlib.UID(13), "area": 0.0},
    {"name": plistlib.UID(8), "area": 7607100.0},
    {"name": plistlib.UID(10), "area": 1.0e12},
    "Boulder", "CO", "United States",
    "1 Example St, Boulder, CO, United States", "US", "Children's Museum",
])

place = photos.reverse_geocode(BLOB)
check("the most specific name wins, not the first string",
      place["name"], "Children's Museum")
check("the city comes off the postal address", place["city"], "Boulder")
check("the state comes off the postal address", place["state"], "CO")
check("the country comes off the postal address",
      place["country"], "United States")
check("the ISO code is read", place["country_code"], "US")
check("isHome is carried", place["home"], True)

# ⚠️ ABSENT, NEVER False — the shape every optional key in `apple contacts`
# uses, so "Photos does not say" stays distinguishable from "Photos says no".
NOT_HOME = archive([
    "$null",
    {"postalAddress": plistlib.UID(2), "mapItem": plistlib.UID(3),
     "isHome": False},
    {"_city": plistlib.UID(4)},
    {"sortedPlaceInfos": plistlib.UID(5)},
    "Boulder",
    {"NS.objects": []},
])
check("isHome false is absent, not False",
      photos.reverse_geocode(NOT_HOME)["home"], None)
check("a place with no infos still yields a city",
      photos.reverse_geocode(NOT_HOME)["city"], "Boulder")

# 🛑 A BLOB THAT WILL NOT DECODE IS NOT AN ERROR WORTH STOPPING FOR. The photo
# keeps its coordinate and loses only its name.
check("garbage decodes to None", photos.reverse_geocode(b"not a plist"), None)
check("empty decodes to None", photos.reverse_geocode(b""), None)


# --------------------------------------------------------------------------
# clustering
# --------------------------------------------------------------------------

# Three points within a few metres, and one 4 km away.
HERE = [(40.0350, -105.2400, 1_000_000, ("Home", "Boulder", "CO", "US", "US")),
        (40.0351, -105.2401, 1_086_400, ("Home", "Boulder", "CO", "US", "US")),
        (40.0349, -105.2399, 1_172_800, ("Home", "Boulder", "CO", "US", "US")),
        (40.0700, -105.2400, 1_259_200, ("Away", "Boulder", "CO", "US", "US"))]

spots = photos.cluster(HERE)
check("nearby points make one place, far ones another", len(spots), 2)
check("the busiest place is first", spots[0]["photos"], 3)
check("a day count is days, not photos", spots[0]["days"], 3)
check("the label is the majority vote", spots[0]["label"][0], "Home")
check("the far point kept its own label", spots[1]["label"][0], "Away")

# ⚠️ THE MAJORITY LABEL, not the first seen. A cluster straddles a corner, so
# its photos can carry two neighbourhoods.
SPLIT = [(40.0350, -105.2400, 1_000_000, ("Wrong", None, None, None, None)),
         (40.0351, -105.2401, 1_086_400, ("Right", None, None, None, None)),
         (40.0349, -105.2399, 1_172_800, ("Right", None, None, None, None))]
check("a split cluster takes the majority label",
      photos.cluster(SPLIT)[0]["label"][0], "Right")

# ⚠️ Three photos on ONE day are one day, which is the whole unit correction.
SAME_DAY = [(40.0350, -105.2400, 1_000_000, None),
            (40.0350, -105.2400, 1_000_100, None),
            (40.0350, -105.2400, 1_000_200, None)]
one = photos.cluster(SAME_DAY)[0]
check("three photos in one day count as three photos", one["photos"], 3)
check("...and as ONE day", one["days"], 1)

# A point with no label at all must not crash or invent one.
check("an unlabelled cluster reports no label",
      photos.cluster([(1.0, 1.0, 1_000_000, None)])[0]["label"], None)

# 🛑 THE SENTINEL. -180.0 is "no location", and read as a number it is a real
# point in the Pacific that 8,733 photos would pile up on.
check("the no-location sentinel is a constant, not a magic number",
      photos.NO_LOCATION, -180.0)
check("the radius matches the one `apple maps geocode` uses",
      photos.CLUSTER_RADIUS_M, 250.0)
check("only detection type 1 counts as a person", photos.HUMAN_FACE, 1)

# Distance, so a wrong earth radius or a missing cos(lat) is caught.
metres = photos._metres(40.0350, -105.2400, 40.0350, -105.2388)
check("a tenth of a degree-minute of longitude is about 102 m at 40N",
      95 < metres < 110, True)


# --------------------------------------------------------------------------

if FAILURES:
    sys.stderr.write("test-photos: %d failed\n\n" % len(FAILURES))
    for line in FAILURES:
        sys.stderr.write("  ✗ %s\n\n" % line)
    sys.exit(1)
print("test-photos: ok")
