#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

for _v in $(env | grep -o '^CBOX_[A-Za-z0-9_]*' || true); do
  unset "$_v"
done

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

_extract() {
  awk "/^$1\\(\\) \\{/,/^}\$/" "$INSTALL_DIR/cbox"
}

PREREQ_FUNCS="$(
  _extract _cbox_wg_tun_present
  _extract _cbox_wg_pkg_manager
  _extract _cbox_wg_install_display
  _extract _cbox_wg_install_run
  _extract _cbox_wg_firewalld_open_port
  _extract _cbox_wg_ufw_allow_port
  _extract _cbox_wg_ufw_allow_display
  _extract _cbox_wg_offer_sudo
  _extract _cbox_wg_ensure_wg_tools
  _extract _cbox_wg_ensure_tun
  _extract _cbox_wg_firewall_active
  _extract _cbox_wg_ensure_firewall_port
  _extract _cbox_wg_ensure_prereqs
  _extract _cbox_wg_up_cmd
  _extract _cbox_wg_reload_or_restart
  _extract _cbox_wg_server_add_client_cmd
  _extract _cbox_wg_client_join_cmd
  _extract _cbox_wg_wait_and_probe
)"
[ -n "$PREREQ_FUNCS" ] || _fail "could not extract wg prereq/pairing functions from cbox"

PEER_CONFIG_CMD_FN="$(
  _extract _cbox_wg_peer_config_cmd
  _extract _cbox_wg_peer_config_impl
)"
[ -n "$PEER_CONFIG_CMD_FN" ] || _fail "could not extract _cbox_wg_peer_config_cmd/_cbox_wg_peer_config_impl from cbox"

RECONCILE_CMD_FN="$(_extract _cbox_ollama_reconcile_cmd)"
[ -n "$RECONCILE_CMD_FN" ] || _fail "could not extract _cbox_ollama_reconcile_cmd from cbox"

STUBBIN="$TMPBASE/stubbin"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/wg" <<'WGEOF'
#!/bin/sh
case "$1" in
  genkey) echo "cGwWRIbAQD8FKgYYs8gyRcgJelPeQ7WPfFdBIRO4EEo=" ;;
  pubkey) echo "aRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs=" ;;
esac
WGEOF
chmod +x "$STUBBIN/wg"

_STUB_PRIVKEY="cGwWRIbAQD8FKgYYs8gyRcgJelPeQ7WPfFdBIRO4EEo="

_write_sudo_stub() {
  local dir="$1" logfile="$2"
  cat > "$dir/sudo" <<EOF
#!/bin/sh
echo "\$*" >> "$logfile"
exec "\$@"
EOF
  chmod +x "$dir/sudo"
}

_write_ip_stub() {
  local path="$1" src="${2:-}"
  if [ -n "$src" ]; then
    cat > "$path" <<EOF
#!/bin/sh
case "\$*" in
  *"route get"*) echo "1.1.1.1 dev eth0 src $src uid 0" ;;
esac
EOF
  else
    cat > "$path" <<'EOF'
#!/bin/sh
exit 1
EOF
  fi
  chmod +x "$path"
}

_write_systemctl_stub() {
  local path="$1" active_unit="${2:-}"
  cat > "$path" <<EOF
#!/bin/sh
if [ "\$1" = "is-active" ]; then
  for a in "\$@"; do
    [ "\$a" = "$active_unit" ] && exit 0
  done
  exit 1
fi
exit 0
EOF
  chmod +x "$path"
}

_common_preamble() {
  cat <<EOF
set -e
source "$INSTALL_DIR/templates/generators.sh"
eval "\$PREREQ_FUNCS"
eval "\$PEER_CONFIG_CMD_FN"
_cbox_ollama_owner_dir() { printf '%s/owner' "\$HOME"; }
_cbox_ollama_reconcile_cmd() { echo "cbox: RECONCILE-CALLED" >> "\$HOME/.reconcile.log"; return 0; }
_cbox_config_set() {
  local pair k v
  for pair in "\$@"; do
    k="\${pair%%=*}"
    v="\${pair#*=}"
    printf '%s\n' "\$pair" >> "\$HOME/.configset.log"
    export "\$k=\$v"
  done
  return 0
}
_cbox_wg_reload_global_conf() { return 0; }
EOF
}

echo "--- prereq gating: wg up ---"

