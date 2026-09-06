#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_all_names() {
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(" ".join(sorted(data.keys())))
'
}

_render() {
  local selection="$1" progress="$2" out="$3"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" "$selection" \
    "/home/x/.claude/hooks" "$progress" claude > "$out"
}

_seed_shape() {
  local rendered="$1" out="$2"
  python3 - "$rendered" "$out" <<'PY'
import json
import sys

rendered_path, out_path = sys.argv[1], sys.argv[2]
mcp = json.load(open(rendered_path))
text = json.dumps(
    {"hasCompletedOnboarding": True, "mcpServers": mcp},
    separators=(",", ":"),
)
with open(out_path, "w") as fh:
    fh.write(text)
PY
}

test_render_byte_identity_progress_off() {
  local all
  all="$(_all_names)"
  _render "$all" off "$TMPBASE/render_off.json"
  local got want
  got="$(sha256sum "$TMPBASE/render_off.json" | awk '{print $1}')"
  want="5f586d02a69b55441334653cb2ce85f5e7b6335ede37f39cfdd2031686b44e16"
  [ "$got" = "$want" ] || _fail "render selection=all progress=off changed (got $got want $want)"
  echo "PASS: render byte-identity progress=off"
}

test_render_byte_identity_progress_on() {
  local all
  all="$(_all_names)"
  _render "$all" on "$TMPBASE/render_on.json"
  local got want
  got="$(sha256sum "$TMPBASE/render_on.json" | awk '{print $1}')"
  want="26fb1f3159c8266bd590d19453f42cca2e7e53d1ee96826be9e9f70511cbbff4"
  [ "$got" = "$want" ] || _fail "render selection=all progress=on changed (got $got want $want)"
  echo "PASS: render byte-identity progress=on"
}

test_seed_shape_byte_identity() {
  local all
  all="$(_all_names)"
  _render "$all" off "$TMPBASE/render_off2.json"
  _seed_shape "$TMPBASE/render_off2.json" "$TMPBASE/seed_off.json"
  local got want
  got="$(sha256sum "$TMPBASE/seed_off.json" | awk '{print $1}')"
  want="1721ccbf2432263426a8a8642280a0697c23ff0bd8cc8ce266ddf227946d7f38"
  [ "$got" = "$want" ] || _fail "seed shape progress=off changed (got $got want $want)"

  _render "$all" on "$TMPBASE/render_on2.json"
  _seed_shape "$TMPBASE/render_on2.json" "$TMPBASE/seed_on.json"
  got="$(sha256sum "$TMPBASE/seed_on.json" | awk '{print $1}')"
  want="864c24e5d9bad4b0299d87b7a19331fde296dd9ef63cd82bc423abad994ad921"
  [ "$got" = "$want" ] || _fail "seed shape progress=on changed (got $got want $want)"
  echo "PASS: seed shape byte-identity (gen_claude_json_seed consumer)"
}

test_merge_mcp_json_call_site() {
  local extracted="$TMPBASE/setup_functions.sh"
  awk '
    /^merge_mcp_json\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/lib/cbox-setup.sh" > "$extracted"
  die() { echo "die: $*" >&2; exit 1; }
  ETC_DIR="$INSTALL_DIR/etc"
  source "$extracted"
  local target="$TMPBASE/merge_target.json"
  echo '{"mcpServers":{}}' > "$target"
  local all
  all="$(_all_names)"
  merge_mcp_json "$target" "$INSTALL_DIR/etc/mcp/delegates.json" "$all" "$TMPBASE/merge_out.json" off "/home/x"
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
assert set(data["mcpServers"].keys()) == set(sys.argv[2].split()), data["mcpServers"].keys()
for name, spec in data["mcpServers"].items():
    assert spec["command"] == "python3", (name, spec)
    assert any(a.endswith("codex_mcp_shim.py") for a in spec["args"]), (name, spec)
' "$TMPBASE/merge_out.json" "$all"
  echo "PASS: merge_mcp_json call site (setup.sh consumer) wraps every selected codex-* entry"
}

test_shim_argv_contract_per_tier() {
  local all name
  all="$(_all_names)"
  for name in $all; do
    _render "$name" off "$TMPBASE/one_$name.json"
    python3 - "$TMPBASE/one_$name.json" "$name" "$INSTALL_DIR/etc/mcp/delegates.json" <<'PY'
import json
import sys

rendered_path, name, servers_path = sys.argv[1:4]
rendered = json.load(open(rendered_path))
servers = json.load(open(servers_path))
spec = rendered[name]
cbox = servers[name]["_cbox"]
assert spec["command"] == "python3", spec
args = spec["args"]
assert args[0].endswith("/codex_mcp_shim.py"), args
assert args[1:9] == [
    "--tier", name,
    "--model", cbox["model"],
    "--effort", cbox["model_reasoning_effort"],
    "--progress", "off",
], args
assert args[9] == "--", args
assert args[10:] == ["codex", "mcp-server"], args
PY
  done
  echo "PASS: shim argv contract holds for every tier"
}

