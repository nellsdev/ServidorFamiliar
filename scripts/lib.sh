#!/bin/bash
# Shared helper functions for family-backup-server provisioning scripts
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; }
check_root() { if [[ $EUID -ne 0 ]]; then error "Must run as root"; exit 1; fi }
confirm() {
    read -r -p "$1 [y/N] " response
    case "$response" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}
