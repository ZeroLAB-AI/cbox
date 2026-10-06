#!/usr/bin/env bash
set -euo pipefail

unset CBOX_PROFILE CBOX_RENDER_PROFILE _CBOX_RUN_PROFILE HOST_HOME
for _cbox_live_var in $(compgen -v CBOX_); do
  unset "$_cbox_live_var"
done
unset _cbox_live_var

REAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

export HOME="$TMPBASE/home"
WS="$HOME/ws"
mkdir -p "$WS"
INSTALL_DIR="$REAL_DIR"
CONF="$TMPBASE/global.conf"
STORE_ROOT="$HOME/.config/cbox/profiles"
PROJECTS="$HOME/.config/cbox/projects"

STUBBIN="$TMPBASE/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DOCKER_LOG"
case "${1:-}" in
  volume)
    case "${2:-}" in
      ls) [ -z "${STUB_VOLUMES:-}" ] || printf '%s\n' "$STUB_VOLUMES" ;;
    esac
    ;;
  ps)
    case "$*" in
      *label=cbox.kind=isolated*--format*) [ -z "${STUB_LS_ROWS:-}" ] || printf '%b\n' "$STUB_LS_ROWS" ;;
      *label=com.docker.compose.project=*) [ -z "${STUB_SIDECARS:-}" ] || printf '%s\n' "$STUB_SIDECARS" | tr ' ' '\n' ;;
      *label=cbox.profile=*) [ -z "${STUB_PS_PROFILE:-}" ] || printf '%s\n' "$STUB_PS_PROFILE" ;;
    esac
    ;;
  inspect)
    printf '%s\n' "${STUB_PROJECT:-}"
    ;;
  compose)
    case "$*" in
      *" ps -q cbox") [ -z "${STUB_CID:-}" ] || printf '%s\n' "$STUB_CID" ;;
    esac
    ;;
esac
exit 0
EOF
cat > "$STUBBIN/socat" <<'EOF'
#!/usr/bin/env bash
printf 'socat %s\n' "$*" >> "$STUB_DOCKER_LOG"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/xdg-open"
chmod +x "$STUBBIN/docker" "$STUBBIN/socat" "$STUBBIN/xdg-open"
export PATH="$STUBBIN:$PATH"
export STUB_DOCKER_LOG="$TMPBASE/docker.log"
: > "$STUB_DOCKER_LOG"

. "$REAL_DIR/_common.sh"
. "$REAL_DIR/templates/generators.sh"
. "$REAL_DIR/templates/validator_lib.sh"
. "$REAL_DIR/templates/validator_dispatch.sh"
. "$REAL_DIR/lib/cbox-session.sh"
. "$REAL_DIR/lib/cbox-profile.sh"

_cbox_config_in_container() { return 1; }

for _fn in run _cbox_run_dispatch _run_isolated _run_isolated_profile _cbox_profile_require_mount_modes _cbox_run_lockdown_snapshot \
  _cbox_run_egress_lockdown_gate _cbox_scope_creds_ready _cbox_engine_ready _cbox_engine_creds_file \
  _cbox_engine_api_key_present _cbox_volume_file_present _cbox_lockdown_probe_image_tag _cbox_lockdown_vol_name \
  _cbox_lockdown_eff_dir _cbox_run_login_guidance _reap down_project down_project_all _cbox_down_guard_decision \
  _cbox_stop_with_sidecars ls_projects login_claude logs_isolated; do
  _body="$(_extract_fn "$REAL_DIR/cbox" "$_fn")"
  [ -n "$_body" ] || _fail "cannot extract $_fn from cbox"
  eval "$_body"
done
unset _fn _body

_project_eff_from_cwd() { printf '%s' "$FIX_EFF"; }

CALLS="$TMPBASE/calls.log"
_calls_reset() { : > "$CALLS"; }
_calls_reset

_mode() {
  python3 -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"
}

FIX_ROOT="$WS"
FIX_P="$(_cbox_path_hash "$FIX_ROOT")"
FIX_EFF="$PROJECTS/$FIX_P"
mkdir -p "$FIX_EFF"
printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
printf '%s\n' "$FIX_ROOT" > "$FIX_EFF/workspace"
: > "$CONF"

_mkstore() {
  local name="$1"
  mkdir -p "$STORE_ROOT/$name/claude" "$STORE_ROOT/$name/codex" "$STORE_ROOT/$name/usage"
  : > "$STORE_ROOT/$name/codex/auth.json"
  printf '{\n  "schema": 1,\n  "name": "%s",\n  "engines": {"claude": {"status": "empty"}, "codex": {"status": "empty"}}\n}\n' "$name" > "$STORE_ROOT/$name/profile.json"
}

_mkstore work
_mkstore play

_run_cd() {
  RUN_RC=0
  RUN_OUT="$(cd "$FIX_ROOT" && "$@" 2> "$TMPBASE/stderr")" || RUN_RC=$?
  RUN_ERR="$(cat "$TMPBASE/stderr")"
}

_cbox_effective_mode() { printf '%s' "${FIX_MODE:-isolated}"; }
FIX_MODE=isolated

_cbox_session_id_valid() { case "$1" in sess*) return 0 ;; *) return 1 ;; esac; }
_run_isolated_real="$(declare -f _run_isolated)"
_gate_real="$(declare -f _cbox_run_egress_lockdown_gate)"

_run_isolated() { printf 'run_isolated|%s|%s|%s\n' "${_CBOX_RUN_PROFILE:-}" "$1" "$*" >> "$CALLS"; }
_run_global() { printf 'run_global|%s|%s\n' "${_CBOX_RUN_PROFILE:-}" "$*" >> "$CALLS"; }
_cbox_session_run_leg() { printf 'session_leg|%s|%s|%s\n' "${_CBOX_RUN_PROFILE:-}" "$1" "$*" >> "$CALLS"; }

_last_call() { tail -n 1 "$CALLS"; }

_run_cd run --profile work claude -c
[ "$RUN_RC" = 0 ] || _fail "run --profile work claude -c failed: $RUN_ERR"
[ "$(_last_call)" = "run_isolated|work|claude|claude -c" ] || _fail "canonical form: got $(_last_call)"
_ok "flag before the engine: profile work, engine args stay"

_calls_reset
_run_cd run claude --profile work -c
[ "$(_last_call)" = "run_isolated|work|claude|claude -c" ] || _fail "alias strip: got $(_last_call)"
_ok "alias form: --profile after the bin is stripped, engine argv keeps -c"

