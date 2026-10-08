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

while IFS='=' read -r _cbox_env_name _; do
  case "$_cbox_env_name" in
    CBOX_*|OLLAMA_*|HERMES_*|HOST_HOME) unset "$_cbox_env_name" ;;
  esac
done < <(env)

BASE_REV="1ee9547"

bash -n "$INSTALL_DIR/templates/generators.sh" || _fail "generators.sh fails bash -n"
bash -n "$INSTALL_DIR/templates/validator_lib.sh" || _fail "validator_lib.sh fails bash -n"
_ok "bash -n clean on templates/generators.sh and templates/validator_lib.sh"

H="$TMPBASE/home"
mkdir -p "$H"

render_hq() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  ( set -e
    source "$INSTALL_DIR/templates/validator_lib.sh"
    source "$INSTALL_DIR/templates/validator_dispatch.sh"
    _cbox_config_validate_var() { _cbox_reg_validate_var "$@"; }
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$H"
    export CBOX_HYPERQWEN_MODE=on
    export "$@"
    gen_hyperqwen_owner_compose_into "$dir"
  )
}

with_gen() {
  ( set -e
    source "$INSTALL_DIR/templates/validator_lib.sh"
    source "$INSTALL_DIR/templates/validator_dispatch.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$H"
    "$@"
  )
}

gen_eval() {
  local code="$1"
  shift
  with_gen env "$@" bash -c "source \"$INSTALL_DIR/templates/generators.sh\"; $code"
}

UID_NOW="$(id -u)"

D1="$TMPBASE/default"
render_hq "$D1"
C1="$D1/docker-compose.yml"
G1="$D1/docker-compose.gpu.yml"
[ -f "$C1" ] || _fail "default render: docker-compose.yml missing"
[ -f "$G1" ] || _fail "default render: docker-compose.gpu.yml must always be rendered while hyperqwen is on"
grep -qxF "name: \"cbox-infra-u$UID_NOW-hyperqwen\"" "$C1" || _fail "owner project name wrong"
grep -qxF '    image: "ghcr.io/syv-ai/hyperqwen:sha-53557bc"' "$C1" || _fail "default image pin missing"
grep -qxF '    command: ["single"]' "$C1" || _fail "command single missing"
grep -qxF '    restart: "unless-stopped"' "$C1" || _fail "restart policy missing"
grep -qxF '      cbox.kind: infra' "$C1" || _fail "cbox.kind label missing"
grep -qxF '      cbox.component: hyperqwen' "$C1" || _fail "cbox.component label missing"
grep -qxF "      cbox.owner: cbox-infra-u$UID_NOW-hyperqwen" "$C1" || _fail "cbox.owner label missing"
for line in HOME=/cache PORT=18020 SPEC=mtp CTX=long MAX_LEN=150000 PREFIX_CACHE=1 PREPARE=0 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1; do
  grep -qxF "      - \"$line\"" "$C1" || _fail "environment line $line missing"
done
grep -qxF '    shm_size: "8g"' "$C1" || _fail "shm_size default missing"
grep -qxF "      - cbox-hyperqwen-u$UID_NOW-models:/app/models" "$C1" || _fail "models named volume mount missing"
grep -qxF "      - cbox-hyperqwen-u$UID_NOW-cache:/cache" "$C1" || _fail "cache named volume mount missing"
grep -qxF '      test: ["CMD", "curl", "-sf", "http://127.0.0.1:18020/health"]' "$C1" || _fail "healthcheck missing"
grep -qxF '      interval: 30s' "$C1" || _fail "healthcheck interval missing"
grep -qxF '      timeout: 5s' "$C1" || _fail "healthcheck timeout missing"
grep -qxF '      retries: 3' "$C1" || _fail "healthcheck retries missing"
grep -qxF '      start_period: 900s' "$C1" || _fail "healthcheck start_period missing"
grep -qxF '    internal: true' "$C1" || _fail "default network must be internal"
grep -qxF '      cbox.component: hyperqwen-net' "$C1" || _fail "network label cbox.component=hyperqwen-net missing"
grep -qxF "  cbox-hyperqwen-u$UID_NOW-models:" "$C1" || _fail "top-level models volume missing"
grep -qxF "    name: cbox-hyperqwen-u$UID_NOW-models" "$C1" || _fail "models volume lacks explicit name"
grep -qxF "    name: cbox-hyperqwen-u$UID_NOW-cache" "$C1" || _fail "cache volume lacks explicit name"
if grep -Eq '^\s+ports:|API_KEY' "$C1"; then _fail "rendered compose must publish no port and carry no api key"; fi
grep -qxF '                - nvidia.com/gpu=all' "$G1" || _fail "gpu overlay default must reserve nvidia.com/gpu=all"
grep -qxF '            - driver: cdi' "$G1" || _fail "gpu overlay must use the cdi driver"
grep -qxF '  hyperqwen:' "$G1" || _fail "gpu overlay must target the hyperqwen service"
[ "$(ls -A "$D1" | wc -l | tr -d ' ')" = 2 ] || _fail "render left stray files: $(ls -A "$D1")"
_ok "defaults: owner compose and gpu overlay render every contract field with named volumes and no port or key"

python3 - "$C1" "$G1" <<'PY' || _fail "rendered compose is not valid YAML or lacks the expected structure"
import os
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
c = yaml.safe_load(open(sys.argv[1]))
g = yaml.safe_load(open(sys.argv[2]))
svc = c["services"]["hyperqwen"]
assert svc["command"] == ["single"]
assert svc["shm_size"] == "8g"
assert c["networks"]["default"]["internal"] is True
uid = os.getuid()
assert set(c["volumes"]) == {"cbox-hyperqwen-u%d-models" % uid, "cbox-hyperqwen-u%d-cache" % uid}
dev = g["services"]["hyperqwen"]["deploy"]["resources"]["reservations"]["devices"][0]
assert dev["driver"] == "cdi" and dev["device_ids"] == ["nvidia.com/gpu=all"] and dev["capabilities"] == ["gpu"]
PY
_ok "defaults: rendered YAML parses with the expected structure (when a YAML parser is present)"

MP="$TMPBASE/models-dir"
mkdir -p "$MP"
D2="$TMPBASE/bind"
render_hq "$D2" "CBOX_HYPERQWEN_MODELS_PATH=$MP"
grep -qxF "      - '$MP:/app/models'" "$D2/docker-compose.yml" || _fail "bind mount line missing"
if grep -q "cbox-hyperqwen-u$UID_NOW-models" "$D2/docker-compose.yml"; then _fail "bind mode must not mention the models named volume"; fi
grep -qxF "    name: cbox-hyperqwen-u$UID_NOW-cache" "$D2/docker-compose.yml" || _fail "bind mode lost the cache volume"
_ok "MODELS_PATH: bind mount replaces the models named volume, cache volume kept"

