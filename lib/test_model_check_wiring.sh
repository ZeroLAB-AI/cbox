#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

while IFS='=' read -r name _; do
  case "$name" in CBOX_*) unset "$name" ;; esac
done < <(env)

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

CBOX="$INSTALL_DIR/cbox"

run_body="$(sed -n '/^run() {/,/^}/p' "$CBOX")"
hook_line="$(printf '%s\n' "$run_body" | grep -n '_cbox_models_hook start' | head -1 | cut -d: -f1)"
dispatch_line="$(printf '%s\n' "$run_body" | grep -n '_cbox_run_dispatch "\$session_id"' | head -1 | cut -d: -f1)"
[ -n "$hook_line" ] && [ -n "$dispatch_line" ] || _fail "run() lacks the model check hook or the dispatch"
[ "$hook_line" -lt "$dispatch_line" ] || _fail "the model check hook must run before the agent dispatch"
printf '%s\n' "$run_body" | grep -B1 '_cbox_models_hook start' | grep -q 'claude|codex|hermes' \
  || _fail "the hook must be limited to the claude, codex and hermes engines"
_ok "run() calls the model check before dispatching claude, codex or hermes"

acp_body="$(sed -n '/^acp_backend() {/,/^}/p' "$CBOX")"
if printf '%s\n' "$acp_body" | grep -q '_cbox_models_hook'; then
  _fail "the ACP backend path must not run the model check"
fi
_ok "the ACP backend path does not run the check"

grep -q '^  models) shift; models_cmd "\$@";;' "$CBOX" || _fail "models verb missing from the dispatcher"
sed -n '/^usage() {/,/^}/p' "$CBOX" | grep -q 'models check' || _fail "usage lacks models check"
sed -n '/^models_cmd() {/,/^}/p' "$CBOX" | grep -q '_cbox_models_hook check' || _fail "models check does not run the forced check"
_ok "cbox models check is dispatched, documented in usage and forced"

mkdir -p "$TMPBASE/bin" "$TMPBASE/install/lib" "$TMPBASE/eff" "$TMPBASE/home"
cat > "$TMPBASE/bin/python3" <<'PYSTUB'
#!/bin/sh
{
  printf 'ARGV'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
  env | grep -E '^CBOX_(MODEL_|CLAUDE_MODE)' | LC_ALL=C sort
} >> "$STUB_LOG"
exit 0
PYSTUB
chmod +x "$TMPBASE/bin/python3"
: > "$TMPBASE/install/lib/cbox_model_check.py"

eval "$(sed -n '/^_cbox_models_hook() {/,/^}/p' "$CBOX")"

INSTALL_DIR="$TMPBASE/install"
CONF="$INSTALL_DIR/cbox.conf"
COMPOSE=(docker compose -f "$INSTALL_DIR/docker-compose.yml")
export STUB_LOG="$TMPBASE/stub.log"
export PATH="$TMPBASE/bin:$PATH"
MODE_ANSWER=isolated
ROOT="$TMPBASE/proj"
_cbox_effective_mode() { printf '%s' "$MODE_ANSWER"; }
_cbox_workspace_root() { printf '%s' "$ROOT"; }
_cbox_local_effdir_for() { printf '%s' "$TMPBASE/eff"; }

cat > "$TMPBASE/eff/cbox.conf" <<'CONF'
CBOX_MODEL_OPUS=project-opus
CBOX_MODEL_CODEX_SOL=project-sol
CBOX_MODEL_CHECK=off
CBOX_CLAUDE_MODE=volume
CONF
: > "$TMPBASE/eff/docker-compose.yml"
export CBOX_MODEL_OPUS=leaked-opus CBOX_MODEL_FABLE=leaked-fable

: > "$STUB_LOG"
_cbox_models_hook start
grep -qxF "ARGV [$INSTALL_DIR/lib/cbox_model_check.py] [start] [--cbox] [$INSTALL_DIR/cbox] [--] [docker] [compose] [--project-directory] [$TMPBASE/eff] [-f] [$TMPBASE/eff/docker-compose.yml]" "$STUB_LOG" \
  || _fail "isolated hook argv wrong: $(cat "$STUB_LOG")"
grep -qx 'CBOX_MODEL_OPUS=project-opus' "$STUB_LOG" || _fail "project conf did not win over the inherited environment"
grep -qx 'CBOX_MODEL_CODEX_SOL=project-sol' "$STUB_LOG" || _fail "codex pin missing"
grep -qx 'CBOX_MODEL_CHECK=off' "$STUB_LOG" || _fail "check switch missing"
grep -qx 'CBOX_CLAUDE_MODE=volume' "$STUB_LOG" || _fail "claude mode missing"
if grep -q 'leaked' "$STUB_LOG"; then _fail "inherited pins leaked into the checker"; fi
_ok "isolated scope: argv, compose prefix and the project conf values (not the inherited environment) reach the checker"

: > "$STUB_LOG"
_cbox_models_hook check
grep -q '^ARGV .* \[check\] ' "$STUB_LOG" || _fail "forced mode not passed"
_ok "check mode is passed through"

MODE_ANSWER=global
printf 'CBOX_MODEL_HAIKU=global-haiku\n' > "$CONF"
: > "$STUB_LOG"
_cbox_models_hook start
grep -qF "[--] [docker] [compose] [-f] [$INSTALL_DIR/docker-compose.yml]" "$STUB_LOG" || _fail "global compose prefix wrong: $(cat "$STUB_LOG")"
grep -qx 'CBOX_MODEL_HAIKU=global-haiku' "$STUB_LOG" || _fail "global conf value missing"
if grep -q 'project-opus\|leaked' "$STUB_LOG"; then _fail "global scope saw other values"; fi
_ok "global scope uses the global conf and compose"

: > "$STUB_LOG"
mv "$TMPBASE/eff/docker-compose.yml" "$TMPBASE/eff/docker-compose.moved"
MODE_ANSWER=isolated
_cbox_models_hook start
grep -q '\[--\]$' "$STUB_LOG" || _fail "missing compose file must give an empty prefix: $(cat "$STUB_LOG")"
_ok "an isolated project without a compose file passes no compose prefix"

: > "$STUB_LOG"
MODE_ANSWER=none
_cbox_models_hook start
[ ! -s "$STUB_LOG" ] || _fail "unconfigured scope must not run the checker"
MODE_ANSWER=isolated
mv "$TMPBASE/eff/cbox.conf" "$TMPBASE/eff/cbox.conf.moved"
_cbox_models_hook start
[ ! -s "$STUB_LOG" ] || _fail "missing conf must not run the checker"
mv "$TMPBASE/eff/cbox.conf.moved" "$TMPBASE/eff/cbox.conf"
mv "$TMPBASE/install/lib/cbox_model_check.py" "$TMPBASE/install/lib/cbox_model_check.moved"
_cbox_models_hook start
[ ! -s "$STUB_LOG" ] || _fail "missing module must not run the checker"
_ok "no scope, no conf or no module means no checker and no failure"

echo "all ok"
