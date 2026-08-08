# WireGuard runbook (machine-scoped sidecar)

The feature ships OFF by default (`CBOX_WG_MODE=off`): no interface, no key, no published port, no container, no network, and no image build beyond what the cbox-managed ollama already needs. No code is inert without configuration; everything must be opt-in.

Live verification is a host-side step. The two-machine scenarios below describe the topology recipes. Confirm connectivity and bidirectional model traffic over the tunnel before declaring success.

## What this is

A WireGuard sidecar in the same machine-scoped owner project as ollama (`cbox-infra-u<uid>`), with two independently switchable roles:

- **Server mode** - publishes one UDP port (the WireGuard handshake + keepalive channel); peer connections arrive over the tunnel and are forwarded to the local ollama service.
- **Client mode** - dials a configured remote peer; once connected, a forwarder inside the infra network exposes the remote ollama under a stable internal alias (`wg-remote-ollama`).

Both roles can run on the same machine at once (`CBOX_WG_MODE=both`).

The central security design is no routing: the sidecar terminates the tunnel and forwards exactly one TCP service (ollama) in each direction with a userspace forwarder. It never enables IP forwarding, adds NAT or masquerade rules, or acts as a gateway. The sidecar never joins any per-scope cbox network; only the ollama service and one cbox container belong to those. Every peer's allowed address must be a single host (`/32`); wider prefixes are refused because they would let one peer claim other peers' addresses.

## Two-machine setup overview

The most common use case: Machine A shares its ollama with Machine B over WireGuard.

- **Machine A** (server): runs ollama in its cbox-managed infra service, and opens the WireGuard port to accept peer connections from B.
- **Machine B** (client): establishes a tunnel to A and reaches A's ollama through the tunnel forwarder without needing to know about routing.

Both machines need:
- A shared wireguard-tools package on the host (for `wg` CLI key generation and key verification).
- The `/dev/net/tun` device on the host (checked at sidecar startup; referenced in rootless Docker configuration).
- If using GPU acceleration, that capability is available independently on each machine; the WireGuard tunnel itself is transport-agnostic.

None of this has been executed live from the build environment, so a live test of end-to-end model inference over the tunnel is not confirmed.

## Machine A setup (server role - sharing this machine's ollama)

### Step 1: Enable cbox-managed ollama on Machine A

Run `cbox setup` on Machine A and enable the ollama section:

```bash
cbox setup update ollama
```

When prompted, set `CBOX_OLLAMA_MODE=on`. Optionally set `CBOX_OLLAMA_GPU=cdi` if you have GPU access. Accept other defaults or customize as needed.

### Step 2: Pull a test model to the ollama service

```bash
cbox ollama pull qwen2.5:7b
```

(Or any other model that fits your hardware.)

### Step 3: Generate the WireGuard keypair on Machine A

```bash
cbox wg keygen
```

This creates `~/.config/cbox/infra/wireguard/privatekey` (0600) and `~/.config/cbox/infra/wireguard/publickey` (0644).

Verify:

```bash
cbox wg status
```

Should report `OFF` (sidecar not yet enabled) but the keys will be present and ready.

### Step 4: Enable WireGuard server role on Machine A

Run `cbox setup` and go to the wireguard section:

```bash
cbox setup update wireguard
```

When prompted:
- **Mode**: select `server` (this machine will accept inbound tunnel connections).
- **Implementation**: select `auto` (probes for kernel at runtime, falls back to userspace).
- **This node's tunnel address**: e.g., `10.90.0.1/24`.
- **UDP listen port**: e.g., `51820` (default). This is the single intentional exposure - key-authenticated by WireGuard, unlike ollama itself which has no authentication.
- **Host address the UDP port is published on**: empty (listens on all addresses), or a specific address if you want to narrow exposure.

Accept and save.

### Step 5: Reconcile the infra project on Machine A

```bash
cbox ollama reconcile
```

This creates or updates the owner project with both the ollama service and the WireGuard sidecar. The sidecar will start, pick the kernel or userspace WireGuard implementation at runtime, and bring up the tunnel interface.

Verify:

```bash
cbox wg status
```

Should now report `ACTIVE: kernel` (or `userspace`), interface `cbox0`, listen port `51820`, and any registered peers (initially empty).

### Step 6: Add Machine B as a peer on Machine A

On Machine A, you need Machine B's public key and the tunnel address you want to assign to B.

Run this command on Machine A:

```bash
cbox wg peer add machineB <B_PUBKEY> 10.90.0.2/32
```

Replace `<B_PUBKEY>` with Machine B's WireGuard public key (obtained from Step 2 on Machine B).