_calls_reset
_run_cd run --profile=work claude
[ "$(_last_call)" = "run_isolated|work|claude|claude" ] || _fail "--profile=x before engine: got $(_last_call)"
_calls_reset
_run_cd run claude --profile=work --resume abc
[ "$(_last_call)" = "run_isolated|work|claude|claude --resume abc" ] || _fail "--profile=x alias: got $(_last_call)"
_ok "--profile=name accepted before the engine and in the alias position"

_calls_reset
_run_cd run claude -c --profile work
[ "$(_last_call)" = "run_isolated||claude|claude -c --profile work" ] || _fail "non-leading --profile must reach the engine untouched, got $(_last_call)"
_calls_reset
_run_cd run claude --profile work --profile=work -c --profile other
[ "$(_last_call)" = "run_isolated|work|claude|claude -c --profile other" ] || _fail "only the leading run is stripped, got $(_last_call)"
_ok "only the leading run of profile flags after the bin is stripped; later --profile goes to the engine"

_calls_reset
_run_cd run --profile work claude --profile play
[ "$RUN_RC" = 1 ] || _fail "conflicting profile flags must fail"
case "$RUN_ERR" in *"conflicting profile flags"*) ;; *) _fail "conflict message missing: $RUN_ERR" ;; esac
[ ! -s "$CALLS" ] || _fail "a conflicting flag pair must not reach any run path"
_calls_reset
_run_cd run claude --profile
[ "$RUN_RC" = 1 ] || _fail "a bare --profile with no value must fail"
case "$RUN_ERR" in *"needs a profile name"*) ;; *) _fail "missing-value message missing: $RUN_ERR" ;; esac
_ok "conflicting or valueless profile flags fail before any run path"

_calls_reset
_run_cd run --session sess1 --profile work claude
[ "$(_last_call)" = "session_leg|work|sess1|sess1 claude" ] || _fail "session + profile: got $(_last_call)"
_calls_reset
_run_cd run --profile work --session sess1 claude -c
[ "$(_last_call)" = "session_leg|work|sess1|sess1 claude -c" ] || _fail "profile then session: got $(_last_call)"
_ok "--session works together with --profile and the leg sees the profile"

_calls_reset
_run_cd run --profile ghost claude
[ "$RUN_RC" = 1 ] || _fail "unknown profile must fail"
case "$RUN_ERR" in *"does not exist"*"cbox profile add ghost"*) ;; *) _fail "unknown profile message: $RUN_ERR" ;; esac
[ ! -s "$CALLS" ] || _fail "unknown profile must fail before any render or run path"
_calls_reset
_run_cd run claude --profile ghost
[ "$RUN_RC" = 1 ] && [ ! -s "$CALLS" ] || _fail "unknown profile in alias position must fail before any run path"
_ok "unknown profile: error before any run path, with the create hint"

_calls_reset
_run_cd run claude
[ "$(_last_call)" = "run_isolated||claude|claude" ] || _fail "no flag, no conf: default, got $(_last_call)"
printf 'CBOX_PROFILE=play\n' > "$CONF"
_calls_reset
_run_cd run claude
[ "$(_last_call)" = "run_isolated|play|claude|claude" ] || _fail "global conf CBOX_PROFILE=play: got $(_last_call)"
printf 'CBOX_PROFILE=work\n' >> "$FIX_EFF/cbox.conf"
_calls_reset
_run_cd run claude
[ "$(_last_call)" = "run_isolated|work|claude|claude" ] || _fail "project conf must beat global conf: got $(_last_call)"
_calls_reset
_run_cd run --profile play claude
[ "$(_last_call)" = "run_isolated|play|claude|claude" ] || _fail "flag must beat project conf: got $(_last_call)"
_calls_reset
_run_cd run --profile default claude
[ "$(_last_call)" = "run_isolated||claude|claude" ] || _fail "--profile default must run the default path, got $(_last_call)"
_ok "precedence through run: flag > project conf > global conf > default; bare claude follows the project default"
printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
: > "$CONF"

_calls_reset
[ ! -d "$STORE_ROOT/fresh" ] || _fail "fixture: fresh must not exist yet"
_run_cd run --new-profile fresh claude
[ "$RUN_RC" = 0 ] || _fail "--new-profile failed: $RUN_ERR$RUN_OUT"
[ -d "$STORE_ROOT/fresh/claude" ] && [ -f "$STORE_ROOT/fresh/profile.json" ] || _fail "--new-profile must create the store"
[ "$(_last_call)" = "run_isolated|fresh|claude|claude" ] || _fail "--new-profile must run as --profile: got $(_last_call)"
_calls_reset
_run_cd run claude --new-profile fresh -c
[ "$RUN_RC" = 0 ] || _fail "--new-profile on an existing profile failed: $RUN_ERR"
[ "$(_last_call)" = "run_isolated|fresh|claude|claude -c" ] || _fail "--new-profile alias on existing: got $(_last_call)"
_calls_reset
_run_cd run --new-profile Bad-Name claude
[ "$RUN_RC" = 1 ] && [ ! -s "$CALLS" ] || _fail "--new-profile with an invalid name must fail before any run path"
_ok "--new-profile creates the store when missing and then behaves as --profile"

_calls_reset
FIX_MODE=global
_run_cd run --profile work claude
[ "$RUN_RC" = 1 ] || _fail "global scope with a profile must be refused"
case "$RUN_ERR" in *"global scope has no profiles"*) ;; *) _fail "global refusal message: $RUN_ERR" ;; esac
[ ! -s "$CALLS" ] || _fail "global refusal must not reach any run path"
_run_cd run claude
[ "$(_last_call)" = "run_global||claude" ] || _fail "global scope, default profile: got $(_last_call)"
_calls_reset
_run_cd run --profile default claude
[ "$(_last_call)" = "run_global||claude" ] || _fail "global scope, --profile default: got $(_last_call)"
_calls_reset
_run_cd run --new-profile newglobal claude
[ "$RUN_RC" = 1 ] || _fail "--new-profile in the global scope must be refused"
[ ! -e "$STORE_ROOT/newglobal" ] || _fail "--new-profile must validate the scope before it creates a store"
[ ! -s "$CALLS" ] || _fail "refused --new-profile must not reach any run path"
FIX_MODE=isolated
printf 'CBOX_CLAUDE_MODE=volume\n' > "$FIX_EFF/cbox.conf"
_run_cd run --new-profile newvolume claude
[ "$RUN_RC" = 1 ] || _fail "--new-profile in volume mode must be refused"
[ ! -e "$STORE_ROOT/newvolume" ] || _fail "--new-profile must validate the mount modes before it creates a store"
printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
_ok "global scope: non-default profile refused early, default untouched; --new-profile validates before it adds a store"

