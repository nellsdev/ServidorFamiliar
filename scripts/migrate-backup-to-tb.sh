#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

check_root

# Defaults
SETUP_LUKS=false
DRY_RUN=false
TARGET_DEV=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup-luks) SETUP_LUKS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) TARGET_DEV="$1"; shift ;;
    esac
done

# ── Usage / arg validation ──────────────────────────────────────────
if [ -z "$TARGET_DEV" ]; then
    echo "Usage: $0 [--setup-luks] [--dry-run] <target-device>"
    echo ""
    echo "Migrate Borg backup from /backup (single-disk mode) to a dedicated disk."
    echo ""
    echo "Arguments:"
    echo "  <target-device>   Target block device (e.g., /dev/sdb)"
    echo "  --setup-luks      Partition, LUKS-format, and create ext4 on target"
    echo "  --dry-run         Print steps without executing"
    echo ""
    echo "Examples:"
    echo "  $0 --dry-run /dev/sdb"
    echo "  $0 --setup-luks /dev/sdb"
    echo "  $0 /dev/sdc"
    exit 1
fi

# Strip trailing partition number if user passed a partition (e.g. /dev/sdb1 → /dev/sdb)
TARGET_DEV_BASE="${TARGET_DEV}"
if [[ "$TARGET_DEV" =~ ^(/dev/.+?)([0-9]+)$ ]]; then
    log "Detected partition device — stripping to whole device '${BASH_REMATCH[1]}'"
    TARGET_DEV_BASE="${BASH_REMATCH[1]}"
fi
TARGET_PART="${TARGET_DEV_BASE}1"
BACKUP_MOUNT="/mnt/backup"
BORG_PASSPHRASE_FILE="/root/borg-passphrase"

# ── Dry-run mode ────────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] Migration from /backup to $TARGET_DEV"
    echo "[DRY-RUN]"
    echo "[DRY-RUN] The following steps would be executed:"
    echo "[DRY-RUN]"
    echo "[DRY-RUN]   1. systemctl stop borg-backup.timer"
    echo "[DRY-RUN]   2. borg check --verify-data /backup"
    if [ "$SETUP_LUKS" = true ]; then
        echo "[DRY-RUN]   3. Partition $TARGET_DEV (GPT, single partition)"
        echo "[DRY-RUN]   4. LUKS format $TARGET_PART"
        echo "[DRY-RUN]   5. Open LUKS container → /dev/mapper/backup"
        echo "[DRY-RUN]   6. mkfs.ext4 /dev/mapper/backup"
        echo "[DRY-RUN]   7. Write keyfile to /root/luks-keyfile"
        echo "[DRY-RUN]   8. Configure crypttab + fstab"
        echo "[DRY-RUN]   9. Mount /dev/mapper/backup at $BACKUP_MOUNT"
    else
        echo "[DRY-RUN]   3. Mount $TARGET_DEV at $BACKUP_MOUNT (assuming pre-formatted)"
    fi
    echo "[DRY-RUN]  10. rsync -a /backup/ → $BACKUP_MOUNT"
    echo "[DRY-RUN]  11. Rewrite /usr/local/bin/borg-backup.sh (LUKS variant, device: $TARGET_PART)"
    echo "[DRY-RUN]  12. Update /root/backup-creds.txt with LUKS section"
    echo "[DRY-RUN]  13. systemctl daemon-reload"
    echo "[DRY-RUN]  14. systemctl start borg-backup.timer"
    echo "[DRY-RUN]"
    echo "[DRY-RUN] Run without --dry-run to execute."
    exit 0
fi

# ── Idempotency check ──────────────────────────────────────────────
if mountpoint -q "$BACKUP_MOUNT" && borg list "$BACKUP_MOUNT" &>/dev/null; then
    log "Borg repo already exists at $BACKUP_MOUNT — migration appears complete, skipping"
    exit 0
fi

# ── Step 1: Stop timer ─────────────────────────────────────────────
log "Stopping borg-backup.timer..."
systemctl stop borg-backup.timer 2>/dev/null || true

# ── Step 2: Verify source integrity ─────────────────────────────────
log "Verifying source backup integrity..."
borg check --verify-data /backup