D2B="$TMPBASE/bind-missing"
if render_hq "$D2B" "CBOX_HYPERQWEN_MODELS_PATH=$TMPBASE/does-not-exist" 2>"$TMPBASE/e.err"; then _fail "a missing MODELS_PATH directory must refuse the render"; fi
grep -q "refusing to render the hyperqwen owner compose" "$TMPBASE/e.err" || _fail "missing-dir refusal not named"
[ ! -f "$D2B/docker-compose.yml" ] || _fail "missing-dir refusal still rendered"
ln -s "$MP" "$TMPBASE/models-link"
D2C="$TMPBASE/bind-symlink"
if render_hq "$D2C" "CBOX_HYPERQWEN_MODELS_PATH=$TMPBASE/models-link" 2>/dev/null; then _fail "a symlink MODELS_PATH must refuse the render"; fi
[ ! -f "$D2C/docker-compose.yml" ] || _fail "symlink refusal still rendered"
_ok "MODELS_PATH: a missing directory and a symlink both refuse the render"

D3="$TMPBASE/gpu0"
render_hq "$D3" CBOX_HYPERQWEN_GPU_DEVICE=0
grep -qxF '                - nvidia.com/gpu=0' "$D3/docker-compose.gpu.yml" || _fail "GPU_DEVICE=0 must reserve nvidia.com/gpu=0"
if grep -q 'gpu=all' "$D3/docker-compose.gpu.yml"; then _fail "GPU_DEVICE=0 must not reserve all"; fi
D4="$TMPBASE/gpu01"
render_hq "$D4" CBOX_HYPERQWEN_GPU_DEVICE=0,1
[ "$(grep -c 'nvidia.com/gpu=' "$D4/docker-compose.gpu.yml")" = 2 ] || _fail "GPU_DEVICE=0,1 must reserve two devices"
grep -qxF '                - nvidia.com/gpu=0' "$D4/docker-compose.gpu.yml" || _fail "GPU_DEVICE=0,1 lost device 0"
grep -qxF '                - nvidia.com/gpu=1' "$D4/docker-compose.gpu.yml" || _fail "GPU_DEVICE=0,1 lost device 1"
D4B="$TMPBASE/gpuuuid"
render_hq "$D4B" CBOX_HYPERQWEN_GPU_DEVICE=GPU-0a1b2c3d-4e5f-6789-abcd-ef0123456789
grep -qxF '                - nvidia.com/gpu=GPU-0a1b2c3d-4e5f-6789-abcd-ef0123456789' "$D4B/docker-compose.gpu.yml" || _fail "uuid device id not rendered"
_ok "GPU_DEVICE: a single index, an index list and a uuid render as CDI reservations"

check_max_len() {
  local spec="$1" ctx="$2" want="$3" got
  got="$(gen_eval '_cbox_hyperqwen_max_len' CBOX_HYPERQWEN_SPEC="$spec" CBOX_HYPERQWEN_CTX="$ctx")"
  [ "$got" = "$want" ] || _fail "max_len $spec/$ctx: want $want got $got"
}
check_max_len dflash2 fast 65536
check_max_len dflash2 long 131072
check_max_len dflash2 huge 245760
check_max_len mtp fast 65536
check_max_len mtp long 150000
check_max_len mtp huge 200000
_ok "max_len table: every SPEC/CTX cell resolves to the contract value"

D5="$TMPBASE/mtp-huge"
render_hq "$D5" CBOX_HYPERQWEN_SPEC=mtp CBOX_HYPERQWEN_CTX=huge
grep -qxF '      - "PREFIX_CACHE=0"' "$D5/docker-compose.yml" || _fail "mtp+huge must render PREFIX_CACHE=0"
grep -qxF '      - "MAX_LEN=200000"' "$D5/docker-compose.yml" || _fail "mtp+huge MAX_LEN wrong"
grep -qxF '      - "SPEC=mtp"' "$D5/docker-compose.yml" || _fail "SPEC=mtp not rendered"
grep -qxF '      - "CTX=huge"' "$D5/docker-compose.yml" || _fail "CTX=huge not rendered"
D5B="$TMPBASE/mtp-long"
render_hq "$D5B" CBOX_HYPERQWEN_SPEC=mtp CBOX_HYPERQWEN_CTX=long
grep -qxF '      - "PREFIX_CACHE=1"' "$D5B/docker-compose.yml" || _fail "mtp+long must keep PREFIX_CACHE=1"
D5C="$TMPBASE/dflash-huge"
render_hq "$D5C" CBOX_HYPERQWEN_SPEC=dflash2 CBOX_HYPERQWEN_CTX=huge
grep -qxF '      - "PREFIX_CACHE=1"' "$D5C/docker-compose.yml" || _fail "dflash2+huge must keep PREFIX_CACHE=1"
_ok "prefix cache: off only for mtp+huge"

D6="$TMPBASE/maxlen"
render_hq "$D6" CBOX_HYPERQWEN_MAX_LEN=100000 CBOX_HYPERQWEN_SPEC=mtp CBOX_HYPERQWEN_CTX=huge CBOX_HYPERQWEN_SHM_SIZE=16g
grep -qxF '      - "MAX_LEN=100000"' "$D6/docker-compose.yml" || _fail "explicit MAX_LEN must win over the profile table"
grep -qxF '    shm_size: "16g"' "$D6/docker-compose.yml" || _fail "explicit SHM_SIZE not rendered"
_ok "explicit MAX_LEN and SHM_SIZE win over defaults"

refuse() {
  local label="$1"
  shift
  local d="$TMPBASE/refuse-$label"
  if render_hq "$d" "$@" 2>"$TMPBASE/refuse.err"; then _fail "invalid $label must refuse the render"; fi
  grep -q "refusing to render the hyperqwen owner compose" "$TMPBASE/refuse.err" || _fail "invalid $label: refusal not named: $(cat "$TMPBASE/refuse.err")"
  [ ! -f "$d/docker-compose.yml" ] || _fail "invalid $label still rendered a compose file"
  [ ! -f "$d/docker-compose.gpu.yml" ] || _fail "invalid $label still rendered a gpu overlay"
}
refuse spec CBOX_HYPERQWEN_SPEC=bogus
refuse ctx CBOX_HYPERQWEN_CTX=medium
refuse shm CBOX_HYPERQWEN_SHM_SIZE=0
refuse shm-suffix CBOX_HYPERQWEN_SHM_SIZE=8gb
refuse maxlen-zero-lead CBOX_HYPERQWEN_MAX_LEN=01
refuse maxlen-big CBOX_HYPERQWEN_MAX_LEN=1048577
refuse gpu 'CBOX_HYPERQWEN_GPU_DEVICE=0;touch x'
refuse gpu-range CBOX_HYPERQWEN_GPU_DEVICE=100
refuse image 'CBOX_HYPERQWEN_IMAGE=bad image'
refuse models-relative CBOX_HYPERQWEN_MODELS_PATH=relative/path
refuse injection "CBOX_HYPERQWEN_SPEC=dflash2
    privileged: true"
