#!/usr/bin/env bash
if [ -n "${_CBOX_COMMON_LOADED:-}" ]; then
  return 0
fi
_CBOX_COMMON_LOADED=1

die() {
  printf 'cbox: error: %s\n' "$*" >&2
  exit 1
}

_cbox_workspace_root() {
  local r
  if r="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
    r="$(realpath "$r")"
  else
    r="$(realpath "$PWD")"
  fi
  [ "$r" = "/" ] && return 1
  [ "$r" = "$(realpath "$HOME")" ] && return 1
  mountpoint -q "$r" 2>/dev/null && return 1
  printf '%s' "$r"
}

_cbox_path_hash() {
  local root="$1" sha
  sha="$(printf '%s' "$root" | sha256sum)"
  printf '%s' "${sha:0:12}"
}

_cbox_slug() {
  local root="$1" slug
  slug="$(printf '%s' "$root" | sed -E 's/[^a-zA-Z0-9]/-/g')"
  printf '%s' "$slug"
}

_cbox_workspace_file_check() {
  local root="$1" eff="$2" wf recorded
  wf="$eff/workspace"
  if [ -f "$wf" ]; then
    recorded="$(cat "$wf")"
    [ "$recorded" = "$root" ] || die "path-hash collision or moved project for $root (effective dir claims $recorded); remove $eff after review"
  fi
}

_cbox_is_rootless_docker() {
  docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless
}
