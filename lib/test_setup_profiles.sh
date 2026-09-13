#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_HERMES CBOX_HERMES_VERSION \
  CBOX_HERMES_PROVIDER CBOX_HERMES_MODEL_URL CBOX_HERMES_MODEL_NAME CBOX_HERMES_EFFORT \
  CBOX_HERMES_DELEGATE CBOX_HERMES_DELEGATE_MODE CBOX_HERMES_DELEGATE_PROVIDER \
  CBOX_HERMES_DELEGATE_BASE_URL CBOX_HERMES_DELEGATE_MODEL \
  CBOX_LOCAL_MODEL CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME \
  CBOX_OLLAMA_MODE CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE CBOX_OLLAMA_STORE_PATH \
  CBOX_MCP_SERVERS CBOX_AGENTS CBOX_CODEX_MCP CBOX_BINS_SCOPE CBOX_BINS_HEALTH_GATE

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

SETUP_SH="$INSTALL_DIR/lib/cbox-setup.sh"
REG="$INSTALL_DIR/etc/registry/settings.json"

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

python3 -c "
import json
d = json.load(open('$REG'))
profiles = {s['id']: s['profile'] for s in d['sections']}
for sid in ('mcp-servers', 'agents', 'codex-mcp'):
    assert profiles[sid] == 'auto', '%s: expected profile auto, got %r' % (sid, profiles[sid])
" || _fail "registry: mcp-servers/agents/codex-mcp are not profile=auto"
_ok "registry: mcp-servers, agents and codex-mcp are profile=auto"

SEC_GET_OUT="$(
  set +eu
  . "$INSTALL_DIR/templates/sections.sh"
  for sid in mcp-servers agents codex-mcp; do
    printf '%s=%s\n' "$sid" "$(sec_get SEC_PROFILE "$sid")"
  done
)"
for sid in mcp-servers agents codex-mcp; do
  printf '%s\n' "$SEC_GET_OUT" | grep -qx "$sid=auto" \
    || _fail "generated sections.sh: sec_get SEC_PROFILE $sid did not return auto ($SEC_GET_OUT)"
done
_ok "generated templates/sections.sh: sec_get SEC_PROFILE returns auto for mcp-servers, agents and codex-mcp"

RUN_CLASSIC="$(_extract_fn "$SETUP_SH" run_classic)"
[ -n "$RUN_CLASSIC" ] || _fail "cannot extract run_classic from lib/cbox-setup.sh"

printf '%s\n' "$RUN_CLASSIC" | grep -q 'sec_get SEC_PROFILE' \
  || _fail "run_classic does not consume SEC_PROFILE via sec_get - SEC_PROFILE still has no production consumer"
_ok "SEC_PROFILE has a production consumer: run_classic greps for 'sec_get SEC_PROFILE'"

for literal in step_bashrc step_mcp_servers step_agents step_codex_mcp step_continuity step_claude_md \
  step_settings step_hooks step_git_identity step_restart_policy mcp_apply_selection agents_install \
  codex_mcp_ensure_hooks_dep codex_progress_ensure_hooks_dep codex_mcp_apply; do
  if printf '%s\n' "$RUN_CLASSIC" | grep -qw "$literal"; then
    _fail "run_classic still calls '$literal' as a hardcoded literal - it must dispatch through the SEC_PROFILE loop, not a hand-maintained step list"
  fi
done
_ok "run_classic contains no literal per-section step list (the old apply_default_setup hardcoded list is gone)"

printf '%s\n' "$RUN_CLASSIC" | grep -q '"\${SECTIONS\[@\]}"' \
  || _fail "run_classic does not iterate SECTIONS - it is not data-driven"
_ok "run_classic iterates \${SECTIONS[@]} and dispatches step_<section> dynamically"

if declare -f apply_default_setup >/dev/null 2>&1; then
  _fail "apply_default_setup should no longer be defined; it was the hand-maintained second source of truth run_classic replaces"
