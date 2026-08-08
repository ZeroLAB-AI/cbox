# CLI-unification design (cbox)

Status: DRAFT for owner greenlight. Author: main-driver session, from three
Explore recon distillates (setup.sh blast radius, cbox dispatch + hub,
python-first + Q3/Q4/Q7/Q9 enforcement). Norm sibling: USER_EXTENSION_DESIGN.md.

## 0. Owner rulings this design implements (Marek, 2026-08-07, AskUserQuestion)

1. Everything under `cbox` commands; `cbox` works in every directory (not only
   blessed projects).
2. Command chooser at setup time (cbox/claude/codex/hermes as shell-rc
   functions), optional install, `cbox` MANDATORY.
3. Python-first, reduce bash overall: bash logic migrates to python
   incrementally, bash stays a thin bootstrap (supersedes the 07-13 pure-bash
   ruling; builds on multiplatform f65e69c + H1 hub core).
4. `setup.sh` is removed entirely: the first setup is `./cbox setup` from the
   folder, which creates the alias/PATH install.
5. HUB_DESIGN Q3/Q4/Q7/Q9 all ON: Q3 drift stamp for global config too, Q4
   engine attribution row, Q7 tmux multiplex view (persistent-tmux design
   funded now), Q9 HARD-BLOCK of foreign engine processes (over the warn-only
   proposal, knowingly).

## 1. Scope correction (recon result): this is a thin overlay, not a rebuild

P1/P2/P3 of HUB_DESIGN already exist on disk:

- P1 engine registry: `etc/engines/engines.json` + `engines_registry.py` (3
  engines incl. hermes, each with `probe.infra_filter_argv1`).
- P2 `cbox config`: `get/set/pending` verb (cbox:1342 dispatch, 5998),
  headless per-key writer `_cbox_config_set*` (cbox:4873+).
- P3 bare-`cbox` hub: `hub()` (cbox:5849) + python core `lib/cbox_hub.py` with
  `__hub_context` JSON handshake (cbox:6015) and exit-97 -> bash-hub fallback.

The wave therefore adds a `cbox setup` verb, makes `cbox` run anywhere, adds a
command chooser, and lands the Q3/Q4/Q7/Q9 deltas over the existing hub. It
does NOT build the hub or the config engine from scratch.

## 2. What breaks when setup.sh is deleted (blast radius)

### 2.1 Three real subprocess calls (functional blockers, not text)

`cbox` execs `setup.sh` as a subprocess in exactly three places; deleting the
file without replacing these breaks `cbox run` (isolated, new project) and
drift re-bless immediately:

- cbox:1651 `_first_run_init` branch `n` -> `setup.sh --local <root>`
- cbox:1652 `_first_run_init` branch `d` -> `setup.sh --local <root> --from-global`
- cbox:2358 `_cbox_rebless_local` -> `setup.sh --local <root> --from-global`

### 2.2 setup.sh entry verbs (must all live under `cbox setup`)

From setup.sh dispatch (setup.sh:3586-3624): wizard (no arg), `--help`,
`update` (re-bless, `run_rebless`), `update <section>` (`run_update`),
`list-steps`, `--config <file>` (`run_config`), `--local <root>` (`run_local`),
`--local <root> --from-global`, `uninstall` (`run_uninstall`, 4 sub-funcs).

Logic present ONLY in setup.sh (no cbox equivalent, must be internalized): the
whole interactive wizard UI (`ask`/`ask_choice`/`ask_yn`/`_menu_select`/
`checkbox_select`/`nav_prompt`), `run_wizard`, `apply_default_setup`,
`run_update`, `run_rebless`, `list-steps`, `--config` install, and all four
`uninstall` sub-functions. `--local` bless/re-bless is called only as a
subprocess from cbox today (2.1), so it is an external dependency to
internalize, not a duplication.

Already shared (no migration): `_common.sh`, `templates/*.sh`, `regen_all`
(generators.sh) are sourced identically by both `cbox` and `setup.sh`.

### 2.3 External references to repoint (docs sweep + test repoint)