WGUP1="$TMPBASE/wgup1"
mkdir -p "$WGUP1/bin"
_write_sudo_stub "$WGUP1/bin" "$WGUP1/sudo.log"
cat > "$WGUP1/bin/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WGUP1/bin/apt-get"
HOME1="$WGUP1/home"
mkdir -p "$HOME1"
OUT1="$TMPBASE/wgup1.err"
RC1=0
(
  eval "$(_common_preamble)"
  export HOME="$HOME1"
  export PATH="$WGUP1/bin:$PATH"
  export CBOX_WG_MODE=server
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_up_cmd
) > "$TMPBASE/wgup1.out" 2>"$OUT1" || RC1=$?
[ "$RC1" = 1 ] || _fail "wg up with missing wg and no TTY must exit 1 (got $RC1)"
grep -q 'sudo apt-get install -y wireguard-tools' "$OUT1" || _fail "wg up missing-wg message must name the exact install command: $(cat "$OUT1")"
[ ! -s "$WGUP1/sudo.log" ] || _fail "wg up with no TTY and no --yes must never call sudo: $(cat "$WGUP1/sudo.log")"
_ok "wg up: missing wg, no TTY, no --yes -> exit 1, exact command printed, sudo never called"

WGUP2="$TMPBASE/wgup2"
mkdir -p "$WGUP2/bin"
_write_sudo_stub "$WGUP2/bin" "$WGUP2/sudo.log"
cat > "$WGUP2/bin/apt-get" <<EOF
#!/bin/sh
echo "\$*" >> "$WGUP2/aptget.log"
cp "$STUBBIN/wg" "$WGUP2/bin/wg"
chmod +x "$WGUP2/bin/wg"
exit 0
EOF
chmod +x "$WGUP2/bin/apt-get"
HOME2="$WGUP2/home"
mkdir -p "$HOME2"
RC2=0
(
  eval "$(_common_preamble)"
  export HOME="$HOME2"
  export PATH="$WGUP2/bin:$PATH"
  export CBOX_WG_MODE=server
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_up_cmd --yes
) > "$TMPBASE/wgup2.out" 2>"$TMPBASE/wgup2.err" || RC2=$?
[ "$RC2" = 0 ] || _fail "wg up --yes with an installable wg must succeed: $(cat "$TMPBASE/wgup2.err")"
grep -q 'apt-get install -y wireguard-tools' "$WGUP2/sudo.log" || _fail "wg up --yes must run the install through sudo: $(cat "$WGUP2/sudo.log")"
_ok "wg up: missing wg, --yes -> installs via sudo apt-get, exact command runs"

WGUP3="$TMPBASE/wgup3"
mkdir -p "$WGUP3/bin"
_write_sudo_stub "$WGUP3/bin" "$WGUP3/sudo.log"
cp "$STUBBIN/wg" "$WGUP3/bin/wg"
_write_systemctl_stub "$WGUP3/bin/systemctl" "ufw"
HOME3="$WGUP3/home"
mkdir -p "$HOME3"
RC3=0
(
  eval "$(_common_preamble)"
  export HOME="$HOME3"
  export PATH="$WGUP3/bin:$PATH"
  export CBOX_WG_MODE=server
  export CBOX_WG_LISTEN_PORT=51820
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_up_cmd
) > "$TMPBASE/wgup3.out" 2>"$TMPBASE/wgup3.err" || RC3=$?
[ "$RC3" = 0 ] || _fail "wg up must not fail just because ufw is active and there is no TTY: $(cat "$TMPBASE/wgup3.err")"
grep -qi 'ufw is active' "$TMPBASE/wgup3.err" || _fail "wg up must warn about an active ufw: $(cat "$TMPBASE/wgup3.err")"
grep -q 'sudo ufw allow 51820/udp comment cbox-wg' "$TMPBASE/wgup3.err" || _fail "ufw warning must carry the exact command"
[ ! -s "$WGUP3/sudo.log" ] || _fail "ufw offer with no TTY and no --yes must never call sudo: $(cat "$WGUP3/sudo.log")"
_ok "wg up: ufw active, no TTY -> non-fatal warning with the exact command, sudo never called, up continues"

WGUP4="$TMPBASE/wgup4"
mkdir -p "$WGUP4/bin"
_write_sudo_stub "$WGUP4/bin" "$WGUP4/sudo.log"
cp "$STUBBIN/wg" "$WGUP4/bin/wg"
HOME4="$WGUP4/home"
mkdir -p "$HOME4"
RC4=0
(
  eval "$(_common_preamble)"
  export HOME="$HOME4"
  export PATH="$WGUP4/bin:$PATH"
  export CBOX_WG_MODE=client
  _cbox_wg_tun_present() { return 1; }
  _cbox_wg_up_cmd
) > "$TMPBASE/wgup4.out" 2>"$TMPBASE/wgup4.err" || RC4=$?
[ "$RC4" = 1 ] || _fail "wg up with /dev/net/tun missing, no TTY, no --yes must exit 1 (got $RC4)"
grep -q 'sudo modprobe tun' "$TMPBASE/wgup4.err" || _fail "tun-missing message must name the exact command: $(cat "$TMPBASE/wgup4.err")"
[ ! -s "$WGUP4/sudo.log" ] || _fail "tun offer with no TTY and no --yes must never call sudo"
_ok "wg up: /dev/net/tun missing, no TTY, no --yes -> exit 1, exact command printed, sudo never called"

