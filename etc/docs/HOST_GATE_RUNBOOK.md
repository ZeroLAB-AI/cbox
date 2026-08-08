# Host gate runbook

Every step here needs something the container does not have: a docker socket,
a controlling TTY, or a real network peer. None of it can be executed from
inside a cbox container. This is the ordered, single list a host operator
runs after a wave lands in git - collected from `.cbox/LEDGER.md`,
`TODO_FREEZE.txt`, `cbox/MANUAL.md`, and the commit bodies of the netaccess,
GPU, container-exec, and session-multiplex waves.

Order matters. Re-bless before recreate, recreate before live verification -
a re-bless alone never reaches an already-running container, because compose
freezes the container's environment at `create` time (see step 2).

## Mandatory vs optional

| # | Step | Mandatory before next wave | Optional / verification only |
|---|------|------|------|
| 1 | Re-bless templates (`cbox setup update`) | yes | |
| 2 | Recreate the container (`cbox down && cbox run`) | yes | |
| 3 | `update hooks` / `update agents` (only if changed) | yes, if touched | |
| 4 | netaccess: sockd runs foreground under supervisor | | yes |
| 5 | netaccess: alias resolves to the bound address | | yes |
| 6 | netaccess: grant reaches a fresh session | | yes |
| 7 | netaccess: SOCKS connect through a granted network | | yes |
| 8 | netaccess: negative control on a non-granted target | | yes |
| 9 | netaccess: orphan proxy-network sweep | | yes |
| 10 | netaccess: doctor reports truth when proxy is dead | | yes |
| 11 | One-off cleanup of pre-label orphan networks | yes, once per host | |
| 12 | tmux: `new-session` swallows child exit code (pre-fix) | | yes |
| 13 | tmux: read-only attach cannot type | | yes |
| 14 | tmux: attach flag list has read-only + ignore-size | | yes |
| 15 | tmux: server-access ACL support present | | yes |
| 16 | GPU: nvidia-ctk + CDI host prerequisites | yes, if GPU used | |
| 17 | GPU: rootless no-cgroups caveat | | unverifiable from here |

## 1. Re-bless templates

```bash
cd <cbox install dir>
cbox setup update
```

This is `run_rebless` (lib/cbox-setup.sh) - it does not require a TTY (only
`--config <file>` and bare `update` skip the TTY gate; `update <section>`
does not). It reloads `cbox.conf`, regenerates every artifact under
`generated/`, and stamps a new `CBOX_TPL_SHA`.

Expected output ends with:

```
templates re-blessed (CBOX_TPL_SHA updated) and artifacts regenerated
restart containers to pick the changes up: cbox down && cbox run <bin>; isolated projects re-bless interactively on their next cbox run
```

If it dies with `no <conf file>; run cbox setup first`, the host has no
installed config yet - this is a fresh-install path, not a re-bless; run the
interactive wizard instead. Any other non-zero exit means a template failed
to render; re-run with the section name from the error to see the wizard
step's own diagnostics.

Re-blessing alone is not live yet: it only updates the on-disk template
stamp and `generated/`. A running container keeps its old files and old
`Config.Env` until it is recreated (step 2).

## 2. Recreate the container

```bash
cbox down
cbox run <bin>       # claude | codex | hermes
```

or, for a plain restart without a fresh shell:

```bash
cbox down && cbox up
```

Why this step cannot be skipped: docker compose freezes a container's
`Config.Env` at `create` time. A re-bless changes `cbox.conf` and the
rendered compose file on disk, but an already-running container was created
from the *previous* render and does not see the change - this is exactly the
mechanism behind the netaccess "session predates the grant" failure mode
documented below (steps 6, 10) and the `--fallback-model` / opus-pin /
hermes-relay-agent changes from 07-31 (commits `5e1fcc6`, `7c4ec60`,
`3986e96`) staying dark until recreate.

Expected: `cbox down` reports the containers/networks it tore down (or
silently no-ops if nothing was running); `cbox run <bin>` starts a fresh
container and drops you into the engine. If `cbox run` instead prints a
netaccess/exec-bridge apply failure, see step 6 - a recreate does not by
itself fix a broken proxy, only a fresh session's ability to *see* one that
already works.

