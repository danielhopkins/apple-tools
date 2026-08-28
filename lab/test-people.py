#!/usr/bin/env python3
"""Offline checks for the `people` command's identity rules.

🛑 THESE ARE THE RULES THAT CAN DELETE A PERSON, and none of them can be
checked by looking at the output: a merge that did not happen looks exactly
like two people, and a merge that should not have happened looks exactly like
one. So each one is pinned here against a fixture rather than against the
store.

No index, no Contacts, no network. Run it directly:

    ./test-people.py
"""
import sys

import index

FAILED = []


def blank_spans():
    """The per-channel span fields, empty. One place, so the next field added
    to the collector does not break four fixtures in two files."""
    return {"channel_first": {}, "channel_last": {},
            "channel_spoke_days": {}, "channel_spoke_last": {},
            "spoke_days": set()}


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


# --------------------------------------------------------------------------
# handles
# --------------------------------------------------------------------------

check("author handle splits into name and address",
      index.handle_key('Ada Lovelace <ada@example.com>'),
      ("ada@example.com", "Ada Lovelace"))
check("a bare address carries no name",
      index.handle_key("ada@example.com"), ("ada@example.com", ""))
check("a phone number reduces to ten digits",
      index.handle_key("+1 (303) 555-0123")[0], "3035550123")
check("a short code is kept whole",
      index.handle_key("75137")[0], "75137")
# 🛑 `To:` headers really carry this, and it became a person written to 200 times.
check("undisclosed-recipients is not a handle",
      index.handle_key("undisclosed-recipients:;"), ("", ""))
check("a percent-encoded name is decoded",
      index.handle_key("Matt%20%26%20Jennifer <m@example.com>")[1],
      "Matt & Jennifer")


# --------------------------------------------------------------------------
# what names a card answers to
# --------------------------------------------------------------------------

STEPH = {"id": "card-1", "name": "Stephanie Hopkins", "first_name": "Stephanie",
         "nickname": "Steph", "last_name": "Hopkins",
         "previous_family_name": "Anderson"}

check("a card answers to all four crossings of its names",
      index.card_names(STEPH),
      {"Stephanie Hopkins", "Stephanie Anderson",
       "Steph Hopkins", "Steph Anderson"})
check("a card with no previous name or nickname answers to one name",
      index.card_names({"id": "c", "name": "Dan Horne",
                        "first_name": "Dan", "last_name": "Horne"}),
      {"Dan Horne"})


# --------------------------------------------------------------------------
# merging an address with no card into the card that claims its name
# --------------------------------------------------------------------------

def person(pid, name, known, days, first=None, last=None, handles=None,
           channels=None, months=None, same_list=0):
    """One person, in the shape `cmd_people` builds them.

    ⚠️ `days` is a SET here, as it is in the command. It is a count only in
    the JSON at the very end.
    """
    days = set(days) if not isinstance(days, int) else {
        "2020-01-%02d" % (i % 28 + 1) for i in range(days)}
    return {"id": pid, "name": name, "known": known, "days": days,
            "channel_days": {"mail": set(days)},
            # ⚠️ THE COST OF A HAND-ROLLED FIXTURE, paid again. Adding
            # channel_first/last and the spoke fields to the collector broke
            # every builder in both suites at once, because each one restates
            # cmd_people's internal record from memory. `blank_spans()` is one
            # place to add the next field.
            **blank_spans(), "same_list": same_list,
            "alone": {}, "upcoming": 0, "rids": [],
            "mail_from": 0, "mail_to": 0, "mail_bulk": 0, "mail_seen": 0,
            "handles": set(handles or [pid]), "channels": dict(channels or {}),
            "first": first, "last": last,
            "months": {m: set(d) for m, d in (months or {}).items()},
            "names": {name: 1}}


def merge(entries, aliases):
    people = {e["id"]: e for e in entries}
    moved = index.merge_by_name(people, aliases)
    return people, moved


