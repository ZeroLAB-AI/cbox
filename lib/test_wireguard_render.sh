#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

bash -n "$INSTALL_DIR/cbox" || _fail "cbox fails bash -n"
bash -n "$INSTALL_DIR/templates/generators.sh" || _fail "generators.sh fails bash -n"
_ok "bash -n clean on cbox and templates/generators.sh"

VALID_PUBKEY="aRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs="
PEER_PUBKEY="bRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs="

render() {
  local home="$1" ownerdir="$2" mode="$3"
  shift 3
  mkdir -p "$home" "$ownerdir"
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_OLLAMA_MODE=on CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off \
      CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434 CBOX_OLLAMA_NUM_PARALLEL=1
    export CBOX_WG_MODE="$mode"
    export "$@"
    gen_ollama_owner_compose_into "$ownerdir"
    gen_wireguard_conf
  )
}

add_peer() {
  local home="$1" name="$2" pubkey="$3" addr="$4"
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    mkdir -p "$home"
    _cbox_wg_peer_add "$name" "$pubkey" "$addr"
  )
}

OFFHOME="$TMPBASE/off/home"
OFFOWNER="$TMPBASE/off/owner"
mkdir -p "$OFFOWNER"
touch "$OFFOWNER/marker-should-be-untouched"
render "$OFFHOME" "$OFFOWNER" off CBOX_WG_IMPL=auto
! grep -q 'wireguard:' "$OFFOWNER/docker-compose.yml" || _fail "off: wireguard service must not be rendered"
! grep -q 'wg-egress' "$OFFOWNER/docker-compose.yml" || _fail "off: wg-egress network must not be rendered"
[ ! -f "$OFFHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl" ] || _fail "off: no wireguard config file should be rendered"
_ok "off: no wireguard service, no wg-egress network, no rendered wireguard config file"

SRVHOME="$TMPBASE/server/home"
SRVOWNER="$TMPBASE/server/owner"
add_peer "$SRVHOME" laptop "$VALID_PUBKEY" "10.90.0.3/32"
render "$SRVHOME" "$SRVOWNER" server \
  CBOX_WG_IMPL=auto CBOX_WG_ADDRESS=10.90.0.1/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR=198.51.100.7 \
  CBOX_WG_PEER_ENDPOINT= CBOX_WG_PEER_PUBKEY= CBOX_WG_PEER_ADDRESS= CBOX_WG_KEEPALIVE=25

COMPOSE="$SRVOWNER/docker-compose.yml"
[ -f "$COMPOSE" ] || _fail "server: docker-compose.yml missing"
grep -q '^  wireguard:' "$COMPOSE" || _fail "server: wireguard service missing"
grep -q 'cbox.component: wireguard$' "$COMPOSE" || _fail "server: wireguard component label missing"
grep -q 'NET_ADMIN' "$COMPOSE" || _fail "server: NET_ADMIN capability missing"
grep -q '/dev/net/tun:/dev/net/tun' "$COMPOSE" || _fail "server: tun device missing"
! grep -Eq '[0-9]+:[0-9]+/tcp' "$COMPOSE" || _fail "server: must never publish a TCP port"
grep -Eq '"198\.51\.100\.7:51820:51820/udp"' "$COMPOSE" || _fail "server: UDP port 51820 must be published on the configured publish address only"
! grep -Eq '"0\.0\.0\.0:|"::' "$COMPOSE" || _fail "server: must never publish on a wildcard address"
grep -q 'wg-egress: {}' "$COMPOSE" || _fail "server: wireguard service must join wg-egress network"
grep -q '^  wg-egress:' "$COMPOSE" || _fail "server: wg-egress network stanza missing"
grep -A2 '^  wg-egress:' "$COMPOSE" | grep -q 'internal: false' || _fail "server: wg-egress must be the externally routed network (internal: false)"
! grep -q 'aliases:' "$COMPOSE" || _fail "server: must not carry the client alias when the client role is off"
_ok "server mode: wireguard service rendered with NET_ADMIN, tun device, no TCP port, UDP port on wg-egress, no client alias"

