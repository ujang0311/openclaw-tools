#!/usr/bin/env bash
# ============================================================================
#  openclaw-upgrade.sh — upgrade OpenClaw + pastikan Node.js memenuhi syarat
#  Repo: https://github.com/ujang0311/openclaw-tools
#
#  Cek dulu (tidak mengubah apa pun):
#    bash openclaw-upgrade.sh --check
#
#  Upgrade ke rilis stabil terbaru:
#    curl -sS https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-upgrade.sh | bash
#
#  Opsi:
#    --check              hanya laporkan status (versi, requirement Node, rencana)
#    --version 2026.9.4   target versi tertentu (default: tag `latest` di npm)
#    --node-major 24      paksa major Node yang dipasang (default: dihitung dari requirement)
#    --skip-node          batalkan kalau Node belum memenuhi syarat (tanpa memasang Node)
#    --no-backup          lewati backup state sebelum upgrade
#    --no-restart         jangan nyalakan ulang gateway setelah upgrade
#    --dry-run            sama seperti --check tapi juga menampilkan perintah yang akan dijalankan
#    --force              lanjut walau gateway tidak sehat sesudah upgrade (tanpa rollback)
#
#  Env: OPENCLAW_SERVICE (default `openclaw`), OPENCLAW_BACKUP_DIR
#  Bash >= 4.2 · butuh root · diuji di Ubuntu 24.04 (VM App Catalog IDCloudHost)
# ============================================================================
set -u -o pipefail

VERSION_SCRIPT="1.0.0"
SELF_URL="${OPENCLAW_UPGRADE_URL:-https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-upgrade.sh}"
SERVICE_NAME="${OPENCLAW_SERVICE:-openclaw}"
BACKUP_DIR="${OPENCLAW_BACKUP_DIR:-/var/backups/openclaw}"
NODE_REPO_URL="${NODESOURCE_URL:-https://deb.nodesource.com}"
REPO_RAW="${OPENCLAW_TOOLS_RAW:-https://raw.githubusercontent.com/ujang0311/openclaw-tools/main}"
DRY=0; CHECK=0; TARGET_VER=""; NODE_MAJOR=""; SKIP_NODE=0; DO_BACKUP=1; DO_RESTART=1; FORCE=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; R=$'\033[0m'; GRN=$'\033[38;5;42m'; YLW=$'\033[38;5;220m'
  RED=$'\033[38;5;203m'; CYN=$'\033[38;5;45m'; PRP=$'\033[38;5;141m'; GRY=$'\033[38;5;245m'
else
  B=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; PRP=""; GRY=""
fi
W=68
svc_state() { local s; s=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null); [ -n "$s" ] && printf '%s' "$s" || printf 'n/a'; }
boxline() { local t="$1" p; p=$(( W - 6 - ${#t} )); [ "$p" -lt 1 ] && p=1
  printf "${HDR:-$PRP}${B}  │${R}  ${B}%s${R}%*s${HDR:-$PRP}${B}│${R}\n" "$t" "$p" ""; }
title() { printf "\n${PRP}${B}  ╭%s╮${R}\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"; HDR="$PRP" boxline "$1"
          printf "${PRP}${B}  ╰%s╯${R}\n\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"; }
step() { printf "  ${CYN}▸${R} ${B}%s${R}\n" "$1"; }
ok()   { printf "    ${GRN}✓${R} %s\n" "$1"; }
warn() { printf "    ${YLW}!${R} %s\n" "$1"; }
bad()  { printf "    ${RED}✗${R} %s\n" "$1"; }
info() { printf "    ${GRY}·${R} %s\n" "$1"; }
kv()   { printf "    ${GRY}%-12s${R} %s\n" "$1" "$2"; }
die()  { printf "\n  ${RED}${B}✗ %s${R}\n\n" "$1" >&2; exit 1; }
run()  { if [ "$DRY" -eq 1 ]; then printf "      ${GRY}$ %s${R}\n" "$*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --dry-run) DRY=1; CHECK=1 ;;
    --version) shift; TARGET_VER="${1:-}" ;;
    --version=*) TARGET_VER="${1#*=}" ;;
    --node-major) shift; NODE_MAJOR="${1:-}" ;;
    --node-major=*) NODE_MAJOR="${1#*=}" ;;
    --skip-node) SKIP_NODE=1 ;;
    --no-backup) DO_BACKUP=0 ;;
    --no-restart) DO_RESTART=0 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '3,25p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die "Opsi tidak dikenal: $1" ;;
  esac
  shift
done

