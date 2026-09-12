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

BRIDGE="$INSTALL_DIR/etc/hooks/hermes_guard_bridge.py"
FIXDIR="$INSTALL_DIR/lib/fixtures/m4"
DENY_FX="$FIXDIR/hermes_pretoolcall_rm_glob_deny.json"
ALLOW_FX="$FIXDIR/hermes_pretoolcall_innocuous_allow.json"
MALFORMED_FX="$FIXDIR/hermes_pretoolcall_malformed.json"

[ -f "$BRIDGE" ] || _fail "hermes_guard_bridge.py not found at $BRIDGE"
[ -f "$DENY_FX" ] || _fail "deny fixture missing: $DENY_FX"
[ -f "$ALLOW_FX" ] || _fail "allow fixture missing: $ALLOW_FX"
[ -f "$MALFORMED_FX" ] || _fail "malformed fixture missing: $MALFORMED_FX"

python3 -c "import py_compile; py_compile.compile('$BRIDGE', doraise=True)" \
  || _fail "hermes_guard_bridge.py does not py_compile"
_ok "hermes_guard_bridge.py py_compiles cleanly"

for fx in "$DENY_FX" "$ALLOW_FX" "$MALFORMED_FX"; do
  grep -q '"provenance": "spec"\|provenance: spec' "$fx" \
    || _fail "fixture $fx is missing the mandatory 'provenance: spec' marker"
done
_ok "all m4 hermes pre_tool_call fixtures carry the provenance:spec marker"

DENY_OUT="$(python3 "$BRIDGE" < "$DENY_FX")"
DENY_RC=$?
[ "$DENY_RC" -eq 0 ] || _fail "bridge exited non-zero on the deny fixture (rc=$DENY_RC)"
printf '%s' "$DENY_OUT" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
assert doc.get('decision') == 'block', 'decision was not block: %r' % doc
assert doc.get('reason'), 'missing reason'
" || _fail "deny fixture did not drive hermes_guard_bridge.py to a block decision: $DENY_OUT"
_ok "DENY observation: rm-glob-shaped hermes pre_tool_call fixture drives hermes_guard_bridge.py to {\"decision\": \"block\"}"

PROC_DENY_OUT="$(python3 -c "
import json, sys
doc = json.load(open('$DENY_FX'))
cmd = doc['tool_input']['command']
doc['tool_name'] = 'process'
doc['tool_input'] = {'action': 'submit', 'session_id': 'abc', 'data': cmd}
print(json.dumps(doc))
" | python3 "$BRIDGE")"
printf '%s' "$PROC_DENY_OUT" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
assert doc.get('decision') == 'block', 'process submit was not blocked: %r' % doc
" || _fail "the same rm-glob command sent as stdin through the process tool (action=submit) must be blocked, got: $PROC_DENY_OUT"
_ok "DENY observation: the process tool's submit data goes through the same rm guard as a terminal command"

PROC_POLL_OUT="$(python3 -c "
import json, sys
doc = json.load(open('$DENY_FX'))
doc['tool_name'] = 'process'
doc['tool_input'] = {'action': 'poll', 'session_id': 'abc'}
print(json.dumps(doc))
" | python3 "$BRIDGE")"
case "$PROC_POLL_OUT" in
  *'"decision": "block"'*) _fail "a process poll (no stdin) must not be blocked: $PROC_POLL_OUT" ;;
esac
_ok "process actions that send no stdin pass through"

python3 "$INSTALL_DIR/etc/adapters/hermes.py" hooks-yaml /home/x/.claude/hooks | grep -q 'matcher: terminal|process' \
  || _fail "the rendered hooks block must match the process tool as well as terminal"
_ok "render: the hooks block matcher covers terminal and process"

ALLOW_OUT="$(python3 "$BRIDGE" < "$ALLOW_FX")"
ALLOW_RC=$?
[ "$ALLOW_RC" -eq 0 ] || _fail "bridge exited non-zero on the innocuous fixture (rc=$ALLOW_RC)"
case "$ALLOW_OUT" in
  *'"decision": "block"'*) _fail "innocuous command was blocked: $ALLOW_OUT" ;;
