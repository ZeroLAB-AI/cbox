# Coding policy

- NEVER add any comments to code, rather write separated docs
- write scripts and code without any mentioning claude models
- Every file you modify must live in a git work-tree; if a workspace is not a repo, propose `git init` before large edits. Commit completed, verified chunks as you go so any change stays revertable.
- Keep main-only history: work may use temporary branches/worktrees, but after merging fold them and delete the branches with their commits - main is the only branch that persists.
