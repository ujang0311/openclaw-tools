#!/usr/bin/env bash
# ============================================================================
#  run.sh — pembungkus STABIL untuk openclaw-tools
#  Ambil script terbaru langsung dari GitHub (bebas cache CDN), lalu jalankan.
#
#  Pakai:
#    curl -sS https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/run.sh | bash -s -- migrate detect
#    curl -sS .../run.sh | bash -s -- migrate backup
#    curl -sS .../run.sh | bash -s -- migrate restore --archive /root/x.tar.gz --safe-channels
#    curl -sS .../run.sh | bash -s -- upgrade --check
#    curl -sS .../run.sh | bash -s -- upgrade
#    curl -sS .../run.sh | bash -s -- list
# ============================================================================
set -u -o pipefail

REPO="${OPENCLAW_TOOLS_REPO:-ujang0311/openclaw-tools}"
BRANCH="${OPENCLAW_TOOLS_BRANCH:-main}"
API="https://api.github.com/repos/$REPO/contents"
RAW="https://raw.githubusercontent.com/$REPO/refs/heads/$BRANCH"

usage() {
  cat <<EOF

  run.sh — jalankan script openclaw-tools (selalu versi terbaru)

    ... | bash -s -- migrate detect                 # deteksi otomatis (aman)
    ... | bash -s -- migrate backup                 # backup
    ... | bash -s -- migrate restore --archive F --safe-channels
    ... | bash -s -- upgrade --check                # cek update (tanpa mengubah)
    ... | bash -s -- upgrade                        # pasang Node sesuai syarat + update
    ... | bash -s -- list                           # lihat isi repo

  Isi repo: openclaw-migrate.sh · openclaw-upgrade.sh · remap-state-paths.py ·
            channel-off.py · scan-stale-paths.py
EOF
  printf "\n"
}

get_file() { # $1 nama file, $2 tujuan → 0 kalau sukses
  curl -fsSL -H "Accept: application/vnd.github.raw" "$API/$1?ref=$BRANCH" -o "$2" 2>/dev/null && return 0
  curl -fsSL "$RAW/$1" -o "$2" 2>/dev/null
}

TARGET="${1:-}"; [ $# -gt 0 ] && shift || true

case "$TARGET" in
  migrate)               SCRIPT="openclaw-migrate.sh" ;;
  backup|restore|detect) SCRIPT="openclaw-migrate.sh"; set -- "$TARGET" "$@" ;;
  upgrade)               SCRIPT="openclaw-upgrade.sh" ;;
  remap)                 SCRIPT="remap-state-paths.py" ;;
  list)
    printf "\n  Isi repo %s (%s):\n" "$REPO" "$BRANCH"
    curl -fsSL "$API?ref=$BRANCH" 2>/dev/null | grep -o '"name": *"[^"]*"' | sed 's/.*: *"/    - /; s/"$//'
    printf "\n"; exit 0 ;;
  ""|-h|--help) usage; exit 0 ;;
  *) printf "\n  ✖ pilihan tidak dikenal: %s\n\n" "$TARGET" 1>&2; usage; exit 2 ;;
esac

TMP=$(mktemp /tmp/openclaw-tools-XXXXXX)
trap 'rm -f "$TMP"' EXIT

printf "\n  ⇩ ambil %s terbaru dari %s …\n" "$SCRIPT" "$REPO"
if ! get_file "$SCRIPT" "$TMP" || [ ! -s "$TMP" ]; then
  printf "  ✖ gagal mengambil %s — cek koneksi/DNS ke github.com\n\n" "$SCRIPT" 1>&2
  exit 1
fi

case "$SCRIPT" in
  *.py) python3 "$TMP" "$@" ;;
  *)    bash "$TMP" "$@" ;;
esac
