#!/usr/bin/env bash
# ============================================================================
#  ⬢ openclaw-migrate.sh — backup & restore/migrasi OpenClaw antar server
#  Repo: https://github.com/ujang0311/openclaw-tools
#
#  Semua path (state dir, user, cara gateway jalan, port) DETEKSI OTOMATIS.
#  Tidak perlu diarahkan manual — flag hanya untuk override kalau perlu.
#
#  BACKUP  : curl -sS .../openclaw-migrate.sh | bash -s -- backup
#  RESTORE : curl -sS .../openclaw-migrate.sh | bash -s -- restore --archive <arsip.tar.gz>
#  CEK     : bash openclaw-migrate.sh detect
#
#  Opsi: --dry-run  --safe-channels  --no-start  --force-version  --help
#  Bash >= 4.2
# ============================================================================
set -u -o pipefail

VERSION_SCRIPT="1.2.0"
SELF_URL="${OPENCLAW_MIGRATE_URL:-https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-migrate.sh}"
REPO_RAW="${OPENCLAW_TOOLS_RAW:-https://raw.githubusercontent.com/ujang0311/openclaw-tools/main}"
SERVICE_NAME="${OPENCLAW_SERVICE:-openclaw}"
DEFAULT_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
BACKUP_DIR_DEFAULT="${OPENCLAW_BACKUP_DIR:-/root/openclaw-backups}"

