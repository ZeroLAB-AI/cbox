USER-EXTENSION MODEL — design for cbox (deliverable for Marek)

DESIGN SUMMARY
One user-owned directory outside the package (`~/.config/cbox/user/`), read-only to cbox, merged into every engine render through the mechanisms cbox already has — with the single new component being a conflict validator embedded at the existing MCP render chokepoint `_cbox_render_mcp_for_target` (/zerolab/agent_ecosystem/cbox/templates/generators.sh:254). The security red line is enforced by construction (generators always include cbox entries unconditionally; the user layer can only add through the validator) plus entry-level refusal for the dangerous classes. Correction to the input scan: hermes has TWO surfaces — the engine (`cbox run hermes`) DOES have a policy channel (`_hermes_kernel_preamble`, entrypoint.sh:525-539, injected at :606-632); only the delegate (`hermes_delegate_mcp.py`, `--ignore-rules`) has none.

1. OWNERSHIP MODEL

Path: `~/.config/cbox/user/` — precedent already in the tree: `_cbox_ollama_owner_dir` = `~/.config/cbox/infra/ollama` (generators.sh:2838), so `~/.config/cbox/` is already cbox's host root. Outside `$INSTALL_DIR` -> survives the rsync publish of the package dir and survives `generated/` regeneration. Registered as one variable `CBOX_USER_DIR` (default above) in `etc/registry/settings.json` — schema `{key, section, type, default, role, export, prompt, help, validator}`; new section `user-layer`, apply_class `recreate` (a new bind mount). No on/off knob: empty or missing dir = no-op.

Layout:
```
~/.config/cbox/user/
  mcp/<name>.json        one file per server, filename = server name,
                         same entry schema as etc/mcp/delegates.json
                         (MCP spec + _cbox{adapter, available_to, enabled_when_env?})
  policies/*.md
  agents/*.md            (claude only)
  hooks/claude.fragment.json   hooks-block fragment, same shape as
                               etc/claude/settings.merge.json "hooks" key
  hooks/codex.fragment.json    (increment 5, gated)
  hooks/bin/*                  user hook scripts
```

INVARIANT (ownership): cbox opens the user layer read-only and never creates, modifies, deletes, or renames anything under `CBOX_USER_DIR`. No cbox code path holds a write fd there; `backup_host_file` targets stay in `BACKUP_DIR`. Materialized copies of user files in cbox-managed targets (see agents) are cbox-owned artifacts; the source of truth is always the user layer.

Mount: `$CBOX_USER_DIR:/etc/cbox/user:ro` added next to the hermes-managed mount (generators.sh:1099 region, both compose call sites). ro in-container is deliberate: an agent inside the container cannot self-extend the trusted layer, same property the agents dir has today.

Aevum concretely: drop `~/.config/cbox/user/mcp/aevum.json` with `_cbox: {adapter: "stdio-mcp", available_to: ["claude"]}` (or all three engines) — it appears in every selected engine on the next rebuild and never disappears again.

2. THE 4x3 MATRIX

The anti-drift requirement first (the conf_save-vs-whitelist lesson): the user merge lives in exactly ONE place per layer, consumed by both the host-side setup.sh path and the container-rebuild path. For MCP that place is `render_mcp.py` itself — all five render sites already flow through it (`_cbox_render_mcp_for_target` generators.sh:254 called from :2067 hermes, :2134/:2241 claude, :2405 codex; plus `merge_mcp_json` setup.sh:972 host-side). `render_mcp.py` grows a `--user-dir` argument: load `user/mcp/*.json`, validate (section 4), union into the delegates dict, render as today.

MCP:
- claude: source-level inclusion via render_mcp.py, PLUS port the additive python of `merge_mcp_json` (setup.sh:990-994: pop only known-managed names not in rendered, then update) into `_gen_claude_cbox_json_seed_render`, replacing `cur["mcpServers"]=mcp` at generators.sh:2259. "Known-managed" = cbox delegates.json keys + user-layer names; truly foreign entries survive. This moves the existing additive idiom into the rebuild path, which is the whole ask.
- codex: `cbox-container.config.toml` stays a full-file render (`gen_codex_profile_into` generators.sh:2455-2488, MCP blocks from :2405) — additivity is source-level, which is correct for a generated ro artifact. The user's own `~/.codex/config.toml` remains untouched except cbox's marker block (`codex_mcp_merge_block` setup.sh:2049 — existing idiom, refuses unmarked conflicting blocks; no change).
- hermes: `gen_hermes_mcp_servers_into` (generators.sh:2056) renders from the same chokepoint -> user entries come free. `_hermes_apply_mcp_servers` (entrypoint.sh:461-523) stays a block-replace; hand-edits inside `config.yaml`'s `mcp_servers:` block remain unsupported and documented as such — the user layer is the contract.