esac
_ok "innocuous command (git status) passes through hermes_guard_bridge.py without a block decision"

MAL_OUT="$(python3 "$BRIDGE" < "$MALFORMED_FX" 2>"$TMPBASE/mal.stderr")"
MAL_RC=$?
[ "$MAL_RC" -eq 0 ] || _fail "bridge crashed (non-zero exit) on malformed input instead of degrading to allow (rc=$MAL_RC)"
case "$MAL_OUT" in
  *'"decision": "block"'*) _fail "malformed input somehow produced a block decision" ;;
esac
[ -s "$TMPBASE/mal.stderr" ] || _fail "malformed input did not log anything to stderr"
_ok "malformed/non-JSON input degrades to allow (exit 0, no block, stderr note) - bridge never crashes (fail-open armor proven)"

GEN_SH="$INSTALL_DIR/templates/generators.sh"
ORACLE_OUT="$(bash "$INSTALL_DIR/lib/test_m3_oracle.sh" verify 2>&1)" && ORACLE_RC=0 || ORACLE_RC=$?
[ "$ORACLE_RC" -eq 0 ] || _fail "test_m3_oracle.sh verify failed after M4 gating changes (knob-off default render must stay byte-identical):
$ORACLE_OUT"
case "$ORACLE_OUT" in
  *"PASS: m3 oracle verify"*) ;;
  *) _fail "test_m3_oracle.sh did not report PASS: $ORACLE_OUT" ;;
esac
_ok "test_m3_oracle.sh verify still PASSES (CBOX_HERMES_HOOKS off/default render is byte-identical to the frozen oracle)"

HERMES_GEN_OUT="$(bash "$INSTALL_DIR/lib/test_hermes_gen.sh" 2>&1)" && HERMES_GEN_RC=0 || HERMES_GEN_RC=$?
[ "$HERMES_GEN_RC" -eq 0 ] || _fail "test_hermes_gen.sh failed after M4 gating changes:
$HERMES_GEN_OUT"
case "$HERMES_GEN_OUT" in
  *"PASS: all hermes_gen checks"*) ;;
  *) _fail "test_hermes_gen.sh did not report PASS: $HERMES_GEN_OUT" ;;
esac
_ok "test_hermes_gen.sh still PASSES"

ON_HOME="$TMPBASE/hermes_on_home"
ON_OUT="$TMPBASE/hermes_on_out"
mkdir -p "$ON_HOME/.claude/hooks" "$ON_OUT"

GEN_HARNESS="$TMPBASE/gen_hermes_hooks_on_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'TARGET="$1"'
  echo 'HOME="$2"'
  echo 'INSTALL_DIR='"'$INSTALL_DIR'"
  echo 'export INSTALL_DIR'
  echo 'CBOX_HERMES_HOOKS=on'
  echo 'export CBOX_HERMES_HOOKS'
  echo "source '$INSTALL_DIR/_common.sh'"
  echo "source '$GEN_SH'"
  echo 'gen_hermes_hooks_into "$TARGET"'
} > "$GEN_HARNESS"

bash "$GEN_HARNESS" "$ON_OUT/hooks.yaml" "$ON_HOME" \
  || _fail "knob-on hermes hooks render harness failed"

[ -f "$ON_OUT/hooks.yaml" ] || _fail "knob-on render did not produce hooks.yaml"
grep -q '^hooks:$' "$ON_OUT/hooks.yaml" || _fail "CBOX_HERMES_HOOKS=on render is missing the hooks: key"
grep -q 'pre_tool_call:' "$ON_OUT/hooks.yaml" || _fail "CBOX_HERMES_HOOKS=on render is missing pre_tool_call:"
grep -q 'hermes_guard_bridge.py' "$ON_OUT/hooks.yaml" || _fail "CBOX_HERMES_HOOKS=on render does not reference hermes_guard_bridge.py"
_ok "knob-on render: gen_hermes_hooks_into produces a hooks: pre_tool_call block invoking hermes_guard_bridge.py"

