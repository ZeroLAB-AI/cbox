#!/usr/bin/env bash
set -euo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

for _v in $(compgen -v CBOX_); do
  unset "$_v"
done
unset OLLAMA_NUM_PARALLEL _v

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

HOME="$TMPBASE/home"
export HOME
FAKE="$TMPBASE/install"
mkdir -p "$HOME" "$FAKE" "$TMPBASE/elsewhere"
ln -s "$REAL/_common.sh" "$FAKE/_common.sh"
ln -s "$REAL/lib" "$FAKE/lib"
ln -s "$REAL/templates" "$FAKE/templates"
ln -s "$REAL/etc" "$FAKE/etc"
ELSEWHERE="$(cd "$TMPBASE/elsewhere" && pwd -P)"

CBOX_FNS="$TMPBASE/cbox_fns.sh"
awk '
  /^_cbox_machine_scoped_vars\(\) \{/ { infunc=1 }
  /^_cbox_load_machine_scoped_vars\(\) \{/ { infunc=1 }
  /^_cbox_layered_recovery_hint\(\) \{/ { infunc=1 }
  infunc { print }
  infunc && /^\}/ { infunc=0 }
' "$REAL/cbox" > "$CBOX_FNS"
awk '/^_cbox_config_load_sections\(\) \{/{f=1} f{print} f && /^config_cmd\(\) \{/{exit}' "$REAL/cbox" > "$TMPBASE/cbox_config_block.sh"
sed -i '$ d' "$TMPBASE/cbox_config_block.sh"
cat "$TMPBASE/cbox_config_block.sh" >> "$CBOX_FNS"
for fn in _cbox_machine_scoped_vars _cbox_load_machine_scoped_vars _cbox_layered_recovery_hint \
  _cbox_config_set_isolated _cbox_config_whitelist _cbox_config_write_pending _cbox_config_print_report; do
  grep -q "^${fn}() {" "$CBOX_FNS" || _fail "extraction from cbox failed: $fn missing"
done

HARNESS="$TMPBASE/harness.sh"
cat > "$HARNESS" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$1"
shift
. "$REAL_DIR/lib/cbox-setup.sh"
. "$CBOX_FNS"
_cbox_sha256() {
  if [ "$#" -gt 0 ]; then
    sha256sum "$1" | cut -d' ' -f1
  else
    sha256sum | cut -d' ' -f1
  fi
}
_cbox_realpath() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
_cbox_ismount() { return 1; }
_cbox_flock() { return 0; }
_cbox_machine_scoped_vars() { cat "$H_MACHINE_VARS"; }
_cbox_config_whitelist() { cat "$H_WHITELIST"; }
_cbox_config_is_whitelisted() { grep -qxF -- "$1" "$H_WHITELIST"; }
load_generators() {
  . "$INSTALL_DIR/templates/generators.sh"
  regen_all() { :; }
}
if [ "${H_STUB_TTY:-1}" = 1 ]; then
  require_tty() { return 0; }
fi
_cbox_config_in_container() { return 1; }
HAVE_GLOBAL_CONF=1
_gen_effective() {
  mkdir -p "$1/generated"
  printf 'regen root=%s\n' "$2" >> "$1/generated/regen.log"
}
mark() { printf '%s\n' "$1" >> "$H_MARK"; }
step_python() { mark python; CBOX_VENV_MODE=volume; CBOX_VENV_PATH="$CBOX_VENV_PATH"; }
step_gpu() { mark gpu; if [ "${H_GPU:-0}" = 1 ]; then CBOX_GPU=1; fi; }
step_apt_extra() { mark apt-extra; CBOX_APT_EXTRA="curl"; }
step_ollama() { mark ollama; CBOX_OLLAMA_MODE=on; }
step_bashrc() { mark bashrc; }
step_mode() { mark mode; }
if [ "${H_REAL_WS:-0}" != 1 ]; then
  step_workspaces() { mark workspaces; }
else
  path_input() {
    local line
    PATH_VALUE=""
    IFS= read -r line < <(sed -n "$((H_WS_IDX + 1))p" "$H_WS_INPUT") || return 1
    H_WS_IDX=$((H_WS_IDX + 1))
    [ -n "$line" ] || return 1
    PATH_VALUE="$line"
    return 0
  }
  reserved_path_conflict() { return 1; }
  H_WS_IDX=0
fi
step_agents() { mark agents; }
ask_yn() { [ "${H_YES:-0}" = 1 ]; }
have_docker() { return 1; }
user_dir_precreate_host() { :; }
run_local() { printf 'LOCAL root=%s fg=%s reset=%s\n' "$1" "${2:-}" "${3:-}"; }
run_local_menu() { printf 'MENU root=%s\n' "$1"; }
mode="$1"
shift
case "$mode" in
  mkglobal)
    conf_defaults
    conf_save
    ;;
  mkproj)
    root="$1"
    load_generators
    conf_load
    CBOX_MODE=isolated
    CBOX_WORKSPACES="$root"
    CBOX_WORKDIR="$root"
    eff="$(_cbox_local_effdir_for "$root")"
    mkdir -p "$eff/generated"
    _cbox_reg_conf_write_whitelist "$eff/cbox.base" 1
    : > "$eff/cbox.override"
    conf_save "$eff/cbox.conf"
    _cbox_strip_machine_scoped_vars "$eff/cbox.conf"
    _cbox_conf_set_tpl_sha "$eff/cbox.conf"
    printf '%s\n' "$root" > "$eff/workspace"
    _cbox_manifest_write "$eff" "$root" "$eff/cbox.conf"
    _cbox_manifest_write_generated "$eff"
    printf '%s\n' "$eff"
    ;;
  main)
    _cbox_setup_main "$@"
    ;;