Isolated-mode projects re-bless themselves interactively on their next
`cbox run` inside that workspace - no separate step needed per project once
the shared template is re-blessed.

## 3. `update hooks` and `update agents` (when touched)

Only needed when the wave changed hook scripts, agent `.md` definitions, or
anything staged under `~/.claude/hooks` / `~/.claude/agents`. Both require a
real TTY (`require_tty`) - they cannot run inside this container even with a
docker socket, because they are interactive wizard steps that diff and ask
for confirmation before writing.

```bash
cbox setup update hooks
cbox setup update agents
```

Expected: a diff view per changed file, then a y/n confirmation, then
`staged N file(s)` (or similar) on accept. Declining leaves the host copy
untouched and the container mount stays on the old version - the container
mounts are read-only precisely so a compromised agent cannot rewrite them
(MANUAL.md, "hooks" / "agents" sections).

`cbox setup update bashrc` is a related, separate step: turning on hermes
does not retroactively add the `hermes()` shell alias to `~/.bashrc-cbox` -
a bare `cbox setup update` does not touch host files, only in-repo/generated
artifacts. Run `cbox setup update bashrc` once after enabling hermes.

## 4-10. netaccess live verification

Background: three commits (`9ce6688`, `481d217`, `740dcff`) fixed a
crash-looping SOCKS proxy, an alias that resolved to the wrong Docker
network, and orphaned networks; a fourth (`bd737b9`) hardened the apply path
after review; a fifth (`233bb4e`) closed the last day's regressions
(unclamped port in the listener-verify shell string, three exec paths still
falling back to frozen creation-time env, an unvalidated host string reaching
`bash -c` as root). All of it is 38-43/43 statically test-covered from
inside the container; none of it has been exercised against a real docker
daemon. This section is that missing exercise.

Placeholders below: `<proxy-container>` is the running proxy sidecar's name
or ID (`docker ps --filter label=cbox.component=proxy` or similar, or read
it from `cbox netaccess status`); `<granted-target>` is a Docker network,
container name, or `/8`-or-narrower CIDR you have granted; `<ungranted-target>`
is one you have deliberately not granted, on the same host, for the
negative control.

### 4. sockd runs foreground under supervisor, not daemonized

```bash
docker exec <proxy-container> ps -ef | grep sockd
```

Expected: exactly one `sockd` process, PID is a direct child of supervisord
(low PID, parent is supervisord's PID, not PID 1 and not orphaned). This is
the regression check for the `-D` bug fixed in `9ce6688`: dante's `-D` flag
daemonizes (forks and exits), which made the first mother process exit
clean while an unsupervised orphan kept serving - supervisord then saw
"exited status 0", respawned, hit `Address in use`, and crash-looped to
FATAL after 3 retries, while the orphan answered SOCKS connections the
whole time. If `ps -ef` shows two `sockd` processes or one with a PID that
does not trace back to supervisord, the `-D` regression is back.

```bash
ss -lntp | grep 1080
```

Expected: exactly one listener on `1080` (or your configured
`CBOX_NETACCESS_SOCKS_PORT`), owned by the `sockd` process from the previous
check. `ss` needs `docker exec <proxy-container> ss -lntp` if `ss` is not on
the host's own network namespace for that port (the proxy binds inside its
own container network namespace).

### 5. alias resolves to the address sockd actually binds

```bash
docker exec <proxy-container> getent ahostsv4 cbox-proxy-internal
```

Expected: one IPv4 address, and it matches the internal-network IP sockd
bound to in step 4 (cross-check with `docker network inspect
<internal-network-name>` for the proxy container's address on that
network). This is the regression check for `9ce6688`'s alias fix: before
it, the bare name `proxy` resolved on every attached network (both
`internal` and `egress`), and the embedded DNS resolver's tie-break by
network name (`_egress` sorts before `_internal`) could hand back the
egress-side address, which has no SOCKS listener at all. `cbox-proxy-
internal` is a network-scoped alias that exists solely on the internal
network, so it structurally cannot resolve to the wrong one - if this
check ever returns more than one address or an address with no listener,
that guarantee broke.