_ok "invalid CBOX_HYPERQWEN_* values refuse the render and write nothing"

D7="$TMPBASE/off"
mkdir -p "$D7"
touch "$D7/docker-compose.yml" "$D7/docker-compose.gpu.yml" "$D7/keep"
render_hq "$D7" CBOX_HYPERQWEN_MODE=off
[ ! -f "$D7/docker-compose.yml" ] || _fail "mode off must remove docker-compose.yml"
[ ! -f "$D7/docker-compose.gpu.yml" ] || _fail "mode off must remove docker-compose.gpu.yml"
[ -f "$D7/keep" ] || _fail "mode off must only remove the two compose files"
_ok "mode off removes both compose files and nothing else"

MD="$TMPBASE/manifest"
mkdir -p "$MD"
gen_eval "_cbox_hyperqwen_manifest_write \"$MD\"" CBOX_HYPERQWEN_MODE=on
grep -qx 'schema=1' "$MD/ownership.manifest" || _fail "manifest schema=1 missing"
for key in owner uid image gpu_device models_path spec ctx max_len prefix_cache shm_size; do
  grep -q "^$key=" "$MD/ownership.manifest" || _fail "manifest field $key missing"
done
grep -qx "owner=cbox-infra-u$UID_NOW-hyperqwen" "$MD/ownership.manifest" || _fail "manifest owner wrong"
grep -qx 'max_len=150000' "$MD/ownership.manifest" || _fail "manifest max_len must be the resolved value"
match() {
  gen_eval "_cbox_hyperqwen_manifest_matches_current \"$MD\"" "$@"
}
match CBOX_HYPERQWEN_MODE=on || _fail "manifest must match the config it was written from"
for change in CBOX_HYPERQWEN_IMAGE=ghcr.io/syv-ai/hyperqwen:sha-0000000 CBOX_HYPERQWEN_GPU_DEVICE=1 CBOX_HYPERQWEN_MODELS_PATH=/srv/m CBOX_HYPERQWEN_SPEC=dflash2 CBOX_HYPERQWEN_CTX=fast CBOX_HYPERQWEN_MAX_LEN=70000 CBOX_HYPERQWEN_SHM_SIZE=16g; do
  if match "$change"; then _fail "manifest must stop matching after $change"; fi
done
rm "$MD/ownership.manifest"
if match CBOX_HYPERQWEN_MODE=on; then _fail "a missing manifest must not match"; fi
MD2="$TMPBASE/manifest-mtp"
mkdir -p "$MD2"
gen_eval "_cbox_hyperqwen_manifest_write \"$MD2\"" CBOX_HYPERQWEN_SPEC=mtp CBOX_HYPERQWEN_CTX=huge
grep -qx 'prefix_cache=0' "$MD2/ownership.manifest" || _fail "manifest must record prefix_cache=0 for mtp+huge"
_ok "manifest: round trip matches, every rendered field breaks the match when changed"

chk_overlap() {
  local want="$1" a="$2" b="$3" rc=0
  gen_eval "_cbox_gpu_devices_overlap \"$a\" \"$b\"" || rc=$?
  if [ "$want" = yes ] && [ "$rc" != 0 ]; then _fail "overlap '$a' '$b' should intersect"; fi
  if [ "$want" = no ] && [ "$rc" = 0 ]; then _fail "overlap '$a' '$b' should not intersect"; fi
}
chk_overlap yes all all
chk_overlap yes all 0
chk_overlap yes 0 all
chk_overlap yes 0 0
chk_overlap yes 0,1 1
chk_overlap yes 2,3 3,4
chk_overlap no 0 1
chk_overlap no 0,1 2,3
chk_overlap yes GPU-12345678 GPU-12345678
chk_overlap no GPU-12345678 GPU-87654321
chk_overlap yes "" 0
_ok "overlap: all intersects everything, disjoint lists do not, shared entries do"

ids="$(gen_eval '_cbox_gpu_device_ids all; _cbox_gpu_device_ids 0,1; _cbox_gpu_device_ids GPU-12345678')"
[ "$ids" = "$(printf 'nvidia.com/gpu=all\nnvidia.com/gpu=0\nnvidia.com/gpu=1\nnvidia.com/gpu=GPU-12345678')" ] || _fail "_cbox_gpu_device_ids output wrong: $ids"
if gen_eval '_cbox_gpu_device_ids "0,x y"' >/dev/null 2>&1; then _fail "_cbox_gpu_device_ids must refuse an unsafe entry"; fi
_ok "gpu device ids: one CDI id per line, unsafe entries refused"

TABLE="$(gen_eval '
_cbox_local_backends | tr "\n" " "; echo
for b in ollama hyperqwen; do
  printf "%s|%s|%s|%s|%s\n" "$(_cbox_local_backend_alias $b)" "$(_cbox_local_backend_port $b)" "$(_cbox_local_backend_url $b)" "$(_cbox_local_backend_context_length $b)" "$(_cbox_local_backend_served_model $b)"
done
')"
[ "$(printf '%s\n' "$TABLE" | sed -n 1p)" = "ollama hyperqwen " ] || _fail "backend list wrong: $TABLE"
[ "$(printf '%s\n' "$TABLE" | sed -n 2p)" = "ollama|11434|http://ollama:11434|65536|" ] || _fail "ollama backend row wrong: $TABLE"
[ "$(printf '%s\n' "$TABLE" | sed -n 3p)" = "hyperqwen|18020|http://hyperqwen:18020|150000|qwen3.8-27b" ] || _fail "hyperqwen backend row wrong: $TABLE"
CTXROW="$(gen_eval '_cbox_local_backend_context_length ollama; echo; _cbox_local_backend_context_length hyperqwen' CBOX_OLLAMA_CONTEXT_LENGTH=32768 CBOX_HYPERQWEN_SPEC=mtp CBOX_HYPERQWEN_CTX=long)"
[ "$CTXROW" = "$(printf '32768\n150000')" ] || _fail "backend contexts wrong: $CTXROW"
if gen_eval '_cbox_local_backend_alias nope' >/dev/null 2>&1; then _fail "unknown backend must fail"; fi
ACTIVE_CODE='for b in $(_cbox_local_backends); do _cbox_local_backend_active $b && printf "%s " $b; done; true'
act="$(gen_eval "$ACTIVE_CODE" CBOX_OLLAMA_MODE=on CBOX_HYPERQWEN_MODE=off)"
[ "$act" = "ollama " ] || _fail "active backends wrong: $act"
act="$(gen_eval "$ACTIVE_CODE" CBOX_OLLAMA_MODE=off CBOX_HYPERQWEN_MODE=on)"
[ "$act" = "hyperqwen " ] || _fail "active backends wrong: $act"
act="$(gen_eval "$ACTIVE_CODE" CBOX_OLLAMA_MODE=on CBOX_HYPERQWEN_MODE=on)"
[ "$act" = "ollama hyperqwen " ] || _fail "both backends must be active together: $act"
_ok "backend table: alias, port, url, context, served model and activity per backend"

