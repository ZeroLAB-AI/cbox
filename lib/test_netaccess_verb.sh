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

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

ADD_FN="$(_extract_fn "$INSTALL_DIR/cbox" _netaccess_set_add)"
DEL_FN="$(_extract_fn "$INSTALL_DIR/cbox" _netaccess_set_del)"
HAS_FN="$(_extract_fn "$INSTALL_DIR/cbox" _netaccess_set_has)"
[ -n "$HAS_FN" ] || _fail "cannot extract _netaccess_set_has"
CLS_FN="$(_extract_fn "$INSTALL_DIR/cbox" _netaccess_classify)"
VN_FN="$(_extract_fn "$INSTALL_DIR/cbox" _netaccess_valid_name)"
[ -n "$VN_FN" ] || _fail "cannot extract _netaccess_valid_name"
CHG_FN="$(_extract_fn "$INSTALL_DIR/cbox" _netaccess_change)"
SCOPE_FN="$(_extract_fn "$INSTALL_DIR/templates/generators.sh" _cbox_netaccess_scope)"
[ -n "$SCOPE_FN" ] || _fail "cannot extract the real _cbox_netaccess_scope from generators.sh"
CNET_FN="$(_extract_fn "$INSTALL_DIR/cbox" _netaccess_container_networks)"
for f in ADD_FN DEL_FN CLS_FN CHG_FN CNET_FN; do
  [ -n "${!f}" ] || _fail "cannot extract $f from cbox"
done

run_set_ops() {
  bash -c '
    set -u
    '"$ADD_FN"'
    '"$DEL_FN"'
    a="$(_netaccess_set_add "net1 net2" net3)" || a="REJECTED"
    printf "add-new:%s\n" "$a"
    b="$(_netaccess_set_add "net1 net2" net2)" && b="ACCEPTED:$b" || b="dup-rejected:$b"
    printf "add-dup:%s\n" "$b"
    printf "del-mid:%s\n" "$(_netaccess_set_del "net1 net2 net3" net2)"
    printf "del-absent:%s\n" "$(_netaccess_set_del "net1 net2" netX)"
    printf "del-last:[%s]\n" "$(_netaccess_set_del "net1" net1)"
  ' setops
}

out="$(run_set_ops)"
printf '%s\n' "$out" | grep -qx 'add-new:net1 net2 net3' || _fail "set_add must append: $out"
printf '%s\n' "$out" | grep -qx 'add-dup:dup-rejected:net1 net2' || _fail "set_add must signal a duplicate via exit status: $out"
printf '%s\n' "$out" | grep -qx 'del-mid:net1 net3' || _fail "set_del must remove the middle item: $out"
printf '%s\n' "$out" | grep -qx 'del-absent:net1 net2' || _fail "set_del of an absent item must be a no-op: $out"
printf '%s\n' "$out" | grep -qxF 'del-last:[]' || _fail "set_del of the only item must yield an empty set: $out"
_ok "set helpers: add is idempotent-by-status, del is exact and order-preserving"

run_classify() {
  bash -c '
    set -u
    '"$VN_FN"'
    '"$CLS_FN"'
    docker() {
      case "$1" in
        network) [ "${!#}" = "known-net" ] && return 0 || return 1 ;;
        *) [ "${!#}" = "known-ctr" ] && return 0 || return 1 ;;
      esac
    }
    for t in "10.42.0.0/16" "known-net" "known-ctr" "nope"; do
      k="$(_netaccess_classify "$t")" || k="UNRESOLVED"
      printf "%s=%s\n" "$t" "$k"
    done
  ' classify
}

out="$(run_classify)"
printf '%s\n' "$out" | grep -qx '10.42.0.0/16=cidr' || _fail "a slash must classify as cidr without touching docker: $out"
printf '%s\n' "$out" | grep -qx 'known-net=network' || _fail "known network misclassified: $out"
printf '%s\n' "$out" | grep -qx 'known-ctr=container' || _fail "known container misclassified: $out"
printf '%s\n' "$out" | grep -qx 'nope=UNRESOLVED' || _fail "unknown target must not resolve: $out"
_ok "classify: cidr by shape, then network, then container, else unresolved"

