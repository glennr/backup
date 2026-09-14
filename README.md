# backup

Kopia backups for a Linux fleet. Hosts share an encrypted Backblaze B2 repository; this
repository supplies the installer, configuration, policies, and systemd units.

## Install or update a host

```sh
git clone https://github.com/glennr/backup ~/src/glennr/backup
cd ~/src/glennr/backup
sudo make
```

`sudo make` installs dependencies, copies this checkout to `/opt/backup`, obtains missing
secrets, connects to the repository, imports policies, enables timers, and starts a snapshot.
Review changes before running it: the installed copy runs as root.

Secrets are stored only on the host in `/etc/kopia/`: `password`, `b2-key-id`, and `b2-key`.
The B2 master key is used only to create a per-host application key (`sudo make key`).

## Common commands

```sh
sudo make status                 # timers, snapshots, maintenance owner
sudo make snapshot               # snapshot now, foreground
sudo make start                  # snapshot now, via systemd
sudo make progress               # the running snapshot's counters and ETA
sudo make check                  # freshness/history check (maintenance owner)
sudo make retention              # repository object-lock settings
sudo kb snapshot list -a         # all hosts
sudo kb restore <id> /tmp/restore
sudo make ui                     # temporary UI on localhost
```

`kb` runs Kopia with this host's configuration and secrets. `make log` follows the snapshot
journal. Use `git pull && sudo make` to update another host.

## Configuration

`config/default.conf` defines shared non-secret settings. An optional
`config/hosts/<hostname>.conf` overrides it. `SOURCES` in a host file replaces the default;
use `SOURCES+=(...)` to add a source.

Policies are imported into the shared repository, first from `policies/global.json` and then
from an optional host file. Do not use Kopia's `--delete-other-policies`: it would remove
policies belonging to other hosts. See [policies/README.md](policies/README.md).

## Local repository

`LOCAL_REPO` in a host config names a directory on a local disk (its parent must be a
mountpoint) that holds a second repository, used for fast restores and OS migrations. It is
independent of the B2 connection: same password, same sources, same policies, its own config
file (`/etc/kopia/local.config`) and cache. Nothing schedules it; run it by hand.

```sh
sudo make local-create        # new repository at LOCAL_REPO, policies imported
sudo make local-connect       # join an existing one (after a reinstall, or from another OS)
sudo make local-snapshot      # snapshot SOURCES into it, foreground
sudo make local-verify        # read back every file
sudo make local-restore-test  # restore newest /etc snapshot to a temp dir, diff against live (DIR=/home/x for another)
sudo make local-status
sudo KOPIA_CONFIG_PATH=/etc/kopia/local.config kb snapshot list   # any other kopia command against it
```

Restoring onto a fresh OS: install `kopia`, `jq` and `rsync`, mount the disk at the same path,
clone this repo, write the password to `/etc/kopia/password` (`sudo make password`), then
`sudo make install local-connect` and `sudo KOPIA_CONFIG_PATH=/etc/kopia/local.config kb restore
root@<host>:/home/<user> /home/<user>.restored`. Without this tooling,
`kopia repository connect filesystem --path <LOCAL_REPO>` and `kopia restore` do the same.

## Safety boundaries

- The B2 bucket must have Object Lock enabled before the repository is created. Retention
  settings are fixed at creation; changes affect future objects only.
- A shared repository means root on any host with its credentials can read every host backup.
- Object lock delays deletion; it is not an alerting mechanism. The maintenance owner runs the
  daily freshness and snapshot-count check.
- `make uninstall` deliberately preserves `/etc/kopia`, cache, logs, and repository data.

## Development

Run `make audit` after changing ignore rules (what they keep and drop per top-level entry of a
home, no root, throwaway repository) and `make lint` before committing; `make hooks` installs the same secret check as a pre-commit
hook. Syntax checks are `bash -n bin/*` and `systemd-analyze verify systemd/*.service`.
