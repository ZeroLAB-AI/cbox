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

if ! command -v timeout >/dev/null 2>&1; then
  echo "SKIP: GNU timeout not found on PATH - the oracle needs it as counterparty, this run proves nothing"
  echo "PASS: _cbox_timeout oracle skipped (no GNU timeout)"
  exit 0
fi

if ! timeout --version 2>/dev/null | grep -q "GNU coreutils"; then
  echo "SKIP: timeout on PATH is not GNU coreutils - the oracle needs GNU semantics as counterparty, this run proves nothing"
  echo "PASS: _cbox_timeout oracle skipped (non-GNU timeout)"
  exit 0
fi

. "$INSTALL_DIR/lib/portable.sh"

_case_exit() {
  local desc="$1"; shift
  local gnu_rc waist_rc gnu_out waist_out
  set +e
  gnu_out="$(timeout "$@" 2>"$TMPBASE/gnu.err")"
  gnu_rc=$?
  waist_out="$(_cbox_timeout "$@" 2>"$TMPBASE/waist.err")"
  waist_rc=$?
  set -e
  [ "$gnu_rc" = "$waist_rc" ] || _fail "$desc: exit code mismatch: gnu=$gnu_rc waist=$waist_rc"
  [ "$gnu_out" = "$waist_out" ] || _fail "$desc: stdout mismatch: gnu=[$gnu_out] waist=[$waist_out]"
  _ok "$desc: exit=$gnu_rc stdout=[$gnu_out] matches GNU timeout"
}

_case_exit "child exits 0" 2 true
_case_exit "child exits nonzero" 2 sh -c 'exit 7'
_case_exit "child writes stdout" 2 sh -c 'printf out'
_case_exit "child not found" 1 nonexistent-command-cbox-oracle-xyz

printf '#!/bin/sh\nexit 0\n' > "$TMPBASE/not_executable.sh"
chmod 644 "$TMPBASE/not_executable.sh"
_case_exit "child found but not executable (126, distinct from 127)" 1 "$TMPBASE/not_executable.sh"

echo "--- timeout fires: exit 124, output before the deadline is preserved ---"
GNU_START=$(date +%s.%N)
GNU_OUT="$(timeout 1 sh -c 'printf partial; sleep 5' 2>/dev/null)" || GNU_RC=$?
GNU_END=$(date +%s.%N)
[ "$GNU_RC" -eq 124 ] || _fail "test setup: gnu timeout did not exit 124 (got $GNU_RC)"
[ "$GNU_OUT" = partial ] || _fail "test setup: gnu timeout dropped partial stdout: got [$GNU_OUT]"

WAIST_START=$(date +%s.%N)
WAIST_OUT="$(_cbox_timeout 1 sh -c 'printf partial; sleep 5' 2>/dev/null)" || WAIST_RC=$?
WAIST_END=$(date +%s.%N)
[ "$WAIST_RC" -eq 124 ] || _fail "waist timeout did not exit 124 (got $WAIST_RC)"
[ "$WAIST_OUT" = partial ] || _fail "waist timeout dropped partial stdout: got [$WAIST_OUT]"
_ok "timeout fires: both exit 124 with partial stdout preserved (gnu=[$GNU_OUT] waist=[$WAIST_OUT])"

GNU_ELAPSED="$(python3 -c "print($GNU_END - $GNU_START)")"
WAIST_ELAPSED="$(python3 -c "print($WAIST_END - $WAIST_START)")"
WAIST_FAST="$(python3 -c "
e = $WAIST_ELAPSED
print('yes' if 0.8 <= e <= 3.0 else 'no')
")"
[ "$WAIST_FAST" = yes ] || _fail "waist timeout took ${WAIST_ELAPSED}s, expected roughly 1s (gnu took ${GNU_ELAPSED}s)"
_ok "waist timeout fires at ~1s (gnu=${GNU_ELAPSED}s waist=${WAIST_ELAPSED}s)"

echo "--- signal-terminated child: exit code is 128+signal, matching GNU ---"
GNU_RC=0
timeout 2 sh -c 'kill -9 $$' >/dev/null 2>&1 || GNU_RC=$?
WAIST_RC=0
_cbox_timeout 2 sh -c 'kill -9 $$' >/dev/null 2>&1 || WAIST_RC=$?
[ "$GNU_RC" -eq 137 ] || _fail "test setup: gnu timeout on self-SIGKILL child did not report 137 (got $GNU_RC)"
[ "$WAIST_RC" -eq "$GNU_RC" ] || _fail "signal-terminated child exit code mismatch: gnu=$GNU_RC waist=$WAIST_RC"
_ok "signal-terminated child: both report $GNU_RC (128+SIGKILL)"

echo "--- child that ignores TERM: waist does not orphan it past its own return ---"
IGNORE_SCRIPT="$TMPBASE/ignore_term.sh"
cat > "$IGNORE_SCRIPT" <<'EOF'
#!/bin/sh
trap '' TERM
echo ready
sleep 20
EOF
chmod +x "$IGNORE_SCRIPT"

WAIST_RC=0
WAIST_OUT="$(_cbox_timeout 1 "$IGNORE_SCRIPT" 2>/dev/null)" || WAIST_RC=$?
[ "$WAIST_RC" -eq 124 ] || _fail "waist did not report 124 against a TERM-ignoring child (got $WAIST_RC)"
[ "$WAIST_OUT" = ready ] || _fail "waist dropped stdout emitted before the TERM-ignoring child was killed: got [$WAIST_OUT]"
sleep 0.5
if pgrep -f "$IGNORE_SCRIPT" >/dev/null 2>&1; then
  pkill -9 -f "$IGNORE_SCRIPT" >/dev/null 2>&1 || true
  _fail "waist orphaned a TERM-ignoring child past its own 124 return - it must escalate to SIGKILL"
fi
_ok "waist escalates to SIGKILL and does not orphan a TERM-ignoring child (GNU timeout itself does orphan it - this is a deliberate improvement, not a parity claim)"

echo "PASS: _cbox_timeout oracle against GNU timeout"
