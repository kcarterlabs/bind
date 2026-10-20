#!/usr/bin/env bash
# Run the image on this machine the way the Ansible deploy runs it -- config
# directory mounted read-only at /etc/bind/managed -- and check what it does,
# not just that it starts:
#
#   - every record in records.yaml answers (scripts/verify-dns.py)
#   - the serial is generated (serial: auto)
#   - an edit made by rename (Ansible, sed -i, editors) is picked up live
#   - a broken records.yaml is refused and the previous zone keeps serving
#   - named dying takes the container down, so the restart policy recovers it
#
# On 127.0.0.1:15353, so it never clashes with a resolver on this machine.
# KEEP=1 leaves it running.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=bind:validate
NAME=bind-test
PORT=15353
CFG="$REPO_ROOT/.render/test-config"
ZONE=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["zone"])' "$REPO_ROOT/records.yaml")

fail() { echo "FAIL: $*" >&2; docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/      /' >&2; exit 1; }
pass() { echo "  ok  $*"; }
q() { dig +short +time=2 +tries=1 -p "$PORT" @127.0.0.1 "$@"; }
# Write a file the way Ansible's copy does: a new inode renamed into place.
replace() { cp "$2" "$CFG/.tmp.$1" && mv "$CFG/.tmp.$1" "$CFG/$1"; }
wait_for() {  # seconds, command...
  local n=$1; shift
  for _ in $(seq "$n"); do "$@" && return 0; sleep 1; done
  return 1
}
healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null)" = healthy ]; }

docker rm -f "$NAME" >/dev/null 2>&1 || true
trap '[ "${KEEP:-}" = 1 ] || docker rm -f "$NAME" >/dev/null 2>&1' EXIT

rm -rf "$CFG" && mkdir -p "$CFG"
cp "$REPO_ROOT"/{records.yaml,named.conf.options,named.conf.local} "$CFG/"

echo "== start, as the deploy runs it"
docker run -d --name "$NAME" --restart unless-stopped \
  -e BIND_CONFIG_DIR=/etc/bind/managed -v "$CFG:/etc/bind/managed:ro,z" \
  -p "127.0.0.1:$PORT:53/udp" -p "127.0.0.1:$PORT:53/tcp" "$IMAGE" >/dev/null
wait_for 60 healthy && pass "healthy (its own healthcheck: SOA for $ZONE)" || fail "never became healthy"

echo "== every record"
# Recursion goes through the forwarders in named.conf.options (the Pi-holes),
# which only answer the server's own networks. Check it only if this machine
# can reach one; `make verify` always checks it from the real server.
fwd=$(grep -oE '[0-9]+(\.[0-9]+){3}' "$CFG/named.conf.options" | head -1)
recursion=--no-recursion-check
dig +short +time=2 +tries=1 "@$fwd" example.com >/dev/null 2>&1 && recursion= \
  || echo "      (forwarder $fwd doesn't answer this machine: recursion not checked here)"
python3 "$REPO_ROOT/scripts/verify-dns.py" 127.0.0.1 --port "$PORT" --records "$CFG/records.yaml" $recursion \
  | sed 's/^/    /' || fail "records did not all answer"
serial=$(q "$ZONE" SOA | awk '{print $3}')
[ "$serial" -gt 1700000000 ] && pass "serial is generated ($serial)" || fail "serial $serial is not auto"

echo "== an edit made by rename is picked up without a restart"
started=$(docker inspect -f '{{.State.StartedAt}}' "$NAME")
sed 's/^\(  - name: truenas\)$/\1/' "$CFG/records.yaml" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
for r in d["records"]:
    if r["name"] == "truenas": r["value"] = "10.20.69.99"
d["records"].append({"name": "added-by-test", "type": "A", "value": "10.9.9.9"})
yaml.safe_dump(d, sys.stdout, sort_keys=False)' > "$CFG/.edited"
replace records.yaml "$CFG/.edited"
wait_for 15 sh -c "[ \"\$(dig +short -p $PORT @127.0.0.1 truenas.$ZONE)\" = 10.20.69.99 ]" \
  && pass "changed record served" || fail "truenas still $(q truenas.$ZONE)"
[ "$(q added-by-test.$ZONE)" = 10.9.9.9 ] && pass "added record served" || fail "added record missing"
new_serial=$(q "$ZONE" SOA | awk '{print $3}')
[ "$new_serial" -ge "$serial" ] && pass "serial did not go backwards ($new_serial)" || fail "serial went from $serial to $new_serial"
[ "$(docker inspect -f '{{.State.StartedAt}}' "$NAME")" = "$started" ] && pass "no restart" || fail "container restarted"

echo "== a broken records.yaml is refused; the previous zone keeps serving"
printf 'zone: %s\nsoa: {primary_ns: ns1.%s., admin_email: a.%s., refresh: 1, retry: 1, expire: 1, minimum: 1}\nrecords:\n  - {name: www, type: CNAME, value: x.}\n  - {name: www, type: A, value: 1.2.3.4}\n' \
  "$ZONE" "$ZONE" "$ZONE" > "$CFG/.broken"
replace records.yaml "$CFG/.broken"
wait_for 15 sh -c "docker logs $NAME 2>&1 | grep -q 'Reload failed; still serving the previous zone'" \
  && pass "watcher refused it (\"Reload failed; still serving the previous zone\")" || fail "no refusal logged"
[ "$(q truenas.$ZONE)" = 10.20.69.99 ] && pass "previous zone still answers" || fail "zone lost after a bad edit"
docker exec "$NAME" bind-reload >/dev/null 2>&1 && fail "bind-reload accepted a broken file" \
  || pass "bind-reload exits non-zero, so the Ansible handler fails loudly"
healthy && pass "still healthy" || fail "unhealthy after a bad edit"

echo "== named dying takes the container down, and the restart policy brings it back"
replace records.yaml "$REPO_ROOT/records.yaml"
truenas=$(python3 -c 'import sys, yaml; print(next(r["value"] for r in yaml.safe_load(open(sys.argv[1]))["records"] if r["name"] == "truenas"))' "$REPO_ROOT/records.yaml")
wait_for 15 sh -c "[ \"\$(dig +short -p $PORT @127.0.0.1 truenas.$ZONE)\" = $truenas ]" || fail "good file not reloaded"
restarts=$(docker inspect -f '{{.RestartCount}}' "$NAME")
docker exec "$NAME" pkill -x named || true
wait_for 30 sh -c "[ \$(docker inspect -f '{{.RestartCount}}' $NAME) -gt $restarts ]" \
  && pass "container restarted after named died" || fail "container kept running without named"
wait_for 60 healthy && [ "$(q truenas.$ZONE)" = "$truenas" ] && pass "answering again" || fail "did not recover"

echo
echo "All checks passed.$([ "${KEEP:-}" = 1 ] && echo " Left running: dig -p $PORT @127.0.0.1 truenas.$ZONE")"