fi
grep -q '^apply_default_setup()' "$SETUP_SH" \
  && _fail "apply_default_setup() is still defined in lib/cbox-setup.sh - it must be removed, run_classic replaces it"
_ok "apply_default_setup is gone from lib/cbox-setup.sh"

OLD_SETUP_SH="$TMPBASE/cbox-setup.sh.old"
if git -C "$INSTALL_DIR/.." show HEAD:cbox/lib/cbox-setup.sh > "$OLD_SETUP_SH" 2>/dev/null \
  && grep -q '^apply_default_setup()' "$OLD_SETUP_SH"; then
  OLD_APPLY_DEFAULT="$(_extract_fn "$OLD_SETUP_SH" apply_default_setup)"
  found_literal=0
  for literal in step_bashrc step_continuity step_claude_md step_settings step_hooks step_git_identity \
    step_restart_policy mcp_apply_selection agents_install; do
    if printf '%s\n' "$OLD_APPLY_DEFAULT" | grep -qw "$literal"; then
      found_literal=1
    fi
  done
  [ "$found_literal" = 1 ] \
    || _fail "negative control broken: the pre-change apply_default_setup no longer contains any of the literal step calls the detector looks for"
  _ok "negative control: the same literal-list detector DOES flag the pre-change apply_default_setup (git HEAD), proving it has teeth"
else
  _ok "negative control skipped: no pre-change apply_default_setup found at git HEAD (already landed in a prior commit on this branch)"
fi

STEP_MCP="$(_extract_fn "$SETUP_SH" step_mcp_servers)"
STEP_AGENTS="$(_extract_fn "$SETUP_SH" step_agents)"
STEP_CODEX_MCP="$(_extract_fn "$SETUP_SH" step_codex_mcp)"
[ -n "$STEP_MCP" ] || _fail "cannot extract step_mcp_servers"
[ -n "$STEP_AGENTS" ] || _fail "cannot extract step_agents"
[ -n "$STEP_CODEX_MCP" ] || _fail "cannot extract step_codex_mcp"

_run_auto_probe() {
  local fn_src="$1" fn_name="$2"
  (
    set +eu
    note() { :; }
    warn() { :; }
    container_target_ok() { return 0; }
    section_dep_gate() { DEP_ACTION=ok; DEP_REASON=""; }
    mcp_apply_selection() { echo "APPLY_CALLED:mcp_apply_selection"; }
    agents_install() { echo "APPLY_CALLED:agents_install"; }
    codex_mcp_apply() { echo "APPLY_CALLED:codex_mcp_apply"; }
    codex_mcp_ensure_hooks_dep() { echo "APPLY_CALLED:codex_mcp_ensure_hooks_dep"; }
    checkbox_select() { echo "INTERACTIVE_CALLED:checkbox_select"; }
    ask_choice() { echo "INTERACTIVE_CALLED:ask_choice"; ASK_VALUE="$2"; }
    ask() { echo "INTERACTIVE_CALLED:ask"; ASK_VALUE="$2"; }
    ETC_DIR="$TMPBASE/etc"
    mkdir -p "$ETC_DIR/agents" "$ETC_DIR/mcp"
    : > "$ETC_DIR/mcp/delegates.json"
    CBOX_MCP_SERVERS="all"
    CBOX_AGENTS="all"
    CBOX_CODEX_MCP=1
    CBOX_CODEX_MODEL="gpt-5.6-terra"
    CBOX_CODEX_EFFORT="xhigh"
    SEC_AUTO=1
    eval "$fn_src"
    "$fn_name"
  )
}

OUT_MCP="$(_run_auto_probe "$STEP_MCP" step_mcp_servers)"
if printf '%s\n' "$OUT_MCP" | grep -q INTERACTIVE_CALLED; then
  _fail "step_mcp_servers with SEC_AUTO=1 still calls an interactive prompt: $OUT_MCP"
