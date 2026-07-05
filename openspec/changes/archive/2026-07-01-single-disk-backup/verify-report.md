# Verification Report

**Change**: single-disk-backup
**Version**: N/A
**Mode**: Standard (infrastructure project, no test runner)

---

## Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 17 |
| Tasks complete | 17 |
| Tasks incomplete | 0 |

All 17 tasks across all 3 phases are marked `[x]`. No unchecked tasks remain.

---

## Build & Syntax Checks

**Syntax check — setup-backup.sh**: ✅ Passed
```text
$ bash -n scripts/setup-backup.sh
→ No output (syntax OK)
```

**Syntax check — migrate-backup-to-tb.sh**: ✅ Passed
```text
$ bash -n scripts/migrate-backup-to-tb.sh
→ No output (syntax OK)
```

**Syntax check — lib.sh**: ✅ Passed
```text
$ bash -n scripts/lib.sh
→ No output (syntax OK)
```

All three scripts pass `bash -n` syntax validation with zero errors.

---

## Heredoc Quoting & Variable Expansion

| Heredoc Location | Delimiter Quoted? | Intended Variable Expansion | Correct? |
|---|---|---|---|
| setup-backup.sh: `borg-backup.sh` (single-disk) | `'BORGSCRIPT'` — YES | No (script literal) | ✅ |
| setup-backup.sh: `borg-backup.sh` (LUKS) | `'BORGSCRIPT'` — YES | No (script literal) | ✅ |
| setup-backup.sh: systemd service | `'SERVICE'` — YES | No (unit literal) | ✅ |
| setup-backup.sh: systemd timer | `'TIMER'` — YES | No (unit literal) | ✅ |
| setup-backup.sh: creds (single-disk) | `CREDS` — NO | Yes (`$BORG_PASSPHRASE`) | ✅ |
| setup-backup.sh: creds (LUKS) | `CREDS` — NO | Yes (`$LUKS_PASSWORD`, `$BORG_PASSPHRASE`) | ✅ |
| migrate-backup-to-tb.sh: `borg-backup.sh` | `'BORGSCRIPT'` — YES | No (script literal) | ✅ |
| migrate-backup-to-tb.sh: creds | `CREDS` — NO | Yes (`$LUKS_PASSWORD`, `$BORG_PASSPHRASE`) | ✅ |

All heredocs use correct quoting strategy: quoted (`'DELIMITER'`) for script/unit content to prevent premature expansion, unquoted for creds files where runtime variable expansion is required.

---

## Design Coherence

| Decision | Followed? | Evidence |
|----------|-----------|----------|
| `--single-disk` flag is explicit (not auto-detect) | ✅ Yes | Line 12: `--single-disk) SINGLE_DISK=true ;;` — explicit flag parsing before any storage ops |
| Disk quota: 80 GB warn, 90 GB abort | ✅ Yes | Heredoc lines 70-71: `DISK_QUOTA_WARN_GB=80`, `DISK_QUOTA_ABORT_GB=90`; guard at lines 82-90 |
| Single `/usr/local/bin/borg-backup.sh` path | ✅ Yes | Both branches write to same path; systemd service references same `ExecStart`; migration rewrites in place |
| Migration script self-contained with `--dry-run` and optional `--setup-luks` | ✅ Yes | Lines 14-20: flag parsing; lines 45-70: dry-run mode; lines 88-127: LUKS setup path; self-contained heredoc for LUKS borg-backup.sh variant |
| Explicit flag over auto-detect | ✅ Yes | Design decision confirmed in code — no silent fallback logic |
| Bash quota guard (not filesystem quota tools) | ✅ Yes | `df`-based check in borg-backup.sh, no quota-tools dependency |
| Migration rewrites borg-backup.sh with placeholder substitution | ✅ Yes | Heredoc uses `__LUKS_DEVICE__` placeholder; `sed -i` replaces with `$TARGET_PART` post-write (line 231) |

---

## Spec / Proposal Compliance Matrix