# 🛑 THE CASE THIS EXISTS FOR. Mail from 2006 to 2012 signed "Steph Anderson";
# the card now reads "Stephanie Hopkins". Nothing about the address matches.
people, moved = merge(
    [person("card-1", "Stephanie Hopkins", True, {"2020-01-01", "2020-01-02"},
            first=100, last=900, channels={"mail": 8491}),
     person("handle:old@x", "Steph Anderson", False, {"2020-01-02", "2006-10-06"},
            first=10, last=200, channels={"mail": 568})],
    {"card-1": index.card_names(STEPH)})
check("the previous family name folds the old address into the card",
      sorted(people), ["card-1"])
# 🛑 A UNION, NOT A SUM. Both rows hold 2020-01-02, and adding the counts
# would report that day twice — 4 days for a person who had 3.
check("...and a day both rows hold is counted once",
      len(people["card-1"]["days"]), 3)
check("...and the item counts do add up",
      people["card-1"]["channels"]["mail"], 9059)
check("...and the earlier first contact wins", people["card-1"]["first"], 10)
check("...and the later last contact wins", people["card-1"]["last"], 900)
check("...and the old handle is kept",
      "handle:old@x" in people["card-1"]["handles"], True)
check("...and the caller is told where the edges moved",
      moved, {"handle:old@x": "card-1"})

# 🛑 A DIRECTORY WRITES THE NAME BACKWARDS. 208 pairs on this store.
people, _ = merge(
    [person("card-1", "Robin Leopold", True, {"2020-01-01"}),
     person("handle:r@x", "Leopold, Robin", False, {"2021-01-01"})],
    {"card-1": {"Robin Leopold"}})
check("surname-first folds into the card", sorted(people), ["card-1"])
# ⚠️ SAFE ONLY BECAUSE A CARD MUST CLAIM IT. Seven companies here sign
# themselves "Support"; sorting words makes them all agree and none has a card.
people, _ = merge(
    [person("handle:a@x", "Support", False, {"2020-01-01"}),
     person("handle:b@y", "Support", False, {"2020-01-02"}),
     person("handle:c@z", "support .", False, {"2020-01-03"})],
    {})
check("no card means no merge, however alike the names", len(people), 3)

# ⚠️ Two people really can share a name, and merging the wrong pair is worse
# than drawing two circles.
people, _ = merge(
    [person("card-1", "Chris Lee", True, 100),
     person("card-2", "Chris Lee", True, 90),
     person("handle:c@x", "Chris Lee", False, 30)],
    {"card-1": {"Chris Lee"}, "card-2": {"Chris Lee"}})
check("a name two cards answer to merges nothing", len(people), 3)

# A card that claims one name under two spellings is still one card.
people, _ = merge(
    [person("card-1", "Jo Ray", True, 100),
     person("handle:j@x", "Jo Ray", False, 30)],
    {"card-1": {"Jo Ray", "Jo  Ray", "jo ray"}})
check("one card claiming a name several ways still merges", sorted(people), ["card-1"])

# The rule never touches somebody who has their own card.
people, _ = merge(
    [person("card-1", "Sam Vale", True, 100),
     person("card-2", "Sam Vale", True, 30)],
    {"card-1": {"Sam Vale"}, "card-2": {"Sam Vale"}})
check("a person with their own card is never absorbed", len(people), 2)


# --------------------------------------------------------------------------
# talking to someone, versus being on a list with them
# --------------------------------------------------------------------------

MINE = {"me@example.com", "me"}

# 🛑 THE BUG THIS EXISTS FOR. Asking whether the author was "one of the other
# people on the record" is true of almost every email, so every one counted as
# direct and the whole correction did nothing. Nothing in the output said so.
check("a third party writing to us both is not talking",
      index.is_direct("mail", "list@example.com", "her@example.com", 4, MINE),
      False)
check("mail I wrote counts",
      index.is_direct("mail", "me@example.com", "her@example.com", 4, MINE), True)
