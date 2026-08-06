# cbox multiplatform support - decision record

Status: decided. This design went through an adversarial review; section 7 records
what the review changed and what it failed to change. Every line-number cite and
count in this document was verified against source at revision time; the flock
semantics at the center of the dispute were verified by direct reproduction.

## 1. The recommendation

cbox targets Linux and macOS on stock system tools - docker plus the python3 that
is already load-bearing today - with no brew bash, no GNU coreutils requirement,
and no new user-facing dependency. Two tracks run in parallel. Track P makes the
existing bash host layer portable: one waist (`lib/portable.sh` backed by
`lib/cbox_host.py`) absorbs every platform-divergent primitive, and the registry
generator is retargeted to emit bash-3.2-clean accessors, after which nothing
bash-4 remains in the host layer and stock mac bash 3.2 becomes a gate-enforced
target. Track H builds the hub in Python immediately and independently - the hub
host side has no tmux and no bash legacy, so it is portable by construction and
does not wait for track P. The Python host core the hub starts then absorbs the
remaining bash dispatch targets one command at a time. Container internals are
not touched; they are Linux forever by design. Native Windows is dropped; WSL2 is
the documented Windows path.

The present state: macOS is EXPERIMENTAL and out-of-the-box runnable.
`templates/sections.sh` once declared associative arrays at line 3 (`declare -g
-A`, bash 4.2+); track P has retargeted it to bash-3.2 `sec_get`/`sec_has`/`sec_keys`
accessors, the bash floor is now 3.2, and tracks P1-P3 landed the waist shims plus
the darwin branches for process-liveness, peer-credentials and stat. The pre-flight
no longer refuses Darwin - it prints a clear EXPERIMENTAL warning and continues, so
a mac user gets a running cbox on best-effort footing. What is NOT claimed: the
darwin-specific code (ps lstart parsing, LOCAL_PEERCRED/xucred layout, BSD flock
contention) has not been verified on real macOS hardware, so failures are expected
and should be reported. The "macOS supported" claim - a stronger promise than
"runs" - still ships only when the claim gate passes: macOS CI green and one human
end-to-end run on Docker Desktop and OrbStack. Owner ruling (2026-08-06): mac is an
experimental target, not a supported one; it should work out of the box but is not
release-grade.

The alternatives, said out loud. Option A - require brew bash 5 plus GNU
coreutils on mac - is real and cheapest on day 1, and it was rejected for three
reasons: it does not finish the job (no brew package supplies /proc liveness,
SO_PEERCRED, mount checks, runtime-dir semantics; those need Python branches
regardless, so code changes ship either way); gnubin PATH ordering is a silent
per-invocation-context failure mode (sshd-launched, GUI terminal, cron); and it
invests further in the wrong asset the day before the hub - the largest new
component - gets written. Option B - full Python rewrite of the host layer - is
the right destination and a forbidden vehicle: a big bang on a daily-use tool.
The chosen shape is the smallest design that fully solves the problem, because
three facts make it cheap: python3 is already unavoidable on the host (39 call
sites in `cbox` alone; the MCP render path in `_common.sh:58` shells into it with
no guard), the registry source of truth is already Python/JSON
(`etc/registry/settings.json` + `settings_registry.py`; `sections.sh` is a
generated artifact of the 96-line `gen_sections_sh.py`), and every hard
GNU/Linux primitive in the census has a Python-stdlib equivalent (`fcntl.flock`,
`os.path.realpath`, `os.path.ismount`, `hashlib`, subprocess timeouts).

## 2. The Windows verdict

The owner's rule decides: if native Windows forces compromises on Linux/mac
quality, it is dropped, and that is a legitimate answer. Every native-Windows
path forces one:

- CPython on Windows does not support AF_UNIX sockets. The exec bridge and the
  clipboard bridge are unix-socket architectures with peer-credential
  authentication; Windows means named pipes plus a different security model - a
  parallel, security-sensitive IPC implementation whose abstraction seam would
  infect the Linux/mac code.
