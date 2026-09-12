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

source "$INSTALL_DIR/_common.sh"
source "$INSTALL_DIR/templates/generators.sh"
source "$INSTALL_DIR/templates/sections.sh"
source "$INSTALL_DIR/templates/conf_lib.sh"

_load_cbox_functions() {
  local extracted="$TMPBASE/cbox_functions.sh"
  awk '
    /^die_no_conf\(\) \{/ { infunc=1 }
    /^_cbox_local_effdir_for\(\) \{/ { infunc=1 }
    /^_cbox_machine_scoped_vars\(\) \{/ { infunc=1 }
    /^_cbox_load_machine_scoped_vars\(\) \{/ { infunc=1 }
    /^_cbox_root_in_global_scope\(\) \{/ { infunc=1 }
    /^_cbox_effective_mode\(\) \{/ { infunc=1 }
    /^_cbox_doctor_in_container\(\) \{/ { infunc=1 }
    /^require_global_conf\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/cbox" > "$extracted"
  awk '/^_cbox_config_load_sections\(\) \{/{f=1} f{print} f && /^config_cmd\(\) \{/{exit}' "$INSTALL_DIR/cbox" > "$TMPBASE/cbox_config_block.sh"
  sed -i '$ d' "$TMPBASE/cbox_config_block.sh"
  awk '/^config_cmd\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$INSTALL_DIR/cbox" >> "$TMPBASE/cbox_config_block.sh"
  source "$extracted"
  source "$TMPBASE/cbox_config_block.sh"
}
_load_cbox_functions

declare -f _cbox_config_set_var >/dev/null || _fail "extraction failed: _cbox_config_set_var not defined"
declare -f config_cmd >/dev/null || _fail "extraction failed: config_cmd not defined"
declare -f _cbox_config_dep_gate >/dev/null || _fail "extraction failed: _cbox_config_dep_gate not defined"

HOME="$TMPBASE/home"
mkdir -p "$HOME"

_cbox_config_is_whitelisted CBOX_HERMES_VERSION || _fail "whitelist: CBOX_HERMES_VERSION should be whitelisted"
_ok "whitelist: known var accepted"

if _cbox_config_is_whitelisted CBOX_NOT_A_REAL_VAR; then
  _fail "whitelist: unknown var should be rejected"
fi
_ok "whitelist: unknown var rejected"

if _cbox_config_is_whitelisted "PATH"; then
  _fail "whitelist: non-CBOX var should be rejected"
fi
_ok "whitelist: non-CBOX var rejected"

if _cbox_config_parse_pairs 'CBOX_NOPE=x' 2>/dev/null; then
  _fail "parse_pairs: should reject a non-whitelisted key"
fi
_ok "parse_pairs: rejects non-whitelisted key"

if _cbox_config_parse_pairs 'not_upper=x' 2>/dev/null; then
  _fail "parse_pairs: should reject a lowercase key"
fi
_ok "parse_pairs: rejects key not matching ^[A-Z][A-Z0-9_]*\$"

if _cbox_config_parse_pairs "$(printf 'CBOX_GPU=1\n0')" 2>/dev/null; then
  _fail "parse_pairs: should reject a value containing a newline"
fi
_ok "parse_pairs: rejects newline in value"

if _cbox_config_parse_pairs "$(printf 'CBOX_GPU=1\r0')" 2>/dev/null; then
  _fail "parse_pairs: should reject a value containing a carriage return"
fi
_ok "parse_pairs: rejects carriage return in value"

if err="$(_cbox_config_validate_var CBOX_HERMES_MODEL_NAME "$(printf 'a\x01b')" 2>&1)"; then
  _fail "validate_var: should reject other control characters (got: $err)"
fi
_ok "validate_var: rejects other C0 control characters via _cbox_config_no_ctrl"

_cbox_config_validate_var CBOX_MODE global || _fail "enum: CBOX_MODE=global should be valid"
if _cbox_config_validate_var CBOX_MODE bogus >/dev/null 2>&1; then
  _fail "enum: CBOX_MODE=bogus should be rejected"
fi
_ok "validator: enum (CBOX_MODE)"

_cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT 1080 || _fail "numeric: 1080 should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT "-1" >/dev/null 2>&1; then
  _fail "numeric: negative port should be rejected"
fi
if _cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT "abc" >/dev/null 2>&1; then
  _fail "numeric: non-numeric port should be rejected"
fi
if _cbox_config_validate_var CBOX_NETACCESS_SOCKS_PORT 65536 >/dev/null 2>&1; then
  _fail "numeric: out-of-range port should be rejected"
fi
_ok "validator: numeric (CBOX_NETACCESS_SOCKS_PORT)"

_cbox_config_validate_var CBOX_NETACCESS_EXEC_MODE scoped || _fail "netaccess exec: scoped should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_MODE all >/dev/null 2>&1; then
  _fail "netaccess exec: all should be rejected"
fi
_cbox_config_validate_var CBOX_NETACCESS_EXEC_WORKSPACE_GUARD on || _fail "netaccess exec workspace guard: on should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_WORKSPACE_GUARD required >/dev/null 2>&1; then
  _fail "netaccess exec workspace guard: unknown value should be rejected"
fi
_cbox_config_validate_var CBOX_NETACCESS_EXEC_TIMEOUT 900 || _fail "netaccess exec timeout: 900 should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_TIMEOUT 0 >/dev/null 2>&1; then
  _fail "netaccess exec timeout: zero should be rejected"
fi
_cbox_config_validate_var CBOX_NETACCESS_EXEC_MAX_BYTES 10485760 || _fail "netaccess exec max bytes: default should be valid"
if _cbox_config_validate_var CBOX_NETACCESS_EXEC_MAX_BYTES 1023 >/dev/null 2>&1; then
  _fail "netaccess exec max bytes: values below 1024 should be rejected"
fi
_ok "validator: scoped container exec limits"

_cbox_config_validate_var CBOX_LOCAL_MODEL_URL "http://ollama:11434" || _fail "url: valid http url should pass"
_cbox_config_validate_var CBOX_LOCAL_MODEL_URL "" || _fail "url: empty should be allowed (delegate off)"
if _cbox_config_validate_var CBOX_LOCAL_MODEL_URL "ftp://x" >/dev/null 2>&1; then
  _fail "url: non-http(s) scheme should be rejected"
fi
_ok "validator: URL shape (CBOX_LOCAL_MODEL_URL)"

_cbox_config_validate_var CBOX_HERMES_VERSION "0.19.0" || _fail "hermes version: 0.19.0 should be valid"
if _cbox_config_validate_var CBOX_HERMES_VERSION "not-a-version" >/dev/null 2>&1; then
  _fail "hermes version: garbage should be rejected"
fi
if _cbox_config_validate_var CBOX_HERMES_VERSION "1" >/dev/null 2>&1; then
  _fail "hermes version: bare major with no dot should be rejected"
fi
_ok "validator: hermes version pin grammar"

_cbox_config_validate_var CBOX_HERMES_PROVIDER local || _fail "hermes provider: local should be valid"
_cbox_config_validate_var CBOX_HERMES_PROVIDER anthropic || _fail "hermes provider: anthropic should be valid"
if _cbox_config_validate_var CBOX_HERMES_PROVIDER bogus >/dev/null 2>&1; then
  _fail "hermes provider: bogus provider should be rejected"
fi
_ok "validator: hermes provider enum"

_cbox_config_validate_var CBOX_HERMES_DELEGATE_MAX_CONCURRENCY 0 || _fail "hermes delegate max concurrency: 0 should be valid (falls back to server default)"
_cbox_config_validate_var CBOX_HERMES_DELEGATE_MAX_CONCURRENCY 4 || _fail "hermes delegate max concurrency: 4 should be valid"
if _cbox_config_validate_var CBOX_HERMES_DELEGATE_MAX_CONCURRENCY "-1" >/dev/null 2>&1; then
  _fail "hermes delegate max concurrency: negative should be rejected"
fi
if _cbox_config_validate_var CBOX_HERMES_DELEGATE_MAX_CONCURRENCY 17 >/dev/null 2>&1; then
  _fail "hermes delegate max concurrency: above the server MAX_CONCURRENCY_CAP (16) should be rejected"
fi
if _cbox_config_validate_var CBOX_HERMES_DELEGATE_MAX_CONCURRENCY "abc" >/dev/null 2>&1; then
  _fail "hermes delegate max concurrency: non-numeric should be rejected"
fi
_ok "validator: hermes delegate max concurrency (CBOX_HERMES_DELEGATE_MAX_CONCURRENCY)"

_cbox_config_validate_var CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC "" || _fail "hermes delegate queue wait: empty should be valid (falls back to server default)"
_cbox_config_validate_var CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC 900 || _fail "hermes delegate queue wait: 900 should be valid"
if _cbox_config_validate_var CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC "-1" >/dev/null 2>&1; then
  _fail "hermes delegate queue wait: negative should be rejected"
fi
if _cbox_config_validate_var CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC "abc" >/dev/null 2>&1; then
  _fail "hermes delegate queue wait: non-numeric should be rejected"
fi
_ok "validator: hermes delegate queue wait seconds (CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC)"

_cbox_config_validate_var CBOX_HERMES_DELEGATE_LOCK_DIR "" || _fail "hermes delegate lock dir: empty should be valid (falls back to server default)"
_cbox_config_validate_var CBOX_HERMES_DELEGATE_LOCK_DIR "/tmp/cbox-hermes-delegate-locks" || _fail "hermes delegate lock dir: absolute path should be valid"
if _cbox_config_validate_var CBOX_HERMES_DELEGATE_LOCK_DIR "relative/path" >/dev/null 2>&1; then
  _fail "hermes delegate lock dir: relative path should be rejected"
fi
_ok "validator: hermes delegate lock dir (CBOX_HERMES_DELEGATE_LOCK_DIR)"

_cbox_config_validate_var OLLAMA_NUM_PARALLEL "" || _fail "ollama num parallel: empty should be valid (falls back to server default)"
_cbox_config_validate_var OLLAMA_NUM_PARALLEL 4 || _fail "ollama num parallel: 4 should be valid"
if _cbox_config_validate_var OLLAMA_NUM_PARALLEL "-1" >/dev/null 2>&1; then
  _fail "ollama num parallel: negative should be rejected"
fi
if _cbox_config_validate_var OLLAMA_NUM_PARALLEL "abc" >/dev/null 2>&1; then
  _fail "ollama num parallel: non-numeric should be rejected"
fi
_ok "validator: OLLAMA_NUM_PARALLEL"

_cbox_config_validate_var CBOX_HERMES_DELEGATE_MODE "" || _fail "hermes delegate mode: empty should be valid (falls back to server default)"
_cbox_config_validate_var CBOX_HERMES_DELEGATE_MODE qa || _fail "hermes delegate mode: qa should be valid"
if _cbox_config_validate_var CBOX_HERMES_DELEGATE_MODE bogus >/dev/null 2>&1; then
  _fail "hermes delegate mode: unsupported mode should be rejected"
fi
_ok "validator: hermes delegate mode (CBOX_HERMES_DELEGATE_MODE)"

_cbox_config_validate_var CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS "" || _fail "hermes delegate disabled toolsets: empty should be valid (falls back to the default toolset list)"
_cbox_config_validate_var CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS "terminal,file,web" || _fail "hermes delegate disabled toolsets: csv list should be valid"
_ok "validator: hermes delegate disabled toolsets (CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS)"

_cbox_config_validate_var CBOX_LIMIT_RESUME_PROMPT "please continue now" || _fail "free-text: spaces should be allowed"
if _cbox_config_validate_var CBOX_LIMIT_RESUME_PROMPT "" >/dev/null 2>&1; then
  _fail "free-text: empty prompt should be rejected (must not be empty)"
fi
_ok "validator: free-text var accepting spaces (CBOX_LIMIT_RESUME_PROMPT)"

_cbox_config_validate_var CBOX_OLLAMA_MODE off || _fail "ollama mode: off should be valid"
_cbox_config_validate_var CBOX_OLLAMA_MODE on || _fail "ollama mode: on should be valid"
if _cbox_config_validate_var CBOX_OLLAMA_MODE bogus >/dev/null 2>&1; then
  _fail "ollama mode: bogus should be rejected"
fi
_ok "validator: CBOX_OLLAMA_MODE enum"

_cbox_config_validate_var CBOX_OLLAMA_IMAGE "ollama/ollama:0.33.3" || _fail "ollama image: pinned tag should be valid"
if _cbox_config_validate_var CBOX_OLLAMA_IMAGE "" >/dev/null 2>&1; then
  _fail "ollama image: empty should be rejected"
fi
if _cbox_config_validate_var CBOX_OLLAMA_IMAGE "ollama/ollama 0.33.3" >/dev/null 2>&1; then
  _fail "ollama image: whitespace should be rejected"
fi
_ok "validator: CBOX_OLLAMA_IMAGE"

_cbox_config_validate_var CBOX_OLLAMA_GPU off || _fail "ollama gpu: off should be valid"
_cbox_config_validate_var CBOX_OLLAMA_GPU cdi || _fail "ollama gpu: cdi should be valid"
if _cbox_config_validate_var CBOX_OLLAMA_GPU 1 >/dev/null 2>&1; then
  _fail "ollama gpu: numeric CBOX_GPU-style value should be rejected (separate knob)"
fi
_ok "validator: CBOX_OLLAMA_GPU enum (separate from CBOX_GPU)"

_cbox_config_validate_var CBOX_OLLAMA_STORE dedicated || _fail "ollama store: dedicated should be valid"
_cbox_config_validate_var CBOX_OLLAMA_STORE shared || _fail "ollama store: shared should be valid"
if _cbox_config_validate_var CBOX_OLLAMA_STORE bogus >/dev/null 2>&1; then
  _fail "ollama store: bogus should be rejected"
fi
_ok "validator: CBOX_OLLAMA_STORE enum"

_cbox_config_validate_var CBOX_OLLAMA_STORE_PATH "" || _fail "ollama store path: empty should be valid (dedicated mode)"
_cbox_config_validate_var CBOX_OLLAMA_STORE_PATH "/home/user/.ollama" || _fail "ollama store path: absolute path should be valid"
if _cbox_config_validate_var CBOX_OLLAMA_STORE_PATH "relative/path" >/dev/null 2>&1; then
  _fail "ollama store path: relative path should be rejected"
fi
_ok "validator: CBOX_OLLAMA_STORE_PATH"

_cbox_config_validate_var CBOX_OLLAMA_PORT 11434 || _fail "ollama port: 11434 should be valid"
if _cbox_config_validate_var CBOX_OLLAMA_PORT 0 >/dev/null 2>&1; then
  _fail "ollama port: 0 should be rejected"
fi
if _cbox_config_validate_var CBOX_OLLAMA_PORT 70000 >/dev/null 2>&1; then
  _fail "ollama port: out-of-range should be rejected"
fi
_ok "validator: CBOX_OLLAMA_PORT"

_cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL 1 || _fail "ollama num parallel: 1 should be valid"
_cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL 4 || _fail "ollama num parallel: 4 should be valid"
if _cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL 0 >/dev/null 2>&1; then
  _fail "ollama num parallel: 0 should be rejected (must be at least 1, unlike the empty-allowed hermes-delegate fallback var)"
fi
if _cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL "" >/dev/null 2>&1; then
  _fail "ollama num parallel: empty should be rejected (this is the owner's own setting, not an optional fallback)"
fi
if _cbox_config_validate_var CBOX_OLLAMA_NUM_PARALLEL "abc" >/dev/null 2>&1; then
  _fail "ollama num parallel: non-numeric should be rejected"
fi
_ok "validator: CBOX_OLLAMA_NUM_PARALLEL"

_cbox_config_validate_var CBOX_WG_MODE off || _fail "wg mode: off should be valid"
_cbox_config_validate_var CBOX_WG_MODE server || _fail "wg mode: server should be valid"
_cbox_config_validate_var CBOX_WG_MODE client || _fail "wg mode: client should be valid"
_cbox_config_validate_var CBOX_WG_MODE both || _fail "wg mode: both should be valid"
if _cbox_config_validate_var CBOX_WG_MODE bogus >/dev/null 2>&1; then
  _fail "wg mode: bogus should be rejected"
fi
_ok "validator: CBOX_WG_MODE enum"

_cbox_config_validate_var CBOX_WG_IMPL auto || _fail "wg impl: auto should be valid"
_cbox_config_validate_var CBOX_WG_IMPL kernel || _fail "wg impl: kernel should be valid"
_cbox_config_validate_var CBOX_WG_IMPL userspace || _fail "wg impl: userspace should be valid"
if _cbox_config_validate_var CBOX_WG_IMPL bogus >/dev/null 2>&1; then
  _fail "wg impl: bogus should be rejected"
fi
_ok "validator: CBOX_WG_IMPL enum"

_cbox_config_validate_var CBOX_WG_ADDRESS "" || _fail "wg address: empty should be valid"
_cbox_config_validate_var CBOX_WG_ADDRESS "10.90.0.1/24" || _fail "wg address: CIDR should be valid"
if _cbox_config_validate_var CBOX_WG_ADDRESS "10.90.0.1" >/dev/null 2>&1; then
  _fail "wg address: missing prefix length should be rejected"
fi
_ok "validator: CBOX_WG_ADDRESS"

_cbox_config_validate_var CBOX_WG_LISTEN_PORT 51820 || _fail "wg listen port: 51820 should be valid"
if _cbox_config_validate_var CBOX_WG_LISTEN_PORT 0 >/dev/null 2>&1; then
  _fail "wg listen port: 0 should be rejected"
fi
if _cbox_config_validate_var CBOX_WG_LISTEN_PORT 99999 >/dev/null 2>&1; then
  _fail "wg listen port: out-of-range should be rejected"
fi
_ok "validator: CBOX_WG_LISTEN_PORT"

_cbox_config_validate_var CBOX_WG_PUBLISH_ADDR "" || _fail "wg publish addr: empty should be valid"
_cbox_config_validate_var CBOX_WG_PUBLISH_ADDR "203.0.113.5" || _fail "wg publish addr: literal IPv4 should be valid"
if _cbox_config_validate_var CBOX_WG_PUBLISH_ADDR "not-an-ip" >/dev/null 2>&1; then
  _fail "wg publish addr: non-IPv4 should be rejected"
fi
_ok "validator: CBOX_WG_PUBLISH_ADDR"

_cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "" || _fail "wg peer endpoint: empty should be valid"
_cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "example.com:51820" || _fail "wg peer endpoint: host:port should be valid"
if _cbox_config_validate_var CBOX_WG_PEER_ENDPOINT "example.com" >/dev/null 2>&1; then
  _fail "wg peer endpoint: missing port should be rejected"
fi
_ok "validator: CBOX_WG_PEER_ENDPOINT"

_WG_VALID_PUBKEY="aRcYqQIm9uH5B9V0IEQKddz3nO2FnHOEcYcQ0YQnMBs="
_cbox_config_validate_var CBOX_WG_PEER_PUBKEY "" || _fail "wg peer pubkey: empty should be valid"
_cbox_config_validate_var CBOX_WG_PEER_PUBKEY "$_WG_VALID_PUBKEY" || _fail "wg peer pubkey: canonical key shape should be valid"
if _cbox_config_validate_var CBOX_WG_PEER_PUBKEY "short" >/dev/null 2>&1; then
  _fail "wg peer pubkey: too-short key should be rejected"
fi
_ok "validator: CBOX_WG_PEER_PUBKEY"

_cbox_config_validate_var CBOX_WG_PEER_ADDRESS "" || _fail "wg peer address: empty should be valid"
_cbox_config_validate_var CBOX_WG_PEER_ADDRESS "10.90.0.2/32" || _fail "wg peer address: CIDR should be valid"
if _cbox_config_validate_var CBOX_WG_PEER_ADDRESS "not-an-ip" >/dev/null 2>&1; then
  _fail "wg peer address: garbage should be rejected"
fi
_ok "validator: CBOX_WG_PEER_ADDRESS"

_cbox_config_validate_var CBOX_WG_KEEPALIVE 25 || _fail "wg keepalive: 25 should be valid"
_cbox_config_validate_var CBOX_WG_KEEPALIVE 0 || _fail "wg keepalive: 0 should be valid"
if _cbox_config_validate_var CBOX_WG_KEEPALIVE -1 >/dev/null 2>&1; then
  _fail "wg keepalive: negative should be rejected"
fi
_ok "validator: CBOX_WG_KEEPALIVE"

for _v in CBOX_OLLAMA_MODE CBOX_OLLAMA_IMAGE CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE CBOX_OLLAMA_STORE_PATH CBOX_OLLAMA_PORT CBOX_OLLAMA_NUM_PARALLEL CBOX_OLLAMA_CONTEXT_LENGTH CBOX_OLLAMA_FLASH_ATTENTION CBOX_OLLAMA_KV_CACHE_TYPE CBOX_OLLAMA_KEEP_ALIVE; do
  _cbox_config_is_whitelisted "$_v" || _fail "whitelist: $_v should be whitelisted (SEC_VARS[ollama])"
done
unset _v
_ok "whitelist: all ollama vars are whitelisted via SEC_VARS[ollama]"

for _v in CBOX_WG_MODE CBOX_WG_IMPL CBOX_WG_ADDRESS CBOX_WG_LISTEN_PORT CBOX_WG_PUBLISH_ADDR CBOX_WG_PEER_ENDPOINT CBOX_WG_PEER_PUBKEY CBOX_WG_PEER_ADDRESS CBOX_WG_KEEPALIVE; do
  _cbox_config_is_whitelisted "$_v" || _fail "whitelist: $_v should be whitelisted (SEC_VARS[wireguard])"
done
unset _v
_ok "whitelist: all wireguard vars are whitelisted via SEC_VARS[wireguard]"

[ "$(sec_get SEC_SCOPE ollama)" = machine ] || _fail "SEC_SCOPE[ollama] should be machine"
_ok "SEC_SCOPE[ollama]=machine"

[ "$(sec_get SEC_SCOPE wireguard)" = machine ] || _fail "SEC_SCOPE[wireguard] should be machine"
_ok "SEC_SCOPE[wireguard]=machine"

[ "$(sec_get SEC_SCOPE local-model)" = machine ] \
  || _fail "SEC_SCOPE[local-model] should be machine - the endpoint is a fact about the host, and every project reads the same one"
_ok "SEC_SCOPE[local-model]=machine"

[ "$(sec_get SEC_SCOPE hermes)" = project ] \
  || _fail "SEC_SCOPE[hermes] must stay project - whether a project offers the hermes engine is a per-project call, unlike where the model runs"
_ok "SEC_SCOPE[hermes]=project"
[ "$(sec_get SEC_SCOPE hermes-delegate)" = machine ] \
  || _fail "SEC_SCOPE[hermes-delegate] must be machine - the delegate is decided once per host and rendered only where the project-scoped hermes engine is on"
_ok "SEC_SCOPE[hermes-delegate]=machine"

for _s in mode mounts workspaces python gpu egress netaccess hostroute ssh bashrc mcp-servers \
  codex-progress hermes autoresume agents codex-mcp continuity \
  claude-md settings hooks git-identity apt-extra binaries restart-policy; do
  [ "$(sec_get SEC_SCOPE "$_s")" = project ] || _fail "SEC_SCOPE[$_s] should default to project, got $(sec_get SEC_SCOPE "$_s")"
done
unset _s
_ok "SEC_SCOPE defaults to project for every pre-existing section"

[ "$(sec_get SEC_APPLY ollama)" = infra-reconcile ] || _fail "SEC_APPLY[ollama] should be infra-reconcile"
_ok "SEC_APPLY[ollama]=infra-reconcile"

[ "$(sec_get SEC_APPLY wireguard)" = infra-reconcile ] || _fail "SEC_APPLY[wireguard] should be infra-reconcile"
_ok "SEC_APPLY[wireguard]=infra-reconcile"

apply_report="$(_cbox_config_apply_cmd_for infra-reconcile)"
case "$apply_report" in
  *"cbox ollama reconcile"*) ;;
  *) _fail "apply-cmd: infra-reconcile should map to cbox ollama reconcile, got: $apply_report" ;;
esac
_ok "apply-cmd: infra-reconcile class names cbox ollama reconcile"

declare -f _cbox_machine_scoped_vars >/dev/null || _fail "extraction failed: _cbox_machine_scoped_vars not defined"
machine_vars="$(_cbox_machine_scoped_vars | sort)"
expected_machine_vars="$(printf '%s\n' CBOX_OLLAMA_MODE CBOX_OLLAMA_IMAGE CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE CBOX_OLLAMA_STORE_PATH CBOX_OLLAMA_PORT CBOX_OLLAMA_NUM_PARALLEL CBOX_OLLAMA_CONTEXT_LENGTH CBOX_OLLAMA_FLASH_ATTENTION CBOX_OLLAMA_KV_CACHE_TYPE CBOX_OLLAMA_KEEP_ALIVE CBOX_WG_MODE CBOX_WG_IMPL CBOX_WG_ADDRESS CBOX_WG_LISTEN_PORT CBOX_WG_PUBLISH_ADDR CBOX_WG_PEER_ENDPOINT CBOX_WG_PEER_PUBKEY CBOX_WG_PEER_ADDRESS CBOX_WG_KEEPALIVE CBOX_WG_FORWARDS CBOX_LOCAL_MODEL CBOX_LOCAL_MODEL_URL CBOX_LOCAL_MODEL_NAME CBOX_LOCAL_MODEL_TIMEOUT_SEC CBOX_HERMES_DELEGATE CBOX_HERMES_DELEGATE_PROVIDER CBOX_HERMES_DELEGATE_BASE_URL CBOX_HERMES_DELEGATE_MODEL CBOX_HERMES_DELEGATE_MAX_CONCURRENCY CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC CBOX_HERMES_DELEGATE_LOCK_DIR OLLAMA_NUM_PARALLEL CBOX_HERMES_DELEGATE_MODE CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS | sort)"
[ "$machine_vars" = "$expected_machine_vars" ] || _fail "_cbox_machine_scoped_vars: expected exactly the ollama+wireguard+local-model+hermes-delegate vars, got: $machine_vars"
_ok "_cbox_machine_scoped_vars: enumerates exactly SEC_VARS[ollama] + SEC_VARS[wireguard] (the two machine-scoped sections)"

CBOX_MODE=global
_cbox_config_dep_gate CBOX_RESTART_POLICY >/dev/null 2>&1 || _fail "dep-gate: global mode should be unaffected (condition is isolated-mode)"
_ok "dep-gate: global mode leaves restart-policy alone (sanity)"

CBOX_MODE=isolated
if err="$(_cbox_config_dep_gate CBOX_RESTART_POLICY 2>&1)"; then
  _fail "dep-gate: isolated mode should force restart-policy back (disable:isolated-mode)"
else
  case "$err" in
    *"isolated mode"*) _ok "dep-gate: rejects CBOX_RESTART_POLICY under isolated mode ($err)" ;;
    *) _fail "dep-gate: rejection reason missing isolated-mode text: $err" ;;
  esac
fi
unset CBOX_MODE

CBOX_HERMES=off
_cbox_config_dep_gate CBOX_HERMES_DELEGATE >/dev/null 2>&1 \
  || _fail "dep-gate: CBOX_HERMES_DELEGATE is machine-scoped and must not be gated on the project-scoped CBOX_HERMES (the render gate handles a project without the engine); CBOX_HERMES=off rejected it"
_ok "dep-gate: CBOX_HERMES=off no longer forces hermes-delegate back (machine scope, render-gated instead)"
export CBOX_HERMES=on
_cbox_config_dep_gate CBOX_HERMES_DELEGATE >/dev/null 2>&1 \
  || _fail "dep-gate: CBOX_HERMES=on should leave hermes-delegate ungated"
_ok "dep-gate: CBOX_HERMES=on leaves hermes-delegate ungated"
unset CBOX_HERMES

PENDIR="$TMPBASE/pending-eff"
mkdir -p "$PENDIR"
_cbox_config_write_pending "$PENDIR" hermes mode
[ -f "$PENDIR/pending.apply" ] || _fail "pending: pending.apply not written"
grep -qx 'hermes=recreate' "$PENDIR/pending.apply" || _fail "pending: hermes=recreate line missing"
grep -qx 'mode=none' "$PENDIR/pending.apply" || _fail "pending: mode=none line missing"
_ok "pending: pending.apply renders section=apply-class lines"

report="$(_cbox_config_print_report hermes mode)"
case "$report" in
  *"recreate"*"compose recreates"*) ;;
  *) _fail "report: hermes recreate command text missing from report: $report" ;;
esac
case "$report" in
  *"none"*"takes effect on next cbox run"*) ;;
  *) _fail "report: mode none command text missing from report: $report" ;;
