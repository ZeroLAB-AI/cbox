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
bash -n "$INSTALL_DIR/templates/generators.sh" || _fail "generators.sh fails bash -n"
_ok "bash -n clean on cbox and templates/generators.sh"

render_compose() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export "$@"
    gen_ollama_owner_compose_into "$dir"
  )
}

D1="$TMPBASE/off"
mkdir -p "$D1"
touch "$D1/docker-compose.yml" "$D1/docker-compose.gpu.yml"
render_compose "$D1" CBOX_OLLAMA_MODE=off
[ ! -f "$D1/docker-compose.yml" ] || _fail "off mode must remove docker-compose.yml"
[ ! -f "$D1/docker-compose.gpu.yml" ] || _fail "off mode must remove docker-compose.gpu.yml"
[ -z "$(ls -A "$D1")" ] || _fail "off mode must render nothing at all into the owner dir: $(ls -A "$D1")"
_ok "CBOX_OLLAMA_MODE=off renders nothing at all (no compose, no gpu overlay, dir left empty)"

D2="$TMPBASE/dedicated-nogpu"
render_compose "$D2" CBOX_OLLAMA_MODE=on CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off \
  CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434 CBOX_OLLAMA_NUM_PARALLEL=2
[ -f "$D2/docker-compose.yml" ] || _fail "dedicated/no-gpu: docker-compose.yml missing"
[ ! -f "$D2/docker-compose.gpu.yml" ] || _fail "dedicated/no-gpu: gpu overlay must not be rendered when CBOX_OLLAMA_GPU=off"
grep -Eq '^name: "?cbox-infra-u' "$D2/docker-compose.yml" || _fail "owner project name missing"
grep -q 'cbox.kind: infra' "$D2/docker-compose.yml" || _fail "cbox.kind=infra label missing"
grep -q 'cbox.component: ollama' "$D2/docker-compose.yml" || _fail "cbox.component=ollama label missing"
grep -Eq 'restart: "?unless-stopped"?' "$D2/docker-compose.yml" || _fail "restart policy must be unless-stopped"
grep -q 'healthcheck:' "$D2/docker-compose.yml" || _fail "healthcheck missing"
grep -q 'OLLAMA_NUM_PARALLEL=2' "$D2/docker-compose.yml" || _fail "OLLAMA_NUM_PARALLEL not passed through from CBOX_OLLAMA_NUM_PARALLEL"
grep -Eq 'image: "?ollama/ollama:0.32.5"?' "$D2/docker-compose.yml" || _fail "pinned image reference missing"
! grep -Eq '^\s*ports:' "$D2/docker-compose.yml" || _fail "dedicated/no-gpu: must not publish ports"
grep -Eq '^networks:' "$D2/docker-compose.yml" || _fail "dedicated/no-gpu: must declare a top-level networks section (the owner project's own default network must not be the implicit routable one)"
grep -q '^  default:' "$D2/docker-compose.yml" || _fail "dedicated/no-gpu: default network stanza missing"
grep -q 'internal: true' "$D2/docker-compose.yml" || _fail "dedicated/no-gpu: default network must be internal: true (no permanent egress)"
grep -q 'cbox.component: ollama-net' "$D2/docker-compose.yml" || _fail "dedicated/no-gpu: default network missing cbox.component=ollama-net label (must not be netaccess-invisible AND routable at once)"
grep -q 'cbox-ollama-u' "$D2/docker-compose.yml" | true
grep -q ':/root/.ollama$' "$D2/docker-compose.yml" || _fail "dedicated store must mount a whole-home named volume, not just models/"
_ok "dedicated store + gpu=off: compose shape correct (name, labels, restart, healthcheck, image, OLLAMA_NUM_PARALLEL, no ports, internal labeled default network, no gpu overlay)"

D3="$TMPBASE/dedicated-gpu"
render_compose "$D3" CBOX_OLLAMA_MODE=on CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=cdi \
  CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434 CBOX_OLLAMA_NUM_PARALLEL=1
