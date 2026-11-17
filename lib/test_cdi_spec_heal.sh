#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset $(env | sed -n 's/^\(CBOX_[A-Za-z0-9_]*\)=.*/\1/p')

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

_extract_fn() {
  awk -v fn="$2" '$0 == fn"() {", $0 == "}"' "$1"
}

for fn in _cbox_cdi_failed_node _cbox_cdi_spec_files_for _cbox_cdi_spec_writable _cbox_cdi_spec_regenerate \
  _cbox_cdi_host_device_recover _cbox_ollama_owner_up; do
  body="$(_extract_fn "$INSTALL_DIR/cbox" "$fn")"
  [ -n "$body" ] || _fail "cannot extract $fn from cbox"
  eval "$body"
done

WRITABLE_BODY="$(_extract_fn "$INSTALL_DIR/cbox" _cbox_cdi_spec_writable)"
[ -n "$WRITABLE_BODY" ] || _fail "cannot extract _cbox_cdi_spec_writable from cbox"

CALLS="$TMPBASE/calls"
: > "$CALLS"
export CALLS

_cbox_nvidia_uvm_ensure() {
  echo "uvm-ensure" >> "$CALLS"
  [ "${T_UVM_RC:-0}" != 1 ]
}
_cbox_ollama_gpu_preflight() { :; }
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

mkdir -p "$TMPBASE/bin" "$TMPBASE/cdi"

cat > "$TMPBASE/bin/nvidia-ctk" <<'EOS'
#!/usr/bin/env bash
echo "ctk $*" >> "$CALLS"
if [ "${T_CTK_RC:-}" = 1 ]; then
  echo "nvidia-ctk: generate failed" >&2
  exit 1
fi
out=""
for a in "$@"; do
  case "$a" in
    --output=*) out="${a#--output=}" ;;
  esac
done
if [ -n "$out" ]; then
  {
    echo "cdiVersion: 0.5.0"
    echo "kind: nvidia.com/gpu"
    echo "containers:"
    echo "- devices:"
    echo "  - path: /dev/nvidia0"
  } > "$out"
fi
exit 0
EOS
chmod +x "$TMPBASE/bin/nvidia-ctk"

cat > "$TMPBASE/bin/sudo" <<'EOS'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS"
if [ "${1:-}" = "-n" ]; then
  shift
fi
if [ "${1:-}" = "true" ] && [ "${T_SUDO_N:-}" != 1 ]; then
  exit 1
fi
exec "$@"
EOS
chmod +x "$TMPBASE/bin/sudo"

export PATH="$TMPBASE/bin:$PATH"
export _CBOX_CDI_SPEC_DIRS="$TMPBASE/cdi"

_write_spec() {
  {
    echo "cdiVersion: 0.5.0"
    echo "kind: nvidia.com/gpu"
    echo "containers:"
    echo "- devices:"
    echo "  - path: /dev/nvidia0"
    echo "  - path: /dev/dri/card0"
    echo "  - path: /dev/dri/renderD129"
  } > "$TMPBASE/cdi/nvidia.yaml"
}

_reset() {
  : > "$CALLS"
  unset T_UVM_RC T_CTK_RC T_SUDO_N T_UP_ERR T_UP_ERR_ONCE
  rm -f "$TMPBASE/up-failed-once"
  _write_spec
}

ERR='Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/dri/card0": no such file or directory
Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/dri/card0": no such file or directory'
UVM_ERR='Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/nvidia-uvm": no such file or directory
Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/nvidia-uvm": no such file or directory'
CARD7_ERR='Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/dri/card7": no such file or directory
Error response from daemon: CDI device injection failed: failed to inject devices: failed to stat CDI host device "/dev/dri/card7": no such file or directory'

SPEC="$TMPBASE/cdi/nvidia.yaml"

_reset
n="$(_cbox_cdi_failed_node "$ERR")"
[ "$n" = "/dev/dri/card0" ] || _fail "case 1: the failed node must be exactly /dev/dri/card0, got: $n"
_ok "case 1: the failed node is parsed out of the two-line daemon error"

_reset
out="$(_cbox_cdi_host_device_recover "ollama owner" "$UVM_ERR" "cbox ollama gpu-check" 2>&1)" || _fail "case 2a: a creatable uvm node must be recovered, got: $out"
case "$out" in *"/dev/nvidia-uvm"*) ;; *) _fail "case 2a: the output must mention /dev/nvidia-uvm, got: $out" ;; esac
! grep -q '^ctk ' "$CALLS" || _fail "case 2a: an on-demand node must not trigger a spec regeneration"
_ok "case 2a: the uvm node is created without touching the spec"

_reset; export T_UVM_RC=1
if out="$(_cbox_cdi_host_device_recover "ollama owner" "$UVM_ERR" "cbox ollama gpu-check" 2>&1)"; then _fail "case 2b: an uncreatable uvm node must fail"; fi
case "$out" in *"cbox ollama gpu-check"*) ;; *) _fail "case 2b: the failure must point at gpu-check, got: $out" ;; esac
_ok "case 2b: an uncreatable uvm node fails and names the check"

