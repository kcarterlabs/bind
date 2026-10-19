# BIND DNS for kcarterlabs.tech

The LAN's DNS server: authoritative for `kcarterlabs.tech`, recursing to the
Pi-holes (10.10.69.22, 10.10.69.23) for everything else. It runs as a
container on **networkdocker (10.10.69.21)**, which is `ns1` and the address
the grafana repo's DNS probes query.

```
records.yaml ──push to main──▶ GitHub Actions: validate ─▶ build ─▶ ECR  kcarterlabs/bind:<sha>, code-<hash>, latest
     │                                                                  │
     └──── make deploy (Ansible) ── ships records.yaml + named.conf ──▶ networkdocker /opt/bind
                                    pulls code-<hash> from ECR ◀──────────┘   container `bind`, port 53
```

- **`records.yaml`** is the zone, and the only place records live. Every
  host, VM and app in `~/Code` has a name: `immich`, `homarr`, `freshrss`,
  `searxng`, the `*arr`s, `grafana`/`mother-brain`/`grafana-2`, `qbittorrent`
  and so on. An A record names the host, so apps still need their port
  (`http://immich.kcarterlabs.tech:2283`) until Traefik is in front.
- **CI** runs the same `make validate` on every push and pull request, and
  on main builds the image and pushes it to ECR.
- **Ansible** deploys only what is committed and pushed: it pulls the image
  CI built for this code and mounts the records and config from this checkout.

## Changing records

```bash
$EDITOR records.yaml
make release MSG="dns: add foo"
```

`make release` (`scripts/release.sh`) is the whole loop, stopping at the
first thing that fails:

1. refuses unless on `main` and not behind `origin/main`
2. `make validate`, so a change CI would reject never gets pushed
3. shows what changed, asks, commits (`MSG=`) and pushes. Skipped when
   there's nothing to commit or push, so re-running after a failure picks
   up where it stopped.
4. finds the CI run for that exact commit and watches it until it pushes
   the image to ECR. A failed run stops here.
5. checks ECR has `code-<hash>`
6. `make check`, then asks before `make deploy` (which ends by digging every
   record from this machine)

`YES=1` answers yes to both questions (it then needs `MSG=` if there is
anything to commit). The same steps by hand:

```bash
make lint && git commit -am "dns: add foo" && git push
gh run watch             # CI: validate, build, push to ECR (~1 min)
make check && make deploy
```

A records-only change is a reload, not a restart: queries keep being answered
throughout. `serial: auto` bumps the SOA serial for you. A records.yaml that
fails the lint stops the deploy before the server is touched; one that gets
past it but fails `named-checkzone` on the server is refused, and the
previous zone keeps serving.

A change to the image (`Dockerfile`, `entrypoint.sh`, `bind-reload.sh`,
`zone_converter.py`) gets a new `code-<hash>` tag. The deploy pulls it and
recreates the container, a second or two without DNS.

## Make targets

| Target | What it does |
|---|---|
| `make lint` | `scripts/check-records.py`: invalid names or IPs, duplicates, a CNAME sharing its name |
| `make validate` | lint, Ansible syntax, render compose, build the image, `named-checkzone` + `named-checkconf` inside it. What CI runs. |
| `make test` | The image on 127.0.0.1:15353 as the deploy runs it: every record, an edit picked up live, a broken edit refused, recovery after named crashes |
| `make test-playbook` | The real playbook against a Docker-in-Docker copy of networkdocker as it is today (`bind-flask`, the old cron jobs): cutover, `changed=0` on re-run, reload vs recreate, failed pulls, the push gate |
| `make check` | Dry run against the server: preflight plus a diff of every file |
| `make release` | Validate, commit (`MSG=`), push, watch CI push to ECR, check, deploy. `YES=1` skips the prompts |
| `make deploy` | Deploy and verify. `FORCE=1` skips the committed-and-pushed check (emergencies) |
| `make verify` | Ask the server for every record in records.yaml, from this machine |
| `make ps` / `make logs` | Container status / recent logs on the server |
| `make image-tag` / `make ecr-images` | The tag this checkout deploys / what CI has pushed |
| `make ecr-policy` | Apply `ecr-lifecycle-policy.json` to the ECR repository (once) |

Needs: Ansible with `make deps`, Docker, `dig`, and AWS credentials for
account 856817629634 on this machine (the deploy checks ECR before touching
the server). The server logs in to ECR with its own `~/.aws` (IAM user
`bind-dns`).

## Before the first deploy

1. **`make ecr-policy`.** The ECR repository's current lifecycle policy
   expires every image 3 days after it is pushed. The repository was empty
   on 2026-10-18, and networkdocker was running the only copy of the image.
   The new policy keeps the last 30 images and drops untagged ones after a
   week.
2. Commit and push this overhaul, and wait for CI to push
   `code-<hash>` (`make image-tag`, `make ecr-images`).
3. `make check`, then `make deploy`.

The first deploy is the cutover from the hand-run setup in `~/bind` on the
server:

- removes the two cron jobs (`monitor.sh` every minute, `@reboot deploy.sh`).
  They go first: monitor.sh would otherwise "repair" the server by
  redeploying `bind-flask` within a minute.
- removes the `bind-flask` container and starts `bind` immediately after: a
  few seconds without DNS.
- leaves `~/bind` and `~/binddns` on the server alone. Delete them by hand
  when you're happy.

## What runs on the server

`/opt/bind/compose/compose.yaml`, project `bind`, container `bind`:

- the ECR image `kcarterlabs/bind:code-<hash>`
- `/opt/bind/config` (records.yaml, named.conf.options, named.conf.local)
  mounted read-only at `/etc/bind/managed`
- port 53 TCP and UDP on all addresses
- `restart: unless-stopped`. named is the container's main process, so if
  named dies, the container exits and Docker restarts it.
- a healthcheck (SOA query), and `/etc/cron.d/bind-healthcheck`, which
  restarts the container if the healthcheck fails (named hung). Together
  these replace monitor.sh.

## Kubernetes

`bind-flask/` is a Helm chart for the same image. Its `values.yaml` carries
its own copy of the records (older, without `dinner-menu` and the `~/Code`
apps): copy records.yaml in when you next use it.