### 6. grant reaches a fresh session

```bash
cbox netaccess allow <granted-target>
```

Expected tail of output: `cbox: applied to the running proxy` followed by
either `cbox: the running cbox session can reach it now (no restart
needed)` or the honest negative - `cbox: NOTE - the running cbox container
predates this grant ... cbox down && cbox run`. Both are correct answers,
not failures; this is the `481d217` fix (previously the tool always claimed
success even when the running container was never on the internal network
and had no `CBOX_SOCKS_PROXY` in its frozen `Config.Env`).

Then, in a **new** session:

```bash
cbox run claude   # or codex/hermes; any bin
echo "$CBOX_SOCKS_PROXY"
```

Expected: a non-empty `socks5h://cbox-proxy-internal:1080` (or configured
port). If empty, check `cbox netaccess status` for `proxy: not running` or
`applied: <no state yet>` - either means the grant never reached a running
proxy and this is a config-only state, not a live-session bug.

### 7. real SOCKS connect through a granted network

Inside the new session from step 6:

```bash
curl -x "$CBOX_SOCKS_PROXY" http://<granted-target>/
```

Expected: a real HTTP response (or a connection-refused/timeout from the
*target* service itself, not from the proxy) - meaning the SOCKS hop
succeeded and dante forwarded the TCP connection. A `curl: (7) Failed to
connect` at this layer means the proxy itself rejected or could not reach
the hop; re-check steps 4-6 before assuming the target is just down.

### 8. negative control - non-granted target fails

Same session:

```bash
curl -x "$CBOX_SOCKS_PROXY" http://<ungranted-target>/
```

Expected: connection refused/denied by the proxy (dante is deny-by-default
outside the allowed subnets). If this succeeds, the scope is wider than
configured - stop and diff `cbox netaccess status` against what you granted
before trusting anything else in this section. This check only makes sense
paired with step 7; a lone failing curl proves nothing about scope, only
that something is reachable or not.

### 9. orphan network sweep

```bash
cbox netaccess allow <granted-target>     # from step 6, still applied
cbox setup update netaccess                # or: cbox config set CBOX_NETACCESS_MODE=off
cbox down
docker network ls --filter label=cbox.kind=proxy-net
```

Expected: after turning netaccess off and running `cbox down`, no
`cbox.kind=proxy-net`-labeled network with zero attached endpoints remains
(`_cbox_gc_orphan_proxy_networks`, `740dcff`). `cbox down` now also passes
`--remove-orphans` to compose. If a labeled network with 0 endpoints
survives `cbox down`, the sweep regressed.

### 10. doctor reports the truth when the proxy is dead

Kill or stop the proxy sidecar out from under a live session (e.g.
`docker stop <proxy-container>`), then inside that session:

```bash
cbox doctor
```

Expected netaccess row: `MISSING` with a message naming the probed
endpoint - `SOCKS endpoint was configured but unreachable at session start
... proxy is down or this session predates the grant; recover with cbox
down && cbox run`. Before `9ce6688` this reported the reassuring
`HOST-CHECK` line even with a dead proxy; `HOST-CHECK` is now reserved for
the case where netaccess policy legitimately requires host-side inspection,
not for "we could not tell". Bring the proxy back up
(`docker start <proxy-container>` or `cbox up`) before continuing to other
steps - a session started while the proxy was down never sees it recover
until it is itself recreated (`cbox down && cbox run`), by design (`481d217`
messaging).

## 11. One-off cleanup of pre-label orphan networks

The `cbox.kind=proxy-net` label (step 9) only tags networks created *after*
`740dcff` landed. Networks created by earlier cbox versions carry no label
and the automatic sweep in `cbox down`/`cbox gc` will never touch them.

Identify candidates:

```bash
docker network ls --filter driver=bridge --format '{{.ID}}\t{{.Name}}\t{{.Labels}}'
```

