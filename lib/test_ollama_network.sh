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
_ok "bash -n clean on cbox"

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

NAME_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_scope_network_name)"
LABELSOK_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_network_labels_ok)"
ENSURE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_ensure_scope_network)"
ENDPOINTS_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_endpoint_networks)"
CONNECT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_connect_scope_network)"
ERRLINE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_err_line)"
ONESCOPE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_one_scope)"
DISCONNECT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_disconnect_stale_scope_networks)"
PREFIX_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_scope_network_prefix)"
RECONCILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_networks_impl)"
GC_NET_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_gc_scope_networks_impl)"
RECONCILE_LOCK_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_networks)"
GC_NET_LOCK_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_gc_scope_networks)"
OWNERNAME_FN="$(_extract_fn "$INSTALL_DIR/templates/generators.sh" _cbox_ollama_owner_name)"
OWNERDIR_FN="$(_extract_fn "$INSTALL_DIR/templates/generators.sh" _cbox_ollama_owner_dir)"

for f in NAME_FN LABELSOK_FN ENSURE_FN ENDPOINTS_FN CONNECT_FN ERRLINE_FN ONESCOPE_FN DISCONNECT_FN PREFIX_FN RECONCILE_FN GC_NET_FN RECONCILE_LOCK_FN GC_NET_LOCK_FN OWNERNAME_FN OWNERDIR_FN; do
  [ -n "${!f}" ] || _fail "cannot extract $f"
done

run_name() {
  bash -c '
    set -u
    '"$NAME_FN"'
    id() { printf "1000"; }
    _cbox_ollama_scope_network_name "$1" "${2:-}"
  ' nametest "$@"
}

[ "$(run_name global)" = "cbox-ollama-u1000-global" ] || _fail "global scope network name mismatch"
[ "$(run_name isolated abc123def456)" = "cbox-ollama-u1000-pabc123def456" ] || _fail "isolated scope network name mismatch"
_ok "scope network naming: cbox-ollama-u<uid>-global and cbox-ollama-u<uid>-p<projecthash>"

run_labels_ok() {
  local labels="$1"
  bash -c '
    set -u
    '"$OWNERNAME_FN"'
    id() { printf "1000"; }
    '"$LABELSOK_FN"'
    docker() { printf "%s" "'"$labels"'"; }
    _cbox_ollama_network_labels_ok anynet
  ' labelstest
}

OWNER="$(bash -c '
  set -u
  '"$OWNERNAME_FN"'
  id() { printf "1000"; }
  _cbox_ollama_owner_name
' ownernametest)"

run_labels_ok "true|infra|ollama-net|$OWNER" && _ok "label check: internal + infra|ollama-net + matching owner accepted" \
  || _fail "label check rejected the correct labels"
! run_labels_ok "false|infra|ollama-net|$OWNER" || _fail "label check accepted a non-internal network"
! run_labels_ok "true|isolated||$OWNER" || _fail "label check accepted a non-infra network"
! run_labels_ok "true|infra|something-else|$OWNER" || _fail "label check accepted the wrong component"
! run_labels_ok "true|infra|ollama-net|someone-else" || _fail "label check accepted a mismatched cbox.owner"
_ok "label check: internal, kind, component, and owner must all match - any mismatch is rejected"

run_ensure() {
  local exists="$1" labels_ok="$2"
  bash -c '
    set -u
    CREATE_LOG="'"$TMPBASE"'/ensure.calls"
    : > "$CREATE_LOG"
    '"$OWNERNAME_FN"'
    id() { printf "1000"; }
    _cbox_ollama_network_labels_ok() { [ "'"$labels_ok"'" = 1 ]; }
    '"$ENSURE_FN"'
    docker() {
      case "$1" in
        network)
          case "$2" in
            inspect) [ "'"$exists"'" = 1 ] && return 0 || return 1 ;;
            create) echo "$*" >> "$CREATE_LOG"; return 0 ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_ensure_scope_network testnet
  ' ensuretest 2>&1
  echo "RC=$?"
}

out="$(run_ensure 0 0)"
echo "$out" | grep -q 'RC=0' || _fail "creating a fresh network must succeed: $out"
grep -q 'network create --internal' "$TMPBASE/ensure.calls" 2>/dev/null || _fail "ensure did not call docker network create --internal: $(cat "$TMPBASE/ensure.calls" 2>/dev/null)"
grep -q 'cbox.kind=infra' "$TMPBASE/ensure.calls" || _fail "created network missing cbox.kind=infra label"
grep -q 'cbox.component=ollama-net' "$TMPBASE/ensure.calls" || _fail "created network missing cbox.component=ollama-net label"
_ok "ensure_scope_network: a missing network is created --internal with cbox.kind=infra/cbox.component=ollama-net labels"

out="$(run_ensure 1 1)"
echo "$out" | grep -q 'RC=0' || _fail "an existing cbox-owned network must be accepted: $out"
[ ! -s "$TMPBASE/ensure.calls" ] || _fail "an already-existing network must not be re-created: $(cat "$TMPBASE/ensure.calls")"
_ok "ensure_scope_network: an existing cbox-owned network is idempotently accepted, never re-created"

out="$(run_ensure 1 0)"
echo "$out" | grep -q 'RC=1' || _fail "a name collision with a non-cbox network must be refused: $out"
echo "$out" | grep -qi 'refusing' || _fail "the refusal must be stated: $out"
_ok "ensure_scope_network: a name collision with a non-cbox-owned network is refused"

