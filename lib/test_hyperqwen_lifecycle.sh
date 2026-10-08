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
  _cbox_ollama_lock_file _cbox_ollama_lock_fd_open _cbox_ollama_copyup_recover \
  _cbox_local_backends_gpu_overlap_text _cbox_local_backends_gpu_overlap_warn \
  _cbox_hyperqwen_image _cbox_hyperqwen_guard _cbox_hyperqwen_models_guard \
  _cbox_hyperqwen_volume_ensure _cbox_hyperqwen_volumes_ensure \
  _cbox_hyperqwen_adopt_or_refuse _cbox_hyperqwen_prepared_marker _cbox_hyperqwen_prepared_ok \
  _cbox_hyperqwen_prepared_write _cbox_hyperqwen_prepared_key _cbox_hyperqwen_heal_recreate_marker _cbox_hyperqwen_heal_recreate_set \
  _cbox_hyperqwen_heal_recreate_clear _cbox_hyperqwen_gpu_preflight _cbox_hyperqwen_owner_up \
  _cbox_hyperqwen_prepare_restore _cbox_hyperqwen_prepare_run _cbox_hyperqwen_prepare_cmd \
  _cbox_hyperqwen_prepare_inline _cbox_hyperqwen_status_cmd _cbox_hyperqwen_ps_cmd _cbox_hyperqwen_reconcile_cmd \
  _cbox_hyperqwen_render_matches _cbox_hyperqwen_up_cmd _cbox_hyperqwen_down_cmd _cbox_hyperqwen_logs_cmd \
  _cbox_hyperqwen_gpu_check_base_image _cbox_hyperqwen_gpu_check_cmd _cbox_hyperqwen_owner_heal_impl hyperqwen_cmd \
  _cbox_hyperqwen_container_running _cbox_hyperqwen_offload_preflight_warn
do
  _load_fn "$fn"
done

HOME="$TMPBASE/home"
export HOME
mkdir -p "$HOME"
OWNER_DIR="$HOME/.config/cbox/infra/hyperqwen"
CALLS="$TMPBASE/calls"
: > "$CALLS"

id() {
  if [ "${1:-}" = "-u" ]; then printf '1000\n'; else command id "$@"; fi
}
die() { echo "die: $*" >&2; exit 1; }
_cbox_hyperqwen_owner_name() { printf 'cbox-infra-u1000-hyperqwen'; }
_cbox_hyperqwen_owner_dir() { printf '%s' "$OWNER_DIR"; }
_cbox_hyperqwen_models_volume() { printf 'cbox-hyperqwen-u1000-models'; }
_cbox_hyperqwen_cache_volume() { printf 'cbox-hyperqwen-u1000-cache'; }
_cbox_hyperqwen_max_len() { printf '65536'; }
_cbox_local_backend_port() { printf '18020'; }
_cbox_gpu_device_ids() {
  if [ "${1:-all}" = all ]; then printf 'nvidia.com/gpu=all\n'; return 0; fi
  local e
  for e in $(printf '%s' "$1" | tr ',' ' '); do printf 'nvidia.com/gpu=%s\n' "$e"; done
}
_cbox_gpu_devices_overlap() {
  [ "${1:-all}" = all ] && return 0
  [ "${2:-all}" = all ] && return 0
  local a b
  for a in $(printf '%s' "$1" | tr ',' ' '); do
    for b in $(printf '%s' "$2" | tr ',' ' '); do
      [ "$a" = "$b" ] && return 0
    done
  done
  return 1
}
gen_hyperqwen_owner_compose_into() {
  echo "gen $1" >> "$CALLS"
  mkdir -p "$1"
  if [ "${CBOX_HYPERQWEN_MODE:-off}" = on ]; then
    printf '%s' "${T_RENDER:-}" > "$1/docker-compose.yml"
  else
    rm -f -- "$1/docker-compose.yml" "$1/docker-compose.gpu.yml"
  fi
}
_cbox_hyperqwen_manifest_write() { echo "manifest-write" >> "$CALLS"; : > "$1/ownership.manifest"; }
_cbox_hyperqwen_manifest_matches_current() { [ "${T_MANIFEST_OK:-1}" = 1 ] && [ -f "$1/ownership.manifest" ]; }
_cbox_config_in_container() { [ "${T_INCONTAINER:-0}" = 1 ]; }
_cbox_flock() { return 0; }
_cbox_stat_uid() { shift; printf '%s' "${T_STAT_UID:-1000}"; }
_cbox_nvidia_uvm_present() { return 0; }
_cbox_nvidia_uvm_ensure() { return 0; }
_cbox_ollama_reconcile_networks_impl() { echo "networks-reconcile" >> "$CALLS"; return 0; }
_cbox_ollama_gc_scope_networks_impl() { echo "networks-gc" >> "$CALLS"; return 0; }
_cbox_ollama_heal_can_prompt() { return 1; }
_cbox_is_rootless_docker() { return 0; }
_cbox_mem_available_kib() {
  echo "meminfo-read" >> "$CALLS"
  [ -n "${T_MEM_KIB:-}" ] || return 1
  printf '%s' "$T_MEM_KIB"
}

