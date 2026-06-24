# Nextcloud Recovery — Borg Backup Restore Guide

**Host**: HP Compaq 5800 · **OS**: Debian 12 · **Stack**: nginx + PHP 8.2-FPM + MariaDB
**Backup target**: LUKS-encrypted 80 GB HDD (`/dev/sdb1`) · **Backup tool**: Borg (repokey-blake2)

---

## 1. Prerequisites

- Server is powered on and has booted into Debian 12.
- Backup disk is physically attached (eSATA / USB / internal SATA port).
- Required packages are installed: `borgbackup`, `cryptsetup`, `lvm2` (if applicable).

```bash
apt update && apt install -y borgbackup cryptsetup
```

---

## 2. Unlock and Mount the Backup Disk

```bash
sudo cryptsetup luksOpen /dev/sdb1 backup --key-file /root/luks-keyfile
sudo mount /dev/mapper/backup /mnt/backup
```

Verify the mount:

```bash
ls /mnt/backup
# Expected: Borg repo files (config, index, hints, etc.)
```

---

## 3. List Available Archives

```bash
borg list /mnt/backup
```

Sample output:

```
nextcloud-2026-06-22-030002  Mon, 2026-06-22 03:00:02 ...
nextcloud-2026-06-21-030001  Sun, 2026-06-21 03:00:01 ...
```

Identify the archive you want to restore from. The archive name is the ISO-8601 timestamp in the listing.

---

## 4. Full Nextcloud Restore (Worst Case — Primary Disk Failure)

Use this procedure after a complete disk failure, hardware swap, or corrupted system drive.

### 4.1. Reinstall Debian 12 + Nextcloud Stack

Run the bootstrap script — it is idempotent and safe to re-run:

```bash
sudo ./install-nextcloud.sh
```

This installs nginx, PHP 8.2-FPM, MariaDB, and the Nextcloud application tree at `/var/www/nextcloud/`.

### 4.2. Stop Web Services

```bash
sudo systemctl stop nginx php8.2-fpm
```

### 4.3. Drop and Recreate the Nextcloud Database

```bash
sudo mysql -e "DROP DATABASE IF EXISTS nextcloud; CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
```

### 4.4. Extract the Latest Archive

```bash
borg extract /mnt/backup::nextcloud-2026-06-22-030002
```

This restores the full file tree relative to the current directory. The Nextcloud application files land at `/var/www/nextcloud/` and the database dump is at `/tmp/nextcloud-db-<date>.sql.gz` inside the archive.

### 4.5. Restore the MariaDB Dump

```bash
gunzip -c /tmp/nextcloud-db-2026-06-22-030002.sql.gz | sudo mysql nextcloud
```

> **Note**: The exact dump filename appears in the archive listing. Run `borg list /mnt/backup::<archive-name>` to confirm the path.

### 4.6. Restore File Permissions

```bash
sudo chown -R www-data:www-data /var/www/nextcloud
```

### 4.7. Restart Services

```bash
sudo systemctl start php8.2-fpm nginx
```

### 4.8. Post-Restore Nextcloud Tasks

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:data-fingerprint
sudo -u www-data php /var/www/nextcloud/occ files:scan --all
```

Verify the instance is healthy:

```bash
sudo -u www-data php /var/www/nextcloud/occ status
```

---

## 5. Partial Restore (Single File or Directory)

Restore one user's file without touching the rest of the system.

### 5.1. Stop Services (Read-Only Safety)

```bash
sudo systemctl stop nginx php8.2-fpm
```

### 5.2. Extract a Specific Path

```bash
borg extract /mnt/backup::nextcloud-2026-06-22-030002 \
  --path var/www/nextcloud/data/alice/files/Documents/report.pdf
```

### 5.3. Restart Services

```bash
sudo systemctl start php8.2-fpm nginx
```

### 5.4. Rescan Files (Optional)

If restoring a manually placed file (not via Nextcloud trash):

```bash
sudo -u www-data php /var/www/nextcloud/occ files:scan --path alice/files/Documents
```

---

## 6. Restore a Single File to an Arbitrary Location

Use `borg extract --stdout` when you want to preview or copy a file without overwriting the live filesystem.

```bash
borg extract --stdout /mnt/backup::nextcloud-2026-06-22-030002 \
  var/www/nextcloud/config/config.php > ~/restored-config.php
```

This writes the file content to stdout, so any absolute destination is possible via shell redirection.

---

## 7. Offline Recovery (Dead Primary Disk)

If the server's disk is dead and the machine cannot boot:

1. Boot from a Debian 12 live USB.
2. Install required tools:
   ```bash
   apt update && apt install -y borgbackup cryptsetup
   ```
3. Copy the LUKS keyfile from **another safe location** (e.g., USB stick stored with the backup disk, or printed QR code):
   ```bash
   sudo cryptsetup luksOpen /dev/sdb1 backup --key-file /path/to/luks-keyfile
   ```
4. Mount the unlocked volume:
   ```bash
   sudo mount /dev/mapper/backup /mnt/backup
   ```
5. List archives and extract:
   ```bash
   borg list /mnt/backup
   borg extract /mnt/backup::nextcloud-2026-06-22-030002
   ```
6. The extracted tree lands in the current working directory. Copy it to the new disk after partitioning and formatting.

> **Important**: The Borg passphrase file (`/root/borg-passphrase`) is also backed up inside the archive. If you have the LUKS keyfile but not the passphrase, you can find it in the extracted tree at `root/borg-passphrase`.

---

## 8. Credentials Reference

| Credential | Location |
|---|---|
| MariaDB root / nextcloud user passwords | `/root/nextcloud-creds.txt` |
| Borg passphrase | `/root/borg-passphrase` |
| LUKS keyfile | `/root/luks-keyfile` (mode **0400**, root-only) |
| Backup script | `/usr/local/bin/borg-backup.sh` |

The credentials files are included in every Borg archive (under `root/`), so they are recoverable as long as the backup disk is accessible.

---

## 9. Monthly Restore Drill

Run a quick smoke test every month — it takes less than 5 minutes:

```bash
# Mount the backup disk
sudo cryptsetup luksOpen /dev/sdb1 backup --key-file /root/luks-keyfile
sudo mount /dev/mapper/backup /mnt/backup

# Pick a small file from the latest archive and restore it
borg extract --stdout /mnt/backup::$(borg list --sort-by timestamp --last 1 /mnt/backup | head -1 | awk '{print $1}') \
  var/www/nextcloud/config/config.php > /dev/null

echo "Backup archive is readable and consistent."

# Unmount
sudo umount /mnt/backup && sudo cryptsetup luksClose backup
```

This verifies the archive is readable, the LUKS keyfile works, the Borg passphrase is correct, and the hardware path is intact — without touching production data.