_validator_body() {
  local file="$1" fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) \\{" { grab=1; next }
    grab && /^\}/ { exit }
    grab { print }
  ' "$file"
}

_apply_hooks_func() {
  awk '
    /^_hermes_apply_hooks\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^PY$/ { sawpy++; if (sawpy == 1) next }
    infunc && sawpy >= 1 && /^\}/ { exit }
  ' "$INSTALL_DIR/entrypoint.sh"
}

APPLY_HOOKS_FUNC="$TMPBASE/apply_hooks_func.sh"
_apply_hooks_func > "$APPLY_HOOKS_FUNC"
[ -s "$APPLY_HOOKS_FUNC" ] || _fail "could not extract _hermes_apply_hooks from entrypoint.sh"

APPLY_CFG_DIR="$TMPBASE/apply_hooks_cfg"
mkdir -p "$APPLY_CFG_DIR"
cat > "$APPLY_CFG_DIR/config.yaml" <<'EOF'
model:
  provider: local
hooks:
  pre_tool_call:
    - matcher: terminal
      command: "stale-command"
agent:
  iteration_budget: 40
EOF
cp "$ON_OUT/hooks.yaml" "$APPLY_CFG_DIR/hooks.yaml"
(
  _as_user() { "$@"; }
  HERMES_HOME="$APPLY_CFG_DIR"
  source "$APPLY_HOOKS_FUNC"
  _hermes_apply_hooks "$APPLY_CFG_DIR/hooks.yaml" "$APPLY_CFG_DIR/config.yaml"
)
grep -q 'stale-command' "$APPLY_CFG_DIR/config.yaml" \
  && _fail "_hermes_apply_hooks left the stale hooks block in place instead of replacing it:
$(cat "$APPLY_CFG_DIR/config.yaml")"
grep -q 'hermes_guard_bridge.py' "$APPLY_CFG_DIR/config.yaml" \
  || _fail "_hermes_apply_hooks did not write the new hooks block:
$(cat "$APPLY_CFG_DIR/config.yaml")"
grep -q 'iteration_budget: 40' "$APPLY_CFG_DIR/config.yaml" \
  || _fail "_hermes_apply_hooks clobbered an unrelated key outside the hooks: block:
$(cat "$APPLY_CFG_DIR/config.yaml")"
_ok "_hermes_apply_hooks EXECUTED: replaces only the hooks: block in config.yaml, other keys (model, agent) untouched"

APPLY_CFG_DIR2="$TMPBASE/apply_hooks_cfg_absent"
mkdir -p "$APPLY_CFG_DIR2"
cp "$APPLY_CFG_DIR/config.yaml" "$APPLY_CFG_DIR2/config.yaml"
BEFORE_SHA="$(sha256sum "$APPLY_CFG_DIR2/config.yaml" | awk '{print $1}')"
(
  _as_user() { "$@"; }
  HERMES_HOME="$APPLY_CFG_DIR2"
  source "$APPLY_HOOKS_FUNC"
  _hermes_apply_hooks "$APPLY_CFG_DIR2/does-not-exist.yaml" "$APPLY_CFG_DIR2/config.yaml"
)
AFTER_SHA="$(sha256sum "$APPLY_CFG_DIR2/config.yaml" | awk '{print $1}')"
[ "$BEFORE_SHA" = "$AFTER_SHA" ] \
  || _fail "_hermes_apply_hooks modified config.yaml when the source hooks.yaml was absent - absent must mean untouched (knob-off container behavior), not an empty-block replace"
_ok "_hermes_apply_hooks EXECUTED: a missing source file (hermes-hooks knob off) leaves config.yaml byte-identical - untouched, not replaced with an empty block"

