#!/usr/bin/env bash
# Sourced by backup commands. Loads shared and host configuration, then exports credentials read
# from root-only files in /etc/kopia; it is not intended to be executed directly.
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KOPIA_ETC="${KOPIA_ETC:-/etc/kopia}"
HOST="$(hostname -s | tr '[:upper:]' '[:lower:]')"

. "$BACKUP_DIR/config/default.conf"
if [ -r "$BACKUP_DIR/config/hosts/$HOST.conf" ]; then . "$BACKUP_DIR/config/hosts/$HOST.conf"; fi

secret() { if [ -r "$KOPIA_ETC/$1" ]; then printf '%s' "$(<"$KOPIA_ETC/$1")"; fi; }
write_secret() { (umask 077; printf '%s' "$2" > "$KOPIA_ETC/$1.new") && chmod 600 "$KOPIA_ETC/$1.new" && mv -f "$KOPIA_ETC/$1.new" "$KOPIA_ETC/$1"; }
export KOPIA_PASSWORD="$(secret password)"
export AWS_ACCESS_KEY_ID="$(secret b2-key-id)"      # kopia's s3 backend reads these two itself,
export AWS_SECRET_ACCESS_KEY="$(secret b2-key)"     # so they never appear on a command line

export KOPIA_CONFIG_PATH="${KOPIA_CONFIG_PATH:-$KOPIA_ETC/repository.config}"
export KOPIA_CACHE_DIRECTORY="${KOPIA_CACHE_DIRECTORY:-$CACHE_DIR}"
export KOPIA_LOG_DIR="${KOPIA_LOG_DIR:-/var/log/kopia}"
export KOPIA_CHECK_FOR_UPDATES=false
