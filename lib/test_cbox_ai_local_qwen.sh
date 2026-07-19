#!/usr/bin/env bash
set -uo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_reset_env() {
  unset CBOX_LOCAL_MODEL CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME
  CBOX_AI_PROMPT=""
}

source "$INSTALL_DIR/lib/cbox-ai.sh"

test_preflight_refuses_when_local_model_off() {
  _reset_env
  CBOX_LOCAL_MODEL=off
  CBOX_LOCAL_MODEL_URL="http://ollama:11434"
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  local out rc=0
  out="$(_cbox_ai_local_qwen_preflight 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || _fail "preflight accepted CBOX_LOCAL_MODEL=off"
  printf '%s' "$out" | grep -q "local model disabled" \
    || _fail "preflight off-case did not explain why (got: $out)"
  echo "PASS: preflight refuses when CBOX_LOCAL_MODEL is off"
}

test_preflight_refuses_when_local_model_unset() {
  _reset_env
  local out rc=0
  out="$(_cbox_ai_local_qwen_preflight 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || _fail "preflight accepted CBOX_LOCAL_MODEL unset"
  echo "PASS: preflight refuses when CBOX_LOCAL_MODEL is unset"
}

test_preflight_refuses_when_url_missing() {
  _reset_env
  CBOX_LOCAL_MODEL=on
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  local out rc=0
  out="$(_cbox_ai_local_qwen_preflight 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || _fail "preflight accepted missing CBOX_LOCAL_MODEL_URL"
  printf '%s' "$out" | grep -q "CBOX_LOCAL_MODEL_URL" \
    || _fail "preflight url-missing case did not name the missing var (got: $out)"
  echo "PASS: preflight refuses when CBOX_LOCAL_MODEL_URL is missing"
}

test_preflight_refuses_when_name_missing() {
  _reset_env
  CBOX_LOCAL_MODEL=on
  CBOX_LOCAL_MODEL_URL="http://ollama:11434"
  local out rc=0
  out="$(_cbox_ai_local_qwen_preflight 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || _fail "preflight accepted missing CBOX_LOCAL_MODEL_NAME"
  printf '%s' "$out" | grep -q "CBOX_LOCAL_MODEL_NAME" \
    || _fail "preflight name-missing case did not name the missing var (got: $out)"
  echo "PASS: preflight refuses when CBOX_LOCAL_MODEL_NAME is missing"
}

test_preflight_accepts_when_fully_configured() {
  _reset_env
  CBOX_LOCAL_MODEL=on
  CBOX_LOCAL_MODEL_URL="http://ollama:11434"
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  _cbox_ai_local_qwen_preflight || _fail "preflight rejected a fully configured local model"
  echo "PASS: preflight accepts when CBOX_LOCAL_MODEL is on with url and name set"
}

test_host_cmd_uses_oss_local_provider_ollama() {
  _reset_env
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  CBOX_AI_PROMPT="say hi"
  local -a cmd=()
  mapfile -t cmd < <(_cbox_ai_local_qwen_cmd analyse 1)
  local joined="${cmd[*]}"
  case "$joined" in
    *"codex --oss --local-provider ollama"*) ;;
    *) _fail "host local-qwen command missing --oss --local-provider ollama (got: $joined)" ;;
  esac
  case "$joined" in
    *"-m qwen2.5:7b"*) ;;
    *) _fail "host local-qwen command missing -m with CBOX_LOCAL_MODEL_NAME (got: $joined)" ;;
  esac
  case "$joined" in
    *"exec say hi"*) ;;
    *) _fail "host local-qwen headless command missing exec with prompt (got: $joined)" ;;
  esac
  echo "PASS: host local-qwen command line uses --oss --local-provider ollama and the configured model name"
}

