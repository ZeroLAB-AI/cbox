# F7 Remote Control - Design Document

Status: DESIGN ONLY. No code, no compose entries, no ports, no keys exist yet.
This document is a proposal for owner review. Every default below is marked
PROPOSAL and is a starting point for discussion, not a decision.

## 1. Problem statement

Today a cbox session is driven from a local terminal only. F7 is the ability
to reach a running cbox project - to see its state and to push input into it
- from a phone or another machine over the owner's own network, without
depending on a third-party relay (Tailscale, ngrok, cloud VPN providers) and
without exposing the host to the internet.

Remote control of an autonomous AI orchestrator is remote execute. The design
below treats it that way throughout: every capability added is weighed
against the blast radius of a stolen credential or a compromised endpoint,
and the default posture is off.

## 2. Component diagram

```
   mobile (Termius, SSH+WireGuard client)
          |
          | WireGuard tunnel (UDP, owner LAN or via port-forward)
          v
   +-------------------------+
   |   VPN container          |   PROPOSAL: sidecar pattern, same shape
   |   (wireguard + sshd)     |   as the existing egress proxy sidecar
   |                          |
   |  - peer registry         |
   |  - discovery CLI         |
   |  - SSH gate + 2FA gate   |
   +------------+-------------+
                |
                | plain LAN/bridge traffic to each project's listener
                | (NOT docker socket, NOT docker exec)
                v
   +-------------------------+      +-------------------------+
   |  project container A     |      |  project container B     |
   |                          |      |                          |
   |  +--------------------+  |      |  +--------------------+  |
   |  |  listener (per-     |  |      |  |  listener            |  |
   |  |  project, inert     |  |      |  |  (inert by default)  |  |
   |  |  until activated)   |  |      |  +--------------------+  |
   |  +---------+----------+  |      +-------------------------+
   |            | writes       |
   |            v               |
   |  +--------------------+  |
   |  |  request queue       |  |     on-disk, same tree the
   |  |  (on-disk, FIFO)    |  |     tmux/session-farm hooks
   |  +---------+----------+  |     already use for state
   |            | tmux send-keys
   |            v               |
   |  +--------------------+  |
   |  |  tmux session        |  |
   |  |  (claude or codex     |  |
   |  |   running inside)     |  |
   |  +--------------------+  |
   +-------------------------+
```

The VPN container is a peer of the project containers, not a parent of them.
It never crosses into a project container's namespace. It only ever talks to
a listener process over the network, the same way any client talks to any
service.

## 3. Why listener-in-target-container + tmux-push, not a host broker

The alternative design is a single host-level broker: one process on the
host that receives remote requests and does `docker exec` / `docker attach`
into whichever project container the request names. That design needs the
host docker socket (or host docker CLI) reachable from the broker. The owner
has ruled out exposing the host docker socket to anything network-facing:
a broker with docker-socket access is equivalent to root on the host, and
if it is reachable from a WireGuard peer, a stolen peer credential becomes
a host compromise, not a project compromise.

The listener-in-target-container design avoids this entirely:

- Each project's listener runs inside that project's own container, with
  the same restricted capability set as the AI orchestrator it sits next
  to. It has no docker socket, no visibility into other containers, no
  host filesystem access beyond what the project container already mounts.
- The listener does the tmux push locally, inside its own container,
  against the tmux server that is already running there (the same tmux
  server the usage-limit auto-resume wrapper uses - see entrypoint.sh
  `_write_tmux_conf` and the `tmux new-session` invocation gated by
  `CBOX_LIMIT_AUTORESUME`). No cross-container attach, no cross-container
  exec, no shared docker API surface.
- The VPN container's job shrinks to: authenticate the peer, and forward
  bytes to the right project's listener over the network. It carries no
  privilege over any project container. Losing the VPN container costs
  the attacker a network vantage point, not a shell in every project.
