#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION \
  CBOX_HERMES_PROVIDER CBOX_HERMES_MODEL_URL CBOX_HERMES_MODEL_NAME CBOX_BINS_SCOPE \
  CBOX_BINS_HEALTH_GATE CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS CBOX_EGRESS_MODE \
  CBOX_LIMIT_AUTORESUME CBOX_SESSION_MULTIPLEX CBOX_SAFEGUARD_AUTOCONFIRM CBOX_MODE

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

command -v script >/dev/null 2>&1 || _fail "script(1) not found - required for the PTY harness"

[ -f "$INSTALL_DIR/lib/cbox_settings.py" ] || _fail "lib/cbox_settings.py not found - INC8 deliverable missing"
python3 -c "import py_compile; py_compile.compile('$INSTALL_DIR/lib/cbox_settings.py', doraise=True)" \
  || _fail "lib/cbox_settings.py does not py_compile"
_ok "lib/cbox_settings.py exists and py_compiles cleanly"

EXPECTED_USAGE="$TMPBASE/expected_usage.txt"
cat > "$EXPECTED_USAGE" <<'EOF'
usage: cbox setup menu (advanced per-section settings editor)
  numbers select a section, then a key inside it
  /text filters the index by id or title
  a applies pending, c runs classic, q quits, b goes back from a section
  isolated projects add r (reset overrides to global) and g (derive from global)
  requires a real TTY on stdin and stdout - use 'cbox setup update <section>' or 'cbox setup walk' from a script
EOF

NONTTY_OUT="$TMPBASE/nontty.out"
rc=0
python3 "$INSTALL_DIR/lib/cbox_settings.py" "$INSTALL_DIR" "$INSTALL_DIR/cbox" </dev/null > "$NONTTY_OUT" 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "non-TTY cbox_settings.py exited $rc, expected 1 ($(cat "$NONTTY_OUT"))"
cmp -s "$NONTTY_OUT" "$EXPECTED_USAGE" || _fail "non-TTY usage text is not byte-identical to the pinned expectation: $(diff "$EXPECTED_USAGE" "$NONTTY_OUT" || true)"
_ok "non-TTY path prints the byte-pinned usage text and exits 1"

BADARGV_OUT="$TMPBASE/badargv.out"
rc=0
python3 "$INSTALL_DIR/lib/cbox_settings.py" </dev/null > "$BADARGV_OUT" 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "missing-argv invocation exited $rc, expected 1"
cmp -s "$BADARGV_OUT" "$EXPECTED_USAGE" || _fail "missing-argv usage text differs from the pinned expectation"
_ok "missing argv also prints the same pinned usage text"

PTYHOME="$TMPBASE/home-pty"
PROJ="$TMPBASE/proj"
mkdir -p "$PTYHOME" "$PROJ"
git -C "$PROJ" init -q >/dev/null 2>&1
git -C "$PROJ" -c user.email=t@t -c user.name=t commit --allow-empty -m init -q >/dev/null 2>&1 || true

PHASH="$(printf '%s' "$PROJ" | sha256sum)"
PHASH="${PHASH:0:12}"
EFF="$PTYHOME/.config/cbox/projects/$PHASH"
mkdir -p "$EFF"
{
  echo "CBOX_MODE=isolated"
  echo "CBOX_EGRESS_MODE=off"
} > "$EFF/cbox.conf"
printf '%s' "$PROJ" > "$EFF/workspace"

STUBBIN="$TMPBASE/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/docker" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$STUBBIN/docker"

CONF_BEFORE="$TMPBASE/conf_before"
cp "$EFF/cbox.conf" "$CONF_BEFORE"

IN_Q="$TMPBASE/in_q"
printf 'q\n' > "$IN_Q"
LOG_Q="$TMPBASE/log_q"
rc=0
SETTINGS_CMD_LOCAL="python3 $(printf '%q' "$INSTALL_DIR/lib/cbox_settings.py") $(printf '%q' "$INSTALL_DIR") $(printf '%q' "$INSTALL_DIR/cbox") --local $(printf '%q' "$PROJ")"
( cd "$PROJ" && HOME="$PTYHOME" PATH="$STUBBIN:$PATH" \
    script -qec "$SETTINGS_CMD_LOCAL" /dev/null ) \
    < "$IN_Q" > "$LOG_Q" 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY settings menu with immediate 'q' exited $rc, expected 0 ($(cat "$LOG_Q"))"
