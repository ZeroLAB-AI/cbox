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

HARNESS="$TMPBASE/apply_change_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  awk '/^_apply_change_project_eff\(\) \{/,/^}$/' "$INSTALL_REAL/lib/cbox-setup.sh"
  awk '/^_apply_change_running\(\) \{/,/^}$/' "$INSTALL_REAL/lib/cbox-setup.sh"
  awk '/^apply_change\(\) \{/,/^}$/' "$INSTALL_REAL/lib/cbox-setup.sh"
  cat <<'STUBS'
have_docker() { command -v docker >/dev/null 2>&1; }
note() { printf 'note: %s\n' "$*"; }
ask_yn() { printf '%s\n' "$ASK_YN_ANSWER" >> "$ASK_LOG"; [ "$ASK_YN_ANSWER" = y ]; }
apply_action_for() { printf '%s' "$TEST_ACTION"; }
ssh_mixed_sync() { printf 'ssh_mixed_sync_called\n' >> "$SIDE_LOG"; }
_cbox_workspace_root() {
  [ -n "${TEST_WORKSPACE_ROOT:-}" ] || return 1
  printf '%s' "$TEST_WORKSPACE_ROOT"
}
_cbox_local_effdir_for() {
  printf '%s' "$TEST_PROJECT_EFF"
}
apply_change "$1"
STUBS
} > "$HARNESS"
chmod +x "$HARNESS"

grep -q 'apply_change()' "$HARNESS" || _fail "could not extract apply_change from lib/cbox-setup.sh"
grep -q '_apply_change_running()' "$HARNESS" || _fail "could not extract _apply_change_running from lib/cbox-setup.sh"
grep -q '_apply_change_project_eff()' "$HARNESS" || _fail "could not extract _apply_change_project_eff from lib/cbox-setup.sh"

BINDIR="$TMPBASE/bin"
mkdir -p "$BINDIR"

DOCKER_LOG="$TMPBASE/docker.log"
DOCKER_BAD_LOG="$TMPBASE/docker_bad.log"
CBOX_LOG="$TMPBASE/cbox.log"
ASK_LOG="$TMPBASE/ask.log"
SIDE_LOG="$TMPBASE/side.log"

cat > "$BINDIR/docker" <<'DOCKERSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case " $* " in
  *' up '*|*' up '|*' build '*|*' build ')
    printf '%s\n' "$*" >> "$DOCKER_BAD_LOG"
    ;;
esac
if [ "$1" = compose ]; then
  shift
  for a in "$@"; do
    if [ "$a" = ps ]; then
      if [ "${DOCKER_RUNNING:-0}" = 1 ]; then
        printf 'fakecontainerid\n'
      fi
      exit 0
    fi
  done
fi
exit 0
DOCKERSTUB
chmod +x "$BINDIR/docker"

FAKE_INSTALL_DIR="$TMPBASE/install"
mkdir -p "$FAKE_INSTALL_DIR"
cat > "$FAKE_INSTALL_DIR/cbox" <<'CBOXSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CBOX_LOG"
exit 0
CBOXSTUB
chmod +x "$FAKE_INSTALL_DIR/cbox"

_reset_logs() {
  : > "$DOCKER_LOG"
  : > "$DOCKER_BAD_LOG"
  : > "$CBOX_LOG"
  : > "$ASK_LOG"
  : > "$SIDE_LOG"
}

_run() {
  local section="$1"
  env -i \
    HOME="$HOME" \
    PATH="$BINDIR:$PATH" \
    INSTALL_DIR="$FAKE_INSTALL_DIR" \
    COMPOSE_FILE="$FAKE_INSTALL_DIR/docker-compose.yml" \
    SERVICE=cbox \
    DOCKER_LOG="$DOCKER_LOG" \
    DOCKER_BAD_LOG="$DOCKER_BAD_LOG" \
    CBOX_LOG="$CBOX_LOG" \
    ASK_LOG="$ASK_LOG" \
    SIDE_LOG="$SIDE_LOG" \
    CBOX_MODE="${TEST_CBOX_MODE:-global}" \
    DOCKER_RUNNING="${TEST_DOCKER_RUNNING:-0}" \
    ASK_YN_ANSWER="${TEST_ASK_YN_ANSWER:-n}" \
    TEST_ACTION="$TEST_ACTION" \
    TEST_WORKSPACE_ROOT="${TEST_WORKSPACE_ROOT:-}" \
    TEST_PROJECT_EFF="${TEST_PROJECT_EFF:-}" \
    bash "$HARNESS" "$section"
}

for action in recreate restart topology rebuild; do
  _reset_logs
  TEST_ACTION="$action" TEST_CBOX_MODE=global TEST_DOCKER_RUNNING=0
  out="$(_run some-section)"
  [ ! -s "$DOCKER_BAD_LOG" ] || _fail "$action: no-running-container path must never call docker compose up/build, got: $(cat "$DOCKER_BAD_LOG")"
  [ ! -s "$CBOX_LOG" ] || _fail "$action: no-running-container path must not invoke cbox, got: $(cat "$CBOX_LOG")"
  printf '%s\n' "$out" | grep -q 'applies on the next cbox run' || _fail "$action: expected a next-run note, got: $out"
  _ok "$action: no running container - no cbox/docker up-build call, notes next run"
done