WGCONF="$SRVHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl"
[ -f "$WGCONF" ] || _fail "server: wireguard config not rendered"
grep -q '^\[Interface\]' "$WGCONF" || _fail "server config: missing [Interface]"
grep -q '^Address = 10.90.0.1/24' "$WGCONF" || _fail "server config: missing this node's tunnel address"
grep -q '^ListenPort = 51820' "$WGCONF" || _fail "server config: missing ListenPort"
grep -q '^PrivateKey = __CBOX_WG_PRIVATE_KEY__' "$WGCONF" || _fail "server config: private key must be a placeholder, never the real key material"
grep -q '^\[Peer\]' "$WGCONF" || _fail "server config: missing peer stanza"
grep -q '^# laptop' "$WGCONF" || _fail "server config: peer stanza missing the stored peer name comment"
grep -q "^PublicKey = $VALID_PUBKEY" "$WGCONF" || _fail "server config: peer public key missing"
grep -q '^AllowedIPs = 10.90.0.3/32' "$WGCONF" || _fail "server config: peer allowed address missing"
! grep -q '^Endpoint' "$WGCONF" || _fail "server config: server role must not carry a remote Endpoint line"
_ok "server config: [Interface] carries Address/ListenPort/placeholder key, one [Peer] stanza per stored peer"

perm="$(stat -c '%a' "$WGCONF")"
[ "$perm" = "644" ] || _fail "server config template perms: got $perm want 644 (the real runtime config with the injected key is what must be 0600, not this template)"
_ok "server config template: rendered at 0644 (contains only a placeholder, never the real private key)"

CLIHOME="$TMPBASE/client/home"
CLIOWNER="$TMPBASE/client/owner"
render "$CLIHOME" "$CLIOWNER" client \
  CBOX_WG_IMPL=userspace CBOX_WG_ADDRESS=10.90.0.2/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR=198.51.100.7 \
  CBOX_WG_PEER_ENDPOINT=remote.example:51820 CBOX_WG_PEER_PUBKEY="$PEER_PUBKEY" CBOX_WG_PEER_ADDRESS=10.90.0.1/32 CBOX_WG_KEEPALIVE=25

COMPOSE="$CLIOWNER/docker-compose.yml"
[ -f "$COMPOSE" ] || _fail "client: docker-compose.yml missing"
grep -q '^  wireguard:' "$COMPOSE" || _fail "client: wireguard service missing"
! grep -Eq '[0-9]+:[0-9]+/tcp' "$COMPOSE" || _fail "client: must never publish a TCP port"
! grep -Eq '[0-9]+:[0-9]+/udp' "$COMPOSE" || _fail "client: must never publish the UDP port (no inbound listener in client-only mode)"
grep -q '^  wg-egress:' "$COMPOSE" || _fail "client: wg-egress network must exist in client-only mode (the sidecar dials out to the remote endpoint)"
grep -q 'aliases:' "$COMPOSE" || _fail "client: must carry the stable service alias for the client-role forwarder"
grep -q '\- wg-remote-ollama' "$COMPOSE" || _fail "client: alias must be wg-remote-ollama"
_ok "client mode: wireguard service rendered with the stable alias, no UDP port, wg-egress network present (outbound dial only), no TCP port"

WGCONF="$CLIHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl"
[ -f "$WGCONF" ] || _fail "client: wireguard config not rendered"
! grep -q '^ListenPort' "$WGCONF" || _fail "client config: client-only role must not carry a ListenPort"
grep -q '^\[Peer\]' "$WGCONF" || _fail "client config: missing the remote peer stanza"
grep -q "^PublicKey = $PEER_PUBKEY" "$WGCONF" || _fail "client config: remote peer public key missing"
grep -q '^AllowedIPs = 10.90.0.1/32' "$WGCONF" || _fail "client config: remote peer allowed address missing"
grep -q '^Endpoint = remote.example:51820' "$WGCONF" || _fail "client config: remote peer endpoint missing"
grep -q '^PersistentKeepalive = 25' "$WGCONF" || _fail "client config: keepalive missing"
_ok "client config: carries the remote peer stanza with endpoint, allowed address, and keepalive; no ListenPort"