Verify:

```bash
cbox wg status
```

Should now show the peer registered.

## Machine B setup (client role - consuming Machine A's ollama)

### Step 1: Generate the WireGuard keypair on Machine B

```bash
cbox wg keygen
```

This creates `~/.config/cbox/infra/wireguard/privatekey` (0600) and `~/.config/cbox/infra/wireguard/publickey` (0644).

Get the public key to share with Machine A:

```bash
cat ~/.config/cbox/infra/wireguard/publickey
```

Share this value with the operator of Machine A (out-of-band).

### Step 2: Enable WireGuard client role on Machine B

Run `cbox setup` and go to the wireguard section:

```bash
cbox setup update wireguard
```

When prompted:
- **Mode**: select `client` (this machine will dial out to the remote peer).
- **Implementation**: select `auto`.
- **This node's tunnel address**: e.g., `10.90.0.2/24` (must not overlap with A's range or other peers).
- **Remote peer endpoint**: the host:port of Machine A's WireGuard listener, e.g., `machine-a.example.com:51820` or `203.0.113.5:51820`.
- **Remote peer public key**: Machine A's WireGuard public key (shared from Machine A's Step 2).
- **Remote peer's own tunnel address**: Machine A's tunnel address, e.g., `10.90.0.1/32`.

Accept and save.

### Step 3: Reconcile the infra project on Machine B

```bash
cbox ollama reconcile
```

The WireGuard sidecar starts and dials Machine A. Once connected, the remote ollama is available under the `wg-remote-ollama` internal alias on the infra network.

`CBOX_OLLAMA_PORT` does not affect this forward: the sidecar always forwards to the ollama container's real listen port (11434, fixed) and always listens on port 11434 on the tunnel/alias side too. Do not try to change the tunnel port via `CBOX_OLLAMA_PORT` - that setting only controls the host-side probe used by `CBOX_OLLAMA_STORE=shared` to detect a conflicting host daemon.

Verify:

```bash
cbox wg status
```

Should report `ACTIVE: kernel` (or `userspace`), and the peer handshake timestamp should be recent (not `(none)`).

### Step 4: Configure the local-model endpoint on Machine B to use the remote ollama

Set up a local model that points to the remote ollama via the tunnel:

```bash
cbox setup update local-model
```

When prompted:
- **Enable local model**: `on`.
- **Endpoint URL**: `http://wg-remote-ollama:11434` (the stable internal alias).
- **Model name**: the model name running on Machine A, e.g., `qwen2.5:7b`.

Accept and save.

### Step 5: Verify connectivity from inside a cbox session

Start a cbox session on Machine B:

```bash
cbox run claude
```

Inside the session, test that the tunnel is up and the remote ollama is reachable:

```
curl http://wg-remote-ollama:11434/api/tags
```

You should see the list of models available on Machine A's ollama. If the endpoint is unreachable, check:

- Machine A's `cbox wg status` - is the sidecar ACTIVE and is B listed as a peer with a recent handshake?
- Machine B's `cbox wg status` - is the sidecar ACTIVE and is the peer connection timestamp recent?
- Network connectivity: can you ping the tunnel IP from Machine A to B and vice versa? (Packet loss is OK; WireGuard handles it.)
- Firewall rules: does the UDP listen port on Machine A allow inbound traffic from Machine B?

## Switching roles or disabling

### Switching from server to client (or vice versa)

Edit `cbox.conf` manually or use `cbox setup update wireguard` to change `CBOX_WG_MODE`. Then reconcile:

```bash
cbox ollama reconcile
```

The sidecar reconfigures in place.

### Disabling the sidecar entirely

Set `CBOX_WG_MODE=off`:

```bash
cbox setup update wireguard
# or manually edit ~/.config/cbox/cbox.conf: CBOX_WG_MODE=off
```

Then reconcile:

```bash
cbox ollama reconcile
```

This tears down the WireGuard sidecar. Key material stays in place (not deleted); restarting the feature simply brings the sidecar back.

## Key management

Keys live under `~/.config/cbox/infra/wireguard` on the host:

- `privatekey` (0600) - never world- or group-readable. This file is mounted read-only into the sidecar container, never into any cbox workspace container.
- `publickey` (0644) - the public counterpart; safe to share.
- `peers` (0600) - a machine-parseable line-format file: `name|pubkey|allowed-address`. Managed by `cbox wg peer {add,rm,list}`.

### Generating keys

`cbox wg keygen` invokes the host `wg` CLI (from wireguard-tools). If the binary is missing, the command fails naming the package. A placeholder key is never written; either a full key exists or nothing.