- No fcntl/flock and no inherited-fd lock pattern. `msvcrt.locking` is mandatory
  byte-range locking with different semantics; the concurrency backbone forks.
- No /proc and a different process and signal model; PID-reuse-proof liveness
  forks.
- POSIX permissions and uids are meaningless on NTFS; the 0600 key-material
  checks and `stat %u` ownership guards lose their meaning.
- Drive letters and backslashes through compose bind-mount generation and
  HOME/XDG derivation.
- Decisive collision with the session ruling: the conduct core is tmux-managed
  sessions, and tmux does not exist natively on Windows. A native port means a
  parallel ConPTY session manager - a fork of the central design, not an adapter.
- Docker Desktop on Windows runs on WSL2 anyway, and Docker's own guidance is to
  keep project files inside WSL ext4 because NTFS-crossing binds are slow and
  inotify-lossy. WSL is the good path even by Docker's rules.

Verdict: native Windows is dropped. Windows users run cbox inside WSL2,
documented, at zero code cost, because WSL2 is Linux. The adversarial review
asked to keep native Windows open at an estimate of roughly 1.5k LOC and four
weeks; refused. That estimate prices a parallel named-pipe security model plus a
replacement for the tmux session core as if they were adapters; they are a
rewrite of the two most security- and correctness-sensitive components. The
decision is recorded with its revisit condition instead: native Windows returns
only as an explicit owner decision, priced as a rewrite, never as drift.

## 3. The architecture

### The portable waist

`lib/portable.sh` holds thin bash entry points; `lib/cbox_host.py` holds the
implementation. One implementation on all platforms - no native-first branching,
because one behavior to test beats two, and PATH-context divergence is exactly
why option A lost. Verified inventory:

- `_cbox_sha256`: 34 grep hits across production host files (56 including
  tests), including project-slug hashing (`_common.sh:27,51`), template blessing
  (`check_tpl_sha`, `cbox:41`), and the context manifest
  (`templates/generators.sh:2640`). macOS ships `shasum`, not `sha256sum`; the
  waist uses hashlib so neither binary matters.
- `_cbox_flock`: 35 production sites (32 in `cbox`, 2 in `lib/cbox-session.sh`,
  1 in `templates/generators.sh:2181`), all fd-style. Implementation: python
  `fcntl.flock` on the bash-inherited fd; -x/-s/-n map directly, `-w N` is a
  LOCK_NB poll loop; exit codes mirror flock(1). Semantics: flock(2) locks
  attach to the open file description and release only when all duplicated fds
  close. A child that acquires and exits therefore leaves the lock held by the
  parent shell's fd - which is exactly how util-linux flock(1) in fd form works
  today: it is itself an acquire-and-exit child process. This was verified
  empirically on Linux during this design: the lock placed by an exited python
  child persists on the bash fd, blocks util-linux and python contenders in both
  directions, and releases on fd close. Darwin uses the same BSD lock model
  (flock originated in 4.2BSD; locks are references on the file, dup/fork
  produce references to a single lock); Darwin observation remains a hardware
  gate item. Note `generators.sh:2181` today degrades silently when flock is
  missing; the waist makes locking unconditional again.
- `_cbox_realpath_m`: 22 sites (GNU `-m` semantics = `os.path.realpath` non-
  strict). [Corrected during P1 implementation: a direct recount found 25
  line-hits of which only 5 are `-m`; the other 20 invocations are bare
  `realpath`, whose all-but-last-must-exist semantics were implemented as a
  separate form - see MANUAL.md, Track P1.]
- `_cbox_timeout`: 3 real host sites (`generators.sh:105,466,469`); the other
  census hits (`cbox:3199,3923`) execute in-container and stay.
- `_cbox_runtime_dir`: 6 sites; darwin derives from TMPDIR.
- `_cbox_stat_uid` / `_cbox_stat_mtime`: 3 sites including the shared-ollama
  ownership refusal at `cbox:693`.
