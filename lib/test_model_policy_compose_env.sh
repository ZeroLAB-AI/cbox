#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

while IFS='=' read -r name _; do
  case "$name" in CBOX_*) unset "$name" ;; esac
done < <(env)

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

bash -n "$INSTALL_DIR/templates/generators.sh" || _fail "generators.sh fails bash -n"

python3 - "$INSTALL_DIR/etc/claude/settings.merge.json" <<'PY' || _fail "settings.merge.json env lacks the model policy keys"
import json, sys
env = json.load(open(sys.argv[1]))["env"]
assert env["ANTHROPIC_DEFAULT_FABLE_MODEL"] == "claude-opus-5-5[1m]", env
assert env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-5-5[1m]", env
assert env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "claude-haiku-5-5", env
assert "fable-5-1" in env["CBOX_AGENT_MODEL_BAN"], env
assert "opus-4" in env["CBOX_AGENT_MODEL_DENY"], env
PY
_ok "settings.merge.json pins fable, opus and haiku tiers and bans the fable point release"

render_isolated() {
  local eff="$1" root="$2" home="$3" model="$4"
  mkdir -p "$eff" "$root" "$home"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    [ -z "$model" ] || export CBOX_MODEL_FABLE="$model"
    gen_compose_isolated "$eff" "$root" "cbox-img:test" "abcdef123456"
  )
}

render_global() {
  local dir="$1" model="$2" ws
  ws="${dir}-ws"
  mkdir -p "$dir/generated/state" "$dir/generated/claude-config" "$ws"
  : > "$dir/image.inputs"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    INSTALL_DIR="$dir"
    HOME="$dir/home"
    mkdir -p "$HOME" "$dir/etc/claude"
    cp "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etc/claude/settings.merge.json" "$dir/etc/claude/settings.merge.json" 2>/dev/null || true
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    [ -z "$model" ] || export CBOX_MODEL_FABLE="$model"
    export CBOX_WORKSPACES="$ws"
    gen_compose
  )
}

check_file() {
  local f="$1" label="$2" model="$3"
  grep -qF "      - 'ANTHROPIC_DEFAULT_FABLE_MODEL=$model'" "$f" \
    || _fail "$label: ANTHROPIC_DEFAULT_FABLE_MODEL missing from the container environment"
  grep -qF "      - 'ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5[1m]'" "$f" \
    || _fail "$label: ANTHROPIC_DEFAULT_OPUS_MODEL missing from the container environment"
  grep -qF "      - 'ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5'" "$f" \
    || _fail "$label: ANTHROPIC_DEFAULT_HAIKU_MODEL missing from the container environment"
  grep -qF "      - 'CBOX_AGENT_MODEL_BAN=fable-5-1'" "$f" \
    || _fail "$label: CBOX_AGENT_MODEL_BAN missing from the container environment"
  grep -qF "      - 'CBOX_AGENT_MODEL_DENY=opus-4'" "$f" \
    || _fail "$label: CBOX_AGENT_MODEL_DENY missing from the container environment"
  python3 - "$f" "$model" <<'PY' || _fail "$label: rendered compose is not parseable YAML with the policy lines"
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
doc = yaml.safe_load(open(sys.argv[1]))
env = doc["services"]["cbox"]["environment"]
assert "ANTHROPIC_DEFAULT_FABLE_MODEL=" + sys.argv[2] in env, env
assert "CBOX_AGENT_MODEL_BAN=fable-5-1" in env, env
PY
}

ISO="$TMPBASE/iso"
render_isolated "$ISO/eff" "$ISO/root" "$ISO/home" ""
check_file "$ISO/eff/docker-compose.yml" "isolated" 'claude-opus-5-5[1m]'
_ok "isolated compose carries the model policy env (fable/opus pins, ban, deny) into the container"

G="$TMPBASE/global"
render_global "$G" ""
check_file "$G/docker-compose.yml" "global" 'claude-opus-5-5[1m]'
_ok "global compose carries the model policy env into the container"

