# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

BIND for `kcarterlabs.tech` on networkdocker (10.10.69.21, Ubuntu 24.04). It
is the LAN's DNS: authoritative for the zone, recursing to the Pi-holes for
everything else. GitHub Actions builds the image and pushes it to ECR, and
Ansible deploys it.

The flow is push to main → CI (validate, build, push `code-<hash>`) → `make
deploy` (pull that tag, mount records.yaml, reload) → verify. Breaking this
breaks DNS for the whole LAN, so run `make test` and `make test-playbook`
after any change to the image or the role. Neither touches the server.

## Commands

```bash
make lint           # records.yaml only
make validate       # what CI runs: lint, ansible syntax, compose render, image build, named-checkzone/-checkconf
make test           # local container: every record, live reload, bad edit refused, crash recovery
make test-playbook  # real playbook vs a DinD copy of networkdocker's pre-Ansible state, registry standing in for ECR
make release [MSG=..] [YES=1]   # validate, commit, push, watch CI, check, deploy (scripts/release.sh)
make check / deploy [FORCE=1] / verify / ps / logs
make image-tag / ecr-images / ecr-policy
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

**The deploy gate** (preflight, on the controller):

- lint
- deployed files committed and pushed (`git status`, `origin/main..HEAD`)
- the tag exists in ECR (`aws ecr describe-images`)

`FORCE=1` skips the git half. The server pulls with its own `~/.aws` as
`kenny`, not root: kenny is in the docker group, and images are
daemon-wide.

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
- **SSH is as `kenny`**, with passwordless sudo, not `svc-observability`:
  networkdocker isn't in `~/Code/grafana`'s fleet. Adding it there would
  create that account and install the fleet Alloy agent.
- networkdocker also runs the dinner-menu stack (traefik on 80/443, mongo,
  api, vue), from the same ECR registry. The image prune filters by this
  repository only. Never touch those containers.
- systemd-resolved runs with `DNSStubListener=no`. Preflight fails if
  anything but Docker holds port 53.

## Not in git

`.render/` (validate output and test scratch). Nothing secret lives in this
repo; the server's AWS credentials stay on the server.
