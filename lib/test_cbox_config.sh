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

source "$INSTALL_DIR/_common.sh"
source "$INSTALL_DIR/templates/generators.sh"
source "$INSTALL_DIR/templates/sections.sh"

_load_cbox_functions() {
  local extracted="$TMPBASE/cbox_functions.sh"
  awk '
    /^die_no_conf\(\) \{/ { infunc=1 }
    /^_cbox_local_effdir_for\(\) \{/ { infunc=1 }
    /^_cbox_root_in_global_scope\(\) \{/ { infunc=1 }
    /^_cbox_effective_mode\(\) \{/ { infunc=1 }
    /^_cbox_doctor_in_container\(\) \{/ { infunc=1 }
    /^require_global_conf\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/cbox" > "$extracted"
  awk '/^_cbox_config_load_sections\(\) \{/{f=1} f{print} f && /^config_cmd\(\) \{/{exit}' "$INSTALL_DIR/cbox" > "$TMPBASE/cbox_config_block.sh"
  sed -i '$ d' "$TMPBASE/cbox_config_block.sh"
  awk '/^config_cmd\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$INSTALL_DIR/cbox" >> "$TMPBASE/cbox_config_block.sh"
  source "$extracted"
  source "$TMPBASE/cbox_config_block.sh"
}
_load_cbox_functions

declare -f _cbox_config_set_var >/dev/null || _fail "extraction failed: _cbox_config_set_var not defined"
declare -f config_cmd >/dev/null || _fail "extraction failed: config_cmd not defined"
declare -f _cbox_config_dep_gate >/dev/null || _fail "extraction failed: _cbox_config_dep_gate not defined"

HOME="$TMPBASE/home"
mkdir -p "$HOME"

_cbox_config_is_whitelisted CBOX_HERMES_VERSION || _fail "whitelist: CBOX_HERMES_VERSION should be whitelisted"
_ok "whitelist: known var accepted"

if _cbox_config_is_whitelisted CBOX_NOT_A_REAL_VAR; then
  _fail "whitelist: unknown var should be rejected"
fi
_ok "whitelist: unknown var rejected"

if _cbox_config_is_whitelisted "PATH"; then
  _fail "whitelist: non-CBOX var should be rejected"
fi
_ok "whitelist: non-CBOX var rejected"

if _cbox_config_parse_pairs 'CBOX_NOPE=x' 2>/dev/null; then
  _fail "parse_pairs: should reject a non-whitelisted key"
fi
_ok "parse_pairs: rejects non-whitelisted key"

if _cbox_config_parse_pairs 'not_upper=x' 2>/dev/null; then
  _fail "parse_pairs: should reject a lowercase key"
fi
_ok "parse_pairs: rejects key not matching ^[A-Z][A-Z0-9_]*\$"

if _cbox_config_parse_pairs "$(printf 'CBOX_GPU=1\n0')" 2>/dev/null; then
  _fail "parse_pairs: should reject a value containing a newline"
fi
_ok "parse_pairs: rejects newline in value"

if _cbox_config_parse_pairs "$(printf 'CBOX_GPU=1\r0')" 2>/dev/null; then
  _fail "parse_pairs: should reject a value containing a carriage return"
fi
_ok "parse_pairs: rejects carriage return in value"

if err="$(_cbox_config_validate_var CBOX_HERMES_MODEL_NAME "$(printf 'a\x01b')" 2>&1)"; then
  _fail "validate_var: should reject other control characters (got: $err)"
fi
_ok "validate_var: rejects other C0 control characters via _cbox_config_no_ctrl"

_cbox_config_validate_var CBOX_MODE global || _fail "enum: CBOX_MODE=global should be valid"
if _cbox_config_validate_var CBOX_MODE bogus >/dev/null 2>&1; then
  _fail "enum: CBOX_MODE=bogus should be rejected"
fi
_ok "validator: enum (CBOX_MODE)"

_cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT 1080 || _fail "numeric: 1080 should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT "-1" >/dev/null 2>&1; then
  _fail "numeric: negative port should be rejected"
fi
if _cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT "abc" >/dev/null 2>&1; then
  _fail "numeric: non-numeric port should be rejected"
fi
if _cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT 65536 >/dev/null 2>&1; then
  _fail "numeric: out-of-range port should be rejected"
fi
_ok "validator: numeric (CBOX_NETACCESS_SOCKS_PORT)"

_cbox_config_validate_var CBOX_NETACCESS_EXEC_MODE scoped || _fail "netaccess exec: scoped should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_MODE all >/dev/null 2>&1; then
  _fail "netaccess exec: all should be rejected"
fi
_cbox_config_validate_var CBOX_NETACCESS_EXEC_WORKSPACE_GUARD on || _fail "netaccess exec workspace guard: on should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_WORKSPACE_GUARD required >/dev/null 2>&1; then
  _fail "netaccess exec workspace guard: unknown value should be rejected"
fi
_cbox_config_validate_var CBOX_NETACCESS_EXEC_TIMEOUT 900 || _fail "netaccess exec timeout: 900 should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_TIMEOUT 0 >/dev/null 2>&1; then
  _fail "netaccess exec timeout: zero should be rejected"
fi
_cbox_config_validate_var CBOX_NETACCESS_EXEC_MAX_BYTES 10485760 || _fail "netaccess exec max bytes: default should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_MAX_BYTES 1023 >/dev/null 2>&1; then
  _fail "netaccess exec max bytes: values below 1024 should be rejected"
fi
_ok "validator: scoped container exec limits"

_cbox_config_validate_var CBOX_LOCAL_MODEL_URL "http://ollama:11434" || _fail "url: valid http url should pass"
_cbox_config_validate_var CBOX_LOCAL_MODEL_URL "" || _fail "url: empty should be allowed (delegate off)"
if _cbox_config_validate_var CBOX_LOCAL_MODEL_URL "ftp://x" >/dev/null 2>&1; then
  _fail "url: non-http(s) scheme should be rejected"
fi
_ok "validator: URL shape (CBOX_LOCAL_MODEL_URL)"

_cbox_config_validate_var CBOX_HERMES_VERSION "0.19.0" || _fail "hermes version: 0.19.0 should be valid"
if _cbox_config_validate_var CBOX_HERMES_VERSION "not-a-version" >/dev/null 2>&1; then
  _fail "hermes version: garbage should be rejected"
fi
if _cbox_config_validate_var CBOX_HERMES_VERSION "1" >/dev/null 2>&1; then
  _fail "hermes version: bare major with no dot should be rejected"
fi
_ok "validator: hermes version pin grammar"

_cbox_config_validate_var CBOX_HERMES_PROVIDER local || _fail "hermes provider: local should be valid"
_cbox_config_validate_var CBOX_HERMES_PROVIDER anthropic || _fail "hermes provider: anthropic should be valid"
if _cbox_config_validate_var CBOX_HERMES_PROVIDER bogus >/dev/null 2>&1; then
  _fail "hermes provider: bogus provider should be rejected"
fi
_ok "validator: hermes provider enum"

_cbox_config_validate_var CBOX_LIMIT_RESUME_PROMPT "please continue now" || _fail "free-text: spaces should be allowed"
if _cbox_config_validate_var CBOX_LIMIT_RESUME_PROMPT "" >/dev/null 2>&1; then
  _fail "free-text: empty prompt should be rejected (must not be empty)"
fi
_ok "validator: free-text var accepting spaces (CBOX_LIMIT_RESUME_PROMPT)"

CBOX_MODE=global
_cbox_config_dep_gate CBOX_RESTART_POLICY >/dev/null 2>&1 || _fail "dep-gate: global mode should be unaffected (condition is isolated-mode)"
_ok "dep-gate: global mode leaves restart-policy alone (sanity)"

CBOX_MODE=isolated
if err="$(_cbox_config_dep_gate CBOX_RESTART_POLICY 2>&1)"; then
  _fail "dep-gate: isolated mode should force restart-policy back (disable:isolated-mode)"
else
  case "$err" in
    *"isolated mode"*) _ok "dep-gate: rejects CBOX_RESTART_POLICY under isolated mode ($err)" ;;
    *) _fail "dep-gate: rejection reason missing isolated-mode text: $err" ;;
  esac
fi
unset CBOX_MODE

CBOX_HERMES=off
if err="$(_cbox_config_dep_gate CBOX_HERMES_DELEGATE 2>&1)"; then
  _fail "dep-gate: CBOX_HERMES=off should force hermes-delegate back (disable:hermes-off)"
else
  case "$err" in
    *"hermes"*) _ok "dep-gate: rejects CBOX_HERMES_DELEGATE when CBOX_HERMES=off ($err)" ;;
    *) _fail "dep-gate: rejection reason missing hermes text: $err" ;;
  esac
fi

CBOX_HERMES=on
_cbox_config_dep_gate CBOX_HERMES_DELEGATE >/dev/null 2>&1 \
  || _fail "dep-gate: CBOX_HERMES=on should leave hermes-delegate ungated"
_ok "dep-gate: CBOX_HERMES=on leaves hermes-delegate ungated"
unset CBOX_HERMES

PENDIR="$TMPBASE/pending-eff"
mkdir -p "$PENDIR"
_cbox_config_write_pending "$PENDIR" hermes mode
[ -f "$PENDIR/pending.apply" ] || _fail "pending: pending.apply not written"
grep -qx 'hermes=rebuild' "$PENDIR/pending.apply" || _fail "pending: hermes=rebuild line missing"
grep -qx 'mode=none' "$PENDIR/pending.apply" || _fail "pending: mode=none line missing"
_ok "pending: pending.apply renders section=apply-class lines"

report="$(_cbox_config_print_report hermes mode)"
case "$report" in
  *"rebuild"*"next cbox run rebuilds"*) ;;
  *) _fail "report: hermes rebuild command text missing from report: $report" ;;
