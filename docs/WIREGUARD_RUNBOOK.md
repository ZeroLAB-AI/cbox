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

## Quick start

Pair a cbox client: three pastes total, keys never handled by hand, and no private key is ever printed.

1. On the server (Machine A):

   ```bash
   cbox wg server add-client pc2
   ```

   This turns on the server role if needed (default tunnel address `10.90.0.1/24`), runs the up path, reserves the next free tunnel address for `pc2`, and prints one line: `cbox wg client join <token>`. The token holds only public data (server public key, endpoint, both tunnel addresses). The endpoint is the detected LAN IPv4 of A unless `--endpoint HOST:PORT` is given.

2. On the client (Machine B): paste that line. It configures the client role, generates B's own key, runs the up path, and prints one line: `cbox wg server add-client pc2 <pubkey>`. It then waits up to 180 s for the handshake and tests the remote ollama.

3. Back on the server: paste that line. B is accepted, and B's waiting check then reports OK. cbox sessions on B reach A's ollama at `http://wg-remote-ollama:11434` (a project needs `CBOX_WG_CLIENT_ATTACH=on`).

### Client without cbox (e.g., Windows WireGuard app)

On A run `cbox wg server add-client pcb --plain`. It prints a ready WireGuard config whose `PrivateKey` line points to a key file saved on A (that key is never printed). Move that file's content to the client, import the config, then test:

```bash
curl http://10.90.0.1:11434/api/tags
```

### Internet access

The router must forward UDP 51820 to A, and the `add-client` call should use `--endpoint HOST:PORT` with a public IP or DDNS name instead of the LAN address.

## Manual setup (advanced)

The quick start above covers the common case; the step-by-step sections below are for manual control over each piece.

### Machine A setup (server role - sharing this machine's ollama)

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

### Machine B setup (client role - consuming Machine A's ollama)

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

### Plain WireGuard client on Machine B (no cbox)

Machine B does not need cbox to consume A's ollama; any WireGuard client works.

1. On Machine B, generate a keypair in the WireGuard app or on the command line:

   ```bash
   wg genkey | tee privatekey | wg pubkey
   ```

2. Send the public key to Machine A (out-of-band).

3. On Machine A, register the peer and generate its config:

   ```bash
   cbox wg peer add pcb <pubkey> 10.90.0.2/32
   cbox wg peer config pcb
   ```

4. Paste the output into the client on Machine B and put the private key on the `PrivateKey` line.

5. Once connected, test from Machine B - the server forwarder listens on A's tunnel address, port 11434:

   ```bash
   curl http://10.90.0.1:11434/api/tags
   ```

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

This prints a ready-to-paste `[Interface]`/`[Peer]` config for the peer: `[Interface] Address = <the peer's own tunnel address>` and `PrivateKey = <contents of peer-<name>.key>`, then `[Peer]` with this node's public key, this node's tunnel address as `AllowedIPs`, and (for a server-role peer) this node's endpoint. The generated private key itself is written to a `0600` file outside the wireguard sidecar mount (`~/.config/cbox/infra/wireguard-peer-keys/peer-<name>.key`), never printed to the terminal. The peer copies that config, substituting the file's contents on the `PrivateKey` line; this mode is less secure (the peer's private key was generated off the peer's own machine) but can be useful in bootstrapping. `cbox wg peer rm <name>` also deletes that key file.

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

### `cbox wg up`

Turn WireGuard on for any role (server, client, both). It checks prerequisites first: installs wireguard-tools via the detected package manager with sudo, loads the `tun` module with `sudo modprobe tun`, and for the server role offers to open the UDP port in ufw or firewalld. Every sudo action asks y/N first; `--yes` skips the question; without a terminal and without `--yes` it prints the exact command to run instead. A declined firewall rule is only a warning. Then keys and the sidecar start as before. `cbox wg down` stops it.

### `cbox wg server add-client <name> [<pubkey>] [--endpoint HOST:PORT] [--plain] [--yes]`

Pair a client with three pastes total, no keys handled by hand, and no private key ever printed.

