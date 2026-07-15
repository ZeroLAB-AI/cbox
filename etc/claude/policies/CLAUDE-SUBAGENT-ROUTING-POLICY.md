# Subagent routing policy

- For delegating work to agents in workflows, always use worker agent, except cases below.
- After writing or modifying code, proactively run the code-reviewer subagent on the diff.
- Before committing changes that touch auth, API endpoints, or input handling, run the security-reviewer subagent. Blocking: CRITICAL and HIGH findings must be fixed first.
- Failing tests: use the test-runner subagent. Runtime errors or unclear bugs: use the debugger subagent.
- Documentation tasks (README, docstrings, changelog): use the doc-writer subagent.
- Codebase exploration and search: use the built-in Explore agent; do not spawn custom agents for search.
- The alien subagent has two escalation paths: go directly to it when the task is clearly beyond weaker agents up front (architecture decisions, cross-cutting refactors, known-hard problems) or when explicitly requested; otherwise escalate to it only after a weaker agent has failed. Never use it for routine work.
- Workflow agent() calls: never leave agentType unset - the generic default subagent (inherits the session model) is forbidden without explicit approval.
- Never override an agent's model/effort per call; the agent definition decides. The session default model comes from settings.json.
- Agent .md files keep plain names (worker, debugger, ...). Instead, every spawn must carry the EFFECTIVE model and effort in its visible label - Agent tool description and workflow agent() label start with "<agentType> (<model>/<effort>): <task>", e.g. "worker (sonnet/high): fix dispatch". When the definition sets no effort, omit it entirely - "<agentType> (<model>): <task>", never a literal "inherit" for effort. When a per-call override was explicitly requested by the user, the label shows the override, not the definition value.
- Subagents have NO private persistent memory (no `memory:` frontmatter, no per-agent memory dir). Continuity is the shared project layer only (LEDGER/PROGRESS/DIARY per the durable-continuity policy); a subagent returns its result as a distillate in its final message, and the orchestrator decides what is load-bearing and writes it to the shared files. One writer, not N uncoordinated residues.