- Compromise of one listener is scoped to one project container - it
  already had that container's access before the listener existed. It
  cannot pivot to a sibling project because there is no shared broker
  holding credentials for all projects at once.

This mirrors the precedent already in the codebase: `cbox login` /
`login_claude` and `login_codex` in `cbox/cbox` do not reach into the
container from a privileged host process either - they open a `socat`
loopback bridge *into* a `docker compose exec` session per invocation,
scoped to one service, torn down when the login finishes (see
`_socat_exec_addr`, `login_claude`, `login_codex` around cbox:963-1050).
F7 generalizes the same principle - reach in narrowly, per-project, only
while needed - rather than centralizing control on the host.

The cost of this choice: the discovery CLI and the VPN container cannot
prove a project container is alive by asking Docker directly (no socket).
It has to ask the listener, or infer liveness from the on-disk state each
listener already publishes (see section 5's reuse of the jobs/state.json
and pane-map pattern). That is an acceptable trade against never handing
out host docker access.

## 4. WireGuard peer generation flow

Component: a dedicated VPN container, built the same way the egress proxy
sidecar is built today (`templates/generators.sh` `gen_dockerfile_egress_into`,
`gen_supervisord_conf_into`, `gen_tinyproxy_conf_into` - a small Alpine image,
declarative config regenerated from `_cbox_write`, run under supervisord,
wired into compose only when active via `_cbox_proxy_active`-style gating).
The VPN container would follow the same shape: `Dockerfile.vpn`,
`generators.sh`-produced wireguard + sshd config, gated by its own
`_cbox_vpn_active` check, `internal`/`external` compose networks kept
separate the way `internal`/`egress` are kept separate today.

PROPOSAL flow:

1. Operator (owner) runs a host-side `cbox vpn peer add <name>` command
   (name TBD - see open decisions on CLI surface).
2. The command runs inside (or drives) the VPN container to generate a
   fresh WireGuard keypair for the new peer. The private key is shown once
   to the operator (for the mobile client) and never stored server-side in
   plaintext beyond what WireGuard's own peer table requires.
3. Before the peer's public key is added to the WireGuard interface's
   allowed-peers list, two gates must pass:
   - SSH key gate: the peer registration is authenticated by an SSH
     key already trusted by the VPN container's sshd (PROPOSAL: the
     same `authorized_keys` model already used for `CBOX_SSH_MODE`
     host-agent/mixed modes in `generators.sh`, not a new key system).
   - Optional email-2FA gate: PROPOSAL, a one-time code emailed to the
     owner, entered before the peer config is finalized. This is the
     step with the least existing precedent in the codebase and needs
     the most owner decision (see section 8).
4. Once both gates pass, the VPN container writes the peer into its
   WireGuard config and emits a connection profile (a `.conf` / QR
   payload) for the operator to import into Termius or any WireGuard
   client on the phone.
5. The phone connects over the WireGuard tunnel; from inside the tunnel,
   normal SSH (to the VPN container, or onward per section 2) is used for
   the actual work session. The host is never reachable without an
   established WireGuard session first - no service is exposed on the
   open internet; the WireGuard listener itself is the only thing that
   answers UDP without a valid peer key, and it drops unauthenticated
   packets by protocol design (WireGuard does not respond to peers it
   does not recognize, which also avoids give-away port-scanning signal).
6. Home-LAN use is the same flow with the peer connecting over the LAN
   instead of over a forwarded WAN port - no separate code path, just a
   different route to the same WireGuard listener.

Peer revocation is the inverse: remove the public key from the WireGuard
config and regenerate; the VPN container disconnects that peer immediately
on next handshake attempt.

## 5. Activation model

Remote control is off by default, per project, until explicitly turned on.

