#!/usr/bin/env python3
"""Offline checks for apple-plugin-whatsapp.

Nothing here reads WhatsApp's real store. The three files are built in a
temp folder with the columns the plugin reads, in the shapes measured on a
real store: an @lid sender that only ContactsV2 can turn into a number, a
chat titled with a bare number wrapped in bidi controls, a caption in the
media row rather than the message, the year-4000 sentinel, and a message
that exists ONLY in the write-ahead log.

    ./test-whatsapp.py
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "apple-plugin-whatsapp")
APPLE_EPOCH = 978307200
RECORD_FIELDS = ["uid", "tool", "kind", "native_id", "url", "title", "container", "created",
                 "modified", "occurred", "latitude", "longitude", "people", "body", "rev"]

FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


def run(args, env, expect=0):
    proc = subprocess.run([PLUGIN] + args, capture_output=True, text=True, env=env)
    if proc.returncode != expect:
        FAILED.append("%s exited %d (want %d)\n%s" % (" ".join(args), proc.returncode, expect,
                                                      proc.stderr.strip()))
    return proc


def apple(days_ago, minutes=0):
    return time.time() - APPLE_EPOCH - days_ago * 86400 + minutes * 60


ME_LID = "111@lid"
ANA_LID = "222@lid"            # in the address book: ContactsV2 maps her
ANA_WA = "15550001111@s.whatsapp.net"
BOB_LID = "333@lid"            # NOT in the address book; only his push name
CARL_WA = "15550002222@s.whatsapp.net"
DAVE_LID = "444@lid"           # unmapped, but his chat is titled with his number
EVE_LID = "555@lid"            # unmapped; a card claims her id with a URL
GROUP = "120363000000000001@g.us"


def build(folder):
    """Returns an open connection to ChatStorage that holds the WAL open."""
    chat = sqlite3.connect(os.path.join(folder, "ChatStorage.sqlite"))
    chat.execute("PRAGMA journal_mode=WAL")
    chat.executescript("""
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZARCHIVED INTEGER, ZHIDDEN INTEGER,
            ZREMOVED INTEGER, ZSESSIONTYPE INTEGER, ZUNREADCOUNT INTEGER, ZLASTMESSAGEDATE TIMESTAMP,
            ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZISACTIVE INTEGER, ZCHATSESSION INTEGER,
            ZCONTACTNAME VARCHAR, ZMEMBERJID VARCHAR);
        CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZFILESIZE INTEGER, ZMOVIEDURATION INTEGER,
            ZLATITUDE FLOAT, ZLONGITUDE FLOAT, ZMEDIALOCALPATH VARCHAR, ZTITLE VARCHAR, ZVCARDNAME VARCHAR);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER,
            ZSTARRED INTEGER, ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER, ZMEDIAITEM INTEGER,
            ZMESSAGEDATE TIMESTAMP, ZFROMJID VARCHAR, ZSTANZAID VARCHAR, ZTEXT VARCHAR);
        CREATE TABLE ZWAPROFILEPUSHNAME (Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZPUSHNAME VARCHAR);
    """)
    chat.executemany("INSERT INTO ZWACHATSESSION VALUES (?,?,?,?,?,?,?,?,?)", [
        (1, 0, 0, 0, 1, 0, apple(1), GROUP, "School Board Watchers"),
        (2, 0, 0, 0, 0, 0, apple(3), CARL_WA, "Carl Jones"),
        (3, 0, 0, 0, 0, 0, apple(40), DAVE_LID, "‪+1 (940) 290‑7669‬"),
        # WhatsApp's own chat: the year-4000 sentinel, and the number 0.
        (4, 0, 0, 0, 0, 0, 63113904000.0, "0@s.whatsapp.net", "‎WhatsApp"),
        (5, 0, 0, 1, 0, 0, apple(2), "15559999999@s.whatsapp.net", "Removed Chat"),
    ])
    chat.executemany("INSERT INTO ZWAGROUPMEMBER VALUES (?,?,?,?,?)", [
        (1, 1, 1, "Ana Garcia", ANA_LID),
        (2, 1, 1, None, BOB_LID),
        (3, 1, 1, None, EVE_LID),
    ])
    chat.execute("INSERT INTO ZWAPROFILEPUSHNAME VALUES (1, ?, 'Bobby')", (BOB_LID,))
    chat.executemany("INSERT INTO ZWAMEDIAITEM VALUES (?,?,?,?,?,?,?,?)", [
        # A caption in the media row, and a latitude that is not one (654.0
        # was measured on a real image row).
        (1, 1000, 0, 654.0, 0.0, "Media/x/slide.jpg", "Budget slide from the training", "ignored"),
        (2, 0, 42, None, None, None, None, None),
        (3, 0, 0, None, None, None, "District budget calendar", None),
    ])
    rows = [
        # (pk, from_me, type, chat, member, media, date, from, stanza, text)
        (1, 0, 0, 1, 1, None, apple(2), GROUP, "S1", "Is the board meeting on Monday?"),
        (2, 1, 0, 1, None, None, apple(2, 5), None, "S2", "Yes, public comment opens at 6"),
        (3, 0, 1, 1, 2, 1, apple(2, 10), GROUP, "S3", None),
        (4, 0, 6, 1, 2, None, apple(2, 11), GROUP, "S4", "333@lid"),
        (5, 0, 3, 1, 1, 2, apple(2, 12), GROUP, "S5", None),
        (6, 0, 7, 1, 1, 3, apple(2, 13), GROUP, "S6", "See https://example.org/budget"),
        (7, 0, 0, 2, None, None, apple(3), CARL_WA, "S7", "Lunch Friday?"),
        (8, 0, 0, 3, None, None, apple(40), DAVE_LID, "S8", "Hi, is this Dan?"),
        (9, 0, 0, 5, None, None, apple(2), "15559999999@s.whatsapp.net", "S9", "gone"),
        (10, 0, 0, 1, 3, None, apple(2, 14), GROUP, "S10", "I can bring the flyers"),
    ]
    # Eleven more in the group, so the chat makes two index blocks.
    for i in range(11):
        rows.append((100 + i, 1, 0, 1, None, None, apple(1, i), None, "B%d" % i, "filler %d" % i))
    chat.executemany("INSERT INTO ZWAMESSAGE VALUES (?,?,?,0,?,?,?,?,?,?,?)", rows)
    chat.commit()

    contacts = sqlite3.connect(os.path.join(folder, "ContactsV2.sqlite"))
    contacts.executescript("""
        CREATE TABLE ZWAADDRESSBOOKCONTACT (Z_PK INTEGER PRIMARY KEY, ZLID VARCHAR,
            ZWHATSAPPID VARCHAR, ZPHONENUMBER VARCHAR, ZFULLNAME VARCHAR, ZBUSINESSNAME VARCHAR);
    """)
    contacts.execute("INSERT INTO ZWAADDRESSBOOKCONTACT VALUES (1, ?, ?, '+15550001111', "
                     "'Ana Garcia-Lopez', NULL)", (ANA_LID, ANA_WA))
    contacts.commit()
    contacts.close()

    calls = sqlite3.connect(os.path.join(folder, "CallHistory.sqlite"))
    calls.executescript("""
        CREATE TABLE ZWAAGGREGATECALLEVENT (Z_PK INTEGER PRIMARY KEY, ZINCOMING INTEGER,
            ZMISSED INTEGER, ZVIDEO INTEGER, ZFIRSTDATE TIMESTAMP);
        CREATE TABLE ZWACDCALLEVENT (Z_PK INTEGER PRIMARY KEY, Z1CALLEVENTS INTEGER, ZOUTCOME INTEGER,
            ZDURATION FLOAT, ZDATE TIMESTAMP, ZCALLIDSTRING VARCHAR, ZGROUPJIDSTRING VARCHAR);
        CREATE TABLE ZWACDCALLEVENTPARTICIPANT (Z_PK INTEGER PRIMARY KEY, Z1PARTICIPANTS INTEGER,
            ZOUTCOME INTEGER, ZJIDSTRING VARCHAR);
    """)
    calls.executemany("INSERT INTO ZWAAGGREGATECALLEVENT VALUES (?,?,?,?,?)", [
        (1, 1, 1, 0, apple(5)), (2, 0, 0, 1, apple(1))])
    calls.executemany("INSERT INTO ZWACDCALLEVENT VALUES (?,?,?,?,?,?,?)", [
        (1, 1, 1, 0.0, apple(5), "C1", None), (2, 2, 0, 125.0, apple(1), "C2", None)])
    calls.executemany("INSERT INTO ZWACDCALLEVENTPARTICIPANT VALUES (?,?,?,?)", [
        (1, 1, 1, CARL_WA), (2, 2, 0, ANA_LID)])
    calls.commit()
    calls.close()

    # 🛑 The newest message lives in the WAL only. Everything before it is
    # checkpointed into the main file, so a reader that skips the WAL
    # (`immutable=1`) sees a plausible store that is one message short —
    # the failure that matters, since it looks like a quiet chat. Then
    # autocheckpoint is off and this connection stays open.
    chat.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    chat.execute("PRAGMA wal_autocheckpoint=0")
    chat.execute("INSERT INTO ZWAMESSAGE VALUES (200, 0, 0, 0, 2, NULL, NULL, ?, ?, 'W1', "
                 "'only in the write-ahead log')", (apple(0, -5), CARL_WA))
    chat.commit()
    return chat


# What `apple contacts list --json` returns, trimmed to the keys read.
CARDS = [
    # Claims Eve's @lid; no phone, so her email becomes the handle.
    {"id": "EVE:ABPerson", "name": "Eve Card", "emails": [{"address": "Eve@Example.org"}],
     "urls": [{"label": "LinkedIn", "url": "https://linkedin.com/in/eve"},
              {"label": "WhatsApp", "url": "whatsapp-lid:555"}]},
    # Claims Ana's @lid, which ContactsV2 already maps to a number: the
    # card's name wins, WhatsApp's number stays the handle.
    {"id": "ANA:ABPerson", "name": "Ana (card)", "phones": [{"number": "(555) 000-9999"}],
     "urls": [{"label": "WhatsApp", "url": "222@lid"}]},
    # A URL that only looks like an id claims nothing.
    {"id": "X:ABPerson", "name": "Not Bob", "urls": [{"label": "WhatsApp", "url": "whatsapp-lid:333x"}]},
]


def main():
    with tempfile.TemporaryDirectory() as folder:
        holder = build(folder)
        check("the WAL holds the newest message", os.path.getsize(
            os.path.join(folder, "ChatStorage.sqlite-wal")) > 0, True)
        # 🛑 WHATSAPP_CARDS stands in for the address book. Without it the
        # plugin runs `apple contacts list` against the user's real cards.
        cards = os.path.join(folder, "cards.json")
        with open(cards, "w") as f:
            json.dump(CARDS, f)
        env = dict(os.environ, WHATSAPP_FOLDER=folder, APPLE_PLUGINS_BIN="/usr/bin/false",
                   WHATSAPP_CARDS=cards, PYTHONDONTWRITEBYTECODE="1")

        manifest = json.loads(run(["manifest", "--json"], env).stdout)
        check("manifest name", manifest["name"], "whatsapp")
        check("manifest declares no hosts", manifest["network"], {"hosts": [], "writes": False})
        check("manifest kinds", manifest["index"]["kinds"], ["conversation", "call"])

        status = json.loads(run(["status", "--json"], env).stdout)
        check("status usable", (status["status"], status["usable"]), ("ok", True))
        check("status counts removed chats out", status["chats"], 4)
        check("status reads the address book", status["address_book"], 1)
        missing = dict(env, WHATSAPP_FOLDER=os.path.join(folder, "nope"))
        status = json.loads(run(["status", "--json"], missing).stdout)
        check("status --json exits 0 when missing", status["status"], "missing")
        run(["status"], missing, expect=1)

        chats = {c["id"]: c for c in json.loads(run(["chats", "--json"], env).stdout)}
        check("a removed chat is not listed", 5 in chats, False)
        check("group type and members", (chats[1]["type"], chats[1]["members"]), ("group", 3))
        check("bidi controls are stripped", chats[3]["title"], "+1 (940) 290‑7669")
        check("an unmapped @lid chat takes the number in its title", chats[3]["handle"], "+19402907669")
        check("the year-4000 sentinel is no date", chats[4]["last_message"], None)
        check("WhatsApp's own chat is not +0", chats[4]["handle"], "0@s.whatsapp.net")
        check("most recent first", list(chats)[:2], [1, 2])

        export = json.loads(run(["export", "School Board", "--json"], env).stdout)
        msgs = export["messages"]
        by = {m["guid"]: m for m in msgs}
        check("events are left out by default", "S4" in by, False)
        check("a card's name wins, WhatsApp's number stays the handle",
              (by["S1"]["handle"], by["S1"]["sender"]), ("+15550001111", "Ana (card)"))
        check("a card claims an unmapped @lid; its email is the handle",
              (by["S10"]["handle"], by["S10"]["sender"]), ("eve@example.org", "Eve Card"))
        check("an unmapped sender falls back to ~push name",
              (by["S3"]["handle"], by["S3"]["sender"]), (BOB_LID, "~Bobby"))
        check("my own message", (by["S2"]["handle"], by["S2"]["from_me"]), ("me", True))
        nocards = dict(env, WHATSAPP_CARDS=os.path.join(folder, "absent.json"))
        plain = run(["export", "School Board", "--json"], nocards)
        by_plain = {m["guid"]: m for m in json.loads(plain.stdout)["messages"]}
        check("without cards, ContactsV2's name", by_plain["S1"]["sender"], "Ana Garcia-Lopez")
        check("without cards, the raw id", by_plain["S10"]["handle"], EVE_LID)
        check("an unreadable address book is said, not fatal",
              "no card links" in plain.stderr, True)
        check("a caption from the media row", by["S3"]["text"], "[image] Budget slide from the training")
        check("an image's bogus latitude is not a location", "latitude" in by["S3"], False)
        check("a voice note carries its length", by["S5"]["text"], "[voice note 0:42]")
        check("a link carries its preview title", by["S6"]["text"],
              "See https://example.org/budget [link: District budget calendar]")
        with_events = json.loads(run(["export", "1", "--json", "--include-events"], env).stdout)
        check("--include-events adds the join", any(m["kind"] == "event" for m in with_events["messages"]), True)
        run(["export", "no such chat"], env, expect=66)
        ambiguous = run(["export", "a"], env, expect=64)
        check("an ambiguous chat names candidates", "matches" in ambiguous.stderr, True)
        check("a chat by phone number", json.loads(run(["export", "+1 555 000 2222", "--json"], env)
                                                  .stdout)["chat"]["id"], 2)

        check("the WAL-only message is read",
              [m["text"] for m in json.loads(run(["export", "2", "--json"], env).stdout)["messages"]],
              ["Lunch Friday?", "only in the write-ahead log"])

        hits = json.loads(run(["search", "board monday", "--json"], env).stdout)
        check("search is an AND of terms", [m["guid"] for m in hits], ["S1"])
        hits = json.loads(run(["search", '"monday board"', "--json"], env).stdout)
        check("quotes require adjacency", hits, [])
        hits = json.loads(run(["search", "budget", "--json"], env).stdout)
        check("search reads captions and link titles", sorted(m["guid"] for m in hits), ["S3", "S6"])
        hits = json.loads(run(["search", "filler", "--from-me", "--limit", "3", "--json"], env).stdout)
        check("--limit, newest first", [m["guid"] for m in hits], ["B10", "B9", "B8"])
        hits = json.loads(run(["search", "dan", "--since", "30", "--json"], env).stdout)
        check("--since cuts the old chat", hits, [])

        calls = json.loads(run(["calls", "--json"], env).stdout)
        check("calls newest first", [c["call_id"] for c in calls], ["C2", "C1"])
        check("a video call resolves its @lid participant",
              (calls[0]["video"], calls[0]["duration"], calls[0]["participants"][0]["name"]),
              (True, 125, "Ana (card)"))
        check("a missed call", (calls[1]["missed"], calls[1]["connected"], calls[1]["direction"]),
              (True, False, "incoming"))

        records = [json.loads(l) for l in run(["index"], env).stdout.splitlines() if l.strip()]
        for r in records:
            lacking = [f for f in RECORD_FIELDS if f not in r]
            if lacking:
                FAILED.append("record %s lacks %s" % (r.get("uid"), lacking))
            if not r["uid"].startswith("whatsapp:") or r["tool"] != "whatsapp":
                FAILED.append("record %s is not whatsapp's" % r["uid"])
            for key in ("created", "modified", "occurred", "latitude", "longitude"):
                if r[key] is not None and not isinstance(r[key], (int, float)):
                    FAILED.append("record %s %s is not a number" % (r["uid"], key))
        check("no uid repeats", len({r["uid"] for r in records}), len(records))
        group = [r for r in records if r["native_id"] == GROUP]
        check("fifteen group messages make two blocks", len(group), 2)
        check("blocks are cut from the start of the chat",
              group[0]["uid"], "whatsapp:chat:%s:S1" % GROUP)
        check("a bare placeholder is not indexed", "[image]\n" in group[0]["body"], False)
        check("a one-to-one chat links to WhatsApp",
              [r["url"] for r in records if r["native_id"] == CARL_WA], ["whatsapp://send?phone=15550002222"])
        check("people carry handles", {p["handle"] for p in group[0]["people"]},
              {"+15550001111", BOB_LID, "eve@example.org", "me"})
        check("calls are indexed", sorted(r["uid"] for r in records if r["kind"] == "call"),
              ["whatsapp:call:C1", "whatsapp:call:C2"])
        renamed = [json.loads(l) for l in run(["index"], nocards).stdout.splitlines() if l.strip()]
        check("a card link changes the block's rev",
              {r["uid"]: r["rev"] for r in records if r["native_id"] == GROUP} ==
              {r["uid"]: r["rev"] for r in renamed if r["native_id"] == GROUP}, False)
        recent = [json.loads(l) for l in run(["index", "--since", "30"], env).stdout.splitlines() if l]
        check("index --since drops the 40-day-old chat",
              any(r["native_id"] == DAVE_LID for r in recent), False)
        holder.close()

    if FAILED:
        print("FAIL whatsapp: %d" % len(FAILED))
        for f in FAILED:
            print("  - " + f)
        return 1
    print("ok   whatsapp plugin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
