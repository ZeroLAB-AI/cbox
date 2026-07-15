#!/usr/bin/env bash
set -euo pipefail
: "${HOST_USER:?}"; : "${HOST_UID:?}"; : "${HOST_GID:?}"; : "${HOST_HOME:?}"
: "${CBOX_CLAUDE_TARGET:?}"; : "${CBOX_CODEX_VERSION:?}"
CBOX_CODEX_TARGET="${CBOX_CODEX_TARGET:-}"
case "$CBOX_CODEX_TARGET" in
  *[!A-Za-z0-9._-]*) echo "install-bins: CBOX_CODEX_TARGET has invalid characters" >&2; exit 1 ;;
esac
CBOX_INSTALL_TOOLS="${CBOX_INSTALL_TOOLS:-claude codex}"
CBOX_INSTALL_FORCE="${CBOX_INSTALL_FORCE:-0}"

CLROOT="$HOST_HOME/.local"
CXPKG="$HOST_HOME/.codex/packages"

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

_bin_hash() {
  local h
  h="$(timeout 120 sha256sum "$1" 2>/dev/null | awk '{print $1}')" || return 1
  [ -n "$h" ] || return 1
  printf '%s' "$h"
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
  esac
}

_stamp_path() {
  local name="$1"
  case "$name" in
    claude) printf '%s/.cbox-stamp' "$CLROOT" ;;
    codex) printf '%s/.cbox-stamp' "$CXPKG" ;;
  esac
}

_link_for() {
  local name="$1"
  case "$name" in
    claude) printf '%s/bin/claude' "$CLROOT" ;;
    codex) printf '%s/bin/codex' "$CLROOT" ;;
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
  tmp="$(_gosu mktemp "$dir/.cbox-stamp.XXXXXX")"
  printf '%s\n%s\n%s\n%s\n' "$want" "$path" "$hash" "$ver" | _gosu tee "$tmp" >/dev/null
  _gosu mv "$tmp" "$file"
}

_adopt_check() {
  local name="$1" want="$2" stamp cur_want p resolved
  stamp="$(_stamp_path "$name")"
  [ -f "$stamp" ] || return 1
  cur_want="$(_stamp_field "$stamp" 1)" || return 1
  [ "$cur_want" = "$want" ] || return 1
  p="$(_stamp_field "$stamp" 2)" || return 1
  [ -n "$p" ] || return 1
  resolved="$(_resolve_bin "$(_link_for "$name")")" || return 1
  [ "$resolved" = "$p" ] || return 1
  local cur_hash want_hash
  want_hash="$(_stamp_field "$stamp" 3)" || return 1
  cur_hash="$(_bin_hash "$resolved")" || return 1
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

_verify_tool() {
  local name="$1" want_ver path hash ver
  case "$name" in
    claude) want_ver="$CBOX_CLAUDE_TARGET" ;;
    codex) want_ver="$CBOX_CODEX_VERSION" ;;
  esac
  path="$(_resolve_bin "$(_link_for "$name")")" || return 1
  _version_ok "$name" "$want_ver" "$path" || return 1
  hash="$(_bin_hash "$path")" || return 1
  ver="$(_parsed_version "$name" "$path")" || return 1
  printf '%s\n%s\n%s\n' "$path" "$hash" "$ver"
}

_wipe_volume() {
  local dir="$1"
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

  if [ "$force" != "1" ] && _adopt_check "$name" "$want"; then
    local v3 v4
    v3="$(_stamp_field "$stamp" 3)"
    v4="$(_stamp_field "$stamp" 4)"
    printf 'cbox-bins: %s %s %s adopt\n' "$name" "$v4" "$v3"
    return 0
  fi

  case "$name" in
    claude) runfn=_run_claude_install ;;
    codex) runfn=_run_codex_install ;;
  esac

  if ! "$runfn"; then
    echo "install-bins: $name installer failed - no stamp written, $name unavailable" >&2
    printf 'cbox-bins: %s - - fail\n' "$name"
    return 1
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
      claude|codex) ;;
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
