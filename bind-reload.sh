#!/bin/bash
# Regenerate the zone from records.yaml, check it and the config, and only
# then tell named. On any failure the zone named is serving is untouched.
#
#   bind-reload            regenerate, check, `rndc reload`
#   bind-reload --no-rndc  regenerate and check only (entrypoint, before named)
set -euo pipefail

CONFIG_DIR="${BIND_CONFIG_DIR:-/etc/bind}"
RECORDS="$CONFIG_DIR/records.yaml"
ZONE=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["zone"])' "$RECORDS")
TARGET="/etc/bind/zones/$ZONE.zone"

mkdir -p /etc/bind/zones
tmp=$(mktemp /etc/bind/zones/.new.XXXXXX)
trap 'rm -f "$tmp"' EXIT

zone_converter.py "$RECORDS" "$tmp"
named-checkzone -q "$ZONE" "$tmp" || { named-checkzone "$ZONE" "$tmp" >&2; exit 1; }
named-checkconf /etc/bind/named.conf

chmod 0644 "$tmp"
mv "$tmp" "$TARGET"
trap - EXIT

if [ "${1:-}" != --no-rndc ]; then
    # Full reload: re-reads named.conf.options (forwarders) as well as zones.
    rndc reload
fi
