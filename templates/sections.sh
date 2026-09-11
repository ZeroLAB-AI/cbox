SECTIONS=(mode mounts workspaces python gpu egress netaccess hostroute ssh bashrc mcp-servers codex-progress local-model hermes hermes-delegate ollama wireguard autoresume agents codex-mcp continuity claude-md settings hooks git-identity apt-extra binaries restart-policy autoupdate dns clipboard kernel-lang user-layer)

sec_get() {
  case "$1" in
    SEC_TITLE)
      case "$2" in
        mode)
          printf '%s\n' 'Mode'
          ;;
        mounts)
          printf '%s\n' 'Mounts'
          ;;
        workspaces)
          printf '%s\n' 'Workspaces'
          ;;
        python)
          printf '%s\n' 'Python venv'
          ;;
        gpu)
          printf '%s\n' 'GPU'
          ;;
        egress)
          printf '%s\n' 'Egress'
          ;;
        netaccess)
          printf '%s\n' 'Container network access'
          ;;
        hostroute)
          printf '%s\n' 'Host route'
          ;;
        ssh)
          printf '%s\n' 'SSH'
          ;;
        bashrc)
          printf '%s\n' 'Shell functions'
          ;;
        mcp-servers)
          printf '%s\n' 'MCP servers'
          ;;
        codex-progress)
          printf '%s\n' 'Codex progress relay'
          ;;
        local-model)
          printf '%s\n' 'Local model'
          ;;
        hermes)
          printf '%s\n' 'Hermes engine'
          ;;
        hermes-delegate)
          printf '%s\n' 'Hermes MCP delegate'
          ;;
        ollama)
          printf '%s\n' 'Ollama (machine-scoped)'
          ;;
        wireguard)
          printf '%s\n' 'WireGuard (machine-scoped)'
          ;;
        autoresume)
          printf '%s\n' 'Session-limit auto-resume'
          ;;
        agents)
          printf '%s\n' 'Agents'
          ;;
        codex-mcp)
          printf '%s\n' 'Codex MCP'
          ;;
        continuity)
          printf '%s\n' 'Continuity'
          ;;
        claude-md)
          printf '%s\n' 'CLAUDE.md'
          ;;
        settings)
          printf '%s\n' 'Settings'
          ;;
        hooks)
          printf '%s\n' 'Hooks'
          ;;
        git-identity)
          printf '%s\n' 'Git identity'
          ;;
        apt-extra)
          printf '%s\n' 'APT packages'
          ;;
        binaries)
          printf '%s\n' 'Binaries'
          ;;
        restart-policy)
          printf '%s\n' 'Restart policy'
          ;;
        autoupdate)
          printf '%s\n' 'Engine autoupdate'
          ;;
        dns)
          printf '%s\n' 'DNS'
          ;;
        clipboard)
          printf '%s\n' 'Clipboard image bridge'
          ;;
        kernel-lang)
          printf '%s\n' 'Conduct kernel language rule'
          ;;
        user-layer)
          printf '%s\n' 'User extension layer'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_DESC)
      case "$2" in
        mode)
          printf '%s\n' 'Container mode: one shared global container, or one container per project.'
          ;;
        mounts)
          printf '%s\n' 'How ~/.claude and ~/.codex reach the container: bind mount a host dir, or use a volume.'
          ;;
        workspaces)
          printf '%s\n' 'Project directories mounted 1:1 read-write; defines the codex guard scope roots.'
          ;;
        python)
          printf '%s\n' 'Python venv source: none (only python3 in image), a read-only host mount, or a volume.'
          ;;
        gpu)
          printf '%s\n' 'Enable GPU support via CDI; checks for nvidia-ctk and the CDI spec on the host.'
          ;;
        egress)
          printf '%s\n' 'Network egress policy: off, allowlist, or blocklist of domains; applied after login.'
          ;;
        netaccess)
          printf '%s\n' 'Reach Docker networks through Dante SOCKS; optional host-side exec bridge runs tests only in containers on explicit scope=list networks and never mounts docker.sock into cbox.'
          ;;
        hostroute)
          printf '%s\n' 'Route container egress through a host-managed forward proxy so host /etc/hosts and host DNS resolution are honored; optional host-gateway alias maps host.docker.internal for direct host-side endpoints.'
          ;;
        ssh)
          printf '%s\n' 'SSH access mode: none, forwarded host agent, container-generated keys, or both.'
          ;;
        bashrc)
          printf '%s\n' 'Install shell functions (~/.bashrc-cbox) plus a marker block in ~/.bashrc.'
          ;;
        mcp-servers)
          printf '%s\n' 'Select which MCP delegates from delegates.json are available in the container.'
          ;;
        codex-progress)
          printf '%s\n' 'Wrap codex-* MCP servers in a shim that translates codex events into MCP progress notifications - codex output shows live in the Claude UI.'
          ;;
        local-model)
          printf '%s\n' 'Off by default. A text-only MCP delegate (local-qwen) backed by a local OpenAI-compatible endpoint such as ollama - see etc/docs/LOCAL_MODEL_RUNBOOK.md. Machine-scoped: the endpoint is a fact about this host, not about a project, so it is configured once and every project on the machine reads the same value.'
          ;;
        hermes)
          printf '%s\n' 'Off by default; third console engine (NousResearch Hermes Agent) installed at runtime into the shared bins volume; local OpenAI-compatible endpoint by default.'
          ;;
        hermes-delegate)
          printf '%s\n' 'Off by default. A zero-cost MCP delegate tool (hermes-local) that shells out to a one-shot hermes -z call per invocation, in an ephemeral per-call home isolated from the hermes console engine; requires the hermes console engine.'
          ;;
        ollama)
          printf '%s\n' 'Off by default. Machine-scoped infra service: ollama runs in its own owner compose project (cbox-infra-u<uid>), never inside a generated cbox project, so it survives per-project compose down. One value applies to every project on this machine; the isolated per-project wizard never asks about it.'
          ;;
        wireguard)
          printf '%s\n' 'Off by default. Machine-scoped WireGuard sidecar in the same owner project as ollama: server mode shares this machine ollama over one authenticated UDP port (no routing, no NAT, no IP forwarding - a single-service TCP forwarder only); client mode dials a remote peer and exposes it under a stable internal alias. One value applies to every project on this machine; the isolated per-project wizard never asks about it.'
          ;;
        autoresume)
          printf '%s\n' 'Wrap interactive sessions in tmux and let a per-container watchdog type the resume prompt after a usage-limit window resets (isolated session scope + claude mount only). Also carries the in-container sshd remote-attach feature (disabled by default): three layers - WireGuard, an ssh key, and this container'\''s access level - gate list/attach/spawn against the tmux sessions the wrap creates.'
          ;;
        agents)
          printf '%s\n' 'Select which agents from etc/agents are installed; codex-* need their MCP server.'
          ;;
        codex-mcp)
          printf '%s\n' 'Register claude as an MCP tool inside codex for reverse orchestration.'
          ;;
        continuity)
          printf '%s\n' 'Durable-continuity toggles: history, git changelog, diary, open questions.'
          ;;
        claude-md)
          printf '%s\n' 'Deploy CLAUDE.md plus policies and templates; skipped when history is disabled.'
          ;;
        settings)
          printf '%s\n' 'Merge etc/claude/settings.merge.json into the effective ~/.claude/settings.json.'
          ;;
        hooks)
          printf '%s\n' 'Install hook scripts (codex guard, ask-claude MCP bridge) into ~/.claude/hooks.'
          ;;
        git-identity)
          printf '%s\n' 'Mount the host ~/.gitconfig read-only into the container.'
          ;;
        apt-extra)
          printf '%s\n' 'Extra apt packages installed into the image at build time.'
          ;;
        binaries)
          printf '%s\n' 'Claude/codex version pins and the shared binary volumes; installs run host-side, runtime mounts are read-only.'
          ;;
        restart-policy)
          printf '%s\n' 'Docker restart policy applied to the container.'
          ;;
        autoupdate)
          printf '%s\n' 'Host-side engine autoupdate for channel targets (claude stable/latest, codex latest, hermes latest): re-runs the vendor installer once the TTL elapses.'
          ;;
        dns)
          printf '%s\n' 'DNS resolution inside the container when egress is enabled: Docker embedded DNS, public resolvers, or a host-stable stub resolver IP.'
          ;;
        clipboard)
          printf '%s\n' 'Host clipboard image bridge over a unix socket answering Claude Code'\''s Ctrl+V image paste inside the container.'
          ;;
        kernel-lang)
          printf '%s\n' 'Two-part language rule rendered into the deployed conduct kernel: reason in one language, answer in another. Off (output language empty) by default - the rule is not rendered until an output language is set.'
          ;;
        user-layer)
          printf '%s\n' 'Host directory mounted read-only into the container at /etc/cbox/user, letting a user drop their own MCP server declarations (user/mcp/*.json) without touching cbox-owned config. cbox never writes under this directory - only the directory itself is created if missing.'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_VARS)
      case "$2" in
        mode)
          printf '%s\n' 'CBOX_MODE CBOX_SESSION_SCOPE CBOX_BASE_DIGEST_TTL'
          ;;
        mounts)
          printf '%s\n' 'CBOX_CLAUDE_MODE CBOX_CLAUDE_PATH CBOX_CLAUDE_BACKUP CBOX_CODEX_MODE CBOX_CODEX_PATH CBOX_CODEX_BACKUP CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG'
          ;;
        workspaces)
          printf '%s\n' 'CBOX_WORKSPACES CBOX_WORKDIR'
          ;;
        python)
          printf '%s\n' 'CBOX_VENV_MODE CBOX_VENV_PATH'
          ;;
        gpu)
          printf '%s\n' 'CBOX_GPU'
          ;;
        egress)
          printf '%s\n' 'CBOX_EGRESS_MODE CBOX_EGRESS_APPLIED'
          ;;
        netaccess)
          printf '%s\n' 'CBOX_NETACCESS_MODE CBOX_NETACCESS_APPLIED CBOX_NETACCESS_SCOPE CBOX_NETACCESS_NETWORKS CBOX_NETACCESS_CIDRS CBOX_NETACCESS_SOCKS_PORT CBOX_NETACCESS_EXEC_MODE CBOX_NETACCESS_EXEC_WORKSPACE_GUARD CBOX_NETACCESS_EXEC_TIMEOUT CBOX_NETACCESS_EXEC_MAX_BYTES CBOX_CONTAINER_EXEC_TOOL'
          ;;
        hostroute)
          printf '%s\n' 'CBOX_HOST_ROUTE_MODE CBOX_HOST_ROUTE_APPLIED CBOX_HOST_PROXY_URL CBOX_HOST_PROXY_ADDR_MODE CBOX_HOST_GATEWAY_ALIAS'
          ;;
        ssh)
          printf '%s\n' 'CBOX_SSH_MODE CBOX_SSH_AGENT_DIR'
          ;;
        bashrc)
          printf '%s\n' 'CBOX_BASHRC CBOX_BASHRC_COMMANDS'
          ;;
        mcp-servers)
          printf '%s\n' 'CBOX_MCP_SERVERS'
          ;;
        codex-progress)
          printf '%s\n' 'CBOX_CODEX_PROGRESS_MODE'
          ;;
        local-model)
          printf '%s\n' 'CBOX_LOCAL_MODEL CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME CBOX_LOCAL_MODEL_TIMEOUT_SEC'
          ;;
        hermes)
          printf '%s\n' 'CBOX_HERMES CBOX_HERMES_VERSION CBOX_HERMES_PROVIDER CBOX_HERMES_EFFORT CBOX_HERMES_MODEL_URL CBOX_HERMES_MODEL_NAME CBOX_HERMES_HOOKS'
          ;;
        hermes-delegate)
          printf '%s\n' 'CBOX_HERMES_DELEGATE CBOX_HERMES_DELEGATE_PROVIDER CBOX_HERMES_DELEGATE_BASE_URL CBOX_HERMES_DELEGATE_MODEL CBOX_HERMES_DELEGATE_MAX_CONCURRENCY CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC CBOX_HERMES_DELEGATE_LOCK_DIR OLLAMA_NUM_PARALLEL CBOX_HERMES_DELEGATE_MODE CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS'
          ;;
        ollama)
          printf '%s\n' 'CBOX_OLLAMA_MODE CBOX_OLLAMA_IMAGE CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE CBOX_OLLAMA_STORE_PATH CBOX_OLLAMA_PORT CBOX_OLLAMA_NUM_PARALLEL CBOX_OLLAMA_CONTEXT_LENGTH CBOX_OLLAMA_FLASH_ATTENTION CBOX_OLLAMA_KV_CACHE_TYPE CBOX_OLLAMA_KEEP_ALIVE'
          ;;
        wireguard)
          printf '%s\n' 'CBOX_WG_MODE CBOX_WG_IMPL CBOX_WG_ADDRESS CBOX_WG_LISTEN_PORT CBOX_WG_PUBLISH_ADDR CBOX_WG_PEER_ENDPOINT CBOX_WG_PEER_PUBKEY CBOX_WG_PEER_ADDRESS CBOX_WG_KEEPALIVE CBOX_WG_FORWARDS'
          ;;
        autoresume)
          printf '%s\n' 'CBOX_LIMIT_AUTORESUME CBOX_SESSION_MULTIPLEX CBOX_SAFEGUARD_AUTOCONFIRM CBOX_SESSION_BROKER_MODE CBOX_SSHD_LISTEN_ADDR CBOX_SSHD_PORT CBOX_LIMIT_RESUME_DELAY CBOX_LIMIT_RESUME_PROMPT CBOX_LIMIT_RESUME_STAGGER CBOX_LIMIT_RESUME_MAX_PER_DAY'
          ;;
        agents)
          printf '%s\n' 'CBOX_AGENTS'
          ;;
        codex-mcp)
          printf '%s\n' 'CBOX_CODEX_MCP CBOX_CODEX_HOOKS CBOX_CODEX_MODEL CBOX_CODEX_EFFORT'
          ;;
        continuity)
          printf '%s\n' 'CBOX_HISTORY CBOX_GIT CBOX_DIARY CBOX_OPEN_QUESTIONS CBOX_CONTEXT_PROFILE'
          ;;
        claude-md)
          printf '%s\n' ''
          ;;
        settings)
          printf '%s\n' ''
          ;;
        hooks)
          printf '%s\n' ''
          ;;
        git-identity)
          printf '%s\n' 'CBOX_GITCONFIG'
          ;;
        apt-extra)
          printf '%s\n' 'CBOX_APT_EXTRA'
          ;;
        binaries)
          printf '%s\n' 'CBOX_CLAUDE_TARGET CBOX_CODEX_VERSION CBOX_CODEX_TARGET CBOX_BINS_SCOPE'
          ;;
        restart-policy)
          printf '%s\n' 'CBOX_RESTART_POLICY'
          ;;
        autoupdate)
          printf '%s\n' 'CBOX_AUTOUPDATE CBOX_AUTOUPDATE_TTL_HOURS'
          ;;
        dns)
          printf '%s\n' 'CBOX_DNS_MODE CBOX_DNS_SERVERS CBOX_DNS_STUB_IP'
          ;;
        clipboard)
          printf '%s\n' 'CBOX_CLIPBOARD_MODE'
          ;;
        kernel-lang)
          printf '%s\n' 'CBOX_KERNEL_LANG_OUTPUT CBOX_KERNEL_LANG_REASONING'
          ;;
        user-layer)
          printf '%s\n' 'CBOX_USER_DIR'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_APPLY)
      case "$2" in
        mode)
          printf '%s\n' 'none'
          ;;
        mounts)
          printf '%s\n' 'recreate'
          ;;
        workspaces)
          printf '%s\n' 'recreate'
          ;;
        python)
          printf '%s\n' 'recreate'
          ;;
        gpu)
          printf '%s\n' 'none'
          ;;
        egress)
          printf '%s\n' 'topology'
          ;;
        netaccess)
          printf '%s\n' 'topology'
          ;;
        hostroute)
          printf '%s\n' 'topology'
          ;;
        ssh)
          printf '%s\n' 'recreate'
          ;;
        bashrc)
          printf '%s\n' 'shell'
          ;;
        mcp-servers)
          printf '%s\n' 'restart'
          ;;
        codex-progress)
          printf '%s\n' 'restart'
          ;;
        local-model)
          printf '%s\n' 'restart'
          ;;
        hermes)
          printf '%s\n' 'recreate'
          ;;
        hermes-delegate)
          printf '%s\n' 'restart'
          ;;
        ollama)
          printf '%s\n' 'infra-reconcile'
          ;;
        wireguard)
          printf '%s\n' 'infra-reconcile'
          ;;
        autoresume)
          printf '%s\n' 'recreate'
          ;;
        agents)
          printf '%s\n' 'none'
          ;;
        codex-mcp)
          printf '%s\n' 'none'
          ;;
        continuity)
          printf '%s\n' 'none'
          ;;
        claude-md)
          printf '%s\n' 'none'
          ;;
        settings)
          printf '%s\n' 'restart'
          ;;
        hooks)
          printf '%s\n' 'restart'
          ;;
        git-identity)
          printf '%s\n' 'recreate'
          ;;
        apt-extra)
          printf '%s\n' 'rebuild'
          ;;
        binaries)
          printf '%s\n' 'rebuild'
          ;;
        restart-policy)
          printf '%s\n' 'recreate'
          ;;
        autoupdate)
          printf '%s\n' 'none'
          ;;
        dns)
          printf '%s\n' 'recreate'
          ;;
        clipboard)
          printf '%s\n' 'recreate'
          ;;
        kernel-lang)
          printf '%s\n' 'none'
          ;;
        user-layer)
          printf '%s\n' 'recreate'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_PROFILE)
      case "$2" in
        mode)
          printf '%s\n' 'ask'
          ;;
        mounts)
          printf '%s\n' 'ask'
          ;;
        workspaces)
          printf '%s\n' 'ask'
          ;;
        python)
          printf '%s\n' 'skip'
          ;;
        gpu)
          printf '%s\n' 'skip'
          ;;
        egress)
          printf '%s\n' 'skip'
          ;;
        netaccess)
          printf '%s\n' 'skip'
          ;;
        hostroute)
          printf '%s\n' 'skip'
          ;;
        ssh)
          printf '%s\n' 'skip'
          ;;
        bashrc)
          printf '%s\n' 'auto'
          ;;
        mcp-servers)
          printf '%s\n' 'skip'
          ;;
        codex-progress)
          printf '%s\n' 'skip'
          ;;
        local-model)
          printf '%s\n' 'skip'
          ;;
        hermes)
          printf '%s\n' 'skip'
          ;;
        hermes-delegate)
          printf '%s\n' 'skip'
          ;;
        ollama)
          printf '%s\n' 'skip'
          ;;
        wireguard)
          printf '%s\n' 'skip'
          ;;
        autoresume)
          printf '%s\n' 'skip'
          ;;
        agents)
          printf '%s\n' 'skip'
          ;;
        codex-mcp)
          printf '%s\n' 'skip'
          ;;
        continuity)
          printf '%s\n' 'auto'
          ;;
        claude-md)
          printf '%s\n' 'auto'
          ;;
        settings)
          printf '%s\n' 'auto'
          ;;
        hooks)
          printf '%s\n' 'auto'
          ;;
        git-identity)
          printf '%s\n' 'auto'
          ;;
        apt-extra)
          printf '%s\n' 'skip'
          ;;
        binaries)
          printf '%s\n' 'skip'
          ;;
        restart-policy)
          printf '%s\n' 'auto'
          ;;
        autoupdate)
          printf '%s\n' 'skip'
          ;;
        dns)
          printf '%s\n' 'skip'
          ;;
        clipboard)
          printf '%s\n' 'skip'
          ;;
        kernel-lang)
          printf '%s\n' 'skip'
          ;;
        user-layer)
          printf '%s\n' 'skip'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_SCOPE)
      case "$2" in
        mode)
          printf '%s\n' 'project'
          ;;
        mounts)
          printf '%s\n' 'project'
          ;;
        workspaces)
          printf '%s\n' 'project'
          ;;
        python)
          printf '%s\n' 'project'
          ;;
        gpu)
          printf '%s\n' 'project'
          ;;
        egress)
          printf '%s\n' 'project'
          ;;
        netaccess)
          printf '%s\n' 'project'
          ;;
        hostroute)
          printf '%s\n' 'project'
          ;;
        ssh)
          printf '%s\n' 'project'
          ;;
        bashrc)
          printf '%s\n' 'project'
          ;;
        mcp-servers)
          printf '%s\n' 'project'
          ;;
        codex-progress)
          printf '%s\n' 'project'
          ;;
        local-model)
          printf '%s\n' 'machine'
          ;;
        hermes)
          printf '%s\n' 'project'
          ;;
        hermes-delegate)
          printf '%s\n' 'project'
          ;;
        ollama)
          printf '%s\n' 'machine'
          ;;
        wireguard)
          printf '%s\n' 'machine'
          ;;
        autoresume)
          printf '%s\n' 'project'
          ;;
        agents)
          printf '%s\n' 'project'
          ;;
        codex-mcp)
          printf '%s\n' 'project'
          ;;
        continuity)
          printf '%s\n' 'project'
          ;;
        claude-md)
          printf '%s\n' 'project'
          ;;
        settings)
          printf '%s\n' 'project'
          ;;
        hooks)
          printf '%s\n' 'project'
          ;;
        git-identity)
          printf '%s\n' 'project'
          ;;
        apt-extra)
          printf '%s\n' 'project'
          ;;
        binaries)
          printf '%s\n' 'project'
          ;;
        restart-policy)
          printf '%s\n' 'project'
          ;;
        autoupdate)
          printf '%s\n' 'project'
          ;;
        dns)
          printf '%s\n' 'project'
          ;;
        clipboard)
          printf '%s\n' 'project'
          ;;
        kernel-lang)
          printf '%s\n' 'project'
          ;;
        user-layer)
          printf '%s\n' 'project'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_DEPS)
      case "$2" in
        gpu)
          printf '%s\n' 'disable:no-cdi'
          ;;
        codex-progress)
          printf '%s\n' 'dictate:shim-hook'
          ;;
        hermes-delegate)
          printf '%s\n' 'disable:hermes-off'
          ;;
        codex-mcp)
          printf '%s\n' 'dictate:hooks'
          ;;
        continuity)
          printf '%s\n' 'dictate:continuity-hooks'
          ;;
        restart-policy)
          printf '%s\n' 'disable:isolated-mode'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_DEP_TEXT)
      case "$2" in
        disable:no-cdi)
          printf '%s\n' 'disabled until nvidia-ctk and /etc/cdi/nvidia.yaml are present'
          ;;
        dictate:shim-hook)
          printf '%s\n' 'auto-deploys the codex_mcp_shim hook when enabled'
          ;;
        disable:hermes-off)
          printf '%s\n' 'disabled until the hermes console engine (CBOX_HERMES=on) is enabled'
          ;;
        dictate:hooks)
          printf '%s\n' 'auto-deploys the ask-claude hook when enabled'
          ;;
        dictate:continuity-hooks)
          printf '%s\n' 'history=1 auto-deploys the continuity hooks (commit log, ledger sweep, session digest)'
          ;;
        disable:isolated-mode)
          printf '%s\n' 'disabled in isolated mode - container lifecycle managed per-project'
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    SEC_DOCTOR_ROWS)
      case "$2" in
        mounts)
          printf '%s\n' ''
          ;;
        workspaces)
          printf '%s\n' ''
          ;;
        python)
          printf '%s\n' ''
          ;;
        netaccess)
          printf '%s\n' 'netaccess container-exec container-exec-tool'
          ;;
        bashrc)
          printf '%s\n' ''
          ;;
        mcp-servers)
          printf '%s\n' ''
          ;;
        ollama)
          printf '%s\n' 'ollama'
          ;;
        wireguard)
          printf '%s\n' 'wireguard'
          ;;
        autoresume)
          printf '%s\n' 'session-broker'
          ;;
        agents)
          printf '%s\n' ''
          ;;
        continuity)
          printf '%s\n' 'continuity-brain history git-changelog diary open-questions context-profile'
          ;;
        claude-md)
          printf '%s\n' ''
          ;;
        hooks)
          printf '%s\n' 'sessionstart-hooks'
          ;;
        apt-extra)
          printf '%s\n' ''
          ;;
        binaries)
          printf '%s\n' ''
          ;;
        restart-policy)
          printf '%s\n' ''
          ;;
        autoupdate)
          printf '%s\n' ''
          ;;
        dns)
          printf '%s\n' ''
          ;;
        clipboard)
          printf '%s\n' 'clipboard'
          ;;
        kernel-lang)
          printf '%s\n' ''
          ;;
        user-layer)
          printf '%s\n' ''
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      return 0
      ;;
  esac
}

