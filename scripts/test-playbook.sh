#!/usr/bin/env bash
# Run the real playbook (bind.yml) against two throwaway servers on their own
# Docker network, deployed one at a time like the real [dns] group:
#
#   bind-a         a freshly cloned Ubuntu 24.04 VM (tests/testvm.Dockerfile):
#                  systemd, systemd-resolved's stub holding port 53, no Docker
#   networkdocker  Docker-in-Docker set up the way networkdocker was before
#                  Ansible: `bind-flask` running the pre-overhaul image and
#                  holding port 53, the legacy cron jobs plus an unrelated
#                  cron line that must survive
#
# A registry on this machine stands in for ECR, and "CI" is this script
# pushing an image there under scripts/image-tag.sh's tag. A dnsmasq stands
# in for a Pi-hole. Checks:
#
#   - the commit/push gate and the ECR check refuse what they should (run
#     against this real checkout and real ECR, read-only)
#   - preflight: a dead forwarder warns, no live forwarder fails
#   - --check on the fresh VM; the first deploy installs Docker, frees port 53,
#     copies the image from here (pulled once, saved once), hands over from
#     bind-flask; one server at a time
#   - idempotency, --check
#   - a records-only change (and a second NS): reload, same containers, no copy
#   - a broken records.yaml stops at the lint, before any server
#   - a code change CI hasn't pushed: the pull here fails, before the first
#     server is touched; once pushed: new image on both, old images gone
#
# Needs the internet: the VM installs Docker from download.docker.com.
# Verify runs from this machine against the test servers, as it does against
# the real ones. KEEP=1 leaves everything up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$REPO_ROOT/.render/test-playbook"
NET=bind-test
SUBNET=172.28.53
VM=bind-test-a
ND=bind-test-nd
FWD=bind-test-fwd
REGC=bind-test-registry
REG=localhost:5053
REPO=kcarterlabs/bind
VMIMG=bind-testvm:24.04
IP_A=$SUBNET.26
IP_ND=$SUBNET.21
IP_FWD=$SUBNET.28
IP_DEAD=$SUBNET.29
# The last commit before the Ansible overhaul: what bind-flask ran.
LEGACY_COMMIT=ecd7da4

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

cleanup() {
  docker rm -f "$VM" "$ND" "$FWD" "$REGC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker image ls -q --filter "reference=$REG/$REPO" | xargs -r docker rmi -f >/dev/null 2>&1 || true
}
cleanup
trap '[ "${KEEP:-}" = 1 ] || cleanup' EXIT

echo "== images"
if ! docker image inspect bind:legacy >/dev/null 2>&1; then
  rm -rf "$WORK/legacy" && mkdir -p "$WORK/legacy"
  git -C "$REPO_ROOT" archive "$LEGACY_COMMIT" | tar -x -C "$WORK/legacy"
  docker build -q -t bind:legacy "$WORK/legacy" >/dev/null
fi
pass "bind:legacy"
for img in registry:2.8.3 alpine:3.20 docker:29-dind; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
done
docker build -q -t "$VMIMG" -f "$REPO_ROOT/tests/testvm.Dockerfile" "$REPO_ROOT/tests" >/dev/null
pass "$VMIMG"

echo "== test network $SUBNET.0/24"
docker network create --subnet "$SUBNET.0/24" "$NET" >/dev/null
docker run -d --name "$REGC" -p 127.0.0.1:5053:5000 registry:2.8.3 >/dev/null
# The Pi-hole stand-in: answers example.com, refuses the rest.
docker run -d --name "$FWD" --network "$NET" --ip "$IP_FWD" alpine:3.20 \
  sh -c 'apk add -q --no-cache dnsmasq && exec dnsmasq -k --no-resolv --address=/example.com/192.0.2.1' >/dev/null

# bind-a: the fresh VM.
docker run -d --name "$VM" --hostname bind-a --network "$NET" --ip "$IP_A" \
  --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
  -v /var/lib/docker -v /var/lib/containerd "$VMIMG" >/dev/null
for _ in $(seq 30); do
  case "$(docker exec "$VM" systemctl is-system-running 2>/dev/null)" in running|degraded) break;; esac; sleep 1
done
for _ in $(seq 10); do docker exec "$VM" ss -Hlnpu 'sport = :53' | grep -q systemd-resolve && break; sleep 1; done
docker exec "$VM" ss -Hlnpu 'sport = :53' | grep -q systemd-resolve \
  && pass "bind-a booted, systemd-resolved's stub on port 53, no Docker" || fail "resolved's stub isn't listening on bind-a"
