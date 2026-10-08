#!/usr/bin/env bash
set -euo pipefail

for _v in $(compgen -e | grep -E '^(CBOX_|OLLAMA_)' || true); do
  unset "$_v"
done
unset _v TMUX TMUX_PANE

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

bash -n "$INSTALL_DIR/cbox" || _fail "cbox fails bash -n"

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

_load_fn() {
  local body
  body="$(_extract_fn "$INSTALL_DIR/cbox" "$1")"
  [ -n "$body" ] || _fail "cannot extract $1 from cbox"
  eval "$body"
}

for fn in \
  _cbox_ollama_endpoint_networks _cbox_ollama_err_line _cbox_ollama_connect_scope_network \
  _cbox_ollama_reconcile_one_scope _cbox_ollama_scope_network_prefix \
  _cbox_ollama_disconnect_stale_scope_networks _cbox_ollama_reconcile_networks_impl
do
  _load_fn "$fn"
done

CALLS="$TMPBASE/calls"
: > "$CALLS"
HOME="$TMPBASE/home"
export HOME
mkdir -p "$HOME"

id() {
  if [ "${1:-}" = "-u" ]; then printf '1000\n'; else command id "$@"; fi
}
_cbox_ollama_owner_name() { printf 'cbox-infra-u1000'; }
_cbox_ollama_owner_dir() { printf '%s/ollama-owner' "$HOME"; }
_cbox_ollama_scope_network_name() { printf 'scopenet'; }
_cbox_ollama_ensure_scope_network() { echo "ENSURE $1" >> "$CALLS"; return 0; }
_cbox_wg_client_attach_on() { return 1; }
_cbox_wg_detach_client_alias() { echo "WG-DETACH $1 $2 $3" >> "$CALLS"; return 0; }
_cbox_wg_connect_client_alias() { echo "WG-CONNECT $1 $2 $3" >> "$CALLS"; return 0; }

_reset() {
  : > "$CALLS"
  unset CBOX_OLLAMA_MODE CBOX_HYPERQWEN_MODE T_HAS_OLLAMA T_HAS_HQ T_CONNECT_RC T_HQ_CONNECT_RC T_MEMBERS T_WG_ATTACH
}

run_connect() {
  local ep_has="$1" cbox_has="$2" alias_arg="${3:-}"
  : > "$CALLS"
  (
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$1" in
        inspect)
          if [ "$3" = backend-cid ]; then
            [ "$ep_has" = 1 ] && printf 'testnet\n' || printf ''
          else
            [ "$cbox_has" = 1 ] && printf 'testnet\n' || printf ''
          fi
          ;;
        network) return 0 ;;
      esac
    }
    if [ -n "$alias_arg" ]; then
      _cbox_ollama_connect_scope_network testnet backend-cid cbox-cid "$alias_arg"
    else
      _cbox_ollama_connect_scope_network testnet backend-cid cbox-cid
    fi
  ) >/dev/null 2>&1
}

run_connect 0 0
grep -q 'docker network connect --alias ollama -- testnet backend-cid' "$CALLS" || _fail "the default alias must stay ollama: $(cat "$CALLS")"
run_connect 0 0 hyperqwen
grep -q 'docker network connect --alias hyperqwen -- testnet backend-cid' "$CALLS" || _fail "an explicit alias must be used for the backend attachment: $(cat "$CALLS")"
grep -q 'docker network connect -- testnet cbox-cid' "$CALLS" || _fail "the session container still connects without an alias: $(cat "$CALLS")"
run_connect 1 1 hyperqwen
! grep -q 'network connect' "$CALLS" || _fail "attached endpoints are never reconnected: $(cat "$CALLS")"
_ok "connect: alias argument defaults to ollama, hyperqwen alias honoured, idempotent"

run_one_scope() {
  local ollama_cid="$1" hq_cid="$2"
  : > "$CALLS"
  (
    _cbox_ollama_connect_scope_network() {
      echo "CONNECT $1 $2 $3 ${4:-ollama}" >> "$CALLS"
      [ "${T_CONNECT_RC:-0}" = 0 ] || [ "${4:-ollama}" = ollama ] || return 1
      return 0
    }
    _cbox_ollama_reconcile_one_scope isolated cbox-cid phash1 "$ollama_cid" "$hq_cid"
  )
}