_cbox_hyperqwen_owner_compose() {
  echo "compose $*" >> "$CALLS"
  case "$1" in
    ps) printf '%s\n' "${T_CID-hqcid}" ;;
    up)
      if [ -n "${T_UP_ERR:-}" ]; then printf '%s\n' "$T_UP_ERR"; return 1; fi
      return 0
      ;;
  esac
  return 0
}

docker() {
  echo "docker $*" >> "$CALLS"
  case "$1" in
    run)
      case "$*" in *nvidia-smi*) printf '| NVIDIA-SMI 580.95  Driver Version: 580.95  CUDA Version: %s |\n' "${T_CUDA:-13.0}" ;; esac
      return "${T_RUN_RC:-0}"
      ;;
    image) return "${T_IMAGE_RC:-0}" ;;
    volume)
      case "$2" in inspect) return "${T_VOL_RC:-0}" ;; esac
      return 0
      ;;
    network)
      case "$2" in create) return "${T_NETCREATE_RC:-0}" ;; esac
      return 0
      ;;
    ps) printf '%s\n' "${T_PS_CID:-}" ;;
    inspect)
      case "$*" in
        *State.Status*) printf '%s\n' "${T_STATE:-running}" ;;
        *cbox.kind*) printf '%s\n' "${T_LABELS:-}" ;;
        *compose.project*) printf '%s\n' "${T_PROJECT:-}" ;;
        *Config.Image*) printf '%s\n' "${T_IMAGE:-}" ;;
      esac
      ;;
  esac
  return 0
}

IMAGE="ghcr.io/syv-ai/hyperqwen:sha-53557bc"
OTHER_IMAGE="ghcr.io/syv-ai/hyperqwen:sha-0000000"

_reset() {
  : > "$CALLS"
  unset T_MANIFEST_OK T_INCONTAINER T_STAT_UID T_CID T_UP_ERR T_RUN_RC T_NETCREATE_RC T_PS_CID T_STATE T_LABELS T_PROJECT T_IMAGE
  unset CBOX_HYPERQWEN_MODE CBOX_HYPERQWEN_IMAGE CBOX_HYPERQWEN_MODELS_PATH CBOX_HYPERQWEN_GPU_DEVICE
  unset CBOX_OLLAMA_MODE CBOX_OLLAMA_GPU CBOX_OLLAMA_GPU_DEVICE
  unset CBOX_HYPERQWEN_KV_OFFLOAD CBOX_HYPERQWEN_KV_OFFLOAD_MIB CBOX_HYPERQWEN_RAM_RESERVE_GIB T_MEM_KIB
  rm -rf -- "$HOME/.config"
  mkdir -p "$OWNER_DIR"
}

_render() {
  : > "$OWNER_DIR/docker-compose.yml"
  : > "$OWNER_DIR/ownership.manifest"
}

_line_of() {
  grep -n -m1 -- "$1" "$CALLS" | cut -d: -f1
}

_reset
export CBOX_HYPERQWEN_MODE=on
_render
rc=0
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || _fail "up with a missing marker must succeed after the prepare, rc=$rc: $(cat "$CALLS")"
r_line="$(_line_of '^docker run ')"
u_line="$(_line_of '^compose up ')"
[ -n "$r_line" ] || _fail "a missing prepared marker must trigger docker run ... prepare: $(cat "$CALLS")"
[ -n "$u_line" ] || _fail "up must still start serving: $(cat "$CALLS")"
[ "$r_line" -lt "$u_line" ] || _fail "prepare must run before compose up: $(cat "$CALLS")"
grep -q '^docker run .* prepare$' "$CALLS" || _fail "the prepare run must end with the prepare command: $(cat "$CALLS")"
grep -q -- "-v cbox-hyperqwen-u1000-models:/app/models" "$CALLS" || _fail "prepare must mount the models volume: $(cat "$CALLS")"
grep -q -- "-v cbox-hyperqwen-u1000-cache:/cache" "$CALLS" || _fail "prepare must mount the cache volume: $(cat "$CALLS")"
grep -q -- "-e HOME=/cache" "$CALLS" || _fail "prepare must set HOME=/cache: $(cat "$CALLS")"
grep -q -- "--rm" "$CALLS" || _fail "prepare must run with --rm: $(cat "$CALLS")"
[ "$(cat "$OWNER_DIR/prepared")" = "$IMAGE cbox-hyperqwen-u1000-models" ] || _fail "the marker must hold the image reference and the models source"
_ok "up: a missing marker runs prepare before compose up and writes the image and models source"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$OTHER_IMAGE" > "$OWNER_DIR/prepared"
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with a stale marker must succeed"
grep -q '^docker run ' "$CALLS" || _fail "a marker naming another image must rerun prepare: $(cat "$CALLS")"
[ "$(cat "$OWNER_DIR/prepared")" = "$IMAGE cbox-hyperqwen-u1000-models" ] || _fail "the marker must be rewritten with the current image"
_ok "up: a marker naming another image reruns prepare"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with a current marker must succeed"
! grep -q '^docker run ' "$CALLS" || _fail "a current marker must not rerun prepare: $(cat "$CALLS")"
grep -q '^compose up ' "$CALLS" || _fail "up must start serving"
_ok "up: a current marker skips prepare"