_marker="$TMPBASE/conf_exec_marker"
printf 'touch %s\nCBOX_PROFILE=work\n: $(touch %s)\n' "$_marker" "$_marker" > "$FIX_EFF/cbox.conf"
_calls_reset
_run_cd run claude
[ ! -e "$_marker" ] || _fail "the profile resolver executed code from a conf file"
[ "$(_last_call)" = "run_isolated|work|claude|claude" ] || _fail "parsed CBOX_PROFILE from a conf with extra lines: got $(_last_call)"
printf "CBOX_PROFILE='play'\n" > "$FIX_EFF/cbox.conf"
_calls_reset
_run_cd run claude
[ "$(_last_call)" = "run_isolated|play|claude|claude" ] || _fail "quoted CBOX_PROFILE value: got $(_last_call)"
printf 'CBOX_PROFILE=work; touch %s\n' "$_marker" > "$FIX_EFF/cbox.conf"
_calls_reset
_run_cd run claude
[ ! -e "$_marker" ] || _fail "the profile resolver executed a trailing command"
[ "$RUN_RC" = 1 ] || _fail "a CBOX_PROFILE value with trailing code must be rejected as an invalid name"
printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
_ok "resolver: CBOX_PROFILE is parsed from conf files, never sourced"

printf 'CBOX_PROFILE=work\n' > "$FIX_EFF/cbox.conf"
_calls_reset
_CBOX_RUN_PROFILE=""
_CBOX_RUN_PROFILE_SET=0
_run_cd _cbox_session_sync_native
grep -q '^run_isolated|work|python3|' "$CALLS" || _fail "session sync must resolve the project profile before _run_isolated, got: $(cat "$CALLS")"
[ -z "$_CBOX_RUN_PROFILE" ] && [ "$_CBOX_RUN_PROFILE_SET" = 0 ] || _fail "session sync leaked _CBOX_RUN_PROFILE"
_CBOX_RUN_PROFILE=play
_CBOX_RUN_PROFILE_SET=1
_calls_reset
_run_cd _cbox_session_sync_native
grep -q '^run_isolated|play|python3|' "$CALLS" || _fail "an explicit run profile must win over the project profile, got: $(cat "$CALLS")"
[ "$_CBOX_RUN_PROFILE" = play ] || _fail "session sync must not clear a profile the caller owns"
_CBOX_RUN_PROFILE=""
_CBOX_RUN_PROFILE_SET=0
printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
_calls_reset
_run_cd _cbox_session_sync_native
grep -q '^run_isolated||python3|' "$CALLS" || _fail "no project profile means the default path, got: $(cat "$CALLS")"
_ok "session sync: profile resolved from the project conf before _run_isolated, caller-owned profile kept, nothing leaks"

_leg_body="$(_extract_fn "$REAL_DIR/lib/cbox-session.sh" _cbox_session_run_leg)"
enter_line="$(printf '%s\n' "$_leg_body" | grep -n '_cbox_session_profile_enter' | head -n1 | cut -d: -f1)"
run_line="$(printf '%s\n' "$_leg_body" | grep -n '_run_isolated "\$engine"' | head -n1 | cut -d: -f1)"
leave_line="$(printf '%s\n' "$_leg_body" | grep -n '_cbox_session_profile_leave' | head -n1 | cut -d: -f1)"
[ -n "$enter_line" ] && [ -n "$run_line" ] && [ -n "$leave_line" ] && [ "$enter_line" -lt "$run_line" ] && [ "$run_line" -lt "$leave_line" ] \
  || _fail "the session leg must enter the profile, call _run_isolated, then leave it"
_ok "session leg: profile entered before _run_isolated and left right after it"

_cfg_volume="$TMPBASE/volume.conf"
printf 'CBOX_CLAUDE_MODE=volume\n' > "$_cfg_volume"
_run_cd _cbox_profile_require_mount_modes "$_cfg_volume" work
[ "$RUN_RC" = 1 ] || _fail "volume mode with a profile must be refused"
case "$RUN_ERR" in *"not supported with CBOX_CLAUDE_MODE or CBOX_CODEX_MODE=volume"*) ;; *) _fail "volume refusal message: $RUN_ERR" ;; esac
printf 'CBOX_CODEX_MODE=volume\n' > "$_cfg_volume"
_run_cd _cbox_profile_require_mount_modes "$_cfg_volume" work
[ "$RUN_RC" = 1 ] || _fail "codex volume mode with a profile must be refused"
_run_cd _cbox_profile_require_mount_modes "$_cfg_volume" ""
[ "$RUN_RC" = 0 ] || _fail "the default profile must not be affected by volume mode"
printf 'CBOX_CLAUDE_MODE=mount\n' > "$_cfg_volume"
_run_cd _cbox_profile_require_mount_modes "$_cfg_volume" work
[ "$RUN_RC" = 0 ] || _fail "mount mode with a profile must pass"
HOST_HOME=/elsewhere _run_cd _cbox_profile_require_mount_modes "$_cfg_volume" work
[ "$RUN_RC" = 1 ] || _fail "a HOST_HOME that differs from HOME must be refused for a profile"
HOST_HOME="$HOME" _run_cd _cbox_profile_require_mount_modes "$_cfg_volume" work
[ "$RUN_RC" = 0 ] || _fail "HOST_HOME equal to HOME must pass"
HOST_HOME=/elsewhere _run_cd _cbox_profile_require_mount_modes "$_cfg_volume" ""
[ "$RUN_RC" = 0 ] || _fail "the default profile must not be affected by HOST_HOME"
_ok "volume mode and a foreign HOST_HOME: refused for a profile, default profile untouched"

unset -f _run_isolated _run_global _cbox_session_run_leg
eval "$_run_isolated_real"

