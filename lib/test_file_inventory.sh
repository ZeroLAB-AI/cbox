#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

INVENTORY="$INSTALL_DIR/etc/registry/file_inventory.json"
[ -f "$INVENTORY" ] || _fail "etc/registry/file_inventory.json not found"

python3 -c "
import json
inv = json.load(open('$INVENTORY'))
assert inv.get('schema_version') == 1, 'unexpected schema_version'
assert isinstance(inv.get('layers'), dict) and inv['layers'], 'layers map missing or empty'
assert isinstance(inv.get('files'), dict) and inv['files'], 'files map missing or empty'
known_layers = set(inv['layers'].keys())
for path, meta in inv['files'].items():
    assert meta['layer'] in known_layers, '%s: unknown layer %r' % (path, meta['layer'])
    assert meta.get('purpose'), '%s: empty purpose' % path
" || _fail "file_inventory.json failed schema self-check"
_ok "file_inventory.json schema is well-formed: every file has a declared layer and a non-empty purpose"

python3 "$INSTALL_DIR/lib/portability_denylist.py" check >/dev/null \
  || _fail "the current tree does not pass its own inventory coverage check - a real script is missing from etc/registry/file_inventory.json or a listed file no longer exists"
_ok "the current tree is fully covered by etc/registry/file_inventory.json (no missing, no stale entries)"

WORKCOPY="$TMPBASE/cbox"
cp -a "$INSTALL_DIR" "$WORKCOPY"
rm -rf "$WORKCOPY/.git"

cat > "$WORKCOPY/lib/uninventoried_probe.sh" << 'EOF'
#!/usr/bin/env bash
echo "this file exists on disk but was never added to file_inventory.json"
EOF

OUT="$(python3 -c "
import sys
sys.path.insert(0, '$WORKCOPY/lib')
import portability_denylist as pd
pd.INSTALL_DIR = '$WORKCOPY'
pd.INVENTORY_PATH = '$WORKCOPY/etc/registry/file_inventory.json'
pd.BASELINE_PATH = '$WORKCOPY/lib/fixtures/portability_denylist_baseline.json'
sys.exit(pd.cmd_check())
" 2>&1)" && RC=0 || RC=$?

[ "$RC" -ne 0 ] || _fail "adding an uninventoried script to the tree did not fail the check - the boundary is not machine-enforced"
case "$OUT" in
  *"lib/uninventoried_probe.sh"*) ;;
  *) _fail "check failure did not name the uninventoried file: $OUT" ;;
esac
_ok "enforcement: a script present in the tree but absent from file_inventory.json fails the check and names the file (lib/uninventoried_probe.sh)"

rm -f "$WORKCOPY/lib/uninventoried_probe.sh"

STALE_PATH="$WORKCOPY/etc/registry/file_inventory.json"
python3 -c "
import json
inv = json.load(open('$STALE_PATH'))
inv['files']['lib/this_file_does_not_exist.sh'] = {'layer': 'host', 'purpose': 'stale probe entry'}
json.dump(inv, open('$STALE_PATH', 'w'), indent=2)
"
OUT2="$(python3 -c "
import sys
sys.path.insert(0, '$WORKCOPY/lib')
import portability_denylist as pd
pd.INSTALL_DIR = '$WORKCOPY'
pd.INVENTORY_PATH = '$WORKCOPY/etc/registry/file_inventory.json'
pd.BASELINE_PATH = '$WORKCOPY/lib/fixtures/portability_denylist_baseline.json'
sys.exit(pd.cmd_check())
" 2>&1)" && RC2=0 || RC2=$?
[ "$RC2" -ne 0 ] || _fail "a stale inventory entry (file no longer on disk) did not fail the check"
case "$OUT2" in
  *"lib/this_file_does_not_exist.sh"*) ;;
  *) _fail "check failure did not name the stale entry: $OUT2" ;;
esac
_ok "enforcement: an inventory entry for a file no longer on disk also fails the check and names the entry"

echo "PASS: file inventory enforcement"
