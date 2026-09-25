#!/usr/bin/env bash
set -euo pipefail

INSTALL_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

HARNESS="$TMPBASE/gate_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  awk '/^_cbox_engine_creds_file\(\) \{/,/^_run_global\(\) \{/' "$INSTALL_REAL/cbox" | sed '$d'
  cat <<'STUBS'
_cbox_config_set() {
  printf 'ISOLATED %s\n' "$*" >> "$CONFIG_SET_LOG"
  return "${CONFIG_SET_RC:-0}"
}
_cbox_config_set_force_global() {
  printf 'FORCE_GLOBAL %s\n' "$*" >> "$CONFIG_SET_LOG"
  return "${CONFIG_SET_RC:-0}"
}
_cbox_image_hash() {
  printf 'deadbeefcafefeed0011'
}
_cbox_image_tag() {
  printf 'cbox-img:%s' "${1:0:12}"
}
_cbox_run_egress_lockdown_gate "$@"
STUBS
} > "$HARNESS"
chmod +x "$HARNESS"

grep -q '_cbox_run_egress_lockdown_gate()' "$HARNESS" || _fail "could not extract _cbox_run_egress_lockdown_gate from cbox"
grep -q '_cbox_volume_file_present()' "$HARNESS" || _fail "could not extract _cbox_volume_file_present from cbox"
grep -q '_cbox_lockdown_probe_image_tag()' "$HARNESS" || _fail "could not extract _cbox_lockdown_probe_image_tag from cbox"

BINDIR="$TMPBASE/bin"
mkdir -p "$BINDIR"
DOCKER_VOL_FILES="$TMPBASE/vol_files"
mkdir -p "$DOCKER_VOL_FILES"
DOCKER_RUN_LOG="$TMPBASE/docker_run.log"
DOCKER_IMAGE_MARKER="$TMPBASE/docker_image_present"
printf 'present\n' > "$DOCKER_IMAGE_MARKER"
cat > "$BINDIR/docker" <<'DOCKERSTUB'
#!/usr/bin/env bash
if [ "$1" = volume ] && [ "$2" = inspect ]; then
  [ -f "$DOCKER_VOL_FILES/$3.exists" ]
  exit $?
fi
if [ "$1" = image ] && [ "$2" = inspect ]; then
  [ -s "$DOCKER_IMAGE_MARKER" ]
  exit $?
fi
if [ "$1" = run ]; then
  printf '%s\n' "$*" >> "$DOCKER_RUN_LOG"
  vol=""
  args="$*"
  for a in "$@"; do
    case "$a" in
      *:/cbox-lockdown-check:ro) vol="${a%%:*}" ;;
    esac
  done
  file="${args##* }"
  file="${file#/cbox-lockdown-check/}"
  [ -f "$DOCKER_VOL_FILES/$vol/$file" ]
  exit $?
fi
exit 1
DOCKERSTUB
chmod +x "$BINDIR/docker"

FAKE_INSTALL="$TMPBASE/install"
mkdir -p "$FAKE_INSTALL"
printf 'test\n' > "$FAKE_INSTALL/image.inputs"

CONFIG_SET_LOG="$TMPBASE/config_set.log"

_run() {
  local bin="$1" scope="$2" conf="$3" hash="$4"
  : > "$CONFIG_SET_LOG"
  : > "$DOCKER_RUN_LOG"
  env -i \
    HOME="$HOME" \
    PATH="$BINDIR:$PATH" \
    INSTALL_DIR="$FAKE_INSTALL" \
    CBOX_NAME="${TEST_CBOX_NAME:-cbox}" \
    CBOX_EGRESS_MODE="${TEST_EGRESS_MODE:-off}" \
    CBOX_EGRESS_APPLIED="${TEST_EGRESS_APPLIED:-0}" \
    CBOX_NETACCESS_MODE="${TEST_NETACCESS_MODE:-off}" \
    CBOX_NETACCESS_APPLIED="${TEST_NETACCESS_APPLIED:-0}" \
    CBOX_CLAUDE_MODE="${TEST_CLAUDE_MODE:-mount}" \
    CBOX_CLAUDE_PATH="${TEST_CLAUDE_PATH:-$TMPBASE/claude-missing}" \
    CBOX_CODEX_MODE="${TEST_CODEX_MODE:-mount}" \
    CBOX_CODEX_PATH="${TEST_CODEX_PATH:-$TMPBASE/codex-missing}" \
    ANTHROPIC_API_KEY="${TEST_ANTHROPIC_API_KEY:-}" \
    OPENAI_API_KEY="${TEST_OPENAI_API_KEY:-}" \
    DOCKER_VOL_FILES="$DOCKER_VOL_FILES" \
    DOCKER_RUN_LOG="$DOCKER_RUN_LOG" \
    DOCKER_IMAGE_MARKER="$DOCKER_IMAGE_MARKER" \
    CONFIG_SET_LOG="$CONFIG_SET_LOG" \
    CONFIG_SET_RC="${TEST_CONFIG_SET_RC:-0}" \
    bash "$HARNESS" "$bin" "$scope" "$conf" "$hash" 2>"$TMPBASE/stderr.out"
}

