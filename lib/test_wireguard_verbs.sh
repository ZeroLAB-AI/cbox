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
OTHER_PUBKEY="cRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs="

grep -q 'wg) shift; wg_cmd "\$@";;' "$INSTALL_DIR/cbox" || _fail "wg verb not wired into the dispatcher"
grep -q 'wg {status|up|down|keygen|peer {add|rm|list|config}}' "$INSTALL_DIR/cbox" || _fail "wg missing from usage text"
grep -q 'HUB_ROWS+=("wg")' "$INSTALL_DIR/cbox" || _fail "wg row missing from the hub"
grep -q 'wg) _hub_wg_submenu' "$INSTALL_DIR/cbox" || _fail "wg row not dispatched in the hub"
_ok "wiring: dispatcher, usage, hub row and hub dispatch all present"

awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_wg_guard' \
  || _fail "wg_cmd does not call the off-guard for state-changing subcommands"
awk '/^_cbox_wg_guard\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_wg_active' \
  || _fail "_cbox_wg_guard does not check _cbox_wg_active (CBOX_WG_MODE)"
_ok "guard: wg verbs refuse with a clear message when the feature is off"

awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_config_in_container' \
  || _fail "wg_cmd does not refuse to run inside a container"
_ok "guard: wg is host-only, mirroring ollama and netaccess"

for sub in status up down keygen peer; do
  awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q "$sub" \
    || _fail "wg_cmd case statement missing '$sub'"
done
for psub in add rm list config; do
  awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q "$psub" \
    || _fail "wg_cmd peer case statement missing '$psub'"
done
_ok "wg_cmd recognizes status, up, down, keygen, and peer {add|rm|list|config}"

awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eq 'flock -x( -w [0-9]+)? 6' \
  || _fail "wg_cmd does not take an exclusive machine-level lock for state-changing verbs"
awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eq 'flock -s( -w [0-9]+)? 6' \
  || _fail "wg_cmd does not take a shared lock for status"
awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q -- '-w 30' \
  || _fail "wg_cmd flocks should carry a wait timeout, not block forever"
_ok "locking: state-changing verbs hold a timed exclusive machine lock, status/list/config take a timed shared lock"

awk '/^wg_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_ollama_lock_file' \
  || _fail "wg_cmd does not use the same machine lock file as ollama_cmd - the two features must not be able to race"
_ok "locking: wg_cmd takes the same lock file as ollama_cmd, so the two features cannot race on the shared infra project"

awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'OFF' \
  || _fail "wg status does not report OFF"
awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'CONFIG-ONLY' \
  || _fail "wg status does not report CONFIG-ONLY"
awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'ACTIVE' \
  || _fail "wg status does not report ACTIVE"
_ok "status: distinguishes OFF, CONFIG-ONLY, and ACTIVE"

awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eq 'implementation' \
  || _fail "wg status does not report the implementation actually in use (kernel or userspace)"
awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eq 'listen_port' \
  || _fail "wg status does not report the listen port"
awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eq 'handshake' \
  || _fail "wg status does not report peer handshakes"
awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eqi 'rootless.*(port forwarder|endpoint)|endpoint.*rootless' \
  || _fail "wg status does not note the rootless port-forwarder endpoint caveat"
_ok "status: reports interface/implementation/listen port/peer handshakes and notes the rootless endpoint caveat"

awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eiq 'privatekey|private.key|PrivateKey' \
  && _fail "wg status must never reference private key material"
awk '/^_cbox_wg_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'wg show' \
  || _fail "wg status does not query the running interface for handshake data"
_ok "status: never touches private key material, queries the live interface via 'wg show'"

peer_env() {
  local home="$1"
  shift
  mkdir -p "$home"
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$home"
    "$@"
  )
}

PEERHOME="$TMPBASE/peers"
mkdir -p "$PEERHOME"

peer_env "$PEERHOME" _cbox_wg_peer_add laptop "$VALID_PUBKEY" "10.90.0.3/32"
peer_env "$PEERHOME" _cbox_wg_peer_list | grep -q '^laptop|' || _fail "peer add: peer was not written to the store"
_ok "peer add: a valid peer (name, pubkey, /32 address) is accepted and stored"