ACTION="${1:-}"; [ $# -gt 0 ] && shift || true
DRY_RUN=0; NO_WS=0; STATE_DIR=""; OC_USER=""; TRANSFER=""; ARCHIVE=""; SAFE_CH=0; NO_START=0; FORCE_VERSION=0

# ══════════════════════════════ UI ══════════════════════════════════════════
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[38;5;47m'; YLW=$'\033[38;5;221m'; RED=$'\033[38;5;203m'
  CYN=$'\033[38;5;45m'; PRP=$'\033[38;5;141m'; GRY=$'\033[38;5;245m'; BLD=$'\033[38;5;81m'
else
  B=""; DIM=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; PRP=""; GRY=""; BLD=""
fi
UIW=68
_slen() { printf '%s' "$1" | wc -m | tr -d ' '; }
_top() { printf "  ${PRP}${B}╭%s╮${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_bot() { printf "  ${PRP}${B}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_botc() { printf "  ${1}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
_bl() { # $1 = teks biasa (untuk hitung lebar), $2 = teks berwarna
  local plain="$1" colored="${2:-$1}" len pad
  colored="${colored#"${colored%%[![:space:]]*}"}"
  len=$(_slen "$plain"); pad=$(( UIW - 6 - len )); [ "$pad" -lt 0 ] && pad=0
  printf "  ${PRP}${B}│${R}  %s%*s${PRP}${B}│${R}\n" "$colored" "$pad" ""
}
_blc() { # sama, tapi warna border custom ($3)
  local plain="${1:-}" colored="${2:-}" c="${3:-$PRP}" len pad
  colored="${colored#"${colored%%[![:space:]]*}"}"
  len=$(_slen "$plain"); pad=$(( UIW - 6 - len )); [ "$pad" -lt 0 ] && pad=0
  printf "  ${c}│${R}  %s%*s${c}│${R}\n" "$colored" "$pad" ""
}
_fit() { # $1=teks $2=maks karakter → potong dari kiri dengan …
  local t="$1" max="$2"
  if [ "$(_slen "$t")" -gt "$max" ]; then printf '…%s' "$(printf '%s' "$t" | rev | cut -c1-$((max-1)) | rev)"; else printf '%s' "$t"; fi
}
_clr() { printf "\r%*s\r" "$UIW" ""; }
_banner() {
  printf "\n"; _top
  _bl "⬢  OpenClaw Migrate  v$VERSION_SCRIPT" "  ${PRP}⬢${R}  ${B}OpenClaw Migrate${R}  ${GRY}v$VERSION_SCRIPT${R}"
  _bl "backup · restore · migrasi antar server (auto-detect)" "  ${GRY}backup · restore · migrasi antar server (auto-detect)${R}"
  _bot; printf "\n"
}
_header() { # $1=judul $2=warna
  printf "\n"; printf "  ${2}╭─ ${B}%s${R}${2} %s╮${R}\n" "$1" "$(printf '─%.0s' $(seq 1 $((UIW-8-$(_slen "$1")))))"
}
_foot() { printf "  ${1}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"; }
sec()  { printf "  ${CYN}◆${R} ${B}%s${R}${2:+  ${GRY}%s${R}}\n" "$1" "${2:-}"; }
row()  { printf "    ${GRY}%-13s${R} %s\n" "$1" "$2"; }
tree() { printf "    ${GRY}%s${R} %s\n" "$1" "$2"; }
ok()   { printf "    ${GRN}✔${R} %s\n" "$1"; }
warn() { printf "    ${YLW}▲${R} ${YLW}%s${R}\n" "$1"; }
bad()  { printf "    ${RED}✖${R} ${RED}%s${R}\n" "$1"; }
info() { printf "    ${GRY}·${R} ${GRY}%s${R}\n" "$1"; }
hint() { printf "      ${GRY}└─ %s${R}\n" "$1"; }
kv()   { printf "    ${GRY}%-13s${R} %s\n" "$1" "$2"; }
die()  { printf "\n  ${RED}${B}╭─ GAGAL ──────────────────────────────────────────────────────────────╮${R}\n"
         printf "  ${RED}${B}│${R}  ${RED}✖ %s${R}\n" "$1"
         printf "  ${RED}${B}╰──────────────────────────────────────────────────────────────────────╯${R}\n\n"; exit 1; }
panel() { # $1=judul $2=warna ; isi dari stdin
  local t="$1" c="$2"
  printf "\n  ${c}╭─ ${B}%s${R}${c} %s╮${R}\n" "$t" "$(printf '─%.0s' $(seq 1 $((UIW-6-${#t}))))"
  while IFS= read -r l; do printf "  ${c}│${R}  %s\n" "$l"; done
  printf "  ${c}╰%s╯${R}\n" "$(printf '─%.0s' $(seq 1 $((UIW-2))))"
}
hb() { # $1=label, sisa=perintah  → spinner + durasi
  local label="$1"; shift
  local spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 t=0 rc=0
  "$@" >/tmp/ocmigrate-cmd.log 2>&1 & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r    ${PRP}%s${R} ${GRY}%s…${R} ${BLD}%ss${R}   " "${spin[$((i%10))]}" "$label" "$t"
    sleep 1; i=$((i+1)); t=$((t+1))
  done
  wait "$pid" || rc=$?
  _clr
  HB_ELAPSED=$t
  return $rc
}
hsize(){ du -sh "$1" 2>/dev/null | cut -f1; }
svc_state() { local s; s=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null); [ -n "$s" ] && printf '%s' "$s" || printf 'n/a'; }
elapsed() { printf '%ss' "$SECONDS"; }

usage() {
  _banner
  cat <<EOF
  ${B}Deteksi otomatis${R} (tanpa flag): state dir, user pemilik, cara gateway
  jalan, port, dan lokasi data — dibaca dari unit systemd, proses yang jalan,
  file config, lalu pemindaian filesystem.

  ${B}BACKUP${R}  (di server sumber)
    openclaw-migrate.sh backup [--output DIR] [--no-workspace] [--transfer user@host:/dir]

  ${B}RESTORE${R} (di server target)
    openclaw-migrate.sh restore --archive FILE [opsi]
      --safe-channels   matikan telegram/whatsapp/discord/slack setelah restore
      --no-start        jangan nyalakan gateway (uji aman)
      --force-version   lanjut walau versi arsip ≠ versi lokal
      --state-dir DIR   override deteksi lokasi state
      --user USER       override user pemilik state

  ${B}DETEKSI${R}
    openclaw-migrate.sh detect        tampilkan hasil deteksi otomatis saja

  Umum: --dry-run · --help
EOF
  printf "\n"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output) shift; BACKUP_DIR_DEFAULT="${1:-}" ;;
    --output=*) BACKUP_DIR_DEFAULT="${1#*=}" ;;
    --no-workspace|--no-include-workspace) NO_WS=1 ;;
    --transfer) shift; TRANSFER="${1:-}" ;;
    --transfer=*) TRANSFER="${1#*=}" ;;
    --archive) shift; ARCHIVE="${1:-}" ;;
    --archive=*) ARCHIVE="${1#*=}" ;;
    --state-dir) shift; STATE_DIR="${1:-}" ;;
    --state-dir=*) STATE_DIR="${1#*=}" ;;
    --user) shift; OC_USER="${1:-}" ;;
    --user=*) OC_USER="${1#*=}" ;;
    --safe-channels) SAFE_CH=1 ;;
    --no-start) NO_START=1 ;;
    --force-version) FORCE_VERSION=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opsi tidak dikenal: $1 (pakai --help)" ;;
  esac
  shift
