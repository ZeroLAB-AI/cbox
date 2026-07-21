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

For mount mode, the wizard offers to backup existing data first (plain copy or compressed tar.gz). When switching from mount to volume mode, the wizard offers to back up the outgoing host directory at switch time.

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

### dns

DNS resolution mode (`CBOX_DNS_MODE`), applied only when egress is enabled (in egress mode the override applies to the proxy sidecar only; the main container sits on an internal network):

- **docker** (default) - Docker embedded DNS snapshotting host resolvers at container start. Fast but goes stale after wifi/DNS changes until container restart.
- **public** - Compose `dns:` entries from `CBOX_DNS_SERVERS` (default "1.1.1.1 8.8.8.8"). Immune to host network changes but bypasses VPN/LAN split-horizon DNS.
- **stub** - Compose `dns:` pointing at `CBOX_DNS_STUB_IP`, a host-stable resolver such as a systemd-resolved DNSStubListenerExtra address or dnsmasq on the docker bridge. Follows host DNS AND survives wifi changes; host resolver setup is a manual host-side step.

Apply via `./setup.sh update egress` (compose re-render + container recreate).

### netaccess

Optional Dante SOCKS proxy on the egress container for reaching other Docker networks and raw IP ranges. On every `cbox run`, `cbox shell`, or global `cbox up`, the host-side lifecycle resolves the configured scope, joins the proxy to eligible Docker networks, renders `sockd.conf`, disconnects networks removed from the previous scope, and restarts the proxy. The Docker-network side has two scopes (`CBOX_NETACCESS_SCOPE`):

- **all (default)** - the proxy joins every eligible bridge or overlay Docker network present at apply time; networks are autodetected, nothing to enumerate. Host, none, ingress, unsupported-driver, non-IPv4, and the current cbox project's own internal/egress networks are skipped. New networks appearing later are picked up on the next apply.
- **list** - the proxy joins only the networks named in the wizard. An empty list under this scope passes nothing beyond the raw CIDRs; with no CIDRs either, the proxy denies everything.

Raw IPv4 CIDR ranges (minimum `/8` prefix, e.g. k3s pods `10.42.0.0/16`, services `10.43.0.0/16`) are always listed manually under both scopes - they are not Docker networks and cannot be autodetected. Their reachability depends on host routing. A wildcard CIDR does not exist: `0.0.0.0/*` and prefixes broader than `/8` are rejected.

Configs written before `CBOX_NETACCESS_SCOPE` existed resolve conservatively: a non-empty network or CIDR list means `list` (nothing silently broadens), only a fully empty config resolves to `all`.

`cbox doctor` on the host shows what the scope currently resolves to: the Docker networks present (with attached containers), which of them the proxy will join, configured-but-missing networks under scope `list`, and the closest matching host route for each raw CIDR.

Inside cbox, `CBOX_SOCKS_PROXY` is the authoritative endpoint (`socks5h://proxy:<port>`). `ALL_PROXY`/`all_proxy` are also set as a convenience, but tools can prefer `HTTP_PROXY`/`HTTPS_PROXY`; use `CBOX_SOCKS_PROXY` explicitly when testing target-network TCP.

Optional direct test execution (`CBOX_NETACCESS_EXEC_MODE=scoped`) is available only with `scope=list` and at least one explicit Docker network. A session-bound host helper exposes a private Unix socket and the read-only `cbox-container` client inside cbox; `docker.sock` is never mounted into cbox. Each invocation gets a unique read-only socket mount, while its audit file stays outside that mount. The helper re-inspects the configured networks and target container for every request, and denies stopped, privileged, host-namespace, dangerous-capability, device-bearing, unconfined, host-control-mount, and cbox infrastructure containers. Network membership is the default scope boundary. `CBOX_NETACCESS_EXEC_WORKSPACE_GUARD=on` additionally denies target containers whose host bind mounts leave the current isolated project; in global mode it permits the configured `CBOX_WORKSPACES` set. It is off by default.

Use it inside cbox as:

```
cbox-container list
cbox-container exec --cwd /workspace --timeout 300 app -- pytest -q
```

Options must precede the container name. Commands are passed as an argv list without shell interpretation, output is capped, audit records contain an argv hash rather than full arguments, and a target-side `timeout` process bounds execution. If the target image has no `timeout` executable, the command fails instead of running unbounded.

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
- `cbox` - `$CBOX_DIR/cbox "$@"` (so bare `cbox` reaches the hub without the full install path)
- `hermes` - `cbox run hermes`, emitted only when `CBOX_HERMES=on` at the time `~/.bashrc-cbox` was generated

