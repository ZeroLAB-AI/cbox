#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$INSTALL_DIR/_common.sh" ] && . "$INSTALL_DIR/_common.sh"
ETC_DIR="$INSTALL_DIR/etc"
GEN_DIR="$INSTALL_DIR/generated"
CONF_FILE="$INSTALL_DIR/cbox.conf"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SERVICE="cbox"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.claude/cbox-backup-$RUN_TS"
MARK_START="# >>> cbox >>>"
MARK_END="# <<< cbox <<<"
SUPERSEDED_PREFIX="# [cbox superseded] "
SETUP_MODE="wizard"
NAV=""
ASK_VALUE=""
PATH_VALUE=""
WIZ_SECTIONS=()
SEC_AUTO=0
CODEX_MCP_MARK_START="# >>> cbox codex-mcp >>>"
CODEX_MCP_MARK_END="# <<< cbox codex-mcp <<<"
CODEX_MCP_LEGACY_MARK_START="# >>> claude-box codex-mcp >>>"
CODEX_MCP_LEGACY_MARK_END="# <<< claude-box codex-mcp <<<"
CLAUDE_MD_KERNEL_MARK_START="<!-- cbox:conduct-kernel:begin -->"
CLAUDE_MD_KERNEL_MARK_END="<!-- cbox:conduct-kernel:end -->"

CBOX_COLOR=0
if [ -t 1 ] && [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ] \
   && command -v tput >/dev/null 2>&1; then
  _tc="$(tput colors 2>/dev/null || printf '0')"
  case "$_tc" in *[!0-9]*|'') _tc=0 ;; esac
  if [ "$_tc" -ge 8 ]; then CBOX_COLOR=1; fi
fi
if [ "$CBOX_COLOR" = 1 ]; then
  C_RESET="$(tput sgr0 2>/dev/null || printf '')"
  C_BOLD="$(tput bold 2>/dev/null || printf '')"
  C_DIM="$(tput dim 2>/dev/null || printf '')"
  C_HEAD="${C_BOLD}$(tput setaf 6 2>/dev/null || printf '')"
  C_ACCENT="$(tput setaf 6 2>/dev/null || printf '')"
  C_OK="$(tput setaf 2 2>/dev/null || printf '')"
  C_WARN="$(tput setaf 3 2>/dev/null || printf '')"
  C_ERR="${C_BOLD}$(tput setaf 1 2>/dev/null || printf '')"
  C_MUTE="$C_DIM"
  C_REV="$(tput rev 2>/dev/null || printf '')"
  P_ACCENT=$'\001'"${C_ACCENT}"$'\002'
  P_DIM=$'\001'"${C_DIM}"$'\002'
  P_RESET=$'\001'"${C_RESET}"$'\002'
else
  C_RESET="" C_BOLD="" C_DIM="" C_HEAD="" C_ACCENT="" C_OK="" C_WARN="" C_ERR="" C_MUTE=""
  C_REV=""
  P_ACCENT="" P_DIM="" P_RESET=""
fi
HR_LINE="------------------------------------------------------------"
HR_HEAVY="============================================================"

CBOX_TUI=0
if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${CBOX_NO_TUI:-}" ]; then
  CBOX_TUI=1
fi
if [ "$CBOX_TUI" = 1 ]; then
  trap 'printf "\033[?25h" >&2' EXIT
  trap 'printf "\033[?25h" >&2; exit 130' INT TERM
fi

die() { printf '%ssetup: error:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

note() { printf '%ssetup:%s %s\n' "$C_MUTE" "$C_RESET" "$*"; }

warn() { printf '%ssetup: warning:%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }

hr() { printf '%s%s%s\n' "$C_MUTE" "$HR_LINE" "$C_RESET"; }

[ -f "$INSTALL_DIR/templates/sections.sh" ] || die "templates/sections.sh missing"
. "$INSTALL_DIR/templates/sections.sh"

header() {
  local title="$1" step="${2:-}" total="${3:-}"
  printf '\n'
  hr
  if [ -n "$step" ]; then
    printf '%s%s%s  %s[%s/%s]%s\n' "$C_HEAD" "$title" "$C_RESET" "$C_ACCENT" "$step" "$total" "$C_RESET"
  else
    printf '%s%s%s\n' "$C_HEAD" "$title" "$C_RESET"
  fi
  hr
}

section_title() {
  printf '%s' "${SEC_TITLE[$1]:-$1}"
}

have_docker() { command -v docker >/dev/null 2>&1; }

container_running() {
  have_docker || return 1
  [ -f "$COMPOSE_FILE" ] || return 1
  [ -n "$(docker compose -f "$COMPOSE_FILE" ps -q "$SERVICE" 2>/dev/null)" ]
}

container_target_ok() {
  if [ -f /.dockerenv ] || ! have_docker; then
    note "run on host: behavioral configuration (~/.claude policies/templates/agents/settings/hooks) is read-only inside the container"
    return 1
  fi
  return 0
}

_cbox_write_local() {
  local target="$1" dir tmp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.cbox.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$target"
}

require_tty() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "$1 requires an interactive terminal; only --config <file> runs without a TTY"
  fi
}

apply_action_for() {
  printf '%s' "${SEC_APPLY[$1]:-none}"
}

section_help_desc() {
  printf '%s' "${SEC_DESC[$1]:-$1}"
}

section_help_vars() {
  local key="$1" vars var out=() v
  vars="${SEC_VARS[$key]:-}"
  if [ -z "$vars" ]; then
    printf '(file actions only, no conf vars)'
    return 0
  fi
  for var in $vars; do
    v="$(unset "$var"; conf_defaults >/dev/null 2>&1 || true; printf '%s' "${!var}")"
    out+=("$var=$v")
  done
  printf '%s' "${out[*]-}"
}

section_deps_help_lines() {
  local key="$1" tok
  for tok in ${SEC_DEPS[$key]:-}; do
    printf '    depends: %s\n' "${SEC_DEP_TEXT[$tok]:-$tok}"
  done
}

_cbox_no_cdi() {
  if command -v nvidia-ctk >/dev/null 2>&1 && [ -f /etc/cdi/nvidia.yaml ]; then
    return 1
  fi
  return 0
}

_cbox_dep_condition() {
  case "$1" in
    isolated-mode)
      [ "${CBOX_MODE:-global}" = isolated ]
      ;;
    no-cdi)
      _cbox_no_cdi
      ;;
    hooks)
      return 0
      ;;
    continuity-hooks)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

DEP_ACTION=ok
DEP_REASON=""

section_dep_gate() {
  local key="$1" tok mech cond met
  DEP_ACTION=ok
  DEP_REASON=""
  for tok in ${SEC_DEPS[$key]:-}; do
    mech="${tok%%:*}"
    cond="${tok#*:}"
    met=1
    _cbox_dep_condition "$cond" && met=0
    case "$mech" in
      disable)
        if [ "$met" = 0 ]; then
          DEP_ACTION=disable
          DEP_REASON="${SEC_DEP_TEXT[$tok]:-$tok}"
          return 0
        fi
        ;;
      dictate)
        DEP_ACTION=dictate
        DEP_REASON="${SEC_DEP_TEXT[$tok]:-$tok}"
        return 0
        ;;
    esac
  done
}

print_settings_help() {
  local i sec num title action plain pad right
  printf '\n'
  hr
  printf '%ssetup.sh sections reference%s\n' "$C_HEAD" "$C_RESET"
  hr
  for i in "${!SECTIONS[@]}"; do
    sec="${SECTIONS[i]}"
    num=$((i+1))
    title="$(section_title "$sec")"
    action="$(apply_action_for "$sec")"
    plain="$(printf '%2d  %s (%s)' "$num" "$sec" "$title")"
    right="apply: $action"
    pad=$((58 - ${#plain}))
    [ "$pad" -gt 1 ] || pad=1
    printf '%2d  %s%s%s (%s)%*s%s\n' \
      "$num" "$C_ACCENT" "$sec" "$C_RESET" "$title" "$pad" "" "$right"
    printf '    %s\n' "$(section_help_desc "$sec")"
    printf '    %s%s%s\n' "$C_DIM" "$(section_help_vars "$sec")" "$C_RESET"
    section_deps_help_lines "$sec"
  done
  hr
  printf 'wizard navigation: Enter=next  b=back  j=jump  q=save+quit  h=this help\n'
}

mcp_all_names() {
  [ -f "$ETC_DIR/mcp/delegates.json" ] || return 0
  local rendered
  rendered="$(python3 "$ETC_DIR/mcp/render_mcp.py" "$ETC_DIR/mcp/delegates.json" all "$HOME/.claude/hooks" off claude)" \
    || die "mcp_all_names: render_mcp.py rejected $ETC_DIR/mcp/delegates.json (malformed registry entry - see stderr above)"
  python3 -c '
import json
import sys

data = json.loads(sys.argv[1])
print(" ".join(sorted(data.keys())))
' "$rendered"
}

agent_all_names() {
  local f names=()
  for f in "$ETC_DIR/agents/"*.md; do
    [ -e "$f" ] || continue
    names+=("$(basename "$f" .md)")
  done
  printf '%s' "${names[*]-}"
}

canonical_expand() {
  local sel="$1" all="$2"
  if [ -z "$sel" ] || [ "$sel" = all ]; then
    printf '%s' "$all"
    return 0
  fi
  local -a all_arr sel_arr out
  read -r -a all_arr <<< "$all"
  read -r -a sel_arr <<< "$sel"
  out=()
  local a s known
  for a in "${all_arr[@]}"; do
    known=0
    for s in "${sel_arr[@]}"; do
      if [ "$s" = "$a" ]; then
        known=1
      fi
    done
    if [ "$known" = 1 ]; then
      out+=("$a")
    fi
  done
  printf '%s' "${out[*]-}"
}

canonical_store() {
  local sel="$1" all="$2"
  if [ -z "$sel" ]; then
    printf '%s' "all"
    return 0
  fi
  local -a all_arr sel_arr
  read -r -a all_arr <<< "$all"
  read -r -a sel_arr <<< "$sel"
  if [ "${#all_arr[@]}" -gt 0 ] && [ "${#sel_arr[@]}" -eq "${#all_arr[@]}" ]; then
    local a s found allmatch=1
    for a in "${all_arr[@]}"; do
      found=0
      for s in "${sel_arr[@]}"; do
        if [ "$s" = "$a" ]; then
          found=1
        fi
      done
      if [ "$found" = 0 ]; then
        allmatch=0
      fi
    done
    if [ "$allmatch" = 1 ]; then
      printf '%s' "all"
      return 0
    fi
  fi
  printf '%s' "$sel"
}

conf_defaults() {
  : "${CBOX_NAME:=cbox}"
  : "${CBOX_CLAUDE_MODE:=mount}"
  : "${CBOX_CLAUDE_PATH:=$HOME/.claude}"
  : "${CBOX_CLAUDE_BACKUP:=n}"
  : "${CBOX_CODEX_MODE:=mount}"
  : "${CBOX_CODEX_PATH:=$HOME/.codex}"
  : "${CBOX_CODEX_BACKUP:=n}"
  : "${CBOX_WORKSPACES:=}"
  : "${CBOX_VENV_MODE:=none}"
  : "${CBOX_VENV_PATH:=$HOME/.venvs/cuda-py312}"
  : "${CBOX_GPU:=0}"
  : "${CBOX_EGRESS_MODE:=off}"
  : "${CBOX_EGRESS_APPLIED:=0}"
  : "${CBOX_NETACCESS_MODE:=off}"
  : "${CBOX_NETACCESS_APPLIED:=0}"
  : "${CBOX_NETACCESS_NETWORKS:=}"
  : "${CBOX_NETACCESS_CIDRS:=}"
  : "${CBOX_NETACCESS_SOCKS_PORT:=1080}"
  : "${CBOX_HOST_ROUTE_MODE:=off}"
  : "${CBOX_HOST_ROUTE_APPLIED:=0}"
  : "${CBOX_HOST_PROXY_URL:=}"
  : "${CBOX_HOST_PROXY_ADDR_MODE:=host-gateway}"
  : "${CBOX_SSH_MODE:=none}"
  : "${CBOX_SSH_AGENT_DIR:=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/cbox-ssh}"
  : "${CBOX_BASHRC:=1}"
  : "${CBOX_MCP_SERVERS:=all}"
  : "${CBOX_CODEX_PROGRESS_MODE:=off}"
  : "${CBOX_LOCAL_MODEL:=off}"
  : "${CBOX_LOCAL_MODEL_URL:=}"
  : "${CBOX_LOCAL_MODEL_NAME:=}"
  export CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME
  : "${CBOX_LIMIT_AUTORESUME:=off}"
  : "${CBOX_LIMIT_RESUME_DELAY:=300}"
  : "${CBOX_LIMIT_RESUME_PROMPT:=pokracuj}"
  : "${CBOX_LIMIT_RESUME_STAGGER:=30}"
  : "${CBOX_LIMIT_RESUME_MAX_PER_DAY:=10}"
  : "${CBOX_AGENTS:=all}"
  : "${CBOX_CODEX_MCP:=0}"
  : "${CBOX_GITCONFIG:=0}"
  : "${CBOX_APT_EXTRA:=}"
  : "${CBOX_CLAUDE_TARGET:=stable}"
  : "${CBOX_CODEX_VERSION:=latest}"
  : "${CBOX_CODEX_TARGET:=}"
  : "${CBOX_BINS_SCOPE:=global}"
  : "${CBOX_RESTART_POLICY:=no}"
  : "${CBOX_TPL_SHA:=}"
  : "${CBOX_MODE:=global}"
  : "${CBOX_SESSION_SCOPE:=isolated}"
  : "${CBOX_BASE_DIGEST_TTL:=3600}"
  : "${CBOX_HISTORY:=1}"
  : "${CBOX_GIT:=1}"
  : "${CBOX_DIARY:=1}"
  : "${CBOX_OPEN_QUESTIONS:=1}"
  : "${CBOX_CONTEXT_PROFILE:=full}"
  if [ -z "${CBOX_WORKDIR:-}" ]; then
    CBOX_WORKDIR="${CBOX_WORKSPACES%% *}"
    [ -n "$CBOX_WORKDIR" ] || CBOX_WORKDIR="$HOME"
  fi
}

conf_load() {
  if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
  fi
  conf_defaults
}

conf_save() {
  local out="${1:-$CONF_FILE}" tmp outdir
  outdir="$(dirname "$out")"
  mkdir -p "$outdir"
  tmp="$(mktemp "$outdir/.cbox.XXXXXX")"
  {
    printf 'CBOX_NAME=%q\n' "$CBOX_NAME"
    printf 'CBOX_WORKDIR=%q\n' "$CBOX_WORKDIR"
    printf 'CBOX_CLAUDE_MODE=%q\n' "$CBOX_CLAUDE_MODE"
    printf 'CBOX_CLAUDE_PATH=%q\n' "$CBOX_CLAUDE_PATH"
    printf 'CBOX_CLAUDE_BACKUP=%q\n' "$CBOX_CLAUDE_BACKUP"
    printf 'CBOX_CODEX_MODE=%q\n' "$CBOX_CODEX_MODE"
    printf 'CBOX_CODEX_PATH=%q\n' "$CBOX_CODEX_PATH"
    printf 'CBOX_CODEX_BACKUP=%q\n' "$CBOX_CODEX_BACKUP"
    printf 'CBOX_WORKSPACES=%q\n' "$CBOX_WORKSPACES"
    printf 'CBOX_VENV_MODE=%q\n' "$CBOX_VENV_MODE"
    printf 'CBOX_VENV_PATH=%q\n' "$CBOX_VENV_PATH"
    printf 'CBOX_GPU=%q\n' "$CBOX_GPU"
    printf 'CBOX_EGRESS_MODE=%q\n' "$CBOX_EGRESS_MODE"
    printf 'CBOX_EGRESS_APPLIED=%q\n' "$CBOX_EGRESS_APPLIED"
    printf 'CBOX_NETACCESS_MODE=%q\n' "$CBOX_NETACCESS_MODE"
    printf 'CBOX_NETACCESS_APPLIED=%q\n' "$CBOX_NETACCESS_APPLIED"
    printf 'CBOX_NETACCESS_NETWORKS=%q\n' "$CBOX_NETACCESS_NETWORKS"
    printf 'CBOX_NETACCESS_CIDRS=%q\n' "$CBOX_NETACCESS_CIDRS"
    printf 'CBOX_NETACCESS_SOCKS_PORT=%q\n' "$CBOX_NETACCESS_SOCKS_PORT"
    printf 'CBOX_HOST_ROUTE_MODE=%q\n' "$CBOX_HOST_ROUTE_MODE"
    printf 'CBOX_HOST_ROUTE_APPLIED=%q\n' "$CBOX_HOST_ROUTE_APPLIED"
    printf 'CBOX_HOST_PROXY_URL=%q\n' "$CBOX_HOST_PROXY_URL"
    printf 'CBOX_HOST_PROXY_ADDR_MODE=%q\n' "$CBOX_HOST_PROXY_ADDR_MODE"
    printf 'CBOX_SSH_MODE=%q\n' "$CBOX_SSH_MODE"
    printf 'CBOX_SSH_AGENT_DIR=%q\n' "$CBOX_SSH_AGENT_DIR"
    printf 'CBOX_BASHRC=%q\n' "$CBOX_BASHRC"
    printf 'CBOX_MCP_SERVERS=%q\n' "$CBOX_MCP_SERVERS"
    printf 'CBOX_CODEX_PROGRESS_MODE=%q\n' "$CBOX_CODEX_PROGRESS_MODE"
    printf 'CBOX_LOCAL_MODEL=%q\n' "$CBOX_LOCAL_MODEL"
    printf 'CBOX_LOCAL_MODEL_URL=%q\n' "$CBOX_LOCAL_MODEL_URL"
    printf 'CBOX_LOCAL_MODEL_NAME=%q\n' "$CBOX_LOCAL_MODEL_NAME"
    printf 'CBOX_LIMIT_AUTORESUME=%q\n' "$CBOX_LIMIT_AUTORESUME"
    printf 'CBOX_LIMIT_RESUME_DELAY=%q\n' "$CBOX_LIMIT_RESUME_DELAY"
    printf 'CBOX_LIMIT_RESUME_PROMPT=%q\n' "$CBOX_LIMIT_RESUME_PROMPT"
    printf 'CBOX_LIMIT_RESUME_STAGGER=%q\n' "$CBOX_LIMIT_RESUME_STAGGER"
    printf 'CBOX_LIMIT_RESUME_MAX_PER_DAY=%q\n' "$CBOX_LIMIT_RESUME_MAX_PER_DAY"
    printf 'CBOX_AGENTS=%q\n' "$CBOX_AGENTS"
    printf 'CBOX_CODEX_MCP=%q\n' "$CBOX_CODEX_MCP"
    printf 'CBOX_GITCONFIG=%q\n' "$CBOX_GITCONFIG"
    printf 'CBOX_APT_EXTRA=%q\n' "$CBOX_APT_EXTRA"
    printf 'CBOX_CLAUDE_TARGET=%q\n' "$CBOX_CLAUDE_TARGET"
    printf 'CBOX_CODEX_VERSION=%q\n' "$CBOX_CODEX_VERSION"
    printf 'CBOX_CODEX_TARGET=%q\n' "$CBOX_CODEX_TARGET"
    printf 'CBOX_BINS_SCOPE=%q\n' "$CBOX_BINS_SCOPE"
    printf 'CBOX_RESTART_POLICY=%q\n' "$CBOX_RESTART_POLICY"
    printf 'CBOX_TPL_SHA=%q\n' "$CBOX_TPL_SHA"
    printf 'CBOX_MODE=%q\n' "$CBOX_MODE"
    printf 'CBOX_SESSION_SCOPE=%q\n' "$CBOX_SESSION_SCOPE"
    printf 'CBOX_BASE_DIGEST_TTL=%q\n' "$CBOX_BASE_DIGEST_TTL"
    printf 'CBOX_HISTORY=%q\n' "$CBOX_HISTORY"
    printf 'CBOX_GIT=%q\n' "$CBOX_GIT"
    printf 'CBOX_DIARY=%q\n' "$CBOX_DIARY"
    printf 'CBOX_OPEN_QUESTIONS=%q\n' "$CBOX_OPEN_QUESTIONS"
    printf 'CBOX_CONTEXT_PROFILE=%q\n' "$CBOX_CONTEXT_PROFILE"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$out"
}

load_generators() {
  [ -f "$INSTALL_DIR/templates/generators.sh" ] || die "templates/generators.sh missing"
  . "$INSTALL_DIR/templates/generators.sh"
}

_read_key() {
  local key rest
  IFS= read -rsn1 -d '' key || return 1
  case "$key" in
    $'\r'|$'\n'|'')
      KEY=enter
      ;;
    ' ')
      KEY=space
      ;;
    $'\x1b')
      rest=""
      IFS= read -rsn2 -t 0.05 -d '' rest || true
      case "$rest" in
        '[A') KEY=up ;;
        '[B') KEY=down ;;
        *)
          KEY=esc
          while IFS= read -rsn1 -t 0.01 -d '' rest; do :; done
          ;;
      esac
      ;;
    *)
      KEY="$key"
      ;;
  esac
  return 0
}

