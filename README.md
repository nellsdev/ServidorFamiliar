# Family Backup Server

Self-hosted family data server running on reused hardware — replaces cloud subscription services with a private, LAN-only Nextcloud instance and encrypted BorgBackup. Designed to be off >20 hours/day for energy savings while still providing reliable file sync, photo backup, contacts, calendar, and daily encrypted backups.

---

## Hardware

| Component | Spec |
|-----------|------|
| Machine | HP Compaq 5800 |
| CPU | Core 2 Duo E7400 (2.8 GHz) |
| RAM | 4 GB DDR3 |
| Disk 1 | 297 GB HDD — system + Nextcloud data |
| Disk 2 | 80 GB HDD — LUKS-encrypted Borg backup repository |

4 GB RAM is tight for Nextcloud + PHP-FPM + MariaDB. Mitigated with aggressive tuning: PHP-FPM runs 3 static children at 512 MB each, MariaDB is configured for minimal memory usage.

---

## Network

- **IP**: Static `192.168.1.100`
- **Hostname**: `family-server.local` (via Avahi/mDNS)
- **Access**: LAN only (`192.168.1.0/24`)
- **Firewall**: nftables default-drop input policy, allow SSH (22), HTTP (80), ICMP from LAN
- **Router**: DHCP reservation strongly recommended for the static IP

---

## Quickstart

After a Debian 12 minimal install (no desktop, standard system utilities only):

```bash
git clone <repo-url> && cd family-backup-server
sudo ./scripts/install-nextcloud.sh
sudo ./scripts/setup-backup.sh
sudo ./scripts/setup-wol.sh
```

Each script is idempotent — safe to re-run if it fails partway through.

---

## Script Reference

All provisioning scripts live in `scripts/` and share a common library.

| Script | Purpose |
|--------|---------|
| `lib.sh` | Shared helpers: `log`, `error`, `check_root`, `confirm` |
| `install-nextcloud.sh` | Full LAMP stack provisioning: nginx, PHP-FPM (3 static children, 512 MB), MariaDB, Nextcloud with Files/Photos/Contacts/Calendar apps, cron, Avahi. Idempotent — skips if `/var/www/nextcloud/version.php` exists. |
| `setup-backup.sh` | LUKS-encrypts `/dev/sdb1`, writes keyfile + crypttab/fstab, installs BorgBackup, initializes repo (repokey-blake2), writes `borg-backup.sh` to `/usr/local/bin/` with systemd timer for daily 03:00 backups. Retention: 7 daily + 4 weekly + 12 monthly. Idempotent — skips if LUKS is already configured on `/dev/sdb1`. |
| `setup-wol.sh` | Writes systemd link file + ethtool oneshot service + udev rule for WOL, rtcwake script for 02:55 RTC wake, idle-shutdown watchdog (15 min idle via nginx access log mtime, SSH/uptime/Borg guards), nftables firewall (default-drop input, LAN-only), Avahi mDNS service. Idempotent — skips if `ethtool eth0` shows WOL already `g`. |

---

## Power Management

The server is normally powered off. Wake and shutdown are fully automatic:

```
                    ┌─────────────────────────────┐
                    │    OFF (default state)       │
                    └──┬─────────────────────┬─────┘
           RTC alarm   │   Magic packet (WOL) │
          (02:55 daily)│  (Android/desktop)   │
                       ▼                     ▼
              ┌─────────────────────────────────┐
              │      BOOT → RUNNING             │
              │      Guard: no shutdown for     │
              │      30 min after boot          │
              ├─────────────────────────────────┤
              │  Idle check every 5 min:        │
              │  • No active SSH session        │
              │  • No BorgBackup running        │
              │  • No recent WebDAV/NC activity │
              └──────────────┬──────────────────┘
                     15 min idle
                             │
                             ▼
                    ┌─────────────────────────────┐
                    │   systemctl poweroff        │
                    └─────────────────────────────┘
```

**Wake sources**:
- **Magic packet** (WOL) — sent from Android (WOL app/widget) or desktop (wakeonlan CLI) to the server's MAC address
- **RTC alarm** — BIOS wake at 02:55, systemd timer runs backup at 03:00

**Shutdown guards** (systemd scripts prevent shutdown if any are true):
1. A BorgBackup is currently running
2. An SSH session is active
3. Less than 30 minutes have elapsed since boot

---

## Client Setup

### Android

1. Install [Nextcloud app](https://play.google.com/store/apps/details?id=com.nextcloud.client) from Play Store / F-Droid
2. Server address: `http://192.168.1.100` or `http://family-server.local`
3. Enable **Auto-upload** (Camera): settings → Auto-upload → _WiFi only_ + _Charging only_
4. **WhatsApp Media**: the Nextcloud app cannot access Android's scoped storage for WhatsApp. Use [FolderSync Pro](https://play.google.com/store/apps/details?id=dk.tacit.android.foldersync.lite) to sync `WhatsApp/Media/` to a WebDAV folder on the server.

### iOS

- **Manual upload only** — iOS does not allow apps to sync in the background reliably. Users must open the Nextcloud app and upload/share photos explicitly.

### Desktop (Linux / Windows / macOS)

- Install [Nextcloud desktop client](https://nextcloud.com/install/#install-clients) and point it to `http://family-server.local`
- Or mount via WebDAV: `http://192.168.1.100/remote.php/dav/files/USERNAME/`

---

## Backup

| Property | Value |
|----------|-------|
| Tool | BorgBackup |
| Schedule | Daily at 03:00 via `borg-backup.timer` (systemd) |
| Encryption | LUKS on `/dev/sdb1`, keyfile at `/root/luks-keyfile` (mode 0400) |
| Repo | `/mnt/backup` (initialized with repokey-blake2) |
| Retention | 7 daily, 4 weekly, 12 monthly |

The backup timer is independent of server uptime — the server wakes via RTC at 02:55, the backup runs at 03:00, and the idle watchdog shuts down 15 minutes after completion.

---

## Recovery

See [openspec/changes/first-change/recovery.md](openspec/changes/first-change/recovery.md) for step-by-step restore procedures (full system restore, file-level Borg restore, Nextcloud data restore).

---

## Project Structure

```
family-backup-server/
├── scripts/
│   ├── lib.sh                  # Shared shell functions
│   ├── install-nextcloud.sh    # LAMP + Nextcloud provisioning
│   ├── setup-backup.sh         # BorgBackup + LUKS + systemd timer
│   └── setup-wol.sh            # WOL + idle shutdown watchdog
├── openspec/
│   └── changes/
│       └── first-change/       # SDD specs, design, tasks
└── README.md                   # This file
```

---

## Maintenance

Single-person project. Infrastructure-as-code via opinionated bash scripts (idempotent, `set -euo pipefail`, no external config management tools).

- **OS updates**: `apt update && apt upgrade` (manual, no unattended-upgrades)
- **Nextcloud updates**: `sudo -u www-data php /var/www/nextcloud/updater/updater.phar`
- **Borg check**: `sudo borg check --verify-data /mnt/backup` (manual monthly recommended)

PRs and issues welcome. The setup intentionally uses plain bash so anyone with basic Linux knowledge can understand and modify it — no Ansible/Puppet/Docker required.