CFGLOG="$TMPBASE/config.calls"

run_change() {
  local scope="$1" action="$2"; shift 2
  : > "$CFGLOG"
  CFGLOG="$CFGLOG" CBOX_NETACCESS_SCOPE="$scope" CBOX_NETACCESS_NETWORKS="${NETS:-}" CBOX_NETACCESS_CIDRS="${CIDRS:-}" \
  bash -c '
    set -u
    '"$CHG_FN"'
    '"$ADD_FN"'
    '"$DEL_FN"'
    '"$HAS_FN"'
    '"$VN_FN"'
    '"$CLS_FN"'
    '"$CNET_FN"'
    '"$SCOPE_FN"'
    docker() {
      case "$1" in
        network) [ "${!#}" = "appnet" ] && return 0 || return 1 ;;
        *)
          case "${!#}" in
            multi-ctr) printf "frontnet\nbacknet\n"; return 0 ;;
            *) return 1 ;;
          esac
          ;;
      esac
    }
    _cbox_config_set() { printf "CONFIG_SET %s\n" "$*" >> "$CFGLOG"; }
    _netaccess_apply_now() { printf "APPLIED\n"; return 0; }
    _netaccess_change "$1" isolated /eff "${@:2}"
  ' change "$action" "$@" 2>&1
}

out="$(NETS="" run_change list allow appnet)"
grep -q 'CONFIG_SET CBOX_NETACCESS_NETWORKS=appnet' "$CFGLOG" || _fail "allow network must persist the network list: $out"
printf '%s\n' "$out" | grep -q '^APPLIED' || _fail "allow must apply to the running proxy: $out"
_ok "allow <network>: persists then applies"

out="$(NETS="appnet" run_change list allow appnet)"
printf '%s\n' "$out" | grep -q 'already allowed' || _fail "re-allowing must be reported as a no-op: $out"
! grep -q CONFIG_SET "$CFGLOG" || _fail "re-allowing must not rewrite the config: $out"
printf '%s\n' "$out" | grep -q 'APPLIED' && _fail "re-allowing must not restart the proxy: $out"
_ok "allow of an already-allowed target changes nothing"

out="$(NETS="" run_change list allow multi-ctr)"
printf '%s\n' "$out" | grep -q 'network frontnet (whole subnet, from container multi-ctr)' \
  || _fail "container target must expand to its networks and say so: $out"
printf '%s\n' "$out" | grep -q 'network backnet (whole subnet, from container multi-ctr)' \
  || _fail "container target must expand to EVERY network it is on: $out"
grep -q 'CONFIG_SET CBOX_NETACCESS_NETWORKS=frontnet backnet' "$CFGLOG" \
  || _fail "container expansion must persist all of its networks: $out"
_ok "allow <container>: expands to its networks and states the whole-subnet consequence"

out="$(NETS="appnet other" run_change list deny appnet)"
grep -q 'CONFIG_SET CBOX_NETACCESS_NETWORKS=other' "$CFGLOG" || _fail "deny must drop only the named network: $out"
printf '%s\n' "$out" | grep -q '^APPLIED' || _fail "deny must apply to the running proxy: $out"
_ok "deny <network>: drops one entry and applies"

out="$(NETS="appnet" run_change all deny appnet)" && _fail "deny under scope=all must fail" || true
printf '%s\n' "$out" | grep -q 'deny needs scope=list' || _fail "deny under scope=all must explain why: $out"
! grep -q CONFIG_SET "$CFGLOG" || _fail "refused deny must not touch the config: $out"
_ok "deny under scope=all is refused with the reason, config untouched"

out="$(NETS="" run_change all allow appnet)"
printf '%s\n' "$out" | grep -q 'scope=all already joins every eligible' || _fail "allow under scope=all must warn it is inert: $out"
grep -q 'CONFIG_SET' "$CFGLOG" || _fail "allow under scope=all should still record the entry: $out"
_ok "allow under scope=all warns that it changes nothing until scope=list"