: > "$CALLS"
printf '%s\n' "$IMAGE" > "$OWNER_DIR/prepared"
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with an image-only marker must succeed"
grep -q '^docker run ' "$CALLS" || _fail "a marker without the current models source must rerun prepare: $(cat "$CALLS")"
_ok "up: a marker for another models source reruns prepare"

_reset
export CBOX_HYPERQWEN_MODE=on
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
printf 'old render with HOST=0.0.0.0' > "$OWNER_DIR/docker-compose.yml"
: > "$OWNER_DIR/ownership.manifest"
( T_RENDER='new render' _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with a stale render must succeed"
grep -q '^manifest-write$' "$CALLS" || _fail "a compose that differs from the current render must go through reconcile: $(cat "$CALLS")"
[ "$(cat "$OWNER_DIR/docker-compose.yml")" = 'new render' ] || _fail "reconcile must replace the stale compose"
_reset
export CBOX_HYPERQWEN_MODE=on
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
printf 'same' > "$OWNER_DIR/docker-compose.yml"
: > "$OWNER_DIR/ownership.manifest"
( T_RENDER='same' _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with a current render must succeed"
! grep -q '^manifest-write$' "$CALLS" || _fail "an unchanged render must not reconcile: $(cat "$CALLS")"
_ok "up: a compose rendered by an older cbox version is re-rendered, an unchanged one is left alone"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
( T_VOL_RC=1 _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with missing volumes must create them and succeed: $(cat "$CALLS")"
grep -q '^docker volume create --label cbox.kind=infra --label cbox.component=hyperqwen-models .* -- cbox-hyperqwen-u1000-models$' "$CALLS" || _fail "a missing models volume must be created by cbox with infra labels: $(cat "$CALLS")"
grep -q '^docker volume create .*cbox.component=hyperqwen-cache .* -- cbox-hyperqwen-u1000-cache$' "$CALLS" || _fail "a missing cache volume must be created by cbox: $(cat "$CALLS")"
v_line="$(_line_of '^docker volume create ')"
u_line="$(_line_of '^compose up ')"
[ -n "$u_line" ] && [ "$v_line" -lt "$u_line" ] || _fail "volumes must exist before compose up references them as external: $(cat "$CALLS")"
_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with existing volumes must succeed"
! grep -q '^docker volume create ' "$CALLS" || _fail "existing volumes must be reused, never recreated: $(cat "$CALLS")"
_reset
export CBOX_HYPERQWEN_MODE=on
mkdir -p "$TMPBASE/mp"
export CBOX_HYPERQWEN_MODELS_PATH="$TMPBASE/mp"
_render
printf '%s\n' "$IMAGE $TMPBASE/mp" > "$OWNER_DIR/prepared"
( T_VOL_RC=1 _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with a models bind path must succeed: $(cat "$CALLS")"
! grep -q 'hyperqwen-models' "$CALLS" || _fail "a models bind path must not create a models volume: $(cat "$CALLS")"
grep -q 'cbox.component=hyperqwen-cache' "$CALLS" || _fail "the cache volume is still created with a models bind path: $(cat "$CALLS")"
unset CBOX_HYPERQWEN_MODELS_PATH
_ok "volumes: cbox creates missing external volumes with infra labels before compose up, reuses existing ones, skips the models volume for a bind path"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || true
net="$(grep '^docker network create' "$CALLS" | head -n1 | awk '{print $NF}')"
[ -n "$net" ] || _fail "prepare must create a temporary network: $(cat "$CALLS")"
grep -q -- '^docker network create --label cbox.kind=infra --label cbox.component=hyperqwen-prepare' "$CALLS" || _fail "the temporary network must carry the infra labels: $(cat "$CALLS")"
! grep -q -- '--internal' <(grep '^docker network create' "$CALLS") || _fail "the temporary prepare network must not be internal"
grep -q "^docker run .*--network $net " "$CALLS" || _fail "the prepare container must attach to the temporary network: $(cat "$CALLS")"
! grep '^compose ' "$CALLS" | grep -q "$net" || _fail "the serving compose must never receive the temporary network: $(cat "$CALLS")"
grep -q "^docker network rm -- $net" "$CALLS" || _fail "the temporary network must be removed afterwards: $(cat "$CALLS")"
_ok "prepare: temporary non-internal network, never given to the serving compose, removed afterwards"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
T_RUN_RC=1
rc=0
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || _fail "a failed prepare must fail the up"
[ ! -e "$OWNER_DIR/prepared" ] || _fail "a failed prepare must not write the marker"
! grep -q '^compose up ' <(grep -v 'up -d hyperqwen' "$CALLS") || _fail "a failed prepare must not run the full compose up: $(cat "$CALLS")"
grep -q '^docker network rm' "$CALLS" || _fail "a failed prepare must still remove the temporary network"
grep -q '^compose up -d hyperqwen$' "$CALLS" || _fail "a failed prepare must restore serving when it was running before: $(cat "$CALLS")"
_ok "prepare failure: marker not written, network removed, serving restored because it ran before"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
T_RUN_RC=1
T_CID=""
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || true
! grep -q '^compose up' "$CALLS" || _fail "a failed prepare must not start serving that was not running before: $(cat "$CALLS")"
_ok "prepare failure: serving that was not running before stays stopped"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
( _cbox_hyperqwen_prepare_cmd ) >/dev/null 2>&1 || _fail "the prepare verb must succeed"
s_line="$(_line_of '^compose stop hyperqwen')"
r_line="$(_line_of '^docker run ')"
u_line="$(_line_of '^compose up -d hyperqwen$')"
[ -n "$s_line" ] && [ "$s_line" -lt "$r_line" ] || _fail "the prepare verb must stop serving before the run: $(cat "$CALLS")"
[ -n "$u_line" ] && [ "$r_line" -lt "$u_line" ] || _fail "the prepare verb must start serving again afterwards when it was running: $(cat "$CALLS")"
_ok "prepare verb: stops serving, runs prepare, starts serving again when it was running"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
T_CID=""
( _cbox_hyperqwen_prepare_cmd ) >/dev/null 2>&1 || _fail "the prepare verb must succeed with nothing running"
! grep -q '^compose up' "$CALLS" || _fail "the prepare verb must not start serving that was not running: $(cat "$CALLS")"
_ok "prepare verb: does not start serving that was stopped"

_reset
export CBOX_HYPERQWEN_MODE=on
mkdir -p "$TMPBASE/real"
ln -s "$TMPBASE/real" "$OWNER_DIR/prepared"
rc=0
( _cbox_hyperqwen_prepared_write ) >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || _fail "the marker write must refuse a symlink"
[ -z "$(ls -A "$TMPBASE/real")" ] || _fail "nothing may be written through the marker symlink"
_ok "prepared marker: refuses to write through a symlink"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
( _cbox_hyperqwen_down_cmd ) >/dev/null 2>&1 || _fail "down must succeed"
grep -q '^compose down' "$CALLS" || _fail "down must run compose down: $(cat "$CALLS")"
! grep -E '^compose down.* (-v|--volumes)( |$)' "$CALLS" || _fail "down must never remove volumes: $(cat "$CALLS")"
! grep -q 'volume rm' "$CALLS" || _fail "down must never remove a volume"
grep -q '^networks-gc' "$CALLS" || _fail "down must sweep the scope networks"
_ok "down: compose down without -v plus scope network gc"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
T_STATE=exited
( _cbox_hyperqwen_owner_heal_impl ) >/dev/null 2>&1 || _fail "heal with an exited container and a missing marker must not fail"
! grep -q '^docker run ' "$CALLS" || _fail "heal must never run prepare: $(cat "$CALLS")"
! grep -q '^compose up' "$CALLS" || _fail "heal must not start serving without prepared models: $(cat "$CALLS")"
out="$( ( _cbox_hyperqwen_owner_heal_impl ) 2>&1 || true)"
case "$out" in *"cbox hyperqwen prepare"*) ;; *) _fail "heal must print the prepare fix: $out" ;; esac
_ok "heal: missing marker prints the fix, never downloads, never starts"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
T_STATE=exited
( _cbox_hyperqwen_owner_heal_impl ) >/dev/null 2>&1 || _fail "heal of an exited prepared container must succeed"
grep -q '^compose up -d hyperqwen$' "$CALLS" || _fail "heal must start a stopped container detached: $(cat "$CALLS")"
! grep -q '^docker run ' "$CALLS" || _fail "heal must never run prepare"
_ok "heal: a stopped prepared container is started detached"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
T_STATE=running
( _cbox_hyperqwen_owner_heal_impl ) >/dev/null 2>&1 || _fail "heal of a running container must succeed"
! grep -q '^compose up' "$CALLS" || _fail "heal must leave a running container alone"
_reset
( _cbox_hyperqwen_owner_heal_impl ) >/dev/null 2>&1
[ ! -s "$CALLS" ] || _fail "heal with the mode off must not touch docker: $(cat "$CALLS")"
_ok "heal: a running container and the mode off are left alone"

_models_guard_rc() {
  local rc=0
  ( _cbox_hyperqwen_models_guard ) >"$TMPBASE/guard.out" 2>&1 || rc=$?
  echo "$rc"
}
_reset
[ "$(_models_guard_rc)" = 0 ] || _fail "an empty models path must pass the guard"
export CBOX_HYPERQWEN_MODELS_PATH="relative/dir"
[ "$(_models_guard_rc)" = 1 ] || _fail "a relative models path must be refused"
grep -q 'absolute' "$TMPBASE/guard.out" || _fail "the relative refusal must say why"
export CBOX_HYPERQWEN_MODELS_PATH="$TMPBASE/missing"
[ "$(_models_guard_rc)" = 1 ] || _fail "a missing models path must be refused"
mkdir -p "$TMPBASE/models-real"
ln -s "$TMPBASE/models-real" "$TMPBASE/models-link"
export CBOX_HYPERQWEN_MODELS_PATH="$TMPBASE/models-link"
[ "$(_models_guard_rc)" = 1 ] || _fail "a symlinked models path must be refused"
grep -q 'symlink' "$TMPBASE/guard.out" || _fail "the symlink refusal must say why"
: > "$TMPBASE/models-file"
export CBOX_HYPERQWEN_MODELS_PATH="$TMPBASE/models-file"
[ "$(_models_guard_rc)" = 1 ] || _fail "a regular file must be refused"
export CBOX_HYPERQWEN_MODELS_PATH="$TMPBASE/models-real"
T_STAT_UID=0
[ "$(_models_guard_rc)" = 1 ] || _fail "a foreign-owned models path must be refused"
grep -q 'not owned' "$TMPBASE/guard.out" || _fail "the owner refusal must say why"
T_STAT_UID=1000
[ "$(_models_guard_rc)" = 0 ] || _fail "an absolute existing directory owned by the user must pass"
_ok "models path guard: empty ok, relative/missing/symlink/file/foreign refused, real directory ok"

_reset
export CBOX_HYPERQWEN_MODE=on
mkdir -p "$TMPBASE/models-real"
export CBOX_HYPERQWEN_MODELS_PATH="$TMPBASE/models-real"
_render
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with a bind models path must succeed"
grep -q -- "-v $TMPBASE/models-real:/app/models" "$CALLS" || _fail "prepare must mount the bind path as the models dir: $(cat "$CALLS")"
_ok "prepare: a configured models path is mounted instead of the named volume"

_reset
export CBOX_HYPERQWEN_MODE=on
export CBOX_HYPERQWEN_MODELS_PATH="relative/dir"
_render
rc=0
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || _fail "up must refuse a bad models path"
! grep -q '^docker run ' "$CALLS" || _fail "a refused models path must not reach docker run"
_ok "up: a bad models path is refused before any docker action"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
T_PS_CID=foreign1
T_LABELS="||"
rc=0
out="$( ( _cbox_hyperqwen_adopt_or_refuse "$OWNER_DIR" ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "adopt must refuse a foreign container with the expected name: $out"
case "$out" in *"not cbox-owned"*) ;; *) _fail "the refusal must name the problem: $out" ;; esac
_reset
export CBOX_HYPERQWEN_MODE=on
_render
T_PS_CID=own1
T_LABELS="infra|hyperqwen|cbox-infra-u1000-hyperqwen"
T_PROJECT="cbox-infra-u1000-hyperqwen"
T_IMAGE="$IMAGE"
( _cbox_hyperqwen_adopt_or_refuse "$OWNER_DIR" ) >/dev/null 2>&1 || _fail "adopt must accept a cbox-owned container"
T_PROJECT="someone-else"
rc=0
( _cbox_hyperqwen_adopt_or_refuse "$OWNER_DIR" ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "adopt must refuse a container from another compose project"
T_PS_CID=""
( _cbox_hyperqwen_adopt_or_refuse "$OWNER_DIR" ) >/dev/null 2>&1 || _fail "adopt must pass when nothing exists"
_ok "adopt: foreign container refused, owned container accepted, foreign project refused, nothing present passes"

_reset
rc=0
out="$( ( hyperqwen_cmd up ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "up with the mode off must be refused"
case "$out" in *"config set CBOX_HYPERQWEN_MODE=on"*) ;; *) _fail "the off refusal must name the enable command: $out" ;; esac
for sub in down prepare logs; do
  rc=0
  ( hyperqwen_cmd "$sub" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || _fail "$sub with the mode off must be refused"
done
for sub in status ps; do
  out="$( ( hyperqwen_cmd "$sub" ) 2>&1)" || _fail "$sub with the mode off must still work: $out"
  case "$out" in *"OFF"*) ;; *) _fail "$sub with the mode off must say OFF: $out" ;; esac
