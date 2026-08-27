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
import fcntl
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
# ⚠️ Two layouts. In the checkout `vec` is a SwiftPM build product; in an
# install it sits next to this file. Try the checkout first so `make dev`
# behaviour does not change.
VEC = next((candidate for candidate in
            (os.path.join(HERE, "vec", ".build", "release", "vec"),
             os.path.join(HERE, "vec"))
            if os.path.isfile(candidate)),
           os.path.join(HERE, "vec", ".build", "release", "vec"))
OSS = os.path.join(HERE, "embed_oss.py")
DAEMON = os.path.join(HERE, "daemon.py")
COREML = os.path.join(HERE, "coreml", "coreml_embed.py")


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
# The same weights as `e5-small`, converted to Core ML and run with no PyTorch.
# 🛑 Its vectors go in under their own name, `e5-small-coreml-v1`, because two
# models never share a vector space — and a converted model is a second model
# until its parity is measured. See coreml/BAKEOFF.md.
COREML_MODELS = ("e5-small-coreml",)
ALL_MODELS = APPLE_MODELS + OSS_MODELS + COREML_MODELS


def vector_search_cmd(model, db, query, limit, tool=None):
    if model in COREML_MODELS:
        # 🛑 The Swift binary, not `uv run`. The Core ML path needs no PyTorch
        # and no virtualenv; coreml/coreml_embed.py is kept only as the
        # reference the Swift port is measured against.
        #
        # ⚠️ `INDEX_COREML_PY=1` runs that reference instead, which is the only
        # way to tell a Swift regression apart from a change in the index.
        if os.environ.get("INDEX_COREML_PY"):
            cmd = ["uv", "run", "--quiet", COREML, "search", "--db", db,
                   "--query", query, "--limit", str(limit)]
        else:
            cmd = [VEC, "search", "--db", db, "--query", query,
                   "--model", model, "--limit", str(limit)]
    elif model in OSS_MODELS:
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
_SUPPORT = os.path.expanduser("~/Library/Application Support/apple-tools")
# 🛑 The app moves the index into an ENCRYPTED disk image, mounted at
# `<support>/mnt`. Both paths must work: an install that has never run the app
# still has the plaintext file, and the app deletes it only after verifying the
# copy. Prefer the vault whenever it is mounted.
#
# ⚠️ When the image exists and nothing is mounted, the index is LOCKED, not
# missing. `require_index` says so rather than offering to rebuild 812 MB the
# user already has.
VAULT_DB = os.path.join(_SUPPORT, "mnt", "lab-index.db")
VAULT_IMAGE = os.path.join(_SUPPORT, "index.sparsebundle")
PLAIN_DB = os.path.join(_SUPPORT, "lab-index.db")

DEFAULT_DB = os.path.expanduser(
    os.environ.get("APPLE_INDEX_DB",
                   VAULT_DB if os.path.exists(VAULT_DB) else PLAIN_DB))


def require_index(path):
    """Explain a locked index instead of treating it as an empty one."""
    if os.path.exists(path):
        return
    # 🛑 ONLY THE REAL INDEX CAN BE LOCKED. This fired on ANY path that did not
    # exist yet, so once the app had built a vault every scratch database was
    # reported as an encrypted index needing AppleTools to be opened — which
    # broke `make bench`, whose whole design is a second database under
    # `APPLE_INDEX_DB`, and any `--db` pointed somewhere new. A path the user
    # named is a path to create, not a vault to unlock.
    #
    # ⚠️ BOTH DEFAULT PATHS, NOT JUST THE VAULT ONE. Testing `path == VAULT_DB`
    # alone was wrong in the exact case this message exists for: when nothing
    # is mounted, `DEFAULT_DB` resolves to the PLAIN path, so the real index
    # asked about itself and was told to run `init` — which would build a
    # second, empty index beside the encrypted one it could not see.
    if path in (VAULT_DB, PLAIN_DB) and os.path.exists(VAULT_IMAGE):
        die("the index is locked. It lives in an encrypted image that only "
            "AppleTools.app mounts.\n"
            "  Open AppleTools, then try again.\n"
            "  If you deleted the key on purpose, the index is gone for good "
            "and `apple-index refresh` rebuilds it.")

# 🛑 The socket lives in the 0700 index directory at mode 0600, never on a TCP
# port. A port would put the whole mail corpus one bad bind address away from
# the network.
DEFAULT_SOCKET = os.path.join(os.path.dirname(DEFAULT_DB), "index.sock")


# ⚠️ A DIRECTORY LISTING, NOT A TCC QUERY. There is no API that reports Full
# Disk Access. Reading a protected directory is the only honest probe, and
# `~/Library/Mail` is protected on every macOS that has Mail.
FDA_PROBE = os.path.expanduser("~/Library/Mail")


def full_disk_access():
    """True when this process can still read a protected store."""
    try:
        os.listdir(FDA_PROBE)
        return True
    except PermissionError:
        return False
    except OSError:
        # No Mail on this machine. Absence is not a denial, so do not claim one.
        return True


def cmd_enable(opts):
    """Record consent, after showing exactly what the index will hold."""
    if has_consent() and not opts.again:
        print("already enabled (%s)" % CONSENT_PATH)
        return
    print(CONSENT_TEXT % {"db": opts.db})
    if not opts.yes:
        if not sys.stdin.isatty():
            die("refusing to enable without a terminal. Pass --yes if you mean it.")
        answer = input("Type 'index my data' to agree: ").strip().lower()
        if answer != "index my data":
            print("cancelled; nothing was written")
            return
    secure_db_path(opts.db)
    with open(CONSENT_PATH, "w") as handle:
        handle.write("agreed %s\n" % time.strftime("%Y-%m-%dT%H:%M:%S"))
    os.chmod(CONSENT_PATH, 0o600)
    print("enabled. Build the index with: apple-index refresh")


def cmd_forget(opts):
    """Delete everything this tool ever wrote, and stop the daemon.

    🛑 This is the revocation path `SECURITY.md` demands. It removes the index,
    the write-ahead log, the socket, the daemon log and the consent record, so
    the next run starts from nothing and asks again.
    """
    targets = [opts.db, opts.db + "-wal", opts.db + "-shm",
               os.path.join(os.path.dirname(opts.db), "daemon.log"),
               DEFAULT_SOCKET]
    present = [t for t in targets if os.path.exists(t)]
    size = sum(os.path.getsize(t) for t in present
               if os.path.isfile(t)) / 1e6
    if not present:
        print("nothing to forget")
        return
    if not opts.yes and not confirm(
            "Delete the index and every trace of it (%.0f MB)?" % size):
        print("cancelled")
        return
    daemon_request({"op": "stop"})
    for pattern in ("daemon.py serve", "vec daemon"):
        subprocess.run(["pkill", "-f", pattern], capture_output=True)
    for target in present:
        try:
            os.remove(target)
        except OSError as error:
            print("could not remove %s: %s" % (target, error))
    # ⚠️ The consent record lives in the `consent` TABLE, so deleting the
    # database withdraws it and the next ingest asks again.
    print("forgotten. %.0f MB deleted, consent withdrawn." % size)
    print("⚠️  A backup may still hold a copy. This cannot reach one.")


def warn_if_revoked(opts):
    """Say so when the grant is gone but the index remains.

    ⚠️ A user who revokes Full Disk Access expects their mail to stop being
    readable. The index keeps answering, because it is an ordinary file. Saying
    nothing here is the behaviour `SECURITY.md` calls out by name.
    """
    if not os.path.exists(opts.db) or full_disk_access():
        return
    sys.stderr.write(
        "🛑 Full Disk Access is gone, and the index is still here.\n"
        "   It still holds the plaintext of everything indexed before now.\n"
        "   Delete it with: apple-index forget\n")


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
# 🛑 THE CAP IS PER SOURCE, and 20 was silently losing most of a long document.
# Chunks are taken from the FRONT, so a capped record embeds its first ~15,000
# characters and nothing else. Measured 2026-08-25: `COPTA Bylaws.md` produced
# 162 chunks uncapped and the index held 20 — Sections 5, 6 and 7 of a real
# governance document were unreachable by the vector arm. One 112 KB meeting
# transcript had 13% of its text embedded.
#
# ⚠️ `record_fts` holds the FULL body, so only the SEMANTIC arm is blinded.
# That is the arm a paraphrase needs, which is why the loss was invisible: a
# lexical hit still returned something plausible.
#
# 🛑 RAISING IT GLOBALLY IS WORSE THAN LEAVING IT ALONE. Measured over the
# 37-case suite: files-only 200 scores 0.535 against a 0.541 baseline (noise),
# while raising EVERY source to 200 scores 0.511. Mail is 81% of the chunks
# here, and 1,608 mail records sit at the cap; letting each contribute ten
# times as many candidates dilutes every other query. A full re-embed also
# costs 334s against 23s for files alone.
#
# ⚠️ The suite CANNOT see the benefit, by construction. `eval.py`'s resolve()
# reads `chunk.text`, so a locator past the cap does not resolve and the case
# is unwritable at the low cap. The benefit was measured separately: two
# questions answered only past chunk 20 went from MISS to RANK 1.
MAX_CHUNKS_PER_RECORD = 20
MAX_CHUNKS_BY_SOURCE = {
    # Long-form documents the user writes and keeps: an Obsidian vault, meeting
    # minutes, bylaws, transcripts. These are the records that legitimately run
    # to hundreds of chunks, and the ones a paraphrased question has to reach.
    "files": 200,
}


def max_chunks_for(tool):
    """The chunk cap for one source. `INDEX_MAX_CHUNKS` overrides everything,
    which is how the sweep behind these numbers was run."""
    override = os.environ.get("INDEX_MAX_CHUNKS")
    if override:
        return int(override)
    return MAX_CHUNKS_BY_SOURCE.get(tool, MAX_CHUNKS_PER_RECORD)
RRF_K = 60                 # the usual Reciprocal Rank Fusion constant

# Only used to decide whether a query is a keyword lookup or a question.
STOPWORDS = {
    "the", "and", "for", "what", "who", "where", "when", "how", "why", "which",
    "is", "are", "was", "were", "does", "did", "can", "with", "that", "this",
    "from", "about", "into", "onto", "you", "your", "our", "their", "his",
    "her", "its", "have", "has", "had", "get", "got", "any", "all", "some",
}

# ⚠️ `index.py` carries no version string of its own, so nothing can stamp it
# and nothing can drift. It asks the dispatcher, which `make bump` does stamp.
def tool_version():
    try:
        out = subprocess.run(["apple", "--version"], capture_output=True,
                             text=True, timeout=5)
        return out.stdout.strip().split()[-1] if out.returncode == 0 else "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


SOURCES = ["notes", "mail", "messages", "calendar", "contacts", "maps",
           "photos", "reminders", "files"]

# 🛑 ONE PLACE, because two places drift. `refresh` uses these, and so does the
# app's scheduler, which reads them back through `index.py sources --json`
# rather than keeping a second copy in Swift.
#
# ⚠️ Every source must appear here even when it takes no extra arguments. The
# empty entries are the reason `refresh` used `[name]` on a five-key dict and
# raised KeyError on `maps` — the LAST source, which killed the run before the
# embed step and made every refresh embed nothing.
REFRESH_ARGS = {
    "notes": [],
    "mail": ["--with-bodies"],
    "messages": ["--chat-limit", "1331", "--limit", "2000"],
    "calendar": ["--since", "3650"],
    "contacts": ["--limit", "100000"],
    "maps": [],
    "photos": [],
    "reminders": [],
    "files": [],
}


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

-- The `people` report, computed once and read back many times.
--
-- 🛑 IT IS DERIVED DATA, SO IT LIVES WITH THE INDEX. Reading every record with
-- a person on it, then shelling out to Contacts and call history, costs about
-- three seconds — cheap once a day and wrong to pay every time a window opens.
-- Rebuilding the index correctly throws this away with it, which is what
-- should happen: it is an answer about the index, not a setting the user
-- typed. Their rulings live outside, in people.json, for the opposite reason.
CREATE TABLE IF NOT EXISTS people_cache (
  one         INTEGER PRIMARY KEY CHECK (one = 1),
  computed_at REAL NOT NULL,
  payload     TEXT NOT NULL
);

-- 🛑 A REAL SERIES, because `record.seen_at` is not one. That column moves
-- when a record CHANGES, so a note edited today looks like a note indexed
-- today and the curve flattens history into the present. This table is written
-- once per ingest and never updated.
CREATE TABLE IF NOT EXISTS index_history (
  ts       REAL NOT NULL,
  tool     TEXT NOT NULL,
  records  INTEGER NOT NULL,
  chunks   INTEGER NOT NULL,
  PRIMARY KEY (ts, tool)
);
CREATE INDEX IF NOT EXISTS index_history_ts ON index_history(ts);

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
        # 🛑 THE LOCKED CASE FIRST, AND HERE RATHER THAN AT EACH CALL SITE.
        # `require_index` was called by three commands out of nineteen, so
        # `people` and `places` answered a locked index with "Run: ./index.py
        # init" — an instruction that would build a second, empty index beside
        # the encrypted one it could not see. Every command reaches `connect`.
        require_index(path)
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


# --------------------------------------------------------------------------
# photos — who you were with, and where you have been
# --------------------------------------------------------------------------

