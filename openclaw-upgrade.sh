#!/usr/bin/env bash
# ============================================================================
#  ⬢ openclaw-upgrade.sh — upgrade OpenClaw + pastikan Node.js memenuhi syarat
#  Repo: https://github.com/ujang0311/openclaw-tools
#
#  Semua path (state dir, user, cara gateway jalan, port) DETEKSI OTOMATIS.
#
#  CEK   : curl -sS .../openclaw-upgrade.sh | bash -s -- --check
#  UPGRADE: curl -sS .../openclaw-upgrade.sh | bash
#
#  Opsi: --version X  --node-major N  --skip-node  --no-backup  --no-restart  --force  --dry-run
#  Bash >= 4.2 · butuh root
# ============================================================================
set -u -o pipefail

VERSION_SCRIPT="1.2.0"
SELF_URL="${OPENCLAW_UPGRADE_URL:-https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-upgrade.sh}"
REPO_RAW="${OPENCLAW_TOOLS_RAW:-https://raw.githubusercontent.com/ujang0311/openclaw-tools/main}"
SERVICE_NAME="${OPENCLAW_SERVICE:-openclaw}"
BACKUP_DIR="${OPENCLAW_BACKUP_DIR:-/var/backups/openclaw}"
NODE_REPO_URL="${NODESOURCE_URL:-https://deb.nodesource.com}"
DEFAULT_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

DRY=0; CHECK=0; TARGET_VER=""; NODE_MAJOR=""; SKIP_NODE=0; DO_BACKUP=1; DO_RESTART=1; FORCE=0

# ══════════════════════════════ UI ══════════════════════════════════════════
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; R=$'\033[0m'
  GRN=$'\033[38;5;47m'; YLW=$'\033[38;5;221m'; RED=$'\033[38;5;203m'
  CYN=$'\033[38;5;45m'; PRP=$'\033[38;5;141m'; GRY=$'\033[38;5;245m'; BLD=$'\033[38;5;81m'
else
  B=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; PRP=""; GRY=""; BLD=""