for model in 'claude-opus-5-5[1m]' 'claude-opus-5-5'; do
  if [ "$model" = 'claude-opus-5-5[1m]' ]; then
    unset CBOX_MODEL_FABLE
  else
    export CBOX_MODEL_FABLE="$model"
  fi
  for src in settings.merge.json managed-settings.merge.json; do
    python3 "$INSTALL_DIR/etc/adapters/claude.py" settings-merge "$INSTALL_DIR/etc/claude/$src" "$TMPBASE/home" "$model" > "$TMPBASE/rendered.json"
    python3 - "$TMPBASE/rendered.json" "$model" <<'PY' || _fail "$src: wrong fable pin"
import json, sys
assert json.load(open(sys.argv[1]))["env"]["ANTHROPIC_DEFAULT_FABLE_MODEL"] == sys.argv[2]
PY
  done
  source <(sed -n '/^merge_settings_json() {/,/^}/p' "$INSTALL_DIR/lib/cbox-setup.sh")
  printf '{}\n' > "$TMPBASE/target.json"
  merge_settings_json "$TMPBASE/target.json" "$INSTALL_DIR/etc/claude/settings.merge.json" "$TMPBASE/home" "$TMPBASE/host-merged.json"
  python3 - "$TMPBASE/host-merged.json" "$model" <<'PY' || _fail "host settings merge: wrong fable pin"
import json, sys
assert json.load(open(sys.argv[1]))["env"]["ANTHROPIC_DEFAULT_FABLE_MODEL"] == sys.argv[2]
PY
done
_ok "default and override reach both settings merges and the host settings merge"

ISO_OVERRIDE="$TMPBASE/iso-override"
render_isolated "$ISO_OVERRIDE/eff" "$ISO_OVERRIDE/root" "$ISO_OVERRIDE/home" 'claude-opus-5-5'
check_file "$ISO_OVERRIDE/eff/docker-compose.yml" "isolated override" 'claude-opus-5-5'
G_OVERRIDE="$TMPBASE/global-override"
render_global "$G_OVERRIDE" 'claude-opus-5-5'
check_file "$G_OVERRIDE/docker-compose.yml" "global override" 'claude-opus-5-5'
_ok "override reaches both compose environments"

source "$INSTALL_DIR/templates/validator_lib.sh"
source "$INSTALL_DIR/templates/validator_dispatch.sh"
source "$INSTALL_DIR/templates/sections.sh"
[ "$(sec_get SEC_VARS settings)" = "CBOX_MODEL_FABLE CBOX_MODEL_OPUS CBOX_MODEL_HAIKU" ] || _fail "config set whitelist lacks the claude model keys"
[ "$(sec_get SEC_APPLY settings)" = recreate ] || _fail "model setting does not stage a recreate"
_cbox_reg_validate_var CBOX_MODEL_FABLE 'claude-opus-5-5[1m]' >/dev/null || _fail "default rejected"
_cbox_reg_validate_var CBOX_MODEL_FABLE 'claude-opus-5-5' >/dev/null || _fail "override rejected"
for bad in 'claude-fable-5-1' 'claude-fable-5-1[1m]'; do
  reason="$(_cbox_reg_validate_var CBOX_MODEL_FABLE "$bad")" && _fail "banned model accepted: $bad"
  case "$reason" in *banned*) ;; *) _fail "ban is not named: $reason" ;; esac
done
_cbox_reg_validate_var CBOX_MODEL_FABLE 'Claude Opus' >/dev/null && _fail "malformed model accepted"
_ok "validator accepts model IDs and rejects the banned release and malformed input"

python3 - "$INSTALL_DIR" <<'PY' || _fail "registry defaults of the model keys differ from the shipped merge-file literals"
import json, sys
root = sys.argv[1]
reg = {v["key"]: v["default"] for v in json.load(open(root + "/etc/registry/settings.json"))["variables"]}
pairs = {
    "CBOX_MODEL_FABLE": "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "CBOX_MODEL_OPUS": "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "CBOX_MODEL_HAIKU": "ANTHROPIC_DEFAULT_HAIKU_MODEL",
}
for src in ("settings.merge.json", "managed-settings.merge.json"):
    env = json.load(open(root + "/etc/claude/" + src))["env"]
    for key, name in pairs.items():
        assert env[name] == reg[key], (src, name, env[name], reg[key])