run_connect() {
  local ollama_has="$1" cbox_has="$2" connect_ollama_ok="$3" connect_cbox_ok="$4"
  bash -c '
    set -u
    CALLS="'"$TMPBASE"'/connect.calls"
    : > "$CALLS"
    '"$ENDPOINTS_FN"'
    '"$ERRLINE_FN"'
    '"$CONNECT_FN"'
    docker() {
      echo "$*" >> "$CALLS"
      case "$1" in
        inspect)
          if [ "$3" = ollama-cid ]; then
            [ "'"$ollama_has"'" = 1 ] && printf "testnet\n" || printf ""
          else
            [ "'"$cbox_has"'" = 1 ] && printf "testnet\n" || printf ""
          fi
          ;;
        network)
          case "$2" in
            connect)
              if [ "${@: -1}" = ollama-cid ]; then
                [ "'"$connect_ollama_ok"'" = 1 ] && return 0 || { echo "daemon-said-no-ollama" >&2; return 1; }
              else
                [ "'"$connect_cbox_ok"'" = 1 ] && return 0 || { printf "daemon-said-no-cbox\001\nsecond line hidden\n" >&2; return 1; }
              fi
              ;;
            disconnect) return 0 ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_connect_scope_network testnet ollama-cid cbox-cid
  ' connecttest 2>&1
  echo "RC=$?"
}

out="$(run_connect 0 0 1 1)"
echo "$out" | grep -q 'RC=0' || _fail "connecting both fresh endpoints must succeed: $out"
grep -q 'network connect --alias ollama -- testnet ollama-cid' "$TMPBASE/connect.calls" || _fail "ollama container must get the alias=ollama connect: $(cat "$TMPBASE/connect.calls")"
grep -q 'network connect -- testnet cbox-cid' "$TMPBASE/connect.calls" || _fail "cbox container must be connected without an alias: $(cat "$TMPBASE/connect.calls")"
_ok "connect_scope_network: both endpoints connected fresh, ollama container carries the 'ollama' alias"

out="$(run_connect 1 1 1 1)"
echo "$out" | grep -q 'RC=0' || _fail "already-attached endpoints must be a clean no-op: $out"
! grep -q 'network connect' "$TMPBASE/connect.calls" || _fail "already-attached endpoints must not be reconnected: $(cat "$TMPBASE/connect.calls")"
_ok "connect_scope_network: idempotent - already-attached endpoints are never reconnected"

out="$(run_connect 0 0 1 0)"
echo "$out" | grep -q 'RC=1' || _fail "a failed cbox-side connect must be reported as an error: $out"
grep -q 'network disconnect -f -- testnet ollama-cid' "$TMPBASE/connect.calls" || _fail "a failed cbox-side connect must roll back the ollama-side connect: $(cat "$TMPBASE/connect.calls")"
_ok "connect_scope_network: rollback - if the second endpoint's connect fails, the first endpoint's new attachment is rolled back"
echo "$out" | grep -q 'failed to attach cbox-cid to testnet: daemon-said-no-cbox$' || _fail "the daemon's own reason for a failed cbox-side connect must reach the operator as one clean line (first line only, control bytes stripped): $out"
! echo "$out" | grep -q 'second line hidden' || _fail "only the first line of the daemon error may reach the operator: $out"
out="$(run_connect 0 0 0 1)"
echo "$out" | grep -q 'RC=1' || _fail "a failed ollama-side connect must be reported as an error: $out"
echo "$out" | grep -q 'failed to attach ollama to testnet: daemon-said-no-ollama' || _fail "the daemon's own reason for a failed ollama-side connect must reach the operator: $out"
_ok "connect_scope_network: a failed connect carries the docker daemon's reason instead of a bare failure line"

RECONCILE_CALLS="$TMPBASE/reconcile.calls"
run_reconcile() {
  : > "$RECONCILE_CALLS"
  bash -c '
    set -u
    CALLS="'"$RECONCILE_CALLS"'"
    '"$OWNERDIR_FN"'
    '"$OWNERNAME_FN"'
    id() { printf "1000"; }
    HOME="'"$TMPBASE"'/home"
    mkdir -p "$(_cbox_ollama_owner_dir)"
    touch "$(_cbox_ollama_owner_dir)/docker-compose.yml"
    CBOX_OLLAMA_MODE=on
    COMPOSE=(docker compose -f /fake/docker-compose.yml)
    SERVICE=cbox
    _cbox_ollama_owner_compose() { docker "$@"; }
    _cbox_ollama_reconcile_one_scope() {
      echo "SCOPE $1 CID=$2 PHASH=$3 OLLAMA=$4" >> "$CALLS"
      return 0
    }
    _cbox_ollama_disconnect_stale_scope_networks() {
      echo "DISCONNECT-CHECK owner=$1" >> "$CALLS"
    }
    '"$RECONCILE_FN"'
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$*" in
        *"-q ollama"*) printf "ollama-cid\n" ;;
        *"cbox.kind=isolated"*) printf "iso-cid-1\tphash1\niso-cid-2\tphash2\n" ;;
        *"-q cbox"*) printf "global-cid\n" ;;
      esac
    }
    _cbox_ollama_reconcile_networks_impl
  ' reconciletest 2>&1
}

run_reconcile
grep -q 'SCOPE global CID=global-cid PHASH= OLLAMA=ollama-cid' "$RECONCILE_CALLS" || _fail "reconcile must cover the running global scope: $(cat "$RECONCILE_CALLS")"
grep -q 'SCOPE isolated CID=iso-cid-1 PHASH=phash1 OLLAMA=ollama-cid' "$RECONCILE_CALLS" || _fail "reconcile must cover every running isolated scope (1): $(cat "$RECONCILE_CALLS")"
grep -q 'SCOPE isolated CID=iso-cid-2 PHASH=phash2 OLLAMA=ollama-cid' "$RECONCILE_CALLS" || _fail "reconcile must cover every running isolated scope (2): $(cat "$RECONCILE_CALLS")"
_ok "reconcile_networks: enumerates the global scope (if running) and every running isolated scope, attaching each to ollama"