of_url() {
  gen_eval "_cbox_local_backend_of_url \"$1\""
}
[ "$(of_url http://ollama:11434)" = ollama ] || _fail "of_url ollama"
[ "$(of_url http://hyperqwen:18020)" = hyperqwen ] || _fail "of_url hyperqwen"
[ "$(of_url http://hyperqwen:18020/v1)" = hyperqwen ] || _fail "of_url hyperqwen with /v1"
[ "$(of_url hyperqwen:18020)" = hyperqwen ] || _fail "of_url without scheme"
if of_url http://example.com:11434 >/dev/null 2>&1; then _fail "of_url must fail for an unknown host"; fi
if of_url "" >/dev/null 2>&1; then _fail "of_url must fail for an empty url"; fi
if of_url http://myhyperqwen:18020 >/dev/null 2>&1; then _fail "of_url must match the alias exactly"; fi
ctx_for() {
  local url="$1"
  shift
  gen_eval "_cbox_local_context_length_for_url \"$url\"" "$@"
}
[ "$(ctx_for http://hyperqwen:18020 CBOX_HYPERQWEN_SPEC=dflash2 CBOX_HYPERQWEN_CTX=huge CBOX_OLLAMA_CONTEXT_LENGTH=32768)" = 245760 ] || _fail "context for hyperqwen url"
[ "$(ctx_for http://ollama:11434 CBOX_OLLAMA_CONTEXT_LENGTH=32768)" = 32768 ] || _fail "context for ollama url"
[ "$(ctx_for http://example.com:8000 CBOX_OLLAMA_CONTEXT_LENGTH=32768)" = 32768 ] || _fail "context for unknown url keeps the ollama value"
[ "$(ctx_for http://example.com:8000)" = 65536 ] || _fail "context default for unknown url"
[ "$(ctx_for "")" = 65536 ] || _fail "context default for empty url"
_ok "backend_of_url matches the alias host exactly, context_length_for_url follows the backend"

nph() {
  gen_eval '_cbox_no_proxy_hosts' "$@"
}
case ",$(nph CBOX_HYPERQWEN_MODE=on)," in *,hyperqwen,*) ;; *) _fail "no_proxy hosts must include hyperqwen when it is on: $(nph CBOX_HYPERQWEN_MODE=on)" ;; esac
case ",$(nph CBOX_HYPERQWEN_MODE=off)," in *,hyperqwen,*) _fail "no_proxy hosts must not include hyperqwen when it is off" ;; esac
case ",$(nph CBOX_OLLAMA_MODE=on CBOX_HYPERQWEN_MODE=on)," in *,ollama,*) ;; *) _fail "no_proxy hosts must keep ollama next to hyperqwen" ;; esac
case ",$(nph CBOX_OLLAMA_MODE=on CBOX_HYPERQWEN_MODE=on)," in *,hyperqwen,*) ;; *) _fail "no_proxy hosts must list both backends" ;; esac
[ -z "$(nph CBOX_OLLAMA_MODE=off CBOX_HYPERQWEN_MODE=off)" ] || _fail "no_proxy hosts must be empty with both backends off"
_ok "no_proxy hosts: hyperqwen follows its own mode next to ollama"

managed() {
  local out="$1"
  shift
  gen_eval "source \"$INSTALL_DIR/_common.sh\"; gen_hermes_managed_into \"$out\"" CBOX_HERMES_PROVIDER=local CBOX_HERMES_MODEL_NAME=qwen "$@"
}
managed "$TMPBASE/m1.env" CBOX_HERMES_MODEL_URL=http://ollama:11434 CBOX_OLLAMA_CONTEXT_LENGTH=32768 CBOX_HYPERQWEN_CTX=long
grep -qx 'HERMES_MANAGED_CONTEXT_LENGTH=32768' "$TMPBASE/m1.env" || _fail "hermes managed context for an ollama url must be the ollama value: $(cat "$TMPBASE/m1.env")"
managed "$TMPBASE/m2.env" CBOX_HERMES_MODEL_URL=http://hyperqwen:18020 CBOX_OLLAMA_CONTEXT_LENGTH=32768 CBOX_HYPERQWEN_CTX=long CBOX_HYPERQWEN_SPEC=dflash2
grep -qx 'HERMES_MANAGED_CONTEXT_LENGTH=131072' "$TMPBASE/m2.env" || _fail "hermes managed context for a hyperqwen url must be the hyperqwen window: $(cat "$TMPBASE/m2.env")"
grep -qx 'HERMES_MANAGED_BASE_URL=http://hyperqwen:18020/v1' "$TMPBASE/m2.env" || _fail "hermes managed base url wrong"
managed "$TMPBASE/m3.env" CBOX_LOCAL_MODEL_URL=http://hyperqwen:18020 CBOX_HYPERQWEN_MAX_LEN=90000
grep -qx 'HERMES_MANAGED_CONTEXT_LENGTH=90000' "$TMPBASE/m3.env" || _fail "hermes managed context must follow the machine local url and an explicit MAX_LEN"
managed "$TMPBASE/m4.env" CBOX_HERMES_MODEL_URL=http://example.com:8000
grep -qx 'HERMES_MANAGED_CONTEXT_LENGTH=65536' "$TMPBASE/m4.env" || _fail "hermes managed context default for a foreign url must be 65536"
if managed "$TMPBASE/m5.env" CBOX_HERMES_MODEL_URL=http://ollama:11434 CBOX_OLLAMA_CONTEXT_LENGTH=0 >/dev/null 2>&1; then _fail "an invalid ollama context must still stop the managed render"; fi
_ok "hermes managed env: context window follows the backend of the model url"

dctx() {
  gen_eval '_cbox_hermes_delegate_context_length' "$@"
}
[ "$(dctx CBOX_HERMES_DELEGATE_BASE_URL=http://hyperqwen:18020 CBOX_HERMES_MODEL_URL=http://ollama:11434 CBOX_HYPERQWEN_CTX=long CBOX_HYPERQWEN_SPEC=dflash2)" = 131072 ] || _fail "delegate context must follow the delegate url first"
[ "$(dctx CBOX_HERMES_MODEL_URL=http://hyperqwen:18020 CBOX_LOCAL_MODEL_URL=http://ollama:11434 CBOX_HYPERQWEN_CTX=huge CBOX_HYPERQWEN_SPEC=dflash2)" = 245760 ] || _fail "delegate context must fall back to the console url"
[ "$(dctx CBOX_LOCAL_MODEL_URL=http://hyperqwen:18020 CBOX_HYPERQWEN_SPEC=mtp)" = 150000 ] || _fail "delegate context must fall back to the machine local url"
[ "$(dctx CBOX_OLLAMA_CONTEXT_LENGTH=49152)" = 49152 ] || _fail "delegate context with no url must keep the ollama value"
_ok "delegate context length: delegate url, then console url, then machine url, then ollama value"