- 11 test suites parse or iterate setup.sh (correctness critique corrected the
  count from 9). Nine awk/grep-parse functions by name/exact line
  (test_conf_writer_parity, test_container_exec_inertness,
  test_container_exec_render, test_hermes_delegate_render, test_kernel_lang,
  test_ollama_section, test_render_mcp, test_user_policies_layer,
  test_wireguard_section). Two more: test_portable_preflight.sh:26 iterates
  `for f in cbox setup.sh` (structural preflight-ordering invariant), and
  test_bash32_oneliners.sh:220 hardcodes `"setup.sh"` as a denylist key
  (portability_denylist.py:98 `open()` -> FileNotFoundError if setup.sh is
  deleted). All 11 repoint to `lib/cbox-setup.sh` in increment A.
- REGISTRY: `etc/registry/file_inventory.json` is a machine-enforced 1:1
  manifest (test_file_inventory.sh:34 fails on any uninventoried file OR stale
  entry). setup.sh has an entry at file_inventory.json:463. Increment A (adding
  lib/cbox-setup.sh) and increment F (deleting setup.sh) EACH must edit the
  inventory in the SAME increment, or the test fails. This is a hard gate, not a
  doc nicety.
- Docs + error-string sweep (increment F), complete inventory: MANUAL.md (28
  occurrences), README.md quick-start, 3 runbooks (HOST_GATE, LOCAL_MODEL,
  WIREGUARD) full of `./setup.sh update <section>`, entrypoint.sh + lib/cbox-ai.sh
  + etc/mcp/hermes_delegate_mcp.py user-facing error strings, `cbox`'s OWN error
  strings (cbox:40, 44, 53, 4429, 4449, 4463, 4486, 4637, 4793, 4925, 5018,
  5024, 5028 - ~15), templates/generators.sh die strings (415-423, 2890), and
  etc/claude/CLAUDE.md:3 ("re-run setup.sh"). The self-references (cbox,
  generators.sh) were missing from an earlier draft - included now.

## 3. Design decisions this doc fixes

### 3.1 Relocate the setup body ONCE, to `lib/cbox-setup.sh`

Move the setup.sh body into `lib/cbox-setup.sh` a single time, on its final
path. The 11 parsing test suites repoint once, not per increment. `cbox`
gains a `setup` verb (zero collision: `setup` is absent from the cbox
dispatch case-list) that sources `lib/cbox-setup.sh` and dispatches its verbs.
setup.sh becomes a thin forwarder; its deletion is the LAST increment, gated
on the owner's forwarder-vs-hard-cut verdict (section 6).

CONTAINER GATE RE-ASSERTED AT THE VERB (security LOW, one line, increment A):
today setup.sh is a separate executable gated in-container at setup.sh:147.
As a `cbox setup` verb reachable in-container via the mandatory `cbox()` shell
function, the gate must be re-asserted at the verb's dispatch entry, not merely
inherited from the relocated internals: `_cbox_config_in_container && die
"setup is host-only"` (mirroring cbox:4940). Otherwise `cbox setup update
<section>` becomes callable in-container and regenerates host artifacts under a
container-trust caller.

### 3.2 Relocation is NOT new bash (python-first policy)

Ruling (3) is python-first; moving ~3600 lines of bash into `lib/` looks like
it violates that. It does not, under this explicit policy:

- New UI/logic surfaces are written in python (the cbox_hub.py + exit-97
  fallback pattern), never new bash.
- Relocated existing bash MAY stay bash; it is a move, not a rewrite. Section
  migration to python happens per-section in later increments, each behind the
  same bootstrap floor.
- The bash bootstrap floor is fixed and stays bash regardless (section 4).

### 3.3 `update` naming collision (resolved here, not an owner question)

`cbox update` already exists as an alias for `reinstall_bins` (cbox:5974),
while `setup.sh update` means re-bless (template regen). Unified, these are two
different "update" semantics in one CLI. Resolution (conventional default, no
owner question):

- Re-bless lives under `cbox setup update` (and `cbox setup update <section>`),
  where it belongs - it is a setup operation.
