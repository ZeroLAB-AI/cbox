#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

DRIFT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_global_drift_check_interactive)"
TRUNC_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_global_drift_truncate)"
DECL_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_global_drift_declined_file)"
[ -n "$DRIFT_FN" ] || _fail "cannot extract _cbox_global_drift_check_interactive from cbox"
[ -n "$TRUNC_FN" ] || _fail "cannot extract _cbox_global_drift_truncate from cbox"
[ -n "$DECL_FN" ] || _fail "cannot extract _cbox_global_drift_declined_file from cbox"

grep -q '_cbox_global_drift_check_interactive "\$eff" "\$root"' "$INSTALL_DIR/cbox" \
  || _fail "the run path must call _cbox_global_drift_check_interactive"
run_block="$(_extract_fn "$INSTALL_DIR/cbox" _run_isolated)"
printf '%s\n' "$run_block" | grep -q '_cbox_global_drift_check_interactive "\$eff" "\$root"' \
  || _fail "_run_isolated must call the global drift check"
shell_block="$(_extract_fn "$INSTALL_DIR/cbox" shell_isolated)"
printf '%s\n' "$shell_block" | grep -q '_cbox_global_drift_check_interactive "\$scope_eff" "\$root"' \
  || _fail "shell_isolated must call the global drift check"
_ok "wiring: both _run_isolated and shell_isolated call the global drift check"

command -v script >/dev/null 2>&1 || _fail "script(1) not found - required for the PTY harness"

for _v in $(compgen -v CBOX_); do
  unset "$_v"
done
unset OLLAMA_NUM_PARALLEL _v

MACH_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_machine_scoped_vars)"
SECT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_config_load_sections)"
[ -n "$MACH_FN" ] && [ -n "$SECT_FN" ] || _fail "cannot extract the machine-scoped helpers from cbox"

FNFILE="$TMPBASE/fns.sh"
printf '%s\n' "$DRIFT_FN" > "$FNFILE"
printf '%s\n' "$TRUNC_FN" >> "$FNFILE"
printf '%s\n' "$DECL_FN" >> "$FNFILE"
printf '%s\n' "$MACH_FN" >> "$FNFILE"
printf '%s\n' "$SECT_FN" >> "$FNFILE"

HARNESS="$TMPBASE/harness.sh"
cat > "$HARNESS" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -u
. "$INSTALL_DIR_REAL/_common.sh" >/dev/null 2>&1
. "$INSTALL_DIR_REAL/templates/generators.sh" >/dev/null 2>&1
. "$INSTALL_DIR_REAL/templates/conf_lib.sh" >/dev/null 2>&1
. "$FN_FILE"
_cbox_flock() { return 0; }
die() { echo "die: $*" >&2; exit 1; }
_cbox_rebless_local() {
  : > "$MARKER_FILE"
  if [ "${REBLESS_REAL:-0}" = 1 ]; then
    bash "$DERIVE_HARNESS" derive "$1" || return 1
  fi
  return 0
}
HAVE_GLOBAL_CONF=1
INSTALL_DIR="$GLOBAL_DIR"
_cbox_global_drift_check_interactive "$1" "$2"
HARNESS_EOF
chmod +x "$HARNESS"

GLOBAL="$TMPBASE/global"
mkdir -p "$GLOBAL"
for _f in _common.sh lib templates etc; do
  ln -s "$INSTALL_DIR/$_f" "$GLOBAL/$_f"
done
: > "$GLOBAL/entrypoint.sh"
: > "$GLOBAL/install-bins.sh"
HOME="$TMPBASE/home"
mkdir -p "$HOME/.claude/hooks"
export HOME
GLOBAL_WS="'/global/ws1 /global/ws2'"

_write_global() {
  printf 'CBOX_MODE=global\nCBOX_WORKSPACES=%s\nCBOX_WORKDIR=/global/ws1\nCBOX_APT_EXTRA=%s\n' "$GLOBAL_WS" "$1" > "$GLOBAL/cbox.conf"
}

_write_global_local_model() {
  printf 'CBOX_MODE=global\nCBOX_WORKSPACES=%s\nCBOX_LOCAL_MODEL_URL=%s\n' "$GLOBAL_WS" "$1" > "$GLOBAL/cbox.conf"
}