echo "--- server add-client: mode transitions ---"

ACHOME1="$TMPBASE/ac1"
mkdir -p "$ACHOME1/home"
ACBIN1="$TMPBASE/ac1bin"
mkdir -p "$ACBIN1"
cp "$STUBBIN/wg" "$ACBIN1/wg"
RC_AC1=0
(
  eval "$(_common_preamble)"
  export HOME="$ACHOME1/home"
  export PATH="$ACBIN1:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd laptop --endpoint 203.0.113.9:51820
) > "$TMPBASE/ac1.out" 2>"$TMPBASE/ac1.err" || RC_AC1=$?
[ "$RC_AC1" = 0 ] || _fail "server add-client (off -> server) failed: $(cat "$TMPBASE/ac1.err")"
grep -q '^CBOX_WG_MODE=server$' "$ACHOME1/home/.configset.log" || _fail "server add-client must flip CBOX_WG_MODE off -> server: $(cat "$ACHOME1/home/.configset.log" 2>/dev/null)"
grep -q '^CBOX_WG_ADDRESS=10.90.0.1/24$' "$ACHOME1/home/.configset.log" || _fail "server add-client must default CBOX_WG_ADDRESS when empty"
grep -q 'CBOX_WG_MODE: off -> server' "$TMPBASE/ac1.out" || _fail "server add-client must report the CBOX_WG_MODE change as KEY: old -> new"
_ok "server add-client: CBOX_WG_MODE off -> server, CBOX_WG_ADDRESS defaulted, both reported"

ACHOME2="$TMPBASE/ac2"
mkdir -p "$ACHOME2/home"
RC_AC2=0
(
  eval "$(_common_preamble)"
  export HOME="$ACHOME2/home"
  export PATH="$ACBIN1:$PATH"
  export CBOX_WG_MODE=client
  export CBOX_WG_ADDRESS=10.90.0.5/24
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd desktop --endpoint 203.0.113.9:51820
) > "$TMPBASE/ac2.out" 2>"$TMPBASE/ac2.err" || RC_AC2=$?
[ "$RC_AC2" = 0 ] || _fail "server add-client (client -> both) failed: $(cat "$TMPBASE/ac2.err")"
grep -q '^CBOX_WG_MODE=both$' "$ACHOME2/home/.configset.log" || _fail "server add-client must flip CBOX_WG_MODE client -> both: $(cat "$ACHOME2/home/.configset.log" 2>/dev/null)"
! grep -q '^CBOX_WG_ADDRESS=' "$ACHOME2/home/.configset.log" || _fail "server add-client must not touch an already-set CBOX_WG_ADDRESS"
_ok "server add-client: CBOX_WG_MODE client -> both, an already-set CBOX_WG_ADDRESS is left alone"

echo "--- server add-client: name/address/pubkey collisions are checked before the mode switch and wg up ---"

COLHOME="$TMPBASE/collision/home"
mkdir -p "$COLHOME"
(
  source "$INSTALL_DIR/templates/generators.sh"
  export HOME="$COLHOME"
  _cbox_wg_peer_add laptop "$VALID_PUBKEY" 10.90.0.7/32 "" ""
) > "$TMPBASE/collision.seed.out" 2>"$TMPBASE/collision.seed.err" \
  || _fail "could not seed an existing peer for the collision-ordering test: $(cat "$TMPBASE/collision.seed.err")"

RC_COL=0
(
  eval "$(_common_preamble)"
  export HOME="$COLHOME"
  export PATH="$ACBIN1:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd laptop "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
) > "$TMPBASE/collision.out" 2>"$TMPBASE/collision.err" || RC_COL=$?
[ "$RC_COL" = 1 ] || _fail "server add-client must refuse a name that already exists as a peer (got rc=$RC_COL): $(cat "$TMPBASE/collision.out")"
grep -qi 'already exists' "$TMPBASE/collision.err" || _fail "the refusal must explain the name collision: $(cat "$TMPBASE/collision.err")"
[ ! -e "$COLHOME/.configset.log" ] || _fail "a name collision must be caught before the mode switch ever touches config: $(cat "$COLHOME/.configset.log")"
_ok "server add-client: a name collision on the pubkey path is refused before the mode switch or wg up ever run"

