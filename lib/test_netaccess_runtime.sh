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

hosts="$TMPBASE/extra-hosts"
: > "$hosts"
CBOX_HOST_GATEWAY_ALIAS=off
_cbox_extra_hosts_into "$hosts"
if [ -s "$hosts" ]; then
  fail "extra_hosts rendered while gateway alias is off"
fi

: > "$hosts"
CBOX_HOST_GATEWAY_ALIAS=on
CBOX_HOST_ROUTE_MODE=off
_cbox_extra_hosts_into "$hosts"
if [ -s "$hosts" ]; then
  fail "extra_hosts rendered while hostroute mode is off, even though gateway alias is on"
fi

: > "$hosts"
CBOX_HOST_GATEWAY_ALIAS=on
CBOX_HOST_ROUTE_MODE=host-proxy
_cbox_extra_hosts_into "$hosts"
grep -qF 'extra_hosts:' "$hosts" || fail "extra_hosts block missing when gateway alias is on and hostroute is enabled"
grep -qF 'host.docker.internal:host-gateway' "$hosts" || fail "host.docker.internal host-gateway mapping missing"
CBOX_HOST_GATEWAY_ALIAS=off
CBOX_HOST_ROUTE_MODE=off

CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0
CBOX_LOCAL_MODEL_URL=""
CBOX_HERMES_MODEL_URL=""
CBOX_HERMES_DELEGATE_BASE_URL=""
noproxy="$(_cbox_no_proxy_hosts)"
[ -z "$noproxy" ] || fail "NO_PROXY host list not empty when no endpoint vars are set: $noproxy"

CBOX_LOCAL_MODEL_URL="http://ollama:11434"
CBOX_HERMES_MODEL_URL="https://hermes.example.com:9999/v1"
CBOX_HERMES_DELEGATE_BASE_URL="http://ollama:11434"
noproxy="$(_cbox_no_proxy_hosts)"
[ "$noproxy" = "ollama,hermes.example.com" ] || fail "NO_PROXY host list mismatch (dedup/parse) with egress off: $noproxy"

CBOX_HOST_GATEWAY_ALIAS=on
CBOX_HOST_ROUTE_MODE=off
noproxy="$(_cbox_no_proxy_hosts)"
[ "$noproxy" = "ollama,hermes.example.com" ] || fail "NO_PROXY host list added host.docker.internal while hostroute mode is off: $noproxy"

CBOX_HOST_ROUTE_MODE=host-proxy
noproxy="$(_cbox_no_proxy_hosts)"
[ "$noproxy" = "ollama,hermes.example.com,host.docker.internal" ] || fail "NO_PROXY host list missing host.docker.internal when alias is on and hostroute is enabled, egress off: $noproxy"

CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=1
noproxy="$(_cbox_no_proxy_hosts)"
[ -z "$noproxy" ] || fail "NO_PROXY host list must stay empty under egress lockdown (proxy is the only route): $noproxy"

CBOX_HOST_GATEWAY_ALIAS=off
CBOX_HOST_ROUTE_MODE=off
CBOX_LOCAL_MODEL_URL=""
CBOX_HERMES_MODEL_URL=""
CBOX_HERMES_DELEGATE_BASE_URL=""

CBOX_OLLAMA_MODE=on
noproxy="$(_cbox_no_proxy_hosts)"
[ "$noproxy" = "ollama" ] || fail "NO_PROXY must contain the ollama service name under egress lockdown when ollama is on (per-scope internal network is a genuine direct route): $noproxy"

CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0
noproxy="$(_cbox_no_proxy_hosts)"
[ "$noproxy" = "ollama" ] || fail "NO_PROXY must contain the ollama service name with egress off when ollama is on: $noproxy"

CBOX_OLLAMA_MODE=off
noproxy="$(_cbox_no_proxy_hosts)"
[ -z "$noproxy" ] || fail "NO_PROXY must not contain ollama when the ollama feature is off: $noproxy"

CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=1
CBOX_LOCAL_MODEL_URL="http://external-host.example.com:11434"
noproxy="$(_cbox_no_proxy_hosts)"
[ -z "$noproxy" ] || fail "an external endpoint must NOT be exempted from the proxy under egress lockdown, even with ollama off: $noproxy"

CBOX_OLLAMA_MODE=on
noproxy="$(_cbox_no_proxy_hosts)"
[ "$noproxy" = "ollama" ] || fail "under egress lockdown, only ollama (a genuine direct route) may be exempted - the external endpoint host must stay proxied: $noproxy"

CBOX_OLLAMA_MODE=off
CBOX_HOST_GATEWAY_ALIAS=off
CBOX_HOST_ROUTE_MODE=off
CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0
CBOX_LOCAL_MODEL_URL=""
CBOX_HERMES_MODEL_URL=""
CBOX_HERMES_DELEGATE_BASE_URL=""

CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0
if _cbox_no_proxy_endpoint_unreachable; then
  fail "endpoint-unreachable warning fired while egress is off"