done
_ok "mode-off guard: up/down/prepare/logs refused, status/ps report OFF"

_reset
_render
: > "$OWNER_DIR/prepared"
( hyperqwen_cmd reconcile ) >/dev/null 2>&1 || _fail "reconcile with the mode off must succeed"
grep -q '^compose down' "$CALLS" || _fail "reconcile with the mode off must tear the project down: $(cat "$CALLS")"
! grep -E '^compose down.* (-v|--volumes)( |$)' "$CALLS" || _fail "teardown must never remove volumes"
[ ! -e "$OWNER_DIR/docker-compose.yml" ] || _fail "reconcile with the mode off must de-render the compose file"
[ ! -e "$OWNER_DIR/ownership.manifest" ] || _fail "reconcile with the mode off must remove the manifest"
[ -e "$OWNER_DIR/prepared" ] || _fail "the prepared marker describes downloaded models and must survive a teardown"
_ok "reconcile with the mode off: torn down and de-rendered, volumes and marker kept"

_reset
export T_INCONTAINER=1
export CBOX_HYPERQWEN_MODE=on
for sub in status ps up down prepare reconcile logs gpu-check; do
  rc=0
  out="$( ( hyperqwen_cmd "$sub" ) 2>&1)" || rc=$?
  [ "$rc" = 1 ] || _fail "$sub must be refused inside a container"
  case "$out" in *"host-only"*) ;; *) _fail "$sub refusal must say host-only: $out" ;; esac