for action in recreate restart topology rebuild; do
  _reset_logs
  TEST_ACTION="$action" TEST_CBOX_MODE=global TEST_DOCKER_RUNNING=1 TEST_ASK_YN_ANSWER=y
  out="$(_run some-section)"
  [ ! -s "$DOCKER_BAD_LOG" ] || _fail "$action: running-container+yes path must never call docker compose up/build, got: $(cat "$DOCKER_BAD_LOG")"
  grep -qx -- 'down --force' "$CBOX_LOG" || _fail "$action: expected cbox to be invoked with 'down --force', got: $(cat "$CBOX_LOG")"
  [ "$(grep -c . "$CBOX_LOG")" = 1 ] || _fail "$action: expected exactly one cbox invocation, got: $(cat "$CBOX_LOG")"
  _ok "$action: running container + yes - cbox down --force called, no compose up/build"
done

for action in recreate restart topology rebuild; do
  _reset_logs
  TEST_ACTION="$action" TEST_CBOX_MODE=global TEST_DOCKER_RUNNING=1 TEST_ASK_YN_ANSWER=n
  out="$(_run some-section)"
  [ ! -s "$CBOX_LOG" ] || _fail "$action: running-container+no path must not invoke cbox, got: $(cat "$CBOX_LOG")"
  [ ! -s "$DOCKER_BAD_LOG" ] || _fail "$action: running-container+no path must never call docker compose up/build"
  printf '%s\n' "$out" | grep -q 'not stopped' || _fail "$action: expected a not-stopped note, got: $out"
  _ok "$action: running container + no - not stopped, no cbox call"
done

_reset_logs
TEST_ACTION=restart TEST_CBOX_MODE=isolated TEST_WORKSPACE_ROOT="" TEST_DOCKER_RUNNING=1
out="$(_run some-section)"
[ ! -s "$CBOX_LOG" ] || _fail "isolated/no-eff: must not invoke cbox, got: $(cat "$CBOX_LOG")"
[ ! -s "$DOCKER_BAD_LOG" ] || _fail "isolated/no-eff: must never call docker compose up/build"
printf '%s\n' "$out" | grep -qi 'isolated mode' || _fail "isolated/no-eff: expected an isolated-mode note, got: $out"
_ok "isolated mode, no project here - no cbox/docker call, isolated note"

_reset_logs
PROJECT_EFF="$TMPBASE/project-eff"
mkdir -p "$PROJECT_EFF"
: > "$PROJECT_EFF/cbox.conf"
TEST_ACTION=restart TEST_CBOX_MODE=isolated TEST_WORKSPACE_ROOT="$TMPBASE/proj" TEST_PROJECT_EFF="$PROJECT_EFF" TEST_DOCKER_RUNNING=0
out="$(_run some-section)"
[ ! -s "$CBOX_LOG" ] || _fail "isolated/eff-not-running: must not invoke cbox, got: $(cat "$CBOX_LOG")"
printf '%s\n' "$out" | grep -qi 'no running project container' || _fail "isolated/eff-not-running: expected a not-running note, got: $out"
_ok "isolated mode, project exists but not running - no cbox call"

_reset_logs
TEST_ACTION=restart TEST_CBOX_MODE=isolated TEST_WORKSPACE_ROOT="$TMPBASE/proj" TEST_PROJECT_EFF="$PROJECT_EFF" TEST_DOCKER_RUNNING=1 TEST_ASK_YN_ANSWER=y
out="$(_run some-section)"
[ ! -s "$DOCKER_BAD_LOG" ] || _fail "isolated/eff-running+yes: must never call docker compose up/build"
grep -qx -- 'down --force' "$CBOX_LOG" || _fail "isolated/eff-running+yes: expected cbox down --force, got: $(cat "$CBOX_LOG")"
_ok "isolated mode, project running + yes - cbox down --force called"

_reset_logs
command -v docker >/dev/null 2>&1 && _fail "no-docker-cli test precondition failed: a real docker binary is on PATH"
TEST_ACTION=recreate TEST_CBOX_MODE=global TEST_DOCKER_RUNNING=0
env -i HOME="$HOME" PATH="$PATH" INSTALL_DIR="$FAKE_INSTALL_DIR" COMPOSE_FILE="$FAKE_INSTALL_DIR/docker-compose.yml" \
  SERVICE=cbox DOCKER_LOG="$DOCKER_LOG" DOCKER_BAD_LOG="$DOCKER_BAD_LOG" CBOX_LOG="$CBOX_LOG" ASK_LOG="$ASK_LOG" SIDE_LOG="$SIDE_LOG" \
  CBOX_MODE=global TEST_ACTION=recreate \
  bash "$HARNESS" some-section > "$TMPBASE/nodocker.out"
[ ! -s "$CBOX_LOG" ] || _fail "no-docker-cli: must not invoke cbox"
[ ! -s "$DOCKER_BAD_LOG" ] || _fail "no-docker-cli: must never call docker compose up/build"
grep -q 'cbox run' "$TMPBASE/nodocker.out" || _fail "no-docker-cli: expected a 'cbox run' hint, got: $(cat "$TMPBASE/nodocker.out")"
grep -qi 'docker compose' "$TMPBASE/nodocker.out" && _fail "no-docker-cli: must not print raw docker compose commands"
_ok "docker cli unavailable - prints cbox run hint only, no compose commands, no cbox/docker call"

_reset_logs
TEST_ACTION=none TEST_CBOX_MODE=global TEST_DOCKER_RUNNING=0
out="$(_run some-section)"
[ ! -s "$CBOX_LOG" ] || _fail "action=none must not invoke cbox"
[ ! -s "$DOCKER_LOG" ] || _fail "action=none must not touch docker at all"
_ok "action=none short-circuits before any docker/cbox call"

echo "test_apply_change_lifecycle: all checks passed"