_reset_vols() {
  rm -rf "$DOCKER_VOL_FILES"
  mkdir -p "$DOCKER_VOL_FILES"
}

_image_present() {
  printf 'present\n' > "$DOCKER_IMAGE_MARKER"
}

_image_absent() {
  : > "$DOCKER_IMAGE_MARKER"
}

TEST_EGRESS_MODE=off TEST_NETACCESS_MODE=off _run claude global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "mode off: must never call _cbox_config_set, got: $(cat "$CONFIG_SET_LOG")"
_ok "lockdown off: gate is a no-op"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-missing" \
  _run claude global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "creds missing: must not mark the lockdown applied, got: $(cat "$CONFIG_SET_LOG")"
grep -q 'applies once you have logged in' "$TMPBASE/stderr.out" || _fail "creds missing: expected a login-pending note, got: $(cat "$TMPBASE/stderr.out")"
_ok "configured + not applied + no credentials yet - gate holds, prints the pending note, never marks applied"

mkdir -p "$TMPBASE/claude-present"
printf '{"x":1}' > "$TMPBASE/claude-present/.credentials.json"
TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-present" \
  _run claude global "" ""
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" || _fail "creds present: expected CBOX_EGRESS_APPLIED=1 to be recorded, got: $(cat "$CONFIG_SET_LOG")"
_ok "configured + not applied + credentials present - gate marks CBOX_EGRESS_APPLIED=1 exactly once"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=1 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-missing" \
  _run claude global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "already applied: must not touch config again, got: $(cat "$CONFIG_SET_LOG")"
_ok "already applied - gate never re-applies (sticky, no repeated writes)"

_reset_vols
TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=volume TEST_CBOX_NAME=cbox \
  _run claude global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "volume mode, no volume yet: must not mark applied, got: $(cat "$CONFIG_SET_LOG")"
_ok "volume mode, credentials volume absent - gate holds"

mkdir -p "$DOCKER_VOL_FILES/cbox-claude"
: > "$DOCKER_VOL_FILES/cbox-claude.exists"
printf '{"x":1}' > "$DOCKER_VOL_FILES/cbox-claude/.credentials.json"
TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=volume TEST_CBOX_NAME=cbox \
  _run claude global "" ""
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" || _fail "volume mode, credentials present: expected apply, got: $(cat "$CONFIG_SET_LOG")"
_ok "volume mode, credentials volume+file present - gate applies"

rm -f "$FAKE_INSTALL/image.inputs"
TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=volume TEST_CBOX_NAME=cbox \
  _run claude global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "probe: no image.inputs (scope image never built) must not mark applied, got: $(cat "$CONFIG_SET_LOG")"
grep -q 'applies once you have logged in' "$TMPBASE/stderr.out" || _fail "probe: no image.inputs should report not-ready, got: $(cat "$TMPBASE/stderr.out")"
printf 'test\n' > "$FAKE_INSTALL/image.inputs"
_ok "probe: scope image not built yet (no image.inputs) - gate holds, never falls back to a floating tag"

_image_absent
TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=volume TEST_CBOX_NAME=cbox \
  _run claude global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "probe: scope image not present locally must not mark applied, got: $(cat "$CONFIG_SET_LOG")"
_image_present
_ok "probe: scope image resolvable but 'docker image inspect' fails (not built locally) - gate holds"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=volume TEST_CBOX_NAME=cbox \
  _run claude global "" ""
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" || _fail "probe: image+volume+file present should apply, got: $(cat "$CONFIG_SET_LOG")"
grep -q -- '--network none' "$DOCKER_RUN_LOG" || _fail "probe: docker run should pass --network none, got: $(cat "$DOCKER_RUN_LOG")"
grep -q -- '--pull never' "$DOCKER_RUN_LOG" || _fail "probe: docker run should pass --pull never, got: $(cat "$DOCKER_RUN_LOG")"
grep -q -- '--entrypoint test' "$DOCKER_RUN_LOG" || _fail "probe: docker run should pass --entrypoint test, got: $(cat "$DOCKER_RUN_LOG")"
grep -q 'cbox-img:' "$DOCKER_RUN_LOG" || _fail "probe: docker run should use the scope's own cbox-img tag, got: $(cat "$DOCKER_RUN_LOG")"
grep -q 'ubuntu:24.04' "$DOCKER_RUN_LOG" && _fail "probe: docker run must never use a floating ubuntu:24.04 tag, got: $(cat "$DOCKER_RUN_LOG")"
_ok "probe: uses the scope's own already-built image with --network none --pull never --entrypoint test, never a floating ubuntu tag"

