# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

BIND for `kcarterlabs.tech` on every host in `[dns]`: bind-a (10.10.69.26,
pve5), bind-b (.27, pve4) and, until it's retired, networkdocker (.21, on the
seasonal 5700G). Each is an identical server from the same records.yaml, no
zone transfers: authoritative for the zone, forwarding everything else to
the Pi-holes. GitHub Actions builds the image and pushes it to ECR, and
Ansible deploys it. `PLAN.md` is the migration onto the minis and its
cutover steps.

The flow is push to main → CI (validate, build, push `code-<hash>`) → `make
deploy` (this machine pulls that tag and copies it to each server lacking it,
mounts records.yaml, reloads) → verify, one server at a time. Breaking this
breaks DNS for the whole LAN, so run `make test` and `make test-playbook`
after any change to the image or the role. Neither touches the servers. The
user runs everything against the real hosts and creates the VMs; read-only
discovery is fine.

## Commands

```bash
make lint           # records.yaml only
make validate       # what CI runs: lint, ansible syntax, compose render, image build, named-checkzone/-checkconf
make test           # local container: every record, live reload, bad edit refused, crash recovery
make test-playbook  # real playbook vs a DinD copy of networkdocker's pre-Ansible state, registry standing in for ECR
make release [MSG=..] [YES=1]   # validate, commit, push, watch CI, check, deploy (scripts/release.sh)
make check / deploy [FORCE=1] [LIMIT=bind-a] / verify / ps / logs
make image-tag / ecr-images / ecr-policy
make test-pihole / pihole-check / pihole-deploy [LIMIT=pihole2] / pihole-verify / pihole-upgrade-check / pihole-upgrade
```

## Architecture

**One records.yaml, three consumers:**

- the Ansible deploy mounts it
- the CI image bakes it in (the Dockerfile copies it)
- the Helm chart has its own stale copy in `bind-flask/values.yaml`

`zone_converter.py` turns it into a zone file in all three. `serial: auto`
is Unix time at generation.

**The image's config-directory mode.** With `BIND_CONFIG_DIR` set (the
deploy uses `/etc/bind/managed`), `entrypoint.sh` symlinks
`named.conf.options` and `named.conf.local` from there and reads
`records.yaml` there. The deploy mounts the *directory* read-only. Mounting a
single file would freeze it at the old inode once Ansible's copy (or `sed -i`)
replaces it by rename. That is also why the watcher uses inotify on the
directory, for `moved_to` events. The original per-file watch never fired.

**`bind-reload`** regenerates the zone to a temp file and runs
`named-checkzone` and `named-checkconf`; only if both pass does it move the
file into place and `rndc reload`. The entrypoint calls it with `--no-rndc`
before starting named, the watcher calls it on changes, and the Ansible
handler calls it via `docker exec`. A failure leaves the old zone serving,
and its non-zero exit fails the handler. named is the container's main
process (`wait $NAMED_PID`), so its death exits the container.

**Image tags.** `scripts/image-tag.sh` hashes only the image's code
(Dockerfile, entrypoint.sh, bind-reload.sh, zone_converter.py). CI pushes
every build as `<sha>`, `code-<hash>` and `latest`; the deploy pulls
`code-<hash>` for the local checkout. Records-only commits therefore keep the
tag: no pull, no recreate, only the reload handler. Don't add records.yaml or
the named.conf files to the hash. Both sides must call the same script.

**`bind.yml` is `serial: 1` with `any_errors_fatal`.** Each server is
deployed and verified before the next starts; a failure leaves the rest
untouched. The role runs: preflight (`always`), `docker_host` (where
`bind_manage_docker`), `resolved.yml` (where `bind_manage_resolved`: stub
listener off, `/etc/resolv.conf` off the stub file only if it's the stock
symlink), deploy, verify. networkdocker turns both off in its host_vars.

**The image moves from here.** The controller logs in to ECR, pulls, saves
once to `.render/images/`, and copies and `docker load`s it only on a
server that lacks the tag. The servers hold no AWS credentials.

**The deploy gate** (preflight, on the controller):

- lint
- deployed files committed and pushed (`git status`, `origin/main..HEAD`)
- the tag exists in ECR (`aws ecr describe-images`)

`FORCE=1` skips the git half. Preflight also asks each forwarder in
`named.conf.options` from each server (`scripts/dns-ask.py`, stdlib only):
a dead one warns, none answering fails.

**Cutover** (`tasks/cutover.yml`, stays in the role, a no-op once done):

1. remove kenny's two legacy cron jobs, filtering the crontab and keeping
   other lines
