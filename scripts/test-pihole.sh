#!/usr/bin/env bash
# pihole.yml against throwaway Pi-hole containers, one per FTL version on the
# LAN: pihole/pihole:2025.06.2 is FTL v6.2.3 (pihole2, pihole3) and 2026.10.0
# is v6.8 (pihole4). The image is Alpine, not the VMs' Ubuntu, but pihole-FTL,
# pihole.toml, gravity.db and the pihole CLI are the same; the playbook only
# touches those. Each container starts with drift: settings off, a blocklist
# and a deny entry that group_vars doesn't have. Asserts:
#   - --check reports the drift and changes nothing
#   - a run fixes it all: settings, the extra blocklist removed (gravity
#     rebuilt), domains replaced, and verify passes
#   - a second run and --check are changed=0
#   - a domains-only change reloads lists without a gravity rebuild
#   - a setting this FTL doesn't know fails before anything changes
# Needs Docker and the internet (gravity downloads the blocklist; upstreams
# are 8.8.8.8).
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INV="$REPO_ROOT/.render/test-pihole"
declare -A IMAGES=([ph62]=pihole/pihole:2025.06.2 [ph68]=pihole/pihole:2026.10.0)

pass() { echo "  ok  $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
down() { for h in "${!IMAGES[@]}"; do docker rm -f "test-$h" >/dev/null 2>&1 || true; done; }
trap '[ "${KEEP:-}" = 1 ] || down' EXIT
x() { docker exec "test-$1" sh -c "$2"; }
cfg() { docker exec "test-$1" pihole-FTL --config "${@:2}"; }
sql() { x "$1" "pihole-FTL sqlite3 /etc/pihole/gravity.db \"$2\""; }

echo "== Pi-hole containers"
down
for h in "${!IMAGES[@]}"; do
  docker run -d --name "test-$h" -e TZ=UTC "${IMAGES[$h]}" >/dev/null
done
for h in "${!IMAGES[@]}"; do
  # Wait for the image's first gravity run. Don't open gravity.db before it
  # has content: sqlite would create it empty, and start.sh then skips
  # building it.
  for _ in $(seq 90); do
    x "$h" 'test -s /etc/pihole/gravity.db' && [ "$(sql "$h" 'SELECT count(*) FROM gravity' 2>/dev/null || echo 0)" -gt 1000 ] && break
    sleep 2
  done
  [ "$(sql "$h" 'SELECT count(*) FROM gravity')" -gt 1000 ] || fail "$h: no gravity after start"
  x "$h" 'apk add -q python3 >/dev/null'
  # Drift, as a hand-managed Pi-hole might have it.
  cfg "$h" dns.queryLogging false >/dev/null
  cfg "$h" dns.upstreams '["1.1.1.1"]' >/dev/null
  sql "$h" "INSERT INTO adlist (address, comment) VALUES ('https://example.invalid/extra.txt', 'by hand')"
  sql "$h" "INSERT INTO domainlist (type, domain, comment) VALUES (1, 'hand-denied.example', 'by hand')"
  pass "$h: ${IMAGES[$h]} FTL $(x "$h" 'pihole-FTL -vv | grep -m1 Version | tr -s " " | cut -d" " -f2'), drift seeded"
done

rm -rf "$INV" && mkdir -p "$INV"
ln -s ../../ansible/inventory/group_vars "$INV/group_vars"
{ echo "[pihole]"; for h in "${!IMAGES[@]}"; do echo "$h ansible_host=test-$h ansible_connection=community.docker.docker ansible_user=root"; done; } > "$INV/hosts.ini"

DOMAINS='{"pihole_domains": {"allow": ["allowed.example.com"], "deny": ["denied-by-test.example.com"], "allow_regex": [], "deny_regex": ["^ads-regex-test\\."]}}'
play() {
  (cd "$REPO_ROOT/ansible" && ANSIBLE_CALLBACKS_ENABLED= ANSIBLE_DISPLAY_SKIPPED_HOSTS=false \
     ansible-playbook pihole.yml -i "$INV/hosts.ini" -e "$DOMAINS" "$@")
}
recap() { grep -oE '^ph[0-9]+ +: ok=[0-9]+ +changed=[0-9]+ +unreachable=[0-9]+ +failed=[0-9]+' <<<"$1" | tr -s ' ' | paste -sd';'; }
all_unchanged() { ! grep -qE '^ph[0-9]+ +: ok=[0-9]+ +changed=[1-9]' <<<"$1"; }

echo "== --check reports the drift and changes nothing"
out=$(play --check 2>&1) || { echo "$out" | tail -30; fail "check failed"; }
for w in 'dns.queryLogging: false -> true' 'dns.upstreams: [^>]*1\.1\.1\.1[^>]*-> [^;]*8\.8\.8\.8[^;]*8\.8\.4\.4' \
         'blocklists remove: https://example.invalid/extra.txt' 'domains remove: hand-denied.example'; do
  grep -qE "$w" <<<"$out" || { echo "$out" | grep -A3 'Say what'; fail "--check didn't report: $w"; }
done
for h in "${!IMAGES[@]}"; do [ "$(cfg "$h" dns.queryLogging)" = false ] || fail "$h: --check changed a setting"; done
pass "reported settings, blocklist and domain drift on both; nothing changed ($(recap "$out"))"

echo "== deploy"
out=$(play 2>&1) || { echo "$out" | tail -40; fail "deploy failed"; }
pass "$(recap "$out")"
for h in "${!IMAGES[@]}"; do
  [ "$(cfg "$h" dns.queryLogging)" = true ] && [ "$(cfg "$h" dns.upstreams)" = "[ 8.8.8.8, 8.8.4.4 ]" ] \
    || fail "$h: settings not applied"
  [ "$(sql "$h" 'SELECT address FROM adlist')" = https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts ] \
    || fail "$h: adlists $(sql "$h" 'SELECT address FROM adlist')"
  [ "$(sql "$h" 'SELECT type || domain FROM domainlist ORDER BY type')" = "$(printf '0allowed.example.com\n1denied-by-test.example.com\n3^ads-regex-test\\.')" ] \
    || fail "$h: domains $(sql "$h" 'SELECT type, domain FROM domainlist')"
done
pass "settings, blocklists and domains match group_vars on both"
[ "$(grep -c 'TASK \[pihole : Rebuild gravity' <<<"$out")" = 2 ] && pass "gravity rebuilt on both (a blocklist was removed)" || fail "gravity runs"
grep -q 'denied-by-test.example.com -> 0.0.0.0' <<<"$out" && grep -qE 'example.com -> [0-9]' <<<"$out" \
  && pass "verify: example.com resolves, the deny entry answers 0.0.0.0" || { echo "$out" | grep -A6 'Show the checks'; fail "verify output"; }
for h in "${!IMAGES[@]}"; do
  [ "$(cfg "$h" dns.blocking.mode)" = NULL ] || fail "$h blocking mode"
done

echo "== second run and --check must be changed=0"
out=$(play 2>&1); all_unchanged "$out" && pass "run: $(recap "$out")" || { echo "$out" | grep -B2 -A4 'changed:'; fail "second run: $(recap "$out")"; }
out=$(play --check 2>&1); all_unchanged "$out" && pass "--check: $(recap "$out")" || fail "--check: $(recap "$out")"

echo "== a domains-only change reloads lists, no gravity rebuild"
out=$(play -e '{"pihole_domains": {"allow": [], "deny": ["second-test.example.com"], "allow_regex": [], "deny_regex": []}}' 2>&1) \
  || { echo "$out" | tail -30; fail "domains change failed"; }
grep -q 'TASK \[pihole : Rebuild gravity' <<<"$out" && fail "gravity rebuilt for a domains-only change"
[ "$(grep -c 'TASK \[pihole : Reload the allow and deny lists' <<<"$out")" = 2 ] || fail "reloadlists didn't run on both"
grep -q 'second-test.example.com -> 0.0.0.0' <<<"$out" && pass "reloadlists on both, second-test.example.com blocked" || fail "new deny not blocked"

echo "== a setting this FTL doesn't know stops the run before any change"
before=$(cfg ph62 dns.queryLogging)
out=$(play -e '{"pihole_settings": {"dns.queryLogging": false, "dns.noSuchSetting": 1}}' 2>&1) && fail "accepted an unknown key"
grep -q 'dns.noSuchSetting is not a setting' <<<"$out" && [ "$(cfg ph62 dns.queryLogging)" = "$before" ] \
  && pass "stopped in preflight, nothing changed" || { echo "$out" | tail -15; fail "wrong failure"; }

echo
echo "All Pi-hole checks passed."