echo "--- token round trip: add-client -> client join -> add-client <pubkey> ---"

SRVHOME="$TMPBASE/srv/home"
CLIHOME="$TMPBASE/cli/home"
mkdir -p "$SRVHOME" "$CLIHOME"
TOKBIN="$TMPBASE/tokbin"
mkdir -p "$TOKBIN"
cp "$STUBBIN/wg" "$TOKBIN/wg"

RC_STEP1=0
(
  eval "$(_common_preamble)"
  export HOME="$SRVHOME"
  export PATH="$TOKBIN:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd laptop --endpoint 203.0.113.9:51820
) > "$TMPBASE/step1.out" 2>"$TMPBASE/step1.err" || RC_STEP1=$?
[ "$RC_STEP1" = 0 ] || _fail "step1 (server add-client, no pubkey) failed: $(cat "$TMPBASE/step1.err")"
TOKEN="$(grep -o 'cbx1\.[A-Za-z0-9_-]*' "$TMPBASE/step1.out" | head -n1)"
[ -n "$TOKEN" ] || _fail "step1 did not print a pairing token: $(cat "$TMPBASE/step1.out")"
grep -q "wg client join $TOKEN" "$TMPBASE/step1.out" || _fail "step1 must print the exact 'wg client join <token>' line to paste on the client"
_ok "server add-client (no pubkey): reserves an address and prints a pairing token"

RC_STEP1B=0
(
  eval "$(_common_preamble)"
  export HOME="$SRVHOME"
  export PATH="$TOKBIN:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd laptop --endpoint 203.0.113.9:51820
) > "$TMPBASE/step1b.out" 2>"$TMPBASE/step1b.err" || RC_STEP1B=$?
[ "$RC_STEP1B" = 0 ] || _fail "step1b (rerun, reservation reuse) failed: $(cat "$TMPBASE/step1b.err")"
TOKEN2="$(grep -o 'cbx1\.[A-Za-z0-9_-]*' "$TMPBASE/step1b.out" | head -n1)"
[ "$TOKEN2" = "$TOKEN" ] || _fail "rerunning server add-client for the same unresolved name must reuse the same reservation (same token): first=$TOKEN second=$TOKEN2"
_ok "server add-client: rerun with the same unresolved name reuses the reserved address (identical token)"

RC_STEP2=0
(
  eval "$(_common_preamble)"
  export HOME="$CLIHOME"
  export PATH="$TOKBIN:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_client_join_cmd "$TOKEN"
) > "$TMPBASE/step2.out" 2>"$TMPBASE/step2.err" || RC_STEP2=$?
[ "$RC_STEP2" = 0 ] || _fail "step2 (client join) failed: $(cat "$TMPBASE/step2.err")"
grep -q '^CBOX_WG_MODE=client$' "$CLIHOME/.configset.log" || _fail "client join must set CBOX_WG_MODE=client: $(cat "$CLIHOME/.configset.log" 2>/dev/null)"
grep -q '^CBOX_WG_PEER_ENDPOINT=203.0.113.9:51820$' "$CLIHOME/.configset.log" || _fail "client join must set CBOX_WG_PEER_ENDPOINT from the token"
grep -q '^CBOX_WG_PEER_PUBKEY=' "$CLIHOME/.configset.log" || _fail "client join must set CBOX_WG_PEER_PUBKEY from the token"
grep -q '^CBOX_WG_ADDRESS=' "$CLIHOME/.configset.log" || _fail "client join must set CBOX_WG_ADDRESS to the token's client address"
CLIENT_PUB_LINE="$(grep -o 'wg server add-client laptop [A-Za-z0-9+/=]*' "$TMPBASE/step2.out" | head -n1)"
[ -n "$CLIENT_PUB_LINE" ] || _fail "client join must print the exact 'wg server add-client <name> <own-pubkey>' line to paste on the server: $(cat "$TMPBASE/step2.out")"
CLIENT_PUB="${CLIENT_PUB_LINE##* }"
[ "${#CLIENT_PUB}" = 44 ] || _fail "client join printed public key does not look like a wireguard pubkey: $CLIENT_PUB"
grep -q "no TTY" "$TMPBASE/step2.out" || _fail "client join without a TTY must say how to check status instead of waiting"
_ok "client join: writes CBOX_WG_MODE/ADDRESS/PEER_* from the token, prints the add-client line for the server, skips the wait without a TTY"

