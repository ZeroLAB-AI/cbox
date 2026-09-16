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

render_isolated() {
  local eff="$1" root="$2" home="$3" hermes="$4" delegate="$5"
  mkdir -p "$eff" "$root" "$home"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    export CBOX_HERMES="$hermes"
    export CBOX_HERMES_PROVIDER=local
    export CBOX_HERMES_MODEL_URL="http://ollama:11434"
    export CBOX_HERMES_MODEL_NAME=qwen
    export CBOX_HERMES_VERSION=latest
    if [ -n "$delegate" ]; then
      export CBOX_HERMES_DELEGATE="$delegate"
    else
      unset CBOX_HERMES_DELEGATE
    fi
    gen_compose_isolated "$eff" "$root" "cbox-img:test" "abcdef123456"
  )
}

render_global() {
  local dir="$1" hermes="$2" delegate="$3" ws
  ws="${dir}-ws"
  mkdir -p "$dir/generated/state" "$dir/generated/claude-config" "$ws"
  : > "$dir/image.inputs"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    INSTALL_DIR="$dir"
    HOME="$dir/home"
    mkdir -p "$HOME"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    export CBOX_WORKSPACES="$ws"
    export CBOX_HERMES="$hermes"
    export CBOX_HERMES_PROVIDER=local
    export CBOX_HERMES_MODEL_URL="http://ollama:11434"
    export CBOX_HERMES_MODEL_NAME=qwen
    export CBOX_HERMES_VERSION=latest
    if [ -n "$delegate" ]; then
      export CBOX_HERMES_DELEGATE="$delegate"
    else
      unset CBOX_HERMES_DELEGATE
    fi
    gen_compose
  )
}

ON="$TMPBASE/on"
render_isolated "$ON/eff" "$ON/root" "$ON/home" on on
grep -q '^      - CBOX_HERMES_DELEGATE=on$' "$ON/eff/docker-compose.yml" \
  || _fail "isolated: CBOX_HERMES_DELEGATE=on missing from the container environment when the delegate is on"
_ok "isolated compose carries CBOX_HERMES_DELEGATE=on into the container when the delegate is on"

OFF="$TMPBASE/off"
render_isolated "$OFF/eff" "$OFF/root" "$OFF/home" on ""
grep -q '^      - CBOX_HERMES_DELEGATE=off$' "$OFF/eff/docker-compose.yml" \
  || _fail "isolated: an unset delegate must render as CBOX_HERMES_DELEGATE=off"
_ok "isolated compose renders CBOX_HERMES_DELEGATE=off when the delegate is unset"

NOH="$TMPBASE/noh"
render_isolated "$NOH/eff" "$NOH/root" "$NOH/home" off on
if grep -q 'CBOX_HERMES_DELEGATE' "$NOH/eff/docker-compose.yml"; then
  _fail "isolated: CBOX_HERMES_DELEGATE leaked into the environment while hermes itself is off"
fi
_ok "isolated compose omits CBOX_HERMES_DELEGATE while hermes is off"

G="$TMPBASE/global"
render_global "$G" on on
grep -q '^      - CBOX_HERMES_DELEGATE=on$' "$G/docker-compose.yml" \
  || _fail "global: CBOX_HERMES_DELEGATE=on missing from the container environment when the delegate is on"
_ok "global compose carries CBOX_HERMES_DELEGATE=on into the container when the delegate is on"

GOFF="$TMPBASE/global_off"
render_global "$GOFF" on ""
grep -q '^      - CBOX_HERMES_DELEGATE=off$' "$GOFF/docker-compose.yml" \
  || _fail "global: an unset delegate must render as CBOX_HERMES_DELEGATE=off"
_ok "global compose renders CBOX_HERMES_DELEGATE=off when the delegate is unset"

GNOH="$TMPBASE/global_noh"
render_global "$GNOH" off on
if grep -q 'CBOX_HERMES_DELEGATE' "$GNOH/docker-compose.yml"; then
  _fail "global: CBOX_HERMES_DELEGATE leaked into the environment while hermes is off"
fi
_ok "global compose omits CBOX_HERMES_DELEGATE while hermes is off"

echo "all ok"