BOTHHOME="$TMPBASE/both/home"
BOTHOWNER="$TMPBASE/both/owner"
add_peer "$BOTHHOME" laptop "$VALID_PUBKEY" "10.90.0.3/32"
render "$BOTHHOME" "$BOTHOWNER" both \
  CBOX_WG_IMPL=auto CBOX_WG_ADDRESS=10.90.0.1/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR=203.0.113.9 \
  CBOX_WG_PEER_ENDPOINT=remote.example:51820 CBOX_WG_PEER_PUBKEY="$PEER_PUBKEY" CBOX_WG_PEER_ADDRESS=10.90.0.9/32 CBOX_WG_KEEPALIVE=0

COMPOSE="$BOTHOWNER/docker-compose.yml"
grep -q 'aliases:' "$COMPOSE" || _fail "both: must carry the client alias"
grep -q '\- wg-remote-ollama' "$COMPOSE" || _fail "both: alias must be wg-remote-ollama"
grep -Eq '"203\.0\.113\.9:51820:51820/udp"' "$COMPOSE" || _fail "both: UDP port must honour the configured publish address"
! grep -Eq '[0-9]+:[0-9]+/tcp' "$COMPOSE" || _fail "both: must never publish a TCP port"
grep -q 'wg-egress: {}' "$COMPOSE" || _fail "both: must join wg-egress (server role active)"
_ok "both mode: server UDP port honours CBOX_WG_PUBLISH_ADDR, client alias still present, no TCP port"

WGCONF="$BOTHHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl"
grep -q '^ListenPort = 51820' "$WGCONF" || _fail "both config: server role must carry ListenPort"
grep -q '^# laptop' "$WGCONF" || _fail "both config: server role must carry the stored peer stanza"
grep -q "^PublicKey = $PEER_PUBKEY" "$WGCONF" || _fail "both config: client role must carry the remote peer stanza"
grep -q '^Endpoint = remote.example:51820' "$WGCONF" || _fail "both config: client role must carry the remote endpoint"
! grep -q '^PersistentKeepalive' "$WGCONF" || _fail "both config: keepalive=0 must disable the PersistentKeepalive line"
_ok "both config: carries the server ListenPort + stored peer stanza AND the client remote-peer stanza in one file"

for label in server client both; do
  case "$label" in
    server) c="$SRVOWNER/docker-compose.yml" ;;
    client) c="$CLIOWNER/docker-compose.yml" ;;
    both) c="$BOTHOWNER/docker-compose.yml" ;;
  esac
  grep -q '/etc/cbox-generated/wireguard:ro' "$c" || _fail "$label: key material mount must be read-only"
done
_ok "key mount: every mode mounts the key material directory read-only into the sidecar"

HASH1="$TMPBASE/hash1"
HASH2="$TMPBASE/hash2"
render "$TMPBASE/hash1home" "$HASH1" server CBOX_WG_IMPL=auto CBOX_WG_ADDRESS=10.90.0.1/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR=198.51.100.7 CBOX_WG_PEER_ENDPOINT= CBOX_WG_PEER_PUBKEY= CBOX_WG_PEER_ADDRESS= CBOX_WG_KEEPALIVE=25
render "$TMPBASE/hash2home" "$HASH2" server CBOX_WG_IMPL=userspace CBOX_WG_ADDRESS=10.90.0.1/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR=198.51.100.7 CBOX_WG_PEER_ENDPOINT= CBOX_WG_PEER_PUBKEY= CBOX_WG_PEER_ADDRESS= CBOX_WG_KEEPALIVE=25
TAG1="$(grep -oE 'cbox-wg-img:[0-9a-f]+' "$HASH1/docker-compose.yml")"
[ -n "$TAG1" ] || _fail "image hash: could not extract cbox-wg-img tag"
grep -q "$(cat "$HASH1/wireguard-build/Dockerfile.wireguard" "$HASH1/wireguard-build/supervisord.wireguard.conf" "$HASH1/wireguard-build/wg-up.sh" | sha256sum | awk '{print substr($1,1,12)}')" "$HASH1/docker-compose.yml" \
  || _fail "image hash: tag does not match sha256 of Dockerfile+supervisord+wg-up.sh build inputs"
