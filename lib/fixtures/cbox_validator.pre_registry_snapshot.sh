_cbox_config_no_ctrl() {
  local val="$1" c i
  case "$val" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  for ((i = 0; i < ${#val}; i++)); do
    c="${val:i:1}"
    case "$c" in
      $'\x00'|$'\x01'|$'\x02'|$'\x03'|$'\x04'|$'\x05'|$'\x06'|$'\x07'|$'\x08'|\
      $'\x0b'|$'\x0c'|$'\x0e'|$'\x0f'|$'\x10'|$'\x11'|$'\x12'|$'\x13'|$'\x14'|\
      $'\x15'|$'\x16'|$'\x17'|$'\x18'|$'\x19'|$'\x1a'|$'\x1b'|$'\x1c'|$'\x1d'|\
      $'\x1e'|$'\x1f')
        return 1
        ;;
    esac
  done
  return 0
}

_cbox_config_validate_enum() {
  local val="$1"; shift
  local a
  for a in "$@"; do
    [ "$val" = "$a" ] && return 0
  done
  return 1
}

_cbox_config_validate_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

_cbox_config_validate_path() {
  case "$1" in
    ''|*[!\ -~]*) return 1 ;;
    *' '*) return 1 ;;
    /*) return 0 ;;
    '~'|'~/'*) return 0 ;;
  esac
  return 1
}

_cbox_config_validate_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
  esac
  return 1
}

_cbox_config_validate_var() {
  local key="$1" val="$2"
  _cbox_config_no_ctrl "$val" || { printf 'contains a control character'; return 1; }
  case "$key" in
    CBOX_MODE)
      _cbox_config_validate_enum "$val" global isolated || { printf 'expected one of: global isolated'; return 1; }
      ;;
    CBOX_SESSION_SCOPE)
      _cbox_config_validate_enum "$val" isolated global || { printf 'expected one of: isolated global'; return 1; }
      ;;
    CBOX_BASE_DIGEST_TTL)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer (seconds)'; return 1; }
      ;;
    CBOX_CLAUDE_MODE|CBOX_CODEX_MODE)
      _cbox_config_validate_enum "$val" mount volume || { printf 'expected one of: mount volume'; return 1; }
      ;;
    CBOX_CLAUDE_PATH|CBOX_CODEX_PATH|CBOX_VENV_PATH|CBOX_SSH_AGENT_DIR)
      [ -z "$val" ] || _cbox_config_validate_path "$val" || { printf 'expected an absolute path (or empty)'; return 1; }
      ;;
    CBOX_CLAUDE_BACKUP|CBOX_CODEX_BACKUP)
      _cbox_config_validate_enum "$val" y c n || { printf 'expected one of: y c n'; return 1; }
      ;;
    CBOX_WORKSPACES)
      local w
      for w in $val; do
        _cbox_config_validate_path "$w" || { printf 'workspace entries must be absolute paths: %s' "$w"; return 1; }
      done
      ;;
    CBOX_WORKDIR)
      [ -z "$val" ] || _cbox_config_validate_path "$val" || { printf 'expected an absolute path (or empty)'; return 1; }
      ;;
    CBOX_VENV_MODE)
      _cbox_config_validate_enum "$val" none host volume || { printf 'expected one of: none host volume'; return 1; }
      ;;
    CBOX_GPU)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_EGRESS_MODE)
      _cbox_config_validate_enum "$val" off allowlist blocklist || { printf 'expected one of: off allowlist blocklist'; return 1; }
      ;;
    CBOX_EGRESS_APPLIED)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_NETACCESS_MODE)
      _cbox_config_validate_enum "$val" off socks || { printf 'expected one of: off socks'; return 1; }
      ;;
    CBOX_NETACCESS_APPLIED)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_NETACCESS_NETWORKS)
      local n
      for n in $val; do
        case "$n" in
          [A-Za-z0-9]*) ;;
          *) printf 'invalid network name: %s' "$n"; return 1 ;;
        esac
        case "$n" in
          *[!A-Za-z0-9_.-]*) printf 'invalid network name: %s' "$n"; return 1 ;;
        esac
      done
      ;;
    CBOX_NETACCESS_CIDRS)
      command -v _cbox_is_ipv4_cidr >/dev/null 2>&1 || . "$INSTALL_DIR/templates/generators.sh"
      local c
      for c in $val; do
        if ! _cbox_is_ipv4_cidr "$c" || [ "${c%/*}" = "0.0.0.0" ]; then
          printf 'invalid IPv4 CIDR: %s' "$c"; return 1
        fi
        if [ "${c#*/}" -lt 8 ]; then
          printf 'prefix too broad (minimum /8): %s' "$c"; return 1
        fi
      done
      ;;
    CBOX_NETACCESS_SOCKS_PORT)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer (port)'; return 1; }
      [ "$val" -ge 1 ] && [ "$val" -le 65535 ] || { printf 'expected port 1..65535'; return 1; }
      ;;
    CBOX_NETACCESS_EXEC_MODE)
      _cbox_config_validate_enum "$val" off scoped || { printf 'expected one of: off scoped'; return 1; }
      ;;
    CBOX_NETACCESS_EXEC_WORKSPACE_GUARD)
      _cbox_config_validate_enum "$val" off on || { printf 'expected one of: off on'; return 1; }
      ;;
    CBOX_NETACCESS_EXEC_TIMEOUT)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
      [ "$val" -ge 1 ] && [ "$val" -le 3600 ] || { printf 'expected integer 1..3600'; return 1; }
      ;;
    CBOX_NETACCESS_EXEC_MAX_BYTES)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
      [ "$val" -ge 1024 ] && [ "$val" -le 16777216 ] || { printf 'expected integer 1024..16777216'; return 1; }
      ;;
    CBOX_HOST_ROUTE_MODE)
      _cbox_config_validate_enum "$val" off host-proxy || { printf 'expected one of: off host-proxy'; return 1; }
      ;;
    CBOX_HOST_ROUTE_APPLIED)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_HOST_PROXY_URL)
      [ -z "$val" ] || _cbox_config_validate_url "$val" || { printf 'expected an http(s):// URL (or empty)'; return 1; }
      ;;
    CBOX_HOST_PROXY_ADDR_MODE)
      _cbox_config_validate_enum "$val" host-gateway explicit || { printf 'expected one of: host-gateway explicit'; return 1; }
      ;;
    CBOX_HOST_GATEWAY_ALIAS)
      _cbox_config_validate_enum "$val" off on || { printf 'expected one of: off on'; return 1; }
      ;;
    CBOX_SSH_MODE)
      _cbox_config_validate_enum "$val" none host-agent container-keys mixed || { printf 'expected one of: none host-agent container-keys mixed'; return 1; }
      ;;
    CBOX_BASHRC)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_MCP_SERVERS|CBOX_AGENTS)
      : ;;
    CBOX_CODEX_PROGRESS_MODE)
      _cbox_config_validate_enum "$val" off shim || { printf 'expected one of: off shim'; return 1; }
      ;;
    CBOX_LOCAL_MODEL)
      _cbox_config_validate_enum "$val" off on || { printf 'expected one of: off on'; return 1; }
      ;;
    CBOX_LOCAL_MODEL_URL)
      [ -z "$val" ] || _cbox_config_validate_url "$val" || { printf 'expected an http(s):// URL (or empty)'; return 1; }
      ;;
    CBOX_LOCAL_MODEL_NAME)
      : ;;
    CBOX_HERMES)
      _cbox_config_validate_enum "$val" off on || { printf 'expected one of: off on'; return 1; }
      ;;
    CBOX_HERMES_VERSION)
      [ "$val" = latest ] || printf '%s' "$val" | grep -Eq '^[0-9]+([.][0-9]+){1,3}$' \
        || { printf 'expected latest or a plain x.y[.z[.w]] version'; return 1; }
      ;;
    CBOX_HERMES_PROVIDER)
      _cbox_config_validate_enum "$val" local nous openrouter openai anthropic || { printf 'expected one of: local nous openrouter openai anthropic'; return 1; }
      ;;
    CBOX_HERMES_MODEL_URL)
      [ -z "$val" ] || _cbox_config_validate_url "$val" || { printf 'expected an http(s):// URL (or empty)'; return 1; }
      ;;
    CBOX_HERMES_MODEL_NAME)
      : ;;
    CBOX_HERMES_DELEGATE)
      _cbox_config_validate_enum "$val" off on || { printf 'expected one of: off on'; return 1; }
      ;;
    CBOX_HERMES_DELEGATE_PROVIDER)
      [ -z "$val" ] || _cbox_config_validate_enum "$val" local nous openrouter openai anthropic || { printf 'expected one of: local nous openrouter openai anthropic (or empty)'; return 1; }
      ;;
    CBOX_HERMES_DELEGATE_BASE_URL)
      [ -z "$val" ] || _cbox_config_validate_url "$val" || { printf 'expected an http(s):// URL (or empty)'; return 1; }
      ;;
    CBOX_HERMES_DELEGATE_MODEL)
      : ;;
    CBOX_HERMES_DELEGATE_MAX_CONCURRENCY)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
      [ "$val" -ge 0 ] && [ "$val" -le 16 ] || { printf 'expected integer 0..16'; return 1; }
      ;;
    CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC)
      [ -z "$val" ] || _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer (or empty)'; return 1; }
      ;;
    CBOX_HERMES_DELEGATE_LOCK_DIR)
      [ -z "$val" ] || case "$val" in
        /*) : ;;
        *) printf 'expected an absolute path (or empty)'; return 1 ;;
      esac
      ;;
    OLLAMA_NUM_PARALLEL)
      [ -z "$val" ] || _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer (or empty)'; return 1; }
      ;;
    CBOX_HERMES_DELEGATE_MODE)
      [ -z "$val" ] || _cbox_config_validate_enum "$val" qa || { printf 'expected one of: qa (or empty)'; return 1; }
      ;;
    CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS)
      : ;;
    CBOX_LIMIT_AUTORESUME)
      _cbox_config_validate_enum "$val" off on || { printf 'expected one of: off on'; return 1; }
      ;;
    CBOX_LIMIT_RESUME_DELAY|CBOX_LIMIT_RESUME_STAGGER|CBOX_LIMIT_RESUME_MAX_PER_DAY)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
      ;;
    CBOX_LIMIT_RESUME_PROMPT)
      [ -n "$val" ] || { printf 'must not be empty'; return 1; }
      ;;
    CBOX_CODEX_MCP)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_HISTORY|CBOX_GIT|CBOX_DIARY|CBOX_OPEN_QUESTIONS)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_CONTEXT_PROFILE)
      _cbox_config_validate_enum "$val" full light || { printf 'expected one of: full light'; return 1; }
      ;;
    CBOX_GITCONFIG)
      _cbox_config_validate_enum "$val" 0 1 || { printf 'expected one of: 0 1'; return 1; }
      ;;
    CBOX_APT_EXTRA)
      local p
      for p in $val; do
        case "$p" in
          *[!A-Za-z0-9.+-]*|[.+-]*) printf 'invalid package name: %s' "$p"; return 1 ;;
        esac
      done
      ;;
    CBOX_CLAUDE_TARGET)
      printf '%s' "$val" | grep -Eq '^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$' || { printf 'expected stable, latest, or x.y.z'; return 1; }
      ;;
    CBOX_CODEX_VERSION)
      printf '%s' "$val" | grep -Eq '^(latest|[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?)$' || { printf 'expected latest or x.y.z'; return 1; }
      ;;
    CBOX_CODEX_TARGET)
      : ;;
    CBOX_BINS_SCOPE)
      _cbox_config_validate_enum "$val" global pinned || { printf 'expected one of: global pinned'; return 1; }
      ;;
    CBOX_RESTART_POLICY)
      _cbox_config_validate_enum "$val" no unless-stopped || { printf 'expected one of: no unless-stopped'; return 1; }
      ;;
    CBOX_OLLAMA_MODE)
      _cbox_config_validate_enum "$val" off on || { printf 'expected one of: off on'; return 1; }
      ;;
    CBOX_OLLAMA_IMAGE)
      [ -n "$val" ] || { printf 'must not be empty'; return 1; }
      printf '%s' "$val" | grep -Eq '^[A-Za-z0-9._:/@-]+$' || { printf 'expected an image reference matching [A-Za-z0-9._:/@-]+'; return 1; }
      ;;
    CBOX_OLLAMA_GPU)
      _cbox_config_validate_enum "$val" off cdi || { printf 'expected one of: off cdi'; return 1; }
      ;;
    CBOX_OLLAMA_STORE)
      _cbox_config_validate_enum "$val" dedicated shared || { printf 'expected one of: dedicated shared'; return 1; }
      ;;
    CBOX_OLLAMA_STORE_PATH)
      [ -z "$val" ] || _cbox_config_validate_path "$val" || { printf 'expected an absolute path (or empty)'; return 1; }
      ;;
    CBOX_OLLAMA_PORT)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer (port)'; return 1; }
      [ "$val" -ge 1 ] && [ "$val" -le 65535 ] || { printf 'expected port 1..65535'; return 1; }
      ;;
    CBOX_OLLAMA_NUM_PARALLEL)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer'; return 1; }
      [ "$val" -ge 1 ] || { printf 'expected an integer of at least 1'; return 1; }
      ;;
    CBOX_WG_MODE)
      _cbox_config_validate_enum "$val" off server client both || { printf 'expected one of: off server client both'; return 1; }
      ;;
    CBOX_WG_IMPL)
      _cbox_config_validate_enum "$val" auto kernel userspace || { printf 'expected one of: auto kernel userspace'; return 1; }
      ;;
    CBOX_WG_ADDRESS)
      [ -z "$val" ] || _cbox_is_ipv4_cidr "$val" || { printf 'expected an IPv4 address with a prefix length (e.g. 10.90.0.1/24), or empty'; return 1; }
      [ -z "$val" ] || [ "${val#*/}" -ge 8 ] || { printf 'expected a prefix length of /8 or narrower - a wider prefix would install a broad or default route on the tunnel interface'; return 1; }
      ;;
    CBOX_WG_LISTEN_PORT)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer (port)'; return 1; }
      [ "$val" -ge 1 ] && [ "$val" -le 65535 ] || { printf 'expected port 1..65535'; return 1; }
      ;;
    CBOX_WG_PUBLISH_ADDR)
      [ -z "$val" ] || _cbox_is_ipv4 "$val" || { printf 'expected a literal IPv4 address, or empty for all addresses'; return 1; }
      ;;
    CBOX_WG_PEER_ENDPOINT)
      [ -z "$val" ] || _cbox_wg_hostport_ok "$val" || { printf 'expected host:port'; return 1; }
      ;;
    CBOX_WG_PEER_PUBKEY)
      [ -z "$val" ] || _cbox_wg_pubkey_ok "$val" || { printf 'expected a 44-character base64 WireGuard public key, or empty'; return 1; }
      ;;
    CBOX_WG_PEER_ADDRESS)
      [ -z "$val" ] || _cbox_is_ipv4_cidr "$val" || { printf 'expected an IPv4 address with a prefix length, or empty'; return 1; }
      [ -z "$val" ] || [ "${val#*/}" -eq 32 ] || { printf 'expected a single host address (/32) - a wider AllowedIPs would route more than the remote endpoint over the tunnel'; return 1; }
      ;;
    CBOX_WG_KEEPALIVE)
      _cbox_config_validate_uint "$val" || { printf 'expected a non-negative integer (seconds, 0 disables)'; return 1; }
      ;;
    *)
      printf 'no validator registered for %s' "$key"; return 1
      ;;
  esac
  return 0
}