- `_cbox_ismount`: 1 site.
- One-liners: portable in-place sed (`setup.sh:104` pattern), `mapfile` removal
  (11 sites: 9 in `lib/cbox-ai.sh`, 2 in `setup.sh`), `${u^}` (`setup.sh:2213`),
  `xargs -r` (`cbox:2578`).

Latency, measured on the dev host: `python3 -c pass` averages ~11ms against ~1ms
for spawning the flock binary - a ~10ms delta per waist call, not the 30-80ms
the draft guessed. Each waist category commit carries a microbenchmark and a
budget before landing, not after; the one structural rule is that no lock
operation sits inside a per-item GC loop - such loops batch into a single python
invocation if the measurement demands it.

### The registry

The source of truth is and remains `etc/registry/settings.json` +
`settings_registry.py`; `templates/sections.sh` is a generated artifact.
`gen_sections_sh.py` is retargeted to emit three bash-3.2 accessors:

    sec_get  <array> <id>    value or empty
    sec_has  <array> <id>    presence, distinct from empty
    sec_keys <array>         key enumeration

Three, not one, because the source demands three: `cbox:3795` distinguishes
present-but-empty from absent (`${SEC_DOCTOR_ROWS[$s]+set}`), `cbox:3802`
enumerates keys (`${!SEC_DEPS[@]}`), and `cbox:3803` nests lookups (composable
through `sec_get`, but only with `sec_has`/`sec_keys` alongside). The review is
credited with this correction; a scalar-only accessor was wrong. Read sites: 34
production (23 in `cbox`, 11 in `setup.sh`) plus about 68 across test files.
Parity gate: old artifact versus new artifact generated from the same
`settings.json`, all three operations, every id and key - extending the existing
`lib/test_conf_writer_parity.sh` pattern, which already keeps a pre-registry
snapshot fixture for exactly this kind of proof.

### The hub

Python, host side, no tmux. tmux lives in the container: `entrypoint.sh:263,324`
run it, and `generators.sh:682` pins the sshd ForceCommand to the in-container
`/opt/cbox/cbox-session-entry.py`. The hub host half needs a session table,
engine adapters per `etc/engines/engines.json`, JSON, and the unix socket to the
exec bridge - a Python job description. Writing it in bash-on-brew would answer
the portability question wrongly at the exact moment it becomes expensive.

Conduct delivery: one source (`etc/hooks/conduct-kernel.txt`), one thin adapter
per engine (claude SessionStart hook, codex AGENTS render, hermes = the new
adapter closing the verified parity hole), equality proven by the per-channel
sha256 digests in `context-manifest.json` (`generators.sh:2638` onward), checked
at session attach and surfaced as a doctor row - warn and continue, matching the
degradation style at `entrypoint.sh:560,609`. Stated ceiling: digest parity
proves the same content was delivered, not the same behavior - channel semantics
still differ per engine (hook timing versus static render), and no mechanism in
this design pretends otherwise.

The hub is not a single point of failure by construction: `cbox run <engine>`
remains the direct path; hub down means today's behavior; an unattachable
multiplexed session degrades to `cbox shell` plus manual attach while the engine
keeps running.

### The boundary

Portable host layer: `cbox` dispatch (case at `cbox:318`), `setup.sh` wizard,
doctor, config read/write/validate, compose and dockerfile generation, session
lease host side, host bridges (`etc/clipboard/clip_bridge.py`,
`etc/container/docker_exec_bridge.py`, `lib/cbox_session_bridge.py` invocation),
locking, hashing, path canonicalization, runtime dir, context manifest, hub.

Never portable - Linux forever, not to be touched for portability:
`entrypoint.sh`, `install-bins.sh`, Dockerfile, `etc/hooks/*`, in-container MCP
servers, `cbox-session-entry.py`, wg sidecar scripts, tmux,
gosu/socat/supervisord/iproute2, and the /proc probes executed via docker exec.
Entrypoint bashisms stay; it always runs on ubuntu 24.04. The rootless detector
(`entrypoint.sh:7-10`) is container-side and behaves correctly under Docker
Desktop: a rootful engine - including the Desktop VM's - shows a uid_map of
`0 0 4294967295`, and the awk requires 0 mapped to HOST_UID, so Desktop reads
not-rootless, which is true of the VM engine. Its downstream chown behavior on
virtiofs binds is a hardware-gate observation, not a code change.