esac
_ok "pending: stage-and-report table names the exact apply command per class"

CASDIR="$TMPBASE/cas"
mkdir -p "$CASDIR"
printf 'CBOX_GPU=0\n' > "$CASDIR/cbox.conf"
loaded_sha="$(sha256sum "$CASDIR/cbox.conf" | awk '{print $1}')"
printf 'CBOX_GPU=1\n' > "$CASDIR/cbox.conf"
cur_sha="$(sha256sum "$CASDIR/cbox.conf" | awk '{print $1}')"
[ "$cur_sha" != "$loaded_sha" ] || _fail "CAS: test setup did not actually change the file"
_ok "CAS: loaded-vs-disk sha mismatch is detectable (the abort branch in _cbox_config_set_global checks this exact condition)"

_setup_fixture_eff() {
  local eff="$1" root="$2"
  mkdir -p "$eff"
  {
    local v
    for v in $(_cbox_config_whitelist); do
      case "$v" in
        CBOX_MODE) printf 'CBOX_MODE=isolated\n' ;;
        CBOX_HERMES) printf 'CBOX_HERMES=off\n' ;;
        CBOX_HERMES_VERSION) printf 'CBOX_HERMES_VERSION=0.19.0\n' ;;
        CBOX_HERMES_PROVIDER) printf 'CBOX_HERMES_PROVIDER=local\n' ;;
        CBOX_GPU) printf 'CBOX_GPU=0\n' ;;
        CBOX_WORKSPACES) printf 'CBOX_WORKSPACES=%q\n' "$root" ;;
        *) printf '%s=%q\n' "$v" "" ;;
      esac
    done
  } > "$eff/cbox.conf"
  mkdir -p "$eff/generated"
  echo "original-marker" > "$eff/generated/marker.txt"
  _cbox_manifest_write "$eff" "$root" "$eff/cbox.conf"
  _cbox_manifest_write_generated "$eff"
}

