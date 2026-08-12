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

REG="$INSTALL_DIR/etc/registry/settings.json"
python3 -c "
import json
data = json.load(open('$REG'))
keys = {v['key']: v for v in data['variables']}
assert 'CBOX_SESSION_MULTIPLEX' in keys, 'CBOX_SESSION_MULTIPLEX missing from registry'
v = keys['CBOX_SESSION_MULTIPLEX']
assert v['section'] == 'autoresume', v
assert v['default'] == 'off', v
assert v['type'] == {'kind': 'enum', 'values': ['off', 'on']}, v
"
_ok "registry: CBOX_SESSION_MULTIPLEX is section=autoresume, default=off, enum off/on"

grep -q "CBOX_SESSION_MULTIPLEX" "$INSTALL_DIR/templates/sections.sh" \
  || _fail "templates/sections.sh does not carry CBOX_SESSION_MULTIPLEX (registry not regenerated?)"
grep -q "CBOX_SESSION_MULTIPLEX" "$INSTALL_DIR/templates/conf_lib.sh" \
  || _fail "templates/conf_lib.sh does not carry CBOX_SESSION_MULTIPLEX (registry not regenerated?)"
grep -q "CBOX_SESSION_MULTIPLEX" "$INSTALL_DIR/templates/validator_dispatch.sh" \
  || _fail "templates/validator_dispatch.sh does not carry CBOX_SESSION_MULTIPLEX (registry not regenerated?)"
_ok "generated templates (sections.sh, conf_lib.sh, validator_dispatch.sh) all carry CBOX_SESSION_MULTIPLEX"

render_isolated() {
  local eff="$1" root="$2" home="$3" extra_env="${4:-}"
  mkdir -p "$eff" "$root" "$home"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    if [ -n "$extra_env" ]; then eval "$extra_env"; fi
    gen_compose_isolated "$eff" "$root" "cbox-img:test" "abcdef123456"
  )
}

ISO_DEFAULT="$TMPBASE/iso_default"
render_isolated "$ISO_DEFAULT/eff" "$ISO_DEFAULT/root" "$ISO_DEFAULT/home"
grep -qF '      - CBOX_SESSION_MULTIPLEX=off' "$ISO_DEFAULT/eff/docker-compose.yml" \
  || _fail "isolated compose does not default CBOX_SESSION_MULTIPLEX=off"
_ok "isolated compose: CBOX_SESSION_MULTIPLEX=off by default"

ISO_ON="$TMPBASE/iso_on"
render_isolated "$ISO_ON/eff" "$ISO_ON/root" "$ISO_ON/home" 'export CBOX_SESSION_MULTIPLEX=on'
grep -qF '      - CBOX_SESSION_MULTIPLEX=on' "$ISO_ON/eff/docker-compose.yml" \
  || _fail "isolated compose does not carry CBOX_SESSION_MULTIPLEX=on when set"
_ok "isolated compose: CBOX_SESSION_MULTIPLEX=on reaches the rendered compose file"

render_global() {
  local dir="$1" extra_env="${2:-}" ws
  ws="${dir}-ws"
  mkdir -p "$dir/generated/state" "$dir/generated/claude-config" "$ws"
  : > "$dir/image.inputs"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    INSTALL_DIR="$dir"
    HOME="$dir/home"
    mkdir -p "$HOME"
    export CBOX_CLAUDE_MODE=volume
    export CBOX_CODEX_MODE=volume
    export CBOX_WORKSPACES="$ws"
    if [ -n "$extra_env" ]; then eval "$extra_env"; fi
    gen_compose
  )
}

GLOB_DEFAULT="$TMPBASE/glob_default"
render_global "$GLOB_DEFAULT"
grep -qF '      - CBOX_SESSION_MULTIPLEX=off' "$GLOB_DEFAULT/docker-compose.yml" \
  || _fail "global compose does not default CBOX_SESSION_MULTIPLEX=off"
_ok "global compose: CBOX_SESSION_MULTIPLEX=off by default"

GLOB_ON="$TMPBASE/glob_on"
render_global "$GLOB_ON" 'export CBOX_SESSION_MULTIPLEX=on'
grep -qF '      - CBOX_SESSION_MULTIPLEX=on' "$GLOB_ON/docker-compose.yml" \
  || _fail "global compose does not carry CBOX_SESSION_MULTIPLEX=on when set"
_ok "global compose: CBOX_SESSION_MULTIPLEX=on reaches the rendered compose file"

bash -n "$INSTALL_DIR/entrypoint.sh" || _fail "entrypoint.sh fails bash -n"
_ok "entrypoint.sh passes bash -n"