docker exec "$VM" sh -c 'command -v docker' >/dev/null && fail "bind-a already has Docker"

# networkdocker: the legacy setup.
docker run -d --privileged --name "$ND" --hostname networkdocker --network "$NET" --ip "$IP_ND" docker:29-dind >/dev/null
for _ in $(seq 30); do docker exec "$ND" docker info >/dev/null 2>&1 && break; sleep 1; done
# python3 for Ansible, ss for preflight; /etc/cron.d exists on Ubuntu, not Alpine.
docker exec "$ND" sh -c 'apk add --no-cache -q python3 sudo iproute2 >/dev/null && mkdir -p /etc/cron.d'
docker save bind:legacy | docker exec -i "$ND" docker load -q >/dev/null
docker exec "$ND" sh -c "docker tag bind:legacy $REG/$REPO:latest && docker rmi bind:legacy >/dev/null"
docker exec "$ND" docker run -d --name bind-flask -p 53:53/udp -p 53:53/tcp --restart unless-stopped "$REG/$REPO:latest" >/dev/null
docker exec -i "$ND" crontab -u root - <<'EOF'
0 3 * * * /usr/bin/true unrelated-job-that-must-survive

* * * * * /home/kenny/bind/monitor.sh

@reboot sleep 30 && /home/kenny/bind/deploy.sh
EOF
for _ in $(seq 20); do dig +short +time=1 +tries=1 "@$IP_ND" truenas.kcarterlabs.tech | grep -q . && break; sleep 1; done
[ "$(dig +short "@$IP_ND" truenas.kcarterlabs.tech)" = 10.20.69.2 ] && pass "networkdocker: legacy bind-flask answering" || fail "legacy container not answering"
[ -z "$(dig +short "@$IP_ND" immich.kcarterlabs.tech)" ] && pass "and doesn't know the new names yet" || fail "legacy knows immich?"
for _ in $(seq 20); do python3 "$REPO_ROOT/scripts/dns-ask.py" "$IP_FWD" | grep -q '^ok' && break; sleep 1; done
[ "$(python3 "$REPO_ROOT/scripts/dns-ask.py" "$IP_FWD")" = "ok $IP_FWD" ] && pass "forwarder stand-in answers on $IP_FWD" || fail "dnsmasq not answering"

# The real group_vars and host_vars, a throwaway host list: bind-a first, as
# in hosts.ini. -e ansible_user=root below beats host_vars' kenny.
mkdir -p "$WORK/inventory"
ln -sfn "$REPO_ROOT/ansible/inventory/group_vars" "$WORK/inventory/group_vars"
ln -sfn "$REPO_ROOT/ansible/inventory/host_vars" "$WORK/inventory/host_vars"
cat > "$WORK/inventory/hosts.ini" <<EOF
[dns]
bind-a        ansible_host=$VM ansible_connection=community.docker.docker bind_verify_address=$IP_A
networkdocker ansible_host=$ND ansible_connection=community.docker.docker bind_verify_address=$IP_ND
EOF

recap() { grep -oE '^(bind-a|networkdocker) +: ok=[0-9]+ +changed=[0-9]+ +unreachable=[0-9]+ +failed=[0-9]+' <<<"$1" | tr -s ' ' | paste -sd';'; }
changed0() { [ "$(grep -cE '^(bind-a|networkdocker) +: ok=[0-9]+ +changed=0 ' <<<"$1")" = 2 ]; }
cid() { docker exec "$1" docker inspect -f '{{.Id}}' bind 2>/dev/null; }
# Hosts in the order a task ran on them.
order() { awk -v t="TASK [bind : $2]" 'index($0,t){f=1;next} f&&/^(ok|changed|skipping|fatal): \[/{match($0,/\[[^]]+\]/);print substr($0,RSTART+1,RLENGTH-2);f=0}' <<<"$1" | paste -sd' '; }

