#!/usr/bin/env bash
set -uo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

while IFS='=' read -r _cbox_env_name _; do
  case "$_cbox_env_name" in
    CBOX_*|OLLAMA_*|HERMES_*) unset "$_cbox_env_name" ;;
  esac
done < <(env)

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

source "$INSTALL_DIR/lib/portable.sh"
source "$INSTALL_DIR/templates/generators.sh"
XDG_RUNTIME_DIR="$TMPBASE/runtime"

_expected_active() {
  local applied="$1" mode="$2" scope="$3" nets="$4"
  [ "$applied" = 1 ] || { echo no; return; }
  case "$mode" in
    scoped) [ "$scope" = list ] && [ -n "$nets" ] && { echo yes; return; } ;;
    all)
      if [ "$scope" = list ]; then
        [ -n "$nets" ] && { echo yes; return; }
      else
        echo yes; return
      fi
      ;;
  esac
  echo no
}

CASES=0
for applied in 0 1; do
  for mode in off scoped all; do
    for scope in list all; do
      for nets in "" "net_a net_b"; do
        CBOX_NETACCESS_MODE=socks
        CBOX_NETACCESS_APPLIED="$applied"
        CBOX_NETACCESS_EXEC_MODE="$mode"
        CBOX_NETACCESS_SCOPE="$scope"
        CBOX_NETACCESS_NETWORKS="$nets"
        want="$(_expected_active "$applied" "$mode" "$scope" "$nets")"
        if _cbox_netaccess_exec_active; then got=yes; else got=no; fi
        [ "$got" = "$want" ] || _fail "exec active matrix: applied=$applied mode=$mode scope=$scope nets='$nets' expected $want got $got"
        frag="$TMPBASE/frag.$CASES"
        : > "$frag"
        _cbox_container_exec_mounts_into "$frag" x1
        _cbox_container_exec_env_into "$frag"
        if grep -q 'cbox-container-exec' "$frag"; then rendered=yes; else rendered=no; fi
        [ "$rendered" = "$want" ] || _fail "compose mount: applied=$applied mode=$mode scope=$scope nets='$nets' expected rendered=$want got $rendered"
        if [ "$want" = yes ]; then
          grep -q ':/run/cbox-container-exec:ro$' "$frag" || _fail "compose mount must be read-only"
          grep -q 'CBOX_CONTAINER_EXEC_TIMEOUT=' "$frag" || _fail "exec client env missing while active"
        fi
        CASES=$((CASES + 1))
      done
    done
  done
done
_ok "exec active matrix and compose mount rendering agree for $CASES combinations"

CBOX_NETACCESS_MODE=off
CBOX_NETACCESS_APPLIED=1
CBOX_NETACCESS_EXEC_MODE=all
CBOX_NETACCESS_SCOPE=all
CBOX_NETACCESS_NETWORKS=""
if _cbox_netaccess_exec_active; then _fail "exec must be inactive when netaccess mode is off"; fi
_ok "exec inactive when netaccess mode is off even with exec mode all"

CBOX_NETACCESS_SCOPE=""
CBOX_NETACCESS_NETWORKS="net_a"
CBOX_NETACCESS_MODE=socks
CBOX_NETACCESS_EXEC_MODE=all
_cbox_netaccess_exec_active || _fail "legacy empty scope with networks resolves to list and exec all must be active"
_ok "legacy empty scope with a network list resolves to list and exec all is active"

_reason() {
  CBOX_NETACCESS_MODE="$1" CBOX_NETACCESS_APPLIED="$2" CBOX_NETACCESS_EXEC_MODE="$3" CBOX_NETACCESS_SCOPE="$4" CBOX_NETACCESS_NETWORKS="$5" \
    _cbox_netaccess_exec_inactive_reason
}