_menu_select() {
  local prompt="$1" prefill="$2"
  shift 2
  local -a opts=("$@")
  local n="${#opts[@]}" sel=0 i total hint pointer line

  if [ "$n" -eq 0 ]; then
    MENU_VALUE="$prefill"
    return 0
  fi

  sel=0
  for i in "${!opts[@]}"; do
    if [ "${opts[i]}" = "$prefill" ]; then
      sel="$i"
    fi
  done

  total=$((n+1))
  hint="${C_DIM}arrows move  enter select${C_RESET}"

  printf '\033[?25l' >&2
  printf '%s\n' "$prompt" >&2
  local first=1
  while :; do
    if [ "$first" = 1 ]; then
      first=0
    else
      printf '\033[%dA' "$total" >&2
    fi
    for i in "${!opts[@]}"; do
      if [ "$i" = "$sel" ]; then
        if [ -n "$C_REV" ]; then
          pointer="${C_REV}> ${opts[i]}${C_RESET}"
        else
          pointer="${C_BOLD}${C_ACCENT}> ${opts[i]}${C_RESET}"
        fi
      else
        pointer="  ${opts[i]}"
      fi
      printf '%s\033[K\n' "$pointer" >&2
    done
    printf '%s\033[K\n' "$hint" >&2

    if ! _read_key; then
      break
    fi
    case "$KEY" in
      up|k)
        sel=$(( (sel - 1 + n) % n ))
        ;;
      down|j)
        sel=$(( (sel + 1) % n ))
        ;;
      enter|esc)
        break
        ;;
      [1-9])
        if [ "$KEY" -ge 1 ] && [ "$KEY" -le "$n" ]; then
          sel=$((KEY-1))
          break
        fi
        ;;
      *)
        :
        ;;
    esac
  done

  printf '\033[%dA' "$total" >&2
  i=0
  while [ "$i" -lt "$total" ]; do
    printf '\033[K\n' >&2
    i=$((i+1))
  done
  printf '\033[%dA' "$total" >&2
  MENU_VALUE="${opts[sel]}"
  printf '%s %s%s%s\n' "$prompt" "$C_ACCENT" "$MENU_VALUE" "$C_RESET" >&2
  printf '\033[?25h' >&2
  return 0
}

ask() {
  local prompt="$1" prefill="${2:-}"
  read -e -r -i "$prefill" -p "$prompt" ASK_VALUE
}

ask_choice() {
  local prompt="$1" prefill="$2" v
  shift 2
  if [ "$CBOX_TUI" = 1 ]; then
    _menu_select "$prompt ${P_DIM}[${P_RESET}${P_ACCENT}$*${P_RESET}${P_DIM}]:${P_RESET}" "$prefill" "$@"
    ASK_VALUE="$MENU_VALUE"
    return 0
  fi
  while :; do
    ask "$prompt ${P_DIM}[${P_RESET}${P_ACCENT}$*${P_RESET}${P_DIM}]:${P_RESET} " "$prefill"
    for v in "$@"; do
      if [ "$ASK_VALUE" = "$v" ]; then
        return 0
      fi
    done
    warn "expected one of: $*"
  done
}

ask_yn() {
  local prompt="$1" def="${2:-n}" ans badge
  prompt="${prompt% \[y/N\]}"
  prompt="${prompt% \[Y/n\]}"
  if [ "$def" = y ]; then
    badge="${C_DIM}[${C_RESET}${C_BOLD}${C_ACCENT}Y${C_RESET}${C_DIM}/n]${C_RESET}"
  else
    badge="${C_DIM}[y/${C_RESET}${C_BOLD}${C_ACCENT}N${C_RESET}${C_DIM}]${C_RESET}"
  fi
  if [ "$CBOX_TUI" = 1 ]; then
    printf '%s %s ' "$prompt" "$badge" >&2
    while :; do
      if ! _read_key; then
        printf '%s\n' "$def" >&2
        [ "$def" = y ] && return 0 || return 1
      fi
      case "$KEY" in
        y|Y)
          printf 'y\n' >&2
          return 0
          ;;
        n|N)
          printf 'n\n' >&2
          return 1
          ;;
        enter|esc)
          printf '%s\n' "$def" >&2
          [ "$def" = y ] && return 0 || return 1
          ;;
        *)
          :
          ;;
      esac
    done
  fi
  read -r -p "$prompt $badge " ans
  [ -n "$ans" ] || ans="$def"
  case "$ans" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

path_input() {
  local prompt="$1" prefill="$2" must_exist="${3:-1}" raw
  while :; do
    ask "$prompt" "$prefill"
    raw="$ASK_VALUE"
    if [ -z "$raw" ]; then
      PATH_VALUE=""
      return 1
    fi
    case "$raw" in
      "~") raw="$HOME" ;;
      "~/"*) raw="$HOME/${raw#\~/}" ;;
    esac
    case "$raw" in
      *" "*) warn "paths containing spaces are rejected"; continue ;;
    esac
    raw="$(realpath -m "$raw")"
    if [ "$must_exist" = 1 ] && [ ! -d "$raw" ]; then
      warn "directory does not exist: $raw"
      continue
    fi
    PATH_VALUE="$raw"
    return 0
  done
}