done
! grep -q '^docker ' "$CALLS" || _fail "nothing may reach docker inside a container"
unset T_INCONTAINER
_ok "in-container refusal: every verb is host-only"

_reset
rc=0
out="$( ( hyperqwen_cmd bogus ) 2>&1)" || rc=$?
[ "$rc" = 1 ] || _fail "an unknown verb must fail"
case "$out" in *"hyperqwen {status|ps|up|down|prepare|reconcile|logs [-f]|gpu-check}"*) ;; *) _fail "usage must list every verb: $out" ;; esac
_ok "usage lists every verb"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
( hyperqwen_cmd logs -f ) >/dev/null 2>&1 || _fail "logs -f must succeed"
grep -q '^compose logs --tail 200 -f hyperqwen$' "$CALLS" || _fail "logs -f must follow with a 200 line tail: $(cat "$CALLS")"
: > "$CALLS"
( hyperqwen_cmd logs ) >/dev/null 2>&1 || _fail "logs must succeed"
grep -q '^compose logs --tail 200 hyperqwen$' "$CALLS" || _fail "logs must tail 200 lines: $(cat "$CALLS")"
rc=0
( hyperqwen_cmd logs --nope ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || _fail "logs must reject unknown flags"
_ok "logs: compose logs --tail 200 [-f] hyperqwen"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
( _cbox_hyperqwen_ps_cmd ) >/dev/null 2>&1 || _fail "ps must succeed with a running container"
grep -q '^docker exec -- hqcid curl -sf http://127.0.0.1:18020/health$' "$CALLS" || _fail "ps must probe /health through docker exec: $(cat "$CALLS")"
grep -q '^docker exec -- hqcid curl -sf http://127.0.0.1:18020/v1/models$' "$CALLS" || _fail "ps must list /v1/models through docker exec: $(cat "$CALLS")"
_ok "ps: health and served models through docker exec"

_reset
export CBOX_HYPERQWEN_GPU_DEVICE="1,GPU-abc"
( _cbox_hyperqwen_gpu_check_cmd ) >/dev/null 2>&1 || _fail "gpu-check must pass with the stubbed docker"
grep -q -- "^docker run --rm --entrypoint nvidia-smi --device nvidia.com/gpu=1 -- $IMAGE\$" "$CALLS" || _fail "gpu-check must use the first CDI id: $(cat "$CALLS")"
_reset
( _cbox_hyperqwen_gpu_check_cmd ) >/dev/null 2>&1
grep -q -- "--device nvidia.com/gpu=all" "$CALLS" || _fail "gpu-check defaults to all: $(cat "$CALLS")"
_ok "gpu-check: nvidia-smi through the first CDI device of the pinned image"

_reset
( T_IMAGE_RC=1 _cbox_hyperqwen_gpu_check_cmd ) >/dev/null 2>&1 || _fail "gpu-check with the image not pulled must pass through the base image"
grep -q -- "^docker run --rm --entrypoint nvidia-smi --device nvidia.com/gpu=all -- nvidia/cuda:13.0.3-base-ubuntu24.04\$" "$CALLS" || _fail "gpu-check must use the small CUDA base image while the real image is not pulled: $(cat "$CALLS")"
! grep -q -- "^docker run .*-- $IMAGE\$" "$CALLS" || _fail "gpu-check must never pull the 9.5 GB image: $(cat "$CALLS")"
_reset
if T_CUDA=12.8 _cbox_hyperqwen_gpu_check_cmd >/dev/null 2>&1; then _fail "gpu-check must fail on a driver below CUDA 13"; fi
_ok "gpu-check: base image while the real image is absent, CUDA 13 driver floor"

_reset
export CBOX_HYPERQWEN_MODE=on
export CBOX_OLLAMA_MODE=on CBOX_OLLAMA_GPU=cdi
out="$( ( _cbox_local_backends_gpu_overlap_warn ) 2>&1)"
case "$out" in *"WARN"*"CBOX_OLLAMA_MODE=off"*) ;; *) _fail "overlapping backends must warn and name the fix: $out" ;; esac
CBOX_OLLAMA_GPU_DEVICE=0 CBOX_HYPERQWEN_GPU_DEVICE=1 out="$( ( _cbox_local_backends_gpu_overlap_warn ) 2>&1)"
[ -z "$out" ] || _fail "disjoint device pins must not warn: $out"
CBOX_OLLAMA_GPU=off out="$( ( _cbox_local_backends_gpu_overlap_warn ) 2>&1)"
[ -z "$out" ] || _fail "an ollama on cpu must not warn: $out"
_ok "overlap warning: printed for shared cards only, never fatal"

