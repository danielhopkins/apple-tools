# /// script
# dependencies = ["sentence-transformers"]
# ///
"""A resident process that keeps the model and the vectors warm.

Why it exists, measured: an uncached e5-base search takes **4.86 seconds**, and
almost none of that is searching. It is `uv` starting, PyTorch importing, the
model loading from disk, and 183 MB of vectors being read out of SQLite. Doing
that once instead of once per query is the whole point.

It also does the other half of the job: it polls each source for changes and
folds them in, so the index does not go stale between manual runs.

🛑 SECURITY. This process holds the plaintext of every indexed message in RAM,
and it answers a socket. The socket is a Unix socket at mode 0600 inside the
0700 index directory. It is NEVER a TCP port, because that would put the user's
whole mail corpus one bad bind address away from the network. See SECURITY.md.

  uv run daemon.py serve [--model e5-base] [--refresh 300]
"""
import argparse, json, os, socket, sqlite3, sys, threading, time, traceback
import numpy as np
from sentence_transformers import SentenceTransformer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from importlib.machinery import SourceFileLoader
idx = SourceFileLoader("idx", os.path.join(HERE, "index.py")).load_module()

MODELS = {
    "e5-base":  ("intfloat/e5-base-v2",  "query: ", 768),
    "e5-small": ("intfloat/e5-small-v2", "query: ", 384),
    "minilm":   ("sentence-transformers/all-MiniLM-L6-v2", "", 384),
}

SOURCE_ARGS = {
    "mail":     ["--with-bodies"],
    "calendar": ["--since", "3650"],
    "messages": ["--chat-limit", "1331", "--limit", "2000"],
    "notes":    [],
    "contacts": ["--limit", "100000"],
}


def log(message):
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


class Warm:
    """The model and the vector matrix, held in memory and swapped atomically."""

    def __init__(self, db_path, model_name):
        self.db_path = db_path
        self.model_name = model_name
        repo, self.query_prefix, self.dim = MODELS[model_name]
        self.vector_model = "%s-v1" % model_name
        log("loading %s ..." % repo)
        t0 = time.time()
        self.model = SentenceTransformer(repo)
        log("model ready in %.1fs" % (time.time() - t0))
        self.lock = threading.Lock()
        self.cids = np.zeros(0, dtype=np.int64)
        self.matrix = np.zeros((0, self.dim), dtype=np.int8)
        self.fingerprint = None
        self.reload()

    def connect(self):
        # 🛑 Never immutable=1: this database is WAL and the daemon's own writes
        # live in the log.
        db = sqlite3.connect("file:%s?mode=ro" % self.db_path.replace("?", "%3F"),
                             uri=True)
        db.row_factory = sqlite3.Row
        return db

    def reload(self):
        """Read every vector for this model into memory."""
        t0 = time.time()
        db = self.connect()
        rows = db.execute("SELECT cid, v FROM vector WHERE model = ? AND dim = ?",
                          (self.vector_model, self.dim)).fetchall()
        fingerprint = idx.index_fingerprint(db)
        db.close()
        if not rows:
            log("no vectors for %s yet" % self.vector_model)
            return
        cids = np.fromiter((r["cid"] for r in rows), dtype=np.int64, count=len(rows))
        matrix = np.frombuffer(b"".join(r["v"] for r in rows),
                               dtype=np.int8).reshape(len(rows), self.dim)
        with self.lock:
            self.cids, self.matrix, self.fingerprint = cids, matrix, fingerprint
        log("%d vectors warm (%.0f MB) in %.1fs  index=%s"
            % (len(rows), matrix.nbytes / 1e6, time.time() - t0, fingerprint))

    def stale(self):
        db = self.connect()
        current = idx.index_fingerprint(db)
        db.close()
        return current != self.fingerprint

    def score(self, query, limit):
        vector = self.model.encode(self.query_prefix + query, convert_to_numpy=True)
        vector = vector / (np.linalg.norm(vector) or 1.0)
        with self.lock:
            cids, matrix = self.cids, self.matrix
        if not len(cids):
            return []
        scores = matrix.astype(np.float32) @ vector.astype(np.float32) / 127.0
        k = min(limit, len(scores))
        top = np.argpartition(-scores, k - 1)[:k]
        top = top[np.argsort(-scores[top])]
        return [{"cid": int(cids[i]), "score": round(float(scores[i]), 6)}
                for i in top if scores[i] > 0]


class Health:
    """Whether the refresh loop is actually working.

    🛑 A failing ingest prints no change lines, which is indistinguishable from
    "nothing changed". Measured: a launchd agent has NO Full Disk Access, so
    every source fails and the loop looked healthy. Silence is not success, so
    the return code is checked and the failure is reported through `ping`.
    """
    def __init__(self):
        self.last_run = None
        self.last_ok = None
        self.last_error = None
        self.failures = 0