_ok "image input hashing: cbox-wg-img tag is derived from Dockerfile.wireguard + supervisord.wireguard.conf + wg-up.sh, same pattern as the proxy image"

DF="$HASH1/wireguard-build/Dockerfile.wireguard"
[ -f "$DF" ] || _fail "Dockerfile.wireguard not rendered"
grep -q 'wireguard-tools' "$DF" || _fail "Dockerfile.wireguard missing wireguard-tools"
grep -q 'wireguard-go' "$DF" || _fail "Dockerfile.wireguard missing the userspace implementation (wireguard-go)"
grep -q 'socat' "$DF" || _fail "Dockerfile.wireguard missing the TCP forwarder utility (socat)"
grep -q 'supervisor' "$DF" || _fail "Dockerfile.wireguard missing supervisor"
_ok "Dockerfile.wireguard: installs wireguard-tools, wireguard-go (userspace fallback), socat, supervisor"

SUP_SERVER="$SRVOWNER/wireguard-build/supervisord.wireguard.conf"
grep -q '\[program:wg-forward-server\]' "$SUP_SERVER" || _fail "server supervisord: missing wg-forward-server program"
! grep -q '\[program:wg-forward-client\]' "$SUP_SERVER" || _fail "server supervisord: must not run the client forwarder in server-only mode"

SUP_CLIENT="$CLIOWNER/wireguard-build/supervisord.wireguard.conf"
grep -q '\[program:wg-forward-client\]' "$SUP_CLIENT" || _fail "client supervisord: missing wg-forward-client program"
! grep -q '\[program:wg-forward-server\]' "$SUP_CLIENT" || _fail "client supervisord: must not run the server forwarder in client-only mode"

SUP_BOTH="$BOTHOWNER/wireguard-build/supervisord.wireguard.conf"
grep -q '\[program:wg-forward-server\]' "$SUP_BOTH" || _fail "both supervisord: missing wg-forward-server program"
grep -q '\[program:wg-forward-client\]' "$SUP_BOTH" || _fail "both supervisord: missing wg-forward-client program"
_ok "supervisord: server role runs only the server forwarder, client role runs only the client forwarder, both runs both"

grep -q 'TCP:ollama:11434' "$SUP_SERVER" || _fail "server forwarder: must forward to the ollama service on the infra network, not elsewhere"
grep -q 'TCP-LISTEN:11434,bind=10.90.0.1' "$SUP_SERVER" || _fail "server forwarder: must accept only on the tunnel address, not all interfaces"
_ok "server forwarder: accepts TCP on the tunnel address only, forwards to the ollama service by its infra-network name"

CUSTOMPORTHOME="$TMPBASE/server_custom_port/home"
CUSTOMPORTOWNER="$TMPBASE/server_custom_port/owner"
render "$CUSTOMPORTHOME" "$CUSTOMPORTOWNER" server \
  CBOX_WG_IMPL=auto CBOX_WG_ADDRESS=10.90.0.1/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR=198.51.100.7 \
  CBOX_WG_PEER_ENDPOINT= CBOX_WG_PEER_PUBKEY= CBOX_WG_PEER_ADDRESS= CBOX_WG_KEEPALIVE=25 \
  CBOX_OLLAMA_PORT=11500
SUP_CUSTOMPORT="$CUSTOMPORTOWNER/wireguard-build/supervisord.wireguard.conf"
grep -q 'TCP:ollama:11434' "$SUP_CUSTOMPORT" || _fail "server forwarder: forward target must be hardcoded to the ollama container's real listen port (11434) regardless of CBOX_OLLAMA_PORT"
! grep -q 'TCP:ollama:11500' "$SUP_CUSTOMPORT" || _fail "server forwarder: forward target must not follow CBOX_OLLAMA_PORT (a host-side probe setting, not the in-container port) - the ollama container always listens on 11434"
_ok "server forwarder: forward target stays hardcoded to 11434 even when CBOX_OLLAMA_PORT is set to a different value"

grep -q 'TCP:10.90.0.1:11434' "$SUP_CLIENT" || _fail "client forwarder: must forward to the remote tunnel address"
grep -q 'TCP-LISTEN:11434,bind=wg-remote-ollama' "$SUP_CLIENT" || _fail "client forwarder: must accept only on the infra-network alias, not all interfaces"
_ok "client forwarder: accepts TCP on the infra network under the stable alias only, forwards over the tunnel to the remote endpoint"

