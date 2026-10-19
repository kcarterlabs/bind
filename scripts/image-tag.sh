#!/usr/bin/env bash
# Print the image tag for the code in this checkout: code-<sha1 of the files
# that make up the image's behaviour>. CI pushes every build under this tag
# (as well as the commit SHA and latest), and the Ansible deploy pulls it, so
# both sides agree on which image matches the code without talking to each
# other. records.yaml and the named.conf files are deliberately not part of
# it: the deploy mounts those, so a records-only commit keeps the same tag
# and deploys as a reload, not a new image.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
echo "code-$(cat Dockerfile entrypoint.sh bind-reload.sh zone_converter.py | sha1sum | cut -c1-12)"
