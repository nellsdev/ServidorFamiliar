#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

check_root

# Parse arguments
SINGLE_DISK=false
for arg in "$@"; do
    case "$arg" in
        --single-disk) SINGLE_DISK=true ;;
    esac
done

# Guard: if NOT single-disk, check for existing LUKS config
if [ "$SINGLE_DISK" = false ]; then
    if cryptsetup isLuks /dev/sdb1 2>/dev/null; then
        log "LUKS already configured on /dev/sdb1 — skipping setup"
        exit 0
    fi
fi

export DEBIAN_FRONTEND=noninteractive

BORG_PASSPHRASE=$(openssl rand -base64 48)

# ════════════════════════════════════════════════════════
#  Single-Disk Mode  (temporary — no LUKS, /backup on system disk)
# ════════════════════════════════════════════════════════
if [ "$SINGLE_DISK" = true ]; then

    log "Single-disk mode: creating /backup directory"
    mkdir -p /backup

    log "Installing borgbackup..."
    if ! dpkg -l borgbackup &>/dev/null; then
        apt-get install -y -qq borgbackup
        log "borgbackup installed"
    else
        log "borgbackup already installed"
    fi

    log "Initializing Borg repo..."
    if borg list /backup &>/dev/null; then
        log "Borg repo already exists at /backup — skipping init"
    else
        if [ -n "$(ls -A /backup 2>/dev/null)" ]; then
            error "/backup exists but is not empty — aborting for safety"
            exit 1
        fi
        export BORG_PASSPHRASE="$BORG_PASSPHRASE"
        borg init --encryption=repokey-blake2 /backup
    fi

    log "Writing /usr/local/bin/borg-backup.sh..."

    cat > /usr/local/bin/borg-backup.sh << 'BORGSCRIPT'
#!/bin/bash
set -euo pipefail

# Borg backup script — single-disk variant (no LUKS)
# Runs via systemd timer, writes directly to /backup
# Includes disk-usage guard to protect system disk

BACKUP_PATH="/backup"
BORG_PASSPHRASE_FILE="/root/borg-passphrase"
BORG_LOG="/var/log/borg-backup.log"
NC_DIR="/var/www/nextcloud"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME=$(hostname)

# Disk quota thresholds
# Absolute GB limits (100 GB soft limit → warn at 80 GB, abort at 90 GB)
DISK_QUOTA_WARN_GB=80
DISK_QUOTA_ABORT_GB=90
# Percentage limits (safety net regardless of disk size)
DISK_QUOTA_WARN_PCT=80
DISK_QUOTA_ABORT_PCT=90

exec >> "$BORG_LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting backup (single-disk mode)..."

if [ -f "$BORG_PASSPHRASE_FILE" ]; then
    export BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE")
fi

# Disk usage guard — check both absolute GB (intent: 100 GB soft limit)
# and percentage (safety net for any disk size)
USAGE_PCT=$(df "$BACKUP_PATH" | awk 'NR==2 {print $5}' | tr -d '%')
USAGE_GB=$(df "$BACKUP_PATH" | awk 'NR==2 {print $3/1024/1024}' | cut -d. -f1)
if [ "$USAGE_GB" -ge "$DISK_QUOTA_ABORT_GB" ] || [ "$USAGE_PCT" -ge "$DISK_QUOTA_ABORT_PCT" ]; then
    echo "DISK QUOTA EXCEEDED: ${USAGE_GB}GB used (${USAGE_PCT}%) — aborting"
    exit 1
fi
if [ "$USAGE_GB" -ge "$DISK_QUOTA_WARN_GB" ] || [ "$USAGE_PCT" -ge "$DISK_QUOTA_WARN_PCT" ]; then
    echo "WARNING: ${USAGE_GB}GB used (${USAGE_PCT}%)"
fi

# Break stale lock if present
if borg list "$BACKUP_PATH" &>/dev/null; then
    echo "Borg repo OK — no stale lock"
else
    echo "Stale lock detected — breaking lock"
    borg break-lock "$BACKUP_PATH"
    borg check --verify-data "$BACKUP_PATH"
fi

echo "Dumping MariaDB Nextcloud database..."
DB_DUMP="/tmp/nextcloud-db-${TIMESTAMP}.sql.gz"
mysqldump --single-transaction --quick --lock-tables=false \
    nextcloud 2>/dev/null | gzip > "$DB_DUMP"

echo "Creating Borg archive..."
borg create \
    --verbose \
    --filter AME \
    --list \
    --stats \
    --show-rc \
    --compression lz4 \
    --exclude "$NC_DIR/data/*/files_trashbin" \
    --exclude "$NC_DIR/data/*/cache" \
    --exclude '*.tmp' \
    --exclude "$NC_DIR/updater" \
    "$BACKUP_PATH::${HOSTNAME}-${TIMESTAMP}" \
    "$NC_DIR" \
    "$DB_DUMP"