_path_is_within() {
  local a="$1" b="$2"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$a" in
    "$b"/*) return 0 ;;
  esac
  return 1
}

reserved_path_conflict() {
  local candidate="$1" label reserved
  for label in INSTALL_DIR CBOX_CLAUDE_PATH CBOX_CODEX_PATH CBOX_VENV_PATH; do
    reserved="$(realpath -m "${!label}" 2>/dev/null || printf '')"
    [ -n "$reserved" ] || continue
    if _path_is_within "$candidate" "$reserved" || _path_is_within "$reserved" "$candidate"; then
      echo "setup: workspace path conflicts with $label ($reserved): $candidate"
      if [ "$label" = INSTALL_DIR ]; then
        echo "setup: a workspace must not contain or live inside the cbox install dir - to develop cbox itself, use a copied tree"
      fi
      return 0
    fi
  done
  return 1
}

_checkbox_select_tui() {
  local n="${#CB_ITEMS[@]}" total hint i cur row pointer marker name selcount names namestr
  [ "$n" -gt 0 ] || return 0
  local all_disabled=1
  for i in "${!CB_DISABLED[@]}"; do
    if [ "${CB_DISABLED[i]}" != 1 ]; then
      all_disabled=0
    fi
  done
  cur=0
  for i in "${!CB_ITEMS[@]}"; do
    if [ "${CB_DISABLED[i]}" != 1 ]; then
      cur="$i"
      break
    fi
  done
  total=$((n+1))
  hint="${C_DIM}space toggle  enter accept${C_RESET}"

  printf '\033[?25l' >&2
  local first=1
  while :; do
    if [ "$first" = 1 ]; then
      first=0
    else
      printf '\033[%dA' "$total" >&2
    fi
    for i in "${!CB_ITEMS[@]}"; do
      if [ "$i" = "$cur" ]; then
        pointer="> "
      else
        pointer="  "
      fi
      if [ "${CB_DISABLED[i]}" = 1 ]; then
        row="${pointer}${C_MUTE}[-]${C_RESET} ${C_MUTE}$(printf '%2d' "$((i+1))") ${CB_ITEMS[i]} (${CB_REASON[i]})${C_RESET}"
      else
        if [ "${CB_STATE[i]}" = y ]; then
          marker="${C_DIM}[${C_OK}x${C_DIM}]${C_RESET}"
        else
          marker="${C_DIM}[ ]${C_RESET}"
        fi
        if [ "$i" = "$cur" ]; then
          if [ -n "$C_REV" ]; then
            row="${C_REV}${pointer}${marker} $(printf '%2d' "$((i+1))") ${CB_ITEMS[i]}${C_RESET}"
          else
            row="${C_BOLD}${C_ACCENT}${pointer}${C_RESET}${marker} ${C_DIM}$(printf '%2d' "$((i+1))")${C_RESET} ${CB_ITEMS[i]}"
          fi
        else
          row="${pointer}${marker} ${C_DIM}$(printf '%2d' "$((i+1))")${C_RESET} ${CB_ITEMS[i]}"
        fi
      fi
      printf '%s\033[K\n' "$row" >&2
    done
    printf '%s\033[K\n' "$hint" >&2

    if ! _read_key; then
      break
    fi
    case "$KEY" in
      up|k)
        if [ "$all_disabled" != 1 ]; then
          i="$cur"
          while :; do
            i=$(( (i - 1 + n) % n ))
            if [ "${CB_DISABLED[i]}" != 1 ]; then
              cur="$i"
              break
            fi
          done
        fi
        ;;
      down|j)
        if [ "$all_disabled" != 1 ]; then
          i="$cur"
          while :; do
            i=$(( (i + 1) % n ))
            if [ "${CB_DISABLED[i]}" != 1 ]; then
              cur="$i"
              break
            fi
          done
        fi
        ;;
      space)
        if [ "${CB_DISABLED[cur]}" != 1 ]; then
          if [ "${CB_STATE[cur]}" = y ]; then
            CB_STATE[cur]=n
          else
            CB_STATE[cur]=y
          fi
        fi
        ;;
      enter|esc)
        break
        ;;
      [1-9])
        i=$((KEY-1))
        if [ "$i" -ge 0 ] && [ "$i" -lt "$n" ] && [ "${CB_DISABLED[i]}" != 1 ]; then
          cur="$i"
          if [ "${CB_STATE[i]}" = y ]; then
            CB_STATE[i]=n
          else
            CB_STATE[i]=y
          fi
        fi
        ;;
      *)
        :
        ;;
    esac
  done

  printf '\033[%dA' "$total" >&2
  i=0
  while [ "$i" -lt "$total" ]; do
    printf '\033[K\n' >&2
    i=$((i+1))
  done
  printf '\033[%dA' "$total" >&2

  names=()
  selcount=0
  for i in "${!CB_ITEMS[@]}"; do
    if [ "${CB_STATE[i]}" = y ]; then
      names+=("${CB_ITEMS[i]}")
      selcount=$((selcount+1))
    fi
  done
  namestr="${names[*]-}"
  printf '%sselected (%d): %s%s\n' "$C_DIM" "$selcount" "$namestr" "$C_RESET" >&2
  printf '\033[?25h' >&2
  return 0
}

checkbox_select() {
  local i line tok
  if [ "$CBOX_TUI" = 1 ]; then
    _checkbox_select_tui
    return 0
  fi
  while :; do
    for i in "${!CB_ITEMS[@]}"; do
      if [ "${CB_DISABLED[i]}" = 1 ]; then
        printf '  %s[-]%s %s%2d %s (%s)%s\n' "$C_MUTE" "$C_RESET" "$C_MUTE" "$((i+1))" "${CB_ITEMS[i]}" "${CB_REASON[i]}" "$C_RESET"
      else
        if [ "${CB_STATE[i]}" = y ]; then
          printf '  %s[%sx%s]%s %s%2d%s %s\n' "$C_DIM" "$C_OK" "$C_DIM" "$C_RESET" "$C_DIM" "$((i+1))" "$C_RESET" "${CB_ITEMS[i]}"
        else
          printf '  %s[ ]%s %s%2d%s %s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$((i+1))" "$C_RESET" "${CB_ITEMS[i]}"
        fi
      fi
    done
    read -r -p "${C_MUTE}setup:${C_RESET} toggle numbers ${C_DIM}(space-separated)${C_RESET}, Enter to accept: " line
    [ -n "$line" ] || return 0
    for tok in $line; do
      case "$tok" in
        ""|*[!0-9]*) warn "not a number: $tok"; continue ;;
      esac
      i=$((tok-1))
      if [ "$i" -lt 0 ] || [ "$i" -ge "${#CB_ITEMS[@]}" ]; then
        warn "out of range: $tok"
        continue
      fi
      if [ "${CB_DISABLED[i]}" = 1 ]; then
        warn "${CB_ITEMS[i]} is disabled (${CB_REASON[i]})"
        continue
      fi
      if [ "${CB_STATE[i]}" = y ]; then
        CB_STATE[i]=n
      else
        CB_STATE[i]=y
      fi
    done
  done
}

nav_prompt() {
  local line i badge section idx
  badge="${C_MUTE}setup:${C_RESET} ${C_DIM}[${C_RESET}${C_ACCENT}Enter${C_RESET}${C_DIM}=next ${C_RESET}${C_ACCENT}b${C_RESET}${C_DIM}=back ${C_RESET}${C_ACCENT}j${C_RESET}${C_DIM}=jump ${C_RESET}${C_ACCENT}q${C_RESET}${C_DIM}=save+quit ${C_RESET}${C_ACCENT}h${C_RESET}${C_DIM}=help]${C_RESET}"
  if [ "$CBOX_TUI" = 1 ]; then
    printf '%s ' "$badge" >&2
    while :; do
      if ! _read_key; then
        printf '\n' >&2
        NAV="next"
        return 0
      fi
      case "$KEY" in
        enter)
          printf '\n' >&2
          NAV="next"
          return 0
          ;;
        b)
          printf '\n' >&2
          NAV="back"
          return 0
          ;;
        q)
          printf '\n' >&2
          NAV="quit"
          return 0
          ;;
        j)
          printf '\n' >&2
          _menu_select "jump to section" "" "${WIZ_SECTIONS[@]}"
          section="$MENU_VALUE"
          idx=0
          for i in "${!WIZ_SECTIONS[@]}"; do
            if [ "${WIZ_SECTIONS[i]}" = "$section" ]; then
              idx=$((i+1))
            fi
          done
          NAV="$idx"
          return 0
          ;;
        h)
          printf '\n' >&2
          print_settings_help >&2
          printf '%s ' "$badge" >&2
          ;;
        *)
          :
          ;;
      esac
    done
  fi
  while :; do
    read -r -p "$badge " line
    case "$line" in
      "") NAV="next"; return 0 ;;
      b) NAV="back"; return 0 ;;
      q) NAV="quit"; return 0 ;;
      h)
        print_settings_help >&2
        continue
        ;;
      j)
        for i in "${!WIZ_SECTIONS[@]}"; do
          printf '  %s%2d%s %s\n' "$C_ACCENT" "$((i+1))" "$C_RESET" "${WIZ_SECTIONS[i]}"
        done
        read -r -p "${C_MUTE}setup:${C_RESET} jump to section number: " line
        case "$line" in
          ""|*[!0-9]*) warn "not a number"; continue ;;
        esac
        if [ "$line" -ge 1 ] && [ "$line" -le "${#WIZ_SECTIONS[@]}" ]; then
          NAV="$line"
          return 0
        fi
        warn "out of range"
        ;;
      *) warn "unknown choice" ;;
    esac
  done
}

backup_host_file() {
  local target="$1" dest
  [ -e "$target" ] || return 0
  dest="$BACKUP_DIR$target"
  [ -e "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")"
  cp -a "$target" "$dest"
  note "backup: $target -> $dest"
}

staged_write() {
  local target="$1" staged="$2" mode="${3:-0644}" ans
  if [ -f "$target" ] && cmp -s "$staged" "$target"; then
    note "$target unchanged"
    return 0
  fi
  if [ "$SEC_AUTO" = 1 ]; then
    note "auto: installing $target"
  else
    echo "== $target =="
    if [ -f "$target" ]; then
      diff -u "$target" "$staged" || true
    else
      echo "(new file)"
      sed 's/^/+ /' "$staged"
    fi
    read -r -p "setup: install this change to $target? [y/N] " ans
    case "$ans" in
      y|Y) ;;
      *) note "skipped $target"; return 1 ;;
    esac
  fi
  backup_host_file "$target"
  mkdir -p "$(dirname "$target")"
  install -m "$mode" "$staged" "$target"
  note "installed $target"
}

staged_install_files() {
  local src="$1" dst="$2" mode="$3" stage f changed=0 ans
  shift 3
  stage="$(mktemp -d)"
  for f in "$@"; do
    [ -f "$src/$f" ] || { rm -rf "$stage"; die "missing source file $src/$f"; }
    cp "$src/$f" "$stage/$f"
    if [ -f "$dst/$f" ] && cmp -s "$stage/$f" "$dst/$f"; then
      note "$f unchanged"
      continue
    fi
    if [ "$SEC_AUTO" != 1 ]; then
      echo "== $f: $dst vs staged =="
      if [ -f "$dst/$f" ]; then
        diff -u "$dst/$f" "$stage/$f" || true
      else
        echo "(new file)"
        sed 's/^/+ /' "$stage/$f"
      fi
    fi
    changed=1
  done
  if [ "$changed" = 0 ]; then
    rm -rf "$stage"
    return 0
  fi
  if [ "$SEC_AUTO" != 1 ]; then
    read -r -p "setup: install the changes above into $dst? [y/N] " ans
    case "$ans" in
      y|Y) ;;
      *) rm -rf "$stage"; note "skipped $dst"; return 1 ;;
    esac
  fi
  mkdir -p "$dst"
  for f in "$@"; do
    if [ -f "$dst/$f" ] && cmp -s "$stage/$f" "$dst/$f"; then
      continue
    fi
    backup_host_file "$dst/$f"
    install -m "$mode" "$stage/$f" "$dst/$f"
  done
  rm -rf "$stage"
  note "installed into $dst"
}

merge_settings_json() {
  local target="$1" merge="$2" home="$3" out="$4"
  python3 - "$target" "$merge" "$home" "$out" <<'PYEOF'
import json, os, sys
target, merge_path, home, out = sys.argv[1:5]
data = {}
if os.path.isfile(target):
    try:
        with open(target) as f:
            data = json.load(f)
    except ValueError:
        sys.exit("setup: cannot parse " + target)
with open(merge_path) as f:
    raw = f.read().replace("@HOME@", home)
merge = json.loads(raw)

def merge_hooks(dst, src):
    for event, entries in src.items():
        lst = dst.setdefault(event, [])
        for entry in entries:
            matcher = entry.get("matcher")
            found = None
            for e in lst:
                if e.get("matcher") == matcher:
                    found = e
                    break
            if found is None:
                lst.append(entry)
                continue
            have = {h.get("command") for h in found.get("hooks", [])}
            for h in entry.get("hooks", []):
                if h.get("command") not in have:
                    found.setdefault("hooks", []).append(h)

for key, val in merge.items():
    if key == "hooks":
        merge_hooks(data.setdefault("hooks", {}), val)
    elif isinstance(val, dict):
        cur = data.setdefault(key, {})
        for k2, v2 in val.items():
            cur[k2] = v2
    else:
        data[key] = val

with open(out, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
}

merge_mcp_json() {
  local target="$1" servers="$2" selected="$3" out="$4" shim_mode="${5:-off}" shim_home="${6:-$HOME}"
  local progress_flag="off"
  [ "$shim_mode" = shim ] && progress_flag="on"
  local hooks_dir="$shim_home/.claude/hooks"
  local rendered_file
  rendered_file="$(mktemp)"
  python3 "$ETC_DIR/mcp/render_mcp.py" "$servers" "$selected" "$hooks_dir" "$progress_flag" claude > "$rendered_file" \
    || { rm -f "$rendered_file"; die "render_mcp.py failed for $servers"; }
  python3 - "$target" "$selected" "$out" "$rendered_file" "$servers" <<'PYEOF'
import json, os, sys
target, selected_raw, out, rendered_file, servers_file = sys.argv[1:6]
selected = set(selected_raw.split())
data = {}
if os.path.isfile(target):
    try:
        with open(target) as f:
            data = json.load(f)
    except ValueError:
        sys.exit("setup: cannot parse " + target)
with open(rendered_file) as f:
    rendered = json.load(f)
with open(servers_file) as f:
    delegates = json.load(f)
known_cbox = set(delegates.keys())
mcp = data.setdefault("mcpServers", {})
for name in list(mcp.keys()):
    if name in known_cbox and name not in rendered:
        mcp.pop(name, None)
mcp.update(rendered)
with open(out, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
  rm -f "$rendered_file"
}

bashrc_block_file() {
  local out="$1"
  {
    printf '%s\n' "$MARK_START"
    printf '[ -f "$HOME/.bashrc-cbox" ] && . "$HOME/.bashrc-cbox"\n'
    printf '%s\n' "$MARK_END"
  } > "$out"
}

merge_bashrc_block() {
  local file="$1" block tmp
  block="$(mktemp)"
  bashrc_block_file "$block"
  tmp="$(mktemp)"
  if grep -qF "$MARK_START" "$file" && grep -qF "$MARK_END" "$file"; then
    awk -v s="$MARK_START" -v e="$MARK_END" -v bf="$block" '
      index($0, s) { skip = 1; while ((getline line < bf) > 0) print line; close(bf); next }
      index($0, e) { skip = 0; next }
      skip { next }
      { print }
    ' "$file" > "$tmp"
  else
    cp "$file" "$tmp"
    if [ -s "$tmp" ]; then
      printf '\n' >> "$tmp"
    fi
    cat "$block" >> "$tmp"
  fi
  mv "$tmp" "$file"
  rm -f "$block"
}

bashrc_old_lines() {
  awk -v s="$MARK_START" -v e="$MARK_END" -v p="$SUPERSEDED_PREFIX" '
    index($0, s) { inb = 1 }
    index($0, e) { inb = 0; next }
    inb { next }
    index($0, p) == 1 { next }
    /^[[:space:]]*#/ { next }
    /CLAUDE_DOCKER_DIR|_cbox_ensure/ { print FNR ": " $0 }
  ' "$1"
}

bashrc_comment_old() {
  local file="$1" tmp
  tmp="$(mktemp)"
  awk -v s="$MARK_START" -v e="$MARK_END" -v p="$SUPERSEDED_PREFIX" '
    index($0, s) { inb = 1 }
    index($0, e) { print; inb = 0; next }
    inb { print; next }
    index($0, p) == 1 { print; next }
    /^[[:space:]]*#/ { print; next }
    /CLAUDE_DOCKER_DIR|_cbox_ensure/ { print p $0; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

step_mode() {
  echo "== section: mode =="
  ask_choice "setup: container mode" "$CBOX_MODE" global isolated
  CBOX_MODE="$ASK_VALUE"
  if [ "$CBOX_MODE" = global ]; then
    note "global mode: one shared container for every workspace on this machine, exactly as configured below"
    note "warning: a global-mode session that is not the one attached to your terminal becomes invisible and unreachable from another shell - it is never lost, its container keeps running and its work stays on disk, but you cannot see or attach to it until you find it again"
    return 0
  fi
  note "isolated mode: cbox run derives one per-project container from the workspace root (git toplevel or cwd), out-of-mount effective config under ~/.config/cbox/projects/<hash>"
  ask_choice "setup: session scope (which slice of ~/.claude/projects a container mounts)" "$CBOX_SESSION_SCOPE" isolated global
  CBOX_SESSION_SCOPE="$ASK_VALUE"
  if [ "$CBOX_SESSION_SCOPE" = isolated ]; then
    note "session-scope isolated: a container mounts only its own ~/.claude/projects/<slug>; other projects' sessions stay invisible to it"
  else
    note "session-scope global: a container mounts the whole ~/.claude/projects tree; every project's sessions are visible inside it"
  fi
  ask "setup: base image digest cache TTL in seconds (0 = re-check every launch): " "$CBOX_BASE_DIGEST_TTL"
  case "$ASK_VALUE" in
    ''|*[!0-9]*) warn "not a number; keeping $CBOX_BASE_DIGEST_TTL" ;;
    *) CBOX_BASE_DIGEST_TTL="$ASK_VALUE" ;;
  esac
}

step_mounts() {
  echo "== section: mounts =="
  ask_choice "setup: ~/.claude mode" "$CBOX_CLAUDE_MODE" mount volume
  if [ "$ASK_VALUE" = mount ]; then
    if path_input "setup: host directory for ~/.claude (empty = switch to volume): " "$CBOX_CLAUDE_PATH" 1; then
      CBOX_CLAUDE_MODE=mount
      CBOX_CLAUDE_PATH="$PATH_VALUE"
      ask_choice "setup: back up $CBOX_CLAUDE_PATH before first run (y=copy c=tar.gz n=no)" "$CBOX_CLAUDE_BACKUP" y c n
      CBOX_CLAUDE_BACKUP="$ASK_VALUE"
    else
      note "no existing directory given; using volume mode for ~/.claude"
      CBOX_CLAUDE_MODE=volume
      CBOX_CLAUDE_BACKUP=n
    fi
  else
    CBOX_CLAUDE_MODE=volume
    CBOX_CLAUDE_BACKUP=n
  fi
  if [ "$CBOX_CLAUDE_MODE" = volume ]; then
    note "~/.claude lives in volume ${CBOX_NAME}-claude; ~/.claude.json is backed by generated/state/claude.json"
  fi
  ask_choice "setup: ~/.codex mode" "$CBOX_CODEX_MODE" mount volume
  if [ "$ASK_VALUE" = mount ]; then
    if path_input "setup: host directory for ~/.codex (empty = switch to volume): " "$CBOX_CODEX_PATH" 1; then
      CBOX_CODEX_MODE=mount
      CBOX_CODEX_PATH="$PATH_VALUE"
      ask_choice "setup: back up $CBOX_CODEX_PATH before first run (y=copy c=tar.gz n=no)" "$CBOX_CODEX_BACKUP" y c n
      CBOX_CODEX_BACKUP="$ASK_VALUE"
    else
      note "no existing directory given; using volume mode for ~/.codex"
      CBOX_CODEX_MODE=volume
      CBOX_CODEX_BACKUP=n
    fi
  else
    CBOX_CODEX_MODE=volume
    CBOX_CODEX_BACKUP=n
  fi
  if [ "$CBOX_CODEX_MODE" = volume ]; then
    note "~/.codex lives in volume ${CBOX_NAME}-codex"
  fi
  note "guard hooks and settings.json are bind-mounted read-only in both modes"
  if [ "$SETUP_MODE" = update ]; then
    run_backups
  fi
}

step_workspaces() {
  echo "== section: workspaces =="
  local existing=() out=() prefill w dup idx=0
  read -r -a existing <<< "$CBOX_WORKSPACES"
  note "workspace directories are mounted 1:1 read-write; enter one per line, empty line finishes"
  while :; do
    prefill=""
    if [ "$idx" -lt "${#existing[@]}" ]; then
      prefill="${existing[idx]}"
    fi
    if ! path_input "setup: workspace path: " "$prefill" 1; then
      break
    fi
    if reserved_path_conflict "$PATH_VALUE"; then
      idx=$((idx+1))
      continue
    fi
    dup=0
    for w in "${out[@]}"; do
      if [ "$w" = "$PATH_VALUE" ]; then
        dup=1
      fi
    done
    if [ "$dup" = 1 ]; then
      note "duplicate ignored: $PATH_VALUE"
    else
      if ! git -C "$PATH_VALUE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if ask_yn "setup: $PATH_VALUE is not a git work-tree; run git init there? [y/N]" n; then
          git -C "$PATH_VALUE" init || note "warning: git init failed in $PATH_VALUE; continuing without version control there"
        else
          note "warning: $PATH_VALUE has no git history; the codex guard denies write-capable delegation into it and verify flags it"
        fi
      fi
      out+=("$PATH_VALUE")
    fi
    idx=$((idx+1))
  done
  CBOX_WORKSPACES="${out[*]-}"
  if [ -z "$CBOX_WORKSPACES" ]; then
    note "warning: no workspaces mounted; the codex guard is fail-closed and the container sees no project directories"
    CBOX_WORKDIR="$HOME"
  else
    CBOX_WORKDIR="${out[0]}"
  fi
  note "default workdir: $CBOX_WORKDIR"
  note "codex guard scope roots follow this workspace list"
}

step_python() {
  echo "== section: python =="
  ask_choice "setup: venv mode" "$CBOX_VENV_MODE" none host volume
  CBOX_VENV_MODE="$ASK_VALUE"
  case "$CBOX_VENV_MODE" in
    host)
      if path_input "setup: host venv path (mounted read-only at the same path): " "$CBOX_VENV_PATH" 1; then
        CBOX_VENV_PATH="$PATH_VALUE"
      else
        note "no existing directory given; venv mode set to none"
        CBOX_VENV_MODE=none
      fi
      ;;
    volume)
      note "venv volume ${CBOX_NAME}-venv is mounted at /opt/venv"
      ;;
    none)
      :
      ;;
  esac
  note "python3 is always present in the image"
}

step_gpu() {
  echo "== section: gpu =="
  ask_choice "setup: enable gpu support (CDI)" "$CBOX_GPU" 0 1
  CBOX_GPU="$ASK_VALUE"
  [ "$CBOX_GPU" = 1 ] || return 0
  section_dep_gate gpu
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    note "nvidia-ctk not found; run these commands manually (the docker restart stops all running containers):"
    echo "  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    echo "  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    echo "  sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
    echo "  sudo nvidia-ctk runtime configure --runtime=docker"
    echo "  sudo systemctl restart docker"
  fi
  if [ ! -f /etc/cdi/nvidia.yaml ]; then
    note "CDI spec /etc/cdi/nvidia.yaml not found; generate it manually:"
    echo "  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
  fi
  if [ "$DEP_ACTION" = disable ]; then
    note "gpu section disabled: $DEP_REASON"
    CBOX_GPU=0
    return 0
  fi
  note "gpu is a runtime flag: ./cbox up --gpu, or sudo ./bind_egpu.sh after plugging the eGPU"
}

step_egress() {
  echo "== section: egress =="
  local prev_mode="$CBOX_EGRESS_MODE"
  ask_choice "setup: egress mode" "$CBOX_EGRESS_MODE" off allowlist blocklist
  CBOX_EGRESS_MODE="$ASK_VALUE"
  if [ "$SETUP_MODE" = update ] && [ "$CBOX_EGRESS_MODE" != off ]; then
    CBOX_EGRESS_APPLIED=1
  elif [ "$CBOX_EGRESS_MODE" != "$prev_mode" ]; then
    CBOX_EGRESS_APPLIED=0
  fi
  [ "$CBOX_EGRESS_MODE" != off ] || return 0
  local list="$ETC_DIR/egress-allowlist.txt"
  if [ "$CBOX_EGRESS_MODE" = blocklist ]; then
    list="$ETC_DIR/egress-blocklist.txt"
  fi
  if [ -f "$list" ]; then
    note "current entries in $list:"
    sed 's/^/  /' "$list"
  else
    note "warning: list file missing: $list"
  fi
  note "add domains one per line; empty line finishes"
  while :; do
    ask "setup: domain: " ""
    [ -n "$ASK_VALUE" ] || break
    case "$ASK_VALUE" in
      *[!A-Za-z0-9.-]*) echo "setup: invalid domain: $ASK_VALUE"; continue ;;
    esac
    if [ -f "$list" ] && grep -qxF "$ASK_VALUE" "$list"; then
      note "already listed: $ASK_VALUE"
    else
      printf '%s\n' "$ASK_VALUE" >> "$list"
      note "added $ASK_VALUE"
    fi
  done
  note "login-first: the wizard applies the egress lockdown only after the login step"
}

step_netaccess() {
  echo "== section: netaccess =="
  local prev_mode="$CBOX_NETACCESS_MODE"
  ask_choice "setup: netaccess mode" "$CBOX_NETACCESS_MODE" off socks
  CBOX_NETACCESS_MODE="$ASK_VALUE"
  if [ "$SETUP_MODE" = update ] && [ "$CBOX_NETACCESS_MODE" != off ]; then
    CBOX_NETACCESS_APPLIED=1
  elif [ "$CBOX_NETACCESS_MODE" != "$prev_mode" ]; then
    CBOX_NETACCESS_APPLIED=0
  fi
  [ "$CBOX_NETACCESS_MODE" != off ] || return 0
  note "phase-1 config only: the proxy is not wired to any network yet, and access is whole-network (all TCP on the joined networks)"
  if [ -n "$CBOX_NETACCESS_NETWORKS" ]; then
    note "current docker networks: $CBOX_NETACCESS_NETWORKS"
  fi
  note "add docker network names one per line; empty line finishes"
  while :; do
    ask "setup: docker network: " ""
    [ -n "$ASK_VALUE" ] || break
    case "$ASK_VALUE" in
      [A-Za-z0-9]*) ;;
      *) echo "setup: invalid network name: $ASK_VALUE"; continue ;;
    esac
    case "$ASK_VALUE" in
      *[!A-Za-z0-9_.-]*) echo "setup: invalid network name: $ASK_VALUE"; continue ;;
    esac
    case " $CBOX_NETACCESS_NETWORKS " in
      *" $ASK_VALUE "*) note "already listed: $ASK_VALUE" ;;
      *)
        if [ -z "$CBOX_NETACCESS_NETWORKS" ]; then
          CBOX_NETACCESS_NETWORKS="$ASK_VALUE"
        else
          CBOX_NETACCESS_NETWORKS="$CBOX_NETACCESS_NETWORKS $ASK_VALUE"
        fi
        note "added $ASK_VALUE"
        ;;
    esac
  done
  command -v _cbox_is_ipv4_cidr >/dev/null 2>&1 || load_generators
  if [ -n "$CBOX_NETACCESS_CIDRS" ]; then
    note "current raw CIDR targets: $CBOX_NETACCESS_CIDRS"
  fi
  note "add raw IPv4 CIDR targets outside docker networks (e.g. k3s pods 10.42.0.0/16, services 10.43.0.0/16); like the network list they stay inert until the lifecycle phase renders sockd.conf, and reachability from the proxy is host-routing dependent; empty line finishes"
  while :; do
    ask "setup: target CIDR: " ""
    [ -n "$ASK_VALUE" ] || break
    if ! _cbox_is_ipv4_cidr "$ASK_VALUE" || [ "${ASK_VALUE%/*}" = "0.0.0.0" ]; then
      echo "setup: invalid IPv4 CIDR: $ASK_VALUE"
      continue
    fi
    if [ "${ASK_VALUE#*/}" -lt 8 ]; then
      echo "setup: prefix too broad (minimum /8): $ASK_VALUE"
      continue
    fi
    case " $CBOX_NETACCESS_CIDRS " in
      *" $ASK_VALUE "*) note "already listed: $ASK_VALUE" ;;
      *)
        CBOX_NETACCESS_CIDRS="${CBOX_NETACCESS_CIDRS:+$CBOX_NETACCESS_CIDRS }$ASK_VALUE"
        note "added $ASK_VALUE"
        ;;
    esac
  done
  ask "setup: SOCKS proxy port: " "$CBOX_NETACCESS_SOCKS_PORT"
  case "$ASK_VALUE" in
    ''|*[!0-9]*) warn "not a number; keeping $CBOX_NETACCESS_SOCKS_PORT" ;;
    *) CBOX_NETACCESS_SOCKS_PORT="$ASK_VALUE" ;;
  esac
}

