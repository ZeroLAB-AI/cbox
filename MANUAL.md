# cbox setup and operation manual

Complete reference for installing, configuring, and operating cbox. Start with the quick-start in README.md; come here for detail.

## Setup wizard sections

Run `./setup.sh` to open the interactive wizard. Each section configures part of the cbox environment. Navigate with Enter (next), `b` (back), `j` (jump), `q` (save and quit). Re-run individual sections later with `./setup.sh update <name>`.

### mode

Container mode (`CBOX_MODE`): one shared global container for all workspaces, or one container per project (isolated). See "Global vs isolated mode" below for the full comparison.

### mounts

Bind-mount or volume-back the host `~/.claude` and `~/.codex` directories. Each is independent:
- **mount** - host directory bind-mounted into container. Data lives on host; survives volume removal and machine switches.
- **volume** - Docker named volume. Logins and state persist across restarts but exist only in Docker.

For mount mode, the wizard offers to backup existing data first (plain copy or compressed tar.gz).

Mounted `~/.claude` and `~/.codex` must be outside every configured workspace path (no nesting).

The entrypoint fixes ownership of the managed directories (`~/.claude`, `~/.claude-cbox`, `~/.codex`, the venv path, `~/.ssh` when forwarded, and the per-project `~/.claude/projects/<slug>` for isolated scopes) to the container user on every start, listed via `CBOX_MANAGED_DIRS`. `cbox doctor` reports this as the `managed-dirs` row.

### workspaces

List git repositories or directories where cbox will run. The wizard checks each path and offers to `git init` if not a work-tree (required for git guards and codex write-capable delegation).

In global mode, all workspaces mount into the single shared container. In isolated mode, each workspace gets its own container.

The install directory itself, venv paths, and `~/.claude`/`~/.codex` must not overlap with any workspace (wizard enforces this).

### python

Optional Python environment:
- **none** - `python3` from the base image (always available).
- **host** - host venv directory mounted read-only at the same path in the container.
- **volume** - persistent venv on a named Docker volume at `/opt/venv`.

Inside the container, `~/.local` and `~/.codex/packages` are read-only; `pip install --user` or npm/pip to those paths will fail by design. Use a venv instead.

### gpu

Check for NVIDIA GPU support (nvidia-container-toolkit + CDI). If missing, the wizard prints exact manual installation commands but does not run them.

After installing on the host and plugging in an eGPU:

```bash
sudo ./bind_egpu.sh
```

This regenerates the CDI specification and restarts the stack with `--gpu`. A plain `cbox up` always works without GPU.

### egress

Optional domain-filtered egress proxy (tinyproxy sidecar on an internal network). The container has no direct internet; all HTTP/HTTPS is filtered.

The wizard only ever ADDS domains to the allowlist or blocklist. To remove, edit `etc/egress-allowlist.txt` or `etc/egress-blocklist.txt` directly and re-run `./setup.sh update egress`.

What breaks under egress: SSH-based git remotes (unless SSH is enabled), direct DNS, and any tool ignoring `HTTP_PROXY`/`HTTPS_PROXY`.

### netaccess

Optional SOCKS proxy on the egress container for reaching other Docker networks. List Docker network names or raw IPv4 CIDR ranges (minimum `/8` prefix). Reachability depends on host routing.

### hostroute

Route container egress through a host-managed forward proxy so the host `/etc/hosts` and host DNS resolution are honored (`CBOX_HOST_ROUTE_MODE=off|host-proxy`, `CBOX_HOST_PROXY_URL`, `CBOX_HOST_PROXY_ADDR_MODE`). Off by default. Only meaningful with egress enabled; like egress it is applied host-side (MODE + APPLIED) and verified in a running container.

### ssh

SSH access for git over SSH and agent operations. Three modes:
- **none (default)** - no SSH in the container; git over HTTPS works normally.
- **host-agent** - host SSH agent socket bind-mounted read-only. Private keys never enter container; it requests signatures only. Hardening: load keys with destination constraints (`ssh-add -h github.com`).
- **container-keys** - keys generated on a persistent volume inside the container. Add the printed public key as a git deploy key.
- **mixed** - both host agent socket and container-generated keys.

