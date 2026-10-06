#!/usr/bin/env bash

_cbox_profile_config_dir() {
  printf '%s/.config/cbox' "$HOME"
}

_cbox_profile_root() {
  printf '%s/profiles' "$(_cbox_profile_config_dir)"
}

_cbox_profile_projects_dir() {
  printf '%s/projects' "$(_cbox_profile_config_dir)"
}

_cbox_profile_global_conf() {
  printf '%s' "${CONF:-$INSTALL_DIR/cbox.conf}"
}

_cbox_profile_name_check() {
  declare -F _cbox_val_named_profile_name >/dev/null 2>&1 || . "$INSTALL_DIR/templates/validator_lib.sh"
  _cbox_val_named_profile_name "$1" || return 1
  [ "${#1}" -le 16 ] || { printf 'must be at most 16 characters (the exec-bridge socket path limit)'; return 1; }
  return 0
}

_cbox_profile_name_valid() {
  _cbox_profile_name_check "${1-}" >/dev/null 2>&1
}

_cbox_profile_is_reserved() {
  [ "${1-}" = default ]
}

_cbox_profile_require_custom() {
  local name="${1-}" why
  if ! why="$(_cbox_profile_name_check "$name")"; then
    printf 'cbox: invalid profile name %q: %s (allowed: ^[a-z][a-z0-9-]{0,15}$)\n' "$name" "$why" >&2
    return 1
  fi
  if _cbox_profile_is_reserved "$name"; then
    echo "cbox: 'default' is a reserved profile name - it is the host login and has no store" >&2
    return 1
  fi
  return 0
}

_cbox_profile_store_dir() {
  _cbox_profile_require_custom "${1-}" || return 1
  printf '%s/%s' "$(_cbox_profile_root)" "$1"
}

_cbox_profile_eff_dir() {
  local name="${1-}" eff="${2-}"
  _cbox_profile_require_custom "$name" || return 1
  [ -n "$eff" ] || { echo "cbox: a profile runtime directory needs the project effective directory" >&2; return 1; }
  printf '%s/profiles/%s' "$eff" "$name"
}

_cbox_profile_project_eff() {
  local root="${1-}"
  [ -n "$root" ] || return 1
  printf '%s/%s' "$(_cbox_profile_projects_dir)" "$(_cbox_path_hash "$root")"
}

_cbox_profile_path_guard() {
  local path="${1-}" base cur rel part
  base="$(_cbox_profile_config_dir)"
  case "$path" in
    "$base"|"$base"/*) ;;
    *) printf 'cbox: refusing a profile path outside %s: %s\n' "$base" "$path" >&2; return 1 ;;
  esac
  rel="${path#"$base"}"
  rel="${rel#/}"
  cur="$base"
  while :; do
    if [ -L "$cur" ]; then
      printf 'cbox: refusing profile store path - %s is a symlink\n' "$cur" >&2
      return 1
    fi
    if [ -e "$cur" ] && [ ! -O "$cur" ]; then
      printf 'cbox: refusing profile store path - %s is owned by another user\n' "$cur" >&2
      return 1
    fi
    [ -n "$rel" ] || break
    part="${rel%%/*}"
    if [ "$part" = "$rel" ]; then
      rel=""
    else
      rel="${rel#*/}"
    fi
    cur="$cur/$part"
  done
  return 0
}

_cbox_profile_exists() {
  local name="${1-}" store
  _cbox_profile_name_valid "$name" || return 1
  _cbox_profile_is_reserved "$name" && return 0
  store="$(_cbox_profile_root)/$name"
  [ -d "$store" ] && [ ! -L "$store" ]
}

_cbox_profile_conf_value() {
  local conf="${1-}" line val
  [ -n "$conf" ] && [ -f "$conf" ] || return 0
  line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?CBOX_PROFILE=' "$conf" 2>/dev/null | tail -n 1)" || line=""
  [ -n "$line" ] || return 0
  val="${line#*CBOX_PROFILE=}"
  val="${val%$'\r'}"
  case "$val" in
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
  esac
  printf '%s' "$val"
}