# ── Steps 3-9: Optional LUKS setup ──────────────────────────────────
if [ "$SETUP_LUKS" = true ]; then
    log "Setting up LUKS on $TARGET_DEV..."

    log "Partitioning $TARGET_DEV..."
    printf 'g\nn\n\n\n\nw' | fdisk "$TARGET_DEV"

    LUKS_PASSWORD=$(openssl rand -base64 48)

    log "Creating LUKS container on $TARGET_PART..."
    echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat "$TARGET_PART" -

    log "Opening LUKS container..."
    echo -n "$LUKS_PASSWORD" | cryptsetup luksOpen "$TARGET_PART" backup -

    log "Creating ext4 filesystem..."
    mkfs.ext4 /dev/mapper/backup

    log "Writing keyfile to /root/luks-keyfile..."
    umask 077
    echo -n "$LUKS_PASSWORD" > /root/luks-keyfile
    chmod 0400 /root/luks-keyfile

    log "Configuring crypttab..."
    if ! grep -q "^backup " /etc/crypttab 2>/dev/null; then
        echo "backup $TARGET_PART /root/luks-keyfile luks" >> /etc/crypttab
    fi

    log "Configuring fstab..."
    if ! grep -q "/dev/mapper/backup" /etc/fstab 2>/dev/null; then
        mkdir -p "$BACKUP_MOUNT"
        echo "/dev/mapper/backup $BACKUP_MOUNT ext4 defaults,noauto 0 0" >> /etc/fstab
    fi

    log "Mounting backup filesystem..."
    mount "$BACKUP_MOUNT"
else
    log "Mounting $TARGET_DEV at $BACKUP_MOUNT (assuming already formatted)..."
    mkdir -p "$BACKUP_MOUNT"
    mount "$TARGET_DEV" "$BACKUP_MOUNT"
fi

# ── Step 10: rsync backup repo ──────────────────────────────────────
log "Copying backup repository from /backup to $BACKUP_MOUNT..."
rsync -a /backup/ "$BACKUP_MOUNT"

# ── Step 11: Rewrite borg-backup.sh (LUKS-aware variant) ────────────
log "Writing LUKS-aware /usr/local/bin/borg-backup.sh..."

cat > /usr/local/bin/borg-backup.sh << 'BORGSCRIPT'
#!/bin/bash
set -euo pipefail

# Borg backup script — LUKS variant (dedicated encrypted disk)
# Runs via systemd timer
# Handles stale locks, LUKS unlock, mount, dump, create, prune, check, cleanup

BACKUP_MOUNT="/mnt/backup"
LUKS_MAPPER="backup"
LUKS_DEVICE="__LUKS_DEVICE__"
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

# Replace the LUKS device placeholder with the actual target partition
sed -i "s|__LUKS_DEVICE__|${TARGET_PART}|g" /usr/local/bin/borg-backup.sh
chmod 755 /usr/local/bin/borg-backup.sh

# ── Step 12: Update creds file with LUKS section ────────────────────
log "Updating /root/backup-creds.txt..."

# Read existing Borg passphrase
BORG_PASSPHRASE=""
if [ -f "$BORG_PASSPHRASE_FILE" ]; then
    BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE")
fi

# Determine LUKS password (newly generated or existing keyfile)
LUKS_PASSWORD="${LUKS_PASSWORD:-}"
if [ -z "$LUKS_PASSWORD" ] && [ -f /root/luks-keyfile ]; then
    LUKS_PASSWORD=$(cat /root/luks-keyfile)
fi

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
  cryptsetup luksOpen $TARGET_PART backup --key-file /root/luks-keyfile
  mount /dev/mapper/backup /mnt/backup
  borg list /mnt/backup
  borg extract /mnt/backup::<archive-name>
CREDS
chmod 600 /root/backup-creds.txt

# ── Steps 13-14: Restart timer ──────────────────────────────────────
log "Restarting borg-backup.timer..."
systemctl daemon-reload
systemctl start borg-backup.timer

log "Migration complete — backup repository transferred to $TARGET_DEV"
log "Systemd timer borg-backup.timer is active"
log "Verify with: systemctl status borg-backup.timer"
