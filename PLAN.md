# Plan: DNS onto the Lenovo minis

**Status:** decisions confirmed 2026-10-19, code built and tested locally,
nothing deployed. All five new VMs created 2026-10-19 (stopped): bind-a 501
(pve5), bind-b 402 (pve4), pihole4 204 (pve2), traefik-a 401, traefik-b 203.
Addresses come from pfSense DHCP reservations, not static cloud-init. All
five are in `~/Code/grafana` `homelab.ini`.
**Why:** the HA plan (`~/Code/traefik/homelab-ha-infrastructure-plan.md`,
Phase 1) puts critical infrastructure on the three Lenovo minis only, so the
5700G (1u-pve-1) can be powered off for the summer. DNS is the last critical
piece still on it. Until it moves, the Traefik pair is only as available as
the 5700G, because every name resolves through networkdocker.

## Discovery (read-only, 2026-10-19)

| Finding | Consequence |
|---|---|
| networkdocker (10.10.69.21, VM 903) and **lan-cache** (10.10.69.19, VM 901) both run on **1u-pve-1, the 5700G**. | Two pieces of the DNS path are on the seasonal host, not one. |
| This laptop's DHCP (192.168.10.x) hands out **only 10.10.69.19**, lan-cache's `lancache-dns`. | Clients reach BIND *through* lan-cache. Moving BIND alone doesn't free them from the 5700G; DHCP has to change too (decision 4). |
| lan-cache's upstream is `UPSTREAM_DNS=10.10.69.21` in `/home/kenny/docker-compose/.env` on that VM, a clone of lancachenet/docker-compose, not in `~/Code`. | Edited by hand on the VM at step 7, until lan-cache gets its own repo. |
| The Pi-holes (v6.1.4 core, FTL v6.2.3; .22 on pve5, .23 on pve4) forward to 8.8.8.8/8.8.4.4. They have no conditional forwarding, `revServers = []`, and `listeningMode = "LOCAL"`. No repo manages them; `~/Code/grafana` only puts its agent on them. | No loop: BIND → Pi-hole → Google. The existing two don't change. LOCAL means they only answer their own subnet, so the BIND VMs must be on 10.10.69.0/24. A third is built by hand to match (decision 6). |
| pve2 has an old, stopped VM 101 `pihole` (2 GB, 32 GB on `PVE2-NVME`). Its record `pihole` → 10.10.69.72 doesn't answer. | Not reused: a fresh clone is cleaner. Delete it once pihole4 runs. |
| Nothing else in `~/Code` points at 10.10.69.21, apart from this repo and `~/Code/grafana`'s two `bind` blackbox probes (both stacks). | Grafana gets new probe targets. Static clients outside `~/Code` are unknown (see step 8). |
| networkdocker has no `tcpdump` or conntrack, and BIND's query logging is off. | Can't see networkdocker's clients without changing something. `rndc querylog on` at step 8 is how to find stragglers. |
| Free memory: **pve2 4 GB**, **pve5 4 GB** (Mother-Brain has 16 GB), pve4 23 GB. traefik-b will take 2 GB of pve2's. | 1 GB VMs fit. pve2 ends with about 1 GB spare. The HA doc's 4 GB K3s VMs won't fit on pve2 or pve5. That's for later. |
| Ubuntu 24.04 cloud-init templates: 920 on pve2, 904 on pve4, 905 on pve5. DHCP, user `kenny`. | Same procedure as the Traefik VMs. |
| 10.10.69.15–.18, .20, .26–.29, .33–.45 don't answer ping. .30–.32 are the Traefik pair's. | The addresses below. |

## Target

```
clients ──DHCP──▶ lan-cache .19 (5700G, seasonal)  ─┐
              ├─▶ bind-a 10.10.69.26 (pve5)  ◀──────┤ upstream: both
              └─▶ bind-b 10.10.69.27 (pve4)  ◀──────┘
                   │ authoritative kcarterlabs.tech, identical, from records.yaml
                   └─ forward only ─▶ pihole2 .22 (pve5), pihole3 .23 (pve4), pihole4 .28 (pve2) ─▶ 8.8.8.8
```

| | pve5 | pve4 | pve2 |
|---|---|---|---|
| Pi-hole | pihole2 .22 | pihole3 .23 | **pihole4 .28** (new) |
| BIND | **bind-a .26** (new) | **bind-b .27** (new) | |
| Traefik | | traefik-a .31 | traefik-b .32 |