# ── util: banding versi Node dengan range semver (mis. ">=24.16.0 <25 || >=26.1.0") ──
node_satisfies() { # $1=range  $2=versi
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import re,sys
def norm(v):
    p=[int(x) for x in re.findall(r'\d+', v)[:3]]
    while len(p)<3: p.append(0)
    return tuple(p)
rng, ver = sys.argv[1], sys.argv[2]
v = norm(ver)
for alt in rng.split('||'):
    good=True
    for tok in alt.strip().split():
        m=re.match(r'^(>=|<=|>|<|=)?\s*v?([\d.]+)', tok)
        if not m: continue
        op=(m.group(1) or '='); t=norm(m.group(2))
        if   op=='>=' and v<t: good=False
        elif op=='>'  and v<=t: good=False
        elif op=='<=' and v>t: good=False
        elif op=='<'  and v>=t: good=False
        elif op=='='  and v!=t: good=False
        if not good: break
    if good: sys.exit(0)
sys.exit(1)
PY
}
major_from_range() { # pilih major tertinggi yang diizinkan range
  python3 - "$1" <<'PY' 2>/dev/null
import re,sys
rng=sys.argv[1]; best=[]
for alt in rng.split('||'):
    m=re.search(r'>=\s*v?(\d+)\.(\d+)(?:\.(\d+))?', alt)
    if m and re.search(r'<\s*v?(\d+)', alt):
        lo=int(m.group(1)); hi=int(re.search(r'<\s*v?(\d+)', alt).group(1))
        best.append((lo, hi))
if best:
    lo,hi=max(best)
    print(lo)
PY
}

printf "\n"
[ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null && exec sudo -E bash -c "curl -sS '$SELF_URL' | bash -s -- $*" || die "Butuh root/sudo"; }

# ── [1/8] Deteksi ───────────────────────────────────────────────────────────
title "OpenClaw upgrade v$VERSION_SCRIPT"
step "[1/8] Deteksi instalasi"
OC_BIN=$(command -v openclaw || true); [ -n "$OC_BIN" ] || die "CLI openclaw tidak ditemukan (npm i -g openclaw dulu)"
OC_REAL=$(readlink -f "$OC_BIN")
OC_PREFIX=$(echo "$OC_REAL" | sed -E 's#(/lib/node_modules/|/node_modules/).*##; s#/bin/.*##'); [ -n "$OC_PREFIX" ] || OC_PREFIX=/usr
NPM_PREFIX=$(npm prefix -g 2>/dev/null || echo "$OC_PREFIX")
CUR_VER=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
NODE_VER=$(node -v 2>/dev/null | sed 's/^v//')
NPM_VER=$(npm -v 2>/dev/null)

if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then RUNMODE="systemd"
elif screen -ls 2>/dev/null | grep -q "\.$SERVICE_NAME"; then RUNMODE="screen"
elif pgrep -f 'openclaw gateway' >/dev/null 2>&1; then RUNMODE="process"
else RUNMODE="manual"; fi

kv "openclaw" "$CUR_VER ($OC_BIN)"
kv "node/npm" "v$NODE_VER / $NPM_VER"
kv "prefix" "$NPM_PREFIX"
kv "gateway" "$RUNMODE"
kv "service" "$(svc_state)"