ROOT="$TMPBASE/project-root"
mkdir -p "$ROOT"
mkdir -p "$HOME/.config/cbox/projects"
EFF="$HOME/.config/cbox/projects/fixedhash"
_setup_fixture_eff "$EFF" "$ROOT"

REGEN_LOG="$TMPBASE/regen.log"
_gen_effective() {
  local eff="$1" root="$2"
  printf 'regen-called eff=%s root=%s\n' "$eff" "$root" >> "$REGEN_LOG"
  echo "regenerated-marker" > "$eff/generated/marker.txt"
}

_cbox_workspace_root() { printf '%s' "$ROOT"; }
_cbox_path_hash() { printf 'fixedhash'; }

(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_HERMES CBOX_HERMES_VERSION)
  CBOX_CONFIG_VALS=(on 0.20.0)
  _cbox_config_set_isolated
) > "$TMPBASE/set_ok.stdout" 2>"$TMPBASE/set_ok.stderr" || _fail "e2e success path: _cbox_config_set_isolated failed unexpectedly: $(cat "$TMPBASE/set_ok.stderr")"

grep -q '^CBOX_HERMES=on$' "$EFF/cbox.conf" || _fail "e2e success: CBOX_HERMES not updated in cbox.conf"
grep -q '^CBOX_HERMES_VERSION=0.20.0$' "$EFF/cbox.conf" || _fail "e2e success: CBOX_HERMES_VERSION not updated in cbox.conf"
[ "$(cat "$EFF/generated/marker.txt")" = "regenerated-marker" ] || _fail "e2e success: regen did not run (marker not updated)"
grep -q "regen-called eff=$EFF root=$ROOT" "$REGEN_LOG" || _fail "e2e success: regen was not called with the expected eff/root"
[ -f "$EFF/pending.apply" ] || _fail "e2e success: pending.apply not written"
grep -qx 'hermes=recreate' "$EFF/pending.apply" || _fail "e2e success: pending.apply missing hermes=recreate"

