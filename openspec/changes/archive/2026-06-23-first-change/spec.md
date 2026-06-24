# Spec: Provision Debian 12 + Nextcloud + BorgBackup for family backup server

## 1. Requirements

### Functional

**F1 — OS and base provisioning**
Debian 12 minimal installation (no desktop) on the 297GB HDD. Static IP on LAN. Firewall (nftables) allowing ports 22, 80, 443 from LAN only. Hostname set to `family-server`.

**F2 — Nextcloud LAN access**
Nextcloud accessible via browser over LAN at `http://family-server.local` (Avahi/mDNS) or via the server's static IP address. No TLS/HTTPS for this iteration.

**F3 — Android photo/video auto-upload**
Android phones running the Nextcloud app automatically upload new photos and videos when connected to home WiFi. Upload triggers on WiFi + charging (configurable in app).

**F4 — WhatsApp Media auto-upload**
Nextcloud auto-upload configured to also watch the WhatsApp Media folder: `/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/`.

**F5 — Desktop sync**
The user's laptop syncs via the Nextcloud desktop client (or WebDAV mount).

**F6 — iOS access**
iPhone running the Nextcloud app can upload files manually. No background sync (iOS limitation — accepted and documented).

**F7 — BorgBackup with encryption**
LUKS-encrypted Borg backup repository on the 80GB HDD, mounted at `/mnt/backup`. Keyfile stored on primary disk (copy printed + stored in docs).

**F8 — Daily backup schedule**
systemd timer triggers backup of Nextcloud data directory (`/var/www/nextcloud/data`), Nextcloud config (`/var/www/nextcloud/config`), and a MariaDB dump at 03:00 daily.

**F9 — Backup retention**
Borg prune retains: 7 daily, 4 weekly, 12 monthly snapshots.

**F10 — Wake-on-LAN**
Server normally powered off. Wakes on magic packet (sent from Android app, laptop, or any LAN client). Auto-shutdown after configurable idle timeout (15 min default).

**F11 — Scheduled RTC wake**
BIOS RTC alarm set to wake server before 03:00 backup window (target: 02:55).

### Non-Functional

**NF1 — RAM budget ≤ 3GB peak**
The combined stack (MariaDB + PHP-FPM + nginx + Borg during backup) must not exceed 3GB RSS peak, leaving ~1GB headroom for the kernel and bursts.

**NF2 — Debian base RAM ≤ 200MB at idle**
Minimal server install with no desktop, no snapd, no unnecessary services. Base idle RAM must stay under 200MB.

**NF3 — MariaDB tuned for 4GB RAM**
`innodb_buffer_pool_size` set to 256MB. `max_connections` set to 10. Query cache disabled. Conservative `innodb_log_file_size`.

**NF4 — PHP-FPM with max 3-4 children**
Static pool of 2-3 PHP-FPM workers, `pm.max_children = 4` hard cap.

**NF5 — No preview generation**
Preview generation for images and video disabled in Nextcloud `config.php` (`enable_previews => false`).

**NF6 — Backup completion within 2 hours**
Full backup (Nextcloud data + DB dump + Borg create + Borg prune) must complete within the 03:00-05:00 window.

**NF7 — Energy: server off > 20h/day**
Server powers off after idle timeout. Only runs for ~60-90 min nightly backup + on-demand WOL sessions. Target power-off > 20 hours per day.

**NF8 — apt-only software installation**
All software installed via Debian apt repositories. No snap, no flatpak, no pip/pipx system-wide installs, no go install for system packages.

**NF9 — No Docker**
All services run bare-metal (nginx, PHP-FPM, MariaDB). Containerization adds overhead unacceptable for 4GB RAM.

## 2. Scenarios

### 2.1 Happy Path — Daily backup

