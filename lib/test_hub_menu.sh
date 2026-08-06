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

[ -f "$INSTALL_DIR/lib/cbox_hub.py" ] || _fail "lib/cbox_hub.py not found - the python hub core is a required H1 deliverable"
python3 -c "import py_compile; py_compile.compile('$INSTALL_DIR/lib/cbox_hub.py', doraise=True)" \
  || _fail "lib/cbox_hub.py does not py_compile"
_ok "lib/cbox_hub.py exists and py_compiles cleanly"

grep -q "config (read-only view)" "$LOG_Q" || _fail "PTY hub did not render the python-hub-specific config row label - the dispatch may not be routing to lib/cbox_hub.py"
_ok "PTY hub with python3 present is routed through lib/cbox_hub.py (config row label confirms the python implementation, not the bash fallback)"

DOCKERSPY_LOG="$TMPBASE/docker_spy.log"
DOCKERSPYBIN="$TMPBASE/dockerspybin"
mkdir -p "$DOCKERSPYBIN"
cat > "$DOCKERSPYBIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKERSPY_LOG"
exit 1
EOF
chmod +x "$DOCKERSPYBIN/docker"
IN_NAV="$TMPBASE/in_nav"
printf '1\nq\n' > "$IN_NAV"
LOG_NAV="$TMPBASE/log_nav"
rc=0
( cd "$PROJ" && HOME="$PTYHOME" PATH="$DOCKERSPYBIN:$PATH" \
    script -qec "$(printf '%q' "$INSTALL_DIR/cbox")" /dev/null ) < "$IN_NAV" > "$LOG_NAV" 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub selecting the claude engine row exited $rc, expected 0 ($(cat "$LOG_NAV"))"
[ -s "$DOCKERSPY_LOG" ] || _fail "selecting row 1 (claude) never reached the docker CLI at all - navigation dispatch did not run 'cbox run claude'"
grep -q "compose" "$DOCKERSPY_LOG" || _fail "docker was invoked but not with a compose subcommand: $(cat "$DOCKERSPY_LOG")"
_ok "PTY hub: selecting row 1 (claude) reaches the exact 'cbox run claude' path (docker compose invoked, verified via a spy binary), then 'q' exits 0 with no crash despite no real daemon"

PYHOME="$TMPBASE/home-nopy-check"
mkdir -p "$PYHOME"
NOPYBIN="$TMPBASE/nopybin"
mkdir -p "$NOPYBIN"
for b in bash sh cat grep sed awk mkdir rm mv cp ls printf test dirname basename mktemp id git stty script tr sort head tail cut date sleep true false pwd realpath env tty; do
  p="$(command -v "$b" 2>/dev/null)" || continue
  ln -sf "$p" "$NOPYBIN/$b"
done
IN_NOPY="$TMPBASE/in_nopy"
printf 'q\n' > "$IN_NOPY"
LOG_NOPY="$TMPBASE/log_nopy"
GLOBALHOME="$TMPBASE/home-global-nopy"
mkdir -p "$GLOBALHOME"
INSTALLCOPY="$TMPBASE/cbox-install-nopy"
cp -a "$INSTALL_DIR" "$INSTALLCOPY"
{
  echo "CBOX_MODE=global"
  echo "CBOX_EGRESS_MODE=off"
} > "$INSTALLCOPY/cbox.conf"
rc=0
( cd "$TMPBASE" && HOME="$GLOBALHOME" PATH="$STUBBIN:$NOPYBIN" \
    script -qec "$(printf '%q' "$INSTALLCOPY/cbox")" /dev/null ) < "$IN_NOPY" > "$LOG_NOPY" 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub with python3 absent (global mode) exited $rc, expected 0 ($(cat "$LOG_NOPY"))"
grep -q "cbox - $TMPBASE" "$LOG_NOPY" || _fail "python3-missing fallback did not open the bash hub ($(cat "$LOG_NOPY"))"
grep -q "config (read-only view)" "$LOG_NOPY" && _fail "python3-missing fallback rendered the python hub's marker - the fallback guard did not engage"
_ok "python3-missing: bare cbox in global mode falls back to the bash hub (no cbox_hub.py marker present), not a crash"

BROKENHOME="$TMPBASE/home-broken"
mkdir -p "$BROKENHOME"
INSTALLBROKEN="$TMPBASE/cbox-install-broken"
cp -a "$INSTALL_DIR" "$INSTALLBROKEN"
{
  echo "CBOX_MODE=global"
  echo "CBOX_EGRESS_MODE=off"
} > "$INSTALLBROKEN/cbox.conf"
printf 'def this is not valid python(((\n' > "$INSTALLBROKEN/lib/cbox_hub.py"
IN_BROKEN="$TMPBASE/in_broken"
printf 'q\n' > "$IN_BROKEN"
LOG_BROKEN="$TMPBASE/log_broken"
rc=0
( cd "$TMPBASE" && HOME="$BROKENHOME" PATH="$STUBBIN:$PATH" \
    script -qec "$(printf '%q' "$INSTALLBROKEN/cbox")" /dev/null ) < "$IN_BROKEN" > "$LOG_BROKEN" 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub with a broken cbox_hub.py exited $rc, expected 0 ($(cat "$LOG_BROKEN"))"