test_host_cmd_analyse_uses_readonly_sandbox() {
  _reset_env
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  CBOX_AI_PROMPT="say hi"
  local -a cmd=()
  mapfile -t cmd < <(_cbox_ai_local_qwen_cmd analyse 1)
  local joined="${cmd[*]}"
  case "$joined" in
    *"-s read-only"*) ;;
    *) _fail "host local-qwen analyse command did not use read-only sandbox (got: $joined)" ;;
  esac
  echo "PASS: host local-qwen analyse command uses the read-only sandbox"
}

test_host_cmd_full_uses_workspace_write_sandbox() {
  _reset_env
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  CBOX_AI_PROMPT="do it"
  local -a cmd=()
  mapfile -t cmd < <(_cbox_ai_local_qwen_cmd full 1)
  local joined="${cmd[*]}"
  case "$joined" in
    *"-s workspace-write"*) ;;
    *) _fail "host local-qwen full command did not use workspace-write sandbox (got: $joined)" ;;
  esac
  echo "PASS: host local-qwen full command uses the workspace-write sandbox"
}

test_container_cmd_uses_oss_local_provider_ollama() {
  _reset_env
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  CBOX_AI_PROMPT="say hi"
  local -a cmd=()
  mapfile -t cmd < <(_cbox_ai_local_qwen_container_cmd analyse 1)
  local joined="${cmd[*]}"
  case "$joined" in
    *"codex --oss --local-provider ollama"*) ;;
    *) _fail "container local-qwen command missing --oss --local-provider ollama (got: $joined)" ;;
  esac
  case "$joined" in
    *"-s danger-full-access"*) ;;
    *) _fail "container local-qwen command did not use danger-full-access sandbox (got: $joined)" ;;
  esac
  case "$joined" in
    *"-m qwen2.5:7b"*) ;;
    *) _fail "container local-qwen command missing -m with CBOX_LOCAL_MODEL_NAME (got: $joined)" ;;
  esac
  echo "PASS: container local-qwen command line uses --oss --local-provider ollama, danger-full-access, and the configured model name"
}

test_container_cmd_interactive_omits_exec() {
  _reset_env
  CBOX_LOCAL_MODEL_NAME="qwen2.5:7b"
  local -a cmd=()
  mapfile -t cmd < <(_cbox_ai_local_qwen_container_cmd full 0)
  local joined="${cmd[*]}"
  case "$joined" in
    *" exec "*) _fail "interactive container local-qwen command should not include exec (got: $joined)" ;;
  esac
  echo "PASS: interactive container local-qwen command omits exec"
}

test_engine_auto_never_resolves_to_local_qwen() {
  _reset_env
  local out
  out="$(type _cbox_ai_engine_auto)"
  printf '%s' "$out" | grep -q "local-qwen" \
    && _fail "_cbox_ai_engine_auto references local-qwen - auto must never resolve to it"
  echo "PASS: _cbox_ai_engine_auto never resolves to local-qwen (claude or codex only)"
}

test_engine_auto_headless_default_never_local_qwen() {
  local out rc=0
  out="$(type ai)"
  printf '%s' "$out" | grep -q 'CBOX_AI_ENGINE=claude' || rc=1
  [ "$rc" -eq 0 ] || _fail "ai() headless auto-run default engine is not pinned to claude (checked source text)"
  echo "PASS: ai() headless prompt auto-run defaults to claude, not local-qwen"
}

test_preflight_refuses_when_local_model_off
test_preflight_refuses_when_local_model_unset
test_preflight_refuses_when_url_missing
test_preflight_refuses_when_name_missing
test_preflight_accepts_when_fully_configured
test_host_cmd_uses_oss_local_provider_ollama
test_host_cmd_analyse_uses_readonly_sandbox
test_host_cmd_full_uses_workspace_write_sandbox
test_container_cmd_uses_oss_local_provider_ollama
test_container_cmd_interactive_omits_exec
test_engine_auto_never_resolves_to_local_qwen
test_engine_auto_headless_default_never_local_qwen
echo "all cbox-ai local-qwen tests passed"
