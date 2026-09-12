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

source "$INSTALL_DIR/lib/portable.sh"
source "$INSTALL_DIR/templates/sections.sh"
source "$INSTALL_DIR/templates/conf_lib.sh"

OLLAMA_VARS="CBOX_OLLAMA_MODE CBOX_OLLAMA_IMAGE CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE CBOX_OLLAMA_STORE_PATH CBOX_OLLAMA_PORT CBOX_OLLAMA_NUM_PARALLEL CBOX_OLLAMA_CONTEXT_LENGTH CBOX_OLLAMA_FLASH_ATTENTION CBOX_OLLAMA_KV_CACHE_TYPE CBOX_OLLAMA_KEEP_ALIVE"

case " ${SECTIONS[*]} " in
  *" ollama "*) ;;
  *) _fail "registry: 'ollama' missing from SECTIONS" ;;
esac
_ok "registry: SECTIONS includes ollama"

[ -n "$(sec_get SEC_TITLE ollama)" ] || _fail "registry: SEC_TITLE[ollama] missing"
[ -n "$(sec_get SEC_DESC ollama)" ] || _fail "registry: SEC_DESC[ollama] missing"
_ok "registry: SEC_TITLE/SEC_DESC set for ollama"

[ -n "$(sec_get SEC_VARS ollama)" ] || _fail "registry: SEC_VARS[ollama] missing"
for v in $OLLAMA_VARS; do
  case " $(sec_get SEC_VARS ollama) " in
    *" $v "*) ;;
    *) _fail "registry: SEC_VARS[ollama] missing $v" ;;
  esac
done
_ok "registry: SEC_VARS[ollama] lists every required var"

got_count="$(printf '%s\n' $(sec_get SEC_VARS ollama) | wc -l)"
want_count="$(printf '%s\n' $OLLAMA_VARS | wc -l)"
[ "$got_count" -eq "$want_count" ] || _fail "registry: SEC_VARS[ollama] has extra/unexpected entries (got $got_count want $want_count): $(sec_get SEC_VARS ollama)"
_ok "registry: SEC_VARS[ollama] has exactly the 11 required vars, no more"

[ "$(sec_get SEC_APPLY ollama)" = infra-reconcile ] || _fail "registry: SEC_APPLY[ollama] should be infra-reconcile, got $(sec_get SEC_APPLY ollama)"
_ok "registry: SEC_APPLY[ollama]=infra-reconcile"

[ -n "$(sec_get SEC_PROFILE ollama)" ] || _fail "registry: SEC_PROFILE[ollama] missing"
_ok "registry: SEC_PROFILE[ollama] set"

sec_has SEC_DOCTOR_ROWS ollama || _fail "registry: SEC_DOCTOR_ROWS[ollama] not declared"
[ "$(sec_get SEC_DOCTOR_ROWS ollama)" = ollama ] || _fail "registry: SEC_DOCTOR_ROWS[ollama] should declare exactly the 'ollama' row, got: $(sec_get SEC_DOCTOR_ROWS ollama)"
_ok "registry: SEC_DOCTOR_ROWS[ollama] declares the ollama doctor row"

[ -n "$(sec_get SEC_SCOPE ollama)" ] || _fail "registry: SEC_SCOPE[ollama] missing (new concept not wired)"
[ "$(sec_get SEC_SCOPE ollama)" = machine ] || _fail "registry: SEC_SCOPE[ollama] should be machine, got $(sec_get SEC_SCOPE ollama)"
_ok "registry: SEC_SCOPE[ollama]=machine"

other_bad=""
for s in "${SECTIONS[@]}"; do
  case "$s" in
    ollama|wireguard|local-model) continue ;;
  esac
  [ -n "$(sec_get SEC_SCOPE "$s")" ] || { other_bad="$other_bad missing:$s"; continue; }
  [ "$(sec_get SEC_SCOPE "$s")" = project ] || other_bad="$other_bad wrong:$s=$(sec_get SEC_SCOPE "$s")"