mkdir -p "$TMPBASE/run" "$TMPBASE/proj" "$TMPBASE/delhome"
delegate_render() {
  local eff="$1" hermes="$2"
  shift 2
  mkdir -p "$eff"
  ( set -e
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$TMPBASE/delhome" XDG_RUNTIME_DIR="$TMPBASE/run"
    export CBOX_CLAUDE_MODE=volume CBOX_CODEX_MODE=volume CBOX_SESSION_SCOPE=isolated
    export CBOX_USER_DIR="$TMPBASE/nouser"
    export CBOX_HERMES="$hermes" CBOX_HERMES_PROVIDER=local CBOX_HERMES_MODEL_NAME=qwen CBOX_HERMES_VERSION=latest
    export "$@"
    gen_compose_isolated "$eff" "$TMPBASE/proj" "cbox-img:test" "abcdef123456"
  ) >/dev/null 2>"$TMPBASE/del.err" || _fail "isolated render failed: $(cat "$TMPBASE/del.err")"
}
delegate_render "$TMPBASE/del1" on CBOX_HERMES_MODEL_URL=http://ollama:11434 CBOX_HERMES_DELEGATE=on
grep -qxF '      - CBOX_HERMES_DELEGATE_CONTEXT_LENGTH=65536' "$TMPBASE/del1/docker-compose.yml" || _fail "isolated render lacks the delegate context env line for an ollama url"
delegate_render "$TMPBASE/del2" on CBOX_HERMES_MODEL_URL=http://ollama:11434 CBOX_HERMES_DELEGATE=on CBOX_HERMES_DELEGATE_BASE_URL=http://hyperqwen:18020 CBOX_HYPERQWEN_CTX=long CBOX_HYPERQWEN_SPEC=dflash2
grep -qxF '      - CBOX_HERMES_DELEGATE_CONTEXT_LENGTH=131072' "$TMPBASE/del2/docker-compose.yml" || _fail "isolated render must compute the delegate context from the delegate url"
delegate_render "$TMPBASE/del3" off CBOX_HERMES_DELEGATE=on
if grep -q 'CBOX_HERMES_DELEGATE_CONTEXT_LENGTH' "$TMPBASE/del3/docker-compose.yml"; then _fail "no delegate env line may render while hermes is off"; fi
_ok "isolated compose: CBOX_HERMES_DELEGATE_CONTEXT_LENGTH rendered next to the delegate env line only with hermes on"

HAVE_BASE=0
BASEGEN="$TMPBASE/generators_base.sh"
if git -C "$INSTALL_DIR" cat-file -e "$BASE_REV:cbox/templates/generators.sh" 2>/dev/null \
  && git -C "$INSTALL_DIR" show "$BASE_REV:cbox/templates/generators.sh" > "$BASEGEN" 2>/dev/null; then
  HAVE_BASE=1
fi

render_ollama() {
  local gen="$1" dir="$2"
  shift 2
  mkdir -p "$dir"
  ( set -e
    source "$gen"
    export HOME="$H"
    export CBOX_OLLAMA_MODE=on CBOX_OLLAMA_IMAGE=ollama/ollama:0.33.3 CBOX_OLLAMA_STORE=dedicated CBOX_OLLAMA_STORE_PATH= CBOX_OLLAMA_PORT=11434 CBOX_OLLAMA_NUM_PARALLEL=1
    export "$@"
    gen_ollama_owner_compose_into "$dir"
  )
}

if [ "$HAVE_BASE" = 1 ]; then
  VARIANTS=(
    "CBOX_OLLAMA_GPU=off"
    "CBOX_OLLAMA_GPU=cdi"
    "CBOX_OLLAMA_GPU=cdi CBOX_OLLAMA_STORE=shared CBOX_OLLAMA_STORE_PATH=$MP"
  )
  for variant in "${VARIANTS[@]}"; do
    read -r -a vargs <<< "$variant"
    render_ollama "$BASEGEN" "$TMPBASE/ob" "${vargs[@]}"
    render_ollama "$INSTALL_DIR/templates/generators.sh" "$TMPBASE/on" "${vargs[@]}"
    cmp -s "$TMPBASE/ob/docker-compose.yml" "$TMPBASE/on/docker-compose.yml" || _fail "ollama compose changed for [$variant]: $(diff "$TMPBASE/ob/docker-compose.yml" "$TMPBASE/on/docker-compose.yml")"
    if [ -f "$TMPBASE/ob/docker-compose.gpu.yml" ] || [ -f "$TMPBASE/on/docker-compose.gpu.yml" ]; then
      cmp -s "$TMPBASE/ob/docker-compose.gpu.yml" "$TMPBASE/on/docker-compose.gpu.yml" || _fail "ollama gpu overlay changed for [$variant]"
    fi
    rm -rf "$TMPBASE/ob" "$TMPBASE/on"
  done
  _ok "ollama owner compose and gpu overlay with default CBOX_OLLAMA_GPU_DEVICE are byte-identical to baseline $BASE_REV"

  MFB="$TMPBASE/mfb"
  MFN="$TMPBASE/mfn"
  mkdir -p "$MFB" "$MFN"
  ( set -e; source "$INSTALL_DIR/_common.sh"; source "$BASEGEN"; export HOME="$H" CBOX_OLLAMA_MODE=on; _cbox_ollama_manifest_write "$MFB" )
  ( set -e; source "$INSTALL_DIR/_common.sh"; source "$INSTALL_DIR/templates/generators.sh"; export HOME="$H" CBOX_OLLAMA_MODE=on; _cbox_ollama_manifest_write "$MFN" )
  [ "$(grep -v '^gpu_device=' "$MFN/ownership.manifest")" = "$(cat "$MFB/ownership.manifest")" ] || _fail "ollama manifest changed beyond the gpu_device line"
  grep -qx 'gpu_device=all' "$MFN/ownership.manifest" || _fail "ollama manifest lacks gpu_device=all"
  gen_eval "source \"$INSTALL_DIR/_common.sh\"; _cbox_ollama_manifest_matches_current \"$MFB\"" CBOX_OLLAMA_MODE=on || _fail "an old ollama manifest without gpu_device must keep matching the default"
  if gen_eval "source \"$INSTALL_DIR/_common.sh\"; _cbox_ollama_manifest_matches_current \"$MFB\"" CBOX_OLLAMA_MODE=on CBOX_OLLAMA_GPU_DEVICE=1; then _fail "an old ollama manifest must stop matching a non-default gpu device"; fi
  if gen_eval "source \"$INSTALL_DIR/_common.sh\"; _cbox_ollama_manifest_matches_current \"$MFN\"" CBOX_OLLAMA_MODE=on CBOX_OLLAMA_GPU_DEVICE=1; then _fail "a new ollama manifest must stop matching a changed gpu device"; fi
  _ok "ollama manifest: gpu_device added, a missing field counts as all"

  for hosts_env in "CBOX_OLLAMA_MODE=on" "CBOX_OLLAMA_MODE=off" "CBOX_OLLAMA_MODE=on CBOX_LOCAL_MODEL_URL=http://example.com:1"; do
    read -r -a hargs <<< "$hosts_env"
    b="$(env -i HOME="$H" PATH="$PATH" "${hargs[@]}" bash -c 'source "$0"; _cbox_no_proxy_hosts' "$BASEGEN")"
    n="$(env -i HOME="$H" PATH="$PATH" "${hargs[@]}" bash -c 'source "$0/templates/generators.sh"; _cbox_no_proxy_hosts' "$INSTALL_DIR")"
    [ "$b" = "$n" ] || _fail "no_proxy hosts changed for [$hosts_env]: base=$b new=$n"
  done
  _ok "no_proxy hosts with hyperqwen off are identical to baseline $BASE_REV"
