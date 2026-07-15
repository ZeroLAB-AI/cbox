# CHANGELOG_TEMPLATE — norm and template for the project changelog

User-facing file: `./.claude/CHANGELOG.md`. A quick overview of what actually landed on master — the user does not need to dig through LEDGER and PROGRESS. **Introduced ONLY in projects that use git** (no git, no changelog).

## Format

- Adaptation of Keep a Changelog: **commit hash instead of a tag/version**, **"Unmerged" instead of "Unreleased"**.
- `## [Unmerged]` always on top — changes on branches / in the working tree not yet on master.
- Below that, sections `## [<hash>] — YYYY-MM-DD`, newest on top. Related small commits may be merged into one section with a range `[<first>..<last>]`.
- Categories within a section as needed: Added / Changed / Fixed / Removed. Concise plain language, no internal jargon.

## Rituals

- **On every commit to master** (or merge into master), add/update a section — a commit without a changelog entry is unrecorded work.
- Keep things waiting on branches under [Unmerged]; move them under the hash on merge.
- The commit hash is not known in advance: a section covers commits made BEFORE the write; the commit that records the changelog itself shows up in the next section (or by extending the range on the next write). Never amend a commit whose hash is already recorded in the changelog.

## Template (copy-paste)

```markdown
# CHANGELOG — <project>

## [Unmerged]
- <changes on branches / work in progress, not yet on master>

## [<hash>] — YYYY-MM-DD
### Added
- <what was added>
### Changed
- <what changed>
### Fixed
- <what was fixed>
### Removed
- <what was removed>
```
