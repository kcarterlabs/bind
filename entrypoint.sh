#!/bin/bash
set -e

ZONE_PATH="/etc/bind/zones/kcarterlabs.tech.zone"
YAML_PATH="/etc/bind/records.yaml"

/usr/local/bin/zone_converter.py "$YAML_PATH" "$ZONE_PATH"

named -g -c /etc/bind/named.conf &
NAMED_PID=$!

while inotifywait -e modify "$YAML_PATH"; do
    echo "Detected change in records.yaml"
    /usr/local/bin/zone_converter.py "$YAML_PATH" "$ZONE_PATH"
    rndc reload kcarterlabs.tech
done

wait $NAMED_PID