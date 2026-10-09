#!/usr/bin/env bash
set -euo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

for _v in $(compgen -v CBOX_) $(compgen -v OLLAMA_); do
  unset "$_v"
done
unset _v

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

SETUP_SH="$REAL/lib/cbox-setup.sh"

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

SRC_ALL=""
for fn in _setup_suggest_backend _setup_prefill_url _setup_prefill_model _setup_backend_hint_note \
  _setup_gpu_devices_overlap _setup_backend_overlap_note _setup_ask_validated \
  step_hyperqwen step_ollama step_local_model step_hermes step_hermes_delegate \
  _classic_feature_on _classic_feature_off; do
  body="$(_extract_fn "$SETUP_SH" "$fn")"
  [ -n "$body" ] || _fail "cannot extract $fn from lib/cbox-setup.sh"
  SRC_ALL="$SRC_ALL
$body"
done

HOME="$TMPBASE/home"
export HOME
mkdir -p "$HOME/models-dir"

_defaults() {
  CBOX_OLLAMA_MODE=off
  CBOX_OLLAMA_IMAGE=ollama/ollama:0.33.3
  CBOX_OLLAMA_GPU=off
  CBOX_OLLAMA_GPU_DEVICE=all
  CBOX_OLLAMA_STORE=dedicated
  CBOX_OLLAMA_STORE_PATH=""
  CBOX_OLLAMA_PORT=11434
  CBOX_OLLAMA_NUM_PARALLEL=1
  CBOX_OLLAMA_CONTEXT_LENGTH=65536
  CBOX_OLLAMA_FLASH_ATTENTION=off
  CBOX_OLLAMA_KV_CACHE_TYPE=f16
  CBOX_OLLAMA_KEEP_ALIVE=30m
  CBOX_HYPERQWEN_MODE=off
  CBOX_HYPERQWEN_IMAGE=ghcr.io/syv-ai/hyperqwen:sha-53557bc
  CBOX_HYPERQWEN_GPU_DEVICE=all
  CBOX_HYPERQWEN_MODELS_PATH=""
  CBOX_HYPERQWEN_SPEC=dflash2
  CBOX_HYPERQWEN_CTX=fast
  CBOX_HYPERQWEN_MAX_LEN=""
  CBOX_HYPERQWEN_SHM_SIZE=8g
  CBOX_HYPERQWEN_KV_OFFLOAD=off
  CBOX_HYPERQWEN_KV_OFFLOAD_MIB=19072
  CBOX_HYPERQWEN_RAM_RESERVE_GIB=16
  CBOX_LOCAL_MODEL=off
  CBOX_LOCAL_MODEL_URL=""
  CBOX_LOCAL_MODEL_NAME=""
  CBOX_LOCAL_MODEL_TIMEOUT_SEC=600
  CBOX_EGRESS_MODE=off
  CBOX_HERMES=off
  CBOX_HERMES_VERSION=latest
  CBOX_HERMES_PROVIDER=local
  CBOX_HERMES_MODEL_URL=""
  CBOX_HERMES_MODEL_NAME=""
  CBOX_HERMES_EFFORT=medium
  CBOX_HERMES_DELEGATE=off
  CBOX_HERMES_DELEGATE_PROVIDER=""
  CBOX_HERMES_DELEGATE_BASE_URL=""
  CBOX_HERMES_DELEGATE_MODEL=""
  CBOX_HERMES_DELEGATE_MODE=""
  CBOX_HERMES_HOOKS=off
}