Feature-gated on darwin, not ported: GPU/CDI (the config decides, the generator
omits the reservation, doctor reports not-available - the established pattern);
the host `ip route show` netaccess advisory (`cbox:4204`, skip with note);
`systemctl is-active ollama` (already guarded); shared-ollama ownership. On the
last: `cbox:693` is a host-versus-host check (stat of the host directory against
the host `id -u`) and stays as-is once stat goes through the waist. The
Linux-rooted assumption is `generators.sh:2856` emitting
`user: "$(id -u):$(id -g)"` into compose - under Docker Desktop and OrbStack
that numeric uid crosses a VM file-sharing layer, so darwin replaces trust in
numeric equality with a functional write-probe (container-side create and delete
inside the bind) while Linux keeps the exact numeric check.

The boundary is machine-enforced from step 0 by a host/container file inventory
that the lint reads, so which side a file lives on stops being tribal knowledge.

### The pre-flight

`cbox` and `setup.sh` gain a stock-bash-safe preamble that runs before
`sections.sh` is sourced: it checks the bash floor (3.2, dropped from 4.2 once
track P retargeted the registry), checks python3 and docker presence, and on macOS
prints one clear EXPERIMENTAL warning and continues (rather than refusing). python3
becomes an explicit checked dependency rather than a de facto one. On a virgin
mac, `python3` is the Command Line Tools stub that pops an install dialog; the
pre-flight names that instead of hanging.

## 4. The migration sequence

Two tracks after a shared step 0. Every commit leaves the Linux tool working;
commits land in the parent repo per existing publish practice.

Step 0 - gates only, zero behavior change. (a) GNU/bashism denylist lint over
host files, allowlisting only the waist: `declare -A`, `mapfile`, `${var^}`,
`stat -c`, GNU `sed -i`, `sha256sum`, `xargs -r`, raw `timeout`, raw `realpath`,
raw `flock`, `mountpoint`, `/proc/`, raw `XDG_RUNTIME_DIR`, `ip route`. (b) The
bash-3.2 parse gate: `bash -n` for every host script under the official
`bash:3.2` docker image - runs in Linux CI today. (c) The host/container file
inventory. (d) The pre-flight. Value from day one: the platform census itself
missed `sha256sum`, `xargs -r` and host `ip route` - the drift class is real,
and the lint ends it the day it lands.

Track P - portability:

- P1: the waist, one primitive category per commit. Each category is gated by
  oracle tests on Linux (python path against the GNU tool side by side; for
  flock, a contention matrix against util-linux in both directions - already
  reproduced once during this design) and by the latency microbenchmark for the
  lock category. Linux behavior is identical after each commit.
- P2: the registry generator retarget plus conversion of 34 production and ~68
  test read sites, parity-gated across all three accessor operations. This is
  the highest-friction revert in the plan - the largest mechanical surface - but
  not the point of no return: both artifacts derive from the same
  `settings.json`, the old generator remains in git history, and the parity
  fixture pattern already exists; revert means reverting commits and
  regenerating. After P2 the host layer contains nothing bash-4; the floor drops
  to 3.2 and the parse gate enforces it.
- P3: darwin branches in host python: LOCAL_PEERCRED beside SO_PEERCRED in
  `docker_exec_bridge.py` (getsockopt SOL_LOCAL with struct xucred, about ten
  lines), process start-time liveness via `ps -p PID -o lstart=` beside
  /proc stat field 22, the TMPDIR runtime dir, and the feature gates from
  section 3. After P3, `cbox setup && cbox run claude` on a mac is credible end
  to end, pending the hardware gate.