else
  echo "skip: baseline revision $BASE_REV not available, byte-identity checks skipped"
fi

render_ollama "$INSTALL_DIR/templates/generators.sh" "$TMPBASE/og0" CBOX_OLLAMA_GPU=cdi CBOX_OLLAMA_GPU_DEVICE=1
grep -qxF '                - nvidia.com/gpu=1' "$TMPBASE/og0/docker-compose.gpu.yml" || _fail "CBOX_OLLAMA_GPU_DEVICE=1 must reserve nvidia.com/gpu=1"
if grep -q 'gpu=all' "$TMPBASE/og0/docker-compose.gpu.yml"; then _fail "CBOX_OLLAMA_GPU_DEVICE=1 must not reserve all"; fi
render_ollama "$INSTALL_DIR/templates/generators.sh" "$TMPBASE/og1" CBOX_OLLAMA_GPU=cdi CBOX_OLLAMA_GPU_DEVICE=0,1
[ "$(grep -c 'nvidia.com/gpu=' "$TMPBASE/og1/docker-compose.gpu.yml")" = 2 ] || _fail "CBOX_OLLAMA_GPU_DEVICE=0,1 must reserve two devices"
if render_ollama "$INSTALL_DIR/templates/generators.sh" "$TMPBASE/og2" CBOX_OLLAMA_GPU=cdi 'CBOX_OLLAMA_GPU_DEVICE=0;x' 2>/dev/null; then _fail "an unsafe CBOX_OLLAMA_GPU_DEVICE must refuse the overlay"; fi
_ok "ollama gpu overlay follows CBOX_OLLAMA_GPU_DEVICE"

mcp_ctx() {
  ( set -e
    source "$INSTALL_DIR/templates/validator_lib.sh"
    source "$INSTALL_DIR/templates/validator_dispatch.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    export HOME="$H" CBOX_HERMES=on CBOX_HERMES_DELEGATE=on CBOX_HERMES_DELEGATE_PROVIDER=local CBOX_HERMES_PROVIDER=local
    export "$@"
    _cbox_netaccess_active() { return 1; }
    _cbox_render_mcp_for_target "$INSTALL_DIR/etc/mcp/delegates.json" hermes-local "$H/.claude/hooks" off claude
  ) | python3 -c 'import json,sys; print(json.load(sys.stdin)["hermes-local"]["env"]["CBOX_HERMES_DELEGATE_CONTEXT_LENGTH"])'
}
[ "$(mcp_ctx CBOX_HYPERQWEN_MODE=on CBOX_HERMES_DELEGATE_BASE_URL=http://hyperqwen:18020 CBOX_HYPERQWEN_CTX=long CBOX_HYPERQWEN_SPEC=mtp)" = 150000 ] || _fail "hermes-local MCP env must carry the hyperqwen window for a hyperqwen delegate URL"
[ "$(mcp_ctx CBOX_HERMES_MODEL_URL=http://ollama:11434 CBOX_OLLAMA_CONTEXT_LENGTH=32768)" = 32768 ] || _fail "hermes-local MCP env must carry the ollama window through the console URL fallback"
_ok "hermes-local MCP render carries the delegate context window of the selected backend"

[ -f "$D1/docker-compose.yml" ] || _fail "default render missing"
if grep -q 'HOST=' "$D1/docker-compose.yml"; then _fail "HOST must stay unset: upstream binds 0.0.0.0 inside a container on its own, and an explicit HOST without a key makes verify.sh refuse to serve"; fi
_ok "no HOST line: the launcher picks 0.0.0.0 from /.dockerenv and verify.sh only warns"

[ "$(grep -c '^    external: true$' "$D1/docker-compose.yml")" = 2 ] || _fail "both named volumes must be external, so compose never creates or removes them"
[ "$(grep -c '^    external: true$' "$D2/docker-compose.yml")" = 1 ] || _fail "with a models bind path only the cache volume is external"
_ok "named volumes are external: compose down -v cannot remove the model or the compile cache"

HQ_BASE_REV="031ab62"
HQ_BASEGEN="$TMPBASE/generators_hq_base.sh"
if git -C "$INSTALL_DIR" cat-file -e "$HQ_BASE_REV:cbox/templates/generators.sh" 2>/dev/null \
  && git -C "$INSTALL_DIR" show "$HQ_BASE_REV:cbox/templates/generators.sh" > "$HQ_BASEGEN" 2>/dev/null; then
  render_hq_gen() {
    local gen="$1" dir="$2"
    shift 2
    mkdir -p "$dir"
    ( set -e
      source "$INSTALL_DIR/templates/validator_lib.sh"
      source "$INSTALL_DIR/templates/validator_dispatch.sh"
      _cbox_config_validate_var() { _cbox_reg_validate_var "$@"; }
      source "$gen"
      export HOME="$H"
      export CBOX_HYPERQWEN_MODE=on
      export "$@"
      gen_hyperqwen_owner_compose_into "$dir"
    )
  }
  HQ_VARIANTS=(
    "CBOX_HYPERQWEN_SPEC=mtp"
    "CBOX_HYPERQWEN_SHM_SIZE=16g"
    "CBOX_HYPERQWEN_SPEC=dflash2 CBOX_HYPERQWEN_CTX=huge"
    "CBOX_HYPERQWEN_SPEC=mtp CBOX_HYPERQWEN_CTX=huge CBOX_HYPERQWEN_MAX_LEN=100000"
    "CBOX_HYPERQWEN_GPU_DEVICE=0,1 CBOX_HYPERQWEN_MODELS_PATH=$MP"
    "CBOX_HYPERQWEN_KV_OFFLOAD=off CBOX_HYPERQWEN_KV_OFFLOAD_MIB=24576 CBOX_HYPERQWEN_RAM_RESERVE_GIB=24"
  )
  HQ_BASE_OUT="$TMPBASE/hq-base-out"
  HQ_NEW_OUT="$TMPBASE/hq-new-out"
  for variant in "${HQ_VARIANTS[@]}"; do
    read -r -a vargs <<< "$variant"
    rm -rf -- "$HQ_BASE_OUT" "$HQ_NEW_OUT"
    render_hq_gen "$HQ_BASEGEN" "$HQ_BASE_OUT" "${vargs[@]}"
    render_hq_gen "$INSTALL_DIR/templates/generators.sh" "$HQ_NEW_OUT" "${vargs[@]}"
    cmp -s "$HQ_BASE_OUT/docker-compose.yml" "$HQ_NEW_OUT/docker-compose.yml" || _fail "hyperqwen compose with offload off changed for [$variant]: $(diff "$HQ_BASE_OUT/docker-compose.yml" "$HQ_NEW_OUT/docker-compose.yml")"
    cmp -s "$HQ_BASE_OUT/docker-compose.gpu.yml" "$HQ_NEW_OUT/docker-compose.gpu.yml" || _fail "hyperqwen gpu overlay with offload off changed for [$variant]"
  done
  _ok "offload off: hyperqwen compose and gpu overlay are byte-identical to baseline $HQ_BASE_REV for every variant"
