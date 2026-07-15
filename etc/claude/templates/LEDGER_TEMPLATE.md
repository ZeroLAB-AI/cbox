# LEDGER_TEMPLATE — norm and template for project-local memory

Standalone norm (no dependency on any specific project). Applies to `.claude/LEDGER.md` in every project. Sibling files — continuity layer for Claude: `PROGRESS_YYYY_MM_DD.md` (MANDATORY, an honest chronology of every day including decisions and lessons, `~/.claude/templates/PROGRESS_TEMPLATE.md`), `DIARY.md` (optional; Claude's private space — exceptional moments and lived experience of the project, `~/.claude/templates/DIARY_TEMPLATE.md`); user layer for a quick overview: `CHANGELOG.md` (git-only; commits landed on master, `~/.claude/templates/CHANGELOG_TEMPLATE.md`), `OPEN_QUESTIONS.md` (optional; currently open questions, `~/.claude/templates/OPEN_QUESTIONS_TEMPLATE.md`). LEDGER + PROGRESS are a MANDATORY PAIR — introduced together behind one "history" switch; the other files are optional add-ons.

## Format

- **Top = now.** The latest state always on top; older waves further down.
- **Three permanent sections:** **STATE** (done and verified), **OPEN QUEUE** (in progress / PENDING / HELD), **WAITING-ON-USER** (needs a user decision or action).
- **Facts anchored.** Every accept carries a commit hash and evidence (gate, test, verify output). No evidence = PENDING.
- **RESUME safeguard.** A "NEW SESSION — RESUME HERE" block on top with the exact first move.

## Item states

| State | Meaning |
|---|---|
| ACCEPT | Verified (actually run/tested), committed. |
| HELD | Deliberately deferred / waiting on design or a decision. |
| REFUTED | Verification disproved it; not pursued further (stays on the branch). |
| PENDING | Running or unproven; unknown = PENDING, never "done". |

## Rituals

- **Before marking "done":** set state to ACCEPT only after real verification has run, never from an agent's self-report.
- **On phase switch:** update STATE + QUEUE before starting the next phase.
- **DAY-CLOSE:** at the end of a block, summarize accepts (with hashes), the open queue, and the RESUME safeguard.
- **RESUME:** a new session reads the top of the ledger and continues the queue without waiting for a new prompt.

## Growth and archiving

The ledger holds ONLY the live wave. Closed waves live in `.claude/LEDGER_ARCHIVE.md` (newest on top); where the continuity hooks are installed, the sweep hook moves everything below the first wave section there automatically — just write the new wave on top. Distill durable knowledge into the project's docs/. The ledger is never deleted — only moved. Keep the RESUME block ~10 lines so session-start injection stays cheap.

## Template (copy-paste for a new project)

```markdown
# LEDGER — current state + queue (<project>)

> Single source of truth for project state. Top = now. Norm: ~/.claude/templates/LEDGER_TEMPLATE.md.

## WAVE <date> — <name> (running)

> **NEW SESSION — RESUME HERE:** <exact first move>

### STATE (ACCEPT)
- <what is done> — <commit hash>, <evidence>

### OPEN QUEUE (PENDING/HELD)
- <what is running/waiting>

### WAITING-ON-USER
| # | Item | State |
|---|---|---|
| 1 | <decision/action> | <state> |
```