check("mail she wrote counts",
      index.is_direct("mail", "her@example.com", "her@example.com", 4, MINE), True)
check("...but not for the other people copied on it",
      index.is_direct("mail", "her@example.com", "him@example.com", 4, MINE), False)
# A mass mail is a list even when the user sent it.
check("a mail to more people than a conversation holds is a list",
      index.is_direct("mail", "me@example.com", "her@example.com", 40, MINE), False)
# An invitation is shared by definition, however many are on it.
check("an event always counts, however big",
      index.is_direct("calendar", "list@example.com", "her@example.com", 97, MINE),
      True)


# --------------------------------------------------------------------------
# one person, several addresses, no card
# --------------------------------------------------------------------------

def namesakes(entries):
    people = {e["id"]: e for e in entries}
    moved = index.merge_namesakes(people)
    return people, moved

# 🛑 `John Giffin` appears five times here, `Xin Zheng` three, `Staci Ruddy`
# three — work, personal, a role address at the same charity, and the one at
# the employer they left. None has a card, so `merge_by_name` cannot help.
people, moved = namesakes([
    person("handle:a@x", "John Giffin", False, {"2020-01-01", "2020-01-02"}),
    person("handle:b@y", "Giffin, John", False, {"2021-01-01"}),
    person("handle:c@z", "John Giffin", False, {"2022-01-01"})])
check("addresses sharing a full name fold together", len(people), 1)
check("...into the one with the most days", sorted(people), ["handle:a@x"])
check("...and the caller is told where the others went", len(moved), 2)

# ⚠️ TWO WORDS AT LEAST. Seven companies here sign themselves "Support".
people, _ = namesakes([
    person("handle:a@x", "Support", False, {"2020-01-01"}),
    person("handle:b@y", "Support", False, {"2020-01-02"})])
check("a single word is not a name", len(people), 2)

# A card is never absorbed by this rule; `merge_by_name` owns that direction.
people, _ = namesakes([
    person("card-1", "Ada Lovelace", True, {"2020-01-01"}),
    person("card-2", "Ada Lovelace", True, {"2020-01-02"})])
check("two cards with one name are left alone", len(people), 2)


# --------------------------------------------------------------------------
# mailing lists and robots
# --------------------------------------------------------------------------

def spellings(known, names, handle="a@example.com", company=False):
    return {"known": known, "names": names, "handle": handle,
            "card_is_company": company, "name": next(iter(names), ""),
            "channels": {"mail": 1}, "mail_from": 1, "mail_to": 1,
            "mail_bulk": 0, "mail_seen": 1}


check("a robot writing under many names is a list",
      index.not_a_person(spellings(False, {
          "Jon Raphaelson": 119, "Charlie Vo": 118, "Jeff Simpson": 104,
          "Ada Byron": 90, "Kit Marlow": 80, "Ann Frank": 70})),
      "list")
# 🛑 A twenty-year correspondent signs three ways and the commonest dominates.
check("a person with several spellings is not a list",
      index.not_a_person(spellings(False, {
          "Cat Cantor": 385, "musicalhands": 127, "cat": 2})),
      None)
check("a card is never a list, however it signs itself",
      index.not_a_person(spellings(True, {"A": 1, "B": 1, "C": 1,
                                          "D": 1, "E": 1, "F": 1})),
      None)

# --------------------------------------------------------------------------
# transactional mail, decided by reciprocity
# --------------------------------------------------------------------------

def sender(handle, name, frm, to, bulk=0, seen=None, channels=None):
    return {"known": False, "names": {name: 1}, "handle": handle, "name": name,
            "card_is_company": False, "channels": channels or {"mail": frm + to},
            "mail_from": frm, "mail_to": to, "mail_bulk": bulk,
            "mail_seen": seen if seen is not None else frm}

MINE_ADDR2 = {"me@example.com"}