esac
HARNESS_EOF

H_MACHINE_VARS="$TMPBASE/machine.vars"
(
  set +eu
  INSTALL_DIR="$FAKE"
  . "$REAL/templates/sections.sh"
  for s in "${SECTIONS[@]}"; do
    if [ "$(sec_get SEC_SCOPE "$s")" = machine ]; then
      for v in $(sec_get SEC_VARS "$s"); do
        printf '%s\n' "$v"
      done
    fi
  done
) > "$H_MACHINE_VARS"
[ -s "$H_MACHINE_VARS" ] || _fail "fixture: no machine-scoped variables found in the registry"
H_WHITELIST="$TMPBASE/whitelist.vars"
(
  set +eu
  INSTALL_DIR="$FAKE"
  . "$REAL/templates/sections.sh"
  . "$CBOX_FNS"
  _cbox_config_whitelist
) > "$H_WHITELIST"
grep -qx 'CBOX_VENV_MODE' "$H_WHITELIST" || _fail "fixture: the real whitelist lacks CBOX_VENV_MODE"

H_STUB_TTY=1
H_YES=0
H_GPU=0
H_MARK="$TMPBASE/step.marks"
H_RC=0

_h() {
  local cwd="$1"
  shift
  H_RC=0
  : > "$H_MARK"
  env -i HOME="$HOME" PATH="$PATH" INSTALL_DIR="$FAKE" REAL_DIR="$REAL" CBOX_FNS="$CBOX_FNS" \
    H_STUB_TTY="$H_STUB_TTY" H_YES="$H_YES" H_GPU="$H_GPU" H_MARK="$H_MARK" \
    H_REAL_WS="${H_REAL_WS:-0}" H_WS_INPUT="${H_WS_INPUT:-/dev/null}" \
    H_MACHINE_VARS="$H_MACHINE_VARS" H_WHITELIST="$H_WHITELIST" \
    bash "$HARNESS" "$cwd" "$@" > "$TMPBASE/h.out" 2> "$TMPBASE/h.err" || H_RC=$?
}

_sha() { sha256sum "$1" | awk '{print $1}'; }

_effdir() {
  printf '%s/.config/cbox/projects/%s' "$HOME" "$(printf '%s' "$1" | sha256sum | cut -c1-12)"
}

_mkroot() {
  local d="$TMPBASE/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  (cd "$d" && pwd -P)
}

