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
  want="f009635ceb81572436f83d7d35c84be582a040e2e8c38f7380294b44f63af064"
  [ "$got" = "$want" ] || _fail "render selection=all progress=off changed (got $got want $want)"
  echo "PASS: render byte-identity progress=off"
}

test_render_byte_identity_progress_on() {
  local all
  all="$(_all_names)"
  _render "$all" on "$TMPBASE/render_on.json"
  local got want
  got="$(sha256sum "$TMPBASE/render_on.json" | awk '{print $1}')"
  want="4883e938d6aa1161808df6a8f086db347e49a754189c58f3145d2496fc6f8d11"
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
  want="d98bda11cc1e7e4d4c0c60892eeed910a5350c757077b31a94c7b975d30655eb"
  [ "$got" = "$want" ] || _fail "seed shape progress=off changed (got $got want $want)"

  _render "$all" on "$TMPBASE/render_on2.json"
  _seed_shape "$TMPBASE/render_on2.json" "$TMPBASE/seed_on.json"
  got="$(sha256sum "$TMPBASE/seed_on.json" | awk '{print $1}')"
  want="170d810286ad26419316531ee44b7b73505019f670182ba986ef1516e89e7b9c"
  [ "$got" = "$want" ] || _fail "seed shape progress=on changed (got $got want $want)"
  echo "PASS: seed shape byte-identity (gen_claude_json_seed consumer)"
}

test_merge_mcp_json_call_site() {
  local extracted="$TMPBASE/setup_functions.sh"
  awk '
    /^merge_mcp_json\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/setup.sh" > "$extracted"
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
    "$INSTALL_DIR/setup.sh" "$INSTALL_DIR/templates" "$INSTALL_DIR/entrypoint.sh" \
    2>/dev/null || true)"
  [ -z "$hits" ] || _fail "dangling reference(s) to the old mcp-servers.json path: $hits"
  echo "PASS: no dangling references to the old mcp-servers.json path"
}

test_delegates_registry_reproduces_current_default_set() {
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
claude_only = sorted(
    n for n, s in data.items()
    if isinstance(s, dict)
    and isinstance(s.get("_cbox"), dict)
    and s["_cbox"].get("available_to") == ["claude"]
)
codex_only = sorted(
    n for n, s in data.items()
    if isinstance(s, dict)
    and isinstance(s.get("_cbox"), dict)
    and s["_cbox"].get("available_to") == ["codex"]
)
gated_multi = sorted(
    n for n, s in data.items()
    if isinstance(s, dict)
    and isinstance(s.get("_cbox"), dict)
    and s["_cbox"].get("available_to") == ["claude", "codex"]
    and s["_cbox"].get("enabled_when_env")
)
claude_only_gated = sorted(
    n for n, s in data.items()
    if isinstance(s, dict)
    and isinstance(s.get("_cbox"), dict)
    and s["_cbox"].get("available_to") == ["claude"]
    and s["_cbox"].get("enabled_when_env")
)
expected_claude = ["codex-luna", "codex-sol", "codex-terra", "codex-terra-light"]
expected_codex = ["ask-claude"]
expected_gated_multi = ["local-qwen"]
expected_claude_only_gated = ["hermes-local"]
assert claude_only == sorted(expected_claude + expected_claude_only_gated), claude_only
assert codex_only == expected_codex, codex_only
assert gated_multi == expected_gated_multi, gated_multi
assert claude_only_gated == expected_claude_only_gated, claude_only_gated
assert sorted(data.keys()) == sorted(expected_claude + expected_codex + expected_gated_multi + expected_claude_only_gated), sorted(data.keys())
' "$INSTALL_DIR/etc/mcp/delegates.json"
  echo "PASS: delegates.json reproduces the current default set exactly (4 claude-only tiers, ask-claude codex-only, local-qwen env-gated claude+codex, hermes-local env-gated claude-only, no other new entry)"
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
    _fail "render_mcp.py accepted an explicit local-qwen selection with CBOX_LOCAL_MODEL_URL unset"
  fi
  grep -q "explicitly selected but CBOX_LOCAL_MODEL_URL is not set" "$err" \
    || _fail "render_mcp.py refusal message missing for unconfigured explicit local-qwen selection"
  echo "PASS: render_mcp.py refuses an explicit unconfigured local-qwen selection loudly"
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
assert spec["args"] == ["local_model_mcp.py"], spec
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
test_fixture_stdio_mcp_renders_plain_for_claude
test_fixture_stdio_mcp_absent_for_codex
test_fixture_stdio_mcp_invisible_to_boot_gate
test_fixture_selection_expansion_works
echo "all render_mcp golden tests passed"
