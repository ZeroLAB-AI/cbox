#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

_skip() {
  echo "SKIP: $1"
}

if ! command -v docker >/dev/null 2>&1; then
  _skip "docker is not available in this environment - the bash-3.2 parse gate is real only on a docker-capable host/CI, this run proves nothing about bash-3.2 parseability"
  echo "PASS: bash-3.2 parse gate skipped (no docker)"
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  _skip "docker is installed but the daemon/socket is not reachable - the bash-3.2 parse gate is real only on a docker-capable host/CI, this run proves nothing about bash-3.2 parseability"
  echo "PASS: bash-3.2 parse gate skipped (docker daemon unreachable)"
  exit 0
fi

INVENTORY="$INSTALL_DIR/etc/registry/file_inventory.json"
[ -f "$INVENTORY" ] || _fail "etc/registry/file_inventory.json not found"

HOST_SH_FILES="$(python3 - "$INVENTORY" "$INSTALL_DIR" << 'PYEOF'
import json
import sys

inv_path, install_dir = sys.argv[1], sys.argv[2]
inv = json.load(open(inv_path))
for path, meta in sorted(inv["files"].items()):
    if meta["layer"] != "host":
        continue
    if not path.endswith(".sh") and path not in ("cbox",):
        continue
    print(path)
PYEOF
)"

[ -n "$HOST_SH_FILES" ] || _fail "no host-layer bash scripts found via the inventory"

IMAGE="bash:3.2"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if ! docker pull "$IMAGE" >/dev/null 2>&1; then
    _skip "could not pull $IMAGE (registry unreachable?) - without the official image this run proves nothing about bash-3.2 parseability"
    echo "PASS: bash-3.2 parse gate skipped (image unavailable)"
    exit 0
  fi
fi

FAILED=0
CHECKED=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  CHECKED=$((CHECKED + 1))
  if ! docker run --rm -v "$INSTALL_DIR:/work:ro" "$IMAGE" bash -n "/work/$rel"; then
    echo "FAIL: $rel does not parse under $IMAGE" >&2
    FAILED=$((FAILED + 1))
  fi
done << EOF
$HOST_SH_FILES
EOF

[ "$CHECKED" -gt 0 ] || _fail "no host-layer bash scripts were checked"

if [ "$FAILED" -gt 0 ]; then
  _fail "$FAILED of $CHECKED host-layer bash scripts failed to parse under $IMAGE (bash 3.2)"
fi

_ok "$CHECKED host-layer bash scripts parse cleanly under the official $IMAGE image"
echo "PASS: bash-3.2 parse gate"
