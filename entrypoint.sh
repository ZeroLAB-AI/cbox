#!/usr/bin/env bash
set -euo pipefail
: "${HOST_USER:?}"; : "${HOST_UID:?}"; : "${HOST_GID:?}"; : "${HOST_HOME:?}"
: "${CBOX_CLAUDE_TARGET:?}"; : "${CBOX_CODEX_VERSION:?}"
CBOX_CODEX_TARGET="${CBOX_CODEX_TARGET:-}"

_is_rootless() {
  [ -f /proc/self/uid_map ] || return 1
  awk -v hu="$HOST_UID" '$1 == 0 { found=1; if ($2 == hu) ok=1 } END { exit (found && ok) ? 0 : 1 }' /proc/self/uid_map
}

CBOX_ROOTLESS=0
_is_rootless && CBOX_ROOTLESS=1

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" "$HOST_USER"
id -u "$HOST_USER" >/dev/null 2>&1 || useradd -o -u "$HOST_UID" -g "$HOST_GID" -d "$HOST_HOME" -s /bin/bash "$HOST_USER"

if [ ! -d "$HOST_HOME" ]; then
  mkdir -p "$HOST_HOME"
fi
[ "$CBOX_ROOTLESS" = 1 ] || chown "$HOST_UID:$HOST_GID" "$HOST_HOME" 2>/dev/null || true

_no_symlinks() {
  local p="$1"
  while [ "$p" != "/" ] && [ -n "$p" ]; do
    if [ -L "$p" ]; then
      echo "entrypoint: refusing symlink in path ($p) - possible root-escape attempt" >&2
      exit 1
    fi
    [ -e "$p" ] && break
    p="$(dirname "$p")"
  done
}

_ensure_owned() {
  local d="$1"
  if [ ! -e "$d" ]; then
    _no_symlinks "$d"
    mkdir -p "$d"
    [ "$CBOX_ROOTLESS" = 1 ] || chown -R "$HOST_UID:$HOST_GID" "$d"
  elif [ -e "$d" ]; then
    _no_symlinks "$d"
    if [ "$CBOX_ROOTLESS" != 1 ] && [ "$(stat -c %u "$d")" != "$HOST_UID" ]; then
      if [ -z "$(ls -A "$d" 2>/dev/null || true)" ]; then
        chown -R "$HOST_UID:$HOST_GID" "$d"
      else
        chown "$HOST_UID:$HOST_GID" "$d"
      fi
    fi
  fi
}

IFS=':' read -ra _managed_dirs <<< "${CBOX_MANAGED_DIRS:-}"
for _md in "${_managed_dirs[@]}"; do
  [ -n "$_md" ] || continue
  [ "${_md:0:1}" = "/" ] || continue
  _ensure_owned "$_md"
done

CLROOT="$HOST_HOME/.local"
CXPKG="$HOST_HOME/.codex/packages"

export HOME="$HOST_HOME"
export PATH="$HOST_HOME/.local/bin:$PATH"