- `cbox reinstall-bins` stays the canonical binary-reinstall verb; the `cbox
  update` alias for it is deprecated: kept working for one release but dropped
  from the usage string, so nobody learns it as `update`.

### 3.4 `uninstall` placement

`cbox setup uninstall` (uninstall is a setup-lifecycle operation; it lives
next to the wizard that installed the shell-rc block and volumes).

## 4. Bash bootstrap floor (stays bash, never migrates)

- Top-of-file preflight: cbox:1-21 + `lib/portable_preflight.sh` (88 lines)  - 
  bash version + OS gate that runs BEFORE any sourcing, plus soft python3/docker
  detection (WARN, never hard refuse). Must run even when python3 is absent.
- The sourcing chain that follows (`_common.sh` -> `portable.sh` waist ->
  `generators.sh`/`conf_lib.sh`/validators).
- The hub python-dispatch gate: cbox:6017-6040 (py_compile check, exit-97
  runtime-crash fallback to bash hub).

Everything after the floor may be python. The floor stays bash and stays at the
3.2 target from Track P, independent of this wave.

## 5. Feature deltas

### 5.1 `cbox` in every directory (ruling 1)

Two parts, together:

- Mandatory `cbox()` shell-rc function from the chooser (5.3) so the command
  resolves anywhere on the host shell.
- mode=none self-heal: `_cbox_effective_mode` returns `none` only on a truly
  fresh machine (no global cbox.conf AND no effdir) - recon confirmed that with
  an existing global conf, `cbox` already works everywhere. On mode=none, offer
  `cbox setup` instead of printing usage+exit 1. `run` already self-heals via
  `_first_run_init` (TTY only); this generalizes the offer.
- THREE death mechanisms must all route to the offer (correctness critique):
  (1) `die_no_conf` - 10 sites (cbox:580, 1372, 2039, 4790, 4976, 5174, 5955,
  5963, 5971, 5993); (2) bare `cbox` usage - bash `hub()` `*) usage` (cbox:5871)
  AND python `cbox_hub.py:296-299`; (3) `require_global_conf` (cbox:39-41, its
  OWN hardcoded "run ./setup.sh first" message) reached via `check_tpl_sha`
  (cbox:48) from ~13 call sites (cbox:555, 1597, 2013, 2750, 2784, 2822, 2837,
  2842, 2985, 3056, 3085, 3126, 5101). Proof this third path is real and
  separate: `up()` (cbox:2747) does NOT branch on `_cbox_effective_mode` at all
 - it calls `check_tpl_sha -> require_global_conf`, which dies at cbox:40 on a
  fresh machine, bypassing `die_no_conf` entirely. Without fixing path (3),
  `cbox up` on a fresh machine never gets the self-heal offer.
- Python hub touch point (do not skip): `cbox_hub.py:140` renders `mode: none`
  as a normal state with no offer today. The self-heal offer lands in BOTH the
  bash `die_no_conf`/`hub()` path and `cbox_hub.py` - the python side is an
  explicit edit, not covered by the bash change.

### 5.2 Q3 global conf-sha (small)

Global mode today stamps only `CBOX_TPL_SHA` (template drift), never the
content of the global `cbox.conf`. Isolated mode additionally writes
`manifest.sha256` with a conf-sha via `_cbox_manifest_write`
(generators.sh:389), called only from isolated paths. Q3 = also stamp a
conf-sha for global-mode writes, closing the asymmetry. Folds into the `cbox
setup`/`cbox config set` write path for global scope.

### 5.3 Command chooser + shell-rc (ruling 2)

`gen_bashrc` (generators.sh:2759) already emits shell FUNCTIONS (not PATH,
not aliases): `claude`/`codex`/`cbox-stop`/`cbox-shell`/`cbox` (+ `hermes` when
enabled), sourced from `~/.bashrc-cbox` via a marker block in `~/.bashrc`
(step_bashrc, setup.sh:1468). Delta:

- Per-command selection in the chooser (which of claude/codex/hermes wrappers
  to install); `cbox()` is always installed (mandatory).