if peer_env "$PEERHOME" _cbox_wg_peer_add laptop "$OTHER_PUBKEY" "10.90.0.4/32" 2>/dev/null; then
  _fail "peer add: duplicate name must be refused"
fi
out="$(peer_env "$PEERHOME" _cbox_wg_peer_add laptop "$OTHER_PUBKEY" "10.90.0.4/32" 2>&1 || true)"
echo "$out" | grep -qi 'already exists' || _fail "peer add: duplicate-name rejection must explain why: $out"
_ok "peer add: refuses a duplicate peer name"

out="$(peer_env "$PEERHOME" _cbox_wg_peer_add desktop "$VALID_PUBKEY" "10.90.0.5/32" 2>&1 || true)"
echo "$out" | grep -qi 'already registered' || _fail "peer add: duplicate-pubkey rejection must explain why: $out"
_ok "peer add: refuses a duplicate public key under a different name"

out="$(peer_env "$PEERHOME" _cbox_wg_peer_add wide "$OTHER_PUBKEY" "10.90.0.0/24" 2>&1 || true)"
echo "$out" | grep -qi 'single host' || _fail "peer add: non-/32 rejection must explain the security reasoning: $out"
peer_env "$PEERHOME" _cbox_wg_peer_list | grep -q '^wide|' && _fail "peer add: a rejected wide-CIDR peer must not be written to the store"
_ok "peer add: refuses a non-host (non-/32) allowed address, explaining that a wider range would let one peer claim another's address"

out="$(peer_env "$PEERHOME" _cbox_wg_peer_add 'bad name!' "$OTHER_PUBKEY" "10.90.0.6/32" 2>&1 || true)"
echo "$out" | grep -qi 'name' || _fail "peer add: bad name rejection must mention the name: $out"
_ok "peer add: refuses a malformed peer name"

out="$(peer_env "$PEERHOME" _cbox_wg_peer_add badkey 'not-a-valid-key' "10.90.0.7/32" 2>&1 || true)"
echo "$out" | grep -qi 'public key' || _fail "peer add: bad key rejection must mention the key: $out"
_ok "peer add: refuses a malformed public key"

peer_env "$PEERHOME" _cbox_wg_peer_remove laptop
peer_env "$PEERHOME" _cbox_wg_peer_list | grep -q '^laptop|' && _fail "peer rm: peer was not removed from the store"
_ok "peer rm: removes an existing peer from the store"

if peer_env "$PEERHOME" _cbox_wg_peer_remove laptop 2>/dev/null; then
  _fail "peer rm: removing an already-removed (unknown) peer must fail"
fi
out="$(peer_env "$PEERHOME" _cbox_wg_peer_remove ghost 2>&1 || true)"
echo "$out" | grep -qi 'no peer named' || _fail "peer rm: unknown-name rejection must name the peer: $out"
_ok "peer rm: refuses an unknown peer name"

awk '/^_cbox_wg_peer_add_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_wg_reload_or_restart' \
  || _fail "peer add verb does not reload/restart the sidecar after writing the peer"
awk '/^_cbox_wg_peer_rm_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_wg_reload_or_restart' \
  || _fail "peer rm verb does not reload/restart the sidecar after removing the peer"
_ok "peer add/rm verbs regenerate the config and reload (or restart, naming it) the running interface"

awk '/^_cbox_wg_reload_or_restart\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'wg syncconf' \
  || _fail "reload path does not attempt an in-place peer sync (wg syncconf) before falling back to a restart"
awk '/^_cbox_wg_reload_or_restart\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'restart wireguard' \
  || _fail "reload path does not fall back to restarting the wireguard service"
awk '/^_cbox_wg_reload_or_restart\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -qi 'restarting the wireguard sidecar instead' \
  || _fail "reload path does not say so when it falls back to a restart"
_ok "reload path: tries in-place peer sync first (wg syncconf, does not drop other peers), falls back to a restart and says so"

WGBINDIR="$TMPBASE/wgbin"
mkdir -p "$WGBINDIR"
cat > "$WGBINDIR/wg" <<'WGEOF'
#!/bin/sh
case "$1" in
  genkey) echo "cGwWRIbAQD8FKgYYs8gyRcgJelPeQ7WPfFdBIRO4EEo=" ;;
  pubkey) echo "aRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" ;;
