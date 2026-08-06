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

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "SKIP: sha256sum not found on PATH - the oracle needs the GNU tool as counterparty, this run proves nothing"
  echo "PASS: sha256sum oracle skipped (no GNU tool)"
  exit 0
fi

. "$INSTALL_DIR/lib/portable.sh"

_gnu_digest() {
  sha256sum "$1" | awk '{print $1}'
}

_gnu_digest_stdin() {
  sha256sum | awk '{print $1}'
}

EMPTY_FILE="$TMPBASE/empty"
: > "$EMPTY_FILE"

MULTILINE_FILE="$TMPBASE/multiline.txt"
printf 'line one\nline two\nline three with unicode caf\xc3\xa9\n' > "$MULTILINE_FILE"

BINARY_FILE="$TMPBASE/binary.bin"
python3 -c "
import sys
data = bytes(range(256)) * 4 + b'\\x00\\x00\\x00' + bytes([0, 1, 2, 0, 255, 0])
sys.stdout.buffer.write(data)
" > "$BINARY_FILE"

LARGE_FILE="$TMPBASE/large.bin"
python3 -c "
import os
with open('$LARGE_FILE', 'wb') as fh:
    chunk = os.urandom(1024 * 1024)
    for _ in range(20):
        fh.write(chunk)
"

for label in EMPTY_FILE MULTILINE_FILE BINARY_FILE LARGE_FILE; do
  path="${!label}"
  gnu="$(_gnu_digest "$path")"
  waist="$(_cbox_sha256 "$path")"
  [ "$gnu" = "$waist" ] || _fail "$label: file-argument form digest mismatch: gnu=$gnu waist=$waist"
  _ok "$label: file-argument form digest matches sha256sum ($gnu)"

  gnu_stdin="$(_gnu_digest_stdin < "$path")"
  waist_stdin="$(_cbox_sha256 < "$path")"
  [ "$gnu_stdin" = "$waist_stdin" ] || _fail "$label: stdin form digest mismatch: gnu=$gnu_stdin waist=$waist_stdin"
  _ok "$label: stdin form digest matches sha256sum ($gnu_stdin)"

  [ "$gnu" = "$gnu_stdin" ] || _fail "$label: internal inconsistency - GNU file form and stdin form disagree"
done

MISSING="$TMPBASE/does-not-exist"

set +e
GNU_OUT="$(_gnu_digest "$MISSING" 2>"$TMPBASE/gnu.err")"
GNU_RC=$?
set -e
[ "$GNU_RC" -ne 0 ] || _fail "test setup: sha256sum unexpectedly succeeded on a missing file"
[ -z "$GNU_OUT" ] || _fail "test setup: sha256sum wrote to stdout on a missing file"
[ -s "$TMPBASE/gnu.err" ] || _fail "test setup: sha256sum did not write to stderr on a missing file"
_ok "oracle sanity: sha256sum on a missing file exits nonzero, empty stdout, non-empty stderr"

set +e
WAIST_OUT="$(_cbox_sha256 "$MISSING" 2>"$TMPBASE/waist.err")"
WAIST_RC=$?
set -e
[ "$WAIST_RC" -ne 0 ] || _fail "_cbox_sha256 unexpectedly succeeded on a missing file (rc=$WAIST_RC)"
[ -z "$WAIST_OUT" ] || _fail "_cbox_sha256 wrote to stdout on a missing file: $WAIST_OUT"
[ -s "$TMPBASE/waist.err" ] || _fail "_cbox_sha256 did not write to stderr on a missing file"
_ok "matching failure behavior: _cbox_sha256 on a missing file exits nonzero ($WAIST_RC), empty stdout, non-empty stderr"

echo "PASS: _cbox_sha256 oracle against sha256sum"
