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

grep -qF 'CBOX_SOCKS_PROXY=socks5h://cbox-proxy-internal:1081' "$out" || fail "SOCKS environment missing or not pointing at the internal-only proxy alias"
if grep -qiF 'all_proxy' "$out"; then
  fail "blanket ALL_PROXY/all_proxy must not be exported - the deny-by-default SOCKS proxy would capture general egress (curl/git/pip) and block it"
fi
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
[ "$(grep -c '^internal:' "$TMPBASE/proxy/sockd.conf")" -eq 1 ] || fail "sockd must bind exactly one internal address"
[ "$(cat "$TMPBASE/proxy/internal-cidr")" = "172.20.0.0/24" ] || fail "gen_sockd_conf_into must write internal-cidr next to internal-ip"
[ -x "$TMPBASE/proxy/sockd-start.sh" ] || fail "gen_sockd_conf_into must render an executable sockd-start.sh"

gen_supervisord_conf_into "$TMPBASE/proxy"
grep -qF 'command=/bin/sh /etc/cbox-generated/sockd-start.sh' "$TMPBASE/proxy/supervisord.conf" \
  || fail "supervisord must run sockd through the live-address rewrite wrapper, not sockd directly"
if grep -qE 'sockd .*-D' "$TMPBASE/proxy/supervisord.conf"; then
  fail "sockd must not daemonize under supervisord - dante -D forks, the parent exits, supervisord respawns into Address in use and ends FATAL while the orphan serves unsupervised"
fi
grep -qF 'stopasgroup=true' "$TMPBASE/proxy/supervisord.conf" || fail "sockd program must stop its process group (dante mother forks children)"
grep -qF 'killasgroup=true' "$TMPBASE/proxy/supervisord.conf" || fail "sockd program must kill its process group"
if grep -qF 'program:tinyproxy' "$TMPBASE/proxy/supervisord.conf"; then
  fail "tinyproxy program rendered while egress is off"
fi
CBOX_EGRESS_MODE=allowlist
CBOX_EGRESS_APPLIED=1
gen_supervisord_conf_into "$TMPBASE/proxy"
grep -qF 'command=tinyproxy -d -c /etc/cbox-generated/tinyproxy.conf' "$TMPBASE/proxy/supervisord.conf" \
  || fail "tinyproxy program missing with egress active (tinyproxy -d means foreground, opposite of dante)"
grep -qF 'program:sockd' "$TMPBASE/proxy/supervisord.conf" || fail "sockd program missing with both features active"
CBOX_EGRESS_MODE=off
CBOX_EGRESS_APPLIED=0

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

ISOD2B="$TMPBASE/isolated-render-egress-only-no-netaccess"
mkdir -p "$ISOD2B/eff/claude-config/projects" "$ISOD2B/claude" "$ISOD2B/codex"
(
  set -e
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
  export CBOX_CLAUDE_PATH="$ISOD2B/claude" CBOX_CODEX_PATH="$ISOD2B/codex"
  export CBOX_EGRESS_MODE=allowlist CBOX_EGRESS_APPLIED=1
  export CBOX_NETACCESS_MODE=off CBOX_NETACCESS_APPLIED=0
  export CBOX_OLLAMA_MODE=off
  export CBOX_LOCAL_MODEL_URL="" CBOX_HERMES_MODEL_URL="" CBOX_HERMES_DELEGATE_BASE_URL=""
  gen_compose_isolated "$ISOD2B/eff" "$ISOP" testimg testhash123456 >/dev/null 2>&1
)
YML2B="$ISOD2B/eff/docker-compose.yml"
PROXY_BLOCK2B="$(awk '/^  proxy:$/,/^volumes:$/' "$YML2B")"
printf '%s\n' "$PROXY_BLOCK2B" | grep -qF 'restart: "no"' \
  || fail "egress-only (no netaccess) proxy restart policy must stay as configured"
if grep -qF '/etc/cbox/net' "$YML2B"; then
  fail "netmap mount must not appear when netaccess is off (egress-only)"
fi
if grep -qF 'host_alias_forwarder.py' "$YML2B"; then
  fail "host_alias_forwarder.py mount must not appear when netaccess is off (egress-only)"
fi
_ok_render "egress-only compose: proxy restart policy unaffected, no netmap mount without netaccess"

