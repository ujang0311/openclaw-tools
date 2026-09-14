#!/usr/bin/env bash
# ============================================================================
#  openclaw-migrate.sh — backup & restore OpenClaw (migrasi antar server/VM)
#  Repo: https://github.com/ujang0311/openclaw-tools
#
#  BACKUP (dijalankan di server SUMBER):
#    curl -sS https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-migrate.sh | bash -s -- backup
#    ./openclaw-migrate.sh backup --output /root/openclaw-backups --verify
#    ./openclaw-migrate.sh backup --transfer root@IP-VM-TUJUAN:/root/openclaw-backups
#
#  RESTORE (dijalankan di server TARGET):
#    ./openclaw-migrate.sh restore --archive /root/openclaw-backups/<arsip>.tar.gz
#    ./openclaw-migrate.sh restore --archive <arsip> --safe-channels   # matikan channel dulu (token masih sama dengan server sumber)
#    ./openclaw-migrate.sh restore --archive <arsip> --no-start --dry-run
#
#  Opsi umum: --dry-run  --help
#  Bash >= 4.2
# ============================================================================
set -u -o pipefail

VERSION_SCRIPT="1.0.0"
SELF_URL="${OPENCLAW_MIGRATE_URL:-https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-migrate.sh}"
SERVICE_NAME="${OPENCLAW_SERVICE:-openclaw}"
DEFAULT_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
BACKUP_DIR_DEFAULT="${OPENCLAW_BACKUP_DIR:-/root/openclaw-backups}"