grep -q 'DISCONNECT-CHECK owner=' "$RECONCILE_CALLS" || _fail "reconcile must also sweep stale per-scope network attachments: $(cat "$RECONCILE_CALLS")"
_ok "reconcile_networks: also disconnects ollama from any per-scope network whose cbox container is gone (GC can then reclaim it)"

run_reconcile_off() {
  bash -c '
    set -u
    '"$OWNERDIR_FN"'
    HOME="'"$TMPBASE"'/home-off"
    CBOX_OLLAMA_MODE=off
    '"$RECONCILE_FN"'
    docker() { _fail_marker=1; }
    _cbox_ollama_reconcile_networks_impl
    echo "REACHED-END"
  ' reconcileofftest 2>&1
}
out="$(run_reconcile_off)"
echo "$out" | grep -q 'REACHED-END' || _fail "reconcile must return early (rc 0) when ollama is off: $out"
_ok "reconcile_networks: a clean no-op (returns immediately) when CBOX_OLLAMA_MODE is off"

DISCONNECT_CALLS="$TMPBASE/disconnect.calls"
run_disconnect_stale() {
  local members="$1"
  : > "$DISCONNECT_CALLS"
  bash -c '
    set -u
    CALLS="'"$DISCONNECT_CALLS"'"
    '"$PREFIX_FN"'
    '"$DISCONNECT_FN"'
    id() { printf "1000"; }
    docker() {
      echo "$*" >> "$CALLS"
      case "$1" in
        network)
          case "$2" in
            ls) printf "cbox-infra-u1000_default\ncbox-ollama-u1000-global\ncbox-ollama-u1000-pabc\n" ;;
            inspect) printf "%s\n" "'"$members"'" ;;
            disconnect) return 0 ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_disconnect_stale_scope_networks cbox-infra-u1000
  ' disconnecttest 2>&1
}

run_disconnect_stale 'cbox-infra-u1000-ollama-1'
grep -q 'network disconnect -- cbox-ollama-u1000-pabc cbox-infra-u1000-ollama-1' "$DISCONNECT_CALLS" || _fail "a per-scope network whose only member is the real compose-generated ollama container name must be disconnected from it: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: a per-scope network with only ollama attached (cbox side gone) is drained"

run_disconnect_stale 'cbox-infra-u1000-wireguard-1'
grep -q 'network disconnect -- cbox-ollama-u1000-pabc cbox-infra-u1000-wireguard-1' "$DISCONNECT_CALLS" || _fail "a per-scope network whose only member is the wireguard sidecar (dead project) must be drained too: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: a per-scope network holding only the wireguard sidecar hub is drained"

run_disconnect_stale 'cbox-infra-u1000-ollama-1
cbox-infra-u1000-wireguard-1'
grep -q 'network disconnect -- cbox-ollama-u1000-pabc cbox-infra-u1000-ollama-1' "$DISCONNECT_CALLS" || _fail "a dead project's network holding both hubs must be drained of ollama: $(cat "$DISCONNECT_CALLS")"
grep -q 'network disconnect -- cbox-ollama-u1000-pabc cbox-infra-u1000-wireguard-1' "$DISCONNECT_CALLS" || _fail "a dead project's network holding both hubs must be drained of the sidecar: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: a dead project's network holding both hubs (ollama + sidecar) is fully drained"

run_disconnect_stale 'cbox-infra-u1000-ollama-1
cbox-proj-live'
! grep -q 'network disconnect' "$DISCONNECT_CALLS" || _fail "a per-scope network still holding a session container must not be touched: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: a network with a live session container attached is left alone"

run_disconnect_stale 'my-ollama-project'
! grep -q 'network disconnect' "$DISCONNECT_CALLS" || _fail "a session container merely containing 'ollama' in its name must not be mistaken for the owner service: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: owner services are matched by exact compose name, never by substring"

run_disconnect_stale 'cbox-infra-u1000-ollama-1'
! grep -q 'network disconnect -- cbox-ollama-u1000-global' "$DISCONNECT_CALLS" || _fail "the global scope network must never be targeted: $(cat "$DISCONNECT_CALLS")"
! grep -q 'network disconnect -- cbox-infra-u1000_default' "$DISCONNECT_CALLS" || _fail "the owner project's own compose default network carries the same labels and must never be drained: $(cat "$DISCONNECT_CALLS")"
! grep -q 'network inspect.*cbox-infra-u1000_default' "$DISCONNECT_CALLS" || _fail "networks outside the per-scope name prefix must be skipped before any inspect: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: only cbox-ollama-u<uid>-p* networks are candidates - the global scope network and the owner's compose default network (same labels) are never touched"

run_gc_net() {
  local count="$1"
  bash -c '
    set -u
    CALLS="'"$TMPBASE"'/gc.calls"
    : > "$CALLS"
    '"$OWNERNAME_FN"'
    '"$PREFIX_FN"'
    id() { printf "1000"; }
    '"$GC_NET_FN"'
    docker() {
      echo "$*" >> "$CALLS"
      case "$1" in
        ps)
          case "$*" in
            *network=cbox-ollama-u1000-pabc*) printf "stoppedcid\n" ;;
          esac
          ;;
        network)
          case "$2" in
            ls) printf "cbox-infra-u1000_default\ncbox-ollama-u1000-global\ncbox-ollama-u1000-pabc\n" ;;
            inspect) printf "%s" "'"$count"'" ;;
            rm|disconnect) return 0 ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_gc_scope_networks_impl
  ' gcnettest 2>&1
}