_h "$ELSEWHERE" mkglobal
[ "$H_RC" = 0 ] || _fail "fixture: global conf creation failed: $(cat "$TMPBASE/h.err")"
GLOBAL_CONF="$FAKE/cbox.conf"
[ -f "$GLOBAL_CONF" ] || _fail "fixture: no global cbox.conf at $GLOBAL_CONF"
grep -q '^CBOX_VENV_MODE=' "$GLOBAL_CONF" || _fail "fixture: global conf lacks CBOX_VENV_MODE"
GLOBAL_SHA="$(_sha "$GLOBAL_CONF")"

P="$(_mkroot proj)"
EFF="$(_effdir "$P")"
_h "$ELSEWHERE" mkproj "$P"
[ "$H_RC" = 0 ] || _fail "fixture: mkproj failed: $(cat "$TMPBASE/h.err")"
[ "$(cat "$TMPBASE/h.out")" = "$EFF" ] || _fail "fixture: effective dir mismatch: $(cat "$TMPBASE/h.out") vs $EFF"
cp -a "$EFF" "$TMPBASE/pristine"

_reset_proj() {
  rm -rf "$EFF" "$P/.cbox"
  cp -a "$TMPBASE/pristine" "$EFF"
}

_assert_global_untouched() {
  [ "$(_sha "$GLOBAL_CONF")" = "$GLOBAL_SHA" ] || _fail "$1: the global cbox.conf changed"
  [ ! -e "$FAKE/pending.apply" ] || _fail "$1: pending.apply appeared next to the global conf"
  [ ! -e "$GLOBAL_CONF.bak" ] || _fail "$1: a global cbox.conf.bak appeared"
}

_layered_ok() {
  (
    set +eu
    INSTALL_DIR="$FAKE"
    . "$REAL/_common.sh"
    . "$REAL/templates/sections.sh"
    . "$REAL/templates/generators.sh"
    . "$REAL/templates/conf_lib.sh"
    _cbox_sha256() { sha256sum "$1" | cut -d' ' -f1; }
    _cbox_layered_require_ok "$1"
  )
}

_assert_updated_project() {
  local label="$1"
  [ "$H_RC" = 0 ] || _fail "$label: rc=$H_RC: $(cat "$TMPBASE/h.err")"
  [ "$(cat "$H_MARK")" = python ] || _fail "$label: expected exactly the python step to run, got: $(cat "$H_MARK")"
  grep -qx 'CBOX_VENV_MODE=volume' "$EFF/cbox.override" || _fail "$label: cbox.override lacks CBOX_VENV_MODE=volume"
  [ "$(wc -l < "$EFF/cbox.override" | tr -d ' ')" = 1 ] || _fail "$label: cbox.override holds more than the changed key: $(cat "$EFF/cbox.override")"
  grep -qx 'CBOX_VENV_MODE=volume' "$EFF/cbox.conf" || _fail "$label: effective cbox.conf lacks CBOX_VENV_MODE=volume"
  grep -qx "regen root=$P" "$EFF/generated/regen.log" || _fail "$label: effective config was not regenerated"
  grep -qx 'python=recreate' "$EFF/pending.apply" || _fail "$label: pending.apply lacks python=recreate"
  grep -q 'global cbox.conf was not touched' "$TMPBASE/h.out" || _fail "$label: success note missing"
  [ "$(_sha "$EFF/cbox.base")" = "$(_sha "$TMPBASE/pristine/cbox.base")" ] || _fail "$label: cbox.base must stay untouched"
  _assert_global_untouched "$label"
  _layered_ok "$EFF" || _fail "$label: layered config no longer verifies after the update"
}

_h "$P" main update python --local
_assert_updated_project "cwd root, update <section> --local"
_ok "update <section> --local, root from cwd: override + conf written, regen + pending staged, global and base untouched"

if grep -q '^CBOX_VENV_PATH=' "$EFF/cbox.override"; then
  _fail "unchanged keys: CBOX_VENV_PATH was assigned the same value by the step and must not be written to cbox.override"
fi
grep -q '^CBOX_VENV_PATH=' "$EFF/cbox.conf" || _fail "fixture sanity: CBOX_VENV_PATH missing from the effective conf"
_ok "unchanged keys inside a changed section are not written to cbox.override"

_reset_proj
_h "$ELSEWHERE" main update python --local "$P"
_assert_updated_project "explicit root, update <section> --local <root>"
_ok "update <section> --local <root> from an unrelated cwd"