_cbox_workspace_root() { printf '%s' "$FIX_ROOT"; }
_cbox_check_workspace_overlap() { :; }
_first_run_init() { echo FIRST_RUN_INIT >> "$CALLS"; return 1; }
_cbox_manifest_verify_conf_interactive() { printf 'verify|%s\n' "$1" >> "$CALLS"; }
_cbox_global_drift_check_interactive() { printf 'drift|%s\n' "$1" >> "$CALLS"; }
_cbox_run_egress_lockdown_gate() { printf 'gate|%s\n' "$*" >> "$CALLS"; }
_cbox_reg_conf_defaults() { :; }
_cbox_reg_export_vars() { :; }
_cbox_load_machine_scoped_vars() { :; }
_write_mirror() { printf 'mirror|%s|%s\n' "$1" "$2" >> "$CALLS"; }
_cbox_manifest_write_generated() { printf 'manifest|%s\n' "$1" >> "$CALLS"; }
_ensure_image() { printf 'image|%s\n' "$1" >> "$CALLS"; }
_bins_soft() { printf 'bins|%s\n' "$1" >> "$CALLS"; }
_ensure_volumes() { printf 'volumes|%s|%s\n' "$1" "$(cat "$1/workspace")" >> "$CALLS"; }
_gen_effective() {
  printf 'gen|%s|%s\n' "$1" "${CBOX_RENDER_PROFILE:-unset}" >> "$CALLS"
  : > "$1/docker-compose.yml"
  mkdir -p "$1/claude-config"
  printf '{"oauthAccount": {"emailAddress": "first@example.com"}, "userID": "u1"}\n' > "$1/claude-config/.claude.json"
  IMG_TAG=cbox-img:test
}
SESSION_RC=0
_session_run() {
  printf 'session|%s|%s\n' "$1" "$*" >> "$CALLS"
  local st
  st="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["engines"]["claude"]["status"])' "$STORE_ROOT/work/profile.json")"
  printf 'status_before_session|%s\n' "$st" >> "$CALLS"
  printf '{"oauthAccount": {"emailAddress": "second@example.com"}, "userID": "u1"}\n' > "$1/claude-config/.claude.json"
  return "$SESSION_RC"
}

printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
EFF_P="$FIX_EFF/profiles/work"

_calls_reset
_CBOX_RUN_PROFILE=work
SESSION_RC=7
_run_cd _run_isolated claude -c
[ "$RUN_RC" = 7 ] || _fail "profile run must return the session exit status, got $RUN_RC ($RUN_ERR)"
grep -q '^FIRST_RUN_INIT' "$CALLS" && _fail "a fixture with a conf must not trigger first-run init"
expected="verify|$FIX_EFF
drift|$FIX_EFF
gate|claude isolated $FIX_EFF/cbox.conf $FIX_P work
gen|$EFF_P|work
mirror|$FIX_ROOT|$FIX_EFF
manifest|$EFF_P
image|$EFF_P
bins|cbox-img:test
volumes|$EFF_P|$FIX_ROOT
session|$EFF_P|$EFF_P claude -c
status_before_session|ready"
[ "$(cat "$CALLS")" = "$expected" ] || _fail "profile run call sequence differs:
--- got
$(cat "$CALLS")
--- expected
$expected"
_ok "profile run: scope-level steps on the scope eff, render/manifest/image/volumes/session on eff_p, CBOX_RENDER_PROFILE=work reaches _gen_effective"

[ "$(_mode "$EFF_P")" = 700 ] && [ "$(_mode "$FIX_EFF/profiles")" = 700 ] || _fail "eff_p and profiles dir must be 0700"
cmp -s "$FIX_EFF/workspace" "$EFF_P/workspace" || _fail "eff_p workspace must be identical to the scope workspace"
[ -f "$EFF_P/.regen.lock" ] || _fail "the regen lock must live in eff_p"
[ ! -f "$EFF_P/cbox.conf" ] || _fail "eff_p must not get a conf of its own"
_ok "eff_p: 0700, workspace identical, regen lock in eff_p, no conf copy"

second="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["engines"]["claude"]["account"]["oauthAccount"]["emailAddress"])' "$STORE_ROOT/work/profile.json")"
[ "$second" = "second@example.com" ] || _fail "harvest must run after the session too (the failed session still harvests), got $second"
_ok "harvest: once right after regen (before the session) and once after the session, also for a non-zero exit"

_calls_reset
_CBOX_RUN_PROFILE=""
SESSION_RC=0
unset CBOX_RENDER_PROFILE
_cbox_manifest_write_generated() { printf 'manifest|%s\n' "$1" >> "$CALLS"; }
_session_run() { printf 'session|%s\n' "$1" >> "$CALLS"; }
_run_cd _run_isolated claude
[ "$RUN_RC" = 0 ] || _fail "default run failed: $RUN_ERR"
grep -q "^session|$FIX_EFF\$" "$CALLS" || _fail "the default path must run the session on the scope eff, got: $(cat "$CALLS")"
grep -q "^gate|claude isolated $FIX_EFF/cbox.conf $FIX_P \$" "$CALLS" || _fail "default gate call must carry no profile, got: $(cat "$CALLS")"
[ -z "${CBOX_RENDER_PROFILE:-}" ] || _fail "default path must not export CBOX_RENDER_PROFILE"
grep -q "^gen|$FIX_EFF|unset\$" "$CALLS" || _fail "default render must see CBOX_RENDER_PROFILE unset, got: $(cat "$CALLS")"
_ok "default profile: scope eff, no CBOX_RENDER_PROFILE, gate without profile"

_calls_reset
_CBOX_RUN_PROFILE=work
printf 'CBOX_CLAUDE_MODE=volume\n' > "$FIX_EFF/cbox.conf"
_run_cd _run_isolated claude
[ "$RUN_RC" = 1 ] || _fail "a profile run in volume mode must be refused"
grep -q '^gen|' "$CALLS" && _fail "volume refusal must come before any render"
printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
_CBOX_RUN_PROFILE=""
_ok "volume refusal in _run_isolated precedes every render step"

eval "$_gate_real"
_cbox_scope_gate_conf="$TMPBASE/gate.conf"
printf 'CBOX_EGRESS_MODE=on\nCBOX_EGRESS_APPLIED=0\n' > "$_cbox_scope_gate_conf"
mkdir -p "$HOME/.claude" "$HOME/.codex"
printf '{"x":1}\n' > "$HOME/.claude/.credentials.json"
printf '{"x":1}\n' > "$HOME/.codex/auth.json"
_cbox_config_set() { printf 'config_set|%s\n' "$*" >> "$CALLS"; return 0; }
_cbox_config_set_force_global() { printf 'force_global|%s\n' "$*" >> "$CALLS"; return 0; }