[ -f "$D3/docker-compose.gpu.yml" ] || _fail "gpu=cdi must render docker-compose.gpu.yml"
grep -q 'driver: cdi' "$D3/docker-compose.gpu.yml" || _fail "gpu overlay missing cdi driver"
grep -q 'nvidia.com/gpu=all' "$D3/docker-compose.gpu.yml" || _fail "gpu overlay missing device_ids reservation"
awk '/^services:/,0' "$D3/docker-compose.gpu.yml" | grep -q '^  ollama:' || _fail "gpu overlay must target the ollama service"
_ok "gpu=cdi: overlay rendered and targets the ollama service only"

D4="$TMPBASE/shared"
render_compose "$D4" CBOX_OLLAMA_MODE=on CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off \
  CBOX_OLLAMA_STORE=shared CBOX_OLLAMA_STORE_PATH=/home/marek/.ollama CBOX_OLLAMA_PORT=11434 CBOX_OLLAMA_NUM_PARALLEL=1
grep -q '/home/marek/.ollama/models:/root/.ollama/models' "$D4/docker-compose.yml" \
  || _fail "shared store must mount only the models/ subdirectory"
! grep -q '/home/marek/.ollama:/root/.ollama"' "$D4/docker-compose.yml" \
  || _fail "shared store must not mount the whole host ollama directory"
_ok "shared store: mounts only models/ subdirectory, never the whole host ollama dir"

grep -Eq '^\s*user: "[0-9]+:[0-9]+"' "$D4/docker-compose.yml" \
  || _fail "shared store must render a user: uid:gid stanza so manifests/blobs are not written root-owned"
_ok "shared store: renders user: uid:gid so the host directory is not written root-owned"

grep -q 'restart: "no"' "$D4/docker-compose.yml" \
  || _fail "shared store must render restart: no so a reboot cannot bring an unchecked shared-store container back up"
_ok "shared store: restart policy is 'no', not unless-stopped (a reboot must not bypass the host-daemon guard)"

grep -q 'restart: "unless-stopped"' "$D2/docker-compose.yml" \
  || _fail "dedicated store must keep restart: unless-stopped"
_ok "dedicated store: restart policy remains unless-stopped"

D5="$TMPBASE/toggle"
render_compose "$D5" CBOX_OLLAMA_MODE=on CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=cdi \
  CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434 CBOX_OLLAMA_NUM_PARALLEL=1
[ -f "$D5/docker-compose.gpu.yml" ] || _fail "setup: gpu overlay expected before toggling off"
render_compose "$D5" CBOX_OLLAMA_MODE=on CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off \
  CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434 CBOX_OLLAMA_NUM_PARALLEL=1
[ ! -f "$D5/docker-compose.gpu.yml" ] || _fail "toggling CBOX_OLLAMA_GPU back to off must remove the stale gpu overlay"
_ok "toggling gpu off after on removes the stale overlay file (no leftover CDI reservation)"

manifest_write_and_check() {
  local dir="$1"
  shift
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export "$@"
    mkdir -p "$dir"
    _cbox_ollama_manifest_write "$dir"
  )
}

manifest_matches() {
  local dir="$1"
  shift
  ( set -e
    source "$INSTALL_DIR/templates/generators.sh"
    export "$@"
    if _cbox_ollama_manifest_matches_current "$dir"; then
      printf 'MATCH\n'
    else
      printf 'NOMATCH\n'
    fi
  )
}