test_entrypoint_gate_passes_on_golden_seed() {
  local hosthome="$TMPBASE/hosthome_good"
  mkdir -p "$hosthome"
  local all
  all="$(_all_names)"
  _render "$all" on "$TMPBASE/gate_render.json"
  _seed_shape "$TMPBASE/gate_render.json" "$hosthome/.claude.json"
  local gatefunc="$TMPBASE/gate_func.sh"
  awk '
    /^_check_codex_mcp_shim_seed(_one)?\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/entrypoint.sh" > "$gatefunc"
  if ! ( HOST_HOME="$hosthome"; source "$gatefunc"; _check_codex_mcp_shim_seed ); then
    _fail "entrypoint boot gate rejected a well-formed golden seed"
  fi
  echo "PASS: entrypoint boot gate accepts the golden seed"
}

test_entrypoint_gate_fails_on_tampered_seed() {
  local hosthome="$TMPBASE/hosthome_bad"
  mkdir -p "$hosthome"
  python3 -c '
import json
import sys
d = {"hasCompletedOnboarding": True, "mcpServers": {"codex-sol": {"type": "stdio", "command": "codex", "args": ["mcp-server"]}}}
json.dump(d, open(sys.argv[1], "w"))
' "$hosthome/.claude.json"
  local gatefunc="$TMPBASE/gate_func2.sh"
  awk '
    /^_check_codex_mcp_shim_seed(_one)?\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/entrypoint.sh" > "$gatefunc"
  if ( HOST_HOME="$hosthome"; source "$gatefunc"; _check_codex_mcp_shim_seed ) 2>/dev/null; then
    _fail "entrypoint boot gate accepted a tampered (unwrapped codex-*) seed"
  fi
  echo "PASS: entrypoint boot gate refuses a tampered seed"
}

test_entrypoint_gate_checks_active_config_dir_state() {
  local hosthome="$TMPBASE/hosthome_active"
  local cfgdir="$TMPBASE/hosthome_active/.claude-cbox"
  mkdir -p "$cfgdir"
  local all
  all="$(_all_names)"
  _render "$all" on "$TMPBASE/gate_render_active.json"
  _seed_shape "$TMPBASE/gate_render_active.json" "$hosthome/.claude.json"
  python3 -c '
import json
import sys
d = {"hasCompletedOnboarding": True, "mcpServers": {"codex-sol": {"type": "stdio", "command": "codex", "args": ["mcp-server"]}}}
json.dump(d, open(sys.argv[1], "w"))
' "$cfgdir/.claude.json"
  local gatefunc="$TMPBASE/gate_func_active.sh"
  awk '
    /^_check_codex_mcp_shim_seed(_one)?\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/entrypoint.sh" > "$gatefunc"
  if ( HOST_HOME="$hosthome"; CLAUDE_CONFIG_DIR="$cfgdir"; source "$gatefunc"; _check_codex_mcp_shim_seed ) 2>/dev/null; then
    _fail "entrypoint boot gate ignored a tampered active state in CLAUDE_CONFIG_DIR"
  fi
  if ! ( HOST_HOME="$hosthome"; source "$gatefunc"; _check_codex_mcp_shim_seed ); then
    _fail "entrypoint boot gate rejected a clean host seed when CLAUDE_CONFIG_DIR is unset"
  fi
  echo "PASS: entrypoint boot gate validates the active CLAUDE_CONFIG_DIR state too"
}

test_codex_profile_toml_golden_mcp0() {
  local outdir="$TMPBASE/profile_mcp0"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="/home/x"
    export CBOX_WORKSPACES="/zerolab/agent_ecosystem"
    export CBOX_CODEX_MCP=0
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_profile_into "$outdir" global ""
  )
  local got want
  got="$(sha256sum "$outdir/cbox-container.config.toml" | awk '{print $1}')"
  want="897009040fddfa1b1019ba5c85b2ea37cfc0a3edb6dd324ce688e4bf4b1297f1"
  [ "$got" = "$want" ] || _fail "codex profile TOML (CBOX_CODEX_MCP=0) changed (got $got want $want)"
  echo "PASS: codex profile TOML golden CBOX_CODEX_MCP=0"
}

test_codex_profile_toml_golden_mcp1() {
  local outdir="$TMPBASE/profile_mcp1"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="/home/x"
    export CBOX_WORKSPACES="/zerolab/agent_ecosystem"
    export CBOX_CODEX_MCP=1
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_profile_into "$outdir" global ""
  )
  local got want
  got="$(sha256sum "$outdir/cbox-container.config.toml" | awk '{print $1}')"
  want="05a0b33a79b3eb020ebbb76144ea93a31ef61eeeaabb1426589b72cc2d1694df"
  [ "$got" = "$want" ] || _fail "codex profile TOML (CBOX_CODEX_MCP=1) changed (got $got want $want)"
  echo "PASS: codex profile TOML golden CBOX_CODEX_MCP=1"
}

