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

_render_dockerfile() {
  local outdir="$1" hermes="$2" version="$3"
  mkdir -p "$outdir"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="/home/x"
    export CBOX_WORKSPACES="/zerolab/agent_ecosystem"
    export CBOX_HERMES="$hermes"
    export CBOX_HERMES_VERSION="$version"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_dockerfile_into "$outdir" "sha256:deadbeef"
  )
}

BASE="$TMPBASE/base"
_render_dockerfile "$BASE" off ""
[ -f "$BASE/Dockerfile" ] || _fail "baseline Dockerfile (hermes off) not written"
! grep -q 'pip install' "$BASE/Dockerfile" || _fail "hermes off but Dockerfile installs packages:
$(cat "$BASE/Dockerfile")"
[ "$(grep -c hermes "$BASE/Dockerfile")" = 1 ] || _fail "Dockerfile must mention hermes exactly once (the mountpoint line):
$(cat "$BASE/Dockerfile")"
_ok "hermes off: Dockerfile carries only the /opt/hermes mountpoint line"

ON="$TMPBASE/on"
_render_dockerfile "$ON" on "0.19.0"
grep -q 'ln -sf /opt/hermes/bin/hermes /usr/local/bin/hermes' "$ON/Dockerfile" || _fail "hermes mountpoint symlink missing"
! grep -q 'pip install' "$ON/Dockerfile" || _fail "hermes must not be pip-installed into the image (it lives in the bins volume)"
_ok "hermes on: Dockerfile only prepares the /opt/hermes mountpoint"

DIFF_BASE="$TMPBASE/diffbase"
_render_dockerfile "$DIFF_BASE" off ""
diff -q "$BASE/Dockerfile" "$DIFF_BASE/Dockerfile" >/dev/null \
  || _fail "Dockerfile with hermes off is not byte-identical across renders"
_ok "hermes off: Dockerfile is byte-identical to the baseline render"

ON2="$TMPBASE/on2"
_render_dockerfile "$ON2" on "latest"
diff -q "$BASE/Dockerfile" "$ON/Dockerfile" >/dev/null \
  || _fail "Dockerfile differs between hermes off and on - the image must be hermes-invariant"
diff -q "$ON/Dockerfile" "$ON2/Dockerfile" >/dev/null \
  || _fail "Dockerfile differs between hermes version targets - the image must be version-invariant"
_ok "Dockerfile is invariant across hermes on/off and version target"

BAD="$TMPBASE/bad"
mkdir -p "$BAD"
if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_WORKSPACES="/zerolab/agent_ecosystem"
  export CBOX_HERMES=on
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL="http://good.example/v1"
  export CBOX_HERMES_MODEL_NAME=qwen
  export CBOX_HERMES_VERSION="not-a-version; rm -rf /"
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_hermes_validate_compose_env
) 2>/dev/null; then
  _fail "_cbox_hermes_validate_compose_env accepted a malformed CBOX_HERMES_VERSION"
fi
_ok "hermes on: bad version target grammar dies loudly"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES=on
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL="http://good.example/v1"
  export CBOX_HERMES_MODEL_NAME=qwen
  export CBOX_HERMES_VERSION=latest
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_hermes_validate_compose_env
); then
  _ok "hermes on: 'latest' is a valid channel target"
else
  _fail "_cbox_hermes_validate_compose_env rejected the latest channel target"
fi

M1="$TMPBASE/m1/managed.env"
mkdir -p "$(dirname "$M1")"
(
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL=http://127.0.0.1:11434
  export CBOX_HERMES_MODEL_NAME=qwen2.5:7b
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_hermes_managed_into "$M1"
)
grep -q '^HERMES_MANAGED_PROVIDER=local$' "$M1" || _fail "local provider line missing/wrong in $M1:
$(cat "$M1")"
grep -q '^HERMES_MANAGED_BASE_URL=http://127.0.0.1:11434/v1$' "$M1" \
  || _fail "local provider url without /v1 did not get /v1 appended:
$(cat "$M1")"
grep -q '^HERMES_MANAGED_MODEL=qwen2.5:7b$' "$M1" || _fail "model line missing/wrong in $M1:
$(cat "$M1")"
_ok "gen_hermes_managed_into: local provider url without /v1 gets /v1 appended"

