# cbox setup and operation manual

Complete reference for installing, configuring, and operating cbox. Start with the quick-start in README.md; come here for detail.

## Setup wizard sections

Run `cbox setup` to open the interactive wizard. Each section configures part of the cbox environment. Navigate with Enter (next), `b` (back), `j` (jump), `q` (save and quit). Re-run individual sections later with `cbox setup update <name>`.

### mode

Container mode (`CBOX_MODE`): one shared global container for all workspaces, or one container per project (isolated). See "Global vs isolated mode" below for the full comparison.

### mounts

Bind-mount or volume-back the host `~/.claude` and `~/.codex` directories. Each is independent:
- **mount** - host directory bind-mounted into container. Data lives on host; survives volume removal and machine switches.
- **volume** - Docker named volume. Logins and state persist across restarts but exist only in Docker.

For mount mode, the wizard offers to backup existing data first (plain copy or compressed tar.gz). When switching from mount to volume mode, the wizard offers to back up the outgoing host directory at switch time.

Mounted `~/.claude` and `~/.codex` must be outside every configured workspace path (no nesting).

The entrypoint fixes ownership of the managed directories (`~/.claude`, `~/.claude-cbox`, `~/.codex`, the venv path, `~/.ssh` when forwarded, and the per-project `~/.claude/projects/<slug>` for isolated scopes) to the container user on every start, listed via `CBOX_MANAGED_DIRS`. `cbox doctor` reports this as the `managed-dirs` row.

`CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG=|on|off` (empty by default) controls the `switchModelsOnFlag` key in the volume-mode `~/.claude.json` seed (`generated/state/claude.json`; only applies when `CBOX_CLAUDE_MODE=volume`, mount mode never writes to the real host `~/.claude.json`). Empty leaves the key alone: a fresh seed is written without it, exactly as before this setting existed, and an existing seed is never touched. `on`/`off` write the key into a fresh seed, and add it to an existing seed only when the key is absent - cbox never overwrites a value already present, since the user may have set it deliberately through the `/config` menu. This is a one-shot add, not a live toggle: flipping the gate after the seed file already carries the key has no effect on that file.

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

`CBOX_GPU=1` is sufficient by itself: the CDI reservation is rendered into the compose file automatically, in both global and isolated (per-project) mode, and is attached every time the container starts (`cbox run`, `cbox shell`, `cbox up`, ...). The `--gpu` flag on `cbox up`/`cbox restart` is legacy and redundant when `CBOX_GPU=1` - it is still accepted for old habits and scripts, but it is a no-op in that case. If `CBOX_GPU=0`, passing `--gpu` fails loudly and tells you to run `cbox config set CBOX_GPU=1` instead of silently starting without GPU.

Host prerequisites are unchanged: install `nvidia-container-toolkit`, run `nvidia-ctk runtime configure --runtime=docker`, restart docker, then `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`. Under rootless docker, CDI typically also needs `no-cgroups = true` in the nvidia-container-runtime config; this is a host-side step cbox cannot verify.

After installing on the host and plugging in an eGPU:

```bash
sudo ./bind_egpu.sh
```

This regenerates the CDI specification, sets `CBOX_GPU=1` in the config, and restarts the stack. It no longer passes `--gpu`, because the config is now what decides: passing the flag on a machine where `CBOX_GPU=0` would stop the container and then refuse to start it. A plain `cbox up` always works without GPU when `CBOX_GPU=0`.

### egress

Optional domain-filtered egress proxy (tinyproxy sidecar on an internal network). The container has no direct internet; all HTTP/HTTPS is filtered.

The wizard only ever ADDS domains to the allowlist or blocklist. To remove, edit `etc/egress-allowlist.txt` or `etc/egress-blocklist.txt` directly and re-run `cbox setup update egress`.

What breaks under egress: SSH-based git remotes (unless SSH is enabled), direct DNS, and any tool ignoring `HTTP_PROXY`/`HTTPS_PROXY`.

### dns

DNS resolution mode (`CBOX_DNS_MODE`), applied only when egress is enabled (in egress mode the override applies to the proxy sidecar only; the main container sits on an internal network):

- **docker** (default) - Docker embedded DNS snapshotting host resolvers at container start. Fast but goes stale after wifi/DNS changes until container restart.
- **public** - Compose `dns:` entries from `CBOX_DNS_SERVERS` (default "1.1.1.1 8.8.8.8"). Immune to host network changes but bypasses VPN/LAN split-horizon DNS.
- **stub** - Compose `dns:` pointing at `CBOX_DNS_STUB_IP`, a host-stable resolver such as a systemd-resolved DNSStubListenerExtra address or dnsmasq on the docker bridge. Follows host DNS AND survives wifi changes; host resolver setup is a manual host-side step.

Apply via `cbox setup update egress` (compose re-render + container recreate).

### netaccess

Optional Dante SOCKS proxy on the egress container for reaching other Docker networks and raw IP ranges. The host-side lifecycle that resolves the configured scope, joins the proxy to eligible Docker networks, renders `sockd.conf`, disconnects networks removed from the previous scope, and restarts the proxy runs on `cbox run` (both global and isolated), isolated `cbox shell`, and `cbox up`. Global `cbox shell` only execs into the already-running global container - it does not re-run this lifecycle, so a grant made after the global container was started needs `cbox down && cbox up` (or `cbox run`) to take effect there. The Docker-network side has two scopes (`CBOX_NETACCESS_SCOPE`):

- **all (default)** - the proxy joins every eligible bridge or overlay Docker network present at apply time; networks are autodetected, nothing to enumerate. Host, none, ingress, unsupported-driver, non-IPv4, and the current cbox project's own internal/egress networks are skipped. New networks appearing later are picked up on the next apply.
- **list** - the proxy joins only the networks named in the wizard. An empty list under this scope passes nothing beyond the raw CIDRs; with no CIDRs either, the proxy denies everything.

A network named under `scope=list` that does not exist (or cannot be inspected) at apply time is skipped, not fatal: the apply still proceeds and grants every other reachable network, and a warning names it on stderr (`cbox: netaccess: SKIPPING granted network ...`) stating whether the network was absent or merely failed to inspect. `cbox doctor` then lists it under `configured networks not found on this host`; `cbox netaccess status` shows it under `networks:` but not under `applied:`. Only an unsupported driver, a cbox-infrastructure network, or a network with no eligible IPv4 subnet stays a hard error under `scope=list`, since those name a real network the operator asked for that cbox refuses to join on principle rather than one that is simply not there right now.

Raw IPv4 CIDR ranges (minimum `/8` prefix, e.g. k3s pods `10.42.0.0/16`, services `10.43.0.0/16`) are always listed manually under both scopes - they are not Docker networks and cannot be autodetected. Their reachability depends on host routing. A wildcard CIDR does not exist: `0.0.0.0/*` and prefixes broader than `/8` are rejected.

Configs written before `CBOX_NETACCESS_SCOPE` existed resolve conservatively: a non-empty network or CIDR list means `list` (nothing silently broadens), only a fully empty config resolves to `all`.

`cbox netaccess` changes and inspects the allowed set on the host without recreating anything:

```
cbox netaccess status
cbox netaccess allow <docker-network|container|CIDR>...
cbox netaccess deny  <docker-network|container|CIDR>...
```

A target is classified by shape: anything with a `/` is a CIDR, otherwise it is looked up as a Docker network and then as a running container. Naming a container expands to every Docker network that container is on, and the command says so - because a pass rule covers the target network's whole subnet on all TCP ports, allowing one container allows every container on its networks. Changes are written to the effective `cbox.conf` and then applied to the running proxy (config write first, so a failed apply still leaves a recoverable state); the cbox container itself is not restarted, only the proxy sidecar. `deny` requires `scope=list` - under `scope=all` the list is ignored, so a denial would be silently meaningless, and `allow` under `scope=all` warns that it records the entry but changes nothing until the scope is narrowed. Both subcommands are host-only. The same three actions appear in the interactive hub as a `netaccess` row, shown only when the feature is active.

`cbox doctor` on the host shows what the scope currently resolves to: the Docker networks present (with attached containers), which of them the proxy will join, configured-but-missing networks under scope `list`, and the closest matching host route for each raw CIDR.

Inside cbox, `CBOX_SOCKS_PROXY` is the authoritative and only proxy variable (`socks5h://cbox-proxy-internal:<port>` - a network-scoped alias that exists solely on the internal network, so the name always resolves to the address sockd actually binds). `ALL_PROXY`/`all_proxy` are deliberately not exported: the SOCKS proxy passes only the allowed target subnets and denies everything else, so a blanket proxy variable would capture general egress (curl, git, pip) and break it. Use `CBOX_SOCKS_PROXY` explicitly for target-network TCP, e.g. `curl -x "$CBOX_SOCKS_PROXY" http://target-container/`. The entrypoint probes the endpoint at session start; if it is unreachable it drops the variable, records the failure for `cbox doctor` (netaccess row turns MISSING with the probed endpoint), and the session falls back to direct egress. A session started before the grant was applied never sees the proxy - recover with `cbox down && cbox run`.

Optional direct test execution (`CBOX_NETACCESS_EXEC_MODE=scoped`) is available only with `scope=list` and at least one explicit Docker network. A session-bound host helper exposes a private Unix socket and the read-only `cbox-container` client inside cbox; `docker.sock` is never mounted into cbox. Each invocation gets a unique read-only socket mount, while its audit file stays outside that mount. The helper re-inspects the configured networks and target container for every request, and denies stopped, privileged, host-namespace, dangerous-capability, device-bearing, unconfined, host-control-mount, and cbox infrastructure containers. Network membership is the default scope boundary. `CBOX_NETACCESS_EXEC_WORKSPACE_GUARD=on` additionally denies target containers whose host bind mounts leave the current isolated project; in global mode it permits the configured `CBOX_WORKSPACES` set. It is off by default.

Use it inside cbox as:

```
cbox-container list
cbox-container exec --cwd /workspace --timeout 300 app -- pytest -q
```

Options must precede the container name. Commands are passed as an argv list without shell interpretation, output is capped, audit records contain an argv hash rather than full arguments, and a target-side `timeout` process bounds execution. If the target image has no `timeout` executable, the command fails instead of running unbounded.

`CBOX_CONTAINER_EXEC_TOOL=off|on` (off by default) additionally registers the bridge as an MCP tool (`container-exec` in `delegates.json`, tools `container_list` and `container_exec`) so an agent can call it directly instead of a human running `cbox-container` by hand. This is a separate, stricter gate on top of `CBOX_NETACCESS_EXEC_MODE=scoped`: an operator may want the bridge for their own manual use without exposing it as agent-callable, so both must be on for the tool to actually work. The tool speaks the same one-shot, no-TTY, no-stdin protocol as the `cbox-container` client - one bounded `docker exec` per call, nothing persists between calls, and shell metacharacters in `argv` do nothing unless the caller passes `sh -c` itself. If the bridge socket is absent or not a socket, the tool returns a clear error rather than crashing; that error means the operator has not enabled the feature for this session, not that the caller did something wrong. Whatever the tool returns on stdout or stderr is untrusted data from a foreign container; the rendered tool description and the injected context paragraphs say so explicitly, because that output flows straight into an agent's context. Scope deliberately stays where it already was: an exec runs inside the target container's own namespaces, so it grants exactly what that container grants and no host access of its own. There is no hardcoded path deny-list. The one case worth knowing is that a target container which itself bind-mounts a host path lends that access to whoever execs into it; `CBOX_NETACCESS_EXEC_WORKSPACE_GUARD=on` is the opt-in control for that, and it stays off by default. Every request is audited, including denials and `list` calls, not only successful execs, and the exec record is written before the command runs as well as after it. hermes can render this tool too (see the MCP servers for hermes paragraph in the hermes section), but `container-exec`'s own `available_to` list in `delegates.json` does not name `hermes` yet - the entry has to opt in there first, independently of `CBOX_CONTAINER_EXEC_TOOL`.

### hostroute

Route container egress through a host-managed forward proxy so the host `/etc/hosts` and host DNS resolution are honored (`CBOX_HOST_ROUTE_MODE=off|host-proxy`, `CBOX_HOST_PROXY_URL`, `CBOX_HOST_PROXY_ADDR_MODE`, `CBOX_HOST_GATEWAY_ALIAS`). Off by default. Only meaningful with egress enabled; like egress it is applied host-side (MODE + APPLIED) and verified in a running container.

**Host route setup:** Configure `CBOX_HOST_ROUTE_MODE=host-proxy` and `CBOX_HOST_PROXY_ADDR_MODE` (how the container reaches the proxy endpoint). Optional `CBOX_HOST_GATEWAY_ALIAS` (off|on, default off) renders `extra_hosts: host.docker.internal` mapped to host-gateway on the cbox service. This lets container processes reach host-bound services via `http://host.docker.internal:<port>`.

**Host-side LLM pattern:** Run ollama or llama.cpp on the host (not in a container). The process must listen beyond 127.0.0.1: `OLLAMA_HOST=0.0.0.0:11434` or `llama-server --host 0.0.0.0 --port 11434`. Inside the container, with `CBOX_HOST_GATEWAY_ALIAS=on`, call `http://host.docker.internal:11434` (or substitute the actual port).

**Wireguard-remote pattern:** Access an endpoint on a remote machine over a wireguard tunnel. Use the tunnel IP of the remote machine (e.g. `http://10.0.0.5:11434`). The container needs no extra cbox wiring - plain networking reaches the tunnel. Caveat: under egress lockdown or SOCKS mode, the endpoint must be explicitly allowed (egress allowlist) or those modes turned off entirely for the wireguard path to work.

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
- `cbox` - `$CBOX_DIR/cbox "$@"` (so bare `cbox` reaches the hub without the full install path)
- `hermes` - `cbox run hermes`, emitted only when `CBOX_HERMES=on` at the time `~/.bashrc-cbox` was generated

`hermes()` does not appear retroactively when hermes is turned on later: `~/.bashrc-cbox` is a host file only `cbox setup update bashrc` (or the full wizard) rewrites - a bare `cbox setup update` re-renders in-repo/generated artifacts and re-blesses templates but does not touch host files, and `cbox setup update hermes` alone regenerates the hermes-managed config, not the bashrc functions. Run `cbox setup update bashrc` after enabling hermes to get the helper function.

### mcp-servers

List additional MCP servers (environment variables and server commands) to register in both Claude Code and Codex. JSON syntax. The wizard merges with existing `~/.mcp.json` or `~/.codex/mcp-servers.json` without overwriting entries.

### agents

Render agent definitions for Claude Code (policies and custom agents). Pulled from `~/.claude/agents/`. The wizard stages templates and asks for approval before writing.

### codex-mcp

Enable or disable reverse orchestration: register Claude as an MCP tool inside Codex. When enabled, Codex gains an `ask-claude` tool. Codex can delegate questions and file edits to Claude; both subscriptions are charged per call (intended policy: propose-and-ask, never automatic).

Parameters: `prompt` (question), `model` (haiku/sonnet/opus), `effort` (low/medium/high/max), `cwd` (optional, enables file edits), `max_turns` (optional).

Safety: recursion limit (Claude refuses further hops when invoked over MCP), read-only wrapper script, bytewise audit trail to `~/.claude/ask_claude_audit.container.jsonl`.

Each call runs Claude Code in headless print mode (`claude -p ... --output-format json`), so it can carry a real `--fallback-model` chain: a comma-separated list Claude Code tries in order if the requested model is overloaded or not available. This is a genuine multi-step chain, but it is scoped to this one-shot delegate call, not to an interactive Claude Code session - `--fallback-model` only works with `--print`, and it covers "overloaded or not available", not a safety-rules refusal. An interactive session only has `switchModelsOnFlag`, a single automatic switch (see the mounts section above); there is no native three-step interactive chain, and cbox does not pretend otherwise. Set `ASK_CLAUDE_FALLBACK_MODEL` to a comma-separated override list (empty string disables the chain entirely); leave it unset for a built-in default chain keyed on the requested `model` (defined in `etc/codex/ask_claude_fallback_models.json`, deployed alongside `ask_claude_mcp.py`). Every entry in the chain, override or default, passes the same validation as `model` itself: non-empty, no leading `-`, no whitespace; a malformed override entry refuses the call before Claude Code is invoked.

