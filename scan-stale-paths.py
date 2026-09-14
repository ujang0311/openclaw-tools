#!/usr/bin/env python3
"""Cari path absolut lama (mis. /root/.openclaw) di dalam semua database OpenClaw."""
import sqlite3, glob, sys, os

STATE = sys.argv[1] if len(sys.argv) > 1 else "/opt/openclaw/.openclaw"
NEEDLE = sys.argv[2] if len(sys.argv) > 2 else "/root/.openclaw"
dbs = sorted(glob.glob(os.path.join(STATE, "**", "*.sqlite"), recursive=True))
print(f"state      : {STATE}")
print(f"cari string: {NEEDLE}")
print(f"database   : {len(dbs)} file")
for db in dbs:
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        tabs = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
        hits = []
        for t in tabs:
            cols = [c[1] for c in con.execute(f'pragma table_info("{t}")')]
            for c in cols:
                try:
                    n = con.execute(f'select count(*) from "{t}" where "{c}" like ?', (f"%{NEEDLE}%",)).fetchone()[0]
                except Exception:
                    continue
                if n:
                    sample = con.execute(f'select "{c}" from "{t}" where "{c}" like ? limit 1', (f"%{NEEDLE}%",)).fetchone()[0]
                    hits.append((t, c, n, str(sample)[:110]))
        con.close()
        rel = os.path.relpath(db, STATE)
        if hits:
            print(f"\n  {rel}")
            for t, c, n, s in hits:
                print(f"    tabel {t}.{c}: {n} baris → {s}")
        else:
            print(f"  {rel}: bersih")
    except Exception as e:
        print(f"  {rel}: ERROR {e}")
