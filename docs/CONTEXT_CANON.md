# Context canon: kernel K1-K10 and session core C1-C12

Every rule cbox injects into agent context lives in exactly one place:

- `etc/hooks/conduct-kernel.txt` (K1-K10) is rendered into `~/.claude/CLAUDE.md`, codex `AGENTS.override.md`, the codex MCP shim developer instructions and the hermes system prompt. It reaches every agent, so it holds only rules that apply to delegates too.
- `etc/hooks/session-core.txt` (C1-C12) is injected at SessionStart for the main driver only, with `{{FANOUT}}` (C4) and `{{REVIEW}}` (C5) filled by `continuity_session_start.py` from `CBOX_SUBSCRIPTION_PROFILE` and `CBOX_REVIEW`. The light and resume kernels in the loader reuse the C1 line instead of keeping their own copy.
- `etc/claude/policies/*.md` are pointer stubs. They exist only because the host `~/.claude/CLAUDE.md` header imports them with `@` lines. Removing those import lines on the host saves a further ~1.8 KB per Claude spawn.

A guard-enforced rule is stated once with the exact accepted shape. The guard's deny message explains the rest.

## Old to new

| Old location | Old rule | New |
|---|---|---|
| kernel IDENTITY, NAMING policy | call the owner by name | K1 |
| kernel COMMUNICATION, COMMUNICATION policy, core CONDUCT | answer-first, say once, no deliberation, prose over structure, one-line status, every line earns its place | K2 |
| kernel CODE + ASCII, CODING policy, core CONDUCT | no code comments, no model names, ASCII | K3 |
| kernel GIT, CODING policy, core CONDUCT | git work-tree, commit verified chunks, main-only history | K4 (adds the pathspec rule for parallel writers) |
| kernel CBOX ENVIRONMENT HONESTY + ENVIRONMENT HONESTY DETAIL, CBOX-ENVIRONMENT policy, core CONDUCT | no TTY/docker, statically checked vs host step, say what/why/real path, innocent causes first | K5 (adds: no host diagnosis without data, give the deciding command) |
| (new, lesson of 2026-10-07 revert 95f39dc) | no unrequested behavior changes | K6 |
| kernel DESTRUCTIVE COMMANDS | rm target shape | K7 (adds: the guard scans heredoc bodies, so put rm scripts in a file) |
| kernel DELEGATE IS A LEAF | return questions upward, depth limit | K8 |
| kernel DELEGATE WRITE BOUNDARY + DELEGATE SCOPE, routing policy memory line, continuity policy, codex AGENTS extra paragraph | delegates never write the brain, no private memory | K9 |
| continuity policy, core PROCEED | "!!!" decision lines | K10 |
| core LOCAL FIRST, routing policy P0/P5 and local-skip list, light/resume copies | hermes-local first, closed local-skip list, verification | C1 |
| core PROCEED, DO NOT BLOCK | three cases, inert default for owner-only | C2 |
| core ORCHESTRATION | lean orchestrator | C3 |
| core FAN-OUT / SUBSCRIPTION PROFILE low | fan-out vs workflow, low profile | C4 (rendered) |
| core SUBAGENT ROUTING, routing policy review/tests/doc-writer/Explore/alien lines | routing, reviews on request, tests as commands, escalation | C5 |
| core label sentence, routing policy label/agentType/model override/model pin lines | spawn label, literal agentType, no per-call override, RULING line for spawn_gate, model pins | C6 (adds the spawn_gate RULING shape) |
| core GIT ATTRIBUTION | author name is not proof | C7 |
| core DRIVER LEDGER/PROGRESS/COMMIT, continuity policy | brain files, reconstitute, update and commit discipline | C8 (adds: rules belong in policies/core, not project memory) |
| core LIMIT RESUME, continuity policy limit lines | resume after limits, limits not tool-readable | C9 |
| core CROSS-ENGINE DELEGATION | codex delegation in and outside cbox | C10 (depth is shim-enforced, not codex_mode_guard) |
| core NON-BLOCKING CROSS-ENGINE | sync vs background relay | C11 |
| core ONE-ACTIVE-WRITER | one writer of the brain | C12 |
| kernel/stub LANGUAGE line (rendered from CBOX_KERNEL_LANG_*) | reasoning and answer language | LANGUAGE line before the kernel Version line. It now states that files and code stay ASCII, that hermes prompts are English, and that it overrides any other language or diacritics instruction. |

Dropped as pure repetition: the second copy of every kernel rule in the policies, the drifted LOCAL FIRST copies in the light and resume kernels, the duplicated high/max fan-out literal, and the stale "SESSION CORE v7" / "CONDUCT KERNEL v1" headers.
