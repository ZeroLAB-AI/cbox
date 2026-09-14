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

for fn in _cbox_ollama_gpu_preflight _cbox_ollama_owner_up _cbox_nvidia_uvm_present _cbox_nvidia_uvm_ensure; do
  body="$(_extract_fn "$INSTALL_DIR/cbox" "$fn")"
  [ -n "$body" ] || _fail "cannot extract $fn from cbox"
  eval "$body"
done

CALLS="$TMPBASE/calls"
: > "$CALLS"

_cbox_nvidia_uvm_present() { echo "present" >> "$CALLS"; [ "${T_PRESENT:-1}" = 0 ]; }
_cbox_nvidia_uvm_ensure() { echo "ensure" >> "$CALLS"; [ "${T_ENSURE_RC:-1}" = 0 ]; }
_cbox_ollama_heal_recreate_clear() { echo "marker-clear" >> "$CALLS"; }
_cbox_ollama_heal_recreate_set() { echo "marker-set" >> "$CALLS"; }
_cbox_ollama_owner_compose() {
  echo "compose $*" >> "$CALLS"
  case "$1" in
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
  unset T_PRESENT T_ENSURE_RC T_UP_ERR T_UP_ERR_ONCE
  rm -f "$TMPBASE/up-failed-once"
}

_reset
CBOX_OLLAMA_GPU=off _cbox_ollama_gpu_preflight
[ ! -s "$CALLS" ] || _fail "with CBOX_OLLAMA_GPU=off the preflight must not touch the driver at all"
_ok "gpu off: the preflight is inert - no device probe, no modprobe"

_reset; T_PRESENT=0
out="$(CBOX_OLLAMA_GPU=cdi _cbox_ollama_gpu_preflight 2>&1)"
[ -z "$out" ] || _fail "an existing device node must produce no output, got: $out"
! grep -q '^ensure$' "$CALLS" || _fail "an existing device node must not be re-created"
_ok "node present: the preflight is silent and does nothing"

_reset; T_PRESENT=1; T_ENSURE_RC=0
out="$(CBOX_OLLAMA_GPU=cdi _cbox_ollama_gpu_preflight 2>&1)" || _fail "a node cbox could create must not fail the preflight"
grep -q '^ensure$' "$CALLS" || _fail "a missing node must be created before the start"
case "$out" in *"/dev/nvidia-uvm was missing"*) ;; *) _fail "the operator must be told the node was created, got: $out" ;; esac
_ok "node missing, creatable: cbox creates it before the start and says so"

_reset; T_PRESENT=1; T_ENSURE_RC=1
out="$(CBOX_OLLAMA_GPU=cdi _cbox_ollama_gpu_preflight 2>&1)" || _fail "the preflight must never fail the start - the CDI spec may not list the node at all, and a hard refusal would block a start that would otherwise work"
case "$out" in *"could not create it"*) ;; *) _fail "an uncreatable node must warn, got: $out" ;; esac
_ok "node missing, uncreatable: the preflight warns but never blocks the start"

_reset; T_PRESENT=0
CBOX_OLLAMA_GPU=cdi _cbox_ollama_owner_up >/dev/null 2>&1 || _fail "a clean start must succeed"
p_line="$(grep -n '^present$' "$CALLS" | head -n1 | cut -d: -f1)"
u_line="$(grep -n '^compose up' "$CALLS" | head -n1 | cut -d: -f1)"
[ -n "$p_line" ] || _fail "the owner start must run the gpu preflight"
[ "$u_line" -gt "$p_line" ] || _fail "the preflight must run before compose up, not after it"
grep -q '^marker-clear$' "$CALLS" || _fail "a successful start must clear the heal recreate marker"
_ok "owner up: preflight first, then compose up, then the recreate marker is cleared"

_reset; T_PRESENT=1; T_ENSURE_RC=0
T_UP_ERR='Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/nvidia-uvm": no such file or directory'
T_UP_ERR_ONCE=1
out="$(CBOX_OLLAMA_GPU=cdi _cbox_ollama_owner_up 2>&1)" || _fail "a start that fails on a creatable device node must be retried and succeed, got: $out"
[ "$(grep -c '^compose up -d --remove-orphans$' "$CALLS")" = 2 ] || _fail "the start must be retried exactly once after the node is created"
! grep -q '^compose rm' "$CALLS" || _fail "a device node failure must not remove the container - that is the stale-network path"
_ok "owner up, CDI node missing at start time: created and retried once, container left alone"

_reset; T_PRESENT=1; T_ENSURE_RC=1
T_UP_ERR='failed to stat CDI host device "/dev/nvidia-uvm": no such file or directory'
if out="$(CBOX_OLLAMA_GPU=cdi _cbox_ollama_owner_up 2>&1)"; then _fail "an uncreatable device node must fail the start"; fi
[ "$(grep -c '^compose up -d --remove-orphans$' "$CALLS")" = 1 ] || _fail "with the node still missing the start must not be retried"
case "$out" in *"cbox ollama gpu-check"*) ;; *) _fail "the failure must point at gpu-check, got: $out" ;; esac
! grep -q '^marker-clear$' "$CALLS" || _fail "a failed start must not clear the heal recreate marker"
_ok "owner up, CDI node uncreatable: no pointless retry, gpu-check named, marker kept"

