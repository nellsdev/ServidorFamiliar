# First change: Provision Debian 12 + Nextcloud + BorgBackup for family backup server

## Intent & Motivation

- **Why this machine**: Reuse an HP Compaq 5800 (Core 2 Duo E7400, 4GB RAM) sitting idle — avoid cloud subscription costs and keep family data under our control.
- **Why now**: Brother is leaving the country soon. Need a shared data/home server in place before he goes so everyone can sync/back up while he's still here for setup help.
- **Energy concern**: Server will sleep most of the day via Wake-on-LAN (WOL). Magic packet to wake, nightly scheduled wake for backups, auto-shutdown on idle. Keeps electricity cost near zero.

## Scope — What's IN

### OS & Base
- Install Debian 12 (64-bit, minimal, no desktop) on the 297GB HDD
- Configure LAN networking with static IP
- Set hostname and basic firewall (iptables/nftables — port 80/443 LAN only)

### Nextcloud (bare-metal)
- **Stack**: nginx + PHP-FPM + MariaDB (no Docker — too heavy for 4GB RAM)
- **Cache**: APCu only — skip Redis (another daemon, marginal benefit at this scale)
- **Tuning**:
  - MariaDB tuned for 4GB RAM (small `innodb_buffer_pool_size`, conservative connections)
  - PHP-FPM with static child pool (2-3 workers)
  - Disable heavy preview generation for images/video
  - Background jobs via cron (not AJAX/WebDAV)
- **Apps**: Only enable Files, Photos, Contacts, Calendar — disable everything else
- **Access**: LAN only (`http://family-server.local` or static IP)

### BorgBackup
- LUKS-encrypted Borg repo on the 80GB HDD mounted at `/mnt/backup`
- Daily backup via systemd timer at 03:00 (also serves as wake schedule)
- Retention: 7 daily, 4 weekly, 12 monthly
- Backup target: Nextcloud data directory + config + DB dump

### Client Setup
- **Android* (user + mom): Configure Nextcloud auto-upload for camera photos
- **iOS** (brother): Manual upload via Nextcloud app — background sync not possible on iOS
- **Desktop** (user laptop): Nextcloud client or WebDAV mount

### WhatsApp Backup (Android)
- Configure Nextcloud auto-upload to include WhatsApp media folder (`/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/`)
- Optionally use FolderSync or Syncthing-Fork to push WhatsApp local backups (`/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Backups/`) to Nextcloud
- Document the setup for mom so it's one-time and forget
- **iOS**: WhatsApp backup limited to iCloud — cannot self-host. Notify brother.

### Wake-on-LAN
- Enable WOL in BIOS and Debian (ethtool)
- Client-side: Android apps that send magic packet on demand
- Scheduling: Nightly RTC wake before 03:00 backup timer
- Auto-shutdown: systemd idle timer — shutdown after N minutes of inactivity

### Provisioning Scripts
Idempotent bash scripts stored in the repo:
- `install-nextcloud.sh` — full stack install + config
- `setup-backup.sh` — LUKS + Borg init + systemd timer
- `setup-wol.sh` — WOL enable + idle shutdown timer

### Documentation
- Recovery procedure: how to restore Nextcloud from Borg backup

## Scope — What's NOT IN (future changes)

- Internet exposure / HTTPS domain / reverse proxy — deferred

- AI photo classification — requires better hardware
- SSD upgrade — when budget permits
- Monitoring/alerting — manual health checks for now

## Assumptions

- HP Compaq 5800 supports WOL via `eth0` (common in this generation Realtek/Intel NICs)
- BIOS allows USB boot for Debian installer
- 4GB RAM is sufficient with aggressive MariaDB/PHP tuning
- Initial install is done physically (USB + monitor + keyboard)
- Brother accepts manual iOS upload workflow (no background sync expectations)
- Mother's usage is limited to auto-upload + gallery viewing (no admin tasks)

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| HDD slow for DB queries and previews | Degraded UX | Accept explicitly; disable previews; tune aggressively |
| No AES-NI on Core 2 Duo | LUKS/Borg 30-40% slower | Accept — backup window still fits nightly slot |
| iOS no background upload | Brother must open app to sync | Set expectations early; he leaves soon |
| Old hardware is single point of failure | Data loss if PSU/HDD dies | Borg backup is on separate disk; document recovery; accept risk |
| No budget for replacements | Cannot recover if hardware fails | Accept — this is a best-effort setup |

## Success Criteria

- [ ] Nextcloud accessible from LAN via browser (`http://family-server.local` or static IP)
- [ ] Android phones auto-upload photos to Nextcloud on WiFi
- [ ] BorgBackup runs daily via systemd timer, completes, and prune works
- [ ] Server wakes on magic packet (from Android/desktop) within ~30 seconds
- [ ] Server shuts down after configurable idle timeout
- [ ] Mother can open Nextcloud app and see her photos without assistance
- [ ] Brother can access and upload files from iOS during remaining time in country