With the 5700G off, clients still have bind-a and bind-b, and only Steam
cache steering is lost. Any one mini can go down: each BIND still has two
Pi-holes, and a BIND and a Traefik survive.

## Decisions (confirmed 2026-10-19)

1. **Addresses and placement:**
   - `bind-a` 10.10.69.26 on pve5 (template 905, `PVE5-NVME`). This is ns1.
   - `bind-b` 10.10.69.27 on pve4 (template 904, `PVE4-NVME`). This is ns2.
   - Both: 1 core, 1024 MB, static IP, start at boot, DNS set to the Pi-holes.

   Confirm .26–.28 are outside pfSense's DHCP pools.
2. **Image delivery:** this machine pulls the CI image from ECR and copies it
   to each server that lacks it (`docker save | docker load`). The servers
   get no AWS credentials. A running BIND never needs ECR, only a deploy does.
3. **Accounts and monitoring:** both VMs join `~/Code/grafana` `homelab.ini`
   `[misc]`. Bootstrap creates `svc-observability`, and this repo connects as
   that. The fleet agent brings logs and node metrics. networkdocker stays on
   `kenny` until it's retired.
4. **Client DNS (pfSense DHCP):** hand out `10.10.69.19, 10.10.69.26,
   10.10.69.27` on every scope that now gets .19 alone.
   - With the 5700G off, clients fall through to the BIND pair.
   - With it on, some lookups skip lan-cache, so some game downloads miss
     the cache and come from the internet.
5. **Retiring networkdocker's BIND:** keep it serving until query logging
   shows no clients, then stop it. dinner-menu stays on networkdocker, so
   the VM stays. Its `dinner-menu` record still points at .21.
6. **Three Pi-holes, one per mini:** `pihole4` 10.10.69.28 on pve2
   (template 920, `PVE2-NVME`), 1 core, 1024 MB.
   - Built by hand like the other two, since no repo manages Pi-holes yet.
   - Same Pi-hole v6 release as the others.
   - Settings and lists come from pihole2 via Teleporter (Settings →
     Teleporter: export, then import on pihole4).
   - Upstreams 8.8.8.8/8.8.4.4, `listeningMode = "LOCAL"`.
   - Every BIND forwards to all three. Already in `named.conf.options`:
     preflight warns about .28 until it answers, and fails only if none do.

## Code changes here (done; `make validate test test-playbook` pass)

- **Inventory:**
  - `[dns]` is bind-a, bind-b and, during the migration, networkdocker.
  - `ansible.cfg` connects as `svc-observability`.
  - `host_vars/networkdocker.yml` holds `kenny`, the legacy-cutover
    vars, and `bind_manage_docker` / `bind_manage_resolved: false`, so
    nothing changes there but what always did.
- **`docker_host` role:** a copy of `~/Code/traefik`'s (Docker's apt repo,
  pinned 29.x). It runs where `bind_manage_docker` is on.
- **systemd-resolved (`tasks/resolved.yml`):**
  - A drop-in sets `DNSStubListener=no`.
  - `/etc/resolv.conf` is moved off the stub file, only if it is the stock
    symlink.
  - Preflight accepts the stub on :53 there and still fails on anything else.
- **`bind.yml`: `serial: 1`, `any_errors_fatal`.** Each server is deployed
  and verified before the next is touched. A failure on the first leaves the
  rest alone; the test proves it.
- **Image copy:** pulled here once, saved once to `.render/images/`, copied
  and loaded only where missing. Old saves are pruned.
- **Two NS:** `soa.nameservers` in records.yaml. `zone_converter.py` writes
  one NS each, and lint and `verify-dns.py` check them. It lists only ns1
  until step 9.
- **Forwarder preflight:** `scripts/dns-ask.py` runs on each server and asks
  each forwarder. A dead one is a warning; none answering fails.