1. BIOS RTC alarm triggers at 02:55 — server powers on.
2. Debian boots (~30-45s). Network comes up. Filesystems mount (including LUKS + `/mnt/backup`).
3. `borg-backup.timer` fires at 03:00, activating `borg-backup.service`.
4. Service runs `mysqldump` to dump all Nextcloud databases to a temp file.
5. `borg create` runs with `--compression lz4` on: Nextcloud data dir, config dir, DB dump.
6. `borg prune` removes archives outside retention policy (7d, 4w, 12m).
7. Service completes, logs success to systemd journal.
8. Idle timer starts. After 30 min with no SSH/HTTP traffic, systemd triggers `shutdown -P +0`.
9. Total window: ~60-90 min. Server off for remaining ~22.5 hours.

### 2.2 Happy Path — User accesses Nextcloud

1. User opens Nextcloud app on Android (or browser on laptop).
2. Android app sends WOL magic packet to server's MAC address (via external app or Tasker automation; laptop uses `wakeonlan` CLI).
3. Server boots. Nextcloud stack starts (nginx, PHP-FPM, MariaDB all enabled on boot).
4. Within 30-60s, `http://family-server.local` responds with Nextcloud login page.
5. User authenticates, browses/uploads/downloads photos.
6. After 15 min of no SSH or HTTP traffic → idle timer expires → auto-shutdown.

### 2.3 Happy Path — Android auto-upload

1. User takes a photo on their Android phone.
2. Nextcloud app detects new photo. Conditions: connected to home WiFi (SSID match), battery charging or >50%.
3. App uploads photo to configured Nextcloud folder (e.g. `/Photos/`).
4. WhatsApp Media: Nextcloud's folder auto-upload configuration includes `/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/` → files appear under a dedicated folder in Nextcloud (e.g. `/WhatsApp Media/`).

### 2.4 Edge Case — Backup drive missing

1. `borg-backup.timer` fires at 03:00.
2. `borg-backup.service` attempts to run but `/mnt/backup` is not mounted (LUKS not unlocked, drive disconnected, or filesystem error).
3. Borg command fails. systemd logs failure with `FAILURE` level.
4. Service exits non-zero. systemd does not retry (no `Restart=` on the service).
5. **Consequence**: One night of backup missed. No data loss — Nextcloud data remains intact on primary disk.
6. **Recovery**: Admin unlocks LUKS (`cryptsetup open`), mounts, checks filesystem (`fsck`), re-runs `systemctl start borg-backup.service`.
7. **Future prevention**: A simple wrapper script can check mount before Borg and log a more descriptive error.

### 2.5 Edge Case — Power failure during backup

1. Server loses AC power at 03:15 during `borg create`.
2. On next power-on (WOL or RTC), system boots normally.
3. Borg repo may have a stale lock from the aborted operation.
4. Next `borg-backup.service` run: `borg create` detects stale lock and fails.
5. Wrapper script must handle: `borg break-lock <repo>` then `borg check --verify-data <repo>` to ensure repo integrity.
6. At most the in-progress backup is lost. Previous backup archives remain intact.
7. **Mitigation**: Include lock-breaking and check in the backup script pre-run hook.

### 2.6 Edge Case — iOS user

1. Brother opens Nextcloud app on iPhone.
2. Navigates to target folder, taps the upload icon, selects photos from library.
3. Upload proceeds in foreground only. If app is backgrounded or phone locks, upload pauses.
4. No background auto-upload on iOS — this is a platform limitation, not a configuration gap.
5. **Documented and accepted**: Brother informed and agrees to manual upload workflow during his remaining time in country.

## 3. Scenarios for WhatsApp (Android)

### 3.1 Happy Path — WhatsApp media auto-upload

1. WhatsApp receives a photo in a chat → saves to `/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/`.
2. Nextcloud folder auto-upload detects the new file (polling interval: app-dependent, ~5-15 min).
3. File uploads to Nextcloud under the user's WhatsApp backup folder (e.g. `/WhatsApp Media/`).
4. User can browse WhatsApp media from any device (laptop, other phone, tablet) via Nextcloud.

### 3.2 Edge Case — Directory path differs by Android version