M1="$TMPBASE/manifest1"
manifest_write_and_check "$M1" CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434
[ -f "$M1/ownership.manifest" ] || _fail "ownership manifest not written"
grep -q '^image=ollama/ollama:0.32.5$' "$M1/ownership.manifest" || _fail "manifest missing image field"
grep -q '^uid=' "$M1/ownership.manifest" || _fail "manifest missing uid field"
grep -q '^store_path=' "$M1/ownership.manifest" || _fail "manifest missing store_path field"
grep -q '^gpu=off$' "$M1/ownership.manifest" || _fail "manifest missing gpu field"
grep -q '^port=11434$' "$M1/ownership.manifest" || _fail "manifest missing port field"
grep -q '^owner=cbox-infra-u' "$M1/ownership.manifest" || _fail "manifest missing owner field"
_ok "ownership manifest records image, uid, store path, gpu mode, and port"

out="$(manifest_matches "$M1" CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434)"
[ "$out" = MATCH ] || _fail "unchanged config must match its own manifest, got $out"
_ok "manifest self-match: unchanged config matches"

out="$(manifest_matches "$M1" CBOX_OLLAMA_IMAGE=ollama/ollama:0.33.0 CBOX_OLLAMA_GPU=off CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434)"
[ "$out" = NOMATCH ] || _fail "changed image must not match, got $out"
_ok "manifest mismatch: changed image is detected"

out="$(manifest_matches "$M1" CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=cdi CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434)"
[ "$out" = NOMATCH ] || _fail "changed gpu mode must not match, got $out"
_ok "manifest mismatch: changed gpu mode is detected"

out="$(manifest_matches "$M1" CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=9999)"
[ "$out" = NOMATCH ] || _fail "changed port must not match, got $out"
_ok "manifest mismatch: changed port is detected"

M2="$TMPBASE/manifest-missing"
mkdir -p "$M2"
out="$(manifest_matches "$M2" CBOX_OLLAMA_IMAGE=ollama/ollama:0.32.5 CBOX_OLLAMA_GPU=off CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434)"
[ "$out" = NOMATCH ] || _fail "a missing manifest must never claim a match, got $out"
_ok "no manifest present: never claims a match (fails closed)"

ADOPT_FN="$(awk '/^_cbox_ollama_adopt_or_refuse\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
[ -n "$ADOPT_FN" ] || _fail "cannot extract _cbox_ollama_adopt_or_refuse from cbox"
NAME_FN="$(awk '/^_cbox_ollama_owner_name\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh")"
[ -n "$NAME_FN" ] || _fail "cannot extract _cbox_ollama_owner_name from generators.sh"
MATCH_FN="$(awk '/^_cbox_ollama_manifest_matches_current\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh")"
[ -n "$MATCH_FN" ] || _fail "cannot extract _cbox_ollama_manifest_matches_current from generators.sh"

run_adopt() {
  local labels="$1" manifest_ok="$2" project="${3:-cbox-infra-u0}" running_image="${4:-ollama/ollama:0.32.5}" \
    configured_image="${5:-ollama/ollama:0.32.5}"
  bash -c '
    set -u
    '"$NAME_FN"'
    CBOX_OLLAMA_IMAGE="'"$configured_image"'"
    _cbox_ollama_manifest_matches_current() { [ "'"$manifest_ok"'" = 1 ]; }
    '"$ADOPT_FN"'
    docker() {
      case "$1" in
        ps) printf "existing-cid\n" ;;
        inspect)
          case "$*" in
            *"com.docker.compose.project"*) printf "%s\n" "'"$project"'" ;;
            *".Config.Image"*) printf "%s\n" "'"$running_image"'" ;;
            *) printf "%s\n" "'"$labels"'" ;;
          esac
          ;;
      esac
    }
    _cbox_ollama_adopt_or_refuse /tmp/dir
  ' adopttest 2>&1
  echo "RC=$?"
}

out="$(run_adopt 'infra|ollama|cbox-infra-u0' 1)"
echo "$out" | grep -q 'RC=0' || _fail "matching cbox-owned container must be adopted silently: $out"
! echo "$out" | grep -qi refus || _fail "matching cbox-owned container must not be refused: $out"
_ok "adopt: cbox-owned container with matching labels and manifest is adopted without complaint"