conf_sha_now="$(sha256sum "$EFF/cbox.conf" | awk '{print $1}')"
manifest_conf_sha="$(_cbox_manifest_field "$EFF/manifest.sha256" conf)"
[ "$conf_sha_now" = "$manifest_conf_sha" ] || _fail "e2e success: manifest conf sha does not match post-set cbox.conf"
[ -f "$ROOT/.cbox/runtime/cbox.conf.mirror" ] || _fail "e2e success: config set must refresh the in-project mirror"
cmp -s "$ROOT/.cbox/runtime/cbox.conf.mirror" "$EFF/cbox.conf" || _fail "e2e success: mirror must match the effective conf after config set"
_ok "e2e success: conf updated, regen ran, manifests stamped, mirror refreshed, pending.apply written"

ORDER_LOG="$TMPBASE/order.log"
_cbox_manifest_write() {
  echo "manifest-write-conf" >> "$ORDER_LOG"
  local eff="$1" root="$2" conf="$3" conf_sha gen_sha
  conf_sha="$(sha256sum "$conf" | awk '{print $1}')"
  gen_sha="$(_cbox_tpl_sha 2>/dev/null || echo stubgen)"
  {
    printf 'schema=1\n'
    printf 'workspace=%s\n' "$root"
    printf 'conf=%s\n' "$conf_sha"
    printf 'generators=%s\n' "$gen_sha"
  } > "$eff/manifest.sha256"
  printf '%s\n' "$root" > "$eff/workspace"
}
_cbox_manifest_write_generated() {
  echo "manifest-write-generated" >> "$ORDER_LOG"
  local eff="$1"
  printf 'compose=stub\n' >> "$eff/manifest.sha256"
}