REGEN_FUNC="$TMPBASE/regen_all_body.sh"
_validator_body "$INSTALL_DIR/templates/generators.sh" regen_all > "$REGEN_FUNC"
grep -q "gen_hermes_hooks_into" "$REGEN_FUNC" \
  || _fail "regen_all does not call gen_hermes_hooks_into when CBOX_HERMES=on and CBOX_HERMES_HOOKS=on"
_ok "regen_all calls gen_hermes_hooks_into under the CBOX_HERMES_HOOKS gate"
grep -q 'rm -f "\$INSTALL_DIR/generated/hermes/hooks.yaml"' "$REGEN_FUNC" \
  || _fail "regen_all does not remove a stale generated/hermes/hooks.yaml on toggle-off (either CBOX_HERMES=off or CBOX_HERMES_HOOKS=off)"
_ok "regen_all: a stale generated/hermes/hooks.yaml is cleaned up on both toggle-off paths (static check, no network-dependent full regen_all execution)"

ENTRY_SH="$INSTALL_DIR/entrypoint.sh"
PREFLIGHT_BODY="$TMPBASE/hermes_hooks_preflight_body.sh"
_validator_body "$ENTRY_SH" _hermes_hooks_preflight > "$PREFLIGHT_BODY"
[ -s "$PREFLIGHT_BODY" ] || _fail "_hermes_hooks_preflight not found in entrypoint.sh"
_ok "_hermes_hooks_preflight exists in entrypoint.sh (sibling of _codex_profile_preflight)"

PREFLIGHT_SCRIPT="$TMPBASE/run_hermes_hooks_preflight.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo '_hermes_hooks_preflight() {'
  cat "$PREFLIGHT_BODY"
  echo '}'
  echo '_hermes_hooks_preflight "$@"'
} > "$PREFLIGHT_SCRIPT"
chmod 0755 "$PREFLIGHT_SCRIPT"

PREFLIGHT_UNPRIV=""
if [ "$(id -u)" = 0 ]; then
  if command -v setpriv >/dev/null 2>&1 && getent passwd nobody >/dev/null 2>&1; then
    PREFLIGHT_UNPRIV="setpriv --reuid=$(id -u nobody) --regid=$(id -g nobody) --clear-groups"
    chmod 0755 "$TMPBASE"
  else
    echo "SKIP: no setpriv/nobody available to drop root for the writability preflight checks (root bypasses chmod bits) - preflight function-existence check above still ran" >&2
    echo "PASS: hermes guard dialect bridge (writability sub-checks skipped, no unprivileged runner available)"
    exit 0
  fi
fi

_run_preflight() {
  if [ -n "$PREFLIGHT_UNPRIV" ]; then
    $PREFLIGHT_UNPRIV bash "$PREFLIGHT_SCRIPT" "$@"
  else
    bash "$PREFLIGHT_SCRIPT" "$@"
  fi
}

PF_DIR="$TMPBASE/preflight"
mkdir -p "$PF_DIR"
HOOKS_SRC="$PF_DIR/hooks.yaml"
BRIDGE_COPY="$PF_DIR/hermes_guard_bridge.py"
COMMIT_COPY="$PF_DIR/commit_guard.py"
RMGLOB_COPY="$PF_DIR/rm_glob_guard.py"
printf 'hooks:\n  pre_tool_call:\n    - matcher: terminal\n' > "$HOOKS_SRC"
cp "$BRIDGE" "$BRIDGE_COPY"
cp "$INSTALL_DIR/etc/hooks/commit_guard.py" "$COMMIT_COPY"
cp "$INSTALL_DIR/etc/hooks/rm_glob_guard.py" "$RMGLOB_COPY"
if [ -n "$PREFLIGHT_UNPRIV" ]; then
  chown -R nobody:nogroup "$PF_DIR"
fi