_reset
export CBOX_HYPERQWEN_MODE=on
export CBOX_OLLAMA_MODE=on CBOX_OLLAMA_GPU=cdi
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
out="$( ( _cbox_hyperqwen_reconcile_cmd ) 2>&1)" || _fail "an overlap must warn, never refuse: $out"
case "$out" in *WARN*) ;; *) _fail "reconcile must print the overlap warning: $out" ;; esac
_ok "reconcile: overlap warns and continues"

KIB_GIB() { printf '%s' "$(($1 * 1048576))"; }

_offload_env() {
  export CBOX_HYPERQWEN_MODE=on CBOX_HYPERQWEN_KV_OFFLOAD=on
}

_meminfo_reads() {
  grep -c '^meminfo-read$' "$CALLS" || true
}

_reset
_offload_env
out="$( T_MEM_KIB="$(KIB_GIB 20)" _cbox_hyperqwen_offload_preflight_warn 2>&1)" || _fail "the preflight must never fail"
case "$out" in *"WARN"*"19072 MiB"*"-4096 MiB"*"MemAvailable 20480 MiB"*"CBOX_HYPERQWEN_RAM_RESERVE_GIB 16 GiB"*"8 GiB engine headroom"*) ;; *) _fail "a too low MemAvailable must print one WARN with the numbers: $out" ;; esac
case "$out" in *"CBOX_HYPERQWEN_KV_OFFLOAD_MIB"*"CBOX_HYPERQWEN_KV_OFFLOAD=off"*) ;; *) _fail "the WARN must name both fixes: $out" ;; esac
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || _fail "the WARN must be one line: $out"
_ok "preflight: a too low MemAvailable prints one WARN with the numbers and both fixes"

