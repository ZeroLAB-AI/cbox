#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION \
  CBOX_HERMES_PROVIDER CBOX_HERMES_MODEL_URL CBOX_HERMES_MODEL_NAME CBOX_BINS_SCOPE \
  CBOX_BINS_HEALTH_GATE CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_EGRESS_MODE \
  CBOX_LIMIT_AUTORESUME CBOX_SESSION_MULTIPLEX CBOX_SAFEGUARD_AUTOCONFIRM CBOX_HUB_PLAIN \
  CBOX_HUB_TIMING CBOX_HUB_T0 CBOX_MODE

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

command -v script >/dev/null 2>&1 || _fail "script(1) not found - required for the PTY harness"
REALPY="$(command -v python3)"
REALGIT="$(command -v git)"

CALLS="$TMPBASE/calls.log"
SHIMBIN="$TMPBASE/shimbin"
mkdir -p "$SHIMBIN"
cat > "$SHIMBIN/python3" <<EOF2
#!/bin/sh
printf 'py %s\n' "\$1 \$2" >> "$CALLS"
exec "$REALPY" "\$@"
EOF2
cat > "$SHIMBIN/git" <<EOF2
#!/bin/sh
printf 'git %s\n' "\$*" >> "$CALLS"
exec "$REALGIT" "\$@"
EOF2
cat > "$SHIMBIN/docker" <<'EOF2'
#!/bin/sh
case "$1 $2" in
  "compose --project-directory") echo cid1 ;;
  "compose -f") echo cid1 ;;
  inspect*) echo 2026-10-07T10:00:00.123Z ;;
  exec*) printf 'claude\n' ;;
esac
exit 0
EOF2
chmod +x "$SHIMBIN/python3" "$SHIMBIN/git" "$SHIMBIN/docker"

HOME_ISO="$TMPBASE/home-iso"
PROJ="$TMPBASE/proj"
mkdir -p "$HOME_ISO" "$PROJ"
"$REALGIT" -C "$PROJ" init -q
PROJ_REAL="$(cd "$PROJ" && pwd -P)"
PHASH="$(printf '%s' "$PROJ_REAL" | sha256sum)"
PHASH="${PHASH:0:12}"
EFF="$HOME_ISO/.config/cbox/projects/$PHASH"
mkdir -p "$EFF"
printf 'CBOX_MODE=isolated\nCBOX_EGRESS_MODE=on\n' > "$EFF/cbox.conf"
printf '%s' "$PROJ_REAL" > "$EFF/workspace"

INSTALL_ISO="$TMPBASE/install-iso"
cp -a "$INSTALL_DIR" "$INSTALL_ISO"
[ ! -f "$INSTALL_ISO/cbox.conf" ] || mv "$INSTALL_ISO/cbox.conf" "$TMPBASE/unused-global.conf"

count_of() { grep -c "$1" "$CALLS" || true; }

: > "$CALLS"
( cd "$PROJ" && HOME="$HOME_ISO" PATH="$SHIMBIN:$PATH" "$INSTALL_ISO/cbox" __hub_context ) > "$TMPBASE/ctx.json" 2>/dev/null \
  || _fail "__hub_context failed in isolated mode"
grep -q '"mode": "isolated"' "$TMPBASE/ctx.json" || _fail "isolated mode not resolved: $(cat "$TMPBASE/ctx.json")"
[ "$(count_of '^git ')" = 1 ] || _fail "the workspace root must be resolved with exactly one git call, saw $(count_of '^git '): $(cat "$CALLS")"
[ "$(count_of 'cbox_host.py sha256')" = 1 ] || _fail "the path hash must be computed exactly once, saw $(count_of 'cbox_host.py sha256')"
[ "$(count_of 'cbox_host.py ismount')" = 1 ] || _fail "the mount check must run exactly once, saw $(count_of 'cbox_host.py ismount')"
[ "$(count_of 'cbox_host.py realpath')" = 2 ] || _fail "realpath must run exactly twice (root and HOME), saw $(count_of 'cbox_host.py realpath')"
_ok "__hub_context in isolated mode resolves the root (1 git, 2 realpath, 1 ismount) and the path hash (1 sha256) once per invocation"