_reset_proj
_h "$ELSEWHERE" main --local "$P" update python
_assert_updated_project "--local <root> update <section>"
_ok "--local <root> update <section> (reverse order, explicit root)"

_reset_proj
_h "$P" main --local update python
_assert_updated_project "--local update <section> cwd root"
_ok "--local update <section> with the root taken from cwd"

_reset_proj
mkdir -p "$P/sub/dir"
_h "$P/sub/dir" main update python --local
_assert_updated_project "cwd in a project subdirectory"
_ok "cwd inside a project subdirectory resolves the git toplevel as the project root"

_reset_proj
CONF_SHA="$(_sha "$EFF/cbox.conf")"
OVR_SHA="$(_sha "$EFF/cbox.override")"
_h "$P" main update gpu --local
[ "$H_RC" = 0 ] || _fail "no-op update: rc=$H_RC: $(cat "$TMPBASE/h.err")"
grep -q 'no changes' "$TMPBASE/h.out" || _fail "no-op update: missing the no changes note"
[ "$(_sha "$EFF/cbox.conf")" = "$CONF_SHA" ] || _fail "no-op update: effective cbox.conf changed"
[ "$(_sha "$EFF/cbox.override")" = "$OVR_SHA" ] || _fail "no-op update: cbox.override changed"
[ ! -e "$EFF/generated/regen.log" ] || _fail "no-op update: regen ran without a change"
[ ! -e "$EFF/pending.apply" ] || _fail "no-op update: pending.apply staged without a change"
_assert_global_untouched "no-op update"
_ok "unchanged section: nothing written, nothing regenerated, nothing staged"

_reset_proj
H_YES=1
H_GPU=1
_h "$P" main update python --local
H_YES=0
H_GPU=0
[ "$H_RC" = 0 ] || _fail "python follow-up: rc=$H_RC: $(cat "$TMPBASE/h.err")"
[ "$(tr '\n' ' ' < "$H_MARK")" = "python gpu " ] || _fail "python follow-up: expected python then gpu steps, got: $(cat "$H_MARK")"
grep -qx 'CBOX_GPU=1' "$EFF/cbox.override" || _fail "python follow-up: gpu change did not land in cbox.override"
grep -qx 'CBOX_VENV_MODE=volume' "$EFF/cbox.override" || _fail "python follow-up: python change did not land in cbox.override"
_ok "python follow-up prompt offers the gpu section and both changes land in the override"

_reset_proj
_h "$P" main update apt-extra --local
[ "$H_RC" = 0 ] || _fail "apt-extra: rc=$H_RC: $(cat "$TMPBASE/h.err")"
grep -qx 'CBOX_APT_EXTRA=curl' "$EFF/cbox.override" || _fail "apt-extra: override missing"
grep -qx 'apt-extra=rebuild' "$EFF/pending.apply" || _fail "apt-extra: pending.apply must carry the registry apply class (rebuild)"
grep -q 'rebuild' "$TMPBASE/h.out" || _fail "apt-extra: the apply report must name the rebuild class"
_assert_global_untouched "apt-extra"
_ok "apply class and apply report follow cbox config set semantics (apt-extra -> rebuild)"

EX1="$(_mkroot extra1)"
EX2="$(_mkroot extra2)"
WS_INPUT="$TMPBASE/ws.input"
_ws_update() {
  local cwd="$1"
  shift
  H_REAL_WS=1
  H_WS_INPUT="$WS_INPUT"
  _h "$cwd" main update workspaces --local "$@"
  H_REAL_WS=0
  H_WS_INPUT=/dev/null
}