for f in "$DF" "$SUP_SERVER" "$SUP_CLIENT" "$SUP_BOTH" "$SRVOWNER/wireguard-build/wg-up.sh"; do
  ! grep -qiE 'iptables|ip_forward\s*=\s*1|MASQUERADE|ip route add|sysctl.*forward' "$f" \
    || _fail "no-routing: $f contains a forbidden routing/NAT/forwarding construct"
done
_ok "no-routing: no iptables rule, no ip_forward=1, no MASQUERADE, no route-add, no forwarding sysctl anywhere in the rendered sidecar files"

WGUP="$SRVOWNER/wireguard-build/wg-up.sh"
sh -n "$WGUP" || _fail "wg-up.sh fails sh -n"
grep -q 'ip_forward' "$WGUP" || _fail "wg-up.sh: missing the startup assertion that IP forwarding is off"
grep -q 'AllowedIPs' "$WGUP" || _fail "wg-up.sh: missing the startup assertion that AllowedIPs entries are host addresses"
grep -q '\*/32' "$WGUP" || _fail "wg-up.sh: host-address assertion must check for /32, not just presence of AllowedIPs"
_ok "wg-up.sh: startup asserts IP forwarding is off and every AllowedIPs entry is a /32 host address, sh -n clean"

grep -q 'WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go' "$WGUP" || _fail "wg-up.sh: userspace fallback must set WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go"
grep -q 'unset WG_QUICK_USERSPACE_IMPLEMENTATION' "$WGUP" || _fail "wg-up.sh: kernel path must unset the userspace override"
grep -q '/sys/module/wireguard' "$WGUP" || _fail "wg-up.sh: auto mode must probe for the kernel wireguard module"
_ok "wg-up.sh: auto probes the kernel module then falls back to userspace; kernel/userspace force the choice explicitly via CBOX_WG_IMPL"

for tpl in "$SRVHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl" "$CLIHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl" "$BOTHHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl"; do
  grep -q '__CBOX_WG_PRIVATE_KEY__' "$tpl" || _fail "$tpl: private key must be a placeholder token, injected at container start"
  ! grep -Eq '^PrivateKey = [A-Za-z0-9+/]{40,}=' "$tpl" || _fail "$tpl: a real-looking private key must never be written into the rendered template"
done
grep -q 'chmod 0600' "$WGUP" || _fail "wg-up.sh: the assembled runtime config must be created at 0600"
grep -q 'privatekey' "$WGUP" || _fail "wg-up.sh: must read the private key from the mounted key file, not from an env var or embedded literal"
_ok "private key handling: template never carries real key material, wg-up.sh injects it from the mounted file and writes the runtime config at 0600"

_load_no_proxy_hosts() {
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export "$@"
    _cbox_no_proxy_hosts
  )
}

out="$(_load_no_proxy_hosts CBOX_WG_MODE=off CBOX_OLLAMA_MODE=off)"
case ",$out," in
  *,wg-remote-ollama,*) _fail "NO_PROXY: alias must not appear when wireguard is off, got: $out" ;;
esac
_ok "NO_PROXY: wireguard off - alias absent"

out="$(_load_no_proxy_hosts CBOX_WG_MODE=server CBOX_OLLAMA_MODE=off)"
case ",$out," in
  *,wg-remote-ollama,*) _fail "NO_PROXY: alias must not appear in server-only mode (no client forwarder), got: $out" ;;
esac
_ok "NO_PROXY: server-only mode - alias absent (no client-role forwarder exists)"

out="$(_load_no_proxy_hosts CBOX_WG_MODE=client CBOX_OLLAMA_MODE=off)"
case ",$out," in
  *,wg-remote-ollama,*) ;;
  *) _fail "NO_PROXY: alias must appear in client mode, got: $out" ;;
esac
_ok "NO_PROXY: client mode - alias present"

out="$(_load_no_proxy_hosts CBOX_WG_MODE=both CBOX_OLLAMA_MODE=off)"
case ",$out," in
  *,wg-remote-ollama,*) ;;
  *) _fail "NO_PROXY: alias must appear in both mode, got: $out" ;;