M2="$TMPBASE/m2/managed.env"
mkdir -p "$(dirname "$M2")"
(
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=openai
  export CBOX_HERMES_MODEL_URL=""
  export CBOX_HERMES_MODEL_NAME=gpt-5
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_hermes_managed_into "$M2"
)
grep -q '^HERMES_MANAGED_PROVIDER=openai$' "$M2" || _fail "hosted provider line missing/wrong in $M2:
$(cat "$M2")"
! grep -q '^HERMES_MANAGED_BASE_URL=' "$M2" || _fail "hosted provider must omit base_url line:
$(cat "$M2")"
_ok "gen_hermes_managed_into: hosted provider omits base_url"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL='http://x/v1; rm -rf /'
  export CBOX_HERMES_MODEL_NAME=qwen
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_hermes_managed_into "$TMPBASE/m3/managed.env"
) 2>/dev/null; then
  _fail "gen_hermes_managed_into accepted a hostile CBOX_HERMES_MODEL_URL"
fi
_ok "gen_hermes_managed_into: hostile url value rejected"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL=""
  export CBOX_HERMES_MODEL_NAME='qwen; rm -rf /'
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_hermes_managed_into "$TMPBASE/m4/managed.env"
) 2>/dev/null; then
  _fail "gen_hermes_managed_into accepted a hostile CBOX_HERMES_MODEL_NAME"
fi
_ok "gen_hermes_managed_into: hostile model value rejected"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES=on
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL="http://good.example/v1"
  export CBOX_HERMES_MODEL_NAME=qwen
  export CBOX_HERMES_VERSION="$(printf '0.19.0\n      - EVIL=1')"
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_hermes_validate_compose_env
) 2>/dev/null; then
  _fail "_cbox_hermes_validate_compose_env accepted a newline-smuggled CBOX_HERMES_VERSION"
fi
_ok "compose env: newline-smuggled version target rejected"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL="$(printf 'http://good.example/v1\n      - EVIL=1')"
  export CBOX_HERMES_MODEL_NAME=qwen
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_hermes_managed_into "$TMPBASE/m6/managed.env"
) 2>/dev/null; then
  _fail "gen_hermes_managed_into accepted a newline-smuggled CBOX_HERMES_MODEL_URL"
fi
_ok "gen_hermes_managed_into: newline-smuggled url value rejected"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=local
  export CBOX_HERMES_MODEL_URL=""
  export CBOX_HERMES_MODEL_NAME="$(printf 'qwen\nHERMES_MANAGED_PROVIDER=anthropic')"
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_hermes_managed_into "$TMPBASE/m7/managed.env"
) 2>/dev/null; then
  _fail "gen_hermes_managed_into accepted a newline-smuggled CBOX_HERMES_MODEL_NAME"
fi
_ok "gen_hermes_managed_into: newline-smuggled model value rejected"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES=on
  export CBOX_HERMES_PROVIDER=openrouter
  export CBOX_HERMES_MODEL_URL="$(printf 'x\n      - EVIL=1')"
  export CBOX_HERMES_MODEL_NAME=""
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_hermes_validate_compose_env
) 2>/dev/null; then
  _fail "_cbox_hermes_validate_compose_env accepted a newline-smuggled CBOX_HERMES_MODEL_URL for a hosted provider"
fi
_ok "_cbox_hermes_validate_compose_env: newline-smuggled url rejected for hosted provider (compose-injection guard)"

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=nous
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_hermes_validate_provider "$CBOX_HERMES_PROVIDER"
); then
  _ok "_cbox_hermes_validate_provider: nous (Nous Portal) accepted"
else
  _fail "_cbox_hermes_validate_provider rejected 'nous'"
fi

if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_HERMES_PROVIDER=portal
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_hermes_validate_provider "$CBOX_HERMES_PROVIDER"
) 2>/dev/null; then
  _fail "_cbox_hermes_validate_provider accepted stale 'portal' provider name"
fi
_ok "_cbox_hermes_validate_provider: stale 'portal' provider name rejected"

_image_inputs_hash() {
  local eff="$1" hermes="$2" version="$3"
  mkdir -p "$eff"
  : > "$eff/entrypoint.sh"
  : > "$eff/install-bins.sh"
  : > "$eff/cbox-session-entry.py"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="/home/x"
    export CBOX_HERMES="$hermes"
    export CBOX_HERMES_VERSION="$version"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_image_inputs "$eff" "sha256:deadbeef"
  )
  sha256sum "$eff/image.inputs" | awk '{print $1}'
}