_reset_proj
printf '%s\n%s\n' "$EX1" "$EX2" > "$WS_INPUT"
_ws_update "$P"
[ "$H_RC" = 0 ] || _fail "workspaces: rc=$H_RC: $(cat "$TMPBASE/h.err")"
grep -q 'is always mounted first and is fixed' "$TMPBASE/h.out" || _fail "workspaces: the step must show the project root as fixed: $(cat "$TMPBASE/h.out")"
grep -qxF "$(printf 'CBOX_WORKSPACES=%q' "$P $EX1 $EX2")" "$EFF/cbox.override" || _fail "workspaces: override must hold root-first root+extras, got: $(cat "$EFF/cbox.override")"
grep -qxF "$(printf 'CBOX_WORKSPACES=%q' "$P $EX1 $EX2")" "$EFF/cbox.conf" || _fail "workspaces: effective conf must hold root-first root+extras"
grep -qx "CBOX_WORKDIR=$P" "$EFF/cbox.conf" || _fail "workspaces: the project workdir must stay the root"
grep -qx 'workspaces=recreate' "$EFF/pending.apply" || _fail "workspaces: pending.apply lacks workspaces=recreate"
grep -qx "regen root=$P" "$EFF/generated/regen.log" || _fail "workspaces: effective config was not regenerated"
[ "$(_sha "$EFF/cbox.base")" = "$(_sha "$TMPBASE/pristine/cbox.base")" ] || _fail "workspaces: cbox.base must stay untouched"
_assert_global_untouched "workspaces"
_layered_ok "$EFF" || _fail "workspaces: layered config no longer verifies"
_ok "update workspaces --local: root fixed and first, extras stored in the override and conf, global and base untouched"

printf '%s\n' "$EX1" > "$WS_INPUT"
_ws_update "$P"
[ "$H_RC" = 0 ] || _fail "workspaces shrink: rc=$H_RC: $(cat "$TMPBASE/h.err")"
grep -qxF "$(printf 'CBOX_WORKSPACES=%q' "$P $EX1")" "$EFF/cbox.override" || _fail "workspaces shrink: override not updated: $(cat "$EFF/cbox.override")"
_ok "update workspaces --local again replaces the extras"

: > "$WS_INPUT"
_ws_update "$P"
[ "$H_RC" = 0 ] || _fail "workspaces clear: rc=$H_RC: $(cat "$TMPBASE/h.err")"
if grep -q '^CBOX_WORKSPACES=' "$EFF/cbox.override"; then
  _fail "workspaces clear: dropping every extra must remove the override key, got: $(cat "$EFF/cbox.override")"
fi
grep -qx "CBOX_WORKSPACES=$P" "$EFF/cbox.conf" || _fail "workspaces clear: effective conf must be the root alone"
_ok "update workspaces --local with no extras returns the project to its root alone"

_reset_proj
mkdir -p "$P/sub"
printf '%s\n%s\n' "$P/sub" "$P" > "$WS_INPUT"
_ws_update "$P"
[ "$H_RC" = 0 ] || _fail "workspaces overlap: rc=$H_RC: $(cat "$TMPBASE/h.err")"
grep -q 'overlaps the project root, ignored' "$TMPBASE/h.out" || _fail "workspaces overlap: expected the overlap note: $(cat "$TMPBASE/h.out")"
grep -q 'no changes' "$TMPBASE/h.out" || _fail "workspaces overlap: nothing valid was entered, expected no changes"
_ok "update workspaces --local ignores a folder that overlaps the project root"

NOPROJ="$(_mkroot noproj)"
_h "$NOPROJ" main update python --local
[ "$H_RC" != 0 ] || _fail "missing project: expected failure"
grep -q "no effective config for $NOPROJ" "$TMPBASE/h.err" || _fail "missing project: error does not name the root: $(cat "$TMPBASE/h.err")"
grep -q "cbox setup --local $NOPROJ" "$TMPBASE/h.err" || _fail "missing project: error does not point to cbox setup --local: $(cat "$TMPBASE/h.err")"
[ ! -s "$H_MARK" ] || _fail "missing project: a step ran before the check"
_assert_global_untouched "missing project"
_h "$ELSEWHERE" main --local "$NOPROJ" update python
[ "$H_RC" != 0 ] || _fail "missing project (explicit root): expected failure"
grep -q "cbox setup --local $NOPROJ" "$TMPBASE/h.err" || _fail "missing project (explicit root): wrong error: $(cat "$TMPBASE/h.err")"
_h "$ELSEWHERE" main update python --local "$TMPBASE/does-not-exist"
[ "$H_RC" != 0 ] || _fail "bad root: expected failure"
grep -q 'not a directory' "$TMPBASE/h.err" || _fail "bad root: missing not a directory message"
_ok "missing project / bad root: clear error pointing to cbox setup --local, no step runs"

