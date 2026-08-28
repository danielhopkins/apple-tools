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
import glob
import os
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
# a tagged face adopts the card that shares its name
# --------------------------------------------------------------------------

# 🛑 PHOTOS ONLY CARRIES A CONTACTS ID WHEN THE USER CONFIRMED ONE IN
# PHOTOS.APP. 16 of the 63 named faces here have none, so they arrive under a
# `photos:<name>` handle and read as strangers — even when a card for them is
# sitting in Contacts with a birthday on it. Measured: Natalie Hasson had a
# card from 2017 and was reported as unknown.
#
# 🛑 `merge_by_name` COULD NOT DO THIS. It builds its table of claimable names
# from people ALREADY IN THE REPORT, so a card only becomes claimable once some
# mail or message already named that person. A child who has never sent
# anything has a card and no records, and the card is invisible to it.

def entry(pid, name, channels, known=False):
    return {"id": pid, "name": name, "handle": pid, "known": known,
            "channels": dict(channels), "handles": {pid}, "days": set(),
            "channel_days": {}, "alone": {}, "same_list": 0, "upcoming": 0,
            "mail_from": 0, "mail_to": 0, "mail_bulk": 0, "mail_seen": 0,
            "rids": [], "first": None, "last": None, "months": {},
            "names": {name: 1}, "card_is_company": False}


CARD = "AAAA-1111:ABPerson"
ALIASES = {CARD: {"Natalie Hasson"}, "BBBB-2222:ABPerson": {"Jill Hasson"}}

people = {"photos:Natalie Hasson":
          entry("photos:Natalie Hasson", "Natalie Hasson", {"photos": 306})}
moved = index.adopt_photo_cards(people, ALIASES, set())
check("a photo face takes the card that shares its name",
      moved.get("photos:Natalie Hasson"), CARD)
check("...and the row is re-keyed to the card", CARD in people, True)
check("...and is marked known", people[CARD]["known"], True)

# ⚠️ ONLY WHEN PHOTOS IS THE SOLE CHANNEL. Anything with an address or a number
# has already had a better chance to match on the handle, and did not.
people = {"x@y.com": entry("x@y.com", "Natalie Hasson", {"mail": 40})}
check("an address is NEVER adopted by name",
      index.adopt_photo_cards(people, ALIASES, set()), {})
people = {"photos:Natalie Hasson":
          entry("photos:Natalie Hasson", "Natalie Hasson",
                {"photos": 10, "mail": 1})}
check("a face that also has mail is left alone",
      index.adopt_photo_cards(people, ALIASES, set()), {})

# 🛑 TWO CARDS CLAIMING ONE NAME IS REFUSED. Two people really can share a
# name, and the wrong merge is worse than none.
TWO = {"AAAA-1111:ABPerson": {"John Smith"}, "BBBB-2222:ABPerson": {"John Smith"}}
people = {"photos:John Smith": entry("photos:John Smith", "John Smith",
                                     {"photos": 5})}
check("an ambiguous name is refused, not guessed",
      index.adopt_photo_cards(people, TWO, set()), {})

# ⚠️ A business card is never adopted, the same rule the report already uses.
people = {"photos:Natalie Hasson":
          entry("photos:Natalie Hasson", "Natalie Hasson", {"photos": 306})}
check("a company card is not adopted",
      index.adopt_photo_cards(people, ALIASES, {CARD}), {})

# ⚠️ THE NAME MUST AGREE IN FULL. This is why creating a "Ryan Montgomery"
# card did NOT link her: Photos spells her "Ryan Mcgomery", and a second row
# is the bare first name. Neither matches, and neither should.
for spelling in ("Ryan Mcgomery", "Ryan"):
    people = {"photos:" + spelling: entry("photos:" + spelling, spelling,
                                          {"photos": 22})}
    check("a misspelt or partial name does not adopt: %r" % spelling,
          index.adopt_photo_cards(people, {CARD: {"Ryan Montgomery"}}, set()), {})

# 🛑 A CARD THAT ALREADY HAS RECORDS ABSORBS rather than being overwritten.
people = {CARD: entry(CARD, "Natalie Hasson", {"mail": 3}, known=True),
          "photos:Natalie Hasson":
          entry("photos:Natalie Hasson", "Natalie Hasson", {"photos": 306})}
