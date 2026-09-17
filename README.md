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

`kb` runs Kopia with this host's configuration and secrets against the B2 repository
(`REPO=local` for the local one, below). `make log` follows the snapshot journal. Use `git pull && sudo make` to update another host.

## Configuration

`config/default.conf` defines shared non-secret settings. An optional
`config/hosts/<hostname>.conf` overrides it. `SOURCES` in a host file replaces the default;
use `SOURCES+=(...)` to add a source.

`RETIRED_HOSTS` lists hosts that have been decommissioned. Their snapshots stay in the
repository and stay restorable, and they still count toward `make check`'s shrink guard; only
the freshness check skips them, so a retired host does not fail the daily check forever.

Policies are imported into the shared repository, first from `policies/global.json` and then
from an optional host file. Do not use Kopia's `--delete-other-policies`: it would remove
policies belonging to other hosts. See [policies/README.md](policies/README.md).

## Local repository

`LOCAL_REPO` in a host config names a directory on a local disk (its parent must be a mountpoint,
unless `LOCAL_HOST` puts the disk on another host, below) that holds a second, independent
repository: same password, same sources, same policies, its own config file
(`/etc/kopia/local.config`) and cache. It is not a mirror of B2.
Every job writes or reads both repositories in turn, local first because it is faster, and fails, with the usual
notification, if either is unavailable: nothing is skipped because a disk is unmounted or B2
is unreachable. `sudo make connect` offers to create it, `make status`, `make check` and
`make verify` cover it, and `REPO=local` points single-repository commands at it:

```sh
sudo REPO=local kb snapshot list                          # any kopia command against it
sudo REPO=local kb snapshot verify --verify-files-percent=100
sudo REPO=local make ui
sudo make restore-test                                    # restore newest /etc from each repository, diff against live
sudo DIR=/home/x make restore-test
```

Restoring onto a fresh OS (Arch: `pacman -S kopia jq rsync`): mount the disk at the same path
(`LABEL=kopia` on `/mnt/kopia`), clone this repo, `sudo make password`, then
`sudo make install connect` and
`sudo REPO=local kb restore root@<host>:/home/<user> /home/<user>.restored`. Without this
tooling, `kopia repository connect filesystem --path <LOCAL_REPO>` and `kopia restore` do the
same.

### Reaching it from another host

A host without the disk attached reaches the same repository over SFTP, so both hosts snapshot
into it. The disk's host exports it through SSH. The other host sets `LOCAL_HOST` and connects
with kopia's SFTP backend. vega holds the disk today and broomhilda is the client.

On the host with the disk, set `LOCAL_GROUP` in its host config and create the export. kopia
masks its file modes with the umask, so `bin/env.sh` sets `umask 0007` whenever `LOCAL_GROUP` is
set; without it the other host cannot read a blob this one wrote.

```sh
groupadd -r kopia-repo
useradd -r -g kopia-repo -d / -s /usr/bin/nologin kopia-sftp
install -d -m 700 /etc/ssh/authorized_keys.d
chown -R root:kopia-repo /mnt/kopia/repo                    # one time, over the whole repository
find /mnt/kopia/repo -type d -exec chmod 2770 {} +
find /mnt/kopia/repo -type f -exec chmod 660 {} +
chmod 700 /mnt/kopia/wd                                     # anything else on the disk is inside the chroot
```

`/etc/ssh/sshd_config.d/50-kopia.conf` chroots the account to the mountpoint, so the repository
path the client asks for is `/repo`, not `/mnt/kopia/repo`. The chroot directory must be
root-owned and not group-writable, which is why it is `/mnt/kopia` and not the repository itself.

```
ListenAddress 10.10.20.10
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers kopia-sftp
Match User kopia-sftp
    AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
    ChrootDirectory /mnt/kopia
    ForceCommand internal-sftp -u 0007
    AllowAgentForwarding no
    AllowTcpForwarding no
    PermitTunnel no
    X11Forwarding no
```

`AllowUsers kopia-sftp` refuses every other SSH login. Add your own account to that line if you
want a shell on this host. Then `sshd -t`, `systemctl enable --now sshd`, and allow the client
through the firewall: `ufw allow from <client address> to any port 22 proto tcp`.

On the client, mint a key for the backup jobs and pin the server's host key. Read the server's
own fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and compare it against
the scan before you keep the file.

```sh
ssh-keygen -t ed25519 -N '' -C 'kopia backup <client>' -f /etc/kopia/ssh-key
chmod 600 /etc/kopia/ssh-key
ssh-keyscan -t ed25519 vega.local > /etc/kopia/known-hosts
ssh-keygen -lf /etc/kopia/known-hosts                       # must match the server's fingerprint
```

Append `/etc/kopia/ssh-key.pub` to `/etc/ssh/authorized_keys.d/kopia-sftp` on the server, set
`LOCAL_REPO`, `LOCAL_HOST` and `LOCAL_USER` in the client's host config, then `sudo make connect`
and `sudo make snapshot`. `sudo REPO=local kb snapshot list -a` is the test that matters: it
fails if the client cannot read a blob the server wrote.

The client never creates this repository. A connect failure and an empty path look the same over
a network, and a second repository created over the top orphans every snapshot in the first.

## Safety boundaries

- The B2 bucket must have Object Lock enabled before the repository is created. Retention
  settings are fixed at creation; changes affect future objects only.
- A shared repository means root on any host with its credentials can read every host backup.
- A host that reaches the local repository over SFTP can also delete blobs in it. The local
  repository has no object lock. B2 object lock is the defense against a compromised host.
- Object lock delays deletion; it is not an alerting mechanism. The maintenance owner runs the
  daily freshness and snapshot-count check.
- `make uninstall` deliberately preserves `/etc/kopia`, cache, logs, and repository data.

## Development

Run `make test` after changing anything under `bin/` (repository selection, backends and guards
against a fake kopia, no root, no repository touched), `make audit` after changing ignore rules
(what they keep and drop per top-level entry of a home, no root, throwaway repository), and
`make lint` before committing. `make hooks` installs the same secret check as a pre-commit
hook. `make test` already runs `bash -n`. `systemd-analyze verify systemd/*.service` covers the units.