With egress mode on, SSH traffic tunnels through the proxy to `ssh.github.com:443` (GitHub's SSH-over-HTTPS endpoint).

### bashrc

The wizard writes `~/.bashrc-cbox` and sources it from `~/.bashrc`. This installs permanent shell aliases:
- `claude` - `cbox run claude`
- `codex` - `cbox run codex`
- `cbox-shell` - `cbox run bash`
- `cbox-stop` - `cbox down`

### mcp-servers

List additional MCP servers (environment variables and server commands) to register in both Claude Code and Codex. JSON syntax. The wizard merges with existing `~/.mcp.json` or `~/.codex/mcp-servers.json` without overwriting entries.

### agents

Render agent definitions for Claude Code (policies and custom agents). Pulled from `~/.claude/agents/`. The wizard stages templates and asks for approval before writing.

### codex-mcp

Enable or disable reverse orchestration: register Claude as an MCP tool inside Codex. When enabled, Codex gains an `ask-claude` tool. Codex can delegate questions and file edits to Claude; both subscriptions are charged per call (intended policy: propose-and-ask, never automatic).

Parameters: `prompt` (question), `model` (haiku/sonnet/opus), `effort` (low/medium/high/max), `cwd` (optional, enables file edits), `max_turns` (optional).

Safety: recursion limit (Claude refuses further hops when invoked over MCP), read-only wrapper script, bytewise audit trail to `~/.claude/ask_claude_audit.container.jsonl`.

### codex-progress

Enable live progress relay: MCP calls show live Claude Code UI activity during Codex delegation instead of a bare spinner. The relay (`~/.claude/hooks/codex_mcp_shim.py`) translates Codex events to standard MCP progress notifications. Requires claude mount mode and staged hook install (`cbox install-hooks`).

Optional: set `CBOX_CODEX_SHIM_LOG=<path>` to debug all events and synthesized progress.

### continuity

Enable durable project memory layers. All switches default ON:
- `CBOX_HISTORY` - mandatory pair: `LEDGER.md + PROGRESS_YYYY_MM_DD.md` (state + queue).
- `CBOX_DIARY` - `DIARY.md` (Claude's private space for exceptional moments).
- `CBOX_GIT` - `CHANGELOG.md` (git projects only; what landed on master, newest on top).
- `CBOX_OPEN_QUESTIONS` - `OPEN_QUESTIONS.md` (always-current list; resolved ones deleted).

All live in `./.claude/` of the project. They survive session ends, context loss, and machine switches.

Turning off `CBOX_HISTORY` disables the whole continuity system.

### claude-md

Install global policies and templates into `~/.claude/policies/` and `~/.claude/templates/` and append @import lines to `~/.claude/CLAUDE.md`. Pulled from `~/.claude/templates/` and `~/.claude/policies/` (via `~/.claude/`). The wizard stages changes, shows diffs, and asks for confirmation before writing.

Policies are read-only inside the container (mounted read-only in both mount and volume mode) to prevent prompt injection. Manage policies on the host via `./setup.sh update claude-md`.

### settings

Configure model routing: tiers (luna, sol, terra, terra-light) and their associated Claude models + reasoning effort, plus approvals and billing. Pulls from `~/.claude/settings.json`. Changes stage with diffs before confirmation.

### hooks

Install hook scripts (`git/`, `claude/`, `codex/`, `step_hooks/`) into the configured hooks directory. The wizard diffs against the installed version, stages changes, and asks for confirmation.

These are read-only in the container (cannot be rewritten by a compromised agent).

### git-identity

Configure `git config user.name` and `git config user.email` (either global or per-workspace).

### apt-extra

Optional extra apt packages to install in the container image (security updates, build tools, etc.). One per line; rendered at Docker build time.

### autoresume

Enable session-limit auto-resume: `cbox run claude` sessions wrapped in tmux survive usage-limit stops. The watchdog detects resets and types the resume prompt at the appointed time (tunable: `CBOX_LIMIT_RESUME_DELAY` default 300s, `CBOX_LIMIT_RESUME_STAGGER` default 30s, `CBOX_LIMIT_RESUME_PROMPT` default "pokracuj"). Requires isolated session scope and claude mount mode.

### restart-policy

Set Docker restart policy (`no`, `always`, `unless-stopped`). Isolated containers are always `no` (hard stop on process exit).

### binaries

Claude and Codex version pins and the shared binary volumes (`CBOX_CLAUDE_TARGET`, `CBOX_CODEX_VERSION`, `CBOX_CODEX_TARGET`, `CBOX_BINS_SCOPE`). Installs run host-side into machine-wide volumes; runtime mounts are read-only. One install serves every project and mode; see Binaries lifecycle below.

### local-model

Off by default (absent from the rendered MCP server list and refused by `cbox ai`) until configured. Wires an OpenAI-compatible endpoint such as ollama as: (1) `local-qwen`, a text-only MCP delegate exposing one tool, and (2) `local-qwen`, a `cbox ai` engine that drives `codex --oss --local-provider ollama` against the same endpoint. Set `CBOX_LOCAL_MODEL=on` plus `CBOX_LOCAL_MODEL_URL` and `CBOX_LOCAL_MODEL_NAME` via this wizard section, `./setup.sh update local-model`, or `--config`; `cbox doctor` reports ACTIVE/CONFIG-ONLY/OFF. Ollama itself always runs outside cbox (no GPU/CDI grant). See etc/docs/LOCAL_MODEL_RUNBOOK.md for the two setup paths (ollama as a sibling container vs a host process) and open decisions left to the operator.

## Global vs isolated mode

Set `CBOX_MODE` in `cbox.conf`:

- **global** - one container for all workspaces, started by `cbox up`/`down`/`restart`.
- **isolated** - one container per project (keyed by git top-level or cwd if not a work-tree). Per-project config lives in `~/.config/cbox/projects/<path-hash>/` (never mounted into any container, so a process cannot rewrite its own launch config).

In isolated mode, `claude`/`codex` resolve the project from cwd and launch/reuse that project's container. First run in an unconfigured project (with TTY) prompts: set up new, derive from global, or cancel.

Session scope (isolated mode only): `CBOX_SESSION_SCOPE=isolated` (default) mounts only this project's sessions; `global` shows all. Isolated scope uses symlink farms to keep container and host session views in sync as work moves between scopes.

## Image hash and per-project input

Each project's Docker image is tagged `cbox-img:<hash>`, where `<hash>` is the SHA256 of declared inputs: base image digest, package list, Claude/Codex target versions, GPU/egress flags, and Dockerfile COPY sources. Two projects with identical inputs share one image and its per-hash volumes.

The hash is declared inputs, not "freshest bits": it pins the base image by digest (with bounded TTL, default 3600s) but does not re-run `apt-get upgrade` every launch on an unchanged image. "Rebuild if stale" means stale relative to recorded inputs, not upstream packages.

## Lifecycle: global mode

`cbox up [--gpu]` starts the container. `cbox down` stops it. `cbox restart [--gpu]` restarts. Volumes persist across stop/start cycles.

Binaries mount read-only (install once on host, reuse everywhere). Version pin conflicts between projects are refused (see Binaries section in README).

## Lifecycle: isolated mode

A project's container starts on first `claude`/`codex`/`cbox run` and stops the instant the last live process exits (no idle timeout). "Live" is determined by matching `/proc/<pid>/exe` against the binary path recorded in shared volumes' metadata; a copied binary cannot keep the container alive. Engine infrastructure processes do not count as live: the Claude daemon (`claude daemon run`), its PTY helpers (`--bg-pty-host`, `--bg-spare`), and `codex mcp-server` relay subprocesses are ignored, so a lingering daemon or MCP relay never keeps an otherwise idle container running.

Two windows in the same project share one container; only the last window's exit triggers the stop.

`cbox gc` is the backstop for orphaned containers (wrapped processes killed with SIGKILL, backgrounded processes, raw `docker exec`): it samples process count twice (10 seconds apart) under an exclusive lock and stops only idle containers.

## Storage modes (mount vs volume)

Each of `~/.claude` and `~/.codex` is independent:

- **mount** - host directory bind-mounted. Data lives on host; survives machine switches and volume removal.
- **volume** - Docker named volume. Logins and state survive restarts but exist only in Docker. Use `cbox backup` to archive volumes to `./backups/`.

Mixing modes is supported. Never use `docker volume prune` (it deletes volumes not attached to running containers and will destroy volume-mode state). `cbox down` never removes volumes.

## Behavioral read-only

Inside the container, these are always mounted read-only:
- `~/.claude/CLAUDE.md`
- `~/.claude/agents/`
- `~/.claude/policies/`
- `~/.claude/templates/`
- `~/.claude/hooks/`
- `~/.claude/settings.json`
- `~/.claude.json` (Claude Code seed)

This prevents prompt injection: subagent bodies are executed as system prompts, so a writable agent file is a persistent injection foothold.

Consequence: the global #shortcut in Claude Code does not work inside the container. Manage policies on the host via `./setup.sh update claude-md`.

Project-local files in `./.claude/` of a mounted workspace stay writable (same as the rest of the workspace). Runtime state (`~/.claude/projects/`, `~/.claude/agent-memory/`, credentials) remains writable.

The container's own Claude state file lives as a plain file inside the claude-config directory bind (`<effective dir>/claude-config/.claude.json` per project; `generated/claude-config/.claude.json` in global mode). Each regen re-renders its `mcpServers` from the delegate registry and preserves every other key the container wrote (trust dialog, onboarding). One-shot import: drop a `.claude.json.migrate` file next to it and the next regen adopts it as the initial state (only when no state file exists yet) and deletes it.

## Wizard re-runs and host activation

After the initial wizard run:

- `./setup.sh update <section>` re-runs one section and regenerates related outputs.
- `cbox install-hooks` stages and diffs hook scripts, then confirms before installing to the host.
- `cbox restart` reloads configuration and restarts the container.
- `./setup.sh update --config <file>` replicates a saved `cbox.conf` on another machine (non-interactive; skips host-side writes).

For continuity migration (moving project brain from `~/.claude/` to `./.cbox/`):

```bash
cbox continuity migrate
```

## Per-feature toggles

| Feature | Config var | Enable | Behavior |
|---------|-----------|--------|----------|
| History + memory | `CBOX_HISTORY` | on | `LEDGER.md + PROGRESS.md` mandatory; other layers depend on it |
| Diary (private space) | `CBOX_DIARY` | on | `DIARY.md` in project `./.claude/` |
| Changelog (git) | `CBOX_GIT` | on | `CHANGELOG.md` in project `./.claude/` (git only) |
| Open questions | `CBOX_OPEN_QUESTIONS` | on | `OPEN_QUESTIONS.md` in project `./.claude/` |
| Reverse orchestration | codex-mcp section | on | Codex gains `ask-claude` MCP tool; charges both subscriptions per call |
| Progress relay | codex-progress section | on | Live Claude Code UI activity during Codex delegation (mount mode only) |
| Egress lockdown | egress section | on | tinyproxy sidecar; all HTTP/HTTPS filtered by domain |
| SSH access | ssh section | on | `host-agent`, `container-keys`, or `mixed` |
| GPU (CUDA via CDI) | gpu section | on | attach NVIDIA GPU at container start |
| Session auto-resume | autoresume section | on | tmux + watchdog auto-types resume prompt after usage limit reset |
| Light context profile | `CBOX_CONTEXT_PROFILE=light` | light | ~700 tokens; skips orchestration detail, keeps kernel + ledger |

## File layout

```
cbox/                           # Install directory
  setup.sh                        # Wizard entry point
  cbox                            # Wrapper script (docker run, lifecycle)
  docker-compose.yml              # Generated compose file (global mode)
  docker-compose-isolated.yml     # Template for isolated projects
  cbox.conf                       # Generated configuration
  Dockerfile                      # Generated (base image + packages)
  entrypoint.sh                   # Container entry point
  generated/                      # Outputs from setup sections
  templates/                      # Section templates
  etc/                            # Static config
    egress-allowlist.txt          # Domain filter
    egress-blocklist.txt
    mcp/
      codex_mcp_shim.py           # Progress relay
      cbox-container.config.toml  # Codex tier config (rendered)
    hooks/                        # Hook scripts (staged by install-hooks)
    codex/
      ask_claude_mcp.py           # Reverse orch wrapper (read-only in container)
      orchestrator-global.txt     # Codex conduct kernel injected by shim
    bash/
      bashrc-cbox                 # Shell aliases (sourced by ~/.bashrc)
  backups/                        # Volume archives (cbox backup)
```

## Host gates (verification)

`cbox verify` checks:
- Each workspace is a git work-tree.
- `~/.claude/CLAUDE.md`, agents, policies, templates, hooks, settings.json are read-only and present inside the container.
- Claude Code and Codex binaries are at pinned versions.
- MCP protocol roundtrip succeeds.
- Nested ask-claude calls are depth-limited and refused.
- (Isolated mode) Per-project image hash is consistent.
- (Codex-mcp enabled) Config.toml wiring exists.

Configurations that fail verification refuse to start.

## Troubleshooting

**Container won't start:** Run `cbox verify` to check configuration. Look at `cbox logs` for exact errors.

**Stale seed warning:** After `./setup.sh update` (re-bless), re-run `claude` once on the host to regenerate `~/.claude.json`.

**TTY requirement for interactive sections:** The wizard requires a TTY for mounts, workspaces, and project prompts. If running non-interactively, use `./setup.sh --config <file>` instead.

**Old binary volumes still present:** `cbox gc` sweeps orphaned containers and old per-project binary volumes after migration to shared volumes.

**Egress blocklist doesn't work:** The blocklist is hygiene only, not a security boundary. Use an allowlist for actual restrictions.

**SSH-based git with egress:** Enable the SSH section; it tunnels git over HTTPS to `ssh.github.com:443` through the proxy.

## See also

- README.md - feature overview and quick-start.
- etc/docs/LOCAL_MODEL_RUNBOOK.md - local model setup (off by default; two setup paths, open decisions).
- ~/.claude/CLAUDE.md - global conduct kernel, policies, agent definitions.
- cbox.conf - generated configuration (key/value pairs, sourced by shell scripts).