Track H - the hub, starting right after step 0, independent of track P:

- H1: hub core in Python behind the existing dispatch case; the direct run path
  is untouched.
- H2: the hermes conduct adapter, registered in `context-manifest.json` with its
  own digest and a parity row in doctor. Closes the known conduct parity hole
  with a provable digest instead of an assertion.

Step 5 - absorption, after P2 and H1: dispatch targets migrate into the Python
core one command at a time. Doctor first (read-only, densest remaining
GNU-isms); the conf writer second, which retires the conf_save-versus-whitelist
dual-writer divergence by construction, since a single generated writer was
already the agreed direction.

Point of no return: the dispatcher inversion that opens step 5 - the moment
`cbox` becomes a Python entry that calls remaining bash instead of bash
dispatching to Python. Before it, every step is a per-commit revert. After it,
absorbed commands own process state (traps, fds, signals, in-process registry)
in Python, and reverting one means writing it back into bash. The review argued
the point of no return is really P2; that is rejected in section 7, but its
kernel is kept above as the highest-friction-revert label.

Release gating - gates, not dates: step 0 ships in the next minor with no
behavior change. Through P1-P3 macOS is EXPERIMENTAL (pre-flight warns and
continues), out-of-the-box runnable but not release-grade. The stronger "macOS
supported" claim is its own release, cut only after the section 5 hardware gate
passes; no release in between advertises mac as supported. Calendar estimates are
deliberately absent because none would be evidence.

## 5. What is verified where

Static from Linux CI, available today: the bash-3.2 parse gate; the denylist
lint; shellcheck; registry parity (the `test_conf_writer_parity.sh` fixture
pattern extended to the three-operation accessor gate); waist oracle tests with
the GNU tools as counterparty; `py_compile` under a 3.9 floor matrix (stock mac
Command Line Tools ship python 3.9.6; host python is 3.9-clean today and the
gate keeps it so). The suite is the 48 files under `lib/test_*`; new gates land
as members of it. Their git tracking inside the cbox artifact repo lags today -
a property of the rsync publish model, not of the suite - and the gates are only
real once wired into CI, which is part of step 0.