- Without `<pubkey>`: turns on the server role if needed (default tunnel address `10.90.0.1/24`), runs the up path, reserves the next free tunnel address for `<name>`, and prints one line `cbox wg client join <token>`. The token holds only public data (server public key, endpoint, both tunnel addresses). The endpoint is the detected LAN IPv4 of this host unless `--endpoint HOST:PORT` is given; for internet access use a public IP or DDNS name there (and the router must forward the UDP port to this host).
- With `<pubkey>`: accepts the client's public key under `<name>` (the line a client prints after `cbox wg client join <token>`). The client's waiting check (up to 180 s) then reports OK. cbox sessions on the client reach this host's ollama at `http://wg-remote-ollama:11434` (a project on the client needs `CBOX_WG_CLIENT_ATTACH=on`).
- `--plain`: instead of a join line, prints a ready WireGuard config for a client without cbox (for example the Windows WireGuard app) whose `PrivateKey` line points to a key file saved on this host (that key is never printed); move the file's content to the client, import the config, then test `curl http://10.90.0.1:11434/api/tags`.
- `--yes`: skips the y/N question on every sudo action in the up path.

### `cbox wg client join <token> [--yes]`

Run on the client machine: paste the line a server printed from `cbox wg server add-client <name>`. It configures the client role, generates the client's own key, runs the up path, and prints one line `cbox wg server add-client <name> <pubkey>` to paste back on the server. It then waits up to 180 s for the handshake and tests the remote ollama. `--yes` skips the y/N question on every sudo action in the up path; it also skips the pairing token confirmation prompt itself and, without asking, replaces an already-configured `CBOX_WG_PEER_PUBKEY` with the token's public key - only pass it once you trust the token's source.

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

Print a ready-to-paste config for the named peer: `[Interface] Address = <the peer's own tunnel address>`, then `[Peer]` with this node's public key, this node's own tunnel address as the `AllowedIPs` `/32` (the block describes this node from the peer's side), and an `Endpoint` line only when the peer is server-role (it dials this node) - a client-role peer (added with its own `--endpoint`) gets no `Endpoint` line, since this node dials it instead. If `CBOX_WG_PUBLISH_ADDR` is empty or `0.0.0.0`, plain `peer config` keeps a placeholder Endpoint (`<this node's reachable address>:<port>`) rather than guessing; a peer over the internet must use this host's public IP or DDNS name instead. LAN-IPv4 auto-detection with a fallback to that placeholder only happens on the `add-client`/`--plain` pairing path, not on plain `peer config`.

Without `--generate-key`, no private key is involved; `[Interface]` notes that the peer uses its own privately generated key.

With `--generate-key`, generates the peer's own private key locally and writes it to a `0600` file (`peer-<name>.key`) under `~/.config/cbox/infra/wireguard-peer-keys` - a sibling of the wireguard key directory, outside the directory mounted into the sidecar - instead of printing it (stdout would land in session transcripts and shell history). Refuses instead of overwriting if a key file already exists for that peer name. Move that file to the peer's machine and delete it here; `cbox wg peer rm <name>` deletes it too. The preferred path remains: the peer generates its own key and sends you only the public key.

## Design constraints

The sidecar is built to forward exactly one TCP service (ollama) and never route arbitrary traffic. Enforcement:

- The startup script asserts `net.ipv4.ip_forward=0` before bringing the interface up.
- The startup script asserts every `AllowedIPs` entry is a `/32` (single host).
- The sidecar joins a per-scope cbox network only under `CBOX_WG_CLIENT_ATTACH=on`, and then only as an aliased fixed-destination forwarder hub; it still routes nothing.
- Two forwarders (server and client, depending on role) listen on fixed addresses and forward to fixed destinations.

A misconfiguration cannot silently turn the sidecar into a router.

## Release gate

This feature has NOT been exercised against a live two-machine tunnel with end-to-end model inference. The documentation and code are statically verified; live testing on a real host with two machines and a running ollama service is required before this is considered production-ready. Once you confirm a setup like the scenarios above works end to end, the foundation is proven.