echo "Removing local DB dump..."
rm -f "$DB_DUMP"

echo "Pruning old archives..."
borg prune \
    --verbose \
    --list \
    --show-rc \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 12 \
    "$BACKUP_PATH"

echo "Running Borg integrity check..."
borg check --verify-data "$BACKUP_PATH"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup complete"
BORGSCRIPT

    chmod 755 /usr/local/bin/borg-backup.sh

    log "Writing Borg passphrase to /root/borg-passphrase..."
    echo -n "$BORG_PASSPHRASE" > /root/borg-passphrase
    chmod 0400 /root/borg-passphrase

    log "Writing systemd service..."

    cat > /etc/systemd/system/borg-backup.service << 'SERVICE'
[Unit]
Description=Backup Nextcloud to Borg repo
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/borg-backup.sh
StandardOutput=journal
SERVICE

    log "Writing systemd timer..."

    cat > /etc/systemd/system/borg-backup.timer << 'TIMER'
[Unit]
Description=Daily Borg backup at 03:00

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    log "Enabling and starting timer..."
    systemctl daemon-reload
    systemctl enable borg-backup.timer
    systemctl start borg-backup.timer

    log "Saving credentials..."

    cat > /root/backup-creds.txt << CREDS
Backup Credentials — Family Backup Server (Single-Disk Mode)
============================================================

Borg passphrase (stored: /root/borg-passphrase):
$BORG_PASSPHRASE

IMPORTANT NOTES:
  - This is a TEMPORARY single-disk setup on the system disk
  - NO LUKS encryption — Borg passphrase is the only protection
  - System disk space is limited — monitor /backup usage
  - When the TB drive arrives, run:
      sudo ./scripts/migrate-backup-to-tb.sh /dev/sdb [--setup-luks]

Offline recovery:
  - Write down the Borg passphrase and keep in a sealed envelope
  - Without the Borg passphrase, archives are unrecoverable

Restore quick reference:
  borg list /backup
  borg extract /backup::<archive-name>
CREDS
    chmod 600 /root/backup-creds.txt

    log "Backup setup complete (single-disk mode)"
    log "Backup directory: /backup"
    log "Next step: run 'scripts/migrate-backup-to-tb.sh /dev/sdb [--setup-luks]' when TB drive arrives"

# ════════════════════════════════════════════════════════
#  Original LUKS Disk Mode  (dedicated encrypted disk)
# ════════════════════════════════════════════════════════
else

    LUKS_PASSWORD=$(openssl rand -base64 48)

    log "Partitioning /dev/sdb..."
    printf 'g\nn\n\n\n\nw' | fdisk /dev/sdb

    log "Creating LUKS container on /dev/sdb1..."
    echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat /dev/sdb1 -

    log "Opening LUKS container..."
    echo -n "$LUKS_PASSWORD" | cryptsetup luksOpen /dev/sdb1 backup -

    log "Creating ext4 filesystem..."
    mkfs.ext4 /dev/mapper/backup

    log "Writing keyfile to /root/luks-keyfile..."
    umask 077
    echo -n "$LUKS_PASSWORD" > /root/luks-keyfile
    chmod 0400 /root/luks-keyfile

    log "Configuring crypttab..."
    if ! grep -q "^backup " /etc/crypttab 2>/dev/null; then
        echo "backup /dev/sdb1 /root/luks-keyfile luks" >> /etc/crypttab
    fi

    log "Configuring fstab..."
    if ! grep -q "/dev/mapper/backup" /etc/fstab 2>/dev/null; then
        mkdir -p /mnt/backup
        echo "/dev/mapper/backup /mnt/backup ext4 defaults,noauto 0 0" >> /etc/fstab
    fi

    log "Mounting backup filesystem for Borg init..."
    mount /mnt/backup

    log "Installing borgbackup..."
    if ! dpkg -l borgbackup &>/dev/null; then
        apt-get install -y -qq borgbackup
        log "borgbackup installed"
    else
        log "borgbackup already installed"
    fi

    log "Initializing Borg repo..."
    export BORG_REPO="/mnt/backup"
    export BORG_PASSPHRASE="$BORG_PASSPHRASE"
    borg init --encryption=repokey-blake2 /mnt/backup

    log "Writing /usr/local/bin/borg-backup.sh..."

    cat > /usr/local/bin/borg-backup.sh << 'BORGSCRIPT'
#!/bin/bash
set -euo pipefail

# Borg backup script — runs via systemd timer
# Handles stale locks, LUKS unlock, mount, dump, create, prune, check, cleanup

