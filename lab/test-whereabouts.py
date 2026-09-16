#!/usr/bin/env python3
"""Offline checks for `whereabouts`: where the user was, day by day.

A throwaway index is planted with the four kinds of evidence — a Maps
arrival, a dawarich stay, a photo day, a calendar event — and the rules the
first real run paid for are pinned:

  🛑 a calendar event alone is a plan, never a presence
  🛑 a photo day from somebody else's camera is never the user's presence,
     and never makes a day "away" (a grandparent's photo in Rochester put
     the user 2,336 km from a Disneyland trip on the day they flew home)
  🛑 a day nothing places does not end a trip
  ⚠️ agreement is counted in sources, not records
  ⚠️ the same event on two calendars is one plan

No app, no network. Run it directly:

    ./test-whereabouts.py
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "index.py")
FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


def at(day, hour=12):
    """Local epoch for a date at an hour, so day boundaries are the user's."""
    return datetime.strptime("%s %02d" % (day, hour), "%Y-%m-%d %H").timestamp()


HOME = (40.035, -105.240)         # Boulder
SHOP = (40.017, -105.258)         # 2.6 km away: still "home"
FAR = (33.812, -117.915)          # Anaheim, ~1,300 km
ELSEWHERE = (43.138, -77.462)     # Rochester NY: somebody else's camera

ROWS = []


def row(uid, tool, kind, title, day, hour, spot, body="", people=None,
        container="United States"):
    ROWS.append((uid, tool, kind, uid.split(":")[-1], None, title, container,
                 None, None, at(day, hour), json.dumps(people or []),
                 " ".join(p["name"] for p in (people or [])), body, "r", 1.0,
                 spot[0] if spot else None, spot[1] if spot else None))


# Home is the biggest place: many photo days at HOME make it the anchor.
for i in range(1, 21):
    day = "2026-05-%02d" % i
    row("photos:place:home", "photos", "place", "Home", day, 12, HOME) if i == 1 else None
    row("photos:day:%s:home" % day, "photos", "day", "Home", day, 12, HOME)
row("maps:place:shop", "maps", "place", "Corner Shop", "2026-05-01", 12, SHOP)
row("dawarich:place:far", "dawarich", "place", "Hotel", "2026-05-01", 12, FAR)

# 05-21: home, seen by dawarich twice (two records, ONE source) and maps once.
row("dawarich:visit:1", "dawarich", "suggested", "Home", "2026-05-21", 8, HOME,
    body="Home\nstayed 1h 30m")
row("dawarich:visit:2", "dawarich", "suggested", "Home", "2026-05-21", 18, HOME,
    body="Home\nstayed 45m")
row("maps:visit:1", "maps", "visit", "Corner Shop", "2026-05-21", 12, SHOP)
# ...and the same swim lesson on two calendars.
row("calendar:a", "calendar", "event", "Swim lessons", "2026-05-21", 18, SHOP)
row("calendar:b", "calendar", "event", "Swim lessons", "2026-05-21", 18, SHOP)

# 05-22..05-24: away in Anaheim. 05-23 has ONLY a plan and a relative's photo
# back in Rochester — a gap day that must not end the trip and must not be
# "away" by 2,300 km in the wrong direction.
row("dawarich:visit:3", "dawarich", "suggested", "Hotel", "2026-05-22", 20, FAR,
    body="Hotel\nstayed 9h 00m")
row("maps:visit:2", "maps", "visit", "Hotel", "2026-05-22", 20, FAR)
row("calendar:c", "calendar", "event", "Piano", "2026-05-23", 19, HOME)
row("photos:day:2026-05-23:else", "photos", "day", "Rochester", "2026-05-23", 12,
    ELSEWHERE, body="Rochester\nfrom a shared camera")
row("dawarich:visit:4", "dawarich", "suggested", "Hotel", "2026-05-24", 9, FAR,
    body="Hotel\nstayed 2h 00m")
# 05-25: home again, own camera.
row("photos:day:2026-05-25:home", "photos", "day", "Home", "2026-05-25", 12, HOME)
# 05-26: a calendar event with a pin and nothing else — a plan.
row("calendar:d", "calendar", "event", "Dentist", "2026-05-26", 10, SHOP)
# 05-27: a dawarich stay with no coordinate.
row("dawarich:visit:5", "dawarich", "suggested", "Unknown Location", "2026-05-27", 9, None,
    body="Unknown Location\nstayed 20m")

