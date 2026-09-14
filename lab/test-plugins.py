#!/usr/bin/env python3
"""Offline checks for how the index reads a plugin.

A plugin is somebody else's executable, run as a child, whose `index` output
becomes records. These checks build a throwaway index, stand up a FAKE plugin
manager (`APPLE_PLUGINS_BIN`) that reports one enabled plugin, and point that
plugin at a script under our control — so nothing here needs `apple`, a real
plugin, a network, or the user's plugins.json.

🛑 What this pins: an enabled plugin is a source with the same standing as
`maps`; a disabled or non-indexing one is not; a malformed record fails the
ingest LOUDLY instead of landing with NULLs; and the `places` report gives a
plugin its own column and never adds it to `visits`.

    ./test-plugins.py
"""
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "index.py")
FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


def write_exec(path, text):
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


GOOD_RECORDS = [
    {"uid": "fakeloc:place:1", "tool": "fakeloc", "kind": "place", "native_id": "1",
     "url": None, "title": "Costco", "container": "United States",
     "created": 1700000000.0, "modified": None, "occurred": None,
     "latitude": 39.95, "longitude": -105.17, "people": [],
     "body": "Costco\nSuperior, United States", "rev": "a"},
    {"uid": "fakeloc:visit:7", "tool": "fakeloc", "kind": "visit", "native_id": "7",
     "url": None, "title": "Costco", "container": "United States",
     "created": None, "modified": None, "occurred": 1788271200.0,
     "latitude": 39.95, "longitude": -105.17, "people": [],
     "body": "Costco\nstayed 1h 30m", "rev": "b"},
    {"uid": "fakeloc:visit:8", "tool": "fakeloc", "kind": "suggested", "native_id": "8",
     "url": None, "title": "Costco", "container": "United States",
     "created": None, "modified": None, "occurred": 1788357600.0,
     "latitude": 39.95, "longitude": -105.17, "people": [],
     "body": "Costco\nstayed 20m", "rev": "c"},
]

PLUGIN_SCRIPT = '''#!/usr/bin/env python3
import json, os, sys
mode = os.environ.get("FAKELOC_MODE", "good")
if sys.argv[1:2] == ["manifest"]:
    print(json.dumps({"name": "fakeloc", "version": "0", "index": {"kinds": ["place", "visit"],
                      "refresh_args": ["--since", "99"]}}))
    sys.exit(0)
if sys.argv[1:2] != ["index"]:
    sys.exit(64)
sys.stderr.write("fakeloc args: %s\\n" % " ".join(sys.argv[2:]))
records = json.load(open(os.environ["FAKELOC_RECORDS"]))
if mode == "missing-field":
    del records[1]["occurred"]
if mode == "wrong-tool":
    records[1]["tool"] = "maps"
if mode == "bad-number":
    records[1]["latitude"] = "39.95"
if mode == "not-json":
    print("{not json")
    sys.exit(0)
if mode == "crash":
    sys.stderr.write("server said no\\n")
    sys.exit(69)
for r in records:
    print(json.dumps(r))
'''

MANAGER_SCRIPT = '''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:] == ["enabled"]:
    rows = []
    if os.environ.get("FAKELOC_ENABLED", "1") == "1":
        rows.append({"name": "fakeloc", "path": os.environ["FAKELOC_PLUGIN"],
                     "manifest": json.loads(os.environ["FAKELOC_MANIFEST"])})
    print(json.dumps(rows))
    sys.exit(0)
sys.exit(64)
'''