echo "== the gate, against this real checkout and real ECR (read-only)"
gate() {
  (cd "$REPO_ROOT/ansible" && ANSIBLE_CALLBACKS_ENABLED= ansible-playbook bind.yml -i "$WORK/inventory/hosts.ini" \
     -e ansible_user=root -e bind_check_forwarders=false --tags always --check "$@" 2>&1)
}
if [ -n "$(git -C "$REPO_ROOT" status --porcelain -- Dockerfile entrypoint.sh bind-reload.sh zone_converter.py records.yaml named.conf.options named.conf.local)" ]; then
  out=$(gate -e bind_check_ecr=false) && fail "deploy allowed with uncommitted changes"
  grep -q 'Uncommitted:' <<<"$out" && pass "refuses uncommitted changes (this checkout has some)" || { echo "$out" | tail; fail "wrong failure"; }
else
  echo "      (checkout is clean: uncommitted-changes refusal not exercised)"
fi
tag=$("$REPO_ROOT/scripts/image-tag.sh")
if ! aws ecr describe-images --region us-west-2 --repository-name "$REPO" --image-ids "imageTag=$tag" >/dev/null 2>&1; then
  out=$(gate -e bind_allow_unpushed=true) && fail "deploy allowed with $tag missing from ECR"
  grep -q "is not in ECR" <<<"$out" && pass "refuses $tag: CI hasn't pushed it to ECR" || { echo "$out" | tail; fail "wrong failure"; }
else
  echo "      ($tag is in ECR: missing-image refusal not exercised)"
fi

# From here, a copy of the repo (so changes below don't touch it), the test
# registry instead of ECR, the git/ECR gate off (the copy isn't a repo), and
# the stand-in Pi-hole plus a dead one as the forwarders. Recursion isn't
# verified: BIND validates DNSSEC, and dnsmasq's made-up example.com fails it.
rm -rf "$WORK/repo" && mkdir -p "$WORK/repo"
git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard | (cd "$REPO_ROOT" && xargs -0 cp --parents -t "$WORK/repo")
sed -i "/forwarders {/,/};/c\\    forwarders {\\n        $IP_FWD;\\n        $IP_DEAD;\\n    };" "$WORK/repo/named.conf.options"
play() {
  (cd "$WORK/repo/ansible" && ANSIBLE_CALLBACKS_ENABLED= ANSIBLE_DISPLAY_SKIPPED_HOSTS=false ansible-playbook bind.yml -i "$WORK/inventory/hosts.ini" \
     -e ansible_user=root -e bind_legacy_cron_user=root -e bind_verify_recursion=false \
     -e bind_ecr_registry=$REG -e bind_ecr_login=false -e bind_check_ecr=false -e bind_allow_unpushed=true "$@")
}

# "CI": build the given checkout and push it under its code tag. Nothing is
# left on this machine but the registry's copy, so the deploy has to pull.
ci_push() {
  local tag; tag=$("$1/scripts/image-tag.sh")
  docker build -q -t "$REG/$REPO:$tag" "$1" >/dev/null
  docker push -q "$REG/$REPO:$tag" >/dev/null
  docker rmi "$REG/$REPO:$tag" >/dev/null
  echo "$tag"
}
echo "== CI pushes the current code"
pass "pushed $(ci_push "$WORK/repo")"

echo "== preflight: forwarders"
out=$(play --tags always --check 2>&1) || { echo "$out" | tail -30; fail "preflight failed"; }
grep -q "gets no answer from forwarder(s) $IP_DEAD" <<<"$out" && pass "warns: $IP_DEAD doesn't answer" || { echo "$out" | grep -A4 'forwarder' | head -20; fail "no warning for the dead forwarder"; }
cp "$WORK/repo/named.conf.options" "$WORK/options.good"
sed -i "/$IP_FWD;/d" "$WORK/repo/named.conf.options"
out=$(play --tags always --check 2>&1) && fail "preflight passed with no live forwarder"
grep -q 'No forwarder in named.conf.options' <<<"$out" && pass "fails when none answers" || { echo "$out" | grep -A3 fatal | head; fail "wrong failure"; }
cp "$WORK/options.good" "$WORK/repo/named.conf.options"

echo "== --check before the first deploy (make check)"
out=$(play --check --diff --skip-tags verify 2>&1) || { echo "$out" | tail -30; fail "check failed"; }
pass "$(recap "$out")"
grep -q "Would add Docker's repository" <<<"$out" && grep -q 'Would pull .* and copy it to bind-a' <<<"$out" \
  && pass "reports the Docker install and the image copy it would do" || fail "check didn't report what it would do"
docker exec "$ND" docker ps --format '{{.Names}}' | grep -qx bind-flask && pass "and left bind-flask alone" || fail "check removed bind-flask"
docker exec "$VM" sh -c 'command -v docker' >/dev/null && fail "check installed Docker"

