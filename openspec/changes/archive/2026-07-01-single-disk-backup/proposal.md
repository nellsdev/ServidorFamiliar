# Proposal: Single-Disk Backup (Temporary Setup)

## Intent

The backup disk (80 GB HDD) is disconnected due to a missing SATA cable. Until a replacement TB drive arrives, the backup system must work on the existing system disk without a dedicated LUKS device. This is a temporary config refactor — no feature changes, no new capabilities.

## Scope

### In Scope
- Modify `setup-backup.sh` to work without LUKS: create `/backup` on system disk, install Borg, init repo at `/backup`, generate `borg-backup.sh` with no LUKS ops (no unlock/mount/unmount/close)
- Write `scripts/migrate-backup-to-tb.sh` to transfer repo to a future TB drive with optional LUKS setup
- Update `README.md` — hardware table, disk layout notes, migration instructions
- Enforce 100 GB soft quota via `borg-backup.sh` guard (abort if `/backup` usage exceeds threshold)
- Same systemd timer (daily 03:00), same retention (7d/4w/12m), same DB dump + NC data backup

### Out of Scope
- No new encryption layer — Borg passphrase only (user decision)
- No changes to `install-nextcloud.sh`, `setup-wol.sh`, `lib.sh`
- No monitoring or alerting for disk usage (future concern)
- No actual TB drive support — the migration script is a placeholder until hardware arrives

## Capabilities

### New Capabilities
None — this change modifies existing behavior, no new spec-level capabilities.

### Modified Capabilities
None — pure implementation/script refactor with no requirement-level behavior changes.

## Approach

1. **`setup-backup.sh`**: Add a `--single-disk` flag (or detect missing `/dev/sdb`). When active: skip fdisk, LUKS, crypttab, fstab, keyfile. Create `/backup` dir. Install Borg. Init repo. Write `borg-backup.sh` variant without LUKS steps — writes directly to `/backup`, includes a disk-usage guard that aborts if `/backup` exceeds 100 GB.
2. **`borg-backup.sh` (generated)**: No LUKS references. Reads passphrase from `/root/borg-passphrase`. Writes to `/backup`. Skips mount/unmount/luksOpen/luksClose. Has a `DISK_QUOTA_GB=100` guard.
3. **`scripts/migrate-backup-to-tb.sh`**: Stops timer, runs `borg check`, copies repo to new disk (target path as arg), optionally runs LUKS setup, updates systemd service `ExecStart` paths, restarts timer.
4. **README.md**: Update disk layout table, add `/backup` row, document migration flow.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `scripts/setup-backup.sh` | Modified | LUKS-less path with `--single-disk` flag |
| `scripts/migrate-backup-to-tb.sh` | **New** | Migration script for TB drive handoff |
| `README.md` | Modified | Hardware table, disk layout, migration section |
| `borg-backup.sh` (generated) | Modified | No LUKS ops, disk usage guard |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| System disk fills up | Medium | 100 GB soft guard in script; logs warning before abort |
| Borg passphrase lost with no LUKS fallback | Low | Backup `/root/borg-passphrase` instructions in creds file |
| Migration script untested without TB drive | High | Document dry-run mode; test repo copy + path update logic standalone |

## Rollback Plan

Revert hardware config: unplug system disk, reconnect old 80 GB drive. Re-run `setup-backup.sh` (idempotent — detects LUKS on `/dev/sdb1` and exits). Restore from backup if needed.

## Dependencies

- BorgBackup (already on system or installed by script)
- Root access for `/backup` directory creation and systemd timer setup

## Success Criteria

- [ ] `setup-backup.sh --single-disk` creates `/backup`, inits Borg repo, writes `borg-backup.sh`, installs systemd timer — no LUKS errors
- [ ] `borg-backup.sh` runs to completion without touching `/dev/mapper/backup` or `/mnt/backup`
- [ ] `scripts/migrate-backup-to-tb.sh` copies repo and updates paths (verified by dry-run output)
- [ ] README accurately reflects current single-disk layout and migration path