grep -q "cbox - $TMPBASE" "$LOG_BROKEN" || _fail "broken cbox_hub.py did not fall back to the bash hub ($(cat "$LOG_BROKEN"))"
grep -q "config (read-only view)" "$LOG_BROKEN" && _fail "broken cbox_hub.py somehow rendered the python hub's marker"
_ok "a syntactically broken lib/cbox_hub.py degrades to the bash hub instead of crashing bare cbox"

INSTALLCRASH="$TMPBASE/cbox-install-crash"
cp -a "$INSTALL_DIR" "$INSTALLCRASH"
{
  echo "CBOX_MODE=global"
  echo "CBOX_EGRESS_MODE=off"
} > "$INSTALLCRASH/cbox.conf"
{
  printf 'import sys\n'
  printf 'def main(argv):\n'
  printf '    raise RuntimeError("synthetic runtime crash")\n'
  printf 'if __name__ == "__main__":\n'
  printf '    try:\n'
  printf '        sys.exit(main(sys.argv))\n'
  printf '    except SystemExit:\n'
  printf '        raise\n'
  printf '    except Exception:\n'
  printf '        sys.exit(97)\n'
} > "$INSTALLCRASH/lib/cbox_hub.py"
IN_CRASH="$TMPBASE/in_crash"
printf 'q\n' > "$IN_CRASH"
LOG_CRASH="$TMPBASE/log_crash"
rc=0
( cd "$TMPBASE" && HOME="$BROKENHOME" PATH="$STUBBIN:$PATH" \
    script -qec "$(printf '%q' "$INSTALLCRASH/cbox")" /dev/null ) < "$IN_CRASH" > "$LOG_CRASH" 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub with a runtime-crashing cbox_hub.py exited $rc, expected 0 via bash-hub fallback ($(cat "$LOG_CRASH"))"
grep -q "falling back to the bash hub" "$LOG_CRASH" || _fail "runtime-crash fallback note missing from stderr ($(cat "$LOG_CRASH"))"
grep -q "cbox - $TMPBASE" "$LOG_CRASH" || _fail "runtime-crashing cbox_hub.py (py_compile passes, main raises) did not fall back to the bash hub ($(cat "$LOG_CRASH"))"
grep -q "config (read-only view)" "$LOG_CRASH" && _fail "runtime-crashing cbox_hub.py somehow rendered the python hub's marker"
_ok "a syntactically valid but runtime-crashing lib/cbox_hub.py (py_compile blind spot) also degrades to the bash hub via the reserved failure exit code"

RUNGUARD_HOME="$TMPBASE/home-runguard"
mkdir -p "$RUNGUARD_HOME"
GUARDPROJ="$TMPBASE/runguard-proj"
mkdir -p "$GUARDPROJ"
git -C "$GUARDPROJ" init -q >/dev/null 2>&1
git -C "$GUARDPROJ" -c user.email=t@t -c user.name=t commit --allow-empty -m init -q >/dev/null 2>&1 || true
GPHASH="$(printf '%s' "$GUARDPROJ" | sha256sum)"
GPHASH="${GPHASH:0:12}"
GEFF="$RUNGUARD_HOME/.config/cbox/projects/$GPHASH"
mkdir -p "$GEFF"
: > "$GEFF/cbox.conf"
printf '%s' "$GUARDPROJ" > "$GEFF/workspace"
rc=0
( cd "$GUARDPROJ" && HOME="$RUNGUARD_HOME" PATH="$STUBBIN:$PATH" \
    "$INSTALLBROKEN/cbox" run codex --version </dev/null >/dev/null 2>&1 ) || rc=$?
[ "$rc" != 127 ] || _fail "cbox run codex failed with 'command not found' style rc under a broken cbox_hub.py - the direct run path must stay independent of the hub file"
_ok "'cbox run <engine>' keeps working even when lib/cbox_hub.py is syntactically broken (direct run path is independent of the hub dispatch guard)"

INSTALLISO="$TMPBASE/cbox-install-iso"
cp -a "$INSTALL_DIR" "$INSTALLISO"
rm -f "$INSTALLISO/cbox.conf"
ISOHOME="$TMPBASE/home-iso"
mkdir -p "$ISOHOME"
ISOPROJ="$TMPBASE/iso-proj"
mkdir -p "$ISOPROJ"
IPHASH="$(printf '%s' "$ISOPROJ" | sha256sum)"
IPHASH="${IPHASH:0:12}"
IEFF="$ISOHOME/.config/cbox/projects/$IPHASH"
mkdir -p "$IEFF"
{
  echo "CBOX_MODE=isolated"
  echo "CBOX_EGRESS_MODE=on"
} > "$IEFF/cbox.conf"
printf '%s' "$ISOPROJ" > "$IEFF/workspace"
CTX_OUT="$TMPBASE/ctx_iso.json"
( cd "$ISOPROJ" && HOME="$ISOHOME" PATH="$STUBBIN:$PATH" "$INSTALLISO/cbox" __hub_context ) > "$CTX_OUT" 2>/dev/null \
  || _fail "__hub_context failed for the isolated project ($(cat "$CTX_OUT"))"
grep -q '"mode": "isolated"' "$CTX_OUT" || _fail "__hub_context did not resolve isolated mode: $(cat "$CTX_OUT")"
grep -q '"egress": "on"' "$CTX_OUT" || _fail "__hub_context egress must come from the per-project isolated cbox.conf, not the global one: $(cat "$CTX_OUT")"
_ok "__hub_context reads egress from the isolated project's own cbox.conf (per-project on is reported even though no global conf sets it)"

echo "PASS: all hub menu checks"