fi
UIW=68
_slen() { printf '%s' "$1" | wc -m | tr -d ' '; }
_top()  { printf "  ${PRP}${B}╭%s╮${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_bot()  { printf "  ${PRP}${B}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_bl()   { local plain="$1" colored="${2:-$1}" len pad; colored="${colored#"${colored%%[![:space:]]*}"}"
          len=$(_slen "$plain"); pad=$(( UIW - 6 - len )); [ "$pad" -lt 0 ] && pad=0
          printf "  ${PRP}${B}│${R}  %s%*s${PRP}${B}│${R}\n" "$colored" "$pad" ""; }
_blc()  { local plain="${1:-}" colored="${2:-}" c="${3:-$PRP}" len pad; colored="${colored#"${colored%%[![:space:]]*}"}"
          len=$(_slen "$plain"); pad=$(( UIW - 6 - len )); [ "$pad" -lt 0 ] && pad=0
          printf "  ${c}│${R}  %s%*s${c}│${R}\n" "$colored" "$pad" ""; }
_header(){ printf "\n"; printf "  ${2}╭─ ${B}%s${R}${2} %s╮${R}\n" "$1" "$(printf '─%.0s' $(seq 1 $((UIW-8-$(_slen "$1")))))"; }
_foot() { printf "  ${1}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_clr()  { printf "\r%*s\r" "$UIW" ""; }
_fit()  { local t="$1" max="$2"; if [ "$(_slen "$t")" -gt "$max" ]; then printf '…%s' "$(printf '%s' "$t" | rev | cut -c1-$((max-1)) | rev)"; else printf '%s' "$t"; fi; }
_banner() { printf "\n"; _top
  _bl "⬢  OpenClaw Upgrade  v$VERSION_SCRIPT" "  ${PRP}⬢${R}  ${B}OpenClaw Upgrade${R}  ${GRY}v$VERSION_SCRIPT${R}"
  _bl "cek Node → pasang Node → upgrade → migrasi DB → health check" "  ${GRY}cek Node → pasang Node → upgrade → migrasi DB → health check${R}"
  _bot; printf "\n"; }
sec()  { printf "  ${CYN}◆${R} ${B}%s${R}${2:+  ${GRY}%s${R}}\n" "$1" "${2:-}"; }
tree() { printf "    ${GRY}%s${R} %s\n" "$1" "$2"; }
ok()   { printf "    ${GRN}✔${R} %s\n" "$1"; }
warn() { printf "    ${YLW}▲${R} ${YLW}%s${R}\n" "$1"; }
bad()  { printf "    ${RED}✖${R} ${RED}%s${R}\n" "$1"; }
info() { printf "    ${GRY}·${R} ${GRY}%s${R}\n" "$1"; }
kv()   { printf "    ${GRY}%-13s${R} %s\n" "$1" "$2"; }
hint() { printf "      ${GRY}└─ %s${R}\n" "$1"; }
die()  { printf "\n  ${RED}${B}╭─ GAGAL ──────────────────────────────────────────────────────────────╮${R}\n"
         printf "  ${RED}${B}│${R}  ${RED}✖ %s${R}\n" "$1"
         printf "  ${RED}${B}╰──────────────────────────────────────────────────────────────────────╯${R}\n\n"; exit 1; }
hb() { local label="$1"; shift
  local spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 t=0 rc=0
  "$@" >/tmp/oc-upgrade-cmd.log 2>&1 & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r    ${PRP}%s${R} ${GRY}%s…${R} ${BLD}%ss${R}   " "${spin[$((i%10))]}" "$label" "$t"; sleep 1; i=$((i+1)); t=$((t+1)); done
  wait "$pid" || rc=$?; _clr; HB_ELAPSED=$t; return $rc; }
hsize(){ du -sh "$1" 2>/dev/null | cut -f1; }
svc_state(){ local s; s=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null); [ -n "$s" ] && printf '%s' "$s" || printf 'n/a'; }
elapsed(){ printf '%ss' "$SECONDS"; }

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
    -h|--help) _banner; sed -n '3,14p' "$0" 2>/dev/null; exit 0 ;;
    *) die "Opsi tidak dikenal: $1" ;;
  esac
  shift
done

node_satisfies() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import re,sys
def norm(v):
    p=[int(x) for x in re.findall(r'\d+', v)[:3]]
    while len(p)<3: p.append(0)
    return tuple(p)
rng, ver = sys.argv[1], sys.argv[2]; v = norm(ver)
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
major_from_range() {
  python3 - "$1" <<'PY' 2>/dev/null
import re,sys
best=[]
for alt in sys.argv[1].split('||'):
    m=re.search(r'>=\s*v?(\d+)\.(\d+)', alt); h=re.search(r'<\s*v?(\d+)', alt)
    if m and h: best.append((int(m.group(1)), int(h.group(1))))
if best: print(max(best)[0])
PY
}

printf "\n"
[ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null && exec sudo -E bash -c "curl -sS '$SELF_URL' | bash -s -- $*" || die "Butuh root/sudo"; }
command -v openclaw >/dev/null 2>&1 || die "CLI openclaw tidak ditemukan (npm i -g openclaw)"
T0=$SECONDS; _banner

# ══════════════════ DETEKSI OTOMATIS (tanpa arahan manual) ══════════════════
OC_BIN=$(command -v openclaw); CUR_VER=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
NODE_VER=$(node -v 2>/dev/null | sed 's/^v//'); NPM_VER=$(npm -v 2>/dev/null)
NPM_PREFIX=$(npm prefix -g 2>/dev/null || echo /usr)
MODE=""; UNIT_ENV=""; GW_PID=""
if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then MODE="systemd (system)"
  UNIT_ENV=$(systemctl show "$SERVICE_NAME" -p Environment --value 2>/dev/null || echo "")
  OC_USER=$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)
  GW_PID=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || echo "")
elif systemctl --user cat "$SERVICE_NAME" >/dev/null 2>&1; then MODE="systemd (user)"
  UNIT_ENV=$(systemctl --user show "$SERVICE_NAME" -p Environment --value 2>/dev/null || echo "")
  OC_USER=$(systemctl --user show "$SERVICE_NAME" -p User --value 2>/dev/null || true)
