# Policies

`global.json` sets retention, compression, and filesystem rules for every host.
`hosts/<hostname>.json` can override a host or source policy. A source-specific `files.ignore`
replaces, rather than extends, the global ignore list.

Retention keeps 10 latest, 24 hourly, 30 daily, 8 weekly, and 1,200 monthly snapshots.
Scheduling is manual because systemd runs snapshots.

The global policy excludes caches, build output, dependency directories, package and disk-image
files, downloads, and selected application data. It includes dot-directories by default.
Rules beginning with `/` are relative to the configured source root; unanchored rules apply at
any depth. `oneFileSystem` prevents mounted filesystems below a source from being included.

Files over `SRC_CAP` are excluded only below each `/home/*/src`; `make policy` applies that
per-path rule. Review the effective selection with `sudo kb snapshot estimate <source>` before
changing ignore rules.

`hosts/mia.json` has a standalone `/srv` rule set for Minecraft. It keeps worlds and required
configuration while excluding downloaded server files, logs, caches, and RCON credentials.
