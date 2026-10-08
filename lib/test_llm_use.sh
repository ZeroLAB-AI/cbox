#!/usr/bin/env bash
set -euo pipefail

for _v in $(compgen -e | grep -E '^(CBOX_|OLLAMA_)' || true); do
  unset "$_v"
done
unset _v TMUX TMUX_PANE

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

bash -n "$INSTALL_DIR/cbox" || _fail "cbox fails bash -n"

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

_load_fn() {
  local body
  body="$(_extract_fn "$INSTALL_DIR/cbox" "$1")"
  [ -n "$body" ] || _fail "cannot extract $1 from cbox"
  eval "$body"
}

for fn in \
  _cbox_llm_backend_mode_key _cbox_llm_backend_compose _cbox_llm_backend_owner_dir \
  _cbox_llm_backend_state _cbox_llm_ollama_models _cbox_llm_consumers \
  _cbox_llm_consumer_uses_local _cbox_llm_consumer_pointing _cbox_llm_status_cmd \
  _cbox_llm_ollama_model_for_use _cbox_llm_apply_pairs _cbox_llm_use_cmd llm_cmd \
  _cbox_ollama_model_ref_ok _cbox_local_backends_gpu_overlap_text _cbox_local_backends_gpu_overlap_warn
do
  _load_fn "$fn"
done

CALLS="$TMPBASE/calls"
: > "$CALLS"

die() { echo "die: $*" >&2; exit 1; }
_cbox_local_backends() { printf 'ollama\nhyperqwen\n'; }
_cbox_local_backend_active() {
  case "$1" in
    ollama) [ "${CBOX_OLLAMA_MODE:-off}" = on ] ;;
    hyperqwen) [ "${CBOX_HYPERQWEN_MODE:-off}" = on ] ;;
    *) return 1 ;;
  esac
}
_cbox_local_backend_url() {
  case "$1" in
    ollama) printf 'http://ollama:11434' ;;
    hyperqwen) printf 'http://hyperqwen:18020' ;;
  esac
}
_cbox_local_backend_served_model() {
  case "$1" in
    hyperqwen) printf 'qwen3.8-27b' ;;
    *) return 0 ;;
  esac
}
_cbox_local_backend_context_length() {
  case "$1" in
    ollama) printf '65536' ;;
    hyperqwen) printf '65536' ;;
  esac
}
_cbox_local_backend_of_url() {
  case "$1" in
    http://ollama:*) printf 'ollama' ;;
    http://hyperqwen:*) printf 'hyperqwen' ;;
    *) return 1 ;;
  esac
}
_cbox_gpu_devices_overlap() {
  [ "${1:-all}" = all ] && return 0
  [ "${2:-all}" = all ] && return 0
  [ "$1" = "$2" ]
}
_cbox_config_in_container() { [ "${T_INCONTAINER:-0}" = 1 ]; }
_cbox_config_set_force_global() { echo "FORCE-GLOBAL $*" >> "$CALLS"; return "${T_SET_RC:-0}"; }
_cbox_config_set() { echo "SET $*" >> "$CALLS"; return 0; }
_cbox_effective_mode() { printf '%s' "${T_MODE:-global}"; }
_cbox_workspace_root() { printf '/proj'; }
_cbox_local_effdir_for() { printf '/eff%s' "$1"; }
_cbox_override_keys() { printf '%s\n' ${T_OVERRIDE_KEYS:-}; }
_cbox_ollama_owner_compose() { echo "OLLAMA-COMPOSE $*" >> "$CALLS"; printf '%s\n' "${T_OLLAMA_CID-ocid}"; }
_cbox_hyperqwen_owner_compose() { echo "HQ-COMPOSE $*" >> "$CALLS"; printf '%s\n' "${T_HQ_CID-hcid}"; }
_cbox_ollama_owner_dir() { printf '%s/nowhere-o' "$TMPBASE"; }
_cbox_hyperqwen_owner_dir() { printf '%s/nowhere-h' "$TMPBASE"; }
docker() {
  echo "docker $*" >> "$CALLS"
  case "$1" in
    exec)
      printf 'NAME ID SIZE MODIFIED\n'
      local m
      for m in ${T_OLLAMA_MODELS:-}; do printf '%s abc 1GB 1 day ago\n' "$m"; done
      ;;
  esac
}

