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

bash -n "$INSTALL_DIR/templates/generators.sh" || _fail "generators.sh fails bash -n"

python3 - "$INSTALL_DIR/etc/claude/settings.merge.json" <<'PY' || _fail "settings.merge.json env lacks the model policy keys"
import json, sys
env = json.load(open(sys.argv[1]))["env"]
assert env["ANTHROPIC_DEFAULT_FABLE_MODEL"] == "claude-fable-5[1m]", env
assert env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-5[1m]", env
assert "fable-5-1" in env["CBOX_AGENT_MODEL_BAN"], env
assert "opus-4" in env["CBOX_AGENT_MODEL_DENY"], env
PY
_ok "settings.merge.json pins fable and opus tiers and bans the fable point release"

render_isolated() {
  local eff="$1" root="$2" home="$3"
  mkdir -p "$eff" "$root" "$home"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    gen_compose_isolated "$eff" "$root" "cbox-img:test" "abcdef123456"
  )
}

render_global() {
  local dir="$1" ws
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
    export CBOX_WORKSPACES="$ws"
    gen_compose
  )
}

check_file() {
  local f="$1" label="$2"
  grep -qF "      - 'ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5[1m]'" "$f" \
    || _fail "$label: ANTHROPIC_DEFAULT_FABLE_MODEL missing from the container environment"
  grep -qF "      - 'ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5[1m]'" "$f" \
    || _fail "$label: ANTHROPIC_DEFAULT_OPUS_MODEL missing from the container environment"
  grep -qF "      - 'CBOX_AGENT_MODEL_BAN=fable-5-1'" "$f" \
    || _fail "$label: CBOX_AGENT_MODEL_BAN missing from the container environment"
  grep -qF "      - 'CBOX_AGENT_MODEL_DENY=opus-4'" "$f" \
    || _fail "$label: CBOX_AGENT_MODEL_DENY missing from the container environment"
  python3 - "$f" <<'PY' || _fail "$label: rendered compose is not parseable YAML with the policy lines"
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
doc = yaml.safe_load(open(sys.argv[1]))
env = doc["services"]["cbox"]["environment"]
assert "ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5[1m]" in env, env
assert "CBOX_AGENT_MODEL_BAN=fable-5-1" in env, env
PY
}

ISO="$TMPBASE/iso"
render_isolated "$ISO/eff" "$ISO/root" "$ISO/home"
check_file "$ISO/eff/docker-compose.yml" "isolated"
_ok "isolated compose carries the model policy env (fable/opus pins, ban, deny) into the container"

G="$TMPBASE/global"
render_global "$G"
check_file "$G/docker-compose.yml" "global"
_ok "global compose carries the model policy env into the container"

echo "all ok"