step_hostroute() {
  echo "== section: hostroute =="
  local prev_mode="$CBOX_HOST_ROUTE_MODE"
  ask_choice "setup: hostroute mode" "$CBOX_HOST_ROUTE_MODE" off host-proxy
  CBOX_HOST_ROUTE_MODE="$ASK_VALUE"
  if [ "$SETUP_MODE" = update ] && [ "$CBOX_HOST_ROUTE_MODE" != off ]; then
    CBOX_HOST_ROUTE_APPLIED=1
  elif [ "$CBOX_HOST_ROUTE_MODE" != "$prev_mode" ]; then
    CBOX_HOST_ROUTE_APPLIED=0
  fi
  [ "$CBOX_HOST_ROUTE_MODE" != off ] || return 0
  note "host-route requires filtered egress (enforced in a later phase); the host proxy itself is user-managed"
  ask "setup: host proxy URL (e.g. http://host.docker.internal:3128): " "$CBOX_HOST_PROXY_URL"
  CBOX_HOST_PROXY_URL="$ASK_VALUE"
  ask_choice "setup: host proxy address mode" "$CBOX_HOST_PROXY_ADDR_MODE" host-gateway explicit
  CBOX_HOST_PROXY_ADDR_MODE="$ASK_VALUE"
}

step_ssh() {
  echo "== section: ssh =="
  ask_choice "setup: ssh mode" "$CBOX_SSH_MODE" none host-agent container-keys mixed
  CBOX_SSH_MODE="$ASK_VALUE"
  if [ "$CBOX_SSH_MODE" = none ]; then
    note "no ~/.ssh and no agent socket inside the container"
    return 0
  fi
  if [ "$CBOX_SSH_MODE" = host-agent ] || [ "$CBOX_SSH_MODE" = mixed ]; then
    if path_input "setup: host agent socket directory: " "$CBOX_SSH_AGENT_DIR" 0; then
      CBOX_SSH_AGENT_DIR="$PATH_VALUE"
    fi
    if [ ! -d "$CBOX_SSH_AGENT_DIR" ]; then
      note "warning: $CBOX_SSH_AGENT_DIR does not exist yet"
    fi
    note "host keys never enter the container; the agent only signs"
    note "start a dedicated agent with destination constraints, for example:"
    echo "  mkdir -p $CBOX_SSH_AGENT_DIR"
    echo "  ssh-agent -a $CBOX_SSH_AGENT_DIR/agent.sock"
    echo "  ssh-add -h github.com"
  fi
  if [ "$CBOX_SSH_MODE" = container-keys ] || [ "$CBOX_SSH_MODE" = mixed ]; then
    note "volume ${CBOX_NAME}-ssh holds keys generated inside the container; add the public key as a deploy key"
  fi
  if [ "$CBOX_SSH_MODE" = mixed ]; then
    note "the generated ssh config is written into the ssh volume once the container is up"
  fi
  if [ "$CBOX_EGRESS_MODE" != off ]; then
    note "egress is on: git ssh goes through the proxy to ssh.github.com:443; the filter gains ssh.github.com automatically"
  else
    note "egress is off: the generated ssh config is hygiene only; agent constraints remain the control"
  fi
}

step_bashrc() {
  echo "== section: bashrc =="
  if [ "$SEC_AUTO" = 1 ]; then
    note "auto: keeping CBOX_BASHRC=$CBOX_BASHRC"
  else
    ask_choice "setup: install shell functions (~/.bashrc-cbox + marker block in ~/.bashrc)" "$CBOX_BASHRC" 0 1
    CBOX_BASHRC="$ASK_VALUE"
  fi
  if [ "$CBOX_BASHRC" != 1 ]; then
    note "shell integration skipped; existing blocks stay untouched (uninstall removes the marker block)"
    return 0
  fi
  local stage old
  stage="$(mktemp -d)"
  gen_bashrc > "$stage/bashrc-cbox"
  staged_write "$HOME/.bashrc-cbox" "$stage/bashrc-cbox" 0644 || true
  if [ -f "$HOME/.bashrc" ]; then
    cp "$HOME/.bashrc" "$stage/bashrc"
  else
    : > "$stage/bashrc"
  fi
  merge_bashrc_block "$stage/bashrc"
  old="$(bashrc_old_lines "$stage/bashrc")"
  if [ -n "$old" ] && [ "$SEC_AUTO" != 1 ]; then
    note "old cbox shell block detected outside the marker block:"
    printf '%s\n' "$old" | sed 's/^/  /'
    if ask_yn "setup: comment those lines out with the prefix '$SUPERSEDED_PREFIX'? [y/N]" n; then
      bashrc_comment_old "$stage/bashrc"
    fi
  fi
  staged_write "$HOME/.bashrc" "$stage/bashrc" 0644 || true
  rm -rf "$stage"
  note "warning: the claude/codex functions shadow host binaries in new shells"
  note "the shell functions now route through '$INSTALL_DIR/cbox run' for lifecycle management; if ~/.bashrc-cbox was generated before wave-3 isolation, reload your shell after this run: source ~/.bashrc"
}

mcp_apply_selection() {
  local servers_file="$ETC_DIR/mcp/delegates.json"
  local expanded shim_mode="${CBOX_CODEX_PROGRESS_MODE:-off}"
  [ "${CBOX_CLAUDE_MODE:-mount}" = mount ] || shim_mode=off
  expanded="$(canonical_expand "$CBOX_MCP_SERVERS" "$(mcp_all_names)")"
  if [ "$CBOX_CLAUDE_MODE" = mount ]; then
    local target="$HOME/.claude.json" stage
    stage="$(mktemp -d)"
    merge_mcp_json "$target" "$servers_file" "$expanded" "$stage/claude.json" "$shim_mode" "$HOME"
    staged_write "$target" "$stage/claude.json" 0644 || true
    rm -rf "$stage"
  else
    local state="$GEN_DIR/state/claude.json" tmp
    if [ -f "$state" ]; then
      tmp="$(mktemp)"
      merge_mcp_json "$state" "$servers_file" "$expanded" "$tmp" "$shim_mode" "$HOME"
      mv "$tmp" "$state"
      note "updated $state"
    else
      note "generated/state/claude.json will be seeded with this selection at generation time"
    fi
  fi
}

