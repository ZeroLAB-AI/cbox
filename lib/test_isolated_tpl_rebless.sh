#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

REBLESS_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_rebless_local_templates)"
VERIFY_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_manifest_verify_conf_interactive)"
[ -n "$REBLESS_FN" ] || _fail "cannot extract _cbox_rebless_local_templates from cbox"
[ -n "$VERIFY_FN" ] || _fail "cannot extract _cbox_manifest_verify_conf_interactive from cbox"

set +eu
. "$INSTALL_DIR/_common.sh" >/dev/null 2>&1
. "$INSTALL_DIR/templates/generators.sh" >/dev/null 2>&1
set -eu
eval "$REBLESS_FN"
eval "$VERIFY_FN"

declare -f _cbox_strip_machine_scoped_vars >/dev/null \
  || _fail "_cbox_strip_machine_scoped_vars must be defined by templates/generators.sh - the runtime cbox script re-blesses templates without sourcing lib/cbox-setup.sh"
_ok "runtime reach: _cbox_strip_machine_scoped_vars lives in generators.sh, not only in the setup library"

_cbox_machine_scoped_vars() {
  printf 'CBOX_LOCAL_MODEL_URL\nCBOX_LOCAL_MODEL_NAME\n'
}
_cbox_flock() { return 0; }
die() { echo "die: $*" >&2; exit 1; }

ROOT="$TMPBASE/ws"
EFF="$TMPBASE/eff"
mkdir -p "$ROOT" "$EFF"

_write_conf() {
  cat > "$EFF/cbox.conf" <<'EOF'
CBOX_MODE=isolated
CBOX_HERMES=on
CBOX_HERMES_DELEGATE=on
CBOX_HERMES_EFFORT=xhigh
CBOX_MCP_SERVERS='codex-sol hermes-local'
CBOX_LOCAL_MODEL_URL=http://stale:11434
CBOX_TPL_SHA=0000000000000000000000000000000000000000000000000000000000000000
EOF
}

_write_conf
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
printf 'FROM scratch\n' > "$EFF/Dockerfile"
_cbox_manifest_write_generated "$EFF"
[ "$(_cbox_manifest_status "$EFF" "$ROOT")" = ok ] || _fail "fresh manifest must read ok, got $(_cbox_manifest_status "$EFF" "$ROOT")"
_ok "baseline: freshly stamped project reads ok"

sed -i 's/^generators=.*/generators=deadbeef/' "$EFF/manifest.sha256"
[ "$(_cbox_manifest_status "$EFF" "$ROOT")" = tpl-drifted ] \
  || _fail "a template-only change must read tpl-drifted, got $(_cbox_manifest_status "$EFF" "$ROOT")"
_ok "status: templates changed with an untouched conf reads tpl-drifted, not drifted"

before="$(grep -c . "$EFF/cbox.conf")"
out="$(_cbox_manifest_verify_conf_interactive "$EFF" "$ROOT" < /dev/null 2>&1)" \
  || _fail "tpl-drifted must re-bless silently even without a tty, got: $out"
case "$out" in
  *"project settings kept"*) ;;
  *) _fail "re-bless must say the project settings are kept, got: $out" ;;
esac
_ok "verify: tpl-drifted re-blesses without a prompt and without a tty"

grep -q '^CBOX_HERMES_DELEGATE=on$' "$EFF/cbox.conf" || _fail "re-bless dropped the project's hermes-delegate setting"
grep -q '^CBOX_HERMES_EFFORT=xhigh$' "$EFF/cbox.conf" || _fail "re-bless dropped the project's hermes effort"
grep -q "^CBOX_MCP_SERVERS='codex-sol hermes-local'$" "$EFF/cbox.conf" || _fail "re-bless dropped the project's mcp server selection"
_ok "re-bless keeps every project-level setting (delegate, effort, mcp selection)"

! grep -q '^CBOX_LOCAL_MODEL_URL=' "$EFF/cbox.conf" || _fail "re-bless must strip stale machine-scoped keys from the project conf"
_ok "re-bless strips stale machine-scoped keys (local-model moved to machine scope)"

grep -q "^CBOX_TPL_SHA=$(_cbox_tpl_sha)$" "$EFF/cbox.conf" || _fail "re-bless must stamp the current template sha into the conf"
[ "$(_cbox_manifest_status "$EFF" "$ROOT")" = ok ] || _fail "after re-bless the manifest must read ok, got $(_cbox_manifest_status "$EFF" "$ROOT")"
grep -q '^dockerfile=' "$EFF/manifest.sha256" || _fail "re-bless must keep the generated-artifact rows in the manifest"
_cbox_manifest_verify_generated "$EFF" || _fail "generated rows must still verify after the re-bless"
_ok "re-bless stamps CBOX_TPL_SHA, the conf manifest and keeps the generated rows"

awk '/^_cbox_rebless_local_templates\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_manifest_write_keep_generated' \
  || _fail "the re-bless must write the manifest in one atomic step (conf rows and generated rows together) - a cbox down racing a cbox run reads the manifest without the regen lock"
! awk '/^_cbox_rebless_local_templates\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_manifest_write "' \
  || _fail "the re-bless must not use the two-step manifest write"
_ok "re-bless writes the manifest atomically (no window without the generated rows)"

_write_conf
_cbox_manifest_write "$EFF" "$ROOT" "$EFF/cbox.conf"
printf 'CBOX_EXTRA=hand-edited\n' >> "$EFF/cbox.conf"
[ "$(_cbox_manifest_status "$EFF" "$ROOT")" = drifted ] \
  || _fail "a hand-edited conf must still read drifted, got $(_cbox_manifest_status "$EFF" "$ROOT")"
if out="$(_cbox_manifest_verify_conf_interactive "$EFF" "$ROOT" < /dev/null 2>&1)"; then
  _fail "a hand-edited conf must be refused without a tty, got: $out"
fi
grep -q '^CBOX_EXTRA=hand-edited$' "$EFF/cbox.conf" || _fail "refusal must not touch the conf"
_ok "verify: a conf edited outside cbox is still refused (no silent re-bless, no re-derive)"

grep -q 'Re-derive from the global profile now? This replaces every project-level setting' "$INSTALL_DIR/cbox" \
  || _fail "the re-derive prompt must warn that project-level settings are replaced"
grep -q '\[y/N\]' <<< "$(_extract_fn "$INSTALL_DIR/cbox" _cbox_manifest_verify_conf_interactive)" \
  || _fail "the re-derive prompt must default to no"
_ok "prompt: re-derive warns about the replacement and defaults to no"

awk '/^_cbox_config_set_isolated\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'tpl-drifted)' \
  || _fail "cbox config set (isolated) must accept tpl-drifted by re-blessing the templates instead of refusing"
_ok "config set: a template-only drift no longer refuses the set"

run_block="$(awk '/^_run_isolated\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
src_line="$(printf '%s\n' "$run_block" | grep -n '^    \. "\$eff/cbox.conf"$' | head -1 | cut -d: -f1)"
def_line="$(printf '%s\n' "$run_block" | grep -n '^    _cbox_reg_conf_defaults$' | head -1 | cut -d: -f1)"
[ -n "$src_line" ] && [ -n "$def_line" ] && [ "$def_line" -gt "$src_line" ] \
  || _fail "_run_isolated must apply the registry defaults right after sourcing the project conf, so a value a previous registry persisted as empty (CBOX_HERMES_EFFORT='') picks up the current default instead of staying empty forever"
_ok "run path: registry defaults are applied after sourcing the project conf (legacy empty values heal on the next run)"

echo "PASS: isolated template re-bless keeps project settings"