grep -q "cbox settings" "$LOG_Q" || _fail "PTY settings menu did not render its header ($(cat "$LOG_Q"))"
grep -q "mode: isolated" "$LOG_Q" || _fail "PTY settings menu did not report isolated mode ($(cat "$LOG_Q"))"
grep -Eq '   [0-9]+\) mode ' "$LOG_Q" || _fail "PTY settings menu did not render the mode section row ($(cat "$LOG_Q"))"
grep -q "r) reset all overrides to global" "$LOG_Q" || _fail "PTY settings menu did not render the isolated-only reset key ($(cat "$LOG_Q"))"
cmp -s "$CONF_BEFORE" "$EFF/cbox.conf" || _fail "menu then q must leave cbox.conf byte-identical, but it changed"
_ok "PTY settings menu: renders the index, isolated-only keys present, quits cleanly on 'q', conf byte-identical"

IN_FILTER="$TMPBASE/in_filter"
printf '/hermes\nq\n' > "$IN_FILTER"
LOG_FILTER="$TMPBASE/log_filter"
rc=0
( cd "$PROJ" && HOME="$PTYHOME" PATH="$STUBBIN:$PATH" \
    script -qec "$SETTINGS_CMD_LOCAL" /dev/null ) \
    < "$IN_FILTER" > "$LOG_FILTER" 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY settings menu with a /hermes filter then 'q' exited $rc, expected 0 ($(cat "$LOG_FILTER"))"
grep -q "hermes" "$LOG_FILTER" || _fail "filtering by /hermes did not surface the hermes section ($(cat "$LOG_FILTER"))"
cmp -s "$CONF_BEFORE" "$EFF/cbox.conf" || _fail "filtering then q must leave cbox.conf byte-identical"
_ok "PTY settings menu: /text filter narrows the index, quits cleanly, conf byte-identical"

GLOBALHOME="$TMPBASE/home-global"
mkdir -p "$GLOBALHOME"
INSTALLGLOBAL="$TMPBASE/cbox-install-global"
cp -a "$INSTALL_DIR" "$INSTALLGLOBAL"
{
  echo "CBOX_MODE=global"
  echo "CBOX_EGRESS_MODE=off"
} > "$INSTALLGLOBAL/cbox.conf"
GLOBAL_CONF_BEFORE="$TMPBASE/global_conf_before"
cp "$INSTALLGLOBAL/cbox.conf" "$GLOBAL_CONF_BEFORE"
IN_GQ="$TMPBASE/in_gq"
printf 'q\n' > "$IN_GQ"
LOG_GQ="$TMPBASE/log_gq"
rc=0
SETTINGS_CMD_GLOBAL="python3 $(printf '%q' "$INSTALLGLOBAL/lib/cbox_settings.py") $(printf '%q' "$INSTALLGLOBAL") $(printf '%q' "$INSTALLGLOBAL/cbox")"
( cd "$TMPBASE" && HOME="$GLOBALHOME" PATH="$STUBBIN:$PATH" \
    script -qec "$SETTINGS_CMD_GLOBAL" /dev/null ) \
    < "$IN_GQ" > "$LOG_GQ" 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "PTY settings menu (global mode) with immediate 'q' exited $rc, expected 0 ($(cat "$LOG_GQ"))"
grep -q "mode: global" "$LOG_GQ" || _fail "PTY settings menu (global mode) did not report global mode ($(cat "$LOG_GQ"))"
grep -q "r) reset all overrides to global" "$LOG_GQ" && _fail "global mode must not show the isolated-only reset key"
cmp -s "$GLOBAL_CONF_BEFORE" "$INSTALLGLOBAL/cbox.conf" || _fail "global menu then q must leave cbox.conf byte-identical"
_ok "PTY settings menu (global mode): no isolated-only keys shown, quits cleanly, conf byte-identical"

echo "PASS: all settings menu checks"
