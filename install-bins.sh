#!/usr/bin/env bash
set -euo pipefail
: "${HOST_USER:?}"; : "${HOST_UID:?}"; : "${HOST_GID:?}"; : "${HOST_HOME:?}"
: "${CBOX_CLAUDE_TARGET:?}"; : "${CBOX_CODEX_VERSION:?}"
CBOX_CODEX_TARGET="${CBOX_CODEX_TARGET:-}"
case "$CBOX_CODEX_TARGET" in
  *[!A-Za-z0-9._-]*) echo "install-bins: CBOX_CODEX_TARGET has invalid characters" >&2; exit 1 ;;
esac
CBOX_HERMES_VERSION="${CBOX_HERMES_VERSION:-latest}"
CBOX_INSTALL_TOOLS="${CBOX_INSTALL_TOOLS:-claude codex}"
case " $CBOX_INSTALL_TOOLS " in
  *" hermes "*)
    if [ "$CBOX_HERMES_VERSION" != latest ]; then
      printf '%s' "$CBOX_HERMES_VERSION" | grep -Eq '^[0-9]+([.][0-9]+){1,3}$' \
        || { echo "install-bins: CBOX_HERMES_VERSION must be latest or x.y[.z[.w]]" >&2; exit 1; }
    fi
    ;;
esac
CBOX_INSTALL_FORCE="${CBOX_INSTALL_FORCE:-0}"

CLROOT="$HOST_HOME/.local"
CXPKG="$HOST_HOME/.codex/packages"
HXROOT="/opt/hermes"
HXSEED="$HXROOT/delegate-home"

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" "$HOST_USER"
id -u "$HOST_USER" >/dev/null 2>&1 || useradd -o -u "$HOST_UID" -g "$HOST_GID" -d "$HOST_HOME" -s /bin/bash "$HOST_USER"

mkdir -p "$HOST_HOME"
chown "$HOST_UID:$HOST_GID" "$HOST_HOME" 2>/dev/null || true
mkdir -p "$CLROOT" "$CXPKG"
chown "$HOST_UID:$HOST_GID" "$CLROOT" "$CXPKG"

_gosu() {
  /usr/sbin/gosu "$HOST_UID:$HOST_GID" env HOME="$HOST_HOME" "$@"
}