_resolve_bin() {
  local p
  p="$(readlink -f "$1" 2>/dev/null)" || return 1
  [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] || return 1
  case "$p" in
    "$HOST_HOME"/*) ;;
    *) return 1 ;;
  esac
  head -c4 "$p" 2>/dev/null | grep -q "$(printf '\177ELF')" || return 1
  printf '%s' "$p"
}

_stamp_field() {
  [ -f "$1" ] || return 1
  sed -n "${2}p" "$1"
}

_bins_ready() {
  local name="$1" want stamp link cur_want p resolved
  case "$name" in
    claude) want="$CBOX_CLAUDE_TARGET"; stamp="$CLROOT/.cbox-stamp"; link="$CLROOT/bin/claude" ;;
    codex) want="$CBOX_CODEX_VERSION|$CBOX_CODEX_TARGET"; stamp="$CXPKG/.cbox-stamp"; link="$CLROOT/bin/codex" ;;
  esac
  cur_want="$(_stamp_field "$stamp" 1)" || return 1
  [ "$cur_want" = "$want" ] || return 1
  p="$(_stamp_field "$stamp" 2)" || return 1
  [ -n "$p" ] || return 1
  resolved="$(_resolve_bin "$link")" || return 1
  [ "$resolved" = "$p" ] && printf '%s' "$p"
}

_run_as_user() {
  if [ "$CBOX_ROOTLESS" = 1 ]; then
    exec "$@"
  else
    exec /usr/sbin/gosu "$HOST_UID:$HOST_GID" "$@"
  fi
}

_as_user() {
  if [ "$CBOX_ROOTLESS" = 1 ]; then
    "$@"
  else
    /usr/sbin/gosu "$HOST_UID:$HOST_GID" "$@"
  fi
}

_socks_proxy_port() {
  local p="${CBOX_SOCKS_PROXY##*:}"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1 ;;
  esac
  printf '%s' "$p"
}

_socks_alive() {
  local host="$1" port="$2" i=0
  while [ "$i" -lt 3 ]; do
    if timeout 1 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      return 0
    fi
    i=$((i + 1))
    sleep 0.25
  done
  return 1
}

_guard_socks_proxy() {
  [ -n "${CBOX_SOCKS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}" ] || return 0
  local port
  if port="$(_socks_proxy_port)" && _socks_alive proxy "$port"; then
    return 0
  fi
  if [ -z "${port:-}" ]; then
    echo "entrypoint: CBOX_SOCKS_PROXY is malformed or unset while ALL_PROXY is set - dropping ALL_PROXY so the agent uses direct egress" >&2
  else
    echo "entrypoint: SOCKS proxy (proxy:$port) is unreachable - dropping ALL_PROXY so the agent uses direct egress instead of failing on a dead proxy" >&2
  fi
  unset CBOX_SOCKS_PROXY ALL_PROXY all_proxy
}

_ensure_scope_services() {
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] || return 0
  [ -n "${CBOX_SCOPE_SLUG:-}" ] || return 0
  [ -d "$CLAUDE_CONFIG_DIR" ] || return 0
  local farmpy="$HOST_HOME/.claude/hooks/session_scope_farm.py"
  local watchpy="$HOST_HOME/.claude/hooks/limit_watchdog.py"
  if [ -f "$farmpy" ]; then
    _as_user python3 "$farmpy" --once || true
  else
    echo "entrypoint: session_scope_farm.py missing in ~/.claude/hooks - the scoped session view stays EMPTY (no sessions in the task manager) until the hooks are deployed: run './setup.sh update hooks' or 'cbox install-hooks' on the host" >&2
  fi
  if [ -f "$watchpy" ]; then
    _as_user setsid python3 "$watchpy" --daemon < /dev/null > /dev/null 2>&1 &
  fi
}

_check_codex_mcp_shim_seed() {
  local seed
  local -a seeds=()
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    seeds+=("$CLAUDE_CONFIG_DIR/.claude.json")
  fi
  seeds+=("$HOST_HOME/.claude.json")
  for seed in "${seeds[@]}"; do
    [ -f "$seed" ] || continue
    if ! command -v python3 >/dev/null 2>&1; then
      echo "entrypoint: python3 missing - cannot validate the codex mcp shim wrapper in $seed, refusing to start claude" >&2
      return 1
    fi
    _check_codex_mcp_shim_seed_one "$seed" || return 1
  done
  return 0
}

_check_codex_mcp_shim_seed_one() {
  python3 - "$1" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, ValueError) as e:
    sys.stderr.write("entrypoint: cannot parse " + path + ": " + type(e).__name__ + "\n")
    sys.exit(1)

servers = data.get("mcpServers")
if not isinstance(servers, dict):
    sys.exit(0)

REQUIRED_FLAGS = ("--tier", "--model", "--effort", "--progress")

stale = []
for name, spec in servers.items():
    if not isinstance(name, str) or not name.startswith("codex-"):
        continue
    if not isinstance(spec, dict):
        stale.append(name)
        continue
    args = spec.get("args")
    if spec.get("command") != "python3" or not isinstance(args, list):
        stale.append(name)
        continue
    has_shim = any(
        isinstance(a, str) and a.endswith("codex_mcp_shim.py") for a in args
    )
    has_flags = all(
        any(isinstance(a, str) and a == flag for a in args)
        for flag in REQUIRED_FLAGS
    )
    has_codex_mcp_server = any(
        isinstance(a, str) and a == "mcp-server" for a in args
    ) and any(isinstance(a, str) and a == "codex" for a in args)
    if not (has_shim and has_flags and has_codex_mcp_server):
        stale.append(name)

if stale:
    sys.stderr.write(
        "entrypoint: " + path + " has codex mcp server(s) not wrapped by codex_mcp_shim.py ("
        + ", ".join(sorted(stale))
        + ") - tier injection and the delegation depth guard would be bypassed; "
        "refusing to start claude - run './setup.sh update mcp-servers' or "
        "'cbox install-hooks' on the host, then recreate the container\n"
    )
    sys.exit(1)
PYEOF
}

_write_tmux_conf() {
  cat > /tmp/cbox-tmux.conf <<'TMUXCONF'
set -g status off
set -g mouse on
set -g history-limit 50000
set -g escape-time 0
set -g default-terminal "xterm-256color"
TMUXCONF
  chmod 0644 /tmp/cbox-tmux.conf
}

_codex_profile_preflight() {
  local profile="$HOST_HOME/.codex/cbox-container.config.toml"
  if [ ! -e "$profile" ]; then
    echo "entrypoint: codex managed profile missing at $profile - host re-bless required: run './setup.sh update hooks' on the host, then recreate the container" >&2
    return 1
  fi
  if [ ! -f "$profile" ]; then
    echo "entrypoint: codex managed profile at $profile is not a regular file - host re-bless required: run './setup.sh update hooks' on the host" >&2
    return 1
  fi
  if [ ! -s "$profile" ]; then
    echo "entrypoint: codex managed profile at $profile is empty - host re-bless required: run './setup.sh update hooks' on the host" >&2
    return 1
  fi
  if ! python3 -c '
import sys
import tomllib
path = sys.argv[1]
with open(path, "rb") as f:
    tomllib.load(f)
' "$profile" 2>/dev/null; then
    echo "entrypoint: codex managed profile at $profile does not parse as TOML - host re-bless required: run './setup.sh update hooks' on the host" >&2
    return 1
  fi
  local hooks_json="$HOST_HOME/.codex/hooks.json"
  if [ -e "$hooks_json" ] && [ -s "$hooks_json" ]; then
    if ! python3 -c '
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    json.load(f)
' "$hooks_json" 2>/dev/null; then
      echo "entrypoint: codex managed hooks.json at $hooks_json does not parse as JSON - host re-bless required: run '\''./setup.sh update hooks'\'' on the host" >&2
      return 1
    fi
    if [ -w "$hooks_json" ]; then
      echo "entrypoint: codex managed hooks.json at $hooks_json is writable by the container user - refusing to run codex with --dangerously-bypass-hook-trust against an untrusted mount; host re-bless required: run './setup.sh update hooks' on the host" >&2
      return 1
    fi
  fi
  return 0
}

_hermes_validate_url() {
  case "$1" in
    *[$'\n\r']*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$'
}

_hermes_validate_model() {
  case "$1" in
    *[$'\n\r']*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._:/-]+$'
}

_hermes_validate_provider() {
  case "$1" in
    local|nous|openrouter|openai|anthropic) return 0 ;;
    *) return 1 ;;
  esac
}

_hermes_apply_managed_env() {
  local envfile="$1" key val
  [ -f "$envfile" ] || return 0
  while IFS='=' read -r key val || [ -n "$key" ]; do
    if [ "$key" = HERMES_MANAGED_PROVIDER ]; then
      _hermes_validate_provider "$val" \
        || { echo "entrypoint: hermes-managed.env has an invalid HERMES_MANAGED_PROVIDER '$val' - refusing to apply" >&2; return 1; }
      _as_user env HERMES_HOME="$HERMES_HOME" /opt/hermes/bin/hermes config set model.provider "$val" \
        || { echo "entrypoint: 'hermes config set model.provider $val' failed" >&2; return 1; }
    elif [ "$key" = HERMES_MANAGED_BASE_URL ]; then
      _hermes_validate_url "$val" \
        || { echo "entrypoint: hermes-managed.env has an invalid HERMES_MANAGED_BASE_URL '$val' - refusing to apply" >&2; return 1; }
      _as_user env HERMES_HOME="$HERMES_HOME" /opt/hermes/bin/hermes config set model.base_url "$val" \
        || { echo "entrypoint: 'hermes config set model.base_url $val' failed" >&2; return 1; }
    elif [ "$key" = HERMES_MANAGED_MODEL ]; then
      _hermes_validate_model "$val" \
        || { echo "entrypoint: hermes-managed.env has an invalid HERMES_MANAGED_MODEL '$val' - refusing to apply" >&2; return 1; }
      _as_user env HERMES_HOME="$HERMES_HOME" /opt/hermes/bin/hermes config set model.default "$val" \
        || { echo "entrypoint: 'hermes config set model.default $val' failed" >&2; return 1; }
    fi
  done < "$envfile"
}

_guard_socks_proxy

case "${1:-}" in
  claude|codex)
    _verb="$1"
    if ! _resolved="$(_bins_ready "$1")"; then
      case "$1" in
        claude) _want="$CBOX_CLAUDE_TARGET" ;;
        codex) _want="$CBOX_CODEX_VERSION|$CBOX_CODEX_TARGET" ;;
      esac
      echo "entrypoint: $1 not installed or does not match the pinned version (want $_want) - run 'cbox reinstall-bins' on the host" >&2
      exit 1
    fi
    shift
    _ensure_scope_services
    if [ "$_verb" = claude ]; then
      _check_codex_mcp_shim_seed || exit 1
    fi
    if [ "$_verb" = codex ]; then
      _codex_profile_preflight || exit 1
      for _a in "$@"; do
        case "$_a" in
          -p|--profile|-p=*|--profile=*)
            echo "entrypoint: -p/--profile may not be overridden - the container always runs codex --profile cbox-container" >&2
            exit 1
            ;;
        esac
      done
      set -- --strict-config --profile cbox-container --dangerously-bypass-hook-trust "$@"
    fi
    if [ "$_verb" = claude ] && [ "${CBOX_LIMIT_AUTORESUME:-off}" = on ] \
        && [ -t 0 ] && [ -t 1 ]; then
      if command -v tmux >/dev/null 2>&1; then
        _write_tmux_conf
        _cmd="$(printf '%q ' "$_resolved" "$@")"
        _run_as_user env SHELL=/bin/bash LANG=C.UTF-8 tmux -u -f /tmp/cbox-tmux.conf new-session -c "$PWD" "$_cmd"
      fi
      echo "entrypoint: CBOX_LIMIT_AUTORESUME=on but tmux is missing in this image - rebuild on the host (next 'cbox run' after re-bless); running without auto-resume" >&2
    fi
    _run_as_user "$_resolved" "$@"
    ;;
  hermes)
    : "${CBOX_HERMES:?entrypoint: CBOX_HERMES is off - enable and rebuild first: ./setup.sh update hermes}"
    [ "$CBOX_HERMES" = on ] \
      || { echo "entrypoint: hermes is disabled (CBOX_HERMES=$CBOX_HERMES) - run './setup.sh update hermes' on the host, then rebuild" >&2; exit 1; }
    : "${CBOX_HERMES_VERSION:?entrypoint: CBOX_HERMES_VERSION is unset - run ./setup.sh update hermes}"
    if [ ! -x /opt/hermes/bin/hermes ]; then
      echo "entrypoint: /opt/hermes/bin/hermes missing or not executable - this image predates enabling hermes, rebuild: ./setup.sh update hermes" >&2
      exit 1
    fi
    shift
    HERMES_HOME="${HERMES_HOME:-$HOST_HOME/.hermes-cbox}"
    _ensure_owned "$HERMES_HOME"
    if [ ! -f "$HERMES_HOME/config.yaml" ]; then
      _as_user env HERMES_HOME="$HERMES_HOME" /opt/hermes/bin/hermes setup --non-interactive \
        || { echo "entrypoint: 'hermes setup --non-interactive' failed - fix manually via 'cbox shell'" >&2; exit 1; }
    fi
    _hermes_apply_managed_env /etc/cbox/hermes-managed/managed.env || exit 1
    _hermes_session_prompt="${HERMES_EPHEMERAL_SYSTEM_PROMPT:-}"
    if [ -n "${CBOX_SESSION_MEMORY_FILE:-}" ] && [ -f "${CBOX_SESSION_MEMORY_FILE:-}" ] \
        && [ -f /opt/cbox/cbox_session_bridge.py ]; then
      _cbox_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || _cbox_root=""
      _cbox_ref="${CBOX_SESSION_MEMORY_FILE#"$_cbox_root"/}"
      _cbox_memory=""
      case "$_cbox_ref" in
        ".cbox/sessions/${CBOX_SESSION_ID:-invalid}/distillates/"handoff-[0-9][0-9][0-9][0-9][0-9][0-9].json) _cbox_ref_ok=1 ;;
        *) _cbox_ref_ok=0 ;;
      esac
      if [ -n "$_cbox_root" ] && [ "$_cbox_ref" != "$CBOX_SESSION_MEMORY_FILE" ] && [ "$_cbox_ref_ok" = 1 ]; then
        _cbox_memory="$(_as_user python3 /opt/cbox/cbox_session_bridge.py render --root "$_cbox_root" --ref "$_cbox_ref" 2>/dev/null)" || _cbox_memory=""
      fi
      if [ -n "$_cbox_memory" ]; then
        _hermes_session_prompt="${_hermes_session_prompt:+$_hermes_session_prompt$'\n\n'}$_cbox_memory"
      fi
    fi
    _run_as_user env HERMES_HOME="$HERMES_HOME" HERMES_EPHEMERAL_SYSTEM_PROMPT="$_hermes_session_prompt" /opt/hermes/bin/hermes "$@"
    ;;
esac

_run_as_user "$@"