`hermes()` does not appear retroactively when hermes is turned on later: `~/.bashrc-cbox` is a host file only `./setup.sh update bashrc` (or the full wizard) rewrites - a bare `./setup.sh update` re-renders in-repo/generated artifacts and re-blesses templates but does not touch host files, and `./setup.sh update hermes` alone regenerates the hermes-managed config, not the bashrc functions. Run `./setup.sh update bashrc` after enabling hermes to get the helper function.

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

### autoupdate

Engine autoupdate (`CBOX_AUTOUPDATE`, default `on`; `CBOX_AUTOUPDATE_TTL_HOURS`, default 24). When the engine target is a channel (claude stable/latest, codex latest) and the TTL since the last check elapsed, cbox re-runs the host-side vendor installer into the shared bins volumes in the background at session start (same operation as `cbox reinstall-bins`), refreshing the version stamp; log at `~/.config/cbox/autoupdate.log`. Pinned versions never autoupdate.

Engine-own opt-outs are respected: `"autoUpdates": false` in host `~/.claude/settings.json` skips claude; `check_for_update_on_startup = false` in host `~/.codex/config.toml` skips codex. In-container self-update stays disabled by design (read-only bins mounts, `DISABLE_AUTOUPDATER=1`).

A running session keeps its already-loaded binary; the next session uses the updated one.

### local-model

Off by default (absent from the rendered MCP server list and refused by `cbox ai`) until configured. Wires an OpenAI-compatible endpoint such as ollama as: (1) `local-qwen`, a text-only MCP delegate exposing one tool, and (2) `local-qwen`, a `cbox ai` engine that drives `codex --oss --local-provider ollama` against the same endpoint. Set `CBOX_LOCAL_MODEL=on` plus `CBOX_LOCAL_MODEL_URL` and `CBOX_LOCAL_MODEL_NAME` via this wizard section, `./setup.sh update local-model`, or `--config`; `cbox doctor` reports ACTIVE/CONFIG-ONLY/OFF. Ollama itself always runs outside cbox (no GPU/CDI grant). See etc/docs/LOCAL_MODEL_RUNBOOK.md for the two setup paths (ollama as a sibling container vs a host process) and open decisions left to the operator.

### hermes