_expect_refusal() {
  local sec="$1" want="$2"
  _h "$P" main update "$sec" --local
  [ "$H_RC" != 0 ] || _fail "refusal $sec: expected failure"
  grep -q "$want" "$TMPBASE/h.err" || _fail "refusal $sec: message lacks '$want': $(cat "$TMPBASE/h.err")"
  grep -q 'run without --local' "$TMPBASE/h.err" || _fail "refusal $sec: message does not point to running without --local"
  [ ! -s "$H_MARK" ] || _fail "refusal $sec: the step ran before the refusal"
}

MACHINE_SECTIONS="$(
  set +eu
  . "$REAL/templates/sections.sh"
  for s in "${SECTIONS[@]}"; do
    if [ "$(sec_get SEC_SCOPE "$s")" = machine ]; then
      printf '%s\n' "$s"
    fi
  done
)"
[ -n "$MACHINE_SECTIONS" ] || _fail "registry: no machine-scoped sections found"
for sec in $MACHINE_SECTIONS; do
  _expect_refusal "$sec" "machine-scoped"
done
_ok "every machine-scoped section is refused with --local ($(printf '%s' "$MACHINE_SECTIONS" | tr '\n' ' '))"

_expect_refusal mode "pinned"
_ok "mode is refused with --local (pinned by the derive)"

for sec in bashrc mcp-servers codex-progress agents codex-mcp claude-md settings hooks; do
  _expect_refusal "$sec" "host-wide files"
done
_ok "host-wide sections are refused with --local"

_h "$P" main --local update mode
[ "$H_RC" != 0 ] || _fail "refusal via the --local first order: expected failure"
grep -q 'pinned' "$TMPBASE/h.err" || _fail "refusal via the --local first order: message lacks pinned"
_h "$P" main update nosuchsection --local
[ "$H_RC" != 0 ] || _fail "unknown section: expected failure"
grep -q "unknown section 'nosuchsection'" "$TMPBASE/h.err" || _fail "unknown section: missing message"
_ok "refusals hold in both argument orders; unknown sections are rejected"

_reset_proj
H_STUB_TTY=0
_h "$P" main update python --local
H_STUB_TTY=1
[ "$H_RC" != 0 ] || _fail "tty gate: update --local must refuse without a terminal"
grep -q 'requires an interactive terminal' "$TMPBASE/h.err" || _fail "tty gate: wrong message: $(cat "$TMPBASE/h.err")"
[ ! -s "$H_MARK" ] || _fail "tty gate: a step ran"
_ok "update --local refuses without a terminal (non-TTY side only; the positive TTY path is stubbed here and is a host step)"

_reset_proj
printf 'CBOX_VENV_MODE=host\n' >> "$EFF/cbox.override"
_h "$P" main update python --local
[ "$H_RC" != 0 ] || _fail "drifted layered config: expected failure"
grep -q 'drifted' "$TMPBASE/h.err" || _fail "drifted layered config: missing drift message: $(cat "$TMPBASE/h.err")"
[ ! -s "$H_MARK" ] || _fail "drifted layered config: a step ran"
_ok "an override edited outside cbox is refused before any question is asked"

_reset_proj
CONF_SHA="$(_sha "$EFF/cbox.conf")"
GLOBAL_BEFORE_PLAIN="$(_sha "$GLOBAL_CONF")"
_h "$P" main update python
[ "$H_RC" = 0 ] || _fail "plain update in a project: rc=$H_RC: $(cat "$TMPBASE/h.err")"
grep -qx 'CBOX_VENV_MODE=volume' "$GLOBAL_CONF" || _fail "plain update: the global conf was not updated"
[ "$(_sha "$GLOBAL_CONF")" != "$GLOBAL_BEFORE_PLAIN" ] || _fail "plain update: the global conf did not change"
[ "$(_sha "$EFF/cbox.conf")" = "$CONF_SHA" ] || _fail "plain update: the project conf must not change"
[ ! -s "$EFF/cbox.override" ] || _fail "plain update: the project override must not change"
[ "$(grep -c 'keeps its own config' "$TMPBASE/h.out")" = 1 ] || _fail "plain update in a project: expected exactly one note line, got: $(grep -c 'keeps its own config' "$TMPBASE/h.out")"
grep 'keeps its own config' "$TMPBASE/h.out" | grep -q -- '--local' || _fail "plain update note does not mention --local"
_ok "plain update stays global, leaves the project alone and prints one note line inside a project"