out="$(run_adopt 'infra|ollama|cbox-infra-u0' 1 'some-other-project' 'ollama/ollama:0.32.5' 'ollama/ollama:0.32.5')"
echo "$out" | grep -q 'RC=1' || _fail "a container with cbox labels but belonging to a different compose project must be refused: $out"
echo "$out" | grep -qi 'compose project' || _fail "the refusal must name the compose project mismatch: $out"
_ok "adopt: a labeled container belonging to a different compose project is refused, not silently adopted"

out="$(run_adopt 'infra|ollama|cbox-infra-u0' 1 'cbox-infra-u0' 'attacker/evil:latest' 'ollama/ollama:0.32.5')"
echo "$out" | grep -q 'RC=0' || _fail "an image mismatch must report, not hard-refuse (rc=0): $out"
echo "$out" | grep -qi 'does not match the configured' || _fail "an image mismatch against CBOX_OLLAMA_IMAGE must be reported: $out"
_ok "adopt: a running container whose image no longer matches CBOX_OLLAMA_IMAGE is reported, not silently trusted"

out="$(run_adopt 'infra|ollama|cbox-infra-u0' 0)"
echo "$out" | grep -q 'RC=0' || _fail "cbox-owned container with mismatched manifest must still return 0 (report only): $out"
echo "$out" | grep -q 'ownership manifest does not match' || _fail "manifest mismatch on an owned container must be reported: $out"
_ok "adopt: cbox-owned container with a stale manifest is reported, not silently accepted"

out="$(run_adopt 'unrelated|unrelated|unrelated' 1)"
echo "$out" | grep -q 'RC=1' || _fail "a name/label collision with a non-cbox container must refuse (rc=1): $out"
echo "$out" | grep -q 'existing-cid' || _fail "the refusal message must name what it found: $out"
_ok "adopt: name collision with a container cbox does not own is refused, naming what it found"

grep -q 'ollama) shift; ollama_cmd "\$@";;' "$INSTALL_DIR/cbox" || _fail "ollama verb not wired into the dispatcher"
grep -q 'ollama {status|up|down|pull <model>|reconcile}' "$INSTALL_DIR/cbox" || _fail "ollama missing from usage text"
grep -q 'HUB_ROWS+=("ollama")' "$INSTALL_DIR/cbox" || _fail "ollama row missing from the hub"
grep -q 'ollama) _hub_ollama_submenu' "$INSTALL_DIR/cbox" || _fail "ollama row not dispatched in the hub"
_ok "wiring: dispatcher, usage, hub row and hub dispatch all present"

awk '/^ollama_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_ollama_guard' \
  || _fail "ollama_cmd does not call the off-guard for state-changing subcommands"
awk '/^_cbox_ollama_guard\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'CBOX_OLLAMA_MODE' \
  || _fail "_cbox_ollama_guard does not check CBOX_OLLAMA_MODE"
_ok "guard: ollama verbs die with a clear message when the feature is off"

awk '/^ollama_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q '_cbox_config_in_container' \
  || _fail "ollama_cmd does not refuse to run inside a container"
_ok "guard: ollama is host-only, mirroring netaccess"

for sub in status up down pull reconcile; do
  awk '/^ollama_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q "$sub" \
    || _fail "ollama_cmd case statement missing '$sub'"
done
_ok "ollama_cmd recognizes status, up, down, pull, and reconcile"

awk '/^ollama_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eq 'flock -x( -w [0-9]+)? 6' \
  || _fail "ollama_cmd does not take an exclusive machine-level lock for state-changing verbs"
awk '/^ollama_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -Eq 'flock -s( -w [0-9]+)? 6' \
  || _fail "ollama_cmd does not take a shared lock for status"
awk '/^ollama_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q -- '-w 30' \
  || _fail "ollama_cmd flocks should carry a wait timeout, not block forever"
_ok "locking: state-changing verbs hold a timed exclusive machine lock, status takes a timed shared lock"

awk '/^_cbox_ollama_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'OFF' \
  || _fail "status does not report OFF"
