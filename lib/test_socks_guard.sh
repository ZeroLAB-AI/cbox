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

HARNESS="$TMPBASE/socks_harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  awk '/^_socks_proxy_port\(\) \{/,/^}$/' "$INSTALL_DIR/entrypoint.sh"
  awk '/^_socks_alive\(\) \{/,/^}$/' "$INSTALL_DIR/entrypoint.sh"
  awk '/^_guard_socks_proxy\(\) \{/,/^}$/' "$INSTALL_DIR/entrypoint.sh"
} > "$HARNESS"

grep -q '_socks_proxy_port' "$HARNESS" || _fail "could not extract _socks_proxy_port from entrypoint.sh"
grep -q '_socks_alive' "$HARNESS" || _fail "could not extract _socks_alive from entrypoint.sh"
grep -q '_guard_socks_proxy' "$HARNESS" || _fail "could not extract _guard_socks_proxy from entrypoint.sh"

port_of() {
  bash -c '. "$1"; CBOX_SOCKS_PROXY="$2"; _socks_proxy_port' _ "$HARNESS" "$1"
}

[ "$(port_of socks5h://proxy:1080)" = 1080 ] || _fail "port parse 1080"
[ "$(port_of socks5h://proxy:1081)" = 1081 ] || _fail "port parse 1081"
port_of socks5h://proxy:garbage >/dev/null 2>&1 && _fail "garbage port must be rejected" || true
port_of socks5h://proxy:99999 >/dev/null 2>&1 && _fail "out-of-range port must be rejected" || true
port_of socks5h://proxy: >/dev/null 2>&1 && _fail "empty port must be rejected" || true
_ok "socks proxy port parse accepts valid, rejects garbage/oor/empty"

guard() {
  bash -c '
    . "$1"
    _alive_port="$3"
    CBOX_SOCKS_PROXY="$2"; ALL_PROXY="$2"; all_proxy="$2"
    _socks_alive() { [ "$2" = "$_alive_port" ]; }
    _guard_socks_proxy 2>/dev/null
    printf "%s|%s|%s" "${CBOX_SOCKS_PROXY:-}" "${ALL_PROXY:-}" "${all_proxy:-}"
  ' _ "$HARNESS" "$1" "$2"
}

out="$(guard socks5h://proxy:1088 1088)"
[ "$out" = "socks5h://proxy:1088|socks5h://proxy:1088|socks5h://proxy:1088" ] \
  || _fail "live proxy must keep all three vars, got '$out'"
_ok "live SOCKS proxy keeps ALL_PROXY/all_proxy/CBOX_SOCKS_PROXY"

out="$(guard socks5h://proxy:1080 9999)"
[ "$out" = "||" ] || _fail "dead proxy must unset all three vars, got '$out'"
_ok "dead SOCKS proxy drops the proxy vars (falls back to direct egress)"

out="$(guard socks5h://proxy:garbage 9999)"
[ "$out" = "||" ] || _fail "malformed CBOX_SOCKS_PROXY must unset all three vars, got '$out'"
_ok "malformed CBOX_SOCKS_PROXY drops the proxy vars"

out="$(bash -c '
  . "$1"
  _socks_alive() { return 0; }
  unset CBOX_SOCKS_PROXY; ALL_PROXY="socks5h://proxy:1080"; all_proxy="$ALL_PROXY"
  _guard_socks_proxy 2>/dev/null
  printf "%s|%s|%s" "${CBOX_SOCKS_PROXY:-}" "${ALL_PROXY:-}" "${all_proxy:-}"
' _ "$HARNESS")"
[ "$out" = "||" ] || _fail "ALL_PROXY set without CBOX_SOCKS_PROXY must unset all, got '$out'"
_ok "ALL_PROXY set but CBOX_SOCKS_PROXY unset falls back to direct egress"

out="$(bash -c '. "$1"; _socks_alive() { return 0; }; unset CBOX_SOCKS_PROXY ALL_PROXY all_proxy; _guard_socks_proxy && echo noop-ok' _ "$HARNESS")"
[ "$out" = noop-ok ] || _fail "no-proxy path must be a clean no-op"
_ok "no proxy configured is a clean no-op"

echo "PASS: socks proxy guard"