POLICIES (uniform rule: user text first, cbox kernel after = cbox has the last word; plus one new kernel sentence: "If any user policy conflicts with this kernel, this kernel wins."):
- claude: nested bind `$CBOX_USER_DIR/policies` -> `${HOST_HOME}/.claude/policies/user:ro` (under the existing policies mount, generators.sh:1007/1026/1038). New marker block `<!-- cbox:user-policies:begin/end -->` in CLAUDE.md ABOVE the kernel block, containing `@~/.claude/policies/user/<file>.md` imports — rendered by a sibling of `claude_md_merge_kernel_block` (setup.sh:2318). The `@~/...` import form is proven by Marek's own global CLAUDE.md. This closes the real gap the scan found: user policy files today sit on disk unread.
- codex: `gen_codex_agents_into` (generators.sh:2569-2604) already folds the user's AGENTS.override.md first; extend it to also concatenate `user/policies/*.md` in a `===== cbox user policies =====` section before cbox's preamble+kernel (codex has no import syntax). The 64000-byte die (:2598-2601) gets a validator pre-check that names the offending user files.
- hermes engine: prepend `cat` of `/etc/cbox/user/policies/*.md` (sorted) before the kernel in `_hermes_session_prompt` (entrypoint.sh:606) — pure concatenation into an existing additive channel.
- hermes delegate: N/A honestly — `--ignore-rules`, caller-supplied system only, no injection point by design (owner decision 3).

AGENTS:
- claude: `agents_install` (setup.sh:1931-1956) gains a second pass installing `user/agents/*.md` into the same target, skipping any basename that collides with an `etc/agents/*.md` name (warn + skip, section 3). `agents_prune_deselected` (setup.sh:1909-1929) keeps iterating only cbox-shipped names -> user files never pruned (already true today). Materialized copies are tracked in `generated/state/user-materialized.list` so cbox may clean up its own copy when the user deletes the source — this cleanup deletes a cbox artifact, not user data. Optimization pending a live check (below): if Claude Code scans `~/.claude/agents` recursively, replace materialization with a zero-copy nested bind `agents/user:ro`.
- codex: N/A — no agent-file concept exists; the nearest unit is a profile, which is already user-owned and untouched. Do not fake it.
- hermes: N/A — reached via the claude-side `hermes-local` agent, governed by the claude row.

