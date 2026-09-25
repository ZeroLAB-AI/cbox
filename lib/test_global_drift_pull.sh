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
printf '%s\n' "$shell_block" | grep -q '_cbox_global_drift_check_interactive "\$eff" "\$root"' \
  || _fail "shell_isolated must call the global drift check"
_ok "wiring: both _run_isolated and shell_isolated call the global drift check"

command -v script >/dev/null 2>&1 || _fail "script(1) not found - required for the PTY harness"

FNFILE="$TMPBASE/fns.sh"
printf '%s\n' "$DRIFT_FN" > "$FNFILE"
printf '%s\n' "$TRUNC_FN" >> "$FNFILE"
printf '%s\n' "$DECL_FN" >> "$FNFILE"

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
  return 0
}
HAVE_GLOBAL_CONF=1
INSTALL_DIR="$GLOBAL_DIR"
_cbox_global_drift_check_interactive "$1" "$2"
HARNESS_EOF
chmod +x "$HARNESS"

GLOBAL="$TMPBASE/global"
mkdir -p "$GLOBAL"

_write_global() {
  printf 'CBOX_MODE=global\nCBOX_APT_EXTRA=%s\n' "$1" > "$GLOBAL/cbox.conf"
}

_write_global_local_model() {
  printf 'CBOX_MODE=global\nCBOX_LOCAL_MODEL_URL=%s\n' "$1" > "$GLOBAL/cbox.conf"
}

set +eu
. "$INSTALL_DIR/_common.sh" >/dev/null 2>&1
. "$INSTALL_DIR/templates/generators.sh" >/dev/null 2>&1
. "$INSTALL_DIR/templates/conf_lib.sh" >/dev/null 2>&1
set -eu

_derive_base() {
  local eff="$1" override_content="${2:-}"
  mkdir -p "$eff"
  _cbox_conf_kv "$GLOBAL/cbox.conf" "$eff/cbox.base"
  : > "$eff/cbox.override"
  [ -z "$override_content" ] || printf '%s\n' "$override_content" > "$eff/cbox.override"
}

export INSTALL_DIR_REAL="$INSTALL_DIR"
export GLOBAL_DIR="$GLOBAL"
export FN_FILE="$FNFILE"

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

EFF1="$TMPBASE/eff1"
ROOT1="$TMPBASE/ws1"
mkdir -p "$ROOT1"
_write_global old
_derive_base "$EFF1" ""
_write_global new
LOG1="$TMPBASE/log1"
MARK1="$TMPBASE/marker1"
_run_pty "$EFF1" "$ROOT1" "$INPUT_Y" "$LOG1" "$MARK1"
grep -q 'CBOX_APT_EXTRA: old -> new' "$LOG1" || _fail "changed key must be offered with base -> global values, got: $(cat "$LOG1")"
grep -q 'Pull these global changes into' "$LOG1" || _fail "the pull prompt must be shown"
[ -f "$MARK1" ] || _fail "answering y must call the rebless path"
_ok "changed global key is offered and pulled on y"

EFF2="$TMPBASE/eff2"
ROOT2="$TMPBASE/ws2"
mkdir -p "$ROOT2"
_write_global old
_derive_base "$EFF2" ""
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

EFF3="$TMPBASE/eff3"
ROOT3="$TMPBASE/ws3"
mkdir -p "$ROOT3"
_write_global old
_derive_base "$EFF3" "CBOX_APT_EXTRA=mine"
_write_global theirs
out3="$(_run_plain "$EFF3" "$ROOT3")"
[ -z "$out3" ] || _fail "a key the project already overrides must not be offered, got: $out3"
_ok "overridden key not offered"

EFF4="$TMPBASE/eff4"
ROOT4="$TMPBASE/ws4"
mkdir -p "$ROOT4"
_write_global_local_model "http://old:11434"
_derive_base "$EFF4" ""
_write_global_local_model "http://new:11434"
out4="$(_run_plain "$EFF4" "$ROOT4")"
[ -z "$out4" ] || _fail "a machine-scoped key must never be offered as a global change, got: $out4"
_ok "machine-scoped key ignored"

EFF5="$TMPBASE/eff5"
ROOT5="$TMPBASE/ws5"
mkdir -p "$ROOT5"
_write_global old
_derive_base "$EFF5" ""
_write_global newval
out5="$(_run_plain "$EFF5" "$ROOT5")"
case "$out5" in
  *"cbox setup --local $ROOT5 --from-global"*) ;;
  *) _fail "no-tty must print one stderr note naming the re-derive command, got: $out5" ;;
esac
[ ! -f "$EFF5/.global_drift_declined" ] || _fail "a no-tty note must not silently record a decline"
_ok "no-TTY note names the re-derive command and does not record a decline"

EFF6="$TMPBASE/eff6"
ROOT6="$TMPBASE/ws6"
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