out="$(NETS="" run_change list allow ghost)" && _fail "unresolvable target must fail" || true
printf '%s\n' "$out" | grep -q 'neither a docker network, a running container, nor a CIDR' || _fail "bad target must be named: $out"
! grep -q CONFIG_SET "$CFGLOG" || _fail "unresolvable target must not touch the config: $out"
_ok "unresolvable target fails closed before any config write"

out="$(CIDRS="" run_change list allow 10.9.0.0/16)"
grep -q 'CONFIG_SET CBOX_NETACCESS_NETWORKS= CBOX_NETACCESS_CIDRS=10.9.0.0/16' "$CFGLOG" \
  || _fail "cidr must land in the cidr list, not the network list: $out"
_ok "allow <cidr>: lands in the CIDR list"

out="$(NETS="" run_change list allow "bad name")" && _fail "a whitespace-bearing target must fail" || true
printf '%s\n' "$out" | grep -q 'neither a docker network' || _fail "whitespace target must be rejected, not split: $out"
! grep -q CONFIG_SET "$CFGLOG" || _fail "whitespace target must not reach the config: $out"
_ok "a target name with whitespace is rejected instead of splitting into two entries"

out="$(NETS="other" run_change list deny appnet)"
! grep -q CONFIG_SET "$CFGLOG" \
  || _fail "denying a live-but-unallowed network must not rewrite the config: $out"
printf '%s\n' "$out" | grep -q 'was not allowed' \
  || _fail "denying something that was not in the set must say so, not claim a removal: $out"
printf '%s\n' "$out" | grep -q 'APPLIED' \
  && _fail "denying a live-but-unallowed network must not restart the proxy: $out"
_ok "deny of a live but unallowed network is a no-op, not a false removal"

out="$(NETS="ghostnet other" run_change list deny ghostnet)"
grep -q 'CONFIG_SET CBOX_NETACCESS_NETWORKS=other' "$CFGLOG" \
  || _fail "deny must work for an entry whose docker network no longer exists: $out"
_ok "deny of a vanished network still removes it from the allowed set"

out="$(NETS="onlynet" run_change "" deny onlynet)"
grep -q 'CONFIG_SET .*CBOX_NETACCESS_SCOPE=list' "$CFGLOG" \
  || _fail "denying the last entry with no explicit scope must pin scope=list, else the empty set re-infers to all: $out"
printf '%s\n' "$out" | grep -q 'pinning CBOX_NETACCESS_SCOPE=list' \
  || _fail "the scope pin must be stated, not silent: $out"
_ok "deny of the last entry pins scope=list instead of silently falling back to all"

out="$(NETS="onlynet" run_change list deny onlynet)"
! grep -q 'CBOX_NETACCESS_SCOPE' "$CFGLOG" \
  || _fail "an already-explicit scope must not be rewritten: $out"
_ok "an explicitly pinned scope is left alone when the set empties"

out="$(NETS="a b" run_change "" deny a)"
! grep -q 'CBOX_NETACCESS_SCOPE' "$CFGLOG" \
  || _fail "a non-empty remainder must not trigger the scope pin: $out"
_ok "the scope pin fires only when the set actually becomes empty"

grep -q 'netaccess) shift; netaccess_cmd "$@";;' "$INSTALL_DIR/cbox" || _fail "netaccess verb not wired into the dispatcher"
grep -q 'netaccess {status|allow|deny}' "$INSTALL_DIR/cbox" || _fail "netaccess missing from usage"
grep -q 'HUB_ROWS+=("netaccess")' "$INSTALL_DIR/cbox" || _fail "netaccess row missing from the hub"
grep -q 'netaccess) _hub_netaccess_submenu' "$INSTALL_DIR/cbox" || _fail "netaccess row not dispatched in the hub"
_ok "wiring: dispatcher, usage, hub row and hub dispatch all present"

echo "PASS: all netaccess verb checks"
