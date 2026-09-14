#!/usr/bin/env python3
"""
remap-state-paths.py — ganti path absolut state dir lama di dalam database OpenClaw.

Dipakai otomatis oleh openclaw-migrate.sh (restore) dan openclaw-upgrade.sh.
Kenapa perlu: setelah restore ke server dengan lokasi state berbeda (mis. /root/.openclaw
→ /opt/openclaw/.openclaw), database masih menyimpan path lama. Akibatnya
`openclaw doctor --fix` gagal (EACCES/ENOENT) dan migrasi skema tidak jalan → gateway menolak start.

Pakai:
  remap-state-paths.py --state-dir /opt/openclaw/.openclaw                 # auto-deteksi path lama
  remap-state-paths.py --state-dir /opt/openclaw/.openclaw --old /root/.openclaw
  remap-state-paths.py --state-dir /opt/openclaw/.openclaw --dry-run
"""
import argparse, glob, os, re, sqlite3, sys

ap = argparse.ArgumentParser()
ap.add_argument("--state-dir", required=True, help="state dir BARU (mis. /opt/openclaw/.openclaw)")
ap.add_argument("--old", default="", help="path lama (kosong = auto-deteksi)")
ap.add_argument("--dry-run", action="store_true")
ap.add_argument("--quiet", action="store_true")
a = ap.parse_args()

NEW = a.state_dir.rstrip("/")
if not os.path.isdir(NEW):
    sys.exit(f"state dir tidak ada: {NEW}")

dbs = sorted(glob.glob(os.path.join(NEW, "**", "*.sqlite"), recursive=True))


def open_ro(p):
    return sqlite3.connect(f"file:{p}?mode=ro", uri=True)


# ── 1. Tentukan path lama ───────────────────────────────────────────────────
PAT = re.compile(r'((?:/[A-Za-z0-9._-]+)+/\.openclaw)')
OLD = a.old.rstrip("/")
if not OLD:
    from collections import Counter
    c = Counter()
    for db in dbs:
        try:
            con = open_ro(db)
            tabs = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
            for t in tabs:
                cols = [x[1] for x in con.execute(f'pragma table_info("{t}")')]
                for col in cols:
                    try:
                        rows = con.execute(f'select "{col}" from "{t}" where "{col}" like ?', ("%/.openclaw%",)).fetchall()
                    except Exception:
                        continue
                    for (v,) in rows:
                        if isinstance(v, str):
                            for m in PAT.findall(v):
                                if m.rstrip("/") != NEW:
                                    c[m.rstrip("/")] += 1
            con.close()
        except Exception:
            pass
    if not c:
        if not a.quiet:
            print("path lama tidak ditemukan — tidak ada yang perlu diubah")
        sys.exit(0)
    OLD = c.most_common(1)[0][0]
    if not a.quiet:
        print(f"path lama terdeteksi: {OLD} ({c[OLD]} kemunculan)")

if OLD == NEW:
    if not a.quiet:
        print("path lama == baru — tidak ada yang perlu diubah")
    sys.exit(0)

# ── 2. Ganti di semua tabel/kolom teks ─────────────────────────────────────
total = 0
for db in dbs:
    if a.dry_run:
        con = open_ro(db)
    else:
        con = sqlite3.connect(db, timeout=30)
    rel = os.path.relpath(db, NEW)
    try:
        tabs = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
        for t in tabs:
            cols = [(x[1], (x[2] or "").upper()) for x in con.execute(f'pragma table_info("{t}")')]
            for col, typ in cols:
                if typ and typ not in ("TEXT", "VARCHAR", "CLOB", ""):
                    continue
                try:
                    n = con.execute(
                        f'select count(*) from "{t}" where "{col}" like ?', (f"%{OLD}%",)).fetchone()[0]
                except Exception:
                    continue
                if not n:
                    continue
                if a.dry_run:
                    total += n
                    print(f"  [dry] {rel}: {t}.{col} → {n} baris")
                    continue
                try:
                    con.execute(
                        f'update "{t}" set "{col}" = replace("{col}", ?, ?) where "{col}" like ?',
                        (OLD, NEW, f"%{OLD}%"))
                    con.commit()
                    total += con.total_changes
                    print(f"  {rel}: {t}.{col} → {n} baris diperbarui")
                except sqlite3.IntegrityError:
                    # baris lama bentrok dengan baris baru (unique constraint) → buang baris lama
                    removed = con.execute(
                        f'delete from "{t}" where "{col}" like ?', (f"%{OLD}%",)).rowcount
                    con.commit()
                    total += removed
                    print(f"  {rel}: {t}.{col} → {removed} baris lama DIHAPUS (bentrok unique dengan baris baru)")
                except Exception as e:
                    print(f"  {rel}: {t}.{col} → dilewati ({e})")
    finally:
        con.close()

verb = "akan diperbarui" if a.dry_run else "diperbarui"
if not a.quiet:
    print(f"total {total} baris {verb}: {OLD} → {NEW}")
print(f"REMAP_OK old={OLD} new={NEW} rows={total}")