step_mcp_servers() {
  echo "== section: mcp-servers =="
  local servers_file="$ETC_DIR/mcp/delegates.json"
  if [ ! -f "$servers_file" ]; then
    note "missing $servers_file; section skipped"
    return 0
  fi
  if ! container_target_ok; then
    return 0
  fi
  local all=() name i out=() expanded
  read -r -a all <<< "$(mcp_all_names)"
  expanded="$(canonical_expand "$CBOX_MCP_SERVERS" "${all[*]-}")"
  CB_ITEMS=("${all[@]}")
  CB_STATE=()
  CB_DISABLED=()
  CB_REASON=()
  for name in "${all[@]}"; do
    if [[ " $expanded " == *" $name "* ]]; then
      CB_STATE+=(y)
    else
      CB_STATE+=(n)
    fi
    CB_DISABLED+=(0)
    CB_REASON+=("")
  done
  note "select mcp servers available inside the container"
  checkbox_select
  for i in "${!CB_ITEMS[@]}"; do
    if [ "${CB_STATE[i]}" = y ]; then
      out+=("${CB_ITEMS[i]}")
    fi
  done
  CBOX_MCP_SERVERS="$(canonical_store "${out[*]-}" "${all[*]-}")"
  note "selected mcp servers: $CBOX_MCP_SERVERS"
  mcp_apply_selection
}

codex_progress_ensure_hooks_dep() {
  [ "$CBOX_CLAUDE_MODE" = mount ] || return 0
  [ -d "$ETC_DIR/hooks" ] || return 0
  [ -f "$ETC_DIR/mcp/codex_mcp_shim.py" ] || return 0
  container_target_ok || return 0
  gen_hooks_dir
  staged_install_files "$GEN_DIR/hooks" "$CBOX_CLAUDE_PATH/hooks" 0644 codex_mcp_shim.py conduct-kernel.txt codex_notify.py || true
}

step_codex_progress() {
  echo "== section: codex-progress =="
  note "the tier-injecting relay (codex_mcp_shim.py) is always on for codex-* mcp servers; this toggle only controls whether it also translates codex events into MCP progress notifications"
  local prev="$CBOX_CODEX_PROGRESS_MODE"
  ask_choice "setup: codex progress relay" "$CBOX_CODEX_PROGRESS_MODE" off shim
  CBOX_CODEX_PROGRESS_MODE="$ASK_VALUE"
  if [ "$CBOX_CODEX_PROGRESS_MODE" = shim ] && [ "$CBOX_CLAUDE_MODE" != mount ]; then
    warn "codex progress relay needs claude mount mode (the shim lives in ~/.claude/hooks); keeping off"
    CBOX_CODEX_PROGRESS_MODE=off
  fi
  section_dep_gate codex-progress
  if [ "$DEP_ACTION" = dictate ]; then
    note "hooks dependency: $DEP_REASON"
  fi
  codex_progress_ensure_hooks_dep
  [ "$CBOX_CODEX_PROGRESS_MODE" != "$prev" ] || return 0
  if container_target_ok; then
    mcp_apply_selection
  fi
  note "host claude picks the change up on next start; the container needs re-bless + restart (~/.claude.json bind pins the old inode)"
}

step_local_model() {
  echo "== section: local-model =="
  note "off by default; a text-only MCP delegate (local-qwen) backed by an OpenAI-compatible endpoint such as ollama - see etc/docs/LOCAL_MODEL_RUNBOOK.md"
  note "ollama runs outside cbox; local-qwen is absent from the rendered mcp server list unless CBOX_LOCAL_MODEL_URL is set, regardless of CBOX_MCP_SERVERS"
  local prev_on="$CBOX_LOCAL_MODEL" prev_url="$CBOX_LOCAL_MODEL_URL" prev_name="$CBOX_LOCAL_MODEL_NAME"
  ask_choice "setup: enable the local model delegate" "$CBOX_LOCAL_MODEL" off on
  CBOX_LOCAL_MODEL="$ASK_VALUE"
  if [ "$CBOX_LOCAL_MODEL" = on ]; then
    ask "setup: local model endpoint url (OpenAI-compatible, e.g. http://ollama:11434 or http://host-gateway:11434)" "$CBOX_LOCAL_MODEL_URL"
    CBOX_LOCAL_MODEL_URL="$ASK_VALUE"
    ask "setup: local model name (as known to the endpoint, e.g. qwen2.5:7b)" "$CBOX_LOCAL_MODEL_NAME"
    CBOX_LOCAL_MODEL_NAME="$ASK_VALUE"
    if [ -z "$CBOX_LOCAL_MODEL_URL" ] || [ -z "$CBOX_LOCAL_MODEL_NAME" ]; then
      warn "local model url or name left empty - keeping the delegate off (CBOX_LOCAL_MODEL=off) until both are set"
      CBOX_LOCAL_MODEL=off
    fi
  else
    CBOX_LOCAL_MODEL_URL=""
    CBOX_LOCAL_MODEL_NAME=""
  fi
  export CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME
  if [ "$CBOX_LOCAL_MODEL" = "$prev_on" ] && [ "$CBOX_LOCAL_MODEL_URL" = "$prev_url" ] \
      && [ "$CBOX_LOCAL_MODEL_NAME" = "$prev_name" ]; then
    return 0
  fi
  if container_target_ok; then
    mcp_apply_selection
  fi
  note "host claude/codex pick the change up on next start; the container needs re-bless + restart"
}

autoresume_ensure_hooks() {
  [ "$CBOX_LIMIT_AUTORESUME" = on ] || return 0
  [ "$CBOX_CLAUDE_MODE" = mount ] || return 0
  [ -d "$ETC_DIR/hooks" ] || return 0
  container_target_ok || return 0
  gen_hooks_dir
  staged_install_files "$GEN_DIR/hooks" "$CBOX_CLAUDE_PATH/hooks" 0644 session_scope_farm.py limit_watchdog.py session_pane_map.py || true
}

step_autoresume() {
  echo "== section: autoresume =="
  local prev="$CBOX_LIMIT_AUTORESUME"
  ask_choice "setup: session-limit auto-resume (tmux-wrapped sessions, watchdog continues them after the limit resets)" "$CBOX_LIMIT_AUTORESUME" off on
  CBOX_LIMIT_AUTORESUME="$ASK_VALUE"
  if [ "$CBOX_LIMIT_AUTORESUME" = on ] && [ "$CBOX_CLAUDE_MODE" != mount ]; then
    warn "session-limit auto-resume needs claude mount mode (watchdog lives in ~/.claude/hooks); keeping off"
    CBOX_LIMIT_AUTORESUME=off
  fi
  [ "$CBOX_LIMIT_AUTORESUME" != "$prev" ] || return 0
  autoresume_ensure_hooks
  note "applies on container recreate; the image rebuild (adds tmux) happens automatically on the next run"
}

agents_install() {
  local expanded
  expanded="$(canonical_expand "$CBOX_AGENTS" "$(agent_all_names)")"
  if [ -z "$expanded" ]; then
    note "no agents selected; nothing installed"
    return 0
  fi
  local files=() name f
  read -r -a name <<< "$expanded"
  for f in "${name[@]}"; do
    files+=("$f.md")
  done
  if [ "$CBOX_CLAUDE_MODE" = mount ]; then
    staged_install_files "$ETC_DIR/agents" "$CBOX_CLAUDE_PATH/agents" 0644 "${files[@]}" || true
  else
    mkdir -p "$GEN_DIR/claude/agents"
    for f in "${files[@]}"; do
      _cbox_write_local "$GEN_DIR/claude/agents/$f" < "$ETC_DIR/agents/$f"
    done
    note "agents written into $GEN_DIR/claude/agents (served read-only via bind mount; restart to pick up)"
  fi
}

step_agents() {
  echo "== section: agents =="
  if [ ! -d "$ETC_DIR/agents" ]; then
    note "missing $ETC_DIR/agents; section skipped"
    return 0
  fi
  if ! container_target_ok; then
    return 0
  fi
  local all=() name i out=() dis reason notice=0 expanded mcp_expanded
  read -r -a all <<< "$(agent_all_names)"
  expanded="$(canonical_expand "$CBOX_AGENTS" "${all[*]-}")"
  mcp_expanded="$(canonical_expand "$CBOX_MCP_SERVERS" "$(mcp_all_names)")"
  CB_ITEMS=("${all[@]}")
  CB_STATE=()
  CB_DISABLED=()
  CB_REASON=()
  for name in "${all[@]}"; do
    dis=0
    reason=""
    case "$name" in
      codex-*)
        if [[ " $mcp_expanded " != *" $name "* ]]; then
          dis=1
          reason="mcp server $name not selected"
        fi
        ;;
    esac
    if [ "$dis" = 1 ]; then
      CB_STATE+=(n)
    elif [[ " $expanded " == *" $name "* ]]; then
      CB_STATE+=(y)
    else
      CB_STATE+=(n)
    fi
    CB_DISABLED+=("$dis")
    CB_REASON+=("$reason")
  done
  for i in "${!CB_ITEMS[@]}"; do
    if [ "${CB_DISABLED[i]}" = 1 ]; then
      note "agent ${CB_ITEMS[i]} disabled: ${CB_REASON[i]}"
      notice=1
    fi
  done
  if [ "$notice" = 1 ]; then
    note "agents named codex-* delegate to the same-named mcp server; select the server in mcp-servers to enable them"
  fi
  note "select agents to install"
  checkbox_select
  for i in "${!CB_ITEMS[@]}"; do
    if [ "${CB_STATE[i]}" = y ]; then
      out+=("${CB_ITEMS[i]}")
    fi
  done
  CBOX_AGENTS="$(canonical_store "${out[*]-}" "${all[*]-}")"
  note "selected agents: $CBOX_AGENTS"
  agents_install
}

codex_mcp_block_file() {
  local blockfile="$1"
  {
    printf '%s\n' "$CODEX_MCP_MARK_START"
    printf '[mcp_servers.claude]\n'
    printf 'command = "python3"\n'
    printf 'args = [%s]\n' "$(_cbox_toml_string "$HOME/.claude/hooks/ask_claude_mcp.py")"
    printf 'startup_timeout_sec = 30\n'
    printf 'tool_timeout_sec = 600\n'
    printf '%s\n' "$CODEX_MCP_MARK_END"
  } > "$blockfile"
}

