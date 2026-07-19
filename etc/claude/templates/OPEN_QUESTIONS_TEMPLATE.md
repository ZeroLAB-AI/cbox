# OPEN_QUESTIONS_TEMPLATE — norm and template for open questions

User-facing file: `./.cbox/OPEN_QUESTIONS.md`. An ALWAYS-CURRENT list of the project's open questions — a quick overview for the user without reading the LEDGER.

## Format

- One question = one bullet: date opened, the question, brief context (what it blocks / why it matters).
- **Deleted on resolution:** a resolved question is REMOVED from the file (no archive here) — the decision and reasoning go to `DIARY.md`, the committed consequence to `CHANGELOG.md`.
- May overlap with "WAITING-ON-USER" in the LEDGER: the ledger is Claude's working queue, this is the curated view for the user.

## Rituals

- A new open question → write it down as soon as it arises.
- On resolution → delete it from here + record the decision in DIARY (and CHANGELOG, if committed).
- At day-close, check that the list matches reality.

## Template (copy-paste)

```markdown
# OPEN QUESTIONS — <project>

- [YYYY-MM-DD] <question>? — context: <what it blocks / why it matters>
```