fi
printf '%s\n' "$OUT_MCP" | grep -q 'APPLY_CALLED:mcp_apply_selection' \
  || _fail "step_mcp_servers with SEC_AUTO=1 did not apply the current selection"
_ok "step_mcp_servers: SEC_AUTO=1 applies the current selection without prompting"

OUT_AGENTS="$(_run_auto_probe "$STEP_AGENTS" step_agents)"
if printf '%s\n' "$OUT_AGENTS" | grep -q INTERACTIVE_CALLED; then
  _fail "step_agents with SEC_AUTO=1 still calls an interactive prompt: $OUT_AGENTS"
fi
printf '%s\n' "$OUT_AGENTS" | grep -q 'APPLY_CALLED:agents_install' \
  || _fail "step_agents with SEC_AUTO=1 did not apply the current selection"
_ok "step_agents: SEC_AUTO=1 applies the current selection without prompting"

OUT_CODEX_MCP="$(_run_auto_probe "$STEP_CODEX_MCP" step_codex_mcp)"
if printf '%s\n' "$OUT_CODEX_MCP" | grep -q INTERACTIVE_CALLED; then
  _fail "step_codex_mcp with SEC_AUTO=1 still calls an interactive prompt: $OUT_CODEX_MCP"
fi
printf '%s\n' "$OUT_CODEX_MCP" | grep -q 'APPLY_CALLED:codex_mcp_apply' \
  || _fail "step_codex_mcp with SEC_AUTO=1 did not apply the current selection"
_ok "step_codex_mcp: SEC_AUTO=1 applies the current selection without prompting"

if git -C "$INSTALL_DIR/.." show HEAD:cbox/lib/cbox-setup.sh > "$OLD_SETUP_SH" 2>/dev/null; then
  OLD_STEP_MCP="$(_extract_fn "$OLD_SETUP_SH" step_mcp_servers)"
  OLD_STEP_AGENTS="$(_extract_fn "$OLD_SETUP_SH" step_agents)"
  OLD_STEP_CODEX_MCP="$(_extract_fn "$OLD_SETUP_SH" step_codex_mcp)"
  if [ -n "$OLD_STEP_MCP" ] && ! printf '%s\n' "$OLD_STEP_MCP" | grep -q 'SEC_AUTO' ; then
    OLD_OUT_MCP="$(_run_auto_probe "$OLD_STEP_MCP" step_mcp_servers 2>/dev/null || true)"
    printf '%s\n' "$OLD_OUT_MCP" | grep -q INTERACTIVE_CALLED \
      || _fail "negative control broken: the pre-change step_mcp_servers did not hit an interactive prompt under SEC_AUTO=1"
    _ok "negative control: the pre-change step_mcp_servers DOES call an interactive prompt under SEC_AUTO=1 (proves the probe catches a missing SEC_AUTO branch)"
  else
    _ok "negative control skipped: pre-change step_mcp_servers already had a SEC_AUTO branch at git HEAD"
  fi
else
  _ok "negative control skipped: no git HEAD revision of lib/cbox-setup.sh available"
fi

CFO_SRC="$(_extract_fn "$SETUP_SH" _classic_feature_on)"
CFOFF_SRC="$(_extract_fn "$SETUP_SH" _classic_feature_off)"
[ -n "$CFO_SRC" ] || _fail "cannot extract _classic_feature_on"
[ -n "$CFOFF_SRC" ] || _fail "cannot extract _classic_feature_off"