DERIVE_HARNESS="$TMPBASE/derive.sh"
cat > "$DERIVE_HARNESS" <<'DERIVE_EOF'
#!/usr/bin/env bash
set -eu
INSTALL_DIR="$GLOBAL_DIR"
. "$INSTALL_DIR/lib/cbox-setup.sh"
. "$FN_FILE"
_cbox_flock() { return 0; }
_cbox_ismount() { return 1; }
load_generators() {
  . "$INSTALL_DIR/templates/generators.sh"
  _cbox_resolve_base_digest() { printf 'sha256:%064d' 0; }
  gen_managed_settings() { :; }
  gen_session_entry_into() { :; }
  gen_image_inputs() { printf 'inputs\n' > "$1/image.inputs"; }
  _cbox_image_hash() { printf 'hash'; }
  _cbox_image_tag() { printf 'tag'; }
  gen_dockerfile_into() { :; }
  gen_env_file_into() { :; }
  gen_compose_isolated() { printf 'compose %s\n' "$CBOX_WORKSPACES" > "$1/docker-compose.yml"; }
  _write_mirror() { :; }
}
mode="$1"
shift
case "$mode" in
  derive)
    run_local "$1" 1 "${2:-0}"
    ;;
  setovr)
    root="$1"
    eff="$(_cbox_local_effdir_for "$root")"
    load_generators
    _cbox_override_set "$eff" "$2" "$3"
    _cbox_manifest_write_keep_generated "$eff" "$root" "$eff/cbox.conf"
    ;;
esac
DERIVE_EOF
export GLOBAL_DIR="$GLOBAL"

set +eu
. "$INSTALL_DIR/_common.sh" >/dev/null 2>&1
. "$INSTALL_DIR/templates/generators.sh" >/dev/null 2>&1
. "$INSTALL_DIR/templates/conf_lib.sh" >/dev/null 2>&1
set -eu

_derive_base() {
  local root="$1" key="${2:-}" val="${3:-}"
  _derive "$root"
  if [ -n "$key" ]; then
    bash "$DERIVE_HARNESS" setovr "$root" "$key" "$val" >/dev/null 2>&1 || _fail "setting the override $key failed"
  fi
}

export INSTALL_DIR_REAL="$INSTALL_DIR"
export GLOBAL_DIR="$GLOBAL"
export FN_FILE="$FNFILE"
export DERIVE_HARNESS

_eff_for() {
  printf '%s/.config/cbox/projects/%s' "$HOME" "$(printf '%s' "$1" | sha256sum | cut -c1-12)"
}

_derive() {
  local root="$1"
  shift
  bash "$DERIVE_HARNESS" derive "$root" "$@" >/dev/null 2>"$TMPBASE/derive.err" || _fail "real derive of $root failed: $(cat "$TMPBASE/derive.err")"
}

_run_pty() {
  local eff="$1" root="$2" input="$3" logfile="$4" marker="$5"
  export MARKER_FILE="$marker"
  rm -f "$marker"
  local cmd
  cmd="bash $(printf '%q' "$HARNESS") $(printf '%q' "$eff") $(printf '%q' "$root")"
  script -qec "$cmd" /dev/null < "$input" > "$logfile" 2>&1 || true
}

_run_plain() {
  local eff="$1" root="$2"
  bash -c '
    set -u
    INSTALL_DIR_REAL="'"$INSTALL_DIR_REAL"'"
    . "$INSTALL_DIR_REAL/_common.sh" >/dev/null 2>&1
    . "$INSTALL_DIR_REAL/templates/generators.sh" >/dev/null 2>&1
    . "$INSTALL_DIR_REAL/templates/conf_lib.sh" >/dev/null 2>&1
    . "'"$FNFILE"'"
    _cbox_flock() { return 0; }
    die() { echo "die: $*" >&2; exit 1; }
    HAVE_GLOBAL_CONF=1
    INSTALL_DIR="'"$GLOBAL"'"
    _cbox_global_drift_check_interactive "'"$eff"'" "'"$root"'"
  ' 2>&1
}

INPUT_Y="$TMPBASE/input_y"
printf 'y\n' > "$INPUT_Y"
INPUT_N="$TMPBASE/input_n"
printf 'n\n' > "$INPUT_N"