1. Android 11+ scoped storage restricts access to `Android/media/` paths.
2. Nextcloud app's auto-upload folder picker may not be able to browse to that path directly.
3. **Workaround**: Use FolderSync or Syncthing-Fork as a bridge — these apps have scoped storage permissions and can watch the WhatsApp Media folder, then sync to Nextcloud via WebDAV.
4. **Accept**: On older Android (< 11) the Nextcloud app can watch the path directly.

### 3.3 Manual WhatsApp chat backup (Android)

1. User opens WhatsApp → Settings → Chats → Chat backup → tap BACK UP.
2. Backup file lands in `/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Backups/`.
3. FolderSync (or Nextcloud auto-upload if path is accessible) picks up the backup file and syncs to Nextcloud.
4. **Restore procedure**: Download backup file from Nextcloud, place it back in the WhatsApp Backups folder, open WhatsApp and restore from local backup.

## 4. Acceptance Criteria

Each criterion is a testable pass/fail statement for verification.

| ID | Criterion | Verification |
|----|-----------|-------------|
| AC1 | Debian 12 boots and reports correct version | `uname -a` kernel dated 2023+; `cat /etc/debian_version` shows `12.x` |
| AC2 | Total RAM is ≥ 3.7GB | `free -m` shows total ≥ 3700 |
| AC3 | Nextcloud login page is reachable via LAN hostname | `curl -s -o /dev/null -w '%{http_code}' http://family-server.local` returns `200` |
| AC4 | Nextcloud login page is reachable via static IP | `curl -s -o /dev/null -w '%{http_code}' http://<STATIC_IP>` returns `200` |
| AC5 | Firewall blocks WAN access on port 80 | From outside LAN: `curl --connect-timeout 5 http://<STATIC_IP>` fails (timeout or no route) |
| AC6 | MariaDB is running | `systemctl is-active mariadb` returns `active` |
| AC7 | Nextcloud config has previews disabled | `grep enable_previews /var/www/nextcloud/config/config.php` shows `false` |
| AC8 | PHP-FPM is running with ≤ 4 children | `systemctl is-active php8.2-fpm` (or version-matched) returns `active`; `ps aux | grep 'php-fpm: pool' | wc -l` ≤ 4 |
| AC9 | Android auto-upload: photo taken on WiFi appears in Nextcloud within 5 min | Manual test: take photo, verify in Nextcloud web UI within 5 min |
| AC10 | WhatsApp Media folder contents appear in Nextcloud | Manual test: place test file in WhatsApp Media on Android, verify it syncs to Nextcloud |
| AC11 | Borg backup systemd timer is active | `systemctl is-active borg-backup.timer` returns `active` |
| AC12 | Borg backup systemd timer is enabled | `systemctl is-enabled borg-backup.timer` returns `enabled` |
| AC13 | Borg repo exists and contains at least one archive | `sudo borg list /mnt/backup` exits 0 and shows ≥ 1 archive |
| AC14 | Backup retention prune works | After 2+ simulated backups, `sudo borg list /mnt/backup --short` shows ≤ retention limit |
| AC15 | Wake-on-LAN: server boots from magic packet | Shutdown server, send magic packet from laptop, verify it boots within 60s |
| AC16 | Auto-shutdown: server shuts down after idle timeout | Wait 15 min after last SSH session, verify `last -x | grep shutdown` shows recent entry |
| AC17 | RTC wake alarm is set | `cat /sys/class/rtc/rtc0/wakealarm` shows a future timestamp (or BIOS confirms alarm configured) |
| AC18 | Idle RAM ≤ 200MB for base Debian | After boot with no services: `free -m` shows `used` ≤ 200 (excluding buffers/cache) |
| AC19 | Peak RAM during backup ≤ 3GB | Monitor with `free -m` during `borg-backup.service` run — verify `used` never exceeds 3072 |
| AC20 | All software installed via apt | `dpkg -S $(which ...)` for each binary — no snap/flatpak/pip packages in system paths |
