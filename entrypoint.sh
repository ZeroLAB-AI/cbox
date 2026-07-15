#!/usr/bin/env bash
set -euo pipefail
: "${HOST_USER:?}"; : "${HOST_UID:?}"; : "${HOST_GID:?}"; : "${HOST_HOME:?}"
: "${CBOX_CLAUDE_TARGET:?}"; : "${CBOX_CODEX_VERSION:?}"
CBOX_CODEX_TARGET="${CBOX_CODEX_TARGET:-}"

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" "$HOST_USER"
id -u "$HOST_USER" >/dev/null 2>&1 || useradd -o -u "$HOST_UID" -g "$HOST_GID" -d "$HOST_HOME" -s /bin/bash "$HOST_USER"

if [ ! -d "$HOST_HOME" ]; then
  mkdir -p "$HOST_HOME"
fi
chown "$HOST_UID:$HOST_GID" "$HOST_HOME" 2>/dev/null || true

_no_symlinks() {
  local p="$1"
  while [ "$p" != "/" ] && [ -n "$p" ]; do
    if [ -L "$p" ]; then
      echo "entrypoint: refusing symlink in path ($p) - possible root-escape attempt" >&2
      exit 1
    fi
    [ -e "$p" ] && break
    p="$(dirname "$p")"
  done
}

_ensure_owned() {
  local d="$1"
  if [ ! -e "$d" ]; then
    _no_symlinks "$d"
    mkdir -p "$d"
    chown -R "$HOST_UID:$HOST_GID" "$d"
  elif [ "$(stat -c %u "$d")" != "$HOST_UID" ]; then
    _no_symlinks "$d"
    if [ -z "$(ls -A "$d" 2>/dev/null || true)" ]; then
      chown -R "$HOST_UID:$HOST_GID" "$d"
    else
      chown "$HOST_UID:$HOST_GID" "$d"
    fi
  fi
}

IFS=':' read -ra _managed_dirs <<< "${CBOX_MANAGED_DIRS:-}"
for _md in "${_managed_dirs[@]}"; do
  [ -n "$_md" ] || continue
  [ "${_md:0:1}" = "/" ] || continue
  _ensure_owned "$_md"
done

CLROOT="$HOST_HOME/.local"
CXPKG="$HOST_HOME/.codex/packages"

export HOME="$HOST_HOME"
export PATH="$HOST_HOME/.local/bin:$PATH"

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

_stamp_field() {
  [ -f "$1" ] || return 1
  sed -n "${2}p" "$1"
}

_bins_ready() {
  local name="$1" want stamp link cur_want p resolved
  case "$name" in
    claude) want="$CBOX_CLAUDE_TARGET"; stamp="$CLROOT/.cbox-stamp"; link="$CLROOT/bin/claude" ;;
    codex) want="$CBOX_CODEX_VERSION|$CBOX_CODEX_TARGET"; stamp="$CXPKG/.cbox-stamp"; link="$CLROOT/bin/codex" ;;
  esac
  cur_want="$(_stamp_field "$stamp" 1)" || return 1
  [ "$cur_want" = "$want" ] || return 1
  p="$(_stamp_field "$stamp" 2)" || return 1
  [ -n "$p" ] || return 1
  resolved="$(_resolve_bin "$link")" || return 1
  [ "$resolved" = "$p" ] && printf '%s' "$p"
}

case "${1:-}" in
  claude|codex)
    if ! _resolved="$(_bins_ready "$1")"; then
      case "$1" in
        claude) _want="$CBOX_CLAUDE_TARGET" ;;
        codex) _want="$CBOX_CODEX_VERSION|$CBOX_CODEX_TARGET" ;;
      esac
      echo "entrypoint: $1 not installed or does not match the pinned version (want $_want) - run 'cbox reinstall-bins' on the host" >&2
      exit 1
    fi
    shift
    exec /usr/sbin/gosu "$HOST_UID:$HOST_GID" "$_resolved" "$@"
    ;;
esac

exec /usr/sbin/gosu "$HOST_UID:$HOST_GID" "$@"