RC_STEP3=0
(
  eval "$(_common_preamble)"
  export HOME="$SRVHOME"
  export PATH="$TOKBIN:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd laptop "$CLIENT_PUB"
) > "$TMPBASE/step3.out" 2>"$TMPBASE/step3.err" || RC_STEP3=$?
[ "$RC_STEP3" = 0 ] || _fail "step3 (server add-client <pubkey>) failed: $(cat "$TMPBASE/step3.err")"
grep -q "client 'laptop' accepted at " "$TMPBASE/step3.out" || _fail "step3 must confirm the client was accepted: $(cat "$TMPBASE/step3.out")"
PEERSFILE="$SRVHOME/.config/cbox/infra/wireguard/peers"
[ -f "$PEERSFILE" ] || _fail "step3 did not write a peers file"
PEERLINE="$(grep '^laptop|' "$PEERSFILE" || true)"
[ -n "$PEERLINE" ] || _fail "step3 did not add 'laptop' to the peers file: $(cat "$PEERSFILE" 2>/dev/null)"
echo "$PEERLINE" | grep -qF "|$CLIENT_PUB|" || _fail "peers line does not carry the client's own pubkey from the join step: $PEERLINE"
echo "$PEERLINE" | grep -Eq '\|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32\|\|ollama$' || _fail "peers line is not a valid /32 server-role entry: $PEERLINE"
[ ! -e "$SRVHOME/.config/cbox/infra/wireguard/pending" ] || ! grep -q '^laptop|' "$SRVHOME/.config/cbox/infra/wireguard/pending" \
  || _fail "step3 must clear the reservation for 'laptop' once the peer is added"
_ok "token round trip: add-client -> client join -> add-client <pubkey> ends with a valid peers line and a clean reservation"

echo "--- client join: collision-check relaxation (idempotent re-run, server-node join, real collisions still refused) ---"

TOK_FIELDS="$(
  source "$INSTALL_DIR/templates/generators.sh"
  p="$(_cbox_wg_token_decode "$TOKEN")"
  _cbox_wg_token_parse "$p"
)"
TOK_PUBKEY="$(sed -n 2p <<<"$TOK_FIELDS")"
TOK_ENDPOINT="$(sed -n 3p <<<"$TOK_FIELDS")"
TOK_SERVER_ADDR="$(sed -n 4p <<<"$TOK_FIELDS")"
TOK_CLIENT_ADDR="$(sed -n 5p <<<"$TOK_FIELDS")"
[ -n "$TOK_CLIENT_ADDR" ] || _fail "could not re-parse TOKEN for the collision-relaxation tests"

RERUNHOME="$TMPBASE/rerun/home"
mkdir -p "$RERUNHOME"
RC_RERUN=0
(
  eval "$(_common_preamble)"
  export HOME="$RERUNHOME"
  export PATH="$TOKBIN:$PATH"
  export CBOX_WG_MODE=client
  export CBOX_WG_ADDRESS="$TOK_CLIENT_ADDR"
  export CBOX_WG_PEER_PUBKEY="$TOK_PUBKEY"
  export CBOX_WG_PEER_ENDPOINT="$TOK_ENDPOINT"
  export CBOX_WG_PEER_ADDRESS="$TOK_SERVER_ADDR"
  export CBOX_WG_KEEPALIVE=25
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_client_join_cmd "$TOKEN"
) > "$TMPBASE/rerun.out" 2>"$TMPBASE/rerun.err" || RC_RERUN=$?
[ "$RC_RERUN" = 0 ] || _fail "re-running client join with a token that is already fully applied (same address/pubkey/endpoint) must be idempotent, not a refused collision: $(cat "$TMPBASE/rerun.err")"
_ok "client join: re-running the exact same already-applied token succeeds instead of being refused as a collision"

REMOTE_PUBKEY="AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
SRVJOIN="$TMPBASE/srvjoin/home"
mkdir -p "$SRVJOIN"
TOKEN_FRIEND="$(
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_wg_token_encode friend "$REMOTE_PUBKEY" "203.0.113.50:51820" "10.90.0.9/32" "10.90.0.1/32" 25
)"
RC_SRVJOIN=0
(
  eval "$(_common_preamble)"
  export HOME="$SRVJOIN"
  export PATH="$TOKBIN:$PATH"
  export CBOX_WG_MODE=server
  export CBOX_WG_ADDRESS=10.90.0.1/24
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_client_join_cmd "$TOKEN_FRIEND"
) > "$TMPBASE/srvjoin.out" 2>"$TMPBASE/srvjoin.err" || RC_SRVJOIN=$?
[ "$RC_SRVJOIN" = 0 ] || _fail "a server-role node joining as a client using its own tunnel host address (different CIDR notation) must be allowed to reach the both-mode transition: $(cat "$TMPBASE/srvjoin.err")"
grep -q '^CBOX_WG_MODE=both$' "$SRVJOIN/.configset.log" || _fail "server node join must flip CBOX_WG_MODE server -> both: $(cat "$SRVJOIN/.configset.log" 2>/dev/null)"
_ok "client join: a server-role node can join as a client using its own tunnel host address, reaching the server -> both transition"