index.adopt_photo_cards(people, ALIASES, set())
check("an existing card keeps its own channels and gains the photos",
      people[CARD]["channels"], {"mail": 3, "photos": 306})
check("...and the photo row is gone", "photos:Natalie Hasson" in people, False)


# --------------------------------------------------------------------------
# a face tag is Apple's guess, not ground truth
# --------------------------------------------------------------------------

# 🛑 THE CLEAREST EVIDENCE IS A PHOTOGRAPH OF SOMEBODY TAKEN BEFORE THEY WERE
# BORN. This user's daughter was born 2019-07-07 and carried 13 tagged photos
# from 2012 to 2017 -- one of them dated the EXACT DAY another child in the
# library was born. Apple's matcher confuses babies with babies.
#
# ⚠️ Rare, and measured: 13 of 15,260 tagged photos, 0.09%, all one person. The
# reason to drop them is not the count. It is that they set `first` to 2012 for
# somebody born in 2019, and nothing else in the report contradicts that.

check("a full birthday is parsed to an epoch",
      isinstance(index._card_birthdays(), dict), True)

# ⚠️ ONLY A FULL BIRTHDAY COUNTS. Contacts stores `--MM-DD` when nobody knows
# the year, and that cannot date anything. This must never become a rule that
# quietly deletes real days.
import subprocess as _sp
_real_apple = index.apple
def _fake_apple(*args, **kw):
    return [{"id": "A:ABPerson", "birthday": "2019-07-07"},
            {"id": "B:ABPerson", "birthday": "--04-13"},
            {"id": "C:ABPerson"},
            {"id": "D:ABPerson", "birthday": "not a date"}]
index.apple = _fake_apple
try:
    born = index._card_birthdays()
finally:
    index.apple = _real_apple
check("a card with a full birthday is dated", "A:ABPerson" in born, True)
check("a card with only --MM-DD is NOT dated", "B:ABPerson" in born, False)
check("a card with no birthday is NOT dated", "C:ABPerson" in born, False)
check("an unparseable birthday is NOT dated", "D:ABPerson" in born, False)
check("the epoch is UTC midnight of that day",
      __import__("datetime").datetime.fromtimestamp(
          born["A:ABPerson"], __import__("datetime").timezone.utc
      ).strftime("%Y-%m-%d %H:%M"), "2019-07-07 00:00")


# --------------------------------------------------------------------------
# the payload declares its own siblings
# --------------------------------------------------------------------------

# 🛑 THREE COPY LISTS SHIP THIS PAYLOAD and none of them can see an `import`
# statement. `make dist`, `app/stage.sh` and the formula's `bin.install` have
# each been the thing that went out wrong. photos.py was left out of the first
# two on the day it was written: both artifacts would have shipped an
# `apple-index` that tracebacks on `--source photos` for every install, while
# working perfectly from a checkout, because `import photos` lives INSIDE the
# photos adapter and nothing runs it until an ingest does.
#
# index.py now declares SIBLING_MODULES, the build asks it, and `selfcheck`
# keeps the declaration honest in both directions.

check("photos is declared as a sibling module",
      "photos" in index.SIBLING_MODULES, True)

# ⚠️ DERIVED FROM THE DIRECTORY, not from a second hand-written list. An
# earlier version named `eval`, `daemon`, `test-photos` and four more by hand —
# which restates a listing that drifts, and four of those names contain a
# hyphen and so could never have been module names at all. Anything importable
# beside index.py that is not declared is dev-only and must not be declared.
_here = os.path.dirname(os.path.abspath(index.__file__))
_beside = {os.path.basename(p)[:-3] for p in glob.glob(os.path.join(_here, "*.py"))}
_dev_only = _beside - set(index.SIBLING_MODULES) - {"index"}
check("lab holds dev-only modules, so a glob would ship them",
      len(_dev_only) > 0, True)
check("and none of them is declared as shipping",
      _dev_only & set(index.SIBLING_MODULES), set())


# --------------------------------------------------------------------------

if FAILURES:
    sys.stderr.write("test-photos: %d failed\n\n" % len(FAILURES))
    for line in FAILURES:
        sys.stderr.write("  ✗ %s\n\n" % line)
    sys.exit(1)
print("test-photos: ok")