_reset
run_one_scope ollama-cid ""
grep -q '^CONNECT scopenet ollama-cid cbox-cid ollama$' "$CALLS" || _fail "ollama-only attaches ollama with its alias: $(cat "$CALLS")"
[ "$(grep -c '^CONNECT' "$CALLS")" = 1 ] || _fail "ollama-only must attach exactly one backend: $(cat "$CALLS")"
_ok "one_scope: ollama only behaves as before"

_reset
run_one_scope ollama-cid hq-cid
grep -q '^CONNECT scopenet ollama-cid cbox-cid ollama$' "$CALLS" || _fail "both: ollama attached with alias ollama: $(cat "$CALLS")"
grep -q '^CONNECT scopenet hq-cid cbox-cid hyperqwen$' "$CALLS" || _fail "both: hyperqwen attached with alias hyperqwen: $(cat "$CALLS")"
_ok "one_scope: both running backends attached with their own aliases"

_reset
run_one_scope "" hq-cid
grep -q '^CONNECT scopenet hq-cid cbox-cid hyperqwen$' "$CALLS" || _fail "hyperqwen only: attached with its alias: $(cat "$CALLS")"
! grep -q 'cbox-cid ollama$' "$CALLS" || _fail "hyperqwen only: ollama must not be attached: $(cat "$CALLS")"
_ok "one_scope: hyperqwen alone is attached without ollama"

_reset
rc=0
run_one_scope "" "" || rc=$?
[ "$rc" = 0 ] || _fail "no backend is a clean no-op"
! grep -q '^CONNECT\|^ENSURE' "$CALLS" || _fail "no backend attaches nothing: $(cat "$CALLS")"
_ok "one_scope: no running backend attaches nothing"

_reset
export T_CONNECT_RC=1
rc=0
run_one_scope ollama-cid hq-cid || rc=$?
[ "$rc" = 1 ] || _fail "a failed hyperqwen attach must be reported"
grep -q '^CONNECT scopenet ollama-cid cbox-cid ollama$' "$CALLS" || _fail "a failed hyperqwen attach must not stop the ollama attach: $(cat "$CALLS")"
unset T_CONNECT_RC
_ok "one_scope: a failed hyperqwen attach is reported and does not block ollama"

run_reconcile() {
  local ollama_mode="$1" hq_mode="$2" has_ollama_dir="$3"
  : > "$CALLS"
  (
    rm -rf -- "$HOME/ollama-owner"
    if [ "$has_ollama_dir" = 1 ]; then
      mkdir -p "$HOME/ollama-owner"
      : > "$HOME/ollama-owner/docker-compose.yml"
    fi
    CBOX_OLLAMA_MODE="$ollama_mode"
    CBOX_HYPERQWEN_MODE="$hq_mode"
    COMPOSE=(docker compose -f /fake/docker-compose.yml)
    SERVICE=cbox
    _cbox_ollama_owner_compose() { echo "OLLAMA-COMPOSE $*" >> "$CALLS"; printf 'ollama-cid\n'; }
    _cbox_hyperqwen_owner_compose() { echo "HQ-COMPOSE $*" >> "$CALLS"; printf 'hq-cid\n'; }
    _cbox_ollama_reconcile_one_scope() {
      echo "SCOPE $1 CID=$2 PHASH=$3 OLLAMA=${4:-} HQ=${5:-}" >> "$CALLS"
      return 0
    }
    _cbox_ollama_disconnect_stale_scope_networks() { echo "DISCONNECT-CHECK" >> "$CALLS"; }
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$*" in
        *"cbox.kind=isolated"*) printf 'iso-cid-1\tphash1\n' ;;
        *"-q cbox"*) printf 'global-cid\n' ;;
      esac
    }
    _cbox_ollama_reconcile_networks_impl
  ) >/dev/null 2>&1
}

run_reconcile on on 1
grep -q 'SCOPE global CID=global-cid PHASH= OLLAMA=ollama-cid HQ=hq-cid' "$CALLS" || _fail "both on: the global scope carries both backend ids: $(cat "$CALLS")"
grep -q 'SCOPE isolated CID=iso-cid-1 PHASH=phash1 OLLAMA=ollama-cid HQ=hq-cid' "$CALLS" || _fail "both on: isolated scopes carry both backend ids: $(cat "$CALLS")"
grep -q 'HQ-COMPOSE ps -q hyperqwen' "$CALLS" || _fail "the hyperqwen container is looked up through its own owner project: $(cat "$CALLS")"
_ok "reconcile_networks: both backends on, every scope gets both container ids"