H_OFF="$(_image_inputs_hash "$TMPBASE/inputs_off" off "")"
H_ON="$(_image_inputs_hash "$TMPBASE/inputs_on" on "0.19.0")"
[ "$H_OFF" = "$H_ON" ] || _fail "image.inputs hash changed when toggling CBOX_HERMES on - hermes must not be an image input"
_ok "image.inputs: hash is invariant to the hermes toggle"

H_ON2="$(_image_inputs_hash "$TMPBASE/inputs_on2" on latest)"
[ "$H_ON" = "$H_ON2" ] || _fail "image.inputs hash changed when moving the hermes version target - no rebuild may be needed for a repin"
_ok "image.inputs: hash is invariant to the hermes version target"

! grep -q hermes "$TMPBASE/inputs_on/image.inputs" || _fail "image.inputs still carries a hermes key"
_ok "image.inputs: carries no hermes key at all"

_validator_body() {
  local file="$1" fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) \\{" { grab=1; next }
    grab && /^\}/ { exit }
    grab { print }
  ' "$file"
}

_cross_check_validator() {
  local name="$1" gen_fn="$2" entry_fn="$3"
  local gen_body entry_body
  gen_body="$(_validator_body "$INSTALL_DIR/templates/generators.sh" "$gen_fn")"
  entry_body="$(_validator_body "$INSTALL_DIR/entrypoint.sh" "$entry_fn")"
  [ -n "$gen_body" ] || _fail "textual-agreement: $gen_fn body not found in templates/generators.sh"
  [ -n "$entry_body" ] || _fail "textual-agreement: $entry_fn body not found in entrypoint.sh"
  [ "$gen_body" = "$entry_body" ] \
    || _fail "textual-agreement: $gen_fn (generators.sh) and $entry_fn (entrypoint.sh) have drifted:
--- $gen_fn ---
$gen_body
--- $entry_fn ---
$entry_body"
  _ok "textual-agreement: $gen_fn and $entry_fn stay in sync ($name)"
}

_cross_check_validator "url"      _cbox_hermes_validate_url      _hermes_validate_url
_cross_check_validator "model"    _cbox_hermes_validate_model    _hermes_validate_model
_cross_check_validator "provider" _cbox_hermes_validate_provider _hermes_validate_provider

_render_hermes_mcp_servers() {
  local fake_install="$1" out="$2"
  (
    INSTALL_DIR="$fake_install"
    export INSTALL_DIR
    export HOME="/home/x"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_hermes_mcp_servers_into "$out"
  )
}