_calls_reset
_run_cd _cbox_run_egress_lockdown_gate claude isolated "$_cbox_scope_gate_conf" "$FIX_P" ""
grep -q '^config_set|CBOX_EGRESS_APPLIED=1' "$CALLS" || _fail "default gate with host credentials must apply the lockdown, got: $(cat "$CALLS")"
_calls_reset
_run_cd _cbox_run_egress_lockdown_gate claude isolated "$_cbox_scope_gate_conf" "$FIX_P" work
[ ! -s "$CALLS" ] || _fail "a fresh profile must not count the host credentials, got: $(cat "$CALLS")"
case "$RUN_ERR" in *"applies once you have logged in to claude"*) ;; *) _fail "fresh profile gate message: $RUN_ERR" ;; esac
_ok "gate: a fresh profile is a fresh install - host credentials do not count, the lockdown waits for the login"

printf '{"t":1}\n' > "$STORE_ROOT/work/claude/.credentials.json"
_calls_reset
_run_cd _cbox_run_egress_lockdown_gate claude isolated "$_cbox_scope_gate_conf" "$FIX_P" work
if grep -q '^config_set|' "$CALLS"; then _fail "a profile login must not flip the scope APPLIED flag (the default's), got: $(cat "$CALLS")"; fi
[ "$(_cbox_profile_applied_get "$FIX_EFF/profiles/work" CBOX_EGRESS_APPLIED)" = 1 ] || _fail "profile claude credentials must record the lockdown in the profile's own state"
[ "$(stat -c %a "$FIX_EFF/profiles/work/state/lockdown-applied")" = 600 ] || _fail "profile applied state mode"
[ "$(_cbox_profile_applied_get "$FIX_EFF/profiles/other" CBOX_EGRESS_APPLIED)" = 0 ] || _fail "another profile must not inherit the applied state"
_ok "gate: a profile login records APPLIED in its own eff state, never in the scope conf, and no other profile inherits it"
rm -f "$STORE_ROOT/work/claude/.credentials.json" "$FIX_EFF/profiles/work/state/lockdown-applied"
_calls_reset
printf 'CBOX_EGRESS_MODE=on\nCBOX_EGRESS_APPLIED=1\n' > "$TMPBASE/gate_applied.conf"
_run_cd _cbox_run_egress_lockdown_gate claude isolated "$TMPBASE/gate_applied.conf" "$FIX_P" work
[ ! -s "$CALLS" ] || _fail "a fresh profile must be held until its own login even when the default scope is already applied, got: $(cat "$CALLS")"
case "$RUN_ERR" in *"applies once you have logged in to claude"*) ;; *) _fail "scope-applied fresh profile gate message: $RUN_ERR" ;; esac
_ok "gate: the default scope being applied does not release a fresh profile - held until its own login"
(
  export CBOX_EGRESS_MODE=on CBOX_EGRESS_APPLIED=1 CBOX_NETACCESS_APPLIED=1
  _cbox_profile_apply_env "$FIX_EFF/profiles/work"
  [ "$CBOX_EGRESS_APPLIED" = 0 ] && [ "$CBOX_NETACCESS_APPLIED" = 0 ]
) || _fail "profile apply_env must replace the scope flags with the profile's own (0 when never applied)"
_cbox_profile_applied_set "$FIX_EFF/profiles/work" CBOX_NETACCESS_APPLIED=1
(
  export CBOX_EGRESS_APPLIED=1
  _cbox_profile_apply_env "$FIX_EFF/profiles/work"
  [ "$CBOX_EGRESS_APPLIED" = 0 ] && [ "$CBOX_NETACCESS_APPLIED" = 1 ]
) || _fail "profile apply_env must read each flag from the profile state"
rm -f "$FIX_EFF/profiles/work/state/lockdown-applied"
_ok "profile apply_env exports the profile's own APPLIED flags over the scope's"
_calls_reset
_run_cd _cbox_run_egress_lockdown_gate codex isolated "$_cbox_scope_gate_conf" "$FIX_P" work
[ ! -s "$CALLS" ] || _fail "an empty store codex auth.json is not ready, got: $(cat "$CALLS")"
printf '{"t":1}\n' > "$STORE_ROOT/work/codex/auth.json"
_calls_reset
_run_cd _cbox_run_egress_lockdown_gate codex isolated "$_cbox_scope_gate_conf" "$FIX_P" work
[ "$(_cbox_profile_applied_get "$FIX_EFF/profiles/work" CBOX_EGRESS_APPLIED)" = 1 ] || _fail "profile codex auth.json must record the lockdown in the profile's own state"
rm -f "$FIX_EFF/profiles/work/state/lockdown-applied"
: > "$STORE_ROOT/work/codex/auth.json"
_ok "gate and readiness read the profile store (claude/.credentials.json, codex/auth.json) with the default semantics"

_cbox_engine_ready claude isolated "$FIX_P" mount "$HOME/.claude" "$STORE_ROOT/work/claude" && _fail "engine_ready must check the profile dir, not the host path"
_cbox_engine_ready claude isolated "$FIX_P" mount "$HOME/.claude" "" || _fail "engine_ready without a profile dir keeps the host path semantics"
_ok "engine_ready: profile dir overrides the host path only when given"

[ "$(_cbox_eff_bridge_key "$FIX_EFF")" = "p$FIX_P" ] || _fail "default bridge key must stay p<P>, got $(_cbox_eff_bridge_key "$FIX_EFF")"
[ "$(_cbox_eff_bridge_key "$FIX_EFF/profiles/work")" = "p$FIX_P-work" ] || _fail "profile bridge key must be p<P>-<p>, got $(_cbox_eff_bridge_key "$FIX_EFF/profiles/work")"
for _fn in _session_run shell_isolated; do
  _b="$(_extract_fn "$REAL_DIR/cbox" "$_fn")"
  case "$_b" in *'_cbox_eff_bridge_key "$eff"'*) ;; *) _fail "$_fn must derive the bridge suffix from _cbox_eff_bridge_key" ;; esac
  case "$_b" in *'p$(basename "$eff")'*) _fail "$_fn must not build the bridge suffix from the eff basename" ;; esac
done
_ok "runtime clip/exec bridge suffix: p<P> for the default, p<P>-<p> for a profile (session run and shell)"

mkdir -p "$FIX_EFF/profiles/play"
: > "$FIX_EFF/docker-compose.yml"
: > "$FIX_EFF/profiles/work/docker-compose.yml"
: > "$FIX_EFF/profiles/play/docker-compose.yml"