run_gc_net 0
grep -q 'network rm -- cbox-ollama-u1000-global' "$TMPBASE/gc.calls" || _fail "gc must remove a per-scope network with zero attached endpoints: $(cat "$TMPBASE/gc.calls")"
grep -q 'network rm -- cbox-ollama-u1000-pabc' "$TMPBASE/gc.calls" || _fail "gc must remove an isolated per-scope network with zero attached endpoints: $(cat "$TMPBASE/gc.calls")"
! grep -q 'cbox-infra-u1000_default' "$TMPBASE/gc.calls" || _fail "gc must never touch the owner project's compose default network even at zero endpoints (ollama stopped) - removing it makes the next owner start fail with 'network not found' and forces a recreate that drops every per-scope attachment: $(cat "$TMPBASE/gc.calls")"
_ok "gc_scope_networks: zero-endpoint per-scope networks (global and isolated) are removed, the owner's compose default network never is"
disc_line="$(grep -n -x 'network disconnect -f -- cbox-ollama-u1000-pabc stoppedcid' "$TMPBASE/gc.calls" | head -n1 | cut -d: -f1 || true)"
rm_line="$(grep -n -x 'network rm -- cbox-ollama-u1000-pabc' "$TMPBASE/gc.calls" | head -n1 | cut -d: -f1 || true)"
[ -n "$disc_line" ] || _fail "gc must force-disconnect a stopped container that still references a zero-endpoint scope network - otherwise its next start fails with 'network <id> not found': $(cat "$TMPBASE/gc.calls")"
[ -n "$rm_line" ] && [ "$disc_line" -lt "$rm_line" ] || _fail "gc must disconnect stopped members before removing the network: $(cat "$TMPBASE/gc.calls")"
! grep -q 'network disconnect -f -- cbox-ollama-u1000-global' "$TMPBASE/gc.calls" || _fail "gc must disconnect only containers that reference the network: $(cat "$TMPBASE/gc.calls")"
_ok "gc_scope_networks: stopped containers still referencing a zero-endpoint scope network are disconnected before it is removed"

run_gc_net 2
! grep -q 'network rm' "$TMPBASE/gc.calls" || _fail "gc must not remove a per-scope network while endpoints remain attached: $(cat "$TMPBASE/gc.calls")"
! grep -q 'network disconnect' "$TMPBASE/gc.calls" || _fail "gc must not disconnect anything from a per-scope network with running endpoints: $(cat "$TMPBASE/gc.calls")"
_ok "gc_scope_networks: a labeled per-scope network with attached containers is left alone"

grep -q 'label=cbox.component=ollama-net' <(echo "$GC_NET_FN") || _fail "gc_scope_networks must filter strictly by the ollama-net component label"
grep -q 'label=cbox.owner=' <(echo "$GC_NET_FN") || _fail "gc_scope_networks must also filter by cbox.owner (never sweeps a different owner/user's networks)"
_ok "gc_scope_networks: enumeration is filtered by both the ollama-net component label and the current owner (never touches unrelated docker networks or another owner's)"

echo "$RECONCILE_LOCK_FN" | grep -q 'flock -x -w' || _fail "_cbox_ollama_reconcile_networks (public entry point) does not take a timed exclusive lock"
echo "$RECONCILE_LOCK_FN" | grep -q '_cbox_ollama_reconcile_networks_impl' || _fail "_cbox_ollama_reconcile_networks does not delegate to the _impl body while holding the lock"
_ok "reconcile_networks: the public entry point takes a timed flock before delegating to the actual reconciliation logic"

echo "$GC_NET_LOCK_FN" | grep -q 'flock -x -w' || _fail "_cbox_ollama_gc_scope_networks (public entry point) does not take a timed exclusive lock"
echo "$GC_NET_LOCK_FN" | grep -q '_cbox_ollama_gc_scope_networks_impl' || _fail "_cbox_ollama_gc_scope_networks does not delegate to the _impl body while holding the lock"
_ok "gc_scope_networks: the public entry point takes a timed flock before delegating to the actual sweep logic"

for callsite in _cbox_ollama_reconcile_cmd _cbox_ollama_up_cmd _cbox_ollama_down_cmd _cbox_ollama_pull_cmd; do
  BODY="$(_extract_fn "$INSTALL_DIR/cbox" "$callsite")"
  case "$BODY" in
    *'_cbox_ollama_reconcile_networks '*|*'_cbox_ollama_reconcile_networks'$'\n'*|*'_cbox_ollama_gc_scope_networks '*)
      echo "$BODY" | grep -qE '_cbox_ollama_(reconcile_networks|gc_scope_networks)\b[^_]' \
        && _fail "$callsite calls the locking wrapper while ollama_cmd already holds the same lock (self-deadlock risk): $BODY"
      ;;
  esac
  echo "$BODY" | grep -qE '_cbox_ollama_(reconcile_networks|gc_scope_networks)_impl' \
    || _fail "$callsite does not call the lock-free _impl variant (it runs while ollama_cmd already holds the machine lock)"
done
_ok "regression: reconcile/up/down/pull call the _impl network functions directly, avoiding a self-deadlock against the already-held ollama_cmd lock"

GC_FN="$(_extract_fn "$INSTALL_DIR/cbox" gc)"
[ -n "$GC_FN" ] || _fail "cannot extract gc"
echo "$GC_FN" | grep -q '_cbox_ollama_gc_scope_networks' || _fail "gc() does not call _cbox_ollama_gc_scope_networks"
_ok "wiring: gc() sweeps orphaned per-scope ollama networks"

UP_FN="$(_extract_fn "$INSTALL_DIR/cbox" up)"
[ -n "$UP_FN" ] || _fail "cannot extract global up()"
echo "$UP_FN" | grep -q '_cbox_ollama_reconcile_networks' || _fail "global up() does not reconcile ollama per-scope networks after the container starts"
_ok "wiring: global up() reconciles ollama per-scope networks host-side after the container starts"