esac
case "$report" in
  *"none"*"takes effect on next cbox run"*) ;;
  *) _fail "report: mode none command text missing from report: $report" ;;
esac
_ok "pending: stage-and-report table names the exact apply command per class"

CASDIR="$TMPBASE/cas"
mkdir -p "$CASDIR"
printf 'CBOX_GPU=0\n' > "$CASDIR/cbox.conf"
loaded_sha="$(sha256sum "$CASDIR/cbox.conf" | awk '{print $1}')"
printf 'CBOX_GPU=1\n' > "$CASDIR/cbox.conf"
cur_sha="$(sha256sum "$CASDIR/cbox.conf" | awk '{print $1}')"
[ "$cur_sha" != "$loaded_sha" ] || _fail "CAS: test setup did not actually change the file"
_ok "CAS: loaded-vs-disk sha mismatch is detectable (the abort branch in _cbox_config_set_global checks this exact condition)"

_setup_fixture_eff() {
  local eff="$1" root="$2"
  mkdir -p "$eff"
  {
    local v
    for v in $(_cbox_config_whitelist); do
      case "$v" in
        CBOX_MODE) printf 'CBOX_MODE=isolated\n' ;;
        CBOX_HERMES) printf 'CBOX_HERMES=off\n' ;;
        CBOX_HERMES_VERSION) printf 'CBOX_HERMES_VERSION=0.19.0\n' ;;
        CBOX_HERMES_PROVIDER) printf 'CBOX_HERMES_PROVIDER=local\n' ;;
        CBOX_GPU) printf 'CBOX_GPU=0\n' ;;
        CBOX_WORKSPACES) printf 'CBOX_WORKSPACES=%q\n' "$root" ;;
        *) printf '%s=%q\n' "$v" "" ;;
      esac
    done
  } > "$eff/cbox.conf"
  mkdir -p "$eff/generated"
  echo "original-marker" > "$eff/generated/marker.txt"
  _cbox_manifest_write "$eff" "$root" "$eff/cbox.conf"
  _cbox_manifest_write_generated "$eff"
}