awk '/^_cbox_ollama_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'CONFIG-ONLY' \
  || _fail "status does not report CONFIG-ONLY"
awk '/^_cbox_ollama_status_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox" | grep -q 'ACTIVE' \
  || _fail "status does not report ACTIVE"
_ok "status clearly distinguishes OFF, CONFIG-ONLY, and ACTIVE"

PULL_FN="$(awk '/^_cbox_ollama_pull_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
echo "$PULL_FN" | grep -q 'stop ollama' \
  || _fail "pull does not stop the serving container before granting egress"
echo "$PULL_FN" | grep -q 'network create' \
  || _fail "pull does not create a temporary egress network"
echo "$PULL_FN" | grep -q 'network rm' \
  || _fail "pull does not remove the temporary egress network afterwards"
echo "$PULL_FN" | grep -q 'up -d ollama' \
  || _fail "pull does not restore the serving container after the pull"
_ok "pull: stops the server, grants egress only for the pull's duration, tears the egress network down, restarts the server"

echo "$PULL_FN" | grep -q "ollama pull '\$model'" \
  && _fail "pull still interpolates the raw model string into a single-quoted sh -c string (command injection)"
echo "$PULL_FN" | grep -Fq 'ollama pull "$1"' \
  || _fail "pull must pass the model as a positional argument (\"\$1\") to the nested sh -c, not interpolate it"
echo "$PULL_FN" | grep -q '_cbox_ollama_model_ref_ok' \
  || _fail "pull does not validate the model reference before use"
_ok "pull: model reference is validated and passed positionally, not interpolated into the shell string"

MODELOK_FN="$(awk '/^_cbox_ollama_model_ref_ok\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
[ -n "$MODELOK_FN" ] || _fail "cannot extract _cbox_ollama_model_ref_ok"
run_model_ok() {
  bash -c '
    set -u
    '"$MODELOK_FN"'
    _cbox_ollama_model_ref_ok "$1"
  ' modeloktest "$1"
}
run_model_ok "llama3:8b" || _fail "a plain model reference must be accepted"
run_model_ok "registry.example.com/models/llama3@sha256:abcdef0123" || _fail "a digest-pinned reference must be accepted"
! run_model_ok "x'; touch /tmp/pwned; '" || _fail "a model reference containing shell metacharacters must be rejected"
! run_model_ok "" || _fail "an empty model reference must be rejected"
_ok "_cbox_ollama_model_ref_ok: accepts plain/digest references, rejects shell metacharacters and empty strings"

echo "$PULL_FN" | grep -q 'trap _restore_ollama EXIT INT TERM' \
  || _fail "pull does not install a trap to restore the server on every exit path"
_ok "pull: installs a trap so SIGINT/failure still restores the serving container and removes the pull network"

GUARD_FN="$(awk '/^_cbox_ollama_shared_store_guard\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
[ -n "$GUARD_FN" ] || _fail "cannot extract _cbox_ollama_shared_store_guard"
echo "$GUARD_FN" | grep -q 'CBOX_OLLAMA_STORE.*shared' || _fail "shared store guard does not special-case shared store mode"
echo "$GUARD_FN" | grep -q '_cbox_ollama_host_daemon_detected' || _fail "shared store guard does not call the host-daemon detector"
echo "$GUARD_FN" | grep -q '\-L "\$models_dir"' || _fail "shared store guard does not refuse a symlinked models directory"
echo "$GUARD_FN" | grep -q '! -d "\$models_dir"' || _fail "shared store guard does not require the models directory to already exist"
echo "$GUARD_FN" | grep -q "stat -c '%u'" || _fail "shared store guard does not check the models directory's owning uid"
_ok "shared store guard: refuses shared mode on a host ollama daemon, a missing/symlinked models dir, or a foreign-owned models dir"