grep -q '"egress"\|"bins"' "$TMPBASE/ctx.json" && _fail "the default __hub_context must not carry egress or bins"
: > "$CALLS"
( cd "$PROJ" && HOME="$HOME_ISO" PATH="$SHIMBIN:$PATH" "$INSTALL_ISO/cbox" __hub_context --full ) > "$TMPBASE/ctx_full.json" 2>/dev/null \
  || _fail "__hub_context --full failed"
grep -q '"egress": "on"' "$TMPBASE/ctx_full.json" || _fail "--full must carry the project egress: $(cat "$TMPBASE/ctx_full.json")"
grep -q '"bins": "bins: ' "$TMPBASE/ctx_full.json" || _fail "--full must carry the bins line: $(cat "$TMPBASE/ctx_full.json")"
[ "$(count_of 'cbox_host.py sha256')" = 1 ] || _fail "--full must still hash the path once, saw $(count_of 'cbox_host.py sha256')"
[ "$(count_of '^git ')" = 1 ] || _fail "--full must still use one git call"
"$REALPY" - "$TMPBASE/ctx.json" "$TMPBASE/ctx_full.json" <<'PY' || _fail "the default context must equal the full one minus egress and bins"
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
b.pop("egress")
b.pop("bins")
assert a == b, (a, b)
PY
_ok "__hub_context --full adds egress and bins on top of the identical default document, still with one root and one hash computation"

GLOBAL_HOME="$TMPBASE/home-global"
mkdir -p "$GLOBAL_HOME"
INSTALL_GLOBAL="$TMPBASE/install-global"
cp -a "$INSTALL_DIR" "$INSTALL_GLOBAL"
printf 'CBOX_MODE=global\nCBOX_EGRESS_MODE=off\n' > "$INSTALL_GLOBAL/cbox.conf"
: > "$CALLS"
( cd "$TMPBASE" && HOME="$GLOBAL_HOME" PATH="$SHIMBIN:$PATH" "$INSTALL_GLOBAL/cbox" __hub_context ) > "$TMPBASE/ctx_g.json" 2>/dev/null \
  || _fail "__hub_context failed in global mode"
grep -q '"mode": "global"' "$TMPBASE/ctx_g.json" || _fail "global mode not resolved: $(cat "$TMPBASE/ctx_g.json")"
grep -q '"egress"' "$TMPBASE/ctx_g.json" && _fail "the default global context must not carry egress"
[ "$(count_of '^git ')" -le 1 ] || _fail "global mode must resolve the root at most once"
( cd "$TMPBASE" && HOME="$GLOBAL_HOME" PATH="$SHIMBIN:$PATH" "$INSTALL_GLOBAL/cbox" __hub_context --full ) > "$TMPBASE/ctx_gf.json" 2>/dev/null
grep -q '"egress": "off"' "$TMPBASE/ctx_gf.json" || _fail "global --full must carry egress: $(cat "$TMPBASE/ctx_gf.json")"
_ok "__hub_context in global mode drops egress and bins by default and carries them with --full"

grep -q 'py_compile' "$INSTALL_DIR/cbox" && _fail "the cbox dispatch must not start a separate python3 syntax check before the hub"
_ok "the cbox script contains no py_compile pre-check"

run_pty() {
  local home="$1" input="$2" out="$3"
  shift 3
  ( cd "$PROJ" && env HOME="$home" PATH="$SHIMBIN:$PATH" "$@" \
      script -qec "$(printf '%q' "$INSTALL_ISO/cbox")" /dev/null ) < "$input" > "$out" 2>&1
}

printf 'q\n' > "$TMPBASE/in_q"
: > "$CALLS"
rc=0
run_pty "$HOME_ISO" "$TMPBASE/in_q" "$TMPBASE/pty1.log" || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub exited $rc ($(cat "$TMPBASE/pty1.log"))"
grep -q 'cmd: ' "$TMPBASE/pty1.log" || _fail "the python hub did not render"
grep -q 'py_compile' "$CALLS" && _fail "bare cbox started a py_compile python3 before the hub: $(cat "$CALLS")"
[ "$(count_of 'cbox_hub_launch.py')" = 1 ] || _fail "the hub must start python3 exactly once through the launcher: $(cat "$CALLS")"
_ok "bare cbox opens the python hub with a single launcher start and no separate syntax-check python3"