with tempfile.TemporaryDirectory() as tmp:
    db = os.path.join(tmp, "index.db")
    plugin = os.path.join(tmp, "apple-plugin-fakeloc")
    manager = os.path.join(tmp, "apple-plugins")
    records_path = os.path.join(tmp, "records.json")
    write_exec(plugin, PLUGIN_SCRIPT)
    write_exec(manager, MANAGER_SCRIPT)
    with open(records_path, "w") as fh:
        json.dump(GOOD_RECORDS, fh)

    manifest = {"name": "fakeloc", "version": "0",
                "index": {"kinds": ["place", "visit"], "refresh_args": ["--since", "99"]}}
    BASE = dict(os.environ,
                APPLE_PLUGINS_BIN=manager, FAKELOC_PLUGIN=plugin,
                FAKELOC_RECORDS=records_path, FAKELOC_MANIFEST=json.dumps(manifest),
                APPLE_INDEX_DB=db)

    def run(args, env=None, ok=True):
        proc = subprocess.run([sys.executable, INDEX, "--db", db] + args,
                              capture_output=True, text=True, env=env or BASE)
        if ok and proc.returncode != 0:
            FAILED.append("%s exited %d\n%s" % (" ".join(args), proc.returncode, proc.stderr))
        return proc

    run(["init"])

    # sources: the plugin appears after the built-ins, with its own args
    src = json.loads(run(["sources"]).stdout)
    check("plugin is a source", "fakeloc" in src, True)
    check("plugin is listed last", list(src)[-1], "fakeloc")
    check("plugin refresh args come from its manifest", src["fakeloc"], ["--since", "99"])
    check("built-ins untouched", src["maps"], [])

    # a non-indexing manifest is not a source
    env = dict(BASE, FAKELOC_MANIFEST=json.dumps({"name": "fakeloc", "version": "0"}))
    src = json.loads(run(["sources"], env).stdout)
    check("a plugin without index kinds is not a source", "fakeloc" in src, False)
    # and neither is a disabled one
    src = json.loads(run(["sources"], dict(BASE, FAKELOC_ENABLED="0")).stdout)
    check("a disabled plugin is not a source", "fakeloc" in src, False)
    p = run(["ingest", "--source", "fakeloc", "--accept-risk"],
            dict(BASE, FAKELOC_ENABLED="0"), ok=False)
    check("ingesting a disabled plugin is an unknown source", "unknown source" in p.stderr, True)

    # ingest: three records land, --since reaches the plugin
    p = run(["ingest", "--source", "fakeloc", "--since", "42", "--accept-risk"])
    check("plugin got --since", "fakeloc args: --since 42" in p.stderr, True)
    con = sqlite3.connect(db)
    rows = con.execute("SELECT uid, kind, container, latitude FROM record "
                       "WHERE tool='fakeloc' ORDER BY uid").fetchall()
    check("records landed", rows, [
        ("fakeloc:place:1", "place", "United States", 39.95),
        ("fakeloc:visit:7", "visit", "United States", 39.95),
        ("fakeloc:visit:8", "suggested", "United States", 39.95)])
    chunks = con.execute("SELECT COUNT(*) FROM chunk c JOIN record r ON r.rid=c.rid "
                         "WHERE r.tool='fakeloc'").fetchone()[0]
    check("records were chunked", chunks > 0, True)
    con.close()

    # --limit stops the plugin early rather than reading it all
    p = run(["ingest", "--source", "fakeloc", "--limit", "1", "--accept-risk"])
    check("--limit is honoured", p.returncode, 0)

    # places: the plugin gets its own columns, never added to `visits`
    rep = json.loads(run(["places"]).stdout)
    costco = [s for s in rep["places"] if s["name"] == "Costco"]
    check("plugin place in the report", len(costco), 1)
    check("plugin visits in their own column", costco[0]["fakeloc_visits"], 1)
    check("suggested counted apart", costco[0]["fakeloc_suggested"], 1)
    check("maps visits untouched", costco[0]["visits"], 0)
    check("plugin container is read as a country", costco[0]["country"], "United States")
    check("from_<plugin> count", rep["counts"]["from_fakeloc"], 1)
    check("countries from the plugin", rep["countries"], [{"name": "United States", "places": 1}])

    # 🛑 A SUGGESTED VISIT NEVER ANCHORS A MERGE. Plant a photos place 100 m
    # from Costco with TWO days, and give Costco three suggested visits beside
    # its one confirmed one. Counting guesses, fakeloc weighs 3 and names the
    # merged row "Costco"; counting only what is confirmed, photos weighs 2
    # against 1 and its name survives. The first real dawarich ingest renamed
    # the user's home this way, after a house number.
    con = sqlite3.connect(db)
    con.execute("INSERT INTO record (uid, tool, kind, native_id, title, container, "
                "latitude, longitude, body, rev, seen_at, occurred) VALUES "
                "('photos:place:x','photos','place','x','Home','United States',"
                "39.9508,-105.17,'Home','r',1,1)")
    for day in ("a", "b"):
        con.execute("INSERT INTO record (uid, tool, kind, native_id, title, "
                    "latitude, longitude, body, rev, seen_at, occurred) VALUES "
                    "('photos:day:%s','photos','day','%s','Home',39.9508,-105.17,"
                    "'Home','r',1,1)" % (day, day))
    for guess in ("9", "10"):
        con.execute("INSERT INTO record (uid, tool, kind, native_id, title, "
                    "latitude, longitude, body, rev, seen_at, occurred) VALUES "
                    "('fakeloc:visit:%s','fakeloc','suggested','%s','Costco',39.95,-105.17,"
                    "'Costco','r',1,1)" % (guess, guess))
    con.commit(); con.close()
    rep = json.loads(run(["places"]).stdout)
    home = [s for s in rep["places"] if "photos" in s["sources"] and "fakeloc" in s["sources"]]
    check("merged across sources", len(home), 1)
    check("a guess never names a place", home[0]["name"], "Home")
    check("but every guess is still counted", home[0]["fakeloc_suggested"], 3)
    check("and the confirmed one too", home[0]["fakeloc_visits"], 1)

    # every malformed shape fails the ingest and names the problem
    for mode, needle in [("missing-field", "lacks occurred"),
                         ("wrong-tool", "claims tool 'maps'"),
                         ("bad-number", "latitude is not a number"),
                         ("not-json", "is not JSON"),
                         ("crash", "exited 69")]:
        p = run(["ingest", "--source", "fakeloc", "--accept-risk"],
                dict(BASE, FAKELOC_MODE=mode), ok=False)
        check("%s fails" % mode, p.returncode != 0, True)
        check("%s is named" % mode, needle in p.stderr, True)
        if mode == "crash":
            check("plugin stderr is relayed", "server said no" in p.stderr, True)

    # a plugin cannot shadow a built-in
    env = dict(BASE, FAKELOC_MANIFEST=json.dumps(dict(manifest, name="maps")))
    manager_shadow = os.path.join(tmp, "apple-plugins-shadow")
    write_exec(manager_shadow, MANAGER_SCRIPT.replace('"name": "fakeloc"', '"name": "maps"'))
    p = run(["sources"], dict(env, APPLE_PLUGINS_BIN=manager_shadow))
    check("shadowing a built-in is refused", "has the name of a built-in" in p.stderr, True)
    check("and maps keeps its own args", json.loads(p.stdout)["maps"], [])

    # an `apple` that does not know `plugins` reads as no plugins, not a crash
    p = run(["sources"], dict(os.environ, APPLE_PLUGINS_BIN="/usr/bin/false"))
    check("old manager means no plugins", p.returncode, 0)
    check("old manager keeps built-ins", "maps" in json.loads(p.stdout), True)

if FAILED:
    print("FAILED %d:" % len(FAILED))
    for f in FAILED:
        print("  -", f)
    sys.exit(1)
print("ok")
