#!/usr/bin/env bash
# Sourced by backup commands. Loads shared and host configuration, then exports credentials read
# from root-only files in /etc/kopia; it is not intended to be executed directly.
# Repositories: `local` when LOCAL_REPO is set, then `b2` always; the fast one first, so a job
# queued behind a slow upload still gets the local copy done early. `local` is a disk attached to
# this machine, or, when LOCAL_HOST is set, the same disk on another host over SFTP. Each has its
# own kopia config file and cache. After sourcing, kopia addresses $REPO (default b2;
# `REPO=local kb ...`); for_each_repo runs a command against every repository in turn.
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

export KOPIA_LOG_DIR="${KOPIA_LOG_DIR:-/var/log/kopia}"
export KOPIA_CHECK_FOR_UPDATES=false

REPOS=()
[ -z "${LOCAL_REPO:-}" ] || REPOS+=(local)
REPOS+=(b2)

repo_env() { # point kopia at repository $1: config file, cache, and for an attached local disk, it must be mounted
  local r
  for r in "${REPOS[@]}"; do [ "$r" = "$1" ] && break; done
  [ "$r" = "$1" ] || { echo "unknown repository '$1' (configured: ${REPOS[*]})" >&2; return 1; }
  export REPO="$1" KOPIA_CONFIG_PATH="$KOPIA_ETC/$1.config"
  case $1 in
    b2)    export KOPIA_CACHE_DIRECTORY="$CACHE_DIR" ;;
    local) export KOPIA_CACHE_DIRECTORY="$CACHE_DIR/local"
           # kopia masks its --file-mode and --dir-mode with the umask, so 0660 would land as 0640
           # and the hosts sharing the disk could not write each other's blobs.
           [ -z "${LOCAL_GROUP:-}" ] || umask 0007
           # An unmounted disk is the dangerous case: kopia would happily make a second repository
           # on the root filesystem. Over SFTP it cannot, and its own error names the host, so the
           # guard applies to an attached disk only.
           [ -n "${LOCAL_HOST:-}" ] ||
             mountpoint -q "$(dirname "$LOCAL_REPO")" || { echo "$(dirname "$LOCAL_REPO") is not a mountpoint; local repository $LOCAL_REPO unavailable" >&2; return 1; } ;;
  esac
}

for_each_repo() { # run "$@" once per repository with repo_env applied. Never skips one: runs all, then fails if any failed.
  local name rc failed=() opts=$-
  for name in "${REPOS[@]}"; do
    echo "== $name"
    set +e; ( set -e; repo_env "$name"; "$@" ); rc=$?; [[ $opts == *e* ]] && set -e
    [ "$rc" -eq 0 ] || failed+=("$name")
  done
  [ ${#failed[@]} -eq 0 ] || { echo "FAILED: ${failed[*]}" >&2; return 1; }
}

repo_env "${REPO:-b2}"
