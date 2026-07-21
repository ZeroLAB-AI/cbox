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

command -v script >/dev/null 2>&1 || _fail "script(1) not found - required for the PTY harness"

FIXHOME="$TMPBASE/home-nontty"
mkdir -p "$FIXHOME"

BARE_RAW="$TMPBASE/bare.raw"
BOGUS_RAW="$TMPBASE/bogus.raw"
rc_bare=0
HOME="$FIXHOME" "$INSTALL_DIR/cbox" </dev/null > "$BARE_RAW" 2>&1 || rc_bare=$?
rc_bogus=0
HOME="$FIXHOME" "$INSTALL_DIR/cbox" bogus-subcommand </dev/null > "$BOGUS_RAW" 2>&1 || rc_bogus=$?
out_bare="$(cat "$BARE_RAW")"
out_bogus="$(cat "$BOGUS_RAW")"

[ "$rc_bare" = "$rc_bogus" ] || _fail "exit code differs: bare=$rc_bare bogus=$rc_bogus"
[ "$out_bare" = "$out_bogus" ] || _fail "non-TTY bare cbox output differs from an invalid-subcommand invocation"
cmp -s "$BARE_RAW" "$BOGUS_RAW" || _fail "non-TTY bare cbox output differs byte-for-byte (including trailing newlines) from an invalid-subcommand invocation"
_ok "non-TTY bare cbox is byte-identical to an invalid-subcommand invocation (usage text + exit code, verified raw-byte via cmp, not just command-substitution-stripped)"

echo "$out_bare" | grep -qF "usage: $INSTALL_DIR/cbox {run" || _fail "usage text missing the run-verb summary"
_ok "usage text intact"

out_stdout_tty="$(HOME="$FIXHOME" script -qec "$(printf '%q' "$INSTALL_DIR/cbox") </dev/null" /dev/null 2>&1)" || true
echo "$out_stdout_tty" | grep -qF "usage: $INSTALL_DIR/cbox {run" \
  || _fail "stdin from /dev/null (non-TTY) with a TTY stdout unexpectedly opened the hub"
_ok "TTY stdout alone (non-TTY stdin) does not open the hub"

PTYHOME="$TMPBASE/home-pty"
PROJ="$TMPBASE/proj"
mkdir -p "$PTYHOME" "$PROJ"
git -C "$PROJ" init -q >/dev/null 2>&1
git -C "$PROJ" -c user.email=t@t -c user.name=t commit --allow-empty -m init -q >/dev/null 2>&1 || true

PHASH="$(printf '%s' "$PROJ" | sha256sum)"
PHASH="${PHASH:0:12}"
EFF="$PTYHOME/.config/cbox/projects/$PHASH"
mkdir -p "$EFF"
: > "$EFF/cbox.conf"
printf '%s' "$PROJ" > "$EFF/workspace"

STUBBIN="$TMPBASE/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/docker" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$STUBBIN/docker"

run_pty() {
  local input="$1" logfile="$2"
  ( cd "$PROJ" && HOME="$PTYHOME" PATH="$STUBBIN:$PATH" \
      script -qec "$(printf '%q' "$INSTALL_DIR/cbox")" /dev/null ) < "$input" > "$logfile" 2>&1
}

IN_Q="$TMPBASE/in_q"
printf 'q\n' > "$IN_Q"
LOG_Q="$TMPBASE/log_q"
rc=0
run_pty "$IN_Q" "$LOG_Q" || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub with immediate 'q' exited $rc, expected 0 ($(cat "$LOG_Q"))"
grep -q "cbox - $PROJ" "$LOG_Q" || _fail "PTY hub header line missing ($(cat "$LOG_Q"))"
grep -Eq 'container: +(unknown|down)' "$LOG_Q" || _fail "PTY hub did not render container state as unknown-or-down ($(cat "$LOG_Q"))"
grep -q 'mode: isolated' "$LOG_Q" || _fail "PTY hub did not report isolated mode"
grep -q '  1) claude' "$LOG_Q" || _fail "PTY hub did not render the claude engine row"
grep -q '  2) codex' "$LOG_Q" || _fail "PTY hub did not render the codex engine row"
_ok "PTY hub: renders header (container state unknown-or-down), quits cleanly on 'q', exit 0"

IN_ZZ="$TMPBASE/in_zz"
printf 'zz\nq\n' > "$IN_ZZ"
LOG_ZZ="$TMPBASE/log_zz"
rc=0
run_pty "$IN_ZZ" "$LOG_ZZ" || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub with invalid-then-q exited $rc, expected 0 ($(cat "$LOG_ZZ"))"
grep -q "unrecognized selection 'zz'" "$LOG_ZZ" || _fail "PTY hub did not report the invalid selection ($(cat "$LOG_ZZ"))"
header_count="$(grep -c "cbox - $PROJ" "$LOG_ZZ" || true)"
[ "$header_count" -ge 2 ] || _fail "PTY hub did not re-render the header after an invalid selection (saw $header_count)"
_ok "PTY hub: invalid selection ('zz') re-prompts (header re-rendered), then 'q' exits 0"

echo "PASS: all hub menu checks"
