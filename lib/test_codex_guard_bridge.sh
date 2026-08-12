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

BRIDGE="$INSTALL_DIR/etc/hooks/codex_guard_bridge.py"
FIXDIR="$INSTALL_DIR/lib/fixtures/m4"
DENY_FX="$FIXDIR/codex_pretooluse_rm_glob_deny.json"
ALLOW_FX="$FIXDIR/codex_pretooluse_innocuous_allow.json"
MALFORMED_FX="$FIXDIR/codex_pretooluse_malformed.json"

[ -f "$BRIDGE" ] || _fail "codex_guard_bridge.py not found at $BRIDGE"
[ -f "$DENY_FX" ] || _fail "deny fixture missing: $DENY_FX"
[ -f "$ALLOW_FX" ] || _fail "allow fixture missing: $ALLOW_FX"
[ -f "$MALFORMED_FX" ] || _fail "malformed fixture missing: $MALFORMED_FX"

python3 -c "import py_compile; py_compile.compile('$BRIDGE', doraise=True)" \
  || _fail "codex_guard_bridge.py does not py_compile"
_ok "codex_guard_bridge.py py_compiles cleanly"

for fx in "$DENY_FX" "$ALLOW_FX" "$MALFORMED_FX"; do
  grep -q '"provenance": "spec"\|provenance: spec' "$fx" \
    || _fail "fixture $fx is missing the mandatory 'provenance: spec' marker"
done
_ok "all m4 codex PreToolUse fixtures carry the provenance:spec marker"

DENY_OUT="$(python3 "$BRIDGE" < "$DENY_FX")"
DENY_RC=$?
[ "$DENY_RC" -eq 0 ] || _fail "bridge exited non-zero on the deny fixture (rc=$DENY_RC)"
printf '%s' "$DENY_OUT" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
hso = doc.get('hookSpecificOutput') or {}
assert hso.get('hookEventName') == 'PreToolUse', 'hookEventName mismatch: %r' % hso
assert hso.get('permissionDecision') == 'deny', 'permissionDecision was not deny: %r' % hso
assert hso.get('permissionDecisionReason'), 'missing permissionDecisionReason'
" || _fail "deny fixture did not drive codex_guard_bridge.py to a DENY decision: $DENY_OUT"
_ok "DENY observation: rm-glob-shaped codex PreToolUse fixture drives codex_guard_bridge.py to hookSpecificOutput.permissionDecision=deny"

ALLOW_OUT="$(python3 "$BRIDGE" < "$ALLOW_FX")"
ALLOW_RC=$?
[ "$ALLOW_RC" -eq 0 ] || _fail "bridge exited non-zero on the innocuous fixture (rc=$ALLOW_RC)"
case "$ALLOW_OUT" in
  *'"permissionDecision": "deny"'*) _fail "innocuous command was denied: $ALLOW_OUT" ;;
esac
_ok "innocuous command (git status) passes through codex_guard_bridge.py without a deny decision"

MAL_OUT="$(python3 "$BRIDGE" < "$MALFORMED_FX" 2>"$TMPBASE/mal.stderr")"
MAL_RC=$?
[ "$MAL_RC" -eq 0 ] || _fail "bridge crashed (non-zero exit) on malformed input instead of degrading to allow (rc=$MAL_RC)"
case "$MAL_OUT" in
  *'"permissionDecision": "deny"'*) _fail "malformed input somehow produced a deny decision" ;;
esac
[ -s "$TMPBASE/mal.stderr" ] || _fail "malformed input did not log anything to stderr"
_ok "malformed/non-JSON input degrades to allow (exit 0, no deny, stderr note) - bridge never crashes"

GEN_SH="$INSTALL_DIR/templates/generators.sh"
ORACLE_OUT="$(bash "$INSTALL_DIR/lib/test_m3_oracle.sh" verify 2>&1)" && ORACLE_RC=0 || ORACLE_RC=$?
[ "$ORACLE_RC" -eq 0 ] || _fail "test_m3_oracle.sh verify failed after M4 gating changes (knob-off default render must stay byte-identical):
$ORACLE_OUT"
case "$ORACLE_OUT" in
  *"PASS: m3 oracle verify"*) ;;
  *) _fail "test_m3_oracle.sh did not report PASS: $ORACLE_OUT" ;;