_stubs() {
  note() { printf 'NOTE: %s\n' "$*"; }
  warn() { printf 'WARN: %s\n' "$*"; }
  ask() { _next "$1" "${2-}"; }
  ask_choice() { _next "$1" "${2-}"; }
  _next() {
    printf '%s\t%s\n' "$1" "$2" >> "$H_LOG"
    if [ "$H_I" -ge "${#H_ANS[@]}" ]; then
      echo "QUEUE EXHAUSTED at prompt: $1"
      exit 99
    fi
    ASK_VALUE="${H_ANS[$H_I]}"
    H_I=$((H_I + 1))
    if [ "$ASK_VALUE" = "__KEEP__" ]; then
      ASK_VALUE="${2-}"
    fi
  }
  H_I=0
  _cbox_no_cdi() { return 1; }
  container_target_ok() { return 1; }
  mcp_apply_selection() { :; }
  section_dep_gate() { DEP_ACTION=none; DEP_REASON=""; }
  path_input() { PATH_VALUE=""; return 1; }
  _cbox_reg_validate_var() {
    local key="$1" val="$2"
    case "$key" in
      CBOX_HYPERQWEN_IMAGE)
        case "$val" in
          ''|-*|*[[:space:]]*) printf 'not an image reference'; return 1 ;;
        esac
        ;;
      CBOX_HYPERQWEN_GPU_DEVICE|CBOX_OLLAMA_GPU_DEVICE)
        printf '%s' "$val" | grep -Eq '^(all|([0-9]{1,2}|GPU-[0-9a-fA-F-]+)(,([0-9]{1,2}|GPU-[0-9a-fA-F-]+))*)$' \
          || { printf 'expected all or a comma list of GPU ids'; return 1; }
        ;;
      CBOX_HYPERQWEN_MODELS_PATH)
        [ -z "$val" ] && return 0
        case "$val" in
          /*) [ -d "$val" ] && [ ! -L "$val" ] || { printf 'not an existing directory'; return 1; } ;;
          *) printf 'must be absolute'; return 1 ;;
        esac
        ;;
      CBOX_HYPERQWEN_MAX_LEN)
        [ -z "$val" ] && return 0
        printf '%s' "$val" | grep -Eq '^[1-9][0-9]*$' || { printf 'expected a positive integer'; return 1; }
        ;;
      CBOX_HYPERQWEN_SHM_SIZE)
        printf '%s' "$val" | grep -Eq '^[1-9][0-9]*[kmg]?$' || { printf 'expected <n>[kmg]'; return 1; }
        ;;
      CBOX_HYPERQWEN_KV_OFFLOAD_MIB)
        printf '%s' "$val" | grep -Eq '^[0-9]{4,5}$' || { printf 'expected integer 1024..49152'; return 1; }
        ;;
      CBOX_HYPERQWEN_RAM_RESERVE_GIB)
        printf '%s' "$val" | grep -Eq '^(8|9|1[0-9]|2[0-9]|3[0-2])$' || { printf 'expected integer 8..32'; return 1; }
        ;;
    esac
    return 0
  }
  _cbox_local_backend_active() {
    case "$1" in
      hyperqwen) [ "${CBOX_HYPERQWEN_MODE:-off}" = on ] ;;
      ollama) [ "${CBOX_OLLAMA_MODE:-off}" = on ] ;;
      *) return 1 ;;
    esac
  }
  _cbox_local_backend_url() {
    case "$1" in
      hyperqwen) printf 'http://hyperqwen:18020' ;;
      ollama) printf 'http://ollama:11434' ;;
    esac
  }
  _cbox_local_backend_served_model() {
    case "$1" in
      hyperqwen) printf 'qwen3.8-27b' ;;
      *) : ;;
    esac
  }
  _cbox_local_backend_of_url() {
    case "$1" in
      http://hyperqwen:18020|http://hyperqwen:18020/*) printf 'hyperqwen' ;;
      http://ollama:11434|http://ollama:11434/*) printf 'ollama' ;;
      *) return 1 ;;
    esac
  }
}

_run() {
  local name="$1" fnname="$2"
  shift 2
  H_LOG="$TMPBASE/$name.log"
  : > "$H_LOG"
  (
    set +eu
    _defaults
    _stubs
    eval "$SRC_ALL"
    if declare -F _case_setup >/dev/null 2>&1; then
      _case_setup
    fi
    H_ANS=("$@")
    "$fnname"
    printf 'RC=%s\n' "$?"
    for v in $(compgen -v CBOX_); do
      printf 'VAR %s=%s\n' "$v" "${!v}"
    done
  ) 2>&1
}

_var() { printf '%s\n' "$1" | sed -n "s/^VAR $2=//p" | head -1; }
_has() { printf '%s\n' "$1" | grep -qF -- "$2"; }
_prefill() { awk -F'\t' -v p="$2" 'index($1, p) { print $2; exit }' "$TMPBASE/$1.log"; }
_prompt_count() { grep -c . "$TMPBASE/$1.log" || true; }

OUT="$(_run off step_hyperqwen off)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODE)" = off ] || _fail "off path: mode should stay off"
[ "$(_prompt_count off)" = 1 ] || _fail "off path: only the mode prompt expected, got $(_prompt_count off)"
_has "$OUT" "infra-reconcile" && _fail "off path: unchanged section should not print the reconcile hint"
[ "$(_var "$OUT" CBOX_HYPERQWEN_IMAGE)" = "ghcr.io/syv-ai/hyperqwen:sha-53557bc" ] || _fail "off path: image changed"
_ok "step_hyperqwen off path asks only the mode and changes nothing"

OUT="$(_run on step_hyperqwen on ghcr.io/syv-ai/hyperqwen:sha-aaaaaaa 1 "$HOME/models-dir" mtp long 150000 16g __KEEP__ __KEEP__)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODE)" = on ] || _fail "on path: mode"
[ "$(_var "$OUT" CBOX_HYPERQWEN_IMAGE)" = "ghcr.io/syv-ai/hyperqwen:sha-aaaaaaa" ] || _fail "on path: image"
[ "$(_var "$OUT" CBOX_HYPERQWEN_GPU_DEVICE)" = 1 ] || _fail "on path: gpu device"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODELS_PATH)" = "$HOME/models-dir" ] || _fail "on path: models path"
[ "$(_var "$OUT" CBOX_HYPERQWEN_SPEC)" = mtp ] || _fail "on path: spec"
[ "$(_var "$OUT" CBOX_HYPERQWEN_CTX)" = long ] || _fail "on path: ctx"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MAX_LEN)" = 150000 ] || _fail "on path: max len"
[ "$(_var "$OUT" CBOX_HYPERQWEN_SHM_SIZE)" = 16g ] || _fail "on path: shm"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD)" = off ] || _fail "on path: kv offload"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD_MIB)" = "19072" ] || _fail "on path: kv offload mib"
[ "$(_var "$OUT" CBOX_HYPERQWEN_RAM_RESERVE_GIB)" = "16" ] || _fail "on path: ram reserve gib"
_has "$OUT" "cbox hyperqwen reconcile" || _fail "on path: reconcile hint missing"
_has "$OUT" "cbox llm use hyperqwen" || _fail "on path: llm use hint missing"
[ "$(_prompt_count on)" = 9 ] || _fail "on path: expected 9 prompts, got $(_prompt_count on)"
_ok "step_hyperqwen on path asks image, device, models path, spec, ctx, max len, shm and writes every key"

OUT="$(_run keep step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODE)" = on ] || _fail "keep path: mode"
[ "$(_var "$OUT" CBOX_HYPERQWEN_IMAGE)" = "ghcr.io/syv-ai/hyperqwen:sha-53557bc" ] || _fail "keep path: image"
[ "$(_var "$OUT" CBOX_HYPERQWEN_GPU_DEVICE)" = all ] || _fail "keep path: device"
[ -z "$(_var "$OUT" CBOX_HYPERQWEN_MODELS_PATH)" ] || _fail "keep path: models path should stay empty"
[ -z "$(_var "$OUT" CBOX_HYPERQWEN_MAX_LEN)" ] || _fail "keep path: max len should stay empty"
[ "$(_var "$OUT" CBOX_HYPERQWEN_SHM_SIZE)" = 8g ] || _fail "keep path: shm"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD)" = off ] || _fail "keep path: kv offload"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD_MIB)" = "19072" ] || _fail "keep path: kv offload mib"
[ "$(_var "$OUT" CBOX_HYPERQWEN_RAM_RESERVE_GIB)" = "16" ] || _fail "keep path: ram reserve gib"
[ "$(_prefill keep 'models directory')" = "" ] || _fail "keep path: models path prefill should be empty"
_has "$OUT" "about 20 GB" || _fail "keep path: models path note should explain the ~20 GB size"
_ok "step_hyperqwen defaults survive Enter on every prompt and the models path note names the size"

OUT="$(_run tilde step_hyperqwen on __KEEP__ __KEEP__ "~/models-dir" __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODELS_PATH)" = "$HOME/models-dir" ] || _fail "tilde: models path should expand to \$HOME"
_ok "step_hyperqwen expands a leading ~/ in the models path before validating"
_has "$OUT" "home directory itself" && _fail "tilde: a ~/ subdirectory must not trigger the home-directory refusal"

OUT="$(_run tildehome1 step_hyperqwen on __KEEP__ __KEEP__ "~" "$HOME/models-dir" __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
[ "$(printf '%s\n' "$OUT" | grep -c "home directory itself")" = 1 ] || _fail "tilde bare: bare ~ must be refused with the dedicated-directory warning"
[ "$(grep -c "host models directory" "$TMPBASE/tildehome1.log" || true)" = 2 ] || _fail "tilde bare: the models prompt must be re-asked after refusing bare ~"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODELS_PATH)" = "$HOME/models-dir" ] || _fail "tilde bare: the dedicated directory must be accepted after the re-ask"
[ "$(_prompt_count tildehome1)" = 10 ] || _fail "tilde bare: expected 10 prompts, got $(_prompt_count tildehome1)"
_ok "step_hyperqwen refuses bare ~ (the home directory) and re-asks until a dedicated directory is given"

OUT="$(_run tildehome2 step_hyperqwen on __KEEP__ __KEEP__ "~/" "~/bogus" "$HOME/models-dir" __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
[ "$(printf '%s\n' "$OUT" | grep -c "home directory itself")" = 1 ] || _fail "tilde empty: ~/ must be refused with the dedicated-directory warning"
[ "$(printf '%s\n' "$OUT" | grep -c "not an existing directory")" = 1 ] || _fail "tilde empty: the expanded ~/bogus must be refused by the directory check"
[ "$(grep -c "host models directory" "$TMPBASE/tildehome2.log" || true)" = 3 ] || _fail "tilde empty: the models prompt must be re-asked after each refusal"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODELS_PATH)" = "$HOME/models-dir" ] || _fail "tilde empty: the dedicated directory must be accepted after the re-asks"
[ "$(_prompt_count tildehome2)" = 11 ] || _fail "tilde empty: expected 11 prompts, got $(_prompt_count tildehome2)"
_ok "step_hyperqwen refuses ~/ (nothing after the slash) and keeps re-asking until a dedicated directory is given"

OUT="$(_run invalid step_hyperqwen on -bad "has space" ghcr.io/x/y:1 foo 999 0,1 /nonexistent relative "" dflash2 fast 0 abc 70000 8x "" 4g on 500 25000 33 30)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_IMAGE)" = "ghcr.io/x/y:1" ] || _fail "invalid: image should be re-asked until valid"
[ "$(_var "$OUT" CBOX_HYPERQWEN_GPU_DEVICE)" = "0,1" ] || _fail "invalid: gpu device should be re-asked until valid"
[ -z "$(_var "$OUT" CBOX_HYPERQWEN_MODELS_PATH)" ] || _fail "invalid: models path should end empty"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MAX_LEN)" = 70000 ] || _fail "invalid: max len should be re-asked until valid"
[ "$(_var "$OUT" CBOX_HYPERQWEN_SHM_SIZE)" = 4g ] || _fail "invalid: shm should be re-asked until the second try"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD_MIB)" = "25000" ] || _fail "invalid: kv offload mib should be re-asked until valid"
[ "$(_var "$OUT" CBOX_HYPERQWEN_RAM_RESERVE_GIB)" = "30" ] || _fail "invalid: ram reserve should be re-asked until valid"
[ "$(printf '%s\n' "$OUT" | grep -c '^WARN: invalid')" = 12 ] || _fail "invalid: expected 12 invalid-value warnings, got $(printf '%s\n' "$OUT" | grep -c '^WARN: invalid')"
_ok "step_hyperqwen re-asks every validated prompt until the validator accepts, never keeps a bad value"

OUT="$(_run nocdi step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
_has "$OUT" "CDI is set up" && _fail "cdi present: no CDI warning expected"
_case_setup() { _cbox_no_cdi() { return 0; }; }
OUT="$(_run nocdi2 step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
unset -f _case_setup
_has "$OUT" "CDI is set up" || _fail "no cdi: warning about CDI expected"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODE)" = on ] || _fail "no cdi: warning must not refuse"
_ok "step_hyperqwen warns about missing CDI without refusing"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_HYPERQWEN_KV_OFFLOAD=off; }
OUT="$(_run ko1 step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ off __KEEP__)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD)" = off ] || _fail "kv offload: offload should stay off"
[ -z "$(_prefill ko1 'KV offload RAM size')" ] || [ "$(_prefill ko1 'KV offload RAM size')" = "" ] || _fail "kv offload: ram size must not be asked when offload is off"
[ -z "$(_prefill ko1 'host RAM always reserved')" ] || [ "$(_prefill ko1 'host RAM always reserved')" = "" ] || _fail "kv offload: ram reserve must not be asked when offload is off"
_ok "step_hyperqwen with KV offload off: size and reserve not asked"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_HYPERQWEN_KV_OFFLOAD=off; }
OUT="$(_run ko2 step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ on 20000 12)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD)" = on ] || _fail "kv offload on: offload should be on"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD_MIB)" = "20000" ] || _fail "kv offload on: offload mib should be 20000"
[ "$(_var "$OUT" CBOX_HYPERQWEN_RAM_RESERVE_GIB)" = "12" ] || _fail "kv offload on: ram reserve should be 12"
[ "$(_prompt_count ko2)" = 11 ] || _fail "kv offload on: expected 11 prompts when offload is on, got $(_prompt_count ko2)"
_ok "step_hyperqwen with KV offload on: all three values asked and set"

OUT="$(_run ko3 step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ on 500 25000 33 30)"
[ "$(_var "$OUT" CBOX_HYPERQWEN_KV_OFFLOAD_MIB)" = "25000" ] || _fail "kv offload invalid: offload mib should eventually be 25000"
[ "$(_var "$OUT" CBOX_HYPERQWEN_RAM_RESERVE_GIB)" = "30" ] || _fail "kv offload invalid: ram reserve should eventually be 30"
[ "$(printf '%s\n' "$OUT" | grep -c '^WARN: invalid')" -ge 1 ] || _fail "kv offload invalid: must warn about invalid value"
_ok "step_hyperqwen KV offload size and reserve: invalid values are re-asked"
unset -f _case_setup

_setup_overlap_probe() {
  (
    set +eu
    eval "$(_extract_fn "$SETUP_SH" _setup_gpu_devices_overlap)"
    _setup_gpu_devices_overlap "$1" "$2" && echo overlap || echo disjoint
  )
}
[ "$(_setup_overlap_probe all 0)" = overlap ] || _fail "overlap: all vs 0"
[ "$(_setup_overlap_probe 0 all)" = overlap ] || _fail "overlap: 0 vs all"
[ "$(_setup_overlap_probe 0,1 1)" = overlap ] || _fail "overlap: 0,1 vs 1"
[ "$(_setup_overlap_probe GPU-ab12 GPU-ab12)" = overlap ] || _fail "overlap: same uuid"
[ "$(_setup_overlap_probe 0 1)" = disjoint ] || _fail "overlap: 0 vs 1"
[ "$(_setup_overlap_probe 0,2 1,3)" = disjoint ] || _fail "overlap: 0,2 vs 1,3"
[ "$(_setup_overlap_probe GPU-ab12 GPU-cd34)" = disjoint ] || _fail "overlap: different uuids"
_ok "device set overlap: all intersects everything, lists intersect on a shared id"

_case_setup() { CBOX_OLLAMA_MODE=on; CBOX_OLLAMA_GPU=cdi; CBOX_OLLAMA_GPU_DEVICE=all; }
OUT="$(_run ov1 step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
_has "$OUT" "share a GPU" || _fail "overlap note: ollama cdi all + hyperqwen all must warn"
_has "$OUT" "CBOX_OLLAMA_MODE=off" || _fail "overlap note: must recommend CBOX_OLLAMA_MODE=off"
[ "$(_var "$OUT" CBOX_HYPERQWEN_MODE)" = on ] || _fail "overlap note: must never refuse"

_case_setup() { CBOX_OLLAMA_MODE=on; CBOX_OLLAMA_GPU=cdi; CBOX_OLLAMA_GPU_DEVICE=1; }
OUT="$(_run ov2 step_hyperqwen on __KEEP__ 0 __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
_has "$OUT" "share a GPU" && _fail "overlap note: separate cards must not warn"

_case_setup() { CBOX_OLLAMA_MODE=on; CBOX_OLLAMA_GPU=off; CBOX_OLLAMA_GPU_DEVICE=all; }
OUT="$(_run ov3 step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
_has "$OUT" "share a GPU" && _fail "overlap note: ollama without CDI (CPU) must not warn"

_case_setup() { CBOX_OLLAMA_MODE=off; CBOX_OLLAMA_GPU=cdi; CBOX_OLLAMA_GPU_DEVICE=all; }
OUT="$(_run ov4 step_hyperqwen on __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
_has "$OUT" "share a GPU" && _fail "overlap note: ollama off must not warn"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_HYPERQWEN_GPU_DEVICE=0; }
OUT="$(_run ov5 step_ollama on __KEEP__ cdi all __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
_has "$OUT" "share a GPU" || _fail "overlap note: step_ollama with cdi all against hyperqwen on must warn"
unset -f _case_setup
_ok "overlap note: warns on a shared card from either section, silent for separate cards, cpu ollama or ollama off, never refuses"

_case_setup() { CBOX_OLLAMA_GPU_DEVICE=all; }
OUT="$(_run oll1 step_ollama on __KEEP__ cdi 1 dedicated __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
unset -f _case_setup
[ "$(_var "$OUT" CBOX_OLLAMA_GPU_DEVICE)" = 1 ] || _fail "step_ollama: gpu device should be written when CBOX_OLLAMA_GPU=cdi"
_has "$OUT" "cbox ollama reconcile" || _fail "step_ollama: a changed device must print the reconcile hint"
_prefill oll1 "ollama GPU device" | grep -qx all || _fail "step_ollama: gpu device prefill should be the current value"
OUT="$(_run oll2 step_ollama on __KEEP__ off dedicated __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
grep -qF "ollama GPU device" "$TMPBASE/oll2.log" && _fail "step_ollama: gpu device must not be asked when CBOX_OLLAMA_GPU is off"
[ "$(_var "$OUT" CBOX_OLLAMA_GPU_DEVICE)" = all ] || _fail "step_ollama: gpu device must stay all when not asked"
OUT="$(_run oll3 step_ollama on __KEEP__ cdi bogus 99x 1,2 dedicated __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__ __KEEP__)"
[ "$(_var "$OUT" CBOX_OLLAMA_GPU_DEVICE)" = "1,2" ] || _fail "step_ollama: invalid gpu device must be re-asked"
_ok "step_ollama asks CBOX_OLLAMA_GPU_DEVICE only for cdi, re-asks invalid values and flags the change"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_OLLAMA_MODE=on; }
OUT="$(_run lm1 step_local_model on __KEEP__ __KEEP__ __KEEP__)"
[ "$(_prefill lm1 'local model endpoint url')" = "http://hyperqwen:18020" ] || _fail "local-model: url prefill should prefer hyperqwen, got '$(_prefill lm1 'local model endpoint url')'"
[ "$(_prefill lm1 'local model name')" = "qwen3.8-27b" ] || _fail "local-model: model prefill should be the hyperqwen served model"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL_URL)" = "http://hyperqwen:18020" ] || _fail "local-model: accepted url"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL_NAME)" = "qwen3.8-27b" ] || _fail "local-model: accepted model"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL)" = on ] || _fail "local-model: delegate should stay on"

_case_setup() { CBOX_HYPERQWEN_MODE=off; CBOX_OLLAMA_MODE=on; }
OUT="$(_run lm2 step_local_model on __KEEP__ qwen2.5:7b __KEEP__)"
[ "$(_prefill lm2 'local model endpoint url')" = "http://ollama:11434" ] || _fail "local-model: url prefill should fall back to ollama"
[ -z "$(_prefill lm2 'local model name')" ] || _fail "local-model: no model suggestion for ollama"

_case_setup() { CBOX_HYPERQWEN_MODE=off; CBOX_OLLAMA_MODE=off; }
OUT="$(_run lm3 step_local_model on http://x:1 m __KEEP__)"
[ -z "$(_prefill lm3 'local model endpoint url')" ] || _fail "local-model: no backend active means no url suggestion"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_LOCAL_MODEL=on; CBOX_LOCAL_MODEL_URL=http://ollama:11434; }
OUT="$(_run lm4 step_local_model on __KEEP__ __KEEP__ __KEEP__)"
[ "$(_prefill lm4 'local model endpoint url')" = "http://ollama:11434" ] || _fail "local-model: a set url must not be replaced by the suggestion"
[ -z "$(_prefill lm4 'local model name')" ] || _fail "local-model: a url pointing at ollama must not suggest the hyperqwen model"
_has "$OUT" "WARN: local model url or name left empty" || _fail "local-model: empty name should keep the delegate off"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_LOCAL_MODEL=on; CBOX_LOCAL_MODEL_URL=http://hyperqwen:18020; CBOX_LOCAL_MODEL_NAME=custom; }
OUT="$(_run lm5 step_local_model on __KEEP__ __KEEP__ __KEEP__)"
[ "$(_prefill lm5 'local model name')" = custom ] || _fail "local-model: a set model name must not be replaced"
_ok "step_local_model suggests the first active backend (hyperqwen before ollama) for an empty url and its served model for an empty name, never overriding a set value"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_OLLAMA_MODE=on; }
OUT="$(_run he1 step_hermes on __KEEP__ local __KEEP__ __KEEP__ __KEEP__)"
[ "$(_prefill he1 'hermes local model endpoint url')" = "http://hyperqwen:18020" ] || _fail "hermes: url prefill should prefer hyperqwen"
[ "$(_prefill he1 'hermes model name')" = "qwen3.8-27b" ] || _fail "hermes: model prefill should be the hyperqwen served model"
[ "$(_var "$OUT" CBOX_HERMES_MODEL_URL)" = "http://hyperqwen:18020" ] || _fail "hermes: accepted url"
[ "$(_var "$OUT" CBOX_HERMES_MODEL_NAME)" = "qwen3.8-27b" ] || _fail "hermes: accepted model"

_case_setup() { CBOX_HYPERQWEN_MODE=off; CBOX_OLLAMA_MODE=on; }
OUT="$(_run he2 step_hermes on __KEEP__ local __KEEP__ m __KEEP__)"
[ "$(_prefill he2 'hermes local model endpoint url')" = "http://ollama:11434" ] || _fail "hermes: url prefill should fall back to ollama"
[ -z "$(_prefill he2 'hermes model name')" ] || _fail "hermes: no model suggestion for ollama"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_LOCAL_MODEL_URL=http://remote:1; }
OUT="$(_run he3 step_hermes on __KEEP__ local __KEEP__ __KEEP__ __KEEP__)"
[ "$(_prefill he3 'hermes local model endpoint url')" = "http://remote:1" ] || _fail "hermes: the local-model url keeps priority over the suggestion"

_case_setup() { CBOX_HYPERQWEN_MODE=on; }
OUT="$(_run he4 step_hermes on __KEEP__ openai __KEEP__ __KEEP__)"
[ -z "$(_prefill he4 'hermes model name')" ] || _fail "hermes: a non-local provider must not suggest a local model"
_ok "step_hermes follows the same suggestion rules and only for the local provider"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_OLLAMA_MODE=on; }
OUT="$(_run de1 step_hermes_delegate on local __KEEP__ __KEEP__ qa)"
[ "$(_prefill de1 'hermes delegate local model endpoint url')" = "http://hyperqwen:18020" ] || _fail "delegate: url prefill should prefer hyperqwen"
[ "$(_prefill de1 'hermes delegate model name')" = "qwen3.8-27b" ] || _fail "delegate: model prefill should be the hyperqwen served model"
[ "$(_var "$OUT" CBOX_HERMES_DELEGATE_BASE_URL)" = "http://hyperqwen:18020" ] || _fail "delegate: accepted url"

_case_setup() { CBOX_HYPERQWEN_MODE=off; CBOX_OLLAMA_MODE=on; }
OUT="$(_run de2 step_hermes_delegate on local __KEEP__ m qa)"
[ "$(_prefill de2 'hermes delegate local model endpoint url')" = "http://ollama:11434" ] || _fail "delegate: url prefill should fall back to ollama"
[ -z "$(_prefill de2 'hermes delegate model name')" ] || _fail "delegate: no model suggestion for ollama"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_HERMES_MODEL_URL=http://ollama:11434; CBOX_HERMES_MODEL_NAME=llama; }
OUT="$(_run de3 step_hermes_delegate on local __KEEP__ __KEEP__ qa)"
[ "$(_prefill de3 'hermes delegate local model endpoint url')" = "http://ollama:11434" ] || _fail "delegate: hermes url keeps priority over the suggestion"
[ "$(_prefill de3 'hermes delegate model name')" = llama ] || _fail "delegate: hermes model keeps priority over the suggestion"
_ok "step_hermes_delegate follows the same suggestion rules and keeps the hermes inheritance first"
unset -f _case_setup

_preset() {
  local name="$1"
  shift
  H_LOG="$TMPBASE/$name.log"
  : > "$H_LOG"
  (
    set +eu
    _defaults
    _stubs
    eval "$SRC_ALL"
    _case_setup
    H_ANS=(__KEEP__)
    _classic_feature_on local-model
    _classic_feature_on hermes
    _classic_feature_on hermes-delegate
    for v in $(compgen -v CBOX_); do
      printf 'VAR %s=%s\n' "$v" "${!v}"
    done
  ) 2>&1
}

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_OLLAMA_MODE=off; }
OUT="$(_preset pr1)"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL)" = on ] || _fail "preset hyperqwen: local model on"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL_URL)" = "http://hyperqwen:18020" ] || _fail "preset hyperqwen: url, got $(_var "$OUT" CBOX_LOCAL_MODEL_URL)"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL_NAME)" = "qwen3.8-27b" ] || _fail "preset hyperqwen: model name"
[ "$(_prefill pr1 'local model name')" = "qwen3.8-27b" ] || _fail "preset hyperqwen: model prompt prefill"
[ "$(_var "$OUT" CBOX_OLLAMA_MODE)" = off ] || _fail "preset hyperqwen: ollama must not be switched on"
[ "$(_var "$OUT" CBOX_HERMES_MODEL_URL)" = "http://hyperqwen:18020" ] || _fail "preset hyperqwen: hermes url"
[ "$(_var "$OUT" CBOX_HERMES_MODEL_NAME)" = "qwen3.8-27b" ] || _fail "preset hyperqwen: hermes model"
[ "$(_var "$OUT" CBOX_HERMES_DELEGATE_BASE_URL)" = "http://hyperqwen:18020" ] || _fail "preset hyperqwen: delegate url"
[ "$(_var "$OUT" CBOX_HERMES_DELEGATE_MODEL)" = "qwen3.8-27b" ] || _fail "preset hyperqwen: delegate model"
_has "$OUT" "cbox hyperqwen prepare" || _fail "preset hyperqwen: prepare hint"
_has "$OUT" "cbox ollama pull" && _fail "preset hyperqwen: must not tell the user to pull an ollama model"

_case_setup() { CBOX_HYPERQWEN_MODE=on; CBOX_OLLAMA_MODE=on; }
OUT="$(_preset pr2)"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL_URL)" = "http://hyperqwen:18020" ] || _fail "preset both: hyperqwen url wins"
[ "$(_var "$OUT" CBOX_OLLAMA_MODE)" = on ] || _fail "preset both: ollama stays on"

_case_setup() { CBOX_HYPERQWEN_MODE=off; CBOX_OLLAMA_MODE=off; }
OUT="$(_preset pr3)"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL_URL)" = "http://ollama:11434" ] || _fail "preset ollama: url"
[ "$(_var "$OUT" CBOX_OLLAMA_MODE)" = on ] || _fail "preset ollama: ollama switched on as before"
[ "$(_var "$OUT" CBOX_OLLAMA_GPU)" = cdi ] || _fail "preset ollama: gpu cdi when CDI present"
[ "$(_var "$OUT" CBOX_OLLAMA_STORE)" = dedicated ] || _fail "preset ollama: dedicated store"
[ "$(_var "$OUT" CBOX_HERMES_MODEL_URL)" = "http://ollama:11434" ] || _fail "preset ollama: hermes url"
_has "$OUT" "cbox ollama pull" || _fail "preset ollama: pull hint"
_has "$OUT" "cbox hyperqwen prepare" && _fail "preset ollama: no hyperqwen hint"

_case_setup() { unset CBOX_HYPERQWEN_MODE; CBOX_OLLAMA_MODE=off; }
OUT="$(_preset pr4)"
[ "$(_var "$OUT" CBOX_LOCAL_MODEL_URL)" = "http://ollama:11434" ] || _fail "preset with the hyperqwen mode unset: ollama url"
_ok "classic preset local-model picks hyperqwen url and model when CBOX_HYPERQWEN_MODE=on and keeps the ollama behaviour otherwise"

_ok_reg=0
(
  set +eu
  . "$REAL/templates/validator_lib.sh"
  . "$REAL/templates/validator_dispatch.sh"
  _cbox_reg_validate_var CBOX_HYPERQWEN_SHM_SIZE 8g >/dev/null 2>&1 || exit 2
  _cbox_reg_validate_var CBOX_HYPERQWEN_SHM_SIZE zz >/dev/null 2>&1 && exit 2
  exit 0
) && _ok_reg=1 || _ok_reg=0
if [ "$_ok_reg" = 1 ]; then
  RS="$TMPBASE/real_validator.sh"
  {
    printf 'set +eu\n'
    printf '. "%s/templates/validator_lib.sh"\n' "$REAL"
    printf '. "%s/templates/validator_dispatch.sh"\n' "$REAL"
    printf '%s\n' "$(_extract_fn "$SETUP_SH" _setup_ask_validated)"
    cat <<'EOF'
warn() { printf 'WARN: %s\n' "$*"; }
ask() { ASK_VALUE="${H_REAL[$H_RI]}"; H_RI=$((H_RI + 1)); }
H_RI=0
H_REAL=("-bad" "ghcr.io/syv-ai/hyperqwen:sha-1234567")
_setup_ask_validated CBOX_HYPERQWEN_IMAGE "p" ""
printf 'IMAGE=%s\n' "$ASK_VALUE"
H_RI=0
H_REAL=("zz" "0" "all")
_setup_ask_validated CBOX_HYPERQWEN_GPU_DEVICE "p" ""
printf 'DEVICE=%s\n' "$ASK_VALUE"
H_RI=0
H_REAL=("0" "12x" "2g")
_setup_ask_validated CBOX_HYPERQWEN_SHM_SIZE "p" ""
printf 'SHM=%s\n' "$ASK_VALUE"
H_RI=0
H_REAL=("0" "-5" "4096")
_setup_ask_validated CBOX_HYPERQWEN_MAX_LEN "p" ""
printf 'MAXLEN=%s\n' "$ASK_VALUE"
EOF
  } > "$RS"
  ROUT="$(bash "$RS" 2>&1)"
  _has "$ROUT" "IMAGE=ghcr.io/syv-ai/hyperqwen:sha-1234567" || _fail "real validators: image loop: $ROUT"
  _has "$ROUT" "DEVICE=0" || _fail "real validators: device loop: $ROUT"
  _has "$ROUT" "SHM=2g" || _fail "real validators: shm loop: $ROUT"
  _has "$ROUT" "MAXLEN=4096" || _fail "real validators: max len loop: $ROUT"
  _ok "real registry validators drive the same re-ask loop for image, gpu device, shm size and max len"
else
  echo "skip: real registry validators do not know the CBOX_HYPERQWEN keys yet (generated validators not committed)"
fi

WIRING="$(awk '/^run_local_wizard_subset\(\) \{/,/^}$/' "$SETUP_SH")"
case "$WIRING" in
  *step_hyperqwen*) _fail "wiring: the isolated per-project wizard must never call step_hyperqwen" ;;
esac
BODY="$(_extract_fn "$SETUP_SH" step_hyperqwen)"
case "$BODY" in
  *mkdir*|*'docker '*|*docker-compose*) _fail "wiring: step_hyperqwen must only stage config values" ;;
esac
case "$BODY" in
  *'CBOX_HYPERQWEN_MODE" = on'*) ;;
  *) _fail "wiring: step_hyperqwen follow-up prompts must be gated behind CBOX_HYPERQWEN_MODE=on" ;;
esac
_ok "wiring: step_hyperqwen is never called by the isolated wizard, has no side effects and gates its prompts behind mode on"

echo "PASS: all hyperqwen setup checks"