codex_mcp_strip_marked() {
  local file="$1" s="$2" e="$3" tmp
  grep -qF "$s" "$file" || return 0
  tmp="$(mktemp)"
  awk -v s="$s" -v e="$e" '
    index($0, s) { skip++; next }
    index($0, e) { if (skip > 0) skip--; next }
    skip { next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

codex_mcp_merge_block() {
  local file="$1" block tmp
  codex_mcp_strip_marked "$file" "$CODEX_MCP_LEGACY_MARK_START" "$CODEX_MCP_LEGACY_MARK_END"
  block="$(mktemp)"
  codex_mcp_block_file "$block"
  tmp="$(mktemp)"
  if grep -qF "$CODEX_MCP_MARK_START" "$file" && grep -qF "$CODEX_MCP_MARK_END" "$file"; then
    awk -v s="$CODEX_MCP_MARK_START" -v e="$CODEX_MCP_MARK_END" -v bf="$block" '
      index($0, s) { skip = 1; while ((getline line < bf) > 0) print line; close(bf); next }
      index($0, e) { skip = 0; next }
      skip { next }
      { print }
    ' "$file" > "$tmp"
  else
    if grep -qE '^[[:space:]]*\[mcp_servers\.claude\]' "$file" 2>/dev/null; then
      warn "existing [mcp_servers.claude] without cbox markers in $file - leaving it untouched; remove or rename that block and re-run to let cbox manage it"
      rm -f "$block" "$tmp"
      return 0
    fi
    cp "$file" "$tmp"
    if [ -s "$tmp" ]; then
      printf '\n' >> "$tmp"
    fi
    cat "$block" >> "$tmp"
  fi
  mv "$tmp" "$file"
  rm -f "$block"
}

codex_mcp_strip_block() {
  local file="$1"
  codex_mcp_strip_marked "$file" "$CODEX_MCP_LEGACY_MARK_START" "$CODEX_MCP_LEGACY_MARK_END"
  codex_mcp_strip_marked "$file" "$CODEX_MCP_MARK_START" "$CODEX_MCP_MARK_END"
}

codex_mcp_render() {
  codex_mcp_strip_block "$1"
}

codex_mcp_apply() {
  local stage work target
  stage="$(mktemp -d)"
  work="$stage/config.toml"
  if [ -f /.dockerenv ]; then
    target="$HOME/.codex/config.toml"
    mkdir -p "$HOME/.codex"
    if [ -f "$target" ]; then
      cp "$target" "$work"
    else
      : > "$work"
    fi
    codex_mcp_render "$work"
    if [ -f "$target" ] && cmp -s "$work" "$target"; then
      note "$target unchanged"
    else
      _cbox_write_local "$target" < "$work"
      note "updated $target - [mcp_servers.claude] now lives in the cbox-container profile only; raw codex without --profile cbox-container loses ask-claude"
    fi
  elif [ "$CBOX_CODEX_MODE" = mount ]; then
    target="$CBOX_CODEX_PATH/config.toml"
    if [ -f "$target" ]; then
      cp "$target" "$work"
    else
      : > "$work"
    fi
    codex_mcp_render "$work"
    staged_write "$target" "$work" 0644 || true
  elif container_running; then
    docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" /entrypoint.sh sh -c 'cat "$HOME/.codex/config.toml" 2>/dev/null || true' > "$work"
    cp "$work" "$stage/config.toml.orig"
    codex_mcp_render "$work"
    if cmp -s "$work" "$stage/config.toml.orig"; then
      note "codex config.toml unchanged in the codex volume"
    else
      docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" /entrypoint.sh sh -c 'mkdir -p "$HOME/.codex" && cat > "$HOME/.codex/config.toml.cbox" && mv "$HOME/.codex/config.toml.cbox" "$HOME/.codex/config.toml"' < "$work"
      note "codex config.toml updated in the codex volume - [mcp_servers.claude] now lives in the cbox-container profile only"
    fi
  else
    note "container not running; codex volume config not touched - start it and re-run ./setup.sh update codex-mcp"
  fi
  rm -rf "$stage"
}

codex_mcp_ensure_hooks_dep() {
  [ "$CBOX_CODEX_MCP" = 1 ] || return 0
  [ "$CBOX_CLAUDE_MODE" = mount ] || return 0
  [ -d "$ETC_DIR/hooks" ] || return 0
  container_target_ok || return 0
  gen_hooks_dir
  staged_install_files "$GEN_DIR/hooks" "$CBOX_CLAUDE_PATH/hooks" 0644 ask_claude_mcp.py codex_notify.py codex_bump_probe.sh || true
}

codex_profile_precreate_host_files() {
  [ "$CBOX_CODEX_MODE" = mount ] || return 0
  mkdir -p "$CBOX_CODEX_PATH"
  [ -e "$CBOX_CODEX_PATH/AGENTS.override.md" ] || : > "$CBOX_CODEX_PATH/AGENTS.override.md"
  [ -e "$CBOX_CODEX_PATH/cbox-container.config.toml" ] || : > "$CBOX_CODEX_PATH/cbox-container.config.toml"
  [ -e "$CBOX_CODEX_PATH/cbox-host.config.toml" ] || : > "$CBOX_CODEX_PATH/cbox-host.config.toml"
  [ -e "$CBOX_CODEX_PATH/config.toml" ] || : > "$CBOX_CODEX_PATH/config.toml"
  [ -e "$CBOX_CODEX_PATH/AGENTS.md" ] || : > "$CBOX_CODEX_PATH/AGENTS.md"
}

codex_host_profile_render() {
  local outdir="$1" mode="${2:-global}" root="${3:-}" stage
  stage="$(mktemp -d)"
  gen_codex_profile_into "$stage" "$mode" "$root"
  sed -e 's/^approval_policy = "never"$/approval_policy = "on-request"/' \
      -e 's/^sandbox_mode = "danger-full-access"$/sandbox_mode = "workspace-write"/' \
      "$stage/cbox-container.config.toml" > "$stage/cbox-host.config.toml"
  mkdir -p "$outdir"
  mv "$stage/cbox-host.config.toml" "$outdir/cbox-host.config.toml"
  rm -rf "$stage"
}

codex_profile_apply_host() {
  [ "$CBOX_CODEX_MODE" = mount ] || return 0
  container_target_ok || return 0
  codex_profile_precreate_host_files
  local stage
  stage="$(mktemp -d)"
  codex_host_profile_render "$stage" global ""
  staged_write "$CBOX_CODEX_PATH/cbox-host.config.toml" "$stage/cbox-host.config.toml" 0644 || true
  rm -rf "$stage"
  if [ -f "$GEN_DIR/codex/hooks.json" ]; then
    staged_write "$CBOX_CODEX_PATH/hooks.json" "$GEN_DIR/codex/hooks.json" 0644 || true
    note "host codex does not run with --dangerously-bypass-hook-trust (unlike the container); a bare host-side 'codex' or the first 'cbox ai ... codex --host' run skips continuity_session_start.py until you run codex's '/hooks' command once to trust it"
  fi
}


continuity_ensure_hooks_dep() {
  [ "$CBOX_HISTORY" = 1 ] || return 0
  [ "$CBOX_CLAUDE_MODE" = mount ] || return 0
  [ -d "$ETC_DIR/hooks" ] || return 0
  container_target_ok || return 0
  gen_hooks_dir
  staged_install_files "$GEN_DIR/hooks" "$CBOX_CLAUDE_PATH/hooks" 0644 continuity_commit_log.py continuity_ledger_sweep.py continuity_session_digest.py continuity_session_start.py session-core.txt || true
}

step_codex_mcp() {
  echo "== section: codex-mcp =="
  ask_choice "setup: register claude as a codex mcp tool (reverse orchestration via ask-claude)" "$CBOX_CODEX_MCP" 0 1
  CBOX_CODEX_MCP="$ASK_VALUE"
  if [ "$CBOX_CODEX_MCP" = 1 ]; then
    note "codex gains an ask-claude tool backed by claude print mode; every delegation spends both subscriptions - codex must propose and ask first"
    note "recursion is depth-limited: a claude spawned via ask-claude refuses further hops and has the codex relays disabled"
    section_dep_gate codex-mcp
    if [ "$DEP_ACTION" = dictate ]; then
      note "hooks dependency: $DEP_REASON"
      codex_mcp_ensure_hooks_dep
    fi
  fi
  codex_mcp_apply
}

claude_md_policy_files() {
  printf '%s\n' "CLAUDE-CODING-POLICY.md" "CLAUDE-COMMUNICATION-POLICY.md" "CLAUDE-NAMING-POLICY.md" "CLAUDE-SUBAGENT-ROUTING-POLICY.md" "CLAUDE-CBOX-ENVIRONMENT-POLICY.md"
  if [ "$CBOX_HISTORY" = 1 ]; then
    printf '%s\n' "CLAUDE-DURABLE-CONTINUITY.md"
  fi
}

claude_md_template_files() {
  printf '%s\n' "LEDGER_TEMPLATE.md" "PROGRESS_TEMPLATE.md"
  if [ "$CBOX_DIARY" = 1 ]; then
    printf '%s\n' "DIARY_TEMPLATE.md"
  fi
  if [ "$CBOX_GIT" = 1 ]; then
    printf '%s\n' "CHANGELOG_TEMPLATE.md"
  fi
  if [ "$CBOX_OPEN_QUESTIONS" = 1 ]; then
    printf '%s\n' "OPEN_QUESTIONS_TEMPLATE.md"
  fi
}

apply_name_substitution() {
  local src="$1" dst="$2" u name
  u="$(id -un)"
  name="${u^}"
  name="${name//\\/\\\\}"
  name="${name//\//\\/}"
  name="${name//&/\\&}"
  sed "s/{NAME}/$name/g" "$src" > "$dst"
}

stage_policies_and_templates() {
  local stage="$1" f
  mkdir -p "$stage/policies" "$stage/templates"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$ETC_DIR/claude/policies/$f" ] || die "missing policy source $ETC_DIR/claude/policies/$f"
    if [ "$f" = "CLAUDE-NAMING-POLICY.md" ]; then
      apply_name_substitution "$ETC_DIR/claude/policies/$f" "$stage/policies/$f"
    else
      cp "$ETC_DIR/claude/policies/$f" "$stage/policies/$f"
    fi
  done < <(claude_md_policy_files)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$ETC_DIR/claude/templates/$f" ] || die "missing template source $ETC_DIR/claude/templates/$f"
    cp "$ETC_DIR/claude/templates/$f" "$stage/templates/$f"
  done < <(claude_md_template_files)
}

claude_md_kernel_block_file() {
  local out="$1"
  local kernel_src="$ETC_DIR/hooks/conduct-kernel.txt"
  [ -f "$kernel_src" ] || die "missing conduct-kernel source $kernel_src"
  local rendered digest
  rendered="$(mktemp)"
  apply_name_substitution "$kernel_src" "$rendered"
  digest="$(sha256sum "$kernel_src" | awk '{print $1}')"
  digest="${digest:0:16}"
  {
    printf '%s\n' "$CLAUDE_MD_KERNEL_MARK_START"
    cat "$rendered"
    printf 'Digest: %s\n' "$digest"
    printf '%s\n' "$CLAUDE_MD_KERNEL_MARK_END"
  } > "$out"
  rm -f "$rendered"
}

claude_md_merge_kernel_block() {
  local file="$1" block tmp
  block="$(mktemp)"
  claude_md_kernel_block_file "$block"
  tmp="$(mktemp)"
  if grep -qF "$CLAUDE_MD_KERNEL_MARK_START" "$file" && grep -qF "$CLAUDE_MD_KERNEL_MARK_END" "$file"; then
    awk -v s="$CLAUDE_MD_KERNEL_MARK_START" -v e="$CLAUDE_MD_KERNEL_MARK_END" -v bf="$block" '
      index($0, s) { skip = 1; while ((getline line < bf) > 0) print line; close(bf); next }
      index($0, e) { skip = 0; next }
      skip { next }
      { print }
    ' "$file" > "$tmp"
  else
    cp "$file" "$tmp"
    if [ -s "$tmp" ]; then
      printf '\n' >> "$tmp"
    fi
    cat "$block" >> "$tmp"
  fi
  mv "$tmp" "$file"
  rm -f "$block"
}

step_claude_md() {
  echo "== section: claude-md =="
  if [ "$CBOX_HISTORY" = 0 ]; then
    note "history disabled (CBOX_HISTORY=0); claude-md deployment (policies/templates/CLAUDE.md) skipped"
    return 0
  fi
  local src="$ETC_DIR/claude/CLAUDE.md"
  if [ ! -f "$src" ] || [ ! -d "$ETC_DIR/claude/policies" ] || [ ! -d "$ETC_DIR/claude/templates" ]; then
    note "missing $ETC_DIR/claude/{CLAUDE.md,policies,templates}; section skipped"
    return 0
  fi
  if ! container_target_ok; then
    return 0
  fi
  local stage
  stage="$(mktemp -d)"
  stage_policies_and_templates "$stage"
  apply_name_substitution "$src" "$stage/CLAUDE.md"
  local -a policy_files=() template_files=()
  mapfile -t policy_files < <(claude_md_policy_files)
  mapfile -t template_files < <(claude_md_template_files)
  if [ "$CBOX_CLAUDE_MODE" = mount ]; then
    staged_install_files "$stage/policies" "$CBOX_CLAUDE_PATH/policies" 0644 "${policy_files[@]}" || true
    staged_install_files "$stage/templates" "$CBOX_CLAUDE_PATH/templates" 0644 "${template_files[@]}" || true
    local target="$CBOX_CLAUDE_PATH/CLAUDE.md" work
    work="$stage/target-claude-md"
    if [ -f "$target" ]; then
      cp "$target" "$work"
    else
      cp "$stage/CLAUDE.md" "$work"
    fi
    claude_md_merge_kernel_block "$work"
    staged_write "$target" "$work" 0644 || true
  else
    mkdir -p "$GEN_DIR/claude/policies" "$GEN_DIR/claude/templates"
    local f
    for f in "${policy_files[@]}"; do
      _cbox_write_local "$GEN_DIR/claude/policies/$f" < "$stage/policies/$f"
    done
    for f in "${template_files[@]}"; do
      _cbox_write_local "$GEN_DIR/claude/templates/$f" < "$stage/templates/$f"
    done
    local work="$GEN_DIR/claude/CLAUDE.md"
    if [ ! -f "$work" ]; then
      cp "$stage/CLAUDE.md" "$work"
    fi
    claude_md_merge_kernel_block "$work"
    note "wrote $GEN_DIR/claude/{policies,templates,CLAUDE.md} (served read-only via bind mounts; restart to pick up)"
  fi
  rm -rf "$stage"
}

step_settings() {
  echo "== section: settings =="
  local merge="$ETC_DIR/claude/settings.merge.json"
  if [ ! -f "$merge" ]; then
    note "missing $merge; section skipped"
    return 0
  fi
  if ! container_target_ok; then
    return 0
  fi
  local stage
  stage="$(mktemp -d)"
  if [ "$CBOX_CLAUDE_MODE" = mount ]; then
    local target="$CBOX_CLAUDE_PATH/settings.json"
    merge_settings_json "$target" "$merge" "$HOME" "$stage/settings.json"
    staged_write "$target" "$stage/settings.json" 0644 || true
  else
    mkdir -p "$GEN_DIR"
    merge_settings_json "$GEN_DIR/settings.json" "$merge" "$HOME" "$stage/settings.json"
    mv "$stage/settings.json" "$GEN_DIR/settings.json"
    note "wrote $GEN_DIR/settings.json"
  fi
  rm -rf "$stage"
}

step_hooks() {
  echo "== section: hooks =="
  if [ ! -d "$ETC_DIR/hooks" ]; then
    note "missing $ETC_DIR/hooks; section skipped"
    return 0
  fi
  if ! container_target_ok; then
    return 0
  fi
  gen_hooks_dir
  if [ "$CBOX_CLAUDE_MODE" = mount ]; then
    staged_install_files "$GEN_DIR/hooks" "$CBOX_CLAUDE_PATH/hooks" 0644 codex_mode_guard.py agent_label_guard.py code_hygiene_guard.py commit_guard.py orchestrator-global.txt conduct-kernel.txt session-core.txt codex_scope.container.json ask_claude_mcp.py codex_notify.py codex_bump_probe.sh codex_mcp_shim.py continuity_commit_log.py continuity_ledger_sweep.py continuity_session_digest.py continuity_session_start.py session_scope_farm.py limit_watchdog.py session_pane_map.py || true
  else
    note "volume mode: hooks are served read-only from $GEN_DIR/hooks (synced)"
  fi
  codex_profile_apply_host
}

step_continuity() {
  echo "== section: continuity =="
  if [ "$SEC_AUTO" = 1 ]; then
    note "auto: keeping CBOX_HISTORY=$CBOX_HISTORY CBOX_GIT=$CBOX_GIT CBOX_DIARY=$CBOX_DIARY CBOX_OPEN_QUESTIONS=$CBOX_OPEN_QUESTIONS"
  else
    ask_choice "setup: history y/n (track project state in ./.cbox/ LEDGER + daily PROGRESS - mandatory pair)" "$([ "$CBOX_HISTORY" = 1 ] && echo y || echo n)" y n
    case "$ASK_VALUE" in
      y) CBOX_HISTORY=1 ;;
      n) CBOX_HISTORY=0 ;;
    esac
  fi
  if [ "$CBOX_HISTORY" = 0 ]; then
    note "history disabled; diary/open-questions/git questions skipped (durable-continuity system disabled)"
    CBOX_GIT=0
    CBOX_DIARY=0
    CBOX_OPEN_QUESTIONS=0
    if [ "$SEC_AUTO" != 1 ]; then
      note "switches saved; run ./setup.sh update claude-md and ./setup.sh update agents to deploy the change"
    fi
    return 0
  fi
  if [ "$SEC_AUTO" != 1 ]; then
    ask_choice "setup: git y/n (project uses git - enables CHANGELOG)" "$([ "$CBOX_GIT" = 1 ] && echo y || echo n)" y n
    case "$ASK_VALUE" in
      y) CBOX_GIT=1 ;;
      n) CBOX_GIT=0 ;;
    esac
    ask_choice "setup: diary y/n" "$([ "$CBOX_DIARY" = 1 ] && echo y || echo n)" y n
    case "$ASK_VALUE" in
      y) CBOX_DIARY=1 ;;
      n) CBOX_DIARY=0 ;;
    esac
    ask_choice "setup: open-questions y/n" "$([ "$CBOX_OPEN_QUESTIONS" = 1 ] && echo y || echo n)" y n
    case "$ASK_VALUE" in
      y) CBOX_OPEN_QUESTIONS=1 ;;
      n) CBOX_OPEN_QUESTIONS=0 ;;
    esac
    ask_choice "setup: session context profile (full = complete driver core + progress history each startup; light = conduct kernel + one-writer + ledger RESUME + digest only, no orchestration detail, no progress)" "$CBOX_CONTEXT_PROFILE" full light
    CBOX_CONTEXT_PROFILE="$ASK_VALUE"
  fi
  section_dep_gate continuity
  if [ "$DEP_ACTION" = dictate ]; then
    note "continuity dependency: $DEP_REASON"
    continuity_ensure_hooks_dep
  fi
  if [ "$SEC_AUTO" != 1 ]; then
    note "switches saved; run ./setup.sh update claude-md and ./setup.sh update agents to deploy the change"
  fi
}

step_git_identity() {
  echo "== section: git-identity =="
  if [ "$SEC_AUTO" = 1 ]; then
    note "auto: keeping CBOX_GITCONFIG=$CBOX_GITCONFIG"
  else
    ask_choice "setup: mount host ~/.gitconfig read-only" "$CBOX_GITCONFIG" 0 1
    CBOX_GITCONFIG="$ASK_VALUE"
  fi
  if [ "$CBOX_GITCONFIG" = 1 ] && [ ! -f "$HOME/.gitconfig" ]; then
    note "warning: $HOME/.gitconfig does not exist; the mount is emitted only when the file exists"
  fi
}

step_apt_extra() {
  echo "== section: apt-extra =="
  local ok pkgs=() p
  while :; do
    ask "setup: extra apt packages (space-separated, empty for none): " "$CBOX_APT_EXTRA"
    ok=1
    read -r -a pkgs <<< "$ASK_VALUE"
    for p in "${pkgs[@]}"; do
      case "$p" in
        *[!A-Za-z0-9.+-]*|[.+-]*)
          echo "setup: invalid package name: $p"
          ok=0
          break
          ;;
      esac
    done
    if [ "$ok" = 1 ]; then
      break
    fi
  done
  CBOX_APT_EXTRA="${pkgs[*]-}"
}