for fn in _cbox_ollama_reconcile_cmd _cbox_ollama_up_cmd _cbox_ollama_pull_cmd; do
  BODY="$(awk -v fn="$fn" '$0 == fn"() {" , $0 == "}"' "$INSTALL_DIR/cbox")"
  [ -n "$BODY" ] || _fail "cannot extract $fn"
  echo "$BODY" | grep -q '_cbox_ollama_shared_store_guard' || _fail "$fn does not call the shared-store guard"
done
_ok "wiring: reconcile, up, and pull all call the shared-store guard - not just reconcile's first run"

DAEMON_FN="$(awk '/^_cbox_ollama_host_daemon_detected\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
[ -n "$DAEMON_FN" ] || _fail "cannot extract _cbox_ollama_host_daemon_detected"
echo "$DAEMON_FN" | grep -q 'curl' || _fail "host daemon detection does not probe the ollama HTTP endpoint"
echo "$DAEMON_FN" | grep -qE 'ss |pgrep|systemctl' || _fail "host daemon detection does not fall back to process/socket/unit checks"
_ok "host daemon detection: probes the HTTP endpoint plus process/socket/systemd fallbacks (cannot be exercised live in this container - no docker socket, no host systemd/process view)"

DOWN_FN="$(awk '/^down\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
DOWNP_FN="$(awk '/^down_project\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
GC_FN="$(awk '/^gc\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
REAP_FN="$(awk '/^_reap\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"

echo "$DOWN_FN" | grep -q '"\${COMPOSE\[@\]}" down' || _fail "global down() must use the file-scoped COMPOSE array, not a label-based enumeration"
! echo "$DOWN_FN" | grep -q 'cbox.kind' || _fail "global down() must not filter by cbox.kind at all (it is scoped by compose file, not label)"
_ok "regression: global down() is scoped to \$INSTALL_DIR/docker-compose.yml only - cannot reach the owner project's separate compose file/project name"

echo "$DOWNP_FN" | grep -q '_compose_p "\$eff"' || _fail "down_project() must use the per-project compose file, not a label-based enumeration"
! echo "$DOWNP_FN" | grep -q 'cbox.kind' || _fail "down_project() must not filter by cbox.kind (file-scoped, not label-scoped)"
_ok "regression: down_project() is scoped to the isolated project's own \$eff/docker-compose.yml - cannot reach the owner project"

echo "$DOWN_FN" | grep -q '_cbox_ollama_gc_scope_networks' \
  || _fail "global down() does not sweep orphaned per-scope ollama networks after tearing down the container"
_ok "cleanliness: global down() sweeps per-scope ollama networks after compose down (not just gc()/ollama down)"

echo "$DOWNP_FN" | grep -q '_cbox_ollama_gc_scope_networks' \
  || _fail "down_project() does not sweep orphaned per-scope ollama networks after tearing down the isolated project"
_ok "cleanliness: down_project() sweeps per-scope ollama networks after compose down (not just gc()/ollama down)"

echo "$REAP_FN" | grep -q '_compose_p "\$eff"' || _fail "_reap() must use the per-project compose file"
_ok "regression: _reap() (used by cbox shell/shell_isolated) is scoped to the per-project compose file, cannot reach the owner project"

echo "$GC_FN" | grep -q 'label=cbox.kind=isolated' || _fail "gc() must filter strictly by label=cbox.kind=isolated"
! echo "$GC_FN" | grep -qE 'docker ps[^|]*(-a)?[^|]*(--filter[^|]*)*$' || true
echo "$GC_FN" | grep -c 'cbox.kind=isolated' | grep -qE '^[2-9]$' \
  || _fail "gc() must apply the isolated-only filter to both its live-probe enumeration and its exited-container cleanup pass"
_ok "regression: gc() enumerates strictly label=cbox.kind=isolated in both its live and exited-container passes - an owner labeled cbox.kind=infra is never enumerated, never probed, never stopped, never removed"

