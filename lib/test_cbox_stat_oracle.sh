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

if ! command -v stat >/dev/null 2>&1; then
  echo "SKIP: GNU stat not found on PATH - the oracle needs it as counterparty, this run proves nothing"
  echo "PASS: _cbox_stat_uid / _cbox_stat_mtime oracle skipped (no GNU stat)"
  exit 0
fi

if ! stat --version 2>/dev/null | grep -q "GNU coreutils"; then
  echo "SKIP: stat on PATH is not GNU coreutils - the oracle needs GNU semantics as counterparty, this run proves nothing"
  echo "PASS: _cbox_stat_uid / _cbox_stat_mtime oracle skipped (non-GNU stat)"
  exit 0
fi

. "$INSTALL_DIR/lib/portable.sh"

_case_uid() {
  local desc="$1" path="$2"
  local gnu_out gnu_rc waist_out waist_rc
  set +e
  gnu_out="$(stat -c '%u' -- "$path" 2>"$TMPBASE/gnu.err")"
  gnu_rc=$?
  waist_out="$(_cbox_stat_uid -- "$path" 2>"$TMPBASE/waist.err")"
  waist_rc=$?
  set -e
  [ "$gnu_rc" = "$waist_rc" ] || _fail "uid/$desc: exit code mismatch: gnu=$gnu_rc waist=$waist_rc"
  [ "$gnu_out" = "$waist_out" ] || _fail "uid/$desc: stdout mismatch: gnu=[$gnu_out] waist=[$waist_out]"
  if [ "$gnu_rc" != 0 ]; then
    [ -z "$waist_out" ] || _fail "uid/$desc: waist wrote to stdout on failure: $waist_out"
    [ -s "$TMPBASE/waist.err" ] || _fail "uid/$desc: waist did not write to stderr on failure"
  fi
  _ok "uid/$desc: stdout=[$gnu_out] rc=$gnu_rc matches GNU stat -c %u"
}

_case_mtime() {
  local desc="$1" path="$2"
  local gnu_out gnu_rc waist_out waist_rc
  set +e
  gnu_out="$(stat -c '%Y' -- "$path" 2>"$TMPBASE/gnu.err")"
  gnu_rc=$?
  waist_out="$(_cbox_stat_mtime -- "$path" 2>"$TMPBASE/waist.err")"
  waist_rc=$?
  set -e
  [ "$gnu_rc" = "$waist_rc" ] || _fail "mtime/$desc: exit code mismatch: gnu=$gnu_rc waist=$waist_rc"
  [ "$gnu_out" = "$waist_out" ] || _fail "mtime/$desc: stdout mismatch: gnu=[$gnu_out] waist=[$waist_out]"
  if [ "$gnu_rc" != 0 ]; then
    [ -z "$waist_out" ] || _fail "mtime/$desc: waist wrote to stdout on failure: $waist_out"
    [ -s "$TMPBASE/waist.err" ] || _fail "mtime/$desc: waist did not write to stderr on failure"
  fi
  _ok "mtime/$desc: stdout=[$gnu_out] rc=$gnu_rc matches GNU stat -c %Y"
}

mkdir -p "$TMPBASE/dir1"
touch "$TMPBASE/file1"
sleep 1.1
ln -s "$TMPBASE/file1" "$TMPBASE/link_to_file"
ln -s /no/such/target-cbox-oracle "$TMPBASE/dangling_link"

_case_uid "regular file" "$TMPBASE/file1"
_case_uid "directory" "$TMPBASE/dir1"
_case_uid "missing path" "$TMPBASE/does-not-exist"
_case_uid "symlink to file (lstat, not the target)" "$TMPBASE/link_to_file"
_case_uid "dangling symlink" "$TMPBASE/dangling_link"

_case_mtime "regular file" "$TMPBASE/file1"
_case_mtime "directory" "$TMPBASE/dir1"
_case_mtime "missing path" "$TMPBASE/does-not-exist"
_case_mtime "symlink to file (lstat, not the target)" "$TMPBASE/link_to_file"
_case_mtime "dangling symlink" "$TMPBASE/dangling_link"

LINK_MTIME="$(stat -c '%Y' -- "$TMPBASE/link_to_file")"
FILE_MTIME="$(stat -c '%Y' -- "$TMPBASE/file1")"
[ "$LINK_MTIME" != "$FILE_MTIME" ] || _fail "test setup: link and target mtimes coincide, the lstat-vs-stat distinction is not actually exercised"
_ok "test setup sanity: symlink mtime ($LINK_MTIME) differs from target mtime ($FILE_MTIME), lstat distinction is real"

echo "PASS: _cbox_stat_uid / _cbox_stat_mtime oracle against GNU stat"
