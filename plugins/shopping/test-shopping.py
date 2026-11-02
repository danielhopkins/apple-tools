#!/usr/bin/env python3
"""Offline checks for apple-plugin-shopping.

Nothing here reads the real Milk for Us store or starts the app. The store
is built in a temp folder with the columns the plugin reads, in the shapes
measured on a real one: a list name with a trailing space and a curly
apostrophe, a product with no category, a product with two usage rows for
the same list, and an item that exists ONLY in the write-ahead log.

The milkforus-server backend runs against a fake WebDAV server on
127.0.0.1 that checks the Basic login, and `setup` runs through the real
manager with a temp config and a temp Keychain file.

The app backend's `sync` is not tested here: it starts a real app. It was
measured by hand, and the numbers are in docs/plugin-shopping.md.

    ./test-shopping.py
"""
import base64
import datetime as dt
import http.server
import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "apple-plugin-shopping")
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


def apple(days_ago):
    return time.time() - APPLE_EPOCH - days_ago * 86400


def build(folder):
    """Returns an open connection that holds the WAL open."""
    db = sqlite3.connect(os.path.join(folder, "db.sqlite"))
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
        CREATE TABLE ZSHOPPINGLIST (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZINCLUDEINAPPLICATIONBADGE INTEGER, ZSORTORDER INTEGER, ZCOLORSTRING VARCHAR,
            ZGHOSTDATA VARCHAR, ZNAME VARCHAR, ZSIMPERIUMKEY VARCHAR);
        CREATE TABLE ZSHOPPINGLISTITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZCHECKED INTEGER, ZPRODUCT INTEGER, ZSHOPPINGLIST INTEGER, ZGHOSTDATA VARCHAR,
            ZNOTE VARCHAR, ZSIMPERIUMKEY VARCHAR);
        CREATE TABLE ZPRODUCT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZCATEGORY INTEGER, ZGHOSTDATA VARCHAR, ZNAME VARCHAR, ZSIMPERIUMKEY VARCHAR);
        CREATE TABLE ZPRODUCTCATEGORY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZDEFAULTSORTORDER INTEGER, ZGHOSTDATA VARCHAR, ZGLOBALCATEGORYID VARCHAR,
            ZICONNAME VARCHAR, ZNAME VARCHAR, ZSIMPERIUMKEY VARCHAR, ZUNIQUEID VARCHAR);
        CREATE TABLE ZPRODUCTUSAGE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZTIMESUSED INTEGER, ZPRODUCT INTEGER, ZSHOPPINGLIST INTEGER, ZLASTUSED TIMESTAMP,
            ZGHOSTDATA VARCHAR, ZSIMPERIUMKEY VARCHAR);
    """)
    db.executemany("INSERT INTO ZSHOPPINGLIST (Z_PK, ZSORTORDER, ZCOLORSTRING, ZNAME, ZSIMPERIUMKEY) "
                   "VALUES (?,?,?,?,?)", [
                       (1, 0, "2ba22c", "Grocery", "912541b67db449fa8fc9697ce9b69ef7"),
                       (2, 6, "d82d23", "Trader Joe’s ", "52FB7109-0000-0000-0000-000000000002"),
                       (3, 8, None, "Costco", "F0CE08DC-0000-0000-0000-000000000003"),
                   ])
    db.executemany("INSERT INTO ZPRODUCTCATEGORY (Z_PK, ZDEFAULTSORTORDER, ZNAME) VALUES (?,?,?)",
                   [(1, 0, "Produce"), (2, 4, "Dairy"), (3, 12, "Frozen")])
    db.executemany("INSERT INTO ZPRODUCT (Z_PK, ZCATEGORY, ZNAME) VALUES (?,?,?)", [
        (1, 2, "Eggs"), (2, 1, "Avocados"), (3, 3, "Ice cream"),
        (4, None, "Boboli "),           # no category, and a trailing space
        (5, 2, "Sour cream"), (6, 1, "Bananas"),
    ])
    db.executemany("INSERT INTO ZSHOPPINGLISTITEM (Z_PK, ZCHECKED, ZPRODUCT, ZSHOPPINGLIST, "
                   "ZNOTE, ZSIMPERIUMKEY) VALUES (?,?,?,?,?,?)", [
                       (1, 0, 1, 1, None, "ITEM-EGGS"),
                       (2, 0, 4, 1, None, "ITEM-BOBOLI"),
                       (3, 1, 2, 1, None, "ITEM-AVOCADOS"),
                       (4, 0, 3, 2, "Milk and Cookies", "ITEM-ICECREAM"),
                       (5, 1, 5, 3, None, "ITEM-SOURCREAM"),
                   ])
    db.executemany("INSERT INTO ZPRODUCTUSAGE (Z_PK, ZTIMESUSED, ZPRODUCT, ZSHOPPINGLIST, "
                   "ZLASTUSED) VALUES (?,?,?,?,?)", [
                       (1, 191, 1, 1, apple(1)),
                       (2, 13, 4, 1, apple(3)),
                       (3, 161, 2, 1, apple(40)),
                       (4, 5, 3, 2, apple(2)),
                       (5, 14, 5, 3, apple(60)),
                       # The measured duplicate: a second usage row for the
                       # same product and list. The item must not appear twice.
                       (6, 2, 3, 2, apple(300)),
                   ])
    db.commit()
    # Checkpoint what is there, then write one item that lives only in the WAL.
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.execute("PRAGMA wal_autocheckpoint=0")
    db.execute("INSERT INTO ZSHOPPINGLISTITEM (Z_PK, ZCHECKED, ZPRODUCT, ZSHOPPINGLIST, "
               "ZSIMPERIUMKEY) VALUES (6, 0, 6, 1, 'ITEM-BANANAS')")
    db.execute("INSERT INTO ZPRODUCTUSAGE (Z_PK, ZTIMESUSED, ZPRODUCT, ZSHOPPINGLIST, ZLASTUSED) "
               "VALUES (7, 136, 6, 1, ?)", (apple(0.01),))
    db.commit()
    return db


def main():
    tmp = tempfile.mkdtemp(prefix="test-shopping-")
    folder = os.path.join(tmp, "group")
    engine = os.path.join(tmp, "engine")
    os.makedirs(folder)
    os.makedirs(engine)
    plist = os.path.join(engine, "store.plist")
    open(plist, "w").close()
    keep = build(folder)
    check("the WAL holds the newest item", os.path.getsize(os.path.join(folder, "db.sqlite-wal")) > 0, True)

    env = dict(os.environ)
    env.update({
        "SHOPPING_FOLDER": folder,
        "SHOPPING_MILKFORUS_ENGINE": engine,
        "SHOPPING_MILKFORUS_NO_APP": "1",
        # The manager is never asked: a test must not read the user's config.
        "APPLE_PLUGINS_BIN": "/usr/bin/false",
    })
    env.pop("SHOPPING_BACKEND", None)

    # manifest
    m = json.loads(run(["manifest", "--json"], env).stdout)
    check("manifest name", m["name"], "shopping")
    check("manifest kinds", m["index"]["kinds"], ["list"])
    check("manifest declares the app's host", m["network"]["hosts"], ["sync.milkforus.com"])
    check("manifest config keys", [c["key"] for c in m["config"]],
          ["backend", "folder", "webdav_url", "webdav_user", "webdav_password"])
    check("manifest: only the password is secret",
          [c["key"] for c in m["config"] if c["secret"]], ["webdav_password"])

    # status: fresh
    s = json.loads(run(["status", "--json"], env).stdout)
    check("status usable", (s["status"], s["usable"]), ("ok", True))
    check("status counts", (s["lists"], s["open_items"], s["checked_items"]), (3, 4, 2))
    check("status backend", s["backend"], "milkforus")
    check("status fresh", s["stale"], False)

    # status: stale. The sync check was two days ago.
    two_days = time.time() - 2 * 86400
    os.utime(plist, (two_days, two_days))
    s = json.loads(run(["status", "--json"], env).stdout)
    check("status stale", s["stale"], True)
    check("stale advice names sync", "apple shopping sync" in (s["advice"] or ""), True)
    p = run(["items"], env)
    check("a read warns on stderr when stale", "last synced 2 days ago" in p.stderr, True)
    os.utime(plist, None)
    p = run(["items"], env)
    check("no warning when fresh", p.stderr, "")

    # status: missing store, --json still exits 0
    missing = dict(env, SHOPPING_FOLDER=os.path.join(tmp, "nowhere"))
    s = json.loads(run(["status", "--json"], missing).stdout)
    check("status missing", (s["status"], s["usable"]), ("missing", False))
    run(["status"], missing, expect=1)

    # unknown backend
    p = run(["lists"], dict(env, SHOPPING_BACKEND="anylist"), expect=1)
    check("unknown backend is named", "unknown backend 'anylist'" in p.stderr, True)

    # lists
    lists = json.loads(run(["lists", "--json"], env).stdout)
    check("list names, trailing space gone", [l["name"] for l in lists],
          ["Grocery", "Trader Joe’s", "Costco"])
    check("list counts", [(l["open"], l["checked"]) for l in lists], [(3, 1), (1, 0), (0, 1)])
    check("list colour", lists[0]["color"], "#2ba22c")

    # items: open by default, the app's order, the WAL item included
    items = json.loads(run(["items", "--json"], env).stdout)
    check("open items in order", [(i["list"], i["name"]) for i in items], [
        ("Grocery", "Boboli"), ("Grocery", "Bananas"), ("Grocery", "Eggs"),
        ("Trader Joe’s", "Ice cream")])
    check("no category is null", items[0]["category"], None)
    check("note", items[3]["note"], "Milk and Cookies")
    check("times_added from usage", items[2]["times_added"], 191)
    check("last_added is ISO", items[2]["last_added"][:4].isdigit() and "T" in items[2]["last_added"], True)
    check("no internal fields", sorted(items[0]), sorted(
        ["id", "list", "list_id", "name", "note", "category", "checked", "last_added", "times_added"]))
    check("duplicate usage row does not duplicate the item",
          sum(1 for i in json.loads(run(["items", "--all", "--json"], env).stdout)
              if i["id"] == "ITEM-ICECREAM"), 1)

    # list matching: a straight apostrophe, any case, a prefix, an id
    for ref in ("trader joe's", "TRADER", "52FB7109-0000-0000-0000-000000000002"):
        got = json.loads(run(["items", ref, "--json"], env).stdout)
        check("list ref %r" % ref, [i["name"] for i in got], ["Ice cream"])
    p = run(["items", "Walmart"], env, expect=1)
    check("unknown list names the lists", "Grocery" in p.stderr, True)

    checked = json.loads(run(["items", "--checked", "--json"], env).stdout)
    check("--checked", sorted(i["name"] for i in checked), ["Avocados", "Sour cream"])
    got = json.loads(run(["items", "--all", "--search", "cream", "--json"], env).stdout)
    check("--search", sorted(i["name"] for i in got), ["Ice cream", "Sour cream"])

    # history
    h = json.loads(run(["history", "--since", "7", "--json"], env).stdout)
    check("history --since, newest first", [r["name"] for r in h],
          ["Bananas", "Eggs", "Ice cream", "Boboli"])
    h = json.loads(run(["history", "--most", "--limit", "2", "--json"], env).stdout)
    check("history --most", [r["name"] for r in h], ["Eggs", "Avocados"])
    h = json.loads(run(["history", "--list", "costco", "--json"], env).stdout)
    check("history --list", [r["name"] for r in h], ["Sour cream"])

    # index
    lines = run(["index", "--full"], env).stdout.splitlines()
    records = [json.loads(l) for l in lines]
    check("one record per list", len(records), 3)
    for r in records:
        check("record fields %s" % r["uid"], sorted(r), sorted(RECORD_FIELDS))
        check("uid prefix %s" % r["uid"], r["uid"].startswith("shopping:list:"), True)
        check("tool %s" % r["uid"], r["tool"], "shopping")
    grocery = records[0]
    check("body lists what to buy", grocery["body"].splitlines()[1],
          "To buy: Boboli, Bananas, Eggs")
    check("body lists what was checked off", grocery["body"].splitlines()[2],
          "Checked off: Avocados")
    check("title counts", grocery["title"], "Grocery shopping list (3 to buy)")
    check("occurred is a number", isinstance(grocery["occurred"], float), True)
    recent = [json.loads(l) for l in run(["index", "--since", "30"], env).stdout.splitlines()]
    check("index --since drops a list untouched for 60 days",
          [r["container"] for r in recent], ["Grocery", "Trader Joe’s"])

    # rev moves when an item is checked off
    keep.execute("UPDATE ZSHOPPINGLISTITEM SET ZCHECKED = 1 WHERE Z_PK = 1")
    keep.commit()
    after = json.loads(run(["index"], env).stdout.splitlines()[0])
    check("rev changes when an item is checked off", after["rev"] != grocery["rev"], True)
    keep.close()

    server_tests(tmp)

    if FAILED:
        print("FAIL test-shopping: %d" % len(FAILED))
        for f in FAILED:
            print("  - " + f)
        return 1
    print("ok   test-shopping")
    return 0


# --------------------------------------------------------------------------
# milkforus-server: a fake WebDAV server in the shapes measured on the real one
# --------------------------------------------------------------------------

USER, PASSWORD = "fakeuser", "s3cret-not-real"


class FakeDAV(http.server.BaseHTTPRequestHandler):
    files = {}          # "baselines" / "events" -> {name: bytes}
    log = []

    def log_message(self, *args):
        pass

    def _authorized(self):
        want = "Basic " + base64.b64encode(("%s:%s" % (USER, PASSWORD)).encode()).decode()
        if self.headers.get("Authorization") != want:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Milk for Us Sync"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        return True

    def _folder(self):
        parts = [p for p in urllib.parse.unquote(self.path).split("/") if p]
        # /fa/<user>/milkforus/<folder>[/<name>]
        return parts[3] if len(parts) > 3 else None, parts[4] if len(parts) > 4 else None

    def do_PROPFIND(self):
        FakeDAV.log.append(("PROPFIND", self.path))
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if not self._authorized():
            return
        folder, _ = self._folder()
        base = urllib.parse.unquote(self.path).rstrip("/")
        out = ['<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">',
               '<D:response><D:href>%s/</D:href><D:propstat><D:prop><D:resourcetype>'
               '<D:collection/></D:resourcetype></D:prop></D:propstat></D:response>' % base]
        for name, data in sorted(FakeDAV.files.get(folder, {}).items()):
            out.append('<D:response><D:href>%s/%s</D:href><D:propstat><D:prop>'
                       '<D:resourcetype/><D:getcontentlength>%d</D:getcontentlength>'
                       '</D:prop></D:propstat></D:response>' % (base, urllib.parse.quote(name), len(data)))
        out.append("</D:multistatus>")
        body = "".join(out).encode()
        self.send_response(207)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        FakeDAV.log.append(("GET", self.path))
        if not self._authorized():
            return
        folder, name = self._folder()
        data = FakeDAV.files.get(folder, {}).get(name)
        if data is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PUT(self):           # the plugin must never send one
        FakeDAV.log.append(("PUT", self.path))
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_DELETE = do_MKCOL = do_PUT


def attr(name, value=None):
    p = {"propertyName": name, "type": 0}
    if value is not None:
        p["value"] = value
    return p


def ref(name, gid):
    return {"propertyName": name, "relatedIdentifier": gid, "type": 1}


def ms(days_ago):
    return ["date", (time.time() - days_ago * 86400) * 1000.0]


def event(count, changes, kind=200):
    return json.dumps({"uniqueIdentifier": "E%d" % count, "type": kind, "globalCount": count,
                       "timestamp": time.time() - APPLE_EPOCH, "storeIdentifier": "PHONE",
                       "revisionsByStoreIdentifier": {}, "changesByEntity": changes}).encode()


def baseline_doc(count):
    return event(count, {
        "ShoppingList": [{"globalIdentifier": "L1", "type": 100, "properties": [
            attr("name", "Grocery"), attr("sortOrder", 0), attr("colorString", "2ba22c"),
            attr("simperiumKey", "L1"),
            {"propertyName": "items", "addedIdentifiers": ["I1"], "removedIdentifiers": [],
             "type": 2}]}],
        "ProductCategory": [{"globalIdentifier": "C1", "type": 100, "properties": [
            attr("name", "Dairy"), attr("defaultSortOrder", 4)]}],
        "Product": [{"globalIdentifier": "P1", "type": 100, "properties": [
            attr("name", "Eggs"), ref("category", "C1"), attr("simperiumKey", "P1")]},
            {"globalIdentifier": "P2", "type": 100, "properties": [
                attr("name", "Tea"), attr("simperiumKey", "P2")]}],
        "ShoppingListItem": [{"globalIdentifier": "I1", "type": 100, "properties": [
            attr("checked", 0), attr("note"), ref("product", "P1"), ref("shoppingList", "L1"),
            attr("simperiumKey", "I1")]}],
        "ProductUsage": [{"globalIdentifier": "U1", "type": 100, "properties": [
            attr("lastUsed", ms(3)), attr("timesUsed", 191), ref("product", "P1"),
            ref("shoppingList", "L1")]}],
    }, kind=100)


def serve():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeDAV)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def items_of(env):
    return [(i["name"], i["checked"], i["note"])
            for i in json.loads(run(["items", "--all", "--json"], env).stdout)]


def server_tests(tmp):
    server = serve()
    url = "http://127.0.0.1:%d/fa/%s" % (server.server_address[1], USER)
    FakeDAV.files = {"baselines": {"10_BASE_PHONE.cdeevent": baseline_doc(10)},
                     "events": {"9_OLD_PHONE_1.cdeevent": event(9, {})}}
    state = os.path.join(tmp, "server-state")
    env = dict(os.environ)
    env.update({
        "SHOPPING_BACKEND": "milkforus-server", "SHOPPING_FOLDER": state,
        "SHOPPING_WEBDAV_URL": url, "SHOPPING_WEBDAV_USER": USER,
        "SHOPPING_WEBDAV_PASSWORD": PASSWORD,
        "APPLE_PLUGINS_BIN": "/usr/bin/false",
        "SHOPPING_LAUNCH_AGENTS": os.path.join(tmp, "LaunchAgents"),
        "SHOPPING_LAUNCHCTL": "/usr/bin/true",
    })

    # before any pull
    s = json.loads(run(["status", "--json"], env).stdout)
    check("server: nothing pulled yet", (s["status"], s["usable"]), ("missing", False))
    check("server: index with no store prints nothing", run(["index"], env).stdout, "")

    # the first pull: the baseline only; an event older than it is skipped
    r = json.loads(run(["sync", "--json"], env).stdout)
    check("server: first pull", (r["synced"], r["changed"], r["downloaded"]), (True, True, 1))
    check("server: never sent a write", [m for m, _ in FakeDAV.log if m not in ("PROPFIND", "GET")], [])
    check("server: baseline items", items_of(env), [("Eggs", False, None)])
    got = json.loads(run(["items", "--json"], env).stdout)[0]
    check("server: same fields as the app backend", (got["list"], got["category"], got["times_added"]),
          ("Grocery", "Dairy", 191))
    check("server: a date from milliseconds", abs(
        dt.datetime.fromisoformat(got["last_added"]).timestamp() - (time.time() - 3 * 86400)) < 5, True)

    # a second pull with nothing new downloads nothing
    FakeDAV.log.clear()
    r = json.loads(run(["sync", "--json"], env).stdout)
    # Two requests, two PROPFINDs: the login went with the first request,
    # so no 401 challenge doubled them.
    check("server: quiet pull", (r["changed"], r["downloaded"], r["requests"]), (False, 0, 2))
    check("server: no challenge round trips", [m for m, _ in FakeDAV.log], ["PROPFIND", "PROPFIND"])

    # change sets: Tea added, Eggs checked off, then a late one with a LOWER
    # count than one already applied
    FakeDAV.files["events"]["12_X_PHONE_2.cdeevent"] = event(12, {
        "ShoppingListItem": [
            {"globalIdentifier": "I2", "type": 100, "properties": [
                attr("checked", 0), ref("product", "P2"), ref("shoppingList", "L1"),
                attr("note", "green")]},
            {"globalIdentifier": "I1", "type": 200, "properties": [attr("checked", 1)]}],
        "ProductUsage": [{"globalIdentifier": "U2", "type": 100, "properties": [
            attr("lastUsed", ms(0)), attr("timesUsed", 10), ref("product", "P2"),
            ref("shoppingList", "L1")]}]})
    run(["sync"], env)
    check("server: an insert and an update", items_of(env),
          [("Tea", False, "green"), ("Eggs", True, None)])
    FakeDAV.files["events"]["11_Y_MAC_1.cdeevent"] = event(11, {
        "ShoppingListItem": [{"globalIdentifier": "I2", "type": 200,
                              "properties": [attr("note", "black")]}]})
    run(["sync"], env)
    check("server: a late lower count does not win over a higher one", items_of(env),
          [("Tea", False, "green"), ("Eggs", True, None)])

    # a delete
    FakeDAV.files["events"]["13_Z_PHONE_3.cdeevent"] = event(13, {
        "ShoppingListItem": [{"globalIdentifier": "I1", "type": 300, "properties": []}]})
    run(["sync"], env)
    check("server: a delete", items_of(env), [("Tea", False, "green")])

    # a new baseline replaces the old one, and the change sets it covers go
    FakeDAV.files = {"baselines": {"13_NEWBASE_PHONE.cdeevent": event(13, {
        "ShoppingList": [{"globalIdentifier": "L1", "type": 100, "properties": [
            attr("name", "Grocery"), attr("sortOrder", 0)]}],
        "Product": [{"globalIdentifier": "P2", "type": 100, "properties": [attr("name", "Tea")]}],
        "ShoppingListItem": [{"globalIdentifier": "I2", "type": 100, "properties": [
            attr("checked", 1), ref("product", "P2"), ref("shoppingList", "L1")]}]}, kind=100)},
        "events": {}}
    r = json.loads(run(["sync", "--json"], env).stdout)
    check("server: new baseline", (r["baseline"], r["downloaded"], r["dropped"]),
          ("13_NEWBASE_PHONE.cdeevent", 1, 3))
    check("server: one baseline kept", os.listdir(os.path.join(state, "baseline")),
          ["13_NEWBASE_PHONE.cdeevent"])
    check("server: items from the new baseline", items_of(env), [("Tea", True, None)])

    # a refused login: exit 1, the store is kept, status says why
    bad = dict(env, SHOPPING_WEBDAV_PASSWORD="wrong")
    r = json.loads(run(["sync", "--json"], bad, expect=1).stdout)
    check("server: refused login", (r["synced"], "setup" in (r["error"] or "")), (False, True))
    s = json.loads(run(["status", "--json"], env).stdout)
    check("server: status reports the error", (s["status"], s["usable"]), ("error", False))
    check("server: the store survives a failed pull", items_of(env), [("Tea", True, None)])
    run(["sync"], env)
    s = json.loads(run(["status", "--json"], env).stdout)
    check("server: a good pull clears the error", (s["status"], s["last_error"]), ("ok", None))

    # stale after 15 minutes
    st = json.load(open(os.path.join(state, "state.json")))
    st["last_pull"] = time.time() - 3600
    json.dump(st, open(os.path.join(state, "state.json"), "w"))
    p = run(["items"], env)
    check("server: stale note", "last pull from the server was 60 minutes ago" in p.stderr, True)

    # the agent: refused while the plugin is not enabled; never pulls then
    p = run(["agent", "install"], env, expect=1)
    check("agent: refused when not enabled", "not enabled" in p.stderr, True)
    FakeDAV.log.clear()
    run(["sync", "--agent"], env)
    check("agent: a disabled plugin makes no request", FakeDAV.log, [])
    on = dict(env, SHOPPING_ASSUME_ENABLED="1")
    p = run(["agent", "install"], on)
    plist = os.path.join(tmp, "LaunchAgents", "com.boulderhopkins.apple-tools.shopping.plist")
    with open(plist, "rb") as handle:
        agent = plistlib.load(handle)
    check("agent: runs sync --agent with the system python",
          agent["ProgramArguments"][0::2], ["/usr/bin/python3", "sync"])
    check("agent: every two minutes", (agent["StartInterval"], agent["RunAtLoad"]), (120, True))
    run(["agent", "remove"], on)
    check("agent: removed", os.path.exists(plist), False)

    # 🛑 Under Homebrew the agent names opt/, not Cellar/<version>/, which
    # the next upgrade deletes.
    cellar = os.path.join(tmp, "brew", "Cellar", "apple-tools", "9.9.9", "libexec", "plugins", "shopping")
    os.makedirs(cellar)
    shutil.copy(PLUGIN, cellar)
    os.makedirs(os.path.join(tmp, "brew", "opt"))
    os.symlink("../Cellar/apple-tools/9.9.9", os.path.join(tmp, "brew", "opt", "apple-tools"))
    subprocess.run([os.path.join(cellar, "apple-plugin-shopping"), "agent", "install"],
                   capture_output=True, env=on, check=True)
    with open(plist, "rb") as handle:
        agent = plistlib.load(handle)
    check("agent: a Homebrew install runs the opt path, not the Cellar version",
          agent["ProgramArguments"][1],
          os.path.join(os.path.realpath(tmp), "brew", "opt", "apple-tools", "libexec", "plugins",
                       "shopping", "apple-plugin-shopping"))
    run(["agent", "remove"], on)

    server_setup_test(tmp, url)
    server.shutdown()


def server_setup_test(tmp, url):
    """setup reads the login from a cache shaped like the app's, stores it
    through the real manager into a temp config and a temp Keychain file,
    and never prints the password."""
    cache = os.path.join(tmp, "Cache.db")
    db = sqlite3.connect(cache)
    db.executescript("""
        CREATE TABLE cfurl_cache_response (entry_ID INTEGER PRIMARY KEY, request_key TEXT, time_stamp TEXT);
        CREATE TABLE cfurl_cache_receiver_data (entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
    """)
    db.execute("INSERT INTO cfurl_cache_response VALUES (1, "
               "'https://api.milkforus.com/v1/users/webdav_sync_authorization', '2026-11-02 16:00:00')")
    db.execute("INSERT INTO cfurl_cache_receiver_data VALUES (1, 0, ?)", (json.dumps(
        {"webdav_base_url": url, "webdav_username": USER, "webdav_password": PASSWORD}).encode(),))
    db.commit()
    db.close()
    root = os.path.dirname(os.path.dirname(HERE))
    config = os.path.join(tmp, "plugins.json")
    keychain = os.path.join(tmp, "keychain.json")
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("SHOPPING_"):
            del env[k]
    env.update({
        "SHOPPING_MILKFORUS_CACHE": cache,
        "SHOPPING_FOLDER": os.path.join(tmp, "setup-state"),
        "APPLE_PLUGINS_BIN": os.path.join(root, "bin", "apple-plugins"),
        "APPLE_PLUGINS_CONFIG": config,
        "APPLE_PLUGINS_KEYCHAIN_FILE": keychain,
        "APPLE_TOOLS_PLUGINS": os.path.dirname(HERE),
    })
    p = run(["setup"], env)
    check("setup: never prints the password", PASSWORD in p.stdout + p.stderr, False)
    check("setup: pulls after storing", "pulled in" in p.stdout, True)
    with open(config) as handle:
        stored = json.load(handle)["shopping"]
    check("setup: backend and login in the config",
          (stored.get("backend"), stored.get("webdav_user")), ("milkforus-server", USER))
    check("setup: the password is not in plugins.json", PASSWORD in json.dumps(stored), False)
    with open(keychain) as handle:
        check("setup: the password is in the Keychain", json.load(handle).get("shopping/webdav_password"),
              PASSWORD)
    check("setup: items read through the config", items_of(env), [("Tea", True, None)])


if __name__ == "__main__":
    sys.exit(main())
