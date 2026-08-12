_cbox_reg_validate_var() {
  local _cbox_val_had_f=0 _cbox_val_rc=0
  case $- in *f*) _cbox_val_had_f=1 ;; esac
  set -f
  _cbox_reg_validate_var_dispatch "$@" || _cbox_val_rc=$?
  [ "$_cbox_val_had_f" = 1 ] || set +f
  return "$_cbox_val_rc"
}

_cbox_reg_validate_var_dispatch() {
  local key="$1" val="$2"
  _cbox_val_no_ctrl "$val" || { printf 'contains a control character'; return 1; }
  case "$key" in
    CBOX_MODE)
      _cbox_val_kind_enum "$val" 'global' 'isolated' || return 1
      ;;
    CBOX_SESSION_SCOPE)
      _cbox_val_kind_enum "$val" 'isolated' 'global' || return 1
      ;;
    CBOX_BASE_DIGEST_TTL)
      _cbox_val_kind_uint "$val" || return 1
      ;;
    CBOX_NAME)
      _cbox_val_kind_nonempty_string "$val" || return 1
      ;;
    CBOX_CLAUDE_MODE)
      _cbox_val_kind_enum "$val" 'mount' 'volume' || return 1
      ;;
    CBOX_CLAUDE_PATH)
      _cbox_val_kind_path_or_empty "$val" || return 1
      ;;
    CBOX_CLAUDE_BACKUP)
      _cbox_val_kind_enum "$val" 'y' 'c' 'n' || return 1
      ;;
    CBOX_CODEX_MODE)
      _cbox_val_kind_enum "$val" 'mount' 'volume' || return 1
      ;;
    CBOX_CODEX_PATH)
      _cbox_val_kind_path_or_empty "$val" || return 1
      ;;
    CBOX_CODEX_BACKUP)
      _cbox_val_kind_enum "$val" 'y' 'c' 'n' || return 1
      ;;
    CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG)
      _cbox_val_kind_enum_or_empty "$val" 'on' 'off' || return 1
      ;;
    CBOX_WORKSPACES)
      _cbox_val_kind_path_list "$val" || return 1
      ;;
    CBOX_WORKDIR)
      _cbox_val_kind_path_or_empty "$val" || return 1
      ;;
    CBOX_VENV_MODE)
      _cbox_val_kind_enum "$val" 'none' 'host' 'volume' || return 1
      ;;
    CBOX_VENV_PATH)
      _cbox_val_kind_path_or_empty "$val" || return 1
      ;;
    CBOX_GPU)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_EGRESS_MODE)
      _cbox_val_kind_enum "$val" 'off' 'allowlist' 'blocklist' || return 1
      ;;
    CBOX_EGRESS_APPLIED)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_NETACCESS_MODE)
      _cbox_val_kind_enum "$val" 'off' 'socks' || return 1
      ;;
    CBOX_NETACCESS_APPLIED)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_NETACCESS_SCOPE)
      _cbox_val_named_unvalidated_legacy_gap "$key" || return 1
      ;;
    CBOX_NETACCESS_NETWORKS)
      _cbox_val_kind_network_name_list "$val" || return 1
      ;;
    CBOX_NETACCESS_CIDRS)
      _cbox_val_kind_cidr_list "$val" 8 || return 1
      ;;
    CBOX_NETACCESS_SOCKS_PORT)
      _cbox_val_kind_port "$val" || return 1
      ;;
    CBOX_NETACCESS_EXEC_MODE)
      _cbox_val_kind_enum "$val" 'off' 'scoped' || return 1
      ;;
    CBOX_NETACCESS_EXEC_WORKSPACE_GUARD)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_NETACCESS_EXEC_TIMEOUT)
      _cbox_val_kind_uint_range "$val" 1 3600 || return 1
      ;;
    CBOX_NETACCESS_EXEC_MAX_BYTES)
      _cbox_val_kind_uint_range "$val" 1024 16777216 || return 1
      ;;
    CBOX_CONTAINER_EXEC_TOOL)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_HOST_ROUTE_MODE)
      _cbox_val_kind_enum "$val" 'off' 'host-proxy' || return 1
      ;;
    CBOX_HOST_ROUTE_APPLIED)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_HOST_PROXY_URL)
      _cbox_val_kind_url_or_empty "$val" || return 1
      ;;
    CBOX_HOST_PROXY_ADDR_MODE)
      _cbox_val_kind_enum "$val" 'host-gateway' 'explicit' || return 1
      ;;
    CBOX_HOST_GATEWAY_ALIAS)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_SSH_MODE)
      _cbox_val_kind_enum "$val" 'none' 'host-agent' 'container-keys' 'mixed' || return 1
      ;;
    CBOX_SSH_AGENT_DIR)
      _cbox_val_kind_path_or_empty "$val" || return 1
      ;;
    CBOX_BASHRC)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_BASHRC_COMMANDS)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_MCP_SERVERS)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_CODEX_PROGRESS_MODE)
      _cbox_val_kind_enum "$val" 'off' 'shim' || return 1
      ;;
    CBOX_LOCAL_MODEL)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_LOCAL_MODEL_URL)
      _cbox_val_kind_url_or_empty "$val" || return 1
      ;;
    CBOX_LOCAL_MODEL_NAME)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_HERMES)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_HERMES_VERSION)
      _cbox_val_named_hermes_version "$val" || return 1
      ;;
    CBOX_HERMES_PROVIDER)
      _cbox_val_kind_enum "$val" 'local' 'nous' 'openrouter' 'openai' 'anthropic' || return 1
      ;;
    CBOX_HERMES_MODEL_URL)
      _cbox_val_kind_url_or_empty "$val" || return 1
      ;;
    CBOX_HERMES_MODEL_NAME)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_HERMES_HOOKS)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_HERMES_DELEGATE)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_HERMES_DELEGATE_PROVIDER)
      _cbox_val_kind_enum_or_empty "$val" 'local' 'nous' 'openrouter' 'openai' 'anthropic' || return 1
      ;;
    CBOX_HERMES_DELEGATE_BASE_URL)
      _cbox_val_kind_url_or_empty "$val" || return 1
      ;;
    CBOX_HERMES_DELEGATE_MODEL)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_HERMES_DELEGATE_MAX_CONCURRENCY)
      _cbox_val_kind_uint_range "$val" 0 16 || return 1
      ;;
    CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC)
      _cbox_val_kind_uint_or_empty "$val" || return 1
      ;;
    CBOX_HERMES_DELEGATE_LOCK_DIR)
      _cbox_val_named_path_slash_or_empty "$val" || return 1
      ;;
    OLLAMA_NUM_PARALLEL)
      _cbox_val_kind_uint_or_empty "$val" || return 1
      ;;
    CBOX_HERMES_DELEGATE_MODE)
      _cbox_val_kind_enum_or_empty "$val" 'qa' || return 1
      ;;
    CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_OLLAMA_MODE)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_OLLAMA_IMAGE)
      _cbox_val_named_ollama_image "$val" || return 1
      ;;
    CBOX_OLLAMA_GPU)
      _cbox_val_kind_enum "$val" 'off' 'cdi' || return 1
      ;;
    CBOX_OLLAMA_STORE)
      _cbox_val_kind_enum "$val" 'dedicated' 'shared' || return 1
      ;;
    CBOX_OLLAMA_STORE_PATH)
      _cbox_val_kind_path_or_empty "$val" || return 1
      ;;
    CBOX_OLLAMA_PORT)
      _cbox_val_kind_port "$val" || return 1
      ;;
    CBOX_OLLAMA_NUM_PARALLEL)
      _cbox_val_kind_uint_min "$val" 1 || return 1
      ;;
    CBOX_WG_MODE)
      _cbox_val_kind_enum "$val" 'off' 'server' 'client' 'both' || return 1
      ;;
    CBOX_WG_IMPL)
      _cbox_val_kind_enum "$val" 'auto' 'kernel' 'userspace' || return 1
      ;;
    CBOX_WG_ADDRESS)
      _cbox_val_named_wg_address_cidr "$val" 8 || return 1
      ;;
    CBOX_WG_LISTEN_PORT)
      _cbox_val_kind_port "$val" || return 1
      ;;
    CBOX_WG_PUBLISH_ADDR)
      _cbox_val_named_ipv4_or_empty "$val" || return 1
      ;;
    CBOX_WG_PEER_ENDPOINT)
      _cbox_val_named_wg_hostport_or_empty "$val" || return 1
      ;;
    CBOX_WG_PEER_PUBKEY)
      _cbox_val_named_wg_pubkey_or_empty "$val" || return 1
      ;;
    CBOX_WG_PEER_ADDRESS)
      _cbox_val_named_wg_peer_address_cidr "$val" || return 1
      ;;
    CBOX_WG_KEEPALIVE)
      _cbox_val_kind_uint "$val" || return 1
      ;;
    CBOX_WG_FORWARDS)
      _cbox_val_kind_wg_forward_list "$val" || return 1
      ;;
    CBOX_LIMIT_AUTORESUME)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_SESSION_MULTIPLEX)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_SAFEGUARD_AUTOCONFIRM)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_SESSION_BROKER_MODE)
      _cbox_val_kind_enum "$val" 'disabled' 'viewer' 'full-attach' || return 1
      ;;
    CBOX_SSHD_LISTEN_ADDR)
      _cbox_val_named_ipv4_or_empty "$val" || return 1
      ;;
    CBOX_SSHD_PORT)
      _cbox_val_kind_port "$val" || return 1
      ;;
    CBOX_LIMIT_RESUME_DELAY)
      _cbox_val_kind_uint "$val" || return 1
      ;;
    CBOX_LIMIT_RESUME_PROMPT)
      _cbox_val_kind_nonempty_string "$val" || return 1
      ;;
    CBOX_LIMIT_RESUME_STAGGER)
      _cbox_val_kind_uint "$val" || return 1
      ;;
    CBOX_LIMIT_RESUME_MAX_PER_DAY)
      _cbox_val_kind_uint "$val" || return 1
      ;;
    CBOX_AGENTS)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_CODEX_MCP)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_CODEX_HOOKS)
      _cbox_val_kind_enum "$val" 'off' 'on' || return 1
      ;;
    CBOX_HISTORY)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_GIT)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_DIARY)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_OPEN_QUESTIONS)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_CONTEXT_PROFILE)
      _cbox_val_kind_enum "$val" 'full' 'light' || return 1
      ;;
    CBOX_GITCONFIG)
      _cbox_val_kind_enum "$val" '0' '1' || return 1
      ;;
    CBOX_APT_EXTRA)
      _cbox_val_kind_apt_package_list "$val" || return 1
      ;;
    CBOX_CLAUDE_TARGET)
      _cbox_val_named_claude_target "$val" || return 1
      ;;
    CBOX_CODEX_VERSION)
      _cbox_val_named_codex_version "$val" || return 1
      ;;
    CBOX_CODEX_TARGET)
      _cbox_val_named_no_validator "$val" || return 1
      ;;
    CBOX_BINS_SCOPE)
      _cbox_val_kind_enum "$val" 'global' 'pinned' || return 1
      ;;
    CBOX_RESTART_POLICY)
      _cbox_val_kind_enum "$val" 'no' 'unless-stopped' || return 1
      ;;
    CBOX_AUTOUPDATE)
      _cbox_val_kind_enum "$val" 'on' 'off' || return 1
      ;;
    CBOX_AUTOUPDATE_TTL_HOURS)
      _cbox_val_kind_uint_min "$val" 0 || return 1
      ;;
    CBOX_DNS_MODE)
      _cbox_val_kind_enum "$val" 'docker' 'public' 'stub' || return 1
      ;;
    CBOX_DNS_SERVERS)
      _cbox_val_named_ipv4_list "$val" || return 1
      ;;
    CBOX_DNS_STUB_IP)
      _cbox_val_named_ipv4_or_empty "$val" || return 1
      ;;
    CBOX_CLIPBOARD_MODE)
      _cbox_val_kind_enum "$val" 'off' 'bridge' || return 1
      ;;
    CBOX_KERNEL_LANG_OUTPUT)
      _cbox_val_named_kernel_lang "$val" || return 1
      ;;
    CBOX_KERNEL_LANG_REASONING)
      _cbox_val_named_kernel_lang "$val" || return 1
      ;;
    CBOX_USER_DIR)
      _cbox_val_kind_path_or_empty "$val" || return 1
      ;;
    *)
      printf 'no validator registered for %s' "$key"; return 1
      ;;
  esac
  return 0
}