esac
_ok "NO_PROXY: both mode - alias present"

render_main_compose_no_proxy() {
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$TMPBASE/noproxyhome"
    mkdir -p "$HOME"
    export CBOX_NETACCESS_MODE=allowlist CBOX_NETACCESS_APPLIED=1
    export CBOX_WG_MODE=client
    _cbox_no_proxy_hosts
  )
}
out="$(render_main_compose_no_proxy)"
case ",$out," in
  *,wg-remote-ollama,*) ;;
  *) _fail "NO_PROXY under egress lockdown must still include the client alias, got: $out" ;;
esac
_ok "NO_PROXY under egress lockdown: client alias included (internal name, genuine direct route)"

REFUSEHOME="$TMPBASE/refuse/home"
REFUSEOWNER="$TMPBASE/refuse/owner"
set +e
render "$REFUSEHOME" "$REFUSEOWNER" server \
  CBOX_WG_IMPL=auto CBOX_WG_ADDRESS=10.90.0.1/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR= \
  CBOX_WG_PEER_ENDPOINT= CBOX_WG_PEER_PUBKEY= CBOX_WG_PEER_ADDRESS= CBOX_WG_KEEPALIVE=25 >/dev/null 2>&1
refuse_rc=$?
set -e
[ "$refuse_rc" -ne 0 ] || _fail "server with an empty publish address must refuse to render, never fall back to a wildcard"
! grep -Eq '"0\.0\.0\.0:|"::' "$REFUSEOWNER/docker-compose.yml" 2>/dev/null \
  || _fail "server with an empty publish address left a wildcard publish in the compose file"
_ok "server with an empty publish address refuses instead of binding every interface"

render_ollama_off() {
  local home="$1" ownerdir="$2" mode="$3"
  shift 3
  mkdir -p "$home" "$ownerdir"
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    export CBOX_OLLAMA_MODE=off
    export CBOX_WG_MODE="$mode"
    export "$@"
    gen_ollama_owner_compose_into "$ownerdir"
    gen_wireguard_conf
  )
}

CLIOFFHOME="$TMPBASE/client_ollama_off/home"
CLIOFFOWNER="$TMPBASE/client_ollama_off/owner"
render_ollama_off "$CLIOFFHOME" "$CLIOFFOWNER" client \
  CBOX_WG_IMPL=auto CBOX_WG_ADDRESS=10.90.0.2/24 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_PUBLISH_ADDR= \
  CBOX_WG_PEER_ENDPOINT=example.com:51820 CBOX_WG_PEER_PUBKEY="$VALID_PUBKEY" CBOX_WG_PEER_ADDRESS=10.90.0.1/32 CBOX_WG_KEEPALIVE=25

CLIOFFCOMPOSE="$CLIOFFOWNER/docker-compose.yml"
[ -f "$CLIOFFCOMPOSE" ] || _fail "client role with ollama off: docker-compose.yml must still be rendered (the wireguard sidecar needs an owner project to run in)"
! grep -q '^  ollama:' "$CLIOFFCOMPOSE" || _fail "client role with ollama off: ollama service must not be rendered"
grep -q '^  wireguard:' "$CLIOFFCOMPOSE" || _fail "client role with ollama off: wireguard service missing"
grep -q 'wg-remote-ollama' "$CLIOFFCOMPOSE" || _fail "client role with ollama off: client alias missing from the wireguard service"
grep -q 'wg-egress:' "$CLIOFFCOMPOSE" || _fail "client role with ollama off: wg-egress network missing"
! grep -q '^volumes:' "$CLIOFFCOMPOSE" || _fail "client role with ollama off: no ollama store volume should be declared"
[ -f "$CLIOFFHOME/.config/cbox/infra/wireguard/cbox0.conf.tpl" ] || _fail "client role with ollama off: wireguard config template must still be rendered"
_ok "client role with ollama off: owner project renders the wireguard sidecar alone (this is the bug the reconcile/up verbs must also honor - see cbox _cbox_ollama_reconcile_cmd)"

echo "PASS: all wireguard render checks"