mkdir -p "$TMPBASE/claude-apikey-helper"
cat > "$TMPBASE/claude-apikey-helper/settings.json" <<'JSON'
{"apiKeyHelper": "/usr/local/bin/get-anthropic-key"}
JSON
TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-apikey-helper" \
  _run claude global "" ""
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" || _fail "api key: apiKeyHelper in settings.json should count as logged in, got: $(cat "$CONFIG_SET_LOG")"
_ok "api key: claude apiKeyHelper in settings.json (mount mode) is treated as logged in"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-missing" \
  TEST_ANTHROPIC_API_KEY=sk-ant-test \
  _run claude global "" ""
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" || _fail "api key: ANTHROPIC_API_KEY should count as logged in, got: $(cat "$CONFIG_SET_LOG")"
_ok "api key: ANTHROPIC_API_KEY in the calling shell is treated as logged in for claude"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CODEX_MODE=mount \
  TEST_CODEX_PATH="$TMPBASE/codex-missing" \
  TEST_OPENAI_API_KEY=sk-test \
  _run codex global "" ""
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" || _fail "api key: OPENAI_API_KEY should count as logged in, got: $(cat "$CONFIG_SET_LOG")"
_ok "api key: OPENAI_API_KEY in the calling shell is treated as logged in for codex"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-present" \
  TEST_CODEX_MODE=mount TEST_CODEX_PATH="$TMPBASE/codex-missing" \
  _run codex global "" ""
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" \
  || _fail "MEDIUM-A: cbox run codex with only claude logged in must still lock the global container (both engines' credentials are mounted in it), got: $(cat "$CONFIG_SET_LOG")"
grep -q '^FORCE_GLOBAL ' "$CONFIG_SET_LOG" \
  || _fail "LOW-1: global scope must write through the explicit global config writer, not the cwd-routed one, got: $(cat "$CONFIG_SET_LOG")"
_ok "MEDIUM-A: global scope, claude has credentials and codex does not - 'cbox run codex' still locks the network (readiness is scope-wide across every engine the scope carries, not just the one being invoked)"
_ok "LOW-1: global-scope gate writes go through the global config writer explicitly, unaffected by the caller's cwd-derived effective mode"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-missing" \
  TEST_CODEX_MODE=mount TEST_CODEX_PATH="$TMPBASE/codex-missing" \
  _run codex global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "MEDIUM-A negative control: neither engine has credentials, gate must hold, got: $(cat "$CONFIG_SET_LOG")"
_ok "MEDIUM-A negative control: global scope, neither claude nor codex has credentials - gate still holds"

TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-missing" \
  _run claude global "" ""
[ ! -s "$CONFIG_SET_LOG" ] || _fail "no creds, no api key: must not mark applied, got: $(cat "$CONFIG_SET_LOG")"
grep -q 'override once verified:.*config set CBOX_EGRESS_APPLIED=1' "$TMPBASE/stderr.out" \
  || _fail "no creds, no api key: expected an explicit config-set override hint, got: $(cat "$TMPBASE/stderr.out")"
_ok "no credentials, no detectable api key - gate holds and prints the explicit 'cbox config set' override hint"

rc=0
TEST_EGRESS_MODE=allowlist TEST_EGRESS_APPLIED=0 TEST_CLAUDE_MODE=mount \
  TEST_CLAUDE_PATH="$TMPBASE/claude-present" \
  TEST_CONFIG_SET_RC=1 \
  _run claude global "" "" || rc=$?
[ "$rc" = 1 ] || _fail "config set failure: gate should return non-zero to abort the run, got rc=$rc"
grep -qi 'aborting' "$TMPBASE/stderr.out" || _fail "config set failure: expected an abort message, got: $(cat "$TMPBASE/stderr.out")"
_ok "config set write failure - gate aborts non-zero with a clear message, never continues open silently"

PROJ_CONF="$TMPBASE/project.conf"
cat > "$PROJ_CONF" <<CONF
CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=0
CBOX_NETACCESS_MODE=off
CBOX_NETACCESS_APPLIED=0
CBOX_CLAUDE_MODE=mount
CBOX_CLAUDE_PATH=$TMPBASE/iso-claude-missing
CBOX_CODEX_MODE=mount
CBOX_CODEX_PATH=$TMPBASE/codex-missing
CONF
_run codex isolated "$PROJ_CONF" "deadbeefcafe"
[ ! -s "$CONFIG_SET_LOG" ] || _fail "isolated, codex creds missing: must not mark applied, got: $(cat "$CONFIG_SET_LOG")"
_ok "isolated scope, codex credentials missing - gate holds"

mkdir -p "$TMPBASE/codex-present"
printf '{"x":1}' > "$TMPBASE/codex-present/auth.json"
sed -i "s#CODEX_PATH=.*#CODEX_PATH=$TMPBASE/codex-present#" "$PROJ_CONF"
_run codex isolated "$PROJ_CONF" "deadbeefcafe"
grep -q 'CBOX_EGRESS_APPLIED=1' "$CONFIG_SET_LOG" || _fail "isolated, codex creds present: expected apply, got: $(cat "$CONFIG_SET_LOG")"
grep -q '^ISOLATED ' "$CONFIG_SET_LOG" \
  || _fail "LOW-1: isolated scope must route through the ordinary cwd-routed config writer, not the global-only one, got: $(cat "$CONFIG_SET_LOG")"
grep -q '^FORCE_GLOBAL ' "$CONFIG_SET_LOG" \
  && _fail "LOW-1: isolated scope must never use the global-only config writer, got: $(cat "$CONFIG_SET_LOG")"
_ok "isolated scope, codex credentials present - gate applies"
_ok "LOW-1: isolated-scope gate writes go through the ordinary (cwd-routed) config writer, never the global-only one"

up_body="$(awk '/^up\(\) \{/,/^}$/' "$INSTALL_REAL/cbox")"
[ -n "$up_body" ] || _fail "wiring: up() function not found in cbox"
case "$up_body" in
  *'_cbox_run_egress_lockdown_gate claude global || return 1'*) ;;
  *) _fail "wiring: up() should call the egress lockdown gate (claude, global) and abort (return 1) on failure" ;;