else
  echo "skip: baseline revision $HQ_BASE_REV not available, hyperqwen byte-identity check skipped"
fi

KO="$TMPBASE/offload-on"
render_hq "$KO" CBOX_HYPERQWEN_KV_OFFLOAD=on
KC="$KO/docker-compose.yml"
grep -qxF '      - "EXTRA_ARGS=--kv-offloading-size 18.625 --kv-offloading-backend native"' "$KC" || _fail "offload on: EXTRA_ARGS line wrong or missing (19072 MiB must render 18.625 GiB)"
grep -qxF '      - "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False"' "$KC" || _fail "offload on: allocator line missing"
grep -qxF '      - "VLLM_USE_SIMPLE_KV_OFFLOAD=0"' "$KC" || _fail "offload on: simple offload switch line missing"
grep -qxF '    shm_size: "23219666944"' "$KC" || _fail "offload on: default shm must be 18.625 GiB + 3 GiB as a byte count"
grep -qxF '    restart: "no"' "$KC" || _fail "offload on: restart policy must be no"
if grep -q 'unless-stopped' "$KC"; then _fail "offload on: unless-stopped must not remain"; fi
if grep -Eq 'mem_limit|memswap_limit|disable-log-stats|REQ_METRICS|ipc:|KEEP_SHM' "$KC"; then _fail "offload on: no cgroup limit, stats flag, ipc host or keep-shm line may render"; fi
[ "$(grep -c 'EXTRA_ARGS' "$KC")" = 1 ] || _fail "offload on: exactly one EXTRA_ARGS line"
diff <(grep -v -e 'EXTRA_ARGS' -e 'PYTORCH_CUDA_ALLOC_CONF' -e 'VLLM_USE_SIMPLE_KV_OFFLOAD' -e '    shm_size:' -e '    restart:' "$KC") <(grep -v -e '    shm_size:' -e '    restart:' "$C1") >/dev/null || _fail "offload on: the compose must differ from the default only in the offload lines, shm_size and restart"
cmp -s "$KO/docker-compose.gpu.yml" "$G1" || _fail "offload on: the gpu overlay must not change"
_ok "offload on: exactly the three env lines, byte shm_size and restart no are added, nothing else changes"

python3 - "$KC" <<'PY' || _fail "offload on compose is not valid YAML"
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
svc = yaml.safe_load(open(sys.argv[1]))["services"]["hyperqwen"]
assert svc["restart"] == "no"
assert svc["shm_size"] == "23219666944"
assert "EXTRA_ARGS=--kv-offloading-size 18.625 --kv-offloading-backend native" in svc["environment"]
PY

gib_text() {
  gen_eval '_cbox_hyperqwen_kv_offload_gib_text' CBOX_HYPERQWEN_KV_OFFLOAD_MIB="$1"
}
[ "$(gib_text 19072)" = 18.625 ] || _fail "19072 MiB must format as 18.625"
[ "$(gib_text 1024)" = 1.000 ] || _fail "1024 MiB must format as 1.000"
[ "$(gib_text 49152)" = 48.000 ] || _fail "49152 MiB must format as 48.000"
[ "$(gib_text 1025)" = 1.001 ] || _fail "1025 MiB must round to 1.001"
[ "$(gib_text 4096)" = 4.000 ] || _fail "4096 MiB must format as 4.000"
[ "$(gib_text 019072)" = 18.625 ] || _fail "a zero-padded value must still format as decimal"
_ok "offload size: MiB over 1024 formatted with three decimals, decimal even when zero-padded"

shm_of() {
  local dir="$TMPBASE/shm-$1"
  shift
  render_hq "$dir" CBOX_HYPERQWEN_KV_OFFLOAD=on "$@"
  grep -m1 '^    shm_size:' "$dir/docker-compose.yml"
}
[ "$(shm_of a)" = '    shm_size: "23219666944"' ] || _fail "shm default 8g must be raised to the offload need"
[ "$(shm_of b CBOX_HYPERQWEN_KV_OFFLOAD_MIB=24576)" = "    shm_size: \"$((27 * 1073741824))\"" ] || _fail "24 GiB offload must give 27 GiB shm"
[ "$(shm_of c CBOX_HYPERQWEN_SHM_SIZE=64g)" = "    shm_size: \"$((64 * 1073741824))\"" ] || _fail "a larger user SHM_SIZE must win"
[ "$(shm_of d CBOX_HYPERQWEN_SHM_SIZE=65536m)" = "    shm_size: \"$((64 * 1073741824))\"" ] || _fail "the m suffix must normalize to powers of 1024"
[ "$(shm_of e CBOX_HYPERQWEN_SHM_SIZE=22g)" = "    shm_size: \"$((22 * 1073741824))\"" ] || _fail "22g user shm must win over 21.625 GiB"
[ "$(shm_of f CBOX_HYPERQWEN_SHM_SIZE=21g)" = '    shm_size: "23219666944"' ] || _fail "21g user shm is below the need and must be raised"
[ "$(shm_of g CBOX_HYPERQWEN_KV_OFFLOAD_MIB=1024 CBOX_HYPERQWEN_SHM_SIZE=1g)" = "    shm_size: \"$((3 * 1073741824))\"" ] || _fail "1 GiB offload plus the 2 GiB margin must give 3 GiB"
[ "$(shm_of g2 CBOX_HYPERQWEN_KV_OFFLOAD_MIB=1024)" = "    shm_size: \"$((8 * 1073741824))\"" ] || _fail "the default 8g must stay when it already exceeds the small offload need"
[ "$(gen_eval '_cbox_hyperqwen_shm_bytes 524288k')" = 536870912 ] || _fail "the k suffix must normalize to powers of 1024"
[ "$(gen_eval '_cbox_hyperqwen_shm_bytes 512m')" = 536870912 ] || _fail "the m suffix must normalize to powers of 1024"
[ "$(gen_eval '_cbox_hyperqwen_shm_bytes 8g')" = 8589934592 ] || _fail "the g suffix must normalize to powers of 1024"
[ "$(gen_eval '_cbox_hyperqwen_shm_bytes 100000')" = 100000 ] || _fail "a bare number is a byte count"
_ok "shm: max(user size in bytes, offload bytes + margin) rendered as a byte count"