_reset
_offload_env
out="$( T_MEM_KIB="$(KIB_GIB 54)" _cbox_hyperqwen_offload_preflight_warn 2>&1)"
[ -z "$out" ] || _fail "sufficient MemAvailable must print nothing: $out"
out="$( T_MEM_KIB="$((43648 * 1024))" _cbox_hyperqwen_offload_preflight_warn 2>&1)"
[ -z "$out" ] || _fail "a budget exactly equal to the offload size must print nothing: $out"
out="$( T_MEM_KIB="$((43647 * 1024))" _cbox_hyperqwen_offload_preflight_warn 2>&1)"
case "$out" in *WARN*) ;; *) _fail "one MiB below the budget must warn: $out" ;; esac
_ok "preflight: nothing printed when the offload fits, WARN one MiB past the boundary"

_reset
_offload_env
export CBOX_HYPERQWEN_RAM_RESERVE_GIB=8
out="$( T_MEM_KIB="$(KIB_GIB 40)" _cbox_hyperqwen_offload_preflight_warn 2>&1)"
[ -z "$out" ] || _fail "a smaller reserve must widen the budget: $out"
export CBOX_HYPERQWEN_RAM_RESERVE_GIB=16
out="$( T_MEM_KIB="$(KIB_GIB 40)" _cbox_hyperqwen_offload_preflight_warn 2>&1)"
case "$out" in *WARN*"16384 MiB"*) ;; *) _fail "the default reserve must give a 16384 MiB budget at 40 GiB: $out" ;; esac
export CBOX_HYPERQWEN_KV_OFFLOAD_MIB=8192
out="$( T_MEM_KIB="$(KIB_GIB 40)" _cbox_hyperqwen_offload_preflight_warn 2>&1)"
[ -z "$out" ] || _fail "a smaller offload size must fit: $out"
_ok "preflight: budget follows the reserve and the configured size"

_reset
_offload_env
out="$( T_MEM_KIB= _cbox_hyperqwen_offload_preflight_warn 2>&1)" || _fail "an unreadable MemAvailable must not fail"
case "$out" in *WARN*"could not be read"*) ;; *) _fail "an unreadable MemAvailable must say the check was skipped: $out" ;; esac
_ok "preflight: an unreadable MemAvailable says the check was skipped and continues"

