# cbox

An isolated Docker sandbox with an orchestrator layer for Claude Code and Codex CLI. Run AI coding agents at full speed inside a hard boundary—no per-command prompts, integrated model routing, and durable memory across session limits.

## Why cbox

- **No confirmation fatigue.** The sandbox is the security boundary and workspaces are git-versioned. Agents run in auto mode; approvals surface only where they matter: rule changes (install-hooks diff+confirm) and paid delegations (propose-and-ask).
- **Smart model routing built in.** Policies enforce explicit agent types. The orchestrator runs on the top-tier model; workers and reviewers use smaller models (Sonnet, Haiku), cutting costs when a smaller model suffices.
- **Resume after session limits.** Workflow run IDs are recorded in a project ledger. Interrupted work resumes from cache instead of restarting.
- **Project history and memory.** Mandatory LEDGER + daily PROGRESS, optional DIARY and OPEN_QUESTIONS, plus user-facing CHANGELOG (git projects). State survives session ends, compaction, and machine switches.
- **Behavioral read-only.** Agent definitions, policies, CLAUDE.md, templates, hooks, and settings are read-only inside the container. A compromised or prompt-injected agent cannot rewrite its own rules.
- **Shared global binary volumes.** Claude and Codex binaries live in machine-wide Docker volumes, installed host-side once and mounted read-only in all containers. One install serves every project and mode; updates are explicit.
- **Optional egress allowlist.** Tinyproxy sidecar with anchored-regex domain filtering, no host ports, login-first flow.
- **SSH without secrets.** Agent-socket forwarding (keys never enter the container), container-local keys on a volume, or nothing (default).
- **Per-directory hybrid storage.** ~/.claude and ~/.codex each independently host-mounted or volume-backed.
- **Reverse orchestration (opt-in).** Codex gains an `ask-claude` MCP tool that delegates to Claude Code in print mode. Recursion is depth-limited; nested calls are refused. Every delegation spends both subscriptions (intended policy: propose-and-ask, never automatic). Calls are audit-logged.
- **GPU on demand.** CUDA via CDI at container start (hot-plug eGPU workflow).

## Requirements

- Linux host with rootful Docker and Compose v2
- bash
- Optional: NVIDIA GPU with nvidia-container-toolkit (CUDA via CDI)
- Optional: socat on the host (only for `cbox login-codex` under egress lockdown)

## Install

Copy or clone the `cbox/` directory anywhere on the host, then run:

```
./setup.sh
```

The wizard walks through all sections: mounts, workspaces, python, gpu, egress, ssh, bashrc, mcp-servers, agents, codex-mcp, continuity, claude-md, settings, hooks, git-identity, apt-extra, restart-policy. Navigation after each section: `Enter` = next, `b` = back, `j` = jump to a section, `q` = save and quit.

**Warning:** The install directory, ~/.claude, ~/.codex, and any host venv paths must live **outside every mounted workspace**. The setup wizard refuses overlapping paths.

During the workspaces section, if a path is not a git work-tree, the wizard offers to run `git init` there. This is required for the codex guard to permit write-capable delegation and for verify to pass.

Options:
- `./setup.sh update <section>` re-runs one section later (see `./setup.sh list-steps` for names and which container action each one triggers)
- `./setup.sh --config <file>` replicates a saved `cbox.conf` on another machine non-interactively; skips host-side writes (bashrc, mcp-servers, agents, claude-md, settings, hooks)
- `./setup.sh uninstall` removes the installation

## Commands

The wizard writes `~/.bashrc-cbox` and sources it from `~/.bashrc`. The shell functions are thin, permanent shims over the `cbox` wrapper — all lifecycle logic (start, stop, gate checks, mode dispatch) lives in `cbox run`, never in the shims themselves:

| Command | Description |
|---|---|
| `claude` | `cbox run claude` — global container, or the current project's isolated container in isolated mode |
| `codex` | `cbox run codex` the same way |
| `cbox-shell` | `cbox run bash` the same way |
| `cbox-stop` | `cbox down` |