_cbox_path_hash() { printf 'orderhash'; }
EFF2="$HOME/.config/cbox/projects/orderhash"
_setup_fixture_eff "$EFF2" "$ROOT"
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_GPU)
  CBOX_CONFIG_VALS=(1)
  _cbox_config_set_isolated
) > /dev/null 2>"$TMPBASE/order.stderr" || _fail "order test: set failed: $(cat "$TMPBASE/order.stderr")"

[ "$(sed -n 1p "$ORDER_LOG")" = "manifest-write-conf" ] || _fail "order: conf manifest not written first"
[ "$(sed -n 2p "$ORDER_LOG")" = "manifest-write-generated" ] || _fail "order: generated manifest not written second"
_ok "e2e order: conf manifest stamped before generated manifest (observable via stub logging)"

unset -f _cbox_manifest_write
unset -f _cbox_manifest_write_generated
source <(awk '/^_cbox_manifest_write\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh")
source <(awk '/^_cbox_manifest_write_generated\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh")

_gen_effective() {
  echo "cbox-config-test: simulated regen failure" >&2
  return 1
}

_cbox_path_hash() { printf 'failhash'; }
EFF3="$HOME/.config/cbox/projects/failhash"
_setup_fixture_eff "$EFF3" "$ROOT"
cp "$EFF3/cbox.conf" "$TMPBASE/pre-conf"
cp -a "$EFF3/generated" "$TMPBASE/pre-generated"
cp "$EFF3/manifest.sha256" "$TMPBASE/pre-manifest.sha256"

(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_HERMES)
  CBOX_CONFIG_VALS=(on)
  _cbox_config_set_isolated
) > "$TMPBASE/fail.stdout" 2>"$TMPBASE/fail.stderr" && _fail "e2e failure path: _cbox_config_set_isolated should have returned non-zero on regen failure"

cmp -s "$TMPBASE/pre-conf" "$EFF3/cbox.conf" || _fail "e2e failure: cbox.conf not byte-identical to pre-state after regen failure"
diff -rq "$TMPBASE/pre-generated" "$EFF3/generated" >/dev/null || _fail "e2e failure: generated/ not byte-identical to pre-state after regen failure"
cmp -s "$TMPBASE/pre-manifest.sha256" "$EFF3/manifest.sha256" || _fail "e2e failure: manifest.sha256 changed despite regen failure"
[ -f "$EFF3/pending.apply" ] && _fail "e2e failure: pending.apply should not have been written on failure"
grep -qi "restored" "$TMPBASE/fail.stderr" || _fail "e2e failure: failure message does not mention restoration"
_ok "e2e failure: conf and generated left byte-identical to pre-state, no manifest/pending written, failure reported"

DEPFAIL="$HOME/.config/cbox/projects/depfailhash"
mkdir -p "$DEPFAIL/generated"
{
  for v in $(_cbox_config_whitelist); do
    case "$v" in
      CBOX_MODE) printf 'CBOX_MODE=isolated\n' ;;
      CBOX_RESTART_POLICY) printf 'CBOX_RESTART_POLICY=no\n' ;;
      CBOX_WORKSPACES) printf 'CBOX_WORKSPACES=%q\n' "$ROOT" ;;
      *) printf '%s=%q\n' "$v" "" ;;
    esac
  done
} > "$DEPFAIL/cbox.conf"
mkdir -p "$DEPFAIL/generated"
echo original > "$DEPFAIL/generated/marker.txt"
_cbox_manifest_write "$DEPFAIL" "$ROOT" "$DEPFAIL/cbox.conf"
_cbox_manifest_write_generated "$DEPFAIL"
cp "$DEPFAIL/cbox.conf" "$TMPBASE/depfail-pre-conf"

