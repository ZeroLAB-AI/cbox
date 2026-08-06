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

if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP: util-linux flock not found on PATH - the oracle needs it as counterparty, this run proves nothing"
  echo "PASS: _cbox_flock oracle skipped (no util-linux flock)"
  exit 0
fi

. "$INSTALL_DIR/lib/portable.sh"

_wait_for_line() {
  local file="$1" line="$2" tries=0
  while [ "$tries" -lt 500 ]; do
    if [ -f "$file" ] && grep -qx "$line" "$file" 2>/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.01
  done
  return 1
}

echo "--- direction 1: waist exclusive blocks util-linux flock -n ---"
LOCKFILE_A1="$TMPBASE/a1.lock"
: > "$LOCKFILE_A1"
LOG_A1="$TMPBASE/a1.log"
(
  exec 9> "$LOCKFILE_A1"
  _cbox_flock -x 9 || exit 1
  echo HELD >> "$LOG_A1"
  while [ ! -e "$TMPBASE/a1.release" ]; do sleep 0.01; done
) &
A1_PID=$!
_wait_for_line "$LOG_A1" HELD || _fail "a1: waist holder never signaled HELD"
if flock -n -x "$LOCKFILE_A1" -c true 2>/dev/null; then
  _fail "a1: util-linux flock -n unexpectedly acquired a file held by the waist"
fi
_ok "a1: waist exclusive lock blocks util-linux flock -n on the same file"
: > "$TMPBASE/a1.release"
wait "$A1_PID"

echo "--- direction 2: util-linux exclusive blocks the waist's -n ---"
LOCKFILE_A2="$TMPBASE/a2.lock"
: > "$LOCKFILE_A2"
LOG_A2="$TMPBASE/a2.log"
(
  flock -x "$LOCKFILE_A2" -c "echo HELD >> '$LOG_A2'; while [ ! -e '$TMPBASE/a2.release' ]; do sleep 0.01; done"
) &
A2_PID=$!
_wait_for_line "$LOG_A2" HELD || _fail "a2: util-linux holder never signaled HELD"
(
  exec 8> "$LOCKFILE_A2"
  if _cbox_flock -n -x 8; then
    _fail "a2: waist -n unexpectedly acquired a file held by util-linux flock"
  fi
  exec 8>&-
)
_ok "a2: util-linux exclusive lock blocks the waist's -n on the same file"
: > "$TMPBASE/a2.release"
wait "$A2_PID"

echo "--- central claim: exited python child's lock persists on the bash parent fd ---"
LOCKFILE_B="$TMPBASE/b.lock"
: > "$LOCKFILE_B"
exec 9> "$LOCKFILE_B"
_cbox_flock -x 9 || _fail "b: waist failed to acquire the initial lock"
if flock -n -x "$LOCKFILE_B" -c true 2>/dev/null; then
  exec 9>&-
  _fail "b: util-linux flock -n unexpectedly acquired right after the waist's python child exited (lock did not persist on the parent fd)"
fi
_ok "b: lock placed by the waist's exited python child persists on the bash parent's fd (util-linux -n still blocked)"
(
  exec 8> "$LOCKFILE_B"
  if _cbox_flock -n -x 8 2>/dev/null; then
    _fail "b: a second waist contender unexpectedly acquired while the parent fd still holds the lock"
  fi
)
_ok "b: a python contender also blocks against the persisted lock"
exec 9>&-
B_RELEASED=0
B_TRIES=0
while [ "$B_TRIES" -lt 500 ]; do
  if flock -n -x "$LOCKFILE_B" -c true 2>/dev/null; then
    B_RELEASED=1
    break
  fi
  B_TRIES=$((B_TRIES + 1))
  sleep 0.01
done
[ "$B_RELEASED" -eq 1 ] || _fail "b: lock did not release after the holding fd was closed"
_ok "b: lock releases once the bash parent's fd is closed"

echo "--- shared locks coexist, block exclusive ---"
LOCKFILE_C="$TMPBASE/c.lock"
: > "$LOCKFILE_C"
LOG_C1="$TMPBASE/c1.log"
LOG_C2="$TMPBASE/c2.log"
(
  exec 9> "$LOCKFILE_C"
  _cbox_flock -s 9 || exit 1
  echo HELD >> "$LOG_C1"
  while [ ! -e "$TMPBASE/c.release" ]; do sleep 0.01; done
) &
C1_PID=$!
_wait_for_line "$LOG_C1" HELD || _fail "c: first shared holder never signaled HELD"
(
  exec 8> "$LOCKFILE_C"
  _cbox_flock -s -n 8 || exit 1
  echo HELD >> "$LOG_C2"
  exec 8>&-
) &
C2_PID=$!
wait "$C2_PID"
_wait_for_line "$LOG_C2" HELD || _fail "c: second shared contender failed to coexist with the first"
_ok "c: two shared (-s) waist locks coexist on the same file"
if flock -n -x "$LOCKFILE_C" -c true 2>/dev/null; then
  : > "$TMPBASE/c.release"
  wait "$C1_PID"
  _fail "c: util-linux -x unexpectedly acquired while a shared waist lock was held"
