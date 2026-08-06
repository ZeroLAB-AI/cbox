#!/usr/bin/env bash
if [ -n "${_CBOX_PORTABLE_LOADED:-}" ]; then
  return 0
fi
_CBOX_PORTABLE_LOADED=1

_CBOX_PORTABLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CBOX_HOST_PY="$_CBOX_PORTABLE_DIR/cbox_host.py"
unset _CBOX_PORTABLE_DIR

_cbox_sha256() {
  if [ "$#" -gt 0 ]; then
    python3 "$_CBOX_HOST_PY" sha256 "$1"
    return $?
  fi
  python3 "$_CBOX_HOST_PY" sha256
  return $?
}

_cbox_flock() {
  python3 "$_CBOX_HOST_PY" flock "$@"
  return $?
}

_cbox_realpath() {
  python3 "$_CBOX_HOST_PY" realpath "$1"
  return $?
}

_cbox_realpath_m() {
  python3 "$_CBOX_HOST_PY" realpath -m "$1"
  return $?
}

_cbox_timeout() {
  python3 "$_CBOX_HOST_PY" timeout "$@"
  return $?
}

_cbox_stat_uid() {
  python3 "$_CBOX_HOST_PY" stat_uid "$@"
  return $?
}

_cbox_stat_mtime() {
  python3 "$_CBOX_HOST_PY" stat_mtime "$@"
  return $?
}

_cbox_ismount() {
  python3 "$_CBOX_HOST_PY" ismount "$1"
  return $?
}

_cbox_xdg_runtime_dir() {
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s' "$XDG_RUNTIME_DIR"
  else
    printf '/run/user/%s' "$(id -u)"
  fi
}

_cbox_is_darwin() {
  [ "$(uname -s)" = Darwin ]
}

_cbox_readarray() {
  local _cbox_readarray_var="$1"
  local _cbox_readarray_line
  while IFS= read -r _cbox_readarray_line || [ -n "$_cbox_readarray_line" ]; do
    eval "$_cbox_readarray_var+=(\"\$_cbox_readarray_line\")"
  done
}