done

case "$ACTION" in backup|restore|detect) ;; ""|-h|--help) usage; exit 0 ;;
  *) die "Aksi tidak dikenal: '$ACTION' (pakai: backup | restore | detect)";; esac

if [ "$ACTION" != detect ] && [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "Butuh root (atau sudo)."
  exec sudo -E bash -c "curl -sS '$SELF_URL' | bash -s -- $ACTION $(printf '%q ' "$@")"
fi
command -v openclaw >/dev/null 2>&1 || die "CLI openclaw tidak ditemukan (install: npm i -g openclaw)"

T0=$SECONDS

# ══════════════════ DETEKSI OTOMATIS (tanpa arahan manual) ══════════════════
detect() {
  OC_BIN=$(command -v openclaw); OC_REAL=$(readlink -f "$OC_BIN")
  CUR_VER=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
  NODE_VER=$(node -v 2>/dev/null | sed 's/^v//'); NPM_VER=$(npm -v 2>/dev/null)
  MODE=""; UNIT_SCOPE=""; UNIT_ENV=""; GW_PID=""

  # ── cara gateway berjalan + pid
  if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    MODE="systemd (system)"; UNIT_SCOPE="--system"
    UNIT_ENV=$(systemctl show "$SERVICE_NAME" -p Environment --value 2>/dev/null || echo "")
    GW_PID=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || echo "")
  elif systemctl --user cat "$SERVICE_NAME" >/dev/null 2>&1; then
    MODE="systemd (user)"; UNIT_SCOPE="--user"
    UNIT_ENV=$(systemctl --user show "$SERVICE_NAME" -p Environment --value 2>/dev/null || echo "")
    GW_PID=$(systemctl --user show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || echo "")
  elif screen -ls 2>/dev/null | grep -q "$SERVICE_NAME"; then MODE="screen session"
  elif pgrep -f 'openclaw.*gateway' >/dev/null 2>&1; then MODE="proses manual"
  else MODE="tidak terdeteksi"; fi
  [ -n "${GW_PID:-}" ] && [ "${GW_PID:-0}" = 0 ] && GW_PID=""
  [ -z "${GW_PID:-}" ] && GW_PID=$(pgrep -f 'openclaw.*gateway' 2>/dev/null | head -1 || true)

  # ── user pemilik: unit → owner state dir → user `openclaw` → root
  if [ -n "$UNIT_SCOPE" ]; then
    OC_USER=$(systemctl $UNIT_SCOPE show "$SERVICE_NAME" -p User --value 2>/dev/null || true)
  fi
  SRC_USER="unit systemd"
  if [ -z "${OC_USER:-}" ]; then
    for c in /opt/openclaw/.openclaw /var/lib/openclaw/.openclaw; do
      [ -d "$c" ] && { OC_USER=$(stat -c %U "$c"); SRC_USER="owner $c"; break; }
    done
  fi
  if [ -z "${OC_USER:-}" ]; then
    if id openclaw >/dev/null 2>&1; then OC_USER=openclaw; SRC_USER="user 'openclaw' ada"
    else OC_USER=root; SRC_USER="default"; fi
  fi
  OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER")
  OC_HOME=$(getent passwd "$OC_USER" | cut -d: -f6); [ -n "$OC_HOME" ] && [ "$OC_HOME" != "/" ] || OC_HOME=/opt/openclaw

  # ── HOME/port dari unit
  UNIT_HOME=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -1)
  [ -n "${UNIT_HOME:-}" ] && OC_HOME="$UNIT_HOME"
  PORT=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^OPENCLAW_GATEWAY_PORT=//p' | head -1)
  [ -n "${PORT:-}" ] || PORT=$(sed -n 's/^OPENCLAW_GATEWAY_PORT=\([0-9]*\).*/\1/p' "$OC_HOME/.env" 2>/dev/null | head -1)
  [ -n "${PORT:-}" ] || PORT="$DEFAULT_PORT"

  # ── state dir: override → env → unit → env proses → CLI → pemindaian
  SRC_STATE=""
  if [ -n "$STATE_DIR" ]; then SRC_STATE="override (--state-dir)"
  elif [ -n "${OPENCLAW_STATE_DIR:-}" ]; then STATE_DIR="$OPENCLAW_STATE_DIR"; SRC_STATE="env OPENCLAW_STATE_DIR"
  else
    v=$(printf '%s\n' "${UNIT_ENV:-}" | tr ' ' '\n' | sed -n 's/^OPENCLAW_STATE_DIR=//p' | head -1)
    if [ -n "${v:-}" ]; then STATE_DIR="$v"; SRC_STATE="unit systemd"
    elif [ -n "${GW_PID:-}" ] && [ -r "/proc/$GW_PID/environ" ]; then
      v=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null | sed -n 's/^OPENCLAW_STATE_DIR=//p' | head -1)
      if [ -n "${v:-}" ]; then STATE_DIR="$v"; SRC_STATE="proses gateway (pid $GW_PID)"
      else
        v=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)
        [ -n "${v:-}" ] && [ -f "$v/.openclaw/openclaw.json" ] && { STATE_DIR="$v/.openclaw"; SRC_STATE="HOME proses gateway (pid $GW_PID)"; }
      fi
    fi
  fi
  if [ -z "${STATE_DIR:-}" ]; then
    v=$(openclaw config file 2>/dev/null | grep -oE '/[^ "]*/\.openclaw/openclaw\.json' | head -1)
    if [ -n "${v:-}" ]; then STATE_DIR="$(dirname "$v")"; SRC_STATE="CLI config file"
    else
      for c in "$OC_HOME/.openclaw" /opt/openclaw/.openclaw /root/.openclaw /var/lib/openclaw/.openclaw /home/*/.openclaw; do
        [ -f "$c/openclaw.json" ] && { STATE_DIR="$c"; SRC_STATE="pemindaian filesystem"; break; }
      done
    fi
  fi
  [ -n "${STATE_DIR:-}" ] || STATE_DIR="$OC_HOME/.openclaw"
  [ -n "$SRC_STATE" ] || SRC_STATE="default ($OC_HOME/.openclaw)"
  # owner otomatis ikut lokasi state (kalau user belum dipastikan dari unit)
  if [ -d "$STATE_DIR" ] && [ -z "$UNIT_SCOPE" ]; then
    o=$(stat -c %U "$STATE_DIR" 2>/dev/null || echo "$OC_USER"); OC_USER="$o"; OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER"); SRC_USER="owner $STATE_DIR"
  fi
  STATE_DB=$(ls "$STATE_DIR"/state/*.sqlite 2>/dev/null | head -1)
}

show_detect() {
  sec "Deteksi otomatis" "$(elapsed)"
  tree "├" "state dir    ${B}${STATE_DIR}${R}$( [ -d "$STATE_DIR" ] && echo "  ${GRY}($(hsize "$STATE_DIR"))${R}" || echo "  ${YLW}(belum ada)${R}" )"
  tree "│" "${GRY}└ sumber      $SRC_STATE${R}"
  tree "├" "owner        ${OC_USER}:${OC_GROUP}  ${GRY}(${SRC_USER})${R}"
  tree "├" "openclaw     ${CUR_VER}  ${GRY}${OC_BIN}${R}"
  tree "├" "node / npm   v${NODE_VER} / ${NPM_VER}"
  tree "└" "gateway      ${MODE}${PORT:+ · port $PORT} · ${GRN}$(svc_state)${R}$( [ -n "${GW_PID:-}" ] && echo " ${GRY}(pid $GW_PID)${R}" )"
}

detect
_banner
[ "$ACTION" = detect ] && { show_detect; printf "\n  ${GRY}Tidak ada perubahan (mode deteksi).${R}\n\n"; exit 0; }
show_detect

# ══════════════════════════════ BACKUP ═════════════════════════════════════
if [ "$ACTION" = backup ]; then
  [ -d "$STATE_DIR" ] || die "State dir tidak ditemukan: $STATE_DIR (pakai --state-dir untuk menunjuk manual)"
  printf "\n"
  sec "[1/3] Membuat arsip" "$(elapsed)"
  kv "output" "$BACKUP_DIR_DEFAULT"
  mkdir -p "$BACKUP_DIR_DEFAULT"; chmod 700 "$BACKUP_DIR_DEFAULT" 2>/dev/null || true
  chown "$OC_USER:$OC_GROUP" "$BACKUP_DIR_DEFAULT" 2>/dev/null || true
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: openclaw backup create --output $BACKUP_DIR_DEFAULT --verify$( [ "$NO_WS" -eq 1 ] && echo ' --no-include-workspace' )"
  else
    ARGS="openclaw backup create --output '$BACKUP_DIR_DEFAULT' --verify$( [ "$NO_WS" -eq 1 ] && echo ' --no-include-workspace' )"
    if [ "$OC_USER" = root ]; then hb "membuat arsip + verifikasi" bash -c "$ARGS"
    else hb "membuat arsip + verifikasi" sudo -u "$OC_USER" -H env HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "$ARGS"; fi
    RC=$?
    NEW=$(ls -t "$BACKUP_DIR_DEFAULT"/*openclaw-backup.tar.gz 2>/dev/null | head -1)
    if [ "$RC" -eq 0 ] && [ -n "${NEW:-}" ]; then
      ok "arsip jadi ${GRN}${B}$(basename "$NEW")${R}  ${GRY}($(hsize "$NEW") · ${HB_ELAPSED}s)${R}"
      grep -iE "verification|volatile" /tmp/ocmigrate-cmd.log | sed 's/^/      /' | head -3
    elif grep -qi "schema migration" /tmp/ocmigrate-cmd.log; then
      warn "OpenClaw menolak backup: state DB butuh migrasi dulu"
      hint "jalankan (service mati): openclaw doctor --fix — lalu ulangi backup"
      RC=1
    else
      tail -4 /tmp/ocmigrate-cmd.log | sed 's/^/      /'; bad "backup gagal (rc=$RC)"; RC=1
    fi
  fi

  printf "\n"
  sec "[2/3] Transfer" "$(elapsed)"
  if [ -n "$TRANSFER" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then info "dry-run: scp $(basename "${NEW:-arsip}") → $TRANSFER"
    elif [ -n "${NEW:-}" ]; then
      hb "mengirim arsip ke $TRANSFER" scp -o StrictHostKeyChecking=accept-new "$NEW" "$TRANSFER"/ && ok "terkirim (${HB_ELAPSED}s)" || { bad "scp gagal"; RC=1; }
    fi
  else
    info "opsional — kirim manual atau pakai --transfer user@host:/dir"
    hint "scp $BACKUP_DIR_DEFAULT/$(basename "${NEW:-<arsip>}") user@host:/path"
  fi

  printf "\n"
  sec "[3/3] Ringkasan" "$(elapsed)"
  _header "✔ BACKUP SELESAI" "$GRN"
  _blc "" ""
  _blc "arsip        $( [ -n "${NEW:-}" ] && basename "$NEW" || echo 'belum dibuat (dry-run)')" "  ${GRY}arsip${R}        $( [ -n "${NEW:-}" ] && basename "$NEW" || echo "${GRY}belum dibuat (dry-run)${R}")"
  _blc "lokasi       $( [ -n "${NEW:-}" ] && dirname "$NEW" || echo -)" "  ${GRY}lokasi${R}       $( [ -n "${NEW:-}" ] && dirname "$NEW" || echo -)"
  _blc "ukuran       $( [ -n "${NEW:-}" ] && hsize "$NEW" || echo - )" "  ${GRY}ukuran${R}       $( [ -n "${NEW:-}" ] && hsize "$NEW" || echo - )"
  ST_FIT=$(_fit "$STATE_DIR" 40)
  _blc "state        $ST_FIT ($(hsize "$STATE_DIR" 2>/dev/null || echo -))" "  ${GRY}state${R}        $ST_FIT ${GRY}($(hsize "$STATE_DIR" 2>/dev/null || echo -))${R}"
  _blc "durasi       $(elapsed)" "  ${GRY}durasi${R}       $(elapsed)"
  _blc "" ""
  _foot "$GRN"
  printf "\n  ${GRY}Langkah berikutnya:${R}  restore di server target\n"
  printf "    ${GRY}scp $( [ -n "${NEW:-}" ] && basename "$NEW" || echo '<arsip>') user@host:/root/  →  openclaw-migrate.sh restore --archive <arsip>${R}\n\n"
  exit "${RC:-0}"
fi

# ══════════════════════════════ RESTORE ════════════════════════════════════
[ -n "$ARCHIVE" ] || die "Wajib: --archive <file.tar.gz>"
[ -f "$ARCHIVE" ] || die "Arsip tidak ditemukan: $ARCHIVE"
TS=$(date +%Y%m%d-%H%M%S); STAGE="/tmp/openclaw-restore-$TS"
PRE="/var/backups/openclaw/pre-restore-$TS.tar.gz"; mkdir -p "$(dirname "$PRE")"
printf "\n"

sec "[1/7] Verifikasi arsip" "$(elapsed)"
kv "arsip" "$(basename "$ARCHIVE") ($(hsize "$ARCHIVE"))"
if hb "memeriksa arsip" openclaw backup verify "$ARCHIVE"; then
  ARC_VER=$(grep -i "Runtime version" /tmp/ocmigrate-cmd.log | head -1 | awk '{print $3}')
  ENTRIES=$(grep -io "entries scanned: [0-9]*" /tmp/ocmigrate-cmd.log | head -1 | grep -o "[0-9]*")
  ok "arsip valid ${GRY}(${HB_ELAPSED}s · ${ENTRIES:-?} entri · runtime ${ARC_VER:-?})${R}"
else
  tail -4 /tmp/ocmigrate-cmd.log | sed 's/^/      /'; die "arsip TIDAK valid — restore dibatalkan"
fi
LOCAL_VER="$CUR_VER"
kv "versi lokal" "$LOCAL_VER"
if [ -n "${ARC_VER:-}" ] && [ "$ARC_VER" != "$LOCAL_VER" ] && [ "$FORCE_VERSION" -eq 0 ]; then
  _header "⚠ VERSI BERBEDA" "$YLW"
  _blc "arsip ${ARC_VER}  ≠  lokal ${LOCAL_VER}" "  ${YLW}arsip ${ARC_VER}${R}  ≠  ${YLW}lokal ${LOCAL_VER}${R}" "$YLW"
  _foot "$YLW"
  hint "setelah restore: openclaw doctor --fix (service mati), lalu cek openclaw database preflight"
  hint "lanjutkan dengan: --force-version"
  exit 1
fi

printf "\n"
sec "[2/7] Rencana" "$(elapsed)"
kv "state dir" "$STATE_DIR$( [ -d "$STATE_DIR" ] && echo " ($(hsize "$STATE_DIR"))" || echo ' (kosong)')"
kv "user" "$OC_USER:$OC_GROUP"
kv "gateway" "$MODE · port $PORT · $(svc_state)"
if [ "$DRY_RUN" -eq 1 ]; then
  kv "akan" "stop gateway → rollback point → pasang state → chown → remap path → doctor → start"
  [ "$SAFE_CH" -eq 1 ] && kv "tambahan" "matikan telegram/whatsapp/discord/slack"
  printf "\n  ${CYN}${B}◆ DRY-RUN — tidak ada perubahan.${R}\n\n"; exit 0
fi

printf "\n"
sec "[3/7] Hentikan gateway" "$(elapsed)"
case "$MODE" in
  systemd*)  hb "stop service" systemctl stop "$SERVICE_NAME" 2>/dev/null || true; ok "service dihentikan" ;;
  *)         pkill -f 'openclaw.*gateway' 2>/dev/null || true; sleep 2; ok "proses gateway dihentikan" ;;
esac

printf "\n"
sec "[4/7] Rollback point" "$(elapsed)"
if [ -d "$STATE_DIR" ]; then
  if hb "mengamankan state sekarang" tar czf "$PRE" -C "$(dirname "$STATE_DIR")" "$(basename "$STATE_DIR")"; then
    ok "$PRE ${GRY}($(hsize "$PRE") · ${HB_ELAPSED}s)${R}"
  else warn "gagal membuat rollback point (lanjut, tapi hati-hati)"; fi
else info "state dir belum ada — tidak ada yang perlu diamankan"; fi

printf "\n"
sec "[5/7] Pasang state dari arsip" "$(elapsed)"
rm -rf "$STAGE"; mkdir -p "$STAGE"
hb "ekstrak arsip" tar xzf "$ARCHIVE" -C "$STAGE" || die "ekstraksi gagal"
SRC=$(find "$STAGE" -maxdepth 5 -type d -name ".openclaw" | head -1)
[ -n "$SRC" ] || die "state (.openclaw) tidak ditemukan di dalam arsip"
info "sumber di arsip: $(echo "$SRC" | sed "s|$STAGE/||")  ($(hsize "$SRC"))"
mkdir -p "$STATE_DIR"
hb "menyalin state" rsync -aHAX --delete "$SRC"/ "$STATE_DIR"/ || die "sinkronisasi state gagal"
chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR"; chmod 2775 "$(dirname "$STATE_DIR")" "$STATE_DIR" 2>/dev/null || true
ok "state terpasang: $(hsize "$STATE_DIR") · $(ls "$STATE_DIR/agents" 2>/dev/null | wc -l) agen · $(find "$STATE_DIR" -name '*.sqlite' 2>/dev/null | wc -l) database"

# path absolut server lama di dalam DB → dipetakan otomatis (deteksi dari manifest + isi DB)
OLD_STATE=$(python3 -c "
import json,glob
m=glob.glob('$STAGE/*/manifest.json')
print(((json.load(open(m[0])).get('paths') or {}).get('stateDir','')) if m else '')
" 2>/dev/null || echo "")
REMAP=/tmp/remap-state-paths.py
[ -s "$REMAP" ] || curl -fsS -m 30 "$REPO_RAW/remap-state-paths.py" -o "$REMAP" 2>/dev/null || true
if [ -s "$REMAP" ]; then
  ROUT=$(python3 "$REMAP" --state-dir "$STATE_DIR" ${OLD_STATE:+--old "$OLD_STATE"} --quiet 2>&1 | tail -1)
  case "$ROUT" in
    REMAP_OK*) ok "path state dipetakan ulang ${GRY}(old=${OLD_STATE:-auto} → new=$STATE_DIR · rows=${ROUT##*rows=})${R}"; chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" ;;
    *) info "pemetaan path: tidak ada perubahan diperlukan" ;;
  esac