chmod 0644 "$HOOKS_SRC" "$BRIDGE_COPY" "$COMMIT_COPY" "$RMGLOB_COPY"
if _run_preflight "$HOOKS_SRC" "$BRIDGE_COPY" "$COMMIT_COPY" "$RMGLOB_COPY" 2>"$TMPBASE/pf_writable.stderr"; then
  _fail "_hermes_hooks_preflight PASSED against a writable hooks.yaml - the adapter-law refusal did not fire"
fi
[ -s "$TMPBASE/pf_writable.stderr" ] || _fail "_hermes_hooks_preflight refused silently (no re-bless message on stderr)"
grep -qi "re-bless\|writable" "$TMPBASE/pf_writable.stderr" \
  || _fail "_hermes_hooks_preflight refusal message does not mention re-bless/writable: $(cat "$TMPBASE/pf_writable.stderr")"
_ok "PREFLIGHT REFUSE observation: a writable rendered hooks.yaml is refused (adapter law), non-zero exit + host-re-bless stderr message"

chmod 0444 "$HOOKS_SRC" "$BRIDGE_COPY" "$COMMIT_COPY" "$RMGLOB_COPY"
if ! _run_preflight "$HOOKS_SRC" "$BRIDGE_COPY" "$COMMIT_COPY" "$RMGLOB_COPY" 2>"$TMPBASE/pf_readonly.stderr"; then
  chmod 0644 "$HOOKS_SRC" "$BRIDGE_COPY" "$COMMIT_COPY" "$RMGLOB_COPY"
  _fail "_hermes_hooks_preflight REFUSED against a read-only hooks.yaml + read-only scripts: $(cat "$TMPBASE/pf_readonly.stderr")"
fi
chmod 0644 "$HOOKS_SRC" "$BRIDGE_COPY" "$COMMIT_COPY" "$RMGLOB_COPY"
_ok "PREFLIGHT PASS observation: an unwritable rendered hooks.yaml + unwritable guard scripts pass the preflight"

WRITABLE_SCRIPT_DIR="$TMPBASE/preflight_script_writable"
mkdir -p "$WRITABLE_SCRIPT_DIR"
cp "$HOOKS_SRC" "$WRITABLE_SCRIPT_DIR/hooks.yaml"
cp "$BRIDGE_COPY" "$WRITABLE_SCRIPT_DIR/hermes_guard_bridge.py"
cp "$COMMIT_COPY" "$WRITABLE_SCRIPT_DIR/commit_guard.py"
cp "$RMGLOB_COPY" "$WRITABLE_SCRIPT_DIR/rm_glob_guard.py"
if [ -n "$PREFLIGHT_UNPRIV" ]; then
  chown -R nobody:nogroup "$WRITABLE_SCRIPT_DIR"
fi
chmod 0444 "$WRITABLE_SCRIPT_DIR/hooks.yaml" "$WRITABLE_SCRIPT_DIR/hermes_guard_bridge.py" "$WRITABLE_SCRIPT_DIR/commit_guard.py"
chmod 0644 "$WRITABLE_SCRIPT_DIR/rm_glob_guard.py"
if _run_preflight "$WRITABLE_SCRIPT_DIR/hooks.yaml" "$WRITABLE_SCRIPT_DIR/hermes_guard_bridge.py" "$WRITABLE_SCRIPT_DIR/commit_guard.py" "$WRITABLE_SCRIPT_DIR/rm_glob_guard.py" 2>/dev/null; then
  chmod 0644 "$WRITABLE_SCRIPT_DIR"/*.py "$WRITABLE_SCRIPT_DIR"/*.yaml
  _fail "_hermes_hooks_preflight PASSED with an unwritable hooks.yaml but a WRITABLE referenced script (rm_glob_guard.py) - the referenced-scripts check is not enforced"
fi
chmod 0644 "$WRITABLE_SCRIPT_DIR"/*.py "$WRITABLE_SCRIPT_DIR"/*.yaml
_ok "PREFLIGHT REFUSE observation: an unwritable hooks.yaml with ONE writable referenced script (rm_glob_guard.py) is still refused"

echo "PASS: hermes guard dialect bridge"
