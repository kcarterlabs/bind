#!/usr/bin/env bash
# Run the real playbook (bind.yml) against a throwaway Docker-in-Docker host
# set up the way networkdocker is today, before Ansible:
#
#   - `bind-flask`, running the pre-overhaul image as <registry>/kcarterlabs/bind:latest,
#     holding port 53
#   - the legacy cron jobs (monitor.sh every minute, @reboot deploy.sh), plus
#     an unrelated cron line that must survive
#
# A registry inside the host stands in for ECR, and "CI" is this script
# pushing an image there under scripts/image-tag.sh's tag. Checks:
#
#   - the commit/push gate and the ECR check refuse what they should (run
#     against this real checkout and real ECR, read-only)
#   - the cutover, idempotency, --check
#   - a records-only change: reload, same container
#   - a code change CI hasn't pushed: the pull fails, the running BIND is
#     untouched; once pushed: new image, container recreated, old images gone
#   - a broken records.yaml stops at the lint, before the server
#
# Verify runs from this machine against the test host, as it does against
# the real server. KEEP=1 leaves the host up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST=bind-testhost
WORK="$REPO_ROOT/.render/test-playbook"
REG=localhost:5000
REPO=kcarterlabs/bind

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

docker rm -f "$HOST" >/dev/null 2>&1 || true
trap '[ "${KEEP:-}" = 1 ] || docker rm -f "$HOST" >/dev/null 2>&1' EXIT

echo "== images"
# What networkdocker runs today: the committed, pre-overhaul code.
if ! docker image inspect bind:legacy >/dev/null 2>&1; then
  rm -rf "$WORK/legacy" && mkdir -p "$WORK/legacy"
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$WORK/legacy"
  docker build -q -t bind:legacy "$WORK/legacy" >/dev/null
fi
pass "bind:legacy (HEAD, $(git -C "$REPO_ROOT" rev-parse --short HEAD))"
docker image inspect registry:2.8.3 >/dev/null 2>&1 || docker pull -q registry:2.8.3 >/dev/null

echo "== test host"
docker run -d --privileged --name "$HOST" --hostname networkdocker docker:29-dind >/dev/null
for _ in $(seq 30); do docker exec "$HOST" docker info >/dev/null 2>&1 && break; sleep 1; done
# python3 for Ansible, ss for preflight; /etc/cron.d exists on Ubuntu, not Alpine.
docker exec "$HOST" sh -c 'apk add --no-cache -q python3 sudo iproute2 >/dev/null && mkdir -p /etc/cron.d'
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$HOST")
for img in bind:legacy registry:2.8.3; do docker save "$img" | docker exec -i "$HOST" docker load -q >/dev/null; done
docker exec "$HOST" docker run -d --name registry -p 127.0.0.1:5000:5000 registry:2.8.3 >/dev/null

# "CI": build the given checkout and push it under its code tag.
ci_push() {
  local tag; tag=$("$1/scripts/image-tag.sh")
  docker build -q -t "bind:ci-$tag" "$1" >/dev/null
  docker save "bind:ci-$tag" | docker exec -i "$HOST" docker load -q >/dev/null
  docker exec "$HOST" sh -c "docker tag bind:ci-$tag $REG/$REPO:$tag && docker push -q $REG/$REPO:$tag >/dev/null && docker rmi -f bind:ci-$tag $REG/$REPO:$tag >/dev/null"
  docker rmi "bind:ci-$tag" >/dev/null
  echo "$tag"
}

docker exec "$HOST" sh -c "docker tag bind:legacy $REG/$REPO:latest && docker rmi bind:legacy >/dev/null"
docker exec "$HOST" docker run -d --name bind-flask -p 53:53/udp -p 53:53/tcp --restart unless-stopped "$REG/$REPO:latest" >/dev/null
docker exec -i "$HOST" crontab -u root - <<'EOF'
0 3 * * * /usr/bin/true unrelated-job-that-must-survive

* * * * * /home/kenny/bind/monitor.sh

