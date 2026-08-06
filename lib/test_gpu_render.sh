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

bash -n "$INSTALL_DIR/cbox" || _fail "cbox fails bash -n"
bash -n "$INSTALL_DIR/templates/generators.sh" || _fail "generators.sh fails bash -n"
_ok "bash -n clean on cbox and templates/generators.sh"

render_isolated() {
  local eff="$1" root="$2" home="$3" gpu="$4"
  mkdir -p "$eff" "$root" "$home"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    export CBOX_GPU="$gpu"
    gen_compose_isolated "$eff" "$root" "cbox-img:test" "abcdef123456"
  )
}

ISO_ON="$TMPBASE/iso_on"
render_isolated "$ISO_ON/eff" "$ISO_ON/root" "$ISO_ON/home" 1
COMPOSE_ON="$ISO_ON/eff/docker-compose.yml"
[ -f "$COMPOSE_ON" ] || _fail "isolated: docker-compose.yml missing (gpu=1)"
grep -q '^    deploy:$' "$COMPOSE_ON" || _fail "isolated: deploy: block missing with CBOX_GPU=1"
grep -q 'driver: cdi' "$COMPOSE_ON" || _fail "isolated: cdi driver missing with CBOX_GPU=1"
grep -q 'nvidia.com/gpu=all' "$COMPOSE_ON" || _fail "isolated: nvidia.com/gpu=all device id missing with CBOX_GPU=1"
_ok "isolated compose carries the CDI reservation block when CBOX_GPU=1"

ISO_OFF="$TMPBASE/iso_off"
render_isolated "$ISO_OFF/eff" "$ISO_OFF/root" "$ISO_OFF/home" 0
COMPOSE_OFF="$ISO_OFF/eff/docker-compose.yml"
[ -f "$COMPOSE_OFF" ] || _fail "isolated: docker-compose.yml missing (gpu=0)"
! grep -q '^    deploy:$' "$COMPOSE_OFF" || _fail "isolated: deploy: block present with CBOX_GPU=0"
! grep -q 'driver: cdi' "$COMPOSE_OFF" || _fail "isolated: cdi driver present with CBOX_GPU=0"
_ok "isolated compose carries no reservation when CBOX_GPU=0 (inertness)"

ISO_BLOCK="$(sed -n '/^    deploy:$/,/nvidia\.com\/gpu=all$/p' "$COMPOSE_ON")"
GLOBAL_BLOCK="$(sed -n '/^gen_compose_gpu()/,/^EOF$/p' "$INSTALL_DIR/templates/generators.sh" \
  | sed -n '/^    deploy:$/,/nvidia\.com\/gpu=all$/p')"
[ -n "$ISO_BLOCK" ] || _fail "could not extract isolated deploy block"
[ -n "$GLOBAL_BLOCK" ] || _fail "could not extract global overlay deploy block"
[ "$ISO_BLOCK" = "$GLOBAL_BLOCK" ] \
  || _fail "isolated deploy block and global overlay block have drifted apart in shape"
_ok "isolated deploy block is byte-identical in shape to the global overlay block"

render_global_gpu() {
  local dir="$1" gpu="$2"
  mkdir -p "$dir"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    INSTALL_DIR="$dir"
    CBOX_GPU="$gpu"
    gen_compose_gpu
  )
}

GLOB_ON="$TMPBASE/glob_on"
render_global_gpu "$GLOB_ON" 1
[ -f "$GLOB_ON/docker-compose.gpu.yml" ] || _fail "global: docker-compose.gpu.yml not written when CBOX_GPU=1"
grep -q 'driver: cdi' "$GLOB_ON/docker-compose.gpu.yml" || _fail "global: cdi driver missing in overlay"
_ok "global overlay file is written when CBOX_GPU=1"

GLOB_OFF="$TMPBASE/glob_off"
mkdir -p "$GLOB_OFF"
: > "$GLOB_OFF/docker-compose.gpu.yml"
render_global_gpu "$GLOB_OFF" 0
[ ! -f "$GLOB_OFF/docker-compose.gpu.yml" ] || _fail "global: docker-compose.gpu.yml not removed when CBOX_GPU=0"
_ok "global overlay file is removed when CBOX_GPU=0"

COMPOSE_REFRESH="$TMPBASE/compose_refresh_func.sh"
awk '
  /^_cbox_compose_refresh_gpu\(\) \{/ { infunc=1 }
  infunc { print }
  infunc && /^\}/ { infunc=0; exit }
' "$INSTALL_DIR/cbox" > "$COMPOSE_REFRESH"
[ -s "$COMPOSE_REFRESH" ] || _fail "cannot extract _cbox_compose_refresh_gpu from cbox"

REFRESH_ON="$TMPBASE/refresh_on"
mkdir -p "$REFRESH_ON"
: > "$REFRESH_ON/docker-compose.yml"
: > "$REFRESH_ON/docker-compose.gpu.yml"
COMPOSE_STR="$(
  INSTALL_DIR="$REFRESH_ON" CBOX_GPU=1 bash -c '
    source "'"$COMPOSE_REFRESH"'"
    _cbox_compose_refresh_gpu
    printf "%s\n" "${COMPOSE[@]}"
  '
)"
printf '%s\n' "$COMPOSE_STR" | grep -qF -- "-f" || _fail "COMPOSE array missing -f flags entirely"
printf '%s\n' "$COMPOSE_STR" | grep -qF "$REFRESH_ON/docker-compose.gpu.yml" \
  || _fail "COMPOSE array does not pick up docker-compose.gpu.yml when CBOX_GPU=1 and file exists"
_ok "global COMPOSE array picks up the gpu overlay when CBOX_GPU=1 and the file exists"

REFRESH_OFF="$TMPBASE/refresh_off"
mkdir -p "$REFRESH_OFF"
: > "$REFRESH_OFF/docker-compose.yml"
COMPOSE_STR_OFF="$(
  INSTALL_DIR="$REFRESH_OFF" CBOX_GPU=0 bash -c '
    source "'"$COMPOSE_REFRESH"'"
    _cbox_compose_refresh_gpu
    printf "%s\n" "${COMPOSE[@]}"
  '
)"
! printf '%s\n' "$COMPOSE_STR_OFF" | grep -qF "docker-compose.gpu.yml" \
  || _fail "COMPOSE array picked up docker-compose.gpu.yml when CBOX_GPU=0"
_ok "global COMPOSE array does not add the gpu overlay when CBOX_GPU=0"

echo "PASS: all gpu_render checks"
