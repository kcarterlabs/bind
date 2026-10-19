#!/bin/bash
# Generate the zone from records.yaml, start named, and reload whenever the
# config directory changes.
#
# BIND_CONFIG_DIR (default /etc/bind) holds records.yaml, named.conf.options
# and named.conf.local. The Ansible deploy mounts its managed copies at
# /etc/bind/managed and points this there; with nothing mounted (the CI
# image, a plain `docker run`) the copies baked into the image are used.
set -euo pipefail

CONFIG_DIR="${BIND_CONFIG_DIR:-/etc/bind}"

if [ "$CONFIG_DIR" != /etc/bind ]; then
    # named.conf includes these by absolute path.
    for f in named.conf.options named.conf.local; do
        ln -sf "$CONFIG_DIR/$f" "/etc/bind/$f"
    done
fi

# Writes the zone and checks it; refuses to start on a broken records.yaml.
bind-reload --no-rndc

named -g -c /etc/bind/named.conf &
NAMED_PID=$!

# Watch the directory, not the file: editors, `sed -i`, Ansible's copy and
# Kubernetes ConfigMap updates all replace files by rename, which a watch on
# the file itself never sees. A failed reload leaves the old zone serving.
(
    while inotifywait -qq -e close_write,moved_to,create "$CONFIG_DIR"; do
        echo "Change in $CONFIG_DIR, reloading"
        bind-reload || echo "Reload failed; still serving the previous zone"
    done
) &

# named is the container's life: if it dies, the container exits and its
# restart policy brings it back, rather than the watcher keeping a dead
# server "running".
wait "$NAMED_PID"