The `cbox` wrapper (install directory) manages the stack:

| Command | Description |
|---|---|
| `cbox run <bin> [args]` | Mode-dispatched launch: global container or the current project's isolated container |
| `cbox up [--gpu]` | Start global container (build if needed), attach to Claude |
| `cbox down` | Stop the container for the current mode/project (never removes volumes) |
| `cbox restart [--gpu]` | Down, then up (global mode) |
| `cbox shell` | Interactive bash in the global container |
| `cbox verify [--gpu\|--isolated]` | Configuration-driven verification suite; isolated battery runs against the current project when `CBOX_MODE=isolated` or `--isolated` is passed |
| `cbox logs [args]` | Show container logs (global mode) |
| `cbox update` | Update Claude Code and Codex CLI binaries on the host (alias for `cbox reinstall-bins`) |
| `cbox reinstall-bins` | Reinstall binary volumes with current version pins; `--fresh` wipes and rebuilds volumes |
| `cbox install-hooks` | Stage, diff, and confirm hook installation to target hooks dir |
| `cbox backup` | Archive active named volumes to `./backups/` |
| `cbox login-codex` | Bridge Codex OAuth callback port through container (egress mode) |
| `cbox gc` | Sweep isolated containers with zero live sessions (backstop for orphans; see Lifecycle) |
| `cbox ls` | List running isolated project containers |
| `cbox images [list\|rm <hash>]` | List or remove per-project-input image tags |

## Binaries lifecycle

Claude and Codex binaries live in two machine-wide Docker volumes: `cbox-bins-claude` (mounted at `~/.local`) and `cbox-bins-codex` (mounted at `~/.codex/packages`). All containers across both global and isolated modes share these volumes; one install serves every project, with no per-project re-download. Runtime containers mount them read-only — binaries cannot be modified from inside a container.

**Automatic installation:** Binaries install on first `cbox run`/`cbox up` when the volumes are missing or pins have changed. The install runs on the host as a one-shot `docker run` step before container startup, not inside the container.

**Manual control:**
- `cbox reinstall-bins` — re-run the install with current version pins (force reinstall even if already present)
- `cbox reinstall-bins --fresh` — wipe volumes and reinstall from scratch

**The one-tuple rule:** By default, one version pin applies machine-wide to the shared volumes (CBOX_CLAUDE_TARGET, CBOX_CODEX_VERSION set via `./setup.sh` or `cbox.conf`). If two projects pin different versions and both use the default scope, the second project's `cbox run` is refused with guidance. Options: (1) change that project's pins, (2) run `cbox reinstall-bins` on the host to move the shared tuple (which lists any other projects that will then mismatch), or (3) set `CBOX_BINS_SCOPE=pinned` in that project's `cbox.conf` to get its own per-pin volume pair.

**Read-only note:** Inside containers, `~/.local` and `~/.codex/packages` are mounted read-only. User-level installs via `pip install --user` or `npm install -g` into those paths will fail by design. Use a venv (the `python` section) instead, or edit and re-run `./setup.sh update python`.

**Migration:** Existing installs re-download binaries once into the new shared volumes on next run (binaries are re-downloadable, so this is safe and automatic); old per-project binary volumes are swept by `cbox gc`.

## Global vs isolated mode

cbox runs in one of two modes, set by `CBOX_MODE` in `cbox.conf`:

- **global (default)** — one shared container for every configured workspace, managed by `cbox up`/`down`/`restart`. Matches cbox's original single-container model.
- **isolated** — one container per project, keyed by the resolved workspace root (git top-level, or the cwd itself if not a git repository). Configuration, generated Dockerfile/compose, and image inputs for each project live entirely outside any mounted directory, in `~/.config/cbox/projects/<path-hash>/` — the "effective directory" (effdir). A container process can never write its own launch configuration, because that directory is never mounted into any container.