[ -d "$HOME_ISO/.config/cbox/hub-cache" ] || _fail "the first open must write the status cache"
CACHE_FILE="$(ls "$HOME_ISO/.config/cbox/hub-cache"/status-*.json)"
[ "$(stat -c %a "$CACHE_FILE")" = 600 ] || _fail "cache file must be 0600"
[ "$(stat -c %a "$HOME_ISO/.config/cbox/hub-cache")" = 700 ] || _fail "cache dir must be 0700"
grep -q '(cached ' "$TMPBASE/pty1.log" && _fail "a first open without a cache must not show a cached marker"
rc=0
run_pty "$HOME_ISO" "$TMPBASE/in_q" "$TMPBASE/pty2.log" || rc=$?
[ "$rc" = 0 ] || _fail "second PTY hub exited $rc"
grep -q 'container  up (since 2026-10-07T10:00:00) (cached [0-9]*s ago)' "$TMPBASE/pty2.log" \
  || _fail "the second open must show the cached status with its age: $(cat "$TMPBASE/pty2.log")"
_ok "the first open writes a private status cache and the second open shows it at once, marked cached with its age"

printf '%s' 'garbage' > "$CACHE_FILE"
rc=0
run_pty "$HOME_ISO" "$TMPBASE/in_q" "$TMPBASE/pty3.log" || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub with a corrupt cache exited $rc"
grep -q 'container  up (since 2026-10-07T10:00:00)[[:space:]]*$' "$TMPBASE/pty3.log" \
  || _fail "a corrupt cache must be ignored and a fresh probe shown: $(cat "$TMPBASE/pty3.log")"
_ok "a corrupt cache file is ignored and the hub falls back to the fresh probe"

rc=0
run_pty "$HOME_ISO" "$TMPBASE/in_q" "$TMPBASE/pty4.log" CBOX_HUB_TIMING=1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY hub with timing exited $rc"
for label in "bash start" "context startup" "context total" "python imports" "context (cbox __hub_context)" "first screen shown"; do
  grep -q "cbox-hub-timing: $label" "$TMPBASE/pty4.log" || _fail "timing output is missing '$label': $(cat "$TMPBASE/pty4.log")"
done
grep -q "cbox-hub-timing: [a-z ()_]* [0-9]* ms" "$TMPBASE/pty4.log" || _fail "timing lines must carry millisecond figures"
_ok "CBOX_HUB_TIMING=1 prints the bash, context, import and screen phases to stderr"

grep -q 'cbox-hub-timing' "$TMPBASE/pty1.log" "$TMPBASE/pty2.log" && _fail "timing output must stay off by default"
_ok "no timing output unless CBOX_HUB_TIMING=1"

( cd "$PROJ" && HOME="$HOME_ISO" PATH="$SHIMBIN:$PATH" CBOX_HUB_TIMING=0 "$INSTALL_ISO/cbox" __hub_context ) > /dev/null 2> "$TMPBASE/err0.log" || true
grep -q 'cbox-hub-timing' "$TMPBASE/err0.log" && _fail "CBOX_HUB_TIMING=0 must not print timing"
_ok "only CBOX_HUB_TIMING=1 switches timing on"

( cd "$PROJ" && env HOME="$HOME_ISO" PATH="$SHIMBIN:$PATH" _CBOX_HUB_T0=1 "$INSTALL_ISO/cbox" __hub_context ) > /dev/null 2> "$TMPBASE/err_inherit.log" || true
grep -q 'cbox-hub-timing' "$TMPBASE/err_inherit.log" && _fail "an inherited _CBOX_HUB_T0 must never switch timing on"
( cd "$PROJ" && env HOME="$HOME_ISO" PATH="$SHIMBIN:$PATH" _CBOX_HUB_T0=1 CBOX_HUB_TIMING=0 "$INSTALL_ISO/cbox" __hub_context ) > /dev/null 2> "$TMPBASE/err_inherit0.log" || true
grep -q 'cbox-hub-timing' "$TMPBASE/err_inherit0.log" && _fail "an inherited _CBOX_HUB_T0 with timing off must stay silent"
_ok "an inherited _CBOX_HUB_T0 is cleared when timing is off"

echo "PASS: all hub speed checks"