elif screen -ls 2>/dev/null | grep -q "$SERVICE_NAME"; then MODE="screen session"
elif pgrep -f 'openclaw.*gateway' >/dev/null 2>&1; then MODE="proses manual"; else MODE="tidak terdeteksi"; fi
[ -n "${GW_PID:-}" ] && [ "${GW_PID:-0}" = 0 ] && GW_PID=""
[ -z "${GW_PID:-}" ] && GW_PID=$(pgrep -f 'openclaw.*gateway' 2>/dev/null | head -1 || true)

SRC_USER="unit systemd"
[ -n "${OC_USER:-}" ] || { id openclaw >/dev/null 2>&1 && { OC_USER=openclaw; SRC_USER="user 'openclaw'"; } || { OC_USER=root; SRC_USER="default"; }; }
OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER")
OC_HOME=$(getent passwd "$OC_USER" | cut -d: -f6); [ -n "$OC_HOME" ] && [ "$OC_HOME" != "/" ] || OC_HOME=/opt/openclaw
UNIT_HOME=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -1); [ -n "${UNIT_HOME:-}" ] && OC_HOME="$UNIT_HOME"
PORT=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^OPENCLAW_GATEWAY_PORT=//p' | head -1); [ -n "${PORT:-}" ] || PORT="$DEFAULT_PORT"

SRC_STATE=""
if [ -n "${OPENCLAW_STATE_DIR:-}" ]; then STATE_DIR="$OPENCLAW_STATE_DIR"; SRC_STATE="env OPENCLAW_STATE_DIR"
else
  v=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^OPENCLAW_STATE_DIR=//p' | head -1)
  if [ -n "${v:-}" ]; then STATE_DIR="$v"; SRC_STATE="unit systemd"
  elif [ -n "${GW_PID:-}" ] && [ -r "/proc/$GW_PID/environ" ]; then
    v=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null | sed -n 's/^OPENCLAW_STATE_DIR=//p' | head -1)
    if [ -n "${v:-}" ]; then STATE_DIR="$v"; SRC_STATE="proses gateway (pid $GW_PID)"
    else v=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)
      [ -n "${v:-}" ] && [ -f "$v/.openclaw/openclaw.json" ] && { STATE_DIR="$v/.openclaw"; SRC_STATE="HOME proses gateway (pid $GW_PID)"; }
    fi
  fi
