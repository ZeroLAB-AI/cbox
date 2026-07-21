#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

source "$INSTALL_DIR/templates/generators.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

CBOX_NETACCESS_MODE=socks
CBOX_NETACCESS_APPLIED=1
CBOX_NETACCESS_SCOPE=list
CBOX_NETACCESS_NETWORKS="project_a project_b"
CBOX_NETACCESS_EXEC_MODE=scoped
CBOX_NETACCESS_SOCKS_PORT=1081
XDG_RUNTIME_DIR="$TMPBASE/runtime"

out="$TMPBASE/compose-fragment"
: > "$out"
_cbox_netaccess_env_into "$out"
_cbox_container_exec_env_into "$out"
_cbox_container_exec_mounts_into "$out" p123

grep -qF 'ALL_PROXY=socks5h://proxy:1081' "$out" || fail "SOCKS environment missing"
grep -qF 'CBOX_CONTAINER_EXEC_TIMEOUT=900' "$out" || fail "exec client timeout environment missing"
grep -qF 'CBOX_CONTAINER_EXEC_MAX_BYTES=10485760' "$out" || fail "exec client output cap environment missing"
grep -qF "$TMPBASE/runtime/cbox-container-exec-p123/sockets:/run/cbox-container-exec:ro" "$out" || fail "read-only private socket mount missing"
if grep -qF ':rw' "$out"; then
  fail "container exec runtime must not be writable from cbox"
fi
grep -qF '/etc/container/cbox-container:/usr/local/bin/cbox-container:ro' "$out" || fail "client mount missing"

networks="$TMPBASE/main-networks"
: > "$networks"
CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0
_cbox_proxy_main_networks_into "$networks"
grep -qF '      - internal' "$networks" || fail "main container internal network missing"
grep -qF '      - egress' "$networks" || fail "netaccess-only mode lost normal direct egress"

: > "$networks"
CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=1
_cbox_proxy_main_networks_into "$networks"
grep -qF '      - internal' "$networks" || fail "filtered main container internal network missing"
if grep -qF '      - egress' "$networks"; then
  fail "filtered egress mode exposed the main container directly"
fi
CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0

CBOX_NETACCESS_SCOPE=all
if _cbox_netaccess_exec_active; then
  fail "scoped exec widened to scope=all"
fi

CBOX_NETACCESS_SCOPE=list
mkdir -p "$TMPBASE/proxy"
CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=1
gen_tinyproxy_conf_into "$TMPBASE/proxy"
grep -qF 'Listen 127.0.0.1' "$TMPBASE/proxy/tinyproxy.conf" || fail "initial Tinyproxy config is not fail-closed on loopback"
gen_tinyproxy_conf_into "$TMPBASE/proxy" 172.20.0.2
grep -qF 'Listen 172.20.0.2' "$TMPBASE/proxy/tinyproxy.conf" || fail "Tinyproxy did not bind the cbox-internal endpoint"
if grep -qF 'Listen 0.0.0.0' "$TMPBASE/proxy/tinyproxy.conf"; then
  fail "Tinyproxy exposed itself on attached target networks"
fi
CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0
gen_sockd_conf_into "$TMPBASE/proxy" 172.20.0.2 172.20.0.0/24 '10.10.0.2,10.10.0.0/24 10.10.0.2,10.42.0.0/16'
[ "$(grep -c '^external: 10.10.0.2$' "$TMPBASE/proxy/sockd.conf")" -eq 1 ] || fail "external endpoint was not deduplicated"
grep -qF 'from: 172.20.0.0/24 to: 10.10.0.0/24' "$TMPBASE/proxy/sockd.conf" || fail "Docker network pass rule missing"
grep -qF 'from: 172.20.0.0/24 to: 10.42.0.0/16' "$TMPBASE/proxy/sockd.conf" || fail "raw CIDR pass rule missing"
grep -qF 'from: 0.0.0.0/0 to: 0.0.0.0/0' "$TMPBASE/proxy/sockd.conf" || fail "default block rule missing"

echo "PASS: netaccess runtime rendering"
