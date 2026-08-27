"""Reader for the Photos library: who is in a picture, and where it was taken.

🛑 THIS READS SQLITE DIRECTLY, and that is a decision rather than a shortcut.
`osxphotos` is installed on this machine and does most of this well, but it is
a large third-party dependency the rest of `apple-tools` does not have, and it
cannot answer the one question that matters most here: whether a tagged face is
a person or a dog. `ZDETECTEDFACE.ZDETECTIONTYPE` says so and `PersonInfo` does
not expose it. Reading the store is also what every other reader in this repo
does — chat.db, CallHistory, MapsSync and NoteStore are all read the same way.

⚠️ osxphotos 0.76.1 IS ALSO WRONG ABOUT THIS LIBRARY on macOS 27. It looks for
`database/search/psi.sqlite`; the file is now `database/search/leo.sqlite`. It
warns once on stderr and then reports ZERO labels for every photo, which reads
exactly like a library that has none. Nothing here depends on that file.

Two things are taken from the store and nothing else:

  people   who is tagged in each photo, with their Contacts id
  places   where each photo was taken, clustered into visited places

🛑 WHAT IS DELIBERATELY NOT TAKEN: the picture, the OCR text, and Apple's scene
labels. Measured on this library — 36,341 photos carrying 5,349 characters of
title and description between them, twelve distinct keywords, and Live Text on
5.9% of photos whose word order the store destroys. The scene labels exist and
are synonym-inflated to the point of meaninglessness ("Laugh, Laughed, Laughing,
Laughter" on one photo). Indexing any of it would add 36,000 thin bodies to a
retrieval index that already works. See docs/apple-photos-store.md.
"""

import os
import sqlite3
import urllib.parse
from collections import defaultdict

# Core Data keeps Apple-epoch seconds here, like CallHistory and unlike
# chat.db's nanoseconds.
APPLE_EPOCH = 978307200

# 🛑 A SENTINEL, NOT A COORDINATE. An asset with no location stores -180.0 in
# both columns rather than NULL. Read as a number it is a real point in the
# Pacific, and 8,733 photos would pile up there.
NO_LOCATION = -180.0

# ⚠️ ZDETECTIONTYPE 1 IS A HUMAN FACE. 3 is a dog and 4 is a cat. Photos tags
# pets by name exactly as it tags people, and `osxphotos`'s `photo.persons`
# returns them mixed together with no way to tell. Measured here: Emma ranks
# FOURTH by tagged days, above every human but three, and Emma is a dog. Seven
# pets are named on this library.
HUMAN_FACE = 1

DEFAULT_LIBRARY = "~/Pictures/Photos Library.photoslibrary"


class Unavailable(Exception):
    """No readable Photos library. Never a crash: the caller carries on."""


def library_path():
    """The library to read. `APPLE_PHOTOS_LIBRARY` overrides it, for tests."""
    return os.path.expanduser(
        os.environ.get("APPLE_PHOTOS_LIBRARY") or DEFAULT_LIBRARY)


def open_db(library=None):
    """The Photos store, read-only.

    🛑 NEVER `immutable=1`. The store is in WAL mode with a live multi-megabyte
    log, and `immutable=1` does not replay it — the same mistake that made the
    AddressBook store report a contact as absent seconds after it was created.
    `mode=ro` replays the log and still writes nothing.
    """
    path = os.path.join(library or library_path(), "database", "Photos.sqlite")
    if not os.path.exists(path):
        raise Unavailable("no Photos library at %s" % path)
    try:
        db = sqlite3.connect(
            "file:%s?mode=ro" % urllib.parse.quote(path), uri=True)
    except sqlite3.Error as exc:
        # 🛑 `sqlite3.Error`, NOT `OperationalError`. Measured from a launchd
        # job, which has no Full Disk Access: the library STATS FINE and the
        # open fails with `DatabaseError: authorization denied`.
        # `OperationalError` is a SUBCLASS of `DatabaseError`, not its parent,
        # so catching the narrower one missed the only failure this handler
        # exists for — a machine without the grant got a raw traceback instead
        # of the sentence naming it.
        #
        # ⚠️ THE PATH EXISTING PROVES NOTHING. TCC lets the directory listing
        # through and denies the read, so an `os.path.exists` check above is
        # not the guard; this is.
        raise Unavailable(
            "cannot read %s (%s). This needs Full Disk Access for the "
            "calling process." % (path, exc))
    db.row_factory = sqlite3.Row
    return db