- PROPOSAL: a `CBOX_REMOTE_MODE` (name TBD) project-level flag, same
  pattern as `CBOX_EGRESS_MODE` / `CBOX_NETACCESS_MODE` today - defaults
  to `off`, only becomes real when both the flag is set and an "applied"
  bit is set after generation (mirroring `CBOX_EGRESS_APPLIED` gating
  `_cbox_egress_active`). This double-gate (declared + applied) is the
  existing convention for "this changes the attack surface, so it needs
  two separate steps to turn on," and F7 should reuse it rather than
  invent a new switch shape.
- When off, the listener binary/process does not run at all - it is not
  merely firewalled, it is not started. Compose would not even include
  the listener's port/service definition for a project with remote
  disabled, the same way `gen_compose_*` only emits the `proxy` service
  block when `_cbox_proxy_active` is true.
- Turning it on is a project-scoped, explicit action (host-side compose
  regen + container recreate, matching how `CBOX_EGRESS_MODE` changes take
  effect today - not a live runtime toggle inside a running container).
- Per-project activation means enabling remote for one project does not
  expose any other project; each project's listener is independently
  gated, independently keyed (see open decisions), and independently
  revocable.

## 6. Queue semantics

The listener does not talk to the tmux session directly on receipt of a
request; it writes to an on-disk queue first, then drains it.

- PROPOSAL: a directory-based FIFO under the project's existing
  `.claude-cbox` / generated-state tree (the same tree `session_scope_farm.py`
  and `limit_watchdog.py` already read and write - `jobs/`, `limit-watch/`,
  atomic write-then-rename patterns throughout those hooks are the
  established idiom in this codebase: write to a `.tmp` file, `os.replace`
  into place, so a reader never sees a half-written record).
- One request in flight at a time per session/pane. The listener reads the
  next queued request, resolves which tmux pane it targets (see discovery,
  section 2/7), and performs the push. It does not accept a second push to
  the same pane until the first has been delivered - this matches how a
  human at a keyboard can only type one thing at a time, and avoids
  interleaving two remote inputs into one CLI turn.
- The push itself is `tmux send-keys -t <pane> -l <text>` followed by
  `tmux send-keys -t <pane> Enter`, the exact mechanism already in
  production in `limit_watchdog.py`'s `inject()` function (send literal
  text, then a separate Enter key event, wrapped in error handling that
  distinguishes "typed but Enter failed" from a clean send). F7's queue
  drainer should call the same two-step pattern rather than reinvent it.
- Output return path: PROPOSAL, the listener tails the same tmux pane (or
  the underlying transcript JSONL that Claude/Codex sessions already write
  under `projects/<slug>/<sid>.jsonl`, which `session_scope_farm.py` and
  `limit_watchdog.py` already parse) and streams new lines back to the
  queue's response side, which the remote client polls or receives over
  the same authenticated channel it used to submit the request. This
  avoids a second capture mechanism - the transcript file is already the
  system of record for "what did the session say," and F7 becomes a
  reader of it, not a new producer.
- Queue depth and backpressure: PROPOSAL, small bounded queue per pane
  (single digit), reject new remote submissions with a clear "busy" reply
  once the pane already has a pending job of its own, rather than silently
  queuing an unbounded backlog a returning operator would not expect.

## 7. Expert-mode session spawn (sharpest capability)

Everything above assumes a session is already running and remote control
pushes text into it. Expert mode adds the ability to *start* a new session
in a project that has none running. This is qualitatively more dangerous
than pushing a follow-up prompt into an existing conversation - it is the
difference between talking to a running process and being able to launch
new processes. Treat it as a separate, higher-gated capability, not a
mode flag on the same listener.

PROPOSAL gating, all of which must hold before an expert-mode spawn is
accepted:

- Separate authorization: expert mode requires its own credential/scope
  beyond the base WireGuard peer + SSH + 2FA gate that gets someone
  "into" the system - e.g., a peer is provisioned for ordinary remote
  push, and a distinct, explicitly-granted flag or separate peer class
  is required for spawn rights. Owner decision on shape (see section 8).