RC_SRVJOIN_OTHER=0
TOKEN_OTHER="$(
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_wg_token_encode other "$REMOTE_PUBKEY" "203.0.113.60:51820" "10.77.0.9/32" "10.77.0.5/32" 25
)"
(
  eval "$(_common_preamble)"
  export HOME="$SRVJOIN"
  export PATH="$TOKBIN:$PATH"
  export CBOX_WG_MODE=server
  export CBOX_WG_ADDRESS=10.90.0.1/24
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_client_join_cmd "$TOKEN_OTHER"
) > "$TMPBASE/srvjoin_other.out" 2>"$TMPBASE/srvjoin_other.err" || RC_SRVJOIN_OTHER=$?
[ "$RC_SRVJOIN_OTHER" = 1 ] || _fail "a server-role node must still refuse a token for a genuinely different address (unrelated network) that would overwrite its own tunnel address (got rc=$RC_SRVJOIN_OTHER): $(cat "$TMPBASE/srvjoin_other.out")"
grep -qi 'already has a server role' "$TMPBASE/srvjoin_other.err" || _fail "the refusal must explain the server-role collision: $(cat "$TMPBASE/srvjoin_other.err")"
_ok "client join: a server-role node still refuses a token for an unrelated address that would overwrite its own tunnel address"

RC_SELFPUB=0
TOKEN_SELFPUB="$(
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_wg_token_encode selfpub "$VALID_PUBKEY" "203.0.113.70:51820" "10.90.0.9/32" "10.90.0.5/32" 25
)"
SELFPUBHOME="$TMPBASE/selfpub/home"
mkdir -p "$SELFPUBHOME"
(
  source "$INSTALL_DIR/templates/generators.sh"
  export HOME="$SELFPUBHOME"
  export PATH="$TOKBIN:$PATH"
  _cbox_wg_keygen
) > "$TMPBASE/selfpub.keygen.out" 2>"$TMPBASE/selfpub.keygen.err" \
  || _fail "could not pre-generate a local keypair for the self-pubkey collision test: $(cat "$TMPBASE/selfpub.keygen.err")"
(
  eval "$(_common_preamble)"
  export HOME="$SELFPUBHOME"
  export PATH="$TOKBIN:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_client_join_cmd "$TOKEN_SELFPUB"
) > "$TMPBASE/selfpub.out" 2>"$TMPBASE/selfpub.err" || RC_SELFPUB=$?
[ "$RC_SELFPUB" = 1 ] || _fail "a token whose public key equals this node's own wireguard public key must still be refused (got rc=$RC_SELFPUB): $(cat "$TMPBASE/selfpub.out")"
grep -qi 'own wireguard public key' "$TMPBASE/selfpub.err" || _fail "the refusal must explain the self-pubkey collision: $(cat "$TMPBASE/selfpub.err")"
_ok "client join: a token carrying this node's own public key is still refused"

RC_SRVADDR=0
TOKEN_SRVADDR="$(
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_wg_token_encode srvaddr "$REMOTE_PUBKEY" "203.0.113.80:51820" "10.44.0.7/32" "10.44.0.8/32" 25
)"
SRVADDRHOME="$TMPBASE/srvaddr/home"
mkdir -p "$SRVADDRHOME"
(
  eval "$(_common_preamble)"
  export HOME="$SRVADDRHOME"
  export PATH="$TOKBIN:$PATH"
  export CBOX_WG_ADDRESS=10.44.0.7/32
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_client_join_cmd "$TOKEN_SRVADDR"
) > "$TMPBASE/srvaddr.out" 2>"$TMPBASE/srvaddr.err" || RC_SRVADDR=$?
[ "$RC_SRVADDR" = 1 ] || _fail "a token whose server address equals this node's own tunnel address must still be refused (got rc=$RC_SRVADDR): $(cat "$TMPBASE/srvaddr.out")"
grep -qi 'own tunnel address' "$TMPBASE/srvaddr.err" || _fail "the refusal must explain the own-tunnel-address collision: $(cat "$TMPBASE/srvaddr.err")"
_ok "client join: a token whose server address equals this node's own tunnel address is still refused"

echo "--- token validation ---"

