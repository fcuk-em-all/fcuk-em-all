#!/usr/bin/env python3
# lib/db-sqlite-backup.py - consistent hot backup of a live SQLite DB (33.sh).
# Uses SQLite's ONLINE BACKUP API (Connection.backup): safe on a live WAL database
# being written by the app - no app downtime, no risk of a torn copy (unlike a
# plain cp of a mid-write file). Runs an integrity_check, then gzips the snapshot.
#   usage: db-sqlite-backup.py <source.db> <out.db.gz>
import sqlite3, gzip, shutil, os, sys

if len(sys.argv) != 3:
    sys.exit("usage: db-sqlite-backup.py <source.db> <out.db.gz>")
src_path, out_path = sys.argv[1], sys.argv[2]
tmp = out_path + ".tmp"

src = sqlite3.connect(src_path)
dst = sqlite3.connect(tmp)
try:
    src.backup(dst)                                   # online snapshot of the live DB
    ok = dst.execute("PRAGMA integrity_check").fetchone()[0]
finally:
    dst.close(); src.close()
if ok != "ok":
    try: os.remove(tmp)
    except OSError: pass
    sys.exit("integrity_check=%s" % ok)

with open(tmp, "rb") as f, gzip.open(out_path, "wb") as g:
    shutil.copyfileobj(f, g)
os.remove(tmp)
print("ok")