ISOD3="$TMPBASE/isolated-render-netaccess"
mkdir -p "$ISOD3/eff/claude-config/projects" "$ISOD3/claude" "$ISOD3/codex"
(
  set -e
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
  export CBOX_CLAUDE_PATH="$ISOD3/claude" CBOX_CODEX_PATH="$ISOD3/codex"
  export CBOX_EGRESS_MODE=off CBOX_EGRESS_APPLIED=0
  export CBOX_NETACCESS_MODE=socks CBOX_NETACCESS_APPLIED=1 CBOX_NETACCESS_SOCKS_PORT=1081
  export CBOX_OLLAMA_MODE=off
  export CBOX_LOCAL_MODEL_URL="" CBOX_HERMES_MODEL_URL="" CBOX_HERMES_DELEGATE_BASE_URL=""
  gen_compose_isolated "$ISOD3/eff" "$ISOP" testimg testhash123456 >/dev/null 2>&1
)
YML="$ISOD3/eff/docker-compose.yml"
grep -qF '          - cbox-proxy-internal' "$YML" || fail "netaccess compose: proxy internal-network alias missing"
[ "$(grep -cF -- '- cbox-proxy-internal' "$YML")" -eq 1 ] || fail "netaccess compose: the proxy alias must exist on exactly one network (internal), not on egress too"
grep -A 2 '^      internal:$' "$YML" | grep -qF 'aliases:' || fail "netaccess compose: alias is not scoped under the proxy's internal network"
grep -qF 'CBOX_SOCKS_PROXY=socks5h://cbox-proxy-internal:1081' "$YML" || fail "netaccess compose: env endpoint does not use the internal-only alias"
if grep -qi 'all_proxy' "$YML"; then
  fail "netaccess compose: blanket ALL_PROXY/all_proxy leaked into the render"
fi
grep -qF 'nc -z -w 2 \"$$ip\" 1081' "$YML" || fail "netaccess compose: healthcheck does not probe the SOCKS port"
if grep -q '8888' "$YML"; then
  fail "netaccess compose: healthcheck probes the tinyproxy port while egress is off"
fi
if grep -qF '|| nc -z' "$YML"; then
  fail "netaccess compose: healthcheck must not OR feature ports - a live tinyproxy would mask a dead sockd"
fi
PROXY_BLOCK3="$(awk '/^  proxy:$/,/^volumes:$/' "$YML")"
MAIN_RESTART3="$(awk '/^  proxy:$/{exit} /^    restart:/{print; exit}' "$YML")"
[ -n "$MAIN_RESTART3" ] || fail "netaccess compose: main service restart policy not found"
printf '%s\n' "$PROXY_BLOCK3" | grep -qxF "$MAIN_RESTART3" \
  || fail "netaccess active: the proxy sidecar must share the cbox service restart policy ($MAIN_RESTART3)"
if printf '%s\n' "$PROXY_BLOCK3" | grep -qF 'unless-stopped'; then
  fail "netaccess active: the proxy must not outlive cbox with its own unless-stopped policy"
fi
printf '%s\n' "$PROXY_BLOCK3" | grep -qF 'cbox.kind: proxy' \
  || fail "netaccess active: the proxy service must carry the cbox.kind=proxy label so cbox gc's sidecar sweep stops it"
grep -qF "$ISOD3/eff/proxy/netmap:/etc/cbox/net:ro" "$YML" \
  || fail "netaccess active must mount <eff>/proxy/netmap read-only at /etc/cbox/net on the main service"
[ -d "$ISOD3/eff/proxy/netmap" ] || fail "the netmap host directory must be created before compose up, not left to docker to auto-vivify"
grep -qF "$INSTALL_DIR/etc/net/host_alias_forwarder.py:/opt/cbox/host_alias_forwarder.py:ro" "$YML" \
  || fail "netaccess active (isolated) must also mount host_alias_forwarder.py, same gate as the netmap mount"
grep -qF 'if [ -f /run/cbox/internal-ip ]; then ip=$$(cat /run/cbox/internal-ip); elif [ -f /etc/cbox-generated/internal-ip ]; then ip=$$(cat /etc/cbox-generated/internal-ip); fi' "$YML" \
  || fail "healthcheck must prefer /run/cbox/internal-ip, fall back to /etc/cbox-generated/internal-ip"
_ok_render "netaccess-only compose: internal-scoped proxy alias, alias-based endpoint, no ALL_PROXY, healthcheck probes only the SOCKS port"
_ok_render "netaccess-only compose: proxy shares the cbox restart policy, netmap mounted read-only, healthcheck prefers /run/cbox/internal-ip"