esac
_ok "test_m3_oracle.sh verify still PASSES (CBOX_CODEX_HOOKS off/default render is byte-identical to the frozen oracle)"

ON_HOME="$TMPBASE/codex_on_home"
ON_OUT="$TMPBASE/codex_on_out"
mkdir -p "$ON_HOME" "$ON_OUT"

GEN_HARNESS="$TMPBASE/gen_codex_on_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'PROFILE_OUT="$1"'
  echo 'HOOKS_OUT="$2"'
  echo 'HOME="$3"'
  echo 'INSTALL_DIR='"'$INSTALL_DIR'"
  echo 'export INSTALL_DIR'
  echo 'CBOX_CODEX_HOOKS=on'
  echo 'export CBOX_CODEX_HOOKS'
  echo "source '$INSTALL_DIR/_common.sh'"
  echo "source '$GEN_SH'"
  echo 'gen_codex_profile_into "$PROFILE_OUT" global /opt/m4-test-workspace'
  echo 'gen_codex_hooks_json_into "$HOOKS_OUT"'
} > "$GEN_HARNESS"

bash "$GEN_HARNESS" "$ON_OUT" "$ON_OUT" "$ON_HOME" \
  || _fail "knob-on render harness failed"

PROFILE_TOML="$ON_OUT/cbox-container.config.toml"
HOOKS_JSON="$ON_OUT/hooks.json"
[ -f "$PROFILE_TOML" ] || _fail "knob-on render did not produce cbox-container.config.toml"
[ -f "$HOOKS_JSON" ] || _fail "knob-on render did not produce hooks.json"

grep -q '^\[features\]$' "$PROFILE_TOML" || _fail "CBOX_CODEX_HOOKS=on profile render is missing [features] table"
grep -q '^codex_hooks = true$' "$PROFILE_TOML" || _fail "CBOX_CODEX_HOOKS=on profile render is missing codex_hooks = true"
_ok "knob-on render: [features]\\ncodex_hooks = true appears in the codex profile toml"

python3 -c "
import json
doc = json.load(open('$HOOKS_JSON'))
pre = doc.get('hooks', {}).get('PreToolUse')
assert pre, 'no PreToolUse entries in knob-on hooks.json'
found = False
for entry in pre:
    assert entry.get('matcher') == 'Bash', 'PreToolUse matcher is not Bash-only: %r' % entry
    for h in entry.get('hooks', []):
        if 'codex_guard_bridge.py' in (h.get('command') or ''):
            found = True
assert found, 'no PreToolUse hook command references codex_guard_bridge.py'
" || _fail "knob-on hooks.json does not carry a Bash-matcher PreToolUse entry pointing at codex_guard_bridge.py"
_ok "knob-on render: hooks.json carries a Bash-only PreToolUse entry invoking codex_guard_bridge.py"

REAL_INSTALL="$INSTALL_DIR"
STAGE_DIR="$TMPBASE/hooks_stage"
mkdir -p "$STAGE_DIR/generated/hooks"
cp -r "$REAL_INSTALL/etc" "$STAGE_DIR/etc"
(
  set -euo pipefail
  INSTALL_DIR="$STAGE_DIR"
  export INSTALL_DIR
  source "$REAL_INSTALL/_common.sh"
  source "$REAL_INSTALL/templates/generators.sh"
  gen_hooks_dir
) || _fail "gen_hooks_dir failed against a staged install dir"
[ -f "$STAGE_DIR/generated/hooks/codex_guard_bridge.py" ] \
  || _fail "gen_hooks_dir did not stage codex_guard_bridge.py into generated/hooks - the knob-on hooks.json command would point at a file that never lands in the container (guard silently absent)"
_ok "deployment: gen_hooks_dir stages codex_guard_bridge.py into generated/hooks (the guard the hooks.json command points at actually lands)"

echo "PASS: codex guard dialect bridge"
