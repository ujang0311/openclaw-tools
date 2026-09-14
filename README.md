# OpenClaw Tools

Backup & restore (migrasi) instalasi **OpenClaw** antar server/VM — satu script, aman, ada rollback.

```bash
# DI SERVER SUMBER — buat arsip + verifikasi
curl -sS https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-migrate.sh | bash -s -- backup

# DI SERVER TARGET — pasang arsip (channel dimatikan dulu supaya token tidak rebutan)
curl -sS https://raw.githubusercontent.com/ujang0311/openclaw-tools/main/openclaw-migrate.sh | bash -s -- \
  restore --archive /root/openclaw-backups/<arsip>.tar.gz --safe-channels
```

Terverifikasi pada migrasi nyata: **server produksi → VM App Catalog IDCloudHost** (OpenClaw 2026.7.1-2, state 571 MB).

---

## Kenapa perlu script ini

Restore OpenClaw punya beberapa jebakan yang tidak kelihatan kalau hanya `tar` manual:

| Jebakan | Akibat | Ditangani script |
|---|---|---|
| State dir berbeda antar host | `~/.openclaw` (root) vs `/opt/openclaw/.openclaw` (App Catalog, user `openclaw`) | auto-deteksi dari unit systemd/HOME user service |
| Token channel masih dipakai server lama | Bot Telegram/WhatsApp **rebutan** (`Conflict: terminated by other getUpdates`) | `--safe-channels` mematikan channel setelah restore |
| Versi OpenClaw beda | Migrasi database gagal / plugin tidak kompatibel | cek versi arsip vs lokal, butuh `--force-version` |
| Restore langsung menimpa state hidup | Tidak ada jalan pulang | rollback point otomatis (`/var/backups/openclaw/pre-restore-<ts>.tar.gz`) + auto-rollback kalau gateway gagal sehat |
| Ownership salah | Gateway gagal start (permission) | `chown` ke user service + setgid 2775 |

## Aksi `backup`

```bash
openclaw-migrate.sh backup                       # arsip + verifikasi ke /root/openclaw-backups
openclaw-migrate.sh backup --output /data/backups
openclaw-migrate.sh backup --no-workspace        # lebih kecil/cepat
openclaw-migrate.sh backup --transfer root@IP-VM:/root/openclaw-backups   # langsung kirim ke target
```

Yang dijalankan: deteksi state dir & user → `openclaw backup create --verify` (memakai SQLite online-backup API, aman saat gateway hidup) → opsional `scp` ke server target.

## Aksi `restore`

```bash
openclaw-migrate.sh restore --archive <arsip.tar.gz> [opsi]

  --state-dir DIR    lokasi state (default: hasil deteksi)
  --user USER        user pemilik state (default: user unit systemd, atau 'openclaw')
  --safe-channels    matikan telegram/whatsapp/discord/slack setelah restore
  --no-start         jangan nyalakan gateway (uji aman / staging)
  --force-version    lanjut walau versi arsip ≠ versi lokal
  --dry-run          lihat rencana tanpa mengubah apa pun
```

Urutan kerja: verifikasi arsip → cek versi → hentikan gateway → backup state sekarang → ekstrak & pasang state (rsync `--delete`) → `chown` → opsional matikan channel → `openclaw doctor` → start gateway → tunggu port + dashboard HTTP 200. Kalau health check gagal, script mengembalikan state lama otomatis.

## Hasil uji nyata

Sumber: server produksi (`/root/.openclaw`, 687 MB, root) → Target: VM App Catalog IDCloudHost (`/opt/openclaw/.openclaw`, user `openclaw`).

| Tahap | Hasil |
|---|---|
| `backup create --verify` | arsip **196 MB**, 34 detik, 22.875 entri, verifikasi lolos |
| Transfer | `scp` 1,4 detik (antar VM) |
| `backup verify` di target | `Backup archive OK` — runtime version 2026.7.1-2 cocok |
| Restore | state 571 MB, **1 agen**, 6 database, config & model ikut (`9router/dahono/dahono/deepseek-v4-flash`) |
| Gateway setelah restore | service `active`, listening `:18789`, dashboard **HTTP 200** |
| Channel | telegram/whatsapp/discord/slack dimatikan (mode aman) |
| Rollback point | `/var/backups/openclaw/pre-restore-*.tar.gz` (194 MB) |

## Penting sebelum dipakai untuk produksi

1. **Satu token = satu gateway.** Setelah restore, jangan nyalakan channel di dua host dengan token yang sama. Pilih salah satu: matikan yang lama, atau ganti token di host baru (`openclaw config set channels.telegram.botToken ...`).
2. **Versi harus sepadan.** Restore ke versi OpenClaw lama sementara arsip dari versi baru (atau sebaliknya) bisa butuh `openclaw database preflight` sebelum gateway dinyalakan.
3. **Plugin bisa perlu diinstall ulang** — kalau `openclaw status` melaporkan `plugin not installed`:
   `openclaw plugins install @openclaw/discord` (idem slack/codex).
4. **Arsip berisi kredensial** (token bot, API key, OAuth). `chmod 600`, jangan pernah taruh di repo publik.
5. VM App Catalog segar yang crash-loop karena plugin minta API lebih baru → kondisi ini normal; restore arsip yang cocok versinya akan memperbaikinya (terbukti pada uji di atas).

## Prasyarat

- Linux + root (script re-exec lewat `sudo` kalau perlu)
- CLI `openclaw` sudah terpasang (untuk backup: di sumber; untuk restore: di target)
- `rsync` di target (untuk restore), `scp` untuk `--transfer`
- Bash >= 4.2

## Refrensi resmi

- `openclaw backup` CLI: https://docs.openclaw.ai/cli/backup
- Panduan backup & restore: https://docs.openclaw.ai/install/backups
- Migrasi antar mesin: https://docs.openclaw.ai/install/migrating