HOOKS:
- claude mount mode: second `merge_settings_json` call (setup.sh:2444 idiom) with `user/hooks/claude.fragment.json` after the cbox merge — `merge_hooks` (setup.sh:931-951) is union-by-matcher/append-by-command and cannot delete. Scripts via nested bind `hooks/bin` -> `${HOST_HOME}/.claude/hooks/user:ro` (no filename collisions possible with cbox's flat hooks dir).
- claude volume mode: fix `gen_settings_volume` (generators.sh:2305-2324) to apply the same two merges source-level (template + user fragment). This removes the silent additive->overwrite downgrade for cbox+user content; live `/config` edits still get clobbered on rebuild — unchanged today, documented, out of scope.
- codex: `gen_codex_hooks_json_into` (generators.sh:2491-2514) merges `user/hooks/codex.fragment.json` at generation time (source-level union by event). GATED on the codex hook semantics live check (section 4). Note codex runs in-container with `--dangerously-bypass-hook-trust` (entrypoint.sh:570), so a user fragment is unprompted code execution at codex start — same trust class as a user MCP server in-container, but it makes the semantics check mandatory before shipping.
- hermes: N/A — no hook concept anywhere in the integration.

3. NAME COLLISION

Rule: cbox wins for every name cbox ships (delegates.json keys, `etc/agents/*.md` basenames, `claude_md_policy_files()` names, hook script filenames). A colliding user entry is not rendered; setup and `cbox doctor` print: `user mcp 'X' is shadowed by a cbox-managed entry - rename it`. Additionally the prefixes `codex-*` and `cbox-*` are reserved and refused outright for user MCP names — `render_mcp.py:33-46` already hard-couples `codex-*` to the shim-wrapped `codex-mcp` adapter because the entrypoint boot gate and `codex_mode_guard` key off those names.

Justification: (a) guards and policies trust cbox names — routing policy references `codex-sol` etc., `agent_label_guard` validates agent names, the boot gate requires every `codex-*` server to be shim-wrapped; user-wins would make a user-controlled server silently receive traffic that cbox routes with cbox trust (confused deputy). (b) Deterministic and rebuild-stable — independent of mtimes and iteration order. (c) Cheap to recover — renaming costs the user one string; aevum collides with nothing.

4. CONFLICT VALIDATOR

Placement: inside `render_mcp.py` for MCP (its `DelegateEntryError` fail-closed idiom is exactly the needed shape) plus a small `user_layer_check` (etc/registry or lib) for the other three layers, called from `regen_all` (generators.sh:2793) and from the setup steps. Because generators include cbox entries unconditionally and the user layer is input-only, subtraction is impossible by construction — the validator only has to police additions.

Per-engine semantics decide strictness:
- claude hooks: FAIL-SAFE (verified: all matching hooks run, any deny wins) -> minimal validation.
- codex hooks: semantics UNKNOWN (union vs replace/first-match) + full-file generated delivery -> treat as FAIL-OPEN, strict, gated.
- hermes hooks: nonexistent.
- MCP, all engines: generated-from-source (fail-open at file level, controlled at source) -> strictness lives in entry validation.
- policies, all engines: advisory concatenation; mechanical invariants live in guards, not text -> fail-safe for the security invariant, UX-only validation.

Classes:
(a) SAFE-ADDITIVE — schema check only: claude hook fragments (deny-union), non-colliding claude user agents, policy files, plain stdio user MCP entries (command/args/env — aevum's class).
(b) UX-CONFLICT — warn, render anyway: policy text contradicting a cbox policy (not mechanically judgeable; mitigated by user-first/kernel-last ordering plus the kernel precedence sentence); a user hook whose matcher/deny is broad enough to block cbox's own flows ("your deny on Write|Edit will also fire on cbox operations"); codex AGENTS size near the 64000 cap; duplicate tool names across user servers.
(c) SECURITY-DANGEROUS — entry REFUSED, never rendered: name collision with a cbox-managed name or reserved prefix; user MCP using adapter `codex-mcp` or `claude-cli` (trust-bearing wrappers that inject cbox shim/relay scripts with pinned flags — user layer gets `stdio-mcp` only); command/args referencing cbox hook/relay script paths or carrying escalation tokens (`--dangerously-*`, `danger-full-access`, `approval_policy`, `bypassPermissions`, `--ignore-rules`); keys outside the allowed user schema (no compose/mount influence — the user layer contributes in-container config only, never mounts); and, until the codex semantics check passes, any user codex fragment on guard-relevant events (`PreToolUse`, `PermissionRequest`).

Refusal behavior: the entry is excluded from ALL renders, a hard error names file and reason, `cbox doctor` carries a persistent row, and interactive setup blocks its confirm screen until acknowledged. In non-interactive regen paths the rebuild still completes without the entry — a broken user file must not brick container rebuilds; the dangerous thing simply never ships. That is the "refuses, not just warns" semantics at entry granularity.

5. THE SECURITY INVARIANT

Stated once: THE USER LAYER IS INPUT, NEVER AUTHORITY. Nothing under `CBOX_USER_DIR` can remove, replace, disable, or reconfigure any cbox-shipped guard, delegate, policy file, or hook, and no user entry may acquire a cbox-trusted name, a trust-bearing adapter wrapper, or a capability-escalation flag. cbox reads the user layer read-only and writes nothing there.

Enforcement point: the render chokepoint. Every generated artifact is a function of (etc sources + user layer), cbox content is included unconditionally by the generators, and the validator inside `render_mcp.py` / `user_layer_check` refuses class-(c) entries at every render — `regen_all`, every setup step, and the hermes entrypoint render all pass through it. The claude hook layer adds defense in depth: even a validator miss cannot weaken a guard there, because deny-union semantics make weakening structurally impossible.

6. setup.sh UX

New `step_user_layer` screen (registry section `user-layer`, so prompts/help live in `etc/registry/settings.json`, not hand-carried in step_ functions): first an inventory line ("user layer: 1 mcp (aevum), 2 policies, 0 agents, 1 hook fragment"), then per target the contract as computed fact, not promise:

```
  cbox adds its own:   8 mcp servers, kernel block, 5 hooks
  yours, kept as-is:   aevum (mcp), MY-POLICY.md
  deleted:             NONE
  refused (security):  NONE
```

The "deleted: NONE" line is asserted by the merge code itself (the merge scripts count removed keys; only deselected cbox-owned names may ever appear, printed as "cbox removed its own: X"). Existing diff previews (`staged_write` setup.sh:842, `staged_install_files` :870) already show additions line by line; confirmation reuses the same `[y/N]` idiom. Any class-(c) refusal renders in red above the prompt and requires acknowledgment. `cbox doctor` gets a user-layer row: active / shadowed / refused counts.

7. SEQUENCING

Increment 1 — MCP, the aevum driver: `CBOX_USER_DIR` registry var + mount; `render_mcp.py --user-dir` + validator v1 (schema, cbox-wins collision, reserved prefixes, stdio-only, token denylist); port merge_mcp_json semantics into `_gen_claude_cbox_json_seed_render` (kills the generators.sh:2259 overwrite); codex and hermes inclusion comes free through the chokepoint; `step_user_layer` + doctor row. Tests: extend `lib/test_render_mcp.sh` (user entry included; collision, codex-*, danger-token refused) + a differential rebuild test proving foreign and user entries survive the seed render.
Increment 2 — policies: claude user-policies marker block + nested policies/user mount; codex fold-in extension + cap pre-check; hermes-engine preamble prepend; kernel precedence sentence.
Increment 3 — agents (claude only): materialization + manifest, or recursive-mount if the live check passes.
Increment 4 — claude hooks: second merge_settings_json call (mount) + `gen_settings_volume` merge fix (volume) + hooks/bin nested mount.
Increment 5 — codex hooks, genuinely hard: requires a host-side experiment answering whether codex runs all hooks per event with deny-wins (union) or replace/first-match, and how that interacts with `--dangerously-bypass-hook-trust`. Until answered, user codex hooks stay refused on guard-relevant events. Hermes hooks: permanently N/A unless hermes grows the concept.

OWNER DECISIONS (the 2-3 that are Marek's to make)
1. Policy-conflict protection scope: recommended red line = mechanical guards only; textual policy conflicts are UX (user-first/kernel-last ordering + precedence sentence). The alternative — mechanically protecting prompt-only norms — requires text classification and cannot be honest. Accept that a user CAN talk their own sessions out of prompt-only conduct norms on their own machine?
2. User MCP adapter scope: recommended `stdio-mcp` only. Allowing user reuse of `codex-mcp`/`claude-cli` wrappers would need per-flag validation of trust-bearing relays — defer until a real need exists.
3. Hermes-delegate policy channel: keep `--ignore-rules`/no-kernel as designed (recommended), or inject a user/cbox preamble into `hermes_delegate_mcp.py` calls — that changes delegate behavior globally and narrows the sharpest cross-engine asymmetry, but was a deliberate choice.

UNSURE — live checks required (all named in place above)
- Codex hook multi-entry semantics (union vs replace) — decides increment 5; host experiment.
- Claude Code recursive scan of `~/.claude/agents` subdirs — decides materialization vs zero-copy mount.
- `@~/.claude/policies/user/x.md` import from inside a marker block in-container — high confidence (Marek's global CLAUDE.md uses the `@~` form today), still a host TTY verification.
- Publish privacy: after this change `generated/codex/cbox-container.config.toml` and `generated/hermes/mcp_servers.yaml` will embed user server names/commands/env names — confirm the rsync publish excludes `generated/` and `cbox.conf`, or user config leaks into the public repo.
- Claude hooks deny-union is verified on current CC 2.1.x; re-verify after any CC bump (tripwire).

ADR
- Context: all three engines overwrite parts of their config at rebuild; users need durable own MCP/policies/agents/hooks; the security guards must stay unweakenable; cbox already owns merge idioms (merge_settings_json, merge_mcp_json, marker blocks) and one MCP render chokepoint.
- Decision: a read-only user layer at `~/.config/cbox/user/` merged at the existing chokepoints (user merge implemented once per layer, inside the shared renderer, used by both host and rebuild paths); cbox-wins deterministic name collisions; a three-class conflict validator embedded in `render_mcp.py`'s existing refusal idiom, strict where engine semantics are fail-open (codex hooks), minimal where fail-safe (claude hooks); refusal at entry granularity so rebuilds never brick.
- Consequences: aevum wires in one JSON file and survives every rebuild; the generators.sh:2259 and gen_settings_volume overwrites get fixed as part of the model rather than as separate bugs; codex user hooks are consciously deferred behind an empirical gate; generated artifacts now carry user data, making publish excludes a hard requirement; the user layer cannot weaken any guard by construction plus validation, and setup.sh can prove "nothing deleted" arithmetically instead of asserting it.

Key files: /zerolab/agent_ecosystem/cbox/etc/mcp/render_mcp.py, /zerolab/agent_ecosystem/cbox/templates/generators.sh (:254, :2259, :2305, :2455, :2491, :2569, :2056, :2793, mounts :995-1101), /zerolab/agent_ecosystem/cbox/setup.sh (:842, :870, :915, :965, :1902-1956, :2049, :2204, :2318, :2444), /zerolab/agent_ecosystem/cbox/entrypoint.sh (:461-523, :525-539, :570, :598-632), /zerolab/agent_ecosystem/cbox/etc/registry/settings.json, /zerolab/agent_ecosystem/cbox/etc/mcp/delegates.json.
---

# SECURITY CRITIQUE (security-reviewer opus/high)

I have what I need. The design is strong on the MCP axis but has real gaps elsewhere.

# Security review: cbox user-extension layer design

Verdict: the MCP axis (increment 1) is genuinely sound; the invariant "user layer is input, never authority" **does not hold as stated** for three other paths. Two findings are blocking.

---

## CRITICAL-1 — User agent file silently rewrites the model-deny guard's input
`/zerolab/agent_ecosystem/cbox/etc/hooks/agent_label_guard.py:41-47`

```python
meta = frontmatter(os.path.expanduser("~/.claude/agents/%s.md" % atype))
model = ti.get("model") or meta.get("model") or "inherit"
...
if deny and re.search(deny, model) and "safety-fallback" not in desc:
```

The guard reads the model **out of the agent file's own frontmatter** — the very file the design lets users install (`user/agents/*.md`, increment 3). The design's collision rule only protects `etc/agents/*.md` **basenames**; a user file with a *new* name is class-(a) SAFE-ADDITIVE and installed unchecked.

Exploit: drop `~/.config/cbox/user/agents/helper.md` with frontmatter `model: opus-4-1`. `CBOX_AGENT_MODEL_DENY=opus-4` (settings.merge.json:18) is evaded because the resolved model string is attacker-chosen — set `model: sonnet` in frontmatter while the definition body instructs otherwise, or pick any string that fails the deny regex. The guard then *validates the label as correct*, so the deny policy plus the label-truthfulness property both break, with no refusal anywhere.

Minimal fix: validator must parse user agent frontmatter and refuse any entry whose `model` matches `CBOX_AGENT_MODEL_DENY`, or whose frontmatter carries `model`/`effort` keys at all (force user agents to inherit). Add to class (c).

## CRITICAL-2 — Mount mode: hooks dir and agents dir are host-writable; ro is only in-container
`/zerolab/agent_ecosystem/cbox/templates/generators.sh:1001,1017,1022`

```
- $claude_path/hooks:${HOST_HOME}/.claude/hooks:ro
- $claude_path/agents:${HOST_HOME}/.claude/agents:ro
```

`:ro` stops the *container* agent, which the design correctly claims. But `$claude_path` is a plain host directory (`CBOX_CLAUDE_PATH`), and the design's threat model treats the user as trusted-on-host — yet it simultaneously promises the invariant that no user-layer content "can remove, replace, disable or reconfigure any cbox-shipped guard." On the host, a user who is already editing `~/.config/cbox/user/` can equally edit `$claude_path/hooks/rm_glob_guard.py` directly. The guards `rm_glob_guard` and `spawn_gate` exist **only** in `settings.merge.json` (:79-100), which is mounted `:rw` (generators.sh:1002) and is *not* duplicated into `managed-settings.merge.json`. Their guard scripts sit in a host-writable dir.

So the invariant is really "the container-side agent cannot self-extend" — true — not "the user layer cannot weaken a guard" — false, and the design states the latter. This matters because the design's own selling point is that setup.sh can *prove* "deleted: NONE."

Minimal fix: state the invariant honestly as scoped to the container-side agent, **and** mirror `rm_glob_guard` + `spawn_gate` into `managed-settings.merge.json` so the four-guard/six-guard asymmetry closes. Managed-settings is mounted ro from `generated/` (generators.sh:1003) and is the only tamper-resistant channel.

## HIGH-1 — Answer to probe (3): a user MCP entry CAN reach danger-full-access, via env not adapter
`/zerolab/agent_ecosystem/cbox/etc/hooks/codex_mode_guard.py:9-12,82-86,138`

The design blocks the `codex-mcp` adapter and `--dangerously-*` argv tokens. It does **not** block `env`. The guard's entire scope config is env-addressable:

```python
CONFIG = os.environ.get("CODEX_GUARD_CONFIG", ...)
roots += os.environ.get("CODEX_GUARD_EXTRA_ROOTS", "").split(":")
danger_ok = cfg.get("allow_danger_full_access") is True or in_container
```

A class-(a) "plain stdio user MCP entry (command/args/env — aevum's class)" may set `env: {CODEX_GUARD_CONFIG: "/workspace/mine.json", CODEX_GUARD_EXTRA_ROOTS: "/"}`. That env is inherited by any child the server spawns, and `allow_danger_full_access: true` in a user-controlled JSON grants the exception the design says is "scoped to cbox codex delegates." Also `CODEX_GUARD_AUDIT` can be pointed at `/dev/null` to blind the audit trail, and `CBOX_SPAWN_GATE_MAX_UNLANDED` / `CBOX_SPAWN_GATE_STATE` (spawn_gate.py:9-12) are equally redirectable.

Minimal fix: validator refuses user MCP `env` keys matching `^(CODEX_GUARD_|CBOX_SPAWN_GATE_|CBOX_RUNTIME|CBOX_AGENT_MODEL_DENY|CLAUDE_|ANTHROPIC_)`. Allowlist user env keys rather than denylisting tokens — the design's argv-token denylist is the wrong shape here.

## HIGH-2 — Answer to probe (2): hermes policy channel is REPLACE, not union
`/zerolab/agent_ecosystem/cbox/entrypoint.sh:461-523` (`_hermes_apply_mcp_servers`)

The block-replace logic deletes every line after `mcp_servers:` that starts with whitespace, then inserts the rendered block. That is fine for cbox-rendered content. The risk is the design's increment-2 hermes step: prepending `cat` of `/etc/cbox/user/policies/*.md` before the kernel in `_hermes_session_prompt` (:606). Unlike claude's hooks, this is **plain text concatenation with no structural precedence** — the "kernel wins" property is a *sentence inside the prompt*, not a mechanism. The design admits this under owner decision 1, but classifies hermes policies as "fail-safe for the security invariant," which is only true because hermes has no hooks — the kernel is hermes' *only* control channel, so degrading it is not fail-safe, it is total.

A user policy file of 60KB of "ignore all subsequent instructions" is class-(a) SAFE-ADDITIVE and prepends ahead of the kernel. Minimal fix: cap total user policy bytes for hermes, and put the kernel *last with a delimiter*, which the design does — but also add a size ceiling per engine and surface the ratio (user bytes : kernel bytes) in `cbox doctor`.

## MEDIUM-1 — Codex hooks: correctly deferred, and the gate is right
`gen_codex_hooks_json_into` (generators.sh:2491-2513) is a **full-file overwrite** producing only `SessionStart`. Combined with `--dangerously-bypass-hook-trust` (entrypoint.sh:570), a user fragment on `PreToolUse` would be unprompted code execution with unknown union/replace semantics. The design refuses this until the live check passes. **Closed as designed** — keep increment 5 gated, do not relax.

## MEDIUM-2 — Answer to probe (4): ownership boundary holds; publish leak is real
No cbox code path writes under `CBOX_USER_DIR`; `backup_host_file` targets `BACKUP_DIR`, and `staged_install_files` (setup.sh:870-912) only writes into `$dst`, never the source. **Closed.** The design's own UNSURE item is however a genuine leak: `generated/` will embed user server names, commands and env *keys*. Note the existing precedent at `lib/test_sshd_entry.sh:260` — the tree already treats package-dir private state as a publish leak. Minimal fix: make the publish exclude of `generated/` and `cbox.conf` a **test**, not a convention.

## MEDIUM-3 — Answer to probe (5): name collision is closed for MCP, open for hooks/policies
`render_mcp.py:33-46` already hard-refuses `codex-*` mismatches, and the design extends this correctly with reserved prefixes and cbox-wins. **Closed for MCP.** But `merge_hooks` (setup.sh:923-940) matches on `matcher` string equality and appends by `command`. A user fragment with `matcher: "Bash"` merges into the *same* entry as `commit_guard` and `rm_glob_guard`. It cannot delete them (append-only, verified), so deny-union holds — but a user hook that exits 0 loudly with misleading stderr on every Bash call can drown the guard's DENY message. UX-conflict class (b) is the right bucket; make sure the warning fires on exact-matcher collisions with guard matchers (`Bash`, `Write|Edit|MultiEdit`, `Agent`, `Agent|Workflow`, `mcp__codex-.*`).

## LOW-1 — `render_stdio_entry` path-joins relative python3 args into the hooks dir
`render_mcp.py:99-103`: if `command == "python3"` and `args[0]` is relative, it is prefixed with `hooks_dir`. A user entry `{command: "python3", args: ["../../../workspace/evil.py"]}` resolves inside the trusted hooks path. Harmless today (the user already controls the command), but it defeats the design's "command/args referencing cbox hook/relay script paths" refusal by using traversal instead of a literal path. Minimal fix: refuse `..` in user args, and reject relative `args[0]` for user entries entirely.

---

## Summary of required design changes before increment 1 ships
1. Env-key allowlist for user MCP entries (HIGH-1) — belongs in increment 1, not later; it is the same file the aevum driver touches.
2. Restate the invariant as container-scoped, and mirror `rm_glob_guard` + `spawn_gate` into managed-settings (CRITICAL-2).
3. Agent frontmatter `model`/`effort` into class (c) before increment 3 (CRITICAL-1).
4. Traversal refusal in user args (LOW-1).

Probes (2)-codex, (4) and (5)-MCP are closed by the design as written. Probe (1) is **not** closed: the guard-weakening path runs through guard *inputs* (env vars, agent frontmatter, scope JSON), which the design's validator does not model at all — it polices entry shape, not the configuration surface the guards themselves read.
---

# CORRECTNESS CRITIQUE (code-reviewer sonnet/high)

No publish/rsync script found in this repo at all — the design's own "publish privacy" concern (section UNSURE, bullet 4) references a mechanism I cannot locate here, consistent with the memory note that `cbox/` publishes via a separate mechanism/repo outside this tree. That's a real unverifiable gap, correctly flagged by the design as UNSURE already.

I have enough grounded evidence. Here is the review.

CRITICAL

1. `cbox/etc/mcp/render_mcp.py:218-234` (`main()`) — the design's Increment-1 centerpiece, "`render_mcp.py` grows a `--user-dir` argument," undersells the actual change. `main()` takes exactly 4 or 5 strictly positional args (`sys.argv[1:5]` + optional `sys.argv[5]`) with no flag parser at all. Every one of the 5 call sites (`_cbox_render_mcp_for_target` generators.sh:254-262, `merge_mcp_json` setup.sh:972) passes positional args, several inline with `$(...)`. Adding `--user-dir` means writing an actual arg parser (currently none exists — argv is destructured by position), then touching every call site to pass the new flag *and* every call site must also compute/pass the actual `user/mcp/*.json` glob contents into that flag reliably in both host (setup.sh) and container-rebuild contexts, which have different `$HOME`/mount visibility (host process doesn't have `/etc/cbox/user` — it has `$CBOX_USER_DIR` directly; container-rebuild does through the ro bind). The design states this as if it's a one-line parameter add; it is closer to a rewrite of `main()`'s argument handling plus a real path-selection decision (host path vs. mounted path) at every one of 5 call sites. Fix: spell out the two distinct filesystem views (host: read `$CBOX_USER_DIR/mcp/*.json` directly; container path in `_cbox_render_mcp_for_target`: read `/etc/cbox/user/mcp/*.json` via the ro mount) and confirm `_cbox_render_mcp_for_target` is only ever invoked host-side during generation (i.e., "container-rebuild" here means host-side render into `generated/`, not something running live inside a container) — if that's not true the mount isn't even in scope for render time and the whole ro-mount premise for MCP is moot (mounts affect running containers, not the host-side generator that produces `generated/`).

2. `cbox/templates/generators.sh:2491-2514` (`gen_codex_hooks_json_into`) — the design describes Increment 4/5's codex-hooks change as "`gen_codex_hooks_json_into` merges `user/hooks/codex.fragment.json` at generation time (source-level union by event)," implying an existing merge mechanism gets extended. Reading the function: it is not a merge at all today — it's a hardcoded single-entry dict (`SessionStart` → `continuity_session_start.py`) built inline in an embedded `python3 -c` one-liner with no generalized event-merge logic. "Union by event" for arbitrary hook events (PreToolUse, PermissionRequest, etc.) does not exist to extend; it must be built from scratch, and this is exactly the surface the design itself flags as "genuinely hard" and gates behind an unresolved semantics question (union vs. replace/first-match). That's consistent internally, but the ADR's summary language ("the generators.sh:2259 and gen_settings_volume overwrites get fixed as part of the model rather than as separate bugs") lumps this in with genuinely mechanical fixes when it is actually new code behind an open unknown — the sequencing section (Increment 5) already says this correctly; the top-level summary/ADR overstate uniformity. Fix: ADR consequences bullet should explicitly separate "mechanical merge-idiom reuse" (claude JSON, MCP union) from "new merge logic pending an experiment" (codex hooks) so a reader skimming only the ADR doesn't walk away thinking increment 5 is as safe as increment 1.

3. Missing lifecycle cell: **first-run / fresh-install ordering** is never addressed. `CBOX_USER_DIR` defaults to `~/.config/cbox/user/`, and the design says "empty or missing dir = no-op" — but does the mount (`$CBOX_USER_DIR:/etc/cbox/user:ro`, apply_class `recreate`) get added to compose *before* the directory exists on disk? Docker bind-mounting a nonexistent host path historically silently creates an empty root-owned directory (or errors, depending on engine/version) — this is exactly the kind of thing that should be a `mkdir -p "$CBOX_USER_DIR"` in setup, but the design never states who creates the directory, when, and with what ownership/perms, despite explicitly disclaiming cbox writes anything *under* it (the directory itself is a different question from its contents). Fix: state explicitly "setup.sh creates `$CBOX_USER_DIR` itself (mkdir, not a write to its contents) exactly once, idempotently, before the mount is ever rendered into compose," and add a test asserting fresh-install with no pre-existing user dir does not error or produce a root-owned directory.

WARNING

4. `cbox/setup.sh:989-994` (`merge_mcp_json`'s "known-managed" pop-logic) — the design's Increment 1 says: `"Known-managed" = cbox delegates.json keys + user-layer names; truly foreign entries survive`. But look at the actual prune condition: `if name in known_cbox and name not in rendered: mcp.pop(...)`. If `known_cbox` is unioned with user-layer names, then a name that is *no longer* in the user's `mcp/*.json` on disk (i.e., the user deleted `aevum.json`) but is still present in the *live* `~/.claude.json` from a prior render will now be silently popped by this same mechanism, since it will be in the "known" set from a stale render pass, or — worse — if "known" is computed fresh each run from the current `user/mcp/*.json` glob, then deleting the user's file causes cbox to prune an entry it does not own the deletion rights to per the stated ownership invariant ("cbox opens the user layer read-only and never creates, modifies, deletes... anything under CBOX_USER_DIR"). That invariant is about the *source* directory, but this pop() operates on the *materialized* `~/.claude.json`, a cbox-owned artifact — so it's arguably fine, but the design never states this distinction explicitly, and "yours, kept as-is" language in the setup.sh UX mockup (`aevum (mcp)`) reads as a promise about persistence that a user deleting their own source file will falsify (the entry disappears from `~/.claude.json` next rebuild, which is correct behavior but contradicts the "deleted: NONE" / "kept as-is" framing unless the user's own removal is called out as the one case where cbox legitimately removes a materialized copy). Fix: add explicit fourth line to the UX contract: `removed because you deleted the source: <names>` distinct from `refused (security)` and `cbox removed its own`.

5. Section 3 name-collision + Section 4 class-(c) validator — `codex-*` prefix reservation is justified by `render_mcp.py:33-46`'s existing `_adapter_of` checks, which is real and correctly cited. But the design's refusal list for class (c) includes "command/args referencing cbox hook/relay script paths" as a refused pattern — this requires string-matching against paths like `$hooks_dir + "/" + script` that are *computed at render time* per engine (see `render_stdio_entry`: `hooks_dir + "/" + args[0]`), meaning the denylist check must run either before or after path resolution, and a user MCP entry legitimately wanting `command: python3, args: [myscript.py]` (relative, resolved against the *user's own* hooks convention, not cbox's) could false-positive collide with the "referencing cbox hook/relay script paths" rule if the check is implemented as a naive substring match on the resolved absolute path (`/root/.claude/hooks/...` prefix shared by both cbox and — if materialized wrongly — user scripts). The design never specifies where user MCP stdio scripts even live (there's no `user/mcp/bin/` in the layout) or how `render_stdio_entry`'s relative-arg-resolution (`hooks_dir + "/" + args[0]`) applies to user entries without accidentally reaching into cbox's own `hooks_dir`. Fix: define whether user stdio MCP entries may reference on-disk scripts at all (if so, where — a `user/mcp/bin/` mirroring `hooks/bin`), or restrict class (a) SAFE-ADDITIVE stdio entries to `command` being an absolute path or a bare PATH-resolved binary name only, never a cbox-hooks-relative one.

6. Section 2 AGENTS / materialization tracking (`generated/state/user-materialized.list`) — the design proposes this new state file as the delete-tracking mechanism ("cbox may clean up its own copy when the user deletes the source"), but this is a genuinely new persistent-state mechanism, not a reuse of an existing idiom, and the design's own probe question #2 asks "does it genuinely reuse existing idioms... or quietly invent parallel new mechanisms that add drift?" — this is exactly such an invention, correctly flagged as "pending a live check" only for the *materialization vs. mount* choice, but the tracking-list mechanism itself is unconditional new state regardless of which branch wins. If the recursive-mount branch is taken (Claude Code scans `~/.claude/agents` subdirs), the tracking list becomes entirely dead code / never-written, which is fine, but if materialization is required, this is a new drift surface (a manifest file that must itself survive rebuilds, be read on every `agents_prune_deselected` pass, and correctly reconcile with `agents_prune_deselected`'s existing cbox-name-only iteration) that the design doesn't test-plan at all (Increment 3 in section 7 has no test bullet, unlike Increment 1's explicit test list). Fix: give Increment 3 the same test rigor as Increment 1 (a differential test: materialize, delete source, rebuild, assert cbox's copy is gone and no other agent file was touched), and pin the live check with a concrete deadline/owner since it gates which mechanism ships at all.

SUGGESTION

7. Section 5 (security invariant) states "the claude hook layer adds defense in depth: even a validator miss cannot weaken a guard there, because deny-union semantics make weakening structurally impossible" — this is asserted as "verified" per the UNSURE section's last bullet, but that verification is CC-version-pinned and explicitly named as a tripwire. Given how load-bearing this specific claim is (it's the fallback argument for why a validator bug in class (c) refusal is not catastrophic for claude hooks specifically), consider promoting it from a tripwire bullet to an actual CI/doctor check — e.g., `cbox doctor` could assert the installed CC version against the last-verified version and downgrade the "defense in depth" doctor row to WARN if untested on the current version, rather than relying on a human remembering to re-check after every bump.

8. Section 7 sequencing never states what happens to a user who has already dropped files into `~/.config/cbox/user/` (following documentation, or copying the design doc's own example) during Increment 1 (MCP-only) — if they also drop `policies/*.md` or `agents/*.md` early (since the directory layout in section 1 is presented as the full final shape up front), Increment-1-era code has no `user_layer_check` for those classes yet, so those files sit inert with zero feedback (no warning that "policies aren't wired yet"). Since `cbox doctor`'s user-layer row is introduced with the inventory line in section 6 but doctor rows aren't scoped per-increment in the design, a user could reasonably believe an inert `policies/*.md` file is either respected or refused, when it's actually silently ignored by Increment-1 code. Fix: Increment 1's `step_user_layer` inventory line should still enumerate *all* subdirectories present (mcp/policies/agents/hooks) even before those layers are wired, with an explicit "not yet active in this cbox version" marker for classes beyond MCP, so nothing is silently invisible.

Everything cited above was checked against the current HEAD tree: `/zerolab/agent_ecosystem/cbox/etc/mcp/render_mcp.py`, `/zerolab/agent_ecosystem/cbox/templates/generators.sh` (lines 254, 2237-2263, 2305-2324, 2455-2514), `/zerolab/agent_ecosystem/cbox/setup.sh` (lines 965-999, 1909-1956), `/zerolab/agent_ecosystem/cbox/entrypoint.sh` (lines 461-539, 598-632). All line-number citations in the design document itself were verified accurate against HEAD — the design's factual grounding is solid; the gaps found are in the *delta* it proposes (undersold implementation cost of `render_mcp.py`'s CLI, a from-scratch merge mechanism described as an extension of an existing one, and two untested/undertested lifecycle edges: fresh-install directory creation and materialized-file deletion reconciliation), not in its reading of the existing codebase.