step_binaries() {
  echo "== section: binaries =="
  local ok
  while :; do
    ask "setup: claude version target (stable, latest, or x.y.z): " "$CBOX_CLAUDE_TARGET"
    CBOX_CLAUDE_TARGET="$ASK_VALUE"
    ok=1
    printf '%s' "$CBOX_CLAUDE_TARGET" | grep -Eq '^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$' || ok=0
    if [ "$ok" = 1 ]; then
      break
    fi
    echo "setup: invalid claude target: $CBOX_CLAUDE_TARGET (expected stable, latest, or x.y.z)"
  done
  while :; do
    ask "setup: codex version (latest or x.y.z): " "$CBOX_CODEX_VERSION"
    CBOX_CODEX_VERSION="$ASK_VALUE"
    ok=1
    printf '%s' "$CBOX_CODEX_VERSION" | grep -Eq '^(latest|[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?)$' || ok=0
    if [ "$ok" = 1 ]; then
      break
    fi
    echo "setup: invalid codex version: $CBOX_CODEX_VERSION (expected latest or x.y.z)"
  done
  ask "setup: codex install target override (empty = default for the version): " "$CBOX_CODEX_TARGET"
  CBOX_CODEX_TARGET="$ASK_VALUE"
  note "claude/codex binaries live in global external volumes (cbox-bins-claude, cbox-bins-codex), mounted read-only at runtime; installs run host-side via 'cbox reinstall-bins'"
  note "global scope: one shared install serves every project on this host, tracking one pin tuple per tool"
  note "pinned scope: this project gets its own cbox-bins-<tool>-<hash> pair, only needed if it must pin a claude/codex version that differs from the shared tuple"
  ask_choice "setup: binaries scope" "$CBOX_BINS_SCOPE" global pinned
  CBOX_BINS_SCOPE="$ASK_VALUE"
  if [ "$CBOX_BINS_SCOPE" = pinned ]; then
    note "pinned scope: a mismatched shared tuple would otherwise refuse to run; this project tracks its own volumes instead"
  fi
  note "the bins reinstall happens automatically on the next run via staleness detection (cbox reinstall-bins --if-stale); use 'cbox reinstall-bins' to force it now"
}

step_restart_policy() {
  echo "== section: restart-policy =="
  section_dep_gate restart-policy
  if [ "$DEP_ACTION" = disable ]; then
    note "restart-policy skipped: $DEP_REASON"
    CBOX_RESTART_POLICY=no
    return 0
  fi
  if [ "$SEC_AUTO" = 1 ]; then
    note "auto: keeping CBOX_RESTART_POLICY=$CBOX_RESTART_POLICY"
  else
    ask_choice "setup: container restart policy" "$CBOX_RESTART_POLICY" no unless-stopped
    CBOX_RESTART_POLICY="$ASK_VALUE"
  fi
}

backup_one_dir() {
  local mode="$1" path="$2" choice="$3"
  [ "$mode" = mount ] || return 0
  [ -d "$path" ] || return 0
  case "$choice" in
    y)
      cp -a "$path" "$path.backup-$RUN_TS"
      note "backup: $path -> $path.backup-$RUN_TS"
      ;;
    c)
      tar czf "$path.backup-$RUN_TS.tar.gz" -C "$(dirname "$path")" "$(basename "$path")"
      note "backup: $path -> $path.backup-$RUN_TS.tar.gz"
      ;;
    *)
      :
      ;;
  esac
}

run_backups() {
  backup_one_dir "$CBOX_CLAUDE_MODE" "$CBOX_CLAUDE_PATH" "$CBOX_CLAUDE_BACKUP"
  backup_one_dir "$CBOX_CODEX_MODE" "$CBOX_CODEX_PATH" "$CBOX_CODEX_BACKUP"
}

smoke_test() {
  note "smoke test: claude and codex inside the container (binaries are installed host-side into shared volumes before this point; first boot no longer downloads)"
  docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" /entrypoint.sh claude --version
  docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" /entrypoint.sh codex --version
}

login_guidance() {
  if [ "$CBOX_CLAUDE_MODE" != volume ] && [ "$CBOX_CODEX_MODE" != volume ]; then
    return 0
  fi
  note "login required inside the container (credentials live in volumes):"
  echo "  ./cbox shell"
  echo "    claude"
  echo "      complete the OAuth flow in your host browser"
  echo "    codex login --device-auth"
  read -r -p "setup: press Enter once both logins are done "
}

ssh_mixed_sync() {
  [ "$CBOX_SSH_MODE" = mixed ] || return 0
  [ -f "$GEN_DIR/ssh/config" ] || return 0
  if container_running; then
    docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" /entrypoint.sh sh -c 'mkdir -p "$HOME/.ssh" && cat > "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"' < "$GEN_DIR/ssh/config"
    note "ssh config written into the ssh volume"
  else
    note "container not running; ssh config for mixed mode not synced (re-run: ./setup.sh update ssh)"
  fi
}

egress_lockdown() {
  [ "$CBOX_EGRESS_MODE" != off ] || return 0
  CBOX_EGRESS_APPLIED=1
  conf_save
  regen_all
  docker compose -f "$COMPOSE_FILE" down --remove-orphans
  docker compose -f "$COMPOSE_FILE" up -d
  note "egress lockdown applied ($CBOX_EGRESS_MODE)"
}

print_backup_cmds() {
  local mode="$1" path="$2" choice="$3"
  [ "$mode" = mount ] || return 0
  case "$choice" in
    y)
      echo "  cp -a $path $path.backup-\$(date +%Y%m%d-%H%M%S)"
      ;;
    c)
      echo "  tar czf $path.backup-\$(date +%Y%m%d-%H%M%S).tar.gz -C $(dirname "$path") $(basename "$path")"
      ;;
    *)
      :
      ;;
  esac
}

print_host_sequence() {
  note "docker cli is not available here; run this sequence on the host from $INSTALL_DIR:"
  echo "  docker compose -f docker-compose.yml build"
  print_backup_cmds "$CBOX_CLAUDE_MODE" "$CBOX_CLAUDE_PATH" "$CBOX_CLAUDE_BACKUP"
  print_backup_cmds "$CBOX_CODEX_MODE" "$CBOX_CODEX_PATH" "$CBOX_CODEX_BACKUP"
  echo "  ./cbox reinstall-bins --if-stale"
  echo "  CBOX_NO_EXEC=1 ./cbox up"
  echo "  docker compose -f docker-compose.yml exec -T cbox /entrypoint.sh claude --version"
  echo "  docker compose -f docker-compose.yml exec -T cbox /entrypoint.sh codex --version"
  if [ "$CBOX_CLAUDE_MODE" = volume ] || [ "$CBOX_CODEX_MODE" = volume ]; then
    echo "  ./cbox shell"
    echo "    claude"
    echo "    codex login --device-auth"
  fi
  if [ "$CBOX_EGRESS_MODE" != off ] && [ "$CBOX_EGRESS_APPLIED" = 0 ]; then
    echo "  ./setup.sh update egress"
  fi
  if [ "$CBOX_CODEX_MCP" = 1 ] && [ "$CBOX_CODEX_MODE" = volume ]; then
    echo "  ./setup.sh update codex-mcp"
  fi
  echo "  ./cbox verify"
}

apply_change() {
  local section="$1" action
  action="$(apply_action_for "$section")"
  note "apply action for $section: $action"
  case "$action" in
    none)
      note "no container action needed"
      return 0
      ;;
    shell)
      note "reload your shell: source ~/.bashrc"
      return 0
      ;;
  esac
  if ! have_docker; then
    note "docker cli is not available; run from $INSTALL_DIR:"
    case "$action" in
      recreate) echo "  docker compose -f docker-compose.yml up -d" ;;
      restart) echo "  docker compose -f docker-compose.yml down && docker compose -f docker-compose.yml up -d" ;;
      topology) echo "  docker compose -f docker-compose.yml down --remove-orphans && docker compose -f docker-compose.yml up -d" ;;
      rebuild) echo "  docker compose -f docker-compose.yml build && docker compose -f docker-compose.yml up -d" ;;
    esac
    return 0
  fi
  if ! ask_yn "setup: execute '$action' now? [y/N]" n; then
    note "not applied; the next ./cbox up picks the changes up"
    return 0
  fi
  case "$action" in
    recreate)
      docker compose -f "$COMPOSE_FILE" up -d
      ;;
    restart)
      docker compose -f "$COMPOSE_FILE" down
      docker compose -f "$COMPOSE_FILE" up -d
      ;;
    topology)
      docker compose -f "$COMPOSE_FILE" down --remove-orphans
      docker compose -f "$COMPOSE_FILE" up -d
      ;;
    rebuild)
      docker compose -f "$COMPOSE_FILE" build
      docker compose -f "$COMPOSE_FILE" up -d
      ;;
  esac
  if [ "$section" = ssh ]; then
    ssh_mixed_sync
  fi
  note "applied"
}

isolated_next_steps() {
  local root="$1"
  note "isolated mode: cbox run derives one container per project from the workspace root (git toplevel or cwd)"
  note "the image builds automatically on the first cbox run (reused when inputs are unchanged)"
  if [ -n "$root" ]; then
    note "run from $root: cbox run claude   (or codex)"
  else
    note "cd into a project directory and run: cbox run claude   (or codex)"
  fi
}

run_phase_isolated() {
  local root=""
  note "isolated mode: the image is built and shared bins install on the first cbox run; no global container is created here"
  if ! { [ -t 0 ] && [ -t 1 ]; }; then
    isolated_next_steps ""
    return 0
  fi
  if ! root="$(_cbox_workspace_root 2>/dev/null)"; then
    warn "$PWD is not a usable project root (home, /, or a mount root); no per-project container is started"
    isolated_next_steps ""
    return 0
  fi
  if reserved_path_conflict "$root" >/dev/null 2>&1; then
    warn "$root looks like the cbox tool directory or a reserved path, not a project to sandbox"
    reserved_path_conflict "$root" | sed 's/^setup: /  /'
    note "cd into an actual project directory and run: cbox run claude"
    isolated_next_steps ""
    return 0
  fi
  note "no per-project container exists yet for this project"
  if ask_yn "setup: start this project's container now for $root (cbox run claude)? [y/N]" n; then
    note "starting cbox run claude for $root"
    exec "$INSTALL_DIR/cbox" run claude
  fi
  isolated_next_steps "$root"
  return 0
}

run_phase() {
  CBOX_EGRESS_APPLIED=0
  conf_save
  regen_all
  conf_load
  note "configuration saved to $CONF_FILE; artifacts generated"
  if ! have_docker; then
    print_host_sequence
    return 0
  fi
  docker compose -f "$COMPOSE_FILE" build
  run_backups
  if [ "${CBOX_MODE:-global}" = isolated ]; then
    run_phase_isolated
    return 0
  fi
  if [ ! -f /.dockerenv ] && have_docker; then
    "$INSTALL_DIR/cbox" reinstall-bins --if-stale
  fi
  CBOX_NO_EXEC=1 "$INSTALL_DIR/cbox" up
  smoke_test
  ssh_mixed_sync
  if [ "$CBOX_CODEX_MCP" = 1 ] && [ "$CBOX_CODEX_MODE" = volume ] && [ ! -f /.dockerenv ]; then
    codex_mcp_apply
  fi
  login_guidance
  egress_lockdown
  if [ "$CBOX_GPU" = 1 ]; then
    note "gpu is runtime opt-in: ./cbox up --gpu"
  fi
  "$INSTALL_DIR/cbox" verify
}

default_preset_set() {
  CBOX_CLAUDE_MODE=mount
  CBOX_CLAUDE_PATH="$HOME/.claude"
  CBOX_CLAUDE_BACKUP=n
  CBOX_CODEX_MODE=mount
  CBOX_CODEX_PATH="$HOME/.codex"
  CBOX_CODEX_BACKUP=n
  CBOX_WORKSPACES=""
  CBOX_WORKDIR="$HOME"
  CBOX_VENV_MODE=host
  CBOX_VENV_PATH="$HOME/.venvs"
  CBOX_GPU=0
  CBOX_EGRESS_MODE=off
  CBOX_NETACCESS_MODE=off
  CBOX_HOST_ROUTE_MODE=off
  CBOX_SSH_MODE=host-agent
  CBOX_SSH_AGENT_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/cbox-ssh"
  CBOX_BASHRC=1
  CBOX_MCP_SERVERS=all
  CBOX_AGENTS=all
  CBOX_CODEX_MCP=1
  CBOX_GITCONFIG=1
  CBOX_APT_EXTRA=""
  CBOX_CLAUDE_TARGET=stable
  CBOX_CODEX_VERSION=latest
  CBOX_CODEX_TARGET=""
  CBOX_BINS_SCOPE=global
  CBOX_RESTART_POLICY=no
  CBOX_MODE=isolated
  CBOX_HISTORY=1
  CBOX_GIT=1
  CBOX_DIARY=1
  CBOX_OPEN_QUESTIONS=1
  CBOX_CONTEXT_PROFILE=full
}

default_preset_validate_paths() {
  if [ ! -d "$CBOX_CLAUDE_PATH" ]; then
    note "default preset: $CBOX_CLAUDE_PATH does not exist; asking for the ~/.claude path"
    if path_input "setup: host directory for ~/.claude (empty = switch to volume): " "$CBOX_CLAUDE_PATH" 1; then
      CBOX_CLAUDE_PATH="$PATH_VALUE"
    else
      CBOX_CLAUDE_MODE=volume
      CBOX_CLAUDE_BACKUP=n
    fi
  fi
  if [ ! -d "$CBOX_CODEX_PATH" ]; then
    note "default preset: $CBOX_CODEX_PATH does not exist; asking for the ~/.codex path"
    if path_input "setup: host directory for ~/.codex (empty = switch to volume): " "$CBOX_CODEX_PATH" 1; then
      CBOX_CODEX_PATH="$PATH_VALUE"
    else
      CBOX_CODEX_MODE=volume
      CBOX_CODEX_BACKUP=n
    fi
  fi
  if [ ! -d "$CBOX_VENV_PATH" ]; then
    note "default preset: $CBOX_VENV_PATH does not exist; asking for the venv path"
    if path_input "setup: host venv path (mounted read-only at the same path): " "$CBOX_VENV_PATH" 1; then
      CBOX_VENV_PATH="$PATH_VALUE"
    else
      CBOX_VENV_MODE=none
    fi
  fi
  if [ "$CBOX_GITCONFIG" = 1 ] && [ ! -f "$HOME/.gitconfig" ]; then
    note "warning: $HOME/.gitconfig does not exist; the mount is emitted only when the file exists"
  fi
}

default_preset_summary() {
  note "default setup preset:"
  note "  claude: $CBOX_CLAUDE_MODE $CBOX_CLAUDE_PATH"
  note "  codex: $CBOX_CODEX_MODE $CBOX_CODEX_PATH"
  note "  workspaces: (none - isolated mode derives one container per project)"
  note "  venv: $CBOX_VENV_MODE $CBOX_VENV_PATH"
  note "  gpu: $CBOX_GPU  egress: $CBOX_EGRESS_MODE  ssh: $CBOX_SSH_MODE"
  note "  mcp-servers: $CBOX_MCP_SERVERS  agents: $CBOX_AGENTS  codex-mcp: $CBOX_CODEX_MCP"
  note "  claude target: $CBOX_CLAUDE_TARGET  codex version: $CBOX_CODEX_VERSION  bins scope: $CBOX_BINS_SCOPE"
  note "  container mode: $CBOX_MODE  restart policy: $CBOX_RESTART_POLICY"
  note "  history: $CBOX_HISTORY  git: $CBOX_GIT  diary: $CBOX_DIARY  open-questions: $CBOX_OPEN_QUESTIONS  context-profile: $CBOX_CONTEXT_PROFILE"
}

apply_default_setup() {
  header "Default setup" "" ""
  default_preset_set
  default_preset_validate_paths
  default_preset_summary
  if ! ask_yn "setup: apply this default setup? [y/N]" y; then
    note "default setup declined; switching to advanced (all sections)"
    return 1
  fi
  SEC_AUTO=1
  step_bashrc
  if container_target_ok; then
    mcp_apply_selection
    agents_install
  fi
  codex_mcp_ensure_hooks_dep
  codex_progress_ensure_hooks_dep
  codex_mcp_apply
  step_continuity
  step_claude_md
  step_settings
  step_hooks
  step_git_identity
  step_restart_policy
  SEC_AUTO=0
  return 0
}