esac
WGEOF
chmod +x "$WGBINDIR/wg"

awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_wg_pubkey' \
  || _fail "peer config verb does not read this node's own public key"
awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'PublicKey = \$my_pub' \
  || _fail "peer config output does not include this node's public key"
awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'Endpoint = ' \
  || _fail "peer config output does not include this node's endpoint"
awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'AllowedIPs = \$paddr' \
  || _fail "peer config output does not include the peer's own allowed address"
awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eiq 'privatekey|PrivateKey' \
  || _fail "peer config generate-key path (optional) must exist to test the never-by-default private key path"
_ok "peer config: prints this node's public key, endpoint, and the peer's allowed address"

awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" \
  | awk '/generate-key/,0' | grep -q 'PrivateKey' \
  || _fail "peer config only ever emits PrivateKey inside the --generate-key branch"
awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eiq 'preferred|preference' \
  || _fail "peer config does not document that the peer generating its own key is preferred"
_ok "peer config: generating the peer's private key locally is optional (--generate-key) and the docs/output state the peer-generates-its-own-key preference"

PEER_CONFIG_CMD_FN="$(awk '/^_cbox_wg_peer_config_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
[ -n "$PEER_CONFIG_CMD_FN" ] || _fail "cannot extract _cbox_wg_peer_config_cmd from cbox"

CFGHOME2="$TMPBASE/config-out2"
mkdir -p "$CFGHOME2"
(
  set -e
  cd "$TMPBASE"
  source "$INSTALL_DIR/templates/generators.sh"
  eval "$PEER_CONFIG_CMD_FN"
  export HOME="$CFGHOME2"
  export PATH="$WGBINDIR:$PATH"
  _cbox_wg_ensure_keys
  _cbox_wg_peer_add laptop "$VALID_PUBKEY" "10.90.0.3/32"
  export CBOX_WG_PUBLISH_ADDR=203.0.113.9 CBOX_WG_LISTEN_PORT=51820 CBOX_WG_KEEPALIVE=25
  _cbox_wg_peer_config_cmd laptop > "$TMPBASE/peerconfig.out" 2>&1
)
grep -q "PublicKey = $(cat "$CFGHOME2/.config/cbox/infra/wireguard/publickey")" "$TMPBASE/peerconfig.out" \
  || _fail "peer config live run: output does not carry this node's real public key"
grep -q 'AllowedIPs = 10.90.0.3/32' "$TMPBASE/peerconfig.out" || _fail "peer config live run: missing the peer's allowed address"
grep -q 'Endpoint = 203.0.113.9:51820' "$TMPBASE/peerconfig.out" || _fail "peer config live run: missing this node's endpoint"
! grep -qi 'PrivateKey' "$TMPBASE/peerconfig.out" || _fail "peer config live run (no --generate-key): must never print a private key"
_ok "peer config output (live run): contains the public key, endpoint, and peer allowed address; never a private key when --generate-key is not passed"

for fn in _cbox_wg_status_cmd _cbox_wg_up_cmd _cbox_wg_down_cmd _cbox_wg_keygen_cmd _cbox_wg_peer_add_cmd _cbox_wg_peer_rm_cmd _cbox_wg_peer_list_cmd _cbox_wg_peer_config_cmd; do
  grep -q "^$fn() {" "$INSTALL_DIR/cbox" || _fail "expected implementation function $fn missing"
done
_ok "every documented verb has a backing implementation function"

awk '/^_cbox_ollama_reconcile_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_wg_ensure_keys' \
  || _fail "ollama reconcile (the shared infra apply path) does not ensure wireguard keys exist"
awk '/^_cbox_ollama_reconcile_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'gen_wireguard_conf' \
  || _fail "ollama reconcile does not regenerate the wireguard config"
_ok "infra reconcile: bringing the shared owner project up also restores the wireguard interface config"

awk '/^gc\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'cbox.kind=isolated' \
  || _fail "gc() must still filter strictly on cbox.kind=isolated (never touch the infra owner, wireguard included)"
_ok "regression: gc() still filters strictly on cbox.kind=isolated - the wireguard sidecar (cbox.kind=infra) is structurally unreachable"

echo "PASS: all wireguard verb checks"