r="$(_reason off 1 all all "")"
case "$r" in *"netaccess mode is off"*) ;; *) _fail "reason for netaccess off: $r" ;; esac
r="$(_reason socks 0 all all "")"
case "$r" in *"not applied"*) ;; *) _fail "reason for applied=0: $r" ;; esac
r="$(_reason socks 1 off all "")"
case "$r" in *"exec mode is off"*) ;; *) _fail "reason for exec off: $r" ;; esac
r="$(_reason socks 1 scoped all "")"
case "$r" in *"needs CBOX_NETACCESS_SCOPE=list"*"CBOX_NETACCESS_EXEC_MODE=all"*) ;; *) _fail "reason for scoped under scope=all: $r" ;; esac
r="$(_reason socks 1 scoped list "")"
case "$r" in *"at least one network"*) ;; *) _fail "reason for scoped without networks: $r" ;; esac
r="$(_reason socks 1 all list "")"
case "$r" in *"at least one network"*) ;; *) _fail "reason for all+list without networks: $r" ;; esac
if _reason socks 1 all all "" >/dev/null; then _fail "all under scope=all must have no inactive reason"; fi
if _reason socks 1 scoped list "net_a" >/dev/null; then _fail "scoped list with networks must have no inactive reason"; fi
_ok "inactive reason names the first missing condition (mode off, applied 0, exec off, scoped needs list, networks needed)"

grep -q '_cbox_netaccess_exec_inactive_reason' "$INSTALL_DIR/cbox" || _fail "cbox doctor does not use the inactive reason"
awk '/_cbox_doctor_row "container-exec" OFF "inactive: \$ce_reason"/ { found=1 } END { exit found ? 0 : 1 }' "$INSTALL_DIR/cbox" \
  || _fail "doctor container-exec row does not print the inactive reason"
_ok "doctor container-exec row prints the inactive reason"

FAKEBIN="$TMPBASE/fakebin"
mkdir -p "$FAKEBIN"
REAL_PY="$(command -v python3)"
cat > "$FAKEBIN/python3" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *docker_exec_bridge.py)
    printf '%s\n' "\$*" > "\$BRIDGE_ARGS_FILE"
    sockdir=""
    while [ "\$#" -gt 0 ]; do
      if [ "\$1" = "--sock-dir" ]; then sockdir="\$2"; fi
      shift
    done
    exec "$REAL_PY" -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); time.sleep(4)' "\$sockdir/bridge.sock"
    ;;
esac
exec "$REAL_PY" "\$@"
EOF
chmod +x "$FAKEBIN/python3"

EXTRACT="$TMPBASE/bridge_funcs.sh"
awk '
  /^_cbox_compose_project_of\(\) \{/ { infunc=1 }
  /^_container_exec_bridge_start\(\) \{/ { infunc=1 }
  /^_container_exec_bridge_stop\(\) \{/ { infunc=1 }
  infunc { print }
  infunc && /^\}/ { infunc=0 }
' "$INSTALL_DIR/cbox" > "$EXTRACT"
grep -q '^_container_exec_bridge_start()' "$EXTRACT" || _fail "extraction of the bridge start function failed"

mkdir -p "$TMPBASE/ws1" "$TMPBASE/ws2" "$TMPBASE/home"
printf 'name: myproj\nservices:\n' > "$TMPBASE/compose.yml"

_run_bridge() {
  local label="$1" mode="$2" scope="$3" nets="$4" guard="$5" start_mode="$6"
  (
    export PATH="$FAKEBIN:$PATH"
    export BRIDGE_ARGS_FILE="$TMPBASE/bridge.args.$label"
    INSTALL_DIR="$INSTALL_DIR"
    CBOX_NETACCESS_MODE=socks
    CBOX_NETACCESS_APPLIED=1
    CBOX_NETACCESS_EXEC_MODE="$mode"
    CBOX_NETACCESS_SCOPE="$scope"
    CBOX_NETACCESS_NETWORKS="$nets"
    CBOX_NETACCESS_EXEC_WORKSPACE_GUARD="$guard"
    CBOX_WORKSPACES="$TMPBASE/ws1 $TMPBASE/ws2"
    XDG_RUNTIME_DIR="$TMPBASE/runtime"
    _cbox_workspace_root() { printf '%s' "$TMPBASE/ws1"; }
    _cbox_project_extra_workspaces() { :; }
    _cbox_local_effdir_for() { printf '%s' "$TMPBASE/ws1"; }
    source "$EXTRACT"
    _container_exec_bridge_start "$TMPBASE/exec-$label" "$TMPBASE/ws1" "$start_mode" "$TMPBASE/compose.yml"
    rc=$?
    _container_exec_bridge_stop
    exit "$rc"
  )
}

_run_bridge allscope all all "" off global || _fail "bridge start under exec all + scope=all failed"
ARGS="$(cat "$TMPBASE/bridge.args.allscope")"
case "$ARGS" in *"--all-networks"*) ;; *) _fail "bridge args under all+scope=all lack --all-networks: $ARGS" ;; esac
case "$ARGS" in *"--project myproj"*) ;; *) _fail "bridge args lack the compose project: $ARGS" ;; esac
case "$ARGS" in *"--networks"*) _fail "bridge args under all+scope=all must not carry --networks: $ARGS" ;; esac
case "$ARGS" in *"--workspace-root"*) _fail "guard off must not pass --workspace-root under all: $ARGS" ;; esac
_ok "bridge under exec all + scope=all resolves every eligible network (--all-networks plus the compose project) and follows the guard setting (off)"