_compose_p() { printf 'compose|%s|%s\n' "$1" "$*" >> "$CALLS"; case "$2" in ps) printf 'cidX\n' ;; esac; }
_probe() { printf '0'; }
_cbox_manifest_verify_generated() { :; }
_cbox_ollama_gc_scope_networks() { :; }
_cbox_gc_orphan_proxy_networks() { :; }
_project_eff_from_cwd() { printf '%s' "$FIX_EFF"; }

_downs() { grep '^compose|.*|[^|]* down --remove-orphans$' "$CALLS" | cut -d'|' -f2 | sort | tr '\n' ' '; }

_calls_reset
_run_cd down_project_all 0
[ "$RUN_RC" = 0 ] || _fail "down in a project failed: $RUN_ERR"
[ "$(_downs)" = "$FIX_EFF $FIX_EFF/profiles/play $FIX_EFF/profiles/work " ] || _fail "plain down must stop the default and every profile, got: $(_downs)"
_calls_reset
_run_cd down_project_all 0 work
[ "$RUN_RC" = 0 ] || _fail "down --profile work failed: $RUN_ERR"
[ "$(_downs)" = "$FIX_EFF/profiles/work " ] || _fail "down --profile work must stop only that profile, got: $(_downs)"
_calls_reset
_run_cd down_project_all 0 ghost
[ "$RUN_RC" = 0 ] && [ -z "$(_downs)" ] || _fail "down --profile of a never-rendered profile must be a no-op"
case "$RUN_OUT" in *"nothing to stop"*) ;; *) _fail "no-op message missing: $RUN_OUT" ;; esac
_calls_reset
rm -f "$FIX_EFF/docker-compose.yml"
_run_cd down_project_all 0
[ "$(_downs)" = "$FIX_EFF/profiles/play $FIX_EFF/profiles/work " ] || _fail "an unrendered default must be skipped when profiles exist, got: $(_downs)"
: > "$FIX_EFF/docker-compose.yml"
_ok "down: default plus every profile, --profile only one, unrendered default skipped"

_calls_reset
_run_cd _reap "$FIX_EFF"
[ "$(_downs)" = "$FIX_EFF $FIX_EFF/profiles/play $FIX_EFF/profiles/work " ] || _fail "_reap of the scope eff must also reap every profile eff, got: $(_downs)"
_calls_reset
_run_cd _reap "$FIX_EFF/profiles/work"
[ "$(_downs)" = "$FIX_EFF/profiles/work " ] || _fail "_reap of a profile eff reaps only itself, got: $(_downs)"
_ok "_reap iterates eff/profiles/*"

_stop_case() {
  local project="$1"
  : > "$STUB_DOCKER_LOG"
  STUB_PROJECT="$project" STUB_SIDECARS="s1 s2" _run_cd _cbox_stop_with_sidecars cidP
}
_stop_case "cbox-pdeadbeef0011-work"
grep -q '^stop s1 s2$' "$STUB_DOCKER_LOG" || _fail "profile compose project must stop every sidecar, got: $(cat "$STUB_DOCKER_LOG")"
_stop_case "cbox-pdeadbeef0011"
grep -q '^stop s1 s2$' "$STUB_DOCKER_LOG" || _fail "scope compose project must still stop every sidecar"
_stop_case "cbox-pdeadbeef0011-Work"
grep -q '^stop cidP$' "$STUB_DOCKER_LOG" && ! grep -q '^stop s1' "$STUB_DOCKER_LOG" || _fail "an invalid profile suffix must fall back to stopping only the container, got: $(cat "$STUB_DOCKER_LOG")"
_stop_case "cbox-pdeadbeef0011-"
grep -q '^stop cidP$' "$STUB_DOCKER_LOG" && ! grep -q '^stop s1' "$STUB_DOCKER_LOG" || _fail "a dangling dash must not match"
_stop_case "other-project"
grep -q '^stop cidP$' "$STUB_DOCKER_LOG" && ! grep -q '^stop s1' "$STUB_DOCKER_LOG" || _fail "a foreign project must not match"
_ok "stop regex: cbox-p<12hex>-<profile> accepted, malformed and foreign project names refused"

: > "$STUB_DOCKER_LOG"
STUB_LS_ROWS='aaaaaaaaaaaa\tbbbbbbbbbbbb\t/srv/one\t\ncccccccccccc\tdddddddddddd\t/srv/one\twork' _run_cd ls_projects
printf '%s\n' "$RUN_OUT" | grep -Eq '^aaaaaaaaaaaa +bbbbbbbbbbbb +/srv/one$' || _fail "ls: default container row must stay unchanged, got: $RUN_OUT"
printf '%s\n' "$RUN_OUT" | grep -Eq '^cccccccccccc +dddddddddddd +/srv/one \[work\]$' || _fail "ls: profile container must print <root> [<p>], got: $RUN_OUT"
grep -q 'cbox.profile' "$STUB_DOCKER_LOG" || _fail "ls must ask docker for the cbox.profile label"
_ok "ls prints <root> [<profile>] for containers carrying a cbox.profile label"

_login_url='https://claude.ai/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A45454%2Fcallback'
_socat_exec_addr() { printf 'socat_addr|%s\n' "$*" >> "$CALLS"; printf 'EXEC:stub'; }
_calls_reset
_run_cd login_claude --profile work "$_login_url"
[ "$RUN_RC" = 0 ] || _fail "login --profile work failed: $RUN_OUT $RUN_ERR"
grep -q "^socat_addr|docker compose --project-directory $EFF_P -f $EFF_P/docker-compose.yml exec -T cbox socat - TCP:127.0.0.1:45454\$" "$CALLS" || _fail "login --profile must bridge into the profile compose, got: $(cat "$CALLS")"
_calls_reset
_run_cd login_claude "$_login_url" --profile=work
grep -q "^socat_addr|docker compose --project-directory $EFF_P " "$CALLS" || _fail "login with the flag after the url, got: $(cat "$CALLS")"
_calls_reset
_run_cd login_claude "$_login_url"
grep -q "^socat_addr|docker compose --project-directory $FIX_EFF -f $FIX_EFF/docker-compose.yml " "$CALLS" || _fail "login without a profile must bridge into the scope compose, got: $(cat "$CALLS")"
_calls_reset
_run_cd login_claude --profile ghost "$_login_url"
[ "$RUN_RC" = 1 ] && [ ! -s "$CALLS" ] || _fail "login --profile of an unknown profile must fail before the bridge"
rm -f "$EFF_P/docker-compose.yml"
_run_cd login_claude --profile work "$_login_url"
[ "$RUN_RC" = 1 ] || _fail "login --profile of a never-started profile must fail"
case "$RUN_OUT" in *"has no container config"*) ;; *) _fail "login never-started message: $RUN_OUT" ;; esac
: > "$EFF_P/docker-compose.yml"
FIX_MODE=global
_run_cd login_claude --profile work "$_login_url"
[ "$RUN_RC" = 1 ] || _fail "login --profile in global scope must be refused"
FIX_MODE=isolated
_ok "login: bridge targets the profile compose, flag position free, unknown/never-started/global refused"