_resolve_bin() {
  local p
  p="$(readlink -f "$1" 2>/dev/null)" || return 1
  [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] || return 1
  case "$p" in
    "$HOST_HOME"/*) ;;
    *) return 1 ;;
  esac
  head -c4 "$p" 2>/dev/null | grep -q "$(printf '\177ELF')" || return 1
  printf '%s' "$p"
}

_resolve_hermes_bin() {
  local p
  p="$(readlink -f "$HXROOT/bin/hermes" 2>/dev/null)" || return 1
  [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] || return 1
  case "$p" in
    "$HXROOT"/*) ;;
    *) return 1 ;;
  esac
  [ -x "$HXROOT/bin/python" ] || return 1
  printf '%s' "$p"
}

_resolve_tool_bin() {
  case "$1" in
    hermes) _resolve_hermes_bin ;;
    *) _resolve_bin "$(_link_for "$1")" ;;
  esac
}

_bin_hash() {
  local h
  h="$(timeout 120 sha256sum "$1" 2>/dev/null | awk '{print $1}')" || return 1
  [ -n "$h" ] || return 1
  printf '%s' "$h"
}

_hermes_hash() {
  local h
  h="$( { timeout 600 find "$HXROOT" -mindepth 1 ! -path "$HXROOT/.cbox-stamp" ! -path "$HXROOT/.prev" ! -path "$HXROOT/.prev/*" -type f -print0 2>/dev/null \
           | LC_ALL=C sort -z | xargs -0 -r sha256sum
         timeout 60 find "$HXROOT" -mindepth 1 ! -path "$HXROOT/.prev" ! -path "$HXROOT/.prev/*" -type l -printf '%p -> %l\n' 2>/dev/null \
           | LC_ALL=C sort
       } | sha256sum | awk '{print $1}')" || return 1
  [ -n "$h" ] && [ "$h" != "$(printf '' | sha256sum | awk '{print $1}')" ] || return 1
  printf '%s' "$h"
}

_tool_hash() {
  case "$1" in
    hermes) _hermes_hash "$2" ;;
    *) _bin_hash "$2" ;;
  esac
}

_user_version_raw() {
  _gosu timeout 30 "$1" --version 2>/dev/null
}

_parsed_version() {
  local name="$1" path="$2" v
  case "$name" in
    claude)
      v="$(_user_version_raw "$path" | awk '{print $1; exit}')" || v=""
      ;;
    codex)
      v="$(_user_version_raw "$path" | awk '{print $NF; exit}')" || v=""
      ;;
    hermes)
      v="$(timeout 60 "$HXROOT/bin/python" -c 'import importlib.metadata as m; print(m.version("hermes-agent"))' 2>/dev/null)" || v=""
      ;;
    *)
      v=""
      ;;
  esac
  printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?$' || return 1
  printf '%s' "$v"
}

_version_ok() {
  local name="$1" want_ver="$2" path="$3" v
  v="$(_parsed_version "$name" "$path")" || return 1
  case "$want_ver" in
    stable|latest) return 0 ;;
    *) [ "$v" = "$want_ver" ] ;;
  esac
}

_want_string() {
  local name="$1"
  case "$name" in
    claude) printf '%s' "$CBOX_CLAUDE_TARGET" ;;
    codex) printf '%s|%s' "$CBOX_CODEX_VERSION" "$CBOX_CODEX_TARGET" ;;
    hermes) printf '%s' "$CBOX_HERMES_VERSION" ;;
  esac
}

_stamp_path() {
  local name="$1"
  case "$name" in
    claude) printf '%s/.cbox-stamp' "$CLROOT" ;;
    codex) printf '%s/.cbox-stamp' "$CXPKG" ;;
    hermes) printf '%s/.cbox-stamp' "$HXROOT" ;;
  esac
}

_link_for() {
  local name="$1"
  case "$name" in
    claude) printf '%s/bin/claude' "$CLROOT" ;;
    codex) printf '%s/bin/codex' "$CLROOT" ;;
    hermes) printf '%s/bin/hermes' "$HXROOT" ;;
  esac
}

_stamp_field() {
  local file="$1" n="$2"
  [ -f "$file" ] || return 1
  sed -n "${n}p" "$file"
}

_stamp_write() {
  local file="$1" want="$2" path="$3" hash="$4" ver="$5" dir tmp
  dir="$(dirname "$file")"
  case "$file" in
    "$HXROOT"/*)
      tmp="$(mktemp "$dir/.cbox-stamp.XXXXXX")"
      printf '%s\n%s\n%s\n%s\n' "$want" "$path" "$hash" "$ver" > "$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" "$file"
      ;;
    *)
      tmp="$(_gosu mktemp "$dir/.cbox-stamp.XXXXXX")"
      printf '%s\n%s\n%s\n%s\n' "$want" "$path" "$hash" "$ver" | _gosu tee "$tmp" >/dev/null
      _gosu mv "$tmp" "$file"
      ;;
  esac
}

_adopt_check() {
  local name="$1" want="$2" stamp cur_want p resolved
  stamp="$(_stamp_path "$name")"
  [ -f "$stamp" ] || return 1
  cur_want="$(_stamp_field "$stamp" 1)" || return 1
  [ "$cur_want" = "$want" ] || return 1
  p="$(_stamp_field "$stamp" 2)" || return 1
  [ -n "$p" ] || return 1
  resolved="$(_resolve_tool_bin "$name")" || return 1
  [ "$resolved" = "$p" ] || return 1
  local cur_hash want_hash
  want_hash="$(_stamp_field "$stamp" 3)" || return 1
  cur_hash="$(_tool_hash "$name" "$resolved")" || return 1
  [ "$cur_hash" = "$want_hash" ]
}

_run_claude_install() {
  _gosu flock -w 900 "$CLROOT/.cbox-install.lock" bash -c '
    set -euo pipefail
    tmp="$(mktemp)"
    cfg="$(mktemp -d)"
    trap "rm -rf \"$tmp\" \"$cfg\"" EXIT
    curl -fsSL --connect-timeout 10 --retry 2 --retry-connrefused -o "$tmp" https://claude.ai/install.sh
    CLAUDE_CONFIG_DIR="$cfg" bash "$tmp" "$1"
  ' claude-install "$CBOX_CLAUDE_TARGET"
}

_run_codex_install() {
  /usr/sbin/gosu "$HOST_UID:$HOST_GID" env HOME="$HOST_HOME" CODEX_NON_INTERACTIVE=1 CODEX_RELEASE="$CBOX_CODEX_VERSION" flock -w 900 "$CXPKG/.cbox-install.lock" sh -c '
    set -eu
    tmp="$(mktemp)"
    trap "rm -f \"$tmp\"" EXIT
    curl -fsSL --connect-timeout 10 --retry 2 --retry-connrefused -o "$tmp" https://chatgpt.com/codex/install.sh
    sh "$tmp"
  '
}

_hermes_seed_delegate_home() {
  _hxgosu rm -rf "$HXSEED" || return 1
  _hxgosu mkdir -p "$HXSEED" || return 1
  _hxgosu env HERMES_HOME="$HXSEED" "$HXROOT/bin/hermes" setup --non-interactive || return 1
  _hxgosu rm -rf "$HXSEED/.env" "$HXSEED/skills"
  _hxgosu find "$HXSEED" -maxdepth 1 \( -name '*.db' -o -name '*.sqlite*' \) -exec rm -rf {} +
  _hermes_strip_seed_endpoints || return 1
  chown -R root:root "$HXSEED"
  find "$HXSEED" -type d -exec chmod 0555 {} \;
  find "$HXSEED" -type f -exec chmod 0444 {} \;
}

_hxgosu() {
  /usr/sbin/gosu "$HOST_UID:$HOST_GID" env HOME="$HXROOT" "$@"
}

_hermes_strip_seed_endpoints() {
  local cfg tmp rc
  for cfg in "$HXSEED"/*.yaml "$HXSEED"/*.yml; do
    [ -f "$cfg" ] || continue
    tmp="$(_hxgosu mktemp "$HXSEED/.cbox-cfg.XXXXXX")" || return 1
    rc=0
    grep -Ev '^[[:space:]-]*(base_url|endpoint|api_base|api_base_url|url)[[:space:]]*:' "$cfg" > "$tmp" || rc=$?
    if [ "$rc" -gt 1 ]; then
      _hxgosu rm -f "$tmp"
      return 1
    fi
    _hxgosu mv "$tmp" "$cfg" || return 1
  done
}

_hermes_venv_reset() {
  find "$HXROOT" -mindepth 1 -maxdepth 1 ! -name '.prev' -exec rm -rf {} + || return 1
  chown "$HOST_UID:$HOST_GID" "$HXROOT" || return 1
  _hxgosu python3 -m venv "$HXROOT"
}

_hermes_backup_dir() {
  printf '%s/.prev' "$HXROOT"
}

_hermes_tree_complete() {
  [ -x "$HXROOT/bin/python" ] && [ -e "$HXROOT/bin/hermes" ]
}

_hermes_backup_marker() {
  printf '%s/.cbox-backup-complete' "$(_hermes_backup_dir)"
}

_hermes_prev_is_real_dir() {
  local prev="$1"
  [ -e "$prev" ] || return 1
  [ -L "$prev" ] && return 1
  [ -d "$prev" ]
}

_hermes_backup_is_complete() {
  local prev
  prev="$(_hermes_backup_dir)"
  _hermes_prev_is_real_dir "$prev" && [ -f "$(_hermes_backup_marker)" ] && [ ! -L "$(_hermes_backup_marker)" ]
}

_hermes_backup_take_unwind() {
  local prev="$1" entry base
  while IFS= read -r -d '' entry; do
    base="$(basename "$entry")"
    [ "$base" = ".cbox-backup-complete" ] && continue
    mv "$entry" "$HXROOT/$base" 2>/dev/null || true
  done < <(find "$prev" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  rm -rf "$prev" 2>/dev/null || true
}

_hermes_recover_stale_backup() {
  local prev entry
  prev="$(_hermes_backup_dir)"
  [ -e "$prev" ] || return 0
  if [ -L "$prev" ]; then
    echo "install-bins: $prev is a symlink, not a real directory - refusing to follow it; remove it manually" >&2
    return 1
  fi
  [ -d "$prev" ] || return 0
  if _hermes_tree_complete; then
    rm -rf "$prev" || return 1
    return 0
  fi
  if ! _hermes_backup_is_complete; then
    echo "install-bins: $prev is present but incomplete (missing completion marker) and the live hermes tree is also incomplete - refusing to combine fragments; remove $prev manually after inspecting it if the loss is acceptable" >&2
    return 1
  fi
  find "$HXROOT" -mindepth 1 -maxdepth 1 ! -name '.prev' -exec rm -rf {} + || return 1
  while IFS= read -r -d '' entry; do
    local base
    base="$(basename "$entry")"
    [ "$base" = ".cbox-backup-complete" ] && continue
    mv "$entry" "$HXROOT/$base" || {
      echo "install-bins: recovery mv failed for $base - $prev left in place, HXROOT may be incomplete" >&2
      return 1
    }
  done < <(find "$prev" -mindepth 1 -maxdepth 1 -print0)
  rm -rf "$prev"
}

_hermes_backup_take() {
  local prev entry base found=0
  prev="$(_hermes_backup_dir)"
  rm -rf "$prev" || return 1
  local entries=()
  while IFS= read -r -d '' entry; do
    entries+=("$entry")
  done < <(find "$HXROOT" -mindepth 1 -maxdepth 1 -print0)
  for entry in "${entries[@]-}"; do
    [ -n "$entry" ] || continue
    base="$(basename "$entry")"
    [ "$base" = ".prev" ] && continue
    if [ "$found" = 0 ]; then
      mkdir -p "$prev" || return 1
      found=1
    fi
    mv "$entry" "$prev/$base" || {
      _hermes_backup_take_unwind "$prev"
      return 1
    }
  done
  if [ "$found" = 1 ]; then
    : > "$(_hermes_backup_marker)" || {
      _hermes_backup_take_unwind "$prev"
      return 1
    }
  fi
  return 0
}

_hermes_backup_commit() {
  local prev
  prev="$(_hermes_backup_dir)"
  rm -rf "$prev"
}

_hermes_backup_restore() {
  local prev entry base
  prev="$(_hermes_backup_dir)"
  [ -e "$prev" ] || return 0
  if [ -L "$prev" ]; then
    echo "install-bins: $prev is a symlink, not a real directory - refusing to follow it; remove it manually" >&2
    return 1
  fi
  [ -d "$prev" ] || return 0
  while IFS= read -r -d '' entry; do
    base="$(basename "$entry")"
    [ "$base" = ".prev" ] && continue
    rm -rf "$entry"
  done < <(find "$HXROOT" -mindepth 1 -maxdepth 1 -print0)
  while IFS= read -r -d '' entry; do
    base="$(basename "$entry")"
    [ "$base" = ".cbox-backup-complete" ] && continue
    mv "$entry" "$HXROOT/$base" || {
      echo "install-bins: restore mv failed for $base - $prev left in place, HXROOT may be incomplete" >&2
      return 1
    }
  done < <(find "$prev" -mindepth 1 -maxdepth 1 -print0)
  rm -rf "$prev"
}

_HERMES_INSTALL_VERIFIED=""
_HERMES_INSTALL_HASH=""
_HERMES_INSTALL_VER=""

_run_hermes_install() {
  local spec rc=0 backed_up=0 take_rc=0
  _HERMES_INSTALL_VERIFIED=""
  _HERMES_INSTALL_HASH=""
  _HERMES_INSTALL_VER=""
  if [ "$CBOX_HERMES_VERSION" = latest ]; then
    spec="hermes-agent"
  else
    printf '%s' "$CBOX_HERMES_VERSION" | grep -Eq '^[0-9]+([.][0-9]+){1,3}$' \
      || { echo "install-bins: CBOX_HERMES_VERSION must be latest or x.y[.z[.w]]" >&2; return 1; }
    spec="hermes-agent==$CBOX_HERMES_VERSION"
  fi
  mkdir -p "$HXROOT"
  exec 7< "$HXROOT"
  flock -w 900 7 || { echo "install-bins: timed out waiting for the hermes install lock" >&2; exec 7<&-; return 1; }
  if ! _hermes_recover_stale_backup; then
    exec 7<&-
    return 1
  fi
  if _hermes_backup_take; then
    take_rc=0
  else
    take_rc=1
  fi
  if [ -d "$(_hermes_backup_dir)" ]; then backed_up=1; fi
  if [ "$take_rc" = 0 ]; then
    if _hermes_venv_reset; then
      _hxgosu "$HXROOT/bin/pip" install --no-cache-dir "$spec" && _hermes_seed_delegate_home || rc=1
    else
      rc=1
    fi
  else
    rc=1
  fi
  if [ "$rc" = 0 ]; then
    local verified path hash ver stamp
    stamp="$(_stamp_path hermes)"
    if verified="$(_verify_tool hermes)"; then
      path="$(printf '%s' "$verified" | sed -n '1p')"
      hash="$(printf '%s' "$verified" | sed -n '2p')"
      ver="$(printf '%s' "$verified" | sed -n '3p')"
      if _stamp_write "$stamp" "$(_want_string hermes)" "$path" "$hash" "$ver"; then
        _HERMES_INSTALL_VERIFIED="$path"
        _HERMES_INSTALL_HASH="$hash"
        _HERMES_INSTALL_VER="$ver"
      else
        rc=1
      fi
    else
      rc=1
    fi
  fi
  if [ "$rc" = 0 ]; then
    if [ "$backed_up" = 1 ]; then _hermes_backup_commit; fi
  else
    if [ "$backed_up" = 1 ]; then _hermes_backup_restore; fi
  fi
  exec 7<&-
  return "$rc"
}

_verify_tool() {
  local name="$1" want_ver path hash ver
  case "$name" in
    claude) want_ver="$CBOX_CLAUDE_TARGET" ;;
    codex) want_ver="$CBOX_CODEX_VERSION" ;;
    hermes) want_ver="$CBOX_HERMES_VERSION" ;;
  esac
  path="$(_resolve_tool_bin "$name")" || return 1
  _version_ok "$name" "$want_ver" "$path" || return 1
  hash="$(_tool_hash "$name" "$path")" || return 1
  ver="$(_parsed_version "$name" "$path")" || return 1
  printf '%s\n%s\n%s\n' "$path" "$hash" "$ver"
}

_wipe_volume() {
  local dir="$1"
  if [ "$dir" = "$HXROOT" ]; then
    mkdir -p "$dir"
    exec 8< "$dir"
    flock -w 900 8 || { echo "install-bins: timed out waiting for the hermes install lock" >&2; exec 8<&-; return 1; }
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    exec 8<&-
    return 0
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

_install_one() {
  local name="$1" want stamp runfn verified path hash ver force cur_want

  want="$(_want_string "$name")"
  stamp="$(_stamp_path "$name")"
  force="$CBOX_INSTALL_FORCE"

  if [ "$force" = "1" ]; then
    case "$name" in
      claude) _wipe_volume "$CLROOT" ;;
      codex) _wipe_volume "$CXPKG" ;;
      hermes) _wipe_volume "$HXROOT" ;;
    esac
  fi

  if [ "$force" != "1" ] && [ -f "$stamp" ]; then
    cur_want="$(_stamp_field "$stamp" 1)" || cur_want=""
    if [ -n "$cur_want" ] && [ "$cur_want" != "$want" ]; then
      echo "install-bins: $name pin mismatch - volume stamped for $cur_want, requested $want - run with CBOX_INSTALL_FORCE=1 (cbox reinstall-bins) to move the shared tuple, or use CBOX_BINS_SCOPE=pinned for a private volume" >&2
      printf 'cbox-bins: %s %s %s refuse\n' "$name" "$cur_want" "$want"
      return 1
    fi
  fi

  if [ "$force" != "1" ] && [ "$force" != "refresh" ] && _adopt_check "$name" "$want"; then
    local v3 v4
    v3="$(_stamp_field "$stamp" 3)"
    v4="$(_stamp_field "$stamp" 4)"
    printf 'cbox-bins: %s %s %s adopt\n' "$name" "$v4" "$v3"
    return 0
  fi

  case "$name" in
    claude) runfn=_run_claude_install ;;
    codex) runfn=_run_codex_install ;;
    hermes) runfn=_run_hermes_install ;;
  esac

  if ! "$runfn"; then
    echo "install-bins: $name installer failed - no stamp written, $name unavailable" >&2
    printf 'cbox-bins: %s - - fail\n' "$name"
    return 1
  fi

  if [ "$name" = hermes ]; then
    if [ -z "${_HERMES_INSTALL_VERIFIED:-}" ]; then
      echo "install-bins: hermes post-install verification failed - no stamp written, hermes unavailable" >&2
      printf 'cbox-bins: %s - - fail\n' "$name"
      return 1
    fi
    printf 'cbox-bins: %s %s %s ok\n' "$name" "${_HERMES_INSTALL_VER:-}" "${_HERMES_INSTALL_HASH:-}"
    return 0
  fi

  if ! verified="$(_verify_tool "$name")"; then
    echo "install-bins: $name post-install verification failed - no stamp written, $name unavailable" >&2
    printf 'cbox-bins: %s - - fail\n' "$name"
    return 1
  fi

  path="$(printf '%s' "$verified" | sed -n '1p')"
  hash="$(printf '%s' "$verified" | sed -n '2p')"
  ver="$(printf '%s' "$verified" | sed -n '3p')"
  if ! _stamp_write "$stamp" "$want" "$path" "$hash" "$ver"; then
    echo "install-bins: $name stamp write failed - $name unavailable" >&2
    printf 'cbox-bins: %s - - fail\n' "$name"
    return 1
  fi
  printf 'cbox-bins: %s %s %s ok\n' "$name" "$ver" "$hash"
}

main() {
  local -a tools=()
  read -r -a tools <<< "$CBOX_INSTALL_TOOLS"
  local name status=0
  for name in "${tools[@]}"; do
    [ -n "$name" ] || continue
    case "$name" in
      claude|codex|hermes) ;;
      *)
        echo "install-bins: unknown tool $name" >&2
        status=1
        continue
        ;;
    esac
    _install_one "$name" || status=1
  done
  return "$status"
}

main