ACTION="${1:-}"; [ $# -gt 0 ] && shift || true
DRY_RUN=0; NO_WS=0; STATE_DIR=""; OC_USER=""; TRANSFER=""; ARCHIVE=""; SAFE_CH=0; NO_START=0
FORCE_VERSION=0; PORT="${OPENCLAW_GATEWAY_PORT:-}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; R=$'\033[0m'; GRN=$'\033[38;5;42m'; YLW=$'\033[38;5;220m'
  RED=$'\033[38;5;203m'; CYN=$'\033[38;5;45m'; PRP=$'\033[38;5;141m'; GRY=$'\033[38;5;245m'
else
  B=""; R=""; GRN=""; YLW=""; RED=""; CYN=""; PRP=""; GRY=""
fi
W=64
boxline() { local t="$1" p; p=$(( W - 6 - ${#t} )); [ "$p" -lt 1 ] && p=1
  printf "${HDR:-$PRP}${B}  │${R}  ${B}%s${R}%*s${HDR:-$PRP}${B}│${R}\n" "$t" "$p" ""; }
title() { printf "\n${PRP}${B}  ╭%s╮${R}\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"; HDR="$PRP" boxline "$1"
          printf "${PRP}${B}  ╰%s╯${R}\n\n" "$(printf '─%.0s' $(seq 1 $((W-4))))"; }
step() { printf "  ${CYN}▸${R} ${B}%s${R}\n" "$1"; }
ok()   { printf "    ${GRN}✓${R} %s\n" "$1"; }
warn() { printf "    ${YLW}!${R} %s\n" "$1"; }
bad()  { printf "    ${RED}✗${R} %s\n" "$1"; }
info() { printf "    ${GRY}·${R} %s\n" "$1"; }
kv()   { printf "    ${GRY}%-11s${R} %s\n" "$1" "$2"; }
die()  { printf "\n  ${RED}${B}✗ %s${R}\n\n" "$1" >&2; exit 1; }
ts()   { date +%Y%m%d-%H%M%S; }
hsize(){ du -sh "$1" 2>/dev/null | cut -f1; }

usage() {
  title "openclaw-migrate.sh v$VERSION_SCRIPT"
  cat <<EOF
  Backup & restore OpenClaw — untuk migrasi server→VM baru.

  BACKUP (di server sumber):
    openclaw-migrate.sh backup [--output DIR] [--no-workspace] [--transfer user@host:/dir]

  RESTORE (di server target):
    openclaw-migrate.sh restore --archive FILE [opsi]
      --state-dir DIR     lokasi state (default: ~/.openclaw user service / /opt/openclaw/.openclaw)
      --user USER         user pemilik state (default: user unit systemd, atau 'openclaw')
      --safe-channels     matikan telegram/whatsapp/discord/slack setelah restore
                          (WAJIB kalau token masih dipakai server lain — cegah rebutan bot)
      --no-start          jangan nyalakan service setelah restore (uji aman)
      --force-version     lanjut walau versi OpenClaw di arsip beda dengan lokal

  Umum: --dry-run  --help
  Env : OPENCLAW_STATE_DIR, OPENCLAW_SERVICE, OPENCLAW_GATEWAY_PORT, OPENCLAW_BACKUP_DIR
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

case "$ACTION" in backup|restore) ;; ""|-h|--help) usage; exit 0 ;;
  *) die "Aksi tidak dikenal: $ACTION (pakai: backup | restore)";; esac

if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "Butuh root (atau sudo)."
  exec sudo -E bash -c "curl -sS '$SELF_URL' | bash -s -- $ACTION $(printf '%q ' "$@")"
fi
command -v openclaw >/dev/null 2>&1 || die "CLI openclaw tidak ditemukan. Install dulu: npm i -g openclaw"

# ── Deteksi lingkungan ──────────────────────────────────────────────────────
detect() {
  # user service
  if [ -z "$OC_USER" ]; then
    OC_USER=$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)
    [ -n "$OC_USER" ] || { id openclaw >/dev/null 2>&1 && OC_USER=openclaw || OC_USER=root; }
  fi
  OC_GROUP=$(id -gn "$OC_USER" 2>/dev/null || echo "$OC_USER")
  OC_HOME=$(getent passwd "$OC_USER" | cut -d: -f6); [ -n "$OC_HOME" ] && [ "$OC_HOME" != "/" ] || OC_HOME="/opt/openclaw"
  # port
  if [ -z "$PORT" ]; then
    PORT=$(systemctl show "$SERVICE_NAME" -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^OPENCLAW_GATEWAY_PORT=//p' | head -1)
    [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
  fi
  # state dir
  if [ -z "$STATE_DIR" ]; then
    if [ -n "${OPENCLAW_STATE_DIR:-}" ]; then STATE_DIR="$OPENCLAW_STATE_DIR"
    elif [ -f "$OC_HOME/.openclaw/openclaw.json" ]; then STATE_DIR="$OC_HOME/.openclaw"
    elif [ -f "${HOME}/.openclaw/openclaw.json" ]; then STATE_DIR="${HOME}/.openclaw"
    else STATE_DIR="$OC_HOME/.openclaw"; fi
  fi
  # cara menjalankan gateway
  if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then RUNMODE="systemd"
  elif screen -ls 2>/dev/null | grep -q "\.$SERVICE_NAME"; then RUNMODE="screen"
  elif pgrep -f 'openclaw gateway' >/dev/null 2>&1; then RUNMODE="process"
  else RUNMODE="manual"; fi
}
detect

svc_state() { local s; s=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null); [ -n "$s" ] && printf '%s' "$s" || printf 'n/a'; }

gw_stop() {
  case "$RUNMODE" in
    systemd) systemctl stop "$SERVICE_NAME" 2>/dev/null || true; sleep 2 ;;
    screen)  pkill -f 'openclaw/dist/index.js gateway' 2>/dev/null || true
             pkill -f 'openclaw gateway' 2>/dev/null || true; sleep 2 ;;
    *)       pkill -f 'openclaw gateway' 2>/dev/null || true; sleep 2 ;;
  esac
}
gw_start() {
  case "$RUNMODE" in
    systemd) systemctl start "$SERVICE_NAME" ;;
    screen)  screen -dmS "$SERVICE_NAME" bash -c "openclaw gateway --port $PORT 2>&1 | tee -a /var/log/openclaw-gateway.log" ;;
    *)       info "mode manual — jalankan sendiri: openclaw gateway --port $PORT" ;;
  esac
}
gw_wait() { # tunggu port siap, max ~30s
  local i; for i in $(seq 1 15); do
    ss -tlnH 2>/dev/null | grep -q ":$PORT " && return 0
    sleep 2
  done
  return 1
}
as_user() { if [ "$OC_USER" = root ]; then bash -lc "$1"; else sudo -u "$OC_USER" -H bash -lc "cd $OC_HOME && $1"; fi; }
slim() { python3 -c "
import json,sys
d=json.load(open('$STATE_DIR/openclaw.json'))
ch=d.get('channels') or {}
print('   channel   : ' + ', '.join(f\"{k}={'on' if (v or {}).get('enabled') else 'off'}\" for k,v in ch.items()))
print('   model     : ' + str(((d.get('agents') or {}).get('defaults') or {}).get('model',{}).get('primary','-')))
" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
#  BACKUP
# ════════════════════════════════════════════════════════════════════════════
if [ "$ACTION" = backup ]; then
  title "OpenClaw backup v$VERSION_SCRIPT"
  step "[1/3] Deteksi instalasi"
  kv "state dir" "$STATE_DIR ($( [ -d "$STATE_DIR" ] && hsize "$STATE_DIR" || echo 'tidak ada'))"
  kv "owner" "$OC_USER:$OC_GROUP"
  kv "versi" "$(openclaw --version 2>&1 | head -1 | awk '{print $2}')"
  kv "output" "$BACKUP_DIR_DEFAULT"
  [ -d "$STATE_DIR" ] || die "State dir tidak ditemukan: $STATE_DIR"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: tidak menulis arsip"
  else
    step "[2/3] Buat arsip + verifikasi"
    mkdir -p "$BACKUP_DIR_DEFAULT"; chmod 700 "$BACKUP_DIR_DEFAULT" 2>/dev/null || true
    ARGS=(backup create --output "$BACKUP_DIR_DEFAULT" --verify)
    [ "$NO_WS" -eq 1 ] && ARGS+=(--no-include-workspace)
    LOG=/tmp/ocmigrate-backup.log
    if [ "$OC_USER" = root ]; then openclaw "${ARGS[@]}" >"$LOG" 2>&1; RC=$?
    else sudo -u "$OC_USER" -H openclaw "${ARGS[@]}" >"$LOG" 2>&1; RC=$?; fi
    if [ "$RC" -ne 0 ]; then tail -6 "$LOG" | sed 's/^/      /'; die "backup gagal (rc=$RC)"; fi
    NEW=$(ls -t "$BACKUP_DIR_DEFAULT"/*openclaw-backup.tar.gz 2>/dev/null | head -1)
    ok "arsip: $(basename "${NEW:-?}") ($(hsize "${NEW:-}"))"
    grep -i "verification" "$LOG" | tail -1 | sed 's/^/      /'
  fi

  if [ -n "$TRANSFER" ]; then
    step "[3/3] Kirim arsip ke $TRANSFER"
    [ "$DRY_RUN" -eq 1 ] && info "dry-run: scp $(basename "${NEW:-arsip}") → $TRANSFER"
    if [ "$DRY_RUN" -eq 0 ]; then
      scp -o StrictHostKeyChecking=accept-new "$NEW" "$TRANSFER"/ && ok "terkirim"
    fi
  else
    step "[3/3] Transfer (opsional)"
    info "untuk mengirim ke server lain: scp $BACKUP_DIR_DEFAULT/$(basename "${NEW:-<arsip>}") user@host:/path"
  fi

  printf "\n  ${GRN}${B}✓ Backup selesai${R}\n"
  kv "arsip" "${NEW:-$BACKUP_DIR_DEFAULT}"
  [ -d "$STATE_DIR" ] && slim
  printf "\n  ${GRY}  Restore di server target: openclaw-migrate.sh restore --archive <arsip>${R}\n\n"
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
#  RESTORE
# ════════════════════════════════════════════════════════════════════════════
[ -n "$ARCHIVE" ] || die "Wajib: --archive <file.tar.gz>"
[ -f "$ARCHIVE" ] || die "Arsip tidak ditemukan: $ARCHIVE"
TS=$(ts); STAGE="/tmp/openclaw-restore-$TS"; PRE="/var/backups/openclaw/pre-restore-$TS.tar.gz"
mkdir -p "$(dirname "$PRE")"

title "OpenClaw restore v$VERSION_SCRIPT"
step "[1/7] Verifikasi arsip"
if openclaw backup verify "$ARCHIVE" >/tmp/ocmigrate-verify.log 2>&1; then
  ok "arsip valid: $(basename "$ARCHIVE") ($(hsize "$ARCHIVE"))"
  grep -iE "Runtime version|Archive entries" /tmp/ocmigrate-verify.log | sed 's/^/      /'
  ARC_VER=$(grep -i "Runtime version" /tmp/ocmigrate-verify.log | head -1 | awk '{print $3}')
else
  tail -4 /tmp/ocmigrate-verify.log | sed 's/^/      /'; die "arsip TIDAK valid — restore dibatalkan"
fi

LOCAL_VER=$(openclaw --version 2>&1 | head -1 | awk '{print $2}')
kv "versi arsip" "${ARC_VER:-?}"
kv "versi lokal" "$LOCAL_VER"
if [ -n "${ARC_VER:-}" ] && [ "$ARC_VER" != "$LOCAL_VER" ] && [ "$FORCE_VERSION" -eq 0 ]; then
  warn "versi beda — setelah restore jalankan: openclaw database preflight && openclaw doctor"
  warn "lanjut butuh eksplisit: tambahkan --force-version"
  exit 1
fi

step "[2/7] Deteksi target"
kv "state dir" "$STATE_DIR ($( [ -d "$STATE_DIR" ] && hsize "$STATE_DIR" || echo 'kosong'))"
kv "user" "$OC_USER:$OC_GROUP"
kv "gateway" "$RUNMODE (port $PORT)"
kv "service" "$(svc_state)"

if [ "$DRY_RUN" -eq 1 ]; then
  printf "\n  ${CYN}${B}DRY-RUN — tidak ada perubahan.${R}\n"
  kv "akan" "stop gateway → backup state lama → pasang state dari arsip → chown → doctor → start"
  [ "$SAFE_CH" -eq 1 ] && kv "tambahan" "matikan telegram/whatsapp/discord/slack"
  printf "\n"
  exit 0
fi

step "[3/7] Hentikan gateway"
gw_stop; case "$RUNMODE" in systemd) ok "service dihentikan";; *) ok "proses gateway dihentikan";; esac

step "[4/7] Amankan state sekarang"
if [ -d "$STATE_DIR" ]; then
  tar czf "$PRE" -C "$(dirname "$STATE_DIR")" "$(basename "$STATE_DIR")" 2>/dev/null \
    && ok "rollback point: $PRE ($(hsize "$PRE"))" || warn "gagal membuat rollback point"
fi

step "[5/7] Ekstrak & pasang state dari arsip"
rm -rf "$STAGE"; mkdir -p "$STAGE"
tar xzf "$ARCHIVE" -C "$STAGE" || die "ekstraksi gagal"
SRC=$(find "$STAGE" -maxdepth 5 -type d -name ".openclaw" | head -1)
[ -n "$SRC" ] || die "state (.openclaw) tidak ditemukan di dalam arsip"
info "sumber di arsip: $(echo "$SRC" | sed "s|$STAGE/||")  ($(hsize "$SRC"))"
mkdir -p "$STATE_DIR"
rsync -aHAX --delete "$SRC"/ "$STATE_DIR"/ || die "sinkronisasi state gagal"
chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR"
chmod 2775 "$(dirname "$STATE_DIR")" "$STATE_DIR" 2>/dev/null || true
ok "state terpasang: $(hsize "$STATE_DIR"), $(ls "$STATE_DIR/agents" 2>/dev/null | wc -l) agen, $(find "$STATE_DIR" -name '*.sqlite' 2>/dev/null | wc -l) database"

if [ "$SAFE_CH" -eq 1 ]; then
  step "[6/7] Matikan channel (cegah rebutan token dengan server sumber)"
  for ch in telegram whatsapp discord slack; do
    if as_user "openclaw config set channels.$ch.enabled false" >/dev/null 2>&1; then ok "channels.$ch.enabled=false"
    else warn "gagal set channels.$ch"; fi
  done
else
  step "[6/7] Channel dibiarkan apa adanya"
  warn "kalau token channel masih dipakai server lain, gunakan --safe-channels (bot bisa rebutan)"
fi

step "[7/7] Doctor + jalankan gateway"
as_user "timeout 240 openclaw doctor 2>&1 | tail -8" || warn "doctor melaporkan catatan (cek output di atas)"
if [ "$NO_START" -eq 1 ]; then
  info "--no-start: gateway tidak dinyalakan"
  gw_failed=0
else
  gw_start
  if gw_wait; then ok "gateway listening di port $PORT"
  else bad "port $PORT tidak listen setelah 30s — cek: journalctl -u $SERVICE_NAME -n 40"; gw_failed=1; fi
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
  [ "$CODE" = "200" ] && ok "dashboard HTTP 200" || warn "dashboard HTTP $CODE"
fi

if [ "${gw_failed:-0}" -eq 1 ]; then
  bad "restore gagal sehat — mengembalikan state lama"
  gw_stop
  [ -f "$PRE" ] && tar xzf "$PRE" -C "$(dirname "$STATE_DIR")" && chown -R "$OC_USER:$OC_GROUP" "$STATE_DIR" && ok "state lama dipulihkan"
  [ "$NO_START" -eq 0 ] && gw_start
  die "rollback dijalankan. Arsip: $ARCHIVE"
fi

printf "\n  ${GRN}${B}╭────────────────────────────────────────────────────────────╮${R}\n"
  HDR="$GRN" boxline "✓ Restore OpenClaw selesai"
printf "  ${GRN}${B}╰────────────────────────────────────────────────────────────╯${R}\n\n"
kv "versi"    "$LOCAL_VER"
kv "state"    "$STATE_DIR ($(hsize "$STATE_DIR"))"
kv "gateway"  "$RUNMODE, port $PORT"
kv "service"  "$(svc_state)"
slim
kv "rollback" "$PRE"
kv "arsip"    "$ARCHIVE"
printf "\n  ${GRY}  Cek lanjutan: openclaw status · openclaw doctor · akses dashboard :$PORT${R}\n"
[ "$SAFE_CH" -eq 1 ] && printf "  ${YLW}  Channel dimatikan. Nyalakan setelah token/server lama sudah tidak dipakai.${R}\n"
printf "\n"
exit 0