sec_has() {
  case "$1" in
    SEC_TITLE)
      case "$2" in
        mode|mounts|workspaces|python|gpu|egress|netaccess|hostroute|ssh|bashrc|mcp-servers|codex-progress|local-model|hermes|hermes-delegate|ollama|wireguard|autoresume|agents|codex-mcp|continuity|claude-md|settings|hooks|git-identity|apt-extra|binaries|restart-policy|autoupdate|dns|clipboard|kernel-lang|user-layer)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_DESC)
      case "$2" in
        mode|mounts|workspaces|python|gpu|egress|netaccess|hostroute|ssh|bashrc|mcp-servers|codex-progress|local-model|hermes|hermes-delegate|ollama|wireguard|autoresume|agents|codex-mcp|continuity|claude-md|settings|hooks|git-identity|apt-extra|binaries|restart-policy|autoupdate|dns|clipboard|kernel-lang|user-layer)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_VARS)
      case "$2" in
        mode|mounts|workspaces|python|gpu|egress|netaccess|hostroute|ssh|bashrc|mcp-servers|codex-progress|local-model|hermes|hermes-delegate|ollama|wireguard|autoresume|agents|codex-mcp|continuity|claude-md|settings|hooks|git-identity|apt-extra|binaries|restart-policy|autoupdate|dns|clipboard|kernel-lang|user-layer)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_APPLY)
      case "$2" in
        mode|mounts|workspaces|python|gpu|egress|netaccess|hostroute|ssh|bashrc|mcp-servers|codex-progress|local-model|hermes|hermes-delegate|ollama|wireguard|autoresume|agents|codex-mcp|continuity|claude-md|settings|hooks|git-identity|apt-extra|binaries|restart-policy|autoupdate|dns|clipboard|kernel-lang|user-layer)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_PROFILE)
      case "$2" in
        mode|mounts|workspaces|python|gpu|egress|netaccess|hostroute|ssh|bashrc|mcp-servers|codex-progress|local-model|hermes|hermes-delegate|ollama|wireguard|autoresume|agents|codex-mcp|continuity|claude-md|settings|hooks|git-identity|apt-extra|binaries|restart-policy|autoupdate|dns|clipboard|kernel-lang|user-layer)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_SCOPE)
      case "$2" in
        mode|mounts|workspaces|python|gpu|egress|netaccess|hostroute|ssh|bashrc|mcp-servers|codex-progress|local-model|hermes|hermes-delegate|ollama|wireguard|autoresume|agents|codex-mcp|continuity|claude-md|settings|hooks|git-identity|apt-extra|binaries|restart-policy|autoupdate|dns|clipboard|kernel-lang|user-layer)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_DEPS)
      case "$2" in
        gpu|codex-progress|hermes-delegate|codex-mcp|continuity|restart-policy)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_DEP_TEXT)
      case "$2" in
        disable:no-cdi|dictate:shim-hook|disable:hermes-off|dictate:hooks|dictate:continuity-hooks|disable:isolated-mode)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    SEC_DOCTOR_ROWS)
      case "$2" in
        mounts|workspaces|python|netaccess|bashrc|mcp-servers|ollama|wireguard|autoresume|agents|continuity|claude-md|hooks|apt-extra|binaries|restart-policy|autoupdate|dns|clipboard|kernel-lang|user-layer)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

