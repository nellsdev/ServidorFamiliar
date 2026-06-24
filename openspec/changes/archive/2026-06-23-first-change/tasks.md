# Tasks — First Change: Provision Debian 12 + Nextcloud + BorgBackup

## Dependencies Graph

```
T1 (scaffold)
├── T2 (install-nextcloud.sh) — depends on T1
├── T3 (setup-backup.sh) — depends on T1
├── T4 (setup-wol.sh) — depends on T1
├── T5 (recovery.md) — depends on T3
├── T6 (README.md) — depends on T2, T3, T4
└── T7 (verify.md) — depends on T2, T3, T4
```

T2, T3, T4, T5 run in parallel after T1. T6 and T7 depend on all three scripts being written.

---

### T1 — Create scripts directory and structure ✅

- **Description**: Create the `scripts/` directory and the scaffolding for all provisioning scripts: empty files with `set -euo pipefail` headers, idempotency guards, and a shared `lib.sh` with helper functions.
- **Dependencies**: none
- **Files to create/modify**:
  - `scripts/lib.sh`
  - `scripts/install-nextcloud.sh`
  - `scripts/setup-backup.sh`
  - `scripts/setup-wol.sh`
- **Est. changed lines**: 45 (lib.sh ~30, 3 script scaffolds ~5 each)
- **Est. complexity**: S
- **Acceptance**: `scripts/` exists with 4 files, each bash script has `set -euo pipefail` and shebang, `lib.sh` exports `log()`, `error()`, `check_root()`, `confirm()`. Each script starts with an idempotency guard comment placeholder.

---

### T2 — Write install-nextcloud.sh ✅

- **Description**: Full implementation of the Nextcloud install script per the design (§6). Covers system packages, MariaDB secure + database creation, Nextcloud tarball download + extract, nginx vhost, PHP-FPM pool, MariaDB config, config.php, occ app disable, cron for background jobs.
- **Dependencies**: T1
- **Files to create/modify**:
  - `scripts/install-nextcloud.sh`
- **Est. changed lines**: 380
- **Est. complexity**: L
- **Acceptance**: Script runs idempotently (detects existing install via `/var/www/nextcloud/version.php`). Produces:
  - nginx vhost at `/etc/nginx/sites-available/nextcloud` with `client_max_body_size 2G`, pass to `php8.2-fpm.sock`
  - PHP-FPM pool `nextcloud` with `pm = static`, `pm.max_children = 3`, `memory_limit = 512M`
  - MariaDB config at `/etc/mysql/mariadb.conf.d/99-nextcloud.cnf` with `innodb_buffer_pool_size = 512M`
  - `config.php` with previews disabled, APCu memcache, cron mode, trusted domains
  - Cron file at `/etc/cron.d/nextcloud` running every 5 minutes
  - Unused apps disabled via `occ app:disable`
  - All package installs via `apt` only

---

### T3 — Write setup-backup.sh ✅

- **Description**: Full implementation of the backup setup script per the design (§4, §6). Covers LUKS creation (idempotent), ext4, keyfile, crypttab/fstab, Borg install + repo init, `/usr/local/bin/borg-backup.sh` with full backup loop (luksOpen → mount → mysqldump → borg create → borg prune → umount → luksClose), systemd service + timer.
- **Dependencies**: T1
- **Files to create/modify**:
  - `scripts/setup-backup.sh`
- **Est. changed lines**: 310
- **Est. complexity**: L
- **Acceptance**: Script runs idempotently (skips if LUKS exists on `/dev/sdb1`). Produces:
  - LUKS container on `/dev/sdb1` with keyfile at `/root/luks-keyfile` (mode 0400)
  - `/etc/crypttab` entry for auto-unlock on mount attempt
  - `/etc/fstab` entry with `noauto` for `/mnt/backup`
  - Borg repo initialized with `repokey-blake2` at `/mnt/backup`
  - `/usr/local/bin/borg-backup.sh` with: lock-breaking pre-check, mysqldump → gzip, borg create with excludes (trashbin, cache, tmp, updater), borg prune (7d, 4w, 12m), borg check --verify-data, cleanup
  - `borg-backup.service` (oneshot) and `borg-backup.timer` (daily, Persistent=true)

---