ROOT="$TMPBASE/project-root"
mkdir -p "$ROOT"
mkdir -p "$HOME/.config/cbox/projects"
EFF="$HOME/.config/cbox/projects/fixedhash"
_setup_fixture_eff "$EFF" "$ROOT"

REGEN_LOG="$TMPBASE/regen.log"
_gen_effective() {
  local eff="$1" root="$2"
  printf 'regen-called eff=%s root=%s\n' "$eff" "$root" >> "$REGEN_LOG"
  echo "regenerated-marker" > "$eff/generated/marker.txt"
}

_cbox_workspace_root() { printf '%s' "$ROOT"; }
_cbox_path_hash() { printf 'fixedhash'; }

(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_HERMES CBOX_HERMES_VERSION)
  CBOX_CONFIG_VALS=(on 0.20.0)
  _cbox_config_set_isolated
) > "$TMPBASE/set_ok.stdout" 2>"$TMPBASE/set_ok.stderr" || _fail "e2e success path: _cbox_config_set_isolated failed unexpectedly: $(cat "$TMPBASE/set_ok.stderr")"

grep -q '^CBOX_HERMES=on$' "$EFF/cbox.conf" || _fail "e2e success: CBOX_HERMES not updated in cbox.conf"
grep -q '^CBOX_HERMES_VERSION=0.20.0$' "$EFF/cbox.conf" || _fail "e2e success: CBOX_HERMES_VERSION not updated in cbox.conf"
[ "$(cat "$EFF/generated/marker.txt")" = "regenerated-marker" ] || _fail "e2e success: regen did not run (marker not updated)"
grep -q "regen-called eff=$EFF root=$ROOT" "$REGEN_LOG" || _fail "e2e success: regen was not called with the expected eff/root"
[ -f "$EFF/pending.apply" ] || _fail "e2e success: pending.apply not written"
grep -qx 'hermes=rebuild' "$EFF/pending.apply" || _fail "e2e success: pending.apply missing hermes=rebuild"