2. remove `bind-flask` (only if it has no compose label)
3. `compose up`

The order is load-bearing: `monitor.sh` would redeploy `bind-flask` within
a minute.

## Constraints that bite

- **ECR expiry.** The ECR repo's original lifecycle policy expires images 3
  days after push. Until `make ecr-policy` is applied, a deploy more than 3
  days after the last code change finds nothing to pull. The ECR preflight
  says so.
- **The Pi-holes don't answer this laptop's network** (192.168.10.x). Tests
  skip the recursion check (`bind_verify_recursion=false`, or
  `--no-recursion-check` in test-local when a forwarder doesn't answer).
  The real deploy always checks it.
- **Boolean flags.** `-e flag=false` is the string "false", which is truthy.
  Every flag in a `when:` has `| bool`; keep it that way.
- **Ansible prints skipped task headers.** test-playbook sets
  `ANSIBLE_DISPLAY_SKIPPED_HOSTS=false` so that `grep 'TASK [bind : Pull it]'`
  means the task ran.
- **SSH is as `svc-observability`** (created by `~/Code/grafana`'s
  bootstrap), except networkdocker: `kenny`, set in its host_vars, because
  it isn't in the fleet.
- **Cutover vars are networkdocker's only.** The role defaults are empty
  lists, which skip `tasks/cutover.yml` everywhere else.
- **NS records** come from `soa.nameservers` (default `[primary_ns]`);
  the old image ignores the key, so records.yaml stays compatible.
- **Regexes in folded (`>-`) Jinja take single backslashes** (`\s`, not
  `\\s`): Ansible doesn't unescape them there.
- networkdocker also runs the dinner-menu stack (traefik on 80/443, mongo,
  api, vue), from the same ECR registry. The image prune filters by this
  repository only. Never touch those containers.
- systemd-resolved runs with `DNSStubListener=no`. Preflight fails if
  anything but Docker holds port 53.

## The Pi-holes (`pihole.yml`)

A second, independent playbook for `[pihole]` (pihole2/3/4, native Pi-hole
v6), from `group_vars/pihole.yml`. Every step runs `scripts/pihole-sync.py`
on the host through the script module (`plan`, `apply`, `verify`), with the
desired state as base64 JSON on its command line.

- **Settings:** only the listed `pihole.toml` keys. Read with `tomllib`, and
  written with `pihole-FTL --config KEY VALUE` (arrays as JSON). A key the
  host's FTL doesn't know fails `plan`, so nothing changes. Key names differ
  between FTL versions (`dns.domain` vs `dns.domain.name`), so manage only
  keys that exist in every version on the LAN.
- **Lists:** `adlist` (type 0 only) and `domainlist` in `gravity.db` are the
  whole set, with rows added, enabled or deleted directly. Blocklists changed
  → `pihole -g`. Only domains changed → `pihole reloadlists`.
- **Plan under `--check`:** the "Say what would change" debug task reports
  `changed` in check mode only, so `make pihole-check` counts drift and a
  real run stays changed=0 when nothing differs.
- **Verify is on the host, against 127.0.0.1:** `listeningMode: LOCAL`
  ignores this laptop's subnet. It skips hosts-file boilerplate (localhost,
  broadcasthost) when it picks a gravity domain.
- **`make test-pihole`** runs `pihole/pihole:2025.06.2` (FTL 6.2.3) and
  `2026.10.0` (6.8), Alpine, with `apk add python3`. Never open
  `gravity.db` before the image's first gravity run: sqlite creates it empty,
  and start.sh then skips building it.
- **`pihole-upgrade.yml`** (`pihole_upgrade` role, then `pihole`) reads
  `/etc/pihole/versions` (installed and `GITHUB_*` latest, from Pi-hole's
  daily updatechecker). Never `pihole -up --check-only`: it reinstalls the
  dependency package before checking. Before `pihole -up`, it asks the other
  Pi-holes from this host over the LAN (`pihole-sync.py ask`, at
  `pihole_address`, which lives in group_vars so every host can read every
  other's) and refuses if none answer. Not `delegate_to`: an unreachable
  delegated item ends the play even with `ignore_unreachable`. The test
  can't run a real `pihole -up` (the image doesn't upgrade itself), so it
  stands in a wrapper that sets installed = latest. The real upgrade path is
  only exercised on the VMs.
- **`make release` runs `git add -A`**, so Pi-hole changes ride along with
  whatever records change is being released.

## Not in git

`.render/` (validate output, test scratch, saved images). Nothing secret
lives in this repo; ECR access is this machine's AWS credentials.