_reset() {
  : > "$CALLS"
  unset T_INCONTAINER T_SET_RC T_MODE T_OVERRIDE_KEYS T_OLLAMA_CID T_HQ_CID T_OLLAMA_MODELS
  local v
  for v in $(compgen -v | grep -E '^(CBOX_|OLLAMA_)' || true); do unset "$v"; done
  export CBOX_OLLAMA_MODE=on CBOX_HYPERQWEN_MODE=on
  export CBOX_LOCAL_MODEL=on CBOX_HERMES_PROVIDER=local
}

_set_line() {
  grep -m1 '^FORCE-GLOBAL ' "$CALLS" || true
}

_reset
out="$( ( _cbox_llm_use_cmd hyperqwen ) 2>&1)" || _fail "use hyperqwen must succeed: $out"
line="$(_set_line)"
for pair in CBOX_LOCAL_MODEL_URL=http://hyperqwen:18020 CBOX_LOCAL_MODEL_NAME=qwen3.8-27b \
  CBOX_HERMES_MODEL_URL=http://hyperqwen:18020 CBOX_HERMES_MODEL_NAME=qwen3.8-27b \
  CBOX_HERMES_DELEGATE_BASE_URL=http://hyperqwen:18020 CBOX_HERMES_DELEGATE_MODEL=qwen3.8-27b; do
  case "$line" in *"$pair"*) ;; *) _fail "use hyperqwen must set $pair: $line" ;; esac
done
_ok "use hyperqwen: local-model, hermes console and delegate all switched with the fixed served model"

_reset
export CBOX_LOCAL_MODEL=off
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1
line="$(_set_line)"
case "$line" in *CBOX_LOCAL_MODEL_URL*) _fail "local-model off with no url must not be touched: $line" ;; esac
export CBOX_LOCAL_MODEL_URL=http://ollama:11434
: > "$CALLS"
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1
case "$(_set_line)" in *CBOX_LOCAL_MODEL_URL=http://hyperqwen:18020*) ;; *) _fail "local-model off but with a url counts as a consumer" ;; esac
_ok "local-model consumer: on, or off with a url"

_reset
export CBOX_HERMES_PROVIDER=openrouter
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1
line="$(_set_line)"
case "$line" in *CBOX_HERMES_MODEL_URL*|*CBOX_HERMES_DELEGATE_BASE_URL*) _fail "a non-local hermes provider is not a consumer, and the delegate inherits it: $line" ;; esac
export CBOX_HERMES_DELEGATE_PROVIDER=local
: > "$CALLS"
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1
line="$(_set_line)"
case "$line" in *CBOX_HERMES_DELEGATE_BASE_URL=http://hyperqwen:18020*) ;; *) _fail "an explicit local delegate provider is a consumer: $line" ;; esac
case "$line" in *CBOX_HERMES_MODEL_URL*) _fail "the hermes console stays untouched with another provider: $line" ;; esac
export CBOX_HERMES_DELEGATE_PROVIDER=nous CBOX_HERMES_PROVIDER=local
: > "$CALLS"
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1
case "$(_set_line)" in *CBOX_HERMES_DELEGATE_BASE_URL*) _fail "a delegate on another provider is not a consumer" ;; esac
_ok "hermes consumers: provider gates the console, delegate follows its own or the inherited provider"

_reset
export CBOX_LOCAL_MODEL=off CBOX_HERMES_PROVIDER=openai
rc=0
out="$( ( _cbox_llm_use_cmd hyperqwen ) 2>&1)" || rc=$?
[ "$rc" = 0 ] || _fail "no consumer is not an error: $out"
case "$out" in *"nothing to switch"*) ;; *) _fail "no consumer must say so: $out" ;; esac
! grep -q 'FORCE-GLOBAL' "$CALLS" || _fail "nothing may be written when there is no consumer"
_ok "no consumer: reported, nothing written"