fi
if [ -z "${STATE_DIR:-}" ]; then
  v=$(openclaw config file 2>/dev/null | grep -oE '/[^ "]*/\.openclaw/openclaw\.json' | head -1)
  if [ -n "${v:-}" ]; then STATE_DIR="$(dirname "$v")"; SRC_STATE="CLI config file"
  else for c in "$OC_HOME/.openclaw" /opt/openclaw/.openclaw /root/.openclaw /var/lib/openclaw/.openclaw /home/*/.openclaw; do
         [ -f "$c/openclaw.json" ] && { STATE_DIR="$c"; SRC_STATE="pemindaian filesystem"; break; }; done; fi
fi
[ -n "${STATE_DIR:-}" ] || STATE_DIR="$OC_HOME/.openclaw"
[ -n "$SRC_STATE" ] || SRC_STATE="default ($OC_HOME/.openclaw)"
if [ -d "$STATE_DIR" ]; then
  o=$(stat -c %U "$STATE_DIR" 2>/dev/null || echo "$OC_USER")
  if [ -z "$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)" ]; then OC_USER="$o"; OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER"); SRC_USER="owner $STATE_DIR"; fi
fi
STATE_DB=$(ls "$STATE_DIR"/state/*.sqlite 2>/dev/null | head -1)
oc_hb() { # $1 = label spinner (HB_LABEL), $2 = perintah CLI
  if [ "$OC_USER" = root ]; then hb "$HB_LABEL" env HOME="$OC_HOME" OPENCLAW_HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "cd $OC_HOME && $2"
  else hb "$HB_LABEL" sudo -u "$OC_USER" -H env HOME="$OC_HOME" OPENCLAW_HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "cd $OC_HOME && $2"; fi
}
as_oc() { local cmd="$1"
  if [ "$OC_USER" = root ]; then env HOME="$OC_HOME" OPENCLAW_HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "$cmd"
  else sudo -u "$OC_USER" -H env HOME="$OC_HOME" OPENCLAW_HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "cd $OC_HOME && $cmd"; fi; }

sec "[1/8] Deteksi otomatis" "$(elapsed)"
tree "├" "state dir    ${B}$STATE_DIR${R}$( [ -d "$STATE_DIR" ] && echo "  ${GRY}($(hsize "$STATE_DIR"))${R}" || echo "  ${YLW}(belum ada)${R}" )"
tree "│" "${GRY}└ sumber      $SRC_STATE${R}"
tree "├" "owner        ${OC_USER}:${OC_GROUP}  ${GRY}(${SRC_USER})${R}"
tree "├" "openclaw     ${CUR_VER}  ${GRY}${OC_BIN}${R}"
tree "├" "node / npm   v${NODE_VER} / ${NPM_VER}  ${GRY}(prefix $NPM_PREFIX)${R}"
tree "└" "gateway      ${MODE} · port ${PORT} · ${GRN}$(svc_state)${R}$( [ -n "${GW_PID:-}" ] && echo " ${GRY}(pid $GW_PID)${R}" )"

# ── [2/8] target + requirement ──────────────────────────────────────────────
printf "\n"
sec "[2/8] Target versi & requirement Node" "$(elapsed)"
if [ -z "$TARGET_VER" ]; then
  TARGET_VER=$(npm view openclaw dist-tags.latest 2>/dev/null | tr -d "'\"")
  [ -n "$TARGET_VER" ] || die "Tidak bisa membaca versi terbaru dari npm (cek koneksi/DNS server ini)"
fi
REQ_NODE=$(npm view "openclaw@$TARGET_VER" engines.node 2>/dev/null | tr -d "'\"")
kv "target" "$TARGET_VER"
kv "butuh node" "${REQ_NODE:-(tidak dideklarasikan)}"
NODE_OK=1
if [ -n "$REQ_NODE" ]; then
  if node_satisfies "$REQ_NODE" "$NODE_VER"; then ok "Node v$NODE_VER memenuhi syarat"
  else NODE_OK=0; warn "Node v$NODE_VER BELUM memenuhi syarat"; fi
fi
[ -z "$NODE_MAJOR" ] && [ -n "$REQ_NODE" ] && NODE_MAJOR=$(major_from_range "$REQ_NODE")
[ -n "$NODE_MAJOR" ] && info "major Node yang akan dipasang: $NODE_MAJOR"

SKIP_NPM=0
if [ "$CUR_VER" = "$TARGET_VER" ] && [ "$NODE_OK" -eq 1 ]; then
  if [ "$(svc_state)" = active ] && ss -tlnH 2>/dev/null | grep -q ":$PORT "; then
    _header "✔ SUDAH TERBARU & SEHAT" "$GRN"
    _blc "versi        $CUR_VER (terbaru)" "  ${GRY}versi${R}        ${GRN}$CUR_VER${R} (terbaru)"
    _blc "node         v$NODE_VER memenuhi ${REQ_NODE}" "  ${GRY}node${R}         v$NODE_VER ${GRN}memenuhi${R} ${GRY}${REQ_NODE}${R}"
    _blc "gateway      $MODE · port $PORT · aktif" "  ${GRY}gateway${R}      $MODE · port $PORT · ${GRN}aktif${R}"
    _blc "" ""
    _foot "$GRN"; printf "\n  ${GRY}Tidak ada yang perlu dilakukan.${R}\n\n"; exit 0
  fi
  SKIP_NPM=1; warn "versi sudah $TARGET_VER tapi gateway belum sehat → lanjut perbaikan (migrasi DB + start)"
fi

if [ "$CHECK" -eq 1 ]; then
  printf "\n"
  sec "[3/8] Rencana" "$(elapsed)"
  [ "$DO_BACKUP" -eq 1 ] && printf "    ${GRY}1.${R} backup state → %s\n" "$BACKUP_DIR"
  if [ "$NODE_OK" -eq 0 ]; then printf "    ${GRY}2.${R} pasang Node.js %s (NodeSource %s/setup_%s.x)\n" "${NODE_MAJOR:-?}" "$NODE_REPO_URL" "${NODE_MAJOR:-?}"
  else printf "    ${GRY}2.${R} Node sudah memenuhi — dilewati\n"; fi
  printf "    ${GRY}3.${R} npm i -g openclaw@%s (prefix %s)\n" "$TARGET_VER" "$NPM_PREFIX"
  printf "    ${GRY}4.${R} remap path state lama + openclaw update repair + doctor --fix\n"
  printf "    ${GRY}5.${R} start gateway (%s) + health check port %s & dashboard\n" "$MODE" "$PORT"
  kv "rollback" "npm i -g openclaw@$CUR_VER"
  printf "\n  ${CYN}${B}◆ %s — tidak ada perubahan.${R}\n\n" "$( [ "$DRY" -eq 1 ] && echo 'DRY-RUN' || echo 'CEK SAJA' )"
  exit 0
fi

# ── [3/8] backup ────────────────────────────────────────────────────────────
printf "\n"
sec "[3/8] Backup state sebelum upgrade" "$(elapsed)"
if [ "$DO_BACKUP" -eq 1 ]; then
  mkdir -p "$BACKUP_DIR"; chmod 750 "$BACKUP_DIR" 2>/dev/null || true; chown "$OC_USER:$OC_GROUP" "$BACKUP_DIR" 2>/dev/null || true
  HB_LABEL="membuat arsip + verifikasi"
  if oc_hb "$HB_LABEL" "openclaw backup create --output '$BACKUP_DIR' --verify"; then
    ARSIP=$(ls -t "$BACKUP_DIR"/*openclaw-backup.tar.gz 2>/dev/null | head -1)
    ok "arsip: $( [ -n "${ARSIP:-}" ] && basename "$ARSIP" || '-' ) ${GRY}($( [ -n "${ARSIP:-}" ] && hsize "$ARSIP" || echo - ) · ${HB_ELAPSED}s)${R}"
  elif grep -qi "schema migration" /tmp/oc-upgrade-cmd.log; then
    warn "OpenClaw menolak backup: state DB butuh migrasi dulu (dilakukan di langkah 6)"
  else
    warn "backup tidak berhasil — lanjut (lihat /tmp/oc-upgrade-cmd.log)"
  fi
else info "--no-backup: dilewati"; fi

# ── [4/8] Node ──────────────────────────────────────────────────────────────
printf "\n"
sec "[4/8] Node.js" "$(elapsed)"
if [ "$NODE_OK" -eq 1 ]; then ok "lewat — Node v$NODE_VER sudah cocok"
elif [ "$SKIP_NODE" -eq 1 ]; then die "Node v$NODE_VER belum memenuhi ($REQ_NODE) dan --skip-node dipakai"
else
  [ -n "$NODE_MAJOR" ] || die "Tidak bisa menentukan major Node dari requirement: $REQ_NODE (pakai --node-major N)"
  if [ -d /root/.nvm/versions/node ] || [ -s "${NVM_DIR:-/root/.nvm}/nvm.sh" ]; then
    info "nvm terdeteksi → nvm install $NODE_MAJOR"
    hb "nvm install $NODE_MAJOR" bash -lc "source ${NVM_DIR:-/root/.nvm}/nvm.sh && nvm install $NODE_MAJOR && nvm alias default $NODE_MAJOR" || true
  else
    command -v apt-get >/dev/null || die "bukan sistem apt — pasang Node $NODE_MAJOR manual lalu pakai --skip-node"
    info "NodeSource: setup_$NODE_MAJOR.x"
    hb "menyiapkan repo NodeSource $NODE_MAJOR" bash -c "curl -fsSL $NODE_REPO_URL/setup_$NODE_MAJOR.x | bash -" || true
    hb "memasang Node.js $NODE_MAJOR" env DEBIAN_FRONTEND=noninteractive apt-get install -y -q nodejs || true
  fi
  hash -r; NODE_VER=$(node -v 2>/dev/null | sed 's/^v//'); NPM_VER=$(npm -v 2>/dev/null)
  if [ -n "$REQ_NODE" ] && node_satisfies "$REQ_NODE" "$NODE_VER"; then ok "Node sekarang v$NODE_VER (memenuhi ${REQ_NODE})"
  else die "Node v$NODE_VER masih belum memenuhi $REQ_NODE — pasang manual lalu ulangi dengan --skip-node"; fi
fi

# ── [5/8] upgrade paket ─────────────────────────────────────────────────────
printf "\n"
sec "[5/8] Upgrade OpenClaw" "$(elapsed)"
kv "perubahan" "$CUR_VER → $TARGET_VER"
case "$MODE" in
  systemd*) hb "stop service" systemctl stop "$SERVICE_NAME" 2>/dev/null || true; ok "service dihentikan" ;;
  *) pkill -f 'openclaw.*gateway' 2>/dev/null || true; sleep 2; ok "proses gateway dihentikan" ;;
esac
if [ "$SKIP_NPM" -eq 1 ]; then info "lewati npm install — versi $TARGET_VER sudah terpasang"
else
  if hb "npm i -g openclaw@$TARGET_VER" bash -c "npm i -g openclaw@$TARGET_VER"; then
    NEW_VER=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
    [ "$NEW_VER" = "$TARGET_VER" ] && ok "terpasang: ${GRN}${B}$NEW_VER${R} ${GRY}(${HB_ELAPSED}s)${R}" || { bad "versi terdeteksi $NEW_VER"; die "upgrade gagal"; }
  else tail -6 /tmp/oc-upgrade-cmd.log | sed 's/^/      /'; die "npm install gagal"; fi
fi

# ── [6/8] migrasi & perbaikan ───────────────────────────────────────────────
printf "\n"
sec "[6/8] Migrasi & perbaikan" "$(elapsed)"
REMAP=/tmp/remap-state-paths.py
[ -s "$REMAP" ] || curl -fsS -m 30 "$REPO_RAW/remap-state-paths.py" -o "$REMAP" 2>/dev/null || true
if [ -s "$REMAP" ]; then
  ROUT=$(python3 "$REMAP" --state-dir "$STATE_DIR" --quiet 2>&1 | tail -1)
  case "$ROUT" in
    REMAP_OK*) ok "path state lama dipetakan ${GRY}(${ROUT#REMAP_OK })${R}"; chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" ;;
    *) info "pemetaan path: tidak ada perubahan diperlukan" ;;
  esac
else warn "helper remap tidak tersedia — lewati pemetaan path"; fi
openclaw --help 2>&1 | grep -qE "^  update " && { HB_LABEL="openclaw update repair"; oc_hb "$HB_LABEL" "timeout 240 openclaw update repair" || true; }
HB_LABEL="openclaw doctor --fix (service mati)"
if oc_hb "$HB_LABEL" "timeout 300 openclaw doctor --fix"; then
  ok "doctor --fix selesai ${GRY}(${HB_ELAPSED}s)${R}"
else warn "doctor --fix melaporkan catatan — cek output di atas"; fi

# ── [7/8] start + health ────────────────────────────────────────────────────
printf "\n"
sec "[7/8] Jalankan gateway + health check" "$(elapsed)"
GW_OK=0
if [ "$DO_RESTART" -eq 0 ]; then info "--no-restart: gateway dibiarkan mati"
else
  case "$MODE" in
    systemd*) systemctl start "$SERVICE_NAME" ;;
    screen*)  screen -dmS "$SERVICE_NAME" bash -c "openclaw gateway --port $PORT 2>&1 | tee -a /var/log/openclaw-gateway.log" ;;
    *)        info "mode manual — jalankan sendiri: openclaw gateway --port $PORT" ;;
  esac
  WMAX="${OPENCLAW_START_TIMEOUT:-180}"; W=0
  while [ "$W" -lt "$WMAX" ]; do
    ss -tlnH 2>/dev/null | grep -q ":$PORT " && { GW_OK=1; break; }
    printf "\r    ${PRP}⠿${R} ${GRY}menunggu gateway siap…${R} ${BLD}%ss${R} ${GRY}(service: %s)${R}   " "$W" "$(svc_state)"
    sleep 3; W=$((W+3))
  done
  _clr
  [ "$GW_OK" -eq 1 ] && ok "gateway listening :$PORT ${GRY}(${W}s)${R}" || bad "port :$PORT tidak listen setelah ${WMAX}s"
  CODE=000; for i in 1 2 3 4 5; do CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000); [ "$CODE" = 200 ] && break; sleep 3; done
  [ "$CODE" = 200 ] && ok "dashboard HTTP 200" || warn "dashboard HTTP $CODE"
  if [ "$GW_OK" -eq 0 ]; then
    info "6 baris log terakhir:"; journalctl -u "$SERVICE_NAME" -n 6 --no-pager 2>/dev/null | tail -6 | sed 's/^/      /'
  fi
fi

# ── [8/8] rollback kalau tidak sehat ────────────────────────────────────────
if [ "$GW_OK" -eq 0 ] && [ "$DO_RESTART" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  printf "\n"; sec "[8/8] Rollback ke $CUR_VER" "$(elapsed)"
  case "$MODE" in systemd*) systemctl stop "$SERVICE_NAME" 2>/dev/null || true ;; esac
  if hb "kembalikan versi $CUR_VER" npm i -g "openclaw@$CUR_VER"; then ok "versi dikembalikan: $(openclaw --version 2>&1 | head -1 | awk '{print $2}')"
  else bad "rollback gagal — cek /tmp/oc-upgrade-cmd.log"; fi
  case "$MODE" in systemd*) systemctl start "$SERVICE_NAME" 2>/dev/null || true ;; esac
  die "upgrade di-rollback karena gateway tidak sehat (log: journalctl -u $SERVICE_NAME -n 50)"
fi

# ── ringkasan ───────────────────────────────────────────────────────────────
NEW_VER=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
_header "✔ UPGRADE SELESAI" "$GRN"; _blc "" ""
_blc "versi        $CUR_VER → $NEW_VER" "  ${GRY}versi${R}        $CUR_VER ${GRY}→${R} ${GRN}${B}$NEW_VER${R}"
_blc "node         v$NODE_VER (butuh ${REQ_NODE:-bebas})" "  ${GRY}node${R}         v$NODE_VER ${GRY}(butuh ${REQ_NODE:-bebas})${R}"
_blc "state        $(_fit "$STATE_DIR" 40)" "  ${GRY}state${R}        $(_fit "$STATE_DIR" 40)"
_blc "gateway      $MODE · port $PORT · $(svc_state)" "  ${GRY}gateway${R}      $MODE · port $PORT · $(svc_state)"
_blc "dashboard    http://127.0.0.1:$PORT/ (HTTP ${CODE:-n/a})" "  ${GRY}dashboard${R}    http://127.0.0.1:$PORT/ ${GRY}(HTTP ${CODE:-n/a})${R}"
_blc "backup       $( [ -n "${ARSIP:-}" ] && basename "$ARSIP" || echo '-')" "  ${GRY}backup${R}       $( [ -n "${ARSIP:-}" ] && basename "$ARSIP" || echo '-' )"
_blc "durasi       $(elapsed)" "  ${GRY}durasi${R}       $(elapsed)"
_blc "" ""; _foot "$GRN"
printf "\n  ${GRY}Langkah berikutnya:${R}\n"
printf "    ${GRY}1.${R} openclaw status   ${GRY}# gateway, channel, runtime${R}\n"
printf "    ${GRY}2.${R} openclaw doctor   ${GRY}# pastikan bersih${R}\n"
printf "    ${GRY}3.${R} rollback bila perlu: ${B}npm i -g openclaw@$CUR_VER && systemctl restart $SERVICE_NAME${R}\n\n"
exit 0