@reboot sleep 30 && /home/kenny/bind/deploy.sh
EOF
for _ in $(seq 20); do dig +short +time=1 +tries=1 "@$IP" truenas.kcarterlabs.tech | grep -q . && break; sleep 1; done
[ "$(dig +short "@$IP" truenas.kcarterlabs.tech)" = 10.20.69.2 ] && pass "legacy bind-flask answering on $IP:53" || fail "legacy container not answering"
[ -z "$(dig +short "@$IP" immich.kcarterlabs.tech)" ] && pass "and doesn't know the new names yet" || fail "legacy knows immich?"

# The real inventory with only the host line swapped.
mkdir -p "$WORK/inventory"
ln -sfn "$REPO_ROOT/ansible/inventory/group_vars" "$WORK/inventory/group_vars"
sed "s/^networkdocker ansible_host=.*/networkdocker ansible_host=$HOST ansible_connection=community.docker.docker ansible_user=root/" \
  "$REPO_ROOT/ansible/inventory/hosts.ini" > "$WORK/inventory/hosts.ini"

recap() { grep -oE 'networkdocker +: ok=[0-9]+ +changed=[0-9]+ +unreachable=[0-9]+ +failed=[0-9]+' <<<"$1"; }
cid() { docker exec "$HOST" docker inspect -f '{{.Id}}' bind 2>/dev/null; }