test_codex_profile_toml_hermes_local_gated_on() {
  local outdir="$TMPBASE/profile_hermes_local"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="/home/x"
    export CBOX_WORKSPACES="/zerolab/agent_ecosystem"
    export CBOX_CODEX_MCP=1
    export CBOX_HERMES_DELEGATE=on
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_profile_into "$outdir" global ""
  )
  grep -q '^\[mcp_servers.hermes-local\]$' "$outdir/cbox-container.config.toml" \
    || _fail "codex profile TOML with CBOX_CODEX_MCP=1 and CBOX_HERMES_DELEGATE=on is missing [mcp_servers.hermes-local]"
  grep -q '"HERMES_BIN" = "/opt/hermes/bin/hermes"' "$outdir/cbox-container.config.toml" \
    || _fail "codex profile TOML [mcp_servers.hermes-local] has an empty/missing HERMES_BIN (hermes defaults not applied for codex render)"
  grep -q '"CBOX_HERMES_DELEGATE_HOME_TEMPLATE" = "/opt/hermes/delegate-home"' "$outdir/cbox-container.config.toml" \
    || _fail "codex profile TOML [mcp_servers.hermes-local] has an empty/missing CBOX_HERMES_DELEGATE_HOME_TEMPLATE (hermes defaults not applied for codex render)"
  echo "PASS: codex profile TOML carries [mcp_servers.hermes-local] when CBOX_CODEX_MCP=1 and CBOX_HERMES_DELEGATE=on"
}

test_shim_behavioral_pin_via_existing_suite() {
  python3 "$INSTALL_DIR/lib/test_codex_mcp_shim.py" -v >/dev/null 2>&1 \
    || _fail "codex_mcp_shim.py behavioral pin (test_codex_mcp_shim.py) failed"
  echo "PASS: shim behavioral pin (model/effort/kernel/thread-refusal/base-instructions) via test_codex_mcp_shim.py"
}

test_no_dangling_mcp_servers_json_refs() {
  [ -f "$INSTALL_DIR/etc/mcp/mcp-servers.json" ] \
    && _fail "old etc/mcp/mcp-servers.json still present - migration to delegates.json incomplete"
  [ -f "$INSTALL_DIR/etc/mcp/delegates.json" ] \
    || _fail "etc/mcp/delegates.json missing - migration to delegates.json incomplete"
  local hits
  hits="$(grep -rl "etc/mcp/mcp-servers\.json\|mcp/mcp-servers\.json" \
    "$INSTALL_DIR/lib/cbox-setup.sh" "$INSTALL_DIR/templates" "$INSTALL_DIR/entrypoint.sh" \
    2>/dev/null || true)"
  [ -z "$hits" ] || _fail "dangling reference(s) to the old mcp-servers.json path: $hits"
  echo "PASS: no dangling references to the old mcp-servers.json path"
}

test_delegates_registry_reproduces_current_default_set() {
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
avail = {
    n: sorted(s["_cbox"].get("available_to") or [])
    for n, s in data.items()
    if isinstance(s, dict) and isinstance(s.get("_cbox"), dict)
}
codex_tiers = ["codex-astra", "codex-luna", "codex-sol", "codex-terra", "codex-terra-light"]
expected_avail = {
    "codex-astra": ["claude", "hermes"],
    "codex-luna": ["claude", "hermes"],
    "codex-sol": ["claude", "hermes"],
    "codex-terra": ["claude", "hermes"],
    "codex-terra-light": ["claude", "hermes"],
    "ask-claude": ["codex"],
    "local-qwen": ["claude", "codex", "hermes"],
    "hermes-local": ["claude", "codex", "hermes"],
    "container-exec": ["claude", "codex", "hermes"],
}
assert avail == expected_avail, avail
gated = sorted(
    n for n, s in data.items()
    if isinstance(s, dict)
    and isinstance(s.get("_cbox"), dict)
    and s["_cbox"].get("enabled_when_env")
)
expected_gated = sorted(["local-qwen", "hermes-local", "container-exec"])
assert gated == expected_gated, gated
assert sorted(data.keys()) == sorted(expected_avail.keys()), sorted(data.keys())
' "$INSTALL_DIR/etc/mcp/delegates.json"
  echo "PASS: delegates.json reproduces the current default set exactly (5 codex tiers available to claude+hermes, ask-claude codex-only, local-qwen/container-exec/hermes-local claude+codex+hermes env-gated, no other new entry)"
}

test_render_refuses_codex_named_non_codex_mcp_adapter() {
  local bad="$TMPBASE/bad_named_codex.json"
  echo '{"codex-bad":{"type":"stdio","command":"codex","args":["mcp-server"],"_cbox":{"adapter":"stdio-mcp","available_to":["claude"]}}}' > "$bad"
  if python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$bad" codex-bad "/home/x/.claude/hooks" off claude >/dev/null 2>"$TMPBASE/bad_named_codex.err"; then
    _fail "render_mcp.py accepted a codex-* entry with a non-codex-mcp adapter"
  fi
  grep -q "refusing to ship it" "$TMPBASE/bad_named_codex.err" \
    || _fail "render_mcp.py refusal message missing for codex-* naming violation"
  echo "PASS: render_mcp.py refuses a codex-* entry with a non-codex-mcp adapter"
}

