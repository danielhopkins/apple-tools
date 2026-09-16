#!/usr/bin/env python3
"""Offline checks for apple-plugin-dawarich and the plugin manager.

Nothing here touches the network, plugins.json, or the Keychain. A fake
Dawarich answers on 127.0.0.1 with the shapes taken from the server's own
serializers (Api::VisitSerializer, Api::PlaceSerializer, Api::PointSerializer),
the manager is pointed at a temp config and a temp "keychain" file, and the
plugin is run as a subprocess the way `apple` runs it.

    ./test-dawarich.py
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PLUGIN = os.path.join(HERE, "apple-plugin-dawarich")
MANAGER = os.path.join(ROOT, "bin", "apple-plugins")
APPLE = os.path.join(ROOT, "bin", "apple")
KEY = "test-key-123"

FAILED = []


def check(name, got, want):
    if got != want:
        FAILED.append("%s\n     got  %r\n     want %r" % (name, got, want))


# --------------------------------------------------------------------------
# a fake Dawarich
# --------------------------------------------------------------------------

VISITS = [
    {"id": 1, "area_id": None, "user_id": 1, "name": "Costco", "status": "confirmed",
     "confidence": 90, "confidence_band": "high",
     "started_at": "2026-09-01T14:00:00.000Z", "ended_at": "2026-09-01T15:30:00.000Z",
     "duration": 90, "place": {"latitude": 39.95, "longitude": -105.17, "id": 10}},
    {"id": 2, "area_id": None, "user_id": 1, "name": "Library", "status": "suggested",
     "confidence": 40, "confidence_band": "medium",
     "started_at": "2026-09-02T09:00:00.000Z", "ended_at": "2026-09-02T09:20:00.000Z",
     "duration": 20, "place": {"latitude": 40.01, "longitude": -105.28, "id": 11}},
    {"id": 3, "area_id": None, "user_id": 1, "name": "Nope", "status": "declined",
     "confidence": 10, "confidence_band": "low",
     "started_at": "2026-09-03T09:00:00.000Z", "ended_at": "2026-09-03T09:05:00.000Z",
     "duration": 5, "place": {"latitude": 40.0, "longitude": -105.0, "id": None}},
]
PLACES = [
    {"id": 10, "name": "Costco", "longitude": -105.17, "latitude": 39.95,
     "city": "Superior", "country": "United States", "source": "manual",
     "geodata": {}, "created_at": "2026-01-01T00:00:00.000Z",
     "updated_at": "2026-02-01T00:00:00.000Z", "reverse_geocoded_at": None,
     "name_locked": False},
    {"id": 11, "name": "Boulder Public Library", "longitude": -105.28, "latitude": 40.01,
     "city": "Boulder", "country": "United States", "source": "photon",
     "geodata": {}, "created_at": "2026-01-02T00:00:00.000Z",
     "updated_at": "2026-01-02T00:00:00.000Z", "reverse_geocoded_at": None,
     "name_locked": False},
]
POINTS = [
    {"id": 100 + i, "timestamp": 1788271200 + 60 * i, "latitude": "39.95%02d" % i,
     "longitude": "-105.17", "altitude": 1600, "accuracy": 5, "velocity": "0.0",
     "battery": 80, "city": "Superior", "country_name": "United States"}
    for i in range(7)
]

REQUESTS = []


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, payload, headers=None):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Dawarich-Version", "0.99.0")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = urlsplit(self.path)
        params = {k: v[0] for k, v in parse_qs(parts.query).items()}
        REQUESTS.append((parts.path, params, self.headers.get("Authorization")))
        if parts.path == "/api/v1/health":
            return self._send(200, {"status": "ok"})
        if self.headers.get("Authorization") != "Bearer " + KEY:
            return self._send(401, {"error": "unauthorized"})
        if parts.path == "/api/v1/users/me":
            return self._send(200, {"user": {"email": "dan@example.com"}})
        page = int(params.get("page", "1"))
        per = int(params.get("per_page", "100"))
        if parts.path == "/api/v1/visits":
            rows = VISITS
        elif parts.path == "/api/v1/places":
            rows = PLACES
        elif parts.path == "/api/v1/points":
            rows = POINTS
            per = min(per, 3)   # force pagination on the smallest collection
        else:
            return self._send(404, {"error": "not found"})
        total_pages = max(1, -(-len(rows) // per))
        chunk = rows[(page - 1) * per: page * per]
        return self._send(200, chunk, {"X-Total-Pages": str(total_pages),
                                       "X-Current-Page": str(page)})


server = HTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:%d" % server.server_address[1]


def run(cmd, env=None, ok=True):
    full = dict(os.environ, **(env or {}))
    proc = subprocess.run(cmd, capture_output=True, text=True, env=full)
    if ok and proc.returncode != 0:
        FAILED.append("%s exited %d\n%s" % (" ".join(cmd), proc.returncode, proc.stderr))
    return proc


def js(proc):
    try:
        return json.loads(proc.stdout)
    except ValueError:
        FAILED.append("not JSON: %r" % proc.stdout[:200])
        return None


# --------------------------------------------------------------------------
# the plugin, pointed at the fake by flags
# --------------------------------------------------------------------------

direct = ["--url", URL, "--api-key", KEY]
# 🛑 Isolate from the real plugins.json and Keychain for EVERY call below, even
# those that pass flags, so a stray lookup can never reach the user's config.
with tempfile.TemporaryDirectory() as tmp:
    ISOLATED = {"APPLE_PLUGINS_CONFIG": os.path.join(tmp, "plugins.json"),
                "APPLE_PLUGINS_KEYCHAIN_FILE": os.path.join(tmp, "keychain.json"),
                "APPLE_TOOLS_PLUGINS": os.path.join(ROOT, "plugins"),
                "PATH": "/usr/bin:/bin"}

    m = js(run([PLUGIN, "manifest", "--json"], ISOLATED))
    check("manifest name", m and m["name"], "dawarich")
    check("manifest declares network", bool(m and m.get("network")), True)
    check("manifest config keys", [c["key"] for c in m["config"]], ["url", "api_key"])
    check("api_key is secret", [c["secret"] for c in m["config"]], [False, True])

    s = js(run([PLUGIN, "status", "--json"] + direct, ISOLATED))
    check("status ok", (s["status"], s["usable"]), ("ok", True))
    check("status version from header", s["version"], "0.99.0")
    check("status host", s["hosts"], ["127.0.0.1:%d" % server.server_address[1]])

    p = run([PLUGIN, "status", "--json", "--url", URL, "--api-key", "wrong"], ISOLATED, ok=False)
    check("bad key --json still exits 0, like the tools", p.returncode, 0)
    p2 = run([PLUGIN, "status", "--url", URL, "--api-key", "wrong"], ISOLATED, ok=False)
    check("bad key plain exits 1", p2.returncode, 1)
    check("bad key is unauthorized", js(p)["status"], "unauthorized")

    p = run([PLUGIN, "status", "--json", "--url", "http://127.0.0.1:1", "--api-key", KEY],
            ISOLATED, ok=False)
    check("dead server is unreachable", js(p)["status"], "unreachable")

    p = run([PLUGIN, "status", "--json"], ISOLATED, ok=False)
    check("unconfigured status", js(p)["status"], "unconfigured")
    check("unconfigured --json exits 0", p.returncode, 0)
    p = run([PLUGIN, "visits", "--json"], ISOLATED, ok=False)
    check("unconfigured read exits 78", p.returncode, 78)

    v = js(run([PLUGIN, "visits", "--json", "--from", "2026-08-01", "--to", "2026-10-01"]
               + direct, ISOLATED))
    check("declined never reported", sorted(x["status"] for x in v), ["confirmed", "suggested"])
    check("newest first", [x["id"] for x in v], [2, 1])
    costco = [x for x in v if x["id"] == 1][0]
    check("duration recomputed in seconds", costco["duration_seconds"], 5400)
    check("duration human", costco["duration"], "1h 30m")
    check("visit coordinates", (costco["latitude"], costco["longitude"]), (39.95, -105.17))
    sent = [q for path, q, _ in REQUESTS if path == "/api/v1/visits"][-1]
    check("visits window sent", (sent["start_at"], sent["end_at"]),
          ("2026-08-01T00:00:00Z", "2026-10-01T00:00:00Z"))
    check("visits asked by page", sent["page"], "1")

    v = js(run([PLUGIN, "visits", "--json", "--from", "2026-08-01", "--to", "2026-10-01",
                "--status", "confirmed"] + direct, ISOLATED))
    check("--status confirmed", [x["id"] for x in v], [1])

    pl = js(run([PLUGIN, "places", "--json"] + direct, ISOLATED))
    check("places", [(x["name"], x["city"]) for x in pl],
          [("Costco", "Superior"), ("Boulder Public Library", "Boulder")])
    pl = js(run([PLUGIN, "places", "--json", "--search", "boulder"] + direct, ISOLATED))
    check("places --search matches city", [x["id"] for x in pl], [11])

    REQUESTS.clear()
    pts = js(run([PLUGIN, "points", "--json", "--from", "2026-09-01", "--to", "2026-09-02",
                  "--limit", "0"] + direct, ISOLATED))
    check("points follow X-Total-Pages", len(pts), 7)
    check("points paged three times",
          [q["page"] for path, q, _ in REQUESTS if path == "/api/v1/points"], ["1", "2", "3"])
    check("points epoch window",
          [q["start_at"] for path, q, _ in REQUESTS if path == "/api/v1/points"][0],
          str(1788220800))
    p = run([PLUGIN, "points", "--json", "--from", "2026-09-01", "--to", "2026-09-02",
             "--limit", "2"] + direct, ISOLATED)
    check("points --limit cuts", len(js(p)), 2)
    check("points cut is said on stderr", "showing the first 2" in p.stderr, True)

    # index: NDJSON in the record shape
    p = run([PLUGIN, "index", "--from", "2026-08-01", "--to", "2026-10-01"] + direct, ISOLATED)
    records = [json.loads(line) for line in p.stdout.splitlines() if line.strip()]
    kinds = sorted((r["kind"], r["native_id"]) for r in records)
    check("index kinds", kinds,
          [("place", "10"), ("place", "11"), ("suggested", "2"), ("visit", "1")])
    need = {"uid", "tool", "kind", "native_id", "url", "title", "container", "created",
            "modified", "occurred", "latitude", "longitude", "people", "body", "rev"}
    check("every record has every field",
          all(need <= set(r) for r in records), True)
    visit = [r for r in records if r["uid"] == "dawarich:visit:1"][0]
    check("visit body carries the stay", "stayed 1h 30m" in visit["body"], True)
    check("visit body carries the confidence", "confidence 90" in visit["body"], True)
    check("rev tracks the confidence", visit["rev"].endswith("|90"), True)
    check("visit container is the country", visit["container"], "United States")
    check("visit occurred", visit["occurred"], 1788271200.0)
    check("visit url", visit["url"], "%s/visits/1" % URL)
    place = [r for r in records if r["uid"] == "dawarich:place:10"][0]
    check("place container is the country", place["container"], "United States")
    check("place rev tracks updated_at", place["rev"], "Costco|2026-02-01T00:00:00.000Z")

    # ----------------------------------------------------------------------
    # the manager, against the temp config and temp keychain
    # ----------------------------------------------------------------------
    lst = js(run([MANAGER, "list", "--json"], ISOLATED))
    row = [r for r in lst if r["name"] == "dawarich"]
    check("manager finds the checkout plugin", len(row), 1)
    check("not enabled by default", row[0]["enabled"], False)
    check("missing config listed", sorted(row[0]["missing"]), ["api_key", "url"])
    check("network shown", row[0]["network"], True)

    p = run([MANAGER, "enable", "dawarich"], ISOLATED, ok=False)
    check("enable refuses without config", p.returncode, 1)
    check("enable names the missing keys", "api_key" in p.stderr and "url" in p.stderr, True)

    p = run([MANAGER, "config", "dawarich", "bogus=1"], ISOLATED, ok=False)
    check("unknown key is a hard error", p.returncode, 64)

    c = js(run([MANAGER, "config", "dawarich", "url=" + URL, "api_key=" + KEY, "--json"],
               ISOLATED))
    check("url stored", c["config"]["url"], URL)
    check("secret redacted", c["config"]["api_key"], "•••")
    check("nothing missing now", c["missing"], [])
    with open(ISOLATED["APPLE_PLUGINS_CONFIG"]) as fh:
        on_disk = fh.read()
    check("secret never in plugins.json", KEY in on_disk, False)
    check("file is 0600", oct(os.stat(ISOLATED["APPLE_PLUGINS_CONFIG"]).st_mode & 0o777), "0o600")
    c = js(run([MANAGER, "config", "dawarich", "--json", "--reveal"], ISOLATED))
    check("--reveal shows the secret", c["config"]["api_key"], KEY)

    e = js(run([MANAGER, "enable", "dawarich", "--json"], ISOLATED))
    check("enabled", (e["enabled"], e["changed"]), (True, True))
    e = js(run([MANAGER, "enable", "dawarich", "--json"], ISOLATED))
    check("re-enable is a no-op", e["changed"], False)
    en = js(run([MANAGER, "enabled"], ISOLATED))
    check("enabled lists it with a manifest", [r["name"] for r in en], ["dawarich"])
    check("enabled carries refresh args", en[0]["manifest"]["index"]["refresh_args"],
          ["--since", "3650"])

    p = run([MANAGER, "resolve", "dawarich"], ISOLATED)
    check("resolve prints the path", os.path.realpath(p.stdout.strip()), os.path.realpath(PLUGIN))

    # the plugin now reads url + key from the manager, with no flags
    s = js(run([PLUGIN, "status", "--json"], dict(ISOLATED, APPLE_PLUGINS_BIN=MANAGER)))
    check("plugin reads stored config", (s["status"], s["url"]), ("ok", URL))

    # dispatch through `apple`
    env = dict(ISOLATED, APPLE_PLUGINS_BIN=MANAGER)
    s = js(run([APPLE, "dawarich", "status", "--json"], env))
    check("apple dawarich dispatches", s and s["status"], "ok")
    st = js(run([APPLE, "status", "--json"], env, ok=False))
    check("apple status carries the plugin", st and st.get("dawarich", {}).get("usable"), True)
    check("apple status names the host as its permission",
          st and st["dawarich"]["pane"].startswith("plugin: 127.0.0.1"), True)
    check("granted_to is plugin", st and st["dawarich"]["granted_to"], "plugin")
    p = run([APPLE, "--which"], env)
    check("--which lists the plugin", "dawarich" in p.stdout and "(plugin)" in p.stdout, True)
    p = run([APPLE, "nosuchplugin", "status"], env, ok=False)
    check("unknown tool still errors", "unknown tool" in p.stderr, True)

    d = js(run([MANAGER, "disable", "dawarich", "--json"], ISOLATED))
    check("disabled", (d["enabled"], d["changed"]), (False, True))
    p = run([MANAGER, "resolve", "dawarich"], ISOLATED, ok=False)
    check("resolve refuses a disabled plugin with 2", p.returncode, 2)
    p = run([APPLE, "dawarich", "status"], env, ok=False)
    check("apple refuses a disabled plugin", p.returncode, 1)
    check("and says how to enable it", "apple plugins enable dawarich" in p.stderr, True)
    check("disabled is not unknown", "unknown tool" in p.stderr, False)
    en = js(run([MANAGER, "enabled"], ISOLATED))
    check("disabled is absent from enabled", en, [])

    # unsetting a secret removes it from the keychain file
    js(run([MANAGER, "config", "dawarich", "--unset", "api_key", "--json"], ISOLATED))
    with open(ISOLATED["APPLE_PLUGINS_KEYCHAIN_FILE"]) as fh:
        check("unset removes the secret", json.load(fh), {})

server.shutdown()

if FAILED:
    print("FAILED %d:" % len(FAILED))
    for f in FAILED:
        print("  -", f)
    sys.exit(1)
print("ok")