run_wizard() {
  require_tty "the wizard"
  SETUP_MODE=wizard
  local fresh=0 is_default=0
  [ -f "$CONF_FILE" ] || fresh=1
  conf_load
  load_generators
  printf '%s%s%s\n' "$C_MUTE" "$HR_HEAVY" "$C_RESET"
  printf '%scbox setup%s  %sprofile '\''%s'\''%s\n' "$C_HEAD" "$C_RESET" "$C_DIM" "$CBOX_NAME" "$C_RESET"
  printf '%s%s%s\n' "$C_MUTE" "$HR_HEAVY" "$C_RESET"
  if [ "$fresh" = 1 ]; then
    note "default applies a ready-made preset with one confirm; advanced walks every section"
    ask_choice "setup: profile" default default advanced
    if [ "$ASK_VALUE" = default ] && apply_default_setup; then
      is_default=1
    fi
  fi
  if [ "$is_default" = 1 ]; then
    run_phase
    return 0
  fi
  WIZ_SECTIONS=("${SECTIONS[@]}")
  note "sections: ${WIZ_SECTIONS[*]}"
  local i=0 fn
  while [ "$i" -lt "${#WIZ_SECTIONS[@]}" ]; do
    fn="step_${WIZ_SECTIONS[i]//-/_}"
    header "$(section_title "${WIZ_SECTIONS[i]}")" "$((i+1))" "${#WIZ_SECTIONS[@]}"
    "$fn"
    nav_prompt
    case "$NAV" in
      next)
        i=$((i+1))
        ;;
      back)
        if [ "$i" -gt 0 ]; then
          i=$((i-1))
        fi
        ;;
      quit)
        conf_save
        note "saved to $CONF_FILE; run ./setup.sh again to continue"
        return 0
        ;;
      *)
        i=$((NAV-1))
        ;;
    esac
  done
  run_phase
}

run_update() {
  require_tty "update"
  SETUP_MODE=update
  [ -f "$CONF_FILE" ] || die "no $CONF_FILE; run ./setup.sh first"
  local section="$1" found=0 s
  for s in "${SECTIONS[@]}"; do
    if [ "$s" = "$section" ]; then
      found=1
    fi
  done
  [ "$found" = 1 ] || die "unknown section '$section'; valid: ${SECTIONS[*]}"
  conf_load
  load_generators
  header "$(section_title "$section")"
  "step_${section//-/_}"
  case "$section" in
    python)
      if ask_yn "setup: python changed; re-run the gpu section too? [y/N]" n; then
        step_gpu
      fi
      ;;
    mcp-servers)
      if ask_yn "setup: mcp servers changed; re-run the agents section too? [y/N]" n; then
        step_agents
      fi
      ;;
  esac
  conf_save
  regen_all
  conf_load
  if [ "$section" = workspaces ] && [ "$CBOX_CLAUDE_MODE" = mount ]; then
    staged_install_files "$GEN_DIR/hooks" "$CBOX_CLAUDE_PATH/hooks" 0644 codex_scope.container.json \
      || note "codex guard scope not synced; run ./setup.sh update hooks (or ./cbox install-hooks) before relying on the new workspace list"
  fi
  apply_change "$section"
}

run_list_steps() {
  local i
  for i in "${!SECTIONS[@]}"; do
    printf '%2d  %-16s apply: %s\n' "$((i+1))" "${SECTIONS[i]}" "$(apply_action_for "${SECTIONS[i]}")"
  done
}

run_config() {
  SETUP_MODE=config
  local file="$1" abs
  [ -f "$file" ] || die "config file not found: $file"
  abs="$(realpath -m "$file")"
  if [ "$abs" != "$CONF_FILE" ]; then
    cp "$abs" "$CONF_FILE"
  fi
  conf_load
  load_generators
  note "non-interactive install for profile '$CBOX_NAME'"
  if [ "$CBOX_CLAUDE_MODE" = mount ]; then
    note "host-write sections are skipped in --config mode (bashrc mcp-servers agents claude-md settings hooks); apply them later with ./setup.sh update <section>"
  else
    note "host-write sections are skipped in --config mode (bashrc mcp-servers settings hooks); agents and claude-md are populated into $GEN_DIR/claude"
  fi
  section_dep_gate restart-policy
  if [ "$DEP_ACTION" = disable ]; then
    note "restart-policy forced: $DEP_REASON"
    CBOX_RESTART_POLICY=no
  fi
  if [ "$CBOX_GPU" = 1 ]; then
    section_dep_gate gpu
    if [ "$DEP_ACTION" = disable ]; then
      note "gpu forced off: $DEP_REASON"
      CBOX_GPU=0
    fi
  fi
  if [ "$CBOX_CODEX_MCP" = 1 ] && [ "$CBOX_CLAUDE_MODE" = mount ]; then
    note "codex-mcp is enabled but config writes (including the hooks dependency) are skipped in --config mode; apply with ./setup.sh update codex-mcp"
  fi
  if [ "$CBOX_HISTORY" = 1 ] && [ "$CBOX_CLAUDE_MODE" = mount ]; then
    note "continuity hooks staging is skipped in --config mode; apply with ./setup.sh update continuity"
  fi
  if [ "$CBOX_CODEX_MODE" = mount ]; then
    note "codex managed profile host files (~/.codex/cbox-container.config.toml, AGENTS.override.md, cbox-host.config.toml) are skipped in --config mode; apply with ./setup.sh update hooks"
  fi
  conf_save
  regen_all
  conf_load
  codex_profile_precreate_host_files
  if [ "$CBOX_CLAUDE_MODE" = volume ]; then
    agents_install
    step_claude_md
  fi
  if ! have_docker; then
    print_host_sequence
    return 0
  fi
  docker compose -f "$COMPOSE_FILE" build
  if [ "${CBOX_MODE:-global}" = isolated ]; then
    note "isolated mode: the image is built and shared bins install on the first cbox run; no global container is created here"
    isolated_next_steps ""
    return 0
  fi
  if [ ! -f /.dockerenv ] && have_docker; then
    "$INSTALL_DIR/cbox" reinstall-bins --if-stale
  fi
  CBOX_NO_EXEC=1 "$INSTALL_DIR/cbox" up
  smoke_test
  ssh_mixed_sync
  if [ "$CBOX_CODEX_MCP" = 1 ] && [ "$CBOX_CODEX_MODE" = volume ] && [ ! -f /.dockerenv ]; then
    codex_mcp_apply
  elif [ "$CBOX_CODEX_MCP" = 1 ]; then
    note "codex-mcp is enabled but config writes are skipped in --config mode; apply with ./setup.sh update codex-mcp"
  fi
  "$INSTALL_DIR/cbox" verify
  if [ "$CBOX_EGRESS_MODE" != off ] && [ "$CBOX_EGRESS_APPLIED" = 0 ]; then
    note "egress mode '$CBOX_EGRESS_MODE' is configured but not applied yet; run ./setup.sh update egress"
  fi
}

uninstall_bashrc() {
  [ -f "$HOME/.bashrc" ] || return 0
  grep -qF "$MARK_START" "$HOME/.bashrc" || return 0
  local stage
  stage="$(mktemp -d)"
  awk -v s="$MARK_START" -v e="$MARK_END" '
    index($0, s) { skip = 1; next }
    index($0, e) { skip = 0; next }
    skip { next }
    { print }
  ' "$HOME/.bashrc" > "$stage/bashrc"
  staged_write "$HOME/.bashrc" "$stage/bashrc" 0644 || true
  rm -rf "$stage"
  note "kept $HOME/.bashrc-cbox; delete it manually if you no longer want the shell functions"
}

uninstall_codex_mcp() {
  [ "$CBOX_CODEX_MODE" = mount ] || return 0
  local target="$CBOX_CODEX_PATH/config.toml"
  [ -f "$target" ] || return 0
  grep -qF "$CODEX_MCP_MARK_START" "$target" || grep -qF "$CODEX_MCP_LEGACY_MARK_START" "$target" || return 0
  local stage work
  stage="$(mktemp -d)"
  work="$stage/config.toml"
  cp "$target" "$work"
  codex_mcp_strip_block "$work"
  staged_write "$target" "$work" 0644 || true
  rm -rf "$stage"
}

uninstall_volumes() {
  local vols=() v
  if [ "$CBOX_CLAUDE_MODE" = volume ]; then
    vols+=("${CBOX_NAME}-claude")
  fi
  if [ "$CBOX_CODEX_MODE" = volume ]; then
    vols+=("${CBOX_NAME}-codex")
  fi
  if [ "$CBOX_VENV_MODE" = volume ]; then
    vols+=("${CBOX_NAME}-venv")
  fi
  case "$CBOX_SSH_MODE" in
    container-keys|mixed) vols+=("${CBOX_NAME}-ssh") ;;
  esac
  for v in "${vols[@]}"; do
    if ask_yn "setup: remove volume $v (its data is lost)? [y/N]" n; then
      if have_docker; then
        docker volume rm "$v" || true
      else
        note "docker cli is not available; run on the host:"
        echo "  docker volume rm $v"
      fi
    else
      note "kept volume $v"
    fi
  done
  note "binary volumes ($(_cbox_bins_volume claude), $(_cbox_bins_volume codex)) are global/shared and not removed here; they may be used by other projects - use 'cbox gc' or 'docker volume rm' explicitly if you really want them gone"
}

uninstall_generated() {
  if ask_yn "setup: remove generated artifacts (Dockerfile, compose files, .env, cbox.conf, generated/)? [y/N]" n; then
    rm -f "$INSTALL_DIR/Dockerfile" "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.gpu.yml" "$INSTALL_DIR/Dockerfile.egress" "$INSTALL_DIR/.env" "$CONF_FILE"
    rm -rf "$GEN_DIR"
    note "generated artifacts removed"
  else
    note "kept generated artifacts"
  fi
}

run_uninstall() {
  require_tty "uninstall"
  SETUP_MODE=uninstall
  conf_load
  load_generators
  if ! ask_yn "setup: uninstall cbox instance '$CBOX_NAME'? [y/N]" n; then
    note "aborted"
    return 0
  fi
  if [ -f "$COMPOSE_FILE" ]; then
    if have_docker && [ -x "$INSTALL_DIR/cbox" ]; then
      "$INSTALL_DIR/cbox" down || true
    elif have_docker; then
      docker compose -f "$COMPOSE_FILE" down || true
    else
      note "docker cli is not available; run on the host: docker compose -f $COMPOSE_FILE down"
    fi
  fi
  uninstall_bashrc
  uninstall_codex_mcp
  uninstall_volumes
  uninstall_generated
  note "uninstall finished"
}

_cbox_local_effdir_for() {
  local root="$1" p
  p="$(_cbox_path_hash "$root")"
  printf '%s/.config/cbox/projects/%s' "$HOME" "$p"
}

run_local_wizard_subset() {
  local root="$1"
  note "isolated-project wizard for $root (mounts derive from this workspace only)"
  ask_choice "setup: session scope (which slice of ~/.claude/projects this container mounts)" "$CBOX_SESSION_SCOPE" isolated global
  CBOX_SESSION_SCOPE="$ASK_VALUE"
  ask "setup: base image digest cache TTL in seconds (0 = re-check every launch): " "$CBOX_BASE_DIGEST_TTL"
  case "$ASK_VALUE" in
    ''|*[!0-9]*) warn "not a number; keeping $CBOX_BASE_DIGEST_TTL" ;;
    *) CBOX_BASE_DIGEST_TTL="$ASK_VALUE" ;;
  esac
  step_python
  step_gpu
  step_egress
  step_netaccess
  step_hostroute
  step_ssh
  step_apt_extra
  step_binaries
}

run_local() {
  local root="$1" from_global="${2:-0}" eff
  [ "$from_global" = 1 ] || require_tty "setup.sh --local"
  [ -n "$root" ] || die "usage: ./setup.sh --local <root> [--from-global]"
  [ -d "$root" ] || die "not a directory: $root"
  if root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)"; then
    root="$(realpath "$root")"
  else
    root="$(realpath "$1")"
  fi
  [ "$root" != "/" ] || die "refusing to use / as a workspace"
  [ "$root" != "$(realpath "$HOME")" ] || die "refusing to use \$HOME as a workspace"
  mountpoint -q "$root" 2>/dev/null && die "refusing to use a mount root as a workspace: $root"
  [ "$root" != "$(realpath "$INSTALL_DIR")" ] || die "refusing: workspace equals the cbox install directory ($INSTALL_DIR) - develop on a copied tree instead"
  case "$root" in
    "$(realpath "$INSTALL_DIR")"/*) die "refusing: workspace is inside the cbox install directory ($INSTALL_DIR)" ;;
  esac
  eff="$(_cbox_local_effdir_for "$root")"
  mkdir -p "$eff"
  _cbox_workspace_file_check "$root" "$eff"

  SETUP_MODE=local
  load_generators
  if [ -f "$eff/cbox.conf" ]; then
    CONF_FILE="$eff/cbox.conf"
  fi
  conf_load
  CONF_FILE="$eff/cbox.conf"
  CBOX_MODE=isolated
  CBOX_WORKSPACES="$root"
  CBOX_WORKDIR="$root"

  if [ "$from_global" = 1 ]; then
    note "deriving $eff/cbox.conf from the global profile (silent, no wizard)"
  else
    header "Isolated project: $root"
    run_local_wizard_subset "$root"
  fi

  conf_save "$eff/cbox.conf"
  _cbox_conf_set_tpl_sha "$eff/cbox.conf"
  conf_load

  local digest
  digest="$(_cbox_resolve_base_digest ubuntu:24.04)" || die "cannot resolve base image digest and no local image - network required for first build"
  cp "$INSTALL_DIR/entrypoint.sh" "$eff/entrypoint.sh"
  cp "$INSTALL_DIR/install-bins.sh" "$eff/install-bins.sh"
  gen_image_inputs "$eff" "$digest"
  local img_hash img_tag
  img_hash="$(_cbox_image_hash "$eff")"
  img_tag="$(_cbox_image_tag "$img_hash")"
  gen_dockerfile_into "$eff" "$digest"
  gen_env_file_into "$eff"
  gen_compose_isolated "$eff" "$root" "$img_tag" "$img_hash"

  _cbox_manifest_write "$eff" "$root" "$eff/cbox.conf"
  _cbox_manifest_write_generated "$eff"

  note "blessed effective config in $eff"
  note "the image builds automatically on the first cbox run (reused when inputs are unchanged)"
  note "run from $root: cbox run claude   (or codex)"
}

main() {
  case "${1:-}" in
    "")
      run_wizard
      ;;
    --help|-h|help)
      printf 'usage: ./setup.sh [update <section>|list-steps|--config <file>|--local <root> [--from-global]|uninstall|--help]\n'
      print_settings_help
      exit 0
      ;;
    update)
      [ -n "${2:-}" ] || die "usage: ./setup.sh update <section>"
      run_update "$2"
      ;;
    list-steps)
      run_list_steps
      ;;
    --config)
      [ -n "${2:-}" ] || die "usage: ./setup.sh --config <file>"
      run_config "$2"
      ;;
    --local)
      [ -n "${2:-}" ] || die "usage: ./setup.sh --local <root> [--from-global]"
      case "${3:-}" in
        --from-global) run_local "$2" 1 ;;
        "") run_local "$2" 0 ;;
        *) die "usage: ./setup.sh --local <root> [--from-global]" ;;
      esac
      ;;
    uninstall)
      run_uninstall
      ;;
    *)
      die "usage: ./setup.sh [--help|update <section>|list-steps|--config <file>|--local <root> [--from-global]|uninstall]"
      ;;
  esac
}

main "$@"
