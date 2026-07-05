# Tasks: Single-Disk Backup (Temporary Setup)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 200–280 |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | single-pr |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Foundation: `setup-backup.sh --single-disk` flag | PR 1 | Base; modifies 1 file |
| 2 | Core: `migrate-backup-to-tb.sh` | PR 1 | New file; depends on Phase 1 paths |
| 3 | Docs: `README.md` update | PR 1 | Requires Phase 1/2 knowledge |

## Phase 1: Foundation — `setup-backup.sh` `--single-disk` flag

- [x] 1.1 Add `--single-disk` flag parsing to `setup-backup.sh` after `check_root`, before the existing LUKS detection gate
- [x] 1.2 Guard existing fdisk/LUKS/crypttab/fstab/keyfile block behind `! single_disk` conditional
- [x] 1.3 Write single-disk branch: `mkdir -p /backup`, install Borg, `borg init /backup` (repokey-blake2)
- [x] 1.4 Write alternative `borg-backup.sh` heredoc: `BACKUP_PATH=/backup`, no LUKS ops, `DISK_QUOTA_WARN_GB=80`, `DISK_QUOTA_ABORT_GB=90` guard before `borg create`
- [x] 1.5 Write alternative creds file (no LUKS section, Borg passphrase only)
- [x] 1.6 Ensure idempotency: detect existing `/backup` Borg repo and skip when `--single-disk`

## Phase 2: Core — `scripts/migrate-backup-to-tb.sh`

- [x] 2.1 Create script with shebang, `set -euo pipefail`, arg parsing for `TARGET_DEV`, `--setup-luks`, `--dry-run`
- [x] 2.2 Implement `--dry-run`: print all steps with `[DRY-RUN]` prefix, exit without executing
- [x] 2.3 Pre-migration guard: `systemctl stop borg-backup.timer`, `borg check --verify-data /backup`
- [x] 2.4 Implement optional LUKS setup: `fdisk`, `cryptsetup luksFormat/luksOpen`, `mkfs.ext4`, mount target
- [x] 2.5 Implement `rsync -a /backup/` to target mount point
- [x] 2.6 Rewrite `/usr/local/bin/borg-backup.sh` with LUKS-aware variant (`/mnt/backup` paths, cryptsetup ops, keyfile)
- [x] 2.7 Implement `systemctl daemon-reload`, `systemctl start borg-backup.timer`
- [x] 2.8 Implement idempotency: detect existing Borg repo at target and skip

## Phase 3: Documentation — `README.md` update

- [x] 3.1 Update hardware table: add `Disk 2 (temp)` row for `/backup` on system disk, rename current Disk 2 to `Disk 3 (future)`
- [x] 3.2 Add disk layout section: single-disk temp setup vs. LUKS dedicated disk
- [x] 3.3 Add migration section with `migrate-backup-to-tb.sh` usage examples (`--dry-run`, `--setup-luks`)
