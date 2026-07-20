# PROGRESS_TEMPLATE - norm and template for the daily progress log

Chronological daily record of work in the project: `./.cbox/PROGRESS_YYYY_MM_DD.md` (one file per day, underscores in the date). Division of roles: **LEDGER** = state and queue (what holds now), **PROGRESS** = the day's chronology (what happened when), **DIARY** = narrative and reasoning (why).

## Format

- Write step by step top to bottom (chronologically), short lines `HH:MM - action - result/anchor (hash, test, file)`.
- Write continuously at every major step, not retroactively at day's end.
- **Before every write, check today's date:** if it is newer than the existing file's date, start a new `PROGRESS_YYYY_MM_DD.md` with today's date and write there (do not keep writing into the old one - first append a Carry-over section to it).
- At the end of the day, a **Carry-over** section - what remains open and where to pick it up (typically the LEDGER queue or the next daily file).

## Template (copy-paste)

```markdown
# PROGRESS 2026-MM-DD - <project> (<wave/topic>)

- HH:MM - <action> - <result, commit hash, evidence>
- HH:MM - <action> - <result>

## Carry-over
- <what remains open -> LEDGER queue / tomorrow's progress>
```