- zsh support: emit a `~/.zshrc-cbox` + marker block in `~/.zshrc` as well. The
  emitted functions ARE zsh-compatible (correctness critique confirmed
  gen_bashrc:2759-2791 is pure POSIX function syntax, no bash-only construct).
  macOS default shell is zsh (mac experimental-but-compatible, ruling 08-06)  - 
  without this the mac install story dies at the chooser. SCOPE NOTE: this is
  not just one more output file - `merge_bashrc_block`/`bashrc_old_lines`/
  `bashrc_comment_old` (setup.sh:1014/1037/1048) are `.bashrc`-specific
  (marker-block + old-block detection), so zsh needs a parameterized version of
  all three helpers (target rc file as an argument), not a copy.
- Security (host-only + injection): the write stays host-only - `step_bashrc`
  is gated upstream by the container check (setup.sh:147, 3057, 3364) and the
  target is the container's own `$HOME`, not a mounted host rc (unchanged by
  adding `~/.zshrc`). `merge_bashrc_block` (setup.sh:1014) is injection-safe:
  literal `index()` marker matching, verbatim block from a fixed 2-line
  constant, no interpolation of user data. ONE residual to fix (MEDIUM, now
  doubled across two rc files): if `$HOME/.zshrc` already contains more than one
  `MARK_START`, the awk merge replaces the FIRST region and drops content up to
  the next `MARK_END` - a data-loss footgun. Fix: refuse to merge and warn when
  more than one `MARK_START` is present, for both bashrc and zshrc.

### 5.4 Q4 engine attribution row (small)

The bash hub already has a real `docker exec` ps scan (`_hub_running_marker`,
cbox:5254; `_hub_engines_line`, cbox:5335) that is cosmetic-only and never
feeds reap. The python hub's `Probe.running_engines()` (cbox_hub.py:95) is a
stub returning "unknown". Q4 = port the bash scan into the python core so the
attribution row ships in the python hub too. `_probe`'s aggregate count keeps
sole authority over reap/liveness (unchanged).

### 5.5 Q9 hard-block of foreign engine processes (ruling 5)

Today `_probe` (cbox:2143) + its heredoc `_CBOX_PROBE_SH` (cbox:2105-2141)
counts engine processes for a SOFT reap decision. Exclusions are exact argv[1]
string matches (`daemon|--bg-pty-host|--bg-spare` for claude, `mcp-server` for
codex). No hard-block flag exists in the repo today.

SECURITY FRAMING (security critique, binding): Q9 is an INTEGRITY / HYGIENE
feature, NOT a container-escape security boundary. The probe identifies engines
by data readable and writable at container trust level, so a deliberate evader
running at container trust can defeat it three ways (stamp rewrite, argv[1]
spoof, binary copy - see below). Q9 raises effort against ACCIDENTAL foreign
engines (the hub-attribution / reap-correctness case, its actual goal); it
provides no guarantee against code that already runs in the container. The doc
uses "block" in that narrower sense. Anyone reading "hard-block" as a trust
boundary is misreading it, and 5.5 states so.

Q9 design:

- Define what "block" DOES: a foreign process (an engine binary running in the
  container that is NOT one the hub/lifecycle started and NOT a known infra
  subprocess) causes the offending action to refuse - specifically, `cbox run`
  refuses to attach a second engine into a container whose process set contains
  an unrecognized engine binary, and the hub renders it as blocked. It does NOT
  kill processes and does NOT override `_probe`'s reap authority; reap stays
  count-based.
- Registry-generated probe: the `_CBOX_PROBE_SH` heredoc's hardcoded two
  stamp paths + inline exclusions are generated from `etc/engines/engines.json`
  (`probe.stamp` + `probe.infra_filter_argv1` per engine), closing the
  duplication between the registry and cbox:2105-2141 and giving hermes a
  stamp-path (today it relies on exe/argv match only, a false-negative class:
  container torn down under a live hermes when claude/codex exit  - 
  HUB_DESIGN.md:44-49).