SHELLISO_FN="$(_extract_fn "$INSTALL_DIR/cbox" shell_isolated)"
[ -n "$SHELLISO_FN" ] || _fail "cannot extract shell_isolated"
echo "$SHELLISO_FN" | grep -q '_cbox_ollama_reconcile_networks' || _fail "shell_isolated() does not reconcile ollama per-scope networks"
_ok "wiring: shell_isolated() reconciles ollama per-scope networks host-side after the container starts"

SESSIONRUN_FN="$(_extract_fn "$INSTALL_DIR/cbox" _session_run)"
[ -n "$SESSIONRUN_FN" ] || _fail "cannot extract _session_run"
echo "$SESSIONRUN_FN" | grep -q '_cbox_ollama_reconcile_networks' || _fail "_session_run() (used by cbox run in isolated mode) does not reconcile ollama per-scope networks"
_ok "wiring: _session_run() (cbox run, isolated mode) reconciles ollama per-scope networks host-side after the container starts"

OLLAMA_RECONCILE_CMD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_cmd)"
[ -n "$OLLAMA_RECONCILE_CMD_FN" ] || _fail "cannot extract _cbox_ollama_reconcile_cmd"
echo "$OLLAMA_RECONCILE_CMD_FN" | grep -q '_cbox_ollama_reconcile_networks' || _fail "cbox ollama reconcile does not restore per-scope network attachments after an owner recreate"
echo "$OLLAMA_RECONCILE_CMD_FN" | grep -q '_cbox_ollama_gc_scope_networks' || _fail "cbox ollama reconcile (mode-off teardown path) does not sweep orphaned per-scope networks"
_ok "wiring: cbox ollama reconcile restores every running scope's network attachment after an owner recreate, and sweeps networks when torn down"

OLLAMA_UP_CMD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_up_cmd)"
[ -n "$OLLAMA_UP_CMD_FN" ] || _fail "cannot extract _cbox_ollama_up_cmd"
echo "$OLLAMA_UP_CMD_FN" | grep -q '_cbox_ollama_reconcile_networks' || _fail "cbox ollama up does not reconcile per-scope networks"
_ok "wiring: cbox ollama up reconciles per-scope networks after bringing the owner up"

OLLAMA_DOWN_CMD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_down_cmd)"
[ -n "$OLLAMA_DOWN_CMD_FN" ] || _fail "cannot extract _cbox_ollama_down_cmd"
echo "$OLLAMA_DOWN_CMD_FN" | grep -q '_cbox_ollama_gc_scope_networks' || _fail "cbox ollama down does not sweep orphaned per-scope networks"
_ok "wiring: cbox ollama down sweeps per-scope networks after stopping the owner"

WG_ATTACH_ON_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_wg_client_attach_on)"
WG_CONNECT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_wg_connect_client_alias)"
WG_DETACH_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_wg_detach_client_alias)"
WG_DEFAULTNET_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_wg_infra_default_network)"
for f in WG_ATTACH_ON_FN WG_CONNECT_FN WG_DETACH_FN WG_DEFAULTNET_FN; do
  [ -n "${!f}" ] || _fail "cannot extract $f"
done

run_attach_on() {
  bash -c '
    set -u
    '"$WG_ATTACH_ON_FN"'
    _cbox_wg_active() { [ "$1" = active ]; }
    _cbox_wg_client_role() { [ "$2" = client ]; }
    _cbox_wg_active_arg="$1"; _cbox_wg_client_arg="$2"
    _cbox_wg_active() { [ "$_cbox_wg_active_arg" = active ]; }
    _cbox_wg_client_role() { [ "$_cbox_wg_client_arg" = client ]; }
    CBOX_WG_CLIENT_ATTACH="$3"
    _cbox_wg_client_attach_on && echo YES || echo NO
  ' attachontest "$@"
}
[ "$(run_attach_on active client on)" = YES ] || _fail "attach gate must open with wg active, client role, and the var on"
[ "$(run_attach_on active client off)" = NO ] || _fail "attach gate must stay closed with the var off"
[ "$(run_attach_on active server on)" = NO ] || _fail "attach gate must stay closed without the client role"
[ "$(run_attach_on inactive client on)" = NO ] || _fail "attach gate must stay closed with wg off"
_ok "wg client attach gate: needs wg active + client role + CBOX_WG_CLIENT_ATTACH=on, default off"

WGC_CALLS="$TMPBASE/wgconnect.calls"
run_wg_connect() {
  local scope="$1" cbox_nets="$2" wg_nets="$3" wg_cid="$4"
  : > "$WGC_CALLS"
  bash -c '
    set -u
    CALLS="'"$WGC_CALLS"'"
    '"$WG_CONNECT_FN"'
    '"$WG_DEFAULTNET_FN"'
    _cbox_ollama_owner_name() { printf "cbox-infra-u1000"; }
    _cbox_wg_client_alias() { printf "wg-remote-ollama"; }
    _cbox_wg_owner_container_id() { printf "%s" "'"$wg_cid"'"; }
    _cbox_wg_scope_forward_ensure() { echo "FWD-ENSURE $1 $2" >> "$CALLS"; return 0; }
    _cbox_ollama_ensure_scope_network() { echo "ENSURE $1" >> "$CALLS"; return 0; }
    _cbox_ollama_endpoint_networks() {
      if [ "$1" = wg-cid ]; then printf "%s\n" "'"$wg_nets"'"; else printf "%s\n" "'"$cbox_nets"'"; fi
    }
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$*" in
        "network ls"*) printf "infra_default\n" ;;
        "network connect"*) return 0 ;;
      esac
    }
    _cbox_wg_connect_client_alias "'"$scope"'" cbox-cid scopenet
  ' wgconnecttest 2>&1
  echo "RC=$?"
}