ROOT1="$TMPBASE/ws1"
mkdir -p "$ROOT1"
EFF1="$(_eff_for "$ROOT1")"
_write_global old
_derive_base "$ROOT1"
_write_global new
LOG1="$TMPBASE/log1"
MARK1="$TMPBASE/marker1"
_run_pty "$EFF1" "$ROOT1" "$INPUT_Y" "$LOG1" "$MARK1"
grep -q 'CBOX_APT_EXTRA: old -> new' "$LOG1" || _fail "changed key must be offered with base -> global values, got: $(cat "$LOG1")"
grep -q 'Pull these global changes into' "$LOG1" || _fail "the pull prompt must be shown"
[ -f "$MARK1" ] || _fail "answering y must call the rebless path"
_ok "changed global key is offered and pulled on y"

ROOT2="$TMPBASE/ws2"
mkdir -p "$ROOT2"
EFF2="$(_eff_for "$ROOT2")"
_write_global old
_derive_base "$ROOT2"
_write_global changed1
LOG2A="$TMPBASE/log2a"
MARK2="$TMPBASE/marker2"
_run_pty "$EFF2" "$ROOT2" "$INPUT_N" "$LOG2A" "$MARK2"
grep -q 'CBOX_APT_EXTRA: old -> changed1' "$LOG2A" || _fail "first decline must still show the prompt"
[ ! -f "$MARK2" ] || _fail "answering n must not call the rebless path"
[ -f "$EFF2/.global_drift_declined" ] || _fail "declining must record a digest for the current global state"
_ok "declined offer is recorded"

LOG2B="$TMPBASE/log2b"
_run_pty "$EFF2" "$ROOT2" "$INPUT_N" "$LOG2B" "$MARK2"
! grep -q 'Pull these global changes' "$LOG2B" \
  || _fail "the same global digest must not be asked about twice, got: $(cat "$LOG2B")"
_ok "declined on N and not asked again for the same global digest"

_write_global changed2
LOG2C="$TMPBASE/log2c"
_run_pty "$EFF2" "$ROOT2" "$INPUT_N" "$LOG2C" "$MARK2"
grep -q 'CBOX_APT_EXTRA: old -> changed2' "$LOG2C" || _fail "a further global change must prompt again, got: $(cat "$LOG2C")"
_ok "asked again after a further global change"

ROOT3="$TMPBASE/ws3"
mkdir -p "$ROOT3"
EFF3="$(_eff_for "$ROOT3")"
_write_global old
_derive_base "$ROOT3" CBOX_APT_EXTRA mine
_write_global theirs
out3="$(_run_plain "$EFF3" "$ROOT3")"
[ -z "$out3" ] || _fail "a key the project already overrides must not be offered, got: $out3"
_ok "overridden key not offered"

ROOT4="$TMPBASE/ws4"
mkdir -p "$ROOT4"
EFF4="$(_eff_for "$ROOT4")"
_write_global_local_model "http://old:11434"
_derive_base "$ROOT4"
_write_global_local_model "http://new:11434"
out4="$(_run_plain "$EFF4" "$ROOT4")"
[ -z "$out4" ] || _fail "a machine-scoped key must never be offered as a global change, got: $out4"
_ok "machine-scoped key ignored"

ROOT5="$TMPBASE/ws5"
mkdir -p "$ROOT5"
EFF5="$(_eff_for "$ROOT5")"
_write_global old
_derive_base "$ROOT5"
_write_global newval
out5="$(_run_plain "$EFF5" "$ROOT5")"
case "$out5" in
  *"cbox setup --local $ROOT5 --from-global"*) ;;
  *) _fail "no-tty must print one stderr note naming the re-derive command, got: $out5" ;;
esac
[ ! -f "$EFF5/.global_drift_declined" ] || _fail "a no-tty note must not silently record a decline"
_ok "no-TTY note names the re-derive command and does not record a decline"

ROOT7="$TMPBASE/ws7"
mkdir -p "$ROOT7"
EFF7="$(_eff_for "$ROOT7")"
_write_global old
_derive_base "$ROOT7"
grep -qx "CBOX_WORKSPACES=$ROOT7" "$EFF7/cbox.base" || _fail "a real derive must write the project root alone into cbox.base, got: $(grep '^CBOX_WORKSPACES=' "$EFF7/cbox.base")"
grep -qx "CBOX_WORKSPACES=$ROOT7" "$EFF7/cbox.conf" || _fail "a real derive must write the project root alone into cbox.conf"
if grep -q '/global/ws' "$EFF7/cbox.base" "$EFF7/cbox.conf" "$EFF7/docker-compose.yml"; then
  _fail "the global workspaces list must never reach an isolated project"