done
[ -z "$other_bad" ] || _fail "registry: SEC_SCOPE should default to project for every section except the machine-scoped ones (ollama, wireguard, local-model):$other_bad"
_ok "registry: SEC_SCOPE defaults to project for every non-machine-scoped section"

_load_cbox_config_block() {
  awk '/^_cbox_config_load_sections\(\) \{/{f=1} f{print} f && /^config_cmd\(\) \{/{exit}' "$INSTALL_DIR/cbox" > "$TMPBASE/cbox_config_block.sh"
  sed -i '$ d' "$TMPBASE/cbox_config_block.sh"
  awk '/^config_cmd\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$INSTALL_DIR/cbox" >> "$TMPBASE/cbox_config_block.sh"
  awk '
    /^_cbox_local_effdir_for\(\) \{/ { infunc=1 }
    /^_cbox_machine_scoped_vars\(\) \{/ { infunc=1 }
    /^_cbox_load_machine_scoped_vars\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/cbox" > "$TMPBASE/cbox_helpers.sh"
  source "$TMPBASE/cbox_helpers.sh"
  source "$TMPBASE/cbox_config_block.sh"
}
_load_cbox_config_block

declare -f _cbox_config_whitelist >/dev/null || _fail "extraction failed: _cbox_config_whitelist not defined"
declare -f _cbox_config_validate_var >/dev/null || _fail "extraction failed: _cbox_config_validate_var not defined"
declare -f _cbox_machine_scoped_vars >/dev/null || _fail "extraction failed: _cbox_machine_scoped_vars not defined (cbox copy)"

for v in $OLLAMA_VARS; do
  _cbox_config_is_whitelisted "$v" || _fail "whitelist: $v should be in the cbox config whitelist"
done
_ok "whitelist: every ollama var is settable via cbox config set"

_cbox_config_validate_var CBOX_OLLAMA_MODE off || _fail "validator: CBOX_OLLAMA_MODE=off should be valid"
_cbox_config_validate_var CBOX_OLLAMA_MODE on || _fail "validator: CBOX_OLLAMA_MODE=on should be valid"
_cbox_config_validate_var CBOX_OLLAMA_MODE bogus >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_MODE=bogus should be rejected"
_ok "validator: CBOX_OLLAMA_MODE"

_cbox_config_validate_var CBOX_OLLAMA_IMAGE "ollama/ollama:0.33.3" || _fail "validator: pinned image tag should be valid"
_cbox_config_validate_var CBOX_OLLAMA_IMAGE "" >/dev/null 2>&1 && _fail "validator: empty image should be rejected"
_ok "validator: CBOX_OLLAMA_IMAGE"

_cbox_config_validate_var CBOX_OLLAMA_GPU off || _fail "validator: CBOX_OLLAMA_GPU=off should be valid"
_cbox_config_validate_var CBOX_OLLAMA_GPU cdi || _fail "validator: CBOX_OLLAMA_GPU=cdi should be valid"
_cbox_config_validate_var CBOX_OLLAMA_GPU 1 >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_GPU=1 (CBOX_GPU-style) should be rejected"
_ok "validator: CBOX_OLLAMA_GPU is its own off|cdi enum, not a reuse of CBOX_GPU's 0|1"

_cbox_config_validate_var CBOX_OLLAMA_STORE dedicated || _fail "validator: CBOX_OLLAMA_STORE=dedicated should be valid"
_cbox_config_validate_var CBOX_OLLAMA_STORE shared || _fail "validator: CBOX_OLLAMA_STORE=shared should be valid"
_cbox_config_validate_var CBOX_OLLAMA_STORE bogus >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_STORE=bogus should be rejected"
_ok "validator: CBOX_OLLAMA_STORE"

_cbox_config_validate_var CBOX_OLLAMA_STORE_PATH "" || _fail "validator: empty store path should be valid"
_cbox_config_validate_var CBOX_OLLAMA_STORE_PATH "/srv/ollama" || _fail "validator: absolute store path should be valid"
_cbox_config_validate_var CBOX_OLLAMA_STORE_PATH "relative" >/dev/null 2>&1 && _fail "validator: relative store path should be rejected"
_ok "validator: CBOX_OLLAMA_STORE_PATH"

_cbox_config_validate_var CBOX_OLLAMA_PORT 11434 || _fail "validator: port 11434 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_PORT 0 >/dev/null 2>&1 && _fail "validator: port 0 should be rejected"
_cbox_config_validate_var CBOX_OLLAMA_PORT 99999 >/dev/null 2>&1 && _fail "validator: out-of-range port should be rejected"
_ok "validator: CBOX_OLLAMA_PORT"

_cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL 1 || _fail "validator: CBOX_OLLAMA_NUM_PARALLEL=1 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL 0 >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_NUM_PARALLEL=0 should be rejected"
_cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL abc >/dev/null 2>&1 && _fail "validator: non-numeric CBOX_OLLAMA_NUM_PARALLEL should be rejected"
_ok "validator: CBOX_OLLAMA_NUM_PARALLEL"

_cbox_config_validate_var CBOX_OLLAMA_CONTEXT_LENGTH 32768 || _fail "validator: CBOX_OLLAMA_CONTEXT_LENGTH=32768 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_CONTEXT_LENGTH 2048 || _fail "validator: CBOX_OLLAMA_CONTEXT_LENGTH=2048 (the floor) should be valid"
_cbox_config_validate_var CBOX_OLLAMA_CONTEXT_LENGTH 0 >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_CONTEXT_LENGTH=0 must be rejected (ollama would fall back to its own default silently)"
_cbox_config_validate_var CBOX_OLLAMA_CONTEXT_LENGTH 2047 >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_CONTEXT_LENGTH=2047 must be rejected (below the 2048 floor)"
_cbox_config_validate_var CBOX_OLLAMA_CONTEXT_LENGTH -1 >/dev/null 2>&1 && _fail "validator: negative CBOX_OLLAMA_CONTEXT_LENGTH should be rejected"
_cbox_config_validate_var CBOX_OLLAMA_CONTEXT_LENGTH abc >/dev/null 2>&1 && _fail "validator: non-numeric CBOX_OLLAMA_CONTEXT_LENGTH should be rejected"
_ok "validator: CBOX_OLLAMA_CONTEXT_LENGTH"

_cbox_config_validate_var CBOX_OLLAMA_FLASH_ATTENTION off || _fail "validator: CBOX_OLLAMA_FLASH_ATTENTION=off should be valid"
_cbox_config_validate_var CBOX_OLLAMA_FLASH_ATTENTION on || _fail "validator: CBOX_OLLAMA_FLASH_ATTENTION=on should be valid"
_cbox_config_validate_var CBOX_OLLAMA_FLASH_ATTENTION bogus >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_FLASH_ATTENTION=bogus should be rejected"
_ok "validator: CBOX_OLLAMA_FLASH_ATTENTION"

_cbox_config_validate_var CBOX_OLLAMA_KV_CACHE_TYPE f16 || _fail "validator: CBOX_OLLAMA_KV_CACHE_TYPE=f16 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KV_CACHE_TYPE q8_0 || _fail "validator: CBOX_OLLAMA_KV_CACHE_TYPE=q8_0 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KV_CACHE_TYPE q4_0 || _fail "validator: CBOX_OLLAMA_KV_CACHE_TYPE=q4_0 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KV_CACHE_TYPE bogus >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_KV_CACHE_TYPE=bogus should be rejected"
_ok "validator: CBOX_OLLAMA_KV_CACHE_TYPE"

_cbox_config_validate_var CBOX_OLLAMA_KEEP_ALIVE 30m || _fail "validator: CBOX_OLLAMA_KEEP_ALIVE=30m should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KEEP_ALIVE 1h || _fail "validator: CBOX_OLLAMA_KEEP_ALIVE=1h should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KEEP_ALIVE 0 || _fail "validator: CBOX_OLLAMA_KEEP_ALIVE=0 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KEEP_ALIVE -1 || _fail "validator: CBOX_OLLAMA_KEEP_ALIVE=-1 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KEEP_ALIVE 3600 || _fail "validator: CBOX_OLLAMA_KEEP_ALIVE=3600 (plain seconds, documented by ollama) should be valid"
_cbox_config_validate_var CBOX_OLLAMA_KEEP_ALIVE "30m; rm -rf /" >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_KEEP_ALIVE with shell metacharacters should be rejected"
_cbox_config_validate_var CBOX_OLLAMA_KEEP_ALIVE '$(evil)' >/dev/null 2>&1 && _fail "validator: CBOX_OLLAMA_KEEP_ALIVE with command substitution should be rejected"
_ok "validator: CBOX_OLLAMA_KEEP_ALIVE"

machine_vars="$(_cbox_machine_scoped_vars | sort)"
missing_ollama_vars=""
for v in $OLLAMA_VARS; do
  printf '%s\n' "$machine_vars" | grep -qxF "$v" || missing_ollama_vars="$missing_ollama_vars $v"
done
[ -z "$missing_ollama_vars" ] || _fail "cbox's _cbox_machine_scoped_vars is missing ollama vars:$missing_ollama_vars (got [$machine_vars])"
_ok "cbox: _cbox_machine_scoped_vars includes every ollama var (other machine-scoped sections may contribute more)"

_load_setup_functions() {
  awk '
    /^conf_defaults\(\) \{/ { infunc=1 }
    /^conf_load\(\) \{/ { infunc=1 }
    /^conf_save\(\) \{/ { infunc=1 }
    /^_cbox_machine_scoped_vars\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/lib/cbox-setup.sh" > "$TMPBASE/setup_functions.sh"
  awk '
    /^_cbox_strip_machine_scoped_vars\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/templates/generators.sh" >> "$TMPBASE/setup_functions.sh"
  source "$TMPBASE/setup_functions.sh"
}
_load_setup_functions

declare -f conf_defaults >/dev/null || _fail "extraction failed: conf_defaults not defined (setup.sh)"
declare -f conf_save >/dev/null || _fail "extraction failed: conf_save not defined (setup.sh)"
declare -f _cbox_strip_machine_scoped_vars >/dev/null || _fail "extraction failed: _cbox_strip_machine_scoped_vars not defined (generators.sh - it must be reachable from the runtime cbox script, which never sources the setup library)"

CBOX_NAME=cbox
CBOX_WORKSPACES=""
conf_defaults

[ "$CBOX_OLLAMA_MODE" = off ] || _fail "conf_defaults: CBOX_OLLAMA_MODE should default to off, got $CBOX_OLLAMA_MODE"
[ -n "$CBOX_OLLAMA_IMAGE" ] || _fail "conf_defaults: CBOX_OLLAMA_IMAGE should default to a non-empty pinned reference"
[ "$CBOX_OLLAMA_GPU" = off ] || _fail "conf_defaults: CBOX_OLLAMA_GPU should default to off, got $CBOX_OLLAMA_GPU"
[ "$CBOX_OLLAMA_STORE" = dedicated ] || _fail "conf_defaults: CBOX_OLLAMA_STORE should default to dedicated, got $CBOX_OLLAMA_STORE"
[ -z "$CBOX_OLLAMA_STORE_PATH" ] || _fail "conf_defaults: CBOX_OLLAMA_STORE_PATH should default to empty, got $CBOX_OLLAMA_STORE_PATH"
[ "$CBOX_OLLAMA_PORT" = 11434 ] || _fail "conf_defaults: CBOX_OLLAMA_PORT should default to 11434, got $CBOX_OLLAMA_PORT"
[ "$CBOX_OLLAMA_NUM_PARALLEL" = 1 ] || _fail "conf_defaults: CBOX_OLLAMA_NUM_PARALLEL should default to 1, got $CBOX_OLLAMA_NUM_PARALLEL"
[ "$CBOX_OLLAMA_CONTEXT_LENGTH" = 65536 ] || _fail "conf_defaults: CBOX_OLLAMA_CONTEXT_LENGTH should default to 65536, got $CBOX_OLLAMA_CONTEXT_LENGTH"
[ "$CBOX_OLLAMA_FLASH_ATTENTION" = on ] || _fail "conf_defaults: CBOX_OLLAMA_FLASH_ATTENTION should default to on, got $CBOX_OLLAMA_FLASH_ATTENTION"
[ "$CBOX_OLLAMA_KV_CACHE_TYPE" = q8_0 ] || _fail "conf_defaults: CBOX_OLLAMA_KV_CACHE_TYPE should default to q8_0, got $CBOX_OLLAMA_KV_CACHE_TYPE"
[ "$CBOX_OLLAMA_KEEP_ALIVE" = 30m ] || _fail "conf_defaults: CBOX_OLLAMA_KEEP_ALIVE should default to 30m, got $CBOX_OLLAMA_KEEP_ALIVE"
_ok "conf_defaults: every new var has the documented default, CBOX_OLLAMA_MODE=off"

[ "$CBOX_LOCAL_MODEL_TIMEOUT_SEC" = 600 ] || _fail "conf_defaults: CBOX_LOCAL_MODEL_TIMEOUT_SEC should default to 600, got $CBOX_LOCAL_MODEL_TIMEOUT_SEC"
_ok "conf_defaults: K5 CBOX_LOCAL_MODEL_TIMEOUT_SEC defaults to 600"

CONFFILE="$TMPBASE/roundtrip.conf"
CBOX_OLLAMA_MODE=on
CBOX_OLLAMA_IMAGE="ollama/ollama:9.9.9"
CBOX_OLLAMA_GPU=cdi
CBOX_OLLAMA_STORE=shared
CBOX_OLLAMA_STORE_PATH=/srv/ollama-host
CBOX_OLLAMA_PORT=18434
CBOX_OLLAMA_NUM_PARALLEL=4
CBOX_OLLAMA_CONTEXT_LENGTH=8192
CBOX_OLLAMA_FLASH_ATTENTION=off
CBOX_OLLAMA_KV_CACHE_TYPE=f16
CBOX_OLLAMA_KEEP_ALIVE=1h
conf_save "$CONFFILE"

for v in $OLLAMA_VARS; do
  grep -q "^${v}=" "$CONFFILE" || _fail "conf_save: $v missing from saved conf (conf_save is hand-maintained, not derived from SEC_VARS - did it get added?)"
done
_ok "conf_save: every new var has an explicit printf line (not silently dropped)"

(
  unset CBOX_OLLAMA_MODE CBOX_OLLAMA_IMAGE CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE CBOX_OLLAMA_STORE_PATH CBOX_OLLAMA_PORT CBOX_OLLAMA_NUM_PARALLEL \
    CBOX_OLLAMA_CONTEXT_LENGTH CBOX_OLLAMA_FLASH_ATTENTION CBOX_OLLAMA_KV_CACHE_TYPE CBOX_OLLAMA_KEEP_ALIVE
  . "$CONFFILE"
  [ "$CBOX_OLLAMA_MODE" = on ] || exit 1
  [ "$CBOX_OLLAMA_IMAGE" = "ollama/ollama:9.9.9" ] || exit 1
  [ "$CBOX_OLLAMA_GPU" = cdi ] || exit 1
  [ "$CBOX_OLLAMA_STORE" = shared ] || exit 1
  [ "$CBOX_OLLAMA_STORE_PATH" = /srv/ollama-host ] || exit 1
  [ "$CBOX_OLLAMA_PORT" = 18434 ] || exit 1
  [ "$CBOX_OLLAMA_NUM_PARALLEL" = 4 ] || exit 1
  [ "$CBOX_OLLAMA_CONTEXT_LENGTH" = 8192 ] || exit 1
  [ "$CBOX_OLLAMA_FLASH_ATTENTION" = off ] || exit 1
  [ "$CBOX_OLLAMA_KV_CACHE_TYPE" = f16 ] || exit 1
  [ "$CBOX_OLLAMA_KEEP_ALIVE" = 1h ] || exit 1
) || _fail "round-trip: values written by conf_save do not read back identically"
_ok "round-trip: every new var survives conf_save -> disk -> source unchanged"

STRIPCONF="$TMPBASE/strip.conf"
{
  for v in $OLLAMA_VARS CBOX_GPU CBOX_MODE; do
    printf '%s=set-value\n' "$v"
  done
  printf 'CBOX_NAME=myprofile\n'
} > "$STRIPCONF"

_cbox_strip_machine_scoped_vars "$STRIPCONF"

for v in $OLLAMA_VARS; do
  grep -q "^${v}=" "$STRIPCONF" && _fail "isolated-derivation skip: $v should have been stripped from the per-project cbox.conf, still present"
done
grep -q '^CBOX_GPU=set-value' "$STRIPCONF" || _fail "isolated-derivation skip: an unrelated project-scoped var (CBOX_GPU) should survive the strip"
grep -q '^CBOX_MODE=set-value' "$STRIPCONF" || _fail "isolated-derivation skip: CBOX_MODE (project-scoped) should survive the strip"
grep -q '^CBOX_NAME=myprofile' "$STRIPCONF" || _fail "isolated-derivation skip: an untouched non-whitelisted line should survive the strip"
_ok "isolated-derivation skip: _cbox_strip_machine_scoped_vars removes exactly the ollama lines, leaves everything else"

run_local_line="$(grep -n '_cbox_strip_machine_scoped_vars "\$eff/cbox.conf"' "$INSTALL_DIR/lib/cbox-setup.sh" | head -1)"
[ -n "$run_local_line" ] || _fail "wiring: run_local (isolated derivation) does not call _cbox_strip_machine_scoped_vars on \$eff/cbox.conf"
save_line_no="$(grep -n 'conf_save "\$eff/cbox.conf"' "$INSTALL_DIR/lib/cbox-setup.sh" | head -1 | cut -d: -f1)"
strip_line_no="${run_local_line%%:*}"
[ "$strip_line_no" -gt "$save_line_no" ] || _fail "wiring: _cbox_strip_machine_scoped_vars must run after conf_save \$eff/cbox.conf, not before"
_ok "wiring: run_local calls _cbox_strip_machine_scoped_vars right after conf_save \$eff/cbox.conf (line $strip_line_no > $save_line_no)"

run_local_wizard_subset="$(awk '/^run_local_wizard_subset\(\) \{/,/^}$/' "$INSTALL_DIR/lib/cbox-setup.sh")"
case "$run_local_wizard_subset" in
  *step_ollama*) _fail "wiring: run_local_wizard_subset (isolated per-project wizard) must never call step_ollama" ;;
esac
_ok "wiring: the isolated per-project wizard never calls step_ollama (machine-scoped section is never asked per-project)"

step_ollama_body="$(awk '/^step_ollama\(\) \{/,/^}$/' "$INSTALL_DIR/lib/cbox-setup.sh")"
[ -n "$step_ollama_body" ] || _fail "wiring: step_ollama function not found in setup.sh"
_ok "wiring: step_ollama wizard function exists in setup.sh"

run_isolated_body="$(awk '/^_run_isolated\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
case "$run_isolated_body" in
  *_cbox_load_machine_scoped_vars*) ;;
  *) _fail "wiring: _run_isolated does not call _cbox_load_machine_scoped_vars after sourcing \$eff/cbox.conf" ;;
esac
_ok "wiring: _run_isolated (isolated 'cbox run') re-loads machine-scoped vars from the machine cbox.conf"

shell_isolated_body="$(awk '/^shell_isolated\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
case "$shell_isolated_body" in
  *_cbox_load_machine_scoped_vars*) ;;
  *) _fail "wiring: shell_isolated does not call _cbox_load_machine_scoped_vars after sourcing \$eff/cbox.conf" ;;