_calls_reset
_run_cd logs_isolated work --tail 5
grep -q "^compose|$EFF_P|$EFF_P logs --tail 5\$" "$CALLS" || _fail "logs --profile must read the profile compose, got: $(cat "$CALLS")"
_calls_reset
_run_cd logs_isolated "" -f
grep -q "^compose|$FIX_EFF|$FIX_EFF logs -f\$" "$CALLS" || _fail "logs without a profile must read the scope compose, got: $(cat "$CALLS")"
_ok "logs --profile selects the profile compose"

mkdir -p "$PROJECTS/aaaaaaaaaaaa/profiles/work/claude-config" "$PROJECTS/bbbbbbbbbbbb/profiles/work" "$PROJECTS/bbbbbbbbbbbb/profiles/play"
printf 'x\n' > "$PROJECTS/aaaaaaaaaaaa/profiles/work/claude-config/.claude.json"
: > "$STUB_DOCKER_LOG"
STUB_VOLUMES='cbox-paaaaaaaaaaaa-work-hermes-home
cbox-pbbbbbbbbbbbb-work-hermes-home
cbox-pbbbbbbbbbbbb-play-hermes-home
cbox-paaaaaaaaaaaa-hermes-home
cbox-paaaaaaaaaaaa-work-x-hermes-home
cbox-paaaaaaaaaaaa-work-claude
unrelated-work-hermes-home' _run_cd _cbox_profile_rm work --yes
[ "$RUN_RC" = 0 ] || _fail "profile rm failed: $RUN_ERR$RUN_OUT"
[ ! -e "$PROJECTS/aaaaaaaaaaaa/profiles/work" ] && [ ! -e "$PROJECTS/bbbbbbbbbbbb/profiles/work" ] || _fail "rm must remove eff/profiles/work in every project"
[ -d "$PROJECTS/bbbbbbbbbbbb/profiles/play" ] || _fail "rm must not touch other profiles"
[ ! -e "$STORE_ROOT/work" ] || _fail "rm must remove the store"
grep -q '^volume rm cbox-paaaaaaaaaaaa-work-hermes-home$' "$STUB_DOCKER_LOG" || _fail "rm must remove the hermes volume of every scope"
grep -q '^volume rm cbox-pbbbbbbbbbbbb-work-hermes-home$' "$STUB_DOCKER_LOG" || _fail "rm must remove the second scope hermes volume"
[ "$(grep -c '^volume rm ' "$STUB_DOCKER_LOG")" = 2 ] || _fail "rm must remove only the profile hermes volumes, got: $(grep '^volume rm ' "$STUB_DOCKER_LOG")"
_ok "profile rm: eff/profiles/<p> across projects and the cbox-p<P>-<p>-hermes-home volumes, nothing else"

_mkstore work
: > "$STUB_DOCKER_LOG"
STUB_PS_PROFILE=runningcid _run_cd _cbox_profile_rm work --yes
[ "$RUN_RC" = 1 ] || _fail "rm of a profile with a running container must be refused"
! grep -q '^volume rm' "$STUB_DOCKER_LOG" || _fail "a refused rm must not touch volumes"
[ -d "$STORE_ROOT/work" ] || _fail "a refused rm must keep the store"
_ok "profile rm refuses while a container of the profile runs, before any deletion"

_arm() {
  awk -v verb="$1" '$0 == "  " verb ")" , $0 == "    ;;"' "$REAL_DIR/cbox"
}
for _verb in down shell logs; do
  _arm_text="$(_arm "$_verb")"
  [ -n "$_arm_text" ] || _fail "cannot extract the $_verb dispatch arm from cbox"
  eval "_dispatch_$_verb() { case $_verb in
$_arm_text
esac; }"
done
unset _verb _arm_text

usage() { echo USAGE; exit 1; }
die() { echo "DIE $*"; exit 1; }
die_no_conf() { echo NOCONF; exit 1; }
down_project_all() { printf 'down_all|%s|%s\n' "$1" "${2:-}" >> "$CALLS"; }
down_project() { printf 'down_one|%s\n' "$1" >> "$CALLS"; }
down() { printf 'down_global|%s\n' "$1" >> "$CALLS"; }
shell_isolated() { printf 'shell_iso|%s\n' "${1:-}" >> "$CALLS"; }
shell() { printf 'shell_global\n' >> "$CALLS"; }
logs_isolated() { printf 'logs_iso|%s|%s\n' "${1:-}" "$*" >> "$CALLS"; }
logs() { printf 'logs_global|%s\n' "$*" >> "$CALLS"; }

_disp() {
  local fn="$1"
  shift
  _calls_reset
  RUN_RC=0
  RUN_OUT="$(cd "$FIX_ROOT" && "$fn" "$@" 2> "$TMPBASE/stderr")" || RUN_RC=$?
  RUN_ERR="$(cat "$TMPBASE/stderr")"
}
_mkstore work