_cbox_profile_precheck_new() {
  local name="${1-}" pconf
  _cbox_profile_require_custom "$name" || return 1
  if [ "$(_cbox_effective_mode)" = global ]; then
    printf 'cbox: profile %s needs an isolated project - the global scope has no profiles\n' "$name" >&2
    return 1
  fi
  pconf="$(_cbox_profile_project_conf)"
  _cbox_profile_require_mount_modes "$pconf" "$name"
}

_cbox_profile_resolve_from() {
  local flag="${1-}" pconf="${2-}" gconf="${3-}" check="${4-1}" val src why
  CBOX_PROFILE_EFFECTIVE=""
  CBOX_PROFILE_SOURCE=""
  if [ -n "$flag" ]; then
    val="$flag"
    src=flag
  else
    val="$(_cbox_profile_conf_value "$pconf")"
    src=project
    if [ -z "$val" ]; then
      val="$(_cbox_profile_conf_value "$gconf")"
      src=global
    fi
    if [ -z "$val" ]; then
      val=default
      src=default
    fi
  fi
  if ! why="$(_cbox_profile_name_check "$val")"; then
    printf 'cbox: invalid profile name %q from %s: %s\n' "$val" "$src" "$why" >&2
    return 1
  fi
  if [ "$check" = 1 ] && ! _cbox_profile_exists "$val"; then
    printf 'cbox: profile %q (from %s) does not exist - create it with: cbox profile add %s\n' "$val" "$src" "$val" >&2
    return 1
  fi
  CBOX_PROFILE_EFFECTIVE="$val"
  CBOX_PROFILE_SOURCE="$src"
  return 0
}

_cbox_profile_project_conf() {
  local root eff
  if declare -F _cbox_effective_mode >/dev/null 2>&1; then
    [ "$(_cbox_effective_mode)" = isolated ] || return 0
  fi
  root="$(_cbox_workspace_root 2>/dev/null)" || return 0
  eff="$(_cbox_profile_project_eff "$root")" || return 0
  [ -f "$eff/cbox.conf" ] && printf '%s' "$eff/cbox.conf"
  return 0
}

_cbox_profile_resolve() {
  local flag="${1-}" check="${2-1}" pconf=""
  [ -n "$flag" ] || pconf="$(_cbox_profile_project_conf)"
  _cbox_profile_resolve_from "$flag" "$pconf" "$(_cbox_profile_global_conf)" "$check"
}

_cbox_profile_source_text() {
  case "${1-}" in
    flag) printf -- '--profile flag' ;;
    project) printf 'project conf CBOX_PROFILE' ;;
    global) printf 'global conf CBOX_PROFILE' ;;
    *) printf 'built-in default' ;;
  esac
}

_cbox_profile_host_only() {
  if declare -F _cbox_config_in_container >/dev/null 2>&1 && _cbox_config_in_container; then
    printf 'cbox: cbox profile %s is host-only - it writes the host profile store; run it on the host, not inside the container\n' "$1" >&2
    return 1
  fi
  return 0
}

_cbox_profile_write_json() {
  local dir="$1" name="$2" tmp stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "$dir/.profile.json.XXXXXX")" || return 1
  printf '{\n  "schema": 1,\n  "name": "%s",\n  "created_at": "%s",\n  "engines": {\n    "claude": {"status": "empty"},\n    "codex": {"status": "empty"}\n  }\n}\n' "$name" "$stamp" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$dir/profile.json" || { rm -f "$tmp"; return 1; }
}

