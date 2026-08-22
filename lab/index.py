#!/usr/bin/env python3
"""A semantic index over the apple-tools readers. Experimental.

Nothing here is part of the shipped tool. It calls the installed `apple` CLI as
a subprocess and shares no code with it, so the readers stay the single source
of truth and this directory can be deleted without consequence.

The split of work:

  * Python (this file) owns ingestion, the SQLite schema, FTS5 and the fusion.
  * `vec/` (Swift) owns the embedding model and the dot products, because the
    system python3 has no numpy.

The design follows Apple's own, read out of `_CoreSpotlight_FoundationModels`
in the macOS 27 SDK: one flat record shape for every app, a small set of shared
people/date/container roles, and lexical and vector matching fused into one
ranked list.

  ./index.py init
  ./index.py ingest --source notes --limit 50
  ./index.py embed
  ./index.py search "the budget thing before the board meeting"
"""

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import socket
import glob
import sqlite3
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
VEC = os.path.join(HERE, "vec", ".build", "release", "vec")
OSS = os.path.join(HERE, "embed_oss.py")
DAEMON = os.path.join(HERE, "daemon.py")


def daemon_request(payload, socket_path=None, timeout=30):
    """Ask the warm daemon. Returns None when it is not running.

    ⚠️ Never an error when absent. The daemon is an optimisation, and a search
    must still work without it, just slower.
    """
    path = socket_path or DEFAULT_SOCKET
    if not os.path.exists(path):
        return None
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(timeout)
        client.connect(path)
        client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        chunks = b""
        while not chunks.endswith(b"\n"):
            part = client.recv(65536)
            if not part:
                break
            chunks += part
        client.close()
        return json.loads(chunks)
    except (OSError, json.JSONDecodeError):
        return None

# Apple's models live in the Swift binary; the open ones need PyTorch, so they
# live in embed_oss.py behind `uv run`. Both write the same `vector` table and
# both record `model`, so a search never mixes two vector spaces.
APPLE_MODELS = ("sentence", "contextual")
OSS_MODELS = ("e5-base", "e5-small", "minilm")
ALL_MODELS = APPLE_MODELS + OSS_MODELS


def vector_search_cmd(model, db, query, limit, tool=None):
    if model in OSS_MODELS:
        cmd = ["uv", "run", "--quiet", OSS, "search", "--db", db,
               "--model", model, "--query", query, "--limit", str(limit)]
    else:
        cmd = [VEC, "search", "--db", db, "--query", query,
               "--model", model, "--limit", str(limit)]
    if tool:
        cmd += ["--tool", tool]
    return cmd

# 🛑 WHERE THIS FILE LIVES IS A SECURITY DECISION, not a tidiness one.
#
# The index holds ~105 MB of DECODED mail bodies, every message block, every
# note and every contact, in one plain SQLite file. The stores it was built
# from are protected two ways: `~/Library/Mail` is mode 0700, and TCC Full Disk
# Access gates all of them at the kernel. **The index inherits neither.**
#
# A CLI cannot put a file inside a TCC-protected location, so that protection
# cannot be reproduced. What is left is the directory mode, which is why the
# parent is created 0700 and the file 0600. An index left at 0644 in a project
# directory hands every process running as this user the whole mail corpus with
# no grant at all — which is exactly what the first version of this lab did.
#
# ⚠️ Time Machine and any cloud backup will copy this file. Deleting the
# original mail does not delete it from a backup.
DEFAULT_DB = os.path.expanduser(
    os.environ.get("APPLE_INDEX_DB",
                   "~/Library/Application Support/apple-tools/lab-index.db"))

# 🛑 The socket lives in the 0700 index directory at mode 0600, never on a TCP
# port. A port would put the whole mail corpus one bad bind address away from
# the network.
DEFAULT_SOCKET = os.path.join(os.path.dirname(DEFAULT_DB), "index.sock")


def secure_db_path(path):
    """Create the parent 0700, keep Spotlight out, and force the file to 0600."""
    parent = os.path.dirname(path)
    if parent:
        try:
            os.makedirs(parent, mode=0o700, exist_ok=True)
            os.chmod(parent, 0o700)
        except OSError as e:
            # ⚠️ A shared parent such as /tmp cannot be chmodded, and dying
            # there would break every --db outside the default location. Say
            # the protection is missing instead, because it really is.
            sys.stderr.write(
                "⚠️  cannot set %s to 0700 (%s). The index is readable by anyone\n"
                "   who can list that directory. Use the default location.\n"
                % (parent, e.strerror))
        # Spotlight will not index a directory holding this file, so the mail
        # bodies do not end up in a second searchable copy.
        marker = os.path.join(parent, ".metadata_never_index")
        try:
            if not os.path.exists(marker):
                open(marker, "w").close()
        except OSError:
            pass
    for suffix in ("", "-wal", "-shm"):
        f = path + suffix
        if os.path.exists(f):
            try:
                os.chmod(f, 0o600)
            except OSError:
                pass

CHUNK_CHARS = 900          # ~200 tokens, under the model's 256-token window
CHUNK_OVERLAP = 150
MAX_CHUNKS_PER_RECORD = 20 # bound the cost of one enormous note or thread
RRF_K = 60                 # the usual Reciprocal Rank Fusion constant

# Only used to decide whether a query is a keyword lookup or a question.
STOPWORDS = {
    "the", "and", "for", "what", "who", "where", "when", "how", "why", "which",
    "is", "are", "was", "were", "does", "did", "can", "with", "that", "this",
    "from", "about", "into", "onto", "you", "your", "our", "their", "his",
    "her", "its", "have", "has", "had", "get", "got", "any", "all", "some",
}

SOURCES = ["notes", "mail", "messages", "calendar", "contacts", "maps"]


# --------------------------------------------------------------------------
# schema
# --------------------------------------------------------------------------

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS record (
  rid       INTEGER PRIMARY KEY,
  uid       TEXT    NOT NULL UNIQUE,   -- "notes:11821"
  tool      TEXT    NOT NULL,
  kind      TEXT    NOT NULL,
  native_id TEXT    NOT NULL,
  url       TEXT,
  title     TEXT,
  container TEXT,                      -- folder / mailbox / calendar / chat
  created   REAL,
  modified  REAL,
  occurred  REAL,                      -- when the thing happened, not when indexed
  people    TEXT,                      -- JSON [{role, name, handle}]
  people_text TEXT,                    -- the same names, flattened for FTS
  body      TEXT,
  rev       TEXT,                      -- source revision, for change detection
  seen_at   REAL NOT NULL,
  -- 🛑 A COORDINATE, not the location text. `location` on a calendar event is
  -- free text that may say "Zoom" or "my desk", and nothing geocodes it after
  -- the fact. Only a record that already carries a real latitude and longitude
  -- can answer "what was near what". EventKit keeps that on a separate
  -- EKStructuredLocation, and `apple maps` carries one on every place.
  latitude  REAL,
  longitude REAL
);

CREATE INDEX IF NOT EXISTS record_tool     ON record(tool);
CREATE INDEX IF NOT EXISTS record_occurred ON record(occurred);

CREATE VIRTUAL TABLE IF NOT EXISTS record_fts USING fts5(
  title, body, people_text,
  content='record', content_rowid='rid',
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS record_ai AFTER INSERT ON record BEGIN
  INSERT INTO record_fts(rowid, title, body, people_text)
  VALUES (new.rid, new.title, new.body, new.people_text);
END;

CREATE TRIGGER IF NOT EXISTS record_ad AFTER DELETE ON record BEGIN
  INSERT INTO record_fts(record_fts, rowid, title, body, people_text)
  VALUES ('delete', old.rid, old.title, old.body, old.people_text);
END;

CREATE TRIGGER IF NOT EXISTS record_au AFTER UPDATE ON record BEGIN
  INSERT INTO record_fts(record_fts, rowid, title, body, people_text)
  VALUES ('delete', old.rid, old.title, old.body, old.people_text);
  INSERT INTO record_fts(rowid, title, body, people_text)
  VALUES (new.rid, new.title, new.body, new.people_text);
END;

CREATE TABLE IF NOT EXISTS chunk (
  cid  INTEGER PRIMARY KEY,
  rid  INTEGER NOT NULL REFERENCES record(rid) ON DELETE CASCADE,
  ord  INTEGER NOT NULL,
  text TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS chunk_rid ON chunk(rid);

-- 🛑 The lexical arm ranked whole RECORDS while the vector arm ranked CHUNKS.
-- bm25 then preferred a passing mention inside a long email over a short record
-- that was entirely about the term. Measured: searching "Jenoptik" put six
-- Christmas-poem emails above the contact whose 73-character body is
-- "Dave Stephenson / Jenoptik Optical Systems, LLC / Sr MTS". Indexing chunks
-- puts both arms on the same unit.
CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
  text, content='chunk', content_rowid='cid', tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS chunk_ai AFTER INSERT ON chunk BEGIN
  INSERT INTO chunk_fts(rowid, text) VALUES (new.cid, new.text);
END;

CREATE TRIGGER IF NOT EXISTS chunk_ad AFTER DELETE ON chunk BEGIN
  INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.cid, old.text);
END;

CREATE TRIGGER IF NOT EXISTS chunk_au AFTER UPDATE ON chunk BEGIN
  INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.cid, old.text);
  INSERT INTO chunk_fts(rowid, text) VALUES (new.cid, new.text);
END;

-- Written only by vec/. int8, mean-pooled, L2-normalised, scaled by 127.
-- 🛑 `model` is part of the key. Two embedding models do not share a vector
-- space, so scoring across both returns confident nonsense.
CREATE TABLE IF NOT EXISTS vector (
  cid   INTEGER NOT NULL REFERENCES chunk(cid) ON DELETE CASCADE,
  model TEXT    NOT NULL,
  dim   INTEGER NOT NULL,
  v     BLOB    NOT NULL,
  PRIMARY KEY (cid, model)
);

-- A revision for a UNIT INSIDE a source, so an adapter can skip an expensive
-- fetch. `messages` uses it per chat: the chat listing already carries
-- last_message and message_count, which identify a chat's state without
-- exporting it.
CREATE TABLE IF NOT EXISTS cursor (
  tool TEXT NOT NULL,
  key  TEXT NOT NULL,
  rev  TEXT NOT NULL,
  PRIMARY KEY (tool, key)
);

-- Every search is recorded: the query, the settings that produced it, and the
-- ranked result the caller actually saw. Without this, "why did it return
-- that?" can only be answered by guessing at settings that have since changed.
-- 🛑 Aggregating every protected store into one unprotected file is not
-- something a user should get by accident. Recorded once, per index.
CREATE TABLE IF NOT EXISTS consent (
  granted_at REAL NOT NULL,
  version    TEXT NOT NULL,
  how        TEXT NOT NULL          -- 'interactive' or '--accept-risk'
);

CREATE TABLE IF NOT EXISTS query_log (
  qid        INTEGER PRIMARY KEY,
  ts         REAL NOT NULL,
  query      TEXT NOT NULL,
  settings   TEXT NOT NULL,      -- JSON: model, weights, lexical unit, fts mode
  fingerprint TEXT NOT NULL,     -- what the index held at the time
  elapsed_ms REAL,
  n_results  INTEGER,
  cached     INTEGER NOT NULL DEFAULT 0,
  results    TEXT NOT NULL       -- JSON: the ranked rows, exactly as returned
);
CREATE INDEX IF NOT EXISTS query_log_ts ON query_log(ts);
CREATE INDEX IF NOT EXISTS query_log_query ON query_log(query);