Verified empirically during this design, on Linux: the inherited-fd flock
pattern. A python child acquired LOCK_EX on the bash-opened fd 9 and exited; an
independent `flock -n` then blocked (lock persisted, held by the shell's fd); a
python contender blocked against a util-linux-held lock and vice versa; closing
the fd released it. This was the review's central objection, and it is
contradicted by observation.

macOS CI (hosted runner: real BSD userland, stock bash 3.2, no docker): the
non-TTY wizard and doctor paths executed on bash 3.2; darwin flock contention
including `-w` timeout behavior; a LOCAL_PEERCRED unit test; `ps lstart`
liveness under pid churn; waist oracle tests against the BSD userland.

The irreducible human mac session, once per release that claims mac - hosted mac
runners have no nested virtualization, so docker E2E cannot be mechanized:
`cbox setup && cbox run claude && cbox doctor` on Docker Desktop AND OrbStack;
shared-ollama bind ownership behavior under the numeric-uid compose user line
(`generators.sh:2856`); mtime/inotify coherence for the session watchdog under
virtiofs; the rootless-detector outcome and chown behavior in the Desktop VM;
and the live-TTY wizard with real arrow keys, which is TTY-gated and
unverifiable from any CI beyond the script-based PTY harness. Nothing in this
design is done for mac until this session has happened once.

## 6. The risks accepted

1. Darwin flock is argued from the BSD lock model and proven on Linux, not yet
   observed on Darwin; a defect here corrupts the concurrency backbone. Gated by
   the macOS CI contention tests before any mac claim.
2. Waist latency: ~10ms measured delta per call on the dev host. Budgeted per
   category before landing; co-process batching is the prepared fallback for hot
   loops, and no lock op may sit inside a per-item GC loop.
3. Docker Desktop and OrbStack file-sharing semantics (uid mapping, mtime
   coherence, chown on virtiofs) can pass every CI and still misbehave live;
   accepted until the human E2E, which exists for exactly this.
4. The 3.2 parse gate misses runtime-only bashisms and the denylist is
   enumerative; mitigated by macOS CI actually executing the non-TTY paths on
   real bash 3.2.
5. Boundary erosion during the dual-language window; the lint is permanent
   infrastructure until step 5 completes, not scaffolding.
6. Hub as a failure point is bounded, not eliminated: multiplexed attach depends
   on hub and exec-bridge health; the degradation paths (direct run, shell
   attach) are design-level requirements.
7. Conduct parity ceiling: digest-equal content with channel-divergent delivery
   semantics; hermes is the weakest channel until H2 lands, and possibly after.
8. APFS case-insensitivity can collide two case-differing workspace paths onto
   one config directory via slug hashing (`_common.sh:27`). Freak case; doctor
   warning at most.
9. Virgin-mac python3 is the Command Line Tools stub; the pre-flight names it
   but cannot remove it.
10. Native Windows is foreclosed short of a rewrite by the AF_UNIX, flock,
    liveness and tmux choices - priced deliberately under the owner's rule.
11. The dual-language window itself: two languages in one host layer until step
    5 completes, policed by lint and parity gates. It is priced, not forgotten -
    it buys revert-in-commits instead of a big bang.

## 7. What the adversarial review changed, and what it failed to change

The review returned REJECT with an accept-with-changes appendix. Every point was
adjudicated against source; the disagreement is preserved here rather than
smoothed into consensus.

Changed by the review:

- The registry accessor API. Its strongest correct point, verified at
  `cbox:3795` (presence check via `+set`), `cbox:3802` (key enumeration via
  `${!SEC_DEPS[@]}`), `cbox:3803` (nested lookup). A scalar-only accessor was
  wrong; the design now specifies `sec_get`/`sec_has`/`sec_keys` with a
  three-operation parity gate.
- The pre-flight UX. Accepted wholesale: the window now fails politely on mac,
  and python3 becomes an explicit checked dependency instead of a de facto one.
- The track split. The review's reorder is accepted in shape: the hub is
  Python-native and never needed to wait for portability, so the hub track now
  runs parallel to the portability track. Its reasoning for the reorder (that
  the flock step would break the tool) was wrong, but the reordering itself
  improves the plan.
- Release gating. Accepted as gates bound to releases and an explicit
  no-mac-claim rule mid-window; refused as calendar dates, which would be
  invented numbers.
- The Docker Desktop ownership concern, in its kernel. The design now names the
  darwin write-probe replacing numeric-uid trust for the compose `user:` line
  and lists Desktop/OrbStack ownership behavior in the hardware gate.
- Count corrections triggered by the recount: production flock sites are 35
  (draft said 39, review said 33); production registry reads are 34 (23 + 11);
  mountpoint is 1 site, not 2; realpath is 22.

Refuted, with the evidence:

- "Python flock releases when the subprocess exits; the shims ship broken
  serialization" - the review's core objection and the basis of its verdict.
  Contradicted twice. By the contract: flock(2) locks attach to the open file
  description and release only when all duplicated fds close; the bash parent's
  fd survives the child, so the lock survives the child. And by reproduction on
  this machine: the lock placed by an exited python child persisted on the bash
  fd, blocked util-linux and python contenders in both directions, and released
  on fd close. util-linux flock(1) in fd form is itself an acquire-and-exit
  child process - if the review's model were true, cbox's existing bash locking
  would already be broken. The review's recommendation A1 (keep locks in bash,
  split the lock domains between languages) falls with it; the fd-inheritance
  pattern is the design precisely because it lets bash and python hold the same
  locks during the window.
- "macOS is not viable under this design." The evidence cited (sections.sh line
  3, sha256sum, flock, realpath -m, stat -c, sed -i) describes the
  pre-migration present - it is this design's own census and the reason the
  tracks exist. The design claims mac only at the post-P3 gate and never claims
  stock-bash viability mid-window. The one actionable kernel - fail politely
  meanwhile - is accepted as the pre-flight.