WRAP_DIR="$TMPBASE/wrapcheck"
mkdir -p "$WRAP_DIR"

awk '
  /^    if \[ -t 0 \] && \[ -t 1 \] \\$/ && !claude_done {
    claude_done = 1; in_block = 1
  }
  in_block { print }
  in_block && /^    fi$/ { in_block = 0; exit }
' "$INSTALL_DIR/entrypoint.sh" > "$WRAP_DIR/claude_codex_block.sh"
[ -s "$WRAP_DIR/claude_codex_block.sh" ] || _fail "could not extract the claude/codex wrap-decision block from entrypoint.sh"

awk '
  /^    if \[ -t 0 \] && \[ -t 1 \] && \[ "\$\{CBOX_SESSION_MULTIPLEX:-off\}" = on \]; then$/ {
    in_block = 1
  }
  in_block { print }
  in_block && /^    fi$/ { in_block = 0; exit }
' "$INSTALL_DIR/entrypoint.sh" > "$WRAP_DIR/hermes_block.sh"
[ -s "$WRAP_DIR/hermes_block.sh" ] || _fail "could not extract the hermes wrap-decision block from entrypoint.sh"

_run_wrap_decision() {
  local block="$1" verb="$2" multiplex="$3" autoresume="$4" tmux_present="$5" tty="$6"
  local out="$TMPBASE/decision_out_$$_$RANDOM"
  local script_body
  script_body="$(cat <<INNER
set -eu
_verb='$verb'
CBOX_SESSION_MULTIPLEX='$multiplex'
CBOX_LIMIT_AUTORESUME='$autoresume'
_resolved=/fake/bin
HERMES_HOME=/fake/home
_hermes_session_prompt=""
command() {
  if [ "\$1" = -v ] && [ "\$2" = tmux ]; then
    [ "$tmux_present" = 1 ] && return 0 || return 1
  fi
  builtin command "\$@"
}
_multiplex_run() {
  echo "MULTIPLEX_RUN_CALLED args=\$*" > "$out"
  exit 90
}
set -- fake-arg
. "$block"
echo "FELL_THROUGH_NO_WRAP" > "$out"
INNER
)"
  if [ "$tty" = 1 ]; then
    script -qec "bash -c $(printf '%q' "$script_body")" /dev/null </dev/null >/dev/null 2>&1 || true
  else
    bash -c "$script_body" </dev/null >/dev/null 2>&1 </dev/null || true
  fi
  [ -f "$out" ] && cat "$out" || echo "NO_OUTPUT"
}

R1="$(_run_wrap_decision "$WRAP_DIR/claude_codex_block.sh" claude on off 1 1)"
case "$R1" in
  MULTIPLEX_RUN_CALLED*) _ok "claude wraps when CBOX_SESSION_MULTIPLEX=on, tmux present, real TTY" ;;
  *) _fail "claude did not wrap with CBOX_SESSION_MULTIPLEX=on (got: $R1)" ;;
esac

R2="$(_run_wrap_decision "$WRAP_DIR/claude_codex_block.sh" codex on off 1 1)"
case "$R2" in
  MULTIPLEX_RUN_CALLED*) _ok "codex wraps when CBOX_SESSION_MULTIPLEX=on, tmux present, real TTY" ;;
  *) _fail "codex did not wrap with CBOX_SESSION_MULTIPLEX=on (got: $R2)" ;;
esac

R3="$(_run_wrap_decision "$WRAP_DIR/hermes_block.sh" hermes on off 1 1)"
case "$R3" in
  MULTIPLEX_RUN_CALLED*) _ok "hermes wraps when CBOX_SESSION_MULTIPLEX=on, tmux present, real TTY" ;;
  *) _fail "hermes did not wrap with CBOX_SESSION_MULTIPLEX=on (got: $R3)" ;;
esac

R4="$(_run_wrap_decision "$WRAP_DIR/claude_codex_block.sh" claude off on 1 1)"
case "$R4" in
  MULTIPLEX_RUN_CALLED*) _ok "claude still wraps on CBOX_LIMIT_AUTORESUME=on alone (CBOX_SESSION_MULTIPLEX=off), real TTY" ;;
  *) _fail "claude did not wrap under legacy CBOX_LIMIT_AUTORESUME=on (got: $R4)" ;;
esac