# 🛑 THE ONE RULE THAT READS THE RELATIONSHIP. Every other rule reads the
# address or the card, so a sender with a friendly From line and a personal
# address slips through. "NORTHWESTERN MUTUAL", "Boulder Reporting Lab" and
# "Sharon Halkovics" all did.
check("40 emails and never one reply is transactional",
      index.not_a_person(sender("id@proxyvote.com", "Northwestern Mutual", 135, 0),
                         {}, MINE_ADDR2),
      "never-answered")
# ⚠️ ONE REPLY IS ENOUGH TO SPARE THEM, and that is deliberate. Measured: every
# real correspondent in the top sixty had written back at least twice.
check("one reply spares them, however lopsided",
      index.not_a_person(sender("eagle1@4dv.net", "Dean Mathena", 178, 2),
                         {}, MINE_ADDR2),
      None)
# ⚠️ A text or a call is two-way by nature, so a handle with either is never
# judged this way.
check("somebody who also texts is never judged on mail alone",
      index.not_a_person(sender("a@b.com", "Ada", 90, 0,
                                channels={"mail": 90, "messages": 4}),
                         {}, MINE_ADDR2),
      None)
check("...and neither is somebody who calls",
      index.not_a_person(sender("a@b.com", "Ada", 90, 0,
                                channels={"mail": 90, "phone": 1}),
                         {}, MINE_ADDR2),
      None)

# 🛑 BELOW FORTY, VOLUME IS NOT ENOUGH. Two of the school's teachers wrote 16
# and 19 times and were never answered. They are people.
check("a quiet sender with no newsletter footer is left alone",
      index.not_a_person(sender("nancy.s@tep.school.org", "Nancy Salto", 16, 0),
                         {}, MINE_ADDR2),
      None)
check("a newsletter footer on half of them is the second reason",
      index.not_a_person(sender("members@mail.livestrong.com", "LIVESTRONG.COM",
                                14, 0, bulk=14), {}, MINE_ADDR2),
      "bulk-mail")
# 🛑 AND THE GUARD: their own name in the address means a person.
check("...unless the address carries their own name",
      index.not_a_person(sender("nancy.s@tep.school.org", "Nancy Salto",
                                16, 0, bulk=16), {}, MINE_ADDR2),
      None)

# The name guard on its own.
check("a name token the domain does not have means a person",
      index.carries_own_name("nancy.s@tep.boulderjourneyschool.com", "Nancy Salto"),
      True)
# 🛑 A brand writes from its own name, and the DOMAIN gives it away.
check("a name token the domain also has is a brand",
      index.carries_own_name("chase@emailinfo.chase.com", "Chase Card Services"),
      False)
# ⚠️ "ent" is a substring of "estatements".
check("three characters are not a name",
      index.carries_own_name("estatements@email.ent.com", "Ent Credit Union"), False)
check("an address used as its own display name is not a person",
      index.carries_own_name("orders@dominos.com", "orders@dominos.com"), False)
check("a role address is not their name",
      index.carries_own_name("communications@copta.org", "Kate Herdejurgen"), False)


# --------------------------------------------------------------------------
# businesses
# --------------------------------------------------------------------------

check("a card marked as a company is not a person",
      index.not_a_person(spellings(True, {"Venmo": 90}, company=True)), "company")
check("Contacts' own checkbox is enough",
      index.is_company_card({"name": "Chase", "is_company": True}), True)
# ⚠️ The checkbox is often left off. A card naming an organisation and no
# person is a business whatever it says.
check("a company name with no person on the card is a company",
      index.is_company_card({"name": "State Farm", "company": "State Farm"}), True)
check("...but a person who has an employer is not",
      index.is_company_card({"name": "Joni Klippert", "first_name": "Joni",
                             "last_name": "Klippert", "company": "StackHawk"}),
      False)
# 🛑 A five or six digit number is an SMS short code. It cannot be a person.
check("an SMS short code is not a person",
      index.not_a_person(spellings(True, {"Venmo": 9}, handle="86753")),
      "short-code")
