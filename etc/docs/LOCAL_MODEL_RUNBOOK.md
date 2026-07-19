# Local model runbook (F4/F5)

Written blind on 2026-07-19, autonomous overnight wave, and has never run
against a live ollama endpoint. Everything below is a plan to verify on the
host, not a confirmed result. The feature ships OFF by default: absent from
the rendered MCP server list unless CBOX_LOCAL_MODEL_URL is set, and the
cbox ai local-qwen engine refuses to run unless CBOX_LOCAL_MODEL=on plus both
CBOX_LOCAL_MODEL_URL and CBOX_LOCAL_MODEL_NAME are set.

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

## Path A: ollama as its own docker container

Run ollama as a sibling container joined to the same docker network cbox's
egress/netaccess topology already supports, and reach it by service name.

1. On the host, run ollama as its own container (not inside cbox):
   `docker run -d --name ollama -v ollama:/root/.ollama -p 11434:11434 ollama/ollama`
   (or add it as a service in a separate compose file the operator owns -
   cbox's own docker-compose.yml is not touched by this feature).
2. Pull the model into that container: `docker exec ollama ollama pull qwen2.5:7b`
   (pick the qwen variant that fits the available VRAM/RAM - see "open
   decisions" below).
3. Join cbox's container to the same docker network as the ollama container
   (the existing CBOX_NETACCESS_MODE / netaccess section already builds a
   SOCKS-reachable path to other docker networks; whether local-qwen reuses
   that path or needs a plain network join is an open decision - see below).
4. Set CBOX_LOCAL_MODEL_URL=http://ollama:11434 (service-name resolution
   inside the shared network) and CBOX_LOCAL_MODEL_NAME=qwen2.5:7b.
5. Run `./setup.sh update local-model` (or the interactive wizard, section
   "local-model") to persist CBOX_LOCAL_MODEL=on plus the URL/name, then
   `./setup.sh update mcp-servers` or recreate the container so the rendered
   MCP server list picks up local-qwen.

Note: local-qwen only becomes selectable in the mcp-servers wizard step
(and in `mcp_all_names()`, which the wizard's checkbox list is built from)
once CBOX_LOCAL_MODEL_URL is set - it is not merely unchecked before that,
it is absent from the list entirely. With the default CBOX_MCP_SERVERS=all
this self-heals: configuring local-model afterward calls mcp_apply_selection
automatically and picks it up with no extra step. If CBOX_MCP_SERVERS was
narrowed to an explicit subset before local-model was configured, re-run
`./setup.sh update mcp-servers` once after setting the URL to add local-qwen
to that subset.

## Path B: ollama as a host process

Run ollama directly on the host (not containerized) and reach it through the
host-route gateway the 07-15 egress wave built (CBOX_HOST_ROUTE_MODE and the
host-proxy layer), which lets a container reach a host-bound port without a
raw host-network mount.

1. On the host: `ollama serve` (default port 11434), `ollama pull qwen2.5:7b`.
2. Configure the host-route section (CBOX_HOST_ROUTE_MODE=on,
   CBOX_HOST_PROXY_ADDR_MODE) per its own section in ./setup.sh so the
   container can reach 127.0.0.1:11434 on the host through the managed
   forward proxy rather than a direct bind-to-host-network hack.
3. Set CBOX_LOCAL_MODEL_URL to whatever address the host-route layer exposes
   for the host-bound ollama port (exact value depends on
   CBOX_HOST_PROXY_ADDR_MODE - host-gateway vs explicit URL; this mapping
   needs a real host run to pin down, it is not verified here).
4. Same as Path A steps 4-5 for CBOX_LOCAL_MODEL_NAME and applying the
   section.

Path A is likely simpler (service-name DNS inside a shared docker network,
no host-route plumbing needed); Path B avoids running ollama in a container
if the operator wants ollama to have direct GPU access without container
GPU/CDI wiring. Both are description-only until run once on the host.

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