run_reconcile on off 1
grep -q 'SCOPE global CID=global-cid PHASH= OLLAMA=ollama-cid HQ=$' "$CALLS" || _fail "ollama only: identical to before, empty hyperqwen id: $(cat "$CALLS")"
! grep -q 'HQ-COMPOSE' "$CALLS" || _fail "ollama only must not ask the hyperqwen project anything: $(cat "$CALLS")"
_ok "reconcile_networks: ollama only is identical to before"

run_reconcile off on 0
grep -q 'SCOPE global CID=global-cid PHASH= OLLAMA= HQ=hq-cid' "$CALLS" || _fail "hyperqwen on with no ollama owner project must still reconcile: $(cat "$CALLS")"
grep -q 'SCOPE isolated CID=iso-cid-1 PHASH=phash1 OLLAMA= HQ=hq-cid' "$CALLS" || _fail "isolated scopes too: $(cat "$CALLS")"
! grep -q 'OLLAMA-COMPOSE' "$CALLS" || _fail "ollama off must not ask the ollama project: $(cat "$CALLS")"
_ok "reconcile_networks: independent of the ollama owner project when hyperqwen is on"

run_reconcile off off 0
[ ! -s "$CALLS" ] || _fail "everything off and nothing rendered is a clean no-op: $(cat "$CALLS")"
_ok "reconcile_networks: no backend and no owner project touches nothing"

run_reconcile off off 1
grep -q 'SCOPE global CID=global-cid' "$CALLS" || _fail "a rendered ollama project keeps the sweep alive with both off: $(cat "$CALLS")"
_ok "reconcile_networks: a rendered ollama project keeps the module-off sweep"

run_disconnect_stale() {
  local T_MEMBERS_TEXT="$1"
  : > "$CALLS"
  (
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$1" in
        network)
          case "$2" in
            ls) printf 'cbox-infra-u1000_default\ncbox-ollama-u1000-global\ncbox-ollama-u1000-pabc\n' ;;
            inspect) printf '%s\n' "$T_MEMBERS_TEXT" ;;
            disconnect) return 0 ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_disconnect_stale_scope_networks cbox-infra-u1000
  ) >/dev/null 2>&1
}

run_disconnect_stale 'cbox-infra-u1000-hyperqwen-hyperqwen-1'
grep -q 'network disconnect -- cbox-ollama-u1000-pabc cbox-infra-u1000-hyperqwen-hyperqwen-1' "$CALLS" || _fail "a network holding only the hyperqwen container must be drained: $(cat "$CALLS")"
_ok "stale members: the hyperqwen container is an infra member"

run_disconnect_stale 'cbox-infra-u1000-ollama-1
cbox-infra-u1000-hyperqwen-hyperqwen-1
cbox-infra-u1000-wireguard-1'
for m in cbox-infra-u1000-ollama-1 cbox-infra-u1000-hyperqwen-hyperqwen-1 cbox-infra-u1000-wireguard-1; do
  grep -q "network disconnect -- cbox-ollama-u1000-pabc $m" "$CALLS" || _fail "a dead project's network holding every infra service must drain $m: $(cat "$CALLS")"
done
_ok "stale members: ollama, hyperqwen and wireguard drain together"

run_disconnect_stale 'cbox-infra-u1000-hyperqwen-hyperqwen-1
cbox-proj-live'
! grep -q 'network disconnect' "$CALLS" || _fail "a network with a live session container is left alone: $(cat "$CALLS")"
run_disconnect_stale 'my-hyperqwen-hyperqwen-1'
! grep -q 'network disconnect' "$CALLS" || _fail "a foreign name containing hyperqwen is not an infra member: $(cat "$CALLS")"
run_disconnect_stale 'cbox-infra-u1000-hyperqwen-1'
! grep -q 'network disconnect' "$CALLS" || _fail "only the exact compose name of the hyperqwen service matches: $(cat "$CALLS")"
run_disconnect_stale 'cbox-infra-u1000-hyperqwen-hyperqwen-1x'
! grep -q 'network disconnect' "$CALLS" || _fail "the replica suffix must be numeric: $(cat "$CALLS")"
_ok "stale members: live sessions and look-alike names are never drained"

echo "PASS: all hyperqwen network checks"