_reset
out="$(_cbox_cdi_host_device_recover "ollama owner" "$ERR" "cbox ollama gpu-check" 2>&1)" || _fail "case 3: a stale spec must be regenerated, got: $out"
[ "$(grep -c "^ctk cdi generate --output=$SPEC\$" "$CALLS")" = 1 ] || _fail "case 3: exactly one ctk cdi generate for the spec is expected, calls: $(cat "$CALLS")"
! grep -q '^sudo ' "$CALLS" || _fail "case 3: a writable spec must not need sudo"
! grep -qF -- '/dev/dri/card0' "$SPEC" || _fail "case 3: the regenerated spec must no longer list /dev/dri/card0"
case "$out" in *"/dev/dri/card0"*) ;; *) _fail "case 3: the output must name the stale node, got: $out" ;; esac
case "$out" in *"created /dev/nvidia-uvm"*) _fail "case 3: this path is a stale spec, not the uvm node" ;; *) ;; esac
_ok "case 3: a stale dri node regenerates the spec in place without sudo"

_reset; export T_UVM_RC=1
if out="$(_cbox_cdi_host_device_recover "ollama owner" "$ERR" "cbox ollama gpu-check" 2>&1)"; then _fail "case 4: with /dev/nvidia-uvm missing too the spec must not be regenerated"; fi
! grep -q '^ctk ' "$CALLS" || _fail "case 4: no regeneration is expected while the uvm node is missing"
grep -qF -- '/dev/dri/card0' "$SPEC" || _fail "case 4: the spec must be left untouched"
_ok "case 4: a stale dri node is not regenerated while the uvm node is missing"

_reset
if out="$(_cbox_cdi_host_device_recover "ollama owner" "$CARD7_ERR" "cbox ollama gpu-check" 2>&1)"; then _fail "case 5: a node no spec lists must fail"; fi
! grep -q '^ctk ' "$CALLS" || _fail "case 5: no spec lists the node, so nothing may be regenerated"
case "$out" in *"cbox ollama gpu-check"*) ;; *) _fail "case 5: the failure must point at gpu-check, got: $out" ;; esac
_ok "case 5: an unlisted node fails and names the check"

_reset
_cbox_cdi_spec_writable() { return 1; }
if out="$(_cbox_cdi_host_device_recover "ollama owner" "$ERR" "cbox ollama gpu-check" </dev/null 2>&1)"; then _fail "case 6a: an unwritable spec without passwordless sudo must fail"; fi
! grep -q '^ctk ' "$CALLS" || _fail "case 6a: without a working sudo the spec must not be regenerated"
case "$out" in *"sudo nvidia-ctk cdi generate --output=$SPEC"*) ;; *) _fail "case 6a: the operator must be handed the exact sudo command, got: $out" ;; esac
export T_SUDO_N=1
out="$(_cbox_cdi_host_device_recover "ollama owner" "$ERR" "cbox ollama gpu-check" </dev/null 2>&1)" || _fail "case 6b: a passwordless sudo must let the spec be regenerated, got: $out"
grep -q "^sudo -n $TMPBASE/bin/nvidia-ctk cdi generate --output=" "$CALLS" || _fail "case 6b: the sudo -n invocation of the absolute nvidia-ctk path is expected, calls: $(cat "$CALLS")"
eval "$WRITABLE_BODY"
_ok "case 6: an unwritable spec falls back to sudo -n and names the exact command otherwise"

_reset; export T_CTK_RC=1
if out="$(_cbox_cdi_host_device_recover "ollama owner" "$ERR" "cbox ollama gpu-check" 2>&1)"; then _fail "case 7: a failed nvidia-ctk run must fail the recovery"; fi
grep -qF -- '/dev/dri/card0' "$SPEC" || _fail "case 7: the spec must be left untouched when nvidia-ctk fails"
_ok "case 7: a failed nvidia-ctk run leaves the spec in place and fails"

_reset; T_UP_ERR="$ERR"; T_UP_ERR_ONCE=1
out="$(_cbox_ollama_owner_up 2>&1)" || _fail "case 8: a stale spec must heal and the start must succeed, got: $out"
[ "$(grep -c '^compose up -d --remove-orphans$' "$CALLS")" = 2 ] || _fail "case 8: the start must be retried exactly once, calls: $(cat "$CALLS")"
[ "$(grep -c '^ctk ' "$CALLS")" = 1 ] || _fail "case 8: exactly one spec regeneration is expected, calls: $(cat "$CALLS")"
! grep -q '^compose rm' "$CALLS" || _fail "case 8: a stale spec must not remove the container"
_ok "case 8: owner up heals the stale spec and retries the start exactly once"

_reset; T_UP_ERR="$ERR"; export T_UVM_RC=1
if out="$(_cbox_ollama_owner_up 2>&1)"; then _fail "case 9: with the uvm node uncreatable the start must fail, got: $out"; fi
[ "$(grep -c '^compose up -d --remove-orphans$' "$CALLS")" = 1 ] || _fail "case 9: a failed recovery must not retry the start, calls: $(cat "$CALLS")"
_ok "case 9: owner up with an uncreatable uvm node fails without a pointless retry"

echo "PASS: CDI stale spec self-heal"