In isolated mode, `claude`/`codex`/`cbox-shell` resolve the project from the current working directory (git top-level of `$PWD`, refusing `$HOME`, `/`, or a bare mountpoint) and launch or reuse that project's own container. Running `claude` from an unconfigured directory triggers a one-time interactive prompt: configure from scratch, derive from the global config, or cancel. Without a TTY, that prompt is refused rather than silently guessed.

Running the global-mode `claude`/`codex` shims from a folder outside every `CBOX_WORKSPACES` entry prompts (TTY only) to switch to the isolated flow for that folder instead of silently running with the wrong mount set.

**Workspace == install directory is refused.** `cbox` refuses to treat its own install directory (or `~/.claude`, `~/.codex`, or a configured venv path) as a workspace. Allowing it would let a container process edit the host-side tooling that launches containers — the same class of self-rewrite risk the effdir isolation exists to close, one level up.

### Session scope

`CBOX_SESSION_SCOPE` (isolated mode only) controls how much of `~/.claude/projects/` a project's container can see:

- **isolated (default)** — only `~/.claude/projects/<slug>` (the slug Claude Code itself derives from the workspace path) is bind-mounted. A container for project A cannot read project B's session transcripts, even though both share the host `~/.claude` mount for CLAUDE.md, agents, policies, hooks, and settings.
- **global** — the whole `~/.claude/projects/` directory is mounted, matching today's behavior, for setups that want cross-project `/resume` visibility inside every container.

`~/.claude` itself is always a host bind in isolated mode, exactly as in global `mount` mode — there is no separate `claude-home` volume. Session-scope only changes which subpath of that same host directory is exposed.

### Image-hash semantics

Each project's image is tagged `cbox-img:<hash>`, where `<hash>` is the sha256 of a canonical manifest of *declared* inputs: base image digest, package list, Claude/Codex target versions, GPU/egress flags, and the Dockerfile's COPY sources. Two projects with identical inputs share one image and its per-hash volumes; a project's image is rebuilt automatically whenever its own declared inputs change.

This hash is **declared inputs, not freshest bits**: it pins the base image by digest (resolved from the registry, cached with a bounded TTL — default 3600s, `CBOX_BASE_DIGEST_TTL=0` forces a fresh check every launch) but does not re-run `apt-get upgrade` inside an unchanged image on every launch. "Rebuild if stale" means stale relative to the recorded inputs, not stale relative to whatever the upstream packages have become since the image was built.

### Lifecycle contract

An isolated project's container starts on first `cbox run`/`claude`/`codex` in that project and stops the instant the last live Claude or Codex process inside it exits — no idle timeout, no polling loop. "Live" is determined by matching `/proc/<pid>/exe` against the exact binary path recorded in the shared binary volumes' read-only metadata stamp; a container process cannot keep itself alive by copying the binary elsewhere and running the copy.

Two windows in the same project share one container and neither's exit stops it while the other is still running a session; the last one to exit triggers an immediate stop. `restart: "no"` is hard-coded for every isolated container — a self-restarting container would resurrect itself behind the stop logic's back.

`cbox gc` is the backstop for sessions the lifecycle logic could not observe directly (a wrapper killed with SIGKILL, a manually backgrounded process, a raw `docker exec`): it samples the process count twice, ten seconds apart, under an exclusive lock that excludes any in-progress launch, and stops only containers that are idle on both samples. Routine launches never wait on gc; gc yields to a launch in progress rather than the other way around.

## Storage modes

~/.claude and ~/.codex are configured independently, each as either:

- **mount** — host directory bind-mounted into container. Data lives on host; survives `down` and even volume removal.
- **volume** — Docker named volume. Logins and state survive `cbox down` and restarts, but exist only inside Docker.

Mixing modes (hybrid) is supported. When you choose mount, the wizard asks per directory whether to back it up first: `y` = plain copy, `c` = compressed tar.gz, `n` = skip. For volume-mode data use `cbox backup`, which archives each active volume to `./backups/`.