### Adding peers from the peer's own generated key

Preferred: the peer generates its own private key (`cbox wg keygen` on their machine) and sends you only their public key.

```bash
cbox wg peer add remote-machine-name <their-pubkey> 10.90.0.3/32
```

### Generating a peer's key locally and sharing it

Optional: generate the peer's entire keypair locally if they cannot run cbox tools:

```bash
cbox wg peer config peer-name --generate-key
```

This prints a ready-to-paste `[Peer]` block containing this node's public key, the tunnel endpoint, and a newly generated private key for the peer. The peer can paste that block into their WireGuard config; this mode is less secure (the peer's private key crosses the network) but can be useful in bootstrapping.

## Verifying the tunnel

### From Machine A (server)

```bash
cbox wg status
```

Should show:
- Interface: `cbox0`
- Mode: `ACTIVE`
- Implementation: `kernel` or `userspace`
- Listen port: `51820` (or configured value)
- List of peers with public key, allowed address, and last handshake timestamp

### From Machine B (client)

```bash
cbox wg status
```

Should show:
- Interface: `cbox0`
- Mode: `ACTIVE`
- Peer with endpoint, public key, allowed address, and last handshake timestamp

### Testing model inference over the tunnel

On Machine B, inside a cbox session:

```bash
curl http://wg-remote-ollama:11434/api/tags
curl http://wg-remote-ollama:11434/api/generate -X POST \
  -H 'Content-Type: application/json' \
  -d '{"model": "qwen2.5:7b", "prompt": "Hello", "stream": false}'
```

Both should respond with model output. If the first curl returns a connection error, the tunnel is not up or the forwarder is not listening yet; if it connects but times out or hangs, check that ollama is actually running on Machine A.

## Rootless Docker caveats

This host runs rootless Docker. A published port under rootless docker goes through the rootless port forwarder, which can rewrite the observed source address. This is harmless for WireGuard (peer authentication is by key, not source address) but means a displayed peer endpoint in `cbox wg status` may be the port forwarder's address rather than the peer's true remote address. The connection is still authenticated correctly.

The sidecar needs `NET_ADMIN` (to manage the WireGuard interface) and `/dev/net/tun` (the kernel tunnel device). These are runtime prerequisites checked by the sidecar startup script and the preflight in `cbox ollama reconcile`. If `/dev/net/tun` is missing, both commands print a clear message; the sidecar cannot proceed without it.

## Detailed verbs and peer management

### `cbox wg status`

Print the sidecar status: OFF, CONFIG-ONLY, or ACTIVE.

When ACTIVE:
- Interface name and address
- Kernel or userspace implementation choice
- Listen port (server mode only)
- Each peer: public key, allowed address, last handshake time

### `cbox wg keygen`

Generate or confirm the keypair at `~/.config/cbox/infra/wireguard/{privatekey,publickey}`.

### `cbox wg peer add <name> <pubkey> <address/32>`

Register a peer. Validates:
- Name matches `[A-Za-z0-9_-]+`
- Public key is 44-character base64
- Address is a single host (`/32`); wider prefixes are refused

Attempts an in-place reload with `wg syncconf` to avoid dropping other peers; falls back to restarting the sidecar if that fails.

### `cbox wg peer remove <name>`

Unregister a peer. Inverse of add.

### `cbox wg peer list`

Print the peers file: one line per peer, format `name|pubkey|allowed-address`.

### `cbox wg peer config <name> [--generate-key]`

Print a ready-to-paste `[Peer]` block for the named peer containing this node's public key and endpoint.

Without `--generate-key`, no private key is included.

With `--generate-key`, generates the peer's own private key locally and includes it in the output. Use with caution: the peer's private key will be in the output. The preferred path is for the peer to generate their own key and send you only the public key.

## Design constraints

The sidecar is built to forward exactly one TCP service (ollama) and never route arbitrary traffic. Enforcement:

- The startup script asserts `net.ipv4.ip_forward=0` before bringing the interface up.
- The startup script asserts every `AllowedIPs` entry is a `/32` (single host).
- The sidecar never joins any per-scope cbox network; only the ollama service does.
- Two forwarders (server and client, depending on role) listen on fixed addresses and forward to fixed destinations.

A misconfiguration cannot silently turn the sidecar into a router.

## Release gate

This feature has NOT been exercised against a live two-machine tunnel with end-to-end model inference. The documentation and code are statically verified; live testing on a real host with two machines and a running ollama service is required before this is considered production-ready. Once you confirm a setup like the scenarios above works end to end, the foundation is proven.