esac
_ok "wiring: shell_isolated ('cbox shell' in an isolated project) re-loads machine-scoped vars too"

case "$step_ollama_body" in
  *'mkdir'*|*'docker '*|*'docker-compose'*)
    _fail "off-default: step_ollama performs a filesystem/docker side effect directly (should defer to 'cbox ollama reconcile')"
    ;;
esac
_ok "off-default: step_ollama never touches the filesystem or docker directly - it only stages cbox.conf values"

case "$(sec_get SEC_APPLY ollama)" in
  infra-reconcile) ;;
  *) _fail "off-default: SEC_APPLY[ollama] changed unexpectedly" ;;
esac
apply_cmd="$(_cbox_config_apply_cmd_for infra-reconcile)"
case "$apply_cmd" in
  *"cbox ollama reconcile"*) ;;
  *) _fail "off-default: infra-reconcile apply command should name 'cbox ollama reconcile', got: $apply_cmd" ;;
esac
_ok "off-default: applying ollama config changes is opt-in via 'cbox ollama reconcile', never automatic"

CBOX_OLLAMA_MODE=off
case "$step_ollama_body" in
  *'ask "setup: ollama image reference'*)
    case "$step_ollama_body" in
      *'CBOX_OLLAMA_MODE" = on'*) ;;
      *) _fail "off-default: step_ollama should gate its follow-up prompts behind CBOX_OLLAMA_MODE=on" ;;
    esac
    ;;