_run_bridge allguard all all "" on global || _fail "bridge start under exec all with guard on failed"
ARGS="$(cat "$TMPBASE/bridge.args.allguard")"
case "$ARGS" in *"--workspace-root $TMPBASE/ws1"*"--workspace-root $TMPBASE/ws2"*) ;; *) _fail "guard on under all must pass the global workspace roots: $ARGS" ;; esac
_ok "bridge under exec all honours CBOX_NETACCESS_EXEC_WORKSPACE_GUARD=on with the global workspace roots"

_run_bridge alllist all list "net_a net_b" off isolated || _fail "bridge start under exec all + scope=list failed"
ARGS="$(cat "$TMPBASE/bridge.args.alllist")"
case "$ARGS" in *"--networks net_a net_b"*) ;; *) _fail "bridge args under all+scope=list must pass the listed networks: $ARGS" ;; esac
case "$ARGS" in *"--all-networks"*) _fail "all+scope=list must not widen to every network: $ARGS" ;; esac
_ok "bridge under exec all + scope=list is bounded to the listed networks"

_run_bridge scoped scoped list "net_a" off isolated || _fail "bridge start under scoped failed"
ARGS="$(cat "$TMPBASE/bridge.args.scoped")"
case "$ARGS" in *"--networks net_a"*) ;; *) _fail "scoped bridge args: $ARGS" ;; esac
case "$ARGS" in *"--all-networks"*) _fail "scoped must never widen: $ARGS" ;; esac
_ok "bridge under scoped is unchanged (listed networks only)"

_run_bridge scopedall scoped all "" off isolated
[ ! -f "$TMPBASE/bridge.args.scopedall" ] || _fail "scoped under scope=all must not start a bridge"
_run_bridge allnolist all list "" off isolated
[ ! -f "$TMPBASE/bridge.args.allnolist" ] || _fail "exec all under scope=list without networks must not start a bridge"
_ok "inactive combinations start no bridge"

CONFIG_FN="$TMPBASE/config_warn.sh"
awk '
  /^_cbox_config_exec_mode_warn\(\) \{/ { infunc=1 }
  infunc { print }
  infunc && /^\}/ { infunc=0 }
' "$INSTALL_DIR/cbox" > "$CONFIG_FN"
grep -q '^_cbox_config_exec_mode_warn()' "$CONFIG_FN" || _fail "extraction of the config warning function failed"

_warn() {
  (
    unset CBOX_NETACCESS_EXEC_MODE CBOX_NETACCESS_SCOPE CBOX_NETACCESS_NETWORKS CBOX_NETACCESS_CIDRS
    source "$CONFIG_FN"
    CBOX_CONFIG_KEYS=()
    CBOX_CONFIG_VALS=()
    local kv
    for kv in "$@"; do
      CBOX_CONFIG_KEYS+=("${kv%%=*}")
      CBOX_CONFIG_VALS+=("${kv#*=}")
    done
    _cbox_config_exec_mode_warn
  ) 2>&1
}

