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

HARNESS="$TMPBASE/decision_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  awk '/^_cbox_down_guard_decision\(\) \{/,/^}$/' "$INSTALL_DIR/cbox"
  echo '_cbox_down_guard_decision "$1" "$2" "$3"'
} > "$HARNESS"
chmod +x "$HARNESS"

grep -q '_cbox_down_guard_decision' "$HARNESS" || _fail "could not extract _cbox_down_guard_decision from cbox"

d() {
  bash "$HARNESS" "$1" "$2" "$3"
}

out="$(d 1 "3" 0)"
[ "$out" = refuse ] || _fail "live-lock (n=3) + no-force expected refuse, got $out"
_ok "live-lock + no-force refuses"

out="$(d 0 "0" 0)"
[ "$out" = refuse ] || _fail "unlocked (session live, another holder) + no-force expected refuse, got $out"
_ok "lock not acquired (live session held elsewhere) + no-force refuses"

out="$(d 1 "3" 1)"
[ "$out" = proceed ] || _fail "live-lock + force expected proceed, got $out"
_ok "live-lock + force proceeds"

out="$(d 0 "0" 1)"
[ "$out" = proceed ] || _fail "unlocked + force expected proceed, got $out"
_ok "unlocked + force proceeds"

out="$(d 1 "unknown" 0)"
[ "$out" = refuse ] || _fail "free-lock + n=unknown + no-force expected refuse, got $out"
_ok "free-lock + n=unknown + no-force refuses (fail closed)"

out="$(d 1 "" 0)"
[ "$out" = refuse ] || _fail "free-lock + empty probe output + no-force expected refuse, got $out"
_ok "free-lock + empty probe output + no-force refuses (fail closed)"

out="$(d 1 "0" 0)"
[ "$out" = proceed ] || _fail "free-lock + n=0 + no-force expected proceed, got $out"
_ok "free-lock + n=0 + no-force proceeds"

out="$(d 1 "1" 0)"
[ "$out" = refuse ] || _fail "free-lock + n=1 + no-force expected refuse, got $out"
_ok "free-lock + n=1 (live process) + no-force refuses"

v_down_project="$INSTALL_DIR/cbox"
grep -q '^down_project() {' "$v_down_project" || _fail "down_project function not found in cbox"
grep -q 'flock -n -x 9' "$v_down_project" || _fail "down_project does not attempt an exclusive non-blocking flock"
awk '/^down_project\(\) \{/,/^}$/' "$v_down_project" | grep -q '_cbox_down_guard_decision' \
  || _fail "down_project does not call _cbox_down_guard_decision"
_ok "down_project wires the exclusive flock + shared decision helper"

awk '/^down_project\(\) \{/,/^}$/' "$v_down_project" | grep -q 'ps_rc' \
  || _fail "down_project does not track compose ps exit status separately from an empty cid"
awk '/^down\(\) \{/,/^}$/' "$v_down_project" | grep -q 'ps_rc' \
  || _fail "global down() does not track compose ps exit status separately from an empty cid"
_ok "down_project and down() distinguish a failed compose ps from a genuinely absent container (fail-closed on probe failure)"

grep -q '^shell_isolated() {' "$v_down_project" || _fail "shell_isolated function not found"
awk '/^shell_isolated\(\) \{/,/^}$/' "$v_down_project" | grep -q 'flock -s 8' \
  || _fail "shell_isolated does not take the shared session lock"
awk '/^shell_isolated\(\) \{/,/^}$/' "$v_down_project" | grep -q '_reap "\$eff"' \
  || _fail "shell_isolated does not reap after the shell exits"
awk '/^shell_isolated\(\) \{/,/^}$/' "$v_down_project" | grep -q '/entrypoint.sh bash' \
  || _fail "shell_isolated does not exec through /entrypoint.sh bash"
_ok "shell_isolated holds the shared session lock and reaps on exit"

grep -q '^logs_isolated() {' "$v_down_project" || _fail "logs_isolated function not found"
_ok "logs_isolated present"

awk '/^shell\(\) \{/,/^}$/' "$v_down_project" | grep -q 'flock -s 8' \
  || _fail "global shell() does not take the shared session lock"
_ok "global shell() holds the shared session lock (so _probe blind spots do not let down tear it down)"

awk '/^down\(\) \{/,/^}$/' "$v_down_project" | grep -q 'flock -n -x 9' \
  || _fail "global down() does not attempt the exclusive session lock"
_ok "global down() wires the exclusive flock, matching down_project's guard"

echo "PASS: all lifecycle guard checks"