- Explicit confirmation per spawn: not a fire-and-forget API call - the
  request must be confirmed (PROPOSAL: a second round-trip, e.g. the
  listener echoes back what it is about to start - which binary, which
  project, which working directory - and requires a second signed/typed
  confirmation before it runs `cbox run claude` / `cbox run codex` or
  opens a new tmux window for it).
- Project allowlist: expert-mode spawn is only valid against projects the
  owner has pre-approved for remote spawn, distinct from the (larger) set
  of projects that merely have remote push enabled. A project can accept
  remote input into an already-running session without also accepting
  remote-triggered new sessions.
- Audit: every spawn attempt (accepted or rejected) is logged with peer
  identity, timestamp, project, and the exact command that would run /
  did run, written to durable on-disk state before the spawn is attempted,
  not only after - so a crash mid-spawn still leaves a record.

Even with all four gates, expert-mode spawn should default to disabled at
the project level independent of whether basic remote push is enabled
there (see open decision on whether it ships enabled at all in v1).

## 8. Security boundary analysis

Remote control is remote execute against an autonomous AI that can run
shell commands, edit files, and call other tools. The threat model is not
"someone reads my session," it is "someone gets to type into an agent that
can act on this machine." The boundary has to hold at every layer:

- Network identity: WireGuard is the outermost gate. No peer, no packet
  answered - not "packet answered then rejected," but silently dropped,
  so an unauthenticated scanner cannot even confirm the service exists.
  This is a stronger default posture than a TCP listener with app-level
  auth, which at minimum leaks "something is listening here."
- Per-project activation: compromising the VPN container's peer table
  does not, by itself, grant control of any project - the peer still has
  to reach a listener that is (a) running at all (activation gate) and
  (b) willing to accept that peer's requests (its own auth, see below).
  Two independent projects with remote enabled are two independent
  blast radii, not one.
- SSH + 2FA at peer-issuance time: the WireGuard peer itself is not the
  only credential - getting a peer config issued in the first place is
  gated behind an SSH key the operator already controls, plus (PROPOSAL)
  a second factor. This means stealing a `.conf` file after the fact is
  necessary but not sufficient to mint new access; it only replays
  existing access until revoked.
- Listener default-off: the single biggest reduction in attack surface
  is that most projects, most of the time, run no listener process at
  all. There is no code path to exploit in a project that has not been
  explicitly turned on for remote.
- Container remains the boundary: none of the above changes cbox's
  standing security model - the project container is still the sandbox,
  egress is still proxied/filtered per `CBOX_EGRESS_MODE`, and the
  listener has exactly the same container-level restrictions as the AI
  orchestrator it lives next to. Remote control adds a new way to *reach*
  the boundary; it does not move the boundary.
- Audit: every remote request (push and spawn) should be logged with
  peer identity, project, timestamp, and payload/command, independent of
  the transcript the AI session itself already writes - so "who told the
  agent to do X" is answerable even if the session transcript alone would
  not distinguish a local vs. remote origin.
- Failure-closed defaults throughout: unknown peer -> dropped; project
  not activated -> no listener to receive; pane busy -> queue full ->
  reject, do not silently drop or interleave; spawn without allowlist
  membership -> reject and log, do not fall back to "ask forgiveness."

## 9. Open owner decisions

These are not implementation details deferred for convenience - each one
materially changes the security posture and needs an explicit owner call
before build starts.

1. Email-2FA mechanism and bypass story: which email provider/relay sends
   the code, how is it triggered from inside a container whose egress is
   normally filtered, and - critically - what happens if email is
   unavailable (lockout risk) or if 2FA is skipped entirely (owner-only
   fallback, and how that fallback itself is protected from abuse).
