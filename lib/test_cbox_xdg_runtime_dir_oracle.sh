#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

. "$INSTALL_DIR/lib/portable.sh"

_bash_expr() {
  printf '%s' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
}

_case() {
  local desc="$1"
  local expr_out waist_out
  expr_out="$(_bash_expr)"
  waist_out="$(_cbox_xdg_runtime_dir)"
  [ "$expr_out" = "$waist_out" ] || _fail "$desc: mismatch: bash-expr=[$expr_out] waist=[$waist_out]"
  _ok "$desc: [$waist_out] matches \${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
}

(
  export XDG_RUNTIME_DIR=/run/user/9999
  _case "XDG_RUNTIME_DIR set"
)

(
  unset XDG_RUNTIME_DIR
  _case "XDG_RUNTIME_DIR unset, falls back to /run/user/\$(id -u)"
)

(
  export XDG_RUNTIME_DIR=""
  _case "XDG_RUNTIME_DIR set but empty, falls back per bash :- semantics"
)

(
  export XDG_RUNTIME_DIR="/run/user/9999/with a space"
  _case "XDG_RUNTIME_DIR contains a space"
)

echo "PASS: _cbox_xdg_runtime_dir oracle against the literal bash expression it replaces"
