# Design: Single-Disk Backup (Temporary Setup)

## Technical Approach

Adapt the backup provisioning and execution pipeline to work without a dedicated LUKS-encrypted disk. Add a `--single-disk` flag to `setup-backup.sh` that skips fdisk, LUKS, crypttab, fstab, and keyfile setup, and instead creates a `/backup` directory on the system disk. The generated `borg-backup.sh` omits all LUKS operations (no luksOpen/mount/unmount/luksClose) and includes a disk-usage guard that aborts if `/backup` usage exceeds 90 GB (soft limit: 100 GB). Retention, timer schedule, and DB dump flow are unchanged. A new `migrate-backup-to-tb.sh` script handles future migration to a TB drive with optional LUKS setup.

## Architecture Decisions

### Decision: --single-disk flag vs auto-detect

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Explicit `--single-disk` flag | User must remember it; no false positives | **Chosen** |
| Auto-detect missing LUKS device | Silent fallback could mask real disk failure; implicit behavior changes | Rejected |

**Rationale**: Explicit flag makes the temporary state visible in provisioning commands and logs. Auto-detect would silently change behavior if `/dev/sdb` disappears due to hardware fault — exactly when you want an error, not a silent fallback.

### Decision: Disk quota mechanism

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Bash guard: check `/backup` usage before Borg create | Trivial to implement, inspect, and remove when TB drive arrives | **Chosen** |
| Filesystem quota (quota tools) | Kernel config dependency; extra tooling for a temp setup | Rejected |
| No guard | System disk fills with no warning | Rejected |

**Rationale**: A bash guard with warning at 80 GB and abort at 90 GB is trivially inspectable and removable. The 10 GB buffer accounts for the DB dump and temporary files during a backup run.

### Decision: Single borg-backup.sh path

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Same path `/usr/local/bin/borg-backup.sh` | Migration overwrites with LUKS variant; systemd service needs no path change | **Chosen** |
| Separate path per mode | Systemd service must be re-pointed during migration; more moving parts | Rejected |

**Rationale**: The systemd service always points to the same binary. During migration, `migrate-backup-to-tb.sh` rewrites it with a LUKS-aware version. Fewer config files, simpler state tracking.

### Decision: Migration script scope

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Self-contained: handles LUKS + copy + script rewrite | Duplicates some heredoc logic from setup-backup.sh; single entry point | **Chosen** |
| Migration copies repo only; user re-runs setup-backup.sh | setup-backup.sh assumes specific device paths; more manual steps | Rejected |

**Rationale**: A self-contained migration script takes the target device as a single argument, optionally partitions/encrypts it, copies the Borg repo, and rewrites `borg-backup.sh` with LUKS operations. Dry-run mode shows every step without executing. Idempotent — second run detects migrated state and skips.

## Data Flow

```
Single-Disk Mode:

  setup-backup.sh --single-disk
    └→ Create /backup
    └→ Borg init /backup (repokey-blake2)
    └→ Write /usr/local/bin/borg-backup.sh (no LUKS)
    └→ systemd timer (daily 03:00)

  Daily 03:00 (borg-backup.sh):
    ├→ Read passphrase from /root/borg-passphrase
    ├→ Check /backup usage < 90 GB → abort if exceeded
    ├→ Break stale lock if present
    ├→ mysqldump → /tmp/nextcloud-db-*.sql.gz
    ├→ borg create → /backup (lz4, exclusions)
    ├→ borg prune (7d/4w/12m)
    └→ borg check --verify-data

Migration Path (future TB drive):

  migrate-backup-to-tb.sh /dev/sdb [--setup-luks] [--dry-run]
    └→ systemctl stop borg-backup.timer
    └→ borg check --verify-data /backup
    └→ [--setup-luks] Partition, LUKS format, mount
    └→ rsync -a /backup/ → /mnt/backup/
    └→ Rewrite borg-backup.sh (LUKS variant, /mnt/backup paths)
    └→ systemctl daemon-reload && systemctl start borg-backup.timer
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `scripts/setup-backup.sh` | Modify | Add `--single-disk` flag guard; conditional skip of fdisk/LUKS/fstab/crypttab/keyfile; alternative heredoc for borg-backup.sh without LUKS ops; alternative creds file without LUKS section |
| `scripts/migrate-backup-to-tb.sh` | Create | Idempotent migration: stop timer, borg check, optional LUKS setup, rsync repo, rewrite borg-backup.sh, restart timer; `--dry-run` preview; `--setup-luks` flag |
| `README.md` | Modify | Hardware table: add `Disk 2 (temp)` row for `/backup` on system disk; rename current Disk 2 to "Disk 3 (future)"; add migration section referencing the script |

## Interfaces / Contracts

### Flag Contract: `setup-backup.sh --single-disk`

```
Input:  --single-disk              # Enables LUKS-less path
Pre:    root access; no prior Borg repo at /backup
Post:   /backup/ created, Borg repo init'd, borg-backup.sh at
        /usr/local/bin, borg-backup.timer enabled
Errors: /backup exists with Borg repo → idempotent skip
        /backup exists but is not empty → abort (safety)
```

### Generated Script Contract (single-disk variant)

```
BACKUP_PATH=/backup                    # Direct path, no LUKS mapper
BORG_PASSPHRASE_FILE=/root/borg-passphrase
DISK_QUOTA_WARN_GB=80
DISK_QUOTA_ABORT_GB=90                 # Abort before borg create
No LUKS ops: no cryptsetup, no mount, no umount
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Provisioning | `setup-backup.sh --single-disk` completes | Debian 12 VM: check `/backup` exists, Borg repo init'd, systemd timer active |
| Execution | `borg-backup.sh` runs to completion | Trigger systemd oneshot; verify archive in `/backup`, no LUKS commands in log |
| Disk guard | Quota abort behavior | Fill `/backup` past 90 GB; verify script exits before `borg create` |
| Migration | Dry-run output correctness | Run `--dry-run` with mock device path; verify printed steps |
| Idempotency | Re-run setup and migration scripts | Second run should detect existing state and skip |

## Migration / Rollout

No staged rollout — this is a fresh setup on a new machine with the 80 GB HDD disconnected. One-step: `setup-backup.sh --single-disk`. When the TB drive arrives, run `migrate-backup-to-tb.sh /dev/sdb [--setup-luks]` to switch to dedicated storage. Rollback: stop timer, delete `/backup`, re-run `setup-backup.sh` (without flag) once the old LUKS disk is reconnected.

## Open Questions

- [ ] Should `migrate-backup-to-tb.sh` embed its own LUKS-aware borg-backup.sh template, or invoke `setup-backup.sh` (without `--single-disk`) after LUKS setup? Design assumes self-contained for simplicity, but this duplicates the heredoc.
- [ ] `borg check --verify-data` before migration — estimate runtime on 100 GB repo over USB 2.0; may need a `--quick-check` option if migration takes too long.
