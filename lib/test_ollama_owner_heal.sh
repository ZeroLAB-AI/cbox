#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {" , $0 == "}"' "$1"
}

HEAL_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_owner_heal_impl)"
RESTART_FN="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_docker_restart_rootless)"
[ -n "$HEAL_FN" ] || _fail "cannot extract _cbox_ollama_owner_heal_impl from cbox"
[ -n "$RESTART_FN" ] || _fail "cannot extract _cbox_docker_restart_rootless from cbox"
eval "$HEAL_FN"
eval "$RESTART_FN"
for fn in _cbox_ollama_heal_recreate_marker _cbox_ollama_heal_recreate_set _cbox_ollama_heal_recreate_clear; do
  body="$(_extract_fn "$INSTALL_DIR/cbox" "$fn")"
  [ -n "$body" ] || _fail "cannot extract $fn from cbox"
  eval "$body"
done

CALLS="$TMPBASE/calls"
: > "$CALLS"
OWNER="$TMPBASE/owner"
mkdir -p "$OWNER"

_cbox_ollama_owner_dir() { printf '%s' "$OWNER"; }
_cbox_is_rootless_docker() { [ "${T_ROOTLESS:-1}" = 1 ]; }
_cbox_ollama_heal_can_prompt() { [ "${T_TTY:-0}" = 1 ]; }
_cbox_ollama_reconcile_cmd() { echo "reconcile" >> "$CALLS"; [ "${T_RECONCILE_RC:-0}" = 0 ]; }
systemctl() { echo "systemctl $*" >> "$CALLS"; return 0; }
sleep() { :; }
docker() {
  case "$1" in
    inspect) printf '%s\n' "${T_STATE:-exited}" ;;
    info) return 0 ;;
    *) echo "docker $*" >> "$CALLS" ;;
  esac
}
_cbox_ollama_gpu_preflight() { echo "preflight" >> "$CALLS"; return 0; }
_cbox_nvidia_uvm_ensure() { echo "uvm-ensure" >> "$CALLS"; [ "${T_UVM_RC:-1}" = 0 ]; }
_cbox_ollama_owner_compose() {
  echo "compose $*" >> "$CALLS"
  case "$1" in
    ps) printf '%s\n' "${T_CID-abc123}" ;;
    up)
      [ -z "${T_UP_ERR:-}" ] && return 0
      if [ -n "${T_UP_ERR_ONCE:-}" ] && [ -f "$TMPBASE/up-failed-once" ]; then
        return 0
      fi
      : > "$TMPBASE/up-failed-once"
      printf '%s\n' "$T_UP_ERR"
      return 1
      ;;
    rm) : ;;
  esac
}

_reset() {
  : > "$CALLS"
  unset T_UP_ERR T_UP_ERR_ONCE T_STATE T_CID T_TTY T_RECONCILE_RC T_ROOTLESS T_UVM_RC
  rm -f "$OWNER/.heal-recreate" "$TMPBASE/up-failed-once"
}

_reset
CBOX_OLLAMA_MODE=off _cbox_ollama_owner_heal_impl
[ ! -s "$CALLS" ] || _fail "mode off must not touch docker at all"
_ok "off: nothing happens when CBOX_OLLAMA_MODE is off"

_reset
export CBOX_OLLAMA_MODE=on
_cbox_ollama_owner_heal_impl
[ ! -s "$CALLS" ] || _fail "an owner project that was never rendered must be left alone (no compose.yml)"
_ok "never rendered: no owner compose.yml means no action (cbox ollama reconcile is the explicit path)"

touch "$OWNER/docker-compose.yml"
_reset; T_CID=""
_cbox_ollama_owner_heal_impl
! grep -q '^compose up' "$CALLS" || _fail "an owner project with no container (cbox ollama down) must not be started behind the operator's back"
_ok "stopped by the operator: no container means no auto-start"

_reset; T_CID=""; : > "$OWNER/.heal-recreate"
_cbox_ollama_owner_heal_impl 2>/dev/null
grep -q '^compose up -d ollama$' "$CALLS" || _fail "a container removed by an earlier heal whose reconcile failed must be recreated, not left dead forever"
[ ! -f "$OWNER/.heal-recreate" ] || _fail "a successful recreate must clear the marker"
_ok "self-removed container: the recreate marker lets the next heal create it again, then clears"

_reset; T_STATE=running
_cbox_ollama_owner_heal_impl
! grep -q '^compose up' "$CALLS" || _fail "a running owner must not be touched"
_ok "running: healthy owner is left alone"

_reset; T_STATE=running; : > "$OWNER/.heal-recreate"
_cbox_ollama_owner_heal_impl
[ ! -f "$OWNER/.heal-recreate" ] || _fail "a running owner must clear a stale recreate marker"
_ok "running: a stale recreate marker is cleared"

