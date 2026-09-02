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

_want_compat() {
  local name="$1" value="$2"
  case "$name" in
    codex) printf '%s' "${value%%|*}" ;;
    *) printf '%s' "$value" ;;
  esac
}

_bins_ready() {
  local name="$1" want stamp link cur_want p resolved
  case "$name" in
    claude) want="$CBOX_CLAUDE_TARGET"; stamp="$CLROOT/.cbox-stamp"; link="$CLROOT/bin/claude" ;;
    codex) want="$CBOX_CODEX_VERSION"; stamp="$CXPKG/.cbox-stamp"; link="$CLROOT/bin/codex" ;;
  esac
  cur_want="$(_stamp_field "$stamp" 1)" || return 1
  cur_want="$(_want_compat "$name" "$cur_want")"
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

_socks_proxy_host() {
  local LC_ALL=C
  local h="${CBOX_SOCKS_PROXY:-}"
  h="${h#*://}"
  h="${h%%/*}"
  h="${h%:*}"
  [ -n "$h" ] || return 1
  case "$h" in
    *[!A-Za-z0-9.-]*) return 1 ;;
  esac
  printf '%s' "$h"
}

_socks_state_write() {
  local dir
  for dir in /run/cbox /tmp/cbox; do
    if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
      printf '%s\n' "$1" > "$dir/netaccess.state" 2>/dev/null && return 0
    fi
  done
  return 0
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
  local host port
  if host="$(_socks_proxy_host)" && port="$(_socks_proxy_port)" && _socks_alive "$host" "$port"; then
    _socks_state_write "ok $host:$port"
    return 0
  fi
  if [ -z "${host:-}" ] || [ -z "${port:-}" ]; then
    echo "entrypoint: CBOX_SOCKS_PROXY is malformed or unset while a proxy variable is set - dropping the proxy variables so the agent uses direct egress" >&2
  else
    echo "entrypoint: SOCKS proxy ($host:$port) is unreachable - dropping the proxy variables so the agent uses direct egress instead of failing on a dead proxy" >&2
  fi
  _socks_state_write "broken ${host:-unset}:${port:-unset}"
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
    echo "entrypoint: session_scope_farm.py missing in ~/.claude/hooks - the scoped session view stays EMPTY (no sessions in the task manager) until the hooks are deployed: run 'cbox setup update hooks' or 'cbox install-hooks' on the host" >&2
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
        "refusing to start claude - run 'cbox setup update mcp-servers' or "
        "'cbox install-hooks' on the host, then recreate the container\n"
    )
    sys.exit(1)
PYEOF
}

_write_tmux_conf() {
  local target="${1:?}"
  _no_symlinks "$target"
  cat > "$target" <<'TMUXCONF'
set -g status off
set -g mouse on
set -g history-limit 50000
set -g escape-time 0
set -g focus-events on
set -g default-terminal "xterm-256color"
TMUXCONF
  chmod 0644 "$target"
}

_multiplex_session_name() {
  local engine="$1" hex
  hex="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || hex=""
  [ -n "$hex" ] || return 1
  printf 'cbox-%s-%s' "$engine" "$hex"
}

