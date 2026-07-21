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

python3 -c "import json; json.load(open('$INSTALL_DIR/etc/mcp/delegates.json'))" \
  || _fail "delegates.json does not parse as JSON"
_ok "delegates.json parses as JSON"

python3 -c "
import json
data = json.load(open('$INSTALL_DIR/etc/mcp/delegates.json'))
assert 'hermes-local' in data, data.keys()
spec = data['hermes-local']
assert spec['type'] == 'stdio', spec
assert spec['command'] == 'python3', spec
assert spec['args'] == ['hermes_delegate_mcp.py'], spec
cbox = spec['_cbox']
assert cbox['adapter'] == 'stdio-mcp', cbox
assert cbox['available_to'] == ['claude'], cbox
assert cbox['backend'] == 'hermes', cbox
assert cbox['enabled_when_env'] == 'CBOX_HERMES_DELEGATE', cbox
assert 'spawns-hermes-subprocess' in cbox['side_effects'], cbox
"
_ok "hermes-local entry shape matches the stdio-mcp delegate contract"

RENDERED_ABSENT="$TMPBASE/absent.json"
env -u CBOX_HERMES_DELEGATE \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_ABSENT"
python3 -c "
import json
data = json.load(open('$RENDERED_ABSENT'))
assert 'hermes-local' not in data, data.keys()
"
_ok "hermes-local is absent from selection=all render when CBOX_HERMES_DELEGATE is unset"

ERR_EXPLICIT="$TMPBASE/explicit.err"
if env -u CBOX_HERMES_DELEGATE \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" hermes-local "/home/x/.claude/hooks" off claude \
  >/dev/null 2>"$ERR_EXPLICIT"; then
  _fail "render_mcp.py accepted an explicit hermes-local selection with CBOX_HERMES_DELEGATE unset"
fi
grep -q "explicitly selected but CBOX_HERMES_DELEGATE is not set" "$ERR_EXPLICIT" \
  || _fail "render_mcp.py refusal message missing for unconfigured explicit hermes-local selection"
_ok "render_mcp.py refuses an explicit unconfigured hermes-local selection loudly"

RENDERED_OFF_EXPORTED="$TMPBASE/off_exported.json"
CBOX_HERMES_DELEGATE=off \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_OFF_EXPORTED"
python3 -c "
import json
data = json.load(open('$RENDERED_OFF_EXPORTED'))
assert 'hermes-local' not in data, data.keys()
"
_ok "hermes-local is absent from selection=all render when CBOX_HERMES_DELEGATE=off is explicitly exported"

RENDERED_PRESENT="$TMPBASE/present.json"
CBOX_HERMES_DELEGATE=on \
CBOX_HERMES_DELEGATE_BIN=/opt/hermes/bin/hermes \
CBOX_HERMES_DELEGATE_HOME_TEMPLATE=/etc/cbox/hermes-delegate-home \
CBOX_HERMES_DELEGATE_PROVIDER=local \
CBOX_HERMES_DELEGATE_BASE_URL=http://127.0.0.1:11434 \
CBOX_HERMES_DELEGATE_MODEL=qwen2.5:7b \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_PRESENT"
python3 -c "
import json
data = json.load(open('$RENDERED_PRESENT'))
assert 'hermes-local' in data, data.keys()
spec = data['hermes-local']
assert spec['command'] == 'python3', spec
assert spec['args'] == ['hermes_delegate_mcp.py'], spec
assert spec['env'] == {
    'HERMES_BIN': '/opt/hermes/bin/hermes',
    'CBOX_HERMES_DELEGATE_HOME_TEMPLATE': '/etc/cbox/hermes-delegate-home',
    'CBOX_HERMES_DELEGATE_PROVIDER': 'local',
    'CBOX_HERMES_DELEGATE_BASE_URL': 'http://127.0.0.1:11434',
    'CBOX_HERMES_DELEGATE_MODEL': 'qwen2.5:7b',
}, spec
"
_ok "hermes-local renders with substituted env when CBOX_HERMES_DELEGATE and inputs are set"