_cbox_profile_rmtree() {
  local path="${1-}" name="${2-}" parent
  _cbox_profile_name_valid "$name" || return 1
  _cbox_profile_is_reserved "$name" && return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    */..|*/../*|*/.|*/./*|*//*|*/) return 1 ;;
  esac
  [ "${path##*/}" = "$name" ] || return 1
  parent="${path%/*}"
  [ "${parent##*/}" = profiles ] || return 1
  _cbox_profile_path_guard "$parent" || return 1
  if [ -L "$path" ]; then
    rm -f -- "$path"
    return 0
  fi
  [ -e "$path" ] || return 0
  rm -rf -- "$path"
}

_cbox_profile_add() {
  local name store root
  [ $# -eq 1 ] || { echo "usage: cbox profile add <name>" >&2; return 2; }
  name="$1"
  _cbox_profile_require_custom "$name" || return 1
  _cbox_profile_host_only add || return 1
  root="$(_cbox_profile_root)"
  store="$root/$name"
  _cbox_profile_path_guard "$store" || return 1
  if [ -e "$store" ] || [ -L "$store" ]; then
    printf 'cbox: profile %s already exists at %s\n' "$name" "$store" >&2
    return 1
  fi
  (
    umask 077
    mkdir -p "$root" || exit 1
    chmod 0700 "$root" || exit 1
    mkdir -m 0700 "$store" || exit 1
    if ! {
      mkdir -m 0700 "$store/claude" "$store/codex" "$store/usage" \
        && : > "$store/codex/auth.json" \
        && chmod 0600 "$store/codex/auth.json" \
        && _cbox_profile_write_json "$store" "$name"
    }; then
      _cbox_profile_rmtree "$store" "$name" || true
      exit 1
    fi
  ) || { printf 'cbox: could not create profile %s\n' "$name" >&2; return 1; }
  printf 'cbox: profile %s created at %s (claude and codex are logged out; log in with: cbox run --profile %s claude, then /login, then cbox login --profile %s <url>)\n' "$name" "$store" "$name" "$name" >&2
}

_cbox_profile_status_text() {
  python3 -I -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    engines = data.get("engines") or {}
    print(" ".join("%s=%s" % (k, (engines[k] or {}).get("status", "?")) for k in sorted(engines)))
except Exception:
    print("profile.json=unreadable")
' "$1" 2>/dev/null || printf 'profile.json=unreadable\n'
}

_cbox_profile_list() {
  local root d name mark status star_name star_src found_star=0
  [ $# -eq 0 ] || { echo "usage: cbox profile list" >&2; return 2; }
  root="$(_cbox_profile_root)"
  _cbox_profile_path_guard "$root" || return 1
  if ! _cbox_profile_resolve "" 0; then
    star_name=""
    star_src=""
  else
    star_name="$CBOX_PROFILE_EFFECTIVE"
    star_src="$CBOX_PROFILE_SOURCE"
  fi
  mark=" "
  [ "$star_name" = default ] && mark="*"
  printf '%s %-32s %s\n' "$mark" default "claude=host codex=host"
  if [ -d "$root" ]; then
    for d in "$root"/*; do
      [ -d "$d" ] || continue
      name="${d##*/}"
      _cbox_profile_name_valid "$name" || continue
      _cbox_profile_is_reserved "$name" && continue
      if [ -L "$d" ]; then
        printf '  %-32s %s\n' "$name" "refused: symlink in the store" >&2
        continue
      fi
      mark=" "
      if [ "$name" = "$star_name" ]; then
        mark="*"
        found_star=1
      fi
      status="$(_cbox_profile_status_text "$d/profile.json")"
      printf '%s %-32s %s\n' "$mark" "$name" "$status"
    done
  fi
  if [ -n "$star_name" ] && [ "$star_name" != default ] && [ "$found_star" = 0 ]; then
    printf '* %-32s %s\n' "$star_name" "missing (set by $(_cbox_profile_source_text "$star_src"))"
  fi
  return 0
}

_cbox_profile_running_ids() {
  local name="$1" out
  command -v docker >/dev/null 2>&1 || return 0
  out="$(_cbox_docker_bounded ps -q --filter "label=cbox.profile=$name")" || {
    printf 'cbox: refusing - cannot verify that no container of profile %s is running (docker ps failed)\n' "$name" >&2
    return 1
  }
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

_cbox_profile_rm_hermes_volumes() {
  local name="${1-}" v vols
  _cbox_profile_name_valid "$name" || return 1
  _cbox_profile_is_reserved "$name" && return 1
  command -v docker >/dev/null 2>&1 || return 0
  vols="$(_cbox_docker_bounded volume ls --format '{{.Name}}')" || return 0
  while IFS= read -r v; do
    case "$v" in
      cbox-p[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-"$name"-hermes-home)
        if _cbox_docker_bounded volume rm "$v" >/dev/null; then
          printf 'cbox: removed volume %s\n' "$v"
        else
          printf 'cbox: could not remove volume %s (still in use?) - remove it with: docker volume rm %s\n' "$v" "$v" >&2
        fi
        ;;
    esac
  done <<EOF_VOLS
$vols
EOF_VOLS
  return 0
}

_cbox_profile_rm() {
  local name="" assume_yes=0 arg store gval pval pconf ids ans d projects
  for arg in "$@"; do
    case "$arg" in
      --yes) assume_yes=1 ;;
      -*) echo "usage: cbox profile rm <name> [--yes]" >&2; return 2 ;;
      *)
        [ -z "$name" ] || { echo "usage: cbox profile rm <name> [--yes]" >&2; return 2; }
        name="$arg"
        ;;
    esac
  done
  [ -n "$name" ] || { echo "usage: cbox profile rm <name> [--yes]" >&2; return 2; }
  _cbox_profile_require_custom "$name" || return 1
  _cbox_profile_host_only rm || return 1
  store="$(_cbox_profile_root)/$name"
  _cbox_profile_path_guard "$store" || return 1
  if [ ! -d "$store" ]; then
    printf 'cbox: profile %s does not exist\n' "$name" >&2
    return 1
  fi
  gval="$(_cbox_profile_conf_value "$(_cbox_profile_global_conf)")"
  if [ "$gval" = "$name" ]; then
    printf 'cbox: refusing - %s is the CBOX_PROFILE of the global conf; change it first (cbox config set CBOX_PROFILE <other>)\n' "$name" >&2
    return 1
  fi
  pconf="$(_cbox_profile_project_conf)"
  pval="$(_cbox_profile_conf_value "$pconf")"
  if [ "$pval" = "$name" ]; then
    printf 'cbox: refusing - %s is the CBOX_PROFILE of this project conf; change it first (cbox config set CBOX_PROFILE <other>)\n' "$name" >&2
    return 1
  fi
  ids="$(_cbox_profile_running_ids "$name")" || return 1
  if [ -n "$ids" ]; then
    printf 'cbox: refusing - profile %s has a running container; stop it first\n' "$name" >&2
    return 1
  fi
  if [ "$assume_yes" != 1 ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      printf 'cbox: remove profile %s - its stored logins and derived runtime directories are deleted. [y/N] ' "$name"
      read -r ans || ans=""
      case "$ans" in
        y|Y) ;;
        *) echo "cbox: cancelled" >&2; return 1 ;;
      esac
    else
      echo "cbox: refusing - removing a profile deletes its stored logins; there is no TTY to confirm, pass --yes" >&2
      return 1
    fi
  fi
  projects="$(_cbox_profile_projects_dir)"
  if [ -d "$projects" ] && [ ! -L "$projects" ]; then
    for d in "$projects"/*; do
      [ -d "$d" ] || continue
      [ -e "$d/profiles/$name" ] || [ -L "$d/profiles/$name" ] || continue
      _cbox_profile_rmtree "$d/profiles/$name" "$name" || return 1
    done
  fi
  _cbox_profile_rm_hermes_volumes "$name" || return 1
  _cbox_profile_rmtree "$store" "$name" || return 1
  printf 'cbox: profile %s removed\n' "$name"
}

_cbox_profile_cmd() {
  local verb="${1-}"
  [ $# -eq 0 ] || shift
  case "$verb" in
    add) _cbox_profile_add "$@" ;;
    list|ls) _cbox_profile_list "$@" ;;
    rm) _cbox_profile_rm "$@" ;;
    *)
      echo "usage: cbox profile {add <name>|list|ls|rm <name> [--yes]}" >&2
      return 2
      ;;
  esac
}

_cbox_profile_doctor_detail() {
  local store state out
  out="$(_cbox_profile_resolve "" 1 2>&1 && printf 'OK:%s:%s' "$CBOX_PROFILE_EFFECTIVE" "$CBOX_PROFILE_SOURCE")" || {
    out="$(printf '%s' "$out" | tr '\n' ' ')"
    printf 'unresolved: %s' "${out#cbox: }"
    return 1
  }
  CBOX_PROFILE_SOURCE="${out##*:}"
  out="${out%:*}"
  CBOX_PROFILE_EFFECTIVE="${out#OK:}"
  if [ "$CBOX_PROFILE_EFFECTIVE" = default ]; then
    state="host login (no store)"
  else
    store="$(_cbox_profile_root)/$CBOX_PROFILE_EFFECTIVE"
    state="store $store"
  fi
  printf '%s (from %s), %s' "$CBOX_PROFILE_EFFECTIVE" "$(_cbox_profile_source_text "$CBOX_PROFILE_SOURCE")" "$state"
}

_CBOX_PF_NAME=""
_CBOX_PF_NEW=0
_CBOX_PF_SHIFT=0
_CBOX_VERB_PROFILE=""

_cbox_profile_flags_reset() {
  _CBOX_PF_NAME=""
  _CBOX_PF_NEW=0
  _CBOX_PF_SHIFT=0
}

_cbox_profile_flag_take() {
  local allow_new="${1-0}" arg val n new=0
  shift
  arg="${1-}"
  case "$arg" in
    --profile|--new-profile)
      if [ "$arg" = --new-profile ]; then
        [ "$allow_new" = 1 ] || return 1
        new=1
      fi
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        printf 'cbox: %s needs a profile name\n' "$arg" >&2
        return 2
      fi
      val="$2"
      n=2
      ;;
    --profile=*|--new-profile=*)
      case "$arg" in
        --new-profile=*)
          [ "$allow_new" = 1 ] || return 1
          new=1
          ;;
      esac
      val="${arg#*=}"
      if [ -z "$val" ]; then
        printf 'cbox: %s needs a profile name\n' "${arg%%=*}" >&2
        return 2
      fi
      n=1
      ;;
    *) return 1 ;;
  esac
  if [ -n "$_CBOX_PF_NAME" ] && [ "$_CBOX_PF_NAME" != "$val" ]; then
    printf 'cbox: conflicting profile flags: %s and %s\n' "$_CBOX_PF_NAME" "$val" >&2
    return 2
  fi
  _CBOX_PF_NAME="$val"
  [ "$new" = 0 ] || _CBOX_PF_NEW=1
  _CBOX_PF_SHIFT="$n"
  return 0
}

_cbox_profile_select() {
  local flag="${1-}" mode
  _CBOX_VERB_PROFILE=""
  _cbox_profile_resolve "$flag" || return 1
  if [ "$CBOX_PROFILE_EFFECTIVE" = default ]; then
    return 0
  fi
  mode="$(_cbox_effective_mode)"
  if [ "$mode" = global ]; then
    printf 'cbox: profile %s (from %s) needs an isolated project - the global scope has no profiles; use --profile default or cbox config set CBOX_PROFILE default\n' "$CBOX_PROFILE_EFFECTIVE" "$(_cbox_profile_source_text "$CBOX_PROFILE_SOURCE")" >&2
    return 1
  fi
  _CBOX_VERB_PROFILE="$CBOX_PROFILE_EFFECTIVE"
  return 0
}

_cbox_eff_bridge_key() {
  local eff="${1-}" parent scope
  parent="${eff%/*}"
  if [ "${parent##*/}" = profiles ]; then
    scope="${parent%/*}"
    printf 'p%s-%s' "${scope##*/}" "${eff##*/}"
  else
    printf 'p%s' "${eff##*/}"
  fi
}