def ingest_photos(opts):
    """Photo days and photo places, from the Photos library.

    🛑 THIS SOURCE INDEXES NO PICTURES AND NO WORDS OUT OF THEM, and that is a
    measurement rather than a limitation. This library holds 36,341 photos
    carrying 5,349 characters of title and description between them — 0.15
    characters per photo — and twelve distinct keywords, most of them a pet
    photographer's watermark. Apple's own scene labels exist and are
    synonym-inflated past the point of meaning: one photo carries "Laugh,
    Laughed, Laughing, Laughter" and "Apparatus, Apparel, Art". Live Text OCR
    covers 5.9% of photos and the store keeps it as a deduplicated bag of
    lowercased words with the order destroyed, so a receipt is findable by
    keyword and unreadable as a sentence. None of it would help a retrieval
    index that already holds 239,000 real chunks. See
    docs/apple-photos-store.md.

    What this source is for is the two things no other source here can answer:
    who the user was physically with, and everywhere they have been.

    ⚠️ IT ANSWERS THE FIRST ONE BETTER THAN MAIL DOES, for the people mail
    cannot see at all. Measured against the ranking this feeds: the user's
    child is the most photographed person in the library by a factor of three,
    1,378 days against the runner-up, and the text channels give her 18 days
    and no rank — below a cleaning service. Children do not send email. Six of
    the top twenty people here are absent from every other source.
    """
    import photos as photo_store
    try:
        places, days = photo_store.survey()
    except photo_store.Unavailable as exc:
        # ⚠️ Not fatal, and not silent. A machine with no Photos library, or a
        # process without Full Disk Access, indexes every other source and says
        # what it skipped.
        sys.stderr.write("photos: %s\n" % exc)
        return

    # 🛑 THE UID CANNOT BE THE CLUSTER'S INDEX. Clusters are recomputed from
    # scratch every run and their order moves as photos arrive, so an index
    # would rename every place on any change and `--full` would delete the lot.
    # A rounded coordinate is stable: 0.001 degrees is about 110 metres, well
    # inside the 250 m radius that made the cluster, so a mean that shifts by a
    # few metres keeps its name.
    keys, taken = [], {}
    for spot in places:
        key = "%.3f,%.3f" % (spot["latitude"], spot["longitude"])
        # ⚠️ Two clusters CAN round into one cell when they sit diagonally
        # apart. Rare, and silently merging them would join two places; the
        # suffix keeps them separate and the order is stable because `survey`
        # sorts by days.
        taken[key] = taken.get(key, 0) + 1
        if taken[key] > 1:
            key = "%s#%d" % (key, taken[key])
        keys.append(key)

    for spot, key in zip(places, keys):
        name = spot.get("name") or ""
        where = [name, spot.get("city"), spot.get("state"), spot.get("country")]
        title = name or spot.get("city") or "%.4f, %.4f" % (
            spot["latitude"], spot["longitude"])
        yield {
            "uid": "photos:place:%s" % key,
            "tool": "photos", "kind": "place", "native_id": key,
            "url": None,
            "title": title,
            "container": spot.get("country"),
            "created": spot.get("first"),
            "modified": None,
            "occurred": spot.get("last"),
            "latitude": spot["latitude"], "longitude": spot["longitude"],
            "people": [],
            "body": ", ".join(x for x in where if x),
            "rev": rev_of(title, str(spot["photos"]), str(spot["days"])),
        }

    for entry in days:
        at = entry["place"]
        spot = places[at] if at is not None else None
        key = keys[at] if at is not None else "-"
        where = ""
        if spot:
            where = ", ".join(x for x in [spot.get("name"), spot.get("city"),
                                          spot.get("country")] if x)
        # 🛑 A PHOTO FROM SOMEBODY ELSE'S CAMERA IS NOT PROOF YOU WERE THERE.
        # 7,460 assets here belong to the iCloud Shared Library rather than to
        # this Mac's own library — other people's cameras pointed at the same
        # families. Most of the time that is the best evidence there is, since
        # it is the photo somebody else took OF the user. But a day whose every
        # photo came from a shared camera may be a day the user was not at, so
        # its people are marked `alongside` rather than `subject`, exactly as a
        # mailing list is `same_list` rather than contact.
        shared_only = entry["shared"] == entry["photos"]
        role = "alongside" if shared_only else "subject"
        # ⚠️ THE COUNT TRAVELS WITH THE PERSON, because a photo day holds a
        # different number of pictures of each person in it and the channel's
        # unit is one photo. Recomputing it in the report would mean opening
        # the Photos store a second time.
        people = [{"role": role, "name": who["name"],
                   "handle": who["contact_id"] or ("photos:" + who["name"]),
                   "photos": who["photos"]}
                  for who in entry["people"].values()]
        names = ", ".join(who["name"] for who in entry["people"].values())
        yield {
            "uid": "photos:day:%s:%s" % (entry["day"], key),
            "tool": "photos", "kind": "day",
            "native_id": entry["day"],
            "url": None,
            "title": where or entry["day"],
            "container": (spot or {}).get("country"),
            "created": None, "modified": None,
            "occurred": entry["when"],
            "latitude": (spot or {}).get("latitude"),
            "longitude": (spot or {}).get("longitude"),
            "people": people,
            "body": "\n".join(x for x in [where, names] if x),
            "rev": rev_of(entry["day"], key, str(entry["photos"]), names),
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


def ingest_reminders(opts):
    """Reminders, completed ones included.

    🛑 `--include-completed`, and that is the point. 1,417 of 1,478 reminders on
    this machine are done, and a finished reminder is the record of what
    actually happened. Indexing only the open ones would index the 4% that is
    still a todo list and throw away the history.

    ⚠️ A reminder has no per-item URL scheme, like calendar. See
    docs/todo-deep-links.md.
    """
    rows = apple("reminders", "show-all", "--include-completed", "--json")
    if opts.limit:
        rows = rows[:opts.limit]
    for row in rows:
        external = row.get("externalId")
        if not external:
            continue
        title = row.get("title") or ""

        # 🛑 `location` is a COORDINATE PAIR as a string, not an address —
        # `locationTitle` holds the human name. Reading `location` as text puts
        # "40.035336, -105.240627" in the body and places nothing on a map.
        lat = lon = None
        pair = (row.get("location") or "").split(",")
        if len(pair) == 2:
            try:
                lat, lon = float(pair[0]), float(pair[1])
            except ValueError:
                lat = lon = None

        # ⚠️ Tags are invisible to EventKit and never appear in the title, so a
        # reminder tagged #PTA has no "PTA" anywhere in its text. Put them in
        # the body or the index cannot find it by that word.
        tags = row.get("tags") or []
        body = "\n".join(x for x in [
            row.get("notes"),
            row.get("locationTitle"),
            row.get("url"),
            " ".join("#" + t for t in tags) if tags else None,
        ] if x)

        # 🛑 WHEN did this happen. A completed reminder's due date may be years
        # off or absent; what dates it is when it was finished. Prefer the
        # completion, then the due date, then creation, so every row has one.
        occurred = (epoch(row.get("completionDate")) or epoch(row.get("dueDate"))
                    or epoch(row.get("creationDate")))

        state = "done" if row.get("isCompleted") else "open"
        yield {
            "uid": "reminders:%s" % external,
            "latitude": lat, "longitude": lon,
            "tool": "reminders", "kind": "reminder", "native_id": external,
            "url": None,
            "title": title,
            "container": row.get("list"),
            "created": epoch(row.get("creationDate")),
            "modified": epoch(row.get("lastModified")),
            "occurred": occurred,
            "people": [],
            "body": body.strip(),
            # ⚠️ The completion state is part of the revision. Ticking a
            # reminder changes nothing else about it, and without this the
            # index would keep reporting it as open forever.
            "rev": rev_of(title, body, state, row.get("dueDate"),
                          row.get("lastModified")),
        }


# --------------------------------------------------------------------------
# files — a folder of markdown, with Obsidian understood
# --------------------------------------------------------------------------

# 🛑 ROOTS ARE CONFIGURED, NEVER GUESSED. A guessed path that happens to exist
# on one machine is exactly the kind of thing that ships and then indexes
# somebody's Downloads folder. `apple-index files add <path>` writes this.
#
# 🛑 `_SUPPORT`, NOT `dirname(DEFAULT_DB)`. That path FOLLOWS THE VAULT: it is
# `<support>/mnt` whenever the app has the encrypted image mounted. A folder
# added from the app therefore landed inside the volume, disappeared the moment
# the app quit, and `apple-index forget` destroyed it with the index. Same trap
# `PEOPLE_CONFIG` records, and the same fix.
#
# ⚠️ An explicit `APPLE_INDEX_DB` still wins, because `lab/bench` relies on it
# to keep its own configuration away from the real one.
FILES_CONFIG = os.path.join(
    os.path.dirname(os.path.expanduser(os.environ["APPLE_INDEX_DB"]))
    if os.environ.get("APPLE_INDEX_DB") else _SUPPORT,
    "files.json")

# Where the vault-following version used to write. Read as a fallback, never
# written, so an install that configured folders before this fix keeps them.
FILES_CONFIG_LEGACY = os.path.join(os.path.dirname(DEFAULT_DB), "files.json")


def read_files_config():
    """The configuration, from the current path or the one it used to use."""
    # 🛑 DE-DUPLICATE, DO NOT SKIP. An earlier version dropped the legacy path
    # when it equalled the current one — and the condition matched the FIRST
    # entry too, so whenever the vault was unmounted the two paths coincided
    # and NOTHING was read. Every configured folder read as "you have none".
    seen = set()
    for path in (FILES_CONFIG, FILES_CONFIG_LEGACY):
        if path in seen:
            continue
        seen.add(path)
        try:
            with open(path) as handle:
                config = json.load(handle)
        except (OSError, ValueError):
            continue
        if isinstance(config, dict):
            return config
    return {"roots": []}


def write_files_config(config):
    """Write it, always to the path that survives the vault unmounting."""
    os.makedirs(os.path.dirname(FILES_CONFIG), mode=0o700, exist_ok=True)
    with open(FILES_CONFIG, "w") as handle:
        json.dump(config, handle, indent=2)
    os.chmod(FILES_CONFIG, 0o600)

# ⚠️ Directories that are never content. `Attachments` and an images folder can
# be hundreds of megabytes of binaries next to five megabytes of text — on this
# vault, 959 MB against 5.6 MB.
FILE_SKIP_DIRS = {
    ".obsidian", ".git", ".trash", ".stfolder", ".stversions",
    "node_modules", "__pycache__", "Attachments", "attachments",
    ".smart-connections", ".makemd",
}
FILE_EXTENSIONS = {".md", ".markdown", ".txt"}
# ⚠️ A cap, because one runaway export should not become 40% of the index. The
# largest real note in this vault is 701 KB, so this keeps everything genuine.
FILE_MAX_BYTES = 2 * 1024 * 1024


def files_roots():
    """The configured roots, each {path, name, exclude}."""
    config = read_files_config()
    roots = []
    for entry in config.get("roots", []):
        path = os.path.expanduser(entry.get("path", ""))
        if not path:
            continue
        roots.append({
            "path": os.path.realpath(path),
            "name": entry.get("name") or os.path.basename(path.rstrip("/")),
            "exclude": entry.get("exclude") or [],
        })
    return roots


def is_obsidian_vault(path):
    return os.path.isdir(os.path.join(path, ".obsidian"))


def parse_frontmatter(text):
    """The YAML subset Obsidian actually writes: `key: value` and `- item`.

    🛑 NOT a YAML parser, and deliberately. Bringing PyYAML in would break the
    stdlib-only rule the whole ingest path is built on, for a block that is
    flat `key: value` in 861 of 861 notes here. Anything it cannot read is
    skipped rather than guessed at.

    Returns (fields, body). A file with no frontmatter returns ({}, text).
    """
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 4)
    if end == -1:
        return {}, text
    block, body = text[4:end], text[end + 4:].lstrip("\n")
    fields, key = {}, None
    for line in block.splitlines():
        if line.startswith(("- ", "  - ")) and key:
            fields.setdefault(key, [])
            if isinstance(fields[key], list):
                fields[key].append(line.split("- ", 1)[1].strip())
            continue
        match = re.match(r"^([A-Za-z][\w-]*)\s*:\s*(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        fields[key] = value if value else []
    return fields, body


# ⚠️ Wikilinks carry meaning and must survive into the text. `[[Ada Lovelace]]`
# is how a note names a person, and stripping the brackets without keeping the
# name loses the only mention. `[[path/to/note|Shown]]` keeps the shown half.
WIKILINK = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")


def flatten_markdown(text):
    text = WIKILINK.sub(lambda m: (m.group(2) or m.group(1)).split("/")[-1], text)
    # Images add nothing searchable and their alt text is usually a filename.
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)
    return text


def obsidian_url(root, relative):
    return "obsidian://open?vault=%s&file=%s" % (
        urllib.parse.quote(os.path.basename(root["path"])),
        urllib.parse.quote(os.path.splitext(relative)[0]))