-- 🛑 A cache entry is keyed by the query AND the settings AND a fingerprint of
-- the index. Any of the three changing must miss, or a tuning run reads back
-- the previous run's answers and every comparison becomes meaningless.
CREATE TABLE IF NOT EXISTS result_cache (
  key        TEXT PRIMARY KEY,
  ts         REAL NOT NULL,
  query      TEXT NOT NULL,
  results    TEXT NOT NULL,
  elapsed_ms REAL
);

CREATE TABLE IF NOT EXISTS source_state (
  tool      TEXT PRIMARY KEY,
  watermark TEXT,
  records   INTEGER,
  updated   REAL
);
"""


def connect(path, create=False):
    if not create and not os.path.exists(path):
        die("no index at %s. Run: ./index.py init" % path)
    secure_db_path(path)
    db = sqlite3.connect(path)
    secure_db_path(path)          # again: connecting creates -wal and -shm
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA busy_timeout = 5000")
    # ⚠️ Apply the schema on every connect. Every statement in it is
    # IF NOT EXISTS, so this is a no-op on an up-to-date index and a migration
    # on an old one. Adding query_log and result_cache without this made every
    # command fail on an existing database.
    db.executescript(SCHEMA)
    # ⚠️ Every statement in SCHEMA is IF NOT EXISTS, so it migrates an old
    # index for free. ADD COLUMN is the one thing with no such form, so it
    # needs an explicit check. Do not wrap this in try/except: a silent failure
    # leaves every coordinate null and the geo commands answering nothing.
    have = {r["name"] for r in db.execute("PRAGMA table_info(record)")}
    for column in ("latitude", "longitude"):
        if column not in have:
            db.execute("ALTER TABLE record ADD COLUMN %s REAL" % column)
    # 🛑 AFTER the ALTER, never inside SCHEMA. SCHEMA runs first on every
    # connect, and an index naming a column that does not exist yet fails the
    # whole script — which locks an old index out of the migration that would
    # have fixed it.
    db.execute("CREATE INDEX IF NOT EXISTS record_coord "
               "ON record(latitude, longitude)")
    db.commit()
    return db


def die(message):
    print("index: " + message, file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------------------
# calling the apple CLI
# --------------------------------------------------------------------------

def apple(*args, text_output=False, allow_fail=False):
    """Run `apple ...`. Returns parsed JSON, or raw text, or None on failure."""
    cmd = ["apple"] + [str(a) for a in args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        if allow_fail:
            return None
        die("%s exited %d\n%s" % (" ".join(cmd), proc.returncode, proc.stderr.strip()))
    if text_output:
        return proc.stdout
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        if allow_fail:
            return None
        die("%s did not return JSON:\n%s" % (" ".join(cmd), proc.stdout[:400]))


def epoch(value):
    """ISO 8601 (with Z or an offset) to a Unix timestamp. None stays None."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        pass
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    return None


# --------------------------------------------------------------------------
# store watermarks
#
# 🛑 The CLI's cheap listings do not carry a change signal: `apple notes
# search` returns an id and a title, `apple contacts list` an id and a name.
# Both underlying stores DO carry a per-record modification date, and reading
# one costs milliseconds. That is the only place this lab reaches past the CLI,
# and it reads nothing but the id and the date.
#
# 🛑 NEVER open these with `immutable=1`. Both stores are in WAL mode with a
# multi-megabyte log, and `immutable=1` does not replay it. Measured: the
# AddressBook store answered "max modification 18:09:41" under `immutable=1`
# and "20:33:45" under `mode=ro` at the same moment, and a contact created
# seconds earlier was absent entirely. That mistake produced a written
# conclusion that contacts had no change signal at all. It has one.
#
# The right long-term fix is a `--modified-since` flag on the CLI itself, which
# would remove the need for this file to know any schema.
# --------------------------------------------------------------------------

def _read_only(path):
    return sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(path), uri=True)


def store_revs_contacts():
    """{'UUID:ABPerson': modification_date} across every AddressBook source."""
    base = os.path.expanduser("~/Library/Application Support/AddressBook")
    paths = [os.path.join(base, "AddressBook-v22.abcddb")]
    paths += glob.glob(os.path.join(base, "Sources", "*", "AddressBook-v22.abcddb"))
    out = {}
    for path in paths:
        if not os.path.exists(path):
            continue
        try:
            db = _read_only(path)
            for uid, mod in db.execute(
                    "SELECT ZUNIQUEID, ZMODIFICATIONDATE FROM ZABCDRECORD "
                    "WHERE ZUNIQUEID IS NOT NULL AND ZMODIFICATIONDATE IS NOT NULL"):
                out[uid] = mod
            db.close()
        except sqlite3.Error:
            continue
    return out