echo "== first deploy: Docker, port 53, image copy, cutover; one server at a time"
out=$(play 2>&1) || { echo "$out" | tail -40; fail "first deploy failed"; }
pass "$(recap "$out")"
[ "$(order "$out" 'Check BIND is healthy')" = "bind-a networkdocker" ] && pass "bind-a verified before networkdocker" \
  || fail "order: $(order "$out" 'Check BIND is healthy')"
first_nd=$(grep -n '\[networkdocker' <<<"$out" | head -1 | cut -d: -f1)
last_a=$(grep -n '\[bind-a\]' <<<"$out" | tail -1 | cut -d: -f1)
[ "$last_a" -lt "$first_nd" ] && pass "no networkdocker task before bind-a finished" || fail "interleaved"
[ "$(grep -c 'TASK \[bind : Pull it\]' <<<"$out")" = 1 ] && pass "pulled once, here" || fail "pulled $(grep -c 'TASK \[bind : Pull it\]' <<<"$out") times"
grep -A1 'TASK \[bind : Save it to a file\]' <<<"$out" | grep -q '^ok: \[networkdocker -> localhost\]' \
  && pass "saved once, reused for the second server" || fail "save: $(order "$out" 'Save it to a file')"
for h in "$VM" "$ND"; do docker exec "$h" test -e /opt/bind/image.tar.gz && fail "image copy left on $h"; done
pass "no image copy left on either server"
v=$(docker exec "$VM" docker version --format '{{.Server.Version}}')
[[ "$v" == 29.* ]] && pass "bind-a: Docker $v from Docker's repository" || fail "bind-a Docker $v"
docker exec "$VM" test -f /etc/systemd/resolved.conf.d/bind-no-stub.conf && [ "$(docker exec "$VM" systemctl is-active systemd-resolved)" = active ] \
  && ! docker exec "$VM" ss -Hlnpu 'sport = :53' | grep -q systemd-resolve \
  && pass "bind-a: resolved running, stub off, port 53 BIND's" || fail "resolved state wrong on bind-a"
docker exec "$ND" docker ps -a --format '{{.Names}}' | grep -qx bind-flask && fail "bind-flask still there" || pass "networkdocker: bind-flask removed"
cron=$(docker exec "$ND" crontab -u root -l)
grep -q monitor.sh <<<"$cron" && fail "monitor.sh cron left" || pass "monitor.sh cron removed"
grep -q deploy.sh <<<"$cron" && fail "@reboot deploy.sh cron left" || pass "@reboot deploy.sh cron removed"
grep -q unrelated-job-that-must-survive <<<"$cron" && pass "unrelated cron job kept" || fail "unrelated cron job lost"
docker exec "$ND" docker image inspect "$REG/$REPO:latest" >/dev/null 2>&1 && fail "legacy :latest image left" || pass "legacy :latest image removed"
for h in "$VM" "$ND"; do docker exec "$h" test -f /etc/cron.d/bind-healthcheck || fail "no healthcheck cron on $h"; done
pass "healthcheck cron on both"
for ip in "$IP_A" "$IP_ND"; do
  [ "$(dig +short "@$ip" immich.kcarterlabs.tech)" = 10.20.69.2 ] || fail "immich missing on $ip"
done
pass "both answer the new names (immich -> 10.20.69.2)"

echo "== second deploy and --check: changed=0"
out=$(play 2>&1) || { echo "$out" | tail -30; fail "second deploy failed"; }
changed0 "$out" || { echo "$out" | grep -B3 -A6 '^changed' | head -40; fail "$(recap "$out")"; }
pass "$(recap "$out")"
out=$(play --check --skip-tags verify 2>&1) || { echo "$out" | tail -30; fail "check failed"; }
changed0 "$out" || { echo "$out" | grep -B3 -A6 '^changed' | head -40; fail "$(recap "$out")"; }
pass "--check: $(recap "$out")"

