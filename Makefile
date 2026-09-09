# Kopia fleet backup. `sudo make` brings a machine up end to end; `make help` lists the parts.
SHELL  := /bin/bash
PREFIX := /opt/backup
ETC    := /etc/kopia
UNITS  := /etc/systemd/system
KB     := $(PREFIX)/bin/kb
HOST   ?= $(shell hostname -s | tr A-Z a-z)
SRC_CAP ?= 1073741824
TIMERS := kopia-snapshot.timer kopia-verify.timer kopia-check.timer

.PHONY: all help install secrets password key connect disconnect policy snapshot start log verify check schedule unschedule status retention ui audit lint hooks uninstall root

all: install secrets connect policy schedule start status ## (default) bring this machine up; prompts only for missing secrets; first snapshot runs in the background

help: ## list targets
	@grep -hE '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

install: root ## install dependencies, files, and systemd units
	bin/install

secrets: root ## repository password + this machine's B2 key into /etc/kopia, only the ones missing
	@test -s $(ETC)/password || $(MAKE) --no-print-directory password
	@test -s $(ETC)/b2-key || $(MAKE) --no-print-directory key

password: root ## (re)enter the repository password (KeePass); hidden, asked twice
	@. $(PREFIX)/bin/env.sh; read -rsp "repository password (KeePass): " a; echo; read -rsp "again: " b; echo; \
	[ -n "$$a" ] || { echo "empty; nothing written" >&2; exit 1; }; \
	[ "$$a" = "$$b" ] || { echo "passwords differ; nothing written" >&2; exit 1; }; \
	write_secret password "$$a"; echo "written to $(ETC)/password"

key: ## mint this machine's B2 key (needs the master key from KeePass) and reconnect. HOST=other prints one instead
	@$(PREFIX)/bin/b2-key.sh $(HOST)

connect: root ## connect to the repository; offers to create it if the bucket is empty
	$(PREFIX)/bin/connect

disconnect: root ## forget the repository connection (repo data untouched)
	$(KB) repository disconnect

policy: root ## import policies/global.json, then policies/hosts/$(HOST).json if present; cap file size under each /home/*/src
	$(KB) policy import --from-file $(PREFIX)/policies/global.json
	@if [ -f $(PREFIX)/policies/hosts/$(HOST).json ]; then $(KB) policy import --from-file $(PREFIX)/policies/hosts/$(HOST).json; fi
	@set -e; for d in /home/*/src; do \
	  if [ -d "$$d" ]; then $(KB) policy set "root@$(HOST):$$d" --max-file-size=$(SRC_CAP) >/dev/null; echo "max file size $(SRC_CAP) under $$d"; fi; \
	done
	$(KB) policy show --global

snapshot: root ## snapshot the configured SOURCES now, in the foreground
	$(PREFIX)/bin/job snapshot

start: root ## snapshot now via the timer's unit: background, sandboxed, journal, notifies on failure
	systemctl start --no-block kopia-snapshot.service

log: ## follow the snapshot unit's journal (U=kopia-check.service for another unit)
	journalctl -fu $(or $(U),kopia-snapshot.service)

verify: root ## read back a sample of file data and check it
	$(PREFIX)/bin/job verify

check: root ## freshness check: every host snapshotted recently, history not shrinking (owner only)
	$(PREFIX)/bin/check

schedule: root ## enable the timers: hourly snapshot, monthly verify, daily check
	systemctl enable --now $(TIMERS)
	systemctl list-timers 'kopia-*' --no-pager

unschedule: root ## disable the timers
	systemctl disable --now $(TIMERS)

status: root ## timers, running/last run, snapshots across all hosts, maintenance owner
	systemctl list-timers 'kopia-*' --all --no-pager
	@systemctl --no-pager --lines=0 status kopia-snapshot.service | sed -n '3p'
	@journalctl -u kopia-snapshot.service -n 10 --no-pager -o cat || true
	$(KB) snapshot list -a
	$(KB) maintenance info

retention: root ## object-lock settings: repo retention mode/period, lock extension, maintenance schedule
	@$(KB) repository status | grep -iE 'retention|storage type|bucket' || true
	@$(KB) maintenance info | grep -iE 'owner|object lock|full maintenance|next' || true

ui: root ## kopia web UI at http://127.0.0.1:51515, foreground, ctrl-c stops it. Localhost only.
	@pw=$$(openssl rand -hex 8); \
	echo; echo "  http://127.0.0.1:51515/?$$(date +%s)   login: kopia / $$pw"; \
	echo "  (401 in the UI = browser cached a previous run's page: hard-refresh, ctrl-shift-r)"; echo; \
	exec $(KB) server start --ui --insecure --address=http://127.0.0.1:51515 --refresh-interval=1m \
	  --server-username=kopia --server-password="$$pw" --ui-preferences-file=$(ETC)/ui-preferences.json

audit: ## what the rules keep and drop per top-level entry of a home (DIR=/home/x; default yours). No root, throwaway repo
	SRC_CAP=$(SRC_CAP) bin/audit $(DIR)

lint: ## fail if anything secret-shaped is staged in git
	bin/check-no-secrets.sh

hooks: ## install the secret check as a git pre-commit hook (only on machines you commit from)
	ln -sf ../../bin/check-no-secrets.sh .git/hooks/pre-commit

uninstall: root ## remove timers, units, /opt/backup and kb. Leaves /etc/kopia, cache, logs and repo data alone.
	-systemctl disable --now $(TIMERS)
	rm -f $(UNITS)/kopia-*.service $(UNITS)/kopia-*.timer /usr/local/bin/kb
	systemctl daemon-reload
	rm -rf $(PREFIX)

root:
	@test "$$(id -u)" = 0 || { echo "needs root: sudo make $(MAKECMDGOALS)" >&2; exit 1; }