R5="$(_run_wrap_decision "$WRAP_DIR/claude_codex_block.sh" codex off on 1 1)"
case "$R5" in
  FELL_THROUGH_NO_WRAP) _ok "codex does not wrap on CBOX_LIMIT_AUTORESUME=on alone (autoresume is claude-only)" ;;
  *) _fail "codex unexpectedly wrapped under CBOX_LIMIT_AUTORESUME=on (got: $R5)" ;;
esac

R6="$(_run_wrap_decision "$WRAP_DIR/claude_codex_block.sh" claude off off 1 1)"
case "$R6" in
  FELL_THROUGH_NO_WRAP) _ok "claude does not wrap when both CBOX_SESSION_MULTIPLEX and CBOX_LIMIT_AUTORESUME are off" ;;
  *) _fail "claude unexpectedly wrapped with both variables off (got: $R6)" ;;
esac

R7="$(_run_wrap_decision "$WRAP_DIR/claude_codex_block.sh" claude on off 1 0)"
case "$R7" in
  FELL_THROUGH_NO_WRAP) _ok "claude does not wrap when CBOX_SESSION_MULTIPLEX=on but there is no TTY" ;;
  *) _fail "claude unexpectedly wrapped without a TTY (got: $R7)" ;;
esac

R8="$(_run_wrap_decision "$WRAP_DIR/hermes_block.sh" hermes on off 1 0)"
case "$R8" in
  FELL_THROUGH_NO_WRAP) _ok "hermes does not wrap when CBOX_SESSION_MULTIPLEX=on but there is no TTY" ;;
  *) _fail "hermes unexpectedly wrapped without a TTY (got: $R8)" ;;
esac

R9="$(_run_wrap_decision "$WRAP_DIR/claude_codex_block.sh" claude on off 0 1)"
case "$R9" in
  NO_OUTPUT|FELL_THROUGH_NO_WRAP)
    grep -q "tmux is missing" "$WRAP_DIR/claude_codex_block.sh" >/dev/null 2>&1 || true
    _ok "claude does not call _multiplex_run when tmux is absent, even with CBOX_SESSION_MULTIPLEX=on and a real TTY"
    ;;
  MULTIPLEX_RUN_CALLED*) _fail "claude called _multiplex_run despite tmux being reported absent (got: $R9)" ;;
  *) _fail "unexpected decision output when tmux absent (got: $R9)" ;;
esac