- "The Windows decision should have been left open, at roughly 1.5k LOC and
  four weeks." The owner's rule decides the question when compromises are
  forced, and every enumerated item forces one. The estimate prices a parallel
  named-pipe security model plus a ConPTY replacement for the tmux conduct core
  as adapters; they are a rewrite of the central design. The decision is
  recorded with an explicit revisit condition instead of a false price tag.
- "The real point of no return is the registry retarget - the source of truth
  moves from Python to Bash." Backwards on the facts: the source of truth is
  Python today (`settings.json` plus generator; `sections.sh` is a generated
  artifact with a parity snapshot fixture) and remains Python; only the emitted
  dialect changes. P2 is the highest-friction revert and is now labelled so,
  but it is a git revert plus regeneration, not a one-way door. The point of no
  return stays at the dispatcher inversion, where process-state ownership
  changes languages.
- "Docker Desktop does not present host paths in the container", and the
  reading of `cbox:693` as a container-side uid comparison. Same-path bind
  mounts are the standard Desktop mechanism - the host path appears at the
  identical absolute path in the container via the file-sharing layer; the real
  divergences (ownership mapping, coherence) were already the hardware-gate
  items. And `cbox:693` compares the host directory's owner to the invoking
  host user - host versus host, no container in the chain; it needs only the
  stat waist.
- "Rootless detection is unreliable; the 0-to-HOST_UID row exists in Docker
  Desktop VMs." The detector at `entrypoint.sh:7-10` requires uid 0 mapped to
  HOST_UID; a rootful engine - including the Desktop VM's - maps 0 to 0, so
  Desktop correctly reads not-rootless. Container-side, out of portability
  scope; its chown consequences under virtiofs are in the hardware gate.
- "Zero committed tests in the project." 48 test files exist under `lib/` and
  run, the parity fixture pattern among them; their git tracking inside the
  artifact repo lags for known publish-model reasons. The accepted kernel:
  gates count only once wired into CI, which step 0 does.
- "The dual-language window is a permanent branch-forever risk." There is no
  branch: one codebase narrows its dialect under a lint, and after P2 nothing
  bash-4 remains to need a bash-4-only fix. The window's real cost is boundary
  erosion - named as risk 5 and policed by the permanent lint.

Net: the review sharpened the accessor API, the failure UX, the sequencing and
four counts. Its central technical objection did not survive contact with the
lock contract or the reproduction, and the verdict built on that objection does
not stand. The direction - portable waist, Python core grown from the hub,
registry retarget, container internals untouched, Windows via WSL2 - stands as
drafted.

## ADR

- Context: the cbox host layer is bash-4.2+/GNU/Linux-bound (generated
  assoc-array registry, fd-style flock, GNU coreutils, /proc, SO_PEERCRED);
  macOS ships bash 3.2 forever; python3 is already load-bearing on the host;
  the owner ruled that the tmux hub is the conduct core and that Linux/mac
  quality is never traded for Windows reach.
- Decision: a portable waist (`lib/portable.sh` + `lib/cbox_host.py`) with the
  remaining bash held to a 3.2 floor by permanent gates; the registry generator
  retargeted to emit get/has/keys accessors; the hub built in Python
  immediately on a parallel track and made the first resident of a host core
  that absorbs commands incrementally after the dispatcher inversion (the point
  of no return); container internals untouched; GPU/CDI and kin feature-gated
  on darwin; native Windows dropped with WSL2 as the documented path.
- Consequences: mac support lands without new user-facing dependencies (docker
  plus python3), claimed only after macOS CI plus one human E2E on Docker
  Desktop and OrbStack; one conduct source with digest-proven per-engine
  adapters including a new hermes one; a lint-policed dual-language window with
  roughly 90 mechanical call-site edits plus a 100-site registry conversion
  before any mac claim; ~10ms added per waist call, budgeted; native Windows
  forever a rewrite, never a port.