else warn "helper remap tidak tersedia — lewati pemetaan path"; fi

printf "\n"
if [ "$SAFE_CH" -eq 1 ]; then
  sec "[6/7] Matikan channel" "$(elapsed)"
  for ch in telegram whatsapp discord slack; do
    if sudo -u "$OC_USER" -H env HOME="$OC_HOME" OPENCLAW_STATE_DIR="$STATE_DIR" bash -lc "cd $OC_HOME && openclaw config set channels.$ch.enabled false" >/dev/null 2>&1; then
      ok "channels.$ch.enabled=false"; else warn "gagal set channels.$ch"; fi
  done
  hint "nyalakan lagi hanya di SATU host: openclaw config set channels.telegram.enabled true"
else
  sec "[6/7] Channel" "$(elapsed)"
  warn "channel dibiarkan apa adanya"
  hint "kalau token masih dipakai server lain → pakai --safe-channels (cegah bot rebutan)"
fi

printf "\n"
sec "[7/7] Doctor + jalankan gateway" "$(elapsed)"
AS_OC="sudo -u $OC_USER -H env HOME=$OC_HOME OPENCLAW_STATE_DIR=$STATE_DIR bash -lc"
if [ "$OC_USER" = root ]; then AS_OC="env HOME=$OC_HOME OPENCLAW_STATE_DIR=$STATE_DIR bash -lc"; fi
hb "openclaw doctor" bash -c "$AS_OC 'cd $OC_HOME && timeout 240 openclaw doctor 2>&1 | tail -3'" || warn "doctor melaporkan catatan (lihat di atas)"
# arsip dari versi lebih lama → skema DB perlu dimigrasi sebelum gateway boleh start
hb "doctor --fix (migrasi skema DB bila perlu)" bash -c "$AS_OC 'cd $OC_HOME && timeout 300 openclaw doctor --fix 2>&1 | tail -3'" \
  && ok "migrasi/konvergensi selesai ${GRY}(${HB_ELAPSED}s)${R}" \
  || warn "doctor --fix melaporkan catatan — lanjut, health check akan memutuskan"
chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" 2>/dev/null || true
GW_OK=0
if [ "$NO_START" -eq 1 ]; then
  info "--no-start: gateway tidak dinyalakan"
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
fi

if [ "$GW_OK" -eq 0 ] && [ "$NO_START" -eq 0 ]; then
  printf "\n"
  sec "Rollback" "$(elapsed)"
  case "$MODE" in systemd*) systemctl stop "$SERVICE_NAME" 2>/dev/null || true ;; *) pkill -f 'openclaw.*gateway' 2>/dev/null || true ;; esac
  [ -f "$PRE" ] && tar xzf "$PRE" -C "$(dirname "$STATE_DIR")" && chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" && ok "state lama dipulihkan dari $PRE"
  case "$MODE" in systemd*) systemctl start "$SERVICE_NAME" 2>/dev/null || true ;; esac
  die "restore di-rollback: gateway tidak sehat setelah restore"
fi

_header "✔ RESTORE SELESAI" "$GRN"
_blc "" ""
_blc "versi        $LOCAL_VER" "  ${GRY}versi${R}        $LOCAL_VER"
_blc "state        $(_fit "$STATE_DIR" 40) ($(hsize "$STATE_DIR"))" "  ${GRY}state${R}        $(_fit "$STATE_DIR" 40) ${GRY}($(hsize "$STATE_DIR"))${R}"
_blc "agen / db    $(ls "$STATE_DIR/agents" 2>/dev/null | wc -l) agen · $(find "$STATE_DIR" -name '*.sqlite' 2>/dev/null | wc -l) database" "  ${GRY}agen / db${R}    $(ls "$STATE_DIR/agents" 2>/dev/null | wc -l) agen · $(find "$STATE_DIR" -name '*.sqlite' 2>/dev/null | wc -l) database"
_blc "gateway      $MODE · port $PORT · $(svc_state)" "  ${GRY}gateway${R}      $MODE · port $PORT · $(svc_state)"
CHSUM=$(python3 -c "
import json;d=json.load(open('$STATE_DIR/openclaw.json'));ch=d.get('channels') or {}
print(', '.join(f\"{k}={'ON' if (v or {}).get('enabled') else 'off'}\" for k,v in ch.items()) or '-')" 2>/dev/null || echo '-')
_blc "channel      $CHSUM" "  ${GRY}channel${R}      $CHSUM"
_blc "rollback     $(_fit "$PRE" 46)" "  ${GRY}rollback${R}     $(_fit "$PRE" 46)"
_blc "durasi       $(elapsed)" "  ${GRY}durasi${R}       $(elapsed)"
_blc "" ""
_foot "$GRN"
printf "\n  ${GRY}Langkah berikutnya:${R}\n"
printf "    ${GRY}1.${R} openclaw status        ${GRY}# cek gateway & channel${R}\n"
printf "    ${GRY}2.${R} openclaw doctor        ${GRY}# pastikan tidak ada catatan${R}\n"
printf "    ${GRY}3.${R} buka dashboard :$PORT  ${GRY}# atau domain lewat nginx${R}\n"
[ "$SAFE_CH" -eq 1 ] && printf "    ${YLW}4.${R} ${YLW}channel dimatikan — nyalakan hanya di SATU host${R}\n"
printf "\n"
exit 0