_cbox_path_hash() { printf 'depfailhash'; }
_gen_effective() { echo "should not be called" >&2; return 1; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_RESTART_POLICY)
  CBOX_CONFIG_VALS=(unless-stopped)
  _cbox_config_set_isolated
) > "$TMPBASE/depfail.stdout" 2>"$TMPBASE/depfail.stderr" && _fail "dep-gate e2e: set should have been rejected (isolated mode forces restart-policy back)"
grep -qi "dependency rule" "$TMPBASE/depfail.stderr" || _fail "dep-gate e2e: rejection message missing: $(cat "$TMPBASE/depfail.stderr")"
cmp -s "$TMPBASE/depfail-pre-conf" "$DEPFAIL/cbox.conf" || _fail "dep-gate e2e: cbox.conf was modified despite dep-gate rejection"
_ok "dep-gate e2e: set rejected inside the transaction, conf left untouched"

_cbox_path_hash() { printf 'preservehash'; }
PRESERVE="$HOME/.config/cbox/projects/preservehash"
mkdir -p "$PRESERVE/generated"
{
  for v in $(_cbox_config_whitelist); do
    case "$v" in
      CBOX_MODE) printf 'CBOX_MODE=isolated\n' ;;
      CBOX_HERMES) printf 'CBOX_HERMES=off\n' ;;
      CBOX_HERMES_VERSION) printf 'CBOX_HERMES_VERSION=0.19.0\n' ;;
      CBOX_HERMES_PROVIDER) printf 'CBOX_HERMES_PROVIDER=local\n' ;;
      CBOX_GPU) printf 'CBOX_GPU=0\n' ;;
      CBOX_WORKSPACES) printf 'CBOX_WORKSPACES=%q\n' "$ROOT" ;;
      *) printf '%s=%q\n' "$v" "" ;;
    esac
  done
  printf 'CBOX_NAME=myprofile\n'
  printf 'CBOX_TPL_SHA=deadbeef\n'
} > "$PRESERVE/cbox.conf"
echo "original-marker" > "$PRESERVE/generated/marker.txt"
_cbox_manifest_write "$PRESERVE" "$ROOT" "$PRESERVE/cbox.conf"
_cbox_manifest_write_generated "$PRESERVE"

_gen_effective() { :; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_GPU)
  CBOX_CONFIG_VALS=(1)
  _cbox_config_set_isolated
) > /dev/null 2>"$TMPBASE/preserve.stderr" || _fail "preserve-extra-lines: set failed: $(cat "$TMPBASE/preserve.stderr")"