_reset; T_PRESENT=0
T_UP_ERR='Error response from daemon: failed to set up container networking: network 8745668e2dc2 not found'
T_UP_ERR_ONCE=1
CBOX_OLLAMA_GPU=cdi _cbox_ollama_owner_up >/dev/null 2>&1 || _fail "the stale-network path must still heal"
grep -q '^compose rm -f -s$' "$CALLS" || _fail "the stale-network path must still remove the dead container"
m_line="$(grep -n '^marker-set$' "$CALLS" | head -n1 | cut -d: -f1)"
r_line="$(grep -n '^compose rm -f -s$' "$CALLS" | head -n1 | cut -d: -f1)"
[ -n "$m_line" ] || _fail "the stale-network path must arm the recreate marker before it removes the container"
[ "$r_line" -gt "$m_line" ] || _fail "the marker must be armed before the removal, not after - a crash in between would lose the container with no way back"
grep -q '^marker-clear$' "$CALLS" || _fail "a successful retry must clear the marker again"
_ok "owner up, stale network: the recreate marker is armed before the removal and cleared on success"

_reset; T_PRESENT=0
T_UP_ERR='Error response from daemon: failed to set up container networking: network 8745668e2dc2 not found'
if CBOX_OLLAMA_GPU=cdi _cbox_ollama_owner_up >/dev/null 2>&1; then _fail "a stale network that survives the retry must fail the start"; fi
grep -q '^marker-set$' "$CALLS" || _fail "when cbox ollama up removes the container and cannot start it again, the recreate marker must survive - otherwise the next engine-start heal finds no container, no marker, and gives up forever (the exact bug the marker exists for, reached through 'up'/'reconcile' instead of the heal)"
! grep -q '^marker-clear$' "$CALLS" || _fail "a failed start must never clear the marker"
_ok "owner up, stale network, retry fails: the container is gone but the marker survives for the next heal"

ENSURE_BODY="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_nvidia_uvm_ensure)"
printf '%s\n' "$ENSURE_BODY" | grep -q 'nvidia-modprobe -u -c 0' \
  || _fail "the node must be created with nvidia-modprobe -u -c 0 (setuid, no root needed) as the primary path"
printf '%s\n' "$ENSURE_BODY" | grep -q 'nvidia-smi' \
  || _fail "nvidia-smi must remain the fallback for hosts that ship no nvidia-modprobe"
printf '%s\n' "$ENSURE_BODY" | grep -q 'command -v nvidia-modprobe' \
  || _fail "the tools must be probed before use - a host with no driver must not emit command-not-found noise"
first="$(printf '%s\n' "$ENSURE_BODY" | grep -n '_cbox_nvidia_uvm_present' | head -n1 | cut -d: -f1)"
[ "$first" = 2 ] || _fail "the ensure must short-circuit on an already-present node before touching any tool"
_ok "ensure: modprobe first, nvidia-smi fallback, both probed, present short-circuits"

PRESENT_BODY="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_nvidia_uvm_present)"
printf '%s\n' "$PRESENT_BODY" | grep -q '/dev/nvidia-uvm-tools' \
  || _fail "both on-demand nodes must be checked - the CDI spec lists nvidia-uvm-tools too"
_ok "present: both /dev/nvidia-uvm and /dev/nvidia-uvm-tools are checked"

RESTORE_BODY="$(awk '/_restore_ollama\(\) \{/,/^  \}$/' "$INSTALL_DIR/cbox")"
printf '%s\n' "$RESTORE_BODY" | grep -q '_cbox_ollama_gpu_preflight' \
  || _fail "the pull restore must run the preflight too - the driver can drop the node while the server is stopped"
r_pre="$(printf '%s\n' "$RESTORE_BODY" | grep -n '_cbox_ollama_gpu_preflight' | head -n1 | cut -d: -f1)"
r_up="$(printf '%s\n' "$RESTORE_BODY" | grep -n 'up -d ollama' | head -n1 | cut -d: -f1)"
[ "$r_up" -gt "$r_pre" ] || _fail "in the pull restore the preflight must precede the restart"
_ok "pull restore: the preflight runs before the serving container comes back"

PULL_BODY="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_ollama_pull_cmd)"
printf '%s\n' "$PULL_BODY" | grep -q '_cbox_ollama_gpu_preflight' \
  || _fail "cbox ollama pull must run the preflight too - a pull can be the first CUDA-touching action after a boot, and its temporary container claims the same CDI device"
p_pre="$(printf '%s\n' "$PULL_BODY" | grep -n '_cbox_ollama_gpu_preflight' | head -n1 | cut -d: -f1)"
p_restore="$(printf '%s\n' "$PULL_BODY" | grep -n '_restore_ollama() {' | head -n1 | cut -d: -f1)"
[ -n "$p_restore" ] || _fail "cannot find the pull restore helper"
[ "$p_pre" -lt "$p_restore" ] || _fail "the pull must run the preflight in its own body before the restore helper is even defined - a preflight that only exists inside the restore comes too late for the temporary pull container, which claims the same CDI device"
[ "$(printf '%s\n' "$PULL_BODY" | grep -c '_cbox_ollama_gpu_preflight')" -ge 2 ] || _fail "the pull needs the preflight twice: once up front for the temporary container, once in the restore before the serving container comes back"
_ok "pull: the preflight runs up front for the temporary container and again in the restore"

grep -q 'nvidia-uvm' "$INSTALL_DIR/MANUAL.md" || _fail "MANUAL must document the on-demand device node handling"
_ok "MANUAL documents the on-demand CDI device node"

echo "PASS: ollama gpu preflight and on-demand CDI device node recovery"