_make_fake_install_with_delegates() {
  local dir="$1" delegates_json="$2"
  mkdir -p "$dir/etc/mcp" "$dir/etc/adapters" "$dir/generated/hermes" "$dir/templates"
  cp "$INSTALL_DIR/_common.sh" "$dir/_common.sh"
  cp "$INSTALL_DIR/templates/generators.sh" "$dir/templates/generators.sh"
  cp "$INSTALL_DIR/etc/mcp/render_mcp.py" "$dir/etc/mcp/render_mcp.py"
  if [ -d "$INSTALL_DIR/etc/adapters" ]; then
    cp "$INSTALL_DIR"/etc/adapters/*.py "$dir/etc/adapters/" 2>/dev/null || true
  fi
  printf '%s' "$delegates_json" > "$dir/etc/mcp/delegates.json"
}

FI_EMPTY="$TMPBASE/fi_empty"
_make_fake_install_with_delegates "$FI_EMPTY" "$(cat "$INSTALL_DIR/etc/mcp/delegates.json")"
MCP_OUT_EMPTY="$FI_EMPTY/generated/hermes/mcp_servers.yaml"
(
  unset CBOX_HERMES_DELEGATE CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME CBOX_CONTAINER_EXEC_TOOL
  _render_hermes_mcp_servers "$FI_EMPTY" "$MCP_OUT_EMPTY"
)
[ -f "$MCP_OUT_EMPTY" ] || _fail "gen_hermes_mcp_servers_into did not write $MCP_OUT_EMPTY"
grep -q '^mcp_servers:$' "$MCP_OUT_EMPTY" \
  || _fail "gen_hermes_mcp_servers_into: default render missing top-level mcp_servers: key (real delegates.json opts codex-* and hermes-local into hermes):
$(cat "$MCP_OUT_EMPTY")"
for tier in codex-astra codex-sol codex-terra codex-terra-light codex-luna; do
  grep -q "\"$tier\":" "$MCP_OUT_EMPTY" \
    || _fail "gen_hermes_mcp_servers_into: default render missing opted-in $tier:
$(cat "$MCP_OUT_EMPTY")"
  grep -q 'codex_mcp_shim.py' "$MCP_OUT_EMPTY" \
    || _fail "gen_hermes_mcp_servers_into: default render codex tier not shim-wrapped:
$(cat "$MCP_OUT_EMPTY")"
done
grep -q '"hermes-local":' "$MCP_OUT_EMPTY" \
  || _fail "gen_hermes_mcp_servers_into: default render missing hermes-local - mcp_all_names() is now target-aware (hermes) so a gated entry available to hermes must show up disabled, not vanish:
$(cat "$MCP_OUT_EMPTY")"
_gated_entry_disabled() {
  local name="$1" file="$2"
  awk -v name="\"$name\":" '
    $0 == "  " name { grab=1; next }
    grab && /^  "/ { exit }
    grab { print }
  ' "$file" | grep -q '^    enabled: false$'
}

_gated_entry_disabled hermes-local "$MCP_OUT_EMPTY" \
  || _fail "gen_hermes_mcp_servers_into: default render's hermes-local entry does not carry enabled: false with CBOX_HERMES_DELEGATE unset:
$(cat "$MCP_OUT_EMPTY")"
grep -q '"local-qwen":' "$MCP_OUT_EMPTY" \
  || _fail "gen_hermes_mcp_servers_into: default render missing local-qwen - it is now available_to hermes and must show up disabled, not vanish:
$(cat "$MCP_OUT_EMPTY")"
_gated_entry_disabled local-qwen "$MCP_OUT_EMPTY" \
  || _fail "gen_hermes_mcp_servers_into: default render's local-qwen entry does not carry enabled: false with CBOX_LOCAL_MODEL_URL unset:
$(cat "$MCP_OUT_EMPTY")"
grep -q '"container-exec":' "$MCP_OUT_EMPTY" \
  || _fail "gen_hermes_mcp_servers_into: default render missing container-exec - it is now available_to hermes and must show up disabled, not vanish:
$(cat "$MCP_OUT_EMPTY")"
_gated_entry_disabled container-exec "$MCP_OUT_EMPTY" \
  || _fail "gen_hermes_mcp_servers_into: default render's container-exec entry does not carry enabled: false with CBOX_CONTAINER_EXEC_TOOL unset:
$(cat "$MCP_OUT_EMPTY")"
_ok "gen_hermes_mcp_servers_into: real delegates.json default render carries the 5 codex tiers (shim-wrapped) plus hermes-local/local-qwen/container-exec rendered disabled since their gates are unset"

FI_OPTED="$TMPBASE/fi_opted"
OPTED_JSON="$(python3 -c '
import json
data = json.load(open("'"$INSTALL_DIR"'/etc/mcp/delegates.json"))
data["local-qwen"]["_cbox"]["available_to"].append("hermes")
print(json.dumps(data))
')"
_make_fake_install_with_delegates "$FI_OPTED" "$OPTED_JSON"
MCP_OUT_OPTED="$FI_OPTED/generated/hermes/mcp_servers.yaml"
(
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500"
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  export CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME
  _render_hermes_mcp_servers "$FI_OPTED" "$MCP_OUT_OPTED"
)
grep -q '^mcp_servers:$' "$MCP_OUT_OPTED" \
  || _fail "gen_hermes_mcp_servers_into: opted-in render missing top-level mcp_servers: key:
$(cat "$MCP_OUT_OPTED")"
grep -q '"local-qwen":' "$MCP_OUT_OPTED" \
  || _fail "gen_hermes_mcp_servers_into: opted-in local-qwen entry missing from render:
$(cat "$MCP_OUT_OPTED")"
grep -q 'timeout: 180$' "$MCP_OUT_OPTED" \
  || _fail "gen_hermes_mcp_servers_into: local-qwen tool_timeout_sec (180) did not carry through as timeout:
$(cat "$MCP_OUT_OPTED")"
_ok "gen_hermes_mcp_servers_into: an entry with hermes added to available_to renders with its command/args/env and timeout"

FI_REAL_OPTED="$TMPBASE/fi_real_opted"
_make_fake_install_with_delegates "$FI_REAL_OPTED" "$(cat "$INSTALL_DIR/etc/mcp/delegates.json")"
MCP_OUT_REAL_OPTED="$FI_REAL_OPTED/generated/hermes/mcp_servers.yaml"
(
  CBOX_LOCAL_MODEL_URL="http://127.0.0.1:11500"
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  CBOX_CONTAINER_EXEC_TOOL="on"
  export CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME CBOX_CONTAINER_EXEC_TOOL
  _render_hermes_mcp_servers "$FI_REAL_OPTED" "$MCP_OUT_REAL_OPTED"
)
grep -q '"local-qwen":' "$MCP_OUT_REAL_OPTED" \
  || _fail "gen_hermes_mcp_servers_into: real delegates.json opted-in render missing local-qwen:
$(cat "$MCP_OUT_REAL_OPTED")"
grep -q '"container-exec":' "$MCP_OUT_REAL_OPTED" \
  || _fail "gen_hermes_mcp_servers_into: real delegates.json opted-in render missing container-exec:
$(cat "$MCP_OUT_REAL_OPTED")"
grep -q 'timeout: 180$' "$MCP_OUT_REAL_OPTED" \
  || _fail "gen_hermes_mcp_servers_into: real local-qwen tool_timeout_sec (180) did not carry through as timeout:
$(cat "$MCP_OUT_REAL_OPTED")"
grep -q 'timeout: 3600$' "$MCP_OUT_REAL_OPTED" \
  || _fail "gen_hermes_mcp_servers_into: real container-exec tool_timeout_sec (3600) did not carry through as timeout:
$(cat "$MCP_OUT_REAL_OPTED")"
_gated_entry_disabled local-qwen "$MCP_OUT_REAL_OPTED" \
  && _fail "gen_hermes_mcp_servers_into: local-qwen should carry no enabled key once its gate is satisfied:
$(cat "$MCP_OUT_REAL_OPTED")"
_gated_entry_disabled container-exec "$MCP_OUT_REAL_OPTED" \
  && _fail "gen_hermes_mcp_servers_into: container-exec should carry no enabled key once its gate is satisfied:
$(cat "$MCP_OUT_REAL_OPTED")"
_ok "gen_hermes_mcp_servers_into: real delegates.json local-qwen and container-exec render enabled for hermes with their timeouts (180, 3600) carried through once their gates are set"

_apply_mcp_servers_func() {
  awk '
    /^_hermes_apply_mcp_servers\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^PY$/ { sawpy++; if (sawpy == 1) next }
    infunc && sawpy >= 1 && /^\}/ { exit }
  ' "$INSTALL_DIR/entrypoint.sh"
}

APPLY_FUNC="$TMPBASE/apply_func.sh"
_apply_mcp_servers_func > "$APPLY_FUNC"
[ -s "$APPLY_FUNC" ] || _fail "could not extract _hermes_apply_mcp_servers from entrypoint.sh"

CFG_DIR="$TMPBASE/cfgmerge"
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config.yaml" <<'EOF'
model:
  provider: local
mcp_servers:
  "stale-tool":
    command: "stale"
    args: []
agent:
  iteration_budget: 40
EOF
cp "$MCP_OUT_OPTED" "$CFG_DIR/mcp_servers.yaml"
(
  _as_user() { "$@"; }
  HERMES_HOME="$CFG_DIR"
  source "$APPLY_FUNC"
  _hermes_apply_mcp_servers "$CFG_DIR/mcp_servers.yaml" "$CFG_DIR/config.yaml"
)
grep -q 'stale-tool' "$CFG_DIR/config.yaml" \
  && _fail "_hermes_apply_mcp_servers left the stale mcp_servers block in place instead of replacing it:
$(cat "$CFG_DIR/config.yaml")"
grep -q 'local-qwen' "$CFG_DIR/config.yaml" \
  || _fail "_hermes_apply_mcp_servers did not write the new mcp_servers block:
$(cat "$CFG_DIR/config.yaml")"
grep -q '^  provider: local$' "$CFG_DIR/config.yaml" \
  || _fail "_hermes_apply_mcp_servers dropped an unrelated top-level key (model.provider):
$(cat "$CFG_DIR/config.yaml")"
grep -q '^  iteration_budget: 40$' "$CFG_DIR/config.yaml" \
  || _fail "_hermes_apply_mcp_servers dropped an unrelated top-level key after the block (agent.iteration_budget):
$(cat "$CFG_DIR/config.yaml")"
_ok "_hermes_apply_mcp_servers: replaces only the mcp_servers: block in config.yaml, every other key is untouched"

CFG_DIR2="$TMPBASE/cfgmerge_missing_src"
mkdir -p "$CFG_DIR2"
cp "$CFG_DIR/config.yaml" "$CFG_DIR2/config.yaml" 2>/dev/null || cat > "$CFG_DIR2/config.yaml" <<'EOF'
model:
  provider: local
mcp_servers:
  "old-tool":
    command: "old"
    args: []
EOF
(
  _as_user() { "$@"; }
  HERMES_HOME="$CFG_DIR2"
  source "$APPLY_FUNC"
  _hermes_apply_mcp_servers "$CFG_DIR2/does-not-exist.yaml" "$CFG_DIR2/config.yaml"
)
grep -q '^mcp_servers: {}$' "$CFG_DIR2/config.yaml" \
  || _fail "_hermes_apply_mcp_servers did not degrade to mcp_servers: {} when the source file is missing:
$(cat "$CFG_DIR2/config.yaml")"
_ok "_hermes_apply_mcp_servers: a missing source file (hermes off, or no entry opted in) degrades config.yaml's block to mcp_servers: {} rather than leaving stale entries"

REGEN_FUNC="$TMPBASE/regen_all_body.sh"
_validator_body "$INSTALL_DIR/templates/generators.sh" regen_all > "$REGEN_FUNC"
grep -q "gen_hermes_mcp_servers_into" "$REGEN_FUNC" \
  || _fail "regen_all no longer calls gen_hermes_mcp_servers_into when CBOX_HERMES=on"
_ok "regen_all calls gen_hermes_mcp_servers_into alongside gen_hermes_managed_into"

for RUNTIME_FN in _global_prepare _cbox_global_prepare_locked _gen_effective; do
  RUNTIME_BODY="$TMPBASE/${RUNTIME_FN}_body.sh"
  _validator_body "$INSTALL_DIR/cbox" "$RUNTIME_FN" > "$RUNTIME_BODY"
  [ -s "$RUNTIME_BODY" ] || _fail "could not extract $RUNTIME_FN from cbox - has it moved or been renamed?"
  grep -q "gen_hermes_mcp_servers_into" "$RUNTIME_BODY" \
    || _fail "$RUNTIME_FN (runtime prepare path in cbox) does not call gen_hermes_mcp_servers_into when CBOX_HERMES=on - global/isolated hermes would get mcp_servers: {} (zero delegate tools) outside of cbox setup"
  grep -q "gen_hermes_hooks_into" "$RUNTIME_BODY" \
    || _fail "$RUNTIME_FN (runtime prepare path in cbox) does not call gen_hermes_hooks_into behind CBOX_HERMES_HOOKS - drifts from regen_all's gate structure"
  _ok "$RUNTIME_FN: runtime prepare path wires gen_hermes_mcp_servers_into and gen_hermes_hooks_into (mirrors regen_all, closes the setup-only gap)"
done

_extract_hermes_arm() {
  awk '
    /^  hermes\)$/ { grab=1 }
    grab { print }
    grab && /^    ;;$/ { exit }
  ' "$INSTALL_DIR/entrypoint.sh"
}

HERMES_ARM="$TMPBASE/hermes_arm.sh"
_extract_hermes_arm > "$HERMES_ARM"
[ -s "$HERMES_ARM" ] || _fail "could not extract the hermes) case arm from entrypoint.sh"

grep -q "_hermes_apply_mcp_servers /etc/cbox/hermes-managed/mcp_servers.yaml" "$HERMES_ARM" \
  || _fail "entrypoint.sh hermes branch no longer calls _hermes_apply_mcp_servers"
_ok "entrypoint.sh hermes branch applies mcp_servers.yaml on every cbox run hermes"

grep -q '_hermes_session_prompt="\$(_hermes_kernel_preamble)"' "$HERMES_ARM" \
  || _fail "entrypoint.sh hermes branch no longer seeds _hermes_session_prompt from _hermes_kernel_preamble"
_ok "entrypoint.sh hermes branch seeds the session prompt with the conduct kernel before any operator prompt or brain payload"

grep -q 'continuity_session_start.py' "$HERMES_ARM" \
  || _fail "entrypoint.sh hermes branch no longer calls continuity_session_start.py - session-core and brain payloads would be dropped (statically checked; live hermes render is a host step)"
_ok "entrypoint.sh hermes branch calls the one brain loader (continuity_session_start.py) - statically checked; live hermes render is a host step"

grep -q 'cbox_session_bridge.py render' "$HERMES_ARM" \
  && _fail "entrypoint.sh hermes branch still calls cbox_session_bridge.py render - the bridge-render block should be removed, the loader supersedes it"
_ok "entrypoint.sh hermes branch no longer renders the shared-memory bridge directly - the loader supersedes it"

grep -q 'cbox_session_bridge.py render' "$INSTALL_DIR/entrypoint.sh" \
  && _fail "entrypoint.sh still calls cbox_session_bridge.py render somewhere - the bridge-render block should be fully removed, the loader supersedes it"
_ok "entrypoint.sh carries no cbox_session_bridge.py render call anywhere, not just outside the hermes arm"

_extract_kernel_preamble_func() {
  awk '
    /^_hermes_kernel_preamble\(\) \{/ { grab=1 }
    grab { print }
    grab && /^\}/ { exit }
  ' "$INSTALL_DIR/entrypoint.sh"
}

PREAMBLE_FUNC="$TMPBASE/preamble_func.sh"
_extract_kernel_preamble_func > "$PREAMBLE_FUNC"
[ -s "$PREAMBLE_FUNC" ] || _fail "could not extract _hermes_kernel_preamble from entrypoint.sh"

HOOKS_BOTH="$TMPBASE/hooks_both"
mkdir -p "$HOOKS_BOTH/.claude/hooks"
printf 'KERNEL TEXT\n' > "$HOOKS_BOTH/.claude/hooks/conduct-kernel.txt"
printf 'CORE TEXT\n' > "$HOOKS_BOTH/.claude/hooks/session-core.txt"
PREAMBLE_OUT="$(
  HOST_HOME="$HOOKS_BOTH"
  source "$PREAMBLE_FUNC"
  _hermes_kernel_preamble
)"
printf '%s' "$PREAMBLE_OUT" | grep -q '^KERNEL TEXT$' \
  || _fail "_hermes_kernel_preamble dropped the conduct-kernel.txt content:
$PREAMBLE_OUT"
printf '%s' "$PREAMBLE_OUT" | grep -q '^CORE TEXT$' \
  && _fail "_hermes_kernel_preamble must be kernel-only - session-core now comes from the loader exactly once, not from the preamble too:
$PREAMBLE_OUT"
_ok "_hermes_kernel_preamble: kernel-only, session-core.txt content is not read here (the loader supplies it)"

HOOKS_MISSING="$TMPBASE/hooks_missing"
mkdir -p "$HOOKS_MISSING/.claude/hooks"
MISSING_ERR="$TMPBASE/preamble_missing.err"
PREAMBLE_MISSING_OUT="$(
  HOST_HOME="$HOOKS_MISSING"
  source "$PREAMBLE_FUNC"
  _hermes_kernel_preamble 2>"$MISSING_ERR"
)"
[ -z "$PREAMBLE_MISSING_OUT" ] \
  || _fail "_hermes_kernel_preamble should render empty when both source files are absent, got:
$PREAMBLE_MISSING_OUT"
grep -q "conduct-kernel.txt missing" "$MISSING_ERR" \
  || _fail "_hermes_kernel_preamble did not warn about a missing conduct-kernel.txt:
$(cat "$MISSING_ERR")"
_ok "_hermes_kernel_preamble: a missing conduct-kernel.txt degrades to an empty preamble with a stderr warning, not a crash"

REAL_KERNEL="$INSTALL_DIR/etc/hooks/conduct-kernel.txt"
[ -f "$REAL_KERNEL" ] || _fail "missing $REAL_KERNEL"
HOOKS_REAL="$TMPBASE/hooks_real"
mkdir -p "$HOOKS_REAL/.claude/hooks"
cp "$REAL_KERNEL" "$HOOKS_REAL/.claude/hooks/conduct-kernel.txt"
PREAMBLE_REAL_OUT="$(
  HOST_HOME="$HOOKS_REAL"
  source "$PREAMBLE_FUNC"
  _hermes_kernel_preamble
)"
printf '%s' "$PREAMBLE_REAL_OUT" | grep -q 'DELEGATE WRITE BOUNDARY' \
  || _fail "_hermes_kernel_preamble real render lost the conduct kernel's delegate write boundary rule"
printf '%s' "$PREAMBLE_REAL_OUT" | grep -q 'a delegate returns the question upward\|DELEGATE IS A LEAF\|LEAF' \
  || _fail "_hermes_kernel_preamble real render is missing the delegate-is-a-leaf rule (add it to conduct-kernel.txt):
$PREAMBLE_REAL_OUT"
_ok "_hermes_kernel_preamble: real conduct-kernel.txt render carries the delegate write boundary and the leaf rule"

FI_MANIFEST="$TMPBASE/fi_manifest"
mkdir -p "$FI_MANIFEST/etc/hooks" "$FI_MANIFEST/etc/claude" "$FI_MANIFEST/etc/mcp" "$FI_MANIFEST/generated/codex" "$FI_MANIFEST/templates" "$FI_MANIFEST/lib"
cp "$INSTALL_DIR/_common.sh" "$FI_MANIFEST/_common.sh"
cp "$INSTALL_DIR/lib/portable.sh" "$FI_MANIFEST/lib/portable.sh"
cp "$INSTALL_DIR/lib/cbox_host.py" "$FI_MANIFEST/lib/cbox_host.py"
cp "$INSTALL_DIR/templates/generators.sh" "$FI_MANIFEST/templates/generators.sh"
cp "$INSTALL_DIR/etc/hooks/conduct-kernel.txt" "$FI_MANIFEST/etc/hooks/conduct-kernel.txt"
cp "$INSTALL_DIR/etc/hooks/session-core.txt" "$FI_MANIFEST/etc/hooks/session-core.txt"
cp "$INSTALL_DIR/etc/hooks/continuity_session_start.py" "$FI_MANIFEST/etc/hooks/continuity_session_start.py"
cp "$INSTALL_DIR/etc/claude/CLAUDE.md" "$FI_MANIFEST/etc/claude/CLAUDE.md"
cp "$INSTALL_DIR/etc/claude/settings.merge.json" "$FI_MANIFEST/etc/claude/settings.merge.json"
cp "$INSTALL_DIR/etc/mcp/codex_mcp_shim.py" "$FI_MANIFEST/etc/mcp/codex_mcp_shim.py"
: > "$FI_MANIFEST/generated/codex/AGENTS.override.md"
cp "$INSTALL_DIR/entrypoint.sh" "$FI_MANIFEST/entrypoint.sh"
(
  INSTALL_DIR="$FI_MANIFEST"
  export INSTALL_DIR
  export HOME="$FI_MANIFEST/home"
  mkdir -p "$HOME"
  source "$FI_MANIFEST/_common.sh"
  source "$FI_MANIFEST/templates/generators.sh"
  gen_context_manifest_into "$FI_MANIFEST/generated"
)
grep -q '"hermes_entrypoint"' "$FI_MANIFEST/generated/context-manifest.json" \
  || _fail "gen_context_manifest_into no longer writes a hermes_entrypoint digest:
$(cat "$FI_MANIFEST/generated/context-manifest.json")"
_ok "gen_context_manifest_into: context-manifest.json carries a hermes_entrypoint digest"

(
  INSTALL_DIR="$FI_MANIFEST"
  export INSTALL_DIR
  export HOME="$FI_MANIFEST/home"
  source "$FI_MANIFEST/_common.sh"
  source "$FI_MANIFEST/templates/generators.sh"
  _cbox_context_manifest_verify "$FI_MANIFEST/generated"
)
_ok "_cbox_context_manifest_verify: clean tree passes with the hermes_entrypoint digest included"

printf '\n' >> "$FI_MANIFEST/entrypoint.sh"
if (
  INSTALL_DIR="$FI_MANIFEST"
  export INSTALL_DIR
  export HOME="$FI_MANIFEST/home"
  source "$FI_MANIFEST/_common.sh"
  source "$FI_MANIFEST/templates/generators.sh"
  _cbox_context_manifest_verify "$FI_MANIFEST/generated"
) 2>/dev/null; then
  _fail "_cbox_context_manifest_verify did not catch a silent edit to entrypoint.sh (hermes channel drift)"
fi
_ok "_cbox_context_manifest_verify: a silent entrypoint.sh edit is caught as hermes_entrypoint drift"

echo "PASS: all hermes_gen checks"
