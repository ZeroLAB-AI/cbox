#!/usr/bin/env bash

CBOX_AI_ANALYSE_TEXT="You are in analyse mode: read and investigate only, make no modifications, return findings."
CBOX_AI_PLAN_TEXT="You are in plan mode: produce an implementation plan only, make no modifications."
CBOX_AI_FULL_TEXT="You are in full mode: complete the task autonomously, including edits, to the point of a finished, verified result."

CBOX_AI_LIMIT_RETRY_PREFIX="Claude hit a usage limit. Continue the same task from the current working tree and .cbox/LEDGER.md. Reconstitute state and verify existing work before changing anything."

_cbox_ai_mode_text() {
  case "$1" in
    analyse) printf '%s' "$CBOX_AI_ANALYSE_TEXT" ;;
    plan) printf '%s' "$CBOX_AI_PLAN_TEXT" ;;
    full) printf '%s' "$CBOX_AI_FULL_TEXT" ;;
    *) return 1 ;;
  esac
}

_cbox_ai_toml_escape() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      '\') out="$out\\\\" ;;
      '"') out="$out\\\"" ;;
      $'\n') out="$out\\n" ;;
      $'\r') out="$out\\r" ;;
      $'\t') out="$out\\t" ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

_cbox_ai_developer_instructions_arg() {
  local mode="$1" text escaped
  text="$(_cbox_ai_mode_text "$mode")" || return 1
  escaped="$(_cbox_ai_toml_escape "$text")"
  printf 'developer_instructions="%s"' "$escaped"
}

_cbox_ai_usage() {
  cat >&2 <<'EOF'
usage: cbox ai <analyse|plan|full> [claude|codex|local-qwen|auto] [--host|--container]
              [-p <prompt> | -] [--model M] [--effort E] [--dry-run]
local-qwen requires CBOX_LOCAL_MODEL=on plus CBOX_LOCAL_MODEL_URL/CBOX_LOCAL_MODEL_NAME; see cbox/etc/docs/LOCAL_MODEL_RUNBOOK.md
EOF
}

_cbox_ai_die() {
  echo "cbox ai: $*" >&2
  return 1
}

_cbox_ai_parse() {
  CBOX_AI_MODE=""
  CBOX_AI_ENGINE="auto"
  CBOX_AI_RUNTIME="--container"
  CBOX_AI_PROMPT=""
  CBOX_AI_HAVE_PROMPT=0
  CBOX_AI_STDIN_PROMPT=0
  CBOX_AI_MODEL=""
  CBOX_AI_EFFORT=""
  CBOX_AI_DRY_RUN=0

  local args=("$@") i=0 n="$#" a

  if [ "$n" -eq 0 ]; then
    _cbox_ai_usage
    return 1
  fi

  case "${args[0]}" in
    analyse|plan|full) CBOX_AI_MODE="${args[0]}"; i=1 ;;
    *) _cbox_ai_die "unknown mode: ${args[0]:-}"; _cbox_ai_usage; return 1 ;;
  esac

  if [ "$i" -lt "$n" ]; then
    case "${args[$i]}" in
      claude|codex|local-qwen|auto) CBOX_AI_ENGINE="${args[$i]}"; i=$((i + 1)) ;;
    esac
  fi

  while [ "$i" -lt "$n" ]; do
    a="${args[$i]}"
    case "$a" in
      --host) CBOX_AI_RUNTIME="--host"; i=$((i + 1)) ;;
      --container) CBOX_AI_RUNTIME="--container"; i=$((i + 1)) ;;
      --dry-run) CBOX_AI_DRY_RUN=1; i=$((i + 1)) ;;
      -p)
        i=$((i + 1))
        [ "$i" -lt "$n" ] || { _cbox_ai_die "-p requires an argument"; return 1; }
        CBOX_AI_PROMPT="${args[$i]}"
        CBOX_AI_HAVE_PROMPT=1
        i=$((i + 1))
        ;;
      -)
        CBOX_AI_STDIN_PROMPT=1
        CBOX_AI_HAVE_PROMPT=1
        i=$((i + 1))
        ;;
      --model)
        i=$((i + 1))
        [ "$i" -lt "$n" ] || { _cbox_ai_die "--model requires an argument"; return 1; }
        CBOX_AI_MODEL="${args[$i]}"
        i=$((i + 1))
        ;;
      --effort)
        i=$((i + 1))
        [ "$i" -lt "$n" ] || { _cbox_ai_die "--effort requires an argument"; return 1; }
        CBOX_AI_EFFORT="${args[$i]}"
        i=$((i + 1))
        ;;
      *)
        _cbox_ai_die "unknown flag: $a"
        _cbox_ai_usage
        return 1
        ;;
    esac
  done

  if [ "$CBOX_AI_STDIN_PROMPT" = 1 ]; then
    CBOX_AI_PROMPT="$(cat)"
  fi

  return 0
}