out="$(run_wg_connect global none none wg-cid)"
echo "$out" | grep -q 'RC=0' || _fail "global attach must succeed: $out"
grep -q 'docker network connect -- infra_default cbox-cid' "$WGC_CALLS" || _fail "global scope must join the shared infra default network: $(cat "$WGC_CALLS")"
! grep -q 'ENSURE' "$WGC_CALLS" || _fail "global scope must not touch per-project scope networks: $(cat "$WGC_CALLS")"
_ok "wg client attach: the global session container joins the shared infra default network directly"

out="$(run_wg_connect global infra_default none wg-cid)"
! grep -q 'network connect' "$WGC_CALLS" || _fail "an already-attached global container must not be reconnected: $(cat "$WGC_CALLS")"
_ok "wg client attach: global attach is idempotent"

out="$(run_wg_connect isolated none none wg-cid)"
echo "$out" | grep -q 'RC=0' || _fail "isolated attach must succeed: $out"
grep -q 'ENSURE scopenet' "$WGC_CALLS" || _fail "isolated scope must ensure its private scope network: $(cat "$WGC_CALLS")"
grep -q 'docker network connect --alias wg-remote-ollama -- scopenet wg-cid' "$WGC_CALLS" || _fail "the wireguard sidecar must join the scope network under the wg-remote-ollama alias: $(cat "$WGC_CALLS")"
grep -q 'docker network connect -- scopenet cbox-cid' "$WGC_CALLS" || _fail "the isolated container must join its own scope network: $(cat "$WGC_CALLS")"
! grep -q 'infra_default cbox-cid' "$WGC_CALLS" || _fail "an isolated container must NEVER join the shared infra default network: $(cat "$WGC_CALLS")"
grep -q 'FWD-ENSURE wg-cid scopenet' "$WGC_CALLS" || _fail "the isolated attach must also ensure the per-scope-network forwarder inside the sidecar (the supervisord one binds only the infra network address): $(cat "$WGC_CALLS")"
_ok "wg client attach: isolated projects get hub-and-spoke - sidecar aliased into the private scope network, never the shared network, with its per-network forwarder ensured"

out="$(run_wg_connect isolated scopenet scopenet wg-cid)"
! grep -q 'network connect' "$WGC_CALLS" || _fail "already-attached isolated endpoints must not be reconnected: $(cat "$WGC_CALLS")"
grep -q 'FWD-ENSURE wg-cid scopenet' "$WGC_CALLS" || _fail "the forwarder ensure must run even when the network memberships already exist (it heals a restarted sidecar): $(cat "$WGC_CALLS")"
_ok "wg client attach: isolated attach is idempotent, and the forwarder ensure still runs (sidecar-restart heal)"

out="$(run_wg_connect isolated none none "")"
echo "$out" | grep -q 'RC=0' || _fail "a missing sidecar container must be a clean no-op, not an error: $out"
! grep -q 'network connect' "$WGC_CALLS" || _fail "no sidecar, no attachments: $(cat "$WGC_CALLS")"
_ok "wg client attach: isolated attach is a clean no-op while the sidecar is not running"

WGD_CALLS="$TMPBASE/wgdetach.calls"
run_wg_detach() {
  local scope="$1" cbox_nets="$2" wg_nets="$3"
  : > "$WGD_CALLS"
  bash -c '
    set -u
    CALLS="'"$WGD_CALLS"'"
    '"$WG_DETACH_FN"'
    '"$WG_DEFAULTNET_FN"'
    _cbox_ollama_owner_name() { printf "cbox-infra-u1000"; }
    _cbox_wg_owner_container_id() { printf "wg-cid"; }
    _cbox_wg_scope_forward_stop() { echo "FWD-STOP $1 $2" >> "$CALLS"; }
    _cbox_ollama_endpoint_networks() {
      if [ "$1" = wg-cid ]; then printf "%s\n" "'"$wg_nets"'"; else printf "%s\n" "'"$cbox_nets"'"; fi
    }
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$*" in
        "network ls"*) printf "infra_default\n" ;;
        "network disconnect"*) return 0 ;;
      esac
    }
    _cbox_wg_detach_client_alias "'"$scope"'" cbox-cid scopenet
  ' wgdetachtest 2>&1
  echo "RC=$?"
}

out="$(run_wg_detach global infra_default none)"
grep -q 'docker network disconnect -- infra_default cbox-cid' "$WGD_CALLS" || _fail "detach must remove the global container from the shared infra network: $(cat "$WGD_CALLS")"
_ok "wg client detach: turning attach off removes the global session from the shared infra network"

out="$(run_wg_detach isolated scopenet scopenet)"
grep -q 'FWD-STOP wg-cid scopenet' "$WGD_CALLS" || _fail "detach must stop the per-scope-network forwarder before disconnecting the sidecar: $(cat "$WGD_CALLS")"
grep -q 'docker network disconnect -- scopenet wg-cid' "$WGD_CALLS" || _fail "detach must remove the sidecar hub from the per-project scope network: $(cat "$WGD_CALLS")"
! grep -q 'disconnect -- scopenet cbox-cid' "$WGD_CALLS" || _fail "detach must not touch the session container's own scope-network membership (the local-ollama path owns it): $(cat "$WGD_CALLS")"
_ok "wg client detach: the per-network forwarder is stopped, the sidecar hub leaves the per-project scope network; the session's own membership is left to the ollama path"

out="$(run_wg_detach global none none)"
! grep -q 'network disconnect' "$WGD_CALLS" || _fail "detach with nothing attached must be a no-op: $(cat "$WGD_CALLS")"
_ok "wg client detach: idempotent no-op when nothing is attached"