def refresh_loop(warm, interval, sources, health):
    """Poll each source, fold in what changed, embed it, reload the matrix.

    ⚠️ A full no-change sweep of all five sources costs about 7 seconds, so a
    5-minute interval is nearly free. See INCREMENTAL.md for the per-source
    change signals.
    """
    while True:
        time.sleep(interval)
        health.last_run = time.time()
        try:
            changed, failed = False, []
            for name in sources:
                proc = idx.subprocess.run(
                    [sys.executable, os.path.join(HERE, "index.py"), "ingest",
                     "--source", name] + SOURCE_ARGS[name],
                    capture_output=True, text=True)
                if proc.returncode != 0:
                    failed.append("%s: %s" % (name, proc.stderr.strip().splitlines()[-1]
                                              if proc.stderr.strip() else "exit %d"
                                              % proc.returncode))
                    continue
                for line in proc.stdout.splitlines():
                    if line.startswith(name) and " +0 ~0 -0 " not in line:
                        log("changed: %s" % line.strip())
                        changed = True
            if failed:
                health.failures += 1
                health.last_error = "; ".join(failed)
                log("🛑 refresh FAILED for %d of %d sources: %s"
                    % (len(failed), len(sources), health.last_error))
                log("   A launchd agent has no Full Disk Access. Refresh from a"
                    " terminal instead: apple-index refresh")
            else:
                health.last_ok = time.time()
                health.last_error = None
            if changed:
                idx.subprocess.run(
                    ["uv", "run", "--quiet", os.path.join(HERE, "embed_oss.py"),
                     "embed", "--db", warm.db_path, "--model", warm.model_name],
                    capture_output=True, text=True)
            if changed or warm.stale():
                warm.reload()
        except Exception:
            # A refresh must never take the server down. Serving stale results
            # beats serving none.
            log("refresh failed:\n%s" % traceback.format_exc())


def serve(opts):
    warm = Warm(opts.db, opts.model)
    health = Health()
    if opts.refresh:
        threading.Thread(target=refresh_loop,
                         args=(warm, opts.refresh, list(SOURCE_ARGS), health),
                         daemon=True).start()
        log("refresh every %ds" % opts.refresh)
    else:
        log("refresh disabled; run `apple-index refresh` from a terminal")

    if os.path.exists(opts.socket):
        os.remove(opts.socket)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(opts.socket)
    os.chmod(opts.socket, 0o600)          # 🛑 owner only, never a TCP port
    server.listen(16)
    log("listening on %s" % opts.socket)

    while True:
        conn, _ = server.accept()
        try:
            conn.settimeout(30)
            data = b""
            while not data.endswith(b"\n"):
                part = conn.recv(65536)
                if not part:
                    break
                data += part
            if not data:
                continue
            request = json.loads(data)
            op = request.get("op")
            if op == "ping":
                reply = {"ok": True, "model": warm.model_name,
                         "vectors": int(len(warm.cids)),
                         "fingerprint": warm.fingerprint,
                         "megabytes": round(warm.matrix.nbytes / 1e6, 1),
                         "refresh_enabled": bool(opts.refresh),
                         "refresh_last_run": health.last_run,
                         "refresh_last_ok": health.last_ok,
                         "refresh_failures": health.failures,
                         "refresh_error": health.last_error}
            elif op == "search":
                # 🛑 The daemon serves ONE model. A client asking for another
                # must be refused, not quietly answered from the wrong vector
                # space. This bug made `--model sentence` and `--model e5-base`
                # return identical scores in an evaluation, because both were
                # silently served e5-small.
                wanted = request.get("model")
                if wanted and wanted != warm.model_name:
                    reply = {"ok": False, "error": "daemon holds %s, not %s"
                                                   % (warm.model_name, wanted)}
                    conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
                    conn.close()
                    continue
                t0 = time.time()
                hits = warm.score(request["query"], int(request.get("limit", 100)))
                reply = {"ok": True, "hits": hits,
                         "elapsed_ms": round((time.time() - t0) * 1000, 1)}
            elif op == "reload":
                warm.reload()
                reply = {"ok": True, "fingerprint": warm.fingerprint}
            else:
                reply = {"ok": False, "error": "unknown op %r" % op}
        except Exception as e:
            reply = {"ok": False, "error": str(e)}
        try:
            conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
        except OSError:
            pass
        finally:
            conn.close()


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--db", default=idx.DEFAULT_DB)
    s.add_argument("--socket", default=idx.DEFAULT_SOCKET)
    s.add_argument("--model", default="e5-small", choices=sorted(MODELS))
    s.add_argument("--refresh", type=int, default=300,
                   help="seconds between change sweeps; 0 disables")
    s.set_defaults(func=serve)
    opts = p.parse_args()
    opts.func(opts)


if __name__ == "__main__":
    main()