- **`make … LIMIT=bind-a`**; `release.sh` says "every DNS server".
- **`test-playbook.sh`:**
  - A fresh Ubuntu 24.04 VM stand-in (systemd, resolved's stub, no Docker)
    *and* the legacy networkdocker copy, deployed in order.
  - A dnsmasq stands in for a Pi-hole.
  - A registry on this machine stands in for ECR.

## Cutover, in order (you run everything against real hosts)

Each step can be undone by itself. networkdocker keeps answering until step 10.

1. **Review and commit** this repo's changes. `make release` needs them
   pushed: the image code changed (`zone_converter.py`), so CI builds a new
   tag.
2. **pihole4** (VM 204, created): install Pi-hole
   v6, import pihole2's Teleporter export, and set upstreams and listening
   mode as above. Then in `~/Code/grafana`:
   - add it to `[pihole]`
   - `make bootstrap LIMIT=pihole4 NOPASSWD=1` and its agents
   - add a `pihole4` DNS probe beside pihole2/3 in both alloy configs

   Optionally add it to Homarr's DNS links.
3. **The BIND VMs** (501, 402) are created. Start them and check each has
   its reserved address and isn't using networkdocker for DNS.
4. **Bootstrap:** in `~/Code/grafana` (already in `[misc]`),
   `make bootstrap LIMIT=bind-a,bind-b NOPASSWD=1`.
5. **Deploy:** `make preflight check deploy` here, or `make release`.
   - That's all three servers in turn: bind-a, bind-b, then networkdocker,
     which only gets the new records and forwarders.
   - Preflight should warn about no forwarder only if pihole4 isn't up.
   - Then the grafana agents: `make deploy-agents LIMIT=bind-a,bind-b`.
6. **Grafana probes:** add `bind-a` and `bind-b` targets beside the .21 ones
   in `stack-alloy.config.alloy.j2` and `compose/config/alloy/config.alloy`,
   with `resolver_addr` labels. Then deploy both stacks.
7. **lan-cache's upstream:** on the VM, in `/home/kenny/docker-compose/.env`,
   set `UPSTREAM_DNS=10.10.69.26;10.10.69.27` (lancache-dns takes a `;`
   list; check its README). Then `docker compose up -d dns`. A
   `dig @10.10.69.19 immich.kcarterlabs.tech` from the laptop proves the path.
   This is a hand edit until lan-cache is code (TODO §4).
8. **DHCP and stragglers:**
   - pfSense: DNS servers per decision 4, on every scope. Clients pick it up
     at lease renewal.
   - On networkdocker: `docker exec bind rndc querylog on`. After a day,
     check `docker logs bind | grep query:` for the addresses still asking.
     Fix each one, then run `rndc querylog off`.
9. **Records:**
   - `ns1` → 10.10.69.26, add `ns2` → 10.10.69.27, and set
     `nameservers: [ns1…, ns2…]`.
   - Add `pihole4`, `bind-a` and `bind-b` names if wanted.
   - Replace or delete the Helm chart's stale copy (`bind-flask/values.yaml`).
   - `make release`.
10. **Retire networkdocker's BIND:**
    - Remove it from `[dns]` (and `host_vars/networkdocker.yml`).
    - On it: `docker compose -f /opt/bind/compose/compose.yaml down`, and
      remove `/etc/cron.d/bind-healthcheck`.
    - dinner-menu is untouched. Delete `~/bind` and `~/binddns` while there.
    - Grafana: drop the .21 probes. Delete pve2's old VM 101.
11. **Prove it:** in a quiet window, stop networkdocker and lan-cache (or the
    whole 5700G). Names must still resolve from the laptop and from a
    10.10.69.x host. Then stop bind-a, and they must still resolve. Then stop
    one Pi-hole: internet names still resolve.

**Rollback:** at any step before 10, point DHCP and lan-cache back at .21. It
never stopped serving.

## Risks

- **The Pi-holes are the only recursion.** BIND uses `forward only`, so all
  three Pi-holes down means no internet names, though local names still
  work. They're on three different minis.
- **The Pi-holes drift.** They're configured by hand, three times over.
  Teleporter keeps the initial copy honest; after that, a list added on one
  isn't on the others. A Pi-hole repo (or nebula-sync) would fix it (TODO).
- **A records.yaml error reaches every server.** `bind-reload` refuses an
  invalid zone, keeps the old one serving, and fails the deploy on the first
  server, before the second is touched (`serial: 1`). A *valid but wrong*
  record does reach all of them. That's why `verify` runs per server.
- **DHCP lease time:** some clients keep .19-only until renewal. Don't retire
  anything until step 8's query log is quiet.
- **The DNSSEC "broken trust chain" lines** in BIND's log today come from
  forwarded answers. They're pre-existing and move with it unchanged.
- **Not tested here:** the `/etc/resolv.conf` relink. The test VM's
  resolv.conf is Docker's bind mount, not the cloud image's symlink.
  `make check` on bind-a shows it in the diff.