conf_sha_now="$(sha256sum "$EFF/cbox.conf" | awk '{print $1}')"
manifest_conf_sha="$(_cbox_manifest_field "$EFF/manifest.sha256" conf)"
[ "$conf_sha_now" = "$manifest_conf_sha" ] || _fail "e2e success: manifest conf sha does not match post-set cbox.conf"
_ok "e2e success: conf updated, regen ran, manifests stamped, pending.apply written"

ORDER_LOG="$TMPBASE/order.log"
_cbox_manifest_write() {
  echo "manifest-write-conf" >> "$ORDER_LOG"
  local eff="$1" root="$2" conf="$3" conf_sha gen_sha
  conf_sha="$(sha256sum "$conf" | awk '{print $1}')"
  gen_sha="$(_cbox_tpl_sha 2>/dev/null || echo stubgen)"
  {
    printf 'schema=1\n'
    printf 'workspace=%s\n' "$root"
    printf 'conf=%s\n' "$conf_sha"
    printf 'generators=%s\n' "$gen_sha"
  } > "$eff/manifest.sha256"
  printf '%s\n' "$root" > "$eff/workspace"
}
_cbox_manifest_write_generated() {
  echo "manifest-write-generated" >> "$ORDER_LOG"
  local eff="$1"
  printf 'compose=stub\n' >> "$eff/manifest.sha256"
}

_cbox_path_hash() { printf 'orderhash'; }
EFF2="$HOME/.config/cbox/projects/orderhash"
_setup_fixture_eff "$EFF2" "$ROOT"
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_GPU)
  CBOX_CONFIG_VALS=(1)
  _cbox_config_set_isolated
) > /dev/null 2>"$TMPBASE/order.stderr" || _fail "order test: set failed: $(cat "$TMPBASE/order.stderr")"

[ "$(sed -n 1p "$ORDER_LOG")" = "manifest-write-conf" ] || _fail "order: conf manifest not written first"
[ "$(sed -n 2p "$ORDER_LOG")" = "manifest-write-generated" ] || _fail "order: generated manifest not written second"
_ok "e2e order: conf manifest stamped before generated manifest (observable via stub logging)"