test_render_refuses_codex_mcp_adapter_without_codex_prefix() {
  local bad="$TMPBASE/bad_adapter_no_prefix.json"
  echo '{"my-tool":{"type":"stdio","command":"codex","args":["mcp-server"],"_cbox":{"adapter":"codex-mcp","available_to":["claude"],"model":"m","model_reasoning_effort":"e"}}}' > "$bad"
  if python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$bad" my-tool "/home/x/.claude/hooks" off claude >/dev/null 2>"$TMPBASE/bad_adapter_no_prefix.err"; then
    _fail "render_mcp.py accepted a codex-mcp adapter entry not named codex-*"
  fi
  grep -q "refusing to ship it" "$TMPBASE/bad_adapter_no_prefix.err" \
    || _fail "render_mcp.py refusal message missing for codex-mcp adapter naming violation"
  echo "PASS: render_mcp.py refuses a codex-mcp adapter entry not named codex-*"
}

test_available_to_enforced_codex_gains_no_new_tools() {
  local rendered="$TMPBASE/codex_target_all.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex > "$rendered"
  python3 -c '
import json
import sys
data = json.load(open(sys.argv[1]))
assert list(data.keys()) == ["ask-claude"], data.keys()
' "$rendered"
  echo "PASS: codex target selection=all yields only ask-claude (no new tools gained)"
}

test_fixture_stdio_mcp_renders_plain_for_claude() {
  local fixture="$INSTALL_DIR/lib/fixtures/delegates.stdio-mcp-fixture.json"
  local all
  all="$(python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
print(" ".join(data.keys()))
' "$fixture")"
  local rendered="$TMPBASE/fixture_claude.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" "$all" "/home/x/.claude/hooks" off claude > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "fixture-tool" in data, data.keys()
spec = data["fixture-tool"]
assert spec == {
    "type": "stdio",
    "command": "fixture-tool-bin",
    "args": ["--serve"],
    "env": {"FIXTURE_TOOL_MODE": "test"},
}, spec
' "$rendered"
  echo "PASS: fixture stdio-mcp delegate renders as a plain passthrough stdio server for claude"
}

test_fixture_stdio_mcp_absent_for_codex() {
  local fixture="$INSTALL_DIR/lib/fixtures/delegates.stdio-mcp-fixture.json"
  local all
  all="$(python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
print(" ".join(data.keys()))
' "$fixture")"
  local rendered="$TMPBASE/fixture_codex.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" "$all" "/home/x/.claude/hooks" off codex > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "fixture-tool" not in data, data.keys()
assert list(data.keys()) == ["ask-claude"], data.keys()
' "$rendered"
  echo "PASS: fixture stdio-mcp delegate is absent for codex (available_to filtering) and codex still gains no new tools"
}

test_fixture_stdio_mcp_invisible_to_boot_gate() {
  local fixture="$INSTALL_DIR/lib/fixtures/delegates.stdio-mcp-fixture.json"
  local all
  all="$(python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
print(" ".join(data.keys()))
' "$fixture")"
  local rendered="$TMPBASE/fixture_gate.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" "$all" "/home/x/.claude/hooks" off claude > "$rendered"
  local hosthome="$TMPBASE/hosthome_fixture"
  mkdir -p "$hosthome"
  _seed_shape "$rendered" "$hosthome/.claude.json"
  local gatefunc="$TMPBASE/gate_func_fixture.sh"
  awk '
    /^_check_codex_mcp_shim_seed(_one)?\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/entrypoint.sh" > "$gatefunc"
  if ! ( HOST_HOME="$hosthome"; source "$gatefunc"; _check_codex_mcp_shim_seed ); then
    _fail "entrypoint boot gate rejected a seed containing a well-formed non-codex-* fixture entry"
  fi
  echo "PASS: fixture stdio-mcp delegate is invisible to the entrypoint boot gate (not named codex-*)"
}

test_fixture_selection_expansion_works() {
  local fixture="$INSTALL_DIR/lib/fixtures/delegates.stdio-mcp-fixture.json"
  local rendered="$TMPBASE/fixture_selected.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" "fixture-tool codex-sol" "/home/x/.claude/hooks" off claude > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert sorted(data.keys()) == ["codex-sol", "fixture-tool"], data.keys()
' "$rendered"
  echo "PASS: selection expansion works with the fixture delegate mixed alongside real tiers"
}

test_local_qwen_absent_when_url_unset() {
  local rendered="$TMPBASE/local_qwen_absent.json"
  env -u CBOX_LOCAL_MODEL_URL -u CBOX_LOCAL_MODEL_NAME \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "local-qwen" not in data, data.keys()
' "$rendered"
  echo "PASS: local-qwen is absent from selection=all render when CBOX_LOCAL_MODEL_URL is unset"
}