_cbox_ai_interactive() {
  [ "$CBOX_AI_HAVE_PROMPT" = 0 ] && [ -t 0 ] && [ -t 1 ]
}

_cbox_ai_limit_watch_dir() {
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '%s/limit-watch/markers' "$cfg"
}

_cbox_ai_claude_limited() {
  local dir line
  dir="$(_cbox_ai_limit_watch_dir)"
  [ -d "$dir" ] || return 1
  for line in "$dir"/*.json; do
    [ -e "$line" ] || continue
    grep -q '"state": *"pending"' "$line" 2>/dev/null && return 0
  done
  return 1
}

_cbox_ai_claude_logged_in() {
  local out
  out="$(claude auth status 2>/dev/null)" || return 1
  printf '%s' "$out" | grep -q '"loggedIn": *true' 2>/dev/null
}

_cbox_ai_engine_auto() {
  if _cbox_ai_claude_logged_in && ! _cbox_ai_claude_limited; then
    printf 'claude'
  else
    printf 'codex'
  fi
}

_cbox_ai_resolve_engine() {
  if [ "$CBOX_AI_ENGINE" = auto ]; then
    CBOX_AI_ENGINE="$(_cbox_ai_engine_auto)"
  fi
}

_cbox_ai_compose_ctx() {
  local mode
  mode="$(_cbox_effective_mode)"
  case "$mode" in
    global)
      require_global_conf
      CBOX_AI_CC=("${COMPOSE[@]}")
      CBOX_AI_SVC="$SERVICE"
      CBOX_AI_EFF="$INSTALL_DIR"
      ;;
    isolated)
      CBOX_AI_EFF="$(_project_eff_from_cwd)"
      CBOX_AI_CC=(docker compose --project-directory "$CBOX_AI_EFF" -f "$CBOX_AI_EFF/docker-compose.yml")
      CBOX_AI_SVC=cbox
      ;;
    *)
      _cbox_ai_die "no cbox configuration found (neither global nor for this workspace)"
      return 1
      ;;
  esac
}

_cbox_ai_git_fingerprint() {
  local ws="$1" status diff_hash
  status="$(git -C "$ws" status --porcelain=v2 2>/dev/null)" || status=""
  diff_hash="$(git -C "$ws" diff 2>/dev/null | sha256sum | awk '{print $1}')"
  printf '%s\n---\n%s' "$status" "$diff_hash"
}

_cbox_ai_fingerprint_roots() {
  local root="$1" seen=":" w
  printf '%s\n' "$root"
  seen="$seen$root:"
  local -a ws=()
  read -r -a ws <<< "${CBOX_WORKSPACES:-}"
  for w in "${ws[@]}"; do
    [ -n "$w" ] || continue
    case "$seen" in
      *":$w:"*) continue ;;
    esac
    seen="$seen$w:"
    [ -d "$w" ] || continue
    printf '%s\n' "$w"
  done
}

_cbox_ai_fingerprint_all() {
  local root="$1" r out=""
  while IFS= read -r r; do
    out="$out=== $r ===\n$(_cbox_ai_git_fingerprint "$r")\n"
  done < <(_cbox_ai_fingerprint_roots "$root")
  printf '%b' "$out"
}

_cbox_ai_fingerprint_all_check() {
  local root="$1" before="$2" after
  after="$(_cbox_ai_fingerprint_all "$root")"
  if [ "$before" != "$after" ]; then
    echo "cbox ai: a workspace changed during a read-only run - this must never happen:" >&2
    diff <(printf '%s' "$before") <(printf '%s' "$after") >&2 || true
    return 1
  fi
  return 0
}

_cbox_ai_join() {
  local out="" a
  for a in "$@"; do
    out="$out $(printf '%q' "$a")"
  done
  printf '%s' "${out# }"
}

_cbox_ai_run_or_print() {
  if [ "$CBOX_AI_DRY_RUN" = 1 ]; then
    _cbox_ai_join "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

_cbox_ai_claude_model_args() {
  [ -n "$CBOX_AI_MODEL" ] && printf '%s\n' --model "$CBOX_AI_MODEL"
  [ -n "$CBOX_AI_EFFORT" ] && printf '%s\n' --effort "$CBOX_AI_EFFORT"
}

_cbox_ai_codex_model_args() {
  [ -n "$CBOX_AI_MODEL" ] && printf '%s\n' -m "$CBOX_AI_MODEL"
  [ -n "$CBOX_AI_EFFORT" ] && printf '%s\n' -c "model_reasoning_effort=\"$CBOX_AI_EFFORT\""
}

_cbox_ai_container_claude_cmd() {
  local mode="$1" headless="$2"
  local -a inner=(claude)
  mapfile -t -O "${#inner[@]}" inner < <(_cbox_ai_claude_model_args)
  if [ "$mode" = full ]; then
    if [ "$headless" = 1 ]; then
      inner+=(-p "$CBOX_AI_PROMPT" --output-format text --dangerously-skip-permissions)
    else
      inner+=(--dangerously-skip-permissions)
    fi
  else
    local txt
    txt="$(_cbox_ai_mode_text "$mode")"
    if [ "$headless" = 1 ]; then
      inner+=(-p "$CBOX_AI_PROMPT" --output-format text --permission-mode plan --append-system-prompt "$txt")
    else
      inner+=(--permission-mode plan --append-system-prompt "$txt")
    fi
  fi
  printf '%s\n' "${inner[@]}"
}

_cbox_ai_container_codex_cmd() {
  local mode="$1" headless="$2"
  local -a inner=(codex -a never -s danger-full-access -c "$(_cbox_ai_developer_instructions_arg "$mode")")
  mapfile -t -O "${#inner[@]}" inner < <(_cbox_ai_codex_model_args)
  inner+=(-C "$PWD")
  if [ "$headless" = 1 ]; then
    inner+=(exec "$CBOX_AI_PROMPT")
  fi
  printf '%s\n' "${inner[@]}"
}

_cbox_ai_exec_container() {
  local headless=1
  [ -t 0 ] && [ -t 1 ] && headless=0

  local -a inner=()
  local ro=0
  case "$CBOX_AI_MODE" in
    analyse|plan) ro=1 ;;
  esac

  local -a oss_env=()
  if [ "$CBOX_AI_ENGINE" = local-qwen ]; then
    _cbox_ai_local_qwen_preflight || return 1
    oss_env=(-e "CODEX_OSS_BASE_URL=$CBOX_LOCAL_MODEL_URL")
  fi

  if [ "$ro" = 1 ]; then
    mapfile -t inner < <(
      case "$CBOX_AI_ENGINE" in
        claude) _cbox_ai_container_claude_cmd "$CBOX_AI_MODE" "$headless" ;;
        local-qwen) _cbox_ai_local_qwen_container_cmd "$CBOX_AI_MODE" "$headless" ;;
        *) _cbox_ai_container_codex_cmd "$CBOX_AI_MODE" "$headless" ;;
      esac
    )
    local root before
    root="$(_cbox_workspace_root)" || root="$PWD"
    local -a runcmd=("${CBOX_AI_CC[@]}" -f "$CBOX_AI_EFF/docker-compose.readonly.yml" run --rm -w "$PWD" -e "CBOX_AI_MODE=$CBOX_AI_MODE" "${oss_env[@]}" "$CBOX_AI_SVC" /entrypoint.sh "${inner[@]}")
    if [ "$CBOX_AI_DRY_RUN" = 1 ]; then
      _cbox_ai_run_or_print "${runcmd[@]}"
      return 0
    fi
    before="$(_cbox_ai_fingerprint_all "$root")"
    "${runcmd[@]}"
    local rc=$?
    if ! _cbox_ai_fingerprint_all_check "$root" "$before"; then
      return 1
    fi
    return "$rc"
  fi

  mapfile -t inner < <(
    case "$CBOX_AI_ENGINE" in
      claude) _cbox_ai_container_claude_cmd full "$headless" ;;
      local-qwen) _cbox_ai_local_qwen_container_cmd full "$headless" ;;
      *) _cbox_ai_container_codex_cmd full "$headless" ;;
    esac
  )
  local -a execcmd=("${CBOX_AI_CC[@]}")
  if [ "$headless" = 1 ]; then
    execcmd+=(exec -T -w "$PWD" -e "CBOX_AI_MODE=$CBOX_AI_MODE" "${oss_env[@]}" "$CBOX_AI_SVC" /entrypoint.sh "${inner[@]}")
  else
    execcmd+=(exec -it -w "$PWD" -e "CBOX_AI_MODE=$CBOX_AI_MODE" "${oss_env[@]}" "$CBOX_AI_SVC" /entrypoint.sh "${inner[@]}")
  fi
  _cbox_ai_run_or_print "${execcmd[@]}"
}

_cbox_ai_host_claude_permission_mode() {
  case "$1" in
    full) printf 'acceptEdits' ;;
    *) printf 'plan' ;;
  esac
}

_cbox_ai_host_claude_cmd() {
  local mode="$1" headless="$2"
  local -a cmd=(claude)
  mapfile -t -O "${#cmd[@]}" cmd < <(_cbox_ai_claude_model_args)
  local pmode txt
  pmode="$(_cbox_ai_host_claude_permission_mode "$mode")"
  if [ "$mode" != full ]; then
    txt="$(_cbox_ai_mode_text "$mode")"
    cmd+=(--permission-mode "$pmode" --append-system-prompt "$txt")
  else
    cmd+=(--permission-mode "$pmode")
  fi
  if [ "$headless" = 1 ]; then
    cmd+=(-p "$CBOX_AI_PROMPT" --output-format text)
  fi
  printf '%s\n' "${cmd[@]}"
}

_cbox_ai_host_codex_sandbox() {
  case "$1" in
    full) printf 'workspace-write' ;;
    *) printf 'read-only' ;;
  esac
}

_cbox_ai_host_codex_cmd() {
  local mode="$1" headless="$2" sandbox
  sandbox="$(_cbox_ai_host_codex_sandbox "$mode")"
  local -a cmd=(codex -a never -s "$sandbox" -c "$(_cbox_ai_developer_instructions_arg "$mode")")
  mapfile -t -O "${#cmd[@]}" cmd < <(_cbox_ai_codex_model_args)
  cmd+=(-C "$PWD" --strict-config --profile cbox-host)
  if [ "$headless" = 1 ]; then
    cmd+=(exec "$CBOX_AI_PROMPT")
  fi
  printf '%s\n' "${cmd[@]}"
}

_cbox_ai_local_qwen_preflight() {
  if [ "${CBOX_LOCAL_MODEL:-off}" != on ]; then
    echo "cbox ai: local model disabled - set CBOX_LOCAL_MODEL=on plus CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME, see cbox/etc/docs/LOCAL_MODEL_RUNBOOK.md" >&2
    return 1
  fi
  if [ -z "${CBOX_LOCAL_MODEL_URL:-}" ] || [ -z "${CBOX_LOCAL_MODEL_NAME:-}" ]; then
    echo "cbox ai: local model disabled - CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME must both be set, see cbox/etc/docs/LOCAL_MODEL_RUNBOOK.md" >&2
    return 1
  fi
  return 0
}

_cbox_ai_local_qwen_cmd() {
  local mode="$1" headless="$2" sandbox
  sandbox="$(_cbox_ai_host_codex_sandbox "$mode")"
  local -a cmd=(codex --oss --local-provider ollama -a never -s "$sandbox" -c "$(_cbox_ai_developer_instructions_arg "$mode")" -m "$CBOX_LOCAL_MODEL_NAME")
  cmd+=(-C "$PWD")
  if [ "$headless" = 1 ]; then
    cmd+=(exec "$CBOX_AI_PROMPT")
  fi
  printf '%s\n' "${cmd[@]}"
}

_cbox_ai_local_qwen_container_cmd() {
  local mode="$1" headless="$2"
  local -a inner=(codex --oss --local-provider ollama -a never -s danger-full-access -c "$(_cbox_ai_developer_instructions_arg "$mode")" -m "$CBOX_LOCAL_MODEL_NAME")
  inner+=(-C "$PWD")
  if [ "$headless" = 1 ]; then
    inner+=(exec "$CBOX_AI_PROMPT")
  fi
  printf '%s\n' "${inner[@]}"
}

_cbox_ai_host_codex_preflight() {
  local profile="$HOME/.codex/cbox-host.config.toml"
  if [ ! -f "$profile" ]; then
    echo "cbox ai: codex managed host profile missing at $profile - run './setup.sh update codex-mcp' (or './setup.sh') on the host first" >&2
    return 1
  fi
  if [ ! -s "$profile" ]; then
    echo "cbox ai: codex managed host profile at $profile is empty - run './setup.sh update codex-mcp' on the host" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "cbox ai: python3 missing - cannot validate $profile as TOML" >&2
    return 1
  fi
  if ! python3 -c '
import sys
import tomllib
with open(sys.argv[1], "rb") as f:
    tomllib.load(f)
' "$profile" 2>/dev/null; then
    echo "cbox ai: codex managed host profile at $profile does not parse as TOML - run './setup.sh update codex-mcp' on the host" >&2
    return 1
  fi
  return 0
}

_cbox_ai_exec_host() {
  local headless=1
  [ -t 0 ] && [ -t 1 ] && headless=0

  if [ "$CBOX_AI_ENGINE" = local-qwen ]; then
    _cbox_ai_local_qwen_preflight || return 1
    export CODEX_OSS_BASE_URL="$CBOX_LOCAL_MODEL_URL"
  elif [ "$CBOX_AI_ENGINE" != claude ]; then
    _cbox_ai_host_codex_preflight || return 1
  fi

  local -a cmd=()
  case "$CBOX_AI_ENGINE" in
    claude) mapfile -t cmd < <(_cbox_ai_host_claude_cmd "$CBOX_AI_MODE" "$headless") ;;
    local-qwen) mapfile -t cmd < <(_cbox_ai_local_qwen_cmd "$CBOX_AI_MODE" "$headless") ;;
    *) mapfile -t cmd < <(_cbox_ai_host_codex_cmd "$CBOX_AI_MODE" "$headless") ;;
  esac

  case "$CBOX_AI_MODE" in
    analyse|plan)
      local root before
      root="$(_cbox_workspace_root)" || root="$PWD"
      if [ "$CBOX_AI_DRY_RUN" = 1 ]; then
        _cbox_ai_run_or_print "${cmd[@]}"
        return 0
      fi
      before="$(_cbox_ai_fingerprint_all "$root")"
      "${cmd[@]}"
      local rc=$?
      if ! _cbox_ai_fingerprint_all_check "$root" "$before"; then
        return 1
      fi
      return "$rc"
      ;;
    *)
      _cbox_ai_run_or_print "${cmd[@]}"
      ;;
  esac
}

_cbox_ai_headless_result_is_limit() {
  printf '%s' "$1" | grep -qi 'usage limit reached'
}

_cbox_ai_headless_auto_run() {
  local out rc=0
  out="$("${@}")" || rc=$?
  if [ "$rc" -ne 0 ] && _cbox_ai_headless_result_is_limit "$out"; then
    echo "cbox ai: claude reported a usage limit - retrying once with codex" >&2
    CBOX_AI_PROMPT="$CBOX_AI_LIMIT_RETRY_PREFIX
$CBOX_AI_PROMPT"
    CBOX_AI_ENGINE=codex
    if [ "$CBOX_AI_RUNTIME" = "--container" ]; then
      _cbox_ai_exec_container
    else
      _cbox_ai_exec_host
    fi
    return $?
  fi
  printf '%s\n' "$out"
  return "$rc"
}

ai() {
  _cbox_ai_parse "$@" || return 1

  if _cbox_ai_interactive; then
    _cbox_ai_resolve_engine
  else
    if [ "$CBOX_AI_ENGINE" = auto ] && [ "$CBOX_AI_HAVE_PROMPT" = 1 ]; then
      CBOX_AI_ENGINE=claude
      if [ "$CBOX_AI_RUNTIME" = "--container" ]; then
        _cbox_ai_compose_ctx || return 1
        _cbox_ai_headless_auto_run _cbox_ai_exec_container
      else
        _cbox_ai_headless_auto_run _cbox_ai_exec_host
      fi
      return $?
    fi
    _cbox_ai_resolve_engine
  fi

  if [ "$CBOX_AI_RUNTIME" = "--container" ]; then
    _cbox_ai_compose_ctx || return 1
    _cbox_ai_exec_container
  else
    _cbox_ai_exec_host
  fi
}