_cbox_wg_token_reject() {
  local desc="$1" payload="$2"
  (
    source "$INSTALL_DIR/templates/generators.sh"
    _cbox_wg_token_parse "$payload"
  ) >/dev/null 2>"$TMPBASE/tokrej.err" && _fail "token with $desc must be rejected"
  [ -s "$TMPBASE/tokrej.err" ] || _fail "token rejection ($desc) produced no error message"
}

_cbox_wg_token_reject "a bad pubkey" "$(printf 'name=laptop\npubkey=not-a-key\nendpoint=203.0.113.9:51820\nserver_addr=10.90.0.1/32\nclient_addr=10.90.0.2/32\nkeepalive=25\n')"
_cbox_wg_token_reject "an extra unknown key" "$(printf 'name=laptop\npubkey=%s\nendpoint=203.0.113.9:51820\nserver_addr=10.90.0.1/32\nclient_addr=10.90.0.2/32\nkeepalive=25\nextra=x\n' "$VALID_PUBKEY")"
_cbox_wg_token_reject "a non-/32 client address" "$(printf 'name=laptop\npubkey=%s\nendpoint=203.0.113.9:51820\nserver_addr=10.90.0.1/32\nclient_addr=10.90.0.0/24\nkeepalive=25\n' "$VALID_PUBKEY")"
_cbox_wg_token_reject "a non-/32 server address" "$(printf 'name=laptop\npubkey=%s\nendpoint=203.0.113.9:51820\nserver_addr=10.90.0.0/24\nclient_addr=10.90.0.2/32\nkeepalive=25\n' "$VALID_PUBKEY")"
_cbox_wg_token_reject "a shell metacharacter in the endpoint" "$(printf 'name=laptop\npubkey=%s\nendpoint=203.0.113.9:51820; rm -rf /\nserver_addr=10.90.0.1/32\nclient_addr=10.90.0.2/32\nkeepalive=25\n' "$VALID_PUBKEY")"
_ok "token parse: rejects a bad pubkey, an unknown extra key, a non-/32 address on either side, and shell metacharacters"

(
  source "$INSTALL_DIR/templates/generators.sh"
  _cbox_wg_token_decode "not-a-token" 2>/dev/null
) >/dev/null 2>&1 && _fail "a token without the cbx1. prefix must be rejected"
_ok "token decode: refuses anything without the cbx1. prefix"

echo "--- --plain: private key never on stdout/stderr ---"

PLHOME="$TMPBASE/plain/home"
mkdir -p "$PLHOME"
PLBIN="$TMPBASE/plainbin"
mkdir -p "$PLBIN"
cp "$STUBBIN/wg" "$PLBIN/wg"
RC_PLAIN=0
(
  eval "$(_common_preamble)"
  export HOME="$PLHOME"
  export PATH="$PLBIN:$PATH"
  export CBOX_WG_PUBLISH_ADDR=203.0.113.9
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd winbox --plain
) > "$TMPBASE/plain.out" 2>"$TMPBASE/plain.err" || RC_PLAIN=$?
[ "$RC_PLAIN" = 0 ] || _fail "server add-client --plain failed: $(cat "$TMPBASE/plain.err")"
! grep -q "$_STUB_PRIVKEY" "$TMPBASE/plain.out" || _fail "--plain must never print the generated private key to stdout"
! grep -q "$_STUB_PRIVKEY" "$TMPBASE/plain.err" || _fail "--plain must never print the generated private key to stderr"
KEYFILE="$PLHOME/.config/cbox/infra/wireguard-peer-keys/peer-winbox.key"
[ -f "$KEYFILE" ] || _fail "--plain did not save the generated private key to $KEYFILE"
[ "$(stat -c '%a' "$KEYFILE")" = 600 ] || _fail "--plain key file must be mode 600"
grep -q "PrivateKey = <contents of $KEYFILE>" "$TMPBASE/plain.out" || _fail "--plain must print a peer-config pointing at the saved key file, never the key itself"
grep -q '^Endpoint = 203.0.113.9:51820$' "$TMPBASE/plain.out" || _fail "--plain must render a real Endpoint (endpoint rules), not a placeholder, when CBOX_WG_PUBLISH_ADDR is set"
grep -q '^laptop|\|^winbox|' "$PLHOME/.config/cbox/infra/wireguard/peers" >/dev/null 2>&1 || grep -q '^winbox|' "$PLHOME/.config/cbox/infra/wireguard/peers" || _fail "--plain did not register the peer"
_ok "server add-client --plain: private key saved 0600 outside stdout/stderr, peer-config output uses the real endpoint, not a placeholder"

echo "--- ollama reconcile propagates the render's refusal (fresh host, CBOX_WG_MODE=server, no CBOX_WG_PUBLISH_ADDR) ---"