- STAMP SOURCE OF TRUTH MOVES OUT OF CONTAINER-WRITABLE SPACE (security HIGH,
  fixes a pre-existing live bug; done as increment A0). Today the probe reads
  the expected exe path from `$HOST_HOME/.local/.cbox-stamp` line 2 INSIDE the
  container (cbox:2106); those stamp files are container-user-owned
  (install-bins.sh:165, mode 0644, chowned to HOST_UID at entrypoint.sh:30).
  Container-trust code rewrites line 2 to a bogus path -> every engine goes
  invisible -> `_probe` count hits 0 -> `_reap` runs `down --remove-orphans`
  (cbox:2170): a container-triggerable teardown of the sibling engine's
  container, independent of Q9. CORRECTION: the host CANNOT precompute the exe
  path - stamp line 2 is `readlink -f` of the binary (install-bins.sh
  _resolve_bin:38-40), a realpath resolved only in-container, version-specific;
  it is NOT `_link_for` (the symlink path), so an earlier draft's "host passes
  iso_want" was wrong (iso_want at cbox:4091 is the VERSION = stamp line 1, not
  the exe path). Actual fix: the host reads stamp line 2 via `docker exec` at a
  TRUSTED moment (right after install-bins on container start, before any engine
  attaches; and after `reinstall-bins`), caches it host-side in `$eff/probe-exes`
  (verified NOT mounted into the container - only specific `$eff` subdirs are),
  and `_probe` passes it in as `docker exec -e CBOX_PROBE_CP=... -e
  CBOX_PROBE_XP=...`; the heredoc reads the env instead of the stamp. Fail
  direction: a missing/empty cache makes the probe return "unknown" (which
  `_reap` already handles = leave the container up + gc retry), NEVER 0 - so the
  teardown primitive can no longer be container-triggered. Residual (documented,
  integrity-not-boundary consistent): a narrow TOCTOU window during install->read,
  and containers already up before the fix have no cache -> unknown -> stay up
  until down/up (noted in MANUAL).
- ENFORCE KNOB IS HOST-ONLY CONF, NOT AN ENV VAR (security HIGH). A plain
  `CBOX_ENGINE_ENFORCE` env var has the wrong trust property: it is read from
  the ambient environment of whoever invokes `cbox`, and `cbox` is reachable
  in-container via the mandatory shell function - so container-trust code sets
  it to `warn` and disables enforcement (the USER_EXTENSION CRITICAL-1 shape).
  Instead: a registry/conf key `engine_enforce` (default `block`), written only
  through the existing host-only `config set` path (cbox:4940, gated by
  `_cbox_config_in_container`). The enforce site reads the resolved conf value.
  Any env override, if kept for the CC-bump window, is dropped unconditionally
  in-container (`_cbox_config_in_container && enforce=block`) and the drop is
  logged.
- False-positive class + tripwire: exact argv[1] matching means any NEW shape
  of a CC/codex infra subprocess (a future `--bg-*` flag, a renamed daemon
  subcommand after a CC bump) falls outside the exclusion and, under
  hard-block, blocks the user's own infrastructure. Mitigation: (a) the
  exclusion set is registry data, updatable without a code edit; (b) the
  host-only `engine_enforce=warn` conf value downgrades to warn for the CC-bump
  window; (c) a tripwire test pinned to the expected CC/codex argv shapes that
  fails after a binary bump changes them.
- Fail-closed on unknown argv: an engine process with an argv shape not in the
  registry exclusion is treated as BLOCKING (foreign), not excluded - once
  `warn` is available as the release valve. This is the correct direction for
  the hygiene goal; the security critique's false-NEGATIVE concern (a foreign
  process spoofing `argv[1]=daemon` to be excluded) is why exclusion must be
  narrow, not broad.

### 5.6 Q7 tmux multiplex view (design now, impl a later increment)

"FUND NOW" = the design is part of this wave; implementation is a gated
increment. The substrate exists: `_multiplex_session_name` (entrypoint.sh:277,
`cbox-<engine>-<hex>`), `cbox-session-entry.py` (SESSION_RE, run_list, viewer/
full-attach tiers), session-broker cmd (cbox:1542), and a bash-hub `sessions`
submenu (cbox:5427, isolated only) as the natural home.