ISOD4="$TMPBASE/isolated-render-both"
mkdir -p "$ISOD4/eff/claude-config/projects" "$ISOD4/claude" "$ISOD4/codex"
(
  set -e
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
  export CBOX_CLAUDE_PATH="$ISOD4/claude" CBOX_CODEX_PATH="$ISOD4/codex"
  export CBOX_EGRESS_MODE=allowlist CBOX_EGRESS_APPLIED=1
  export CBOX_NETACCESS_MODE=socks CBOX_NETACCESS_APPLIED=1 CBOX_NETACCESS_SOCKS_PORT=1081
  export CBOX_OLLAMA_MODE=off
  export CBOX_LOCAL_MODEL_URL="" CBOX_HERMES_MODEL_URL="" CBOX_HERMES_DELEGATE_BASE_URL=""
  gen_compose_isolated "$ISOD4/eff" "$ISOP" testimg testhash123456 >/dev/null 2>&1
)
grep -qF 'nc -z -w 2 \"$$ip\" 8888 && nc -z -w 2 \"$$ip\" 1081' "$ISOD4/eff/docker-compose.yml" \
  || fail "both-active compose: healthcheck must require BOTH tinyproxy and sockd to listen (AND, not OR)"
_ok_render "both-active compose: healthcheck ANDs the tinyproxy and SOCKS listeners"

EENV="$TMPBASE/exec-env.sh"
{
  echo 'set -uo pipefail'
  echo '_cbox_netaccess_active() { [ "${CBOX_NETACCESS_MODE:-off}" != off ]; }'
  awk '/^_cbox_proxy_internal_alias\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh"
  awk '/^_cbox_netaccess_socks_exec_env\(\) \{/,/^}$/' "$INSTALL_DIR/cbox"
} > "$EENV"
[ -s "$EENV" ] || fail "could not extract _cbox_netaccess_socks_exec_env from cbox"

envout="$(bash -c '. "$1"; CBOX_NETACCESS_MODE=socks CBOX_NETACCESS_SOCKS_PORT=1081 _cbox_netaccess_socks_exec_env; printf "%s" "${CBOX_SOCKS_EXEC_ENV[*]}"' _ "$EENV")"
[ "$envout" = "-e CBOX_SOCKS_PROXY=socks5h://cbox-proxy-internal:1081" ] \
  || fail "per-exec SOCKS delivery must inject the internal-alias endpoint for a new session, got '$envout'"