FUNCDIR="$TMPBASE/funcs"
mkdir -p "$FUNCDIR"
awk '
  /^_no_symlinks\(\) \{/ { in_block = 1 }
  /^_as_user\(\) \{/ { in_block = 1 }
  /^_multiplex_session_name\(\) \{/ { in_block = 1 }
  /^_multiplex_status_dir_new\(\) \{/ { in_block = 1 }
  /^_multiplex_status_read\(\) \{/ { in_block = 1 }
  /^_multiplex_run\(\) \{/ { in_block = 1 }
  /^_write_tmux_conf\(\) \{/ { in_block = 1 }
  in_block { print }
  in_block && /^}$/ { in_block = 0 }
' "$INSTALL_DIR/entrypoint.sh" > "$FUNCDIR/multiplex_funcs.sh"
grep -q '^_multiplex_run() {' "$FUNCDIR/multiplex_funcs.sh" \
  || _fail "could not extract _multiplex_run from entrypoint.sh"
grep -q '^_multiplex_status_read() {' "$FUNCDIR/multiplex_funcs.sh" \
  || _fail "could not extract _multiplex_status_read from entrypoint.sh"
_ok "extracted _multiplex_session_name, _multiplex_status_dir_new, _multiplex_status_read, _multiplex_run, _write_tmux_conf from entrypoint.sh"

cat > "$FUNCDIR/status_probe.sh" <<'PROBEEOF'
set -u
CBOX_ROOTLESS=1
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
. "$1/multiplex_funcs.sh"
base="$2"
probe() {
  local out rc=0
  out="$(_multiplex_status_read "$1")" || rc=$?
  printf '%s=%s/%s\n' "$2" "$rc" "$out"
}
probe "$base/does-not-exist" missing
printf 'not-a-number' > "$base/malformed"
probe "$base/malformed" malformed
printf '99999' > "$base/oversized"
probe "$base/oversized" oversized
ln -sf /etc/passwd "$base/symlinked"
probe "$base/symlinked" symlink
printf '0' > "$base/zero"
probe "$base/zero" zero
printf '42' > "$base/valid"
probe "$base/valid" valid
printf '255' > "$base/maxbyte"
probe "$base/maxbyte" maxbyte
PROBEEOF
STATUS_READ_OUT="$(bash "$FUNCDIR/status_probe.sh" "$FUNCDIR" "$TMPBASE")"
for _case in missing malformed oversized symlink; do
  echo "$STATUS_READ_OUT" | grep -qx "$_case=1/" \
    || _fail "$_case status must report unavailable (rc 1, no value), got: $STATUS_READ_OUT"
done
_ok "unavailable status (missing, malformed, oversized, symlinked) reports rc 1 and emits no value"
echo "$STATUS_READ_OUT" | grep -qx 'zero=0/0' || _fail "a real exit code 0 must survive (got: $STATUS_READ_OUT)"
echo "$STATUS_READ_OUT" | grep -qx 'valid=0/42' || _fail "a real exit code 42 must survive (got: $STATUS_READ_OUT)"
echo "$STATUS_READ_OUT" | grep -qx 'maxbyte=0/255' || _fail "a real exit code 255 must survive (got: $STATUS_READ_OUT)"
_ok "a genuine exit code 1 is now distinguishable from an unavailable status"

SESSION_NAMES="$(
  bash -c '
    source "'"$FUNCDIR/multiplex_funcs.sh"'"
    for i in 1 2 3 4 5; do _multiplex_session_name claude; echo; done
  '
)"
UNIQUE_COUNT="$(printf '%s\n' "$SESSION_NAMES" | sort -u | grep -c .)"
[ "$UNIQUE_COUNT" -eq 5 ] || _fail "session names were not unique across 5 calls (got $UNIQUE_COUNT distinct of 5)"
printf '%s\n' "$SESSION_NAMES" | grep -Eq '^cbox-claude-[0-9a-f]+$' || _fail "session name does not match cbox-<engine>-<hex> shape: $SESSION_NAMES"
_ok "_multiplex_session_name: cbox-<engine>-<hex> shape, unique across repeated calls (5/5 distinct)"

if command -v tmux >/dev/null 2>&1; then
  E2E_DIR="$TMPBASE/e2e"
  E2E_MULTIPLEX_BASE="$TMPBASE/multiplex_base"
  mkdir -p "$E2E_DIR" "$E2E_MULTIPLEX_BASE"
  E2E_SCRIPT="$E2E_DIR/run.sh"
  cat > "$E2E_SCRIPT" <<INNER
#!/usr/bin/env bash
set -euo pipefail
HOST_UID=\$(id -u)
HOST_GID=\$(id -g)
CBOX_ROOTLESS=1
CBOX_MULTIPLEX_BASE="$E2E_MULTIPLEX_BASE"
source "$FUNCDIR/multiplex_funcs.sh"
_as_user() { "\$@"; }
_run_as_user() { exec "\$@"; }
_multiplex_run "\$@"
INNER
  chmod +x "$E2E_SCRIPT"

  run_e2e() {
    local exit_code="$1" rc
    rc=0
    env -u TMUX -u TMUX_PANE -u TERM_PROGRAM TMPDIR="$E2E_DIR" \
      script -qec "$(printf '%q' "$E2E_SCRIPT") fakeengine /bin/bash -c $(printf '%q' "exit $exit_code")" /dev/null \
      </dev/null >/dev/null 2>&1 || rc=$?
    echo "$rc"
  }

  RC1="$(run_e2e 0)"
  [ "$RC1" = 0 ] || _fail "end-to-end multiplex run: expected exit 0, got $RC1"
  RC2="$(run_e2e 37)"
  [ "$RC2" = 37 ] || _fail "end-to-end multiplex run: expected exit 37, got $RC2 (this is the DEFECT 1 regression check - exec-ing tmux new-session used to lose the real exit code)"
  RC3="$(run_e2e 200)"
  [ "$RC3" = 200 ] || _fail "end-to-end multiplex run: expected exit 200 (high-but-valid byte), got $RC3"
  _ok "end-to-end: _multiplex_run under a real tmux propagates the wrapped command's real exit status (0, 37, 200), not tmux client status 0"

  LEFTOVER="$( { find "$E2E_MULTIPLEX_BASE" -mindepth 1 -maxdepth 1 2>/dev/null || true; } | wc -l)"
  [ "$LEFTOVER" = 0 ] || _fail "end-to-end multiplex run left $LEFTOVER stale per-session status dir(s) under $E2E_MULTIPLEX_BASE"
  _ok "end-to-end: per-session private status directory is removed after the run (no leftovers)"
else
  _ok "(skipped end-to-end tmux propagation check - tmux(1) not found in this environment; wrap-decision and status-read logic above are still exercised)"
fi

echo "PASS: all session multiplex checks"