`CBOX_CODEX_HOOKS` (enum `off`/`on`, default `off`) is an experiment gate. `on` renders `[features].codex_hooks=true` into the codex profile and a PreToolUse Bash entry into `generated/codex/hooks.json` pointing at `codex_guard_bridge.py`, which translates codex's Bash-tool payload to the claude-shaped guards (rm-glob denies; commit is advisory; code-hygiene/agent-label/spawn/codex-mode have no codex analog under a Bash-only PreToolUse). `off` (default) keeps today's codex profile and hooks.json byte-for-byte (proven by the M3 frozen oracle). The binding stays `gated:codex-hooks-experiment` until the host runbook (`docs/M4_GUARD_EXPERIMENTS_RUNBOOK.md`) records real payloads and proves deny actually blocks.

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

Policies are read-only inside the container (mounted read-only in both mount and volume mode) to prevent prompt injection. Manage policies on the host via `cbox setup update claude-md`.

### kernel-lang

Two-part language rule rendered into the deployed conduct kernel: `CBOX_KERNEL_LANG_OUTPUT` (free text, default empty) and `CBOX_KERNEL_LANG_REASONING` (free text, default `slovencina bez diakritiky`). Empty output language means the rule is not rendered at all - no language is imposed unless one is set. When an output language is set, one line is added to the kernel: reason and think in the reasoning language, answer and write every output in the output language. Values are bounded to 64 ASCII characters, no control characters, no backslashes, no leading/trailing spaces, no `{`/`}`; non-ASCII input is refused, not transliterated. Set via the wizard section (`cbox setup update kernel-lang`) or `cbox config`; deploy the rendered kernel with `cbox setup update claude-md` (`apply_class: none`, `profile: skip` - the default preset keeps it off).

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

`CBOX_SESSION_MULTIPLEX` (default `off`) wraps the interactive session in a named tmux session (`cbox-<engine>-<random>`) whenever a real TTY is attached, for all three engines (claude, codex, hermes) - not just claude. This is the precondition for attaching to a running cbox session from elsewhere: a bare process cannot be adopted by a multiplexer after the fact, so the session must start under tmux. `CBOX_LIMIT_AUTORESUME=on` already implies this wrap for claude even when `CBOX_SESSION_MULTIPLEX` is off; set `CBOX_SESSION_MULTIPLEX=on` to get the same wrap (and therefore the same attach precondition) for codex and hermes, or for claude without turning on auto-resume. Both variables require a TTY on stdin and stdout; the non-interactive exec path (`cbox exec`, scripted invocations) never wraps.

`CBOX_SAFEGUARD_AUTOCONFIRM` (default `off`) lets the same watchdog answer the model-safeguard switch dialog for you. When claude flags a message under its safety classifier it shows a blocking confirmation to switch to a fallback model and retry; unattended that dialog stalls the session for hours and the prompt cache expires. With this on, the watchdog reads the wrapped claude pane, and only when the visible screen carries both a safeguard/switch phrase and an actual option menu (numbered or bracketed) does it send the confirm keystroke, then re-reads the pane to log whether the dialog cleared. The two-signal match on the visible screen (never scrollback) is deliberate: a substring anywhere would let ordinary output that merely mentions the dialog trigger a keystroke into whatever prompt actually has focus. The match is deliberately strict: the safeguard phrase and the option menu must appear as one coherent block (the menu within a few lines after the phrase), and a screen that also carries a foreign confirmation prompt ("Do you want to proceed", "Do you trust the files", the permission ask's own decline wording) is refused outright - so ordinary output that merely mentions the words cannot turn a permission prompt into an auto-approval. A per-pane cooldown (`CBOX_SAFEGUARD_COOLDOWN`, default 20s) and daily cap (`CBOX_SAFEGUARD_MAX_PER_DAY`, default 40) bound it - both also enforced in-process, so a failed state write disables the pane for the run rather than lifting the cap - and every injection is logged to `watchdog.log`. It implies the tmux wrap for claude (like auto-resume) and needs the same isolated session scope + claude mount mode. The dialog phrase and the confirm key (Enter) are pinned in code, not user-tunable; re-verify them after a Claude Code upgrade, since the dialog is a TUI modal with no settings hook and its wording can change. This covers claude sessions running inside cbox under the wrap; host-side claude sessions outside a cbox container are not reached.

Remote session access is three layers stacked in the owner's order, and all three must be satisfied before a remote viewer sees a single byte: **(1) WireGuard** - the peer has to be a configured tunnel peer (`cbox wg peer add`, see the wireguard section above) before it can reach this container's sshd port at all; without the tunnel up, the port is not on any network the peer can route to. **(2) an ssh key** - the peer's public key has to be in this container's `authorized_keys` (`cbox session-broker key add`, below); WireGuard reachability alone does not authenticate anyone. **(3) the runtime allow** - even a peer who is on the tunnel and holds a trusted key gets nothing until the owner opens the access level and, optionally, a time window (`cbox session-broker access`/`window`, below). Losing any one of the three closes the door; all three are host-side decisions, never made by the connecting peer.

The container runs its own `sshd` (`AllowUsers <container user>`, `PermitRootLogin no`, no password/keyboard-interactive auth, no TCP/agent/stream-local/X11 forwarding, no tunneling, `PermitOpen none`) with a single `ForceCommand /opt/cbox/cbox-session-entry.py` - every connection, regardless of what the client asks for, runs this one program with the client's request available only as the `SSH_ORIGINAL_COMMAND` environment string (`ForceCommand` always wins over any `command=` an authorized_keys line might also carry). The entry program never execs a shell with that string: it matches it against a strict allow-list (`list`, `attach <session>`, `spawn <engine>`) before doing anything, rejects anything shaped like a flag or a path, and builds every downstream `tmux` argv itself - the caller supplies only a session or engine name, never a flag position, so a connection cannot smuggle `-CC`, `send-keys`, or any other tmux argv regardless of what it sends as its "command".

`CBOX_SESSION_BROKER_MODE` (default `disabled`; per-container `cbox setup` default, see the wizard) is the access level: `disabled` renders nothing at all (see Inert default below); `viewer` and `full-attach` render the sshd config, generate host keys once, and mount everything needed. The entry program reads this level fresh from `/etc/cbox-sshd/access.level` on every single connection, before evaluating even a `list` request, and there is also a companion optional time window at `/etc/cbox-sshd/access.window` (an epoch deadline, or empty meaning open indefinitely) checked the same way - so opening or closing access takes effect for an already-running container without any recreate, which is the entire point of resolving it per connection rather than once at container start. Both files are mounted `:ro` into the container and are always written host-side.

`viewer` allows `list` and a read-only `attach`: the entry program builds `tmux attach-session -r -f read-only,ignore-size -t <session>` itself, and independently of tmux honouring `-r`, the entry program's own byte-relay loop only ever forwards stdin bytes into the tmux pty when `tier == full-attach` - a compromised or buggy client cannot regain write access by asking for a different tmux flag, because it never controls the flags at all. `full-attach` allows a writable attach (no `-r`) and is also required for `spawn`, which generates a brand-new session name itself (`cbox-<engine>-<16 hex chars>`, matching the shape `entrypoint.sh`'s own session multiplexing already uses) and starts it under the container's own tmux server; a `viewer`-tier `spawn` request is refused. `list` runs a bounded `tmux list-sessions` and returns only sessions matching that `cbox-<engine>-<hex>` shape.

The tmux socket itself is never exposed beyond the entry program: sessions live on the container's own default tmux socket (the same one `entrypoint.sh`'s multiplexing already uses; the entry program never sets, reads, or forwards `TMUX_TMPDIR`, and `sshd_config` neither accepts nor permits any client-supplied environment), and the entry program is the only thing that ever opens a client against it on a remote connection's behalf. Window resizing works: the entry program opens its own pty for the tmux client, watches `SIGWINCH` on the real ssh terminal, applies `TIOCSWINSZ` to the pty, and forwards `SIGWINCH` to tmux's process group - so an interactive full-attach client resizes correctly, but see the residual risk below about what that does to a session shared with other viewers.

Every operation is audited, including refusals, append-only and `O_NOFOLLOW`-protected JSON lines at `/var/log/cbox-sshd/audit.jsonl` inside the container: op, tier, session/engine, outcome, reason, return code, and start/end pairs for attach/spawn. Identity in the audit record is the connecting address only (`SSH_CONNECTION`), never a key fingerprint - OpenSSH does not pass the authenticated key's fingerprint to `ForceCommand` via environment, only key-level rejections and successes appear in sshd's own log (`LogLevel VERBOSE`) outside this audit file. Cross-reference sshd's own log by timestamp and address if you need to know exactly which trusted key a given audit line used.

**Opening and closing the window.** `cbox session-broker window <minutes>` writes an epoch deadline the entry program checks fresh every connection; `cbox session-broker window off` clears it back to "open indefinitely" (still gated by the access level - clearing the window does not itself grant access). Both are host-only and runtime: no recreate, effective on the very next connection attempt.

**Adding and revoking a key.** `cbox session-broker key add <pubkey-file> [comment]` appends a `restrict,pty <type> <blob> [comment]` line to `authorized_keys` after verifying the file parses as a real public key and is not already present; `restrict` disables everything the sshd hardening directives already disable a second time at the per-key level (forwarding, X11, PTY allocation by default - `pty` is added back explicitly since the entry program needs one for tmux) and `pty` re-enables just that. `cbox session-broker key rm <fingerprint>` removes the matching line. `cbox session-broker key fingerprints` lists every currently trusted key's `ssh-keygen -lf`-style fingerprint line, so the owner can audit what is trusted without hand-parsing `authorized_keys`. All three are host-only, edit the same file the running container already has bind-mounted `:ro`, and OpenSSH re-reads `AuthorizedKeysFile` on every new connection attempt rather than caching it at daemon start - so key add/rm are runtime too, no recreate needed, exactly like access and window.

**What is genuinely runtime versus what needs a recreate.** Runtime, no recreate: `session-broker access`, `session-broker window`, `session-broker key add/rm` - all three write host-side files the running container already has mounted `:ro` and the entry program (or sshd itself, for keys) re-reads fresh on the next connection. Recreate required: `CBOX_SESSION_BROKER_MODE` itself (flips whether sshd config/mounts/port-publish exist in the compose file at all), `CBOX_SSHD_LISTEN_ADDR`, and `CBOX_SSHD_PORT` (both baked into the rendered `sshd_config` and the compose `ports:` mapping) - changing any of these three needs `cbox down` + `cbox up`/`cbox run` to re-render and re-create the container.

**Residual risks, stated plainly.** A `viewer` attach still sees everything the session prints to its terminal, including secrets that scroll past mid-session - read-only stops typing, it does not stop reading. A writable `full-attach` client connecting from a narrow terminal reflows the shared tmux session for every other attached viewer, because tmux by default sizes a session to its smallest attached client - the only mitigation is every attacher using `ignore-size` on their own side, and only `viewer` connections get that automatically here (the read-only attach argv always sets it); a `full-attach` operator sharing a session with a phone-sized terminal will visibly shrink it for everyone else. The audit trail identifies a connection by its source address, not by which trusted key it used - correlating a specific audit line to a specific key requires cross-referencing sshd's own log (`LogLevel VERBOSE`) by timestamp, it is not in `audit.jsonl` itself.

