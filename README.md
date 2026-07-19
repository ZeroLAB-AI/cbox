# cbox

A hardened Docker container where Claude and Codex orchestrate each other over one shared on-disk brain, subscription-optional. Run AI agents at full speed inside a secure boundary with durable memory across session limits, bidirectional delegation, and model routing. Optional local model delegate (Ollama, Qwen) as a token-saving worker, off by default - see MANUAL.md.

## What cbox can do

- Shared on-disk brain: `LEDGER.md + PROGRESS.md` per project survives session ends and machine switches.
- Bidirectional orchestration: Claude calls Codex, Codex calls Claude. Depth-limited, audited.
- Model routing: Explicit agent types route to smaller models (Haiku, Sonnet) where they suffice.
- Sandbox security: Agents run auto; approval gates only for rule changes and paid delegations.
- Session auto-resume: Watchdog detects usage limits and continues work (optional).
- Unified modes: `cbox ai analyse|plan|full claude|codex|auto` with read-only/read-write profiles.
- Guards and audit: Git scope checks, fingerprint audits, recursion limits, bytewise logs, SSH without secrets.

## Quick start

```bash
./setup.sh
```

Wizard stages all setup. Then:

```bash
claude                          # Start Claude
codex                           # Start Codex
cbox ai analyse claude          # Read-only scan
cbox ai plan codex -p "task"    # Plan only
cbox ai full auto -p "task"     # Execute (Claude first, auto-delegate on limit)
cbox ai full local-qwen -p "task" # Execute against a local model (off by default, see MANUAL.md)
```

All binaries, settings, and policies are pre-configured.

## Setup and modes

Two modes:
- **global** (default): one container for all workspaces.
- **isolated**: one container per project.

See [MANUAL.md](MANUAL.md) for wizard sections, storage modes (mount vs volume), lifecycle, troubleshooting, and per-feature toggles.

## Licensing

cbox is MIT-licensed. Base images, packages, Claude Code, and Codex CLI are from official sources.

Version 0.2.0  
(c) Marek Lauko, ZeroLAB, www.zerolab.sk
