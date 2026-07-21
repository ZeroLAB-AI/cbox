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

SRC="$INSTALL_DIR/lib/cbox-session.sh"
[ -f "$SRC" ] || _fail "cbox-session.sh not found at $SRC"

HARNESS="$TMPBASE/decision_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  awk '/^_cbox_session_lease_decision\(\) \{/,/^}$/' "$SRC"
  echo '_cbox_session_lease_decision "$1" "$2" "$3" "$4"'
} > "$HARNESS"
chmod +x "$HARNESS"

grep -q '_cbox_session_lease_decision' "$HARNESS" || _fail "could not extract _cbox_session_lease_decision from cbox-session.sh"

d() {
  bash "$HARNESS" "$1" "$2" "$3" "$4"
}

out="$(d '' 0 claude '')"
[ "$out" = "accept:fresh" ] || _fail "empty state (never opened) expected accept:fresh, got $out"
_ok "fresh session (empty state) accepts"

out="$(d idle 0 claude '')"
[ "$out" = "accept:fresh" ] || _fail "idle state expected accept:fresh, got $out"
_ok "idle session accepts"

out="$(d open 1 claude codex)"
[ "$out" = "refuse:live:codex" ] || _fail "open+live activeMain expected refuse:live:codex, got $out"
_ok "open session with a live activeMain refuses and names the live engine"

out="$(d open 0 claude codex)"
[ "$out" = "accept:reclaim-stale" ] || _fail "open+dead-pid expected accept:reclaim-stale, got $out"
_ok "open session with a stale (dead-pid) activeMain reclaims"

out="$(d closed 0 claude '')"
[ "$out" = "refuse:closed" ] || _fail "closed session expected refuse:closed, got $out"
_ok "closed session refuses a new leg"

out="$(d bogus-state 0 claude '')"
case "$out" in refuse:*) ;; *) _fail "unknown state expected a refuse:* decision (fail closed), got $out" ;; esac
_ok "unknown/unexpected state fails closed (refuse)"

WRAPPER="$INSTALL_DIR/cbox"
[ -f "$WRAPPER" ] || _fail "cbox script not found for wiring check"
grep -q '^_cbox_session_run_leg() {' "$SRC" || _fail "_cbox_session_run_leg not found in cbox-session.sh"
grep -q '_cbox_session_lease_decision' "$SRC" || _fail "_cbox_session_run_leg does not reference the lease decision helper anywhere in the file"
awk '/^_cbox_session_run_leg\(\) \{/,/^}$/' "$SRC" | grep -q '_cbox_session_lease_decision' \
  || _fail "_cbox_session_run_leg does not call _cbox_session_lease_decision"
_ok "_cbox_session_run_leg wires the pure lease-decision helper"

awk '/^_cbox_session_run_leg\(\) \{/,/^}$/' "$SRC" | grep -q '_cbox_session_lock_acquire' \
  || _fail "_cbox_session_run_leg does not acquire the runtime session lock"
_ok "_cbox_session_run_leg acquires the runtime lock before deciding"

awk '/^_cbox_session_run_leg\(\) \{/,/^}$/' "$SRC" | grep -q '_run_isolated "$engine"' \
  || _fail "_cbox_session_run_leg does not route engine legs through _run_isolated (single spawn path)"
_ok "_cbox_session_run_leg routes every engine through _run_isolated / _session_run"

echo "PASS: all session lease checks"