echo "== a records change (and a second NS) is a reload: same containers, no copy, new answers"
before_a=$(cid "$VM"); before_nd=$(cid "$ND")
sed -i 's/^\(    value: \)10\.10\.69\.25$/\110.10.69.26/' "$WORK/repo/records.yaml"
sed -i 's/^  nameservers: \[ns1.kcarterlabs.tech.\]$/  nameservers: [ns1.kcarterlabs.tech., ns2.kcarterlabs.tech.]/' "$WORK/repo/records.yaml"
printf '  - name: ns2\n    type: A\n    value: 10.10.69.27\n' >> "$WORK/repo/records.yaml"
out=$(play 2>&1) || { echo "$out" | tail -30; fail "records deploy failed"; }
[ "$(grep -c 'RUNNING HANDLER \[bind : Reload bind\]' <<<"$out")" = 2 ] && pass "reloaded on both: $(recap "$out")" || fail "no reload"
grep -qE 'TASK \[bind : (Pull it|Copy it to the server)\]' <<<"$out" && fail "image moved for a records-only change" || pass "no pull, no copy (same code tag)"
[ "$(cid "$VM")" = "$before_a" ] && [ "$(cid "$ND")" = "$before_nd" ] && pass "same containers (no restart)" || fail "a container was recreated"
for ip in "$IP_A" "$IP_ND"; do
  [ "$(dig +short "@$ip" qbittorrent.kcarterlabs.tech)" = 10.10.69.26 ] || fail "change not served on $ip"
  [ "$(dig +short "@$ip" kcarterlabs.tech NS | sort | paste -sd' ')" = "ns1.kcarterlabs.tech. ns2.kcarterlabs.tech." ] || fail "NS on $ip: $(dig +short "@$ip" kcarterlabs.tech NS)"
done
pass "both serve the change and two NS records (verify checked each)"

echo "== a broken records.yaml stops the run before any server is touched"
cp "$WORK/repo/records.yaml" "$WORK/records.good"
printf '  - name: Not_Valid\n    type: A\n    value: 10.0.0.999\n' >> "$WORK/repo/records.yaml"
out=$(play 2>&1) && fail "deploy accepted a broken records.yaml"
grep -B1 fatal <<<"$out" | grep -q 'Lint records.yaml' && pass "stopped at the lint" || { echo "$out" | grep -A5 fatal | head; fail "failed somewhere else"; }
for h in "$VM" "$ND"; do docker exec "$h" grep -q Not_Valid /opt/bind/config/records.yaml && fail "broken file reached $h"; done
pass "neither server's records.yaml touched"
cp "$WORK/records.good" "$WORK/repo/records.yaml"

echo "== a code change CI hasn't pushed yet: the pull fails, before any server changes"
old_image=$(docker exec "$VM" docker inspect -f '{{.Config.Image}}' bind)
echo "# test change" >> "$WORK/repo/bind-reload.sh"
out=$(play 2>&1) && fail "deployed an image that isn't in the registry"
grep -B1 fatal <<<"$out" | grep -q 'Pull it' && pass "stopped at the pull, on bind-a" || { echo "$out" | grep -A5 fatal | head; fail "failed somewhere else"; }
grep -q '\[networkdocker' <<<"$out" && fail "networkdocker was touched after bind-a failed" || pass "networkdocker never started (serial, any_errors_fatal)"
[ "$(cid "$VM")" = "$before_a" ] && [ "$(cid "$ND")" = "$before_nd" ] \
  && [ "$(dig +short "@$IP_A" truenas.kcarterlabs.tech)" = 10.20.69.2 ] && [ "$(dig +short "@$IP_ND" truenas.kcarterlabs.tech)" = 10.20.69.2 ] \
  && pass "both servers untouched and answering" || fail "a server was disturbed by a failed deploy"

echo "== once CI pushes it: new image on both, containers recreated, old images gone"
old_save=$(ls "$WORK/repo/.render/images/")
pass "pushed $(ci_push "$WORK/repo")"
out=$(play 2>&1) || { echo "$out" | tail -30; fail "code deploy failed"; }
for h in "$VM" "$ND"; do
  new_image=$(docker exec "$h" docker inspect -f '{{.Config.Image}}' bind)
  [ "$new_image" != "$old_image" ] || fail "image unchanged on $h"
  docker exec "$h" docker image inspect "$old_image" >/dev/null 2>&1 && fail "old image left on $h"
done
pass "${old_image##*:} -> ${new_image##*:} on both, old image removed"
[ "$(cid "$VM")" != "$before_a" ] && [ "$(cid "$ND")" != "$before_nd" ] && pass "both containers recreated" || fail "not recreated"
[ ! -e "$WORK/repo/.render/images/$old_save" ] && pass "old saved image removed here" || fail "$old_save left in the image cache"

echo
echo "All playbook checks passed."