Off by default. The third console engine, alongside `claude` and `codex`: [Hermes Agent](https://github.com/NousResearch/hermes-agent) (NousResearch), run as `cbox run hermes`. Volume-only in v1 - there is no bind-mount mode and no `CBOX_HERMES_MODE` variable; `HERMES_HOME` (`$HOME/.hermes-cbox` in the container) is always backed by a named docker volume (`<CBOX_NAME>-hermes-home` global, `cbox-p<hash>-hermes-home` isolated).

Installed at image build time as a pinned venv: `python3 -m venv /opt/hermes && /opt/hermes/bin/pip install hermes-agent==<CBOX_HERMES_VERSION>`, symlinked to `/usr/local/bin/hermes`. Supply-chain exception (explicit, v1 only): the `hermes-agent` package itself is pinned; its transitive pip dependencies are NOT pinned - a compromised or yanked transitive release could change behavior between rebuilds without a version bump here.

Set `CBOX_HERMES=on` plus `CBOX_HERMES_VERSION` (default `0.19.0`), `CBOX_HERMES_PROVIDER` (`local`, `nous`, `openrouter`, `openai`, or `anthropic`; default `local`), and for `local` provider `CBOX_HERMES_MODEL_URL` plus `CBOX_HERMES_MODEL_NAME` via this wizard section, `./setup.sh update hermes`, or `--config`. This is a rebuild-class change (`SEC_APPLY[hermes]=rebuild`): the image must rebuild before a new pin or provider takes effect.

Managed-keys ownership: provider, base URL (local provider only; `/v1` appended if missing), and model name are re-applied on every `cbox run hermes` via the official `hermes config set model.provider|base_url|default` CLI - never a copy-if-absent seed, never a hand-written YAML merge. Any other key in `~/.hermes-cbox/config.yaml` that the user or hermes itself sets is left untouched between starts. Secrets (`.env` under `HERMES_HOME`) and Nous OAuth login are manual, host-operator steps: `cbox shell` into the running container, then run the relevant `hermes` auth/config command by hand.

Degraded toolset note: the image ships the `hermes-agent` pip package only - no headless-browser or ffmpeg extras are installed, so any Hermes skills that depend on them are unavailable.

First use: enable this section (`./setup.sh update hermes` or the wizard), rebuild (`cbox up` or accept the rebuild prompt), then `cbox run hermes`.

`cbox doctor` reports ACTIVE/CONFIG-ONLY/OFF for this section.

### hermes-delegate

Off by default. A zero-cost local-model tier callable by `claude`: an MCP delegate tool (`hermes-local`) that shells out to one `hermes -z "<prompt>"` subprocess per tool call (plus up to three short-lived `hermes config set` subprocesses when a provider/base_url/model is configured - see Subprocess hygiene below). This is a separate concern from the `hermes` console engine above - `hermes mcp serve` (which exposes hermes's own messaging state) is not involved at all; the delegate is a small stdio MCP server (`etc/mcp/hermes_delegate_mcp.py`) modeled on the existing `local-qwen` delegate.

Requires the `hermes` console engine (`CBOX_HERMES=on`); `SEC_DEPS[hermes-delegate]=disable:hermes-off` forces `CBOX_HERMES_DELEGATE=off` whenever the console engine is off, both in the wizard and in `cbox config set`'s dep-gate. Set `CBOX_HERMES_DELEGATE=on` plus optional `CBOX_HERMES_DELEGATE_PROVIDER`, `CBOX_HERMES_DELEGATE_BASE_URL`, and `CBOX_HERMES_DELEGATE_MODEL` (default-inherited from the console engine's own `CBOX_HERMES_PROVIDER`/`CBOX_HERMES_MODEL_URL`/`CBOX_HERMES_MODEL_NAME` at ask-time, but stored and applied independently) via this wizard section, `./setup.sh update hermes-delegate`, or `--config`. This is a restart-class change (`SEC_APPLY[hermes-delegate]=restart`), same as the other MCP delegates.

Ephemeral-home isolation (the core security property): every tool call creates a fresh `mktemp` directory, seeds it from a root-owned read-only template built at image time (`/etc/cbox/hermes-delegate-home`, produced by `hermes setup --non-interactive` at build with skills/auth/db files stripped and permissions locked to 0555/0444), applies the configured provider/base_url/model to that ephemeral copy via `hermes config set` (never a hand-parsed YAML write - an unparseable template can never poison the call), runs exactly one `hermes -z` subprocess against it, then removes the ephemeral directory in a `finally` block. `HERMES_HOME` for the delegate is never the console engine's `$HOME/.hermes-cbox` - the two never share a `state.db` or contend for one. At startup the server refuses to run unless the template is verified root-owned, non-group/other-writable, and symlink-free (`CBOX_HERMES_DELEGATE_HOME_TEMPLATE` is env-overridable, so this is checked at runtime, not just trusted from the image build); seeding itself also refuses (raises before any file is copied) if the template contains a `skills/` directory, `auth.json`, `mcp.json`, `.env`, or a `*.db`/`*.sqlite*` file, and never dereferences a symlink nested inside a template subdirectory.

Subprocess hygiene: the prompt is capped below `CBOX_HERMES_DELEGATE_MAX_PROMPT_BYTES` (default 32000) before spawn (hermes's `-z` flag takes the prompt as an argv string, not stdin, per the upstream CLI contract, so the cap is enforced pre-spawn rather than deferred to a stdin write); argv is an absolute list with no shell interpretation; the environment passed to the child is a minimal scrubbed set (`PATH`, ephemeral `HOME`/`HERMES_HOME`, fixed `LANG`, a stamped delegation-depth marker) - no inherited secrets; cwd is pinned to the ephemeral home; a wall-clock timeout (`CBOX_HERMES_DELEGATE_TIMEOUT_SEC`, default 300) governs the call; stdout/stderr are read incrementally with a hard byte cap (`CBOX_HERMES_DELEGATE_MAX_RESPONSE_BYTES`, default 1000000), never read-all-then-check; the `hermes config set` calls that apply provider/base_url/model are likewise read incrementally with a fixed 64KB per-stream cap, never an unbounded `communicate()`; ANSI/control sequences are stripped from the response by a linear-time byte scanner (not a backtracking regex, to avoid a pathological-input hang); the child runs in its own process group (`start_new_session=True`) and a timeout escalates SIGTERM then SIGKILL to the whole group; the process is reaped and the ephemeral directory removed in a `finally` regardless of outcome.

Memory is off by design: the ephemeral home already guarantees nothing persists past the call, and `hermes -z ... --ignore-rules` additionally skips auto-injection of `MEMORY.md`/`USER.md` context.

`available_to` is `["claude"]` only in v1 - codex access is a later wave. Depth-guarded identically to `local-qwen`: `CBOX_DELEGATION_DEPTH`/`CBOX_MCP_DEPTH` empties `tools/list` and refuses `tools/call` so a delegate spawned over MCP cannot spawn another one.

First use: enable `hermes` (`CBOX_HERMES=on`) and rebuild so `/etc/cbox/hermes-delegate-home` exists, then enable `hermes-delegate` via the wizard or `--config` and restart. `cbox doctor` reports ACTIVE/CONFIG-ONLY/OFF for this section.

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

**Backup and mode switching:** `cbox backup` archives the global claude/codex/venv/ssh volumes to `./backups/` but does not cover isolated per-project volumes (named `cbox-p<hash>-*`); the command prints a hint with a per-volume archive command for manual backup. When switching `~/.claude` or `~/.codex` from mount to volume mode, the wizard offers to back up the outgoing host directory at switch time. Agents and claude-md sections prune files that were deselected (managed files shipped by cbox only - user-created files are untouched); disabling history removes the managed policies/templates it previously deployed. With claude volume mode plus isolated session scope, the per-project session directory `~/.claude/projects/<slug>` is a host bind (kept host-visible for /resume) and lives outside the claude volume - back it up as host files, not via volume backup.

## Clipboard image bridge

Clipboard image bridge (`CBOX_CLIPBOARD_MODE`, default `off`). In `bridge` mode a per-session host helper (`etc/clipboard/clip_bridge.py`) serves the HOST clipboard read-only over a unix socket in a private 0700 runtime dir mounted at `/run/cbox-clip`, and a `wl-paste` shim mounted at `/usr/local/bin/wl-paste` inside the container answers Claude Code's image paste (Ctrl+V). Image MIME types only (png/jpeg/webp/gif/bmp), 64 MiB cap; text paste stays on the terminal's bracketed paste path.

Privacy note: while enabled, any process in that container can read the host clipboard's image content.

Host requires wl-clipboard (Wayland) or xclip (X11).

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

Consequence: the global #shortcut in Claude Code does not work inside the container. Manage policies on the host via `./setup.sh update claude-md`.

Project-local files in `./.claude/` of a mounted workspace stay writable (same as the rest of the workspace). Runtime state (`~/.claude/projects/`, `~/.claude/agent-memory/`, credentials) remains writable.

The container runs with CLAUDE_CONFIG_DIR=~/.claude-cbox, so its live state file is ~/.claude-cbox/.claude.json. This maps to a plain file inside the claude-config directory bind: `<effective dir>/claude-config/.claude.json` per project, or `generated/claude-config/.claude.json` in global mode. Each regen re-renders its `mcpServers` from the delegate registry and preserves every other key the container wrote (trust dialog, onboarding). Separately, the operator's host ~/.claude.json is bind-mounted read-only at ~/.claude.json inside the container as a seed for initial state - it is not the live state. One-shot import: drop a `.claude.json.migrate` file (valid JSON) next to the live state file and the next regen adopts it as the initial state (operator import wins, even if state already exists) and deletes the migrate file. A malformed JSON migrate file is discarded without adoption; if the copy fails the migrate file is kept for retry.

## Wizard re-runs and host activation

After the initial wizard run:

- `./setup.sh update <section>` re-runs one section and regenerates related outputs.
- `./setup.sh update` (no section) re-renders all artifacts and re-blesses the templates (CBOX_TPL_SHA) without changing configuration. This is the standard step after deploying new cbox files; the blessing now covers both `_common.sh` and `templates/generators.sh`, so a deploy of either requires the re-bless.
- `cbox install-hooks` stages and diffs hook scripts, then confirms before installing to the host.
- `cbox restart` reloads configuration and restarts the container.
- `./setup.sh update --config <file>` replicates a saved `cbox.conf` on another machine (non-interactive; skips host-side writes).

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

## Troubleshooting

**Container won't start:** Run `cbox verify` to check configuration. Look at `cbox logs` for exact errors.

**Stale seed warning:** After `./setup.sh update` (re-bless), re-run `claude` once on the host to regenerate `~/.claude.json`.

**TTY requirement for interactive sections:** The wizard requires a TTY for mounts, workspaces, and project prompts. If running non-interactively, use `./setup.sh --config <file>` instead.

**Old binary volumes still present:** `cbox gc` sweeps orphaned containers and old per-project binary volumes after migration to shared volumes.

**Egress blocklist doesn't work:** The blocklist is hygiene only, not a security boundary. Use an allowlist for actual restrictions.

**SSH-based git with egress:** Enable the SSH section; it tunnels git over HTTPS to `ssh.github.com:443` through the proxy.

**Project paths with similar names:** Project paths that differ only in characters outside [a-zA-Z0-9] map to the same session slug (e.g., /work/client.alpha and /work/client-alpha both become -work-client-alpha). This mirrors Claude Code's own project-directory naming, so such projects share a session directory; distinct effective configs still apply (path hash includes the full path, so they remain independent otherwise).

## See also

- README.md - feature overview and quick-start.
- etc/docs/LOCAL_MODEL_RUNBOOK.md - local model setup (off by default; two setup paths, open decisions).
- ~/.claude/CLAUDE.md - global conduct kernel, policies, agent definitions.
- cbox.conf - generated configuration (key/value pairs, sourced by shell scripts).