BACKUP_MOUNT="/mnt/backup"
LUKS_MAPPER="backup"
LUKS_DEVICE="/dev/sdb1"
KEYFILE="/root/luks-keyfile"
BORG_REPO="/mnt/backup"
BORG_PASSPHRASE_FILE="/root/borg-passphrase"
BORG_LOG="/var/log/borg-backup.log"
NC_DIR="/var/www/nextcloud"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME=$(hostname)

exec >> "$BORG_LOG" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting backup..."

if [ -f "$BORG_PASSPHRASE_FILE" ]; then
    export BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE")
fi

# Break stale lock if present
if borg list "$BORG_REPO" &>/dev/null; then
    echo "Borg repo OK — no stale lock"
else
    echo "Stale lock detected — breaking lock"
    borg break-lock "$BORG_REPO"
    borg check --verify-data "$BORG_REPO"
fi

# Unlock LUKS if not already unlocked
if [ ! -e "/dev/mapper/$LUKS_MAPPER" ]; then
    echo "Opening LUKS container..."
    cryptsetup luksOpen "$LUKS_DEVICE" "$LUKS_MAPPER" --key-file "$KEYFILE"
fi

# Mount if not already mounted
if ! mountpoint -q "$BACKUP_MOUNT"; then
    echo "Mounting $BACKUP_MOUNT..."
    mount "$BACKUP_MOUNT"
fi

echo "Dumping MariaDB Nextcloud database..."
DB_DUMP="/tmp/nextcloud-db-${TIMESTAMP}.sql.gz"
mysqldump --single-transaction --quick --lock-tables=false \
    nextcloud 2>/dev/null | gzip > "$DB_DUMP"

echo "Creating Borg archive..."
borg create \
    --verbose \
    --filter AME \
    --list \
    --stats \
    --show-rc \
    --compression lz4 \
    --exclude "$NC_DIR/data/*/files_trashbin" \
    --exclude "$NC_DIR/data/*/cache" \
    --exclude '*.tmp' \
    --exclude "$NC_DIR/updater" \
    "$BORG_REPO::${HOSTNAME}-${TIMESTAMP}" \
    "$NC_DIR" \
    "$DB_DUMP"

echo "Removing local DB dump..."
rm -f "$DB_DUMP"

echo "Pruning old archives..."
borg prune \
    --verbose \
    --list \
    --show-rc \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 12 \
    "$BORG_REPO"

echo "Running Borg integrity check..."
borg check --verify-data "$BORG_REPO"

echo "Unmounting $BACKUP_MOUNT..."
umount "$BACKUP_MOUNT"

echo "Closing LUKS container..."
cryptsetup luksClose "$LUKS_MAPPER"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup complete"
BORGSCRIPT

    chmod 755 /usr/local/bin/borg-backup.sh

    log "Writing Borg passphrase to /root/borg-passphrase..."
    echo -n "$BORG_PASSPHRASE" > /root/borg-passphrase
    chmod 0400 /root/borg-passphrase

    log "Writing systemd service..."

    cat > /etc/systemd/system/borg-backup.service << 'SERVICE'
[Unit]
Description=Backup Nextcloud to Borg repo
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/borg-backup.sh
StandardOutput=journal
SERVICE

    log "Writing systemd timer..."

    cat > /etc/systemd/system/borg-backup.timer << 'TIMER'
[Unit]
Description=Daily Borg backup at 03:00

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    log "Enabling and starting timer..."
    systemctl daemon-reload
    systemctl enable borg-backup.timer
    systemctl start borg-backup.timer

    log "Saving credentials..."

    cat > /root/backup-creds.txt << CREDS
Backup Credentials — Family Backup Server
==========================================

LUKS password (keyfile: /root/luks-keyfile):
$LUKS_PASSWORD

Borg passphrase (stored: /root/borg-passphrase):
$BORG_PASSPHRASE

Offline recovery:
  - Copy /root/luks-keyfile to a USB stick and store separately
  - Write down both passwords and keep in a sealed envelope
  - Without the LUKS keyfile, the backup disk is unrecoverable
  - Without the Borg passphrase, individual archives are unrecoverable
  - Store the USB stick in a fireproof safe or offsite location

Restore quick reference:
  cryptsetup luksOpen /dev/sdb1 backup --key-file /root/luks-keyfile
  mount /dev/mapper/backup /mnt/backup
  borg list /mnt/backup
  borg extract /mnt/backup::<archive-name>
CREDS
    chmod 600 /root/backup-creds.txt

    log "Unmounting backup filesystem..."
    umount /mnt/backup

    log "Closing LUKS container..."
    cryptsetup luksClose backup

    log "Backup setup complete"
    log "Credentials saved to /root/backup-creds.txt"
    log "IMPORTANT: Copy /root/luks-keyfile and passwords to offline storage before relying on this backup"

fi