check("a real phone number still is",
      index.not_a_person(spellings(True, {"Ada": 9}, handle="3035550123")), None)
check("an address a machine writes from is not a person",
      index.not_a_person(spellings(False, {"Apple": 9},
                                   handle="no_reply@email.apple.com")),
      "no-reply")
check("...and so is auto-confirm",
      index.not_a_person(spellings(False, {"Amazon": 9},
                                   handle="auto-confirm@amazon.com")),
      "no-reply")
# ⚠️ DELIBERATELY NOT CAUGHT. A small charity's office address really is
# answered by one person, and two in this store are.
# 🛑 VERP PUTS THE RECIPIENT IN THE SENDER, so a bounce carries the user's own
# address and reads as a person with their own name.
MINE_ADDR = {"danielhopkins@gmail.com", "dan@boulderhopkins.com"}
check("a bounce path carrying my address is not a person",
      index.is_bounce_path(
          "bounces+3371362-2618-danielhopkins=gmail.com@mailer.example.com",
          MINE_ADDR),
      True)
check("an ordinary address is not a bounce path",
      index.is_bounce_path("ada@example.com", MINE_ADDR), False)
# ⚠️ It must not fire on somebody who merely shares a word with the address.
check("a lookalike is not a bounce path",
      index.is_bounce_path("danielhopkins@example.com", MINE_ADDR), False)

# 🛑 THE FORMAL NAME IS NOT ON THE CARD. "Dan Hopkins" on the card, seven old
# addresses signing themselves "Daniel Hopkins".
ME_PARTS = {("dan", "hopkins")}
check("the formal version of my own name is me",
      index.is_me_by_name("Daniel Hopkins", {"dan hopkins"}, ME_PARTS), True)
check("my own name exactly is me",
      index.is_me_by_name("Dan Hopkins", {"dan hopkins"}, ME_PARTS), True)
check("a relative with a different given name is not",
      index.is_me_by_name("Reid Hopkins", {"dan hopkins"}, ME_PARTS), False)
check("a different family name is not, whatever the given name",
      index.is_me_by_name("Daniel Horne", {"dan hopkins"}, ME_PARTS), False)
# ⚠️ An initial must not claim a stranger.
check("two characters are not a stem",
      index.is_me_by_name("Da Hopkins", {"dan hopkins"}, {("da", "hopkins")}),
      False)

# 🛑 THE USER'S OWN ANSWER WINS OVER EVERY RULE, in both directions.
check("a handle the user called a business is out",
      index.not_a_person(spellings(True, {"Mint": 9}, handle="team@mint.com"),
                         {"team@mint.com": "business"}, MINE_ADDR),
      "marked")
# ⚠️ This direction matters more: a business left in is visible, and a person
# taken out is not.
check("a handle the user called a person is rescued from every rule",
      index.not_a_person(spellings(False, {"Ada": 9}, handle="alerts@example.com"),
                         {"alerts@example.com": "person"}),
      None)
check("...even from the company tick box",
      index.not_a_person(spellings(True, {"Ada": 9}, handle="a@b.com", company=True),
                         {"a@b.com": "person"}),
      None)
check("no ruling changes nothing",
      index.not_a_person(spellings(False, {"Ada": 9}, handle="ada@gmail.com"), {}),
      None)

check("a Google Calendar placeholder is not a guest",
      index.not_a_person(spellings(False, {"Unknown Organizer": 9},
                                   handle="unknownorganizer@calendar.google.com")),
      "calendar-feed")
check("a subscribed calendar is not a guest",
      index.not_a_person(spellings(False, {"BVSD DAC": 9},
                                   handle="abc123@group.calendar.google.com")),
      "calendar-feed")
check("an ordinary gmail address is untouched by that rule",
      index.not_a_person(spellings(False, {"Ada": 9}, handle="ada@gmail.com")), None)
check("an office address is left alone",
      index.not_a_person(spellings(False, {"Tracy Reilly": 9},
                                   handle="office@copta.org")), None)