_run_feature_probe() {
  local no_cdi_rc="$1"
  shift
  (
    set +eu
    note() { :; }
    ask() { ASK_VALUE="qwen2.5:7b"; }
    _cbox_no_cdi() { return "$no_cdi_rc"; }
    eval "$CFO_SRC"
    eval "$CFOFF_SRC"
    for f in "$@"; do
      _classic_feature_on "$f"
    done
    printf 'CBOX_OLLAMA_MODE=%s\n' "$CBOX_OLLAMA_MODE"
    printf 'CBOX_OLLAMA_GPU=%s\n' "$CBOX_OLLAMA_GPU"
    printf 'CBOX_OLLAMA_STORE=%s\n' "$CBOX_OLLAMA_STORE"
    printf 'CBOX_LOCAL_MODEL=%s\n' "$CBOX_LOCAL_MODEL"
    printf 'CBOX_LOCAL_MODEL_URL=%s\n' "$CBOX_LOCAL_MODEL_URL"
    printf 'CBOX_HERMES=%s\n' "$CBOX_HERMES"
    printf 'CBOX_HERMES_PROVIDER=%s\n' "$CBOX_HERMES_PROVIDER"
    printf 'CBOX_HERMES_MODEL_URL=%s\n' "$CBOX_HERMES_MODEL_URL"
    printf 'CBOX_HERMES_MODEL_NAME=%s\n' "$CBOX_HERMES_MODEL_NAME"
    printf 'CBOX_HERMES_EFFORT=%s\n' "$CBOX_HERMES_EFFORT"
    printf 'CBOX_HERMES_DELEGATE=%s\n' "$CBOX_HERMES_DELEGATE"
    printf 'CBOX_HERMES_DELEGATE_MODE=%s\n' "$CBOX_HERMES_DELEGATE_MODE"
    printf 'CBOX_HERMES_DELEGATE_PROVIDER=%s\n' "$CBOX_HERMES_DELEGATE_PROVIDER"
    printf 'CBOX_HERMES_DELEGATE_BASE_URL=%s\n' "$CBOX_HERMES_DELEGATE_BASE_URL"
  )
}

_field() {
  printf '%s\n' "$1" | grep "^$2=" | cut -d= -f2-
}

OUT_CDI="$(_run_feature_probe 1 local-model hermes hermes-delegate)"
[ "$(_field "$OUT_CDI" CBOX_OLLAMA_MODE)" = on ] || _fail "cdi present: CBOX_OLLAMA_MODE expected on"
[ "$(_field "$OUT_CDI" CBOX_OLLAMA_GPU)" = cdi ] || _fail "cdi present (_cbox_no_cdi=false/rc1): CBOX_OLLAMA_GPU expected cdi, got $(_field "$OUT_CDI" CBOX_OLLAMA_GPU)"
[ "$(_field "$OUT_CDI" CBOX_LOCAL_MODEL_URL)" = "http://ollama:11434" ] || _fail "local-model url expected http://ollama:11434"
[ "$(_field "$OUT_CDI" CBOX_HERMES_MODEL_URL)" = "http://ollama:11434" ] || _fail "hermes should inherit the local-model url"
[ "$(_field "$OUT_CDI" CBOX_HERMES_MODEL_NAME)" = "qwen2.5:7b" ] || _fail "hermes should inherit the local-model name"
[ "$(_field "$OUT_CDI" CBOX_HERMES_EFFORT)" = medium ] || _fail "hermes effort expected medium"
[ "$(_field "$OUT_CDI" CBOX_HERMES_DELEGATE_MODE)" = agent ] || _fail "hermes-delegate mode expected agent"
[ "$(_field "$OUT_CDI" CBOX_HERMES_DELEGATE_BASE_URL)" = "http://ollama:11434" ] || _fail "hermes-delegate should inherit the hermes url"
_ok "_classic_feature_on (cdi available): ollama on/cdi, local-model url fixed, hermes inherits, delegate mode agent"

OUT_NOCDI="$(_run_feature_probe 0 local-model)"
[ "$(_field "$OUT_NOCDI" CBOX_OLLAMA_MODE)" = on ] || _fail "no-cdi stub: CBOX_OLLAMA_MODE expected on"
[ "$(_field "$OUT_NOCDI" CBOX_OLLAMA_GPU)" = off ] || _fail "no-cdi stub (_cbox_no_cdi=true/rc0): CBOX_OLLAMA_GPU expected off, got $(_field "$OUT_NOCDI" CBOX_OLLAMA_GPU)"
_ok "_classic_feature_on: CBOX_OLLAMA_GPU follows the _cbox_no_cdi stub (off when no CDI, cdi when CDI is present)"