Sub-design (authored here; codex-sol co-design was blocked on a Codex usage
limit, and recon showed most blockers are already resolved by existing infra):

ARCHITECTURE - a per-container persistent tmux server on a PRIVATE socket:
- Server owner: a long-lived `env -u TMUX tmux -L cbox-mux` server, started
  lazily on the first `cbox run <engine>` in a container that opted into the
  multiplex mode (a new `CBOX_MULTIPLEX` conf key, default off = today's
  disposable-per-exec unchanged). The `-L cbox-mux` private socket is mandatory
  (session-suicide class: a plain tmux inherits `$TMUX` and would target the
  enclosing wrapped server).
- create/attach: `cbox run <engine>` becomes: ensure-server, then
  `new-window -t cbox-mux` running the engine (window name = engine), then
  `attach-session`. A second `cbox run <other>` from a second terminal adds a
  window and attaches - one server, many windows.
- detach/teardown: detaching leaves windows running (the point of persistence).
  Teardown when the last window exits: a tmux `set-hook` on `window-close`
  (or a small wrapper) checks remaining windows and, when zero, kills the
  server, which lets `_probe` count go to 0 and `_reap` tear the container down
  normally.

RESOLVING THE BLOCKERS (recon-grounded, not open):
- "multiple SessionStarts in one server" is ALREADY handled. `session_pane_map.py`
  runs on every SessionStart (per-engine), keyed on the per-pane `TMUX_PANE`
  env var (session_pane_map.py:84), and writes `PANES/<sid>.json` with that
  pane. `limit_watchdog.safeguard_pass`/`resume_pass` iterate ALL `PANES/*.json`
  and act per-pane independently (limit_watchdog.py:338-351). Windows in one
  server each get a distinct `TMUX_PANE`, so pane->engine->session mapping is
  correct today with zero change for claude. Gap: codex has only a SessionStart
  hook and hermes none, so their pane records may be absent - inc E wires the
  codex/hermes SessionStart equivalents to write the same pane record (or the
  multiplex view degrades to claude-only attribution for them, acceptable v1).
- "disposable-per-exec -> persistent" is a MODE switch, not a rewrite:
  `_multiplex_run` (entrypoint.sh:308) stays the default; the persistent path is
  a sibling function behind `CBOX_MULTIPLEX`. Autoresume watchdog is unaffected
 - it already keys on pane records, not on the session lifecycle.
- "long-lived flock-holder shape": the persistent server IS the long-lived
  process. `_probe` (cbox:2143) counts ENGINE processes, not the tmux server, so
  it does not miscount the server as an engine; reap fires when engine windows
  hit 0, which is exactly when the teardown hook kills the server. No new
  flock-holder is needed - the existing session.lock semantics hold, taken by
  the engine windows, not the server.
- SECOND INSTANCE OF THE SAME ENGINE (2x claude): DEFERRED with a named blocker
  (daemon.lock + history collision needs per-instance `CLAUDE_CONFIG_DIR`
  suffixing, HUB_DESIGN P4). v1 multiplex allows at most one window per engine;
  a second `cbox run claude` attaches to the existing claude window rather than
  spawning a second. This keeps the daemon.lock invariant intact.

LIGHTWEIGHT TESTS (no live tmux/server): stub `tmux` on PATH emitting canned
`list-windows`/`display-message` output (the safeguard-wave stub pattern);
assert the ensure-server / new-window / teardown-hook argv is well-formed and
uses `-L cbox-mux`, that a second engine adds a window rather than a server, and
that the teardown hook fires kill-server only at zero windows. Live attach/detach
is host-gated SKIP.

IMPL GATE: this is increment E, after A-D land. The one genuinely unverified
piece is the tmux `window-close` set-hook teardown timing under a real server
(host-gated); if it proves unreliable, the fallback is a wrapper that re-checks
window count on each engine exit. That fallback is bounded and does not block
the design.

## 6. Increment sequence (each leaves the rsync-published tree functional)