| Requirement | Status | Evidence |
|-------------|--------|----------|
| setup-backup.sh works without LUKS when `--single-disk` | ✅ COMPLIANT | Full LUKS-less code path at lines 31-208; no cryptsetup/fdisk/fstab/crypttab calls in single-disk branch |
| `/backup` created on system disk | ✅ COMPLIANT | Line 34: `mkdir -p /backup` |
| Borg init at `/backup` | ✅ COMPLIANT | Line 49: `borg init --encryption=repokey-blake2 /backup` |
| borg-backup.sh has no LUKS ops | ✅ COMPLIANT | Single-disk heredoc (lines 54-139) contains zero cryptsetup/luksOpen/mount/umount/luksClose calls |
| Disk quota guard exists | ✅ COMPLIANT | Lines 70-71: threshold constants; lines 82-90: usage check with abort/warn |
| Same systemd timer, same retention | ✅ COMPLIANT | Timer: identical `OnCalendar=daily` + `Persistent=true` in both branches (lines 163-173). Retention: same `--keep-daily 7 --keep-weekly 4 --keep-monthly 12` (lines 126-133) |
| Migration script exists with dry-run mode | ✅ COMPLIANT | Full script at `scripts/migrate-backup-to-tb.sh` (281 lines); `--dry-run` at lines 45-70 |
| README updated with temp setup and migration docs | ✅ COMPLIANT | Section "Temporary Single-Disk Setup" (lines 133-147) and "Migration: Single-Disk → Dedicated TB Drive" (lines 149-172) with usage examples |

---

## Correctness (Static Evidence)

| Check | Status | Notes |
|-------|--------|-------|
| `--single-disk` doesn't fall through to LUKS code | ✅ Correct | LUKS branch in `else` block (line 213); `SINGLE_DISK=true` skips the pre-LUKS guard (line 17) |
| Idempotency: existing Borg repo at `/backup` detected | ✅ Correct | Line 45: `borg list /backup` check skips init |
| Idempotency: existing LUKS detected | ✅ Correct | Line 18: `cryptsetup isLuks /dev/sdb1` exits early |
| Idempotency: migration detects complete state | ✅ Correct | Line 74: `mountpoint -q && borg list` check skips migration |
| Idempotency: crypttab/fstab guarded | ✅ Correct | Lines 111, 116: `grep -q` before appending |
| Borg passphrase at `/root/borg-passphrase` chmod 0400 | ✅ Correct | Lines 144-145 |
| Creds file chmod 600 | ✅ Correct | Lines 204, 272, 420 |
| LUKS keyfile at `/root/luks-keyfile` chmod 0400 | ✅ Correct | Lines 107-108 (migrate), 231-232 (setup) |
| Retention (7d/4w/12m) consistent in both branches | ✅ Correct | Lines 126-133 (single-disk), identical pattern in LUKS variant (lines 335-342) and migrate heredoc (lines 209-216) |
| DB dump command identical in all variants | ✅ Correct | Same `mysqldump --single-transaction --quick --lock-tables=false` across all three borg-backup.sh variants |

---

## Issues Found

**CRITICAL**: None

**WARNING**: None

**SUGGESTION**:
1. **Quota guard threshold semantics**: The `USAGE_PCT` variable (disk usage percentage) is compared against `DISK_QUOTA_ABORT_GB=90`, meaning it aborts at 90% full (≈267 GB on a 297 GB disk). While the `USAGE_GB >= 90` check reliably triggers first, the `USAGE_PCT` comparison against a GB-named constant is semantically inconsistent. Consider renaming to `DISK_QUOTA_ABORT_THRESHOLD` or splitting into separate percentage and absolute thresholds for clarity.
2. **No partition-as-device guard in migration script**: The migration script assumes `TARGET_DEV` is a whole device (e.g., `/dev/sdb`) and appends `1` to form the partition. Passing `/dev/sdb1` would produce the invalid path `/dev/sdb11`. Add validation or document in usage that only whole devices are accepted.
3. **`/backup` non-empty safety**: The design contract specifies "abort if `/backup` exists but is not empty," but the code relies on `borg init` failing on non-empty directories (via `set -euo pipefail`). An explicit `[ -n "$(ls -A /backup 2>/dev/null)" ] && error "/backup not empty"` would match the contract exactly.

---

## Verdict

**PASS WITH WARNINGS** (suggestions only — no blocking issues)

All 17 tasks complete, all three scripts pass `bash -n` syntax checks, all design decisions are correctly reflected in code, and all proposal requirements are fulfilled. The implementation is coherent, secure, and correctly handles the LUKS-less single-disk path alongside idempotency. The three suggestions above are cosmetic/low-risk improvements, not blockers.

**Next**: sdd-archive