grep -qx 'CBOX_NAME=myprofile' "$PRESERVE/cbox.conf" || _fail "preserve-extra-lines: CBOX_NAME dropped from cbox.conf after set"
grep -qx 'CBOX_TPL_SHA=deadbeef' "$PRESERVE/cbox.conf" || _fail "preserve-extra-lines: CBOX_TPL_SHA dropped from cbox.conf after set"
grep -qx 'CBOX_GPU=1' "$PRESERVE/cbox.conf" || _fail "preserve-extra-lines: CBOX_GPU not updated"
_ok "preserve-extra-lines: non-whitelisted keys (CBOX_NAME, CBOX_TPL_SHA) survive a config set untouched"

_cbox_path_hash() { printf 'restoreatomichash'; }
RESTOREATOMIC="$HOME/.config/cbox/projects/restoreatomichash"
_setup_fixture_eff "$RESTOREATOMIC" "$ROOT"
cp "$RESTOREATOMIC/cbox.conf" "$TMPBASE/restoreatomic-pre-conf"
cp -a "$RESTOREATOMIC/generated" "$TMPBASE/restoreatomic-pre-generated"

WATCH_LOG="$TMPBASE/restoreatomic-watch.log"
: > "$WATCH_LOG"
_gen_effective() {
  local eff="$1"
  echo "changed-before-failure" > "$eff/generated/marker.txt"
  echo "cbox-config-test: simulated regen failure" >&2
  return 1
}
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_HERMES)
  CBOX_CONFIG_VALS=(on)
  _cbox_config_set_isolated &
  bg_pid=$!
  for _ in $(seq 1 200); do
    if [ -d "$RESTOREATOMIC/generated" ]; then
      echo present >> "$WATCH_LOG"
    else
      echo absent >> "$WATCH_LOG"
    fi
  done
  wait "$bg_pid"
) > "$TMPBASE/restoreatomic.stdout" 2>"$TMPBASE/restoreatomic.stderr" && _fail "restore-atomicity: set should have failed on simulated regen failure"

cmp -s "$TMPBASE/restoreatomic-pre-conf" "$RESTOREATOMIC/cbox.conf" || _fail "restore-atomicity: cbox.conf not byte-identical to pre-state after restore"
diff -rq "$TMPBASE/restoreatomic-pre-generated" "$RESTOREATOMIC/generated" >/dev/null || _fail "restore-atomicity: generated/ not byte-identical to pre-state after restore"
if grep -qx absent "$WATCH_LOG"; then
  _fail "restore-atomicity: generated/ observed absent during restore polling window"
fi
_ok "restore-atomicity: cbox.conf/generated restored via mktemp+mv and rename-swap, generated/ never observed absent by a concurrent poller"

_cbox_path_hash() { printf 'dictatenotehash'; }
DICTATENOTE="$HOME/.config/cbox/projects/dictatenotehash"
_setup_fixture_eff "$DICTATENOTE" "$ROOT"
_gen_effective() { :; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_CODEX_MCP)
  CBOX_CONFIG_VALS=(1)
  _cbox_config_set_isolated
) > "$TMPBASE/dictatenote.stdout" 2>"$TMPBASE/dictatenote.stderr" || _fail "dictate-note: set failed: $(cat "$TMPBASE/dictatenote.stderr")"
grep -q "wizard-only auto-deploy" "$TMPBASE/dictatenote.stdout" || _fail "dictate-note: report did not warn about codex-mcp's dictate:hooks wizard-only behavior"
_ok "dictate-note: config set report flags a dictate-gated section as wizard-only auto-deploy"

_cbox_path_hash() { printf 'machinescopehash'; }
MACHINESCOPE="$HOME/.config/cbox/projects/machinescopehash"
_setup_fixture_eff "$MACHINESCOPE" "$ROOT"
_gen_effective() { :; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_MODE=isolated
  HAVE_GLOBAL_CONF=1
  _cbox_config_in_container() { return 1; }
  _cbox_config_set_global() { printf 'global\n' > "$TMPBASE/machinescope.routed"; return 0; }
  _cbox_config_set_isolated() { printf 'isolated\n' > "$TMPBASE/machinescope.routed"; return 0; }
  _cbox_config_set "CBOX_OLLAMA_MODE=on"
) > "$TMPBASE/machinescope.stdout" 2>"$TMPBASE/machinescope.stderr" || _fail "machine-scope routing: set of a machine-scoped key must succeed from an isolated project: $(cat "$TMPBASE/machinescope.stderr")"
[ "$(cat "$TMPBASE/machinescope.routed" 2>/dev/null)" = global ] || _fail "machine-scope routing: a machine-scoped key must be written to the machine-level conf, not the per-project one (routed to: $(cat "$TMPBASE/machinescope.routed" 2>/dev/null))"
grep -q "^CBOX_OLLAMA_MODE='on'" "$MACHINESCOPE/cbox.conf" && _fail "machine-scope routing: CBOX_OLLAMA_MODE must never land in an isolated project's cbox.conf"
_ok "machine-scope routing: config set writes a machine-scoped key to the machine-level conf even from an isolated project"

(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_MODE=isolated
  HAVE_GLOBAL_CONF=1
  _cbox_config_in_container() { return 1; }
  _cbox_config_set_global() { printf 'global\n' > "$TMPBASE/machinemix.routed"; return 0; }
  _cbox_config_set_isolated() { printf 'isolated\n' > "$TMPBASE/machinemix.routed"; return 0; }
  _cbox_config_set "CBOX_OLLAMA_MODE=on" "CBOX_GPU=1"
) > "$TMPBASE/machinemix.stdout" 2>"$TMPBASE/machinemix.stderr" && _fail "machine-scope routing: a call mixing machine-scoped and project-scoped keys must be refused, not split silently"
grep -qi "different config files" "$TMPBASE/machinemix.stderr" || _fail "machine-scope routing: the mixed-call refusal should explain that the keys live in different config files: $(cat "$TMPBASE/machinemix.stderr")"
[ -f "$TMPBASE/machinemix.routed" ] && _fail "machine-scope routing: a refused mixed call must not write anything at all"
_ok "machine-scope routing: a mixed machine/project call is refused before any write"

_cbox_path_hash() { printf 'machinestriphash'; }
MACHINESTRIP="$HOME/.config/cbox/projects/machinestriphash"
_setup_fixture_eff "$MACHINESTRIP" "$ROOT"
grep -q '^CBOX_OLLAMA_MODE=' "$MACHINESTRIP/cbox.conf" || _fail "test setup: fixture should include a CBOX_OLLAMA_MODE line to prove the write-loop strips it"
_gen_effective() { :; }
(
  cd "$ROOT"
  HOME="$TMPBASE/home"
  export HOME
  CBOX_CONFIG_KEYS=(CBOX_GPU)
  CBOX_CONFIG_VALS=(1)
  _cbox_config_set_isolated
) > /dev/null 2>"$TMPBASE/machinestrip.stderr" || _fail "machine-scope strip: unrelated set failed: $(cat "$TMPBASE/machinestrip.stderr")"
grep -q '^CBOX_OLLAMA_MODE=' "$MACHINESTRIP/cbox.conf" && _fail "machine-scope strip: _cbox_config_set_isolated's whitelist write-loop should never re-write a machine-scoped key into the per-project file"
grep -qx 'CBOX_GPU=1' "$MACHINESTRIP/cbox.conf" || _fail "machine-scope strip: the actually-requested key (CBOX_GPU) should still be written"
_ok "machine-scope strip: _cbox_config_set_isolated's whitelist write-loop omits machine-scoped keys even on an unrelated set"