def store_revs_notes():
    """{note_pk: modification_date} from NoteStore."""
    path = os.path.expanduser(
        "~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    if not os.path.exists(path):
        return {}
    try:
        db = _read_only(path)
        out = {pk: mod for pk, mod in db.execute(
            "SELECT Z_PK, ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT "
            "WHERE ZMODIFICATIONDATE1 IS NOT NULL")}
        db.close()
        return out
    except sqlite3.Error:
        return {}


def rev_of(*parts):
    h = hashlib.sha1()
    for p in parts:
        h.update((p or "").encode("utf-8", "replace"))
        h.update(b"\x00")
    return h.hexdigest()[:16]


# --------------------------------------------------------------------------
# adapters — each yields the one flat record shape
# --------------------------------------------------------------------------

def ingest_notes(opts):
    store = store_revs_notes()
    listing = apple("notes", "search", "--limit", opts.limit or 100000, "--json")
    for row in listing:
        nid = row["id"]
        title = row.get("title") or ""

        def load(nid=nid):
            body = apple("notes", "export", nid, text_output=True, allow_fail=True)
            return (body or "").strip(), []   # None means locked (exit 2) or gone

        mod = store.get(nid)
        if mod is None:
            # No store date. Fall back to hashing the body, which costs the
            # export. 681 of 680 notes carry a date, so this is the rare path.
            body, _ = load()
            rev, lazy = rev_of(title, body), None
        else:
            body, rev, lazy = "", rev_of(title, repr(mod)), load

        record = {
            "uid": "notes:%s" % nid,
            "tool": "notes", "kind": "note", "native_id": str(nid),
            "url": None,            # `apple notes get-url` is a second subprocess
            "title": title,
            "container": None,
            "created": None, "occurred": None,
            "people": [],
            "body": body,
            "modified": (mod + 978307200) if mod else None,
            "rev": rev,
        }
        if lazy:
            record["body_fn"] = lazy
        yield record


def ingest_mail(opts):
    # 🛑 `apple mail search` defaults to 20 rows. Passing no --limit does NOT
    # mean "everything"; it means twenty. Combined with --full that once
    # deleted 128 indexed records and reported it as reconciliation.
    args = ["mail", "search", "", "--json", "--limit", str(opts.limit or 1000000)]
    if opts.since:
        args += ["--since", str(opts.since)]
    rows = apple(*args)
    for row in rows:
        mid = row["id"]
        subject = row.get("subject") or ""
        sender = row.get("from") or ""

        # 🛑 The rev must NOT depend on the body. A body costs one subprocess
        # per message, so hashing it forces an export of all 41k messages
        # before the change check can run — 38 minutes to discover that
        # nothing changed. A delivered message's body never changes, so the
        # headers identify a revision on their own.
        # The `bodies` marker forces a refresh when the caller switches
        # --with-bodies on, which a header-only hash would otherwise skip.
        rev = rev_of(subject, sender, row.get("date_iso"),
                     "bodies" if opts.with_bodies else "headers")

        def load_body(mid=mid, sender=sender):
            """Called only when the record is new or its rev moved."""
            people = [{"role": "author", "name": sender, "handle": sender}]
            full = apple("mail", "export", mid, "--json", allow_fail=True)
            if not full:
                return "", people
            for field, role in (("to", "recipient"), ("cc", "recipient")):
                for who in full.get(field) or []:
                    people.append({"role": role, "name": who, "handle": who})
            return (full.get("body") or "").strip(), people

        # One Message-ID can sit in several mailboxes, so the id alone collides.
        # Measured: 150 messages produced 3 collisions on the first run.
        record = {
            "uid": "mail:%s@%s/%s" % (mid, row.get("account") or "", row.get("mailbox") or ""),
            "tool": "mail", "kind": "message", "native_id": mid,
            "url": "message://%%3C%s%%3E" % mid,
            "title": subject,
            "container": "%s/%s" % (row.get("account") or "", row.get("mailbox") or ""),
            "created": epoch(row.get("date_iso")),
            "modified": None,
            "occurred": epoch(row.get("date_iso")),
            "people": [{"role": "author", "name": sender, "handle": sender}],
            "body": "",
            "rev": rev,
        }
        if opts.with_bodies:
            record["body_fn"] = load_body
        yield record


def ingest_messages(opts):
    """One record per BLOCK of consecutive messages, not per message.

    A single SMS is a poor unit to embed: too short to carry meaning, and it
    produces one vector per line. Blocking keeps the conversation together.
    Change --message-block to test other window sizes; that is the experiment.
    """
    chats = apple("messages", "chats", "--limit", opts.chat_limit, "--json")
    per_chat = opts.limit or 500
    db = opts._db
    known = {k: r for k, r in db.execute(
        "SELECT key, rev FROM cursor WHERE tool = 'messages'")}
    skipped_empty = skipped_same = 0

    for chat in chats:
        cid = chat["id"]

        # ⚠️ 475 of 1,331 chats here hold zero messages. Exporting one costs a
        # subprocess and returns nothing.
        count = chat.get("message_count")
        if not count:
            skipped_empty += 1
            continue

        # 🛑 The chat listing already carries a revision, so an unchanged chat
        # needs no export at all. One call describes all 1,331 chats in 0.15s;
        # exporting each costs 0.03s, or 40s for the lot.
        chat_rev = rev_of(chat.get("last_message"), str(count))
        if known.get(str(cid)) == chat_rev:
            skipped_same += 1
            continue

        payload = apple("messages", "export", cid, "--limit", per_chat, "--json",
                        allow_fail=True)
        if not payload:
            continue
        rows = [m for m in payload.get("messages", []) if (m.get("text") or "").strip()]
        title = chat.get("title") or str(cid)
        block = opts.message_block

        for start in range(0, len(rows), block):
            window = rows[start:start + block]
            lines, handles = [], set()
            for m in window:
                who = "me" if m.get("from_me") else (m.get("handle") or m.get("sender") or "?")
                handles.add(who)
                lines.append("%s: %s" % (who, m["text"]))
            first, last = window[0], window[-1]
            yield {
                "uid": "messages:%s:%s" % (cid, first["id"]),
                "tool": "messages", "kind": "conversation", "native_id": str(first["id"]),
                "url": None,
                "title": "%s (%s)" % (title, (first.get("date") or "")[:10]),
                "container": title,
                "created": epoch(first.get("date")),
                "modified": None,
                "occurred": epoch(last.get("date")),
                "people": [{"role": "handle", "name": h, "handle": h} for h in sorted(handles)],
                "body": "\n".join(lines),
                "rev": rev_of(str(len(window)), last.get("guid")),
            }

        # Written only after every block of this chat has been yielded, and
        # cmd_ingest commits per record. A crash mid-chat leaves the cursor
        # unset, so the next run re-exports that chat rather than skipping it.
        db.execute("INSERT INTO cursor (tool, key, rev) VALUES ('messages', ?, ?) "
                   "ON CONFLICT(tool, key) DO UPDATE SET rev = ?",
                   (str(cid), chat_rev, chat_rev))
        db.commit()

    if skipped_empty or skipped_same:
        sys.stderr.write("  messages: skipped %d empty chats, %d unchanged\n"
                         % (skipped_empty, skipped_same))


def ingest_calendar(opts):
    days_back = opts.since or 730
    start = datetime.now(timezone.utc).timestamp() - days_back * 86400
    rows = apple("calendar", "events",
                 "--from", datetime.fromtimestamp(start, timezone.utc).strftime("%Y-%m-%d"),
                 "--to", datetime.fromtimestamp(
                     time.time() + 365 * 86400, timezone.utc).strftime("%Y-%m-%d"),
                 "--json")
    if opts.limit:
        rows = rows[:opts.limit]
    for row in rows:
        eid = row["id"]
        title = row.get("title") or ""
        people = []
        organizer = row.get("organizer") or {}
        if organizer.get("email"):
            people.append({"role": "organizer",
                           "name": organizer.get("name") or organizer["email"],
                           "handle": organizer["email"]})
        for a in row.get("attendees") or []:
            people.append({"role": "attendee",
                           "name": a.get("name") or a.get("email") or "",
                           "handle": a.get("email") or ""})
        body = "\n".join(x for x in [row.get("location"), row.get("notes"), row.get("url")] if x)
        # A recurring event returns the SAME series id for every occurrence, so
        # the id alone collides. Measured: 30 events produced 4 collisions on
        # the first run. `occurrence` is the field that separates them.
        occurrence = row.get("occurrence")
        uid = "calendar:%s@%s" % (eid, occurrence) if occurrence else "calendar:%s" % eid
        # 🛑 `geo` is the only field that can place an event on a map.
        # `location` is free text and may say "Zoom". `has_coordinate` is what
        # separates a geocoded address from a typed one, so read it rather than
        # testing `location` for emptiness.
        geo = row.get("geo") or {}
        lat = geo.get("latitude") if geo.get("has_coordinate") else None
        lon = geo.get("longitude") if geo.get("has_coordinate") else None
        yield {
            "uid": uid,
            "latitude": lat, "longitude": lon,
            "tool": "calendar", "kind": "event", "native_id": eid,
            "url": None,            # no per-event scheme works; see todo-deep-links.md
            "title": title,
            "container": row.get("calendar"),
            "created": None, "modified": None,
            "occurred": epoch(row.get("start")),
            "people": people,
            "body": body.strip(),
            "rev": rev_of(title, row.get("start"), body, str(lat), str(lon)),
        }


# --------------------------------------------------------------------------
# maps — the one source that is ALREADY geospatial
# --------------------------------------------------------------------------

def ingest_maps(opts):
    """Visited places and arrivals, from `apple maps`.

    🛑 This is Maps' "Visited Places", NOT Significant Locations. Significant
    Locations belongs to `routined` under /var/db/locationd/, which no
    unprivileged process can read. They are different features with different
    retention, and reporting one as the other is wrong.

    ⚠️ A visit records a START TIME AND NOTHING ELSE. The schema has no end
    time, so this index cannot say how long the user stayed anywhere. Never
    report a duration from it.

    Two kinds are ingested, and they answer different questions:

      place  one row per location, with a visit count and a last-visit date.
             Answers "where do I go" and "how far is X from Y".
      visit  one row per arrival, dated. Answers "where did I go last week".

    🛑 A place is a location row that HAS a visit. `apple maps places` already
    joins through ZVISIT; the raw table overcounts by 64%. Do not go around it.
    """
    for row in apple("maps", "places", "--limit", opts.limit or 100000, "--json"):
        name = row.get("name") or ""
        parts = [name, row.get("address") or ""]
        parts += row.get("categories") or []
        yield {
            "uid": "maps:place:%s" % row["identifier"],
            "tool": "maps", "kind": "place", "native_id": str(row["id"]),
            "url": None,
            "title": name,
            "container": row.get("category"),
            "created": epoch(row.get("first_visit")),
            "modified": None,
            "occurred": epoch(row.get("latest_visit")),
            "latitude": row.get("latitude"), "longitude": row.get("longitude"),
            "people": [],
            "body": "\n".join(x for x in parts if x),
            "rev": rev_of(name, row.get("latest_visit"), str(row.get("visits"))),
        }

    days = opts.since or 3650
    for row in apple("maps", "visits", "--since", days,
                     "--limit", opts.limit or 100000, "--json"):
        place = row.get("place") or {}
        name = place.get("name") or ""
        # ⚠️ `id` is the VISIT id, and the same place has many. The uid has to
        # carry the visit, or every arrival at one place collapses into one
        # record and the history disappears.
        yield {
            "uid": "maps:visit:%s" % row["id"],
            "tool": "maps", "kind": "visit", "native_id": str(row["id"]),
            "url": None,
            "title": name,
            "container": place.get("category"),
            "created": None, "modified": None,
            "occurred": epoch(row.get("date")),
            "latitude": place.get("latitude"), "longitude": place.get("longitude"),
            "people": [],
            "body": "\n".join(x for x in [name, place.get("address") or ""] if x),
            "rev": rev_of(name, row.get("date")),
        }


def ingest_contacts(opts):
    store = store_revs_contacts()
    listing = apple("contacts", "list", "--limit", opts.limit or 100000)
    for row in listing:
        pid = row["id"]
        name = row.get("name") or ""

        def load(pid=pid, name=name):
            full = apple("contacts", "get", pid, allow_fail=True)
            if not full:
                return "", [{"role": "self", "name": name, "handle": pid}]
            bits = [full.get("company"), full.get("job_title"),
                    full.get("department"), full.get("note")]
            for e in full.get("emails") or []:
                bits.append(e.get("value"))
            for r in full.get("relations") or []:
                bits.append("%s: %s" % (r.get("label"), r.get("value")))
            who = full.get("name") or name
            return ("\n".join(b for b in bits if b),
                    [{"role": "self", "name": who, "handle": pid}])

        mod = store.get(pid)
        if mod is None:
            # 3 of 727 rows carry no modification date. Pay for those.
            body, people = load()
            rev, lazy = rev_of(name, body), None
        else:
            body, people = "", [{"role": "self", "name": name, "handle": pid}]
            rev, lazy = rev_of(name, repr(mod)), load

        record = {
            "uid": "contacts:%s" % pid,
            "tool": "contacts", "kind": "contact", "native_id": pid,
            "url": row.get("contact_url"),
            "title": name,
            "container": None,
            "created": None, "occurred": None,
            "modified": (mod + 978307200) if mod else None,
            "people": people,
            "body": body,
            "rev": rev,
        }
        if lazy:
            record["body_fn"] = lazy
        yield record


ADAPTERS = {
    "notes": ingest_notes,
    "mail": ingest_mail,
    "messages": ingest_messages,
    "calendar": ingest_calendar,
    "contacts": ingest_contacts,
    "maps": ingest_maps,
}


# --------------------------------------------------------------------------
# chunking
# --------------------------------------------------------------------------

HEADING = re.compile(r"^(#{1,6})\s+(\S.*)$")
BLOCK_TARGET = 420        # characters; a packed chunk stops growing past this

MD_LINK = re.compile(r"\[([^\]]*)\]\((?:[^)\s]+)\)")
BARE_URL = re.compile(r"\b(?:https?|applenotes|message|addressbook|x-apple-\S*)://\S+")


QUOTE_LINE = re.compile(r"^\s*>+\s?")

# ⚠️ Outlook and Exchange quote a reply with an underscore rule and bare
# headers, NOT with '>'. 6,085 mail chunks (3%) carried one, and they beat the
# real answer for the snippet because a header block is dense in query terms.
HEADER_RULE = re.compile(r"^\s*_{6,}\s*$")
HEADER_FIELD = re.compile(r"^\s*(From|Sent|To|Cc|Bcc|Subject|Date|Reply-To):\s",
                          re.IGNORECASE)


def strip_quotes(body):
    """Drop quoted reply lines from an email body.

    ⚠️ 95,097 of 251,127 mail chunks carried quoted text, and a reply chain
    repeats the same paragraph once per level. One real thread here held the
    same sentence at five quote depths. Embedding all of them costs time and
    returns the same passage five times in one result list.

    The newest text in a reply sits above the quotes, so dropping quoted lines
    keeps what the sender actually wrote.
    """
    kept, in_header = [], False
    for line in body.splitlines():
        if QUOTE_LINE.match(line):
            continue
        if HEADER_RULE.match(line):
            in_header = True
            continue
        if in_header:
            # The header block runs until a line that is not a header field
            # and not blank. Everything after it is the quoted message.
            if HEADER_FIELD.match(line) or not line.strip():
                continue
            in_header = False
        kept.append(line)
    text = "\n".join(kept)
    # A thread trimmed to nothing means the message was a bare forward. Keep
    # the original rather than indexing an empty record.
    return text if text.strip() else body


def strip_urls(text):
    """Replace a link with its text, and drop a bare URL.

    ⚠️ A URL is nearly pure noise to an embedder and it is long. The chunk
    holding "Bathroom code 3384" was 213 characters, and 145 of them were an
    applenotes:// link with a UUID in it. The signal was outnumbered 2 to 1 by
    a string with no meaning.
    """
    text = MD_LINK.sub(r"\1", text)
    text = BARE_URL.sub("", text)
    return re.sub(r"[ \t]{2,}", " ", text).strip()


def structural_blocks(body):
    """Split a body into (breadcrumb, text) blocks on its own structure.

    🛑 A fixed-width window buries a short answer. "Bathroom code 3384" sat one
    line inside a 900-character window of unrelated HOA text, and mean-pooling
    200 tokens diluted it until six different queries all missed it. A SQL LIKE
    found it in one try. Splitting on headings and blank lines keeps a short,
    self-contained line short.
    """
    crumbs, buf = [], []

    def breadcrumb():
        return " > ".join(text for _, text in crumbs)

    for line in body.splitlines():
        heading = HEADING.match(line)
        if heading:
            if buf:
                yield breadcrumb(), "\n".join(buf).strip()
                buf = []
            level = len(heading.group(1))
            while crumbs and crumbs[-1][0] >= level:
                crumbs.pop()
            crumbs.append((level, heading.group(2).strip()))
            continue
        if not line.strip():
            if buf:
                yield breadcrumb(), "\n".join(buf).strip()
                buf = []
            continue
        buf.append(line)
    if buf:
        yield breadcrumb(), "\n".join(buf).strip()


def chunks_for(record):
    """Title chunk first, then one chunk per structural block.

    Blocks are packed only while they share a breadcrumb and stay under
    BLOCK_TARGET. A block longer than CHUNK_CHARS still gets the sliding
    window, because a wall of prose has no structure to split on.
    """
    # 🛑 A VISIT IS NOT SEARCHABLE TEXT, and chunking one poisons the results.
    # Its title and body are copied verbatim from the place it is a visit to,
    # so 37 arrivals at one gym become 37 identical chunks. Measured: adding
    # maps to the index sent "Frequent Flyers address" from rank 1 to a miss,
    # because the top ten filled with visits to Frequent Flyers that do not
    # carry the address the question asks for. The PLACE record answers every
    # text question about it; a visit exists to carry a date and a coordinate,
    # which `near` and `nearby` read straight off the record.
    if record.get("tool") == "maps" and record.get("kind") == "visit":
        return []

    out = []
    title = (record.get("title") or "").strip()
    people = " ".join(p["name"] for p in record.get("people") or [] if p.get("name"))
    head = " ".join(x for x in [title, people] if x).strip()
    if head:
        out.append(head)

    body = (record.get("body") or "").strip()
    if record.get("tool") == "mail" or record.get("_quoted"):
        body = strip_quotes(body)
    if not body:
        return out[:MAX_CHUNKS_PER_RECORD]

    def emit(crumb, text):
        # The title and the heading path ride along, so a chunk lifted out of
        # the middle of a note still says what it belongs to. Repeated crumbs
        # are dropped: a note whose first heading equals its title otherwise
        # produces "X > X > Research".
        parts, seen = [], set()
        for piece in [title] + (crumb.split(" > ") if crumb else []):
            piece = piece.strip()
            if piece and piece.lower() not in seen:
                parts.append(piece)
                seen.add(piece.lower())
        prefix = " > ".join(parts)
        text = strip_urls(text)
        if not text:
            return
        out.append(("%s\n%s" % (prefix, text)).strip() if prefix else text)

    pending_crumb, pending = None, []
    pending_len = 0

    def flush():
        nonlocal pending, pending_len
        if pending:
            emit(pending_crumb, "\n".join(pending))
            pending, pending_len = [], 0

    for crumb, text in structural_blocks(body):
        if len(out) >= MAX_CHUNKS_PER_RECORD:
            break
        if crumb != pending_crumb:
            flush()
            pending_crumb = crumb

        if len(text) > CHUNK_CHARS:
            flush()
            step = CHUNK_CHARS - CHUNK_OVERLAP
            for start in range(0, len(text), step):
                piece = text[start:start + CHUNK_CHARS].strip()
                if piece:
                    emit(crumb, piece)
                if len(out) >= MAX_CHUNKS_PER_RECORD:
                    break
            continue

        if pending_len + len(text) > BLOCK_TARGET:
            flush()
        pending.append(text)
        pending_len += len(text) + 1

    flush()
    return out[:MAX_CHUNKS_PER_RECORD]


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_init(opts):
    db = connect(opts.db, create=True)
    db.executescript(SCHEMA)
    db.commit()
    print("initialised %s" % opts.db)


CONSENT_VERSION = "1"

CONSENT_PROMPT = """\
Before this reads anything, understand what it builds.

  It copies the PLAINTEXT of your mail, messages, notes, calendar and contacts
  into ONE SQLite file. On this machine that is about 105 MB of decoded email
  bodies alone.

  The stores it reads are protected two ways: Full Disk Access, enforced by the
  kernel, and 0700 directories. THE INDEX INHERITS NEITHER. Any process running
  as you can read every email out of it, with no grant and no prompt.

  Revoking Full Disk Access does NOT disable it. Every backup copies it. There
  is no encryption at rest.

  What is done about it: the directory is 0700, the file is 0600, and Spotlight
  is excluded. That is all.

  Delete it at any time with:  apple-index purge --yes
  Full detail:                 lab/SECURITY.md
"""


def require_consent(db, opts):
    """Ask once per index, and record the answer.

    ⚠️ This is the 'explicit opt-in' SECURITY.md names as a release blocker. It
    refuses without a terminal unless given --accept-risk, the same shape
    `apple notes delete` uses.
    """
    if db.execute("SELECT COUNT(*) c FROM consent").fetchone()["c"]:
        return
    sys.stderr.write("\n" + CONSENT_PROMPT + "\n")
    if getattr(opts, "accept_risk", False):
        how = "--accept-risk"
    else:
        if not sys.stdin.isatty():
            die("indexing needs consent. Re-run in a terminal, or pass --accept-risk.")
        answer = input("Build this index? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            die("cancelled. Nothing was read.")
        how = "interactive"
    db.execute("INSERT INTO consent (granted_at, version, how) VALUES (?,?,?)",
               (time.time(), CONSENT_VERSION, how))
    db.commit()
    sys.stderr.write("consent recorded. This will not be asked again for this index.\n\n")


def cmd_ingest(opts):
    db = connect(opts.db)
    require_consent(db, opts)
    warn_security(db, opts.db)
    wanted = opts.source.split(",") if opts.source else SOURCES
    for name in wanted:
        if name not in ADAPTERS:
            die("unknown source '%s'. Known: %s" % (name, ", ".join(SOURCES)))

    # --full deletes every record the source did not return this run. With a
    # --limit the source returns a slice, so the two together would delete the
    # rest of the index and report it as reconciliation.
    if opts.full and opts.limit:
        die("--full and --limit together would delete everything outside the limit")

    opts._db = db
    for name in wanted:
        started = time.time()
        seen, added, updated, duplicates = set(), 0, 0, 0
        for record in ADAPTERS[name](opts):
            # 🛑 A source can return the same uid more than once with DIFFERENT
            # field values, and then each run writes a different rev and the
            # next run "updates" it back. Measured on mail: 194 Message-IDs
            # appear several times in one mailbox with different received
            # dates (the same Google DMARC report delivered three times), so
            # 474 records reported as changed on every single run, forever.
            # First occurrence wins, and the count is reported rather than
            # hidden.
            if record["uid"] in seen:
                duplicates += 1
                continue
            seen.add(record["uid"])
            # A body pass over 41k messages runs for tens of minutes. Say so.
            if len(seen) % 500 == 0:
                rate = len(seen) / max(time.time() - started, 0.001)
                sys.stderr.write("  %s: %d records, %.1f/sec\n" % (name, len(seen), rate))
                sys.stderr.flush()
            existing = db.execute(
                "SELECT rid, rev FROM record WHERE uid = ?", (record["uid"],)).fetchone()
            if existing and existing["rev"] == record["rev"]:
                continue

            # The expensive part of a record loads only once the rev check has
            # said the record is new or changed. This is what makes an
            # incremental run cheap: an unchanged message costs no subprocess.
            loader = record.pop("body_fn", None)
            if loader:
                body, people = loader()
                record["body"] = body
                record["people"] = people

            people_json = json.dumps(record.get("people") or [])
            people_text = " ".join(
                filter(None, (p.get("name") for p in record.get("people") or [])))
            row = (record["uid"], record["tool"], record["kind"], record["native_id"],
                   record.get("url"), record.get("title"), record.get("container"),
                   record.get("created"), record.get("modified"), record.get("occurred"),
                   people_json, people_text, record.get("body"), record["rev"], time.time(),
                   record.get("latitude"), record.get("longitude"))

            if existing:
                db.execute("""
                    UPDATE record SET tool=?, kind=?, native_id=?, url=?, title=?,
                      container=?, created=?, modified=?, occurred=?, people=?,
                      people_text=?, body=?, rev=?, seen_at=?,
                      latitude=?, longitude=? WHERE uid=?
                    """, row[1:] + (record["uid"],))
                db.execute("DELETE FROM chunk WHERE rid = ?", (existing["rid"],))
                rid = existing["rid"]
                updated += 1
            else:
                cur = db.execute("""
                    INSERT INTO record (uid, tool, kind, native_id, url, title, container,
                      created, modified, occurred, people, people_text, body, rev, seen_at,
                      latitude, longitude)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, row)
                rid = cur.lastrowid
                added += 1

            for ordinal, text in enumerate(chunks_for(record)):
                db.execute("INSERT INTO chunk (rid, ord, text) VALUES (?,?,?)",
                           (rid, ordinal, text))
            db.commit()

        removed = 0
        if opts.full and seen:
            # Reconciliation. A watermark finds new and changed rows; only an
            # id-set sweep finds deleted ones.
            have = {r["uid"] for r in db.execute(
                "SELECT uid FROM record WHERE tool = ?", (name,))}
            gone = have - seen
            # A source that answers with a slice looks exactly like a source
            # whose records were deleted. Refuse rather than guess: an adapter
            # bug must not empty the index quietly.
            if have and len(gone) > 0.2 * len(have) and not opts.force:
                die("%s: the source returned %d records but the index holds %d.\n"
                    "  --full would delete %d of them. That is more likely an adapter\n"
                    "  bug than %d real deletions. Re-run with --force if it is real."
                    % (name, len(seen), len(have), len(gone), len(gone)))
            for uid in gone:
                db.execute("DELETE FROM record WHERE uid = ?", (uid,))
            removed = len(gone)
            db.commit()

        total = db.execute(
            "SELECT COUNT(*) c FROM record WHERE tool = ?", (name,)).fetchone()["c"]
        db.execute("""INSERT INTO source_state (tool, watermark, records, updated)
                      VALUES (?,?,?,?)
                      ON CONFLICT(tool) DO UPDATE SET records=?, updated=?""",
                   (name, None, total, time.time(), total, time.time()))
        db.commit()
        dupe_note = "  [%d duplicate uids skipped]" % duplicates if duplicates else ""
        print("%-9s +%d ~%d -%d  (%d total, %.1fs)%s"
              % (name, added, updated, removed, total, time.time() - started, dupe_note))

    pending = db.execute("""SELECT COUNT(*) c FROM chunk c
                            LEFT JOIN vector v ON v.cid = c.cid
                            WHERE v.cid IS NULL""").fetchone()["c"]
    if pending:
        print("\n%d chunks need embedding. Run: ./index.py embed" % pending)


def cmd_rechunk(opts):
    """Rebuild chunks for a source from the bodies already stored.

    Changing the chunker must not mean re-fetching 41,000 mail bodies. The
    record table already holds every body, so a rechunk is local work.
    Deleting a chunk cascades to its vector, so the next `embed` refills them.
    """
    db = connect(opts.db)
    wanted = opts.source.split(",") if opts.source else SOURCES
    for name in wanted:
        started = time.time()
        rows = db.execute(
            "SELECT rid, kind, title, body, people FROM record WHERE tool = ?",
            (name,)).fetchall()
        before = db.execute("SELECT COUNT(*) c FROM chunk c JOIN record r ON r.rid = c.rid "
                            "WHERE r.tool = ?", (name,)).fetchone()["c"]
        db.execute("DELETE FROM chunk WHERE rid IN (SELECT rid FROM record WHERE tool = ?)",
                   (name,))
        made = 0
        for row in rows:
            # ⚠️ `kind` has to be here. chunks_for() refuses a maps visit, and
            # a rechunk that omits the field silently re-creates every chunk
            # the ingest path declines to make.
            record = {"title": row["title"], "body": row["body"], "tool": name,
                      "kind": row["kind"],
                      "people": json.loads(row["people"] or "[]")}
            for ordinal, text in enumerate(chunks_for(record)):
                db.execute("INSERT INTO chunk (rid, ord, text) VALUES (?,?,?)",
                           (row["rid"], ordinal, text))
                made += 1
        db.commit()
        print("%-9s %d records: %d chunks -> %d  (%.1fs)"
              % (name, len(rows), before, made, time.time() - started))
    pending = db.execute("""SELECT COUNT(*) c FROM chunk c
                            LEFT JOIN vector v ON v.cid = c.cid
                            WHERE v.cid IS NULL""").fetchone()["c"]
    print("\n%d chunks need embedding. Run: ./index.py embed" % pending)


def cmd_embed(opts):
    if not os.path.exists(VEC):
        die("vec is not built. Run: make -C %s" % HERE)
    connect(opts.db).close()
    if opts.model in OSS_MODELS:
        cmd = ["uv", "run", "--quiet", OSS, "embed", "--db", opts.db,
               "--model", opts.model]
    else:
        cmd = [VEC, "embed", "--db", opts.db, "--batch", str(opts.batch),
               "--model", opts.model]
    if opts.limit:
        cmd += ["--limit", str(opts.limit)]
    # 🛑 Do NOT capture stderr here. vec writes its progress there, and
    # capturing it holds every line until the process exits — which on a
    # 223k-chunk run meant 60 minutes of total silence in the log. Let stderr
    # inherit so it streams. Only stdout carries the final JSON.
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        sys.exit(proc.returncode)
    print(proc.stdout.strip())


def fts_query(text, mode, drop_stopwords=False, db=None, rare_only=0):
    """Build an FTS5 MATCH string.

    The lexical arm favours recall by default: fusion re-ranks afterwards, so a
    term that only some documents carry should still bring candidates in. That
    is the opposite of `apple mail search`, which ANDs, and it is deliberate.

    ⚠️ A descriptive question sends every word, including "who", "for" and "a".
    Those match nearly every record, so they add candidates without adding
    evidence. `drop_stopwords` removes them; `rare_only` goes further and keeps
    only terms appearing in fewer than that many records.
    """
    words = [w for w in re.findall(r"[\w']+", text) if len(w) > 1]
    if drop_stopwords:
        kept = [w for w in words if w.lower() not in STOPWORDS]
        # Never return an empty query: a question made entirely of stopwords
        # should still search for something.
        words = kept or words
    if rare_only and db is not None:
        scored = []
        for w in words:
            try:
                n = db.execute(
                    "SELECT COUNT(*) FROM record_fts WHERE record_fts MATCH ?",
                    ('"%s"' % w.replace('"', ''),)).fetchone()[0]
            except sqlite3.OperationalError:
                n = 0
            scored.append((n, w))
        kept = [w for n, w in scored if 0 < n <= rare_only]
        words = kept or [w for _, w in sorted(scored)[:3]]
    if not words:
        return None
    joiner = " AND " if mode == "and" else " OR "
    return joiner.join('"%s"' % w.replace('"', '') for w in words)


def index_fingerprint(db):
    """What the index held when a query ran.

    Cheap enough to compute on every search. A re-ingest, a rechunk or a new
    embedding model all move it, which is exactly when a cached answer becomes
    a lie.
    """
    row = db.execute("""
        SELECT (SELECT COUNT(*) FROM record),
               (SELECT COUNT(*) FROM chunk),
               (SELECT COUNT(*) FROM vector),
               (SELECT COALESCE(MAX(cid), 0) FROM chunk)""").fetchone()
    return "r%d-c%d-v%d-m%d" % tuple(row)


def search_settings(opts):
    return {"model": opts.model, "lexical_unit": opts.lexical_unit,
            "w_lexical": opts.w_lexical, "w_semantic": opts.w_semantic,
            "fts_mode": opts.fts_mode, "limit": opts.limit,
            "w_recency": opts.w_recency, "adaptive": opts.adaptive,
            "adaptive_threshold": opts.adaptive_threshold,
            "tool": opts.tool, "since": opts.since,
            "drop_stopwords": opts.drop_stopwords, "rare_only": opts.rare_only,
            "min_chunk": opts.min_chunk}


def cache_key(query, settings, fingerprint):
    blob = json.dumps({"q": query, "s": settings, "f": fingerprint}, sort_keys=True)
    return hashlib.sha1(blob.encode("utf-8")).hexdigest()


def record_query(db, query, settings, fingerprint, results, elapsed_ms, cached,
                 keep_snippets=True):
    # ⚠️ The log is a SECOND store of the same protected content: a snippet is
    # real message text. --no-snippet-log keeps the ranking and drops the text.
    if not keep_snippets:
        results = [{k: v for k, v in r.items() if k != "snippet"} for r in results]
    db.execute("""INSERT INTO query_log
                  (ts, query, settings, fingerprint, elapsed_ms, n_results, cached, results)
                  VALUES (?,?,?,?,?,?,?,?)""",
               (time.time(), query, json.dumps(settings, sort_keys=True), fingerprint,
                round(elapsed_ms, 1), len(results), 1 if cached else 0,
                json.dumps(results)))
    db.commit()


def cmd_search(opts):
    db = connect(opts.db)
    started = time.time()
    settings = search_settings(opts)
    fingerprint = index_fingerprint(db)
    key = cache_key(opts.query, settings, fingerprint)

    if not opts.no_cache:
        hit = db.execute("SELECT results, elapsed_ms FROM result_cache WHERE key = ?",
                         (key,)).fetchone()
        if hit:
            results = json.loads(hit["results"])
            record_query(db, opts.query, settings, fingerprint, results,
                         (time.time() - started) * 1000, cached=True,
                         keep_snippets=not opts.no_snippet_log)
            render(results, opts, cached=True)
            return

    pool = opts.pool or max(opts.limit * 6, 60)

    # 1. lexical
    lexical, lexical_chunk = [], {}
    match = fts_query(opts.query, opts.fts_mode,
                      drop_stopwords=opts.drop_stopwords,
                      db=db, rare_only=opts.rare_only)
    if match:
        try:
            if opts.lexical_unit == "chunk":
                seen = set()
                for row in db.execute("""
                        SELECT c.rid, c.cid, c.text FROM chunk_fts f
                        JOIN chunk c ON c.cid = f.rowid
                        JOIN record r ON r.rid = c.rid
                        WHERE chunk_fts MATCH ? AND (? IS NULL OR r.tool = ?)
                        ORDER BY bm25(chunk_fts)
                        LIMIT ?""", (match, opts.tool, opts.tool, pool * 4)):
                    if row["rid"] in seen:
                        continue
                    seen.add(row["rid"])
                    lexical.append(row["rid"])
                    lexical_chunk[row["rid"]] = row["text"]
                    if len(lexical) >= pool:
                        break
            else:
                lexical = [r["rid"] for r in db.execute("""
                    SELECT f.rowid AS rid FROM record_fts f
                    JOIN record r ON r.rid = f.rowid
                    WHERE record_fts MATCH ? AND (? IS NULL OR r.tool = ?)
                    ORDER BY bm25(record_fts, 4.0, 1.0, 2.0)
                    LIMIT ?""", (match, opts.tool, opts.tool, pool))]
        except sqlite3.OperationalError as e:
            die("FTS query failed: %s" % e)

    # 2. vector, best chunk per record
    semantic, chunk_scores, matched_chunk = [], {}, {}
    if opts.w_semantic > 0 and (opts.model in OSS_MODELS or os.path.exists(VEC)):
        # Try the warm daemon first. It holds the model and the vectors in
        # memory, which is the difference between 0.05s and 4.86s.
        served = None
        if not opts.no_daemon:
            # Always name the model. A daemon holding a different one must
            # decline, and the search then loads the right model itself.
            reply = daemon_request({"op": "search", "query": opts.query,
                                    "model": opts.model, "limit": pool * 2,
                                    "tool": opts.tool})
            if reply and not reply.get("ok") and opts.verbose:
                sys.stderr.write("daemon declined: %s\n" % reply.get("error"))
            if reply and reply.get("ok"):
                served = json.dumps(reply["hits"])
                if opts.verbose:
                    sys.stderr.write("daemon: %.1f ms\n" % reply.get("elapsed_ms", 0))

        if served is None:
            proc = subprocess.run(
                vector_search_cmd(opts.model, opts.db, opts.query, pool * 2,
                                  tool=opts.tool),
                capture_output=True, text=True)
            if opts.verbose:
                sys.stderr.write(proc.stderr)
            served = proc.stdout if proc.returncode == 0 else None

        class _Result:
            returncode = 0 if served is not None else 1
            stdout = served or "[]"
        proc = _Result()
        if proc.returncode == 0:
            best, best_text = {}, {}
            for hit in json.loads(proc.stdout):
                row = db.execute("SELECT rid, text FROM chunk WHERE cid = ?",
                                 (hit["cid"],)).fetchone()
                if not row:
                    continue
                rid = row["rid"]
                if rid not in best or hit["score"] > best[rid]:
                    best[rid] = hit["score"]
                    # 🛑 Keep the MATCHING chunk, not the record's opening. A
                    # result that ranks the right note first and then shows an
                    # unrelated first paragraph has not answered the question.
                    best_text[rid] = row["text"]
            if opts.min_chunk:
                # ⚠️ A very short chunk sits close to almost any query. Scale
                # its score down toward zero as it gets shorter than --min-chunk
                # so a bare calendar title stops outranking a real passage.
                for rid, text in best_text.items():
                    if rid in best:
                        best[rid] *= min(1.0, len(text) / float(opts.min_chunk))
            semantic = sorted(best, key=lambda r: -best[r])[:pool]
            chunk_scores = best
            matched_chunk = best_text

    # A lexical-only hit has no chunk score, so find its best chunk by term
    # overlap rather than falling back to the record's opening paragraph.
    for rid, text in lexical_chunk.items():
        matched_chunk.setdefault(rid, text)
    terms = [t.lower() for t in re.findall(r"[\w']+", opts.query) if len(t) > 1]
    for rid in lexical:
        if rid in matched_chunk or not terms:
            continue
        rows = db.execute("SELECT text FROM chunk WHERE rid = ?", (rid,)).fetchall()
        scored = [(sum(t in (r["text"] or "").lower() for t in terms), r["text"])
                  for r in rows]
        scored.sort(key=lambda x: -x[0])
        if scored and scored[0][0] > 0:
            matched_chunk[rid] = scored[0][1]

    # 3. Weighted Reciprocal Rank Fusion
    #
    # ⚠️ Equal weights assume both arms are equally trustworthy for every
    # query. Measured, they are not. A two-word keyword lookup scores highest
    # against short generic text under either embedding model: the top semantic
    # hits for "bathroom code" were "Greg Thomton / Microsoft" and "DAC MEETING
    # / Board Room". A descriptive question does much better.
    w_lex, w_sem = opts.w_lexical, opts.w_semantic
    if opts.auto_weight:
        # Content words, ignoring stopwords: a short query is a keyword lookup.
        content = [t for t in re.findall(r"[\w']+", opts.query.lower())
                   if len(t) > 2 and t not in STOPWORDS]
        if len(content) <= 2:
            w_lex, w_sem = 3.0, 1.0
        elif len(content) >= 5:
            w_lex, w_sem = 1.0, 2.0
        else:
            w_lex, w_sem = 1.5, 1.5

    def fuse(a, b):
        out = {}
        for rank, rid in enumerate(lexical):
            out[rid] = out.get(rid, 0.0) + a / (RRF_K + rank + 1)
        for rank, rid in enumerate(semantic):
            out[rid] = out.get(rid, 0.0) + b / (RRF_K + rank + 1)
        return out

    fused = fuse(w_lex, w_sem)

    # 🛑 ADAPTIVE RE-FUSE, on a signal from a field test.
    #
    # At 4:1 a lexical rank-1 hit scores 4/61 = 0.0656 and a semantic rank-1
    # hit scores 1/61 = 0.0164. A record the semantic arm matches almost
    # perfectly cannot recover from a poor LEXICAL rank. Measured: "where do
    # the kids swim" put the correct calendar event at 0.0164 with cosine
    # 0.8443, beaten 4:1 by a 2009 triathlon email that shares only the word
    # "swim" and that the semantic arm never returned at all.
    #
    # The cheap signal that tells the two regimes apart is how many of the top
    # results the SEMANTIC arm never returned. Measured over 8 field queries:
    # all four failures had 3-5 such records in the top 5, and all four wins
    # had the semantic arm present at rank 1.
    #
    # ⚠️ Re-fusing is free. Both ranked lists are already in hand, so this
    # costs no extra search and no extra model call.
    if opts.adaptive and semantic:
        head = sorted(fused, key=lambda r: -fused[r])[:5]
        uncovered = sum(1 for rid in head if rid not in chunk_scores)
        if uncovered >= opts.adaptive_threshold:
            if opts.verbose:
                sys.stderr.write(
                    "adaptive: %d of %d top hits missing from the semantic arm; "
                    "re-fusing semantic-heavy\n" % (uncovered, len(head)))
            fused = fuse(opts.adaptive_lexical, opts.adaptive_semantic)

    # 🛑 A third arm for recency, because nothing else in ranking reads a date.
    # Field-tested during a real board meeting: "where is the October board
    # meeting" returned 2023, 2025 and 2015, and the correct answer was 5 days
    # old and absent entirely. `occurred` was used only as a --since filter.
    #
    # It ranks the CANDIDATES already retrieved, so it re-orders relevant hits
    # rather than dragging in whatever is newest. ⚠️ A record with no date is
    # left out of this arm rather than ranked last, so an undated note is not
    # punished for being undated.
    if opts.w_recency > 0:
        # ⚠️ Only the HEAD of the list. Ranking every candidate by date gave a
        # full recency vote to a recent record sitting at lexical rank 200, and
        # MRR fell from 0.762 to 0.344 as the weight rose. Re-ordering the top
        # few is the intent; re-ranking the tail is not.
        head = sorted(fused, key=lambda r: -fused[r])[:opts.recency_head]
        dated = []
        for rid in head:
            row = db.execute("SELECT occurred FROM record WHERE rid = ?", (rid,)).fetchone()
            if row and row["occurred"]:
                dated.append((row["occurred"], rid))
        dated.sort(reverse=True)
        for rank, (_, rid) in enumerate(dated):
            fused[rid] = fused.get(rid, 0.0) + opts.w_recency / (RRF_K + rank + 1)

    order = sorted(fused, key=lambda r: -fused[r])
    results = []
    for rid in order:
        row = db.execute("SELECT * FROM record WHERE rid = ?", (rid,)).fetchone()
        if not row:
            continue
        # Both arms already filtered on tool. This stays as a backstop: an
        # OLDER daemon ignores the `tool` key and answers globally, and the
        # filter has to hold in that case too.
        if opts.tool and row["tool"] != opts.tool:
            continue
        if opts.since and (row["occurred"] or 0) < time.time() - opts.since * 86400:
            continue
        results.append({
            "uid": row["uid"], "tool": row["tool"], "kind": row["kind"],
            "id": row["native_id"], "url": row["url"], "title": row["title"],
            "container": row["container"],
            "date": (datetime.fromtimestamp(row["occurred"], timezone.utc).isoformat()
                     if row["occurred"] else None),
            "score": round(fused[rid], 6),
            "lexical": rid in lexical,
            "semantic": rid in semantic,
            # 🛑 null, not 0.0, when the semantic arm never returned this
            # record. Field-tested: 0.0 collapsed "absent from the semantic
            # arm" and "genuine cosine near zero" into one number, and a caller
            # could not tell them apart. There is no observed value between 0.0
            # and 0.81 on this index, so every zero was a sentinel.
            # ⚠️ It is NOT a confidence signal. On one real query the four
            # WRONG hits scored 0.838-0.846 and the only correct one was
            # absent from the semantic arm entirely. Any threshold drops it
            # first. Read it as arm coverage, never as relevance.
            "similarity": (round(chunk_scores[rid], 4) if rid in chunk_scores
                           else None),
            "snippet": re.sub(r"\s+", " ",
                              matched_chunk.get(rid) or row["body"] or "")[:240],
            "from_chunk": rid in matched_chunk,
        })
        if len(results) >= opts.limit:
            break

    elapsed_ms = (time.time() - started) * 1000
    # ⚠️ The cache is the OTHER second copy of protected content. It obeys the
    # same flag, otherwise stripping the log alone would achieve nothing.
    cached_rows = results if not opts.no_snippet_log else [
        {k: v for k, v in r.items() if k != "snippet"} for r in results]
    db.execute("""INSERT OR REPLACE INTO result_cache (key, ts, query, results, elapsed_ms)
                  VALUES (?,?,?,?,?)""",
               (key, time.time(), opts.query, json.dumps(cached_rows), round(elapsed_ms, 1)))
    record_query(db, opts.query, settings, fingerprint, results, elapsed_ms,
                 cached=False, keep_snippets=not opts.no_snippet_log)
    render(results, opts, cached=False)


def render(results, opts, cached):
    if opts.json:
        print(json.dumps(results, indent=2))
        return
    if not results:
        print("no matches")
        return

    width = shutil.get_terminal_size((100, 24)).columns
    for r in results:
        marks = ("L" if r["lexical"] else "-") + ("S" if r["semantic"] else "-")
        head = "%-9s %s %5.3f  %s" % (r["tool"], marks, r["score"], r["title"] or "(untitled)")
        print(head[:width])
        meta = "          %s  %s" % ((r["date"] or "")[:16], r["container"] or "")
        print(meta[:width].rstrip())
        if r["snippet"]:
            print(("          " + r["snippet"])[:width])
        print()
    if cached:
        print("(from cache; --no-cache to re-run)")


SECURITY_WARNING = """\
🛑 SECURITY: this index holds the PLAINTEXT of everything it reads.
   %s of decoded mail, messages, notes and contacts, in one file:
     %s
   The stores it came from are protected by Full Disk Access and 0700
   directories. This file is protected by neither, so any process running as
   you can read every email with no grant and no prompt. Revoking Full Disk
   Access does NOT disable it, and every backup copies it.
   Mitigations applied: directory 0700, file 0600, Spotlight excluded.
   Not applied: encryption, access logging, expiry.
   Remove it with:  ./index.py purge --yes        Details: lab/SECURITY.md
"""


def warn_security(db, path, force=False):
    """Say what this file is, on any command that creates or grows it.

    ⚠️ A warning that lives only in a document is a warning nobody reads. This
    prints on ingest and on status, every time, and names the real size.
    """
    try:
        size = os.path.getsize(path) / 1e6
    except OSError:
        size = 0.0
    sys.stderr.write(SECURITY_WARNING % ("%.0f MB" % size, path))
    sys.stderr.write("\n")


def cmd_daemon(opts):
    log_path = os.path.join(os.path.dirname(opts.db), "daemon.log")
    if opts.action == "status":
        reply = daemon_request({"op": "ping"}, opts.socket)
        if not reply:
            print("daemon: not running (socket %s)" % opts.socket)
            sys.exit(1)
        print("daemon: %s, %d vectors warm (%.1f MB), index %s"
              % (reply["model"], reply["vectors"], reply["megabytes"],
                 reply["fingerprint"]))
        # 🛑 Report the refresh state explicitly. Under launchd the agent has no
        # Full Disk Access, every source fails, and a loop that only watches for
        # change lines reports that as "nothing changed".
        if not reply.get("refresh_enabled", True):
            print("refresh: disabled — run `apple-index refresh` from a terminal")
        elif reply.get("refresh_error"):
            print("refresh: 🛑 FAILING (%d times). %s"
                  % (reply.get("refresh_failures", 0), reply["refresh_error"][:120]))
            print("         A launchd agent has no Full Disk Access.")
            sys.exit(2)
        elif reply.get("refresh_last_ok"):
            age = time.time() - reply["refresh_last_ok"]
            print("refresh: ok, %.0f minutes ago" % (age / 60))
        else:
            print("refresh: enabled, not yet run")
        return

    if opts.action == "stop":
        subprocess.run(["pkill", "-f", "daemon.py serve"], capture_output=True)
        if os.path.exists(opts.socket):
            os.remove(opts.socket)
        print("stopped")
        return

    if daemon_request({"op": "ping"}, opts.socket):
        print("already running")
        return
    secure_db_path(opts.db)
    with open(log_path, "a") as log_file:
        subprocess.Popen(
            ["uv", "run", "--quiet", DAEMON, "serve", "--db", opts.db,
             "--socket", opts.socket, "--model", opts.model,
             "--refresh", str(opts.refresh)],
            stdout=log_file, stderr=log_file, start_new_session=True)
    print("starting; the model takes a few seconds to load")
    print("  log:    %s" % log_path)
    print("  check:  ./index.py daemon status")


def cmd_refresh(opts):
    """Ingest, embed and reload, from a terminal that HAS Full Disk Access.

    🛑 This exists because the launchd agent does not have that grant. It
    serves searches perfectly well without one, since the index file is not
    TCC-protected, but it cannot READ the sources. So refreshing is a terminal
    job. Measured: a launchd agent failed on mail, notes and messages alike.
    """
    sources = opts.source.split(",") if opts.source else SOURCES
    changed = False
    for name in sources:
        extra = {"mail": ["--with-bodies"], "calendar": ["--since", "3650"],
                 "messages": ["--chat-limit", "1331", "--limit", "2000"],
                 "notes": [], "contacts": ["--limit", "100000"]}[name]
        # ⚠️ --db is a flag on the MAIN parser, so it must come BEFORE the
        # subcommand. Putting it after gives "unrecognized arguments".
        proc = subprocess.run([sys.executable, __file__, "--db", opts.db, "ingest",
                               "--source", name] + extra,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            print("🛑 %s FAILED: %s" % (name, proc.stderr.strip().splitlines()[-1:]))
            continue
        for line in proc.stdout.splitlines():
            if line.startswith(name):
                print("  " + line.strip())
                if " +0 ~0 -0 " not in line:
                    changed = True

    if changed:
        print("embedding new chunks ...")
        subprocess.run([sys.executable, __file__, "--db", opts.db, "embed",
                        "--model", opts.model])
    reply = daemon_request({"op": "reload"})
    print("daemon reloaded" if reply and reply.get("ok")
          else "daemon not running (nothing to reload)")


def cmd_purge(opts):
    """Delete the index, or just the logs. The closest thing to a revocation."""
    targets = [opts.db, opts.db + "-wal", opts.db + "-shm"]
    if opts.logs_only:
        db = connect(opts.db)
        n_log = db.execute("SELECT COUNT(*) c FROM query_log").fetchone()["c"]
        n_cache = db.execute("SELECT COUNT(*) c FROM result_cache").fetchone()["c"]
        if not opts.yes and not confirm(
                "Delete %d logged queries and %d cached results?" % (n_log, n_cache)):
            print("cancelled")
            return
        db.execute("DELETE FROM query_log")
        db.execute("DELETE FROM result_cache")
        db.commit()
        db.execute("VACUUM")
        print("deleted %d logged queries and %d cached results" % (n_log, n_cache))
        return

    size = sum(os.path.getsize(t) for t in targets if os.path.exists(t)) / 1e6
    if not os.path.exists(opts.db):
        print("nothing to purge at %s" % opts.db)
        return
    if not opts.yes and not confirm(
            "Delete the whole index (%.0f MB) at %s?" % (size, opts.db)):
        print("cancelled")
        return
    for t in targets:
        if os.path.exists(t):
            os.remove(t)
    print("purged %.0f MB. Re-create it with: ./index.py init" % size)


def confirm(question):
    if not sys.stdin.isatty():
        die("refusing to delete without a terminal. Pass --yes if you mean it.")
    return input("%s [y/N] " % question).strip().lower() in ("y", "yes")


def cmd_history(opts):
    """What was searched, with what settings, and what came back."""
    db = connect(opts.db)
    if opts.show:
        row = db.execute("SELECT * FROM query_log WHERE qid = ?", (opts.show,)).fetchone()
        if not row:
            die("no query %d" % opts.show)
        print("query      %s" % row["query"])
        print("when       %s" % datetime.fromtimestamp(row["ts"]).isoformat(" ", "seconds"))
        print("settings   %s" % row["settings"])
        print("index      %s%s" % (row["fingerprint"], "   (served from cache)" if row["cached"] else ""))
        print("took       %.0f ms, %d results\n" % (row["elapsed_ms"] or 0, row["n_results"]))
        for i, r in enumerate(json.loads(row["results"]), 1):
            marks = ("L" if r.get("lexical") else "-") + ("S" if r.get("semantic") else "-")
            print("  %2d. %-9s %s %.3f  %s" % (i, r["tool"], marks, r["score"],
                                               (r["title"] or "(untitled)")[:52]))
            if r.get("snippet"):
                print("      %s" % r["snippet"][:100])
        return

    where, args = "", []
    if opts.query:
        where, args = "WHERE query LIKE ?", ["%" + opts.query + "%"]
    rows = db.execute("""SELECT qid, ts, query, n_results, elapsed_ms, cached, settings,
                                fingerprint
                         FROM query_log %s ORDER BY ts DESC LIMIT ?""" % where,
                      args + [opts.limit]).fetchall()
    if not rows:
        print("no queries recorded")
        return
    print("%-5s %-17s %5s %6s %-5s %s" % ("qid", "when", "hits", "ms", "cache", "query"))
    for r in rows:
        cfg = json.loads(r["settings"])
        print("%-5d %-17s %5d %6.0f %-5s %s"
              % (r["qid"], datetime.fromtimestamp(r["ts"]).strftime("%m-%d %H:%M:%S"),
                 r["n_results"], r["elapsed_ms"] or 0, "hit" if r["cached"] else "-",
                 r["query"][:44]))
        if opts.verbose:
            print("      model=%s unit=%s w=%.1f:%.1f fts=%s  index=%s"
                  % (cfg.get("model"), cfg.get("lexical_unit"), cfg.get("w_lexical"),
                     cfg.get("w_semantic"), cfg.get("fts_mode"), r["fingerprint"]))
    print("\n./index.py history --show <qid>   for the full result list")


def cmd_cache(opts):
    db = connect(opts.db)
    if opts.clear:
        n = db.execute("SELECT COUNT(*) c FROM result_cache").fetchone()["c"]
        db.execute("DELETE FROM result_cache")
        db.commit()
        print("cleared %d cached results" % n)
        return
    rows = db.execute("""SELECT COUNT(*) n, MIN(ts) oldest, AVG(elapsed_ms) avg_ms
                         FROM result_cache""").fetchone()
    print("%d cached results" % rows["n"])
    if rows["n"]:
        print("oldest %s, mean uncached time %.0f ms"
              % (datetime.fromtimestamp(rows["oldest"]).isoformat(" ", "seconds"),
                 rows["avg_ms"] or 0))
    log = db.execute("""SELECT COUNT(*) n, SUM(cached) hits FROM query_log""").fetchone()
    if log["n"]:
        print("%d queries logged, %d served from cache (%.0f%%)"
              % (log["n"], log["hits"] or 0, 100.0 * (log["hits"] or 0) / log["n"]))


# --------------------------------------------------------------------------
# geography
#
# 🛑 ONLY a record that already carries a real coordinate can be placed. The
# index never geocodes a stored `location` string after the fact, and neither
# does EventKit, the server, or Calendar.app. A calendar event has a
# coordinate only when it was written with `apple calendar add --at`, which is
# 617 of the 11,379 events here. Every `apple maps` record has one.
#
# ⚠️ So "nothing found near X" means "nothing INDEXED WITH A COORDINATE is near
# X". It is not evidence the user was not there. Every command below reports
# how many records it could actually place, so that gap is never silent.
# --------------------------------------------------------------------------

EARTH_KM = 6371.0088


def haversine(lat1, lon1, lat2, lon2):
    """Great-circle distance in kilometres.

    ⚠️ Not a flat-earth approximation. A degree of longitude is 111 km at the
    equator and 85 km at Boulder's latitude, so comparing raw degree deltas
    stretches every east-west distance by a third here, and by more further
    north.
    """
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = (math.sin(dp / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return 2 * EARTH_KM * math.asin(min(1.0, math.sqrt(a)))


def resolve_place(db, text):
    """A place name to (lat, lon, label, source).

    Local first, and the local answer is usually the BETTER one: "costco"
    means the branch the user goes to, not whichever branch Apple ranks first.
    The index already holds every visited place with its coordinate, so this
    normally costs no network call at all.

    🛑 The fallback is `apple maps geocode`, which LEAVES THE MACHINE. It is
    the only network call anywhere in this lab, and `--local-only` refuses it.
    """
    pair = re.match(r"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$", text)
    if pair:
        return float(pair.group(1)), float(pair.group(2)), text, "coordinate"

    rows = db.execute("""
        SELECT title, latitude, longitude, occurred FROM record
        WHERE tool = 'maps' AND kind = 'place' AND latitude IS NOT NULL
          AND lower(title) LIKE ?
        ORDER BY occurred DESC""", ("%" + text.lower() + "%",)).fetchall()
    if rows:
        r = rows[0]
        return r["latitude"], r["longitude"], r["title"], "visited-place"
    return None


def geocode_place(text, local_only):
    if local_only:
        die("'%s' is not a place you have visited, and --local-only refuses "
            "the network." % text)
    hits = apple("maps", "geocode", text, "--json", allow_fail=True)
    if not hits:
        die("could not resolve '%s' to a coordinate." % text)
    top = hits[0]
    return (top["latitude"], top["longitude"], top.get("name") or text,
            top.get("source") or "maps-search")


def placed_rows(db, tool=None, since=None, kind=None, past=False):
    sql = ["SELECT rid, uid, tool, kind, native_id, title, container, occurred,"
           " latitude, longitude FROM record WHERE latitude IS NOT NULL"]
    args = []
    if tool:
        sql.append("AND tool = ?")
        args.append(tool)
    if kind:
        sql.append("AND kind = ?")
        args.append(kind)
    if since:
        sql.append("AND occurred >= ?")
        args.append(time.time() - since * 86400)
    # ⚠️ `--since N` alone means "from N days ago ONWARD", and a calendar holds
    # recurring events years into the future. Asking which events the user
    # ATTENDED is a question about the past, so it needs this as well.
    if past:
        sql.append("AND occurred <= ?")
        args.append(time.time())
    sql.append("ORDER BY occurred DESC")
    return db.execute(" ".join(sql), args).fetchall()


def coverage(db, tool=None):
    """How many records of a source could be placed at all."""
    where = "WHERE tool = ?" if tool else ""
    args = (tool,) if tool else ()
    row = db.execute("SELECT COUNT(*) n, SUM(latitude IS NOT NULL) c "
                     "FROM record " + where, args).fetchone()
    return row["c"] or 0, row["n"] or 0


def cmd_near(opts):
    """Everything indexed within --radius km of a place."""
    db = connect(opts.db)
    found = resolve_place(db, opts.place)
    if not found:
        found = geocode_place(opts.place, opts.local_only)
    lat, lon, label, source = found

    # 🛑 COLLAPSE BEFORE THE LIMIT, or the limit hides everything further away.
    # A weekly class is one calendar event per occurrence at ONE coordinate, and
    # a maps place plus its visits are more records at that same coordinate.
    # Measured: `near "Ocean First" --radius 1` filled all 50 result slots with
    # identical "Swim lessons" events at 0.000 km, and dropped two real
    # neighbours 0.585 km and 0.705 km away. The bug was invisible in the output
    # — 50 rows came back and every one of them was true.
    kept = {}
    for row in placed_rows(db, opts.tool, opts.since, past=opts.past):
        km = haversine(lat, lon, row["latitude"], row["longitude"])
        if km > opts.radius:
            continue
        key = (row["tool"], (row["title"] or "").strip())
        best = kept.get(key)
        if best is None:
            kept[key] = {"row": row, "km": km, "count": 1}
        else:
            best["count"] += 1
            # Keep the NEWEST of a repeated title. "when was I last there" is
            # the question a repeated place is usually asked about.
            if (row["occurred"] or 0) > (best["row"]["occurred"] or 0):
                best["row"], best["km"] = row, km

    out = []
    for entry in kept.values():
        row = entry["row"]
        out.append({
            "uid": row["uid"], "tool": row["tool"], "kind": row["kind"],
            "id": row["native_id"], "title": row["title"],
            "container": row["container"],
            "count": entry["count"],
            "date": (datetime.fromtimestamp(row["occurred"], timezone.utc).isoformat()
                     if row["occurred"] else None),
            "km": round(entry["km"], 3),
            "latitude": row["latitude"], "longitude": row["longitude"],
        })
    out.sort(key=lambda r: r["km"])
    out = out[:opts.limit]

    placed, total = coverage(db, opts.tool)
    if opts.json:
        print(json.dumps({
            "origin": {"query": opts.place, "name": label, "latitude": lat,
                       "longitude": lon, "source": source},
            "radius_km": opts.radius,
            "placed_records": placed, "total_records": total,
            "results": out}, indent=2))
        return
    print("%s  %.5f,%.5f  (%s)" % (label, lat, lon, source))
    print("within %g km — searching %d of %d records that carry a coordinate\n"
          % (opts.radius, placed, total))
    for r in out:
        tail = "  (x%d)" % r["count"] if r["count"] > 1 else ""
        print("%-9s %6.2f km  %-10s %s%s"
              % (r["tool"], r["km"], (r["date"] or "")[:10], r["title"], tail))
    if not out:
        print("nothing placed within %g km." % opts.radius)


def collapse(members):
    """One line per distinct thing in a group, newest first.

    ⚠️ A maps PLACE and a maps VISIT to it are two records at one coordinate,
    and a place's date is its LATEST visit — so the same arrival appears twice
    and reads as two separate trips. A recurring calendar event repeats the
    same title too. Both are collapsed on (tool, title), and `count` says how
    many records the line stands for.
    """
    groups = {}
    for m in members:
        key = (m["tool"], m["title"] or "")
        keep = groups.get(key)
        if keep is None or (m["occurred"] or 0) > (keep["occurred"] or 0):
            groups[key] = dict(m)
            groups[key]["count"] = (keep or {}).get("count", 0) + 1
        else:
            keep["count"] = keep.get("count", 1) + 1
    out = [{
        "uid": m["uid"], "tool": m["tool"], "kind": m["kind"],
        "id": m["native_id"], "title": m["title"],
        "count": m.get("count", 1),
        "date": (datetime.fromtimestamp(m["occurred"], timezone.utc).isoformat()
                 if m["occurred"] else None),
    } for m in groups.values()]
    out.sort(key=lambda r: (r["date"] or ""), reverse=True)
    return out


def cmd_nearby(opts):
    """Group placed records that sit close to each other.

    Single-link clustering: two records join the same group when they are
    within --radius km. ⚠️ That means a group can be WIDER than the radius, a
    chain of overlapping pairs. The reported `span_km` is the real width, so
    read that rather than assuming the radius bounds it.
    """
    db = connect(opts.db)
    rows = placed_rows(db, opts.tool, opts.since, opts.kind, past=opts.past)
    if opts.limit:
        rows = rows[:opts.limit]

    parent = list(range(len(rows)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            if haversine(rows[i]["latitude"], rows[i]["longitude"],
                         rows[j]["latitude"], rows[j]["longitude"]) <= opts.radius:
                a, b = find(i), find(j)
                if a != b:
                    parent[a] = b

    groups = {}
    for i, row in enumerate(rows):
        groups.setdefault(find(i), []).append(row)

    out = []
    for members in groups.values():
        if len(members) < opts.min_size:
            continue
        span = 0.0
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                span = max(span, haversine(
                    members[i]["latitude"], members[i]["longitude"],
                    members[j]["latitude"], members[j]["longitude"]))
        out.append({
            "count": len(members),
            "span_km": round(span, 3),
            "latitude": round(sum(m["latitude"] for m in members) / len(members), 6),
            "longitude": round(sum(m["longitude"] for m in members) / len(members), 6),
            "records": collapse(members),
        })
    out.sort(key=lambda g: -g["count"])

    placed, total = coverage(db, opts.tool)
    if opts.json:
        print(json.dumps({"radius_km": opts.radius, "groups": out,
                          "placed_records": placed,
                          "total_records": total}, indent=2))
        return
    print("grouping %d placed records (of %d indexed) within %g km\n"
          % (len(rows), total, opts.radius))
    for g in out:
        print("%d records, %.2f km across, near %.5f,%.5f"
              % (g["count"], g["span_km"], g["latitude"], g["longitude"]))
        for m in g["records"][:opts.show]:
            tail = "  (x%d)" % m["count"] if m["count"] > 1 else ""
            print("    %-9s %-10s %s%s"
                  % (m["tool"], (m["date"] or "")[:10], m["title"], tail))
        if len(g["records"]) > opts.show:
            print("    ... and %d more" % (len(g["records"]) - opts.show))
        print("")
    if not out:
        print("no group of %d or more within %g km." % (opts.min_size, opts.radius))


def cmd_status(opts):
    db = connect(opts.db)
    warn_security(db, opts.db)
    row = db.execute("SELECT granted_at, how FROM consent ORDER BY granted_at").fetchone()
    if row:
        print("consent given %s (%s)\n"
              % (datetime.fromtimestamp(row["granted_at"]).isoformat(" ", "seconds"),
                 row["how"]))
    else:
        print("no consent recorded; `apple-index ingest` will ask\n")
    rows = db.execute("""
        SELECT tool, COUNT(*) records,
               SUM((SELECT COUNT(*) FROM chunk WHERE chunk.rid = record.rid)) chunks
        FROM record GROUP BY tool ORDER BY tool""").fetchall()
    if not rows:
        print("index is empty. Run: ./index.py ingest --source notes --limit 50")
        return
    print("%-10s %8s %8s" % ("tool", "records", "chunks"))
    for r in rows:
        print("%-10s %8d %8d" % (r["tool"], r["records"], r["chunks"] or 0))
    total = db.execute("SELECT COUNT(*) c FROM chunk").fetchone()["c"]
    # ⚠️ Report per model. A single count against one hard-coded model reported
    # "437 pending" while the default model was fully embedded.
    per_model = db.execute(
        "SELECT model, COUNT(*) c FROM vector GROUP BY model ORDER BY model").fetchall()
    vectors = max([r["c"] for r in per_model] or [0])
    size = os.path.getsize(opts.db) / 1e6
    print()
    for r in per_model:
        print("%d chunks, %d embedded as %s, %d pending"
              % (total, r["c"], r["model"], total - r["c"]))
    print("%.1f MB at %s" % (size, opts.db))
    # ⚠️ Quote the rate for the model that is actually behind. A single
    # hardcoded 41 chunks/sec came from Apple's model and told a caller "52
    # minutes" for an e5-small backlog that finished in 5.
    RATES = {"e5-small-v1": 450.0, "e5-base-v1": 133.0,
             "sentence-v1": 60.0, "contextual-v1": 60.0}
    for r in per_model:
        pending = total - r["c"]
        if pending > 0:
            rate = RATES.get(r["model"], 60.0)
            print("~%.1f min to embed the %s backlog at ~%.0f chunks/sec"
                  % (pending / rate / 60, r["model"], rate))


# --------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--db", default=DEFAULT_DB)
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("init", help="create the schema").set_defaults(func=cmd_init)

    g = sub.add_parser("ingest", help="read a source through the apple CLI")
    g.add_argument("--source", help="comma separated: " + ",".join(SOURCES))
    g.add_argument("--limit", type=int, help="records per source")
    g.add_argument("--since", type=int, help="days back (mail, calendar)")
    g.add_argument("--with-bodies", action="store_true",
                   help="mail only: fetch each body. One subprocess per message.")
    g.add_argument("--chat-limit", type=int, default=50, help="messages: chats to walk")
    g.add_argument("--message-block", type=int, default=10,
                   help="messages: how many messages make one record")
    g.add_argument("--accept-risk", action="store_true", dest="accept_risk",
                   help="consent to building the index without a prompt")
    g.add_argument("--full", action="store_true",
                   help="also delete records the source no longer has")
    g.add_argument("--force", action="store_true",
                   help="with --full: allow a deletion of more than 20%% of a source")
    g.set_defaults(func=cmd_ingest)

    rc = sub.add_parser("rechunk", help="rebuild chunks from stored bodies")
    rc.add_argument("--source", help="comma separated; default all")
    rc.set_defaults(func=cmd_rechunk)

    e = sub.add_parser("embed", help="embed every chunk that has no vector")
    e.add_argument("--limit", type=int)
    e.add_argument("--batch", type=int, default=500)
    e.add_argument("--model", default="e5-small", choices=list(ALL_MODELS))
    e.set_defaults(func=cmd_embed)

    s = sub.add_parser("search", help="hybrid search over everything indexed")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=10)
    s.add_argument("--tool")
    s.add_argument("--since", type=int, help="days back")
    s.add_argument("--fts-mode", choices=["and", "or"], default="or")
    s.add_argument("--json", action="store_true")
    s.add_argument("--verbose", action="store_true")
    s.add_argument("--no-cache", action="store_true", dest="no_cache",
                   help="ignore a cached result and re-run the search")
    s.add_argument("--no-daemon", action="store_true", dest="no_daemon",
                   help="ignore the warm daemon and load the model per query")
    s.add_argument("--no-snippet-log", action="store_true", dest="no_snippet_log",
                   help="log rankings without the result text (see SECURITY.md)")
    # Measured over eval.py's 14 cases, daemon warm, identical conditions:
    #   e5-small  MRR 0.786   212-296 ms   661 MB RSS    9 min to index
    #   e5-base   MRR 0.774   212 ms       948 MB RSS   30 min to index
    #   apple     MRR 0.738   160 ms       n/a          66 min to index
    # ⚠️ e5-base has the BETTER vector arm (0.729 vs 0.631), but at 3:1 the
    # lexical arm dominates and that advantage never reaches the ranking. The
    # 0.012 hybrid gap is under one case in fourteen, so read the quality as a
    # tie and the resources as the deciding factor. See MODELS.md.
    s.add_argument("--model", default="e5-small", choices=list(ALL_MODELS),
                   help="which embedding model's vectors to search")
    # Measured over eval.py's 13 cases (MRR): lexical-only 0.565, semantic-only
    # 0.269, equal 1:1 0.562, 2:1 and 3:1 both 0.602, 5:1 and 10:1 0.563.
    # 🛑 The vector arm earns its place only as a MINORITY vote. Equal weighting
    # scores no better than ignoring it. ⚠️ 13 cases is a small set, so read the
    # 1:1 vs 3:1 gap as suggestive; the semantic-only result is decisive.
    # Measured over eval.py's 16 cases (MRR / hit@3): 3:1 0.762/0.81,
    # 4:1 and 5:1 both 0.771/0.88, 6:1 0.750, 12:1 0.690, lexical-only 0.674.
    # 4:1 is the lower of the two tied best. Raised from 3:1 after a field test
    # found multi-token verbatim queries beating a surname collision by only
    # 0.0127.
    s.add_argument("--w-lexical", type=float, default=4.0, dest="w_lexical")
    s.add_argument("--w-semantic", type=float, default=1.0, dest="w_semantic")
    s.add_argument("--recency-head", type=int, default=10, dest="recency_head",
                   help="how many top candidates the recency arm re-orders")
    s.add_argument("--pool", type=int, default=0,
                   help="candidates each arm retrieves before fusion "
                        "(0 = max(limit*6, 60))")
    s.add_argument("--w-recency", type=float, default=0.0, dest="w_recency",
                   help="weight of a third arm ranking candidates newest first")
    # Measured over eval.py's 28 cases (MRR / hit@10): off 0.589/0.64,
    # threshold 2 or 3 0.602/0.71, threshold 4 0.620/0.71, threshold 5
    # 0.607/0.64. The re-fuse target barely matters — 1:2, 1:3 and 0:1 all tie
    # at threshold 4 — so the TRIGGER is the whole mechanism.
    s.add_argument("--no-adaptive", action="store_false", dest="adaptive",
                   help="do not re-fuse even when the lexical arm dominates")
    s.add_argument("--adaptive-threshold", type=int, default=4,
                   dest="adaptive_threshold",
                   help="how many of the top 5 must be missing from the "
                        "semantic arm before re-fusing")
    s.add_argument("--adaptive-lexical", type=float, default=1.0,
                   dest="adaptive_lexical")
    s.add_argument("--adaptive-semantic", type=float, default=2.0,
                   dest="adaptive_semantic")
    s.add_argument("--auto-weight", action="store_true", dest="auto_weight",
                   help="pick the weights from the query's shape")
    # Measured (MRR over eval.py's 13 cases): record-level 0.602, chunk-level
    # 0.679. Ranking chunks puts both arms on the same unit and stops a passing
    # mention in a long email beating a short record that is entirely the answer.
    s.add_argument("--lexical-unit", choices=["record", "chunk"], default="chunk",
                   dest="lexical_unit",
                   help="rank the lexical arm over whole records or over chunks")
    s.add_argument("--drop-stopwords", action="store_true", dest="drop_stopwords",
                   help="strip stopwords from the LEXICAL query only")
    s.add_argument("--rare-only", type=int, default=0, dest="rare_only",
                   help="keep only lexical terms in fewer than N records")
    s.add_argument("--min-chunk", type=int, default=0, dest="min_chunk",
                   help="scale down the score of chunks shorter than this")
    s.set_defaults(func=cmd_search)

    h = sub.add_parser("history", help="what was searched, and what came back")
    h.add_argument("--limit", type=int, default=25)
    h.add_argument("--query", help="only queries containing this text")
    h.add_argument("--show", type=int, help="print one query's full result list")
    h.add_argument("--verbose", action="store_true", help="show the settings per row")
    h.set_defaults(func=cmd_history)

    c = sub.add_parser("cache", help="result cache stats, or clear it")
    c.add_argument("--clear", action="store_true")
    c.set_defaults(func=cmd_cache)

    d = sub.add_parser("daemon", help="start, stop or query the warm daemon")
    d.add_argument("action", choices=["start", "stop", "status"])
    d.add_argument("--model", default="e5-small")
    d.add_argument("--refresh", type=int, default=300)
    d.add_argument("--socket", default=DEFAULT_SOCKET)
    d.set_defaults(func=cmd_daemon)

    rf = sub.add_parser("refresh",
                        help="ingest, embed and reload — run this from a terminal")
    rf.add_argument("--source", help="comma separated; default all")
    rf.add_argument("--model", default="e5-small", choices=list(ALL_MODELS))
    rf.set_defaults(func=cmd_refresh)

    pu = sub.add_parser("purge", help="delete the index, or just the logs")
    pu.add_argument("--yes", action="store_true", help="do not ask")
    pu.add_argument("--logs-only", action="store_true", dest="logs_only",
                    help="keep the index, drop query_log and result_cache")
    pu.set_defaults(func=cmd_purge)

    n = sub.add_parser("near", help="everything indexed near a place")
    n.add_argument("place", help="a place name, an address, or \"lat,lon\"")
    n.add_argument("--radius", type=float, default=1.0,
                   help="kilometres (default 1)")
    n.add_argument("--tool", help="restrict to one source")
    n.add_argument("--since", type=int, help="only records this many days back")
    n.add_argument("--past", action="store_true",
                   help="exclude anything dated in the future")
    n.add_argument("--limit", type=int, default=50)
    n.add_argument("--local-only", action="store_true", dest="local_only",
                   help="refuse the geocoding network call")
    n.add_argument("--json", action="store_true")
    n.set_defaults(func=cmd_near)

    nb = sub.add_parser("nearby", help="group placed records that sit close together")
    nb.add_argument("--radius", type=float, default=1.0,
                    help="kilometres that join two records (default 1)")
    nb.add_argument("--tool", help="restrict to one source")
    nb.add_argument("--kind", help="restrict to one kind (event, place, visit)")
    nb.add_argument("--since", type=int, help="only records this many days back")
    nb.add_argument("--past", action="store_true",
                    help="exclude anything dated in the future")
    nb.add_argument("--min-size", type=int, default=2, dest="min_size",
                    help="smallest group to report (default 2)")
    nb.add_argument("--show", type=int, default=6,
                    help="records to print per group")
    nb.add_argument("--limit", type=int, default=2000,
                    help="cap the records compared; the pairing is O(n^2)")
    nb.add_argument("--json", action="store_true")
    nb.set_defaults(func=cmd_nearby)

    sub.add_parser("status", help="what is indexed").set_defaults(func=cmd_status)

    opts = p.parse_args()
    opts.func(opts)


if __name__ == "__main__":
    main()