esac
gate_pos="${up_body%%_cbox_run_egress_lockdown_gate claude global*}"
prepare_pos="${up_body%%_cbox_global_prepare_locked*}"
[ "${#gate_pos}" -lt "${#prepare_pos}" ] || _fail "wiring: up() must call the egress lockdown gate before _cbox_global_prepare_locked"
_ok "MEDIUM-1: up() calls the egress lockdown gate (claude, global) before _cbox_global_prepare_locked and aborts on gate failure"

shell_isolated_body="$(awk '/^shell_isolated\(\) \{/,/^}$/' "$INSTALL_REAL/cbox")"
[ -n "$shell_isolated_body" ] || _fail "wiring: shell_isolated() function not found in cbox"
case "$shell_isolated_body" in
  *'_cbox_run_egress_lockdown_gate claude isolated'*) ;;
  *) _fail "MEDIUM-B: shell_isolated should call the egress lockdown gate (claude, isolated) before starting the container" ;;
esac
gate_pos="${shell_isolated_body%%_cbox_run_egress_lockdown_gate claude isolated*}"
compose_up_pos="${shell_isolated_body%%_cbox_compose_up*}"
[ "${#gate_pos}" -lt "${#compose_up_pos}" ] \
  || _fail "MEDIUM-B: shell_isolated must call the egress lockdown gate before _cbox_compose_up, got: $shell_isolated_body"
case "$shell_isolated_body" in
  *'_cbox_run_egress_lockdown_gate claude isolated'*'return 1'*) ;;
  *) _fail "MEDIUM-B: shell_isolated must abort (return 1) when the egress lockdown gate fails" ;;
esac
_ok "MEDIUM-B: shell_isolated calls the egress lockdown gate (claude, isolated) before _cbox_compose_up and aborts on gate failure"

REAL_TMPBASE="$TMPBASE/real"
mkdir -p "$REAL_TMPBASE"
REAL_INSTALL="$REAL_TMPBASE/install"
mkdir -p "$REAL_INSTALL"
(
  cd "$INSTALL_REAL" || exit 1
  for entry in *; do
    [ "$entry" = generated ] && continue
    cp -a "$entry" "$REAL_INSTALL/$entry"
  done
)
rm -f "$REAL_INSTALL/cbox.conf" "$REAL_INSTALL/.regen.lock" "$REAL_INSTALL/session.lock" "$REAL_INSTALL/.cbox-conf-manifest"

