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

if ! command -v mountpoint >/dev/null 2>&1; then
  echo "SKIP: util-linux mountpoint not found on PATH - the oracle needs it as counterparty, this run proves nothing"
  echo "PASS: _cbox_ismount oracle skipped (no util-linux mountpoint)"
  exit 0
fi

. "$INSTALL_DIR/lib/portable.sh"

_case() {
  local desc="$1" path="$2"
  local gnu_rc waist_rc
  set +e
  mountpoint -q "$path" 2>"$TMPBASE/gnu.err"
  gnu_rc=$?
  _cbox_ismount "$path" 2>"$TMPBASE/waist.err"
  waist_rc=$?
  set -e
  [ "$gnu_rc" = "$waist_rc" ] || _fail "$desc: exit code mismatch: gnu(mountpoint -q)=$gnu_rc waist=$waist_rc"
  if [ "$gnu_rc" = 0 ]; then
    _ok "$desc: both report a mountpoint (exit 0)"
  elif [ "$gnu_rc" = 32 ]; then
    _ok "$desc: both report not-a-mountpoint (exit 32)"
  else
    [ -s "$TMPBASE/waist.err" ] || _fail "$desc: waist did not write to stderr on a stat failure (rc=$waist_rc)"
    _ok "$desc: both report a stat failure (exit $gnu_rc)"
  fi
}

_case "the real root mountpoint" "/"

mkdir -p "$TMPBASE/plain_dir"
_case "a plain non-mount directory" "$TMPBASE/plain_dir"

_case "a missing path" "$TMPBASE/does-not-exist"

touch "$TMPBASE/plain_file"
_case "a regular file" "$TMPBASE/plain_file"

ln -s / "$TMPBASE/symlink_to_root"
_case "a symlink to a real mountpoint (dereferenced, matching mountpoint's default)" "$TMPBASE/symlink_to_root"

echo "PASS: _cbox_ismount oracle against util-linux mountpoint -q"