delegates = json.load(open(root + "/etc/mcp/delegates.json"))
for tier, key in (("codex-sol", "CBOX_MODEL_CODEX_SOL"), ("codex-luna", "CBOX_MODEL_CODEX_LUNA"), ("codex-astra", "CBOX_MODEL_CODEX_ASTRA")):
    assert delegates[tier]["_cbox"]["model"] == reg[key], (tier, reg[key])
PY
_ok "registry defaults equal the shipped literals (settings, managed settings, delegates.json)"

unset CBOX_MODEL_FABLE
export CBOX_MODEL_OPUS='claude-opus-5-6[1m]'
export CBOX_MODEL_HAIKU='claude-haiku-5-6'
ISO_PINS="$TMPBASE/iso-pins"
render_isolated "$ISO_PINS/eff" "$ISO_PINS/root" "$ISO_PINS/home" ""
G_PINS="$TMPBASE/global-pins"
render_global "$G_PINS" ""
for f in "$ISO_PINS/eff/docker-compose.yml" "$G_PINS/docker-compose.yml"; do
  grep -qF "      - 'ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-6[1m]'" "$f" || _fail "opus pin missing from $f"
  grep -qF "      - 'ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-6'" "$f" || _fail "haiku pin missing from $f"
  grep -qF "      - 'ANTHROPIC_DEFAULT_FABLE_MODEL=claude-opus-5-5[1m]'" "$f" || _fail "fable pin changed by the opus and haiku keys in $f"
done
for src in settings.merge.json managed-settings.merge.json; do
  python3 "$INSTALL_DIR/etc/adapters/claude.py" settings-merge "$INSTALL_DIR/etc/claude/$src" "$TMPBASE/home" "claude-opus-5-5[1m]" "$CBOX_MODEL_OPUS" "$CBOX_MODEL_HAIKU" > "$TMPBASE/rendered.json"
  python3 - "$TMPBASE/rendered.json" <<'PY' || _fail "$src: wrong opus or haiku pin"
import json, sys
env = json.load(open(sys.argv[1]))["env"]
assert env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-5-6[1m]", env
assert env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "claude-haiku-5-6", env
assert env["ANTHROPIC_DEFAULT_FABLE_MODEL"] == "claude-opus-5-5[1m]", env
PY
done
printf '{}\n' > "$TMPBASE/target.json"
merge_settings_json "$TMPBASE/target.json" "$INSTALL_DIR/etc/claude/settings.merge.json" "$TMPBASE/home" "$TMPBASE/host-merged.json"
python3 - "$TMPBASE/host-merged.json" <<'PY' || _fail "host settings merge: wrong opus or haiku pin"
import json, sys
env = json.load(open(sys.argv[1]))["env"]
assert env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-5-6[1m]", env
assert env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "claude-haiku-5-6", env
PY
unset CBOX_MODEL_OPUS CBOX_MODEL_HAIKU
_ok "opus and haiku keys reach both composes, both settings merges and the host settings merge; unset keys keep the default render"

for key in CBOX_MODEL_OPUS CBOX_MODEL_HAIKU; do
  _cbox_reg_validate_var "$key" 'claude-opus-5-6[1m]' >/dev/null || _fail "$key rejects a valid model"
  reason="$(_cbox_reg_validate_var "$key" 'claude-fable-5-1')" && _fail "$key accepts the banned release"
  case "$reason" in *banned*) ;; *) _fail "$key ban is not named: $reason" ;; esac
done
for key in CBOX_MODEL_CODEX_SOL CBOX_MODEL_CODEX_LUNA CBOX_MODEL_CODEX_ASTRA; do
  _cbox_reg_validate_var "$key" 'gpt-6.1-sol' >/dev/null || _fail "$key rejects a valid model"
  _cbox_reg_validate_var "$key" 'gpt-6-Sol' >/dev/null && _fail "$key accepts a malformed model"
done
[ "$(sec_get SEC_VARS mcp-servers)" = "CBOX_MCP_SERVERS CBOX_MODEL_CODEX_SOL CBOX_MODEL_CODEX_LUNA CBOX_MODEL_CODEX_ASTRA" ] || _fail "config set whitelist lacks the codex model keys"
[ "$(sec_get SEC_APPLY mcp-servers)" = restart ] || _fail "codex model keys do not stage a restart"
_ok "model keys validate and are on the config set whitelist"

echo "all ok"