_reset
export CBOX_HYPERQWEN_MODE=off
rc=0
out="$( ( _cbox_llm_use_cmd hyperqwen ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "a backend that is off must be refused"
case "$out" in *"config set CBOX_HYPERQWEN_MODE=on"*) ;; *) _fail "the refusal must name the enable command: $out" ;; esac
! grep -q 'FORCE-GLOBAL' "$CALLS" || _fail "a refused switch must write nothing"
_reset
export CBOX_OLLAMA_MODE=off
rc=0
out="$( ( _cbox_llm_use_cmd ollama --model m ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "ollama off must be refused"
case "$out" in *"config set CBOX_OLLAMA_MODE=on"*) ;; *) _fail "the ollama refusal must name its enable command: $out" ;; esac
_ok "refusal: an off backend is refused with the exact enable command"

_reset
( _cbox_llm_use_cmd ollama --model qwen3:8b ) >/dev/null 2>&1 || _fail "explicit ollama model must work"
case "$(_set_line)" in *CBOX_LOCAL_MODEL_URL=http://ollama:11434*CBOX_LOCAL_MODEL_NAME=qwen3:8b*) ;; *) _fail "--model must win: $(_set_line)" ;; esac
_ok "ollama model: --model wins"

_reset
export CBOX_HERMES_MODEL_URL=http://ollama:11434 CBOX_HERMES_MODEL_NAME=llama3.3:70b
export CBOX_LOCAL_MODEL_URL=http://hyperqwen:18020 CBOX_LOCAL_MODEL_NAME=qwen3.8-27b
T_OLLAMA_MODELS="other:1b"
( _cbox_llm_use_cmd ollama ) >/dev/null 2>&1 || _fail "ollama use with a pointing consumer must work"
case "$(_set_line)" in *CBOX_LOCAL_MODEL_NAME=llama3.3:70b*) ;; *) _fail "the current ollama-pointing consumer model is next in line, a hyperqwen consumer is skipped: $(_set_line)" ;; esac
! grep -q '^docker exec' "$CALLS" || _fail "a consumer model must be found before asking ollama"
_ok "ollama model: the current ollama-pointing consumer model, hyperqwen-pointing consumers skipped"

_reset
T_OLLAMA_MODELS="only:7b"
( _cbox_llm_use_cmd ollama ) >/dev/null 2>&1 || _fail "a single listed model must be picked"
case "$(_set_line)" in *CBOX_LOCAL_MODEL_NAME=only:7b*) ;; *) _fail "the single model from ollama ls: $(_set_line)" ;; esac
grep -q '^docker exec -- ocid ollama ls$' "$CALLS" || _fail "the model list comes from the running owner container: $(cat "$CALLS")"
_ok "ollama model: the single model of the running owner"

_reset
T_OLLAMA_MODELS="a:1b b:2b"
rc=0
out="$( ( _cbox_llm_use_cmd ollama ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "several models and no hint must fail"
case "$out" in *"a:1b"*"b:2b"*"--model"*) ;; *) _fail "the error must list what was found and name --model: $out" ;; esac
! grep -q 'FORCE-GLOBAL' "$CALLS" || _fail "an unresolved model must write nothing"
_reset
T_OLLAMA_MODELS=""
rc=0
out="$( ( _cbox_llm_use_cmd ollama ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "no models and no hint must fail"
case "$out" in *"--model"*) ;; *) _fail "the empty-list error must name --model: $out" ;; esac
_reset
T_OLLAMA_CID=""
rc=0
( _cbox_llm_use_cmd ollama ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "a stopped owner and no hint must fail"
_ok "ollama model: several, none, or a stopped owner fail with a clear message and write nothing"

_reset
rc=0
( _cbox_llm_use_cmd hyperqwen --model other ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "hyperqwen serves one fixed model"
( _cbox_llm_use_cmd hyperqwen --model qwen3.8-27b ) >/dev/null 2>&1 || _fail "the served model name is accepted"
_ok "hyperqwen model: only the served name is accepted"

_reset
export CBOX_OLLAMA_GPU=cdi
out="$( ( _cbox_llm_use_cmd hyperqwen ) 2>&1)"
case "$out" in *WARN*"CBOX_OLLAMA_MODE=off"*) ;; *) _fail "use must print the overlap warning: $out" ;; esac
grep -q '^FORCE-GLOBAL' "$CALLS" || _fail "the overlap warning must not stop the switch"
_ok "overlap: warned, never refused"

