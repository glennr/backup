# mia: Ubuntu -> Omarchy migration, step 1: local kopia repository on the Samsung

Status: Part A (repo changes) done and committed on `local-repo` (session 2, 2026-09-14),
exercised against a fake kopia; not yet installed with `sudo make install`. Parts B and C are
Glenn's to run. Two deviations from Part A as written: no `RequiresMountsFor` (a dependency
failure would not trigger OnFailure, so a missing disk would go unnotified; instead `repo_env`
checks the mountpoint and every command fails loudly), and `ReadWritePaths=-/mnt/kopia` (the
`-` makes systemd ignore it when absent).

## Context

`mia` (Ubuntu 24.04) backs up `/home`, `/etc`, `/srv` hourly to the shared B2 repo via this
repo's tooling (`/opt/backup`, `sudo make ...`). Glenn is moving to Omarchy (Arch) in stages:

1. Confirm B2 backups are complete. Verified 2026-09-14: 10:03 AEST hourly run succeeded for all
   three sources, timers active. Glenn ran `sudo make install && sudo make status` locally.
2. Wipe the unused Windows disk (Samsung 980 PRO) into: unallocated space for an Omarchy
   "free space install" (test-drive, dual boot with Ubuntu) + one ext4 partition holding a
   **second kopia repository**, fed by the same jobs as B2.
3. Prove the local repo works (100% verify + restore-and-diff) before touching the installer.
4. Later, out of scope here: install Omarchy in the free space, boot it, restore `/home` from
   the local repo; when happy, wipe the WD (Ubuntu) and install Omarchy there, restoring again.
   The Samsung repo stays as a permanent second target.

Decisions made with Glenn:
- Same policy rules for both repos (`policies/global.json` + `hosts/mia.json`).
- **Two independent repositories, not a mirror.** No `sync-to`. Host -> kopia -> B2 and
  host -> kopia -> local, both written by every job.
- **No make arguments** (`REPO=` style rejected) and **no parallel `local-*` targets**. The
  existing targets/scripts loop over configured repositories.
- **Never skip; fail.** A configured repository that is unreachable (B2 offline, local disk
  unmounted) fails the unit and triggers the notification. Remove the `online` ExecCondition.
- Sequential, not concurrent, snapshot runs per repo (same disk reads, clean logs). Easy to
  change to `&`/`wait` later if wanted.
- One timer per job as now; each job handles both repos. No new timers.
- No dedicated `/home` partition on the WD later (Omarchy wants LUKS+btrfs with `@home`
  subvolume; B2 + local repo already cover reinstall).

Facts:
- kopia has no multi-repository fan-out: one process, one config file, one repository.
  Two repos = two `snapshot create` runs; source tree is read twice.
- Disks: Samsung 980 PRO 1TB = `/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNS0WB47833B`
  (16M MSR + 931G NTFS, nothing mounted). WD SN850X = Ubuntu (ESP, /boot, LUKS+LVM root, 543G
  used; `/home/g` 412G on disk). Address the Samsung **by-id**; NVMe numbering can swap.
- Windows Boot Manager EFI entry `Boot0000` and `/boot/efi/EFI/Microsoft` live on the Ubuntu
  ESP; remove after the wipe.
- Omarchy installer: "free space install" into unallocated space; LUKS; btrfs `@ @home @log
  @pkg`; FAT32 `/boot` (be generous); Limine; Secure Boot off.
- `bin/env.sh` honours a pre-set `KOPIA_CONFIG_PATH`. Makefile targets run `$(PREFIX)/bin/*`
  (`/opt/backup`), so `sudo make install` must follow edits.
- Root access: this Bash tool has no tty, so `sudo` cannot prompt; Glenn declined an askpass
  helper. Glenn runs root commands himself; hand him batches and ask for pasted output.

## Part A: repo changes (branch `local-repo`, rework of b1f248f)

### `config`
- `default.conf`: `LOCAL_REPO=` (empty = B2 only) with a comment. `hosts/mia.conf`:
  `LOCAL_REPO=/mnt/kopia/repo`.

### `bin/env.sh`
- `REPOS=(b2)`; append `local` when `LOCAL_REPO` is non-empty.
- `REPO="${REPO:-b2}"` selects the current repo for single-repo commands (`kb`).
- `repo_env <name>` sets `KOPIA_CONFIG_PATH=$KOPIA_ETC/<name>.config` and cache dir
  (`$CACHE_DIR` for b2 to keep the existing connection; `$CACHE_DIR/<name>` otherwise).
- `for_each_repo <cmd...>` runs cmd once per repo with `repo_env` applied, printing
  `== <name>` headers, collecting failures, exiting non-zero if any failed (never skips).

### `bin/install`
- One-time migration: `mv /etc/kopia/repository.config /etc/kopia/b2.config` if the old name
  exists and the new does not.

### `bin/connect`
- Loops repos. b2: existing s3 path unchanged (create prompt, object lock, maintenance
  extend-object-locks). local: requires `mountpoint -q "$(dirname "$LOCAL_REPO")"` else fail;
  `kopia repository connect filesystem --path=$LOCAL_REPO` with the same
  `--override-hostname/--override-username=root/--no-persist-credentials/--cache-directory`
  flags; on "repository not initialized"/missing, confirm (or `KOPIA_CREATE=yes`) then
  `repository create filesystem ... --encryption=AES256-GCM-HMAC-SHA256`; then `install -d -m 700`
  first. `repository status` per repo.