def ingest_files(opts):
    """Markdown and text files from configured roots, Obsidian understood.

    🛑 THE PATH IS THE DESCRIPTION, and it is stored as `container` rather than
    smeared into the text. A note in `11 - 🤝 Volunteering/Columbine PTA/` is
    filed there by the user; that is a real fact about the file. Writing a
    hand-maintained folder description instead would be a second thing to keep
    true, and it goes stale silently.
    """
    roots = files_roots()
    if not roots:
        sys.stderr.write(
            "no file roots configured. Add one:\n"
            "  apple-index files add ~/path/to/vault\n")
        return
    seen = 0
    for root in roots:
        base = root["path"]
        if not os.path.isdir(base):
            sys.stderr.write("skipping missing root: %s\n" % base)
            continue
        vault = is_obsidian_vault(base)
        excluded = set(FILE_SKIP_DIRS) | set(root["exclude"])
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames
                           if d not in excluded and not d.startswith(".")]
            for name in sorted(filenames):
                if os.path.splitext(name)[1].lower() not in FILE_EXTENSIONS:
                    continue
                path = os.path.join(dirpath, name)
                try:
                    stat = os.stat(path)
                except OSError:
                    continue
                if stat.st_size > FILE_MAX_BYTES:
                    sys.stderr.write("skipping %.1f MB file: %s\n"
                                     % (stat.st_size / 1e6, path))
                    continue
                if opts.limit and seen >= opts.limit:
                    return
                seen += 1
                try:
                    raw = open(path, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue

                relative = os.path.relpath(path, base)
                fields, body = parse_frontmatter(raw) if vault else ({}, raw)
                body = flatten_markdown(body)

                # ⚠️ Frontmatter goes in the body as `key: value` lines, because
                # that is how it is searched. `type: person` is invisible
                # otherwise — the word "person" appears nowhere in the note.
                meta_lines = []
                for key, value in fields.items():
                    if key in ("cover", "isbn13", "isbn", "goodreads"):
                        continue      # identifiers, not language
                    text = ", ".join(value) if isinstance(value, list) else value
                    if text:
                        # ⚠️ FLATTEN THESE TOO. Frontmatter carries wikilinks —
                        # `source: "[[2026-08-22 COPTA BOD Meeting]]"` — and
                        # flattening only the body left 52 records with raw
                        # brackets around the very names that make them
                        # findable.
                        meta_lines.append("%s: %s"
                                          % (key, flatten_markdown(text).strip('"')))

                title = (fields.get("title") if isinstance(fields.get("title"), str)
                         else None)
                if not title:
                    heading = re.search(r"^#\s+(.+)$", body, re.M)
                    title = heading.group(1).strip() if heading else \
                        os.path.splitext(name)[0]

                folder = os.path.dirname(relative)
                rendered = ("\n".join(meta_lines) + "\n\n" + body).strip()
                yield {
                    "uid": "files:%s:%s" % (root["name"], relative),
                    "latitude": None, "longitude": None,
                    "tool": "files",
                    "kind": "note" if vault else "file",
                    "native_id": path,
                    # 🛑 A REAL DEEP LINK, which most sources here cannot offer.
                    # `obsidian://open` opens the note itself.
                    "url": obsidian_url(root, relative) if vault else "file://"
                           + urllib.parse.quote(path),
                    "title": title,
                    "container": folder or root["name"],
                    "created": stat.st_birthtime if hasattr(stat, "st_birthtime")
                               else stat.st_ctime,
                    "modified": stat.st_mtime,
                    # A dated note is dated by its own frontmatter; everything
                    # else by when it was last written.
                    "occurred": epoch(fields.get("date") if isinstance(
                        fields.get("date"), str) else None) or stat.st_mtime,
                    "people": [],
                    "body": rendered,
                    # 🛑 HASH WHAT THIS ADAPTER PRODUCES, not the file's stats.
                    # A rev of mtime+size tracks the FILE, so improving how the
                    # adapter renders a note — flattening frontmatter
                    # wikilinks, say — reaches no existing record: the file did
                    # not change, so `ingest` reports `+0 ~0 -0` and the fix
                    # silently never lands. Hashing the rendered body costs
                    # nothing, because the body is already in memory.
                    "rev": rev_of(title, folder, rendered),
                }


ADAPTERS = {
    "notes": ingest_notes,
    "mail": ingest_mail,
    "messages": ingest_messages,
    "calendar": ingest_calendar,
    "contacts": ingest_contacts,
    "maps": ingest_maps,
    "photos": ingest_photos,
    "reminders": ingest_reminders,
    "files": ingest_files,
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

    cap = max_chunks_for(record.get("tool"))
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
        return out[:cap]

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
        if len(out) >= cap:
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
                if len(out) >= cap:
                    break
            continue

        if pending_len + len(text) > BLOCK_TARGET:
            flush()
        pending.append(text)
        pending_len += len(text) + 1

    flush()
    return out[:cap]


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


# 🛑 ONE WRITER AT A TIME, ACROSS PROCESSES.
#
# The app indexes on a schedule and the user can still type `apple-index
# refresh` in a terminal. Two `ingest` runs on one SQLite file interleave their
# reads and writes: each decides what is new from a snapshot the other is
# already changing, so both write, and the watermark ends up describing neither.
#
# ⚠️ An advisory flock, held for the whole run and released when the process
# exits — including when it is killed, which a lock row in the database would
# not survive. Non-blocking on purpose: a caller that cannot have the lock must
# be TOLD, not queued behind a mail ingest that runs for twenty minutes.
_LOCK_HANDLE = None


def take_write_lock(db_path, what):
    """Hold the ingest lock for the life of this process, or explain and exit."""
    global _LOCK_HANDLE
    path = db_path + ".lock"
    handle = open(path, "a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.seek(0)
        holder = handle.read().strip() or "another process"
        die("%s is already running (%s). Wait for it, or stop it first."
            % (holder, path))
    handle.seek(0)
    handle.truncate()
    handle.write("%s pid %d since %s\n"
                 % (what, os.getpid(), time.strftime("%Y-%m-%dT%H:%M:%S")))
    handle.flush()
    os.chmod(path, 0o600)
    # ⚠️ Keep the handle alive. Closing it drops the lock, and a local variable
    # going out of scope is exactly how that happens by accident.
    _LOCK_HANDLE = handle


def cmd_ingest(opts):
    require_index(opts.db)
    take_write_lock(opts.db, "ingest")
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

    snapshot_history(db)
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
    take_write_lock(opts.db, "embed")
    if not os.path.exists(VEC):
        die("vec is not built. Run: make -C %s" % HERE)
    connect(opts.db).close()
    if opts.model in COREML_MODELS:
        cmd = [VEC, "embed", "--db", opts.db, "--model", opts.model]
    elif opts.model in OSS_MODELS:
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
            # 🛑 EVERY flag that changes a result belongs in the cache key.
            # `pool` and `per_tool` were missing once, and a comparison of six
            # values returned one cached answer six times -- it read as a flat
            # response curve. `also` changes the result set outright.
            "also": tuple(opts.also or ()),
            "drop_stopwords": opts.drop_stopwords, "rare_only": opts.rare_only,
            "min_chunk": opts.min_chunk,
            # 🛑 EVERY FLAG THAT CHANGES THE RESULT BELONGS IN THE CACHE KEY.
            # `pool` and `per_tool` were missing, so changing either returned
            # the PREVIOUS answer from `result_cache` — a user who tuned a flag
            # saw no effect, and an evaluation comparing six values of
            # `--per-tool` scored all six identically because it was reading
            # one cached result six times.
            "pool": opts.pool, "per_tool": opts.per_tool}


def cache_key(query, settings, fingerprint):
    blob = json.dumps({"q": query, "s": settings, "f": fingerprint}, sort_keys=True)
    return hashlib.sha1(blob.encode("utf-8")).hexdigest()


# 🛑 THE LOG IS A SECOND COPY OF THE PROTECTED CONTENT, so it does not get to
# grow without limit. A logged result carries the title and a 240-character
# snippet of real message text, indexed by what was searched for. Three days of
# ordinary use produced 3,816 rows and 25 MB, and nothing pruned it.
#
# ⚠️ Thirty days is a retention policy, not a size cap. A week of heavy use can
# still be large; what it cannot be is unbounded.
LOG_RETENTION_DAYS = 30


def prune_logs(db, days=LOG_RETENTION_DAYS, commit=True):
    """Drop logged queries and cached results older than `days`.

    ⚠️ Cheap enough to run on every search: `query_log_ts` indexes the column,
    so a delete that matches nothing costs an index probe. Doing it on write is
    what makes the policy real — a prune that needs a cron job is a prune that
    silently stops happening.
    """
    cutoff = time.time() - days * 86400
    dropped = db.execute("DELETE FROM query_log WHERE ts < ?", (cutoff,)).rowcount
    dropped += db.execute("DELETE FROM result_cache WHERE ts < ?", (cutoff,)).rowcount
    # 🛑 COMMIT EVEN WHEN NOTHING WAS DROPPED. A DELETE that matches no rows
    # still opens a transaction, and `if dropped: commit()` left it open — the
    # next `VACUUM` then failed with "cannot VACUUM from within a transaction".
    # The rowcount says what changed; it does not say whether a transaction is
    # open.
    if commit:
        db.commit()
    return dropped


def record_query(db, query, settings, fingerprint, results, elapsed_ms, cached,
                 keep_snippets=True):
    # ⚠️ The log is a SECOND store of the same protected content: a snippet is
    # real message text. --no-snippet-log keeps the ranking and drops the text.
    if not keep_snippets:
        results = [{k: v for k, v in r.items() if k != "snippet"} for r in results]
    prune_logs(db, commit=False)
    db.execute("""INSERT INTO query_log
                  (ts, query, settings, fingerprint, elapsed_ms, n_results, cached, results)
                  VALUES (?,?,?,?,?,?,?,?)""",
               (time.time(), query, json.dumps(settings, sort_keys=True), fingerprint,
                round(elapsed_ms, 1), len(results), 1 if cached else 0,
                json.dumps(results)))
    db.commit()


def cmd_search(opts):
    require_index(opts.db)
    warn_if_revoked(opts)
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

    # 🛑 `--also` runs ANOTHER PHRASING of the same question and fuses by MAX.
    #
    # A vocabulary split — the corpus says "air conditioning", the caller says
    # "HVAC" — is invisible from the results, because the matching half comes
    # back looking complete. Expansion is the fix, and the FUSION RULE is the
    # part that is easy to get wrong, which is why it lives here and not in a
    # caller's head.
    #
    # 🛑 MAX, NEVER SUM. Summing reciprocal ranks rewards a record appearing in
    # MANY lists over one ranking FIRST in one list, which is backwards: the
    # main query is the only phrasing known to be the user's question and the
    # rest are guesses. Measured over 33 cases: sum sent three cases from rank
    # 1 to a miss, and weighting the main query higher made it worse
    # monotonically (w=1 0.521, w=2 0.501, w=3 0.498, w=5 0.487). Under max no
    # case fell out of the top 10.
    #
    # ⚠️ EXPAND A QUESTION, NEVER A KEYWORD LOOKUP. Measured by kind:
    # vocabulary 0.562 -> 0.675, vault 0.190 -> 0.239, descriptive 0.577 ->
    # 0.601, but keyword 0.857 -> 0.821 and recent 0.833 -> 0.800. A keyword
    # query is already the right words; paraphrasing only adds noise. The CLI
    # does not guess — the caller decides by passing `--also` or not.
    #
    # ⚠️ It does NOT fix the `no-overlap` class. All four such cases stay
    # missed under every fusion variant tried. See RANKING.md.
    phrasings = [opts.query] + list(opts.also or [])
    by_uid, best = {}, {}
    for phrasing in phrasings:
        for rank, row in enumerate(rank_one(opts, db, phrasing), 1):
            score = 1.0 / (RRF_K + rank)
            uid = row["uid"]
            if uid not in best or score > best[uid]:
                best[uid] = score
                by_uid[uid] = row
    eligible = sorted(by_uid, key=lambda u: -best[u])
    results = []
    for uid in eligible[:opts.limit]:
        row = dict(by_uid[uid])
        if len(phrasings) > 1:
            # The fused score is a different quantity from a single query's, so
            # do not let a caller compare the two. Say which it is.
            row["score"] = round(best[uid], 6)
            row["fused_over"] = len(phrasings)
        results.append(row)

    # ⚠️ SAY WHAT WAS CUT. `apple maps places` answered "how many times did we
    # go to the Elks Lodge" with 1 when the truth was 4, because its --limit
    # hid the rest in silence. Same failure, different tool: a search that
    # returns exactly --limit rows and says nothing cannot be told apart from a
    # search that found exactly that many.
    if len(eligible) > opts.limit:
        sys.stderr.write("showing %d of %d results\n" % (opts.limit, len(eligible)))

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

def rank_one(opts, db, query):
    """Retrieve, fuse and materialise ONE phrasing.

    Returns EVERY eligible record in rank order. The caller truncates, so it
    can report how many it cut -- `search` used to return exactly `--limit`
    rows and say nothing, and a caller had no way to tell a short list from a
    truncated one. `apple maps places` has printed that line for months.

    🛑 Split out of cmd_search on 2026-08-25 so `--also` can run several
    phrasings through the same path. Nothing here reads `opts.query`; the
    phrasing is the argument, which is the whole point.
    """
    pool = opts.pool or max(opts.limit * 6, 60)

    # 1. lexical
    lexical, lexical_chunk = [], {}
    match = fts_query(query, opts.fts_mode,
                      drop_stopwords=opts.drop_stopwords,
                      db=db, rare_only=opts.rare_only)
    if match:
        try:
            if opts.lexical_unit == "chunk":
                seen = set()
                # 🛑 A PER-TOOL QUOTA, for the same reason the semantic arm
                # has one. A global `ORDER BY bm25 LIMIT` samples the corpus in
                # proportion to its size, and mail is 81.3% of the chunks here.
                # A source that is 3% of the index never reaches the ranker,
                # which defeats the point of not having to name the app.
                sql = """
                        SELECT c.rid, c.cid, c.text FROM chunk_fts f
                        JOIN chunk c ON c.cid = f.rowid
                        JOIN record r ON r.rid = c.rid
                        WHERE chunk_fts MATCH ? AND (? IS NULL OR r.tool = ?)
                        ORDER BY bm25(chunk_fts)
                        LIMIT ?"""
                if opts.per_tool:
                    # ⚠️ A window function, so one query still does it. Needs
                    # SQLite 3.25+; the system one here is 3.53.
                    sql = """
                        SELECT rid, cid, text FROM (
                          SELECT c.rid, c.cid, c.text,
                                 ROW_NUMBER() OVER (PARTITION BY r.tool
                                                    ORDER BY bm25(chunk_fts)) rank
                          FROM chunk_fts f
                          JOIN chunk c ON c.cid = f.rowid
                          JOIN record r ON r.rid = c.rid
                          WHERE chunk_fts MATCH ? AND (? IS NULL OR r.tool = ?)
                        ) WHERE rank <= %d LIMIT ?""" % opts.per_tool
                for row in db.execute(sql, (match, opts.tool, opts.tool, pool * 4)):
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
            reply = daemon_request({"op": "search", "query": query,
                                    "model": opts.model, "limit": pool * 2,
                                    "tool": opts.tool,
                                    "per_tool": opts.per_tool})
            if reply and not reply.get("ok") and opts.verbose:
                sys.stderr.write("daemon declined: %s\n" % reply.get("error"))
            if reply and reply.get("ok"):
                served = json.dumps(reply["hits"])
                if opts.verbose:
                    sys.stderr.write("daemon: %.1f ms\n" % reply.get("elapsed_ms", 0))

        if served is None:
            proc = subprocess.run(
                vector_search_cmd(opts.model, opts.db, query, pool * 2,
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
    terms = [t.lower() for t in re.findall(r"[\w']+", query) if len(t) > 1]
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
        content = [t for t in re.findall(r"[\w']+", query.lower())
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
    return results


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
   %s of decoded mail, messages, notes and contacts, in one UNENCRYPTED file:
     %s
   The stores it came from are protected by Full Disk Access and 0700
   directories. This file is protected by neither, so any process running as
   you can read every email with no grant and no prompt. Revoking Full Disk
   Access does NOT disable it, and every backup copies it.
   Mitigations applied: directory 0700, file 0600, Spotlight excluded.
   Not applied: access logging, expiry.

   ENCRYPT IT: install AppleTools.app, which moves this file into an AES-256
   disk image keyed to your Keychain.  brew install --cask \\
     danielhopkins/formulae/apple-tools-app
   Or remove it:  apple-index purge --yes        Details: lab/SECURITY.md
"""


def index_is_encrypted(path):
    """True when the index sits inside the app's encrypted disk image.

    ⚠️ A PATH TEST, not a question about the file. The image is mounted, so the
    database on it looks exactly like any other file — mode, size and header are
    all identical. Where it lives is the only thing that distinguishes them.
    """
    return os.path.realpath(path).startswith(
        os.path.realpath(os.path.join(_SUPPORT, "mnt")) + os.sep)


def warn_security(db, path, force=False):
    """Say what this file is, on any command that creates or grows it.

    ⚠️ A warning that lives only in a document is a warning nobody reads. This
    prints on ingest and on status, every time, and names the real size.

    🛑 SILENT ONCE THE INDEX IS ENCRYPTED, because then the warning is FALSE.
    It said "Not applied: encryption" and "protected by neither" long after
    AppleTools.app had moved the file into an AES-256 image. A security banner
    that is wrong is worse than none: it trains the reader to skip it.
    """
    if index_is_encrypted(path) and not force:
        return
    try:
        size = os.path.getsize(path) / 1e6
    except OSError:
        size = 0.0
    sys.stderr.write(SECURITY_WARNING % ("%.0f MB" % size, path))
    sys.stderr.write("\n")


AGENT_LABEL = "com.boulderhopkins.apple-index"
AGENT_PLIST = os.path.expanduser(
    "~/Library/LaunchAgents/%s.plist" % AGENT_LABEL)


def agent_template():
    """The plist template, in either layout.

    🛑 A brew install has no `make install-agent`: the lab Makefile does not
    ship. Without this command the shipped template is a file nobody can use,
    which is what v26.822.1 and .2 released.
    """
    for candidate in (os.path.join(HERE, "%s.plist.in" % AGENT_LABEL),
                      os.path.join(os.path.dirname(HERE), "%s.plist.in" % AGENT_LABEL)):
        if os.path.exists(candidate):
            return candidate
    return None


def cmd_agent(opts):
    """Install or remove the launchd agent that keeps the daemon warm."""
    if opts.action == "uninstall":
        subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), AGENT_LABEL)],
                       capture_output=True)
        if os.path.exists(AGENT_PLIST):
            os.remove(AGENT_PLIST)
        print("removed %s" % AGENT_LABEL)
        return

    template = agent_template()
    if not template:
        die("cannot find %s.plist.in beside %s" % (AGENT_LABEL, HERE))
    if not os.path.isfile(VEC):
        die("cannot find the vec binary at %s" % VEC)

    log_dir = os.path.dirname(opts.db)
    secure_db_path(opts.db)
    with open(template) as handle:
        body = handle.read()
    for key, value in (("@VEC@", VEC), ("@INDEXDIR@", HERE),
                       ("@HOME@", os.path.expanduser("~")),
                       ("@LOGDIR@", log_dir),
                       ("@PATH@", "/usr/bin:/bin:/usr/sbin:/sbin")):
        body = body.replace(key, value)
    os.makedirs(os.path.dirname(AGENT_PLIST), exist_ok=True)
    with open(AGENT_PLIST, "w") as handle:
        handle.write(body)

    # ⚠️ bootout is asynchronous. Bootstrapping straight after it fails with
    # "Input/output error" because the old service is still tearing down.
    subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), AGENT_LABEL)],
                   capture_output=True)
    for _ in range(10):
        probe = subprocess.run(
            ["launchctl", "print", "gui/%d/%s" % (os.getuid(), AGENT_LABEL)],
            capture_output=True)
        if probe.returncode != 0:
            break
        time.sleep(1)
    result = subprocess.run(
        ["launchctl", "bootstrap", "gui/%d" % os.getuid(), AGENT_PLIST],
        capture_output=True, text=True)
    if result.returncode != 0:
        die("launchctl bootstrap failed: %s" % result.stderr.strip())
    print("installed %s" % AGENT_LABEL)
    print("  runs:  %s daemon" % VEC)
    print("  log:   %s/daemon.log" % log_dir)
    print("⚠️  The agent SERVES searches and cannot INGEST: a launchd agent has")
    print("   no Full Disk Access. Refresh from a terminal: apple-index refresh")


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
        for pattern in ("daemon.py serve", "vec daemon"):
            subprocess.run(["pkill", "-f", pattern], capture_output=True)
        # ⚠️ The launchd agent sets KeepAlive, so it restarts the daemon within
        # seconds of a kill. Two daemons then raced for the socket here, and
        # `daemon status` reported the one that lost. Say so rather than
        # leaving the user to wonder why "stopped" did not stop anything.
        agent = os.path.expanduser(
            "~/Library/LaunchAgents/com.boulderhopkins.apple-index.plist")
        if os.path.exists(agent):
            print("⚠️  a launchd agent will restart it. To stop it for good:")
            print("    launchctl bootout gui/$(id -u)/com.boulderhopkins.apple-index")
        if os.path.exists(opts.socket):
            os.remove(opts.socket)
        print("stopped")
        return

    if daemon_request({"op": "ping"}, opts.socket):
        print("already running")
        return
    secure_db_path(opts.db)
    # 🛑 The Core ML daemon is the Swift binary. `daemon.py` needs PyTorch and
    # 661 MB to answer the same socket; `vec daemon` holds 110 MB. Both speak
    # the same protocol, so the client cannot tell which one answered.
    if opts.model in COREML_MODELS:
        command = [VEC, "daemon", "--db", opts.db, "--socket", opts.socket,
                   "--model", opts.model]
    else:
        command = ["uv", "run", "--quiet", DAEMON, "serve", "--db", opts.db,
                   "--socket", opts.socket, "--model", opts.model,
                   "--refresh", str(opts.refresh)]
    with open(log_path, "a") as log_file:
        subprocess.Popen(command, stdout=log_file, stderr=log_file,
                         start_new_session=True)
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
        # 🛑 `.get`, never `[name]`. SOURCES lists six sources and this dict
        # held five, so `refresh` raised KeyError on `maps` — the LAST source,
        # which killed the run BEFORE the embed step. Every refresh ingested
        # new records and then embedded none of them, and the traceback looked
        # like a maps problem rather than a silent embed skip.
        extra = REFRESH_ARGS.get(name, [])
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
    if opts.logs_only and getattr(opts, "older_than", 0):
        db = connect(opts.db)
        dropped = prune_logs(db, days=opts.older_than)
        print("dropped %d entries older than %d days" % (dropped, opts.older_than))
        db.execute("VACUUM")
        return
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
        entry = kept.setdefault(key, {"rows": [], "km": km})
        entry["rows"].append(row)
        entry["km"] = min(entry["km"], km)

    out = []
    for entry in kept.values():
        rows = sorted(entry["rows"], key=lambda r: r["occurred"] or 0, reverse=True)
        # Keep the NEWEST of a repeated title. "when was I last there" is the
        # question a repeated place is usually asked about.
        row = rows[0]
        out.append({
            "uid": row["uid"], "tool": row["tool"], "kind": row["kind"],
            "id": row["native_id"], "title": row["title"],
            "container": row["container"],
            "records": len(rows),
            "count": occurrence_count(rows),
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
        print("%-9s %6.2f km  %-10s %s%s"
              % (r["tool"], r["km"], (r["date"] or "")[:10], r["title"],
                 count_label(r["tool"], r["count"])))
    if not out:
        print("nothing placed within %g km." % opts.radius)


def occurrence_count(records):
    """How many TIMES the thing on a collapsed line happened.

    🛑 Not the number of records. A maps PLACE is a summary row, not an
    arrival, and counting it inflates every visit tally by exactly one.
    Measured: the Elks Lodge collapsed to `(x5)` from 4 visits plus 1 place
    record, and read as five trips. The place row is the only record in the
    index that summarises other records, so it is the only one excluded.

    ⚠️ The count is bounded by the same --since/--past window as the listing.
    It is "visits in this window", never a lifetime total. `apple maps places`
    reports the lifetime figure.
    """
    return sum(1 for r in records
               if not (r["tool"] == "maps" and r["kind"] == "place"))


def count_label(tool, count):
    """Say what the number counts. `(x4)` alone invited the wrong reading."""
    if count <= 1:
        return ""
    if tool == "maps":
        return "  (%d visits)" % count
    return "  (x%d)" % count


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
        groups.setdefault((m["tool"], (m["title"] or "").strip()), []).append(m)

    out = []
    for (tool, _), rows in groups.items():
        rows.sort(key=lambda r: r["occurred"] or 0, reverse=True)
        m = rows[0]
        out.append({
            "uid": m["uid"], "tool": m["tool"], "kind": m["kind"],
            "id": m["native_id"], "title": m["title"],
            # `records` is what collapsed; `count` is what happened. They differ
            # for a maps place, and only `count` should ever be shown to a user.
            "records": len(rows),
            "count": occurrence_count(rows),
            "date": (datetime.fromtimestamp(m["occurred"], timezone.utc).isoformat()
                     if m["occurred"] else None),
        })
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
            print("    %-9s %-10s %s%s"
                  % (m["tool"], (m["date"] or "")[:10], m["title"],
                     count_label(m["tool"], m["count"])))
        if len(g["records"]) > opts.show:
            print("    ... and %d more" % (len(g["records"]) - opts.show))
        print("")
    if not out:
        print("no group of %d or more within %g km." % (opts.min_size, opts.radius))


def cmd_files(opts):
    """List, add or remove the folders the `files` source indexes.

    🛑 Roots are configured, never guessed. A guessed path that happens to
    exist on one machine is how a tool ends up indexing somebody's Downloads.
    """
    config = read_files_config()
    roots = config.setdefault("roots", [])
    # ⚠️ MOVE IT ON SIGHT, BUT NEVER FROM `--json`. A configuration still at
    # the vault-following path is one `apple-index forget` away from being
    # deleted with the index, so the human-facing listing copies it out rather
    # than waiting for an edit. `--json` is what the app polls on every window
    # open, and Rule 2 of CLAUDE.md is that a read does not write.
    if roots and not getattr(opts, "json", False) \
            and not os.path.exists(FILES_CONFIG):
        write_files_config(config)

    def described(root):
        path = os.path.expanduser(root.get("path", ""))
        return {
            "path": path,
            "name": root.get("name") or os.path.basename(path.rstrip("/")),
            "exclude": root.get("exclude") or [],
            "kind": "obsidian" if is_obsidian_vault(path) else "folder",
            "present": os.path.isdir(path),
        }

    if opts.action == "add":
        path = os.path.realpath(os.path.expanduser(opts.path))
        if not os.path.isdir(path):
            die("not a directory: %s" % path)
        if any(os.path.realpath(os.path.expanduser(r["path"])) == path for r in roots):
            if getattr(opts, "json", False):
                print(json.dumps({"added": False, "already": True, "path": path}))
            else:
                print("already indexed: %s" % path)
            return
        name = opts.name or os.path.basename(path.rstrip("/"))
        roots.append({"path": path, "name": name,
                      "exclude": opts.exclude.split(",") if opts.exclude else []})
        write_files_config(config)
        kind = "Obsidian vault" if is_obsidian_vault(path) else "folder"
        if getattr(opts, "json", False):
            print(json.dumps({"added": True, "path": path, "name": name,
                              "kind": kind}))
            return
        print("added %s as '%s' (%s)" % (path, name, kind))
        print("index it with:  apple-index ingest --source files")
        return

    if opts.action == "remove":
        path = os.path.realpath(os.path.expanduser(opts.path))
        kept = [r for r in roots
                if os.path.realpath(os.path.expanduser(r["path"])) != path]
        if len(kept) == len(roots):
            die("not a configured root: %s" % path)
        config["roots"] = kept
        write_files_config(config)
        # ⚠️ Removing a root does NOT remove its records. Say so, and say how.
        if getattr(opts, "json", False):
            print(json.dumps({"removed": True, "path": path,
                              "records_remain": True}))
            return
        print("removed %s from the config." % path)
        print("Its indexed records stay until you run:")
        print("  apple-index ingest --source files --full")
        return

    if getattr(opts, "json", False):
        print(json.dumps({"config": FILES_CONFIG,
                          "roots": [described(r) for r in roots]}, indent=2))
        return
    if not roots:
        print("no folders indexed. Add one:")
        print("  apple-index files add ~/path/to/vault")
        return
    for root in roots:
        one = described(root)
        # ⚠️ A ternary, not `cond and "" or X`. An empty string is falsy, so the
        # and/or form returns X for BOTH branches — it reported every present
        # folder as MISSING.
        here = "" if one["present"] else "  🛑 MISSING"
        print("%-10s %-9s %s%s" % (one["name"], one["kind"], one["path"], here))


def cmd_sources(opts):
    """What refresh runs for each source. The app reads this rather than
    keeping a second copy of REFRESH_ARGS in Swift."""
    print(json.dumps({name: REFRESH_ARGS.get(name, []) for name in SOURCES},
                     indent=2))


def cmd_consent(opts):
    """Read, print or record the opt-in.

    🛑 The app cannot use the interactive path: a GUI child has no terminal, so
    `require_consent` would refuse. It shows this same text in its own window
    and then records the answer here, so there is ONE consent record and one
    wording.
    """
    if opts.text:
        print(CONSENT_PROMPT)
        return
    db = connect(opts.db)
    row = db.execute(
        "SELECT granted_at, version, how FROM consent ORDER BY granted_at").fetchone()
    if opts.accept:
        if row:
            print(json.dumps({"granted": True, "granted_at": row["granted_at"],
                              "how": row["how"], "changed": False}))
            return
        db.execute("INSERT INTO consent (granted_at, version, how) VALUES (?,?,?)",
                   (time.time(), CONSENT_VERSION, opts.how))
        db.commit()
        print(json.dumps({"granted": True, "granted_at": time.time(),
                          "how": opts.how, "changed": True}))
        return
    print(json.dumps({"granted": bool(row),
                      "granted_at": row["granted_at"] if row else None,
                      "how": row["how"] if row else None,
                      "changed": False}))


def snapshot_history(db, when=None):
    """One row per tool, per ingest. ⚠️ Rounded to the minute, so a burst of
    per-source ingests in one refresh collapses into a single point instead of
    eight points a second apart."""
    ts = round((when or time.time()) / 60) * 60
    rows = db.execute("""
        SELECT r.tool, COUNT(DISTINCT r.rid) records, COUNT(c.cid) chunks
        FROM record r LEFT JOIN chunk c ON c.rid = r.rid
        GROUP BY r.tool""").fetchall()
    for row in rows:
        db.execute("""INSERT INTO index_history (ts, tool, records, chunks)
                      VALUES (?,?,?,?)
                      ON CONFLICT(ts, tool) DO UPDATE SET records=?, chunks=?""",
                   (ts, row["tool"], row["records"], row["chunks"],
                    row["records"], row["chunks"]))
    db.commit()


def backfill_history(db):
    """Seed the series from `seen_at`, once, so a new install has a shape.

    🛑 AN APPROXIMATION, AND LABELLED AS ONE. `seen_at` is when a record was
    last written, not when it first arrived, so an edited record counts on the
    day it changed. For a corpus that mostly appends the curve is close; for a
    source that was re-ingested wholesale it is a step where the real history
    was a slope.
    """
    if db.execute("SELECT COUNT(*) c FROM index_history").fetchone()["c"]:
        return 0
    days = db.execute("""
        SELECT DISTINCT CAST(seen_at / 86400 AS INTEGER) * 86400 day
        FROM record ORDER BY day""").fetchall()
    written = 0
    for row in days:
        # 🛑 End of that day, so a point means "this is what the index held",
        # not "this is what arrived".
        edge = row["day"] + 86399
        for tool_row in db.execute("""
                SELECT r.tool, COUNT(DISTINCT r.rid) records, COUNT(c.cid) chunks
                FROM record r LEFT JOIN chunk c ON c.rid = r.rid
                WHERE r.seen_at <= ? GROUP BY r.tool""", (edge,)):
            db.execute("""INSERT OR REPLACE INTO index_history
                          (ts, tool, records, chunks) VALUES (?,?,?,?)""",
                       (float(edge), tool_row["tool"],
                        tool_row["records"], tool_row["chunks"]))
            written += 1
    db.commit()
    return written


def top_level_containers(parts, limit=None):
    """Fold a source's containers to their first path segment.

    🛑 ONLY `files` NEEDS THIS, and that is why it is not applied to every
    source. Every other adapter files a record under one flat name — an
    account, a mailbox, a calendar, a list. A file is filed under its whole
    relative folder, so this vault produced 49 rows, most of them a subfolder
    of another row, ordered by size. That answers "which folder is biggest",
    which is not the question anyone has. ⚠️ Folding mail the same way would
    throw away the mailbox and leave the account, and the mailbox is the half
    that says what is indexed.

    🛑 THE LIMIT APPLIES AFTER THE FOLD. Cutting the largest paths first and
    folding what survives reports a top-level folder short by everything past
    the cut — a wrong number, where a missing row is only a missing row.

    ⚠️ TWO ROOTS WITH A FOLDER OF THE SAME NAME MERGE HERE. They already did
    before this: a file at the root of a root is filed under the ROOT's name,
    which collides with a top-level folder of that name in another root.
    """
    folded = {}
    for part in parts:
        name = part["name"]
        # A container that is not a path — "(none)", a calendar name — is left
        # exactly as the caller wrote it.
        head = name.lstrip("/").split("/", 1)[0] or name
        entry = folded.setdefault(head, {"name": head, "records": 0,
                                         "chunks": 0})
        entry["records"] += part["records"]
        entry["chunks"] += part["chunks"]
    # ⚠️ Ties break on the name. Ordered by size alone, two folders of equal
    # size swap places between refreshes, which reads as data changing.
    out = sorted(folded.values(), key=lambda p: (-p["records"], p["name"]))
    return out[:limit] if limit else out


def cmd_places(opts):
    """Everywhere the user has been, from the two sources that know.

    🛑 TWO SOURCES, TWO UNITS, NEVER ADDED. `maps` records a genuine ARRIVAL,
    with a start time, from Maps' Visited Places. `photos` records that a
    camera was somewhere on some DAY. They measure different things, and the
    same place usually has both. Summing them would produce a number that means
    nothing — the same mistake the `people` report made once by adding emails
    to texts, and it is worse here because the two sources overlap.

    So a row that both sources know carries `visits` and `photo_days` side by
    side, each named after what it counts, and the caller picks one.

    ⚠️ NEITHER IS "WHERE YOU HAVE BEEN". Maps keeps 450 arrivals here; the
    photo library holds 27,603 located pictures over twenty-one years. Photos
    reaches back much further and misses everywhere the user did not take a
    picture. Maps sees only where Maps was running. Say which one an answer
    came from.

    ⚠️ THIS IS NOT Significant Locations, which belongs to `routined` under
    /var/db/locationd/ and no unprivileged process can read.
    """
    db = connect(opts.db)
    rows = list(db.execute(
        "SELECT tool, title, container, body, latitude, longitude, "
        "       created, occurred "
        "  FROM record "
        " WHERE kind = 'place' AND latitude IS NOT NULL "
        "   AND tool IN ('photos', 'maps')"))

    # A photo place already carries a day count; a maps place carries visits.
    # Neither is stored on the record, so both are counted back off the days
    # and visits that reference them.
    photo_days = {}
    for row in db.execute(
            "SELECT latitude, longitude, occurred FROM record "
            " WHERE tool = 'photos' AND kind = 'day' AND latitude IS NOT NULL"):
        key = "%.3f,%.3f" % (row["latitude"], row["longitude"])
        photo_days[key] = photo_days.get(key, 0) + 1
    visits = {}
    for row in db.execute(
            "SELECT latitude, longitude FROM record "
            " WHERE tool = 'maps' AND kind = 'visit' AND latitude IS NOT NULL"):
        key = "%.3f,%.3f" % (row["latitude"], row["longitude"])
        visits[key] = visits.get(key, 0) + 1

    places = []
    for row in rows:
        key = "%.3f,%.3f" % (row["latitude"], row["longitude"])
        lines = (row["body"] or "").split("\n")
        places.append({
            "name": row["title"],
            "where": lines[0] if lines else "",
            # 🛑 `container` MEANS A DIFFERENT THING IN EACH ADAPTER, and
            # reading it as a country for both put "Dining", "Transportation"
            # and "Travel Accommodation" in the country list — 65 countries
            # where the honest answer is 8. `maps` puts the place CATEGORY
            # there; only `photos` puts a country. A maps-only place has no
            # country here, and inventing one would be worse than saying so.
            "country": row["container"] if row["tool"] == "photos" else None,
            "latitude": row["latitude"], "longitude": row["longitude"],
            "sources": [row["tool"]],
            "photo_days": photo_days.get(key, 0) if row["tool"] == "photos" else 0,
            "visits": visits.get(key, 0) if row["tool"] == "maps" else 0,
            "first": row["created"], "last": row["occurred"],
        })

    # 🛑 ONE DOT PER PLACE. Without this the map drew a Maps pin and a photo
    # pin a few metres apart for every place the user both went to and
    # photographed, which reads as two places and inflates every count on
    # screen. The threshold is the same 250 m the clusters were built with.
    # ⚠️ `max`, NEVER `+`. A visit and a photo day are different units and must
    # not be added — this ordering exists only to decide which row anchors a
    # merge and which name survives, and it is not a measurement of anything.
    def weight(spot):
        return max(spot["photo_days"], spot["visits"])

    merged = []
    for spot in sorted(places, key=lambda s: -weight(s)):
        for kept in merged:
            if photos_metres(spot, kept) <= 250.0:
                kept["photo_days"] += spot["photo_days"]
                kept["visits"] += spot["visits"]
                for tool in spot["sources"]:
                    if tool not in kept["sources"]:
                        kept["sources"].append(tool)
                # 🛑 THE ANCHOR KEEPS ITS NAME. An earlier version preferred
                # the Maps name here, on the theory that Apple's directory
                # names a place better than a reverse-geocoded street number.
                # It renamed this user's HOME — 1,647 photo days, the largest
                # place in the library — after a charity's office 180 m away
                # with two recorded visits, because that office is what Maps
                # had a name for. A place is named by whichever source actually
                # knows it, and the loop below sorts that source first.
                if not kept["country"] and spot["country"]:
                    kept["country"] = spot["country"]
                if spot["first"]:
                    kept["first"] = min(kept["first"] or spot["first"],
                                        spot["first"])
                if spot["last"]:
                    kept["last"] = max(kept["last"] or spot["last"], spot["last"])
                break
        else:
            merged.append(spot)

    countries = {}
    for spot in merged:
        if spot["country"]:
            countries[spot["country"]] = countries.get(spot["country"], 0) + 1
    dated = [s["last"] for s in merged if s["last"]]
    report = {
        "generated": time.time(),
        "counts": {
            "places": len(merged),
            "countries": len(countries),
            "from_photos": sum(1 for s in merged if "photos" in s["sources"]),
            "from_maps": sum(1 for s in merged if "maps" in s["sources"]),
            "both": sum(1 for s in merged if len(s["sources"]) > 1),
        },
        "span": {"first": min((s["first"] for s in merged if s["first"]),
                              default=None),
                 "last": max(dated, default=None)},
        "countries": sorted(({"name": n, "places": k}
                             for n, k in countries.items()),
                            key=lambda c: -c["places"]),
        "places": sorted(merged, key=lambda s: -weight(s))[
            :(opts.limit or 4000)],
    }
    print(json.dumps(report, indent=2))


def photos_metres(a, b):
    """Distance between two place rows, in metres."""
    import math
    lat = math.radians((a["latitude"] + b["latitude"]) / 2.0)
    dx = math.radians(b["longitude"] - a["longitude"]) * math.cos(lat)
    dy = math.radians(b["latitude"] - a["latitude"])
    return 6371000.0 * math.hypot(dx, dy)


def cmd_stats(opts):
    """Everything the app's window needs, in one call.

    ⚠️ ONE COMMAND, not five. The window refreshes on a timer, and five
    subprocesses per tick is five python starts per tick.
    """
    db = connect(opts.db)
    backfill_history(db)

    sources = []
    for row in db.execute("""
            SELECT r.tool, COUNT(DISTINCT r.rid) records, COUNT(c.cid) chunks
            FROM record r LEFT JOIN chunk c ON c.rid = r.rid
            GROUP BY r.tool ORDER BY r.tool"""):
        # ⚠️ The container is the account, mailbox, list, calendar or folder.
        # It is what makes "what am I indexing" answerable rather than a total.
        # 🛑 NO SQL LIMIT FOR `files`. Its containers are folded to their top
        # level below, and folding a truncated list reports a folder short by
        # whatever fell past the cut. One row per distinct folder is a bounded
        # read either way.
        folds = row["tool"] == "files"
        parts = [{"name": p["container"] or "(none)",
                  "records": p["records"], "chunks": p["chunks"]}
                 for p in db.execute("""
            SELECT COALESCE(r.container,'') container,
                   COUNT(DISTINCT r.rid) records, COUNT(c.cid) chunks
            FROM record r LEFT JOIN chunk c ON c.rid = r.rid
            WHERE r.tool = ? GROUP BY r.container
            ORDER BY records DESC""" + ("" if folds else " LIMIT 60"),
            (row["tool"],))]
        if folds:
            parts = top_level_containers(parts, 60)
        state = db.execute("SELECT updated FROM source_state WHERE tool = ?",
                           (row["tool"],)).fetchone()
        sources.append({"tool": row["tool"], "records": row["records"],
                        "chunks": row["chunks"],
                        "updated": state["updated"] if state else None,
                        "containers": parts})

    history = [{"ts": h["ts"], "tool": h["tool"],
                "records": h["records"], "chunks": h["chunks"]}
               for h in db.execute(
                   "SELECT ts, tool, records, chunks FROM index_history "
                   "ORDER BY ts")]

    models = [{"model": m["model"], "vectors": m["c"]} for m in db.execute(
        "SELECT model, COUNT(*) c FROM vector GROUP BY model")]
    total_chunks = db.execute("SELECT COUNT(*) c FROM chunk").fetchone()["c"]
    size = sum(os.path.getsize(opts.db + s)
               for s in ("", "-wal", "-shm") if os.path.exists(opts.db + s))
    print(json.dumps({
        "version": tool_version(),
        "db": opts.db,
        "encrypted": index_is_encrypted(opts.db),
        "bytes": size,
        "chunks": total_chunks,
        "models": models,
        "sources": sources,
        "history": history,
        "retention_days": LOG_RETENTION_DAYS,
    }, indent=2))


# --------------------------------------------------------------------------
# who you talk to
# --------------------------------------------------------------------------
#
# `people` answers three questions the rest of the index cannot: who is in
# this data, who is in it TOGETHER, and when was each of them around. Every
# number here comes from records already indexed, plus two cheap subprocesses:
# Contacts, to turn a handle into a name, and call history, which is not an
# indexed source.
#
# ⚠️ It is not a diagnostic. Nothing in the window depends on it, and a
# failure here must never make the index look broken.

# A wide class of characters that MAY start an emoji. The presentation test
# below is what decides, not this class — matching widely and then filtering
# is what keeps `✓` and `♦` out of a list of favourite emoji. Both appear
# hundreds of times in mail signatures and newsletters, and both looked like
# top emoji until the filter existed.
_EMOJI_WIDE = ("\U0001F000-\U0001FAFF"
               "←-⇿⌀-⏿■-➿⬀-⯿"
               "©®™〰〽㊗㊙#*0-9")
_EMOJI_ELEMENT = "[%s](?:[\U0001F3FB-\U0001F3FF])?(?:️)?(?:⃣)?" % _EMOJI_WIDE
# 🛑 A FLAG IS TWO CODEPOINTS AND NOTHING JOINS THEM. Regional indicators carry
# no ZWJ and no variation selector, so the general rule below splits 🇺🇸 into
# two letters. It has to be matched first, on its own.
_EMOJI_FLAG = "[\U0001F1E6-\U0001F1FF]{2}"
EMOJI_RE = re.compile("(?:%s)|(?:%s)(?:‍(?:%s))*"
                      % (_EMOJI_FLAG, _EMOJI_ELEMENT, _EMOJI_ELEMENT))

# Emoji_Presentation: what renders as an emoji with no U+FE0F after it.
# Anything outside this set counts only when it carries one.
_EMOJI_PRESENT = re.compile(
    "[\U0001F300-\U0001FAFF\U0001F000-\U0001F02F\U0001F0A0-\U0001F0FF"
    "\U0001F100-\U0001F1FF"
    "⌚⌛⏩-⏬⏰⏳◽◾☔☕"
    "♈-♓♿⚓⚡⚪⚫⚽⚾⛄⛅"
    "⛎⛔⛪⛲⛳⛵⛺⛽✅✊✋"
    "✨❌❎❓-❕❗➕-➗➰➿"
    "⬛⬜⭐⭕]")


def emoji_in(text):
    """Every emoji in one string, as whole clusters.

    ⚠️ CLUSTERS, not codepoints. 👨‍👩‍👧‍👦 is one emoji and four people; 👍🏽 is one
    emoji and two codepoints. Counting codepoints reports a family as four
    separate faces and a skin tone as its own entry.
    """
    found = []
    for match in EMOJI_RE.finditer(text):
        cluster = match.group(0)
        if "️" in cluster or "‍" in cluster or _EMOJI_PRESENT.match(cluster):
            found.append(cluster)
    return found


_ANGLE_ADDRESS = re.compile(r"<([^>]+)>")


def split_handle(raw):
    """`"Ada <ada@x.com>"` to `("Ada", "ada@x.com")`.

    ⚠️ MAIL SPELLS ONE PERSON TWO WAYS. An author arrives as a display name
    with the address in angle brackets, a recipient as the bare address. Left
    unsplit, one person becomes two rows and neither carries their real count.
    """
    raw = (raw or "").strip()
    match = _ANGLE_ADDRESS.search(raw)
    if match:
        return raw[:match.start()].strip().strip('"'), match.group(1).strip().lower()
    return "", raw.strip('"').lower()


def phone_key(raw):
    """The last ten digits of a phone number, or a short code as it stands."""
    digits = re.sub(r"\D", "", raw or "")
    if not digits:
        return ""
    return digits[-10:] if len(digits) > 10 else digits


def handle_key(raw):
    """A stable key for one handle, plus whatever name came with it.

    ⚠️ A PHONE NUMBER IS NOT NORMALISED IN ANY STORE HERE. `chat.db` keeps
    `+13035550123` and Contacts keeps `(303) 555-0123`. Comparing the strings
    matches nothing, so both go through the digits.
    """
    # 🛑 TESTED BEFORE `split_handle`, WHICH LOWERCASES. A Contacts id is a
    # UUID, and `apple contacts get` will not take a lower-cased one. Checked
    # after the split, `…-F074D8875BBE:ABPerson` arrived as `…:abperson`, fell
    # through to the phone branch, and `phone_key` reduced the UUID's digits to
    # a ten-digit "number": 5940748875. That is not a near miss — it is a
    # plausible-looking phone key, so the person merged into whoever really
    # owns that number rather than failing loudly. One real contact was folded
    # into a stranger's row that way.
    raw = (raw or "").strip()
    if raw.endswith(":ABPerson"):
        return raw, ""
    # ⚠️ A face Photos names but Contacts does not know keeps a name-derived
    # key, because there is no card to fold it onto. The case is kept: this is
    # the only name that person will ever be shown under.
    if raw.startswith("photos:"):
        return raw, raw[len("photos:"):]
    name, handle = split_handle(raw)
    # ⚠️ A percent-encoded display name reaches the index as written.
    # "Matt%20%26%20Jennifer" is one real couple, and it is what the window
    # would have shown.
    if "%" in name:
        name = urllib.parse.unquote(name)
    if not handle:
        return "", ""
    if "@" in handle:
        return handle, name
    digits = phone_key(handle)
    if digits:
        return digits, name
    # 🛑 Neither an address nor a number is not a handle. `To:` headers carry
    # "undisclosed-recipients:;", which otherwise becomes a person you have
    # written to 200 times.
    return "", ""


def contact_identities():
    """Every email and phone this Mac knows, mapped to one contact.

    ⚠️ FIRST CARD WINS. Two cards can claim one address — a duplicate, or a
    shared family address — and picking either is better than splitting the
    person in two.
    """
    rows = apple("contacts", "list", "--limit", 100000, allow_fail=True) or []
    identities, aliases, companies, parts = {}, {}, set(), {}
    for row in rows:
        cid = row.get("id")
        name = (row.get("name") or "").strip()
        if not cid or not name or name == "<unnamed>":
            continue
        if is_company_card(row):
            companies.add(cid)
        aliases[cid] = card_names(row)
        parts[cid] = ((row.get("first_name") or "").strip().lower(),
                      (row.get("last_name") or "").strip().lower())
        # 🛑 THE CARD'S OWN ID IS AN IDENTITY. `photos` hands over
        # `UUID:ABPerson` and nothing else, so without this line a tagged face
        # became a stranger with `known: false` and never merged with the same
        # person's mail.
        identities.setdefault(cid, (cid, name))
        for entry in row.get("emails") or []:
            key = (entry.get("address") or "").strip().lower()
            if key:
                identities.setdefault(key, (cid, name))
        for entry in row.get("phones") or []:
            key = phone_key(entry.get("number"))
            if key:
                identities.setdefault(key, (cid, name))
    return identities, aliases, companies, parts


def is_company_card(row):
    """Is this card a business rather than a person?

    Contacts.app has a "Company" checkbox on every card, and it is the only
    reliable answer: a company card carries emails, phones and an address
    exactly like anyone else. 71 of the 694 cards here have it set, including
    every one the user named — PayPal, Venmo, Chase, United Airlines.

    ⚠️ THE CHECKBOX IS OFTEN LEFT OFF. A card with an organisation name and no
    personal name is a business whatever the checkbox says. Measured: 2 more
    here, State Farm and an elementary school, and **none** of the cards that
    rule catches carries a first name or a nickname — so it cannot take a
    person with it.
    """
    if row.get("is_company"):
        return True
    return bool(row.get("company")) and not (row.get("first_name")
                                             or row.get("last_name"))


def card_names(row):
    """Every name one card answers to.

    🛑 A PERSON WHO CHANGED THEIR NAME IS TWO PEOPLE IN THIS DATA, and no
    amount of address matching finds them. Measured here: one card reads
    "Stephanie Hopkins" and holds six handles; an old address signing itself
    "Steph Anderson" carried 568 more encounters from 2006 to 2012, under its
    own row, ending exactly where the other begins.

    The name they used before is `previous_family_name`, which Contacts.app
    labels "Maiden Name". The neutral word is the right one here: the same
    field carries a name changed by a second marriage, a divorce, an adoption
    or a deed poll.

    ⚠️ THE PREVIOUS FAMILY NAME ALONE IS NOT THE NAME THAT ARRIVES. Mail
    signed itself "Steph Anderson" — the NICKNAME and the previous family
    name — so both halves have to be crossed. Four names come off a card:
    given+family, given+previous, nickname+family, nickname+previous.

    ⚠️ It is only ever a claim. `merge_by_name` still refuses a name that two
    cards both answer to.
    """
    first = (row.get("first_name") or "").strip()
    nick = (row.get("nickname") or "").strip()
    last = (row.get("last_name") or "").strip()
    previous = (row.get("previous_family_name") or "").strip()
    names = {(row.get("name") or "").strip()}
    for given in (first, nick):
        for family in (last, previous):
            if given and family:
                names.add("%s %s" % (given, family))
    return {n for n in names if n}


def my_handles(db, identities, card_parts, overrides):
    """Every handle that is the user, and how each one was decided.

    🛑 A SHARE-OF-RECIPIENTS THRESHOLD ALONE IS WRONG, and the numbers say so.
    Measured on this store: the user's own gmail address is on 54.2% of mail,
    but a spouse is on 24.0% of calendar events and a colleague on 23.0%. Any
    threshold low enough to be useful across sources sweeps both of them in,
    and a person counted as the user vanishes from their own social graph.

    So the accounts are read from Mail, which is certain, and exactly one more
    address may be inferred: the top recipient that no account already claims,
    and only when it is on 30% of mail AND at least three times the runner-up.
    Here that is 54.2% against 10.3%, and it names the one address Mail cannot
    know about. Everything inferred is reported, so a wrong guess is visible
    rather than silent.
    """
    known, detected = {"me"}, []
    # 🛑 THE USER'S OWN ANSWER FIRST, before anything is inferred from it. An
    # address they have said is theirs is theirs, and it may be the only clue
    # that a whole domain or a service endpoint belongs to them.
    known |= {h for h, kind in overrides.items() if kind == "me"}
    # ⚠️ `--json`, because `apple mail accounts` prints a human table by
    # default. Without it the parse fails, `allow_fail` returns nothing, and
    # every account address quietly stops counting as the user — which put the
    # user second in their own list of people.
    for account in apple("mail", "accounts", "--json", allow_fail=True) or []:
        for address in account.get("addresses") or []:
            known.add(address.strip().lower())
        if account.get("email"):
            known.add(account["email"].strip().lower())

    counts, records = {}, 0
    for row in db.execute("SELECT people FROM record WHERE tool = 'mail' "
                          "AND people NOT IN ('', '[]')"):
        records += 1
        seen = set()
        for person in json.loads(row["people"]):
            if person.get("role") != "recipient":
                continue
            key, _ = handle_key(person.get("handle"))
            if key and key not in known:
                seen.add(key)
        for key in seen:
            counts[key] = counts.get(key, 0) + 1

    if records:
        ranked = sorted(counts.items(), key=lambda kv: -kv[1])[:2]
        if ranked and ranked[0][1] >= 0.30 * records and (
                len(ranked) < 2 or ranked[0][1] >= 3 * ranked[1][1]):
            detected.append(ranked[0][0])
            known.add(ranked[0][0])

    # 🛑 THE USER'S OWN CARD FINISHES THE JOB. Mail knows the three accounts
    # that still collect mail; the card knows every address the user has ever
    # had. Measured here: one card carries 14 handles — old employers, a
    # university address, two dead photo services — and every one of them
    # counted as somebody else. The user ranked as his own second-closest
    # correspondent, with 789 encounters, under his own name.
    #
    # ⚠️ A CARD IS CLAIMED BY ONE MATCH, not by its name. Names repeat inside a
    # family; an address does not.
    cards, named = {}, {}
    for handle, (cid, name) in identities.items():
        cards.setdefault(cid, set()).add(handle)
        named[cid] = name
    my_names, my_parts = set(), set()
    for cid, handles in cards.items():
        if handles & known:
            known |= handles
            my_names.add(named.get(cid, ""))
            given, family = card_parts.get(cid, ("", ""))
            if given and family:
                my_parts.add((given, family))

    # 🛑 THE USER'S OWN FACE ARRIVES ON A CARD WITH NOTHING TO MATCH ON. Photos
    # links a tagged face to a contact by id, and the card it links this user's
    # own face to is a bare local one: the right name, no email, no phone. So
    # no handle rule above can ever claim it, and the user was drawn SIXTH in
    # his own list of people, with 3,005 photographs of himself.
    #
    # ⚠️ Photos itself cannot settle this. `ZPERSON.ZISMECONFIDENCE` exists and
    # is empty on every row of this library, so there is no "me" flag to read.
    #
    # ⚠️ A NAME MATCH, WHICH IS THE RISKY KIND, so it is fenced twice. The card
    # must answer to a name one of the user's real cards already answers to,
    # AND it must carry no address and no number of its own — a relative who
    # shares a name almost always has one. Every card taken this way is
    # reported in `me.by_card`, never absorbed silently, because a person who
    # has quietly become "the user" is exactly what nobody would notice.
    wanted_names = {re.sub(r"[^a-z0-9]+", " ", n.lower()).strip()
                    for n in my_names}
    by_card = []
    for cid, handles in cards.items():
        if cid in known or handles & known:
            continue
        # ⚠️ THE SAME STEM RULE `is_me_by_name` USES, and it has to be. The
        # user's real card reads "Dan Hopkins"; the card Photos tagged his face
        # against reads "Daniel Hopkins". An exact-name test matched neither.
        if not is_me_by_name(named.get(cid, ""), wanted_names, my_parts):
            continue
        if any(h != cid for h in handles):
            continue
        known |= handles
        by_card.append(cid)
    return known, detected, {n for n in my_names if n}, my_parts, by_card


def adopt_photo_cards(people, aliases, companies):
    """Give a tagged face the contact card that shares its name.

    🛑 PHOTOS ONLY CARRIES A CONTACTS ID WHEN THE USER CONFIRMED ONE IN
    PHOTOS.APP, and on this library 16 of the 63 named faces have none. Those
    people arrive under a `photos:<name>` handle and read as strangers — even
    when a card for them is sitting in Contacts with a birthday on it.
    Measured: Natalie Hasson, Kate Auda and Mary Hopkins all have cards, all
    three were reported as unknown, and one of them has been in the address
    book since 2007.

    🛑 `merge_by_name` CANNOT DO THIS, and the reason is not obvious. It builds
    its table of claimable names out of the people already in the report, so a
    card only becomes claimable once some mail, message, call or event already
    named that person. A child who has never sent anything has a card and no
    records, so the card is invisible to it. This pass builds the table from
    every card in Contacts instead.

    ⚠️ WHY THIS IS SAFE HERE AND WOULD NOT BE FOR MAIL. A tagged face's name
    was typed by the user, in their own library, onto a face they recognised.
    A display name on an email is typed by the sender. Widening `merge_by_name`
    to every card would let a stranger who signs themselves "John Smith" adopt
    a real John Smith's card, which is why it is not widened.

    Three fences:
      * the entry's ONLY channel is photos — anything with an address or a
        number has already had a better chance to match, and did not
      * exactly one card answers to that name; two is refused, because two
        people really can share a name and the wrong merge is worse than none
      * the card is not marked as a business

    Returns the old-id to new-id map, so the caller can repoint the edges.
    """
    def norm(value):
        return " ".join(sorted(
            re.sub(r"[^a-z0-9]+", " ", (value or "").lower()).split()))

    claims = {}
    for cid, names in aliases.items():
        if cid in companies:
            continue
        for claim in names:
            claims.setdefault(norm(claim), set()).add(cid)

    moved = {}
    for entry in list(people.values()):
        if entry["known"] or list(entry["channels"]) != ["photos"]:
            continue
        owners = claims.get(norm(entry["name"]), set())
        if len(owners) != 1:
            continue
        cid = next(iter(owners))
        target = people.get(cid)
        if target is None:
            # ⚠️ RE-KEYED IN PLACE. The card has no records of its own, which
            # is the whole reason this pass exists, so there is nothing to
            # fold into — the entry simply becomes that card's row.
            del people[entry["id"]]
            moved[entry["id"]] = cid
            entry["id"] = cid
            entry["known"] = True
            people[cid] = entry
        else:
            moved[entry["id"]] = cid
            absorb(target, entry)
            del people[entry["id"]]
    return moved


def merge_by_name(people, aliases):
    """Fold an unnamed-by-Contacts address into the card that shares its name.

    🛑 ONE PERSON, TWO CIRCLES. A twenty-year correspondent writes from an old
    address that no card claims and a new one that does, and the graph drew
    "Cat Cantor" twice, side by side, with the encounters split between them.

    ⚠️ The name has to match a card EXACTLY, ignoring case and punctuation, and
    exactly ONE card may claim it. Two people really can share a name, and
    merging the wrong pair is worse than drawing two circles.

    Returns the old-id to new-id map, so the caller can repoint the edges.
    """
    def norm(value):
        """A name, comparable however it is written.

        🛑 THE WORDS ARE SORTED, because a directory writes a name backwards.
        "Leopold, Robin" and "Robin Leopold" are one person with two addresses,
        and so are "Lee, Ming-Ming" and "Ming-Ming Lee" — 208 such pairs on this
        store. Comparing the strings in order matches none of them.

        ⚠️ SAFE ONLY BECAUSE A CARD MUST CLAIM THE NAME. Seven different
        companies here sign themselves "Support"; sorting words makes all seven
        agree, and not one of them has a contact card, so nothing merges. The
        card requirement below is what carries this, not the normalisation.
        """
        return " ".join(sorted(
            re.sub(r"[^a-z0-9]+", " ", (value or "").lower()).split()))

    # ⚠️ A SET OF IDS, not a list. One card claims up to four names and two of
    # them can normalise to the same string, which appended the same id twice
    # and made the card look like two cards fighting over one name — blocking
    # exactly the merge this exists to allow.
    cards = {}
    for entry in people.values():
        if not entry["known"]:
            continue
        # Every name the card answers to, not only the one it displays.
        for claim in aliases.get(entry["id"], set()) | {entry["name"]}:
            cards.setdefault(norm(claim), set()).add(entry["id"])

    moved = {}
    for entry in list(people.values()):
        if entry["known"]:
            continue
        claimed = cards.get(norm(entry["name"]), set())
        if len(claimed) != 1:
            continue
        target = people[next(iter(claimed))]
        moved[entry["id"]] = target["id"]
        absorb(target, entry)
        del people[entry["id"]]
    return moved


def merge_namesakes(people):
    """Fold together addresses with no card that share a full name.

    🛑 ONE PERSON, FIVE ADDRESSES. Work, personal, a role address at the same
    charity, and the one at the employer they left. `John Giffin` appears five
    times here, `Xin Zheng` three, `Staci Ruddy` three — and none of them has a
    contact card, so `merge_by_name` cannot help: it needs a card to fold into.
    Measured: 154 such groups covering 379 rows, and **every one of the
    fourteen largest is plainly the same person**.

    ⚠️ TWO WORDS AT LEAST, and that is the whole guard. Seven different
    companies here sign themselves "Support"; a single word is not a name.

    ⚠️ IT CAN STILL BE WRONG. Two strangers who share a full name and have no
    cards get folded together. Nothing on this store does, and the cost of the
    alternative — one person drawn five times — is paid on every screen. The
    fix for a bad one is a contact card, which beats this.
    """
    def norm(value):
        return " ".join(sorted(
            re.sub(r"[^a-z0-9]+", " ", (value or "").lower()).split()))

    groups = {}
    for entry in people.values():
        if entry["known"]:
            continue
        name = norm(entry["name"])
        if len(name.split()) < 2:
            continue
        groups.setdefault(name, []).append(entry)

    moved = {}
    for members in groups.values():
        if len(members) < 2:
            continue
        # The busiest keeps its id, so anything already pointing at that
        # person stays valid.
        members.sort(key=lambda e: -len(e["days"]))
        target = members[0]
        for entry in members[1:]:
            moved[entry["id"]] = target["id"]
            absorb(target, entry)
            del people[entry["id"]]
    return moved


def absorb(target, entry):
    """Fold one person's record into another's."""
    target["handles"] |= entry["handles"]
    target["same_list"] += entry["same_list"]
    for channel, count in entry["alone"].items():
        target["alone"][channel] = target["alone"].get(channel, 0) + count
    target["upcoming"] += entry["upcoming"]
    for field in ("mail_from", "mail_to", "mail_bulk", "mail_seen"):
        target[field] += entry[field]
    target["rids"] = (target["rids"] + entry["rids"])[:80]
    # ⚠️ A UNION, NOT A SUM. Both rows can hold the same day — the day a
    # name change was announced is exactly such a day — and adding the
    # counts would report it twice.
    target["days"] |= entry["days"]
    for channel, days in entry["channel_days"].items():
        target["channel_days"].setdefault(channel, set()).update(days)
    for channel, count in entry["channels"].items():
        target["channels"][channel] = target["channels"].get(channel, 0) + count
    for month, days in entry["months"].items():
        target["months"].setdefault(month, set()).update(days)
    for spelling, count in entry["names"].items():
        target["names"][spelling] = target["names"].get(spelling, 0) + count
    for edge in ("first", "last"):
        if entry[edge] is None:
            continue
        if target[edge] is None:
            target[edge] = entry[edge]
        else:
            target[edge] = (min(target[edge], entry[edge]) if edge == "first"
                            else max(target[edge], entry[edge]))


# 🛑 THE ESCAPE HATCH FOR A BUSINESS WITH NO CONTACT CARD. Ticking "Company"
# on a card is the right fix when a card exists — but Mint, which ranked 17th
# here on 244 days, has no card at all, and inventing one to hold a tick box
# is clutter in the place the user actually reads.
#
# 🛑 `_SUPPORT`, NEVER `dirname(DEFAULT_DB)`. That path FOLLOWS THE VAULT: when
# the encrypted image is mounted it resolves inside it, so a file written there
# is unreadable whenever AppleTools is not running and is **destroyed by
# `apple-index forget`**, which deletes the image. A ruling the user typed must
# outlive the index it is about. Measured: the first version of this landed in
# `mnt/` for exactly that reason.
#
# ⚠️ IT WORKS BOTH WAYS. `--is-a-person` rescues somebody the rules exclude
# wrongly, which matters more than the other direction: a business left in is
# visible, and a person taken out is not.
PEOPLE_CONFIG = os.path.join(_SUPPORT, "people.json")


def people_overrides():
    """Handles the user has ruled on: handle -> 'business' or 'person'."""
    try:
        with open(PEOPLE_CONFIG) as handle:
            config = json.load(handle)
    except (OSError, ValueError):
        return {}
    out = {}
    for kind in ("business", "person", "me"):
        for raw in config.get(kind) or []:
            key, _ = handle_key(raw)
            if key:
                out[key] = kind
    return out


def write_overrides(business, person, me=()):
    """Record a ruling. Returns the lines to print."""
    try:
        with open(PEOPLE_CONFIG) as handle:
            config = json.load(handle)
    except (OSError, ValueError):
        config = {}
    said = []
    for kind, raws in (("business", business), ("person", person), ("me", me)):
        others = [k for k in ("business", "person", "me") if k != kind]
        for raw in raws:
            key, _ = handle_key(raw)
            if not key:
                die("not a handle: %s" % raw)
            # ⚠️ One answer per handle. Saying "business" removes an earlier
            # "person" rather than leaving the two to fight.
            for other in others:
                config[other] = [h for h in config.get(other) or []
                                 if handle_key(h)[0] != key]
            current = config.setdefault(kind, [])
            if key in {handle_key(h)[0] for h in current}:
                said.append("%s is already recorded as a %s" % (key, kind))
                continue
            current.append(key)
            said.append("%s recorded as a %s" % (key, kind))
    if said:
        with open(PEOPLE_CONFIG, "w") as handle:
            json.dump(config, handle, indent=2)
        os.chmod(PEOPLE_CONFIG, 0o600)
    return said


# 🛑 A LOCAL PART NO PERSON EVER READS. Conservative on purpose: `office@`,
# `info@` and `contact@` are NOT here, because a small charity's office
# address really is answered by one person, and two in this store are.
NO_REPLY = re.compile(
    r"^(no[._-]?reply|do[._-]?not[._-]?reply|auto[-_.]?confirm|mailer[-_]daemon"
    r"|bounce|unsubscribe|notifications?|alerts?|offers|newsletter|receipts"
    r"|billing|postmaster)([-_.+].*)?$", re.I)


# ⚠️ READ ONCE, so every record in one run is measured against the same
# instant. Calling time.time() per record makes "today" drift during a run.
NOW = time.time()


def is_me_by_name(name, wanted, my_parts):
    """Does this display name belong to the user, going by their own card?

    🛑 THE FORMAL NAME IS NOT ON THE CARD. The card here reads "Dan Hopkins",
    and seven old addresses sign themselves "Daniel Hopkins" — two former
    employers, an old hotmail, a machine hostname. An exact-name test misses
    every one, and they show up as somebody the user talks to, in a search for
    their own family name.

    So the family name must match exactly, and the given name must be a stem of
    the card's or the card's a stem of it — "Dan" inside "Daniel". At least
    three characters, so an initial cannot claim a stranger.

    ⚠️ A RELATIVE WITH THE SAME NAME WOULD BE TAKEN TOO. Measured here: seven
    matches, all of them the user, and no other Hopkins on this store has a
    given name beginning "Dan". Every address it takes is reported in
    `me.by_name`, so a wrong one is visible rather than silent.
    """
    flat = re.sub(r"[^a-z0-9]+", " ", (name or "").lower()).strip()
    if flat in wanted:
        return True
    words = flat.split()
    if len(words) < 2:
        return False
    given, family = words[0], words[-1]
    for card_given, card_family in my_parts:
        if family != card_family:
            continue
        short, long = sorted([given, card_given], key=len)
        if len(short) >= 3 and long.startswith(short):
            return True
    return False


# One day. ⚠️ The report changes when the INDEX changes, not on a clock, so
# this is a ceiling on staleness rather than a schedule. The app refreshes it
# after an indexing cycle once a day; a ruling refreshes it at once.
PEOPLE_MAX_AGE = 24 * 3600


def _duration(seconds):
    if seconds < 90:
        return "%.1fs" % seconds
    if seconds < 5400:
        return "%d min" % (seconds / 60)
    if seconds < 36 * 3600:
        return "%d h" % (seconds / 3600)
    return "%d days" % (seconds / 86400)


def read_people_cache(db, max_age):
    """The stored report, or None when there is none or it is too old."""
    try:
        row = db.execute("SELECT computed_at, payload FROM people_cache "
                         "WHERE one = 1").fetchone()
    except sqlite3.OperationalError:
        return None                      # an index older than this table
    if row is None:
        return None
    if max_age is not None and time.time() - row["computed_at"] > max_age:
        return None
    try:
        report = json.loads(row["payload"])
    except ValueError:
        return None
    # ⚠️ SAY IT CAME FROM THE CACHE, and when it was made. A reader who cannot
    # tell a stored answer from a fresh one cannot tell a stale one either.
    report["cached"] = True
    report["computed"] = row["computed_at"]
    return report


def write_people_cache(db, report):
    db.execute("INSERT INTO people_cache (one, computed_at, payload) "
               "VALUES (1, ?, ?) ON CONFLICT(one) DO UPDATE SET "
               "computed_at = excluded.computed_at, payload = excluded.payload",
               (report["generated"], json.dumps(report)))
    db.commit()


def _tally(reasons):
    counts = {}
    for reason in reasons:
        counts[reason] = counts.get(reason, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: -kv[1]))


def is_bounce_path(handle, mine):
    """A return path that carries the user's own address inside it.

    🛑 VERP ENCODES THE RECIPIENT IN THE SENDER. A newsletter bounce arrives
    from `bounces+3371362-2618-danielhopkins=gmail.com@mailer.example`, and
    that address is not a person — it is the user's own address written into
    somebody's return path. 16 of them here, one day each, all of them showing
    up in a search for the user's own family name.

    ⚠️ It cannot be a false positive: the address literally contains the
    user's, with the `@` replaced by `=`.
    """
    local = handle.rsplit("@", 1)[0]
    return any("@" in address and address.replace("@", "=") in local
               for address in mine)


# 🛑 FORTY EMAILS, NEVER ONCE ANSWERED. Measured on this store: every real
# correspondent in the top sixty has written back at least twice, and the five
# transactional senders that survived every other rule — a proxy-vote service,
# a credit union's contact centre, Amazon shipping, QuickBooks, a newsletter —
# have exactly zero. At forty the volume settles it on its own: somebody you
# have never answered forty times is not somebody you talk to.
BULK_CERTAIN = 40
# ⚠️ Below that, volume is not enough — two of this school's teachers wrote 16
# and 19 times and were never answered, and they are people. So the weaker tier
# needs a second reason, and a guard.
BULK_LIKELY = 12
BULK_MARKER = re.compile(
    r"unsubscribe|view (this|it) (email|in your browser)|do not reply"
    r"|automated (message|email|notification)|manage your (preferences|subscription)"
    r"|update your preferences|no longer wish to receive", re.I)
_NAME_TOKEN = re.compile(r"[a-z0-9]+")


def carries_own_name(handle, name):
    """Is this person's own name inside their address?

    🛑 THE TOKEN MUST BE ABSENT FROM THE DOMAIN, and that is the whole test.
    `nancy.s@…boulderjourneyschool.com` carries "nancy", which the domain does
    not — a person. `chase@emailinfo.chase.com` carries "chase", which the
    domain does too — a brand writing from its own name. Without that clause
    the guard spared Chase, NYT, Northwestern Mutual and AT&T.

    ⚠️ FOUR CHARACTERS AT LEAST. "ent" is a substring of "estatements", which
    made Ent Credit Union look like somebody signing their own name.

    ⚠️ It errs toward keeping a person: a real English word in a local part
    ("connect@ironman.com" against the name "Ironman|Connect") is spared. That
    is the right direction to be wrong in.
    """
    if "@" not in handle:
        return False
    local, _, domain = handle.lower().partition("@")
    if (name or "").strip().lower() == handle.strip().lower():
        return False                      # the "name" is just the address
    for token in _NAME_TOKEN.findall((name or "").lower()):
        if len(token) >= 4 and token in local and token not in domain:
            return True
    return False


def not_a_person(entry, overrides=None, mine=()):
    """Why this handle should not be drawn as somebody the user talks to.

    Returns a reason, or None to keep them. Every one is reported rather than
    dropped silently, because each rule can be wrong about somebody.

      marked         the user said so — `people --not-a-person <handle>`
      bounce         a return path carrying the user's own address
      never-answered 40+ emails and not one reply, ever. 🛑 The one rule that
                     reads the RELATIONSHIP rather than the address
      bulk-mail      12+ emails, never answered, a newsletter footer on half of
                     them, and the address does not carry their own name
      company        the card is marked as a business, or names one and no
                     person. 🛑 THE USER'S OWN ESCAPE HATCH: tick "Company" on
                     a card in Contacts, or run `apple contacts edit <id>
                     --company-card`, and it stops being drawn here
      short-code     an SMS short code. 🛑 A five-digit number cannot be a person
      no-reply       an address written by a machine
      calendar-feed  a Google Calendar system address, not a guest
      list           many display names and none of them dominant

    ⚠️ ONLY `list` LOOKS AT BEHAVIOUR. The other three read the handle or the
    card, so they cannot be fooled by a quiet year or a chatty one.
    """
    # 🛑 THE USER'S OWN ANSWER WINS, in both directions and over every rule
    # below. They can see the list; the rules cannot.
    ruling = (overrides or {}).get(entry["handle"])
    if ruling == "business":
        return "marked"
    if ruling == "person":
        return None
    if entry.get("card_is_company"):
        return "company"
    handle = entry["handle"]
    if is_bounce_path(handle, mine):
        return "bounce"
    if "@" not in handle and handle.isdigit() and 3 <= len(handle) <= 6:
        return "short-code"
    # 🛑 TRANSACTIONAL MAIL, DECIDED BY RECIPROCITY. A person writes back. Every
    # rule above reads the handle or the card; this one reads the relationship,
    # so it catches a sender whose address and name look exactly like a
    # person's — "Sharon Halkovics", "NORTHWESTERN MUTUAL", "Boulder Reporting
    # Lab" — and it cannot be fooled by a friendly From line.
    #
    # ⚠️ MAIL ONLY. A text or a call is two-way by its nature, so a handle with
    # either is never judged this way.
    if not (entry.get("channels", {}).get("messages")
            or entry.get("channels", {}).get("phone")):
        if entry.get("mail_to") == 0 and "@" in handle:
            if entry.get("mail_from", 0) >= BULK_CERTAIN:
                return "never-answered"
            if (entry.get("mail_from", 0) >= BULK_LIKELY
                    and entry.get("mail_bulk", 0)
                        >= 0.5 * max(entry.get("mail_seen", 0), 1)
                    and not carries_own_name(handle, entry.get("name", ""))):
                return "bulk-mail"

    if "@" in handle:
        local, _, domain = handle.partition("@")
        if NO_REPLY.match(local):
            return "no-reply"
        # 🛑 A CALENDAR FEED IS NOT A GUEST. Google puts three system addresses
        # in the organiser and attendee fields: `unknownorganizer@` on an event
        # whose owner it cannot name, and a `...@group.calendar.google.com`
        # or `...@resource.calendar.google.com` for a subscribed calendar or a
        # meeting room. Three of them ranked inside the top sixty here, one of
        # them above real people.
        if domain.endswith("calendar.google.com"):
            return "calendar-feed"
    return classify_bulk(entry)


def classify_bulk(entry):
    """Is this address a mailing list rather than a person?

    🛑 THE DISPLAY NAME IS WHAT GIVES IT AWAY, and counting distinct spellings
    alone is not enough. Measured on this store, normalising the name first
    and then asking which spelling DOMINATES separates the two cleanly:

        notifications@github.com    51 names, top 23%   robot
        info@meetup.com             35 names, top 14%   robot
        invitations@linkedin.com    73 names, top 41%   robot
        musicalhands@comcast.net     3 names, top 75%   a person
        whopkins44@gmail.com         3 names, top 70%   a person

    A raw count of spellings put all five in the same bucket, because a real
    correspondent of twenty years signs themselves "Cat Cantor", "cat cantor"
    and "musicalhands", and that already looked like a robot.

    ⚠️ Only ever applied to an address with NO contact card, so nobody in
    Contacts can be hidden by it.
    """
    if entry["known"]:
        return None
    spellings = {}
    for raw, count in entry["names"].items():
        key = re.sub(r"[^a-z0-9]+", " ", raw.lower()).strip()
        if key:
            spellings[key] = spellings.get(key, 0) + count
    if len(spellings) < 5:
        return None
    if max(spellings.values()) < 0.5 * sum(spellings.values()):
        return "list"
    return None


# 🛑 A CLIQUE CAP, because a co-occurrence edge is quadratic. One real calendar
# event here carries 97 attendees, which on its own is 4,656 edges — more than
# every genuine pair in the graph put together, all of them saying nothing but
# "these people were on one invitation". A record with more people than this
# still counts toward each person's own total; it just draws no edges.
EDGE_CLIQUE_CAP = 12


def is_direct(tool, author, key, others, mine):
    """Did one of us write to the other, or were we both on somebody's list?

    🛑 THE TEST IS PER PERSON, NOT PER RECORD, and getting that wrong silently
    undid the whole correction. An earlier version asked whether the author
    was among the other people on the record — which is true of almost every
    email, because the author IS one of the others unless the user wrote it.
    Every mail counted as direct, and `same_list` came back 0 for people whose
    mail was 80% newsletters. Nothing in the output said so.

    An event is shared by definition, so it always counts. An email counts for
    one person only when the user wrote it or THAT person wrote it, and never
    when it went to more people than a conversation holds — the same cap the
    edges use, which also catches a mass mail the user sent themselves.
    """
    if tool == "calendar":
        return True
    if others > EDGE_CLIQUE_CAP:
        return False
    return author in mine or author == key


def cmd_people(opts):
    """Who you talk to, who they overlap with, and which emoji you use.

    🛑 THE HEADLINE IS DAYS, NOT ITEMS, and that is the whole correction. The
    first version counted indexed records and called the sum "encounters",
    which reported a spouse at 9,059. Three things were wrong with it:

      1. A record is a different SIZE in every source. One mail record is one
         email; one messages record is a block of TEN texts; one calendar
         record is one event. Summing them means nothing. Measured: 3,024
         message blocks for one person held 30,395 actual texts.
      2. **Being on the same list is not talking.** 3,118 of the 5,751 emails
         naming that person — 54% — were written by a third party to both of
         them. A school newsletter to forty parents counted as an encounter
         with each one.
      3. A count of items rewards whoever texts in bursts. Forty texts in one
         evening is one conversation.

    A DAY is the same unit in every source and cannot be inflated by volume.
    Measured on this store: a spouse of twenty years comes out at 3,107 days,
    about two days in five, and a committee colleague at 470. Both survive a
    sanity check, which 9,059 did not.

    ⚠️ The per-channel counts are still reported, each in its OWN unit —
    emails, texts, events, calls — because "we exchanged 30,395 texts" is a
    true and interesting sentence. What must not happen is adding it to
    anything.
    """
    said = write_overrides(opts.not_a_person or [], opts.is_a_person or [],
                           opts.me or [])
    for line in said:
        sys.stderr.write("  %s\n" % line)
    overrides = people_overrides()

    started = time.time()
    db = connect(opts.db)

    # 🛑 A RULING MUST NOT WAIT FOR THE CLOCK. Marking Mint as a business and
    # seeing nothing change for a day is indistinguishable from the flag not
    # working, so any ruling forces the recompute it implies.
    stale = bool(said) or opts.refresh
    if not stale:
        cached = read_people_cache(
            db, None if opts.max_age < 0 else (opts.max_age or PEOPLE_MAX_AGE))
        if cached is not None:
            # ⚠️ `--ensure` is for the SCHEDULER, which wants the work done and
            # not the three megabytes of JSON that prove it.
            if opts.ensure:
                age = time.time() - cached["computed"]
                print("people: cached, %s old" % _duration(age))
            else:
                print(json.dumps(cached, indent=2))
            return
    identities, aliases, companies, card_parts = contact_identities()
    mine, detected, my_names, my_parts, my_cards = my_handles(
        db, identities, card_parts, overrides)
    top = opts.top or 80

    people = {}
    edges = {}

    def person(key, name):
        """The record for one person, created on first sight."""
        cid, known_name = identities.get(key, (None, ""))
        pid = cid or ("handle:" + key)
        entry = people.get(pid)
        if entry is None:
            entry = people[pid] = {
                "id": pid, "name": known_name or key,
                "handle": key, "handles": set(), "known": cid is not None,
                "channels": {}, "days": set(), "channel_days": {},
                "same_list": 0, "alone": {}, "upcoming": 0,
                # 🛑 RECIPROCITY. Who wrote to whom is the one signal that
                # separates a correspondent from a sender, and it is free:
                # the author is already in hand.
                "mail_from": 0, "mail_to": 0, "mail_bulk": 0, "mail_seen": 0,
                "rids": [],
                "first": None, "last": None, "months": {}, "names": {},
                "card_is_company": cid in companies,
            }
        entry["handles"].add(key)
        # ⚠️ EVERY SPELLING IS KEPT, not just the first. The display name is
        # what separates a person from a mailing list further down, and it is
        # also the only name an address with no contact card ever gets.
        if name:
            entry["names"][name] = entry["names"].get(name, 0) + 1
        if known_name:
            entry["name"] = known_name
        return entry

    def touch(entry, tool, when, count=1):
        """One exchange, on one day, in one channel's own unit."""
        # 🛑 A DAY THAT HAS NOT HAPPENED IS NOT A DAY OF CONTACT. The calendar
        # adapter fetches a YEAR AHEAD — 1,008 of the 12,014 events here are in
        # the future, the furthest on 2027-08-25 — so a recurring swimming
        # lesson gave its organiser contact every week until next August.
        # Three things went wrong at once, and only the third was visible:
        # the day count was inflated, `last` read 2027, and the timeline's
        # axis ran a year past today, squashing twenty years of real history
        # into less width than it had.
        #
        # ⚠️ It is counted as `upcoming` rather than dropped, because "you have
        # something with them next week" is true and worth keeping. It is just
        # not contact.
        if when and when > NOW:
            entry["upcoming"] += count
            return
        entry["channels"][tool] = entry["channels"].get(tool, 0) + count
        if not when:
            return
        entry["first"] = when if entry["first"] is None else min(entry["first"], when)
        entry["last"] = when if entry["last"] is None else max(entry["last"], when)
        stamp = datetime.fromtimestamp(when, timezone.utc)
        day = stamp.strftime("%Y-%m-%d")
        entry["days"].add(day)
        # 🛑 DAYS PER CHANNEL TOO, because "which channel do we mostly use"
        # cannot be answered from the item counts: one is emails and another
        # is individual texts, and texts win that comparison every time
        # whatever the truth is.
        entry["channel_days"].setdefault(tool, set()).add(day)
        entry["months"].setdefault(stamp.strftime("%Y-%m"), set()).add(day)

    def collect(listed):
        """Everyone on one record who is not the user, with their names."""
        others = {}
        for entry in listed:
            key, name = handle_key(entry.get("handle"))
            # ⚠️ A CALENDAR ATTENDEE KEEPS THE NAME IN ITS OWN FIELD, not
            # inside the handle the way mail does. Reading only the handle
            # threw away the one name a guest who is not in Contacts has.
            if not name and (entry.get("name") or "") != (entry.get("handle") or ""):
                name = (entry.get("name") or "").strip()
            # 🛑 The user is in almost every record and belongs in none of
            # them. Left in, they are the biggest node in their own graph and
            # every edge runs through them.
            if not key or key in mine:
                continue
            others.setdefault(key, name)
        return others

    def draw_edges(ids):
        if 2 <= len(ids) <= EDGE_CLIQUE_CAP:
            ids = sorted(set(ids))
            for i in range(len(ids)):
                for j in range(i + 1, len(ids)):
                    pair = (ids[i], ids[j])
                    edges[pair] = edges.get(pair, 0) + 1

    considered = 0

    # ---- mail and calendar: one record is one email or one event -----------
    for row in db.execute(
            "SELECT rid, tool, people, occurred, created FROM record "
            "WHERE tool IN ('mail', 'calendar') AND people NOT IN ('', '[]')"):
        try:
            listed = json.loads(row["people"])
        except (TypeError, ValueError):
            continue
        others = collect(listed)
        if not others:
            continue
        considered += 1
        when = row["occurred"] or row["created"]
        author, _ = handle_key(
            next((p.get("handle") for p in listed
                  if p.get("role") in ("author", "organizer")), ""))
        ids = []
        for key, name in others.items():
            entry = person(key, name)
            if row["tool"] == "mail":
                entry["mail_seen"] += 1
                if author == key:
                    entry["mail_from"] += 1
                    # ⚠️ BOUNDED. Only a candidate's bodies are ever read, and
                    # a candidate has fewer than 40 mails, so 80 is generous.
                    # Keeping every rid for 9,000 people is a list nobody uses.
                    if len(entry["rids"]) < 80:
                        entry["rids"].append(row["rid"])
                elif author in mine:
                    entry["mail_to"] += 1
            if is_direct(row["tool"], author, key, len(others), mine):
                touch(entry, row["tool"], when)
                # ⚠️ NOBODY ELSE ON IT. The most concrete number here, and the
                # one that answers "surely not". Measured for a spouse of
                # twenty years, straight off the .emlx headers: 5,927 messages
                # carry her address, 2,625 are one of us writing to the other,
                # and 1,336 are just the two of us. Each is a true answer to a
                # different question.
                #
                # 🛑 PER CHANNEL, like `channels`. A single figure came out at
                # 17,201 for that person, which is texts wearing a number that
                # looked like emails — the same unit mistake, one level down.
                if len(others) == 1:
                    entry["alone"][row["tool"]] = \
                        entry["alone"].get(row["tool"], 0) + 1
            else:
                entry["same_list"] += 1
            ids.append(entry["id"])
        # ⚠️ AN EDGE IS CO-OCCURRENCE, so a shared mailing list still makes
        # one. That is the honest answer to "who turns up alongside whom",
        # and it is a different question from "who do I talk to".
        draw_edges(ids)

    # ---- messages: one record is a BLOCK, and the unit is one text ---------
    for row in db.execute(
            "SELECT people, body, occurred, created FROM record "
            "WHERE tool = 'messages' AND people NOT IN ('', '[]')"):
        try:
            listed = json.loads(row["people"])
        except (TypeError, ValueError):
            continue
        others = collect(listed)
        if not others:
            continue
        considered += 1
        when = row["occurred"] or row["created"]
        # ⚠️ A GROUP CHAT CANNOT SAY WHO THE USER WAS ANSWERING. Their own
        # texts count only in a one-to-one chat; in a group, the other
        # person's own texts are what is counted for them.
        alone = len(others) == 1
        sent = {}
        for line in (row["body"] or "").split("\n"):
            who, _, text = line.partition(": ")
            if not text.strip():
                continue
            key, _name = handle_key(who)
            if who == "me" or key in mine:
                if alone:
                    for other in others:
                        sent[other] = sent.get(other, 0) + 1
            elif key in others:
                sent[key] = sent.get(key, 0) + 1
        ids = []
        for key, name in others.items():
            entry = person(key, name)
            touch(entry, "messages", when, count=sent.get(key, 0))
            if alone:
                entry["alone"]["messages"] = \
                    entry["alone"].get("messages", 0) + sent.get(key, 0)
            ids.append(entry["id"])
        draw_edges(ids)

    # ---- photos: one record is one DAY, and the unit is one photograph ------
    #
    # 🛑 THE ONE SOURCE THAT SEES PEOPLE WHO DO NOT WRITE. Every channel above
    # needs an address or a number, so it can only find somebody who sends
    # things. Measured against this exact ranking before photos existed: the
    # user's child had 18 days from 30 texts and 24 calls, no rank at all, and
    # sat below a cleaning service at 57. She is in 9,416 photographs across
    # 1,378 days, three times more than anyone else in the library. Five more
    # of the twenty most-photographed people were absent from the report
    # entirely, and every one of them is a child.
    #
    # ⚠️ IT MEASURES WHO WAS PHOTOGRAPHED, NOT WHO WAS THERE, and the
    # difference falls hardest on the person holding the camera. The user
    # appears on 661 days and was present for all 1,378 of his daughter's. That
    # asymmetry costs nothing here, because the user is excluded from their own
    # graph anyway — but never read a photo day count as "days together"
    # without saying whose camera it was.
    for row in db.execute(
            "SELECT people, occurred FROM record "
            "WHERE tool = 'photos' AND kind = 'day' "
            "AND people NOT IN ('', '[]')"):
        try:
            listed = json.loads(row["people"])
        except (TypeError, ValueError):
            continue
        others = collect(listed)
        if not others:
            continue
        considered += 1
        when = row["occurred"]
        shots = {}
        # 🛑 A DAY WHOSE EVERY PHOTO CAME FROM SOMEBODY ELSE'S CAMERA IS NOT
        # EVIDENCE THE USER WAS THERE. The adapter marks those `alongside`
        # rather than `subject`, and they are counted the way a mailing list
        # is: co-occurrence, an edge in the web, never a day of contact.
        alongside = set()
        for tagged in listed:
            key, _ = handle_key(tagged.get("handle"))
            if not key:
                continue
            shots[key] = shots.get(key, 0) + int(tagged.get("photos") or 1)
            if tagged.get("role") == "alongside":
                alongside.add(key)
        ids = []
        for key, name in others.items():
            entry = person(key, name)
            if key in alongside:
                entry["same_list"] += 1
            else:
                touch(entry, "photos", when, count=shots.get(key, 1))
                # ⚠️ NOBODY ELSE IN THE FRAME that day. The photo equivalent of
                # an email with one recipient, and the same honest answer to
                # "surely not".
                if len(others) == 1:
                    entry["alone"]["photos"] = \
                        entry["alone"].get("photos", 0) + shots.get(key, 1)
            ids.append(entry["id"])
        # ⚠️ THE STRONGEST EDGE IN THE WHOLE GRAPH, because two people in one
        # photograph were in one room. A shared mailing list makes an edge too,
        # and it means far less.
        draw_edges(ids)

    # ⚠️ CALL HISTORY IS NOT AN INDEXED SOURCE, so it is read live. It is also
    # a relay mirror of the iPhone rather than the whole history — four months
    # here against years on the phone — so the window says "recent calls", and
    # a person's `first` must never be read as "when we met".
    calls = apple("phone", "recents", "--limit", 100000, "--json",
                  allow_fail=True) or []
    call_span = None
    for call in calls:
        key, _ = handle_key(call.get("handle") or call.get("number"))
        if not key or key in mine:
            continue
        when = epoch(call.get("date"))
        entry = person(key, call.get("name") or "")
        if call.get("contact_id"):
            entry["known"] = True
            if call.get("name"):
                entry["name"] = call["name"]
        touch(entry, "phone", when)
        if when:
            call_span = (min(call_span[0], when), max(call_span[1], when)) \
                if call_span else (when, when)

    # 🛑 THREE PASSES, IN THIS ORDER, and each one needs the one before it.
    #
    #   1. name    an address with no card is called by the name it signs
    #              itself with most often, not by the first one that arrived
    #   2. merge   which needs step 1: the merge matches on the display name,
    #              and before step 1 that name is still the raw address, so
    #              nothing ever matched and "Cat Cantor" stayed two people
    #   3. bulk    which consumes the spellings, so it has to go last
    for entry in people.values():
        if not entry["known"] and entry["names"]:
            entry["name"] = max(entry["names"].items(),
                                key=lambda kv: (kv[1], kv[0]))[0]

    # 🛑 AN OLD EMPLOYER'S ADDRESS IS STILL YOU, and no card lists it. Ten
    # more addresses here — splunk, victorops, stackhawk, a university, two
    # startups since acquired — arrived under the user's own name and none of
    # them was on the card. The largest ranked inside the top eighty, so the
    # user was drawn as one of the people he talks to.
    #
    # ⚠️ THE SAME RULE `merge_by_name` USES, pointed at the user: an address
    # with no card, signing itself with a name a card already claims. The risk
    # is a relative with the same name, so every address it takes is reported
    # in `me.by_name` rather than absorbed silently.
    # 🛑 THE USER'S OWN LOCAL PART AT SOMEBODY ELSE'S SERVICE IS STILL THEM.
    # Six here: two Send-to-Kindle endpoints, a plus-address at a former
    # employer, a receipts service, Google Wave. Each arrives under the user's
    # own name and each was drawn as somebody they talk to.
    #
    # ⚠️ SIX CHARACTERS AT LEAST, and the next character must be a separator.
    # Without the length guard the local part `dan` would claim `dan@` at every
    # domain on the store.
    my_locals = {address.split("@")[0] for address in mine if "@" in address}
    my_locals = {local for local in my_locals if len(local) >= 6}

    def is_my_address(handle):
        if "@" not in handle:
            return False
        local = handle.rsplit("@", 1)[0]
        for mine_local in my_locals:
            if local == mine_local:
                return True
            if local.startswith(mine_local) and local[len(mine_local)] in "+_.-":
                return True
        return False

    by_name, by_address = [], []
    if my_names:
        wanted = {re.sub(r"[^a-z0-9]+", " ", n.lower()).strip() for n in my_names}
        for entry in list(people.values()):
            if entry["known"]:
                continue
            if is_me_by_name(entry["name"], wanted, my_parts):
                by_name.extend(sorted(entry["handles"]))
            elif is_my_address(entry["handle"]):
                by_address.extend(sorted(entry["handles"]))
            else:
                continue
            mine |= entry["handles"]
            del people[entry["id"]]
        if by_name or by_address:
            edges = {pair: w for pair, w in edges.items()
                     if pair[0] in people and pair[1] in people}

    # 🛑 FIRST, because it is the only pass that can see a card with no
    # records of its own. Running it after `merge_namesakes` would let two
    # unnamed rows fold together first and take a name neither card claims.
    merged = adopt_photo_cards(people, aliases, companies)
    merged.update(merge_by_name(people, aliases))
    # ⚠️ AFTER the card merge, so a card always wins the name it claims.
    merged.update(merge_namesakes(people))
    if merged:
        # ⚠️ A CHAIN HAS TO RESOLVE. b folded into a, then a into c, and an
        # edge pointing at b must end up at c or it points at nobody.
        def final(pid):
            seen = set()
            while pid in merged and pid not in seen:
                seen.add(pid)
                pid = merged[pid]
            return pid
        merged = {old: final(old) for old in merged}
        edges = {(merged.get(a, a), merged.get(b, b)): w
                 for (a, b), w in edges.items()
                 if merged.get(a, a) != merged.get(b, b)}

    # 🛑 ONLY THE CANDIDATES' BODIES. Testing all 40,557 mail bodies for a
    # newsletter footer costs 17 seconds; testing the few hundred that belong
    # to somebody who has never once been written back to costs almost nothing.
    # The first version scanned everything, which tripled the whole command.
    wanted = {}
    for entry in people.values():
        if (entry["mail_to"] == 0 and 12 <= entry["mail_from"] < BULK_CERTAIN
                and not (entry["channels"].get("messages")
                         or entry["channels"].get("phone"))):
            for rid in entry["rids"]:
                wanted.setdefault(rid, []).append(entry)
    if wanted:
        marks = list(wanted)
        for start in range(0, len(marks), 900):     # SQLite's variable limit
            batch = marks[start:start + 900]
            for row in db.execute(
                    "SELECT rid, body FROM record WHERE rid IN (%s)"
                    % ",".join("?" * len(batch)), batch):
                if BULK_MARKER.search(row["body"] or ""):
                    for entry in wanted[row["rid"]]:
                        entry["mail_bulk"] += 1

    for entry in people.values():
        entry["not_person"] = not_a_person(entry, overrides, mine)
        entry.pop("names")
        entry.pop("rids")

    # 🛑 RANKED ON DAYS. Ranking on items put four committee colleagues above
    # three of the user's own children, because a committee generates mail and
    # a child sends texts.
    ordered = sorted(people.values(), key=lambda p: -len(p["days"]))
    dropped = [p for p in ordered if p["not_person"]]
    ranked = [p for p in ordered if not p["not_person"]][:top]
    keep = {p["id"] for p in ranked}
    listed = [p for p in ordered
              if not p["not_person"] and (p["days"] or p["known"])]

    # 🛑 ONE SHARED MONTH AXIS, and every series is a list of positions into
    # it. Repeating "2014-07" nine thousand times is most of what a month
    # series costs, and everybody needs one now that the search filters the
    # timeline: a person in 300th place has to be drawable, because the drawn
    # set is chosen by the reader rather than by rank.
    axis = sorted({month for p in listed for month in p["months"]})
    at = {month: offset for offset, month in enumerate(axis)}

    def series(entry):
        """Months as [position, days], sorted, positions into `axis`."""
        return sorted([at[month], len(days)]
                      for month, days in entry["months"].items())

    # ⚠️ ONE DAY OF REAL CONTACT, OR A CARD. 3,849 of the 8,574 have neither:
    # they are names that appeared beside the user on somebody else's mailing
    # list and never wrote to them. They belong in `same_list`, not in a list
    # of people the user talks to.
    #
    # 🛑 BUILT BEFORE THE LOOP BELOW, which turns `days` from a set into a
    # count in place. Built after it, this read `len()` of an integer for
    # everybody drawn and of a set for everybody else.
    directory = [
        {"id": p["id"], "name": p["name"], "handle": p["handle"],
         "known": p["known"], "days": len(p["days"]), "channels": p["channels"],
         "channel_days": {c: len(d) for c, d in p["channel_days"].items()},
         "alone": p["alone"], "same_list": p["same_list"],
         "upcoming": p["upcoming"], "first": p["first"], "last": p["last"],
         "months": series(p)}
        for p in listed]

    for entry in ranked:
        entry["handles"] = sorted(entry["handles"])
        entry["months"] = series(entry)
        entry["days"] = len(entry["days"])
        entry["channel_days"] = {channel: len(days)
                                 for channel, days in entry["channel_days"].items()}

    kept_edges = sorted(((a, b, w) for (a, b), w in edges.items()
                         if w >= 2 and a in keep and b in keep),
                        key=lambda e: -e[2])[:600]


    report = {
        "generated": time.time(),
        "cached": False,
        "me": {"handles": sorted(mine), "detected": detected,
               "by_name": sorted(set(by_name)),
               "by_address": sorted(set(by_address)),
               # ⚠️ A handle-less card claimed by NAME alone. Read this before
               # trusting a ranking: it is the one rule here that could turn a
               # relative into the user.
               "by_card": sorted(my_cards),
               "declared": sorted(h for h, k in overrides.items() if k == "me")},
        "counts": {"records": considered, "people": len(people),
                   "shown": len(ranked), "calls": len(calls),
                   "excluded": len(dropped)},
        # 🛑 NAMED, NOT JUST COUNTED. Every rule here can be wrong about
        # somebody, and a person who has quietly vanished from their own
        # social graph is exactly what nobody would notice.
        "excluded": _tally(p["not_person"] for p in dropped),
        "overrides": {"business": sorted(h for h, k in overrides.items()
                                         if k == "business"),
                      "person": sorted(h for h, k in overrides.items()
                                       if k == "person")},
        "excluded_examples": [
            {"name": p["name"], "handle": p["handle"],
             "reason": p["not_person"], "days": len(p["days"])}
            for p in dropped[:24]],
        "phone_window": ({"first": call_span[0], "last": call_span[1]}
                         if call_span else None),
        "months_axis": axis,
        "people": ranked,
        "directory": directory,
        "directory_omitted": sum(1 for p in ordered if not p["not_person"]
                                 and not p["days"] and not p["known"]),
        "edges": [{"a": a, "b": b, "weight": w} for a, b, w in kept_edges],
        "emoji": emoji_report(db, mine),
    }
    report["computed"] = report["generated"]
    write_people_cache(db, report)
    if opts.ensure:
        print("people: computed %d people in %s"
              % (len(report["directory"]), _duration(time.time() - started)))
    else:
        print(json.dumps(report, indent=2))


def emoji_report(db, mine):
    """The emoji the user themselves typed, and when.

    🛑 ONLY WHAT THE USER SENT. Counting every emoji in the store measures
    what everyone else types at them: their own top emoji is 😂 at 200, and
    the store's is 😂 at 1,499. The two answers look alike and mean opposite
    things.

    Two sources, and each one has to prove the text is the user's:

      messages — a block body is `handle: text` per line, and the adapter
                 writes `me` for anything the user sent. Exact, not inferred.
      mail     — the author address is one of the user's own, and the line is
                 not quoted. ⚠️ WITHOUT THE QUOTE TEST a reply carries every
                 emoji in the thread below it, and the user is credited with
                 what was written at them. 262,027 quoted lines here.
    """
    totals, per_year, by_source = {}, {}, {"messages": 0, "mail": 0}

    def add(cluster, year, source):
        totals[cluster] = totals.get(cluster, 0) + 1
        by_source[source] += 1
        if year:
            bucket = per_year.setdefault(year, {})
            bucket[cluster] = bucket.get(cluster, 0) + 1

    for row in db.execute("SELECT body, occurred FROM record WHERE tool = 'messages'"):
        year = (datetime.fromtimestamp(row["occurred"], timezone.utc).strftime("%Y")
                if row["occurred"] else None)
        for line in (row["body"] or "").split("\n"):
            who, _, text = line.partition(": ")
            if who != "me":
                continue
            for cluster in emoji_in(text):
                add(cluster, year, "messages")

    for row in db.execute("SELECT body, people, occurred FROM record WHERE tool = 'mail'"):
        try:
            listed = json.loads(row["people"] or "[]")
        except ValueError:
            continue
        author = next((p.get("handle") for p in listed
                       if p.get("role") == "author"), "")
        key, _ = handle_key(author)
        if key not in mine:
            continue
        year = (datetime.fromtimestamp(row["occurred"], timezone.utc).strftime("%Y")
                if row["occurred"] else None)
        for line in (row["body"] or "").split("\n"):
            if line.lstrip().startswith(">"):
                continue
            for cluster in emoji_in(line):
                add(cluster, year, "mail")

    top = sorted(totals.items(), key=lambda kv: (-kv[1], kv[0]))
    champions = []
    for year in sorted(per_year):
        cluster, count = max(per_year[year].items(), key=lambda kv: (kv[1], kv[0]))
        champions.append({"year": year, "emoji": cluster, "count": count,
                          "total": sum(per_year[year].values())})
    return {
        "total": sum(totals.values()),
        "distinct": len(totals),
        "sources": by_source,
        "top": [{"emoji": e, "count": c} for e, c in top[:48]],
        "by_year": champions,
    }


def cmd_status(opts):
    require_index(opts.db)
    warn_if_revoked(opts)
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
    # ⚠️ Name the query log in `status`. It is a SECOND copy of the protected
    # content — each logged hit keeps a 240-character snippet of real message
    # text — and a store nobody can see is a store nobody deletes.
    logged = db.execute("SELECT COUNT(*) c FROM query_log").fetchone()["c"]
    cached = db.execute("SELECT COUNT(*) c FROM result_cache").fetchone()["c"]
    if logged or cached:
        oldest = db.execute("SELECT MIN(ts) t FROM query_log").fetchone()["t"]
        age = (time.time() - oldest) / 86400 if oldest else 0
        print("%d logged queries and %d cached results, kept %d days "
              "(oldest %.1f days). Clear: apple-index purge --logs-only"
              % (logged, cached, LOG_RETENTION_DAYS, age))
    # ⚠️ Quote the rate for the model that is actually behind. A single
    # hardcoded 41 chunks/sec came from Apple's model and told a caller "52
    # minutes" for an e5-small backlog that finished in 5.
    RATES = {"e5-small-v1": 450.0, "e5-small-coreml-v1": 1000.0,
             "e5-base-v1": 133.0,
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
    e.add_argument("--model", default="e5-small-coreml", choices=list(ALL_MODELS))
    e.set_defaults(func=cmd_embed)

    s = sub.add_parser("search", help="hybrid search over everything indexed")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=10)
    # 🛑 Repeatable. Another PHRASING of the same question, fused by max --
    # see cmd_search for why max and not sum, and why this is opt-in.
    s.add_argument("--also", action="append", metavar="QUERY",
                   help="another phrasing of the same question; fused by max. "
                        "Use for a descriptive question, NOT a keyword lookup")
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
    s.add_argument("--model", default="e5-small-coreml", choices=list(ALL_MODELS),
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
    # 🛑 2:1 SINCE 26.824.7, AND IT WAS 4:1. Measured over eval.py's 34 cases,
    # which now include five the Obsidian vault should win:
    #
    #     8:1   0.474      2.5:1  0.526
    #     6:1   0.477      2:1    0.523
    #     5:1   0.506      1.75:1 0.523
    #     4:1   0.509      1.5:1  0.523
    #     3:1   0.517      1.25:1 0.489
    #                      1:1    0.481
    #
    # ⚠️ 2.5:1 scores highest by 0.003, which is one case moving one rank. 2:1
    # is chosen instead because it sits in the MIDDLE of the plateau rather
    # than at its edge, and the cliff below 1.5:1 is steep.
    #
    # 🛑 A PLATEAU IS WHY THIS IS TRUSTWORTHY AND THE ADAPTIVE RULE WAS NOT.
    # Four consecutive points agree to 0.003, and the curve is smooth on both
    # sides. The adaptive fusion rule was a threshold on a count of five — a
    # knife edge whose gain was smaller than the swing it caused between two
    # vector sets that agree to one part in a million.
    s.add_argument("--w-lexical", type=float, default=2.0, dest="w_lexical")
    s.add_argument("--w-semantic", type=float, default=1.0, dest="w_semantic")
    s.add_argument("--recency-head", type=int, default=10, dest="recency_head",
                   help="how many top candidates the recency arm re-orders")
    # 🛑 OFF BY DEFAULT, AND THAT IS A MEASUREMENT, NOT A GUESS.
    #
    # The problem is real: mail holds 81.3% of the chunks here, and for "what
    # books have I been reading" it took 54 of the 60 semantic candidates while
    # the Obsidian vault got 2. A source that is never retrieved cannot be
    # ranked, and the whole point of this index is not having to name the app.
    #
    # A per-tool quota fixes the retrieval and costs more than it earns. Over
    # eval.py's 29 cases:
    #
    #     per-tool  0   MRR 0.565      (no quota)
    #     per-tool  5   MRR 0.474
    #     per-tool 10   MRR 0.338
    #     per-tool 20   MRR 0.237
    #     per-tool 40   MRR 0.175
    #
    # Monotonically worse. The quota admits a weak candidate from every source
    # — a calendar entry called "Book camping" — and those displace good ones.
    #
    # ⚠️ AND THE EVALUATION CANNOT SEE THE OTHER HALF. Its 29 cases have their
    # answers in mail and notes; not one asks a question the vault should win.
    # So this measures what the quota COSTS and says nothing about what it
    # BUYS. Adding vault cases comes before tuning this again — shipping a
    # default that is worse on 29 measured cases to fix an unmeasured one is
    # the mistake the adaptive fusion rule already made here.
    s.add_argument("--per-tool", type=int, default=0, dest="per_tool",
                   metavar="K",
                   help="retrieve K candidates from EACH tool before ranking "
                        "(0 = one global pool, which the largest source wins)")
    s.add_argument("--pool", type=int, default=0,
                   help="candidates each arm retrieves before fusion "
                        "(0 = max(limit*6, 60))")
    s.add_argument("--w-recency", type=float, default=0.0, dest="w_recency",
                   help="weight of a third arm ranking candidates newest first")
    # 🛑 OFF BY DEFAULT SINCE 26.824.2, and it used to be on.
    #
    # It was tuned against the PyTorch e5-small vectors, where it earned its
    # keep: over eval.py's 28 cases, off scored MRR 0.589 and threshold 4
    # scored 0.620. Re-measured on the SAME 29 cases against the shipped Core
    # ML vectors:
    #
    #     default (threshold 4)   hit@1 0.48   hit@3 0.55   MRR 0.535
    #     adaptive off            hit@1 0.52   hit@3 0.62   MRR 0.573
    #
    # ⚠️ A THRESHOLD ON A COUNT OF FIVE IS A KNIFE EDGE. The two vector sets
    # agree to about one part in a million and this rule swings 0.038 MRR
    # between them, in opposite directions. Its gain was always smaller than
    # that swing, so it was never measuring the thing it was named for.
    #
    # `--adaptive` turns it back on. `--no-adaptive` still parses, so anything
    # that already passes it keeps working.
    s.add_argument("--adaptive", action="store_true", dest="adaptive",
                   default=False,
                   help="re-fuse semantic-heavy when the lexical arm dominates")
    s.add_argument("--no-adaptive", action="store_false", dest="adaptive",
                   help="the default; kept so existing callers still parse")
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
    d.add_argument("--model", default="e5-small-coreml")
    d.add_argument("--refresh", type=int, default=300)
    d.add_argument("--socket", default=DEFAULT_SOCKET)
    d.set_defaults(func=cmd_daemon)

    ag = sub.add_parser("agent",
                        help="install or remove the launchd agent")
    ag.add_argument("action", choices=["install", "uninstall"])
    ag.set_defaults(func=cmd_agent)

    rf = sub.add_parser("refresh",
                        help="ingest, embed and reload — run this from a terminal")
    rf.add_argument("--source", help="comma separated; default all")
    rf.add_argument("--model", default="e5-small-coreml", choices=list(ALL_MODELS))
    rf.set_defaults(func=cmd_refresh)

    fg = sub.add_parser("forget",
                        help="delete the index and withdraw consent")
    fg.add_argument("--yes", action="store_true")
    fg.set_defaults(func=cmd_forget)

    pu = sub.add_parser("purge", help="delete the index, or just the logs")
    pu.add_argument("--yes", action="store_true", help="do not ask")
    pu.add_argument("--logs-only", action="store_true", dest="logs_only",
                    help="keep the index, drop query_log and result_cache")
    pu.add_argument("--older-than", type=int, default=0, dest="older_than",
                    metavar="DAYS",
                    help="with --logs-only: drop only entries older than DAYS "
                         "(default 0 = all of them). Searches already prune "
                         "at %d days." % LOG_RETENTION_DAYS)
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

    fl = sub.add_parser("files",
                        help="folders the `files` source indexes")
    fl.add_argument("action", nargs="?", default="list",
                    choices=["list", "add", "remove"])
    fl.add_argument("path", nargs="?", help="the folder, for add/remove")
    fl.add_argument("--name", help="what to call it (default: the folder name)")
    fl.add_argument("--exclude", help="comma separated subdirectory names to skip")
    fl.add_argument("--json", action="store_true")
    fl.set_defaults(func=cmd_files)

    pl = sub.add_parser("places",
                        help="everywhere you have been, as JSON")
    pl.add_argument("--limit", type=int, help="how many places to return")
    pl.set_defaults(func=cmd_places)

    sub.add_parser("stats",
                   help="everything the app's window needs, as JSON"
                   ).set_defaults(func=cmd_stats)

    pe = sub.add_parser("people",
                        help="who you talk to, who overlaps, and which emoji "
                             "you use, as JSON")
    pe.add_argument("--top", type=int, default=80,
                    help="how many people to report (default 80)")
    pe.add_argument("--not-a-person", action="append", metavar="HANDLE",
                    help="record that this address or number is a business, "
                         "not somebody you talk to. Repeatable")
    pe.add_argument("--is-a-person", action="append", metavar="HANDLE",
                    help="undo that, or rescue somebody the rules excluded "
                         "wrongly. Repeatable")
    pe.add_argument("--ensure", action="store_true",
                    help="make sure the stored report is fresh, and print one "
                         "line rather than the report. For the scheduler")
    pe.add_argument("--refresh", action="store_true",
                    help="recompute now, whatever the stored report says")
    pe.add_argument("--max-age", type=int, default=0, metavar="SECONDS",
                    help="how old a stored report may be (default one day; "
                         "-1 accepts any age)")
    pe.add_argument("--me", action="append", metavar="HANDLE",
                    help="record that this address or number is YOU — an old "
                         "one, an alias, a service endpoint. Repeatable")
    pe.set_defaults(func=cmd_people)

    sub.add_parser("sources",
                   help="the per-source arguments `refresh` uses, as JSON"
                   ).set_defaults(func=cmd_sources)

    cs = sub.add_parser("consent", help="read, print or record the opt-in")
    cs.add_argument("--text", action="store_true", help="print the wording and stop")
    cs.add_argument("--accept", action="store_true", help="record consent")
    cs.add_argument("--how", default="app", help="what recorded it")
    cs.set_defaults(func=cmd_consent)

    sub.add_parser("status", help="what is indexed").set_defaults(func=cmd_status)

    opts = p.parse_args()
    opts.func(opts)


if __name__ == "__main__":
    main()