**Warning:** `docker volume prune` deletes volumes not attached to a container and will destroy volume-mode logins and state. cbox itself never removes volumes; `down` is never run with `-v`.

## Host timezone propagation

The generated compose automatically mounts `/etc/localtime` and `/etc/timezone` read-only from the host and derives the container's `TZ` environment variable from the host zone. This ensures container timestamps (logs, file mtime, shell prompts) match the host without manual setup. Applies on next container restart.

## First login

In volume mode the container starts with empty state. Log in once:

```
cbox shell
claude
```

Complete the OAuth flow in your browser. For Codex, run `codex login` inside the shell, or `codex login --device-auth` if the callback flow is unavailable.

The wizard performs these logins BEFORE enabling egress lockdown, because the Codex OAuth callback cannot reach the container once the internal network is active. If you need to re-authenticate later with egress on, use `cbox login-codex`, which bridges the callback port to the host via socat.

## Egress mode (optional)

Egress lockdown adds a tinyproxy sidecar on an internal network. The main container has no direct internet access; all HTTP(S) goes through the proxy, filtered by domain.

- **allowlist** — only listed domains are reachable. Security reduction measure.
- **blocklist** — listed domains are refused. Hygiene only, not a security boundary.

The `egress` setup section only ever ADDS domains. It prints the current entries of `etc/egress-allowlist.txt` or `etc/egress-blocklist.txt` and prompts for new domains, one per line, until you press Enter on an empty line. To remove a domain, edit the list file directly and re-run `./setup.sh update egress`.

### Container network access

The optional `netaccess` setup section wires a SOCKS proxy on the egress container so the main container can reach other Docker networks. You can list Docker network names or raw IPv4 CIDR ranges (e.g., `10.42.0.0/16`, `10.43.0.0/16` for k3s pod/service ranges). CIDRs are validated (minimum `/8` prefix) and rendered as SOCKS pass rules. Like the network list they stay inert until the lifecycle phase wires the proxy; reachability from the proxy depends on host routing.

What breaks under egress lockdown: ssh-based git remotes (unless you enable the ssh section), direct DNS lookups, and any tool ignoring `HTTP_PROXY`/`HTTPS_PROXY` environment variables.

**Residual risk:** The allowlist reduces the exfiltration surface but does not eliminate it. Allowlisted endpoints such as github.com and model provider APIs still accept arbitrary payloads, so a compromised agent could still push data through them. The container remains the hard boundary; egress mode narrows, but does not close, the network channel.

**Egress tightening (optional):** Now that binary installs run on the host, the installer domains (downloads.claude.ai and the github family: github.com, api.github.com, objects.githubusercontent.com, release-assets.githubusercontent.com, raw.githubusercontent.com) are no longer needed in the runtime allowlist. If your agent does not need git-over-HTTPS, you may remove them from `etc/egress-allowlist.txt` to reduce surface. Keep `claude.ai` and `chatgpt.com` if you use OAuth login flows. Note: the host itself needs direct egress to download binaries; a host that can only reach the internet through the container's proxy is not supported.

## SSH modes

- **none (default)** — no ~/.ssh, no agent socket in container. Git over HTTPS works normally; safest option, no setup needed.
- **host-agent** — host SSH agent socket directory bind-mounted read-only. Private keys never enter container; it can only request signatures. Hardening: load keys with destination constraints (`ssh-add -h github.com`) so the agent only signs for that host.
- **container-keys** — keys generated inside container on a named volume, never touch host. Add the printed public key as a repository deploy key.
- **mixed** — container-keys volume plus host agent socket.