### `bin/job`
- Drop the `online` subcommand.
- `snapshot`: for each repo, `kopia snapshot create SOURCES` (foreground exec path becomes a loop;
  progress-file path likewise, prefix the progress file's source line with the repo name).
- `verify`: for each repo, `snapshot verify --verify-files-percent=$VERIFY_PERCENT`.
- Lock unchanged (one job at a time).

### `bin/check`
- Loops repos. For each: owner check (local repo: this host always owns), freshness per host,
  shrink check with state file `snapshot-count.<repo>`.

### `bin/kb`
- Applies `repo_env "$REPO"` then execs kopia. Usage: `sudo kb ...` (b2), `sudo REPO=local kb ...`.

### `systemd/*.service`
- Remove the `ExecCondition=/opt/backup/bin/job online` line from snapshot, verify, check.
- snapshot + verify + check units: add `ReadWritePaths=/mnt/kopia` (needed under
  `ProtectSystem=strict`; harmless if absent). Consider a `RequiresMountsFor=/mnt/kopia` in the
  snapshot unit so a missing disk fails fast with a clear reason.

### `Makefile`
- `policy`: loop repos (import global, host, src cap, show global) via `for_each_repo`; simplest
  is to move the body into a `bin/policy` script and call it.
- `status`, `retention`, `disconnect`: loop repos.
- New `restore-test` target (`DIR` default `/etc`): for each repo, restore newest
  `root@$(HOST):$DIR` to a `mktemp -d /var/tmp/...`, `diff -rq` against live, print count, clean up.
- Remove the six `local-*` targets and `bin/local`. Keep the `^[a-z-]+:` help regex fix and
  the wider help column.
- `ui`: unchanged (b2); document `REPO=local make ui` works because env.sh reads REPO.

### `README.md`
- Replace the "Local repository" section: what `LOCAL_REPO` does, that every job writes both
  repos and fails if either is unavailable, `sudo REPO=local kb ...`, `restore-test`, and the
  fresh-OS restore recipe (`pacman -S kopia jq rsync`, mount `LABEL=kopia` at `/mnt/kopia`,
  clone, `sudo make password`, `sudo make install connect`, `sudo REPO=local kb restore
  root@mia:/home/g /home/g.restored`; or plain `kopia repository connect filesystem --path`).

### Checks
`bash -n bin/*`, `systemd-analyze verify systemd/*.service`, `make lint`, `make help`.
Then Glenn runs `sudo make install && sudo make connect && sudo make status` (b2 still fine,
local fails cleanly with "not a mountpoint" until Part B). Commit.

## Part B: disk (Glenn runs; show him device identity first)

`D=/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNS0WB47833B`
0. `lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL,SERIAL "$D"`; confirm serial
   `S5GXNS0WB47833B`, 16M + NTFS, nothing mounted. `sudo make status`: B2 snapshots < 1h old.
1. `sudo wipefs -a "$D"-part2 "$D"-part1 "$D"; sudo sgdisk --zap-all "$D"`
2. `sudo sgdisk -n 1:0:+500GiB -t 1:8300 -c 1:kopia "$D"`; rest (~431 GiB) left unallocated for
   Omarchy. Size rule: grow if `sudo kb snapshot list` shows `/home` > ~330 GiB; keep >= 200 GiB
   free for Omarchy. (Glenn has not yet pasted the size; 500 GiB is the default.)
3. `sudo partprobe "$D"; sudo mkfs.ext4 -L kopia -m 0 "$D"-part1`
4. fstab: `LABEL=kopia /mnt/kopia ext4 defaults,noatime,nofail,x-systemd.device-timeout=10 0 2`;
   `sudo mkdir -p /mnt/kopia && sudo systemctl daemon-reload && sudo mount /mnt/kopia`.
5. `sudo efibootmgr -b 0000 -B; sudo rm -r /boot/efi/EFI/Microsoft`. Leave `BOOT`, `ubuntu`,
   `systemd`, `Recovery-*`.

## Part C: create, snapshot, prove (Glenn runs)

1. `sudo make connect` -> creates the local repo (confirm prompt), status shows filesystem
   backend at `/mnt/kopia/repo`, cache `/var/cache/kopia/local`. `sudo make policy`.
2. `sudo make snapshot` -> b2 (incremental, fast) then local (full read, tens of minutes).
   Six "Created snapshot" lines, no failures.
3. `sudo make status` -> both repos list three sources; local sizes/file counts match b2.
4. `sudo REPO=local kb snapshot verify --verify-files-percent=100` -> 0 errors.
   (`make verify` does 5% on both; the 100% local read is a one-off.)
5. `sudo make restore-test` (default /etc), then `DIR=/home/g/src/glennr/backup`, then a larger
   home dir -> 0 differences except files changed since the snapshot.
6. `df -h /mnt/kopia`. Wait for one timer-driven hourly run and check `make status` shows both.
7. Save/update the project memory (migration state, disk roles).

## Verification
- Static: `bash -n`, `systemd-analyze verify`, `make lint`, `make help` lists `restore-test`.
- B2 path unchanged: `sudo make status` works before Part B with local reported as failing
  loudly, not skipped.
- After Part C: hourly unit succeeds writing both repos; `local` 100% verify 0 errors;
  `restore-test` 0 diffs; `efibootmgr` has no Windows entry; `findmnt /mnt/kopia` ext4.

## Out of scope, next after this
- Omarchy install: boot USB (first in BootOrder), Secure Boot off, pick Samsung, **Free space
  install**. Choose OS via firmware boot menu, or add Ubuntu chainload (`\EFI\ubuntu\shimx64.efi`
  on the WD ESP) to Limine.
- Restore on Arch into `/home/g.restored` (not over Omarchy dotfiles), move selectively;
  `/srv/minecraft` into `/srv`; `/etc` as reference only.
- Before wiping the WD later: `sudo make snapshot` one last time (writes both repos).