esac
_ok "off-default: step_ollama's follow-up prompts (image/gpu/store/port/parallel) are gated behind CBOX_OLLAMA_MODE=on"

_load_doc_coverage_block() {
  awk '
    /^v_t\(\) \{/ { infunc=1 }
    /^v_ok\(\) \{/ { infunc=1 }
    /^v_fail\(\) \{/ { infunc=1 }
    /^v_skip\(\) \{/ { infunc=1 }
    /^_cbox_verify_doc_coverage\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/cbox" > "$TMPBASE/doc_coverage.sh"
  source "$TMPBASE/doc_coverage.sh"
}
_load_doc_coverage_block

declare -f _cbox_verify_doc_coverage >/dev/null || _fail "extraction failed: _cbox_verify_doc_coverage not defined"

VN=0
VOK=0
VFAIL=0
VSKIP=0
DOC_COVERAGE_OUT="$(_cbox_verify_doc_coverage)"
[ "$VFAIL" -eq 0 ] || _fail "cbox verify doc-coverage guard failed: $DOC_COVERAGE_OUT"
case "$DOC_COVERAGE_OUT" in
  *"coverage gaps"*) _fail "cbox verify doc-coverage guard reported gaps: $DOC_COVERAGE_OUT" ;;
esac
_ok "cbox verify doc-coverage guard: sections in MANUAL, dep-text complete, doctor rows match both ways (ollama included)"

grep -qiE '^### +ollama *$' "$INSTALL_DIR/MANUAL.md" || _fail "MANUAL.md: missing '### ollama' heading required by the doc-coverage guard"
_ok "MANUAL.md: '### ollama' heading present"

echo "PASS: all ollama section tests"
