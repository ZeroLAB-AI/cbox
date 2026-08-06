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

FAKE_DOCKER="$TMPBASE/docker"
CONNECTED_FILE="$TMPBASE/connected-networks"
: > "$CONNECTED_FILE"
cat > "$FAKE_DOCKER" <<FAKEDOCKER
#!/usr/bin/env bash
set -euo pipefail
CONNECTED_FILE="$CONNECTED_FILE"
FAKEDOCKER
cat >> "$FAKE_DOCKER" <<'FAKEDOCKER'
case "$1" in
  network)
    case "$2" in
      ls)
        printf 'cbox-p1_internal\ncbox-p1_egress\nproject_a\ncbox-ollama-u1000-global\ncbox-ollama-u1000-p1\n'
        ;;
      inspect)
        name="$3"
        case "$name" in
          cbox-p1_internal)
            printf '[{"Driver":"bridge","Labels":{"com.docker.compose.project":"cbox-p1","com.docker.compose.network":"internal"},"IPAM":{"Config":[{"Subnet":"172.20.0.0/24"}]}}]'
            ;;
          cbox-p1_egress)
            printf '[{"Driver":"bridge","Labels":{"com.docker.compose.project":"cbox-p1","com.docker.compose.network":"egress"},"IPAM":{"Config":[{"Subnet":"172.21.0.0/24"}]}}]'
            ;;
          project_a)
            printf '[{"Driver":"bridge","Labels":{},"IPAM":{"Config":[{"Subnet":"10.10.0.0/24"}]}}]'
            ;;
          cbox-ollama-u1000-global|cbox-ollama-u1000-p1)
            printf '[{"Driver":"bridge","Labels":{"cbox.kind":"infra","cbox.component":"ollama-net"},"IPAM":{"Config":[{"Subnet":"10.55.0.0/24"}]}}]'
            ;;
          *)
            exit 1
            ;;
        esac
        ;;
      connect)
        echo "$3" >> "$CONNECTED_FILE"
        exit 0
        ;;
      disconnect)
        exit 0
        ;;
    esac
    ;;
  inspect)
    extra=""
    if grep -qxF "project_a" "$CONNECTED_FILE" 2>/dev/null; then
      extra=',"project_a":{"IPAddress":"10.10.0.2"}'
    fi
    printf '[{"Config":{"Labels":{"com.docker.compose.project":"cbox-p1"}},"NetworkSettings":{"Networks":{"cbox-p1_internal":{"IPAddress":"172.20.0.2"},"cbox-p1_egress":{"IPAddress":"172.21.0.2"}%s}}}]' "$extra"
    ;;
  *)
    exit 1
    ;;
esac
FAKEDOCKER
chmod +x "$FAKE_DOCKER"

STATE_DIR="$TMPBASE/netaccess-state"
mkdir -p "$STATE_DIR"
out="$(python3 "$INSTALL_DIR/lib/cbox_netaccess.py" --docker-bin "$FAKE_DOCKER" --container proxy-cid --state-dir "$STATE_DIR" --scope all)"
printf '%s\n' "$out" | grep -qF '"appliedNetworks":["project_a"]' || _fail "scope=all CLI must select only the eligible project network: $out"
printf '%s\n' "$out" | grep -qF '"cbox-ollama-u1000-global"' || _fail "scope=all CLI must name the rejected global ollama network in skipped[]: $out"
printf '%s\n' "$out" | grep -qF '"cbox-ollama-u1000-p1"' || _fail "scope=all CLI must name the rejected per-project ollama network in skipped[]: $out"
_ok "scope=all end-to-end (real cbox_netaccess.py CLI, stubbed docker): per-scope ollama model networks are rejected alongside the compose internal/egress networks, never joined"

out="$(python3 "$INSTALL_DIR/lib/cbox_netaccess.py" --docker-bin "$FAKE_DOCKER" --container proxy-cid --state-dir "$STATE_DIR" --scope list --network project_a --network markiza-cloud-network)"
printf '%s\n' "$out" | grep -qF '"appliedNetworks":["project_a"]' || _fail "scope=list CLI must still apply the live granted network when another grant is absent: $out"
printf '%s\n' "$out" | grep -qF '"network":"markiza-cloud-network"' || _fail "scope=list CLI must name the absent granted network in skipped[]: $out"
printf '%s\n' "$out" | grep -qF '"requested":true' || _fail "scope=list CLI must mark the absent granted network as requested (not scope=all noise): $out"
_ok "scope=list end-to-end (real cbox_netaccess.py CLI, stubbed docker): an absent granted network is skipped, not fatal - the live granted network still applies"

RENDER_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_netaccess_render)"
[ -n "$RENDER_FN" ] || _fail "cannot extract _cbox_netaccess_render from cbox"

RENDER_SCRIPT="$TMPBASE/render.sh"
{
  echo 'set -uo pipefail'
  echo "INSTALL_DIR=\"$INSTALL_DIR\""
  echo '_cbox_proxy_active() { return 0; }'
  echo '_cbox_netaccess_active() { return 0; }'
  echo '_cbox_netaccess_scope() { printf list; }'
  echo '_cbox_egress_active() { return 1; }'
  echo 'gen_sockd_conf_into() { :; }'
  echo 'gen_tinyproxy_conf_into() { :; }'
  printf '%s\n' "$RENDER_FN"
} > "$RENDER_SCRIPT"

RENDER_STATE="$TMPBASE/render-state"
mkdir -p "$RENDER_STATE"
RENDER_BIN_DIR="$TMPBASE/render-bin"
mkdir -p "$RENDER_BIN_DIR"
ln -sf "$FAKE_DOCKER" "$RENDER_BIN_DIR/docker"
render_err="$(CBOX_NETACCESS_NETWORKS="project_a markiza-cloud-network" PATH="$RENDER_BIN_DIR:$PATH" bash -c '
  . "$1"
  _cbox_netaccess_render proxy-cid "$2"
' render "$RENDER_SCRIPT" "$RENDER_STATE" 2>&1 >/dev/null)" || true
printf '%s\n' "$render_err" | grep -qF 'cbox: netaccess: SKIPPING granted network markiza-cloud-network' \
  || _fail "_cbox_netaccess_render must print a loud stderr warning for an absent granted network: $render_err"
printf '%s\n' "$render_err" | grep -qiF 'ollama' && _fail "_cbox_netaccess_render must not warn about scope=all infrastructure noise under scope=list: $render_err"
_ok "_cbox_netaccess_render warns loudly, once per absent granted network, on stderr"

echo "PASS: all netaccess verb checks"
