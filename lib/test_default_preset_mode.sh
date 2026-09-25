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

HARNESS="$TMPBASE/default_preset_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  awk '/^default_preset_set\(\) \{/,/^}$/' "$INSTALL_DIR/lib/cbox-setup.sh"
  cat <<'STUBS'
_cbox_xdg_runtime_dir() { printf '%s' "${XDG_RUNTIME_DIR:-/tmp}"; }
default_preset_set
printf 'CBOX_MODE=%s\n' "$CBOX_MODE"
STUBS
} > "$HARNESS"
chmod +x "$HARNESS"

grep -q 'default_preset_set()' "$HARNESS" || _fail "could not extract default_preset_set from lib/cbox-setup.sh"

got_mode="$(env -i HOME="$HOME" bash "$HARNESS" | sed -n 's/^CBOX_MODE=//p')"
registry_default="$(sed -n 's/.*CBOX_MODE:=\([a-z]*\).*/\1/p' "$INSTALL_DIR/templates/conf_lib.sh" | head -n1)"

[ -n "$registry_default" ] || _fail "could not read the registry default for CBOX_MODE from templates/conf_lib.sh"
[ "$registry_default" = global ] || _fail "registry default for CBOX_MODE changed to '$registry_default' - update this test's expectation deliberately"
[ "$got_mode" = "$registry_default" ] || _fail "default_preset_set sets CBOX_MODE=$got_mode, registry default is $registry_default - global is the only default; isolated mode is opt-in per project setup"
_ok "default_preset_set: CBOX_MODE=$got_mode matches the registry default ($registry_default) - isolated only via project setup"

echo "test_default_preset_mode: all checks passed"