**Reaching the container: the WireGuard forward gap.** `CBOX_WG_FORWARDS` (the WireGuard sidecar's server-role port-forward table) is how a WireGuard peer would normally reach a service that isn't the sidecar itself - but it cannot reach the cbox container's sshd port today, and this is a real, unresolved topology gap rather than something implemented and merely undocumented. The WireGuard sidecar runs in its own machine-scoped compose project (`cbox-infra-u<uid>`, shared with ollama), on that project's own `default`/`wg-egress` networks; a per-project cbox container's own compose file defines an entirely separate `internal`/`egress` network pair (only rendered when the egress proxy is active) and never joins the infra project's networks - there is no shared docker network between the two today. `CBOX_WG_FORWARDS`'s `target_host` is deliberately validated as a docker-service-name (not an IPv4 literal, precisely to keep every forward target a named peer the sidecar can legitimately reach on its own network - see the wireguard section above), and the cbox container is not a named service the sidecar can resolve, because it is not on that network at all. Two ways to close this, neither implemented here: give the WireGuard sidecar a second attachment onto the target cbox container's own compose network (widening what the sidecar is dual-homed into, which is itself a blast-radius increase - see the wireguard section's blast-radius paragraph), or run sshd's own `CBOX_SSHD_LISTEN_ADDR` as a plain address the container already holds on an interface the peer's WireGuard tunnel can already route to directly (a LAN address, or, if the peer's tunnel address space includes it, a genuinely reachable address) rather than routing through the forward table at all. Until one of those lands, `CBOX_SSHD_LISTEN_ADDR` in practice has to be an address the container holds today (a docker-bridge or host-LAN address), not a literal WireGuard tunnel IP - `entrypoint.sh` refuses to start sshd if the configured address is not actually present on one of the container's own interfaces at boot, so a misconfigured address fails loudly rather than silently.

**The client story - no custom client needed.** With WireGuard up on the peer device and its key added, an ordinary ssh client reaches the forwarded port; `ForceCommand` means the usual interactive login shell is never available, so every operation is passed as the one-shot ssh command argument rather than typed after connecting:
```
ssh -p <CBOX_SSHD_PORT> <container-user>@<CBOX_SSHD_LISTEN_ADDR> list
ssh -p <CBOX_SSHD_PORT> <container-user>@<CBOX_SSHD_LISTEN_ADDR> 'attach cbox-claude-3f9a2b1c'
ssh -p <CBOX_SSHD_PORT> <container-user>@<CBOX_SSHD_LISTEN_ADDR> 'spawn claude'
```
`list` prints session name, created time, and path, one per line. `attach <session>` and `spawn <engine>` are interactive (they take over the ssh session's own terminal for the tmux client) - run them with a real pty (an interactive terminal, or a mobile ssh app that allocates one), not through `-T`/batch mode. The container's host key is generated once and stable across recreate (verified idempotent by sha256 across renders), so a peer that has accepted it once will not see a changed-host-key warning on a routine `cbox down && cbox up`; it only changes if the owner deletes the host-side key directory.

Inert default, proved not asserted: with `CBOX_SESSION_BROKER_MODE=disabled`, the rendered `docker-compose.yml` has zero occurrences of `sshd`, no `ports:` key for it, and none of `sshd_config`, `sshd-hostkeys/`, `sshd-authorized_keys`, or `sshd-access/` are ever written to disk - `openssh-server` is still installed into the image (like `tmux`), but nothing execs it, no config exists for it to run against, no port is published, and no key material is generated (`lib/test_sshd_entry.sh`).

### restart-policy

Set Docker restart policy (`no`, `always`, `unless-stopped`). Isolated containers are always `no` (hard stop on process exit).

### binaries

Claude and Codex version pins and the shared binary volumes (`CBOX_CLAUDE_TARGET`, `CBOX_CODEX_VERSION`, `CBOX_CODEX_TARGET`, `CBOX_BINS_SCOPE`). Installs run host-side into machine-wide volumes; runtime mounts are read-only. One install serves every project and mode; see Binaries lifecycle below.

### autoupdate

Engine autoupdate (`CBOX_AUTOUPDATE`, default `on`; `CBOX_AUTOUPDATE_TTL_HOURS`, default 24). When the engine target is a channel (claude stable/latest, codex latest, hermes latest) and the TTL since the last check elapsed, cbox re-runs the host-side vendor installer into the shared bins volumes in the background at session start (same operation as `cbox reinstall-bins`), refreshing the version stamp; log at `~/.config/cbox/autoupdate.log`. Pinned versions never autoupdate. Hermes only participates when `CBOX_HERMES=on`.

Engine-own opt-outs are respected: `"autoUpdates": false` in host `~/.claude/settings.json` skips claude; `check_for_update_on_startup = false` in host `~/.codex/config.toml` skips codex. In-container self-update stays disabled by design (read-only bins mounts, `DISABLE_AUTOUPDATER=1`).

A running session keeps its already-loaded binary; the next session uses the updated one.

### clipboard

Clipboard image bridge (`CBOX_CLIPBOARD_MODE`, default `off`, or `bridge`). In `bridge` mode a per-session host helper serves the host clipboard's image content read-only over a unix socket, answering Claude Code's Ctrl+V image paste inside the container. Recreate-class change. Details, privacy note, and host requirements under Clipboard image bridge below.

### local-model

Off by default (absent from the rendered MCP server list and refused by `cbox ai`) until configured. Wires an OpenAI-compatible endpoint (ollama, llama.cpp llama-server, vllm, or compatible) as: (1) `local-qwen`, a text-only MCP delegate exposing one tool, and (2) `local-qwen`, a `cbox ai` engine that drives `codex --oss --local-provider ollama` against the same endpoint. Set `CBOX_LOCAL_MODEL=on` plus `CBOX_LOCAL_MODEL_URL` and `CBOX_LOCAL_MODEL_NAME` via this wizard section, `cbox setup update local-model`, or `--config`; `cbox doctor` reports ACTIVE/CONFIG-ONLY/OFF. The endpoint always runs outside cbox (no GPU/CDI grant). The delegate health probe is `GET /v1/models`. See etc/docs/LOCAL_MODEL_RUNBOOK.md for the two setup paths (sibling container vs host process) and open decisions left to the operator.

### hermes

Off by default. The third console engine, alongside `claude` and `codex`: [Hermes Agent](https://github.com/NousResearch/hermes-agent) (NousResearch), run as `cbox run hermes`. Volume-only in v1 - there is no bind-mount mode and no `CBOX_HERMES_MODE` variable; `HERMES_HOME` (`$HOME/.hermes-cbox` in the container) is always backed by a named docker volume (`<CBOX_NAME>-hermes-home` global, `cbox-p<hash>-hermes-home` isolated).

Installed into the shared bins volume `cbox-bins-hermes`, exactly like the claude and codex CLIs: the host-side install container recreates the venv at `/opt/hermes` from scratch, runs `pip install hermes-agent[==<CBOX_HERMES_VERSION>]`, then reseeds the delegate template home at `/opt/hermes/delegate-home`. Because `pip install` executes arbitrary package build code, hermes always gets its own install container - it never runs alongside the writable claude/codex bins volumes - and the venv, pip, and `hermes setup` all run as the host user, not root; only the final 0555/0444 hardening of the seed is done as root. The venv is never reused across installs, so a previously planted `pip` or interpreter cannot re-execute itself on the next refresh, and the volume's integrity stamp is a tree digest over every file under `/opt/hermes`. The volume is mounted read-only in the running container and the image only prepares the mountpoint plus the `/usr/local/bin/hermes` symlink, so the image is hermes-invariant - toggling hermes or moving its version target never rebuilds the image. Supply-chain exception (explicit, v1 only): transitive pip dependencies are NOT pinned, and with the `latest` target the `hermes-agent` release itself moves on its own - a compromised or yanked release could change behavior without an explicit version bump here; pin an exact `x.y.z` to opt out.

Set `CBOX_HERMES=on` plus `CBOX_HERMES_VERSION` (default `latest`, or an exact `x.y[.z[.w]]` pin), `CBOX_HERMES_PROVIDER` (`local`, `nous`, `openrouter`, `openai`, or `anthropic`; default `local`), and for `local` provider `CBOX_HERMES_MODEL_URL` plus `CBOX_HERMES_MODEL_NAME` via this wizard section, `cbox setup update hermes`, or `--config`. This is a recreate-class change (`SEC_APPLY[hermes]=recreate`): compose recreates the container, and the binary itself lands via `cbox reinstall-bins` or the next autoupdate pass.

Managed-keys ownership: provider, base URL (local provider only; `/v1` appended if missing), and model name are re-applied on every `cbox run hermes` via the official `hermes config set model.provider|base_url|default` CLI - never a copy-if-absent seed, never a hand-written YAML merge for these three keys. Any other key in `~/.hermes-cbox/config.yaml` that the user or hermes itself sets is left untouched between starts, with one more managed exception: `mcp_servers` (see below), which is a hand-written top-level block replace precisely because `hermes config set`'s dotted-key CLI cannot express a nested mapping (its own model names contain dots, which collide with the dotted-key syntax) and `hermes mcp add` has no non-interactive flag for env maps, timeouts, or the enabled switch. Secrets (`.env` under `HERMES_HOME`) and Nous OAuth login are manual, host-operator steps: `cbox shell` into the running container, then run the relevant `hermes` auth/config command by hand.

MCP servers for hermes: cbox's MCP registry (`etc/mcp/delegates.json`, rendered by `etc/mcp/render_mcp.py`) now has a third render target alongside `claude` and `codex`. `regen_all` writes the rendered set to `generated/hermes/mcp_servers.yaml` (mounted read-only into the container next to `managed.env`, at `/etc/cbox/hermes-managed/`) whenever `CBOX_HERMES=on`; on every `cbox run hermes`, the entrypoint replaces the `mcp_servers:` top-level block in `~/.hermes-cbox/config.yaml` with that file's contents (a block replace, not a general YAML parse - cbox owns the entire block it writes, so no other key in the file is touched). An entry only reaches hermes if its `_cbox.available_to` list in `delegates.json` names `hermes` explicitly; today none does, so the default render is `mcp_servers: {}` and this is inert until an entry opts in (a decision for the entry's owner, not made here - `container-exec`, notably, is not opted in yet). `timeout` (hermes defaults to 300s) is carried through explicitly from the entry's `tool_timeout_sec` so long-running tools do not silently hit hermes's own default. An entry gated by `enabled_when_env` that names `hermes` but whose gate is currently unset renders with hermes's native `enabled: false` rather than being omitted, so `hermes mcp list` shows it as present-but-off instead of it simply not existing. Caveat that matters: each configured server becomes its own `mcp-<server>` toolset, auto-generated by hermes - this is a *different* mechanism from `agent.disabled_toolsets` (the knob the hermes-delegate section's qa mode uses to strip `terminal,file,web`). A tool given to hermes through `mcp_servers` is not covered by that strip list at all, so opting an entry in here can silently bypass a toolset restriction set up elsewhere for the same hermes instance.

Degraded toolset note: the image ships the `hermes-agent` pip package only - no headless-browser or ffmpeg extras are installed, so any Hermes skills that depend on them are unavailable.

Refresh safety: when `cbox reinstall-bins` or autoupdate refreshes the hermes venv, a failed refresh restores the previous venv from an in-volume backup (rollback via a `.prev` directory). A successful install removes the backup.

First use: enable this section (`cbox setup update hermes` or the wizard), then run `cbox reinstall-bins` on the host to install hermes into the shared bins volume. Recreate the container with `cbox up` (or the next `cbox run hermes`), then `cbox run hermes`.

`cbox doctor` reports ACTIVE/CONFIG-ONLY/OFF for this section.

`CBOX_HERMES_HOOKS` (enum `off`/`on`, default `off`) is an experiment gate. `on` renders the cbox `hooks:` block into the hermes config via a block-replace apply and stages `hermes_guard_bridge.py` (an armored wrapper: any internal error degrades to allow-with-stderr, since hermes fails open on crash). The `_hermes_hooks_preflight` refuses `hooks_auto_accept` when the rendered block or any referenced guard script is container-writable (adapter law). `off` (default) keeps today's hermes config byte-for-byte. The binding stays `gated:hermes-hooks-experiment` until the host runbook verifies the pinned hermes version honors block-JSON and confirms crash=allow.

### hermes-delegate

Off by default. A zero-cost local-model tier callable by `claude` and `codex`: an MCP delegate tool (`hermes-local`) that shells out to one `hermes -z "<prompt>"` subprocess per tool call (plus up to three short-lived `hermes config set` subprocesses when a provider/base_url/model is configured - see Subprocess hygiene below). This is a separate concern from the `hermes` console engine above - `hermes mcp serve` (which exposes hermes's own messaging state) is not involved at all; the delegate is a small stdio MCP server (`etc/mcp/hermes_delegate_mcp.py`) modeled on the existing `local-qwen` delegate. When enabled, Claude receives a hermes-local relay subagent, and Codex receives a hermes-local entry in its MCP servers (rendered into the codex profile as `[mcp_servers.hermes-local]` when `CBOX_CODEX_MCP=1` and `CBOX_HERMES_DELEGATE=on`).

Requires the `hermes` console engine (`CBOX_HERMES=on`); `SEC_DEPS[hermes-delegate]=disable:hermes-off` forces `CBOX_HERMES_DELEGATE=off` whenever the console engine is off, both in the wizard and in `cbox config set`'s dep-gate. Set `CBOX_HERMES_DELEGATE=on` plus optional `CBOX_HERMES_DELEGATE_PROVIDER`, `CBOX_HERMES_DELEGATE_BASE_URL`, and `CBOX_HERMES_DELEGATE_MODEL` (default-inherited from the console engine's own `CBOX_HERMES_PROVIDER`/`CBOX_HERMES_MODEL_URL`/`CBOX_HERMES_MODEL_NAME` at ask-time, but stored and applied independently) via this wizard section, `cbox setup update hermes-delegate`, or `--config`. This is a restart-class change (`SEC_APPLY[hermes-delegate]=restart`), same as the other MCP delegates.

Ephemeral-home isolation (the core security property): every tool call creates a fresh `mktemp` directory, seeds it from a root-owned read-only template built at install time (`/opt/hermes/delegate-home` inside the bins volume, produced by `hermes setup --non-interactive` with skills/auth/db files stripped and permissions locked to 0555/0444), applies the configured provider/base_url/model to that ephemeral copy via `hermes config set` (the provider is mandatory, and `local` additionally requires a base URL - falling back to the console engine's `CBOX_HERMES_*` values; with neither set the server refuses the call rather than letting the endpoint come from a template the hermes package seeded for itself) (never a hand-parsed YAML write - an unparseable template can never poison the call), runs exactly one `hermes -z` subprocess against it, then removes the ephemeral directory in a `finally` block. `HERMES_HOME` for the delegate is never the console engine's `$HOME/.hermes-cbox` - the two never share a `state.db` or contend for one. At startup the server refuses to run unless the template is verified root-owned, non-group/other-writable, and symlink-free (`CBOX_HERMES_DELEGATE_HOME_TEMPLATE` is env-overridable, so this is checked at runtime, not just trusted from the image build); seeding itself also refuses (raises before any file is copied) if the template contains a `skills/` directory, `auth.json`, `mcp.json`, `.env`, or a `*.db`/`*.sqlite*` file, and never dereferences a symlink nested inside a template subdirectory.

Subprocess hygiene: the prompt is capped below `CBOX_HERMES_DELEGATE_MAX_PROMPT_BYTES` (default 32000) before spawn (hermes's `-z` flag takes the prompt as an argv string, not stdin, per the upstream CLI contract, so the cap is enforced pre-spawn rather than deferred to a stdin write); argv is an absolute list with no shell interpretation; the environment passed to the child is a minimal scrubbed set (`PATH`, ephemeral `HOME`/`HERMES_HOME`, fixed `LANG`, a stamped delegation-depth marker) - no inherited secrets; cwd is pinned to the ephemeral home; a wall-clock timeout (`CBOX_HERMES_DELEGATE_TIMEOUT_SEC`, default 300) governs the call; stdout/stderr are read incrementally with a hard byte cap (`CBOX_HERMES_DELEGATE_MAX_RESPONSE_BYTES`, default 1000000), never read-all-then-check; the `hermes config set` calls that apply provider/base_url/model are likewise read incrementally with a fixed 64KB per-stream cap, never an unbounded `communicate()`; ANSI/control sequences are stripped from the response by a linear-time byte scanner (not a backtracking regex, to avoid a pathological-input hang); the child runs in its own process group (`start_new_session=True`) and a timeout escalates SIGTERM then SIGKILL to the whole group; the process is reaped and the ephemeral directory removed in a `finally` regardless of outcome.

Memory is off by design: the ephemeral home already guarantees nothing persists past the call, and `hermes -z ... --ignore-rules` additionally skips auto-injection of `MEMORY.md`/`USER.md` context.

`available_to` is `["claude", "codex"]`. Depth-guarded identically to `local-qwen`: `CBOX_DELEGATION_DEPTH`/`CBOX_MCP_DEPTH` empties `tools/list` and refuses `tools/call` so a delegate spawned over MCP cannot spawn another one.

Concurrency: since every call shells out to the same local-model server, concurrent `hermes-delegate` calls (from claude and codex at once, or several parallel subagent calls) are serialized through a slot semaphore before the `hermes -z` subprocess is spawned. The slot count comes from `CBOX_HERMES_DELEGATE_MAX_CONCURRENCY` if set, else falls back to `OLLAMA_NUM_PARALLEL`, else defaults to 1 - always capped at 16. A call that cannot get a slot blocks for up to `CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC` (default 1500s) before returning a "model is busy" error rather than piling load on the endpoint. The slot files themselves live in `CBOX_HERMES_DELEGATE_LOCK_DIR` (default `/tmp/cbox-hermes-delegate-locks`). All three are `cbox config set`-able (section `hermes-delegate`) alongside `CBOX_HERMES_DELEGATE_MAX_CONCURRENCY`, restart-class like the rest of the section.

qa mode (the only mode implemented, `CBOX_HERMES_DELEGATE_MODE=qa`) pins the hermes child's terminal/file/web toolsets off per call via `hermes config set agent.disabled_toolsets` before the prompt runs, so the model answers from the prompt alone. `CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS` overrides the default toolset list (`terminal,file,web`); this is a config-level restriction enforced by hermes itself, not a sandbox around the process - the hermes child still runs with the container's own filesystem and network reach.

First use: enable `hermes` (`CBOX_HERMES=on`) and run `cbox reinstall-bins` so `/opt/hermes/delegate-home` exists, then enable `hermes-delegate` via the wizard or `--config` and restart. `cbox doctor` reports ACTIVE/CONFIG-ONLY/OFF for this section.

### ollama

Off by default (`CBOX_OLLAMA_MODE=off|on`). Machine-scoped infra service, not a per-project one: `SEC_SCOPE[ollama]=machine` (every other section is `project`-scoped). Ollama runs in its own owner compose project, `cbox-infra-u<uid>`, rendered under the user config dir at `config/cbox/infra/ollama` and labeled `cbox.kind=infra` / `cbox.component=ollama` - never embedded inside a generated cbox project, so it is never torn down by a per-project `compose down --remove-orphans` and there is exactly one instance per machine, not one per project.

Because the section is machine-scoped: the isolated per-project wizard (`run_local_wizard_subset`) never calls `step_ollama`, `cbox setup --local <root>` never asks about it and never writes `CBOX_OLLAMA_*` into a project's effective `cbox.conf` (the isolated derivation path strips those keys after `conf_save`), and `cbox config set` refuses `CBOX_OLLAMA_*` from inside an isolated project - run it from the global scope instead. The isolated runtime path (`cbox run`/`cbox shell` in an isolated project) re-reads `CBOX_OLLAMA_*` from the machine-level `cbox.conf` after sourcing the per-project file, so every project observes the same live value rather than a stale per-project copy.

Vars: `CBOX_OLLAMA_MODE` (`off|on`, default `off`), `CBOX_OLLAMA_IMAGE` (pinned image reference, default `ollama/ollama:0.32.5`), `CBOX_OLLAMA_GPU` (`off|cdi`, default `off` - a separate reservation from `CBOX_GPU`, targeting only the ollama service), `CBOX_OLLAMA_STORE` (`dedicated|shared`, default `dedicated` - a cbox-owned named volume/directory; `shared` mounts only the `models/` subdirectory of a host ollama directory read-write and refuses to start while a host ollama daemon is detected), `CBOX_OLLAMA_STORE_PATH` (host path, shared mode only, default empty), `CBOX_OLLAMA_PORT` (default `11434`; informational only - it is never published on the host, it is only the port the shared-store host-daemon probe checks), `CBOX_OLLAMA_NUM_PARALLEL` (default `1`).

`CBOX_OLLAMA_NUM_PARALLEL` and the hermes-delegate section's `OLLAMA_NUM_PARALLEL`/`CBOX_HERMES_DELEGATE_MAX_CONCURRENCY` name the same upstream concept (ollama's own request-parallelism knob) but are independent settable keys in two different sections - the delegate's concurrency slot count falls back to `OLLAMA_NUM_PARALLEL` only when `CBOX_HERMES_DELEGATE_MAX_CONCURRENCY` is unset. When this owner ollama and the hermes-delegate (or local-model) endpoint are the same server, the operator is expected to set `CBOX_OLLAMA_NUM_PARALLEL` to the real server value and mirror it into `OLLAMA_NUM_PARALLEL` (or set `CBOX_HERMES_DELEGATE_MAX_CONCURRENCY` explicitly) - cbox does not infer one from the other.

This is an `infra-reconcile`-class change (`SEC_APPLY[ollama]=infra-reconcile`): neither `cbox down && cbox run` nor a topology/recreate cycle on the current cbox compose project touches the owner project. Apply with `cbox ollama reconcile`, which creates, updates, or tears down the owner project to match `CBOX_OLLAMA_MODE` and the other vars.

Networking: one `internal:true` docker network per scope (`cbox-ollama-u<uid>-global`, `cbox-ollama-u<uid>-p<projecthash>`), never one shared network across scopes - `internal:true` blocks external routing but not member-to-member traffic, so a single shared network would let unrelated cbox containers reach each other's ollama. Each network joins exactly one cbox container plus the one ollama container, with the ollama container aliased `ollama` on each, so the endpoint is always `http://ollama:11434` regardless of scope. Neither the egress network nor the tinyproxy/dante proxy carries ollama traffic; a per-scope model network's service name goes into `NO_PROXY` always (including under egress lockdown, since a direct route genuinely exists there), while external endpoints (a host IP, a remote tunnel IP) are never added to `NO_PROXY` under egress lockdown. The `NO_PROXY` entry is the bare token `ollama`; some clients (e.g. Python's `urllib`) do a no-dot-boundary suffix match, so a hostname ending in `ollama` would also be treated as proxy-exempt - under lockdown that only means the direct attempt fails (no route exists to it), so this is not currently an escalation, but the exemption must never be widened to a wildcard/pattern.

`cbox doctor` reports `ollama` ACTIVE/CONFIG-ONLY/OFF for this section (host-side reads `CBOX_OLLAMA_MODE` from the machine `cbox.conf` directly; inside a container it is HOST-CHECK, since ownership is decided by the host owner project).

Caveat: the per-scope networks isolate scopes at layer 3 only. All scopes still share one unauthenticated ollama instance with one model namespace, one GPU, and one disk - any project can delete or replace a model another project relies on, or exhaust GPU/disk for everyone. Network separation does not prevent this cross-scope influence.

### wireguard

Off by default (`CBOX_WG_MODE=off|server|client|both`). Machine-scoped infra service, not a per-project one: `SEC_SCOPE[wireguard]=machine`. The sidecar reuses the same owner compose project as ollama (`cbox-infra-u<uid>`), joining its internal network to reach the ollama service, and its externally routed network (`wg-egress`) whenever wireguard is active - server mode publishes the UDP port there, client mode uses it only to dial out to the configured remote endpoint (no published port) - mirroring how the egress proxy sidecar is attached, never a second owner project.

Blast radius: the sidecar is dual-homed whenever active - it has NET_ADMIN, `/dev/net/tun`, read-only access to the private key, unrestricted outbound internet on `wg-egress`, and layer-3 reach to the unauthenticated ollama API on the infra internal network. A compromise of the sidecar means full model-server control plus an un-proxied egress path that bypasses this repo's egress-lockdown model; this is the accepted cost of a userspace TCP forwarder that never routes.

The central security decision is no routing: the sidecar terminates the tunnel and forwards exactly one TCP service in each direction with a userspace forwarder. It never enables IP forwarding, never adds NAT or masquerade rules, and never acts as a network gateway - it only accepts a TCP connection on one port and opens another TCP connection to one fixed destination, so it cannot route arbitrary traffic anywhere. The sidecar never joins any per-scope cbox network; only the ollama service and one cbox container belong to those.

Vars: `CBOX_WG_MODE` (`off|server|client|both`, default `off`), `CBOX_WG_IMPL` (`auto|kernel|userspace`, default `auto` - rootless user namespaces may not support a kernel WireGuard interface, so a userspace implementation is the deterministic fallback), `CBOX_WG_ADDRESS` (this node's tunnel address in CIDR form, default empty), `CBOX_WG_LISTEN_PORT` (server role, default `51820` - the single intentional exposure in this feature, key-authenticated by WireGuard unlike the unauthenticated ollama API, which is why the ollama port itself stays unpublished), `CBOX_WG_PUBLISH_ADDR` (the host address the UDP port is published on, default empty meaning all addresses), `CBOX_WG_PEER_ENDPOINT` (legacy scalar client-role remote, host:port), `CBOX_WG_PEER_PUBKEY` (legacy scalar client-role remote's public key), `CBOX_WG_PEER_ADDRESS` (legacy scalar client-role remote's tunnel address in CIDR form), `CBOX_WG_KEEPALIVE` (seconds, default `25`), `CBOX_WG_FORWARDS` (server-role forward table, default empty - space-separated `listen_port:target_host:target_port` entries; see the forward table paragraph below).

The three legacy `CBOX_WG_PEER_*` scalars are kept working as an alias for exactly one client-role peer: `gen_wireguard_conf_into` (`templates/generators.sh`) still renders a `[Peer]` stanza from them whenever any of the three is non-empty, alongside whatever client-role peers now live in the peer store - so an existing single-remote client setup that predates the peer store needs no migration.

Because the section is machine-scoped, the same rules apply as for `ollama`: the isolated per-project wizard never calls `step_wireguard`, `cbox setup --local <root>` never writes `CBOX_WG_*` into a project's effective `cbox.conf`, and `cbox config set` refuses `CBOX_WG_*` from inside an isolated project.

Key material lives under `~/.config/cbox/infra/wireguard` on the host: `privatekey` (created at mode 0600 before any content is written, never world- or group-readable), `publickey` (0644), and `peers` (0600, one line per peer: `name|pubkey|allowed-address|endpoint|capability`). None of these files are ever mounted into a workspace container, only read-only into the sidecar. If `wg` (wireguard-tools) is not installed on the host, key generation fails naming the missing package rather than writing a placeholder key. Every peer's allowed address must be a single host (`/32`); a wider `AllowedIPs` is refused because it would let one peer claim other peers' addresses. Generating a peer's own key locally is optional - generating it on the peer itself is the documented preference; a peer configuration handed to the other machine contains only public material (plus that peer's own private key only if cbox generated it locally).

The peer store holds both roles at once, on the same `wg0` interface: a peer record with a non-empty `endpoint` field is a client-role peer (this node dials it, `Endpoint = ` is rendered in its `[Peer]` stanza); a peer record with an empty `endpoint` is a server-role peer (it dials this node, no `Endpoint` line). `cbox wg peer add <name> <pubkey> <addr/32> [--endpoint host:port] [--capability ...]` sets the role by whether `--endpoint` is passed. Both roles coexist freely - `cbox wg peer list` shows each peer's resolved role (`role=client (dials host:port)` or `role=server (dials us)`). The four legacy `CBOX_WG_PEER_*` scalars remain a backward-compatible alias for one additional client-role peer, rendered alongside the store; an existing `peers` file written before this addition has exactly three pipe-delimited fields per line and continues to parse and render identically (missing trailing fields read as empty, which is the pre-existing server-role, no-capability-restriction behaviour - see the capability paragraph below).

Every peer record also carries a `capability` field: `none`, `ollama`, `session`, or a comma-set of `ollama` and `session` (mixing `none` with another value is rejected). `cbox wg peer add` defaults a new peer's capability to `ollama` when `--capability` is omitted - the minimum capability that is actually useful given this feature exists to share ollama access; `none` would be a peer that can reach nothing over the tunnel-forwarded services. A peer record written before this field existed (three-field legacy line) reads its capability as empty, and cbox treats empty the same as `ollama` - matching exactly what that peer could already do before capability existed, so no existing peer silently loses or gains access on upgrade.

Honesty about enforcement: `capability=session` is not enforced by anything yet - it is recorded for the session broker to read in a later phase. `capability=ollama` (or the empty/legacy default) is NOT currently enforced per peer either, and cannot be with the current forwarder: the `socat` listener for each forward-table entry binds this node's own tunnel address with `fork,reuseaddr` and no source-address filter, so every peer that can route a packet to that address reaches the forwarded service identically, regardless of what its stored capability says. The capability field is bookkeeping and future-facing policy, not a present isolation boundary - do not read "capability=none peer" as "this peer cannot reach ollama" if it holds a valid tunnel address at all; a peer with a tunnel address but capability=none simply is not the documented supported configuration, not a technically enforced denial. The real per-peer enforcement fix is a named follow-up: a source-address filter at the forward point (nftables scoped to each peer's `/32`, or socat's `range=`/`tcpwrap=`), not yet implemented.

Rootless reality: the sidecar needs `NET_ADMIN` and `/dev/net/tun`, which does not exist inside a cbox workspace container - this is a host prerequisite checked at runtime, not assumed. A published port under rootless docker goes through the rootless port forwarder, which can rewrite the observed source address in status output; this is harmless for WireGuard (peer authentication is by key, not source address) but means a displayed peer endpoint is not necessarily the true remote address.

This is an `infra-reconcile`-class change (`SEC_APPLY[wireguard]=infra-reconcile`), reusing the same apply command as `ollama`: `cbox ollama reconcile` creates, updates, or tears down the shared owner project to match both `CBOX_OLLAMA_*` and `CBOX_WG_*`. Turning the feature off (`CBOX_WG_MODE=off`) leaves no interface, no key, no published port, no container, no network, and no image build beyond what `ollama` already needs, and leaves nothing listening.

The sidecar is a second service (`wireguard`) rendered into the same owner `docker-compose.yml` as `ollama`, built from a small Alpine image (`wireguard-tools`, `wireguard-go` for the userspace fallback, `socat` as the TCP forwarder, `supervisor`) tagged `cbox-wg-img:<hash>` where `<hash>` covers the Dockerfile, the supervisord program list, and the startup script - the same build-input-hash pattern the egress proxy image uses. At container start, the private key is read from the read-only-mounted key file and substituted into the rendered `[Interface]` template to produce the runtime `wg-quick` config at `0600`; the rendered template on disk always carries a placeholder, never the real key. The startup script also asserts `net.ipv4.ip_forward=0`, that every `AllowedIPs` entry is a `/32`, that this node's own `Address` prefix is no wider than `/8`, and (fourth) that every rendered forward resolves to one fixed host and one fixed port - no wildcard `bind=` and no shell metacharacter anywhere in a rendered `socat` target - before bringing the interface up, so a misconfiguration cannot silently turn the sidecar into a router or an injection point.

Server-role TCP forwarding is data-driven: `CBOX_WG_FORWARDS` is a space-separated list of `listen_port:target_host:target_port` entries (`templates/generators.sh`, `_cbox_wg_forward_entries`/`gen_supervisord_wireguard_conf_into`), each rendered as its own `[program:wg-forward-<n>]` supervisord block - `exec socat TCP-LISTEN:<listen>,bind=<this node's tunnel address>,fork,reuseaddr TCP:<target_host>:<target_port>`. Validation is hard because these strings are interpolated straight into a supervisord command line: `listen_port`/`target_port` must be digits, 1..65535; `target_host` must be a docker-service-name-shaped string (`[A-Za-z0-9][A-Za-z0-9_.-]*`, max 63 chars) - a LAN IPv4 literal is refused even though it would otherwise match that charset, because this feature's own no-routing posture means a forward target must be something the sidecar can legitimately reach as a named peer on its own network, not an arbitrary host elsewhere on the LAN; listen ports must be unique across the table. When `CBOX_WG_FORWARDS` is empty and `CBOX_OLLAMA_MODE=on`, cbox synthesises exactly one entry (`<CBOX_OLLAMA_PORT-or-11434>:ollama:11434`) so an installation from before the forward table existed renders byte-for-byte the same single ollama forward it always did - this is the documented backward-compatibility path, not a special case. The client-role forwarder is unchanged: it listens on the infra network under the `wg-remote-ollama` alias and forwards to the configured remote tunnel address, driven by the legacy `CBOX_WG_PEER_*` scalars exactly as before. `CBOX_WG_IMPL=auto` probes for the kernel WireGuard module at container start and falls back to `wireguard-go` only if it is absent; `kernel`/`userspace` force the choice.

In client mode, the forwarder that dials the remote ollama over the tunnel listens under a stable service alias (`wg-remote-ollama`) on the infra internal network (the sidecar's `default` network); that alias is an internal docker service name with a genuine direct route, so it belongs in `NO_PROXY` always (the rule already implemented for the `ollama` alias), while the remote endpoint itself (an external host:port) is never added to `NO_PROXY` under egress lockdown. A workspace container reaches that alias because per-scope network reconciliation also connects the workspace container (never the sidecar) to the infra project's `default` network when the client role is active - the sidecar itself never joins a per-scope cbox network, only the shared infra network.

`cbox doctor` reports `wireguard` ACTIVE/CONFIG-ONLY/OFF for this section (host-side reads `CBOX_WG_MODE` from the machine `cbox.conf` directly; inside a container it is HOST-CHECK, since ownership is decided by the host owner project).

Verbs: `cbox wg status|up|down|keygen|peer {add|rm|list|config}`, host-only and wired into the hub exactly like `cbox ollama`. Every state-changing subcommand takes the same machine lock as the `ollama` verbs (`~/.config/cbox/infra/ollama.lock`), so the two features cannot race on the shared owner project; `status` and `peer list` take the lock in shared mode, while `peer config` takes it exclusively because it can generate this node's keypair on first use and must not race a concurrent `keygen`/`peer add`/`peer rm`. `status` distinguishes OFF/CONFIG-ONLY/ACTIVE and, when active, reports the interface, whether the kernel or userspace implementation is actually running, the listen port, and each configured peer's last handshake (via `wg show` inside the sidecar) - it never prints private key material, and it notes that under rootless docker a peer's displayed endpoint may be the port forwarder's address rather than the peer's true remote address. `peer add <name> <pubkey> <addr/32> [--endpoint host:port] [--capability none|ollama|session|ollama,session]` validates name/pubkey/address, refuses duplicates (including against the legacy `CBOX_WG_PEER_*` scalar remote) and any address wider than `/32`; passing `--endpoint` makes it a client-role peer (this node dials it), omitting it keeps the pre-existing server-role behaviour (it dials this node); `--capability` defaults to `ollama` when omitted. `peer add`/`peer rm` both try to reload the running interface in place (`wg syncconf`, so other peers are not dropped) and fall back to restarting the sidecar if that is not possible, saying so. `peer list` prints each peer's name, public key, allowed address, resolved role, and capability. `peer config <name>` prints a ready-to-paste `[Peer]` block for the named peer containing this node's public key, endpoint, and that peer's allowed address - it generates the peer's own private key locally only when `--generate-key` is explicitly passed, and both the output and the flag itself state that the peer generating its own key is the preferred path. A runtime preflight (shared with `cbox ollama reconcile`) reports a clear, actionable message rather than an opaque failure when `/dev/net/tun` is missing or `wireguard-tools` is not installed for the server role; these preflight paths are unexercised in a container without `/dev/net/tun` or a docker socket.

## Global vs isolated mode

Set `CBOX_MODE` in `cbox.conf`:

- **global** - one container for all workspaces, started by `cbox up`/`down`/`restart`.
- **isolated** - one container per project (keyed by git top-level or cwd if not a work-tree). Per-project config lives in `~/.config/cbox/projects/<path-hash>/` (never mounted into any container, so a process cannot rewrite its own launch config).

In isolated mode, `claude`/`codex` resolve the project from cwd and launch/reuse that project's container. First run in an unconfigured project (with TTY) prompts: set up new, derive from global, or cancel.

Session scope (isolated mode only): `CBOX_SESSION_SCOPE=isolated` (default) mounts only this project's sessions; `global` shows all. Isolated scope uses symlink farms to keep container and host session views in sync as work moves between scopes. In-scope project slugs (including git-worktree slugs) are materialized as real directories with per-file symlinks instead of whole-directory symlinks, so the Claude Code /resume picker sees every in-scope project. Locally created transcripts are absorbed to the host per-file after a 60s settle with open-fd checks.

## Image hash and per-project input

Each project's Docker image is tagged `cbox-img:<hash>`, where `<hash>` is the SHA256 of declared inputs: base image digest, package list, Claude/Codex target versions, GPU/egress flags, and Dockerfile COPY sources. Two projects with identical inputs share one image and its per-hash volumes.

The hash is declared inputs, not "freshest bits": it pins the base image by digest (with bounded TTL, default 3600s) but does not re-run `apt-get upgrade` every launch on an unchanged image. "Rebuild if stale" means stale relative to recorded inputs, not upstream packages.

## Lifecycle: global mode

`cbox up [--gpu]` starts the container. `cbox down` stops it. `cbox restart [--gpu]` restarts. Volumes persist across stop/start cycles.

Binaries mount read-only (install once on host, reuse everywhere). Version pin conflicts between projects are refused (see Binaries section in README).

## Lifecycle: isolated mode

A project's container starts on first `claude`/`codex`/`cbox run` and stops the instant the last live process exits (no idle timeout). "Live" is determined by matching `/proc/<pid>/exe` against the binary path recorded in shared volumes' metadata; a copied binary cannot keep the container alive. Engine infrastructure processes do not count as live: the Claude daemon (`claude daemon run`), its PTY helpers (`--bg-pty-host`, `--bg-spare`), and `codex mcp-server` relay subprocesses are ignored, so a lingering daemon or MCP relay never keeps an otherwise idle container running.

Two windows in the same project share one container; only the last window's exit triggers the stop.

Auto-stop hardening: the reap also runs on SIGINT/SIGTERM/SIGHUP of the host wrapper, so killed terminals still clean up. A failed liveness probe is retried once; persistent probe failure leaves the container up with a stderr note for later manual cleanup or `cbox gc` retry. Every `cbox run` spawns a background, lock-guarded `cbox gc` pass so lingering idle containers from crashed clients are cleaned on the next cbox use.

`cbox gc` is the backstop for orphaned containers (wrapped processes killed with SIGKILL, backgrounded processes, raw `docker exec`): it samples process count twice (10 seconds apart) under an exclusive lock and stops only idle containers.

`cbox down` refuses when a session looks live: it takes the same exclusive, non-blocking lock `cbox gc`/`_reap` use on `session.lock` (isolated mode; global mode has its own `session.lock` next to `docker-compose.yml` under the install dir), and if the lock is held or the probe reports a nonzero or unknown live-process count, it prints the probe result and exits 1 instead of stopping the container. Pass `cbox down --force` to stop anyway (still prints what was live). A probe result that cannot be parsed as a number is treated as live (fails closed). `cbox shell` (both modes) holds the shared session lock for its lifetime, so an open shell blocks `down` via the lock even though the process liveness probe only recognizes `claude`/`codex`, not a bare shell. `cbox run`/`cbox up` in global mode do not yet hold this lock, so a plain `cbox down` there still relies on the process probe alone for a running `claude`/`codex` session (isolated-mode `cbox run` holds the lock via `_session_run`).

`cbox restart` (global mode only) always forces past this guard - it is equivalent to `cbox down --force` followed by `cbox up`, so a live session is torn down without the refusal a plain `cbox down` would give. If a live process count is found, the same "--force: ... stopping anyway" notice `cbox down --force` prints is shown before the container stops.

`cbox shell` and `cbox logs` work in isolated mode too: `cbox shell` starts the project container if needed, execs `/entrypoint.sh bash` in it, and holds the same shared session lock a `cbox run` session holds for its lifetime - so an open shell counts as a live session for `cbox down`'s liveness check, and the container reaps normally once the shell exits. `cbox logs [args]` streams the project container's compose logs. Both mirror the existing global-mode `cbox shell`/`cbox logs`.

## Storage modes (mount vs volume)

Each of `~/.claude` and `~/.codex` is independent:

- **mount** - host directory bind-mounted. Data lives on host; survives machine switches and volume removal.
- **volume** - Docker named volume. Logins and state survive restarts but exist only in Docker. Use `cbox backup` to archive global volumes to `./backups/`.

Mixing modes is supported. Never use `docker volume prune` (it deletes volumes not attached to running containers and will destroy volume-mode state). `cbox down` never removes volumes.

The proxy sidecar's `internal` and `egress` networks are labeled `cbox.kind=proxy-net`. `cbox down` (both modes) runs `compose down --remove-orphans` and then sweeps any labeled proxy network that has zero endpoints, and `cbox gc` does the same sweep - so a network stranded by turning the proxy off (its `networks:` block disappears from the render) or by renaming the profile is reclaimed instead of accumulating. Networks created before this labeling existed are not matched by the sweep; remove those once by hand with `docker network rm`.

**Backup and mode switching:** `cbox backup` archives the global claude/codex/venv/ssh volumes to `./backups/` but does not cover isolated per-project volumes (named `cbox-p<hash>-*`); the command prints a hint with a per-volume archive command for manual backup. When switching `~/.claude` or `~/.codex` from mount to volume mode, the wizard offers to back up the outgoing host directory at switch time. Agents and claude-md sections prune files that were deselected (managed files shipped by cbox only - user-created files are untouched); disabling history removes the managed policies/templates it previously deployed. With claude volume mode plus isolated session scope, the per-project session directory `~/.claude/projects/<slug>` is a host bind (kept host-visible for /resume) and lives outside the claude volume - back it up as host files, not via volume backup.

## Clipboard image bridge

Clipboard image bridge (`CBOX_CLIPBOARD_MODE`, default `off`). In `bridge` mode a per-session host helper (`etc/clipboard/clip_bridge.py`) serves the HOST clipboard read-only over a unix socket in a private 0700 runtime dir mounted at `/run/cbox-clip`, and a `wl-paste` shim mounted at `/usr/local/bin/wl-paste` inside the container answers Claude Code's image paste (Ctrl+V). Image MIME types only (png/jpeg/webp/gif/bmp), 64 MiB cap; text paste stays on the terminal's bracketed paste path.

Privacy note: while enabled, any process in that container can read the host clipboard's image content.

Host requires wl-clipboard (Wayland) or xclip (X11). Choosing `bridge` in setup probes the host for a usable backend (`clip_bridge.py --probe` prints `wayland`, `x11` or `none`, the same decision the running bridge makes per connection); when none is found, setup names the missing package and offers to install it with the host package manager (apt-get/dnf/yum/pacman/zypper/apk), or prints the exact command when it cannot run it. The package is picked from the session type: `wl-clipboard` when `WAYLAND_DISPLAY` is set, otherwise `xclip` for `DISPLAY`. Installing it takes effect immediately - the backend is re-detected per paste, no rebuild and no restart - while fixing a missing `WAYLAND_DISPLAY`/`DISPLAY` needs a new cbox session, because the helper inherits its environment at launch. `cbox up` prints a one-line warning when the bridge starts with no host backend, instead of failing silently at the first paste. Compositors without wlr-data-control/ext-data-control (GNOME/mutter) expose no clipboard to `wl-paste` at all; setup reports that as a failed read probe. macOS has no backend (no pbpaste path in the bridge).

## Behavioral read-only

Inside the container, these are always mounted read-only:
- `~/.claude/CLAUDE.md`
- `~/.claude/agents/`
- `~/.claude/policies/`
- `~/.claude/templates/`
- `~/.claude/hooks/`
- `/etc/claude-code/managed-settings.json` (prompt-injection hardened)
- `~/.claude.json` (Claude Code seed)

This prevents prompt injection: subagent bodies are executed as system prompts, so a writable agent file is a persistent injection foothold.

Consequence: the global #shortcut in Claude Code does not work inside the container. Manage policies on the host via `cbox setup update claude-md`.

Project-local files in `./.claude/` of a mounted workspace stay writable (same as the rest of the workspace). Runtime state (`~/.claude/projects/`, `~/.claude/agent-memory/`, credentials) remains writable.

The container runs with CLAUDE_CONFIG_DIR=~/.claude-cbox, so its live state file is ~/.claude-cbox/.claude.json. This maps to a plain file inside the claude-config directory bind: `<effective dir>/claude-config/.claude.json` per project, or `generated/claude-config/.claude.json` in global mode. Each regen re-renders its `mcpServers` from the delegate registry and preserves every other key the container wrote (trust dialog, onboarding). Separately, the operator's host ~/.claude.json is bind-mounted read-only at ~/.claude.json inside the container as a seed for initial state - it is not the live state. One-shot import: drop a `.claude.json.migrate` file (valid JSON) next to the live state file and the next regen adopts it as the initial state (operator import wins, even if state already exists) and deletes the migrate file. A malformed JSON migrate file is discarded without adoption; if the copy fails the migrate file is kept for retry.

## Wizard re-runs and host activation

After the initial wizard run:

- `cbox setup update <section>` re-runs one section and regenerates related outputs.
- `cbox setup update` (no section) re-renders all artifacts and re-blesses the templates (CBOX_TPL_SHA) without changing configuration. This is the standard step after deploying new cbox files; the blessing now covers both `_common.sh` and `templates/generators.sh`, so a deploy of either requires the re-bless.
- `cbox install-hooks` stages and diffs hook scripts, then confirms before installing to the host.
- `cbox restart` reloads configuration and restarts the container.
- `cbox setup update --config <file>` replicates a saved `cbox.conf` on another machine (non-interactive; skips host-side writes).

For continuity migration (moving project brain from `~/.claude/` to `./.cbox/`):

```bash
cbox continuity migrate
```

## cbox config

Headless per-key settings get/set, for scripting and quick edits without the interactive wizard. Mode-dispatched the same way as `down`/`verify`: isolated mode reads/writes the per-project effective `cbox.conf` under `~/.config/cbox/projects/<hash>/`; global mode reads/writes the install-dir `cbox.conf`. No configuration in scope yet is a clear error pointing at first-run - it never silently prints defaults.

`cbox config get [KEY | --section NAME | --all]` prints plain `KEY=VALUE` lines: a single key, every var in one wizard section, or every section (grouped by a `# section` header line) with `--all`. An unknown key or section name errors and lists the valid section names.

`cbox config set KEY=VALUE [KEY=VALUE...]` stages a change and reports; it never applies automatically to a running container. Keys are restricted to a fixed whitelist - the union of every wizard section's variables (`sections.sh` `SEC_VARS`) - and must match `^[A-Z][A-Z0-9_]*$`. Values are rejected outright (never sanitized) if they contain a newline, carriage return, or other control character. Every whitelisted variable has its own validator mirroring the constraint the setup wizard step enforces for it (enum values, numeric ranges, URL shape, path shape, the hermes version pin grammar, the hermes provider enum, etc.); a var with no wizard constraint beyond free text only enforces the no-control-chars rule. Rejections name the variable, the offered value, and the accepted form.

A dependency gate then re-evaluates every touched variable's section against `sections.sh` `SEC_DEPS` (the same `disable:`/`dictate:` vocabulary `setup.sh`'s `section_dep_gate` uses, re-implemented in `cbox` against the fully staged configuration - `setup.sh` itself is never sourced): a set that a dependency rule would force back is rejected outright, naming the rule (for example `CBOX_RESTART_POLICY` in isolated mode - `disable:isolated-mode`). Only the `disable:` side is enforced this way; `dictate:` tokens (`codex-mcp`, `codex-progress`, `continuity`) mark sections where the setup wizard also auto-deploys or removes hooks as a side effect - `config set` does not replicate that side effect, so the stage-and-report table prints an extra note for those sections pointing at `setup.sh` to bring hook state back in sync.

Transaction (isolated mode): an exclusive `flock` on `<effdir>/.regen.lock` is held for the whole operation. `cbox.conf` and the `generated/` directory are backed up first; the new config is written atomically (temp file + `mv`), re-sourced, and the same regeneration path the engine-start flow uses runs against it. On any failure both backups are restored verbatim and the failure is reported - `cbox.conf` and `generated/` are left byte-identical to their pre-set state, and no manifest or `pending.apply` is touched. On success the backups are dropped and both manifest subsystems are stamped in order: the config manifest (`_cbox_manifest_write`) first, then the generated-artifacts manifest (`_cbox_manifest_write_generated`) - manifests are written last and prove file integrity, not that a running container has picked up the change. `pending.apply` is then written with one `section=apply-class` line per touched section, and a stage-and-report table is printed naming, per touched section, its apply class and the exact command to run: `none` takes effect on the next `cbox run`; `shell` needs `source ~/.bashrc`; `restart` needs `cbox down && cbox run <bin>`; `recreate`/`topology` need `cbox down && cbox run <bin>` (compose recreates); `rebuild` rebuilds the image automatically on the next `cbox run` (image.inputs changed). A malformed, colliding, or drifted manifest refuses the set outright and points at `setup.sh --local --from-global` - a single-key edit never routes through the re-bless path, which re-derives the whole profile and would clobber local overrides.

Global mode uses the same lock file (`<install-dir>/.regen.lock`) plus a compare-and-swap on the sha256 of `cbox.conf` as loaded: if the file on disk differs from what was loaded right before the final `mv`, the set aborts naming the race (a concurrent writer) instead of overwriting it blind. Global mode also keeps a `cbox.conf.bak` backup and does not delete it on success (unlike isolated mode, which drops its backup once the transaction lands) - this is a deliberate, documented asymmetry: isolated mode has the manifest as its safety net, global mode does not, so the `.bak` file is the recovery path.

`cbox config set` refuses entirely when run inside the container (detected the same way `doctor`/`_cbox_doctor_in_container` does - `HOST_HOME`/`HOST_USER` set plus `/entrypoint.sh` present); `cbox config get` is unaffected and works in both contexts. There is no automatic apply in v1: `set` only stages configuration and generated artifacts and reports the apply class - it never touches a running container.

The engine-start regen path (`_run_isolated`'s call into `_gen_effective`, and `_run_global`/`up`'s call into global prepare, both before `docker compose up`/`exec`) takes the same per-project or install-dir `.regen.lock` around its regen-and-manifest-write step only - not around the image build or the session itself - so a `cbox config set` cannot race a concurrent `cbox run`'s regen-and-manifest-write step, but a long-running build or session does not hold the lock and does not block a concurrent `config set`.

`cbox config pending` prints the current project's (or global) `pending.apply` file, or `none` if nothing is staged; `cbox config pending --clear` removes it. `cbox doctor` reports a `config-pending` row: `OFF` when no `pending.apply` exists, `CONFIG-ONLY` listing the staged sections when one does, `HOST-CHECK` inside the container (the file lives host-side, outside the container's mounts).

## Operational commands

- `cbox ls` - list running isolated project containers: path hash, image hash, root directory.
- `cbox config get/set/pending` - headless per-key settings; see "cbox config" above.
- `cbox images [list|rm <hash>]` - list or remove per-project cbox-img images with reference counting. Used after image changes or to free space.
- `cbox login [oauth-url]` - host-side bridge for the Claude OAuth callback when logging in inside the container. Paste the printed OAuth authorize URL or run `/login` inside `cbox run claude` and paste the result here.
- `cbox login-codex` - equivalent for Codex device auth (egress mode only); bridges port 1455 to the container.
- `cbox gc` - sweep orphaned isolated containers and old binary volumes (run regularly, especially during development).
- `cbox net-refresh` - restart all cbox egress proxy sidecar containers (images `cbox-proxy:*` / `cbox-proxy-img:*`) so they pick up the host's current DNS after a network/wifi change; main containers are never restarted. Optional: install the NetworkManager dispatcher hook with `sudo install -m 0755 <installdir>/etc/host/90-cbox-net-refresh /etc/NetworkManager/dispatcher.d/` to auto-run the same refresh on connectivity changes.
- `cbox ollama {status|up|down|pull <model>|reconcile}` - machine-scoped ollama owner project control (host-side only, applies `SEC_APPLY[ollama]=infra-reconcile`). Status shows the current state (OFF/CONFIG-ONLY/ACTIVE). Up/down start or stop the owner project. Pull stops the serving container, then downloads the model in a temporary ephemeral container on its own routable network (deliberately not internal, so the registry is reachable, and torn down right after the pull), then restarts the server. Reconcile creates, updates, or tears down the owner project to match the current `CBOX_OLLAMA_*` configuration and per-scope networks.
- `cbox doctor` - report configuration status and active features inside the container.
- `cbox down [--force]` - stop the container (isolated or global, mode-detected). Refuses if a session looks live; `--force` overrides (see Lifecycle: isolated mode).
- `cbox shell` / `cbox logs [args]` - open a shell / stream logs in the current mode (isolated or global); in isolated mode these work per-project the same way `cbox run` does.

## The hub (bare `cbox`)

Running `cbox` with zero arguments, a TTY on stdin, and a TTY on stdout opens the interactive hub - a numbered crossroads over the current scope's container. Any other invocation shape (arguments present, or no TTY on either stream) prints the usual usage text unchanged; a script or pipe piping into a bare `cbox` never sees the hub.

Mode is resolved first, exactly like `cbox down`/`cbox config`: global mode opens the hub over the shared global container; isolated mode with no effective config yet runs the same first-run wizard prompt `cbox run <bin>` would (configure from scratch, derive from global, or cancel) and then continues straight into the hub; isolated mode with an effective config opens the hub over the project container; no workspace at all (home directory, `/`, or a mount root) falls back to the usage text plus a one-line hint that `cbox ls` only lists RUNNING isolated projects, not every configured one.

The screen (all rendered to stderr, plain ASCII, redrawn once per loop iteration):
- Line 1: `cbox - <cwd>   mode: <mode>`.
- Line 2: container state (`up (since <timestamp>)`, `down`, or `unknown` on any probe failure - a missing docker binary or unreachable daemon degrades to `unknown` rather than crashing the hub), image freshness (the running container's `cbox.inputs` label compared against the currently-computed image inputs hash - `fresh` on match, `stale` on mismatch, falling back to the container's raw image ID when the label is unavailable), and the egress mode.
- Line 3: `engines:` followed by every console engine from the registry that is entrypoint-enabled for this scope (claude and codex always; hermes only when `CBOX_HERMES=on`), each tagged `(running)` when a cosmetic `docker exec` scan finds a matching `/entrypoint.sh <bin>` process, with no tag otherwise. This scan is purely cosmetic: any failure (no docker, no running container, exec error) renders no tag rather than a wrong one, and the result never feeds the reap/liveness logic - `_probe`'s aggregate count keeps sole authority there.
- The numbered menu: one row per registry engine (`attach - running` when the cosmetic scan sees it, `start` otherwise), then shell, logs, doctor, config, down, and `q) quit`. In global mode every engine row and the shell row are marked `(ends hub)` - `cbox run`/`shell` in global mode exec-replace the process once a TTY is present, so selecting them ends the hub session outright (a fresh `cbox` reopens it). Isolated-mode rows return to the hub normally since `_session_run`/`shell_isolated` both return control after `_reap`.

Snapshot semantics: the status panel is read-only and never blocks or holds a lock by itself - engine/shell/down actions still acquire their own locks exactly as the CLI equivalents do (`_session_run`'s shared flock, `down_project`'s exclusive probe-gated flock). The panel can be stale between renders; staleness self-heals because every dispatched action re-checks real state on its own before acting.

Selection is a plain numbered prompt (`> `), not the wizard's cursor-driven `_menu_select` and not a tmux attach - both were rejected explicitly: a numbered read keeps the terminal contract unchanged for the common single-engine case, and no multiplexer is introduced. Parallel engines in v1 means a second terminal: open another `cbox` (or `cbox run codex`) alongside a running hub; both attach to the same container under the existing shared-lock parallelism.

Input handling: `IFS= read -r` off a genuine prompt loop under `set -euo pipefail`; EOF (Ctrl-D, or stdin closed) quits cleanly with a message; every dispatched row runs inside a conditional so a nonzero return never kills the hub - a one-line note is printed and the screen re-renders instead. `Ctrl-C` at the prompt redraws the prompt with a hint instead of exiting; a second `Ctrl-C` at the same prompt (before any successful read) force-quits. After every child returns (engine, shell, doctor, config submenu, down), `stty sane` restores terminal state before the next render, so a TUI child that leaves raw mode set behind does not wedge the hub's own prompt.

`down` in the hub reuses the same liveness guard `cbox down` has: on refusal it prints the guard's message and offers typing `FORCE` to run the forced variant, matching `cbox down --force` exactly (anything else at that prompt cancels).

`config` opens a small submenu: show all (`cbox config get --all`), set one key (prompts `KEY=VALUE`, then runs `cbox config set` and shows its stage-and-report output), pending (`cbox config pending`), and back.

First-run flow: an isolated scope with no effective config yet lands in the existing `_first_run_init` prompt (configure from scratch / derive from global / cancel) before the hub ever renders; a successful init continues straight into the hub screen without a second invocation.

## Hub (python core)

Track H of `cbox/docs/MULTIPLATFORM_DESIGN.md`: the hub host half is Python, no tmux, portable by construction. As of H1, bare `cbox` with a TTY on stdin and stdout first tries `lib/cbox_hub.py`: if `python3` is on PATH and the file `py_compile`s cleanly, it runs the python hub; otherwise (no `python3`, the file missing, or a syntax error in it) `cbox` falls back to the bash `hub()` described above unchanged. Runtime failure is covered too, since `py_compile` only proves the file parses: any unhandled exception inside the hub is converted by its entry wrapper to the reserved exit code 97, on which `cbox` prints a one-line note and opens the bash hub. The residual gap is a crash at module import time (before the wrapper exists) - that still surfaces as a plain exit 1 with a traceback; it is a class py_compile all but excludes, and it is stated here rather than claimed away. Exit codes other than 0 and 97 pass through unchanged, so the hub's usage-style exits keep their meaning. Every other invocation shape (arguments present, no TTY, non-TTY stdin/stdout) still prints the same usage text as always - unaffected by which hub implementation exists.

Mode and scope resolution stay bash's job: the python hub calls a hidden `cbox __hub_context` to get one JSON line (mode, workspace root, effective directory, config path, the exact `docker compose` argv for this scope, service name, egress mode) computed by the same `_cbox_effective_mode`/`_cbox_workspace_root`/`_first_run_init` bash uses for every other command - so mode logic is never duplicated or allowed to drift between the two hubs. `__hub_context` prints `{"mode": "none"}` when there is no workspace or no config yet and non-interactive init was refused; the python hub degrades to the usage text in that case, same as bash.

The python module separates screen data from rendering by construction (`build_status_rows`, `build_screen` return plain rows/strings; `hub_loop` owns stdin and the screen rendering, while the config listing and error paths still write to stderr directly - a later curses/alternate-screen increment must route those two through the swappable writer as its first step) so the renderer can be replaced without touching the probe or dispatch logic. `__hub_context` is an internal handshake between the two hub halves, not a public verb: its output shape may change with the hub and nothing outside `cbox_hub.py` may depend on it. Every docker probe call (`Probe.container_id`, `.container_state`, `.running_engines`) is wrapped by the caller in a bare `except Exception`, so any probe failure - no docker, no daemon, a stale container - renders `unknown` rather than crashing the loop; a `NullProbe` exists for callers/tests that want to guarantee zero docker calls.

H1 screens: the main hub screen (header line, container/egress/engines status rows, one numbered row per enabled engine from `etc/engines/engines.json` plus shell/logs/doctor/config/down/quit) and its four action targets - engine rows and shell/logs/doctor/down all `exec` the existing bash verb (`cbox run <engine>`, `cbox shell`, `cbox logs`, `cbox doctor`, `cbox down`) as a subprocess, so the direct run path and every write-capable verb still live in bash unchanged. `config` in H1 is read-only: it parses `KEY=VALUE` lines directly out of the resolved `cbox.conf` (no sourcing, no section metadata) and prints them - no `cbox config set`, no netaccess/ollama/wg/session-broker/sessions submenus, no apply staging. Those stay bash-only for now and are reachable by leaving the hub (`q`) and running the verb directly, or by falling back to the bash hub's fuller submenu tree.

In global mode selecting an engine or shell row ends the python hub loop after the subprocess returns (matching the bash hub's `(ends hub)` convention, rendered the same way in the menu labels); isolated-mode rows loop back to the hub screen.

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
| GPU (CUDA via CDI) | `CBOX_GPU` | on | attach NVIDIA GPU at container start, global and isolated alike; `--gpu` flag is legacy, not required |
| Session auto-resume | autoresume section | on | tmux + watchdog auto-types resume prompt after usage limit reset |
| Session multiplexing | `CBOX_SESSION_MULTIPLEX` | on | wraps claude/codex/hermes in a named tmux session when a TTY is attached; precondition for remote session attach |
| Light context profile | `CBOX_CONTEXT_PROFILE=light` | light | ~700 tokens; skips orchestration detail, keeps kernel + ledger |

## File layout

```
cbox/                           # Install directory
  setup.sh                        # Wizard entry point (now `cbox setup` verb, lib/cbox-setup.sh)
  cbox                            # Wrapper script (docker run, lifecycle)
  docker-compose.yml              # Generated compose file (global mode)
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
      hermes_delegate_mcp.py       # Hermes MCP delegate (hermes-local tool)
    hooks/                        # Hook scripts (staged by install-hooks)
      orchestrator-global.txt     # Codex conduct kernel (host-side)
    codex/
      ask_claude_mcp.py           # Reverse orch wrapper (read-only in container)
      ask_claude_fallback_models.json  # Default --fallback-model chain by requested model
    agents/                       # Subagent definitions (agents section)
    claude/                       # CLAUDE.md, policies/, templates/, settings merges
    docs/                         # Runbooks (local model, remote design)
    engines/
      engines.json                 # Engine driver registry (metadata only)
      engines_registry.py          # Strict validator/reader for engines.json
  backups/                        # Volume archives (cbox backup)
```

In isolated mode, per-project outputs are written to `~/.config/cbox/projects/<path-hash>/`, including project-specific `docker-compose.yml` and `codex/cbox-container.config.toml`. In global mode, codex tier config is at `generated/codex/cbox-container.config.toml`. Generated aliases (~/.bashrc-cbox) are written directly to the home directory, not staged in etc/.

## Engine driver registry (etc/engines/engines.json)

`etc/engines/engines.json` is metadata describing each interactive console engine
(bin name, install mechanism, probe shape, version vars, login flow) for
consumption by the hub display, `cbox verify`, and `doctor`. It is NOT an
authorization surface: adding an engine to the registry does not by itself let
it run, arm its version-pinning, or widen what `entrypoint.sh` executes - it
only makes the metadata declarative for the tools that read it. The
registry is decoupled from runtime dispatch by design: `entrypoint.sh`'s own
`case claude|codex)` arm (with its special-cased profile/version handling) is
the actual gate for those two verbs, and that arm - not the registry - stays
the source of truth for arming a new engine to run. This is a narrower claim
than "sole boundary for what can run in the container": `entrypoint.sh` falls
through to `_run_as_user "$@"` for any verb outside `claude|codex` (this is how
`cbox shell` intentionally runs `bash` in the container in both modes), so
entrypoint.sh does not gate arbitrary command execution, only the
claude/codex-specific pinning and profile checks. The `_probe` liveness
heredoc stays a static, hand-written script, independent of the registry.

`cbox/etc/engines/engines_registry.py` is a dependency-free validator/reader:
`validate <path>` checks the schema strictly (rejects unknown keys, wrong
types, missing required fields); `names <path>` lists engine names; `get
<path> <engine> <dotted.key>` reads one field.

Each engine also carries four shared-session capability fields: `preassign_id`
(whether a native id can be supplied at creation), `resume_argv` (the native
resume command), `seed_channel` (how shared memory is injected), and
`history_read` (the native transcript locator kind). Claude, Codex, and Hermes
all publish resume, seed, and history capabilities.

## Sessions

`cbox` maintains one project-scoped session index across Claude, Codex, and
Hermes. Bare `cbox` syncs all native sessions whose cwd or git root is inside
the current project, imports each previously independent native conversation
as its own cbox session, and lets the user choose a cbox session followed by
an engine. Switching engines creates or resumes that engine's mapped native
leg and injects the latest shared memory.

Layout, rooted at the workspace (the same path on host and in container):
- `.cbox/sessions/<id>/session.json` - the durable record: schema version,
  the cbox session id, scope info, state (`open|idle|closed`), which engine
  currently holds the lease (`activeMain`), per-engine lineage of native
  session ids, native transcript locators/cursors, and handoff bookkeeping.
- `.cbox/sessions/<id>/distillates/handoff-NNNNNN.json` - immutable local
  shared-memory snapshots. The latest 16 conversation messages stay verbatim;
  older messages become deterministic bounded summaries. These files can
  contain conversation data and are ignored by `.cbox/.gitignore` by default.
- `.cbox/runtime/sessions.json` - the volatile, single-writer record of
  which OS process currently holds a leg (pid + start-time, for stale-lock
  detection and display titles). `.cbox/.gitignore` ignores `runtime/` and
  distillates, but keeps the session mapping records eligible for versioning.

The one-MAIN-lease invariant: exactly one engine leg may be active per
session. Acquiring a leg checks the recorded holder's pid/start-time against
`/proc`; a live holder refuses the new leg by name, a dead one is reclaimed
as stale. The serialization lock that guards this decision lives host-only,
under `~/.config/cbox/projects/<hash>/session-runtime.lock` - never inside
the container-writable workspace bind. All session-state writes go through
a nofollow-hardened helper: every path component from the workspace root
down (not just the final file) is opened with `O_NOFOLLOW`, so a symlink
planted anywhere in `.cbox/sessions/`, `.cbox/runtime/`, or their parent
directories is refused rather than followed, and the final write is an
atomic temp-file-plus-rename inside that verified directory. Session ids
are validated against a fixed shape at every entry point (CLI flag, hub
prompts, internal leg/close/show helpers) before they are used to build a
path.

CLI: `cbox session sync` discovers/imports project-native sessions; `cbox
session list`, `new`, `close <id>`, and `show <id>` manage the canonical
index. `cbox run --session <id> <claude|codex|hermes>` runs a mapped leg;
plain `cbox run <engine>` remains sessionless. Imported conversations are
not automatically merged with one another because there is no safe semantic
rule for guessing that two independent histories are the same conversation.
The list is newest-first and labels non-interactive Codex `exec`/MCP records
as `auxiliary`; they remain selectable because sync intentionally imports all
project sessions.

Claude receives cross-engine memory through its SessionStart hook, Codex
through the configured session-start hook environment, and Hermes through an
ephemeral system prompt. Only user/assistant conversation text is extracted;
tool traces and hidden reasoning are excluded. The project-wide runtime lock
serializes cbox-managed legs so native-id discovery cannot cross-wire two new
sessions. If an unrelated native process creates multiple same-project
sessions during a new Codex or Hermes leg, cbox reports ambiguity and does not
guess a mapping. Global mode still runs sessionless.

## Host gates (verification)

`cbox verify` checks:
- Each workspace is a git work-tree.
- `~/.claude/CLAUDE.md`, agents, policies, templates, hooks, settings.json are read-only and present inside the container.
- Claude Code and Codex binaries are at pinned versions.
- MCP protocol roundtrip succeeds.
- Nested ask-claude calls are depth-limited and refused.
- (Isolated mode) Per-project image hash is consistent.
- (Codex-mcp enabled) Config.toml wiring exists.

The netaccess and scoped-exec live gate must run on a Docker host: configure
`scope=list` with a disposable target network, run cbox, confirm the proxy is
attached and Dante reaches a target TCP service, run `cbox-container list` and
a bounded test command, confirm a privileged target is denied, remove one
network from the list and confirm the stale proxy attachment is removed on the
next run. Also confirm Tinyproxy is unreachable from a target network, the
read-only socket mount still permits `cbox-container list`, concurrent sessions
receive different socket paths, and the optional workspace guard changes bind
policy without changing network scope. Raw k3s CIDRs additionally require a
host route check. Static tests inside cbox do not claim these live Docker
results.
- The engine registry (`etc/engines/engines.json`) validates and stays in
  sync with `install-bins.sh`, `entrypoint.sh`, and `SEC_VARS[binaries]`;
  engines with no entrypoint arm yet are reported as a NOTE, not a failure.

Configurations that fail verification refuse to start.

## Multiplatform gates (step 0)

`cbox/docs/MULTIPLATFORM_DESIGN.md` records the decision to target Linux and
macOS on stock system tools. Step 0 of that design lands gates only, with no
behavior change on a healthy Linux host:

- `etc/registry/file_inventory.json` classifies every shell/python file in the
  tree as `host` (runs on the operator's machine, in scope for the portability
  gates), `container` (runs inside the image, Linux forever), `template-
  generating-container-content` (a host script whose job is to author or stage
  container content), `test` (the `lib/test_*` harness), or `fixture-snapshot`
  (a frozen parity fixture, never executed). `lib/portability_denylist.py
  check` fails if a discoverable script (`*.sh`, `*.py`, anything with a `#!`
  shebang, or a fixture named `*.sh.*`) is missing from the inventory, or if
  an inventory entry points at a file that no longer exists - the boundary is
  machine-enforced, not tribal knowledge. The gitignored `generated/`
  directory is excluded from discovery; it is 1:1 build output from `etc/`
  sources, which are what the inventory tracks.
- The same tool ratchets a GNU/bashism denylist (`declare -A`, `mapfile`,
  `${var^}`, `stat -c`, GNU `sed -i`, `sha256sum`, `xargs -r`, raw `timeout`,
  raw `realpath`, raw `flock`, `mountpoint`, `/proc/`, raw `XDG_RUNTIME_DIR`,
  `ip route`) over `host`-layer files only, against a pinned baseline at
  `lib/fixtures/portability_denylist_baseline.json`. A new occurrence anywhere
  fails; a reduced count also fails until the baseline is regenerated with
  `python3 lib/portability_denylist.py regen`, so the baseline cannot drift
  silently in either direction. `lib/test_portability_denylist.sh` and
  `lib/test_file_inventory.sh` wire both checks into the `lib/test_*` suite.
- `lib/test_bash32_parse_gate.sh` runs `bash -n` on every host-layer bash
  script under the official `bash:3.2` docker image. It detects a missing
  docker binary or an unreachable daemon and skips with an explicit note
  instead of reporting a false pass; the gate is real only on a docker-capable
  host or CI.
- `lib/portable_preflight.sh` is sourced as the first executable code in both
  `cbox` and the `cbox setup` verb (lib/cbox-setup.sh), before `templates/sections.sh` or
  `templates/generators.sh` are referenced (the latter is not bash-3.2-clean
  today). Two conditions refuse to run: a bash below the floor (currently
  4.2, dropping to 3.2 after track P of the design) and macOS during the
  unsupported window, each with one clear message instead of letting a later
  `declare -g -A` fail with a raw syntax error. Missing python3 or docker
  only warns on stderr and continues: bare `cbox`, the hub and the help
  paths work without docker today, and turning that into a hard refusal
  would be a behavior change step 0 is not allowed to make. On a healthy
  Linux host with docker and python3 present it prints nothing and changes
  no exit path. `lib/test_portable_preflight.sh` exercises the floor-comparison and
  message logic through injectable seams (`cbox_preflight_check` takes the
  bash binary, an OS-name override, and yes/no/auto flags for python3 and
  docker), since a real bash-3.2 interpreter is not available to run this
  suite in a container without a docker socket.

### user-layer

User extension layer (`CBOX_USER_DIR`, default `~/.config/cbox/user`). A host directory bind-mounted read-only into the container at `/etc/cbox/user`, letting you add your own MCP servers without touching cbox-owned config. Drop one JSON file per server under `user/mcp/<name>.json` (filename stem is the server name); each carries the stdio MCP spec (`command`/`args`/`env`) plus a `_cbox` block (`adapter` must be `stdio-mcp`, `available_to` is the subset of `claude`/`codex`/`hermes` the server is exposed to, optional `enabled_when_env`). cbox never writes under this directory - only the directory skeleton (`mcp/` and `policies/`) is created if missing - and never overwrites your entries: they are unioned with cbox's own delegates at render time, surviving every rebuild.

Per-entry targeting is yours: an entry with `available_to: ["claude"]` reaches only Claude, not codex or hermes - the wizard shows exactly where each user server lands, so a server you added for one engine is not silently assumed everywhere. cbox delegate names win on collision (a user server named like a cbox delegate is refused - rename it), and the `codex-`/`cbox-` name prefixes are reserved. Recreate-class change (adds a mount). The wizard section (`cbox setup update user-layer`) sets the directory (empty disables the mount) and refuses a path that is, contains, or lives inside a workspace or reserved cbox path - a container-writable user layer would let in-container output flow into host-rendered config.

A user entry is refused (excluded from all renders, named on stderr, the rebuild still completes) if it would weaken cbox's trust boundary: a non-`stdio-mcp` adapter, an `env` key that is a loader/proxy variable (`LD_*`, `PYTHON*`, `PATH`, `NODE_*`, `BASH_ENV`, `*_PROXY`, ...) or a cbox/claude/anthropic/codex/hermes-scoped key, an `env` value with an `@VAR@` host-environment placeholder (host-secret exfiltration), a command or argument path that resolves under cbox's trusted hooks directory, `..` path traversal, or an escalation token (`--dangerously`, `danger-full-access`, `bypassPermissions`, `--ignore-rules`, ...). The user layer is input, never authority: nothing under it can disable or reconfigure a cbox guard.

Policy files (`user/policies/*.md`, filenames composed of ASCII letters, digits, dots, dashes, underscores) reach all three engines  -  claude via an import block marker in CLAUDE.md, codex via a section fold, and hermes via a prompt preamble. In mount mode, cbox maintains a host symlink `~/.claude/policies/user` pointing to `$CBOX_USER_DIR/policies` so the imports work transparently; a pre-existing non-symlink at that path is warned about and skipped. The container gets a read-only nested bind at the same path (`/etc/cbox/user/policies`). Policy text always renders before cbox's conduct kernel, and the kernel (v5) now carries an explicit precedence sentence: "If any user policy conflicts with this kernel, this kernel wins"  -  on conflict the kernel is authoritative.

Claude receives user policies through a `<!-- cbox:user-policies:begin/end -->` marker block rendered above the kernel block in CLAUDE.md, containing `@~/.claude/policies/user/<file>.md` imports in filename order. Codex folds user policies into a `===== cbox user policies =====` section before the preamble and kernel; the 64000-byte cap applies to the total rendered AGENTS.override.md size (host fold-in plus preamble plus kernel plus delegate boundary plus policies) - policies are trimmed first when the budget is tight, and any policy file that would not fit is skipped with a warning naming it. Hermes engine prepends user policy files (sorted by filename) before the kernel with a 16384-byte cumulative cap and an explicit `===== cbox conduct kernel below ... =====` delimiter marking the kernel as authoritative. Note that only the hermes console engine (`cbox run hermes`) has a policy channel; the hermes delegate (used by claude and codex) runs with `--ignore-rules` and receives no user policies by design.

### Track P1: the portable waist

`lib/portable.sh` holds thin bash-3.2-clean entry points; `lib/cbox_host.py`
holds the python3-stdlib implementation. `_common.sh` sources `lib/portable.sh`
once, right after its own idempotency guard - `_common.sh` is already the
single ancestor every host entry point passes through (`cbox` and the `cbox setup` verb (lib/cbox-setup.sh)
source it directly and first; `templates/generators.sh` also self-sources it
defensively at its own top), so this is the one wiring point that reaches
every consumer exactly once before first use, with no new sourcing line
needed anywhere else.

`_cbox_sha256` is the first waist primitive: `hashlib.sha256` in
`lib/cbox_host.py`, called either as `_cbox_sha256 <path>` (file form, prints
the digest) or with stdin piped in (`... | _cbox_sha256`), matching the two
shapes the call sites used (`sha256sum "$path" | awk '{print $1}'` and
`... | sha256sum | awk '{print $1}'`). Exit code and stderr/stdout placement
on a missing file match `sha256sum`. Every `sha256sum` call in the production
host files (`_common.sh`, `cbox`, `lib/cbox-ai.sh`, `lib/cbox-setup.sh`,
`templates/generators.sh`) executes on the host - none sit inside a
heredoc/printf payload emitted for the container - so all of them convert;
none stay pinned. `lib/test_cbox_sha256_oracle.sh` feeds identical inputs
(empty, multi-line, binary with NUL bytes, a large file, a missing-file
error path) to `sha256sum` and `_cbox_sha256` side by side and asserts
identical digests and matching failure behavior. Any test harness that hand-
assembles a fake `INSTALL_DIR` tree (copying `_common.sh`/
`templates/generators.sh` in isolation, or `eval`-extracting individual
function bodies) must also carry `lib/portable.sh` and `lib/cbox_host.py` (or
source `lib/portable.sh` directly) into that fixture, since `_common.sh`'s
source of the waist is a soft `[ -f ... ] &&` guard that skips silently
rather than failing loudly when the file is absent.

Measured on this machine, N=50: spawning `sha256sum` has a ~1ms median cost;
the python3 waist call has a ~11ms median cost, a ~10ms delta - matching the
design's stated budget. Three call sites loop over the local
`~/.config/cbox/projects/*/` directory once per project (`images_list`,
`images_rm` in `cbox`, and the sibling-image-sharing check in `cbox verify`);
each now pays the ~10ms python3 cost per project per invocation instead of
the previous ~1ms `sha256sum` spawn. This is an existing per-project loop
shape, not one introduced by this change, and its cardinality is bounded by
the number of locally configured projects rather than by container or GC
cardinality; it has not been batched into a single python invocation.

`_cbox_flock` is the second waist primitive: `fcntl.flock` in
`lib/cbox_host.py` on the bash-inherited file descriptor, called as
`_cbox_flock [-x|-s] [-n] [-w N] FD`, matching the flag surface every real
call site used - fd-form only, never the file-path or command-wrapping forms
of util-linux `flock`. `-x` and `-s` map directly to `LOCK_EX`/`LOCK_SH`
(exclusive is the default when neither is given, matching util-linux); `-n`
attempts the lock once and returns immediately; `-w N` polls `LOCK_NB` in a
loop bounded by the deadline, matching util-linux's own poll-based timeout
behavior; when `-n` and `-w N` are combined, `-n` wins and the call returns
immediately on contention with the deadline ignored - measured against real
util-linux (`flock -n -w 5` against a held lock returns in ~1ms), not
assumed. Exit codes were measured against util-linux flock
2.39.3 on this machine rather than assumed: 0 on acquisition, 1 on `-n`
contention and on `-w` timeout (both match this machine's util-linux flock
exactly), 64 on a usage error (unrecognized flag, missing fd argument -
matches util-linux's own sysexits-derived usage code), 65 on a bad file
descriptor (matches util-linux's `EX_OSERR` on the same condition).

All 35 production fd-style `flock` sites named in
`cbox/docs/MULTIPLATFORM_DESIGN.md` section 3 (32 in `cbox`, 2 in
`lib/cbox-session.sh`, 1 in `templates/generators.sh`) convert to
`_cbox_flock`; none sit inside a heredoc/printf payload emitted for the
container. `templates/generators.sh`'s `gen_claude_cbox_json_seed_into` used
to guard its lock attempt behind `command -v flock` and skip locking
silently when the binary was absent; that guard is removed, since the waist
makes python3 - already load-bearing for every other waist call - the
dependency instead, and the design calls for locking to be unconditional
again. The lockfile symlink refusal and the writability probe on that same
line are independent safety checks unrelated to which flock implementation
runs underneath, and both stay as-is.

`lib/test_cbox_flock_oracle.sh` proves five properties against util-linux
flock as counterparty, using file-based signals polled in a loop rather than
fixed sleeps for synchronization: an exclusive lock taken through the waist
blocks a contending `flock -n` from util-linux, and the reverse direction
also blocks; a lock acquired by the waist's python child, which exits
immediately after the `fcntl.flock` call returns, persists on the bash
parent's open file descriptor and is observably still held by both a
util-linux and a waist contender, releasing only once that fd is closed -
this is the design's central verified claim, reproduced here as a pinned
regression rather than asserted from the flock(2) contract alone; two
shared (`-s`) waist locks coexist on the same file while an exclusive
util-linux contender stays blocked; `-n` contention returns the
util-linux-matching exit code immediately, without waiting on the holder;
`-w 1` against a held lock times out at approximately one second (matching
util-linux's own poll-based `-w` implementation, not an instant fail) with
the util-linux-matching exit code.

Measured on this machine, N=50: spawning `flock -x FD` has a ~0.6ms median
cost; the python3 waist call has a ~11.7ms median cost, a ~11ms delta -
matching the design's stated ~10ms budget (and consistent with the
`_cbox_sha256` category's own measurement, since both pay the same python3
interpreter startup). Every converted call site was checked for placement
inside a per-item loop, per the section 6 risk 2 rule that no lock operation
may sit inside a per-item GC loop without batching or justification. One
site violates the letter of that rule: `gc()` in `cbox` calls
`_cbox_flock -n -x 9` twice inside its `while` loop over currently running
`cbox.kind=isolated` containers (once per iteration, and again inside the
post-sleep recheck branch). It is not batched into a single python
invocation. The call was left as a per-item lock rather than restructured,
for two reasons stated plainly rather than assumed: each loop iteration
already pays a `docker exec` round trip via `_probe` before or after the
lock check, a cost an order of magnitude above the flock delta on any real
docker daemon, so the ~11ms addition is not the dominant cost in that
iteration; and the loop's cardinality is bounded by the count of currently
running isolated containers on the machine, not by a filesystem or registry
scan. This environment has no docker socket, so the relative-dominance claim
above could not be measured directly here and is not presented as verified
- it is the stated justification for the choice, flagged as such, not a
proven bound. If a live measurement on a docker-capable host later shows the
lock cost is material against `_probe`, the fix is to batch the per-iteration
`_cbox_flock -n -x 9` probe into a single python invocation that opens and
trylocks every candidate session lock file in one process, mirroring the
existing `-n` semantics per file.

### Track P1: exit code reference for `_cbox_flock`

| Condition | Exit code | Verified against |
|---|---|---|
| Lock acquired | 0 | util-linux flock 2.39.3, this machine |
| `-n` contention | 1 | util-linux flock 2.39.3, this machine |
| `-w N` timeout | 1 | util-linux flock 2.39.3, this machine |
| Usage error (bad flag, missing fd) | 64 | util-linux flock 2.39.3, this machine |
| Bad file descriptor | 65 | util-linux flock 2.39.3, this machine |

`_cbox_realpath` and `_cbox_realpath_m` are the third waist primitive pair:
`os.path.realpath` in `lib/cbox_host.py`, called as `_cbox_realpath PATH`
(bare GNU form) or `_cbox_realpath_m PATH` (GNU `-m` form). The design's
original estimate (`cbox/docs/MULTIPLATFORM_DESIGN.md` section 3, "22 sites,
all `-m`") did not survive a direct recount: the denylist baseline pinned 25
raw `realpath` line-hits across four host files, and reading every site
before converting showed only 5 use `-m`; the remaining 20 invocations (17
line-sites, 3 of them with two calls per line) are bare `realpath`, whose
default GNU semantics differ from `-m` and had to be implemented separately.
Both forms are backed by `os.path.realpath`, but bare mode additionally
enforces GNU's documented default ("all but the last component must exist"):
the waist first stats the full path; if that fails with `ENOENT`, it
distinguishes a truly absent leaf from a leaf that exists as a dangling
symlink (`os.path.lexists`) - a dangling symlink is a hard failure exactly
as in GNU, only a genuinely absent leaf whose parent directory exists is
tolerated; any other failure (a missing intermediate directory, `ELOOP` on
a symlink cycle anywhere in the path including the leaf itself, `ENOTDIR`
on a non-directory intermediate) is reported with the same exit code and an
error on stderr. Trailing-slash handling has two sides, both mirrored from
measured GNU 9.4 behavior: on an otherwise-missing path the slash is
cosmetic (`realpath /tmp/does-not-exist/` succeeds like the slashless
form), but on a path resolving to a regular file it forces a directory
check and fails `ENOTDIR` (`realpath file/` and `realpath link-to-file/`
both fail in GNU, and the waist refuses them the same way). These parity
claims hold exactly as far as the oracle test asserts them - its case list
(existing/missing leaves and intermediates, symlink chains, dangling
symlinks, symlink loops, both trailing-slash sides, spaces, `..` past root,
empty string, relative from non-root cwd, each compared live against the
installed GNU realpath for stdout, exit code and stderr placement) is the
boundary of what is verified, and the first cut of this category is the
proof that reading GNU's docs is not enough: adversarial review found the
dangling-symlink and file-with-slash divergences only by differential
execution. `strict=True` was not used (unavailable on the python 3.9 floor
this design targets - the 3.12 development machine's presence of `strict=`
was not relied on). An empty string argument is rejected by both
GNU forms (`realpath: '': No such file or directory`, exit 1) even though
`os.path.realpath('')` alone would return the current directory; the waist
special-cases the empty string ahead of any `os.path.realpath` call in both
modes to match GNU rather than Python's default.

All 25 production `realpath` invocations named by the denylist baseline
(`_common.sh`, `cbox`, `lib/cbox-setup.sh`, `templates/generators.sh`) execute on the
host - none sit inside a heredoc/printf payload emitted for the container -
so all convert; the denylist's `raw_realpath` count drops from 25 to 0, and
no site stays pinned. `lib/test_cbox_realpath_oracle.sh` runs both forms
against GNU realpath 9.4 on this machine for: an existing file and directory,
a missing final component, a missing intermediate directory, a symlink chain
(to both a directory and a file), a symlink loop (`ELOOP`, both as the final
component and as an intermediate component), a trailing slash on both an
existing and a missing path, a path with spaces (both existing and missing),
`..` traversal past `/`, an empty string, and a relative path resolved from a
non-root working directory - 15 cases per form, 30 assertions total, each
checking identical stdout, a matching exit code, and (on failure) that
`stderr` carries the error while `stdout` stays empty.

Measured on this machine, N=50: spawning GNU `realpath` has a ~1.1ms median
cost; the python3 waist call has a ~11.7-12.0ms median cost for both forms, a
~10.5ms delta - matching the design's stated ~10ms budget and consistent with
the `_cbox_sha256` and `_cbox_flock` categories' own measurements (all three
pay the same python3 interpreter startup). Four converted call sites in
`cbox` sit inside a per-item loop: `_cbox_realpath "$root"` in the netaccess
exec workspace guard loops over `guard_roots` (bounded by workspace count,
normally 1); the two-call comparison `_cbox_realpath "$other"` /
`_cbox_realpath "$eff"` appears twice more (`images_list`/verify-adjacent
sibling checks) inside `for other in "$HOME"/.config/cbox/projects/*/`, and
once more as `_cbox_realpath "$other_eff"` / `_cbox_realpath "$eff"` in the
bins-volume-sharing verify check over the same glob - the identical
per-project loop shape already named and accepted for `_cbox_sha256`'s
image-hash sites, bounded by locally configured project count rather than by
container or GC cardinality, not batched into a single python invocation for
the same reason given there.

`_cbox_timeout` is the fourth waist primitive: `subprocess.Popen` plus a
deadline in `lib/cbox_host.py`, called as `_cbox_timeout DURATION COMMAND
[ARGS...]`, matching the flag surface every real site uses - a bare numeric
duration followed by the command, never `-s`/`-k`/`--foreground` or any other
GNU `timeout` option, none of which any site passes. The denylist's
`raw_timeout` baseline counted 5 line-hits; two stay pinned rather than
convert, both in `cbox` (`3206`, `3930`): both run `timeout` as part of a
shell string or argv list executed through `"${X[@]}"`/`_compose_p ... exec
-T cbox`, i.e. a `docker exec`/`docker compose exec` invocation - the
`timeout` binary named there runs inside the container, on the container's
own coreutils, never on the host, so it is out of this waist's scope by the
design's own container/host boundary. The remaining 3 (`templates/
generators.sh:134,492,495`, all `timeout 5 docker ...` querying the local
docker daemon or a registry from the host) convert; the denylist's
`raw_timeout` count drops from 5 to 2, pinned at exactly the two in-container
sites. `_cbox_docker_bounded`'s `command -v timeout` fallback branch is
removed, mirroring the same unconditional-locking argument the `_cbox_flock`
category made for `generators.sh`'s dead flock guard: python3 is already the
load-bearing dependency for every other waist call, so gating on a second
binary's presence no longer buys anything.

Exit code and process semantics were measured against GNU `timeout` 9.4 on
this machine, not assumed: a child that exits cleanly passes its exit code
through unchanged (0 or nonzero); a child killed by a signal is reported as
`128+signal` (verified with a self-`SIGKILL` child, both GNU and the waist
report 137); a command that cannot be found reports 127 and a command that
exists but is not executable reports 126, GNU's own split (the first cut
collapsed both to 127 - adversarial review caught it, and the oracle now
pins each side separately); on the deadline firing, both report
124 and both preserve any stdout the child already wrote before being
signaled. One case was measured and deliberately not mirrored: GNU `timeout`
without `-k` sends a single `SIGTERM` to its direct child and returns 124
immediately, even if the child ignores `SIGTERM` and keeps running past
`timeout`'s own return - reproduced live here with a child that traps `TERM`
and sleeps on, which GNU orphans in the background. The waist instead starts
the child in its own session (`start_new_session=True`) and, on deadline,
sends `SIGTERM` to that process group, waits up to two seconds, and escalates
to `SIGKILL` on the same group if the child is still alive, waiting again
before returning 124 - it does not orphan a `SIGTERM`-ignoring child. This is
a stated, deliberate improvement over GNU's own default behavior (which
requires `-k` to get the same guarantee), not a parity claim; the oracle
proves it as its own case, labeled as a divergence rather than folded
silently into the parity list. None of the 3 real call sites install a
`SIGTERM` trap on `docker`/`docker buildx`/`docker manifest`, so the
divergence is never actually exercised in production; it exists to keep the
waist from introducing a runaway-process class GNU's own default already
half-solves.

`lib/test_cbox_timeout_oracle.sh` runs both against GNU `timeout` for: a
child exiting 0, a child exiting nonzero, a child writing stdout, a missing
command, the deadline firing with partial stdout preserved and its ~1s
elapsed time checked, a self-`SIGKILL`ed child's `128+signal` exit code, and
the `SIGTERM`-ignoring child case proving the waist does not orphan it.

`_cbox_stat_uid` and `_cbox_stat_mtime` are the fifth waist primitive pair:
`os.lstat` in `lib/cbox_host.py`, called as `_cbox_stat_uid [--] PATH` /
`_cbox_stat_mtime [--] PATH`, matching the two `-c` formats real sites use
(`%u`, `%Y`) - no other format appears at any host site, so no general
`stat -c FORMAT` dispatcher was built. `os.lstat`, not `os.stat`, is the
correct counterpart: reading GNU's own `--help` (`-L, --dereference: follow
links`, opt-in) and confirming live on this machine that plain `stat -c %u`
on a symlink - dangling or not - reports the link's own uid/mtime, never the
target's, settled it; a first instinct to reach for `os.stat` would have been
wrong; the oracle's dedicated symlink-vs-target case (constructed so the two
mtimes provably differ, not merely presumed to) exists because this
divergence would otherwise only surface later, on a real symlinked private
key or a real symlinked project directory.

The denylist's `stat_c` baseline counted 5 line-hits; 2 stay pinned, both in
`cbox` (`3459`, `3465`, both `stat -c %u "$HOME/.ssh"` inside a `sh -c '...'`
string executed via `"${X[@]}"`, i.e. inside the container, same boundary
reasoning as `_cbox_timeout`'s two pinned sites). The remaining 3 convert:
`cbox:700` (the shared-ollama models-directory ownership refusal named in the
design), `templates/generators.sh:3159` (the wireguard private-key ownership
refusal), and `lib/cbox-session.sh:586` (`%Y` - the newest-transcript-file
scan in the native-session-id diff heuristic). All three already refuse or
skip symlinks before reaching `stat` (`[ -L ... ]` guards on the two uid
sites, `[ -f ... ]` before the mtime site), so the lstat-not-stat semantics
change nothing about their observed behavior on the paths they actually
receive - the divergence matters for correctness of the primitive, not for
any live call site's current input shape. The denylist's `stat_c` count
drops from 5 to 2, pinned at exactly the two in-container sites.

`lib/test_cbox_stat_oracle.sh` runs both against GNU `stat` 9.4 for: a
regular file, a directory, a missing path, a symlink to a file (asserting the
link's own metadata is returned, not the target's), and a dangling symlink -
5 cases per primitive, 10 assertions total, each checking identical stdout, a
matching exit code, and (on failure) that stderr carries the error while
stdout stays empty.

`_cbox_ismount` is the sixth waist primitive: `os.path.ismount` in
`lib/cbox_host.py`, called as `_cbox_ismount PATH`, matching the only flag
shape either real site uses - plain `mountpoint -q PATH`, stderr discarded,
only the 0-vs-nonzero exit code read. `os.path.ismount` alone is not a
faithful stand-in: measured live on this machine, `mountpoint -q` dereferences
a symlink before checking (a symlink to `/` reports as a mountpoint), while
bare `os.path.ismount` does not (it lstats the path's own device/inode and
reports `False` for the same symlink) - the waist resolves the path with
`os.path.realpath` before the `ismount` check to match `mountpoint`'s
dereferencing default. Neither of the two real call sites (`_common.sh:25`
inside `_cbox_workspace_root`, `setup.sh:3345`) ever hands `_cbox_ismount` a
symlink in practice - both already run their path through `_cbox_realpath`
first - but the waist implements the general case correctly rather than
relying on that incidental protection. Exit codes were measured against
util-linux `mountpoint` 2.39.3 rather than assumed: 0 when the path is a
mountpoint, 32 when it exists but is not one (not 1 - a genuine three-way
split in util-linux's own exit codes, not a boolean), 1 when the path cannot
be stat'd at all (missing, or a non-directory intermediate component). Both
real call sites only branch on zero-vs-nonzero, so the 32-vs-1 distinction is
inert for them today, but the waist reproduces it anyway rather than
collapsing to a boolean, since the design calls for one faithful
implementation, not a call-site-shaped one. The denylist's `mountpoint` count
drops from 2 to 0; no site stays pinned.

`lib/test_cbox_ismount_oracle.sh` runs both against util-linux `mountpoint -q`
for: the real root mountpoint, a plain non-mount directory, a missing path, a
regular file, and a symlink to a real mountpoint (the adversarial case that
would have caught the dereferencing gap) - 5 cases, each checking a matching
exit code and, on a stat failure, that stderr carries the error.

`_cbox_xdg_runtime_dir` is the seventh waist primitive, and the odd one out:
a pure bash derivation with no GNU/util-linux tool as counterparty, backed by
nothing but `id -u` - the design's own framing ("pure derivation, no tool
counterparty") is taken literally, so this primitive lives entirely in
`lib/portable.sh` with no `lib/cbox_host.py` subcommand and pays no python3
spawn cost at all, unlike the other six. It reproduces exactly the bash
expression every real site already used inline: `${XDG_RUNTIME_DIR:-/run/
user/$(id -u)}`, using bash's own `:-` semantics (empty-but-set also falls
through to the fallback, matched deliberately rather than treated as a
special case). Darwin's TMPDIR-derived answer is out of scope here per the
design (Track P3); this category returns only the Linux answer read from the
current call sites' own fallback, nothing invented ahead of it.

The primitive is named `_cbox_xdg_runtime_dir`, not `_cbox_runtime_dir` as
the design section 3 prose says, because `_cbox_runtime_dir` was already a
live function name: `lib/cbox-session.sh:45` defines `_cbox_runtime_dir(root)`
- an unrelated, pre-existing primitive returning `$root/.cbox/runtime`, the
project-scoped session bookkeeping directory, used by
`_cbox_runtime_sessions_file`. `cbox` sources `templates/generators.sh` (line
16) before `lib/cbox-session.sh` (line 21); a same-named waist function
defined in `lib/portable.sh` and sourced even earlier via `_common.sh` would
have been silently redefined by `cbox-session.sh`'s definition partway
through `cbox`'s own startup, so every XDG-derivation call site reached after
that point - `_cbox_clip_dir`, `_cbox_container_exec_dir`, both `gen_compose`
agent-dir defaults - would have silently called the session-scoped function
with no `$1`, printing `/.cbox/runtime` instead of an XDG-rooted socket
directory. This was caught before it shipped, by grepping for the target name
across the tree before wiring the waist in, not by a test failure; the
rename is the fix, and the two names now coexist without collision.

All 7 raw `XDG_RUNTIME_DIR` line-hits named by the denylist baseline convert:
`etc/registry/gen_conf_lib.py:148` (the registry generator's own emitted-text
template for the `ssh_agent_dir_default` resolver - not itself a host
execution site, but the source of the pattern that becomes one),
`templates/conf_lib.sh:36` (that template's generated artifact, which is
itself host-executed and scanned directly - regenerating it from the updated
generator was checked byte-for-byte identical to the hand-edit before either
landed), `setup.sh:2922`, and `templates/generators.sh:581,604,902,1215` (two
direct assignments, two nested `${CBOX_SSH_AGENT_DIR:-...}` defaults, where
bash's own lazy evaluation of `:-` means the waist call only actually runs
when `CBOX_SSH_AGENT_DIR` is unset, verified live on this machine before
relying on it - the common case where the registry default already populated
the variable pays zero extra cost). The denylist's `xdg_runtime_dir` count
drops from 7 to 0; no site stays pinned.

`lib/test_cbox_xdg_runtime_dir_oracle.sh` runs the waist against the literal
bash expression it replaces, in a subshell per case so the environment
mutation does not leak: `XDG_RUNTIME_DIR` set, unset, set-but-empty (proving
`:-` triggers on empty, not just unset), and containing a space (proving the
waist does not need its own quoting beyond what the call sites already do).

Measured on this machine, N=50 (direct `lib/cbox_host.py` invocation,
matching the earlier categories' methodology): `_cbox_stat_uid`,
`_cbox_stat_mtime`, and `_cbox_ismount` each cost the same ~11ms delta over
their GNU/util-linux counterparts as the first three categories - all four
non-timeout primitives pay only the bare `python3 -c pass` interpreter-
startup cost, since `lib/cbox_host.py`'s top-level imports stayed unchanged
for them. `_cbox_timeout` costs more: importing `subprocess` (needed only for
this primitive, and only for this one) roughly doubles interpreter startup on
this machine (measured: `python3 -c 'import fcntl, hashlib'` ~10ms versus
`python3 -c 'import fcntl, hashlib, signal, subprocess'` ~17ms) - moving
`import signal` and `import subprocess` from module level into `cmd_timeout`
itself keeps that cost local to the one primitive that needs it, so
`_cbox_stat_uid`/`_cbox_stat_mtime`/`_cbox_ismount` are not taxed for a
dependency they never load; `_cbox_timeout`'s own delta against GNU `timeout`
is ~19-21ms, roughly double the design's ~10ms figure, named here rather than
rounded down, and still small against the sub-second-to-multi-second docker
operations every real call site wraps. `_cbox_xdg_runtime_dir` costs nothing
extra - measured faster than the bash expression it replaces (~2.3ms versus
~3.6ms) in the common case, since it skips the `$(id -u)` subshell fork
whenever `XDG_RUNTIME_DIR` is already set. No converted call site in this
extension sits inside a per-item loop: the three `_cbox_timeout` sites and
three `_cbox_stat_uid`/`_cbox_stat_mtime` sites each run at most once or
twice per command invocation, the two `_cbox_ismount` sites run once per
`_cbox_workspace_root`/`--local` call, and the `_cbox_xdg_runtime_dir` sites
are cheaper than what they replaced.

### Track P1: exit code reference for `_cbox_timeout` and `_cbox_ismount`

| Primitive | Condition | Exit code | Verified against |
|---|---|---|---|
| `_cbox_timeout` | Child exits normally | child's own code | GNU timeout 9.4, this machine |
| `_cbox_timeout` | Child killed by a signal | 128+signal | GNU timeout 9.4, this machine |
| `_cbox_timeout` | Command not found | 127 | GNU timeout 9.4, this machine |
| `_cbox_timeout` | Command found, not executable | 126 | GNU timeout 9.4, this machine |
| `_cbox_timeout` | Deadline fires | 124 | GNU timeout 9.4, this machine |
| `_cbox_ismount` | Path is a mountpoint | 0 | util-linux mountpoint 2.39.3, this machine |
| `_cbox_ismount` | Path exists, not a mountpoint | 32 | util-linux mountpoint 2.39.3, this machine |
| `_cbox_ismount` | Path cannot be stat'd | 1 | util-linux mountpoint 2.39.3, this machine |

## Troubleshooting

**Container won't start:** Run `cbox verify` to check configuration. Look at `cbox logs` for exact errors.

**Stale seed warning:** After `cbox setup update` (re-bless), re-run `claude` once on the host to regenerate `~/.claude.json`.

**TTY requirement for interactive sections:** The wizard requires a TTY for mounts, workspaces, and project prompts. If running non-interactively, use `cbox setup --config <file>` instead.

**Old binary volumes still present:** `cbox gc` sweeps orphaned containers and old per-project binary volumes after migration to shared volumes.

**Egress blocklist doesn't work:** The blocklist is hygiene only, not a security boundary. Use an allowlist for actual restrictions.

**SSH-based git with egress:** Enable the SSH section; it tunnels git over HTTPS to `ssh.github.com:443` through the proxy.

**Project paths with similar names:** Project paths that differ only in characters outside [a-zA-Z0-9] map to the same session slug (e.g., /work/client.alpha and /work/client-alpha both become -work-client-alpha). This mirrors Claude Code's own project-directory naming, so such projects share a session directory; distinct effective configs still apply (path hash includes the full path, so they remain independent otherwise).

## See also

- README.md - feature overview and quick-start.
- etc/docs/LOCAL_MODEL_RUNBOOK.md - local model setup (off by default; two setup paths, open decisions).
- ~/.claude/CLAUDE.md - global conduct kernel, policies, agent definitions.
- cbox.conf - generated configuration (key/value pairs, sourced by shell scripts).