_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 20)"
( _cbox_hyperqwen_reconcile_cmd ) >/dev/null 2>&1 || _fail "reconcile with offload off must succeed"
[ "$(_meminfo_reads)" = 0 ] || _fail "reconcile with offload off must never read meminfo: $(cat "$CALLS")"
: > "$CALLS"
( _cbox_hyperqwen_up_cmd ) >/dev/null 2>&1 || _fail "up with offload off must succeed"
[ "$(_meminfo_reads)" = 0 ] || _fail "up with offload off must never read meminfo: $(cat "$CALLS")"
_reset
export CBOX_HYPERQWEN_MODE=on
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 20)"
T_STATE=exited
( _cbox_hyperqwen_owner_heal_impl ) >/dev/null 2>&1 || _fail "heal with offload off must succeed"
[ "$(_meminfo_reads)" = 0 ] || _fail "heal with offload off must never read meminfo: $(cat "$CALLS")"
grep -q '^compose up -d hyperqwen$' "$CALLS" || _fail "heal with offload off must still start the container"
unset T_MEM_KIB
_ok "offload off: reconcile, up and heal never read meminfo and print no offload warning"

_reset
_offload_env
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 20)"
rc=0
out="$( ( _cbox_hyperqwen_reconcile_cmd ) 2>&1)" || rc=$?
[ "$rc" = 0 ] || _fail "reconcile must proceed after the WARN, rc=$rc: $out"
[ "$(printf '%s\n' "$out" | grep -c 'WARN - hyperqwen KV offload')" = 1 ] || _fail "reconcile must print the offload WARN exactly once: $out"
grep -q '^compose up -d' "$CALLS" || _fail "reconcile must still bring the server up after the WARN: $(cat "$CALLS")"
[ "$(_meminfo_reads)" = 1 ] || _fail "reconcile must read meminfo once: $(cat "$CALLS")"
case "$out" in *"still holds its own RAM"*) ;; *) _fail "a replaced running container must be mentioned in the WARN: $out" ;; esac
_ok "reconcile: the WARN is printed once and the start still proceeds"

_reset
_offload_env
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 54)"
out="$( ( _cbox_hyperqwen_reconcile_cmd ) 2>&1)" || _fail "reconcile with a fitting offload must succeed: $out"
case "$out" in *"KV offload"*) _fail "a fitting offload must print no offload text: $out" ;; esac
grep -q '^compose up -d' "$CALLS" || _fail "reconcile must bring the server up"
_ok "reconcile: nothing printed when the offload fits"

_reset
_offload_env
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 20)" T_CID=
rc=0
out="$( ( _cbox_hyperqwen_up_cmd ) 2>&1)" || rc=$?
[ "$rc" = 0 ] || _fail "up must proceed after the WARN, rc=$rc: $out"
case "$out" in *"WARN - hyperqwen KV offload"*) ;; *) _fail "up with no running container must print the WARN: $out" ;; esac
case "$out" in *"still holds its own RAM"*) _fail "no running container, no add-back note: $out" ;; esac
grep -q '^compose up -d' "$CALLS" || _fail "up must still bring the server up after the WARN: $(cat "$CALLS")"
_ok "up: with no running container the WARN is printed and the start proceeds"

_reset
_offload_env
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 20)"
out="$( ( _cbox_hyperqwen_up_cmd ) 2>&1)" || _fail "up of a running server must succeed: $out"
[ "$(_meminfo_reads)" = 0 ] || _fail "up of an already running server must not read meminfo: $(cat "$CALLS")"
case "$out" in *"KV offload"*) _fail "up of an already running server must not warn: $out" ;; esac
_ok "up: an already running server is not re-checked against its own RAM"

_reset
_offload_env
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 20)"
T_STATE=exited
rc=0
out="$( ( _cbox_hyperqwen_owner_heal_impl ) 2>&1)" || rc=$?
[ "$rc" = 0 ] || _fail "heal must stay non-blocking after the WARN, rc=$rc: $out"
case "$out" in *"WARN - hyperqwen KV offload"*) ;; *) _fail "heal of a stopped container must print the WARN: $out" ;; esac
grep -q '^compose up -d hyperqwen$' "$CALLS" || _fail "heal must still start the container after the WARN: $(cat "$CALLS")"
_reset
_offload_env
_render
printf '%s\n' "$IMAGE cbox-hyperqwen-u1000-models" > "$OWNER_DIR/prepared"
export T_MEM_KIB="$(KIB_GIB 20)"
T_STATE=running
( _cbox_hyperqwen_owner_heal_impl ) >/dev/null 2>&1 || _fail "heal of a running container must succeed"
[ "$(_meminfo_reads)" = 0 ] || _fail "heal of a running container must not read meminfo: $(cat "$CALLS")"
_reset
_offload_env
_render
T_STATE=exited
export T_MEM_KIB="$(KIB_GIB 20)"
( _cbox_hyperqwen_owner_heal_impl ) >/dev/null 2>&1 || _fail "heal with a missing marker must not fail"
[ "$(_meminfo_reads)" = 0 ] || _fail "heal without prepared models must not read meminfo: $(cat "$CALLS")"
unset T_MEM_KIB
_ok "heal: the WARN precedes a start that still proceeds, nothing is read for a running or unprepared server"

echo "PASS: all hyperqwen lifecycle checks"