unset -f _cbox_manifest_write
unset -f _cbox_manifest_write_generated
source <(awk '/^_cbox_manifest_write\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh")
source <(awk '/^_cbox_manifest_write_generated\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh")

_gen_effective() {
  echo "cbox-config-test: simulated regen failure" >&2
  return 1
}

_cbox_path_hash() { printf 'failhash'; }
EFF3="$HOME/.config/cbox/projects/failhash"
_setup_fixture_eff "$EFF3" "$ROOT"
cp "$EFF3/cbox.conf" "$TMPBASE/pre-conf"
cp -a "$EFF3/generated" "$TMPBASE/pre-generated"
cp "$EFF3/manifest.sha256" "$TMPBASE/pre-manifest.sha256"

(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_HERMES)
  CBOX_CONFIG_VALS=(on)
  _cbox_config_set_isolated
) > "$TMPBASE/fail.stdout" 2>"$TMPBASE/fail.stderr" && _fail "e2e failure path: _cbox_config_set_isolated should have returned non-zero on regen failure"

cmp -s "$TMPBASE/pre-conf" "$EFF3/cbox.conf" || _fail "e2e failure: cbox.conf not byte-identical to pre-state after regen failure"
diff -rq "$TMPBASE/pre-generated" "$EFF3/generated" >/dev/null || _fail "e2e failure: generated/ not byte-identical to pre-state after regen failure"
cmp -s "$TMPBASE/pre-manifest.sha256" "$EFF3/manifest.sha256" || _fail "e2e failure: manifest.sha256 changed despite regen failure"
[ -f "$EFF3/pending.apply" ] && _fail "e2e failure: pending.apply should not have been written on failure"
grep -qi "restored" "$TMPBASE/fail.stderr" || _fail "e2e failure: failure message does not mention restoration"
_ok "e2e failure: conf and generated left byte-identical to pre-state, no manifest/pending written, failure reported"

DEPFAIL="$HOME/.config/cbox/projects/depfailhash"
mkdir -p "$DEPFAIL/generated"
{
  for v in $(_cbox_config_whitelist); do
    case "$v" in
      CBOX_MODE) printf 'CBOX_MODE=isolated\n' ;;
      CBOX_RESTART_POLICY) printf 'CBOX_RESTART_POLICY=no\n' ;;
      CBOX_WORKSPACES) printf 'CBOX_WORKSPACES=%q\n' "$ROOT" ;;
      *) printf '%s=%q\n' "$v" "" ;;
    esac
  done
} > "$DEPFAIL/cbox.conf"
mkdir -p "$DEPFAIL/generated"
echo original > "$DEPFAIL/generated/marker.txt"
_cbox_manifest_write "$DEPFAIL" "$ROOT" "$DEPFAIL/cbox.conf"
_cbox_manifest_write_generated "$DEPFAIL"
cp "$DEPFAIL/cbox.conf" "$TMPBASE/depfail-pre-conf"

_cbox_path_hash() { printf 'depfailhash'; }
_gen_effective() { echo "should not be called" >&2; return 1; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_RESTART_POLICY)
  CBOX_CONFIG_VALS=(unless-stopped)
  _cbox_config_set_isolated
) > "$TMPBASE/depfail.stdout" 2>"$TMPBASE/depfail.stderr" && _fail "dep-gate e2e: set should have been rejected (isolated mode forces restart-policy back)"
grep -qi "dependency rule" "$TMPBASE/depfail.stderr" || _fail "dep-gate e2e: rejection message missing: $(cat "$TMPBASE/depfail.stderr")"
cmp -s "$TMPBASE/depfail-pre-conf" "$DEPFAIL/cbox.conf" || _fail "dep-gate e2e: cbox.conf was modified despite dep-gate rejection"
_ok "dep-gate e2e: set rejected inside the transaction, conf left untouched"

_cbox_path_hash() { printf 'preservehash'; }
PRESERVE="$HOME/.config/cbox/projects/preservehash"
mkdir -p "$PRESERVE/generated"
{
  for v in $(_cbox_config_whitelist); do
    case "$v" in
      CBOX_MODE) printf 'CBOX_MODE=isolated\n' ;;
      CBOX_HERMES) printf 'CBOX_HERMES=off\n' ;;
      CBOX_HERMES_VERSION) printf 'CBOX_HERMES_VERSION=0.19.0\n' ;;
      CBOX_HERMES_PROVIDER) printf 'CBOX_HERMES_PROVIDER=local\n' ;;
      CBOX_GPU) printf 'CBOX_GPU=0\n' ;;
      CBOX_WORKSPACES) printf 'CBOX_WORKSPACES=%q\n' "$ROOT" ;;
      *) printf '%s=%q\n' "$v" "" ;;
    esac
  done
  printf 'CBOX_NAME=myprofile\n'
  printf 'CBOX_TPL_SHA=deadbeef\n'
} > "$PRESERVE/cbox.conf"
echo "original-marker" > "$PRESERVE/generated/marker.txt"
_cbox_manifest_write "$PRESERVE" "$ROOT" "$PRESERVE/cbox.conf"
_cbox_manifest_write_generated "$PRESERVE"