RENDERED_CODEX="$TMPBASE/codex.json"
CBOX_HERMES_DELEGATE=on \
CBOX_HERMES_DELEGATE_BIN=/opt/hermes/bin/hermes \
CBOX_HERMES_DELEGATE_HOME_TEMPLATE=/etc/cbox/hermes-delegate-home \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex > "$RENDERED_CODEX"
python3 -c "
import json
data = json.load(open('$RENDERED_CODEX'))
assert 'hermes-local' not in data, data.keys()
assert sorted(data.keys()) == ['ask-claude'], data.keys()
"
_ok "hermes-local is not available_to codex (claude only in v1)"

RENDERED_GATE="$TMPBASE/gate.json"
CBOX_HERMES_DELEGATE=on \
CBOX_HERMES_DELEGATE_BIN=/opt/hermes/bin/hermes \
CBOX_HERMES_DELEGATE_HOME_TEMPLATE=/etc/cbox/hermes-delegate-home \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_GATE"
HOSTHOME="$TMPBASE/hosthome_hermes_delegate"
mkdir -p "$HOSTHOME"
python3 - "$RENDERED_GATE" "$HOSTHOME/.claude.json" <<'PYEOF'
import json, sys
rendered_file, out = sys.argv[1:3]
with open(rendered_file) as f:
    rendered = json.load(f)
data = {"hasCompletedOnboarding": True, "mcpServers": rendered}
with open(out, "w") as f:
    json.dump(data, f, separators=(",", ":"))
PYEOF
GATEFUNC="$TMPBASE/gate_func_hermes_delegate.sh"
awk '
  /^_check_codex_mcp_shim_seed(_one)?\(\) \{/ { infunc=1 }
  infunc { print }
  infunc && /^\}/ { infunc=0 }
' "$INSTALL_DIR/entrypoint.sh" > "$GATEFUNC"
if ! ( HOST_HOME="$HOSTHOME"; source "$GATEFUNC"; _check_codex_mcp_shim_seed ); then
  _fail "entrypoint boot gate rejected a seed containing a well-formed hermes-local entry"
fi
_ok "hermes-local is invisible to the entrypoint boot gate (not named codex-*) once configured"

_dep_gate_body() {
  awk '
    /^_cbox_dep_condition\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0; exit }
  ' "$INSTALL_DIR/setup.sh"
}

SECFUNC="$TMPBASE/sections.sh"
cp "$INSTALL_DIR/templates/sections.sh" "$SECFUNC"
DEPFUNC="$TMPBASE/dep_gate.sh"
{
  _dep_gate_body
  awk '
    /^section_dep_gate\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0; exit }
  ' "$INSTALL_DIR/setup.sh"
} > "$DEPFUNC"

DEP_RESULT="$(
  CBOX_HERMES=off
  source "$SECFUNC"
  source "$DEPFUNC"
  section_dep_gate hermes-delegate
  printf '%s %s' "$DEP_ACTION" "$DEP_REASON"
)"
case "$DEP_RESULT" in
  disable\ *) _ok "dep-gate: CBOX_HERMES=off forces hermes-delegate to disable ($DEP_RESULT)" ;;
  *) _fail "dep-gate did not disable hermes-delegate when CBOX_HERMES=off (got: $DEP_RESULT)" ;;
esac

DEP_RESULT_ON="$(
  CBOX_HERMES=on
  source "$SECFUNC"
  source "$DEPFUNC"
  section_dep_gate hermes-delegate
  printf '%s' "$DEP_ACTION"
)"
[ "$DEP_RESULT_ON" = ok ] \
  || _fail "dep-gate disabled hermes-delegate when CBOX_HERMES=on (got: $DEP_RESULT_ON)"
_ok "dep-gate: CBOX_HERMES=on leaves hermes-delegate ungated"

echo "PASS: all hermes_delegate_render checks"