test_local_qwen_explicit_selection_unconfigured_fails_loud() {
  local err="$TMPBASE/local_qwen_explicit.err"
  if env -u CBOX_LOCAL_MODEL_URL -u CBOX_LOCAL_MODEL_NAME \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" local-qwen "/home/x/.claude/hooks" off claude \
    >/dev/null 2>"$err"; then
    _fail "render_mcp.py accepted an explicit local-qwen selection with CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME unset"
  fi
  grep -q "explicitly selected but CBOX_LOCAL_MODEL_URL, CBOX_LOCAL_MODEL_NAME is not set" "$err" \
    || _fail "render_mcp.py refusal message missing both unmet compound-gate vars for unconfigured explicit local-qwen selection"
  echo "PASS: render_mcp.py refuses an explicit unconfigured local-qwen selection loudly, naming both unmet compound-gate vars"
}

test_local_qwen_present_and_env_substituted_when_configured() {
  local rendered="$TMPBASE/local_qwen_present.json"
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="qwen2.5:7b" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "local-qwen" in data, data.keys()
spec = data["local-qwen"]
assert spec["command"] == "python3", spec
assert spec["args"] == ["/home/x/.claude/hooks/local_model_mcp.py"], spec
assert spec["env"] == {
    "CBOX_LOCAL_MODEL_URL": "http://127.0.0.1:11500",
    "CBOX_LOCAL_MODEL_NAME": "qwen2.5:7b",
}, spec
' "$rendered"
  echo "PASS: local-qwen renders with substituted env when CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME are set"
}

test_local_qwen_available_to_codex_when_configured() {
  local rendered="$TMPBASE/local_qwen_codex.json"
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="qwen2.5:7b" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert sorted(data.keys()) == ["ask-claude", "local-qwen"], data.keys()
' "$rendered"
  echo "PASS: local-qwen is available_to codex too once configured (ask-claude still present)"
}

test_local_qwen_invisible_to_boot_gate_when_configured() {
  local rendered="$TMPBASE/local_qwen_gate.json"
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="qwen2.5:7b" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$rendered"
  local hosthome="$TMPBASE/hosthome_local_qwen"
  mkdir -p "$hosthome"
  _seed_shape "$rendered" "$hosthome/.claude.json"
  local gatefunc="$TMPBASE/gate_func_local_qwen.sh"
  awk '
    /^_check_codex_mcp_shim_seed(_one)?\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/entrypoint.sh" > "$gatefunc"
  if ! ( HOST_HOME="$hosthome"; source "$gatefunc"; _check_codex_mcp_shim_seed ); then
    _fail "entrypoint boot gate rejected a seed containing a well-formed local-qwen entry"
  fi
  echo "PASS: local-qwen is invisible to the entrypoint boot gate (not named codex-*) once configured"
}

test_local_qwen_compound_gate_url_set_name_empty_not_rendered() {
  local rendered="$TMPBASE/local_qwen_url_only_claude.json"
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "local-qwen" not in data, data.keys()
' "$rendered"

  local rendered_codex="$TMPBASE/local_qwen_url_only_codex.json"
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex > "$rendered_codex"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "local-qwen" not in data, data.keys()
' "$rendered_codex"

  local rendered_hermes="$TMPBASE/local_qwen_url_only_hermes.json"
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off hermes > "$rendered_hermes"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["local-qwen"]["enabled"] is False, data["local-qwen"]
' "$rendered_hermes"
  echo "PASS: local-qwen with CBOX_LOCAL_MODEL_URL set but CBOX_LOCAL_MODEL_NAME empty is NOT rendered as an enabled tool for any target (compound gate closes the advertised-but-broken-at-call-time hole)"
}

test_local_qwen_compound_gate_explicit_selection_url_only_fails_loud() {
  local err="$TMPBASE/local_qwen_url_only_explicit.err"
  if CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" local-qwen "/home/x/.claude/hooks" off claude \
    >/dev/null 2>"$err"; then
    _fail "render_mcp.py accepted an explicit local-qwen selection with only CBOX_LOCAL_MODEL_URL set"
  fi
  grep -q "explicitly selected but CBOX_LOCAL_MODEL_NAME is not set" "$err" \
    || _fail "render_mcp.py refusal message missing the unmet CBOX_LOCAL_MODEL_NAME var for a partially-configured explicit local-qwen selection"
  echo "PASS: render_mcp.py refuses an explicit local-qwen selection loudly when only one half of the compound gate is set, naming the unmet var"
}

test_local_qwen_compound_gate_both_set_renders() {
  local rendered="$TMPBASE/local_qwen_both_set.json"
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500" CBOX_LOCAL_MODEL_NAME="qwen2.5:7b" \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "local-qwen" in data, data.keys()
' "$rendered"
  echo "PASS: local-qwen renders when both halves of the compound gate (CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME) are set"
}