_h "$ELSEWHERE" main update apt-extra
[ "$H_RC" = 0 ] || _fail "plain update outside a project: rc=$H_RC: $(cat "$TMPBASE/h.err")"
if grep -q 'keeps its own config' "$TMPBASE/h.out"; then
  _fail "plain update outside a project must not print the project note"
fi
_h "$P" main update ollama
[ "$H_RC" = 0 ] || _fail "plain update of a machine section in a project: rc=$H_RC: $(cat "$TMPBASE/h.err")"
if grep -q 'keeps its own config' "$TMPBASE/h.out"; then
  _fail "plain update of a machine-scoped section must not print the project note"
fi
_ok "no note outside a project or for machine-scoped sections"

_h "$ELSEWHERE" main --local
grep -qx "LOCAL root=$ELSEWHERE fg=0 reset=0" "$TMPBASE/h.out" || _fail "--local: $(cat "$TMPBASE/h.out") $(cat "$TMPBASE/h.err")"
_h "$ELSEWHERE" main --local /some/root
grep -qx 'LOCAL root=/some/root fg=0 reset=0' "$TMPBASE/h.out" || _fail "--local <root>: $(cat "$TMPBASE/h.out")"
_h "$ELSEWHERE" main --local /some/root --from-global
grep -qx 'LOCAL root=/some/root fg=1 reset=0' "$TMPBASE/h.out" || _fail "--local <root> --from-global: $(cat "$TMPBASE/h.out")"
_h "$ELSEWHERE" main --local --from-global --reset
grep -qx "LOCAL root=$ELSEWHERE fg=1 reset=1" "$TMPBASE/h.out" || _fail "--local --from-global --reset: $(cat "$TMPBASE/h.out")"
_h "$ELSEWHERE" main --local /some/root menu
grep -qx 'MENU root=/some/root' "$TMPBASE/h.out" || _fail "--local <root> menu: $(cat "$TMPBASE/h.out")"
_h "$ELSEWHERE" main --from-global
grep -qx "LOCAL root=$ELSEWHERE fg=1 reset=" "$TMPBASE/h.out" || _fail "--from-global: $(cat "$TMPBASE/h.out")"
_ok "existing --local forms still parse (default root, explicit root, --from-global, --reset, menu, bare --from-global)"

_expect_usage() {
  local label="$1"
  shift
  _h "$ELSEWHERE" main "$@"
  [ "$H_RC" != 0 ] || _fail "usage $label: expected failure"
  grep -q 'usage' "$TMPBASE/h.err" || _fail "usage $label: no usage message: $(cat "$TMPBASE/h.err")"
  [ ! -s "$H_MARK" ] || _fail "usage $label: a step ran"
}
_expect_usage "--local update without a section" --local update
_expect_usage "--local update with a flag as section" --local update --reset
_expect_usage "--local root menu update" --local /r menu update python
_expect_usage "--local update with --from-global" --local /r --from-global update python
_expect_usage "update section --local two roots" update python --local /a /b
_expect_usage "update with a leading flag" update --local
_expect_usage "--local two roots" --local /a /b
_ok "malformed forms die with a usage line before any step runs"

_h "$ELSEWHERE" main --help
[ "$H_RC" = 0 ] || _fail "--help: rc=$H_RC"
grep -qF 'update [<section> [--local [<root>]]]' "$TMPBASE/h.out" || _fail "--help: usage line lacks update <section> --local"
grep -qF -- '--local [<root>] update <section>' "$TMPBASE/h.out" || _fail "--help: usage line lacks --local update <section>"
grep -q 'update <section>: edit that section' "$TMPBASE/h.out" || _fail "--help: explanatory line missing"
_ok "--help lists both new forms"

echo "all setup update --local checks passed"