# env milik unit systemd — supaya CLI dijalankan dengan HOME/state dir yang benar
# (kalau tidak, CLI dijalankan sebagai root akan membaca /root/.openclaw, bukan state service)
OC_USER=$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true); [ -n "$OC_USER" ] || OC_USER=$(id -u openclaw >/dev/null 2>&1 && echo openclaw || echo root)
OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER")
UNIT_ENV=$(systemctl show "$SERVICE_NAME" -p Environment --value 2>/dev/null || echo "")
OC_HOME=$(printf '%s\n' "$UNIT_ENV" | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -1)
[ -n "$OC_HOME" ] || { OC_HOME=$(getent passwd "$OC_USER" | cut -d: -f6); [ -n "$OC_HOME" ] && [ "$OC_HOME" != "/" ] || OC_HOME=/opt/openclaw; }
STATE_DIR=$(printf '%s\n' "$UNIT_ENV" | tr ' ' '\n' | sed -n 's/^OPENCLAW_STATE_DIR=//p' | head -1)
[ -n "$STATE_DIR" ] || STATE_DIR="$OC_HOME/.openclaw"
STATE_DB=$(ls "$STATE_DIR"/state/*.sqlite 2>/dev/null | head -1)
PORT=$(printf '%s\n' "$UNIT_ENV" | tr ' ' '\n' | sed -n 's/^OPENCLAW_GATEWAY_PORT=//p' | head -1); [ -n "$PORT" ] || PORT=18789
kv "user/home" "$OC_USER · $OC_HOME"
kv "state dir" "$STATE_DIR$( [ -d "$STATE_DIR" ] && echo " ($(du -sh "$STATE_DIR" 2>/dev/null | cut -f1))" || echo ' (belum ada)')"

# jalankan CLI dengan env milik unit — supaya state dir & HOME benar (root pun ikut env unit)
as_oc() {
  local cmd="$1"
  if [ "$OC_USER" = root ]; then
    env HOME="$OC_HOME" OPENCLAW_HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "$cmd"
  else
    sudo -u "$OC_USER" -H env HOME="$OC_HOME" OPENCLAW_HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "cd $OC_HOME && $cmd"
  fi
}

# ── [2/8] Tentukan target & requirement Node ────────────────────────────────
step "[2/8] Tentukan target versi + requirement Node"
if [ -z "$TARGET_VER" ]; then
  TARGET_VER=$(npm view openclaw dist-tags.latest 2>/dev/null | tr -d "'\"")
  [ -n "$TARGET_VER" ] || die "Tidak bisa membaca versi terbaru dari npm (cek koneksi/DNS)"
fi
REQ_NODE=$(npm view "openclaw@$TARGET_VER" engines.node 2>/dev/null | tr -d "'\"")
[ -n "$REQ_NODE" ] || REQ_NODE=""
kv "target" "$TARGET_VER"
kv "butuh node" "${REQ_NODE:-(tidak dideklarasikan)}"

NODE_OK=1
if [ -n "$REQ_NODE" ]; then
  if node_satisfies "$REQ_NODE" "$NODE_VER"; then ok "Node v$NODE_VER memenuhi syarat"
  else NODE_OK=0; warn "Node v$NODE_VER TIDAK memenuhi ($REQ_NODE)"; fi
fi
if [ -z "$NODE_MAJOR" ] && [ -n "$REQ_NODE" ]; then NODE_MAJOR=$(major_from_range "$REQ_NODE"); fi
info "major Node yang akan dipasang: ${NODE_MAJOR:-<tidak perlu>}"

SKIP_NPM=0
if [ "$CUR_VER" = "$TARGET_VER" ] && [ "$NODE_OK" -eq 1 ]; then
  if [ "$(svc_state)" = active ] && ss -tlnH 2>/dev/null | grep -q ":$PORT "; then
    printf "\n  ${GRN}${B}✓ Sudah versi terbaru ($CUR_VER), Node cocok, dan gateway sehat — tidak ada yang perlu dilakukan.${R}\n\n"; exit 0
  fi
  SKIP_NPM=1
  warn "versi sudah $TARGET_VER tapi gateway belum sehat → lanjut perbaikan (migrasi DB + start)"
fi

if [ "$CHECK" -eq 1 ]; then
  step "[3/8] Rencana"
  [ "$NODE_OK" -eq 0 ] && kv "aksi 1" "pasang Node.js $NODE_MAJOR (NodeSource: $NODE_REPO_URL/setup_$NODE_MAJOR.x)"
  kv "aksi 2" "npm i -g openclaw@$TARGET_VER (prefix $NPM_PREFIX)"
  [ "$DO_BACKUP" -eq 1 ] && kv "aksi 0" "backup state ke $BACKUP_DIR/openclaw-pre-upgrade-<ts>.tar.gz"
  kv "aksi 3" "restart gateway ($RUNMODE) + health check (port 18789, dashboard HTTP 200)"
  kv "rollback" "npm i -g openclaw@$CUR_VER"
  printf "\n  ${CYN}${B}%s — tidak ada perubahan.${R}\n\n" "$( [ "$DRY" -eq 1 ] && echo 'DRY-RUN' || echo 'CEK SAJA' )"
  exit 0
fi

# ── [3/8] Backup state ─────────────────────────────────────────────────────
step "[3/8] Backup state sebelum upgrade"
if [ "$DO_BACKUP" -eq 1 ]; then
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  chown "$OC_USER:$OC_GROUP" "$BACKUP_DIR" 2>/dev/null || true
  if [ "$OC_USER" = root ]; then run openclaw backup create --output "$BACKUP_DIR" --verify >/tmp/oc-upgrade-backup.log 2>&1
  else run as_oc "openclaw backup create --output $BACKUP_DIR --verify" >/tmp/oc-upgrade-backup.log 2>&1; fi
  if [ "$DRY" -eq 0 ]; then
    if grep -qi "verification: passed\|verification passed" /tmp/oc-upgrade-backup.log; then
      ARSIP=$(ls -t "$BACKUP_DIR"/*openclaw-backup.tar.gz 2>/dev/null | head -1)
      ok "backup OK: $(basename "${ARSIP:-?}") ($(du -sh "${ARSIP:-/dev/null}" 2>/dev/null | cut -f1))"
    elif grep -qi "schema migration" /tmp/oc-upgrade-backup.log; then
      warn "backup ditolak OpenClaw: state DB butuh migrasi dulu. Jalankan (service mati): openclaw doctor --fix"
    else warn "backup tidak terverifikasi — cek /tmp/oc-upgrade-backup.log"; fi
  fi
else info "--no-backup: dilewati"; fi

# ── [4/8] Node.js ──────────────────────────────────────────────────────────
step "[4/8] Pastikan Node.js memenuhi syarat"
if [ "$NODE_OK" -eq 1 ]; then
  ok "lewat — Node v$NODE_VER sudah cocok"
elif [ "$SKIP_NODE" -eq 1 ]; then
  die "Node v$NODE_VER belum memenuhi ($REQ_NODE) dan --skip-node dipakai"
else
  [ -n "$NODE_MAJOR" ] || die "Tidak bisa menentukan major Node dari requirement: $REQ_NODE (pakai --node-major N)"
  if [ -d /root/.nvm/versions/node ] || [ -s "${NVM_DIR:-/root/.nvm}/nvm.sh" ]; then
    info "nvm terdeteksi → nvm install $NODE_MAJOR"
    run bash -lc "source ${NVM_DIR:-/root/.nvm}/nvm.sh && nvm install $NODE_MAJOR && nvm alias default $NODE_MAJOR && nvm use $NODE_MAJOR"
  else
    command -v apt-get >/dev/null || die "bukan sistem apt — pasang Node $NODE_MAJOR manual lalu ulangi dengan --skip-node"
    info "pasang Node.js $NODE_MAJOR dari NodeSource"
    run bash -c "curl -fsSL $NODE_REPO_URL/setup_$NODE_MAJOR.x | bash -"
    run apt-get install -y nodejs
  fi
  if [ "$DRY" -eq 0 ]; then
    hash -r
    NODE_VER=$(node -v | sed 's/^v//')
    if [ -n "$REQ_NODE" ] && node_satisfies "$REQ_NODE" "$NODE_VER"; then ok "Node sekarang v$NODE_VER (memenuhi)"
    else die "Node v$NODE_VER masih belum memenuhi $REQ_NODE — pasang manual, lalu pakai --skip-node"; fi
  fi
fi

# ── [5/8] Upgrade OpenClaw ─────────────────────────────────────────────────
step "[5/8] Upgrade OpenClaw $CUR_VER → $TARGET_VER"
GW_STOPPED=0
if [ "$RUNMODE" = systemd ]; then run systemctl stop "$SERVICE_NAME"; GW_STOPPED=1
elif [ "$RUNMODE" = screen ] || [ "$RUNMODE" = process ]; then run pkill -f 'openclaw gateway' || true; GW_STOPPED=1; fi
[ "$DRY" -eq 0 ] && sleep 2
if [ "$SKIP_NPM" -eq 1 ]; then info "lewati npm install — versi $TARGET_VER sudah terpasang"
else run npm i -g "openclaw@$TARGET_VER" >/tmp/oc-upgrade-npm.log 2>&1; fi
if [ "$DRY" -eq 0 ]; then
  NEW_VER=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
  [ "$NEW_VER" = "$TARGET_VER" ] && ok "terpasang: $NEW_VER" || { tail -8 /tmp/oc-upgrade-npm.log | sed 's/^/      /'; die "upgrade gagal (versi terdeteksi: $NEW_VER)"; }
fi

# ── [6/8] Rapikan pasca-upgrade ────────────────────────────────────────────
step "[6/8] Rapikan (migrasi config/db & plugin)"
if [ "$DRY" -eq 0 ]; then
  # path absolut state lama (mis. hasil migrasi dari /root/.openclaw) harus dipetakan dulu,
  # kalau tidak `openclaw doctor --fix` gagal EACCES dan migrasi skema DB tidak jalan
  REMAP=/tmp/remap-state-paths.py
  [ -s "$REMAP" ] || curl -fsS -m 30 "$REPO_RAW/remap-state-paths.py" -o "$REMAP" 2>/dev/null || true
  if [ -s "$REMAP" ]; then
    ROUT=$(python3 "$REMAP" --state-dir "$STATE_DIR" --quiet 2>&1 | tail -1)
    case "$ROUT" in
      REMAP_OK*) ok "path state lama dipetakan ulang (${ROUT#REMAP_OK })"; chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" ;;
      *) info "remap path: ${ROUT:-tidak ada perubahan}" ;;
    esac
  else warn "helper remap tidak tersedia — lewati pemetaan path"; fi
  openclaw --help 2>&1 | grep -qE "^  update " && { as_oc "timeout 240 openclaw update repair 2>&1 | tail -6" || true; }
  as_oc "timeout 240 openclaw doctor --fix 2>&1 | tail -6" || warn "doctor --fix melaporkan catatan (lihat output)"
fi

# ── [7/8] Nyalakan + health check ──────────────────────────────────────────
step "[7/8] Jalankan gateway + health check"
HEALTH_OK=0
if [ "$DO_RESTART" -eq 1 ] && [ "$DRY" -eq 0 ]; then
  case "$RUNMODE" in
    systemd) systemctl start "$SERVICE_NAME" ;;
    screen)  screen -dmS "$SERVICE_NAME" bash -c "openclaw gateway --port $PORT 2>&1 | tee -a /var/log/openclaw-gateway.log" ;;
    *)       info "mode manual — jalankan sendiri: openclaw gateway --port $PORT" ;;
  esac
  # tunggu sampai timeout (migrasi database pada VM kecil bisa >30 detik)
  WAIT_MAX="${OPENCLAW_START_TIMEOUT:-180}"; WAITED=0
  while [ "$WAITED" -lt "$WAIT_MAX" ]; do
    ss -tlnH 2>/dev/null | grep -q ":$PORT " && { HEALTH_OK=1; break; }
    ST=$(svc_state)
    if [ "$RUNMODE" = systemd ] && [ "$ST" = failed ]; then bad "service gagal start (status: failed)"; break; fi
    printf "\r    ${GRY}· menunggu gateway siap… %ss (service: %s)${R}   " "$WAITED" "$ST"
    sleep 3; WAITED=$((WAITED+3))
  done
  printf "\r%*s\r" 64 ""
  if [ "$HEALTH_OK" -eq 1 ]; then ok "gateway listening :$PORT (${WAITED}s)"; else bad "port :$PORT tidak listen setelah ${WAIT_MAX}s"; fi
  CODE=000
  for i in 1 2 3 4 5; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
    [ "$CODE" = "200" ] && break; sleep 3
  done
  [ "$CODE" = "200" ] && ok "dashboard HTTP 200" || warn "dashboard HTTP $CODE"
  if [ "$HEALTH_OK" -eq 0 ]; then
    info "8 baris log terakhir:"
    journalctl -u "$SERVICE_NAME" -n 8 --no-pager 2>/dev/null | tail -8 | sed 's/^/      /'
  fi
else
  info "$( [ "$DO_RESTART" -eq 1 ] && echo 'dry-run: gateway akan dinyalakan' || echo '--no-restart: gateway dibiarkan mati' )"
  HEALTH_OK=1
fi

# ── [8/8] Rollback kalau tidak sehat ───────────────────────────────────────
if [ "$HEALTH_OK" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  step "[8/8] Rollback ke $CUR_VER"
  [ "$RUNMODE" = systemd ] && systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  npm i -g "openclaw@$CUR_VER" >/tmp/oc-upgrade-rollback.log 2>&1 && ok "versi dikembalikan: $(openclaw --version 2>&1 | head -1 | awk '{print $2}')" || bad "rollback gagal — cek /tmp/oc-upgrade-rollback.log"
  [ "$RUNMODE" = systemd ] && systemctl start "$SERVICE_NAME" 2>/dev/null || true
  die "Upgrade di-rollback (gateway tidak sehat setelah upgrade). Log: journalctl -u $SERVICE_NAME -n 50"
fi

printf "\n  ${GRN}${B}╭──────────────────────────────────────────────────────────────╮${R}\n"
  HDR="$GRN" boxline "✓ Upgrade OpenClaw selesai"
printf "  ${GRN}${B}╰──────────────────────────────────────────────────────────────╯${R}\n\n"
kv "versi"     "$CUR_VER → $(openclaw --version 2>&1 | head -1 | awk '{print $2}')"
kv "node"      "v$(node -v | sed 's/^v//') (butuh: ${REQ_NODE:-bebas})"
kv "gateway"   "$RUNMODE, port ${PORT:-18789}"
kv "service"   "$(svc_state)"
kv "backup"    "$(ls -t "$BACKUP_DIR"/*openclaw-backup.tar.gz 2>/dev/null | head -1 || echo '-')"
printf "\n  ${GRY}  Cek lanjutan: openclaw status · openclaw doctor${R}\n"
printf "  ${GRY}  Rollback manual: npm i -g openclaw@$CUR_VER && systemctl restart $SERVICE_NAME${R}\n\n"
exit 0