RECHOME="$TMPBASE/reconcile/home"
mkdir -p "$RECHOME"
RECBIN="$TMPBASE/reconcilebin"
mkdir -p "$RECBIN"
cp "$STUBBIN/wg" "$RECBIN/wg"
RC_RECONCILE=0
(
  source "$INSTALL_DIR/templates/generators.sh"
  eval "$RECONCILE_CMD_FN"
  export HOME="$RECHOME"
  export PATH="$RECBIN:$PATH"
  export CBOX_WG_MODE=server
  export CBOX_WG_ADDRESS=10.90.0.1/24
  unset CBOX_WG_PUBLISH_ADDR 2>/dev/null
  _cbox_ollama_owner_up() { echo "OWNER-UP-CALLED" >> "$TMPBASE/reconcile.ownerup.log"; return 0; }
  _cbox_ollama_reconcile_networks_impl() { return 0; }
  _cbox_ollama_reconcile_cmd
) > "$TMPBASE/reconcile.out" 2>"$TMPBASE/reconcile.err" || RC_RECONCILE=$?
[ "$RC_RECONCILE" = 1 ] || _fail "ollama reconcile must fail when CBOX_WG_MODE=server and CBOX_WG_PUBLISH_ADDR is empty (got rc=$RC_RECONCILE): $(cat "$TMPBASE/reconcile.err")"
grep -qi 'CBOX_WG_PUBLISH_ADDR is empty' "$TMPBASE/reconcile.err" || _fail "reconcile failure must surface the render's clear CBOX_WG_PUBLISH_ADDR message, not swallow it: $(cat "$TMPBASE/reconcile.err")"
[ ! -s "$TMPBASE/reconcile.ownerup.log" ] || _fail "reconcile must refuse before ever starting containers when the render fails"
_ok "ollama reconcile: a fresh host with CBOX_WG_MODE=server and no CBOX_WG_PUBLISH_ADDR fails clearly before touching containers (render rc is no longer swallowed)"

echo "--- endpoint auto-detect fallback ---"

EPHOME="$TMPBASE/ep/home"
mkdir -p "$EPHOME"
EPBIN="$TMPBASE/epbin"
mkdir -p "$EPBIN"
cp "$STUBBIN/wg" "$EPBIN/wg"
_write_ip_stub "$EPBIN/ip" ""
set +e
(
  eval "$(_common_preamble)"
  export HOME="$EPHOME"
  export PATH="$EPBIN:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd nolan
) > "$TMPBASE/ep.out" 2>"$TMPBASE/ep.err"
RC_EP=$?
set -e
[ "$RC_EP" = 1 ] || _fail "server add-client without --endpoint, no CBOX_WG_PUBLISH_ADDR and no detectable LAN IPv4 must fail (got $RC_EP)"
grep -qi 'pass --endpoint' "$TMPBASE/ep.err" || _fail "endpoint-detection failure must tell the operator to pass --endpoint: $(cat "$TMPBASE/ep.err")"
_ok "server add-client: refuses when no endpoint can be resolved and none was given"

EPHOME2="$TMPBASE/ep2/home"
mkdir -p "$EPHOME2"
_write_ip_stub "$EPBIN/ip" "192.0.2.50"
RC_EP2=0
(
  eval "$(_common_preamble)"
  export HOME="$EPHOME2"
  export PATH="$EPBIN:$PATH"
  _cbox_wg_tun_present() { return 0; }
  _cbox_wg_server_add_client_cmd nolan
) > "$TMPBASE/ep2.out" 2>"$TMPBASE/ep2.err" || RC_EP2=$?
[ "$RC_EP2" = 0 ] || _fail "server add-client with a detectable LAN IPv4 must succeed: $(cat "$TMPBASE/ep2.err")"
TOKEN_EP2="$(grep -o 'cbx1\.[A-Za-z0-9_-]*' "$TMPBASE/ep2.out" | head -n1)"
[ -n "$TOKEN_EP2" ] || _fail "server add-client with a detected endpoint did not print a token"
(
  source "$INSTALL_DIR/templates/generators.sh"
  p="$(_cbox_wg_token_decode "$TOKEN_EP2")"
  _cbox_wg_token_parse "$p"
) > "$TMPBASE/ep2.parsed" 2>&1
grep -q '^192.0.2.50:51820$' "$TMPBASE/ep2.parsed" || _fail "detected LAN IPv4 was not used as the token endpoint: $(cat "$TMPBASE/ep2.parsed")"
_ok "server add-client: falls back to the detected LAN IPv4 (ip -4 route get) when CBOX_WG_PUBLISH_ADDR is unset"

echo "PASS: all wireguard pairing checks"