_reset; T_STATE=exited
_cbox_ollama_owner_heal_impl 2>/dev/null
grep -q '^compose up -d ollama$' "$CALLS" || _fail "an exited owner must be started with compose up -d ollama"
! grep -q '^reconcile' "$CALLS" || _fail "a plain start must not reconcile"
p_line="$(grep -n '^preflight$' "$CALLS" | head -n1 | cut -d: -f1)"
u_line="$(grep -n '^compose up -d ollama$' "$CALLS" | head -n1 | cut -d: -f1)"
[ -n "$p_line" ] || _fail "the heal must run the gpu preflight (an on-demand CDI node missing after a boot is the common case)"
[ "$u_line" -gt "$p_line" ] || _fail "the preflight must run before the start, not after it"
_ok "exited: the owner is started in place after the gpu preflight, no reconcile"

_reset; T_STATE=created; T_UP_ERR='Error response from daemon: failed to set up container networking: network 8745668e2dc2 not found'
out="$(_cbox_ollama_owner_heal_impl 2>&1)" || _fail "a missing network must be healed through reconcile, got: $out"
grep -q '^compose rm -f -s ollama$' "$CALLS" || _fail "the dead container must be removed before the reconcile (compose would otherwise retry the same stale network)"
grep -q '^reconcile$' "$CALLS" || _fail "a missing network must trigger the owner reconcile"
! grep -q '^systemctl' "$CALLS" || _fail "a missing network must not restart docker"
[ ! -f "$OWNER/.heal-recreate" ] || _fail "a successful reconcile must clear the recreate marker"
_ok "network not found (daemon restarted): dead container removed, owner reconciled, no docker restart"

_reset; T_STATE=created; T_UP_ERR='Error response from daemon: failed to set up container networking: network 8745668e2dc2 not found'; T_RECONCILE_RC=1
if out="$(_cbox_ollama_owner_heal_impl 2>&1)"; then _fail "a failed reconcile must report failure"; fi
[ -f "$OWNER/.heal-recreate" ] || _fail "when the heal removed the container and the reconcile failed, the marker must survive so the next heal recreates it instead of giving up forever"
_ok "network not found, reconcile fails: the recreate marker survives so the next heal is not a no-op"

_reset; T_STATE=exited; T_UP_ERR='Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/nvidia-uvm": no such file or directory'; T_UP_ERR_ONCE=1; T_UVM_RC=0
out="$(_cbox_ollama_owner_heal_impl 2>&1)" || _fail "a missing on-demand CDI node that cbox can create must be healed, got: $out"
grep -q '^uvm-ensure$' "$CALLS" || _fail "a CDI host device failure must try to create the on-demand node"
[ "$(grep -c '^compose up -d ollama$' "$CALLS")" = 2 ] || _fail "after creating the node the start must be retried exactly once"
! grep -q '^reconcile$' "$CALLS" || _fail "a missing device node must not trigger a reconcile"
_ok "CDI host device missing: the node is created and the start retried, no reconcile"

_reset; T_STATE=exited; T_UP_ERR='failed to stat CDI host device "/dev/nvidia-uvm": no such file or directory'; T_UVM_RC=1
if out="$(_cbox_ollama_owner_heal_impl 2>&1)"; then _fail "an uncreatable device node must report failure"; fi
case "$out" in *"cbox ollama gpu-check"*) ;; *) _fail "an uncreatable device node must point at gpu-check, got: $out" ;; esac
[ "$(grep -c '^compose up -d ollama$' "$CALLS")" = 1 ] || _fail "when the node could not be created the start must not be retried"
_ok "CDI host device missing, uncreatable: no pointless retry, gpu-check is named"

_reset; T_STATE=created; T_UP_ERR='OCI runtime create failed: failed to fulfil mount request: open /run/nvidia-persistenced/socket: no such file or directory'; T_TTY=0
if out="$(_cbox_ollama_owner_heal_impl 2>&1)"; then _fail "copy-up symptom without a tty must report failure"; fi
! grep -q '^systemctl' "$CALLS" || _fail "without a tty docker must never be restarted"
case "$out" in *"systemctl --user restart docker && cbox ollama reconcile"*) ;; *) _fail "without a tty the message must hand over the exact command, got: $out" ;; esac
_ok "copy-up symptom, no tty: no restart, the command is printed"

_reset; T_STATE=created; T_UP_ERR='docker: Error response from daemon: unresolvable CDI devices nvidia.com/gpu=all'; T_TTY=1
out="$(printf 'n\n' | _cbox_ollama_owner_heal_impl 2>&1)" && _fail "answering n must report failure so the caller knows the owner is still down"
! grep -q '^systemctl' "$CALLS" || _fail "answering n must not restart docker"
case "$out" in *"including other cbox sessions"*) ;; *) _fail "the prompt must warn that every container on the daemon stops, got: $out" ;; esac
_ok "copy-up symptom, tty, answer n: nothing restarted, warning shown"