cat > "$REAL_INSTALL/cbox.conf" <<CONF
CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=0
CBOX_NETACCESS_MODE=off
CBOX_NETACCESS_APPLIED=0
CBOX_CLAUDE_MODE=mount
CBOX_CLAUDE_PATH=$REAL_TMPBASE/claude-present
CBOX_CODEX_MODE=mount
CBOX_CODEX_PATH=$REAL_TMPBASE/codex-missing
CBOX_NAME=cbox
CONF

mkdir -p "$REAL_TMPBASE/claude-present"
printf '{"x":1}' > "$REAL_TMPBASE/claude-present/.credentials.json"

REAL_BINDIR="$REAL_TMPBASE/bin"
mkdir -p "$REAL_BINDIR"
cat > "$REAL_BINDIR/docker" <<'DOCKERSTUB'
#!/usr/bin/env bash
exit 0
DOCKERSTUB
chmod +x "$REAL_BINDIR/docker"

REAL_HOME="$REAL_TMPBASE/home"
mkdir -p "$REAL_HOME/.config/cbox"
printf 'ubuntu:24.04|sha256:deadbeefcafefeeddeadbeefcafefeeddeadbeefcafefeeddeadbeefcafefeed|%s\n' "$(date +%s)" > "$REAL_HOME/.config/cbox/base-digest.cache"

REAL_TEST_SCRIPT="$REAL_TMPBASE/realtest.sh"
cat > "$REAL_TEST_SCRIPT" <<'EOS'
set -uo pipefail
source "$REAL_INSTALL/cbox" ls >/dev/null 2>"$REAL_TMPBASE/source.err"
source_rc=$?
_cbox_config_in_container() { return 1; }
pre_applied="${CBOX_EGRESS_APPLIED:-unset}"
_cbox_run_egress_lockdown_gate claude global
gate_rc=$?
post_applied="${CBOX_EGRESS_APPLIED:-unset}"
proxy_active=no
_cbox_proxy_active && proxy_active=yes
disk_applied="$(grep '^CBOX_EGRESS_APPLIED=' "$REAL_INSTALL/cbox.conf" | tail -n1 | cut -d= -f2)"
printf 'source_rc=%s\ngate_rc=%s\npre_applied=%s\npost_applied=%s\nproxy_active=%s\ndisk_applied=%s\n' \
  "$source_rc" "$gate_rc" "$pre_applied" "$post_applied" "$proxy_active" "$disk_applied" > "$REAL_TMPBASE/result.txt"
EOS

env -i \
  HOME="$REAL_HOME" \
  PATH="$REAL_BINDIR:/usr/bin:/bin" \
  REAL_INSTALL="$REAL_INSTALL" \
  REAL_TMPBASE="$REAL_TMPBASE" \
  bash "$REAL_TEST_SCRIPT" 2>"$REAL_TMPBASE/harness.err" || true

[ -f "$REAL_TMPBASE/result.txt" ] \
  || _fail "real config set: harness did not complete, harness.err: $(cat "$REAL_TMPBASE/harness.err" 2>/dev/null) source.err: $(cat "$REAL_TMPBASE/source.err" 2>/dev/null)"
source_rc="" gate_rc="" pre_applied="" post_applied="" proxy_active="" disk_applied=""
. "$REAL_TMPBASE/result.txt"

[ "$source_rc" = 0 ] || _fail "real config set: sourcing the real cbox script failed, rc=$source_rc, stderr: $(cat "$REAL_TMPBASE/source.err")"
[ "$gate_rc" = 0 ] || _fail "real config set: gate should succeed, got rc=$gate_rc"
[ "$pre_applied" = 0 ] || _fail "real config set: precondition CBOX_EGRESS_APPLIED should start at 0, got $pre_applied"
[ "$post_applied" = 1 ] || _fail "real config set (HIGH-1): the calling shell's CBOX_EGRESS_APPLIED must be 1 right after the gate returns (not stale), got $post_applied"
[ "$proxy_active" = yes ] || _fail "real config set (HIGH-1): the rendered posture (_cbox_proxy_active) must reflect applied=1 immediately in the same process, got $proxy_active"
[ "$disk_applied" = 1 ] || _fail "real config set: cbox.conf on disk should also show CBOX_EGRESS_APPLIED=1, got $disk_applied"
_ok "HIGH-1: real (non-stubbed) 'cbox config set' path - the calling process's env and the rendered posture (_cbox_proxy_active) both flip to applied in the same process, no stale-env window"

echo "test_run_egress_lockdown_gate: all checks passed"