def people(db):
    """{person_pk: {name, contact_id, pet}} for everyone with a tagged face.

    🛑 A PERSON IS A ZPERSON ROW THAT HAS A FACE, and the raw table overcounts
    badly. Measured on this library: 188 rows carry a name and 106 of those
    names are distinct, but only 64 of them have a single detected face
    attached. The rest are merge sources, shared-library suggestions and
    entries synced from another device. Counting the table reports 106 people
    where the honest answer is 64 — a 66% overcount, and in the flattering
    direction, exactly like the 64% one `apple maps places` exists to avoid.

    🛑 `ZPERSONURI` IS THE WHOLE PRIZE. It holds `UUID:ABPerson`, the exact
    identifier `apple contacts get` takes, so a face joins to a contact card by
    id and never by name. 47 of the 63 named people here carry one. That is
    what makes this source fold cleanly into `people`, where every other source
    has to guess from a display name.

    ⚠️ It also survives a name change, which nothing else here does. This
    library still calls one person "Keith Hopkins"; the index calls him "Keith
    Van Norstrand" from his mail. Both carry ABPerson id 9BD5F395-…, so the id
    join merges them and a name match never would.
    """
    rows = db.execute("""
        SELECT p.Z_PK          AS pk,
               p.ZFULLNAME     AS name,
               p.ZDISPLAYNAME  AS display,
               p.ZPERSONURI    AS uri,
               MIN(f.ZDETECTIONTYPE) AS detection,
               COUNT(f.Z_PK)   AS faces
          FROM ZPERSON p
          JOIN ZDETECTEDFACE f ON f.ZPERSONFORFACE = p.Z_PK
         WHERE p.ZFULLNAME IS NOT NULL AND p.ZFULLNAME != ''
      GROUP BY p.Z_PK
    """)
    out = {}
    for row in rows:
        uri = (row["uri"] or "").strip()
        out[row["pk"]] = {
            "name": row["name"].strip(),
            "display": (row["display"] or "").strip(),
            # ⚠️ Absent rather than empty, the shape every optional key in
            # `apple contacts` uses.
            "contact_id": uri if uri.endswith(":ABPerson") else None,
            "pet": row["detection"] != HUMAN_FACE,
            "faces": row["faces"],
        }
    return out


def faces_by_asset(db, roster):
    """{asset_pk: [person_pk]} for named, human faces only.

    ⚠️ Pets are dropped HERE rather than by the caller, so no count downstream
    can accidentally include one. `people()` still reports them, because
    "Photos thinks you have seven pets" is a true and useful thing to say.
    """
    out = defaultdict(set)
    for row in db.execute("""
        SELECT ZASSETFORFACE AS asset, ZPERSONFORFACE AS person
          FROM ZDETECTEDFACE
         WHERE ZASSETFORFACE IS NOT NULL AND ZPERSONFORFACE IS NOT NULL
    """):
        who = roster.get(row["person"])
        if who and not who["pet"]:
            out[row["asset"]].add(row["person"])
    return {asset: sorted(who) for asset, who in out.items()}