_reset; T_STATE=created; T_UP_ERR='failed to fulfil mount request: open /run/nvidia-persistenced/socket: no such file or directory'; T_TTY=1
out="$(printf '\n' | _cbox_ollama_owner_heal_impl 2>&1)" || _fail "enter (default Y) must restart and reconcile, got: $out"
grep -q '^systemctl --user restart docker$' "$CALLS" || _fail "default Y must restart the rootless daemon via systemctl --user"
grep -q '^reconcile$' "$CALLS" || _fail "after the restart the owner must be reconciled"
r_line="$(grep -n '^systemctl' "$CALLS" | cut -d: -f1)"; c_line="$(grep -n '^reconcile' "$CALLS" | cut -d: -f1)"
[ "$c_line" -gt "$r_line" ] || _fail "reconcile must come after the restart"
_ok "copy-up symptom, tty, enter: docker restarted, then reconciled, then continues"

_reset; T_STATE=created; T_UP_ERR='failed to fulfil mount request: open /run/nvidia-persistenced/socket: no such file or directory'; T_TTY=1; T_ROOTLESS=0
if out="$(printf '\n' | _cbox_ollama_owner_heal_impl 2>&1)"; then _fail "on rootful docker the heal must not restart anything"; fi
! grep -q '^systemctl' "$CALLS" || _fail "rootful docker must never be restarted by cbox"
case "$out" in *"sudo systemctl restart docker"*) ;; *) _fail "rootful docker must get the sudo hint, got: $out" ;; esac
_ok "rootful docker: no restart, sudo hint only"

_reset; T_STATE=exited; T_UP_ERR='something else entirely'
if out="$(_cbox_ollama_owner_heal_impl 2>&1)"; then _fail "an unknown failure must report failure"; fi
case "$out" in *"this session continues without the local model"*) ;; *) _fail "an unknown failure must say the session continues, got: $out" ;; esac
_ok "unknown failure: reported, never blocks the session"

for site in '_run_global' '_session_run' 'shell_isolated' 'up'; do
  body="$(awk -v fn="$site" '$0 == fn"() {" , $0 == "}"' "$INSTALL_DIR/cbox")"
  printf '%s\n' "$body" | grep -B1 '_cbox_compose_up ' | grep -q '_cbox_ollama_owner_heal || true' \
    || _fail "$site must call _cbox_ollama_owner_heal on the line right before its _cbox_compose_up (a docker restart after the session container is up would kill that session)"
done
n_heal="$(grep -c '^  _cbox_ollama_owner_heal || true$' "$INSTALL_DIR/cbox")"
n_up="$(grep -c '^  _cbox_compose_up ' "$INSTALL_DIR/cbox")"
[ "$n_heal" = "$n_up" ] || _fail "every _cbox_compose_up site must be preceded by the heal call: $n_up compose-up sites, $n_heal heal calls"
_ok "wiring: the heal runs right before every session compose-up (run aliases, shell, up), never after"

wrapper="$(awk '/^_cbox_ollama_owner_heal\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
printf '%s\n' "$wrapper" | grep -q '_cbox_flock -x' \
  || _fail "the heal wrapper must take the ollama machine lock exclusively, like the reconcile verb"
printf '%s\n' "$wrapper" | grep -q 'exec {fd}>>' \
  || _fail "the heal wrapper must open its lock on a dynamically allocated fd - the session leg holds fd 9 across _run_isolated and a fixed exec 9> would drop that lock"
! printf '%s\n' "$wrapper" | grep -q 'exec 9' \
  || _fail "the heal wrapper must not touch fd 9"
_ok "lock: the heal serialises against the ollama verbs on a dynamic fd, never on the session's fd 9"
printf '%s\n' "$HEAL_FN" | grep -q 'read -r -t 60 ans' \
  || _fail "the restart prompt must time out (a tty without a human, e.g. a detached pane, must not hang the run)"
_ok "prompt: the restart question times out and counts as no"

grep -q 'Owner self-heal on engine start' "$INSTALL_DIR/MANUAL.md" || _fail "MANUAL must document the owner self-heal"
_ok "MANUAL documents the owner self-heal"

down_fn="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_down_cmd)"
printf '%s\n' "$down_fn" | grep -q '_cbox_ollama_heal_recreate_clear' \
  || _fail "cbox ollama down must clear the recreate marker - an operator taking the owner down must not be overruled by the next heal"
_ok "down: an explicit teardown clears the recreate marker"

(
  reconcile_fn="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_reconcile_cmd)"
  [ -n "$reconcile_fn" ] || _fail "cannot extract _cbox_ollama_reconcile_cmd from cbox"
  eval "$reconcile_fn"
  _cbox_wg_active() { return 1; }
  gen_ollama_owner_compose_into() { :; }
  gen_wireguard_conf() { :; }
  _cbox_ollama_gc_scope_networks_impl() { :; }
  _reset
  : > "$OWNER/.heal-recreate"
  : > "$OWNER/ownership.manifest"
  CBOX_OLLAMA_MODE=off _cbox_ollama_reconcile_cmd >/dev/null 2>&1 \
    || _fail "a de-rendering reconcile must succeed"
  [ ! -f "$OWNER/.heal-recreate" ] || _fail "a de-rendering 'cbox ollama reconcile' must clear the recreate marker - the owner is deliberately gone and the next heal must not resurrect it"
  _ok "de-rendering reconcile: the real function clears the recreate marker"
)

echo "PASS: ollama owner self-heal on engine start"