echo "== the gate, against this real checkout and real ECR (read-only)"
gate() {
  (cd "$REPO_ROOT/ansible" && ANSIBLE_CALLBACKS_ENABLED= ansible-playbook bind.yml -i "$WORK/inventory/hosts.ini" \
     --tags always --check "$@" 2>&1)
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
# registry instead of ECR, and the git/ECR gate off (the copy isn't a repo).
rm -rf "$WORK/repo" && mkdir -p "$WORK/repo"
git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard | (cd "$REPO_ROOT" && xargs -0 cp --parents -t "$WORK/repo")
play() {
  (cd "$WORK/repo/ansible" && ANSIBLE_CALLBACKS_ENABLED= ANSIBLE_DISPLAY_SKIPPED_HOSTS=false ansible-playbook bind.yml -i "$WORK/inventory/hosts.ini" \
     -e bind_legacy_cron_user=root -e bind_verify_address="$IP" -e bind_verify_recursion=false \
     -e bind_ecr_registry=$REG -e bind_ecr_login=false -e bind_check_ecr=false -e bind_allow_unpushed=true "$@")
}
echo "== CI pushes the current code"
pass "pushed $(ci_push "$WORK/repo")"

echo "== --check before the first deploy (make check)"
out=$(play --check --diff --skip-tags verify 2>&1) || { echo "$out" | tail -30; fail "check failed"; }
pass "$(recap "$out")"
docker exec "$HOST" docker ps --format '{{.Names}}' | grep -qx bind-flask && pass "and left bind-flask alone" || fail "check removed bind-flask"

echo "== first deploy: pull, cutover"
out=$(play 2>&1) || { echo "$out" | tail -40; fail "first deploy failed"; }
pass "$(recap "$out")"
grep -q 'TASK \[bind : Pull it\]' <<<"$out" && pass "pulled from the registry" || fail "didn't pull"
docker exec "$HOST" docker ps -a --format '{{.Names}}' | grep -qx bind-flask && fail "bind-flask still there" || pass "bind-flask removed"
cron=$(docker exec "$HOST" crontab -u root -l)
grep -q monitor.sh <<<"$cron" && fail "monitor.sh cron left" || pass "monitor.sh cron removed"
grep -q deploy.sh <<<"$cron" && fail "@reboot deploy.sh cron left" || pass "@reboot deploy.sh cron removed"
grep -q unrelated-job-that-must-survive <<<"$cron" && pass "unrelated cron job kept" || fail "unrelated cron job lost"
docker exec "$HOST" test -f /etc/cron.d/bind-healthcheck && pass "healthcheck cron installed" || fail "no healthcheck cron"
docker exec "$HOST" docker image inspect "$REG/$REPO:latest" >/dev/null 2>&1 && fail "legacy :latest image left" || pass "legacy :latest image removed"
[ "$(dig +short "@$IP" immich.kcarterlabs.tech)" = 10.20.69.2 ] && pass "new names answer (immich -> 10.20.69.2)" || fail "immich missing"

echo "== second deploy must be changed=0"
out=$(play 2>&1) || { echo "$out" | tail -30; fail "second deploy failed"; }
grep -q 'changed=0 ' <<<"$(recap "$out")" || { echo "$out" | grep -B3 -A6 '^changed' | head -40; fail "$(recap "$out")"; }
pass "$(recap "$out")"

echo "== --check after deploy must be changed=0"
out=$(play --check --skip-tags verify 2>&1) || { echo "$out" | tail -30; fail "check failed"; }
grep -q 'changed=0 ' <<<"$(recap "$out")" || fail "$(recap "$out")"
pass "$(recap "$out")"

echo "== a records change is a reload: same image, same container, new answer"
before=$(cid)
sed -i 's/^\(    value: \)10\.10\.69\.25$/\110.10.69.26/' "$WORK/repo/records.yaml"
out=$(play 2>&1) || { echo "$out" | tail -30; fail "records deploy failed"; }
grep -q 'RUNNING HANDLER \[bind : Reload bind\]' <<<"$out" && pass "handler ran: $(recap "$out")" || fail "no reload"
grep -q 'TASK \[bind : Pull it\]' <<<"$out" && fail "pulled for a records-only change" || pass "no pull (same code tag)"
[ "$(cid)" = "$before" ] && pass "same container (no restart)" || fail "container was recreated"
[ "$(dig +short "@$IP" qbittorrent.kcarterlabs.tech)" = 10.10.69.26 ] && pass "qbittorrent now 10.10.69.26" || fail "change not served"

echo "== a broken records.yaml stops the run before the server is touched"
cp "$WORK/repo/records.yaml" "$WORK/records.good"
printf '  - name: Not_Valid\n    type: A\n    value: 10.0.0.999\n' >> "$WORK/repo/records.yaml"
out=$(play 2>&1) && fail "deploy accepted a broken records.yaml"
grep -B1 fatal <<<"$out" | grep -q 'Lint records.yaml' && pass "stopped at the lint" || { echo "$out" | grep -A5 fatal | head; fail "failed somewhere else"; }
docker exec "$HOST" grep -q Not_Valid /opt/bind/config/records.yaml && fail "broken file reached the server" || pass "server's records.yaml untouched"
cp "$WORK/records.good" "$WORK/repo/records.yaml"

echo "== a code change CI hasn't pushed yet: the pull fails, BIND keeps running"
old_image=$(docker exec "$HOST" docker inspect -f '{{.Config.Image}}' bind)
echo "# test change" >> "$WORK/repo/bind-reload.sh"
out=$(play 2>&1) && fail "deployed an image that isn't in the registry"
grep -B1 fatal <<<"$out" | grep -q 'Pull it' && pass "stopped at the pull" || { echo "$out" | grep -A5 fatal | head; fail "failed somewhere else"; }
[ "$(cid)" = "$before" ] && [ "$(dig +short "@$IP" truenas.kcarterlabs.tech)" = 10.20.69.2 ] \
  && pass "running BIND untouched and answering" || fail "BIND disturbed by a failed deploy"

echo "== once CI pushes it: new image, container recreated, old image removed"
pass "pushed $(ci_push "$WORK/repo")"
out=$(play 2>&1) || { echo "$out" | tail -30; fail "code deploy failed"; }
new_image=$(docker exec "$HOST" docker inspect -f '{{.Config.Image}}' bind)
[ "$new_image" != "$old_image" ] && pass "${old_image##*:} -> ${new_image##*:}" || fail "image unchanged"
[ "$(cid)" != "$before" ] && pass "container recreated" || fail "container not recreated"
docker exec "$HOST" docker image inspect "$old_image" >/dev/null 2>&1 && fail "old image left behind" || pass "old image removed"

echo
echo "All playbook checks passed."