def assets(db, include_shared=True):
    """Every photo, with its date, its coordinate and its tagged people.

    ⚠️ `ZVISIBILITYSTATE` SPLITS THIS LIBRARY IN TWO, and the split is not
    "hidden". 29,087 assets are state 0, the personal library. 7,460 are state
    2, which is the iCloud Shared Library and shared albums — other people's
    cameras, pointed at the same events. They carry 5,713 coordinates and plenty
    of tagged faces, and for "who was I actually with" they are some of the best
    evidence there is, because they are the photos somebody else took of the
    user. They are included by default and flagged, never silently merged.

    ⚠️ Photos in the trash are excluded. There are 22.
    """
    roster = people(db)
    faces = faces_by_asset(db, roster)
    scope = "" if include_shared else "AND a.ZVISIBILITYSTATE = 0"
    rows = db.execute("""
        SELECT a.Z_PK AS pk, a.ZUUID AS uuid,
               a.ZDATECREATED AS created,
               a.ZLATITUDE AS lat, a.ZLONGITUDE AS lon,
               a.ZVISIBILITYSTATE AS visibility
          FROM ZASSET a
         WHERE a.ZTRASHEDSTATE = 0 %s
    """ % scope)
    for row in rows:
        lat, lon = row["lat"], row["lon"]
        if lat is None or lat == NO_LOCATION or lon == NO_LOCATION:
            lat = lon = None
        yield {
            "uuid": row["uuid"],
            "when": (row["created"] + APPLE_EPOCH) if row["created"] else None,
            "latitude": lat,
            "longitude": lon,
            "shared": row["visibility"] == 2,
            "people": [roster[pk] for pk in faces.get(row["pk"], ())],
        }


# --------------------------------------------------------------------------
# places — turning a cloud of coordinates into somewhere you have been
# --------------------------------------------------------------------------

# 🛑 250 METRES, THE SAME NUMBER `apple maps geocode` USES to decide that two
# branches of a shop are different places. Reusing it is deliberate: two
# thresholds for "same place" in one repo drift apart, and then a reminder
# fires at a place the map does not draw.
CLUSTER_RADIUS_M = 250.0

EARTH_M = 6371000.0


def _metres(lat1, lon1, lat2, lon2):
    """Equirectangular distance. Good to ~0.5% at these separations."""
    import math
    lat = math.radians((lat1 + lat2) / 2.0)
    dx = math.radians(lon2 - lon1) * math.cos(lat)
    dy = math.radians(lat2 - lat1)
    return EARTH_M * math.hypot(dx, dy)