with tempfile.TemporaryDirectory() as tmp:
    db = os.path.join(tmp, "index.db")
    env = dict(os.environ, APPLE_INDEX_DB=db, APPLE_PLUGINS_BIN="/usr/bin/false")
    subprocess.run([sys.executable, INDEX, "--db", db, "init"], check=True,
                   capture_output=True, env=env)
    con = sqlite3.connect(db)
    con.executemany(
        "INSERT INTO record (uid, tool, kind, native_id, url, title, container, "
        " created, modified, occurred, people, people_text, body, rev, seen_at, "
        " latitude, longitude) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", ROWS)
    con.commit(); con.close()

    def run(*args):
        proc = subprocess.run([sys.executable, INDEX, "--db", db, "whereabouts"]
                              + list(args), capture_output=True, text=True, env=env)
        if proc.returncode != 0:
            FAILED.append("whereabouts %s exited %d\n%s" % (args, proc.returncode, proc.stderr))
            return {}
        return json.loads(proc.stdout) if "--json" in args else proc.stdout

    r = run("--from", "2026-05-21", "--to", "2026-05-27", "--json")
    check("home is the largest place", r["home"]["name"], "Home")
    days = {d["date"]: d for d in r["days"]}
    check("window days are local dates", r["window"]["days"], 7)

    d = days["2026-05-21"]
    home = [p for p in d["places"] if p["name"] == "Home"][0]
    check("two records from one source are one source", home["agreement"], 1)
    check("one source is a single claim", home["claim"], "single")
    check("minutes add up across stays", home["evidence"]["dawarich"]["minutes"], 135)
    shop = [p for p in d["places"] if p["name"] == "Corner Shop"][0]
    check("maps and calendar: one presence, one plan", (shop["agreement"], shop["claim"]),
          (1, "single"))
    check("the same event on two calendars is one plan",
          len(shop["evidence"]["calendar"]["events"]), 1)
    check("a home day is home", d["state"], "home")
    # 1h30 at default confidence: 0.7 * 0.5 * (0.3 + 0.7*90/180) = 0.2275 → 0.227; the
    # 45m stay is weaker and does not add — one source, its best evidence.
    check("several stays are one source at its best", home["weights"]["dawarich"], 0.227)
    # maps at 12:00 and the swim lesson at 18:00 are 6 h apart: a plan, unkept.
    check("an unkept plan stays a plan", shop["weights"]["calendar"], 0.2)
    check("shop belief", shop["belief"], 0.88)

    d = days["2026-05-22"]
    hotel = d["places"][0]
    check("maps + dawarich corroborate", (hotel["claim"], hotel["agreement"]),
          ("corroborated", 2))
    check("the day is away", d["state"], "away")
    # belief: maps 0.85, a 9 h stay at default confidence 0.7*0.5*1.0 = 0.35,
    # both at 20:00 so they overlap: 1 - 0.15*0.65*0.7 = 0.932
    check("belief is the noisy-OR of the weights", hotel["belief"], 0.932)
    check("and the weights are printed", sorted(hotel["weights"]), ["dawarich", "maps", "overlap"])
    check("distance is from home", 1200 < d["furthest_km"] < 1500, True)

    d = days["2026-05-23"]
    check("a plan and someone else's camera place nobody", d["state"], "unknown")
    claims = sorted(p["claim"] for p in d["places"])
    check("their claims are named", claims, ["planned", "reported"])
    check("someone else's camera is marked", [p["evidence"]["photos"].get("role")
                                            for p in d["places"] if "photos" in p["evidence"]],
          ["alongside"])
    check("and never sets the day's distance", d["furthest_km"], None)
    other = [p for p in d["places"] if "photos" in p["evidence"]][0]
    check("someone else's camera weighs little", other["weights"]["photos"], 0.15)

    d = days["2026-05-26"]
    check("a calendar-only day is unknown, not home", d["state"], "unknown")
    d = days["2026-05-27"]
    check("an unplaced stay is counted", d["unplaced_stays"], 1)
    check("and places nothing", d["state"], "unknown")

    check("one trip", len(r["trips"]), 1)
    trip = r["trips"][0]
    check("the gap day does not end the trip", (trip["from"], trip["to"]),
          ("2026-05-22", "2026-05-24"))
    check("span and placed days are both reported", (trip["days"], trip["days_placed"]), (3, 2))
    check("the trip is named by its place", trip["centre"], "Hotel")
    check("the trip's furthest is the hotel, not Rochester", 1200 < trip["furthest_km"] < 1500,
          True)

    text = run("--from", "2026-05-21", "--to", "2026-05-27")
    check("plain output marks agreement", "✓✓ 0.9" in text and "Hotel" in text, True)
    check("plain output marks a plan", "?  0.20 Corner Shop" in text, True)
    check("plain output names the other camera", "someone else's photos" in text, True)
    check("plain output says what places nobody", "(nothing places you)" in text, True)

    r = run("--from", "2026-05-22", "--to", "2026-05-22", "--home", "%s,%s" % FAR, "--json")
    check("--home moves home", r["home"]["given"], True)
    check("and the hotel is then home", r["days"][0]["state"], "home")

if FAILED:
    print("FAILED %d:" % len(FAILED))
    for f in FAILED:
        print("  -", f)
    sys.exit(1)
print("whereabouts: all checks passed")