With egress mode on, ssh traffic tunnels through the proxy to `ssh.github.com:443` (GitHub's official ssh-over-HTTPS endpoint) via a generated ssh config, so the domain filter applies to ssh as well.

## Reverse orchestration (codex-mcp)

The optional `codex-mcp` setup section registers Claude as an MCP tool inside Codex. When enabled, Codex gains an `ask-claude` tool backed by Claude Code in print mode (`claude -p`). Tool parameters:

- **prompt** — question or instruction
- **model** — model name or shorthand (haiku, sonnet, opus)
- **effort** — thinking budget (low/medium/high/max)
- **cwd** (optional) — working directory for file access
- **max_turns** (optional) — turn budget for this invocation

**Behavior:** Without `cwd`, runs in question-answering mode (read-only tools, no shell, no file writes). With `cwd`, becomes a file-editing delegate (read and edit tools, no shell, no subagents): `cwd` must be inside a configured workspace and be a git work-tree.

**Safety:**
- **Recursion limit.** A Claude invoked over MCP refuses further hops and runs with all MCP servers disabled, so it cannot call Codex relays back.
- **Spending both subscriptions.** Every delegation charges both Claude and Codex subscriptions, so the intended policy is propose-and-ask, never automatic.
- **Read-only wrapper.** The wrapper script is served read-only from `~/.claude/hooks/ask_claude_mcp.py` and cannot be edited from inside the container.
- **Audit trail.** Allowed and denied calls are logged to `~/.claude/ask_claude_audit.container.jsonl`.

**Configuration:** The setup wizard writes a `[mcp_servers.claude]` block to `~/.codex/config.toml`. Re-run `./setup.sh update codex-mcp` to enable or disable; answer 0 to strip the block entirely.

## Codex progress relay (optional)

When enabled, the codex-* MCP servers run under `~/.claude/hooks/codex_mcp_shim.py`, a transparent stdio passthrough that translates codex events into standard MCP progress notifications. Codex activity (task start/end, commands, messages, errors) shows live in the Claude Code UI during a delegation instead of a bare "Calling codex-…" spinner. Every protocol byte passes through verbatim and in order; on any JSON parse error the shim degrades to pure passthrough.

**Setup:** Run `./setup.sh update codex-progress` to enable. Then run `cbox install-hooks` to stage and confirm the host copy of the shim, and re-bless + restart the container to refresh its copy. Requires claude mount mode (in volume mode the relay stays off).

**Optional debugging:** Set `CBOX_CODEX_SHIM_LOG=<path>` in the environment of the claude process (inside the container for container runs) to write a debug journal of all events and synthesized progress notifications to the file.

## GPU

CUDA support uses CDI and attaches only at container start. After plugging in an eGPU:

```
sudo ./bind_egpu.sh
```

This regenerates the CDI specification and restarts the stack with `--gpu`. A plain `cbox up` always works without the GPU present.

The `gpu` setup section checks for nvidia-ctk and CDI. If anything is missing it prints exact manual installation commands (including the Docker restart warning). It never runs them itself.

## Python and venv

`python3` is always present in the image. The `python` section additionally offers:

- **none** — no venv
- **host** — host venv directory mounted read-only at the same path
- **volume** — persistent venv on a named volume at `/opt/venv`

## Project memory and policies

The `continuity` setup section controls a durable, on-disk memory system that survives session end and context loss. It is written as a set of conf switches (CBOX_HISTORY, CBOX_GIT, CBOX_DIARY, CBOX_OPEN_QUESTIONS; all default on) and deployed by the `claude-md` section, which pulls matching policy and template files.

Two layers, kept deliberately separate:

- **Continuity layer (Claude Code, for resuming work)** — lives in `./.claude/` of the project:
  - `LEDGER.md` + `PROGRESS_YYYY_MM_DD.md` — mandatory pair (gated by CBOX_HISTORY). Ledger is the single source of truth for state and queue (top = now); progress is one file per day.
  - `DIARY.md` — optional (CBOX_DIARY). Claude's private space for exceptional moments.
- **User layer (quick overview, no reading LEDGER/PROGRESS)** — also in `./.claude/`:
  - `CHANGELOG.md` — optional (CBOX_GIT), meaningful in git projects: what landed on master, newest on top.
  - `OPEN_QUESTIONS.md` — optional (CBOX_OPEN_QUESTIONS): always-current list of open questions; resolved ones deleted.

Turning CBOX_HISTORY off disables the whole continuity system (git/diary/open-questions are forced off with it).

Deployment: the `claude-md` section installs templates into ~/.claude/templates/ as `*_TEMPLATE.md` and policy prose into ~/.claude/policies/ as `CLAUDE-*-POLICY.md`. It APPENDS missing @import lines to ~/.claude/CLAUDE.md without overwriting existing user content.

Project-local files under `./.claude/` in a mounted workspace (LEDGER, PROGRESS, DIARY, CHANGELOG, OPEN_QUESTIONS) are NOT configuration and stay fully writable.

**Shared-brain confidentiality note.** ~/.claude/CLAUDE.md, agents/, policies/, and templates/ are shared across every project (global or isolated) that mounts them — anything written there is visible to every workspace's container. Do not put project-confidential material in the global layer; it belongs in the project's own `./.claude/` files, which are per-workspace and never shared.

### Isolated project debugging mirror

In isolated mode, each launch refreshes a read-only, non-authoritative mirror at `<project>/.claude/cbox/` inside the workspace: `docker-compose.mirror.yml`, `cbox.conf.mirror`, `Dockerfile.mirror`, `image-inputs.mirror`, a `.gitignore` (`*`), and a `README` explaining the mirror. Nothing in cbox ever reads, sources, or launches from these files — they exist purely so you can inspect what a project effectively runs without digging through the hashed `~/.config/cbox/projects/<hash>/` directory. Editing them has no effect: they are overwritten on the next launch. Because the workspace is agent-writable, treat the mirror as informational only, never as configuration.

If you keep your own top-level `.gitignore` in a project, add `.claude/cbox/` to it (the mirror's own internal `.gitignore` already excludes it from that specific directory, but a repo-level entry is tidier for anyone browsing the tree). **Never add a blanket `.claude/` ignore line** — that would also hide LEDGER/PROGRESS/DIARY/CHANGELOG/OPEN_QUESTIONS, which must stay tracked.

## Behavioral read-only

Inside the container, ~/.claude/CLAUDE.md, ~/.claude/agents/, ~/.claude/policies/, ~/.claude/templates/, ~/.claude/hooks/, ~/.claude/settings.json, and ~/.claude.json are all mounted read-only in both mount and volume mode. This is by design: subagent bodies under agents/ are executed as system prompts, so a container process able to rewrite them would have a persistent prompt-injection foothold.

Consequences: the global #shortcut in Claude Code does not work against read-only ~/.claude/CLAUDE.md inside the container. Manage global policies on the host through `./setup.sh update claude-md`, which stages changes, shows diffs, and asks for confirmation before writing and restarting the container. Those sections (mcp-servers, agents, claude-md, settings, hooks) refuse to run at all if invoked from inside a container or without a working `docker` CLI; they must run on the host.

Project-local files under `./.claude/` in a mounted workspace stay fully writable, same as the rest of the workspace mount. ~/.claude/projects/, ~/.claude/agent-memory/, ~/.claude/.credentials.json, and other runtime state directories remain writable in both modes.

`cbox verify` checks configuration-driven guarantees: each workspace is a git work-tree; the guard script, settings.json, CLAUDE.md, and agents/ are read-only and present; the ask-claude wrapper is present and read-only; the MCP protocol roundtrip succeeds; nested ask-claude calls are depth-limited and refused; and (when codex-mcp is enabled) the config.toml wiring exists.

## Updating

- **Binaries:** `cbox update` (or `cbox reinstall-bins`) runs the official installers on the host. Binaries persist on shared volumes across reboots and container cycles without an image rebuild.
- **cbox itself:** `git pull`, then `./setup.sh update <section>` (or re-run the wizard) to regenerate outputs. The wrapper warns on startup if the templates changed since your files were generated (checksum mismatch).

Version 0.1.0

(c) Marek Lauko, ZeroLAB, www.zerolab.sk