_reset
T_MODE=isolated
T_OVERRIDE_KEYS="CBOX_HERMES_MODEL_URL CBOX_HERMES_MODEL_NAME"
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1
grep -q '^FORCE-GLOBAL .*CBOX_LOCAL_MODEL_URL' "$CALLS" || _fail "machine and global profile keys are written through the global path"
iso="$(grep '^SET ' "$CALLS" || true)"
case "$iso" in *CBOX_HERMES_MODEL_URL=http://hyperqwen:18020*CBOX_HERMES_MODEL_NAME=qwen3.8-27b*) ;; *) _fail "project keys pinned in the isolated project are switched there too: $iso" ;; esac
case "$iso" in *CBOX_LOCAL_MODEL_URL*|*DELEGATE*) _fail "unpinned keys must not become project overrides: $iso" ;; esac
_reset
T_MODE=isolated
T_OVERRIDE_KEYS=""
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1
! grep -q '^SET ' "$CALLS" || _fail "an isolated project without pinned keys needs no second write: $(cat "$CALLS")"
_ok "isolated project: global write plus a project write only for keys the project pins"

_reset
T_SET_RC=1
rc=0
( _cbox_llm_use_cmd hyperqwen ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "a failed config write must fail the switch"
_ok "a failed config write fails the switch"

_reset
T_INCONTAINER=1
rc=0
out="$( ( _cbox_llm_use_cmd hyperqwen ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "llm use is host-only"
case "$out" in *host-only*) ;; *) _fail "the refusal must say host-only: $out" ;; esac
_ok "llm use is host-only"

_reset
rc=0
( _cbox_llm_use_cmd ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "missing backend must fail"
rc=0
( _cbox_llm_use_cmd bogus ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "unknown backend must fail"
rc=0
( _cbox_llm_use_cmd ollama hyperqwen ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "two backends must fail"
rc=0
( _cbox_llm_use_cmd ollama --model ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "--model without a value must fail"
rc=0
( _cbox_llm_use_cmd ollama --nope ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "an unknown flag must fail"
_ok "usage errors fail"

_reset
export CBOX_HERMES_MODEL_URL=http://hyperqwen:18020 CBOX_HERMES_MODEL_NAME=qwen3.8-27b
export CBOX_LOCAL_MODEL_URL=http://ollama:11434 CBOX_LOCAL_MODEL_NAME=llama3
export CBOX_HERMES_DELEGATE_PROVIDER=nous
T_OLLAMA_MODELS="llama3"
out="$( ( _cbox_llm_status_cmd ) 2>&1)"
case "$out" in *"ollama: mode=on"*"url=http://ollama:11434"*) ;; *) _fail "status lists ollama: $out" ;; esac
case "$out" in *"hyperqwen: mode=on"*"model=qwen3.8-27b"*"context=65536"*) ;; *) _fail "status lists hyperqwen with model and context: $out" ;; esac
case "$out" in *"consumer local-model: provider=local backend=ollama"*) ;; *) _fail "status shows the local-model target: $out" ;; esac
case "$out" in *"consumer hermes: provider=local backend=hyperqwen"*) ;; *) _fail "status shows the hermes target: $out" ;; esac
case "$out" in *"consumer hermes-delegate: provider=other-provider backend=unset"*) ;; *) _fail "status shows the delegate target: $out" ;; esac
_ok "status: one line per backend plus the target of each consumer"

_reset
rc=0
( llm_cmd bogus ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "an unknown llm verb must fail"
_ok "llm: unknown verb fails with usage"

echo "PASS: all llm use checks"