Manually cross-reference against `docker network inspect <name> --format
'{{len .Containers}}'` for zero-endpoint networks whose name matches this
host's cbox naming pattern (project-scoped `internal`/`egress` networks)
but whose label list does not include `cbox.kind=proxy-net`. There is no
exact filter for "pre-label orphan" - the label is exactly the thing they
are missing - so this step is a one-time manual audit, not a repeatable
command. Once found:

```bash
docker network rm <name>
```

Do this once per host after upgrading past `740dcff`; new leaks are covered
automatically from then on.

## 12-15. tmux checks

Background: the WG-router wave's `full-attach`/`viewer` design and the
already-landed session-multiplex fix (`62dd41a`) both depend on specific
tmux behaviors that were asserted from documentation, not exercised live.
These four checks close that gap. Run them on the host, not inside cbox
(tmux's own behavior is being tested, not cbox's wrapper around it).

### 12. exit code loss (confirms the underlying defect)

```bash
tmux new-session 'exit 7'; echo $?
```

Expected on a plain, unpatched `tmux new-session` invocation: **0**, not 7.
This is deliberately run against bare tmux, not through `cbox run` - it
confirms the general defect that motivated cbox's own status-file workaround
(`_multiplex_run` in `entrypoint.sh`, landed in `62dd41a`: the child's real
exit code is written to a status file and read back, specifically because
`tmux new-session`'s own exit status does not carry it). If this ever prints
7 on some future tmux version, the workaround becomes redundant but
harmless - it does not need to be run again after `62dd41a`, only before/
independently of it, to confirm the fix was solving a real problem and not
a phantom one.

### 13. read-only attach cannot type

Start a session, attach read-only from a second terminal, attempt to type:

```bash
tmux new-session -d -s ro-test
tmux attach-session -r -f read-only,ignore-size -t ro-test
```

From within that read-only attach, try:

```bash
cat > /tmp/x
hello
<Ctrl-D>
```

Expected: `/tmp/x` is empty (0 bytes) - keystrokes sent from a
`read-only`-flagged client are discarded server-side, not merely hidden
client-side. This is the security property the WG-router `viewer` tier
depends on entirely (`tmux server-access`/`attach -r` enforcement is
described as server-side in the ledger's alien-verdict ruling, but was
never confirmed against a live server before this runbook). Clean up with
`tmux kill-session -t ro-test`.

### 14. attach flag list includes read-only and ignore-size

```bash
tmux attach -f bogus
```

Expected: tmux rejects the unknown flag and prints the valid flag set in
its error, which must include `read-only` and `ignore-size` among the
recognized values. This confirms both flags the broker design depends on
(`viewer` = `attach -r -f read-only,ignore-size`) exist on the installed
tmux version, not just in upstream documentation.

### 15. server-access ACL support present

```bash
tmux server-access -l
```

Expected: a clean listing (possibly empty) rather than an "unknown command"
error - confirms `server-access` subcommand support (tmux >= 3.4 per the
design note in the ledger). This check is informational only: the current
design deliberately does NOT use `server-access` uid ACLs as the
enforcement point (everything in one container runs under one uid, so a
uid ACL enforces nothing) - it confirms the *feature exists* in case a
future design needs it, it does not validate today's `viewer`/`full-attach`
boundary, which lives entirely in the broker's own argv construction plus
the read-only flag from step 13.

## 16-17. GPU

### 16. host prerequisites (mandatory if GPU is used)

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

Expected: each command exits 0; the last one writes a CDI spec file at
`/etc/cdi/nvidia.yaml` listing at least one GPU device. Verify:

```bash
cbox config set CBOX_GPU=1
cbox up
docker exec <cbox-container> nvidia-smi -L
```

Expected: `nvidia-smi -L` inside the container lists the same GPU(s) as on
the host. `CBOX_GPU=1` alone is sufficient now (`3edc007`) - the CDI
reservation is rendered automatically into the compose file in both global
and isolated mode, and the legacy `--gpu` flag on `cbox up`/`cbox restart`
is a no-op when `CBOX_GPU=1`, or a loud failure naming the fix
(`cbox config set CBOX_GPU=1`) when `CBOX_GPU=0`.

For an eGPU specifically, after physically plugging in:

```bash
sudo ./bind_egpu.sh
```

Expected: regenerates the CDI spec, sets `CBOX_GPU=1` in the config, and
restarts the stack - it no longer passes `--gpu` itself, precisely so it
cannot hit the flag-vs-config mismatch this wave closed.

### 17. rootless no-cgroups caveat - unverifiable from here

Under rootless Docker, CDI typically also needs `no-cgroups = true` set in
the nvidia-container-runtime config file on the host. This is stated in
`cbox/MANUAL.md`'s gpu section as a host-side step cbox cannot verify, and
that remains true for this runbook too: there is no cbox-side check that
can confirm the nvidia-container-runtime config carries this setting, only
the downstream symptom (`nvidia-smi -L` failing inside the container despite
CDI generation succeeding on the host). If step 16's in-container
`nvidia-smi -L` fails on a rootless host after CDI generation succeeded,
check this setting by hand before suspecting cbox's own GPU wiring.

## What to do when a step fails

- **Re-bless (step 1) dies on missing conf**: this is a fresh-install host,
  not an update - run the interactive wizard, not `update`.
- **A `netaccess` grant never becomes visible in a live session (step 6)**:
  this is not a bug to chase - the fix already ships the honest message
  (`cbox down && cbox run`). Recreate; do not expect an already-running
  engine process to pick up a repaired proxy, its environment is fixed at
  exec (`481d217`).
- **A `deny` reports "DENY NOT ENFORCED" (step 8's precondition)**: the
  config was written but the running proxy still serves the old, wider
  rules. Re-run `cbox down` to force a clean restart, or re-issue the
  command once docker is healthy, per the tool's own on-screen guidance.
- **Locked out by a dead SOCKS listener (escape hatch)**: the entrypoint
  guard (`_guard_socks_proxy`) already protects against this automatically
  - if `CBOX_SOCKS_PROXY` points at an unreachable host:port, the guard
  drops the proxy variables at session start and the agent falls back to
  direct egress rather than hanging or failing every network call. You are
  not locked out of the container itself in this failure mode; you lose
  only the SOCKS-reachable target networks for that session, and `cbox
  doctor` inside it will show `netaccess: MISSING` (step 10) explaining
  why. If you additionally cannot reach the container at all (proxy
  container itself will not start, `cbox up` hangs), stop the whole stack
  and bring it up without netaccess: `cbox config set
  CBOX_NETACCESS_MODE=off`, `cbox down && cbox up`, diagnose the proxy
  sidecar separately (`docker logs <proxy-container>`).
- **`tmux server-access -l` errors "unknown command" (step 15)**: the host
  tmux is older than 3.4. This does not block the `viewer`/`full-attach`
  design (it does not depend on `server-access`), but note the version gap
  before relying on any future feature that does.
- **GPU: `nvidia-smi -L` fails in-container after CDI generation (step 16)**:
  check Docker was actually restarted after `nvidia-ctk runtime configure`
  (a stale daemon does not pick up the new runtime registration), then check
  the rootless `no-cgroups` setting (step 17) by hand.

## What this runbook does not cover

- The WG-router session broker (list/attach/spawn over a WireGuard tunnel)
  is mid-flight and partially uncommitted as of this writing - the broker is
  being relocated from a host-side daemon into the cbox container per
  Marek's 07-31 architectural ruling, and the old `session_broker.py` /
  `cbox-session-remote` files are being deleted, not adapted. There is
  nothing stable to write a host gate for yet; add one when that design
  lands.
- `cbox verify`'s live SOCKS gate (an end-to-end SOCKS connect performed by
  the verify command itself, not by hand) does not exist yet - steps 7-8
  above are the manual substitute until it is built (tracked in
  `TODO_FREEZE.txt` #19c).
- IP-moved re-render (sockd re-rendering when docker reassigns the internal
  network a different IP mid-restart) is not implemented; only a post-restart
  listener-answer check exists (`TODO_FREEZE.txt` #19b). Not something this
  runbook can verify since it requires provoking that specific docker
  behavior, not just observing current state.