envcount="$(bash -c '. "$1"; CBOX_NETACCESS_MODE=off _cbox_netaccess_socks_exec_env; printf "%s" "${#CBOX_SOCKS_EXEC_ENV[@]}"' _ "$EENV")"
[ "$envcount" = 0 ] || fail "per-exec SOCKS delivery must inject nothing when netaccess is off, got count '$envcount'"
envbad="$(bash -c '. "$1"; CBOX_NETACCESS_MODE=socks CBOX_NETACCESS_SOCKS_PORT=notaport _cbox_netaccess_socks_exec_env; printf "%s" "${CBOX_SOCKS_EXEC_ENV[*]}"' _ "$EENV")"
[ "$envbad" = "-e CBOX_SOCKS_PROXY=socks5h://cbox-proxy-internal:1080" ] \
  || fail "per-exec SOCKS delivery must fall back to port 1080 on a malformed port, got '$envbad'"
if printf '%s' "$envout$envbad" | grep -qi 'all_proxy'; then
  fail "per-exec delivery must never inject ALL_PROXY/all_proxy"
fi
echo "ok: per-exec SOCKS delivery injects only CBOX_SOCKS_PROXY (internal alias) for a new session, nothing when off, safe port fallback, never ALL_PROXY"

CBOX_NETACCESS_MODE=socks
CBOX_NETACCESS_APPLIED=1
CBOX_NETACCESS_SOCKS_PORT=1081
gen_sockd_placeholder_into "$TMPBASE/proxy"
grep -qF 'internal: 127.0.0.1 port = 1081' "$TMPBASE/proxy/sockd.conf" \
  || fail "sockd placeholder must bind loopback (fail-closed) so a proxy that starts before apply re-renders is unreachable, not serving the previous run's rules"
grep -qF 'socks block {' "$TMPBASE/proxy/sockd.conf" || fail "sockd placeholder must have a default socks block rule"
if grep -qF 'socks pass' "$TMPBASE/proxy/sockd.conf"; then
  fail "sockd placeholder must not carry any pass rule - it is fail-closed until apply renders the real config"
fi
[ ! -f "$TMPBASE/proxy/internal-cidr" ] || fail "sockd placeholder must not leave a stale internal-cidr - its presence is how sockd-start.sh tells placeholder from real config"
[ -x "$TMPBASE/proxy/sockd-start.sh" ] || fail "sockd placeholder must still render sockd-start.sh (supervisord always execs it)"
CBOX_NETACCESS_MODE=off
gen_sockd_placeholder_into "$TMPBASE/proxy"
[ ! -f "$TMPBASE/proxy/sockd.conf" ] || fail "sockd placeholder must be removed when netaccess is off"
[ ! -f "$TMPBASE/proxy/sockd-start.sh" ] || fail "sockd-start.sh must be removed when netaccess is off"
[ ! -f "$TMPBASE/proxy/internal-cidr" ] || fail "internal-cidr must be removed when netaccess is off"
CBOX_NETACCESS_MODE=socks
_ok_render "sockd placeholder is fail-closed on loopback in prepare/regen (never leaves a stale real sockd.conf), removed when off"

grep -qF 'cbox.kind: proxy-net' "$ISOD4/eff/docker-compose.yml" \
  || fail "proxy networks must be labeled cbox.kind=proxy-net so an orphan sweep can reclaim them after a topology flip or project rename"
[ "$(grep -c 'cbox.component: internal' "$ISOD4/eff/docker-compose.yml")" -ge 1 ] || fail "internal proxy network must be labeled"
[ "$(grep -c 'cbox.component: egress' "$ISOD4/eff/docker-compose.yml")" -ge 1 ] || fail "egress proxy network must be labeled"
GCF="$TMPBASE/gc.sh"
{
  echo 'set -uo pipefail'
  awk '/^_cbox_gc_orphan_proxy_networks\(\) \{/,/^}$/' "$INSTALL_DIR/cbox"
} > "$GCF"
grep -qF 'label=cbox.kind=proxy-net' "$GCF" || fail "orphan proxy-net sweep must filter on the proxy-net label"
grep -qF 'len .Containers' "$GCF" || fail "orphan proxy-net sweep must only remove networks with zero endpoints"
_ok_render "proxy networks are labeled and a zero-endpoint sweep exists to reclaim orphans"

ISOD5="$TMPBASE/isolated-render-badport"
mkdir -p "$ISOD5/eff/claude-config/projects" "$ISOD5/claude" "$ISOD5/codex"
(
  set -e
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
  export CBOX_CLAUDE_PATH="$ISOD5/claude" CBOX_CODEX_PATH="$ISOD5/codex"
  export CBOX_EGRESS_MODE=off CBOX_EGRESS_APPLIED=0
  export CBOX_NETACCESS_MODE=socks CBOX_NETACCESS_APPLIED=1
  export CBOX_NETACCESS_SOCKS_PORT='1081; touch /pwned'
  export CBOX_OLLAMA_MODE=off
  export CBOX_LOCAL_MODEL_URL="" CBOX_HERMES_MODEL_URL="" CBOX_HERMES_DELEGATE_BASE_URL=""
  gen_compose_isolated "$ISOD5/eff" "$ISOP" testimg testhash123456 >/dev/null 2>&1
)
if grep -qF 'touch /pwned' "$ISOD5/eff/docker-compose.yml"; then
  fail "healthcheck must sanitize CBOX_NETACCESS_SOCKS_PORT before embedding it in the CMD-SHELL string (injected shell reached the healthcheck)"
fi
grep -qF 'nc -z -w 2 \"$$ip\" 1080' "$ISOD5/eff/docker-compose.yml" \
  || fail "a malformed SOCKS port must fall back to 1080 in the healthcheck, not be embedded raw"
_ok_render "healthcheck sanitizes a malformed CBOX_NETACCESS_SOCKS_PORT (no shell injection, falls back to 1080)"

VLF="$TMPBASE/verify_listener.sh"
{
  echo 'set -uo pipefail'
  echo '_cbox_netaccess_active() { [ "${CBOX_NETACCESS_MODE:-off}" != off ]; }'
  echo '_fake_exec_prefix() { echo cid123; }'
  echo 'docker() { echo "docker $*" > "$DOCKER_CMD_LOG"; return 1; }'
  awk '/^_cbox_netaccess_verify_listener\(\) \{/,/^}$/' "$INSTALL_DIR/cbox"
} > "$VLF"
[ -s "$VLF" ] || fail "could not extract _cbox_netaccess_verify_listener from cbox"
grep -q '_cbox_netaccess_verify_listener' "$VLF" || fail "extraction of _cbox_netaccess_verify_listener came up empty"

DOCKER_CMD_LOG="$TMPBASE/docker-cmd.log"
: > "$DOCKER_CMD_LOG"
DOCKER_CMD_LOG="$DOCKER_CMD_LOG" bash -c '
  . "$1"
  CBOX_NETACCESS_MODE=socks CBOX_NETACCESS_SOCKS_PORT='"'"'1081; touch /pwned'"'"'
  _cbox_netaccess_verify_listener "_fake_exec_prefix" >/dev/null 2>&1
' _ "$VLF" || true
vl_cmd="$(cat "$DOCKER_CMD_LOG")"
if printf '%s' "$vl_cmd" | grep -qF 'touch /pwned'; then
  fail "_cbox_netaccess_verify_listener must sanitize CBOX_NETACCESS_SOCKS_PORT before it reaches the docker exec sh -c string (injected shell leaked through)"
fi
printf '%s' "$vl_cmd" | grep -qF ' 1080' || fail "a malformed CBOX_NETACCESS_SOCKS_PORT must fall back to 1080 in the listener probe, got '$vl_cmd'"
echo "ok: _cbox_netaccess_verify_listener sanitizes a malformed CBOX_NETACCESS_SOCKS_PORT before building the docker exec probe string"

printf '%s' "$vl_cmd" | grep -qF '/run/cbox/internal-ip' || fail "_cbox_netaccess_verify_listener must prefer /run/cbox/internal-ip over the old /etc/cbox-generated path, got '$vl_cmd'"
printf '%s' "$vl_cmd" | grep -qF '/etc/cbox-generated/internal-ip' || fail "_cbox_netaccess_verify_listener must still fall back to /etc/cbox-generated/internal-ip, got '$vl_cmd'"
echo "ok: _cbox_netaccess_verify_listener prefers /run/cbox/internal-ip, falls back to /etc/cbox-generated/internal-ip"

RENDER_MODE_FN="$(awk '/^_cbox_netaccess_render\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
[ -n "$RENDER_MODE_FN" ] || fail "cannot extract _cbox_netaccess_render for the netmap-only mode check"

NETMAP_ONLY_SCRIPT="$TMPBASE/render-netmap-only.sh"
{
  echo 'set -uo pipefail'
  echo "INSTALL_DIR=\"$INSTALL_DIR\""
  echo 'PY_ARGS_LOG=""'
  echo 'python3() {'
  echo '  PY_ARGS_LOG="$*"'
  echo '  echo "{}"'
  echo '}'
  echo '_cbox_proxy_active() { return 0; }'
  echo '_cbox_netaccess_active() { return 0; }'
  echo '_cbox_netaccess_scope() { printf list; }'
  echo '_cbox_proxy_internal_alias() { printf cbox-proxy-internal; }'
  printf '%s\n' "$RENDER_MODE_FN"
} > "$NETMAP_ONLY_SCRIPT"

netmap_only_out="$(bash -c '
  . "$1"
  CBOX_NETACCESS_NETWORKS="project_a"
  _cbox_netaccess_render cid123 "$2" netmap-only
  printf "%s" "$PY_ARGS_LOG"
' _ "$NETMAP_ONLY_SCRIPT" "$TMPBASE/netmap-only-state")"
printf '%s' "$netmap_only_out" | grep -qF -- '--netmap-only' || fail "netmap-only mode must pass --netmap-only to cbox_netaccess.py, got: $netmap_only_out"
printf '%s' "$netmap_only_out" | grep -qF -- '--netmap-out' || fail "netmap-only mode must still pass --netmap-out, got: $netmap_only_out"
if printf '%s' "$netmap_only_out" | grep -qF -- '--scope list --network project_a --network'; then
  fail "netmap-only mode must not duplicate the network arguments, got: $netmap_only_out"
fi
echo "ok: _cbox_netaccess_render netmap-only mode calls cbox_netaccess.py with --netmap-only and --netmap-out"

SOCKD_START_PATH="$TMPBASE/sockd-live"
mkdir -p "$SOCKD_START_PATH/gen"
CBOX_NETACCESS_MODE=socks
CBOX_NETACCESS_APPLIED=1
CBOX_NETACCESS_SOCKS_PORT=1080
gen_sockd_conf_into "$SOCKD_START_PATH/gen" 172.20.0.2 172.20.0.0/24 '10.10.0.2,10.10.0.0/24'
[ -f "$SOCKD_START_PATH/gen/sockd-start.sh" ] || fail "gen_sockd_conf_into must render sockd-start.sh"

FAKE_IP_DIR="$TMPBASE/fake-ip-bin"
mkdir -p "$FAKE_IP_DIR"
FAKE_SOCKD="$TMPBASE/fake-sockd"
FAKE_SOCKD_LOG="$TMPBASE/fake-sockd.log"

cat > "$FAKE_SOCKD" <<'FAKESOCKD'
#!/bin/sh
echo "$@" >> "$FAKE_SOCKD_LOG"
FAKESOCKD
chmod +x "$FAKE_SOCKD"

write_fake_ip() {
  cat > "$FAKE_IP_DIR/ip" <<FAKEIP
#!/bin/sh
printf '%s\n' "$1"
FAKEIP
  chmod +x "$FAKE_IP_DIR/ip"
}

run_dir="$TMPBASE/sockd-run-unchanged"
mkdir -p "$run_dir"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 172.20.0.2/24 brd 172.20.0.255 scope global eth0
2: eth1    inet 10.10.0.2/24 brd 10.10.0.255 scope global eth1'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$SOCKD_START_PATH/gen" CBOX_SOCKD_RUN_DIR="$run_dir" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$SOCKD_START_PATH/gen/sockd-start.sh"
[ ! -f "$run_dir/sockd.conf" ] || fail "sockd-start.sh must exec the rendered file unchanged when live addresses match the render, not write a /run copy"
grep -qF -- "-f $SOCKD_START_PATH/gen/sockd.conf" "$FAKE_SOCKD_LOG" || fail "unchanged case must exec sockd on the rendered file, got: $(cat "$FAKE_SOCKD_LOG")"
[ "$(cat "$run_dir/internal-ip" 2>/dev/null)" = "172.20.0.2" ] || fail "fast path must still write the live internal address to run_dir/internal-ip, never leave it stale/absent"
echo "ok: sockd-start.sh execs the rendered config unchanged when live addresses match the render"

run_dir_egress="$TMPBASE/sockd-run-unchanged-egress"
mkdir -p "$run_dir_egress"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 172.20.0.2/24 brd 172.20.0.255 scope global eth0
2: eth1    inet 10.10.0.2/24 brd 10.10.0.255 scope global eth1
3: eth2    inet 192.168.77.5/24 brd 192.168.77.255 scope global eth2'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$SOCKD_START_PATH/gen" CBOX_SOCKD_RUN_DIR="$run_dir_egress" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$SOCKD_START_PATH/gen/sockd-start.sh"
[ ! -f "$run_dir_egress/sockd.conf" ] || fail "an always-present egress-interface address that no raw CIDR target needs must not force a rewrite of a still-correct rendered file"
grep -qF -- "-f $SOCKD_START_PATH/gen/sockd.conf" "$FAKE_SOCKD_LOG" || fail "unchanged-plus-egress case must exec sockd on the rendered file, got: $(cat "$FAKE_SOCKD_LOG")"
[ "$(cat "$run_dir_egress/internal-ip" 2>/dev/null)" = "172.20.0.2" ] || fail "fast path must write run_dir/internal-ip even when an extra live egress address is present"
echo "ok: sockd-start.sh ignores an extra live egress-interface address not referenced by the rendered external targets and still execs the rendered file"

run_dir2="$TMPBASE/sockd-run-changed"
mkdir -p "$run_dir2"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 172.20.0.9/24 brd 172.20.0.255 scope global eth0
2: eth1    inet 10.10.0.9/24 brd 10.10.0.255 scope global eth1'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$SOCKD_START_PATH/gen" CBOX_SOCKD_RUN_DIR="$run_dir2" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$SOCKD_START_PATH/gen/sockd-start.sh"
[ -f "$run_dir2/sockd.conf" ] || fail "sockd-start.sh must write a corrected copy to the run dir when live addresses differ"
grep -qF 'internal: 172.20.0.9 port = 1080' "$run_dir2/sockd.conf" || fail "corrected copy must carry the live internal address"
grep -qF 'external: 10.10.0.9' "$run_dir2/sockd.conf" || fail "corrected copy must carry the live external address"
grep -qF 'to: 172.20.0.9/32' "$run_dir2/sockd.conf" || fail "corrected copy must rewrite the client pass destination"
[ "$(cat "$run_dir2/internal-ip")" = "172.20.0.9" ] || fail "corrected copy must record the live internal-ip in the run dir"
grep -qF -- "-f $run_dir2/sockd.conf" "$FAKE_SOCKD_LOG" || fail "changed case must exec sockd on the corrected /run copy, got: $(cat "$FAKE_SOCKD_LOG")"
echo "ok: sockd-start.sh rewrites internal/external addresses and the client pass destination when live addresses differ, execs the corrected /run copy"

run_dir3="$TMPBASE/sockd-run-placeholder"
mkdir -p "$run_dir3"
gen_dir_ph="$TMPBASE/sockd-gen-placeholder"
mkdir -p "$gen_dir_ph"
gen_sockd_placeholder_into "$gen_dir_ph"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 172.20.0.9/24 brd 172.20.0.255 scope global eth0'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$gen_dir_ph" CBOX_SOCKD_RUN_DIR="$run_dir3" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$gen_dir_ph/sockd-start.sh"
[ ! -f "$run_dir3/sockd.conf" ] || fail "the fail-closed placeholder (no internal-cidr) must never produce a /run copy"
grep -qF -- "-f $gen_dir_ph/sockd.conf" "$FAKE_SOCKD_LOG" || fail "the placeholder must exec the rendered (loopback) file unchanged, got: $(cat "$FAKE_SOCKD_LOG")"
echo "ok: sockd-start.sh execs the fail-closed placeholder unchanged when internal-cidr is absent"

run_dir4="$TMPBASE/sockd-run-no-live-internal"
mkdir -p "$run_dir4"
STDERR4="$TMPBASE/sockd-stderr-no-live-internal.txt"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$SOCKD_START_PATH/gen" CBOX_SOCKD_RUN_DIR="$run_dir4" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$SOCKD_START_PATH/gen/sockd-start.sh" 2> "$STDERR4"
[ ! -f "$run_dir4/sockd.conf" ] || fail "must not produce a /run copy when no live address matches internal-cidr"
grep -qF -- "-f $SOCKD_START_PATH/gen/sockd.conf" "$FAKE_SOCKD_LOG" || fail "must exec the rendered file when no live internal address is found, got: $(cat "$FAKE_SOCKD_LOG")"
grep -qF 'no live IPv4 address found' "$STDERR4" || fail "must name the reason on stderr when the live internal address cannot be determined, got: $(cat "$STDERR4")"
echo "ok: sockd-start.sh prints the reason to stderr and execs the rendered file when no live address matches internal-cidr"

gen_dir_badcidr="$TMPBASE/sockd-gen-badcidr"
mkdir -p "$gen_dir_badcidr"
gen_sockd_conf_into "$gen_dir_badcidr" 172.20.0.2 172.20.0.0/24 ''
printf 'not-a-cidr\n' > "$gen_dir_badcidr/internal-cidr"
run_dir5="$TMPBASE/sockd-run-badcidr"
mkdir -p "$run_dir5"
STDERR5="$TMPBASE/sockd-stderr-badcidr.txt"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 172.20.0.2/24 brd 172.20.0.255 scope global eth0'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$gen_dir_badcidr" CBOX_SOCKD_RUN_DIR="$run_dir5" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$gen_dir_badcidr/sockd-start.sh" 2> "$STDERR5"
[ ! -f "$run_dir5/sockd.conf" ] || fail "must not produce a /run copy when internal-cidr is malformed"
grep -qF -- "-f $gen_dir_badcidr/sockd.conf" "$FAKE_SOCKD_LOG" || fail "must exec the rendered file when internal-cidr is malformed, got: $(cat "$FAKE_SOCKD_LOG")"
grep -qF 'is malformed' "$STDERR5" || fail "must name the reason on stderr when internal-cidr is malformed, got: $(cat "$STDERR5")"
echo "ok: sockd-start.sh falls back to the rendered file and warns on stderr when internal-cidr is malformed"

gen_dir_empty="$TMPBASE/sockd-gen-empty-targets"
mkdir -p "$gen_dir_empty"
gen_sockd_conf_into "$gen_dir_empty" 172.20.0.2 172.20.0.0/24 ''
run_dir6="$TMPBASE/sockd-run-empty-targets"
mkdir -p "$run_dir6"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 172.20.0.2/24 brd 172.20.0.255 scope global eth0'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$gen_dir_empty" CBOX_SOCKD_RUN_DIR="$run_dir6" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$gen_dir_empty/sockd-start.sh"
[ ! -f "$run_dir6/sockd.conf" ] || fail "empty targets_spec with an unchanged live internal address must exec the rendered file unchanged, not write a /run copy"
grep -qF -- "-f $gen_dir_empty/sockd.conf" "$FAKE_SOCKD_LOG" || fail "empty targets_spec with an unchanged live internal address must exec the rendered file, got: $(cat "$FAKE_SOCKD_LOG")"
[ "$(cat "$run_dir6/internal-ip" 2>/dev/null)" = "172.20.0.2" ] || fail "fast path with empty targets_spec must still write run_dir/internal-ip"
echo "ok: sockd-start.sh treats a rendered external equal to the internal address (empty targets_spec) as no external, execs the rendered file when live addresses are unchanged"

run_dir7="$TMPBASE/sockd-run-empty-targets-egress"
mkdir -p "$run_dir7"
: > "$FAKE_SOCKD_LOG"
write_fake_ip '1: eth0    inet 172.20.0.2/24 brd 172.20.0.255 scope global eth0
2: eth1    inet 192.168.88.4/24 brd 192.168.88.255 scope global eth1'
FAKE_SOCKD_LOG="$FAKE_SOCKD_LOG" PATH="$FAKE_IP_DIR:$PATH" \
  CBOX_SOCKD_GEN_DIR="$gen_dir_empty" CBOX_SOCKD_RUN_DIR="$run_dir7" CBOX_SOCKD_BIN="$FAKE_SOCKD" \
  sh "$gen_dir_empty/sockd-start.sh"
[ ! -f "$run_dir7/sockd.conf" ] || fail "no raw CIDR target needs the egress address - it must not force a rewrite when targets_spec is empty"
grep -qF -- "-f $gen_dir_empty/sockd.conf" "$FAKE_SOCKD_LOG" || fail "empty targets_spec plus a live egress address must still exec the rendered file, got: $(cat "$FAKE_SOCKD_LOG")"
[ "$(cat "$run_dir7/internal-ip" 2>/dev/null)" = "172.20.0.2" ] || fail "fast path with empty targets_spec and a live egress address must still write run_dir/internal-ip"
echo "ok: sockd-start.sh with empty targets_spec ignores a live egress address that no raw CIDR target needs"

CBOX_NETACCESS_MODE=socks
CBOX_NETACCESS_APPLIED=1
CBOX_NETACCESS_SCOPE=list
CBOX_NETACCESS_NETWORKS="project_a"
CBOX_NETACCESS_HOST_ALIASES="devel.zerolab.sk,api.zerolab.sk"
CBOX_HOST_GATEWAY_ALIAS=off
CBOX_HOST_ROUTE_MODE=off

host_alias_frag="$TMPBASE/host-alias-fragment"
: > "$host_alias_frag"
_cbox_extra_hosts_into "$host_alias_frag"
grep -qF '    extra_hosts:' "$host_alias_frag" || fail "host-alias extra_hosts block header missing"
grep -qF '      - "devel.zerolab.sk:127.0.0.1"' "$host_alias_frag" || fail "host-alias extra_hosts entry missing for devel.zerolab.sk"
grep -qF '      - "api.zerolab.sk:127.0.0.1"' "$host_alias_frag" || fail "host-alias extra_hosts entry missing for api.zerolab.sk"
echo "ok: _cbox_extra_hosts_into renders one extra_hosts entry per selected host-alias name, mapped to 127.0.0.1"

sysctl_frag="$TMPBASE/host-alias-sysctls"
: > "$sysctl_frag"
_cbox_netaccess_sysctls_into "$sysctl_frag"
grep -qF '    sysctls:' "$sysctl_frag" || fail "host-alias sysctls block header missing"
grep -qF '      - net.ipv4.ip_unprivileged_port_start=0' "$sysctl_frag" || fail "host-alias sysctls entry missing"
echo "ok: _cbox_netaccess_sysctls_into renders the unprivileged-port sysctl when host aliases are active"

CBOX_NETACCESS_HOST_ALIASES=off
host_alias_off_frag="$TMPBASE/host-alias-off-fragment"
: > "$host_alias_off_frag"
_cbox_extra_hosts_into "$host_alias_off_frag"
[ -s "$host_alias_off_frag" ] && fail "extra_hosts must render nothing when host aliases and host-gateway alias are both off" || true
sysctl_off_frag="$TMPBASE/host-alias-off-sysctls"
: > "$sysctl_off_frag"
_cbox_netaccess_sysctls_into "$sysctl_off_frag"
[ -s "$sysctl_off_frag" ] && fail "sysctls must render nothing when host aliases are off" || true
echo "ok: _cbox_extra_hosts_into and _cbox_netaccess_sysctls_into render nothing when host aliases are off"

CBOX_NETACCESS_MODE=off
CBOX_NETACCESS_APPLIED=0
CBOX_NETACCESS_HOST_ALIASES=off

echo "PASS: netaccess runtime rendering"
