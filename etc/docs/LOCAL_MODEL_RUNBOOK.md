# Local model runbook (F4/F5)

The feature ships OFF by default: absent from the rendered MCP server list unless
CBOX_LOCAL_MODEL_URL is set, and the cbox ai local-qwen engine refuses to run unless
CBOX_LOCAL_MODEL=on plus both CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME are set.

Live verification is a host-side step. Paths A, B, and C below describe the topology
recipes; Path A (sibling container) is likely simplest. Confirm the endpoint is
reachable and responding to model queries from inside a cbox session before declaring
success.

## What this is

Two independent pieces, both text-only, both gated off by default:

- F4: an MCP delegate (local-qwen) - a stdio MCP server
  (etc/mcp/local_model_mcp.py) exposing one tool, local-complete, backed by
  an OpenAI-compatible HTTP endpoint (ollama's /v1/chat/completions). No
  filesystem or shell tools; it can only return model text.
- F5: a cbox ai engine (local-qwen) - drives codex --oss --local-provider
  ollama against the same endpoint, so the whole cbox ai analyse/plan/full
  loop (including .cbox SessionStart/write hooks) can run against a local
  model instead of a subscription.

Ollama itself runs OUTSIDE cbox always. Nothing here grants cbox a GPU or
CDI device; compute stays wherever ollama runs, cbox only makes HTTP calls
to it and gets text back.

## Path A: cbox-managed ollama (machine-scoped owner project)

Ollama runs in a separate owner compose project under ~/.config/cbox/infra/ollama,
automatically managed by cbox. This is the primary path: simple, ephemeral, and
survives per-project container lifecycle.

1. Run `./setup.sh update ollama` (or the interactive wizard, section "ollama")
   and set `CBOX_OLLAMA_MODE=on`. Optionally set `CBOX_OLLAMA_GPU=cdi` if GPU
   access is available, `CBOX_OLLAMA_IMAGE` to pin a different image tag, or
   other variables (see cbox/MANUAL.md section "ollama" for full configuration).
2. Pull a model: `cbox ollama pull qwen2.5:7b` (or any model tag). The pull
   temporarily starts the serving container on an ephemeral network, stops the
   server before pulling (so the pull endpoint receives egress permission once
   then loses it), and restarts the server afterward.
3. Set `CBOX_LOCAL_MODEL_URL=http://ollama:11434` and `CBOX_LOCAL_MODEL_NAME=qwen2.5:7b`.
4. Run `./setup.sh update local-model` to persist the local-model settings,
   then `./setup.sh update mcp-servers` or restart the container so the MCP
   server list picks up local-qwen.

The cbox-managed owner project (`cbox-infra-u<uid>`) is machine-scoped: every
project on the machine shares the same ollama instance, and the instance is never
torn down by a per-project `cbox down`. Apply changes with `cbox ollama reconcile`.
The per-scope internal network joins the cbox container and the ollama container
to a shared private network (`cbox-ollama-u<uid>-global` or
`cbox-ollama-u<uid>-p<projecthash>`), so the endpoint is always `http://ollama:11434`
inside any cbox container, regardless of mode or scope.

Note: local-qwen only becomes selectable in the mcp-servers wizard step
(and in `mcp_all_names()`, which the wizard's checkbox list is built from)
once CBOX_LOCAL_MODEL_URL is set - it is not merely unchecked before that,
it is absent from the list entirely. With the default CBOX_MCP_SERVERS=all
this self-heals: configuring local-model afterward calls mcp_apply_selection
automatically and picks it up with no extra step. If CBOX_MCP_SERVERS was
narrowed to an explicit subset before local-model was configured, re-run
`./setup.sh update mcp-servers` once after setting the URL to add local-qwen
to that subset.

## Path B: Manual sibling container (deprecated; use Path A)

An alternative to cbox-managed ollama: run a separate container yourself and
join it to cbox's network via `CBOX_NETACCESS_MODE`. This path is not recommended
for most use cases - Path A handles network wiring and lifecycle automatically.

If you choose this path:

1. On the host, run the model server as its own container (not inside cbox):
   - **Ollama**: `docker run -d --name ollama -v ollama:/root/.ollama -p 11434:11434 ollama/ollama`.
   - **llama.cpp**: `docker run -d --name llama-cpp -v models:/models -p 11434:8000 ghcr.io/ggerganov/llama.cpp:full-cuda --model /models/model.gguf --host 0.0.0.0 --port 8000`.
2. Pull the model: `docker exec ollama ollama pull qwen2.5:7b` or download the GGUF file manually.
3. Configure netaccess to join cbox to the model server container's network
   (not a wizard setting - cbox netaccess allow <docker-network> on the host).
4. Set `CBOX_LOCAL_MODEL_URL=http://ollama:11434` and `CBOX_LOCAL_MODEL_NAME=qwen2.5:7b`.
5. Run `./setup.sh update local-model`, then `./setup.sh update mcp-servers` or restart.

## Path C: ollama as a host process (via host-route gateway)

Run ollama directly on the host (not containerized) and reach it through the
host-route proxy that lets a container reach a host-bound port without a
raw host-network mount.

1. On the host: ensure ollama listens beyond 127.0.0.1 (e.g. `OLLAMA_HOST=0.0.0.0:11434 ollama serve`).
2. Pull the model: `ollama pull qwen2.5:7b` (pick a qwen variant that fits available VRAM/RAM).
3. Enable host-route via `./setup.sh update hostroute`: set `CBOX_HOST_ROUTE_MODE=host-proxy` and optionally `CBOX_HOST_GATEWAY_ALIAS=on` (renders `extra_hosts: host.docker.internal` for `http://host.docker.internal:11434` URLs inside the container).
4. Set `CBOX_LOCAL_MODEL_URL=http://host.docker.internal:11434` (or use the explicit proxy URL if `CBOX_HOST_GATEWAY_ALIAS` is off; the exact URL depends on `CBOX_HOST_PROXY_ADDR_MODE`).
5. Set `CBOX_LOCAL_MODEL_NAME=qwen2.5:7b`.
6. Run `./setup.sh update local-model` to persist the settings, then `./setup.sh update mcp-servers` or restart the container so the MCP server list picks up local-qwen.

Caveat: the host process must listen beyond 127.0.0.1. If listening only on the loopback, the container cannot reach it even through the proxy. Under rootless docker the host-gateway alias does not work; use an explicit host tunnel interface IP (e.g. a wireguard tunnel IP) instead.

## Path D: remote endpoint over wireguard tunnel

Access a local model running on a remote machine over a wireguard tunnel. The
container needs no special cbox wiring - it uses plain routing to reach the
tunnel IP of the remote machine.

1. On the remote machine: run ollama or llama.cpp server with a local model (e.g. `ollama serve` or `llama-server --host 0.0.0.0 --port 11434`).
2. Establish a wireguard tunnel to that machine (setup and join are host OS steps, outside cbox scope).
3. On the host running cbox: note the tunnel IP of the remote machine (e.g. `10.0.0.5`).
4. Set `CBOX_LOCAL_MODEL_URL=http://10.0.0.5:11434` and `CBOX_LOCAL_MODEL_NAME=qwen2.5:7b` (or appropriate model name).
5. Run `./setup.sh update local-model` to persist the settings, then `./setup.sh update mcp-servers` or restart the container.

Caveat under egress lockdown or SOCKS mode: the remote endpoint must be explicitly allowed in the egress allowlist, or those modes must be turned off entirely for the wireguard path to work.

Path A (cbox-managed) is simplest and recommended; Path B avoids containerizing ollama if you want it to run natively; Path C reaches a host ollama via proxy; Path D reaches a remote model over a tunnel without cbox wiring. Live verification of endpoint reachability is a host-side step - these descriptions are configuration goals, not confirmed results.

## Design decision: no CBOX_LOCAL_MODEL_APPLIED flag

egress/netaccess/hostroute each have a CBOX_*_APPLIED flag that tracks
whether a MODE change has actually been re-applied to a running container
(config-drift tracking, not endpoint health). local-model intentionally does
not clone that flag: this was decided during the 07-19 wave (see LEDGER) on
the grounds that local-model has no `require:`-style hard wizard refusal to
protect and the delegate/engine both do their own per-call reachability
checks instead of a one-time apply-time check (local_model_mcp.py probes
/api/tags at MCP server startup, non-fatally; cbox ai's preflight only
checks that the env vars are set, not that the endpoint answers). The
tradeoff: `cbox doctor` reporting ACTIVE means "env vars are set and
consistent", not "the endpoint was verified reachable" or "a running
container has picked up this exact config" - unlike egress/netaccess/
hostroute's ACTIVE, which additionally implies re-application since the
last change. If this becomes confusing in practice, add
CBOX_LOCAL_MODEL_APPLIED cloning the sibling pattern; not done here because
health is already checked per-call, so an apply-time gate would be
redundant with, not a replacement for, that check.

Note: cbox-managed ollama (Path A) is separate and machine-scoped, applying via
`cbox ollama reconcile` with its own SEC_APPLY=infra-reconcile apply class.

## Verifying the MCP delegate (F4) once configured

1. `cbox doctor` (or the doctor row in `cbox`) should report local-model as
   ACTIVE once CBOX_LOCAL_MODEL=on and both CBOX_LOCAL_MODEL_URL/NAME are
   set; CONFIG-ONLY if only partially set; OFF otherwise. ACTIVE here means
   the config is consistent, not that the endpoint has been verified
   reachable - see "Design decision" above.
2. Inside a claude session in the container, the local-qwen MCP server
   should appear with one tool, local-complete. Calling it with a prompt
   should return text from the configured ollama model. If the endpoint is
   unreachable, the tool call fails with a clear "endpoint unreachable"
   message rather than hanging (bounded by CBOX_LOCAL_MODEL_TIMEOUT_SEC).
3. Audit trail: ~/.claude/local_model_audit.container.jsonl inside the
   container should show one line per call (model, duration, byte counts),
   never prompt or response content.

## Verifying the cbox ai engine (F5) once configured

1. `cbox ai analyse local-qwen -p "say hi"` (or `--host`) should run codex
   with --oss --local-provider ollama and CODEX_OSS_BASE_URL set from
   CBOX_LOCAL_MODEL_URL, with no OpenAI login prompt.
2. `cbox ai full local-qwen -p "..."` should run the full .cbox
   SessionStart/write hook path exactly like the claude/codex engines do
   today - the only difference is which model answers.

## Release gate

The stated goal (both subscriptions off, still able to work) is:
`CBOX_LOCAL_MODEL=on` with a real reachable endpoint, then
`cbox ai full local-qwen -p "<task>"` completes an entire
analyse-or-plan-then-edit loop end to end, with .cbox continuity hooks
firing exactly as they do for the claude/codex engines, and no calls to
the Claude or OpenAI/Codex subscriptions anywhere in that run. This has
NOT been exercised against a live ollama endpoint; it is the definition of
done for whoever runs Path A or Path B for real.

## Open decisions (owner's call, not made tonight)

- Path A vs Path B as the supported/default topology (or support both
  indefinitely).
- The exact endpoint URL/port and whether it is pinned in cbox.conf or left
  per-operator.
- Which qwen model/quantization (VRAM/RAM budget, quality-vs-speed
  tradeoff); the code has no opinion, CBOX_LOCAL_MODEL_NAME is a free string.
- Whether Path A's docker network join reuses CBOX_NETACCESS_MODE's existing
  SOCKS-reachable-network mechanism or needs its own simpler join - this
  runbook describes the goal, not a wired implementation; the netaccess
  section itself was not touched by this wave.
- Egress allowlist implications if local-qwen's traffic must cross the
  existing egress proxy sidecar instead of a direct docker network path.
- GPU/VRAM budget for wherever ollama runs (outside cbox's GPU/CDI scope
  entirely - cbox never requests a GPU grant for this feature).
- Whether local-qwen ever enters _cbox_ai_engine_auto's fallback chain.
  Tonight's answer is explicitly NO: inserting a local model into autonomous
  fallback would silently degrade quality without a human noticing, and that
  tradeoff is the owner's to make, not a default to slip in quietly.
