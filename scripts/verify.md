# Family Backup Server — Verification Checklist

Run through these checks **in order** after provisioning. Tick each box as you go.

---

## 1. Pre-flight checks (before any script)

| Check | Command | Expected | Notes |
|---|---|---|---|
| [ ] Debian version | `cat /etc/debian_version` | `12.x` | |
| [ ] RAM | `free -m` | total ≥ 3700 | |
| [ ] Disk layout | `lsblk` | `/dev/sda` ≈ 297 GB, `/dev/sdb` ≈ 80 GB | |
| [ ] Network — static IP | `ip addr show eth0` | `192.168.1.100` (or LAN-appropriate) | |
| [ ] Network — gateway | `ping -c 1 192.168.1.1` | reachable | |

---

## 2. After install-nextcloud.sh

| Check | Command | Expected | Notes |
|---|---|---|---|
| [ ] MariaDB running | `systemctl is-active mariadb` | `active` | |
| [ ] PHP-FPM running | `systemctl is-active php8.2-fpm` | `active` | |
| [ ] nginx running | `systemctl is-active nginx` | `active` | |
| [ ] Nextcloud via hostname | `curl -s -o /dev/null -w '%{http_code}' http://family-server.local` | `200` | |
| [ ] Nextcloud via IP | `curl -s -o /dev/null -w '%{http_code}' http://192.168.1.100` | `200` | |
| [ ] Previews disabled | `grep enable_previews /var/www/nextcloud/config/config.php` | `false` | |
| [ ] PHP-FPM children | `ps aux | grep -c 'php-fpm: pool'` | ≤ 4 | |
| [ ] Cron installed | `cat /etc/cron.d/nextcloud` | contains `cron.php` entry | |
| [ ] Unused apps disabled | `sudo -u www-data php /var/www/nextcloud/occ app:list --no-ansi` | only Files, Photos, Contacts, Calendar, Dashboard, Settings | |
| [ ] Credentials saved | `ls -la /root/nextcloud-creds.txt` | exists, mode `600` | |

---

## 3. After setup-backup.sh

| Check | Command | Expected | Notes |
|---|---|---|---|
| [ ] LUKS exists | `cryptsetup isLuks /dev/sdb1` | exits 0 (no error) | |
| [ ] LUKS keyfile | `ls -la /root/luks-keyfile` | exists, mode `0400` | |
| [ ] crypttab | `grep backup /etc/crypttab` | `backup /dev/sdb1 /root/luks-keyfile luks` | |
| [ ] fstab | `grep backup /etc/fstab` | `/dev/mapper/backup /mnt/backup ext4 defaults,noauto 0 0` | |
| [ ] Borg installed | `borg version` | shows version string | |
| [ ] Borg timer active | `systemctl is-active borg-backup.timer` | `active` | |
| [ ] Borg timer enabled | `systemctl is-enabled borg-backup.timer` | `enabled` | |
| [ ] Backup script | `ls -la /usr/local/bin/borg-backup.sh` | exists, executable | |
| [ ] Borg repo seeded | `sudo borg list /mnt/backup` | shows at least one archive | Run `borg-backup.sh` first if empty |
| [ ] Borg passphrase | `ls -la /root/borg-passphrase` | exists, mode `0400` | |
| [ ] Credentials saved | `ls -la /root/backup-creds.txt` | exists, mode `600` | |

---

## 4. After setup-wol.sh

| Check | Command | Expected | Notes |
|---|---|---|---|
| [ ] WOL enabled | `ethtool eth0 \| grep Wake-on` | `g` | |
| [ ] nftables loaded | `nft list ruleset` | `inet filter` table with default-drop policy | |
| [ ] Idle shutdown timer | `systemctl is-active idle-shutdown.timer` | `active` | |
| [ ] RTC wake timer | `systemctl is-active set-wake.timer` | `active` | |
| [ ] Avahi/mDNS resolves | `avahi-resolve-host-name family-server.local` | returns `192.168.1.100` | |

---

## 5. Client verification

| Check | How to verify | Notes |
|---|---|---|
| [ ] Android auto-upload | Take a photo on WiFi → check Nextcloud web UI within 5 min | Requires Nextcloud Android app with auto-upload configured |
| [ ] WhatsApp Media folder | Place a test file in `WhatsApp Media/` → verify it syncs | On Android 11+ use FolderSync or Syncthing-Fork as a workaround |
| [ ] iOS manual upload | Open Nextcloud app → upload a file → check web UI | |

---

## 6. WhatsApp backup restore note

To restore a WhatsApp local backup from the server:

1. Download the `Backup` file from Nextcloud (shared from the WhatsApp phone's local backup)
2. Place it at:
   `/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Backups/`
3. Open WhatsApp on the phone
4. When prompted, **Restore from local backup**
