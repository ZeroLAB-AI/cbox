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
  echo "PASS: $1"
}

_validator_body() {
  local file="$1" fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) \\{" { grab=1; next }
    grab && /^\}/ { exit }
    grab { print }
  ' "$file"
}

test_run_local_sequence_materializes_session_entry() {
  local eff="$TMPBASE/eff"
  mkdir -p "$eff"
  cp "$INSTALL_DIR/entrypoint.sh" "$eff/entrypoint.sh"
  cp "$INSTALL_DIR/install-bins.sh" "$eff/install-bins.sh"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export HOME="$TMPBASE/home"
    mkdir -p "$HOME"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_session_entry_into "$eff"
    gen_image_inputs "$eff" "sha256:deadbeef"
  )
  [ -f "$eff/cbox-session-entry.py" ] \
    || _fail "gen_session_entry_into did not materialize $eff/cbox-session-entry.py"
  [ -x "$eff/cbox-session-entry.py" ] \
    || _fail "$eff/cbox-session-entry.py is not executable (expected mode 0755)"
  [ -f "$eff/image.inputs" ] \
    || _fail "gen_image_inputs did not write $eff/image.inputs"

  local want got
  want="$(sha256sum "$INSTALL_DIR/etc/container/cbox-session-entry.py" | awk '{print $1}')"
  got="$(grep '^copy.cbox-session-entry.py=' "$eff/image.inputs" | cut -d= -f2)"
  [ -n "$got" ] \
    || _fail "image.inputs carries no copy.cbox-session-entry.py key:
$(cat "$eff/image.inputs")"
  [ "$got" = "$want" ] \
    || _fail "image.inputs copy.cbox-session-entry.py digest ($got) does not match sha256 of etc/container/cbox-session-entry.py ($want)"

  cmp -s "$eff/cbox-session-entry.py" "$INSTALL_DIR/etc/container/cbox-session-entry.py" \
    || _fail "materialized cbox-session-entry.py content differs from the source under etc/container/"
  _ok "run_local's cp+gen_session_entry_into+gen_image_inputs sequence materializes cbox-session-entry.py and image.inputs carries a matching copy.cbox-session-entry.py digest"
}

test_regen_all_calls_session_entry_before_image_inputs() {
  local body="$TMPBASE/regen_all_body.sh"
  _validator_body "$INSTALL_DIR/templates/generators.sh" regen_all > "$body"
  [ -s "$body" ] || _fail "could not extract regen_all body from templates/generators.sh"
  local l_session l_inputs
  l_session="$(grep -n 'gen_session_entry_into' "$body" | head -n1 | cut -d: -f1)"
  l_inputs="$(grep -n 'gen_image_inputs' "$body" | head -n1 | cut -d: -f1)"
  [ -n "$l_session" ] || _fail "regen_all body does not call gen_session_entry_into"
  [ -n "$l_inputs" ] || _fail "regen_all body does not call gen_image_inputs"
  [ "$l_session" -lt "$l_inputs" ] \
    || _fail "regen_all must call gen_session_entry_into before gen_image_inputs (session=$l_session inputs=$l_inputs) - image.inputs hashes cbox-session-entry.py, so it must exist first"
  _ok "regen_all calls gen_session_entry_into before gen_image_inputs"
}

test_run_local_sequence_materializes_session_entry
test_regen_all_calls_session_entry_before_image_inputs
echo "PASS: all image inputs materialization checks"
