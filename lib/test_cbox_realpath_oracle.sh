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

if ! command -v realpath >/dev/null 2>&1; then
  echo "SKIP: GNU realpath not found on PATH - the oracle needs it as counterparty, this run proves nothing"
  echo "PASS: _cbox_realpath oracle skipped (no GNU realpath)"
  exit 0
fi

if ! realpath --version 2>/dev/null | grep -q "GNU coreutils"; then
  echo "SKIP: realpath on PATH is not GNU coreutils - the oracle needs GNU semantics as counterparty, this run proves nothing"
  echo "PASS: _cbox_realpath oracle skipped (non-GNU realpath)"
  exit 0
fi

. "$INSTALL_DIR/lib/portable.sh"

_case() {
  local form="$1" waist_fn="$2" desc="$3" path="$4"
  local gnu_out gnu_rc waist_out waist_rc
  set +e
  if [ "$form" = bare ]; then
    gnu_out="$(realpath "$path" 2>"$TMPBASE/gnu.err")"
  else
    gnu_out="$(realpath -m "$path" 2>"$TMPBASE/gnu.err")"
  fi
  gnu_rc=$?
  waist_out="$("$waist_fn" "$path" 2>"$TMPBASE/waist.err")"
  waist_rc=$?
  set -e

  [ "$gnu_out" = "$waist_out" ] || _fail "$form/$desc: stdout mismatch: gnu=[$gnu_out] waist=[$waist_out]"
  [ "$gnu_rc" = "$waist_rc" ] || _fail "$form/$desc: exit code mismatch: gnu=$gnu_rc waist=$waist_rc"
  if [ "$gnu_rc" != 0 ]; then
    [ -z "$waist_out" ] || _fail "$form/$desc: waist wrote to stdout on failure: $waist_out"
    [ -s "$TMPBASE/waist.err" ] || _fail "$form/$desc: waist did not write to stderr on failure"
  fi
  _ok "$form/$desc: stdout=[$gnu_out] rc=$gnu_rc matches GNU realpath"
}

mkdir -p "$TMPBASE/root/sub/deep"
touch "$TMPBASE/root/sub/deep/file"

ln -s deep "$TMPBASE/root/sub/link_to_deep"
ln -s "$TMPBASE/root/sub/deep/file" "$TMPBASE/root/target_file_link"

ln -s loop_b "$TMPBASE/root/loop_a"
ln -s loop_a "$TMPBASE/root/loop_b"
ln -s /no/such/target "$TMPBASE/root/dangling_leaf"
ln -s /no/such/dir/leaf "$TMPBASE/root/dangling_parent"
ln -s sub/deep/file "$TMPBASE/root/link_to_file"

mkdir -p "$TMPBASE/root/has space dir"
touch "$TMPBASE/root/has space dir/has space file"

mkdir -p "$TMPBASE/nonroot_cwd"

for FORM in bare m; do
  if [ "$FORM" = bare ]; then
    WAIST_FN=_cbox_realpath
  else
    WAIST_FN=_cbox_realpath_m
  fi

  _case "$FORM" "$WAIST_FN" "existing file" "$TMPBASE/root/sub/deep/file"
  _case "$FORM" "$WAIST_FN" "existing dir" "$TMPBASE/root/sub"
  _case "$FORM" "$WAIST_FN" "missing final component" "$TMPBASE/root/sub/deep/does-not-exist"
  _case "$FORM" "$WAIST_FN" "missing intermediate directory" "$TMPBASE/root/no-such-dir/file"
  _case "$FORM" "$WAIST_FN" "symlink chain resolves" "$TMPBASE/root/sub/link_to_deep/file"
  _case "$FORM" "$WAIST_FN" "symlink chain to file resolves" "$TMPBASE/root/target_file_link"
  _case "$FORM" "$WAIST_FN" "symlink loop (ELOOP)" "$TMPBASE/root/loop_a"
  _case "$FORM" "$WAIST_FN" "symlink loop as intermediate" "$TMPBASE/root/loop_a/x"
  _case "$FORM" "$WAIST_FN" "trailing slash on existing dir" "$TMPBASE/root/sub/"
  _case "$FORM" "$WAIST_FN" "trailing slash on missing path" "$TMPBASE/root/sub/deep/does-not-exist/"
  _case "$FORM" "$WAIST_FN" "dangling symlink as leaf" "$TMPBASE/root/dangling_leaf"
  _case "$FORM" "$WAIST_FN" "symlink whose target parent is missing" "$TMPBASE/root/dangling_parent"
  _case "$FORM" "$WAIST_FN" "trailing slash on existing regular file" "$TMPBASE/root/sub/deep/file/"
  _case "$FORM" "$WAIST_FN" "trailing slash on symlink to regular file" "$TMPBASE/root/link_to_file/"
  _case "$FORM" "$WAIST_FN" "path with spaces" "$TMPBASE/root/has space dir/has space file"
  _case "$FORM" "$WAIST_FN" "path with spaces, missing" "$TMPBASE/root/has space dir/not there"
  _case "$FORM" "$WAIST_FN" ".. traversal past root" "/../../../etc"
  _case "$FORM" "$WAIST_FN" "empty string" ""

  (
    cd "$TMPBASE/nonroot_cwd"
    _case "$FORM" "$WAIST_FN" "relative path from non-root cwd" "../root/sub/deep/file"
  )
done

echo "PASS: _cbox_realpath / _cbox_realpath_m oracle against GNU realpath"
