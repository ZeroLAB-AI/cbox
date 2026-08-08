#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

PREFLIGHT="$INSTALL_DIR/lib/portable_preflight.sh"
[ -f "$PREFLIGHT" ] || _fail "lib/portable_preflight.sh not found"

bash -n "$PREFLIGHT" || _fail "portable_preflight.sh fails bash -n"
_ok "portable_preflight.sh is bash -n clean"

! grep -Eq '\bdeclare\s+(-\S+\s+)*-A\b' "$PREFLIGHT" || _fail "portable_preflight.sh contains declare -A (must be bash-3.2 safe)"
grep -Eq '\bmapfile\b' "$PREFLIGHT" && _fail "portable_preflight.sh contains mapfile (must be bash-3.2 safe)"
! grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^|,,?)' "$PREFLIGHT" || _fail "portable_preflight.sh contains a bash-4 case-conversion expansion (must be bash-3.2 safe)"
_ok "portable_preflight.sh source text carries no bash-4-only construct (declare -A / mapfile / \${var^})"

for f in "$INSTALL_DIR/cbox"; do
  name="$(basename "$f")"
  first_nonshebang_line="$(sed -n '2p' "$f")"
  case "$first_nonshebang_line" in
    *portable_preflight.sh*|"set -euo pipefail")
      ;;
    *)
      _fail "$name: line 2 is not the pre-flight source line or the shell strict-mode line: $first_nonshebang_line"
      ;;
  esac
  grep -q 'lib/portable_preflight.sh' "$f" || _fail "$name does not source lib/portable_preflight.sh"
  preflight_line="$(grep -n 'lib/portable_preflight.sh' "$f" | head -1 | cut -d: -f1)"
  sections_line="$(grep -n 'templates/sections.sh' "$f" | head -1 | cut -d: -f1 || true)"
  if [ -n "$sections_line" ]; then
    [ "$preflight_line" -lt "$sections_line" ] \
      || _fail "$name: templates/sections.sh is referenced (line $sections_line) before the pre-flight is sourced (line $preflight_line)"
  fi
  generators_line="$(grep -n 'templates/generators.sh' "$f" | head -1 | cut -d: -f1 || true)"
  if [ -n "$generators_line" ]; then
    [ "$preflight_line" -lt "$generators_line" ] \
      || _fail "$name: templates/generators.sh is referenced (line $generators_line) before the pre-flight is sourced (line $preflight_line, and generators.sh is not bash-3.2-clean today)"
  fi
  call_line="$(grep -n 'cbox_preflight_check' "$f" | head -1 | cut -d: -f1)"
  [ -n "$call_line" ] || _fail "$name does not call cbox_preflight_check"
  [ "$call_line" -gt "$preflight_line" ] || _fail "$name calls cbox_preflight_check before sourcing portable_preflight.sh"
  _ok "$name: pre-flight is sourced and invoked before sections.sh/generators.sh are referenced"
done

(
  . "$PREFLIGHT"
  cbox_preflight_check bash Linux yes yes
) || _fail "healthy Linux host (bash present, python3 yes, docker yes) must pass silently"
_ok "healthy Linux host passes the pre-flight with rc=0"

OUT="$(
  . "$PREFLIGHT"
  cbox_preflight_check bash Linux yes yes
  echo "no-output-expected"
)"
[ "$OUT" = "no-output-expected" ] \
  || _fail "healthy Linux host preflight printed something on stdout (must be silent): $OUT"
_ok "healthy Linux host preflight prints nothing on stdout"

DARWIN_ERR="$(
  . "$PREFLIGHT"
  cbox_preflight_check bash Darwin yes yes 2>&1 1>/dev/null
)" || _fail "darwin must warn and continue (rc=0) now that macOS support is experimental, not refuse"
case "$DARWIN_ERR" in
  *"macOS support is EXPERIMENTAL"*) ;;
  *) _fail "darwin warning missing the experimental text: $DARWIN_ERR" ;;
esac
_ok "darwin: experimental warning on stderr and continues with rc=0 (macOS is out-of-the-box compatible but unverified on real hardware)"

NOPY_ERR="$(
  . "$PREFLIGHT"
  cbox_preflight_check bash Linux no yes 2>&1 1>/dev/null
)" || _fail "missing python3 must warn and continue (rc=0), not refuse - usage and help work without it today"
case "$NOPY_ERR" in
  *"warning: python3"*"Command Line Tools"*) ;;
  *) _fail "missing-python3 warning missing the expected text: $NOPY_ERR" ;;
esac
_ok "missing python3: warns on stderr (naming the Command Line Tools stub trap) and continues with rc=0"

NODOCKER_ERR="$(
  . "$PREFLIGHT"
  cbox_preflight_check bash Linux yes no 2>&1 1>/dev/null
)" || _fail "missing docker must warn and continue (rc=0), not refuse - bare cbox usage and the hub render without docker today, a hard gate here is a behavior change"
case "$NODOCKER_ERR" in
  *"warning: docker"*) ;;
  *) _fail "missing-docker warning missing the expected text: $NODOCKER_ERR" ;;
esac
_ok "missing docker: warns on stderr and continues with rc=0 (usage/hub paths stay reachable on a dockerless host)"

OLDBASH_ERR="$(
  . "$PREFLIGHT"
  fakebash() { :; }
  _cbox_preflight_bash_version() { printf '3 1'; }
  cbox_preflight_check bash Linux yes yes 2>&1 1>/dev/null
)" && _fail "bash below the floor must fail (rc!=0)" || true
case "$OLDBASH_ERR" in
  *"bash 3.2 or newer is required (found 3.1)"*) ;;
  *) _fail "old-bash error message missing the expected floor text: $OLDBASH_ERR" ;;
esac
_ok "bash below the 3.2 floor: clear version error, not a declare crash further down (floor logic exercised on the current bash via the version-injection seam; real bash 3.2 execution is unverified here, see report)"

(
  . "$PREFLIGHT"
  for pair in "3 1:fail" "3 2:pass" "3 3:pass" "3 9:pass" "4 0:pass" "5 2:pass" "2 9:fail" "9 0:pass"; do
    ver="${pair%%:*}"
    expect="${pair##*:}"
    set -- $ver
    if _cbox_preflight_version_ge "$1" "$2" 3 2; then
      got=pass
    else
      got=fail
    fi
    [ "$got" = "$expect" ] || _fail "_cbox_preflight_version_ge($ver, floor 3.2) expected $expect got $got"
  done
)
_ok "_cbox_preflight_version_ge: floor boundary matrix (3.1/3.2/3.3/3.9/4.0/5.2/2.9/9.0) is correct on the running bash 5.x"

echo "PASS: portable_preflight checks"
