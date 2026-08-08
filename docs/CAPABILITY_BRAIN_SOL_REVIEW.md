# Capability + shared-brain design - codex-sol adversarial review (2026-08-08)

Reviewer: codex-sol (GPT-5.6-Sol / xhigh), static verification against the dirty
worktree. Verdict: WITHHOLD greenlight until the two red-line violations
(mode_pin, shim-wrap) and the M3 proof gap are resolved. The architecture is
sound in principle; the current design has enforcement holes, incomplete
preflight validation, missing proof machinery, and several claims the codebase
contradicts.

## Confirmed correct (sol verified against code)
- M2 double-injection fix: correct (loader supersedes entrypoint:688, reads and
  validates both handoff layers at continuity_session_start.py:254, emits
  core/shared-memory/ledger/progress from :318).
- Degradation schema unified: one degrade_floor + binding status override, no
  second per-binding field.
- b1 P1/P2-safe for: delegation depth (shim:502, ask_claude:300, hermes:675,
  local:236), cwd admission (shim:176/422, ask_claude:275/338), mode static
  pins (shim:433, entrypoint:635), shim-wrap of MANAGED entries (render_mcp:78,
  entrypoint:190), egress when applied (generators:20/850/1159).
- Managed MCP render genuinely centralized (render_mcp:232).
- Context-manifest digest is real (generators:2819/2853) but narrower than
  claimed.
- M4 appropriately gated (host experiments + fixtures + deny tests before live).

## CRITICAL (red line broken)
1. mode_pin: parent permission_mode is read ONLY by the claude hook
   (codex_mode_guard.py:114, plan-mode deny :146); no permission_mode logic in
   the P2 shim. A hermes/future caller cannot inherit claude's plan/default/auto
   mode. Design line 38 ("no hard invariant depends on a client hook") is false
   for mode. FIX: move permission-mode enforcement into the mediated server, OR
   reclassify it as claude-only behavioral policy (remove from mode_pin/b1).
2. shim-wrap scope escape: user stdio entries are restricted only by name
   (render_mcp:246/286); a differently-named user entry whose command is bare
   `codex mcp-server` bypasses the shim wrapper. Renderer-scope hole, not a hook
   dependency, but it breaks the P1/P2 boundary. FIX: reject or shim-wrap user
   stdio entries whose executable/argv resolves to `codex mcp-server`.

## HIGH
- M3 proof gap: the render-identical digest gate does not exist; generators:2853
  compares one freshly-generated set against its own manifest and omits several
  M3 outputs -> a changed renderer can certify changed behavior. FIX: frozen
  pre-M3 oracle, byte-for-byte compare of every moved artifact from identical
  fixtures.
- Manifest is not delivery proof: doctor row validates manifest JSON (cbox:4698)
  and the verifier checks files on disk, not installed client config, mounts,
  hook execution, or runtime receipt (design lines 8/111 overstate).
- enabled_when_env single-variable cannot express compound prerequisites:
  local-qwen gated by URL only (delegates:121) but runtime needs a model name
  (local_model_mcp:166); hermes-local gated by enable flag only (delegates:183)
  but provider/base-url enforced later (hermes_delegate:430).
- Registry drift: referential-presence checks do not verify that declared
  planes/mechanisms/status/matcher/artifact actually enforce; a syntactically
  valid capability can lie about its enforcement surface (lines 109/140 "silent
  loss structurally impossible" overstated).
- Zero-core-edit fourth-client is false: hard-coded targets in render_mcp:10,
  engines_registry:14 channel enums, cbox_session_bridge:295 dispatch,
  cbox-session.sh:612 admission, generators:213 binary-volume. FIX: implement
  registry-driven dispatch across all five, OR narrow to "bounded documented
  core edits."
- M5 data risk: bridge extractors keep only user/assistant text
  (bridge:342/362/383), not commit/edit/tool events -> mined PROGRESS/CHANGELOG
  cannot have equivalent durability as claimed (lines 67/160).
- Write-boundary misclassification: hermes-delegate isolation is a temp
  HOME/cwd (hermes_delegate:568) + --ignore-rules (:594), NOT a P1 filesystem
  confinement (design line 68 false).

## MEDIUM
- Broken anchors: line 19 (entrypoint:338 never checks profile writability;
  :362-377 accept missing/empty hooks.json); line 40 (devel_explain.py not in
  etc/hooks - it is a scratchpad draft); line 176 (watchdog ALREADY sends text+
  Enter through tmux at limit_watchdog.py:265 - the real limit is replacing
  trusted startup context in-band, not "no text into a running TUI").
- Registry ownership conflict: engines.json owns channel facts (line 106) but
  adapter describe() owns the same (line 117) - precedence undefined.
- M2 completeness: loader session match conditional on non-empty ID
  (continuity_session_start:269) vs entrypoint rejecting valid path when ID
  absent (:694); byte retention differs (bridge 16KB tail :22/703 vs loader
  12KB prefix :23/185) - "strictly stronger" not proven for edge cases.
- M1 not "pure additive": also changes regen output + doctor (generators:2966).
- One-writer SPOF: lease detects a competing main only inside the same session
  ID (cbox-session.sh:624); two live session IDs in one project both pass their
  local lease and can write the brain concurrently. FIX: project-scope doctor
  check for multiple activeMain across session IDs.
- Loader SPOF: one loader for all engines (line 60) without per-engine failure
  semantics or last-known-good payload.
- Honest list omits: engine history schemas, cursor/resume semantics,
  auth/install probes, permission models, MCP merge/reload formats, startup-hook
  crash behavior, native subprocess paths bypassing P2.

## Required for greenlight (sol's 10)
1. mode_pin -> mediated server, or reclassify claude-only.
2. shim-wrap user stdio resolving to `codex mcp-server`.
3. M3 frozen pre-M3 oracle, byte-for-byte.
4. Compound predicates + operational-prerequisite validation.
5. One owner for engine facts (adapters consume engines.json).
6. Correct false anchors (lines 19,40,59,68,125,140,154,176,197).
7. M2 missing-session-ID + byte-retention contract + golden fixtures.
8. M5 per-engine event extraction (commits/edits/tool outcomes/dedup/cursor/
   provenance) before claiming durability.
9. Registry-driven client dispatch, or narrow "zero core edits."
10. Project-scope doctor check for multiple live activeMain.

## Optional hardening
- Fail-closed (not skip) when egress configured but not applied (cbox:3497).
- Separate manifest production from verification; verify deployed artifacts.
- Cached last-known-good loader payload + explicit fail policy per transport.
- OS-level workspace confinement if cwd admission is meant to be a boundary.