check("...and so is info@",
      index.not_a_person(spellings(False, {"Beth": 9},
                                   handle="info@dcmhoa.com")), None)


# --------------------------------------------------------------------------
# the stored report
# --------------------------------------------------------------------------

import sqlite3
import time

cache = sqlite3.connect(":memory:")
cache.row_factory = sqlite3.Row
cache.executescript("""CREATE TABLE people_cache (
  one INTEGER PRIMARY KEY CHECK (one = 1),
  computed_at REAL NOT NULL, payload TEXT NOT NULL);""")

check("no stored report reads as nothing",
      index.read_people_cache(cache, 3600), None)

index.write_people_cache(cache, {"generated": time.time(), "people": [1, 2]})
fresh = index.read_people_cache(cache, 3600)
check("a stored report comes back", fresh["people"], [1, 2])
# 🛑 A reader that cannot tell a stored answer from a fresh one cannot tell a
# stale one either.
check("...and says it came from the cache", fresh["cached"], True)
check("...and says when it was made", isinstance(fresh["computed"], float), True)

# ⚠️ TOO OLD IS THE SAME AS ABSENT. Serving an expired report would make the
# daily refresh look like it worked and never run.
index.write_people_cache(cache, {"generated": time.time() - 90000})
check("a report older than the limit is refused",
      index.read_people_cache(cache, 24 * 3600), None)
check("...but any age is allowed when no limit is given",
      index.read_people_cache(cache, None) is not None, True)

# ⚠️ A second write replaces the first rather than failing on the primary key.
index.write_people_cache(cache, {"generated": time.time(), "people": [3]})
check("writing again replaces the stored report",
      index.read_people_cache(cache, 3600)["people"], [3])
check("...and leaves exactly one row",
      cache.execute("SELECT COUNT(*) c FROM people_cache").fetchone()["c"], 1)

# An index predating the table must read as "no report", not raise.
bare = sqlite3.connect(":memory:")
bare.row_factory = sqlite3.Row
check("an index with no such table reads as nothing",
      index.read_people_cache(bare, 3600), None)


# --------------------------------------------------------------------------
# emoji
# --------------------------------------------------------------------------

check("a flag is one emoji, not two letters", index.emoji_in("🇺🇸"), ["🇺🇸"])
check("a family is one emoji, not four people",
      index.emoji_in("👨‍👩‍👧‍👦"), ["👨‍👩‍👧‍👦"])
check("a skin tone rides with its emoji", index.emoji_in("👍🏽"), ["👍🏽"])
check("a heart keeps its variation selector", index.emoji_in("❤️"), ["❤️"])
# 🛑 Both of these ranked as top emoji before the presentation test existed.
# They come off mail signatures and newsletters, and neither is an emoji.
check("a dingbat with no emoji presentation is not an emoji",
      index.emoji_in("✓ ♦ ™ © 5"), [])
check("emoji are found among words",
      index.emoji_in("ha 😂 ok 🤣!"), ["😂", "🤣"])


# --------------------------------------------------------------------------
# per-channel spans, and the difference between calling and talking
# --------------------------------------------------------------------------

# 🛑 `last` IS THE MAXIMUM ACROSS EVERY CHANNEL, which answers a question
# nobody asked. "When did I last talk to my mother" returned 2026-08-25 — the
# day she sent a text. The last call they were both on was twelve days earlier,
# and the last call of any kind was a missed one in between. Three readings of
# one question, and the report gave the one that was easiest to compute.
#
# 🛑 A MISSED CALL IS NOT TALKING, and it is not a rounding error: 183 of 372
# calls on this store never connected — 49% — and 7 of the 11 with that one
# person. `days` still counts them, deliberately: somebody reaching for you is
# contact. The connected count sits beside it rather than replacing it.