grep -qx "CBOX_CLAUDE_MODE=mount" "$MACHINESTRIP/cbox.conf" \
  || _fail "conf defaults (production path): _cbox_config_set_isolated must seed registry defaults before writing - the fixture stores CBOX_CLAUDE_MODE='' and it came out as $(grep '^CBOX_CLAUDE_MODE=' "$MACHINESTRIP/cbox.conf")"
_ok "conf defaults (production path): a real _cbox_config_set_isolated run fills a blank key from its registry default"


MACHINEROUTE="$TMPBASE/machineroute"
mkdir -p "$MACHINEROUTE"
INSTALL_DIR_SAVE="$INSTALL_DIR"
INSTALL_DIR="$MACHINEROUTE"
printf 'CBOX_MODE=isolated\n' > "$INSTALL_DIR/cbox.conf"
HAVE_GLOBAL_CONF=1
CBOX_MODE=isolated

_route_probe() {
  local -n _keys=$1
  local -n _vals=$2
  CBOX_CONFIG_KEYS=("${_keys[@]}")
  CBOX_CONFIG_VALS=("${_vals[@]}")
  local mode
  mode="$(_cbox_effective_mode)"
  if [ "$mode" = isolated ]; then
    local i key section n_machine=0 n_project=0
    for i in "${!CBOX_CONFIG_KEYS[@]}"; do
      key="${CBOX_CONFIG_KEYS[$i]}"
      if ! section="$(_cbox_config_section_for_var "$key")"; then
        n_project=$((n_project + 1))
        continue
      fi
      if [ "$(sec_get SEC_SCOPE "$section")" = machine ]; then
        n_machine=$((n_machine + 1))
      else
        n_project=$((n_project + 1))
      fi
    done
    if [ "$n_machine" -gt 0 ] && [ "$n_project" -gt 0 ]; then
      printf 'mixed'
      return 0
    fi
    if [ "$n_machine" -gt 0 ]; then
      printf 'global'
      return 0
    fi
  fi
  printf '%s' "$mode"
}

_mk=(CBOX_OLLAMA_MODE) _mv=(on)
[ "$(_route_probe _mk _mv)" = global ] \
  || _fail "machine-scope routing: a machine-scoped key must route to the global conf even when the effective mode is isolated"
_ok "machine-scope routing: machine-scoped key routes to the global conf from an isolated scope"

_pk=(CBOX_GPU) _pv=(1)
[ "$(_route_probe _pk _pv)" = isolated ] \
  || _fail "machine-scope routing: a project-scoped key must still route to the per-project conf"
_ok "machine-scope routing: project-scoped key still routes to the per-project conf"

_xk=(CBOX_OLLAMA_MODE CBOX_GPU) _xv=(on 1)
[ "$(_route_probe _xk _xv)" = mixed ] \
  || _fail "machine-scope routing: mixing machine-scoped and project-scoped keys in one call must be refused"
_ok "machine-scope routing: a mixed call is refused rather than split across two files"

INSTALL_DIR="$INSTALL_DIR_SAVE"


DEFAULTSFILL="$TMPBASE/defaultsfill"
mkdir -p "$DEFAULTSFILL"
printf 'CBOX_MODE=global\nCBOX_OLLAMA_MODE=off\n' > "$DEFAULTSFILL/cbox.conf"
(
  set -e
  unset CBOX_OLLAMA_IMAGE CBOX_OLLAMA_CONTEXT_LENGTH CBOX_OLLAMA_GPU CBOX_OLLAMA_STORE
  unset CBOX_OLLAMA_KV_CACHE_TYPE CBOX_OLLAMA_FLASH_ATTENTION CBOX_OLLAMA_KEEP_ALIVE
  CBOX_CONFIG_KEYS=(CBOX_OLLAMA_MODE)
  CBOX_CONFIG_VALS=(on)
  . "$DEFAULTSFILL/cbox.conf"
  _cbox_reg_conf_defaults
  _cbox_config_apply_staged_vars
  _cbox_reg_conf_write_whitelist "$DEFAULTSFILL/out.conf" 0 "$DEFAULTSFILL/cbox.conf"
)
grep -qx "CBOX_OLLAMA_MODE=on" "$DEFAULTSFILL/out.conf" \
  || _fail "conf defaults: the requested key must be written (got: $(grep '^CBOX_OLLAMA_MODE=' "$DEFAULTSFILL/out.conf"))"
grep -qE "^CBOX_OLLAMA_IMAGE=''$" "$DEFAULTSFILL/out.conf" \
  && _fail "conf defaults: a key absent from the source conf must be written with its registry default, never as an empty string - that silently breaks the very service being enabled"
grep -qE "^CBOX_OLLAMA_IMAGE=.*ollama/ollama" "$DEFAULTSFILL/out.conf" \
  || _fail "conf defaults: CBOX_OLLAMA_IMAGE should carry its registry default (got: $(grep '^CBOX_OLLAMA_IMAGE=' "$DEFAULTSFILL/out.conf"))"
grep -qE "^CBOX_OLLAMA_CONTEXT_LENGTH=('?)65536\1$" "$DEFAULTSFILL/out.conf" \
  || _fail "conf defaults: CBOX_OLLAMA_CONTEXT_LENGTH should carry its registry default (got: $(grep '^CBOX_OLLAMA_CONTEXT_LENGTH=' "$DEFAULTSFILL/out.conf"))"
_ok "conf defaults: a sparse conf is filled from registry defaults before the whitelist write, not blanked"


SCOPEFLIP_VARS=" $(_cbox_machine_scoped_vars | sort | tr '\n' ' ') "
case "$SCOPEFLIP_VARS" in
  *" CBOX_LOCAL_MODEL_URL "*) ;;
  *) _fail "machine scope: CBOX_LOCAL_MODEL_URL must be machine-scoped - the endpoint is a fact about the host and every project reads the same one" ;;
esac
_ok "machine scope: the local-model keys are machine-scoped"

grep -q '_cbox_strip_machine_scoped_vars "$eff/cbox.conf"' "$INSTALL_DIR/lib/cbox-setup.sh" \
  || _fail "machine scope: the derivation path must strip machine-scoped keys from a project conf - that strip is the ONLY writer that removes them, so a project carrying stale copies is repaired by the re-derive a template bump already forces, and nothing writes to a project conf from the normal run path"
_ok "machine scope: stale project copies are cleared by the derivation strip, not by a writer on the run path"

echo "PASS: all cbox config tests"