run_gc_sim() {
  DOCKER_CALLS="$TMPBASE/docker.calls" bash -c '
    set -u
    : > "$DOCKER_CALLS"
    docker() {
      printf "%s\n" "$*" >> "$DOCKER_CALLS"
      case "$1" in
        ps)
          if printf "%s\n" "$@" | grep -q "cbox.kind=isolated"; then
            printf "\n"
          fi
          ;;
        *) : ;;
      esac
    }
    _gc_legacy_bins_volumes() { :; }
    '"$GC_FN"'
    gc
  ' gcsim 2>&1
}

out="$(run_gc_sim)"
grep -q 'label=cbox.kind=isolated' "$TMPBASE/docker.calls" || _fail "gc() simulation never issued the isolated-label filter: $(cat "$TMPBASE/docker.calls")"
! grep -qi 'cbox.kind=infra' "$TMPBASE/docker.calls" || _fail "gc() simulation touched cbox.kind=infra: $(cat "$TMPBASE/docker.calls")"
! grep -q '^stop \|^rm ' "$TMPBASE/docker.calls" || _fail "gc() simulation with an empty isolated set must not stop or remove anything: $(cat "$TMPBASE/docker.calls")"
_ok "regression (behavioral): a stubbed gc() run with no isolated containers never issues docker stop/rm and every docker ps call carries the isolated-only label filter - an owner container is structurally unreachable, not just absent by coincidence"

LOCKOPEN_FN="$(awk '/^_cbox_ollama_lock_fd_open\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
[ -n "$LOCKOPEN_FN" ] || _fail "cannot extract _cbox_ollama_lock_fd_open"

LOCKDIR="$TMPBASE/lockdir"
mkdir -p "$LOCKDIR"
REALLOCK="$LOCKDIR/real.lock"
: > "$REALLOCK"
bash -c '
  set -u
  '"$LOCKOPEN_FN"'
  _cbox_ollama_lock_fd_open 7 "'"$REALLOCK"'"
' lockopentest
[ $? -eq 0 ] || _fail "_cbox_ollama_lock_fd_open must succeed opening a plain regular file"
_ok "_cbox_ollama_lock_fd_open: opens a plain lock file without complaint"

SYMLOCK="$LOCKDIR/sym.lock"
ln -s "$REALLOCK" "$SYMLOCK"
out="$(bash -c '
  set -u
  '"$LOCKOPEN_FN"'
  _cbox_ollama_lock_fd_open 7 "'"$SYMLOCK"'"
' lockopensymtest 2>&1; echo "RC=$?")"
echo "$out" | grep -q 'RC=1' || _fail "_cbox_ollama_lock_fd_open must refuse a symlinked lock path: $out"
echo "$out" | grep -qi symlink || _fail "the refusal must mention the symlink: $out"
_ok "_cbox_ollama_lock_fd_open: refuses a symlinked lock file path instead of truncating through it"

grep -q 'exec \$fd>> ' <(echo "$LOCKOPEN_FN") || _fail "_cbox_ollama_lock_fd_open must open for append (>>), not truncate (>)"
_ok "_cbox_ollama_lock_fd_open: opens for append, never truncates the lock file"

for site in _cbox_ollama_reconcile_networks _cbox_ollama_gc_scope_networks; do
  BODY="$(awk -v fn="$site" '$0 == fn"() {" , $0 == "}"' "$INSTALL_DIR/cbox")"
  echo "$BODY" | grep -q '_cbox_ollama_lock_fd_open' || _fail "$site does not use the safe lock-open helper"
done
OLLAMA_CMD_BODY="$(awk '/^ollama_cmd\(\) \{/,/^}$/' "$INSTALL_DIR/cbox")"
echo "$OLLAMA_CMD_BODY" | grep -q '_cbox_ollama_lock_fd_open' || _fail "ollama_cmd does not use the safe lock-open helper"
_ok "wiring: every ollama lockfile open site uses the symlink-safe append-mode helper"

echo "PASS: all ollama owner checks"