D8="$TMPBASE/offload-small"
render_hq "$D8" CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_KV_OFFLOAD_MIB=1024
grep -qxF '      - "EXTRA_ARGS=--kv-offloading-size 1.000 --kv-offloading-backend native"' "$D8/docker-compose.yml" || _fail "offload size 1024 must render 1.000"
_ok "offload size follows CBOX_HYPERQWEN_KV_OFFLOAD_MIB"

refuse offload-low CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_KV_OFFLOAD_MIB=1023
refuse offload-high CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_KV_OFFLOAD_MIB=49153
refuse offload-text CBOX_HYPERQWEN_KV_OFFLOAD=on 'CBOX_HYPERQWEN_KV_OFFLOAD_MIB=1024 --evil'
refuse offload-injection CBOX_HYPERQWEN_KV_OFFLOAD=on 'CBOX_HYPERQWEN_KV_OFFLOAD_MIB=2048;touch x'
refuse offload-mode CBOX_HYPERQWEN_KV_OFFLOAD=maybe
refuse offload-off-bad-size CBOX_HYPERQWEN_KV_OFFLOAD=off CBOX_HYPERQWEN_KV_OFFLOAD_MIB=5
refuse reserve-low CBOX_HYPERQWEN_RAM_RESERVE_GIB=7
refuse reserve-high CBOX_HYPERQWEN_RAM_RESERVE_GIB=33
refuse offload-dflash CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_SPEC=dflash2
refuse offload-fast CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_CTX=fast
refuse offload-huge CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_CTX=huge
_ok "offload: out-of-range or injected values and unsupported profiles refuse the render and write nothing"

D9="$TMPBASE/offload-padded"
render_hq "$D9" CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_KV_OFFLOAD_MIB=0004096
grep -qxF '      - "EXTRA_ARGS=--kv-offloading-size 4.000 --kv-offloading-backend native"' "$D9/docker-compose.yml" || _fail "EXTRA_ARGS must be built from the validated integer only"
_ok "EXTRA_ARGS is built from the validated integer only"

MD3="$TMPBASE/manifest-offload"
mkdir -p "$MD3"
gen_eval "_cbox_hyperqwen_manifest_write \"$MD3\"" CBOX_HYPERQWEN_MODE=on CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_KV_OFFLOAD_MIB=8192 CBOX_HYPERQWEN_RAM_RESERVE_GIB=20
grep -qx 'kv_offload=on' "$MD3/ownership.manifest" || _fail "manifest kv_offload missing"
grep -qx 'kv_offload_mib=8192' "$MD3/ownership.manifest" || _fail "manifest kv_offload_mib missing"
grep -qx 'ram_reserve_gib=20' "$MD3/ownership.manifest" || _fail "manifest ram_reserve_gib missing"
match3() {
  gen_eval "_cbox_hyperqwen_manifest_matches_current \"$MD3\"" CBOX_HYPERQWEN_MODE=on CBOX_HYPERQWEN_KV_OFFLOAD=on CBOX_HYPERQWEN_KV_OFFLOAD_MIB=8192 CBOX_HYPERQWEN_RAM_RESERVE_GIB=20 "$@"
}
match3 || _fail "offload manifest must match the config it was written from"
for change in CBOX_HYPERQWEN_KV_OFFLOAD=off CBOX_HYPERQWEN_KV_OFFLOAD_MIB=8256 CBOX_HYPERQWEN_RAM_RESERVE_GIB=21; do
  if match3 "$change"; then _fail "offload manifest must stop matching after $change"; fi
done
_ok "manifest: each offload key breaks the match when changed"

MD4="$TMPBASE/manifest-old"
mkdir -p "$MD4"
gen_eval "_cbox_hyperqwen_manifest_write \"$MD4\"" CBOX_HYPERQWEN_MODE=on
grep -v -e '^kv_offload=' -e '^kv_offload_mib=' -e '^ram_reserve_gib=' "$MD4/ownership.manifest" > "$MD4/old"
mv "$MD4/old" "$MD4/ownership.manifest"
gen_eval "_cbox_hyperqwen_manifest_matches_current \"$MD4\"" CBOX_HYPERQWEN_MODE=on || _fail "an old manifest without the offload fields must match the offload-off defaults"
if gen_eval "_cbox_hyperqwen_manifest_matches_current \"$MD4\"" CBOX_HYPERQWEN_MODE=on CBOX_HYPERQWEN_KV_OFFLOAD=on; then _fail "an old manifest must stop matching once the offload is turned on"; fi
if gen_eval "_cbox_hyperqwen_manifest_matches_current \"$MD4\"" CBOX_HYPERQWEN_MODE=on CBOX_HYPERQWEN_KV_OFFLOAD_MIB=8192; then _fail "an old manifest must stop matching a non-default offload size"; fi
if gen_eval "_cbox_hyperqwen_manifest_matches_current \"$MD4\"" CBOX_HYPERQWEN_MODE=on CBOX_HYPERQWEN_RAM_RESERVE_GIB=20; then _fail "an old manifest must stop matching a non-default reserve"; fi
_ok "manifest: an old manifest without the offload fields counts as offload off with the default size and reserve"

python3 - "$INSTALL_DIR/etc/registry/settings.json" <<'PY' || _fail "registry entries for the offload keys are wrong"
import json
import sys
reg = json.load(open(sys.argv[1]))
vs = {v["key"]: v for v in reg["variables"]}
sec = [s for s in reg["sections"] if s["id"] == "hyperqwen"][0]
assert sec["scope"] == "machine" and sec["apply_class"] == "infra-reconcile" and sec["profile"] == "skip"
k = vs["CBOX_HYPERQWEN_KV_OFFLOAD"]
assert k["section"] == "hyperqwen" and k["default"] == "off" and k["type"]["values"] == ["off", "on"]
m = vs["CBOX_HYPERQWEN_KV_OFFLOAD_MIB"]
assert m["section"] == "hyperqwen" and m["default"] == "19072" and (m["type"]["min"], m["type"]["max"]) == (1024, 49152)
r = vs["CBOX_HYPERQWEN_RAM_RESERVE_GIB"]
assert r["section"] == "hyperqwen" and r["default"] == "16" and (r["type"]["min"], r["type"]["max"]) == (8, 32)
assert not [x for x in vs if x.startswith("CBOX_HYPERQWEN_METRICS") or x.startswith("CBOX_HYPERQWEN_TUNE")]
PY
_ok "registry: three offload keys in the hyperqwen section with the contract defaults and ranges, no metrics or tune keys"

echo "PASS: all hyperqwen render checks"
