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
ONESCOPE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_one_scope)"
DISCONNECT_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_disconnect_stale_scope_networks)"
RECONCILE_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_networks_impl)"
GC_NET_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_gc_scope_networks_impl)"
RECONCILE_LOCK_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_networks)"
GC_NET_LOCK_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_gc_scope_networks)"
OWNERNAME_FN="$(_extract_fn "$INSTALL_DIR/templates/generators.sh" _cbox_ollama_owner_name)"
OWNERDIR_FN="$(_extract_fn "$INSTALL_DIR/templates/generators.sh" _cbox_ollama_owner_dir)"

for f in NAME_FN LABELSOK_FN ENSURE_FN ENDPOINTS_FN CONNECT_FN ONESCOPE_FN DISCONNECT_FN RECONCILE_FN GC_NET_FN RECONCILE_LOCK_FN GC_NET_LOCK_FN OWNERNAME_FN OWNERDIR_FN; do
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
                [ "'"$connect_ollama_ok"'" = 1 ] && return 0 || return 1
              else
                [ "'"$connect_cbox_ok"'" = 1 ] && return 0 || return 1
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
  local endpoint_count="$1" member="$2"
  : > "$DISCONNECT_CALLS"
  bash -c '
    set -u
    CALLS="'"$DISCONNECT_CALLS"'"
    '"$DISCONNECT_FN"'
    docker() {
      echo "$*" >> "$CALLS"
      case "$1" in
        network)
          case "$2" in
            ls) printf "cbox-ollama-u1000-pabc\n" ;;
            inspect)
              case "$*" in
                *"len .Containers"*) printf "%s" "'"$endpoint_count"'" ;;
                *) printf "%s\n" "'"$member"'" ;;
              esac
              ;;
            disconnect) return 0 ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_disconnect_stale_scope_networks myowner
  ' disconnecttest 2>&1
}

run_disconnect_stale 1 ollama
grep -q 'network disconnect -- cbox-ollama-u1000-pabc ollama' "$DISCONNECT_CALLS" || _fail "a per-scope network whose only member is ollama must be disconnected: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: a per-scope network with only ollama attached (cbox side gone) is disconnected from ollama"

run_disconnect_stale 2 ollama
! grep -q 'network disconnect' "$DISCONNECT_CALLS" || _fail "a per-scope network with both endpoints still attached must not be disconnected: $(cat "$DISCONNECT_CALLS")"
_ok "disconnect_stale_scope_networks: a per-scope network still holding both endpoints is left alone"

echo "$DISCONNECT_FN" | grep -q -- '-global' || _fail "disconnect_stale_scope_networks must skip the global scope network"
_ok "disconnect_stale_scope_networks: the global scope network is never targeted (it always has a live global container while ollama is up)"

run_gc_net() {
  local count="$1"
  bash -c '
    set -u
    CALLS="'"$TMPBASE"'/gc.calls"
    : > "$CALLS"
    '"$OWNERNAME_FN"'
    id() { printf "1000"; }
    '"$GC_NET_FN"'
    docker() {
      echo "$*" >> "$CALLS"
      case "$1" in
        network)
          case "$2" in
            ls) printf "cbox-ollama-u1000-global\n" ;;
            inspect) printf "%s" "'"$count"'" ;;
            rm) return 0 ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_gc_scope_networks_impl
  ' gcnettest 2>&1
}

run_gc_net 0
grep -q 'network rm -- cbox-ollama-u1000-global' "$TMPBASE/gc.calls" || _fail "gc must remove a per-scope network with zero attached endpoints: $(cat "$TMPBASE/gc.calls")"
_ok "gc_scope_networks: a labeled per-scope network with zero attached containers is removed"

run_gc_net 2
! grep -q 'network rm' "$TMPBASE/gc.calls" || _fail "gc must not remove a per-scope network while endpoints remain attached: $(cat "$TMPBASE/gc.calls")"
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

echo "PASS: all ollama network checks"