ONE_CALLS="$TMPBASE/onescope.calls"
run_one_scope_wg() {
  local ollama_cid="$1" attach="$2"
  : > "$ONE_CALLS"
  bash -c '
    set -u
    CALLS="'"$ONE_CALLS"'"
    '"$ONESCOPE_FN"'
    id() { printf "1000"; }
    _cbox_ollama_scope_network_name() { printf "scopenet"; }
    _cbox_ollama_ensure_scope_network() { echo "ENSURE $1" >> "$CALLS"; return 0; }
    _cbox_ollama_connect_scope_network() { echo "OLLAMA-CONNECT $1 $2 $3" >> "$CALLS"; return 0; }
    _cbox_wg_client_attach_on() { [ "'"$attach"'" = on ]; }
    _cbox_wg_connect_client_alias() { echo "WG-CONNECT $1 $2 $3" >> "$CALLS"; return 0; }
    _cbox_wg_detach_client_alias() { echo "WG-DETACH $1 $2 $3" >> "$CALLS"; return 0; }
    _cbox_ollama_reconcile_one_scope isolated cbox-cid phash1 "'"$ollama_cid"'"
  ' onescopewgtest 2>&1
  echo "RC=$?"
}

out="$(run_one_scope_wg "" on)"
echo "$out" | grep -q 'RC=0' || _fail "wg-only scope reconcile must succeed: $out"
! grep -q 'OLLAMA-CONNECT' "$ONE_CALLS" || _fail "with no ollama container there is nothing to attach ollama-side: $(cat "$ONE_CALLS")"
grep -q 'WG-CONNECT isolated cbox-cid scopenet' "$ONE_CALLS" || _fail "the wg attach must run even with local ollama off (the pure consumer case): $(cat "$ONE_CALLS")"
_ok "one_scope: a pure consumer (local ollama off, wg attach on) still gets its wg hub attachment"

out="$(run_one_scope_wg ollama-cid off)"
grep -q 'OLLAMA-CONNECT scopenet ollama-cid cbox-cid' "$ONE_CALLS" || _fail "the ollama path must be untouched by the wg gate: $(cat "$ONE_CALLS")"
grep -q 'WG-DETACH isolated cbox-cid scopenet' "$ONE_CALLS" || _fail "attach off must run the detach sweep: $(cat "$ONE_CALLS")"
_ok "one_scope: attach off keeps the ollama path and sweeps any prior wg attachments"

run_reconcile_wg_only() {
  bash -c '
    set -u
    CALLS="'"$RECONCILE_CALLS"'"
    '"$OWNERDIR_FN"'
    '"$OWNERNAME_FN"'
    id() { printf "1000"; }
    HOME="'"$TMPBASE"'/home-wgonly"
    mkdir -p "$(_cbox_ollama_owner_dir)"
    touch "$(_cbox_ollama_owner_dir)/docker-compose.yml"
    CBOX_OLLAMA_MODE=off
    _cbox_wg_active() { return 0; }
    _cbox_wg_client_role() { return 0; }
    COMPOSE=(docker compose -f /fake/docker-compose.yml)
    SERVICE=cbox
    _cbox_ollama_owner_compose() { docker "$@"; }
    _cbox_ollama_reconcile_one_scope() {
      echo "SCOPE $1 CID=$2 PHASH=$3 OLLAMA=$4" >> "$CALLS"
      return 0
    }
    _cbox_ollama_disconnect_stale_scope_networks() { :; }
    '"$RECONCILE_FN"'
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$*" in
        *"cbox.kind=isolated"*) printf "iso-cid-1\tphash1\n" ;;
        *"-q cbox"*) printf "global-cid\n" ;;
      esac
    }
    _cbox_ollama_reconcile_networks_impl
  ' reconcilewgonlytest 2>&1
}
: > "$RECONCILE_CALLS"
run_reconcile_wg_only >/dev/null
grep -q 'SCOPE global CID=global-cid PHASH= OLLAMA=$' "$RECONCILE_CALLS" || _fail "wg-only reconcile must cover the global scope with an empty ollama cid: $(cat "$RECONCILE_CALLS")"
grep -q 'SCOPE isolated CID=iso-cid-1 PHASH=phash1 OLLAMA=$' "$RECONCILE_CALLS" || _fail "wg-only reconcile must cover isolated scopes with an empty ollama cid: $(cat "$RECONCILE_CALLS")"
! grep -q 'docker compose.*-q ollama' "$RECONCILE_CALLS" || _fail "with ollama off the reconcile must not ask compose for an ollama container: $(cat "$RECONCILE_CALLS")"
_ok "reconcile_networks: runs for a wg client machine with local ollama off (the pure consumer), passing an empty ollama cid"

FWD_ENSURE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_wg_scope_forward_ensure)"
FWD_STOP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_wg_scope_forward_stop)"
SCOPE_IP_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_wg_scope_net_ip)"
for f in FWD_ENSURE_FN FWD_STOP_FN SCOPE_IP_FN; do
  [ -n "${!f}" ] || _fail "cannot extract $f"
done

FWD_CALLS="$TMPBASE/fwd.calls"
run_fwd_ensure() {
  local peer="$1" ip="$2"
  : > "$FWD_CALLS"
  bash -c '
    set -u
    CALLS="'"$FWD_CALLS"'"
    '"$FWD_ENSURE_FN"'
    '"$SCOPE_IP_FN"'
    CBOX_WG_PEER_ADDRESS="'"$peer"'"
    _cbox_wg_client_forward_port() { printf "11434"; }
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$1" in
        inspect) printf "%s" "'"$ip"'" ;;
        exec) return 0 ;;
      esac
    }
    _cbox_wg_scope_forward_ensure wg-cid scopenet
  ' fwdensuretest 2>&1
  echo "RC=$?"
}