_multiplex_status_dir_new() {
  local base="${CBOX_MULTIPLEX_BASE:-/run/cbox/multiplex}" dir
  _no_symlinks "$base"
  mkdir -p "$base" 2>/dev/null || return 1
  chmod 0755 "$base" 2>/dev/null || true
  [ -d "$base" ] && [ ! -L "$base" ] || return 1
  dir="$(mktemp -d "$base/s.XXXXXXXXXX")" || return 1
  chmod 0700 "$dir"
  [ "$CBOX_ROOTLESS" = 1 ] || chown "$HOST_UID:$HOST_GID" "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

_multiplex_status_read() {
  local file="$1" val
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  val="$(_as_user cat "$file" 2>/dev/null)" || val=""
  case "$val" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#val}" -le 3 ] || return 1
  [ "$val" -le 255 ] 2>/dev/null || return 1
  printf '%s' "$val"
}

_multiplex_run() {
  local engine="$1"; shift
  local session status_dir status_file conf inner rc trc=0
  session="$(_multiplex_session_name "$engine")" || {
    echo "entrypoint: no usable randomness for a session name - running unwrapped" >&2
    _run_as_user "$@"
  }
  status_dir="$(_multiplex_status_dir_new)" || {
    echo "entrypoint: could not create a private status directory under /run/cbox - running unwrapped" >&2
    _run_as_user "$@"
  }
  status_file="$status_dir/status"
  conf="$status_dir/tmux.conf"
  _write_tmux_conf "$conf"
  inner="$(printf '%q ' "$@")"
  inner="$inner; __rc=\$?; printf %s \$__rc > $(printf '%q' "$status_file"); exit \$__rc"
  _as_user env SHELL=/bin/bash LANG=C.UTF-8 \
    tmux -u -f "$conf" new-session -s "$session" -c "$PWD" "$inner" || trc=$?
  if rc="$(_multiplex_status_read "$status_file")"; then
    :
  elif [ "$trc" -ne 0 ]; then
    rc="$trc"
  else
    echo "entrypoint: the multiplexed session left no exit status - reporting failure rather than a false success" >&2
    rc=1
  fi
  rm -rf "$status_dir" 2>/dev/null || true
  exit "$rc"
}

_codex_profile_preflight() {
  local profile="$HOST_HOME/.codex/cbox-container.config.toml"
  if [ ! -e "$profile" ]; then
    echo "entrypoint: codex managed profile missing at $profile - host re-bless required: run 'cbox setup update hooks' on the host, then recreate the container" >&2
    return 1
  fi
  if [ ! -f "$profile" ]; then
    echo "entrypoint: codex managed profile at $profile is not a regular file - host re-bless required: run 'cbox setup update hooks' on the host" >&2
    return 1
  fi
  if [ ! -s "$profile" ]; then
    echo "entrypoint: codex managed profile at $profile is empty - host re-bless required: run 'cbox setup update hooks' on the host" >&2
    return 1
  fi
  if ! python3 -c '
import sys
import tomllib
path = sys.argv[1]
with open(path, "rb") as f:
    tomllib.load(f)
' "$profile" 2>/dev/null; then
    echo "entrypoint: codex managed profile at $profile does not parse as TOML - host re-bless required: run 'cbox setup update hooks' on the host" >&2
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
      echo "entrypoint: codex managed hooks.json at $hooks_json does not parse as JSON - host re-bless required: run '\''cbox setup update hooks'\'' on the host" >&2
      return 1
    fi
    if [ -w "$hooks_json" ]; then
      echo "entrypoint: codex managed hooks.json at $hooks_json is writable by the container user - refusing to run codex with --dangerously-bypass-hook-trust against an untrusted mount; host re-bless required: run 'cbox setup update hooks' on the host" >&2
      return 1
    fi
    if grep -q "codex_guard_bridge.py" "$hooks_json" 2>/dev/null; then
      local bridge="$HOST_HOME/.claude/hooks/codex_guard_bridge.py"
      if [ ! -f "$bridge" ]; then
        echo "entrypoint: codex hooks.json references codex_guard_bridge.py but $bridge is missing - the guard would silently not fire; host re-bless required: run 'cbox setup update hooks' on the host" >&2
        return 1
      fi
      if [ -w "$bridge" ]; then
        echo "entrypoint: codex guard bridge at $bridge is writable by the container user - refusing to run codex with --dangerously-bypass-hook-trust against an untrusted guard script; host re-bless required: run 'cbox setup update hooks' on the host" >&2
        return 1
      fi
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

_sshd_listen_addr_present() {
  local addr="$1"
  command -v ip >/dev/null 2>&1 || return 1
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$addr"
}

_start_sshd() {
  local cfg=/etc/cbox-sshd/sshd_config
  [ -f "$cfg" ] || return 0
  if [ ! -f /etc/cbox-sshd/authorized_keys ]; then
    echo "entrypoint: /etc/cbox-sshd/authorized_keys missing - refusing to start sshd" >&2
    return 1
  fi
  local listen_addr
  listen_addr="$(awk '$1=="ListenAddress"{print $2; exit}' "$cfg")"
  if [ -z "$listen_addr" ]; then
    echo "entrypoint: sshd_config has no ListenAddress - refusing to start sshd" >&2
    return 1
  fi
  if ! _sshd_listen_addr_present "$listen_addr"; then
    echo "entrypoint: sshd ListenAddress $listen_addr is not held by any interface in this container - refusing to start sshd" >&2
    return 1
  fi
  mkdir -p /run/cbox-sshd /var/log/cbox-sshd
  [ "$CBOX_ROOTLESS" = 1 ] || chown "$HOST_UID:$HOST_GID" /run/cbox-sshd /var/log/cbox-sshd
  if [ ! -r /etc/cbox-sshd/hostkeys/ssh_host_ed25519_key ] || [ ! -r /etc/cbox-sshd/hostkeys/ssh_host_rsa_key ]; then
    echo "entrypoint: sshd host keys missing or unreadable under /etc/cbox-sshd/hostkeys - refusing to start sshd" >&2
    return 1
  fi
  _as_user setsid /usr/sbin/sshd -D -e -f "$cfg" < /dev/null > /var/log/cbox-sshd/sshd.stderr 2>&1 &
  disown "$!" 2>/dev/null || true
}

_start_sshd || {
  echo "entrypoint: sshd did not start - remote session access is unavailable for this container; the container itself continues" >&2
}
_hermes_apply_mcp_servers() {
  local srcfile="$1" configfile="$2"
  [ -f "$srcfile" ] || srcfile=""
  _as_user env HERMES_HOME="$HERMES_HOME" python3 - "$srcfile" "$configfile" <<'PY'
import os
import sys

src_path, config_path = sys.argv[1], sys.argv[2]

block_lines = ["mcp_servers: {}"]
if src_path:
    try:
        fd = os.open(src_path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        text = ""
    if text.strip():
        block_lines = text.rstrip("\n").split("\n")

try:
    fd = os.open(config_path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        cur_lines = fh.read().split("\n")
except OSError:
    cur_lines = [""]

out_lines = []
skipping = False
inserted = False
for line in cur_lines:
    if line.startswith("mcp_servers:"):
        skipping = True
        out_lines.extend(block_lines)
        inserted = True
        continue
    if skipping:
        if line.startswith((" ", "\t")) or line == "":
            continue
        skipping = False
    out_lines.append(line)

if not inserted:
    while out_lines and out_lines[-1] == "":
        out_lines.pop()
    out_lines.append("")
    out_lines.extend(block_lines)

body = "\n".join(out_lines)
if not body.endswith("\n"):
    body += "\n"

tmp_path = config_path + ".cbox-mcp.tmp"
try:
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
except OSError as e:
    sys.stderr.write("entrypoint: cannot write %s: %s\n" % (tmp_path, e))
    sys.exit(1)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(body)
os.replace(tmp_path, config_path)
PY
}

_hermes_apply_hooks() {
  local srcfile="$1" configfile="$2"
  [ -f "$srcfile" ] || return 0
  _as_user env HERMES_HOME="$HERMES_HOME" python3 - "$srcfile" "$configfile" <<'PY'
import os
import sys

src_path, config_path = sys.argv[1], sys.argv[2]

try:
    fd = os.open(src_path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        text = fh.read()
except OSError:
    sys.exit(0)
if not text.strip():
    sys.exit(0)
block_lines = text.rstrip("\n").split("\n")

try:
    fd = os.open(config_path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        cur_lines = fh.read().split("\n")
except OSError:
    cur_lines = [""]

out_lines = []
skipping = False
inserted = False
for line in cur_lines:
    if line.startswith("hooks:"):
        skipping = True
        out_lines.extend(block_lines)
        inserted = True
        continue
    if skipping:
        if line.startswith((" ", "\t")) or line == "":
            continue
        skipping = False
    out_lines.append(line)

if not inserted:
    while out_lines and out_lines[-1] == "":
        out_lines.pop()
    out_lines.append("")
    out_lines.extend(block_lines)

body = "\n".join(out_lines)
if not body.endswith("\n"):
    body += "\n"

tmp_path = config_path + ".cbox-hooks.tmp"
try:
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
except OSError as e:
    sys.stderr.write("entrypoint: cannot write %s: %s\n" % (tmp_path, e))
    sys.exit(1)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(body)
os.replace(tmp_path, config_path)
PY
}

_hermes_hooks_preflight() {
  local hooks_src="$1"; shift
  local script
  if [ ! -e "$hooks_src" ]; then
    echo "entrypoint: hermes managed hooks block missing at $hooks_src - host re-bless required: run 'cbox setup update hooks' on the host, then recreate the container" >&2
    return 1
  fi
  if [ ! -f "$hooks_src" ]; then
    echo "entrypoint: hermes managed hooks block at $hooks_src is not a regular file - host re-bless required: run 'cbox setup update hooks' on the host" >&2
    return 1
  fi
  if [ -w "$hooks_src" ]; then
    echo "entrypoint: hermes managed hooks block at $hooks_src is writable by the container user - refusing to auto-accept hermes hooks against an untrusted mount; host re-bless required: run 'cbox setup update hooks' on the host" >&2
    return 1
  fi
  for script in "$@"; do
    if [ ! -e "$script" ]; then
      echo "entrypoint: hermes guard script missing at $script - host re-bless required: run 'cbox setup update hooks' on the host, then recreate the container" >&2
      return 1
    fi
    if [ ! -f "$script" ]; then
      echo "entrypoint: hermes guard script at $script is not a regular file - host re-bless required: run 'cbox setup update hooks' on the host" >&2
      return 1
    fi
    if [ -w "$script" ]; then
      echo "entrypoint: hermes guard script at $script is writable by the container user - refusing to auto-accept hermes hooks against an untrusted mount; host re-bless required: run 'cbox setup update hooks' on the host" >&2
      return 1
    fi
  done
  return 0
}

_hermes_user_policies_preamble() {
  local dir=/etc/cbox/user/policies
  local cap=16384
  local total=0
  local out=""
  local base f sz dirname_of_f
  [ -d "$dir" ] || return 0
  local -a files=()
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    [ -f "$f" ] || continue
    base="${f##*/}"
    dirname_of_f="${f%/*}"
    if [ "$dirname_of_f" != "$dir" ]; then
      echo "entrypoint: user policy '$base' skipped - unsupported filename" >&2
      continue
    fi
    case "$base" in
      [A-Za-z0-9]*.md)
        case "$base" in
          *[!A-Za-z0-9._-]*)
            echo "entrypoint: user policy '$base' skipped - unsupported filename" >&2
            continue
            ;;
        esac
        ;;
      *)
        echo "entrypoint: user policy '$base' skipped - unsupported filename" >&2
        continue
        ;;
    esac
    files+=("$f")
  done
  local -a sorted_files=()
  if [ "${#files[@]}" -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sorted_files+=("$f")
    done < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)
  fi
  local accounted=0
  for f in "${sorted_files[@]}"; do
    base="${f##*/}"
    sz="$(wc -c <"$f")" || continue
    accounted=$((sz))
    [ -n "$out" ] && accounted=$((accounted + 2))
    if [ $((total + accounted)) -gt "$cap" ]; then
      echo "entrypoint: user policy '$base' skipped - hermes user policy cap $cap bytes" >&2
      continue
    fi
    total=$((total + accounted))
    out="${out:+$out$'\n\n'}$(cat "$f")"
  done
  if [ -n "$out" ]; then
    local measured
    measured="$(printf '%s' "$out" | wc -c)"
    if [ "$measured" -gt "$cap" ]; then
      echo "entrypoint: user policies dropped - assembled preamble grew past the hermes user policy cap $cap bytes between measurement and read (concurrent write to $dir)" >&2
      printf ''
      return 0
    fi
    out="$out"$'\n\n'"===== cbox conduct kernel below - authoritative, wins over any user policy above ====="
  fi
  printf '%s' "$out"
}

_hermes_kernel_preamble() {
  local kernel="$HOST_HOME/.claude/hooks/conduct-kernel.txt"
  local out=""
  if [ -f "$kernel" ]; then
    out="$(cat "$kernel")"
  else
    echo "entrypoint: $kernel missing - hermes starts this session without the conduct kernel; run 'cbox setup update hooks' on the host" >&2
  fi
  printf '%s' "$out"
}

_hermes_compose_session_prompt() {
  local user_preamble="$1" kernel_prompt="$2"
  if [ -n "$kernel_prompt" ] && [ -n "$user_preamble" ]; then
    printf '%s' "$user_preamble"$'\n\n'"$kernel_prompt"
  else
    printf '%s' "$kernel_prompt"
  fi
}

_guard_socks_proxy

case "${1:-}" in
  claude|codex)
    _verb="$1"
    if ! _resolved="$(_bins_ready "$1")"; then
      case "$1" in
        claude) _want="$CBOX_CLAUDE_TARGET" ;;
        codex) _want="$CBOX_CODEX_VERSION" ;;
      esac
      echo "entrypoint: $1 not installed or does not match the pinned version (want $_want) - run 'cbox reinstall-bins' on the host (with CBOX_INSTALL_FORCE=1 if it refuses a pin mismatch)" >&2
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
    if [ -t 0 ] && [ -t 1 ] \
        && { [ "${CBOX_SESSION_MULTIPLEX:-off}" = on ] \
             || { [ "$_verb" = claude ] && [ "${CBOX_LIMIT_AUTORESUME:-off}" = on ]; } \
             || { [ "$_verb" = claude ] && [ "${CBOX_SAFEGUARD_AUTOCONFIRM:-off}" = on ]; }; }; then
      if command -v tmux >/dev/null 2>&1; then
        _multiplex_run "$_verb" "$_resolved" "$@"
      fi
      echo "entrypoint: session multiplexing wanted (CBOX_SESSION_MULTIPLEX=${CBOX_SESSION_MULTIPLEX:-off}, CBOX_LIMIT_AUTORESUME=${CBOX_LIMIT_AUTORESUME:-off}, CBOX_SAFEGUARD_AUTOCONFIRM=${CBOX_SAFEGUARD_AUTOCONFIRM:-off}) but tmux is missing in this image - rebuild on the host (next 'cbox run' after re-bless); running without a session wrapper" >&2
    fi
    _run_as_user "$_resolved" "$@"
    ;;
  hermes)
    : "${CBOX_HERMES:?entrypoint: CBOX_HERMES is off - enable and rebuild first: cbox setup update hermes}"
    [ "$CBOX_HERMES" = on ] \
      || { echo "entrypoint: hermes is disabled (CBOX_HERMES=$CBOX_HERMES) - run 'cbox setup update hermes' on the host, then rebuild" >&2; exit 1; }
    : "${CBOX_HERMES_VERSION:?entrypoint: CBOX_HERMES_VERSION is unset - run cbox setup update hermes}"
    if [ ! -x /opt/hermes/bin/hermes ]; then
      echo "entrypoint: /opt/hermes/bin/hermes missing or not executable - the hermes bins volume is empty, run 'cbox reinstall-bins' on the host" >&2
      exit 1
    fi
    _hermes_want="$(_stamp_field /opt/hermes/.cbox-stamp 1)" || _hermes_want=""
    _hermes_have="$(_stamp_field /opt/hermes/.cbox-stamp 4)" || _hermes_have=""
    if [ "$_hermes_want" != "$CBOX_HERMES_VERSION" ] || [ -z "$_hermes_have" ]; then
      echo "entrypoint: the hermes volume is stale - it was installed for target ${_hermes_want:-none} (installed version ${_hermes_have:-none}) but this container wants $CBOX_HERMES_VERSION; run 'cbox reinstall-bins' on the host. This is a staleness check, not an integrity check - the volume content is trusted." >&2
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
    _hermes_apply_mcp_servers /etc/cbox/hermes-managed/mcp_servers.yaml "$HERMES_HOME/config.yaml" || exit 1
    if [ -f /etc/cbox/hermes-managed/hooks.yaml ]; then
      _hermes_hooks_preflight /etc/cbox/hermes-managed/hooks.yaml \
        "$HOST_HOME/.claude/hooks/hermes_guard_bridge.py" \
        "$HOST_HOME/.claude/hooks/commit_guard.py" \
        "$HOST_HOME/.claude/hooks/rm_glob_guard.py" \
        || exit 1
      _hermes_apply_hooks /etc/cbox/hermes-managed/hooks.yaml "$HERMES_HOME/config.yaml" || exit 1
      HERMES_ACCEPT_HOOKS=1
      export HERMES_ACCEPT_HOOKS
    fi
    _hermes_user_preamble="$(_hermes_user_policies_preamble)"
    _hermes_session_prompt="$(_hermes_kernel_preamble)"
    _hermes_session_prompt="$(_hermes_compose_session_prompt "$_hermes_user_preamble" "$_hermes_session_prompt")"
    if [ -n "${HERMES_EPHEMERAL_SYSTEM_PROMPT:-}" ]; then
      _hermes_session_prompt="${_hermes_session_prompt:+$_hermes_session_prompt$'\n\n'}$HERMES_EPHEMERAL_SYSTEM_PROMPT"
    fi
    _cbox_loader="$HOST_HOME/.claude/hooks/continuity_session_start.py"
    if [ -f "$_cbox_loader" ]; then
      _cbox_brain="$(_as_user python3 "$_cbox_loader" < /dev/null)" || _cbox_brain=""
      if [ -n "$_cbox_brain" ]; then
        _hermes_session_prompt="${_hermes_session_prompt:+$_hermes_session_prompt$'\n\n'}$_cbox_brain"
      fi
    else
      echo "entrypoint: $_cbox_loader missing - hermes starts this session without the session core or brain payloads; run 'cbox setup update hooks' on the host" >&2
    fi
    if [ -t 0 ] && [ -t 1 ] && [ "${CBOX_SESSION_MULTIPLEX:-off}" = on ]; then
      if command -v tmux >/dev/null 2>&1; then
        _multiplex_run hermes env HERMES_HOME="$HERMES_HOME" HERMES_EPHEMERAL_SYSTEM_PROMPT="$_hermes_session_prompt" /opt/hermes/bin/hermes "$@"
      fi
      echo "entrypoint: CBOX_SESSION_MULTIPLEX=on but tmux is missing in this image - rebuild on the host (next 'cbox run' after re-bless); running without a session wrapper" >&2
    fi
    _run_as_user env HERMES_HOME="$HERMES_HOME" HERMES_EPHEMERAL_SYSTEM_PROMPT="$_hermes_session_prompt" /opt/hermes/bin/hermes "$@"
    ;;
esac

_run_as_user "$@"