fi
RAW_KV="$TMPBASE/raw.kv"
_cbox_conf_kv "$GLOBAL/cbox.conf" "$RAW_KV"
raw_changed="$(_cbox_conf_changed_keys "$EFF7/cbox.base" "$RAW_KV" | tr '\n' ' ')"
case "$raw_changed" in
  *CBOX_MODE*CBOX_WORKSPACES*CBOX_WORKDIR*|*CBOX_MODE*CBOX_WORKDIR*CBOX_WORKSPACES*) ;;
  *) _fail "test premise: a real derive's base must differ from the raw global conf on mode/workspaces/workdir (the old loop trigger), got: $raw_changed" ;;
esac
_ok "real derive: base and conf hold the project root alone, the global list never leaks, and the loop trigger keys do differ from the raw global"

out7a="$(_run_plain "$EFF7" "$ROOT7")"
[ -z "$out7a" ] || _fail "a freshly derived project must show no drift (the old loop), got: $out7a"
_ok "drift loop gone: a project just derived from an unchanged global is silent"

_write_global newer
LOG7="$TMPBASE/log7"
MARK7="$TMPBASE/marker7"
REBLESS_REAL=1
export REBLESS_REAL
_run_pty "$EFF7" "$ROOT7" "$INPUT_Y" "$LOG7" "$MARK7"
REBLESS_REAL=0
export REBLESS_REAL
grep -q 'CBOX_APT_EXTRA: old -> newer' "$LOG7" || _fail "the real pull must offer only the genuine change, got: $(cat "$LOG7")"
if grep -q 'CBOX_MODE\|CBOX_WORKSPACES\|CBOX_WORKDIR' "$LOG7"; then
  _fail "mode/workspaces/workdir are never inherited and must never be offered, got: $(cat "$LOG7")"
fi
grep -qx 'CBOX_APT_EXTRA=newer' "$EFF7/cbox.base" || _fail "answering y must run the real derive and refresh cbox.base"
out7b="$(_run_plain "$EFF7" "$ROOT7")"
[ -z "$out7b" ] || _fail "after answering y the next run must stay silent (the prompt used to repeat forever), got: $out7b"
_ok "drift loop gone: after y the real re-derive leaves the next run silent, and the offer never listed mode/workspaces/workdir"

_derive "$ROOT7"
out7c="$(_run_plain "$EFF7" "$ROOT7")"
[ -z "$out7c" ] || _fail "a second real derive must stay silent, got: $out7c"
_derive "$ROOT7" 1
out7d="$(_run_plain "$EFF7" "$ROOT7")"
[ -z "$out7d" ] || _fail "a --reset derive must stay silent, got: $out7d"
_ok "drift loop gone: repeated and --reset derives all leave the check silent"

ROOT6="$TMPBASE/ws6"
EFF6="$(_eff_for "$ROOT6")"
mkdir -p "$EFF6" "$ROOT6"
rc=0
out6="$(_run_plain "$EFF6" "$ROOT6")" || rc=$?
[ "$rc" -eq 0 ] || _fail "a project without cbox.base must not fail, rc=$rc"
[ -z "$out6" ] || _fail "a project without cbox.base must stay silent, got: $out6"
_ok "old project without a stored base works (no crash, no prompt)"

LONGVAL="$(printf 'a%.0s' $(seq 1 90))"
trunc_out="$(bash -c '. "'"$FNFILE"'"; _cbox_global_drift_truncate "'"$LONGVAL"'"')"
[ "${#trunc_out}" -eq 60 ] || _fail "truncated value must be 60 chars, got ${#trunc_out}"
case "$trunc_out" in
  *...) ;;
  *) _fail "truncated value must end with ..." ;;
esac
_ok "long values truncate to 60 chars"

grep -q '_run_global "\$bin" "\$@"' "$INSTALL_DIR/cbox" \
  || _fail "sanity: _run_global must still exist untouched"
_ok "global scope run path is untouched by this feature"

echo "PASS: global profile drift pull-in"