- A. Relocate setup body -> `lib/cbox-setup.sh`; add `cbox setup` verb;
  replace the 3 subprocess calls (cbox:1651/1652/2358) with in-process
  dispatch; repoint the 9 test suites. setup.sh becomes a thin forwarder.
- A. Relocate setup body -> `lib/cbox-setup.sh`; add `cbox setup` verb WITH the
  in-container gate (3.1); replace the 3 subprocess calls (cbox:1651/1652/2358)
  with in-process dispatch; repoint all 11 parsing test suites; add
  `lib/cbox-setup.sh` to file_inventory.json in the SAME increment. PLUS the
  security prerequisite: move the probe's expected-exe source out of
  container-writable stamp files (host passes exe paths into the probe;
  cbox:4091/4104 already computes them) - this fixes the pre-existing
  container-triggerable `down --remove-orphans` (5.5 HIGH #2a), independent of
  Q9, so it lands first.
- B. mode=none self-heal UX - ALL THREE death paths (die_no_conf 10 sites, bare
  `cbox` bash+python usage, require_global_conf/check_tpl_sha ~13 sites incl.
  `up`), offering `cbox setup`; the offer edit also lands in cbox_hub.py:140.
  Command chooser (per-command selection; parameterized bashrc helpers + zsh
  marker block; refuse-on-duplicate-MARK_START).
- C. Q3 (global conf-sha) + Q4 (port running scan into cbox_hub.py). Small,
  bundled.
- D. Q9 hard-block: registry-generated probe heredoc, hermes stamp-path,
  host-only `engine_enforce` CONF key (default block, NOT an env var; 5.5),
  fail-closed-on-unknown-argv, tripwire test.
- E. Q7 persistent-tmux multiplex impl (sub-design in 5.6; `CBOX_MULTIPLEX` conf
  default off).
- F. setup.sh deletion or thin-forwarder finalization + full docs/error-string
  sweep (2.3 inventory) + file_inventory.json entry removal in the SAME
  increment.

First increment already makes `./cbox setup` fully functional; setup.sh
removal is last, per the forwarder-vs-hard-cut verdict.

## 7. Constraints (invariants this wave must not break)

- cbox publishes via rsync of disk state -> every increment leaves a functional
  tree.
- user-extension chokepoints must not regress (render_mcp user-dir arg,
  CBOX_USER_DIR, marker blocks). No inc3-5 scope creep.
- Tests stay lightweight: no live tmux/docker/server; Q7 uses the stub-tmux
  pattern from the safeguard wave; live paths are host-gated SKIP.
- Security floor unchanged: guards mirrored to managed-settings stay;
  writing to shell-rc is a host-only setup operation (the container never edits
  the host `~/.bashrc`/`~/.zshrc`).

## 8. Owner decision (RESOLVED 2026-08-07 Marek): HARD CUT

setup.sh is deleted entirely (ruling 4 taken literally); the only path is
`./cbox setup`. Consequence for increment F: no forwarder is written; the full
docs + error-string sweep (2.3) and the file_inventory.json entry removal MUST
all land in the same increment as the deletion, because every `./setup.sh ...`
host instruction and doc reference breaks at once. During increments A-E,
setup.sh stays a thin forwarder to `cbox setup` (so the tree stays functional
between increments); F replaces the forwarder with deletion + the coordinated
sweep. This does not change increments A-E.

## 9. Review + verification plan

- Correctness critique (sonnet/high): DONE, folded into 2.3/3.1/5.1/5.3/6.
- Security critique (opus/high): DONE, folded into 3.1/5.3/5.5/6 (two HIGH:
  engine_enforce host-only conf, probe stamp source out of container-writable
  space).
- Q7 sub-design: authored in 5.6 (codex-sol was blocked on a Codex usage
  limit; recon closed most blockers so it did not need external depth).
- Per-increment (still to run at IMPL time): differential test run on the
  pre-change tree before ACCEPT (the "pre-existing" claim is never trusted
  without it); code-reviewer + (for A, D) security-reviewer on each increment's
  actual diff; impl agents run WITHOUT worktree, per-file split (worktree
  isolation breaks the uncommitted cbox wave).
