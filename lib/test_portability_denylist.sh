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

INVENTORY="$INSTALL_DIR/etc/registry/file_inventory.json"
[ -f "$INVENTORY" ] || _fail "etc/registry/file_inventory.json not found"

BASELINE="$INSTALL_DIR/lib/fixtures/portability_denylist_baseline.json"
[ -f "$BASELINE" ] || _fail "lib/fixtures/portability_denylist_baseline.json not found"

DETECTOR="$INSTALL_DIR/lib/portability_denylist.py"
[ -f "$DETECTOR" ] || _fail "lib/portability_denylist.py not found"

python3 "$DETECTOR" check || _fail "portability_denylist.py check reported a problem (see stderr above): either an inventory/tree mismatch, or a GNU/bashism occurrence count moved without a baseline regen"
_ok "GNU/bashism denylist ratchet holds: every host-layer file is inventoried, every host-layer file is in the file inventory, and no denylist construct occurrence count changed without a pinned baseline regen"

python3 -c "
import json
inv = json.load(open('$INVENTORY'))
base = json.load(open('$BASELINE'))
host = sorted(k for k, v in inv['files'].items() if v['layer'] == 'host')
print(len(host))
" > /dev/null || _fail "inventory/baseline are not valid JSON"
_ok "inventory and baseline fixture parse as valid JSON"

echo "PASS: portability denylist ratchet"