_cbox_profile_prepare_eff() {
  local eff="${1-}" root="${2-}" profile="${3-}" eff_p tmp
  [ -n "$eff" ] && [ -n "$root" ] || return 1
  eff_p="$(_cbox_profile_eff_dir "$profile" "$eff")" || return 1
  if [ -L "$eff/profiles" ] || [ -L "$eff_p" ]; then
    printf 'cbox: refusing - %s is a symlink\n' "$eff_p" >&2
    return 1
  fi
  ( umask 077; mkdir -p "$eff/profiles" "$eff_p" ) || return 1
  chmod 0700 "$eff/profiles" "$eff_p" || return 1
  tmp="$(mktemp "$eff_p/.workspace.XXXXXX")" || return 1
  if [ -f "$eff/workspace" ]; then
    cp "$eff/workspace" "$tmp" || { rm -f "$tmp"; return 1; }
  else
    printf '%s\n' "$root" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$eff_p/workspace" || { rm -f "$tmp"; return 1; }
  printf '%s' "$eff_p"
}

_cbox_profile_harvest() {
  local eff_p="${1-}" store="${2-}"
  [ -n "$eff_p" ] && [ -n "$store" ] || return 0
  [ -f "$eff_p/claude-config/.claude.json" ] && [ ! -L "$eff_p/claude-config/.claude.json" ] || return 0
  [ -f "$store/profile.json" ] && [ ! -L "$store/profile.json" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$INSTALL_DIR/lib/cbox_profile_seed.py" ] || return 0
  python3 -I "$INSTALL_DIR/lib/cbox_profile_seed.py" harvest "$eff_p/claude-config/.claude.json" "$store/profile.json" >/dev/null 2>&1 || true
  return 0
}

_cbox_profile_applied_file() {
  printf '%s/state/lockdown-applied' "${1-}"
}

_cbox_profile_applied_get() {
  local f
  f="$(_cbox_profile_applied_file "${1-}")"
  if [ -f "$f" ] && [ ! -L "$f" ] && grep -qxF -- "${2-}=1" "$f" 2>/dev/null; then
    printf '1'
  else
    printf '0'
  fi
}

_cbox_profile_applied_set() {
  local eff_p="${1-}" f tmp pair
  shift
  [ -n "$eff_p" ] || return 1
  f="$(_cbox_profile_applied_file "$eff_p")"
  [ ! -L "$f" ] || return 1
  [ ! -L "$eff_p/state" ] || return 1
  ( umask 077; mkdir -p "$eff_p/state" ) || return 1
  tmp="$(mktemp "$eff_p/state/.lockdown.XXXXXX")" || return 1
  {
    [ ! -f "$f" ] || grep -E '^CBOX_(EGRESS|NETACCESS)_APPLIED=1$' "$f" 2>/dev/null || true
    for pair in "$@"; do
      case "$pair" in
        CBOX_EGRESS_APPLIED=1|CBOX_NETACCESS_APPLIED=1) printf '%s\n' "$pair" ;;
      esac
    done
  } | sort -u > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

_cbox_profile_apply_env() {
  local eff_p="${1-}"
  CBOX_EGRESS_APPLIED="$(_cbox_profile_applied_get "$eff_p" CBOX_EGRESS_APPLIED)"
  CBOX_NETACCESS_APPLIED="$(_cbox_profile_applied_get "$eff_p" CBOX_NETACCESS_APPLIED)"
  export CBOX_EGRESS_APPLIED CBOX_NETACCESS_APPLIED
}
