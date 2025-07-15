#!/bin/bash
set -e

CONFIG_DIR=/etc/bind
ZONE_FILE=$CONFIG_DIR/db.override
NAMED_CONF=$CONFIG_DIR/named.conf.local
ZONE_NAME="${BIND_ZONE:-example.com}"
RECORD_FILE="/data/records.yaml"

# Create base BIND config
cat > "$NAMED_CONF" <<EOF
zone "$ZONE_NAME" {
    type master;
    file "$ZONE_FILE";
};
forwarders {
  {{- range .Values.bind.forwarders }}
  {{ . }};
  {{- end }}
};
forward only;
EOF

# Initial zone generation
python3 /render_config.py "$RECORD_FILE" "$ZONE_FILE" "$ZONE_NAME"

# Start named
named &

# Start Flask REST API in background
FLASK_ENV=production FLASK_APP=/flask_server.py \
  RECORD_FILE="$RECORD_FILE" ZONE_NAME="$ZONE_NAME" ZONE_FILE="$ZONE_FILE" \
  flask run --host=0.0.0.0 --port=5000 &

if [ -n "$BIND_FORWARDERS" ]; then
cat <<EOF >> /etc/bind/named.conf.options
forwarders {
    ${BIND_FORWARDERS//,/;};
};
forward only;
EOF
fi

# Optional: Watch for file edits and reload
echo "[*] Watching $RECORD_FILE for changes..."
while inotifywait -e modify "$RECORD_FILE"; do
  echo "[*] Detected change, regenerating zone..."
  python3 /render_config.py "$RECORD_FILE" "$ZONE_FILE" "$ZONE_NAME"
  rndc reload || true
done