fi
_ok "c: an exclusive util-linux flock -n is blocked while the waist holds a shared lock"
: > "$TMPBASE/c.release"
wait "$C1_PID"

echo "--- -n contention exit code ---"
LOCKFILE_D="$TMPBASE/d.lock"
: > "$LOCKFILE_D"
LOG_D="$TMPBASE/d.log"
(
  flock -x "$LOCKFILE_D" -c "echo HELD >> '$LOG_D'; while [ ! -e '$TMPBASE/d.release' ]; do sleep 0.01; done"
) &
D_PID=$!
_wait_for_line "$LOG_D" HELD || _fail "d: util-linux holder never signaled HELD"
UL_RC=0
flock -n -x "$LOCKFILE_D" -c true 2>/dev/null || UL_RC=$?
WAIST_RC=0
(
  exec 8> "$LOCKFILE_D"
  _cbox_flock -n -x 8
) || WAIST_RC=$?
[ "$UL_RC" -ne 0 ] || _fail "d: test setup - util-linux -n unexpectedly succeeded"
[ "$WAIST_RC" -eq "$UL_RC" ] || _fail "d: -n contention exit code mismatch: util-linux=$UL_RC waist=$WAIST_RC"
_ok "d: -n contention exit code matches util-linux ($UL_RC), returned without waiting for release"
: > "$TMPBASE/d.release"
wait "$D_PID"

echo "--- -w 1 timeout exit code and elapsed time ---"
LOCKFILE_E="$TMPBASE/e.lock"
: > "$LOCKFILE_E"
LOG_E="$TMPBASE/e.log"
(
  flock -x "$LOCKFILE_E" -c "echo HELD >> '$LOG_E'; while [ ! -e '$TMPBASE/e.release' ]; do sleep 0.01; done"
) &
E_PID=$!
_wait_for_line "$LOG_E" HELD || _fail "e: util-linux holder never signaled HELD"

UL_START=$(date +%s.%N)
UL_RC=0
flock -w 1 -x "$LOCKFILE_E" -c true 2>/dev/null || UL_RC=$?
UL_END=$(date +%s.%N)
UL_ELAPSED=$(python3 -c "print($UL_END - $UL_START)")

WAIST_START=$(date +%s.%N)
WAIST_RC=0
(
  exec 8> "$LOCKFILE_E"
  _cbox_flock -w 1 -x 8
) || WAIST_RC=$?
WAIST_END=$(date +%s.%N)
WAIST_ELAPSED=$(python3 -c "print($WAIST_END - $WAIST_START)")

[ "$UL_RC" -ne 0 ] || _fail "e: test setup - util-linux -w 1 unexpectedly succeeded against a held lock"
[ "$WAIST_RC" -eq "$UL_RC" ] || _fail "e: -w timeout exit code mismatch: util-linux=$UL_RC waist=$WAIST_RC"
_ok "e: -w 1 timeout exit code matches util-linux ($UL_RC)"

ELAPSED_OK="$(python3 -c "
elapsed = $WAIST_ELAPSED
print('yes' if 0.8 <= elapsed <= 3.0 else 'no')
")"
[ "$ELAPSED_OK" = yes ] || _fail "e: waist -w 1 timeout took ${WAIST_ELAPSED}s, expected roughly 1s"
_ok "e: waist -w 1 timeout elapsed ~1s (util-linux=${UL_ELAPSED}s waist=${WAIST_ELAPSED}s)"

echo "--- -n wins over -w: combined flags return immediately on contention ---"
UL_NW_START=$(date +%s.%N)
UL_NW_RC=0
flock -n -w 5 -x "$LOCKFILE_E" -c true 2>/dev/null || UL_NW_RC=$?
UL_NW_END=$(date +%s.%N)

WAIST_NW_START=$(date +%s.%N)
WAIST_NW_RC=0
(
  exec 8> "$LOCKFILE_E"
  _cbox_flock -n -w 5 -x 8
) || WAIST_NW_RC=$?
WAIST_NW_END=$(date +%s.%N)

[ "$UL_NW_RC" -ne 0 ] || _fail "f: test setup - util-linux -n -w 5 unexpectedly succeeded against a held lock"
[ "$WAIST_NW_RC" -eq "$UL_NW_RC" ] || _fail "f: -n -w exit code mismatch: util-linux=$UL_NW_RC waist=$WAIST_NW_RC"
NW_FAST="$(python3 -c "
ul = $UL_NW_END - $UL_NW_START
waist = $WAIST_NW_END - $WAIST_NW_START
print('yes' if ul < 0.5 and waist < 0.5 else 'no ul=%s waist=%s' % (ul, waist))
")"
[ "$NW_FAST" = yes ] || _fail "f: -n -w must return immediately on contention, deadline ignored: $NW_FAST"
_ok "f: -n -w together return immediately with the util-linux exit code ($UL_NW_RC) - -n wins, deadline ignored"
: > "$TMPBASE/e.release"
wait "$E_PID"

echo "PASS: _cbox_flock oracle against util-linux flock (both directions, fd persistence, shared/exclusive, -n, -w, -n-wins-over--w)"
