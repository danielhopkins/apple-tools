#!/usr/bin/env python3
"""One-off: recompute every mail rev under the new header-only formula.

Changing how a rev is built makes every record look modified, exactly like
changing a uid. Without this, the next ingest would re-export all 41k bodies
to discover that nothing changed. The headers come from one `apple mail
search` call, so this costs seconds instead of 38 minutes.
"""
import sqlite3, subprocess, json, sys
sys.path.insert(0, ".")
from importlib.machinery import SourceFileLoader
mod = SourceFileLoader("idx", "index.py").load_module()

rows = json.loads(subprocess.run(
    ["apple", "mail", "search", "", "--json", "--limit", "1000000"],
    capture_output=True, text=True).stdout)
print("headers: %d" % len(rows))

db = sqlite3.connect("index.db")
updated = 0
for r in rows:
    uid = "mail:%s@%s/%s" % (r["id"], r.get("account") or "", r.get("mailbox") or "")
    rev = mod.rev_of(r.get("subject") or "", r.get("from") or "",
                     r.get("date_iso"), "bodies")
    cur = db.execute("UPDATE record SET rev = ? WHERE uid = ? AND rev != ?",
                     (rev, uid, rev))
    updated += cur.rowcount
db.commit()
print("revs rewritten: %d" % updated)