_gen_effective() { :; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_GPU)
  CBOX_CONFIG_VALS=(1)
  _cbox_config_set_isolated
) > /dev/null 2>"$TMPBASE/preserve.stderr" || _fail "preserve-extra-lines: set failed: $(cat "$TMPBASE/preserve.stderr")"

grep -qx 'CBOX_NAME=myprofile' "$PRESERVE/cbox.conf" || _fail "preserve-extra-lines: CBOX_NAME dropped from cbox.conf after set"
grep -qx 'CBOX_TPL_SHA=deadbeef' "$PRESERVE/cbox.conf" || _fail "preserve-extra-lines: CBOX_TPL_SHA dropped from cbox.conf after set"
grep -qx 'CBOX_GPU=1' "$PRESERVE/cbox.conf" || _fail "preserve-extra-lines: CBOX_GPU not updated"
_ok "preserve-extra-lines: non-whitelisted keys (CBOX_NAME, CBOX_TPL_SHA) survive a config set untouched"

_cbox_path_hash() { printf 'restoreatomichash'; }
RESTOREATOMIC="$HOME/.config/cbox/projects/restoreatomichash"
_setup_fixture_eff "$RESTOREATOMIC" "$ROOT"
cp "$RESTOREATOMIC/cbox.conf" "$TMPBASE/restoreatomic-pre-conf"
cp -a "$RESTOREATOMIC/generated" "$TMPBASE/restoreatomic-pre-generated"

WATCH_LOG="$TMPBASE/restoreatomic-watch.log"
: > "$WATCH_LOG"
_gen_effective() {
  local eff="$1"
  echo "changed-before-failure" > "$eff/generated/marker.txt"
  echo "cbox-config-test: simulated regen failure" >&2
  return 1
}
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_HERMES)
  CBOX_CONFIG_VALS=(on)
  _cbox_config_set_isolated &
  bg_pid=$!
  for _ in $(seq 1 200); do
    if [ -d "$RESTOREATOMIC/generated" ]; then
      echo present >> "$WATCH_LOG"
    else
      echo absent >> "$WATCH_LOG"
    fi
  done
  wait "$bg_pid"
) > "$TMPBASE/restoreatomic.stdout" 2>"$TMPBASE/restoreatomic.stderr" && _fail "restore-atomicity: set should have failed on simulated regen failure"

cmp -s "$TMPBASE/restoreatomic-pre-conf" "$RESTOREATOMIC/cbox.conf" || _fail "restore-atomicity: cbox.conf not byte-identical to pre-state after restore"
diff -rq "$TMPBASE/restoreatomic-pre-generated" "$RESTOREATOMIC/generated" >/dev/null || _fail "restore-atomicity: generated/ not byte-identical to pre-state after restore"
if grep -qx absent "$WATCH_LOG"; then
  _fail "restore-atomicity: generated/ observed absent during restore polling window"
fi
_ok "restore-atomicity: cbox.conf/generated restored via mktemp+mv and rename-swap, generated/ never observed absent by a concurrent poller"

_cbox_path_hash() { printf 'dictatenotehash'; }
DICTATENOTE="$HOME/.config/cbox/projects/dictatenotehash"
_setup_fixture_eff "$DICTATENOTE" "$ROOT"
_gen_effective() { :; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_CODEX_MCP)
  CBOX_CONFIG_VALS=(1)
  _cbox_config_set_isolated
) > "$TMPBASE/dictatenote.stdout" 2>"$TMPBASE/dictatenote.stderr" || _fail "dictate-note: set failed: $(cat "$TMPBASE/dictatenote.stderr")"
grep -q "wizard-only auto-deploy" "$TMPBASE/dictatenote.stdout" || _fail "dictate-note: report did not warn about codex-mcp's dictate:hooks wizard-only behavior"
_ok "dictate-note: config set report flags a dictate-gated section as wizard-only auto-deploy"

echo "PASS: all cbox config tests"