def spanned(pid, channel, first, last, spoke_last=None, days=1, spoke=()):
    entry = person(pid, "A", True, days)
    entry["channel_first"] = {channel: first}
    entry["channel_last"] = {channel: last}
    # ⚠️ SETS OF DAY STRINGS, not counts. `absorb` runs while the collector
    # still holds days as sets; the conversion to integers happens once, at the
    # very end. Passing counts here made the fixture lie about the merge.
    entry["channel_spoke_days"] = {channel: set(spoke)} if spoke else {}
    entry["channel_spoke_last"] = {channel: spoke_last} if spoke_last else {}
    return entry


# ⚠️ ABSORB TAKES MIN AND MAX, never the second row's value. Folding an old
# address into a card must WIDEN that channel's span; overwriting it would
# report a twenty-year correspondence as starting whenever the fold happened.
_t = spanned("card", "mail", 200, 300)
index.absorb(_t, spanned("old", "mail", 100, 250))
check("absorbing widens the channel's first backwards",
      _t["channel_first"]["mail"], 100)
check("...and does not shrink its last", _t["channel_last"]["mail"], 300)

_t = spanned("card", "mail", 200, 300)
index.absorb(_t, spanned("old", "mail", 250, 400))
check("absorbing extends the channel's last forwards",
      _t["channel_last"]["mail"], 400)
check("...and does not move its first", _t["channel_first"]["mail"], 200)

_t = spanned("card", "mail", 200, 300)
index.absorb(_t, spanned("old", "phone", 50, 60))
check("a channel only the other row had is carried over",
      sorted(_t["channel_last"]), ["mail", "phone"])

# ⚠️ THE CONNECTED VARIANT MERGES THE SAME WAY, and separately.
_t = spanned("card", "phone", 200, 300, spoke_last=250, spoke={"2026-01-01"})
index.absorb(_t, spanned("old", "phone", 100, 280, spoke_last=270,
                         spoke={"2026-01-02", "2026-01-03"}))
check("the last CONNECTED call takes the max too",
      _t["channel_spoke_last"]["phone"], 270)
check("...and stays behind the last attempt",
      _t["channel_spoke_last"]["phone"] < _t["channel_last"]["phone"], True)
check("distinct connected days accumulate across the fold",
      len(_t["channel_spoke_days"]["phone"]), 3)

# 🛑 A UNION, NOT A SUM — the same rule `days` already follows. Both rows can
# hold the SAME day, and adding the counts would report one call twice.
_t = spanned("card", "phone", 200, 300, spoke={"2026-01-01", "2026-01-02"})
index.absorb(_t, spanned("old", "phone", 100, 280, spoke={"2026-01-02"}))
check("a day both rows hold is counted once",
      len(_t["channel_spoke_days"]["phone"]), 2)

# ⚠️ ABSENT, NOT ZERO. A person with no connected call has no entry rather than
# a 0 — the shape every optional key in this report uses, so "we never got
# through" and "there were no calls" stay distinct.
_t = spanned("card", "phone", 200, 300)
check("a channel that never connected reports no spoke entry",
      _t["channel_spoke_last"], {})

# 🛑 A SLIDING WINDOW HAS NO FIRST DATE, and phone is the only channel that is
# one. CallHistory on a Mac is a relay mirror of the iPhone: 372 calls over 141
# days here, against years on the phone. The oldest call visible is the edge of
# the mirror, not the first time two people spoke.
#
# ⚠️ Measured before this rule existed: 11 of 137 people with a phone
# first-date sat within a fortnight of that edge, a spouse of twenty years
# landed exactly ON it, and 109 people have no other channel at all. It also
# degrades silently — as the mirror slides the date walks forward and nothing
# says it moved.
check("phone is the only windowed channel", index.WINDOWED_CHANNELS, {"phone"})
for _ch in ("mail", "messages", "photos", "calendar"):
    check("%s reaches the true start of its own store" % _ch,
          _ch in index.WINDOWED_CHANNELS, False)


if FAILED:
    print("%d failed\n" % len(FAILED))
    for line in FAILED:
        print("  ✗ " + line)
    sys.exit(1)
print("people: all checks passed")