CFS_SRC="$(_extract_fn "$SETUP_SH" _classic_features_select)"
[ -n "$CFS_SRC" ] || _fail "cannot extract _classic_features_select"

_run_unchanged_checkbox_probe() {
  (
    set +eu
    note() { :; }
    header() { :; }
    container_target_ok() { return 1; }
    mcp_apply_selection() { :; }
    checkbox_select() { :; }
    eval "$CFO_SRC"
    eval "$CFOFF_SRC"
    eval "$CFS_SRC"
    CBOX_HERMES=on
    CBOX_HERMES_PROVIDER=openrouter
    CBOX_HERMES_MODEL_URL="https://openrouter.example/v1"
    CBOX_HERMES_MODEL_NAME=gpt-4-custom
    CBOX_HERMES_EFFORT=xhigh
    CBOX_LOCAL_MODEL=off
    CBOX_LOCAL_MODEL_URL=""
    CBOX_LOCAL_MODEL_NAME=""
    CBOX_HERMES_DELEGATE=off
    _classic_features_select
    printf 'CBOX_HERMES=%s\n' "$CBOX_HERMES"
    printf 'CBOX_HERMES_PROVIDER=%s\n' "$CBOX_HERMES_PROVIDER"
    printf 'CBOX_HERMES_MODEL_URL=%s\n' "$CBOX_HERMES_MODEL_URL"
    printf 'CBOX_HERMES_MODEL_NAME=%s\n' "$CBOX_HERMES_MODEL_NAME"
    printf 'CBOX_HERMES_EFFORT=%s\n' "$CBOX_HERMES_EFFORT"
    printf 'CBOX_LOCAL_MODEL=%s\n' "$CBOX_LOCAL_MODEL"
  )
}

OUT_UNCHANGED="$(_run_unchanged_checkbox_probe)"
[ "$(_field "$OUT_UNCHANGED" CBOX_HERMES)" = on ] || _fail "unchanged checkbox: CBOX_HERMES should stay on"
[ "$(_field "$OUT_UNCHANGED" CBOX_HERMES_PROVIDER)" = openrouter ] || _fail "unchanged checkbox: CBOX_HERMES_PROVIDER should stay openrouter, got $(_field "$OUT_UNCHANGED" CBOX_HERMES_PROVIDER)"
[ "$(_field "$OUT_UNCHANGED" CBOX_HERMES_MODEL_URL)" = "https://openrouter.example/v1" ] || _fail "unchanged checkbox: CBOX_HERMES_MODEL_URL should stay custom, got $(_field "$OUT_UNCHANGED" CBOX_HERMES_MODEL_URL)"
[ "$(_field "$OUT_UNCHANGED" CBOX_HERMES_MODEL_NAME)" = gpt-4-custom ] || _fail "unchanged checkbox: CBOX_HERMES_MODEL_NAME should stay custom, got $(_field "$OUT_UNCHANGED" CBOX_HERMES_MODEL_NAME)"
[ "$(_field "$OUT_UNCHANGED" CBOX_HERMES_EFFORT)" = xhigh ] || _fail "unchanged checkbox: CBOX_HERMES_EFFORT should stay xhigh, got $(_field "$OUT_UNCHANGED" CBOX_HERMES_EFFORT)"
[ "$(_field "$OUT_UNCHANGED" CBOX_LOCAL_MODEL)" = off ] || _fail "unchanged checkbox: CBOX_LOCAL_MODEL should stay off"
_ok "_classic_features_select: leaving the checkbox unchanged does not re-derive an already-on feature's custom values"

_ok "all setup profile checks passed"