test_single_string_enabled_when_env_still_works() {
  local fixture="$TMPBASE/single_string_gate.json"
  echo '{"fixture-tool":{"type":"stdio","command":"fixture-tool-bin","args":["--serve"],"_cbox":{"adapter":"stdio-mcp","available_to":["claude"],"backend":"fixture-tool-bin","side_effects":["none"],"enabled_when_env":"CBOX_FIXTURE_SINGLE_GATE"}}}' > "$fixture"

  local rendered_off="$TMPBASE/single_string_gate_off.json"
  env -u CBOX_FIXTURE_SINGLE_GATE \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" all "/home/x/.claude/hooks" off claude > "$rendered_off"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "fixture-tool" not in data, data.keys()
' "$rendered_off"

  local rendered_on="$TMPBASE/single_string_gate_on.json"
  CBOX_FIXTURE_SINGLE_GATE=on \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" all "/home/x/.claude/hooks" off claude > "$rendered_on"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "fixture-tool" in data, data.keys()
' "$rendered_on"
  echo "PASS: a single-string enabled_when_env gate still works (back-compat with the pre-list form)"
}

test_local_qwen_gate_agrees_with_capabilities_registry() {
  python3 -c '
import json

delegates = json.load(open("'"$INSTALL_DIR"'/etc/mcp/delegates.json"))
caps = json.load(open("'"$INSTALL_DIR"'/etc/capabilities/capabilities.json"))["capabilities"]

d_gate = delegates["local-qwen"]["_cbox"]["enabled_when_env"]
if isinstance(d_gate, str):
    d_gate = [d_gate]
c_gate = caps["local-qwen"]["enabled_when_env"]
assert sorted(d_gate) == sorted(c_gate), (d_gate, c_gate)
'
  echo "PASS: delegates.json local-qwen enabled_when_env agrees with capabilities.json local-qwen enabled_when_env (both require CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME)"
}

test_enabled_when_env_gates_are_exported_everywhere() {
  local gates
  gates="$(python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
found = set()
for s in data.values():
    if not isinstance(s, dict) or not isinstance(s.get("_cbox"), dict):
        continue
    ewe = s["_cbox"].get("enabled_when_env")
    if not ewe:
        continue
    if isinstance(ewe, str):
        found.add(ewe)
    else:
        found.update(ewe)
print(" ".join(sorted(found)))
' "$INSTALL_DIR/etc/mcp/delegates.json")"
  [ -n "$gates" ] || _fail "no enabled_when_env gates found in delegates.json - test fixture assumption broken"
  local conf_lib="$INSTALL_DIR/templates/conf_lib.sh"
  [ -f "$conf_lib" ] || _fail "templates/conf_lib.sh not found"
  local reg_export_vars
  reg_export_vars="$(awk '
    /^_cbox_reg_export_vars\(\) \{/ { infunc=1; next }
    infunc && /^\}/ { infunc=0 }
    infunc { print }
  ' "$conf_lib" | grep -Eo '^[[:space:]]*export[[:space:]]+.*' | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
  local gate f
  for gate in $gates; do
    local reachable_via_reg=0
    case " $reg_export_vars " in
      *" $gate "*) reachable_via_reg=1 ;;
    esac
    for f in "$INSTALL_DIR/lib/cbox-setup.sh" "$INSTALL_DIR/cbox"; do
      local direct=0 calls_reg=0
      grep -Eq "^[[:space:]]*export[[:space:]]+([A-Z0-9_]+[[:space:]]+)*${gate}([[:space:]]|\$)" "$f" && direct=1
      grep -Eq "_cbox_reg_export_vars" "$f" && calls_reg=1
      if [ "$direct" = 1 ]; then
        continue
      fi
      if [ "$calls_reg" = 1 ] && [ "$reachable_via_reg" = 1 ]; then
        continue
      fi
      _fail "gate var $gate (from delegates.json enabled_when_env): $f neither exports it directly nor calls _cbox_reg_export_vars while templates/conf_lib.sh's _cbox_reg_export_vars actually exports it"
    done
  done
  echo "PASS: every enabled_when_env gate in delegates.json is exported at least once (directly, or via a _cbox_reg_export_vars call whose generated export list actually contains the gate) reachable from both setup.sh and cbox"
}