2. WireGuard vs. home-LAN-only variant: does F7 need to support
   WAN-reachable WireGuard (port-forwarded from the owner's router) or is
   the initial scope LAN-only (phone on the same Wi-Fi, or a VPN back to
   home first via an unrelated, already-trusted mechanism)? This changes
   whether the VPN container ever needs an internet-facing port at all.
3. Whether expert-mode spawn ships enabled in v1, or v1 is push-only into
   already-running sessions with spawn deferred to a later wave.
4. Port and interface choices for the WireGuard listener and any
   listener-to-VPN-container link (which interface binds what, whether
   the project-listener link stays on a private compose network the way
   `internal`/`egress` are split today).
5. Key generation, rotation, and storage: who generates WireGuard keys
   (operator machine vs. inside the VPN container), where private keys
   for the server side live at rest, rotation cadence, and revocation
   procedure/runbook.
6. Queue authentication: does each request need per-request signing
   distinct from the WireGuard tunnel's own authentication, or is "inside
   the tunnel" treated as sufficiently authenticated for queue writes?
7. Operator identity: is there one operator (owner-only) or multiple
   named operators with distinct peers/audit identities from day one -
   this affects whether the peer registry needs a name-to-person mapping
   now or can stay single-user initially.

## 10. Effort and risk estimate, phased build order

Honest estimate: this is a multi-week effort for a careful implementation,
not a weekend add-on, because the hard parts are exactly the parts that
must not be rushed (auth gating, queue correctness, failure-closed
behavior under crash/restart). Order below front-loads the pieces that are
safe to build and test in isolation before anything is network-reachable.

Phase 1 - VPN container skeleton (no network exposure yet):
build the WireGuard + sshd sidecar image and its generator functions in
`templates/generators.sh`, following the existing egress-proxy sidecar
pattern (Dockerfile, supervisord, config regeneration via `_cbox_write`,
compose wiring gated by an off-by-default flag). No peer issuance flow
yet - just prove the container builds, starts, and stays isolated.

Phase 2 - Peer issuance flow, SSH-gated only (2FA deferred):
implement `cbox vpn peer add`, keypair generation, SSH-key-gated approval,
and revocation. Test entirely on the LAN-only variant first (open decision
2) so no port-forwarding or WAN exposure is needed to validate the auth
gate.

Phase 3 - Per-project listener, push-only, no spawn:
implement the listener process, the on-disk queue (reusing the atomic
write-then-rename idiom from `session_scope_farm.py` / `limit_watchdog.py`),
and the tmux push using the same `send-keys` two-step pattern already
proven in `limit_watchdog.py`. Activation flag off by default, applied-bit
gating identical in shape to `CBOX_EGRESS_MODE`/`CBOX_EGRESS_APPLIED`.
Output return path via transcript tailing.

Phase 4 - Discovery CLI:
build the VPN-container-side CLI that lists running cbox containers and
available sessions, reusing the disk-scan approach already used for
`jobs/*/state.json` (`linkScanPath` parsing in `session_scope_farm.py`'s
`job_ref`) and the session-to-pane map (`session_pane_map.py`'s per-session
JSON records under `limit-watch/panes/`). This phase has no new privilege
- it is read-only over data structures that already exist for the
usage-limit auto-resume feature.

Phase 5 - Email-2FA (pending open decision 1):
add the second factor to peer issuance once the mechanism and bypass story
are decided. This is deliberately last among the auth-affecting phases so
the rest of the system can be built and tested without depending on an
external email dependency.

Phase 6 - Expert-mode spawn (pending open decision 3):
only after phases 1-4 are stable in real use. Implements the separate
authorization scope, explicit per-spawn confirmation, project allowlist,
and audit trail described in section 7. Treated as its own review gate,
not a natural extension of phase 3 - a push-only remote system earning
trust does not automatically justify a spawn-capable one.

Each phase should land as its own reviewable, revertable change, with the
activation flag defaulting to off through and past phase 4, so an
in-progress F7 build never widens the live attack surface of any existing
project before the owner turns it on deliberately.