_disp _dispatch_down down
[ "$(cat "$CALLS")" = "down_all|0|" ] || _fail "down: got $(cat "$CALLS")"
_disp _dispatch_down down --force --profile work
[ "$(cat "$CALLS")" = "down_all|1|work" ] || _fail "down --force --profile work: got $(cat "$CALLS")"
_disp _dispatch_down down --profile=work
[ "$(cat "$CALLS")" = "down_all|0|work" ] || _fail "down --profile=work: got $(cat "$CALLS")"
_disp _dispatch_down down --profile default
[ "$(cat "$CALLS")" = "down_one|0" ] || _fail "down --profile default must stop only the default, got $(cat "$CALLS")"
_disp _dispatch_down down --profile Bad
[ "$RUN_RC" != 0 ] && [ ! -s "$CALLS" ] || _fail "down --profile with an invalid name must fail"
_disp _dispatch_down down --profile
[ "$RUN_RC" != 0 ] && [ ! -s "$CALLS" ] || _fail "down --profile without a name must fail"
_disp _dispatch_down down --bogus
[ "$RUN_RC" != 0 ] && [ ! -s "$CALLS" ] || _fail "down with an unknown option must fail"
FIX_MODE=global
_disp _dispatch_down down --profile work
[ "$RUN_RC" != 0 ] && [ ! -s "$CALLS" ] || _fail "global down --profile work must be refused"
_disp _dispatch_down down --force
[ "$(cat "$CALLS")" = "down_global|1" ] || _fail "global down must stay unchanged, got $(cat "$CALLS")"
FIX_MODE=isolated
_ok "dispatch down: all / --profile p / --profile=p / --profile default / --force; malformed flags and global refused"

_disp _dispatch_shell shell --profile work
[ "$(cat "$CALLS")" = "shell_iso|work" ] || _fail "shell --profile work: got $(cat "$CALLS")"
_disp _dispatch_shell shell
[ "$(cat "$CALLS")" = "shell_iso|" ] || _fail "shell without a profile: got $(cat "$CALLS")"
_disp _dispatch_shell shell --profile ghost
[ "$RUN_RC" != 0 ] && [ ! -s "$CALLS" ] || _fail "shell --profile of an unknown profile must fail"
printf 'CBOX_PROFILE=work\n' >> "$FIX_EFF/cbox.conf"
_disp _dispatch_shell shell
[ "$(cat "$CALLS")" = "shell_iso|work" ] || _fail "shell must follow the project default profile, got $(cat "$CALLS")"
printf 'CBOX_FIXTURE=1\n' > "$FIX_EFF/cbox.conf"
_disp _dispatch_logs logs --profile work --tail 3 -f
[ "$(cat "$CALLS")" = "logs_iso|work|work --tail 3 -f" ] || _fail "logs --profile work: got $(cat "$CALLS")"
_disp _dispatch_logs logs --tail 3
[ "$(cat "$CALLS")" = "logs_iso|| --tail 3" ] || _fail "logs without a profile: got $(cat "$CALLS")"
FIX_MODE=global
_disp _dispatch_logs logs --profile work
[ "$RUN_RC" != 0 ] && [ ! -s "$CALLS" ] || _fail "global logs --profile work must be refused"
_disp _dispatch_logs logs -f
[ "$(cat "$CALLS")" = "logs_global|-f" ] || _fail "global logs must stay unchanged, got $(cat "$CALLS")"
FIX_MODE=isolated
_ok "dispatch shell/logs: --profile selects the profile, the project default applies without a flag, other args pass through"

_e2e_setup() {
  E2E_BASE="$(mktemp -d "$TMPBASE/e2e.XXXXXX")"
  mkdir -p "$E2E_BASE/home/ws"
  E2E_HOME="$E2E_BASE/home"
  E2E_WS="$E2E_HOME/ws"
  E2E_P="$(printf '%s' "$(cd "$E2E_WS" && pwd -P)" | _cbox_sha256 | cut -c1-12)"
  E2E_EFF="$E2E_HOME/.config/cbox/projects/$E2E_P"
  mkdir -p "$E2E_EFF/profiles/work" "$E2E_HOME/.config/cbox/profiles/work"
  printf 'CBOX_FIXTURE=1\n' > "$E2E_EFF/cbox.conf"
  printf '%s\n' "$(cd "$E2E_WS" && pwd -P)" > "$E2E_EFF/workspace"
  : > "$E2E_EFF/docker-compose.yml"
  : > "$E2E_EFF/profiles/work/docker-compose.yml"
  printf 'compose=%s\n' "$(_cbox_sha256 "$E2E_EFF/docker-compose.yml")" > "$E2E_EFF/manifest.sha256"
  printf 'compose=%s\n' "$(_cbox_sha256 "$E2E_EFF/profiles/work/docker-compose.yml")" > "$E2E_EFF/profiles/work/manifest.sha256"
}
_e2e() {
  : > "$STUB_DOCKER_LOG"
  E2E_RC=0
  E2E_OUT="$(cd "$E2E_WS" && HOME="$E2E_HOME" bash "$REAL_DIR/cbox" "$@" </dev/null 2>&1)" || E2E_RC=$?
}

_e2e_setup
_e2e down
[ "$E2E_RC" = 0 ] || _fail "e2e down failed: $E2E_OUT"
[ "$(grep -c ' down --remove-orphans$' "$STUB_DOCKER_LOG")" = 2 ] || _fail "e2e plain down must stop the default and the profile, got: $(cat "$STUB_DOCKER_LOG")"
grep -q "profiles/work/docker-compose.yml down --remove-orphans\$" "$STUB_DOCKER_LOG" || _fail "e2e plain down must stop the profile compose"
_e2e shell --profile work
[ "$E2E_RC" = 0 ] || _fail "e2e shell --profile work failed: $E2E_OUT"
grep -q "profiles/work/docker-compose.yml exec -T cbox /entrypoint.sh bash\$" "$STUB_DOCKER_LOG" || _fail "e2e shell --profile must exec into the profile compose, got: $(cat "$STUB_DOCKER_LOG")"
! grep -q "^compose --project-directory $E2E_EFF -f" "$STUB_DOCKER_LOG" || _fail "e2e shell --profile must not touch the default compose"
_ok "real cbox script: down stops default plus profile, shell --profile execs into the profile compose only"

_e2e restart
[ "$E2E_RC" = 0 ] || _fail "e2e restart failed: $E2E_OUT"
[ "$(grep -c ' down --remove-orphans$' "$STUB_DOCKER_LOG")" = 2 ] || _fail "restart in a project must also stop the profile containers, got: $(cat "$STUB_DOCKER_LOG")"
grep -q "profiles/work/docker-compose.yml down --remove-orphans\$" "$STUB_DOCKER_LOG" || _fail "restart must stop the profile compose"
_ok "real cbox script: restart in a project recreates the default and every profile container"

for f in "$REAL_DIR/cbox" "$REAL_DIR/lib/cbox-profile.sh" "$REAL_DIR/lib/test_profile_run.sh"; do
  bash -n "$f" || _fail "bash -n $f"
done
_ok "bash -n on the touched shell files"

echo "PASS: all profile run tests"