sec_keys() {
  case "$1" in
    SEC_TITLE)
      printf '%s\n' 'mode' 'mounts' 'workspaces' 'python' 'gpu' 'egress' 'netaccess' 'hostroute' 'ssh' 'bashrc' 'mcp-servers' 'codex-progress' 'local-model' 'hermes' 'hermes-delegate' 'ollama' 'wireguard' 'autoresume' 'agents' 'codex-mcp' 'continuity' 'claude-md' 'settings' 'hooks' 'git-identity' 'apt-extra' 'binaries' 'restart-policy' 'autoupdate' 'dns' 'clipboard' 'kernel-lang' 'user-layer'
      ;;
    SEC_DESC)
      printf '%s\n' 'mode' 'mounts' 'workspaces' 'python' 'gpu' 'egress' 'netaccess' 'hostroute' 'ssh' 'bashrc' 'mcp-servers' 'codex-progress' 'local-model' 'hermes' 'hermes-delegate' 'ollama' 'wireguard' 'autoresume' 'agents' 'codex-mcp' 'continuity' 'claude-md' 'settings' 'hooks' 'git-identity' 'apt-extra' 'binaries' 'restart-policy' 'autoupdate' 'dns' 'clipboard' 'kernel-lang' 'user-layer'
      ;;
    SEC_VARS)
      printf '%s\n' 'mode' 'mounts' 'workspaces' 'python' 'gpu' 'egress' 'netaccess' 'hostroute' 'ssh' 'bashrc' 'mcp-servers' 'codex-progress' 'local-model' 'hermes' 'hermes-delegate' 'ollama' 'wireguard' 'autoresume' 'agents' 'codex-mcp' 'continuity' 'claude-md' 'settings' 'hooks' 'git-identity' 'apt-extra' 'binaries' 'restart-policy' 'autoupdate' 'dns' 'clipboard' 'kernel-lang' 'user-layer'
      ;;
    SEC_APPLY)
      printf '%s\n' 'mode' 'mounts' 'workspaces' 'python' 'gpu' 'egress' 'netaccess' 'hostroute' 'ssh' 'bashrc' 'mcp-servers' 'codex-progress' 'local-model' 'hermes' 'hermes-delegate' 'ollama' 'wireguard' 'autoresume' 'agents' 'codex-mcp' 'continuity' 'claude-md' 'settings' 'hooks' 'git-identity' 'apt-extra' 'binaries' 'restart-policy' 'autoupdate' 'dns' 'clipboard' 'kernel-lang' 'user-layer'
      ;;
    SEC_PROFILE)
      printf '%s\n' 'mode' 'mounts' 'workspaces' 'python' 'gpu' 'egress' 'netaccess' 'hostroute' 'ssh' 'bashrc' 'mcp-servers' 'codex-progress' 'local-model' 'hermes' 'hermes-delegate' 'ollama' 'wireguard' 'autoresume' 'agents' 'codex-mcp' 'continuity' 'claude-md' 'settings' 'hooks' 'git-identity' 'apt-extra' 'binaries' 'restart-policy' 'autoupdate' 'dns' 'clipboard' 'kernel-lang' 'user-layer'
      ;;
    SEC_SCOPE)
      printf '%s\n' 'mode' 'mounts' 'workspaces' 'python' 'gpu' 'egress' 'netaccess' 'hostroute' 'ssh' 'bashrc' 'mcp-servers' 'codex-progress' 'local-model' 'hermes' 'hermes-delegate' 'ollama' 'wireguard' 'autoresume' 'agents' 'codex-mcp' 'continuity' 'claude-md' 'settings' 'hooks' 'git-identity' 'apt-extra' 'binaries' 'restart-policy' 'autoupdate' 'dns' 'clipboard' 'kernel-lang' 'user-layer'
      ;;
    SEC_DEPS)
      printf '%s\n' 'gpu' 'codex-progress' 'hermes-delegate' 'codex-mcp' 'continuity' 'restart-policy'
      ;;
    SEC_DEP_TEXT)
      printf '%s\n' 'disable:no-cdi' 'dictate:shim-hook' 'disable:hermes-off' 'dictate:hooks' 'dictate:continuity-hooks' 'disable:isolated-mode'
      ;;
    SEC_DOCTOR_ROWS)
      printf '%s\n' 'mounts' 'workspaces' 'python' 'netaccess' 'bashrc' 'mcp-servers' 'ollama' 'wireguard' 'autoresume' 'agents' 'continuity' 'claude-md' 'hooks' 'apt-extra' 'binaries' 'restart-policy' 'autoupdate' 'dns' 'clipboard' 'kernel-lang' 'user-layer'
      ;;
    *)
      return 0
      ;;
  esac
}

DOCTOR_EXTRA_ROWS='codex-profile context-manifest local-model local-model-egress managed-dirs config-pending sessions capabilities stale-binds'
