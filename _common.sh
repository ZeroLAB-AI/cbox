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

_cbox_tpl_sha() {
  cat "$INSTALL_DIR/_common.sh" "$INSTALL_DIR/templates/generators.sh" | sha256sum | awk '{print $1}'
}

mcp_all_names() {
  local etc="${ETC_DIR:-$INSTALL_DIR/etc}"
  [ -f "$etc/mcp/delegates.json" ] || return 0
  local rendered
  rendered="$(python3 "$etc/mcp/render_mcp.py" "$etc/mcp/delegates.json" all "$HOME/.claude/hooks" off claude)" \
    || die "mcp_all_names: render_mcp.py rejected $etc/mcp/delegates.json (malformed registry entry - see stderr above)"
  python3 -c '
import json
import sys

data = json.loads(sys.argv[1])
print(" ".join(sorted(data.keys())))
' "$rendered"
}

canonical_expand() {
  local sel="$1" all="$2"
  if [ -z "$sel" ] || [ "$sel" = all ]; then
    printf '%s' "$all"
    return 0
  fi
  local -a all_arr sel_arr out
  read -r -a all_arr <<< "$all"
  read -r -a sel_arr <<< "$sel"
  out=()
  local a s known
  for a in "${all_arr[@]}"; do
    known=0
    for s in "${sel_arr[@]}"; do
      if [ "$s" = "$a" ]; then
        known=1
      fi
    done
    if [ "$known" = 1 ]; then
      out+=("$a")
    fi
  done
  printf '%s' "${out[*]-}"
}