test_hermes_target_default_render_carries_opted_in_entries_only() {
  local rendered="$TMPBASE/hermes_default.json"
  env -u CBOX_HERMES_DELEGATE -u CBOX_LOCAL_MODEL_URL -u CBOX_LOCAL_MODEL_NAME \
    -u CBOX_CONTAINER_EXEC_TOOL \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off hermes > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
servers = json.load(open(sys.argv[2]))
codex_tiers = ["codex-astra", "codex-luna", "codex-sol", "codex-terra", "codex-terra-light"]
gated_off = ["hermes-local", "local-qwen", "container-exec"]
assert sorted(data.keys()) == sorted(codex_tiers + gated_off), data.keys()
for tier in codex_tiers:
    spec = data[tier]
    cbox = servers[tier]["_cbox"]
    assert spec["command"] == "python3", (tier, spec)
    args = spec["args"]
    assert args[0].endswith("/codex_mcp_shim.py"), (tier, args)
    assert args[1:9] == [
        "--tier", tier, "--model", cbox["model"],
        "--effort", cbox["model_reasoning_effort"], "--progress", "off",
    ], (tier, args)
    assert args[9:] == ["--", "codex", "mcp-server"], (tier, args)
    assert "timeout" not in spec, (tier, spec)
hl = data["hermes-local"]
assert hl["command"] == "python3", hl
assert hl["args"] == ["/home/x/.claude/hooks/hermes_delegate_mcp.py"], hl
assert hl["enabled"] is False, hl
assert hl["timeout"] == 3600, hl
assert hl["connect_timeout"] == 30, hl
lq = data["local-qwen"]
assert lq["enabled"] is False, lq
ce = data["container-exec"]
assert ce["enabled"] is False, ce
' "$rendered" "$INSTALL_DIR/etc/mcp/delegates.json"
  echo "PASS: hermes target default render carries exactly the opted-in entries (5 codex tiers shim-wrapped, hermes-local/local-qwen/container-exec disabled since their gates are unset) and nothing else"
}

test_hermes_target_entry_absent_without_available_to() {
  local fixture="$TMPBASE/hermes_no_avail.json"
  echo '{"fixture-tool":{"type":"stdio","command":"fixture-tool-bin","args":["--serve"],"_cbox":{"adapter":"stdio-mcp","available_to":["claude","codex"],"backend":"fixture-tool-bin","side_effects":["none"]}}}' > "$fixture"
  local rendered="$TMPBASE/hermes_no_avail_out.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" fixture-tool "/home/x/.claude/hooks" off hermes > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert data == {}, data
' "$rendered"
  echo "PASS: an entry not naming hermes in available_to never appears in the hermes target render"
}

test_hermes_target_shape_and_timeout() {
  local fixture="$TMPBASE/hermes_shape.json"
  echo '{"fixture-tool":{"type":"stdio","command":"fixture-tool-bin","args":["--serve"],"env":{"FIXTURE_TOOL_MODE":"test"},"startup_timeout_sec":30,"tool_timeout_sec":1800,"_cbox":{"adapter":"stdio-mcp","available_to":["claude","hermes"],"backend":"fixture-tool-bin","side_effects":["none"]}}}' > "$fixture"
  local rendered="$TMPBASE/hermes_shape_out.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" fixture-tool "/home/x/.claude/hooks" off hermes > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "fixture-tool" in data, data.keys()
spec = data["fixture-tool"]
assert spec == {
    "command": "fixture-tool-bin",
    "args": ["--serve"],
    "env": {"FIXTURE_TOOL_MODE": "test"},
    "timeout": 1800,
    "connect_timeout": 30,
}, spec
' "$rendered"
  echo "PASS: hermes target renders the mcp_servers shape (command/args/env) and carries tool_timeout_sec through as timeout"
}

test_hermes_target_gated_off_entry_renders_enabled_false() {
  local fixture="$TMPBASE/hermes_gate.json"
  echo '{"fixture-tool":{"type":"stdio","command":"fixture-tool-bin","args":["--serve"],"tool_timeout_sec":60,"_cbox":{"adapter":"stdio-mcp","available_to":["claude","hermes"],"backend":"fixture-tool-bin","side_effects":["none"],"enabled_when_env":"CBOX_FIXTURE_TOOL_GATE"}}}' > "$fixture"
  local rendered="$TMPBASE/hermes_gate_out.json"
  env -u CBOX_FIXTURE_TOOL_GATE \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" all "/home/x/.claude/hooks" off hermes > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "fixture-tool" in data, data.keys()
spec = data["fixture-tool"]
assert spec["enabled"] is False, spec
assert spec["timeout"] == 60, spec
' "$rendered"
  echo "PASS: an entry gated by enabled_when_env with an unmet gate renders with hermes native enabled: false instead of being omitted"

  local rendered_on="$TMPBASE/hermes_gate_on_out.json"
  CBOX_FIXTURE_TOOL_GATE=on \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" all "/home/x/.claude/hooks" off hermes > "$rendered_on"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
spec = data["fixture-tool"]
assert "enabled" not in spec, spec
' "$rendered_on"
  echo "PASS: the same entry with its gate satisfied carries no enabled key (hermes default-enabled applies)"
}