### T4 — Write setup-wol.sh ✅

- **Description**: Full implementation of the WOL and power management setup script per the design (§5, §6). Covers ethtool, systemd link file, rtcwake timer, idle-shutdown script + timer, nftables rules.
- **Dependencies**: T1
- **Files to create/modify**:
  - `scripts/setup-wol.sh`
- **Est. changed lines**: 210
- **Est. complexity**: M
- **Acceptance**: Script runs idempotently (skips if WOL already `g` on eth0). Produces:
  - `/etc/systemd/network/10-wol.link` with `WakeOnLan=magic`
  - `/usr/local/bin/set-wake.sh` with rtcwake call for 02:55
  - systemd timer for set-wake.sh
  - `/usr/local/bin/idle-shutdown.sh` with: 15 min idle via nginx access log mtime, SSH session check, uptime guard, backup-running guard
  - systemd timer for idle-shutdown every 5 minutes
  - nftables ruleset at `/etc/nftables.conf` with: default-drop input policy on `inet filter`, allow loopback, allow established/related, allow SSH + HTTP + ICMP from `192.168.1.0/24`, allow outbound

---

### T5 — Write recovery.md ✅

- **Description**: Document the full restore procedure per the design (§4 Restore procedure). Step-by-step guide for unlocking LUKS, mounting, listing Borg archives, extracting files, restoring MariaDB, and verifying Nextcloud after restore.
- **Dependencies**: T3
- **Files to create/modify**:
  - `openspec/changes/first-change/recovery.md`
- **Est. changed lines**: 90
- **Est. complexity**: S
- **Acceptance**: Document covers: LUKS unlock + mount, `borg list` to view archives, `borg extract` for specific paths and full restore, MariaDB restore from compressed dump, verification steps (Nextcloud login, file integrity), offline recovery note (USB keyfile copy).

---

### T6 — Write README.md ✅

- **Description**: Project-level README describing the family backup server: purpose, hardware requirements, one-line quickstart, how to invoke each script, power management behavior, credits.
- **Dependencies**: T2, T3, T4
- **Files to create/modify**:
  - `README.md`
- **Est. changed lines**: 120
- **Est. complexity**: S
- **Acceptance**: README covers: project purpose, hardware specs (HP Compaq 5800, 2 HDDs, 4GB RAM), network requirements (static IP, LAN), quickstart with `sudo ./scripts/install-nextcloud.sh`, per-script documentation, WOL + shutdown behavior, credits/maintenance notes.

---

### T7 — Write verify.md checklist ✅

- **Description**: Create a manual verification checklist at `scripts/verify.md` for the human operator to run through after provisioning. Covers pre-flight, post-install for each script, client setup, and WhatsApp media verification.
- **Dependencies**: T2, T3, T4
- **Files to create/modify**:
  - `scripts/verify.md`
- **Est. changed lines**: 85
- **Est. complexity**: S
- **Acceptance**: Checklist includes: pre-flight (network, hardware detection, disk layout), after install-nextcloud.sh (curl test, MariaDB status, PHP-FPM status, occ app list, previews disabled), after setup-backup.sh (Borg list, systemd timer active, crypttab/fstab entries), after setup-wol.sh (WOL status, nftables ruleset, idle-shutdown test), client verification (Android auto-upload, WhatsApp media, iOS manual upload), WhatsApp backup restore procedure note.

---

## Review Workload Forecast

| Metric | Value |
|---|---|
| **Total estimated changed lines** | ~1,240 |
| **Lines per task** | T1: 45, T2: 380, T3: 310, T4: 210, T5: 90, T6: 120, T7: 85 |
| **Decision needed before apply** | No — all decisions are documented in the design (LUKS device, IP subnet, MariaDB config values, PHP pool size, retention policy, etc.) |
| **Chained PRs recommended** | Yes |
| **400-line budget risk** | High |
| **Proposed split** | PR1: T1 + T2 (425 lines — slightly over 400 but self-contained as the Nextcloud install is the core feature. Acceptable overshoot since T1 is scaffolding.) |
| | PR2: T3 + T5 (400 lines — backup setup + recovery doc are tightly coupled) |
| | PR3: T4 + T6 + T7 (415 lines — WOL + README + verify checklist are the wrap-up layer) |