def cluster(points, radius_m=CLUSTER_RADIUS_M):
    """Group coordinates into places. `points` is [(lat, lon, when, label)].

    `label` is any hashable describing that one photo's place, or None. Each
    cluster reports the label the most photos in it agree on.

    ⚠️ GREEDY SINGLE-LINK, seeded densest-first. A photo library is not evenly
    spread — half of this one is inside one town — so seeding from the densest
    grid cell keeps a home or an office as one place rather than smearing it
    into a chain of overlapping ones.

    🛑 A CLUSTER IS NOT A VISIT, and the difference is the whole reason this is
    not called one. `apple maps` records a genuine arrival with a start time.
    This records that a camera was somewhere. Forty photos over one afternoon
    are one occasion and forty rows here, which is why every count below is a
    count of DAYS. The same correction `people` already had to make.
    """
    import math
    # A grid cell about the size of the radius, used only to seed the order and
    # to keep the neighbour search from being O(n²).
    cell = radius_m / 111320.0
    grid = defaultdict(list)
    for point in points:
        lat, lon = point[0], point[1]
        grid[(int(lat / cell), int(lon / cell))].append(point)

    clusters = []
    index = defaultdict(list)      # grid key -> cluster ids that touch it

    for key in sorted(grid, key=lambda k: -len(grid[k])):
        for lat, lon, when, label in grid[key]:
            best, best_d = None, radius_m
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for cid in index.get((key[0] + dx, key[1] + dy), ()):
                        spot = clusters[cid]
                        d = _metres(lat, lon, spot["latitude"], spot["longitude"])
                        if d < best_d:
                            best, best_d = cid, d
            if best is None:
                best = len(clusters)
                clusters.append({"latitude": lat, "longitude": lon,
                                 "photos": 0, "days": set(),
                                 "first": when, "last": when,
                                 "_n": 0, "_votes": defaultdict(int)})
                index[key].append(best)
            spot = clusters[best]
            # A running mean, so a cluster's point is where the photos are
            # rather than wherever the first one happened to be.
            spot["_n"] += 1
            spot["latitude"] += (lat - spot["latitude"]) / spot["_n"]
            spot["longitude"] += (lon - spot["longitude"]) / spot["_n"]
            spot["photos"] += 1
            if label is not None:
                spot["_votes"][label] += 1
            if when:
                spot["days"].add(int(when // 86400))
                spot["first"] = min(spot["first"] or when, when)
                spot["last"] = max(spot["last"] or when, when)
    for spot in clusters:
        spot["days"] = len(spot["days"])
        # ⚠️ THE MAJORITY LABEL, not the first one seen. A cluster straddles a
        # street corner, so its photos can carry two neighbourhoods and, at a
        # border, two countries. One vote per photo settles it.
        votes = spot.pop("_votes")
        spot["label"] = (max(votes.items(), key=lambda kv: (kv[1], kv[0]))[0]
                         if votes else None)
        spot["labelled"] = sum(votes.values())
        del spot["_n"]
    clusters.sort(key=lambda s: -s["days"])
    return clusters


# --------------------------------------------------------------------------
# reverse geocoding — already done, already local
# --------------------------------------------------------------------------

# 🛑 THE PLACE NAMES ARE ALREADY IN THE STORE, and finding that settled the
# naming question the wrong way round. The first attempt named a photo cluster
# after the nearest place in the Maps store. It named this user's HOME after a
# charity's office 180 m away, and did so for 1,574 days of photographs — the
# largest cluster in the library, labelled with a stranger's name. Only 184 of
# 1,480 clusters got any name at all that way.
#
# `ZADDITIONALASSETATTRIBUTES.ZREVERSELOCATIONDATA` holds Apple's own reverse
# geocode, computed at import time and stored: 21,893 of the 27,603 located
# photos here carry one. It costs no network call and it is never a guess about
# which nearby thing was meant.
#
# ⚠️ IT IS AN NSKeyedArchiver PLIST, so `plistlib` reads the container but not
# the object graph. The `$objects` table has to be walked by hand. Do NOT read
# it by taking strings in the order they appear — the first string is a street
# address on one photo and a museum's name on the next.

_HOME_UNKNOWN = object()


def _resolve(objs, ref, depth=0):
    """One node of an NSKeyedArchiver graph, with UIDs followed."""
    import plistlib
    if depth > 6:
        return None
    if isinstance(ref, plistlib.UID):
        ref = objs[ref.data]
    if isinstance(ref, str):
        return None if ref == "$null" else ref
    if isinstance(ref, dict):
        if "NS.objects" in ref:
            return [_resolve(objs, x, depth + 1) for x in ref["NS.objects"]]
        return {k: _resolve(objs, v, depth + 1)
                for k, v in ref.items() if not k.startswith("$")}
    return ref


def reverse_geocode(blob):
    """{name, city, state, country, country_code, home} from one blob.

    ⚠️ `sortedPlaceInfos` IS SORTED BY AREA, smallest first, and that ordering
    is the only reliable way to get "the most specific name for here". Entry
    zero is a point of interest or a street; the last entry is the continent.
    Reading a fixed index gives a country on one photo and a café on another.

    🛑 `isHome` IS A FLAG APPLE ALREADY SET, and it is the honest answer to the
    biggest cluster in any personal library. Nothing else here can tell a home
    from a business 180 m away.
    """
    import plistlib
    try:
        plist = plistlib.loads(blob)
        objs = plist["$objects"]
        root = _resolve(objs, plist["$top"]["root"])
    except (ValueError, KeyError, TypeError, IndexError):
        # ⚠️ A blob that will not decode is not an error worth stopping for.
        # The photo keeps its coordinate and loses only its name.
        return None
    if not isinstance(root, dict):
        return None
    postal = root.get("postalAddress") or {}
    infos = ((root.get("mapItem") or {}).get("sortedPlaceInfos")) or []
    name = None
    for info in infos:
        if isinstance(info, dict) and info.get("name"):
            name = info["name"]
            break
    return {
        "name": name,
        "city": postal.get("_city"),
        "state": postal.get("_state"),
        "country": postal.get("_country"),
        "country_code": postal.get("_ISOCountryCode"),
        "address": root.get("addressString"),
        # ⚠️ Absent rather than False, so "Photos does not say" and "Photos says
        # no" stay distinguishable.
        "home": True if root.get("isHome") else None,
    }


def located_assets(db, include_shared=True):
    """`assets()`, plus the stored reverse geocode for anything that has one."""
    places = {}
    for row in db.execute("""
        SELECT a.ZUUID AS uuid, x.ZREVERSELOCATIONDATA AS blob
          FROM ZADDITIONALASSETATTRIBUTES x
          JOIN ZASSET a ON a.ZADDITIONALATTRIBUTES = x.Z_PK
         WHERE x.ZREVERSELOCATIONDATA IS NOT NULL
    """):
        places[row["uuid"]] = row["blob"]
    for asset in assets(db, include_shared=include_shared):
        blob = places.get(asset["uuid"])
        asset["place"] = reverse_geocode(blob) if blob else None
        yield asset


def assign(clusters, radius_m=CLUSTER_RADIUS_M):
    """A function mapping one coordinate to its cluster index, or None."""
    cell = radius_m / 111320.0
    grid = defaultdict(list)
    for i, spot in enumerate(clusters):
        grid[(int(spot["latitude"] / cell),
              int(spot["longitude"] / cell))].append(i)

    def which(lat, lon):
        key = (int(lat / cell), int(lon / cell))
        best, best_d = None, radius_m * 2
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in grid.get((key[0] + dx, key[1] + dy), ()):
                    d = _metres(lat, lon, clusters[i]["latitude"],
                                clusters[i]["longitude"])
                    if d < best_d:
                        best, best_d = i, d
        return best
    return which


def survey(include_shared=True, radius_m=CLUSTER_RADIUS_M):
    """The whole library, as places and as days. One pass, about six seconds.

    Returns `(places, days)`.

      places  one per cluster: where the camera has been, with a name voted on
              by its photos, a day count, and a first and last date.
      days    one per (day, place): what the library says about one occasion —
              who was tagged in it and where it was.

    🛑 A DAY, NOT A PHOTO, and this is the same correction `people` already
    made once. Forty photos of one afternoon are one occasion. Indexing each
    one separately would put 36,547 near-identical thin records into a
    retrieval index of 239,000 chunks, and would let a burst of holiday
    snapshots outrank a year of ordinary contact. Grouping first gives 7,798
    records, and every count downstream is then in a unit that cannot be
    inflated by how trigger-happy somebody was.

    ⚠️ A photo with neither a person nor a coordinate is dropped. It has
    nothing to say here — there is no caption to search, by design.
    """
    from datetime import datetime, timezone
    db = open_db()
    everything = list(located_assets(db, include_shared=include_shared))

    def label_of(asset):
        spot = asset.get("place")
        if not spot:
            return None
        return (spot.get("name"), spot.get("city"), spot.get("state"),
                spot.get("country"), spot.get("country_code"))

    points = [(a["latitude"], a["longitude"], a["when"], label_of(a))
              for a in everything if a["latitude"] is not None]
    places = cluster(points, radius_m)
    for spot in places:
        name, city, state, country, code = spot.pop("label") or (None,) * 5
        spot.update(name=name, city=city, state=state,
                    country=country, country_code=code)
    which = assign(places, radius_m)

    days = {}
    for asset in everything:
        if not asset["when"]:
            continue
        if not asset["people"] and asset["latitude"] is None:
            continue
        day = datetime.fromtimestamp(
            asset["when"], timezone.utc).strftime("%Y-%m-%d")
        at = (which(asset["latitude"], asset["longitude"])
              if asset["latitude"] is not None else None)
        entry = days.get((day, at))
        if entry is None:
            entry = days[(day, at)] = {
                "day": day, "place": at, "photos": 0, "shared": 0,
                "people": {}, "when": asset["when"],
            }
        entry["photos"] += 1
        entry["shared"] += 1 if asset["shared"] else 0
        entry["when"] = min(entry["when"], asset["when"])
        for who in asset["people"]:
            key = who["contact_id"] or ("photos:" + who["name"])
            seen = entry["people"].get(key)
            if seen is None:
                seen = entry["people"][key] = dict(who, photos=0)
            seen["photos"] += 1
    return places, sorted(days.values(), key=lambda d: d["when"])
