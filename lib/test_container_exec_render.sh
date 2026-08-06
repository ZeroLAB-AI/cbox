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
assert 'container-exec' in data, data.keys()
spec = data['container-exec']
assert spec['type'] == 'stdio', spec
assert spec['command'] == 'python3', spec
assert spec['args'] == ['container_exec_mcp.py'], spec
cbox = spec['_cbox']
assert cbox['adapter'] == 'stdio-mcp', cbox
assert cbox['available_to'] == ['claude', 'codex', 'hermes'], cbox
assert cbox['enabled_when_env'] == 'CBOX_CONTAINER_EXEC_TOOL', cbox
assert 'spawns-docker-exec-subprocess' in cbox['side_effects'], cbox
"
_ok "container-exec entry shape matches the stdio-mcp delegate contract"

RENDERED_ABSENT="$TMPBASE/absent.json"
env -u CBOX_CONTAINER_EXEC_TOOL \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_ABSENT"
python3 -c "
import json
data = json.load(open('$RENDERED_ABSENT'))
assert 'container-exec' not in data, data.keys()
"
_ok "container-exec is absent from selection=all render when CBOX_CONTAINER_EXEC_TOOL is unset"

ERR_EXPLICIT="$TMPBASE/explicit.err"
if env -u CBOX_CONTAINER_EXEC_TOOL \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" container-exec "/home/x/.claude/hooks" off claude \
  >/dev/null 2>"$ERR_EXPLICIT"; then
  _fail "render_mcp.py accepted an explicit container-exec selection with CBOX_CONTAINER_EXEC_TOOL unset"
fi
grep -q "explicitly selected but CBOX_CONTAINER_EXEC_TOOL is not set" "$ERR_EXPLICIT" \
  || _fail "render_mcp.py refusal message missing for unconfigured explicit container-exec selection"
_ok "render_mcp.py refuses an explicit unconfigured container-exec selection loudly"

RENDERED_OFF_EXPORTED="$TMPBASE/off_exported.json"
CBOX_CONTAINER_EXEC_TOOL=off \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_OFF_EXPORTED"
python3 -c "
import json
data = json.load(open('$RENDERED_OFF_EXPORTED'))
assert 'container-exec' not in data, data.keys()
"
_ok "container-exec is absent from selection=all render when CBOX_CONTAINER_EXEC_TOOL=off is explicitly exported"

RENDERED_PRESENT="$TMPBASE/present.json"
CBOX_CONTAINER_EXEC_TOOL=on \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_PRESENT"
python3 -c "
import json
data = json.load(open('$RENDERED_PRESENT'))
assert 'container-exec' in data, data.keys()
spec = data['container-exec']
assert spec['command'] == 'python3', spec
assert spec['args'] == ['/home/x/.claude/hooks/container_exec_mcp.py'], spec
assert spec['startup_timeout_sec'] == 30, spec
assert spec['tool_timeout_sec'] == 3600, spec
"
_ok "container-exec renders for claude when CBOX_CONTAINER_EXEC_TOOL=on"

RENDERED_CODEX_ABSENT="$TMPBASE/codex_absent.json"
env -u CBOX_CONTAINER_EXEC_TOOL \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex > "$RENDERED_CODEX_ABSENT"
python3 -c "
import json
data = json.load(open('$RENDERED_CODEX_ABSENT'))
assert 'container-exec' not in data, data.keys()
assert sorted(data.keys()) == ['ask-claude'], data.keys()
"
_ok "container-exec is absent from codex target render when CBOX_CONTAINER_EXEC_TOOL is unset"

RENDERED_CODEX="$TMPBASE/codex.json"
CBOX_CONTAINER_EXEC_TOOL=on \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex > "$RENDERED_CODEX"
python3 -c "
import json
data = json.load(open('$RENDERED_CODEX'))
assert sorted(data.keys()) == ['ask-claude', 'container-exec'], data.keys()
"
_ok "container-exec is available_to codex when CBOX_CONTAINER_EXEC_TOOL=on (ask-claude still present)"

RENDERED_GATE="$TMPBASE/gate.json"
CBOX_CONTAINER_EXEC_TOOL=on \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_GATE"
HOSTHOME="$TMPBASE/hosthome_container_exec"
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
GATEFUNC="$TMPBASE/gate_func_container_exec.sh"
awk '
  /^_check_codex_mcp_shim_seed(_one)?\(\) \{/ { infunc=1 }
  infunc { print }
  infunc && /^\}/ { infunc=0 }
' "$INSTALL_DIR/entrypoint.sh" > "$GATEFUNC"
if ! ( HOST_HOME="$HOSTHOME"; source "$GATEFUNC"; _check_codex_mcp_shim_seed ); then
  _fail "entrypoint boot gate rejected a seed containing a well-formed container-exec entry"
fi
_ok "container-exec is invisible to the entrypoint boot gate (not named codex-*) once configured"

_dep_gate_body() {
  awk '
    /^_cbox_dep_condition\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0; exit }
  ' "$INSTALL_DIR/setup.sh"
}

python3 -c "
import json
data = json.load(open('$INSTALL_DIR/etc/registry/settings.json'))
match = [v for v in data['variables'] if v['key'] == 'CBOX_CONTAINER_EXEC_TOOL']
assert len(match) == 1, match
var = match[0]
assert var['default'] == 'off', var
assert var['export'] is True, var
assert var['section'] == 'netaccess', var
"
_ok "CBOX_CONTAINER_EXEC_TOOL registry entry defaults off and is exported"

grep -q "CBOX_CONTAINER_EXEC_TOOL" "$INSTALL_DIR/templates/conf_lib.sh" \
  || _fail "templates/conf_lib.sh does not mention CBOX_CONTAINER_EXEC_TOOL (stale generated file)"
EXPORT_LIST="$(awk '
  /^_cbox_reg_export_vars\(\) \{/ { infunc=1; next }
  infunc && /^\}/ { infunc=0 }
  infunc { print }
' "$INSTALL_DIR/templates/conf_lib.sh" | grep -Eo '^[[:space:]]*export[[:space:]]+.*' | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
case " $EXPORT_LIST " in
  *" CBOX_CONTAINER_EXEC_TOOL "*) _ok "CBOX_CONTAINER_EXEC_TOOL is in the generated _cbox_reg_export_vars export list (the gate reaches render_mcp.py's os.environ)" ;;
  *) _fail "CBOX_CONTAINER_EXEC_TOOL missing from the generated _cbox_reg_export_vars export list - render_mcp.py would never see it, reproducing the dead-gate trap" ;;
esac

echo "PASS: all container_exec_render checks"