w="$(_warn CBOX_NETACCESS_EXEC_MODE=scoped CBOX_NETACCESS_SCOPE=all)"
case "$w" in *"effective scope is all"*"SCOPE=list"*"CBOX_NETACCESS_EXEC_MODE=all"*) ;; *) _fail "scoped under scope=all warning: $w" ;; esac
[ "$(printf '%s\n' "$w" | wc -l)" -eq 1 ] || _fail "the warning must be a single line: $w"
w="$(_warn CBOX_NETACCESS_EXEC_MODE=scoped CBOX_NETACCESS_SCOPE=list)"
case "$w" in *"no networks are listed"*) ;; *) _fail "scoped without networks warning: $w" ;; esac
w="$(_warn CBOX_NETACCESS_EXEC_MODE=scoped)"
case "$w" in *"effective scope is all"*) ;; *) _fail "scoped with default scope warning: $w" ;; esac
w="$(_warn CBOX_NETACCESS_EXEC_MODE=scoped CBOX_NETACCESS_SCOPE=list CBOX_NETACCESS_NETWORKS=net_a)"
[ -z "$w" ] || _fail "a valid scoped config must not warn: $w"
w="$(_warn CBOX_NETACCESS_EXEC_MODE=all CBOX_NETACCESS_SCOPE=all)"
[ -z "$w" ] || _fail "exec all must not warn: $w"
w="$(_warn CBOX_GPU=1)"
[ -z "$w" ] || _fail "an unrelated set must not warn: $w"
_ok "config set warns once for scoped with a non-list scope or without networks, and stays silent otherwise"

WIZARD_FN="$TMPBASE/wizard.sh"
awk '
  /^step_netaccess\(\) \{/ { infunc=1 }
  infunc { print }
  infunc && /^\}/ { infunc=0 }
' "$INSTALL_DIR/lib/cbox-setup.sh" > "$WIZARD_FN"
grep -q '^step_netaccess()' "$WIZARD_FN" || _fail "extraction of step_netaccess failed"

_wizard() {
  local scope="$1" nets="$2" exec_choice="$3"
  (
    source "$INSTALL_DIR/templates/generators.sh"
    source "$WIZARD_FN"
    note() { :; }
    warn() { printf 'WARN: %s\n' "$*"; }
    load_generators() { :; }
    _cbox_list_docker_networks() { :; }
    GUARD_ASKED=0
    ask_choice() {
      case "$1" in
        *"netaccess mode"*) ASK_VALUE=socks ;;
        *"docker-network scope"*) ASK_VALUE="$scope" ;;
        *"direct test execution"*) ASK_VALUE="$exec_choice" ;;
        *"workspace"*) GUARD_ASKED=1; ASK_VALUE="$CBOX_NETACCESS_EXEC_WORKSPACE_GUARD" ;;
        *) ASK_VALUE="$2" ;;
      esac
    }
    ask() { ASK_VALUE=""; }
    SETUP_MODE=fresh
    CBOX_NETACCESS_MODE=off
    CBOX_NETACCESS_APPLIED=0
    CBOX_NETACCESS_SCOPE="$scope"
    CBOX_NETACCESS_NETWORKS="$nets"
    CBOX_NETACCESS_CIDRS=""
    CBOX_NETACCESS_SOCKS_PORT=1080
    CBOX_NETACCESS_EXEC_MODE=off
    CBOX_NETACCESS_EXEC_WORKSPACE_GUARD=off
    CBOX_NETACCESS_EXEC_TIMEOUT=900
    step_netaccess
    printf 'RESULT mode=%s guard_asked=%s\n' "$CBOX_NETACCESS_EXEC_MODE" "$GUARD_ASKED"
  ) 2>&1
}

out="$(_wizard all "" all)"
case "$out" in *"RESULT mode=all guard_asked=1"*) ;; *) _fail "wizard all under scope=all must keep all and ask the guard question: $out" ;; esac
out="$(_wizard list "" all)"
case "$out" in *"RESULT mode=off"*"WARN"*|*"WARN"*"RESULT mode=off"*) ;; *) _fail "wizard all under scope=list without networks must demote to off with a warning: $out" ;; esac
out="$(_wizard list "net_a" all)"
case "$out" in *"RESULT mode=all guard_asked=1"*) ;; *) _fail "wizard all under scope=list with networks must stay all: $out" ;; esac
out="$(_wizard all "" scoped)"
case "$out" in *"RESULT mode=off"*) ;; *) _fail "wizard scoped under scope=all must demote to off: $out" ;; esac
out="$(_wizard list "net_a" scoped)"
case "$out" in *"RESULT mode=scoped guard_asked=1"*) ;; *) _fail "wizard scoped under list with networks must stay scoped: $out" ;; esac
_ok "setup wizard offers off/scoped/all, keeps scoped demotion, demotes all+list without networks, asks the guard question under all"

echo "PASS: all container_exec_all checks"