out="$(run_fwd_ensure 10.90.0.1/32 172.30.0.2)"
echo "$out" | grep -q 'RC=0' || _fail "forwarder ensure with a resolvable scope-net address must succeed: $out"
grep -q 'bind=172.30.0.2,fork,reuseaddr TCP:10.90.0.1:11434' "$FWD_CALLS" || _fail "the forwarder must bind the sidecar's own scope-network address and dial the peer tunnel address on the fixed port: $(cat "$FWD_CALLS")"
grep -qE 'docker exec -d -- wg-cid /bin/sh -c .*pgrep -f' "$FWD_CALLS" || _fail "the forwarder start must be guarded by a pgrep so a live listener is never doubled: $(cat "$FWD_CALLS")"
_ok "wg scope forwarder: started inside the sidecar, bound to its scope-network address, dialing the peer tunnel address, idempotent via pgrep"

out="$(run_fwd_ensure 10.90.0.1/32 "")"
echo "$out" | grep -q 'RC=1' || _fail "no scope-network address yet must be a loud rc=1 (reconcile retries): $out"
echo "$out" | grep -q 'no address on scopenet' || _fail "the failure must say the sidecar has no address on the network yet: $out"
_ok "wg scope forwarder: a not-yet-addressed sidecar fails loudly instead of silently starting a dead listener"

out="$(run_fwd_ensure "" 172.30.0.2)"
echo "$out" | grep -q 'RC=0' || _fail "an empty peer address must be a clean no-op: $out"
! grep -q 'docker exec' "$FWD_CALLS" || _fail "no peer address, no forwarder: $(cat "$FWD_CALLS")"
_ok "wg scope forwarder: clean no-op while CBOX_WG_PEER_ADDRESS is unset"

run_fwd_stop() {
  local ip="$1"
  : > "$FWD_CALLS"
  bash -c '
    set -u
    CALLS="'"$FWD_CALLS"'"
    '"$FWD_STOP_FN"'
    '"$SCOPE_IP_FN"'
    docker() {
      echo "docker $*" >> "$CALLS"
      case "$1" in
        inspect) printf "%s" "'"$ip"'" ;;
        exec) return 0 ;;
      esac
    }
    _cbox_wg_scope_forward_stop wg-cid scopenet
  ' fwdstoptest 2>&1
  echo "RC=$?"
}

out="$(run_fwd_stop 172.30.0.2)"
grep -q "pkill -f 'bind=172.30.0.2,'" "$FWD_CALLS" || _fail "forwarder stop must pkill the listener bound to the scope-network address: $(cat "$FWD_CALLS")"
_ok "wg scope forwarder: detach kills the per-network listener by its bind address"

run_reconcile_sweep_off() {
  bash -c '
    set -u
    CALLS="'"$RECONCILE_CALLS"'"
    '"$OWNERDIR_FN"'
    '"$OWNERNAME_FN"'
    id() { printf "1000"; }
    HOME="'"$TMPBASE"'/home-sweepoff"
    mkdir -p "$(_cbox_ollama_owner_dir)"
    touch "$(_cbox_ollama_owner_dir)/docker-compose.yml"
    CBOX_OLLAMA_MODE=off
    COMPOSE=(docker compose -f /fake/docker-compose.yml)
    SERVICE=cbox
    _cbox_ollama_owner_compose() { docker "$@"; }
    _cbox_ollama_reconcile_one_scope() {
      echo "SCOPE $1 CID=$2 PHASH=$3 OLLAMA=$4" >> "$CALLS"
      return 0
    }
    _cbox_ollama_disconnect_stale_scope_networks() { :; }
    '"$RECONCILE_FN"'
    docker() {
      case "$*" in
        *"cbox.kind=isolated"*) printf "iso-cid-1\tphash1\n" ;;
        *"-q cbox"*) printf "global-cid\n" ;;
      esac
    }
    _cbox_ollama_reconcile_networks_impl
  ' reconcilesweepofftest 2>&1
}
: > "$RECONCILE_CALLS"
run_reconcile_sweep_off >/dev/null
grep -q 'SCOPE global CID=global-cid' "$RECONCILE_CALLS" || _fail "with the owner project still rendered, reconcile must enumerate scopes even when both modules are off, so the detach sweep can undo prior attachments: $(cat "$RECONCILE_CALLS")"
grep -q 'SCOPE isolated CID=iso-cid-1' "$RECONCILE_CALLS" || _fail "the module-off sweep must also cover isolated containers: $(cat "$RECONCILE_CALLS")"
_ok "reconcile_networks: while the owner project stays rendered, the sweep runs even with ollama and wg both off - turning modules off cannot strand attachments"

run_reconcile_all_off() {
  bash -c '
    set -u
    '"$OWNERDIR_FN"'
    HOME="'"$TMPBASE"'/home-alloff"
    CBOX_OLLAMA_MODE=off
    _cbox_wg_active() { return 1; }
    _cbox_wg_client_role() { return 1; }
    '"$RECONCILE_FN"'
    docker() { echo "DOCKER-TOUCHED"; }
    _cbox_ollama_reconcile_networks_impl
    echo "REACHED-END"
  ' reconcilealloff 2>&1
}
out="$(run_reconcile_all_off)"
echo "$out" | grep -q 'REACHED-END' || _fail "reconcile must return cleanly when the owner project is not rendered: $out"
! echo "$out" | grep -q 'DOCKER-TOUCHED' || _fail "reconcile must not touch docker while the owner project is not rendered: $out"
_ok "reconcile_networks: a clean no-op while the owner project is not rendered (nothing can be attached, nothing to sweep)"

echo "PASS: all ollama network checks"