fi
CBOX_LOCAL_MODEL_URL="http://ollama:11434"
if _cbox_no_proxy_endpoint_unreachable; then
  fail "endpoint-unreachable warning fired while egress is off, even with an endpoint configured"
fi
CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=1
_cbox_no_proxy_endpoint_unreachable || fail "endpoint-unreachable warning did not fire under egress lockdown with an endpoint configured"
CBOX_LOCAL_MODEL_URL=""
if _cbox_no_proxy_endpoint_unreachable; then
  fail "endpoint-unreachable warning fired under egress lockdown with no endpoint configured"
fi
CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0

host="$(_cbox_url_host "http://user:pass@userhost:8080/path")"
[ "$host" = "userhost" ] || fail "_cbox_url_host did not strip userinfo: $host"

host="$(_cbox_url_host "http://[::1]:11434")"
[ "$host" = "::1" ] || fail "_cbox_url_host did not extract bracketed IPv6 literal: $host"

host="$(_cbox_url_host "http://[::1]")"
[ "$host" = "::1" ] || fail "_cbox_url_host did not extract bracketed IPv6 literal without port: $host"

host="$(_cbox_url_host "http://bad!host:1234")"
[ -z "$host" ] || fail "_cbox_url_host accepted an invalid-charset host: $host"

host="$(_cbox_url_host "http://OLLAMA:11434")"
[ "$host" = "ollama" ] || fail "_cbox_url_host did not lowercase an uppercase host: $host"

host="$(_cbox_url_host "http://ollama,evil:11434")"
[ -z "$host" ] || fail "_cbox_url_host accepted a comma-bearing host: $host"

host="$(_cbox_url_host "http://ollama evil:11434")"
[ -z "$host" ] || fail "_cbox_url_host accepted a whitespace-bearing host: $host"

CBOX_LOCAL_MODEL_URL="http://user:pass@ollama:11434"
CBOX_HERMES_MODEL_URL=""
CBOX_HERMES_DELEGATE_BASE_URL=""
noproxy="$(_cbox_no_proxy_hosts)"
[ "$noproxy" = "ollama" ] || fail "NO_PROXY host list leaked userinfo instead of the bare host: $noproxy"
CBOX_LOCAL_MODEL_URL=""

grep -q '_cbox_no_proxy_hosts' <(awk '/^gen_compose\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh") \
  || fail "gen_compose (global compose variant) does not call _cbox_no_proxy_hosts"
grep -q '_cbox_no_proxy_hosts' <(awk '/^gen_compose_isolated\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh") \
  || fail "gen_compose_isolated (isolated compose variant) does not call _cbox_no_proxy_hosts"

ISOD="$TMPBASE/isolated-render"
ISOP="$TMPBASE/isolated-root"
mkdir -p "$ISOD/eff/claude-config/projects" "$ISOD/claude" "$ISOD/codex" "$ISOP"
(
  set -e
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
  export CBOX_CLAUDE_PATH="$ISOD/claude" CBOX_CODEX_PATH="$ISOD/codex"
  export CBOX_EGRESS_MODE=allowlist CBOX_EGRESS_APPLIED=1
  export CBOX_OLLAMA_MODE=on
  export CBOX_LOCAL_MODEL_URL="" CBOX_HERMES_MODEL_URL="" CBOX_HERMES_DELEGATE_BASE_URL=""
  gen_compose_isolated "$ISOD/eff" "$ISOP" testimg testhash123456 >/dev/null 2>&1
)
grep -q '^      - NO_PROXY=.*ollama' "$ISOD/eff/docker-compose.yml" || fail "isolated compose: NO_PROXY does not contain ollama under egress lockdown with CBOX_OLLAMA_MODE=on"
grep -q '^      - no_proxy=.*ollama' "$ISOD/eff/docker-compose.yml" || fail "isolated compose: no_proxy does not contain ollama under egress lockdown with CBOX_OLLAMA_MODE=on"
_ok_render() { echo "ok: $1"; }
_ok_render "isolated compose variant renders ollama into both NO_PROXY and no_proxy under egress lockdown"

ISOD2="$TMPBASE/isolated-render-off"
mkdir -p "$ISOD2/eff/claude-config/projects" "$ISOD2/claude" "$ISOD2/codex"
(
  set -e
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
  export CBOX_CLAUDE_PATH="$ISOD2/claude" CBOX_CODEX_PATH="$ISOD2/codex"
  export CBOX_EGRESS_MODE=allowlist CBOX_EGRESS_APPLIED=1
  export CBOX_OLLAMA_MODE=off
  export CBOX_LOCAL_MODEL_URL="" CBOX_HERMES_MODEL_URL="" CBOX_HERMES_DELEGATE_BASE_URL=""
  gen_compose_isolated "$ISOD2/eff" "$ISOP" testimg testhash123456 >/dev/null 2>&1
)
if grep -q 'ollama' "$ISOD2/eff/docker-compose.yml"; then
  fail "isolated compose: ollama leaked into NO_PROXY/rendering while CBOX_OLLAMA_MODE=off"
fi
_ok_render "isolated compose variant omits ollama entirely when the feature is off"

echo "PASS: netaccess runtime rendering"