test_hermes_target_explicit_unconfigured_gate_still_errors() {
  local fixture="$TMPBASE/hermes_gate_explicit.json"
  echo '{"fixture-tool":{"type":"stdio","command":"fixture-tool-bin","args":["--serve"],"_cbox":{"adapter":"stdio-mcp","available_to":["claude","hermes"],"backend":"fixture-tool-bin","side_effects":["none"],"enabled_when_env":"CBOX_FIXTURE_TOOL_GATE"}}}' > "$fixture"
  local err="$TMPBASE/hermes_gate_explicit.err"
  if env -u CBOX_FIXTURE_TOOL_GATE \
    python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" fixture-tool "/home/x/.claude/hooks" off hermes \
    >/dev/null 2>"$err"; then
    _fail "render_mcp.py accepted an explicit hermes selection of a gated entry with an unmet gate"
  fi
  grep -q "explicitly selected but CBOX_FIXTURE_TOOL_GATE is not set" "$err" \
    || _fail "render_mcp.py refusal message missing for explicit unconfigured hermes selection"
  echo "PASS: an explicit hermes selection of an unconfigured gated entry still errors loudly (enabled:false only applies to the implicit selection=all case)"
}

test_hermes_target_claude_cli_adapter_renders() {
  local fixture="$TMPBASE/hermes_claude_cli.json"
  echo '{"ask-claude":{"_cbox":{"adapter":"claude-cli","available_to":["codex","hermes"],"backend":"claude","side_effects":["spawns-claude-subprocess"],"command":"python3","script":"ask_claude_mcp.py","startup_timeout_sec":30,"tool_timeout_sec":3600}}}' > "$fixture"
  local rendered="$TMPBASE/hermes_claude_cli_out.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$fixture" ask-claude "/home/x/.claude/hooks" off hermes > "$rendered"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
spec = data["ask-claude"]
assert spec["command"] == "python3", spec
assert spec["args"] == ["/home/x/.claude/hooks/ask_claude_mcp.py"], spec
assert spec["timeout"] == 3600, spec
assert spec["connect_timeout"] == 30, spec
' "$rendered"
  echo "PASS: the claude-cli adapter (ask-claude shape) also renders for the hermes target with timeout carried through"
}

test_claude_and_codex_renders_unaffected_by_hermes_target() {
  local claude_rendered="$TMPBASE/parity_claude.json"
  local codex_rendered="$TMPBASE/parity_codex.json"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$claude_rendered"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex > "$codex_rendered"
  local got_claude got_codex
  got_claude="$(sha256sum "$claude_rendered" | awk '{print $1}')"
  got_codex="$(sha256sum "$codex_rendered" | awk '{print $1}')"
  local want_claude want_codex
  want_claude="5f586d02a69b55441334653cb2ce85f5e7b6335ede37f39cfdd2031686b44e16"
  want_codex="ddde00b645e9cf9d74f0dd7611f36ad4543caee7dcf8273d8e36715edf911ca3"
  [ "$got_claude" = "$want_claude" ] || _fail "claude target render changed after adding the hermes target (got $got_claude want $want_claude)"
  [ "$got_codex" = "$want_codex" ] || _fail "codex target render changed after adding the hermes target (got $got_codex want $want_codex)"
  echo "PASS: claude and codex renders are byte-identical to before the hermes target was added"
}

test_render_byte_identity_progress_off
test_render_byte_identity_progress_on
test_seed_shape_byte_identity
test_merge_mcp_json_call_site
test_shim_argv_contract_per_tier
test_entrypoint_gate_passes_on_golden_seed
test_entrypoint_gate_fails_on_tampered_seed
test_entrypoint_gate_checks_active_config_dir_state
test_codex_profile_toml_golden_mcp0
test_codex_profile_toml_golden_mcp1
test_codex_profile_toml_hermes_local_gated_on
test_shim_behavioral_pin_via_existing_suite
test_no_dangling_mcp_servers_json_refs
test_delegates_registry_reproduces_current_default_set
test_render_refuses_codex_named_non_codex_mcp_adapter
test_render_refuses_codex_mcp_adapter_without_codex_prefix
test_available_to_enforced_codex_gains_no_new_tools
test_local_qwen_absent_when_url_unset
test_local_qwen_explicit_selection_unconfigured_fails_loud
test_local_qwen_present_and_env_substituted_when_configured
test_local_qwen_available_to_codex_when_configured
test_local_qwen_invisible_to_boot_gate_when_configured
test_local_qwen_compound_gate_url_set_name_empty_not_rendered
test_local_qwen_compound_gate_explicit_selection_url_only_fails_loud
test_local_qwen_compound_gate_both_set_renders
test_single_string_enabled_when_env_still_works
test_local_qwen_gate_agrees_with_capabilities_registry
test_fixture_stdio_mcp_renders_plain_for_claude
test_fixture_stdio_mcp_absent_for_codex
test_fixture_stdio_mcp_invisible_to_boot_gate
test_fixture_selection_expansion_works
test_enabled_when_env_gates_are_exported_everywhere
test_hermes_target_default_render_carries_opted_in_entries_only
test_hermes_target_entry_absent_without_available_to
test_hermes_target_shape_and_timeout
test_hermes_target_gated_off_entry_renders_enabled_false
test_hermes_target_explicit_unconfigured_gate_still_errors
test_hermes_target_claude_cli_adapter_renders
test_claude_and_codex_renders_unaffected_by_hermes_target
echo "all render_mcp golden tests passed"
