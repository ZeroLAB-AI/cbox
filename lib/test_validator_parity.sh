#!/usr/bin/env bash
set -uo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

FAIL_COUNT=0
CASE_COUNT=0

_fail() {
  echo "FAIL: $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

_ok() {
  echo "ok: $1"
}

OLD_SNAPSHOT="$INSTALL_DIR/lib/fixtures/cbox_validator.pre_registry_snapshot.sh"
[ -f "$OLD_SNAPSHOT" ] || { echo "FAIL: old validator snapshot not found at $OLD_SNAPSHOT" >&2; exit 1; }

OLD_RUNNER="$TMPBASE/old_runner.sh"
cat > "$OLD_RUNNER" << EOF
#!/usr/bin/env bash
set -uo pipefail
INSTALL_DIR="$INSTALL_DIR"
source "\$INSTALL_DIR/templates/generators.sh"
source "$OLD_SNAPSHOT"
_cbox_config_validate_var "\$1" "\$2" >/dev/null 2>&1
exit "\$?"
EOF
chmod +x "$OLD_RUNNER"

NEW_RUNNER="$TMPBASE/new_runner.sh"
cat > "$NEW_RUNNER" << EOF
#!/usr/bin/env bash
set -uo pipefail
INSTALL_DIR="$INSTALL_DIR"
source "\$INSTALL_DIR/templates/generators.sh"
source "\$INSTALL_DIR/templates/validator_lib.sh"
source "\$INSTALL_DIR/templates/validator_dispatch.sh"
_cbox_reg_validate_var "\$1" "\$2" >/dev/null 2>&1
exit "\$?"
EOF
chmod +x "$NEW_RUNNER"

CASES_FILE="$TMPBASE/cases.tsv"

_case() {
  printf '%s\t%s\n' "$1" "$2" >> "$CASES_FILE"
}

: > "$CASES_FILE"

_case CBOX_MODE global
_case CBOX_MODE isolated
_case CBOX_MODE bogus
_case CBOX_MODE ""

_case CBOX_SESSION_SCOPE isolated
_case CBOX_SESSION_SCOPE global
_case CBOX_SESSION_SCOPE bogus

_case CBOX_BASE_DIGEST_TTL 0
_case CBOX_BASE_DIGEST_TTL 3600
_case CBOX_BASE_DIGEST_TTL -1
_case CBOX_BASE_DIGEST_TTL abc
_case CBOX_BASE_DIGEST_TTL ""

_case CBOX_CLAUDE_MODE mount
_case CBOX_CLAUDE_MODE volume
_case CBOX_CLAUDE_MODE bogus
_case CBOX_CODEX_MODE mount
_case CBOX_CODEX_MODE volume
_case CBOX_CODEX_MODE bogus

_case CBOX_CLAUDE_PATH ""
_case CBOX_CLAUDE_PATH "/home/user/.claude"
_case CBOX_CLAUDE_PATH "~/claude"
_case CBOX_CLAUDE_PATH "~"
_case CBOX_CLAUDE_PATH "relative/path"
_case CBOX_CLAUDE_PATH "/has space"
_case CBOX_CODEX_PATH "/home/user/.codex"
_case CBOX_CODEX_PATH "relative"
_case CBOX_VENV_PATH "/opt/venv"
_case CBOX_VENV_PATH "not-absolute"
_case CBOX_SSH_AGENT_DIR "/run/user/1000"
_case CBOX_SSH_AGENT_DIR "not-absolute"

_case CBOX_CLAUDE_BACKUP y
_case CBOX_CLAUDE_BACKUP c
_case CBOX_CLAUDE_BACKUP n
_case CBOX_CLAUDE_BACKUP bogus
_case CBOX_CODEX_BACKUP y
_case CBOX_CODEX_BACKUP bogus

_case CBOX_WORKSPACES "/a /b"
_case CBOX_WORKSPACES "/a relb"
_case CBOX_WORKSPACES ""

_case CBOX_WORKDIR ""
_case CBOX_WORKDIR "/home/user"
_case CBOX_WORKDIR "relative"

_case CBOX_VENV_MODE none
_case CBOX_VENV_MODE host
_case CBOX_VENV_MODE volume
_case CBOX_VENV_MODE bogus

_case CBOX_GPU 0
_case CBOX_GPU 1
_case CBOX_GPU 2

_case CBOX_EGRESS_MODE off
_case CBOX_EGRESS_MODE allowlist
_case CBOX_EGRESS_MODE blocklist
_case CBOX_EGRESS_MODE bogus
_case CBOX_EGRESS_APPLIED 0
_case CBOX_EGRESS_APPLIED 1
_case CBOX_EGRESS_APPLIED 2

_case CBOX_NETACCESS_MODE off
_case CBOX_NETACCESS_MODE socks
_case CBOX_NETACCESS_MODE bogus
_case CBOX_NETACCESS_APPLIED 0
_case CBOX_NETACCESS_APPLIED 1
_case CBOX_NETACCESS_APPLIED bogus

_case CBOX_NETACCESS_SCOPE all
_case CBOX_NETACCESS_SCOPE list
_case CBOX_NETACCESS_SCOPE ""
_case CBOX_NETACCESS_SCOPE bogus

_case CBOX_NETACCESS_NETWORKS "mynet"
_case CBOX_NETACCESS_NETWORKS "my_net-1.x"
_case CBOX_NETACCESS_NETWORKS "-badstart"
_case CBOX_NETACCESS_NETWORKS "bad*char"
_case CBOX_NETACCESS_NETWORKS ""

_case CBOX_NETACCESS_CIDRS "10.0.0.0/8"
_case CBOX_NETACCESS_CIDRS "10.0.0.0/24"
_case CBOX_NETACCESS_CIDRS "0.0.0.0/8"
_case CBOX_NETACCESS_CIDRS "not-a-cidr"
_case CBOX_NETACCESS_CIDRS "256.0.0.0/8"
_case CBOX_NETACCESS_CIDRS ""

_case CBOX_NETACCESS_SOCKS_PORT 1080
_case CBOX_NETACCESS_SOCKS_PORT 0
_case CBOX_NETACCESS_SOCKS_PORT 65535
_case CBOX_NETACCESS_SOCKS_PORT 65536
_case CBOX_NETACCESS_SOCKS_PORT abc

_case CBOX_NETACCESS_EXEC_MODE off
_case CBOX_NETACCESS_EXEC_MODE scoped
_case CBOX_NETACCESS_EXEC_MODE bogus
_case CBOX_NETACCESS_EXEC_WORKSPACE_GUARD off
_case CBOX_NETACCESS_EXEC_WORKSPACE_GUARD on
_case CBOX_NETACCESS_EXEC_WORKSPACE_GUARD bogus

_case CBOX_NETACCESS_EXEC_TIMEOUT 1
_case CBOX_NETACCESS_EXEC_TIMEOUT 3600
_case CBOX_NETACCESS_EXEC_TIMEOUT 0
_case CBOX_NETACCESS_EXEC_TIMEOUT 3601
_case CBOX_NETACCESS_EXEC_MAX_BYTES 1024
_case CBOX_NETACCESS_EXEC_MAX_BYTES 16777216
_case CBOX_NETACCESS_EXEC_MAX_BYTES 1023
_case CBOX_NETACCESS_EXEC_MAX_BYTES 16777217

_case CBOX_HOST_ROUTE_MODE off
_case CBOX_HOST_ROUTE_MODE host-proxy
_case CBOX_HOST_ROUTE_MODE bogus
_case CBOX_HOST_ROUTE_APPLIED 0
_case CBOX_HOST_ROUTE_APPLIED 1
_case CBOX_HOST_ROUTE_APPLIED bogus

_case CBOX_HOST_PROXY_URL ""
_case CBOX_HOST_PROXY_URL "http://host:3128"
_case CBOX_HOST_PROXY_URL "https://host:3128"
_case CBOX_HOST_PROXY_URL "ftp://host"
_case CBOX_HOST_PROXY_URL "host:3128"

_case CBOX_HOST_PROXY_ADDR_MODE host-gateway
_case CBOX_HOST_PROXY_ADDR_MODE explicit
_case CBOX_HOST_PROXY_ADDR_MODE bogus
_case CBOX_HOST_GATEWAY_ALIAS off
_case CBOX_HOST_GATEWAY_ALIAS on
_case CBOX_HOST_GATEWAY_ALIAS bogus

_case CBOX_SSH_MODE none
_case CBOX_SSH_MODE host-agent
_case CBOX_SSH_MODE container-keys
_case CBOX_SSH_MODE mixed
_case CBOX_SSH_MODE bogus

_case CBOX_BASHRC 0
_case CBOX_BASHRC 1
_case CBOX_BASHRC 2

_case CBOX_MCP_SERVERS "all"
_case CBOX_MCP_SERVERS "anything goes here !!"
_case CBOX_AGENTS "all"
_case CBOX_AGENTS "whatever"

_case CBOX_CODEX_PROGRESS_MODE off
_case CBOX_CODEX_PROGRESS_MODE shim
_case CBOX_CODEX_PROGRESS_MODE bogus

_case CBOX_LOCAL_MODEL off
_case CBOX_LOCAL_MODEL on
_case CBOX_LOCAL_MODEL bogus
_case CBOX_LOCAL_MODEL_URL ""
_case CBOX_LOCAL_MODEL_URL "http://localhost:11434"
_case CBOX_LOCAL_MODEL_URL "bogus"
_case CBOX_LOCAL_MODEL_NAME "qwen2.5:7b"
_case CBOX_LOCAL_MODEL_NAME ""

_case CBOX_HERMES off
_case CBOX_HERMES on
_case CBOX_HERMES bogus
_case CBOX_HERMES_VERSION latest
_case CBOX_HERMES_VERSION "1.2"
_case CBOX_HERMES_VERSION "1.2.3"
_case CBOX_HERMES_VERSION "1.2.3.4"
_case CBOX_HERMES_VERSION "1"
_case CBOX_HERMES_VERSION "1.2.3.4.5"
_case CBOX_HERMES_VERSION "v1.2.3"
_case CBOX_HERMES_PROVIDER local
_case CBOX_HERMES_PROVIDER nous
_case CBOX_HERMES_PROVIDER openrouter
_case CBOX_HERMES_PROVIDER openai
_case CBOX_HERMES_PROVIDER anthropic
_case CBOX_HERMES_PROVIDER bogus
_case CBOX_HERMES_MODEL_URL ""
_case CBOX_HERMES_MODEL_URL "http://x"
_case CBOX_HERMES_MODEL_URL "bogus"
_case CBOX_HERMES_MODEL_NAME "anything"

_case CBOX_HERMES_DELEGATE off
_case CBOX_HERMES_DELEGATE on
_case CBOX_HERMES_DELEGATE bogus
_case CBOX_HERMES_DELEGATE_PROVIDER ""
_case CBOX_HERMES_DELEGATE_PROVIDER local
_case CBOX_HERMES_DELEGATE_PROVIDER bogus
_case CBOX_HERMES_DELEGATE_BASE_URL ""
_case CBOX_HERMES_DELEGATE_BASE_URL "http://x"
_case CBOX_HERMES_DELEGATE_BASE_URL "bogus"
_case CBOX_HERMES_DELEGATE_MODEL "anything"
_case CBOX_HERMES_DELEGATE_MAX_CONCURRENCY 0
_case CBOX_HERMES_DELEGATE_MAX_CONCURRENCY 16
_case CBOX_HERMES_DELEGATE_MAX_CONCURRENCY 17
_case CBOX_HERMES_DELEGATE_MAX_CONCURRENCY -1
_case CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC ""
_case CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC 100
_case CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC abc
_case CBOX_HERMES_DELEGATE_LOCK_DIR ""
_case CBOX_HERMES_DELEGATE_LOCK_DIR "/tmp/locks"
_case CBOX_HERMES_DELEGATE_LOCK_DIR "/tmp/has space"
_case CBOX_HERMES_DELEGATE_LOCK_DIR "~/locks"
_case CBOX_HERMES_DELEGATE_LOCK_DIR "relative"
_case OLLAMA_NUM_PARALLEL ""
_case OLLAMA_NUM_PARALLEL 4
_case OLLAMA_NUM_PARALLEL abc
_case CBOX_HERMES_DELEGATE_MODE ""
_case CBOX_HERMES_DELEGATE_MODE qa
_case CBOX_HERMES_DELEGATE_MODE bogus
_case CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS "terminal,file,web"
_case CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS ""

_case CBOX_LIMIT_AUTORESUME off
_case CBOX_LIMIT_AUTORESUME on
_case CBOX_LIMIT_AUTORESUME bogus
_case CBOX_LIMIT_RESUME_DELAY 300
_case CBOX_LIMIT_RESUME_DELAY abc
_case CBOX_LIMIT_RESUME_STAGGER 30
_case CBOX_LIMIT_RESUME_MAX_PER_DAY 10
_case CBOX_LIMIT_RESUME_PROMPT "pokracuj"
_case CBOX_LIMIT_RESUME_PROMPT ""

_case CBOX_CODEX_MCP 0
_case CBOX_CODEX_MCP 1
_case CBOX_CODEX_MCP 2

_case CBOX_HISTORY 0
_case CBOX_HISTORY 1
_case CBOX_HISTORY bogus
_case CBOX_GIT 0
_case CBOX_GIT 1
_case CBOX_DIARY 0
_case CBOX_DIARY 1
_case CBOX_OPEN_QUESTIONS 0
_case CBOX_OPEN_QUESTIONS 1

_case CBOX_CONTEXT_PROFILE full
_case CBOX_CONTEXT_PROFILE light
_case CBOX_CONTEXT_PROFILE bogus

_case CBOX_GITCONFIG 0
_case CBOX_GITCONFIG 1
_case CBOX_GITCONFIG bogus

_case CBOX_APT_EXTRA "curl git"
_case CBOX_APT_EXTRA "lib32-foo"
_case CBOX_APT_EXTRA ".badstart"
_case CBOX_APT_EXTRA "bad!char"
_case CBOX_APT_EXTRA ""

_case CBOX_CLAUDE_TARGET stable
_case CBOX_CLAUDE_TARGET latest
_case CBOX_CLAUDE_TARGET "1.2.3"
_case CBOX_CLAUDE_TARGET "1.2.3-beta.1"
_case CBOX_CLAUDE_TARGET "bogus"
_case CBOX_CODEX_VERSION latest
_case CBOX_CODEX_VERSION "1.2.3"
_case CBOX_CODEX_VERSION "1.2.3-alpha"
_case CBOX_CODEX_VERSION "1.2.3-alpha.1"
_case CBOX_CODEX_VERSION "1.2.3-rc1"
_case CBOX_CODEX_VERSION "bogus"
_case CBOX_CODEX_TARGET ""
_case CBOX_CODEX_TARGET "anything"

_case CBOX_BINS_SCOPE global
_case CBOX_BINS_SCOPE pinned
_case CBOX_BINS_SCOPE bogus

_case CBOX_RESTART_POLICY no
_case CBOX_RESTART_POLICY unless-stopped
_case CBOX_RESTART_POLICY always

_case CBOX_OLLAMA_MODE off
_case CBOX_OLLAMA_MODE on
_case CBOX_OLLAMA_MODE bogus
_case CBOX_OLLAMA_IMAGE "ollama/ollama:0.32.5"
_case CBOX_OLLAMA_IMAGE ""
_case CBOX_OLLAMA_IMAGE "bad image ref"
_case CBOX_OLLAMA_GPU off
_case CBOX_OLLAMA_GPU cdi
_case CBOX_OLLAMA_GPU bogus
_case CBOX_OLLAMA_STORE dedicated
_case CBOX_OLLAMA_STORE shared
_case CBOX_OLLAMA_STORE bogus
_case CBOX_OLLAMA_STORE_PATH ""
_case CBOX_OLLAMA_STORE_PATH "/data/ollama"
_case CBOX_OLLAMA_STORE_PATH "relative"
_case CBOX_OLLAMA_PORT 11434
_case CBOX_OLLAMA_PORT 0
_case CBOX_OLLAMA_PORT 65536
_case CBOX_OLLAMA_NUM_PARALLEL 1
_case CBOX_OLLAMA_NUM_PARALLEL 0
_case CBOX_OLLAMA_NUM_PARALLEL abc

_case CBOX_WG_MODE off
_case CBOX_WG_MODE server
_case CBOX_WG_MODE client
_case CBOX_WG_MODE both
_case CBOX_WG_MODE bogus
_case CBOX_WG_IMPL auto
_case CBOX_WG_IMPL kernel
_case CBOX_WG_IMPL userspace
_case CBOX_WG_IMPL bogus

_case CBOX_WG_ADDRESS ""
_case CBOX_WG_ADDRESS "10.90.0.1/24"
_case CBOX_WG_ADDRESS "10.90.0.1/8"
_case CBOX_WG_ADDRESS "10.90.0.1/7"
_case CBOX_WG_ADDRESS "10.90.0.1"
_case CBOX_WG_ADDRESS "bogus"
_case CBOX_WG_LISTEN_PORT 51820
_case CBOX_WG_LISTEN_PORT 0
_case CBOX_WG_LISTEN_PORT 65536
_case CBOX_WG_PUBLISH_ADDR ""
_case CBOX_WG_PUBLISH_ADDR "0.0.0.0"
_case CBOX_WG_PUBLISH_ADDR "1.2.3.4"
_case CBOX_WG_PUBLISH_ADDR "1.2.3.4/24"
_case CBOX_WG_PUBLISH_ADDR "not-an-ip"
_case CBOX_WG_PEER_ENDPOINT ""
_case CBOX_WG_PEER_ENDPOINT "host.example.com:51820"
_case CBOX_WG_PEER_ENDPOINT "1.2.3.4:51820"
_case CBOX_WG_PEER_ENDPOINT "no-port"
_case CBOX_WG_PEER_ENDPOINT "host:notaport"
_case CBOX_WG_PEER_PUBKEY ""
_case CBOX_WG_PEER_PUBKEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
_case CBOX_WG_PEER_PUBKEY "tooshort="
_case CBOX_WG_PEER_PUBKEY "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
_case CBOX_WG_PEER_ADDRESS ""
_case CBOX_WG_PEER_ADDRESS "10.90.0.2/32"
_case CBOX_WG_PEER_ADDRESS "10.90.0.2/24"
_case CBOX_WG_PEER_ADDRESS "bogus"
_case CBOX_WG_KEEPALIVE 0
_case CBOX_WG_KEEPALIVE 25
_case CBOX_WG_KEEPALIVE abc

_case CBOX_NOT_A_REAL_VAR "anything"
_case UNKNOWN_KEY "value"

_case CBOX_MODE $'has\nnewline'
_case CBOX_MODE $'has\x01ctrl'
_case CBOX_LIMIT_RESUME_PROMPT $'bad\x02char'

NEW_CASES_FILE="$TMPBASE/new_cases.tsv"
_new_case() {
  local v="$2"
  [ -n "$v" ] || v='<EMPTY>'
  printf '%s\t%s\t%s\n' "$1" "$v" "$3" >> "$NEW_CASES_FILE"
}
: > "$NEW_CASES_FILE"

_new_case CBOX_NAME "cbox" accept
_new_case CBOX_NAME "myprofile" accept
_new_case CBOX_NAME "" reject

_new_case CBOX_AUTOUPDATE on accept
_new_case CBOX_AUTOUPDATE off accept
_new_case CBOX_AUTOUPDATE bogus reject

_new_case CBOX_AUTOUPDATE_TTL_HOURS 24 accept
_new_case CBOX_AUTOUPDATE_TTL_HOURS 0 accept
_new_case CBOX_AUTOUPDATE_TTL_HOURS -1 reject
_new_case CBOX_AUTOUPDATE_TTL_HOURS abc reject

_new_case CBOX_DNS_MODE docker accept
_new_case CBOX_DNS_MODE public accept
_new_case CBOX_DNS_MODE stub accept
_new_case CBOX_DNS_MODE bogus reject

_new_case CBOX_DNS_SERVERS "1.1.1.1 8.8.8.8" accept
_new_case CBOX_DNS_SERVERS "9.9.9.9" accept
_new_case CBOX_DNS_SERVERS "" accept
_new_case CBOX_DNS_SERVERS "not-an-ip" reject
_new_case CBOX_DNS_SERVERS "1.1.1.1 bogus" reject

_new_case CBOX_DNS_STUB_IP "" accept
_new_case CBOX_DNS_STUB_IP "127.0.0.53" accept
_new_case CBOX_DNS_STUB_IP "not-an-ip" reject

_new_case CBOX_CLIPBOARD_MODE off accept
_new_case CBOX_CLIPBOARD_MODE bridge accept
_new_case CBOX_CLIPBOARD_MODE bogus reject

while IFS=$'\t' read -r key val want; do
  CASE_COUNT=$((CASE_COUNT + 1))
  [ "$val" != '<EMPTY>' ] || val=''
  new_rc=0
  "$NEW_RUNNER" "$key" "$val" || new_rc=$?
  new_verdict="reject"; [ "$new_rc" -eq 0 ] && new_verdict="accept"
  if [ "$new_verdict" != "$want" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    _fail "new-section validator: $key='$val' expected=$want got=$new_verdict"
  fi
done < "$NEW_CASES_FILE"
_ok "new-section validators (autoupdate/dns/clipboard/CBOX_NAME): verdicts match intended semantics for $(wc -l < "$NEW_CASES_FILE" | tr -d ' ') cases"

DIVERGENCES=0
while IFS=$'\t' read -r key val; do
  CASE_COUNT=$((CASE_COUNT + 1))
  old_rc=0
  "$OLD_RUNNER" "$key" "$val" || old_rc=$?
  new_rc=0
  "$NEW_RUNNER" "$key" "$val" || new_rc=$?
  old_verdict="reject"; [ "$old_rc" -eq 0 ] && old_verdict="accept"
  new_verdict="reject"; [ "$new_rc" -eq 0 ] && new_verdict="accept"
  if [ "$old_verdict" != "$new_verdict" ]; then
    DIVERGENCES=$((DIVERGENCES + 1))
    _fail "divergence: $key='$val' old=$old_verdict new=$new_verdict"
  fi
done < "$CASES_FILE"

if [ "$DIVERGENCES" -eq 0 ]; then
  _ok "validator parity: $CASE_COUNT (key,value) cases, old and new verdicts identical for every case"
else
  echo "FAIL: $DIVERGENCES divergence(s) out of $CASE_COUNT cases" >&2
  exit 1
fi

REG_VARS_FILE="$TMPBASE/reg_vars.txt"
python3 "$INSTALL_DIR/etc/registry/settings_registry.py" vars "$INSTALL_DIR/etc/registry/settings.json" | sort > "$REG_VARS_FILE"

CASE_KEYS_FILE="$TMPBASE/case_keys.txt"
{
  cut -f1 "$CASES_FILE" | grep -v '^CBOX_NOT_A_REAL_VAR$' | grep -v '^UNKNOWN_KEY$'
  cut -f1 "$NEW_CASES_FILE"
} | sort -u > "$CASE_KEYS_FILE"

MISSING_COVERAGE="$(comm -23 "$REG_VARS_FILE" "$CASE_KEYS_FILE")"
if [ -n "$MISSING_COVERAGE" ]; then
  _fail "registry variables with no parity test case: $MISSING_COVERAGE"
else
  _ok "every registry variable has at least one parity test case"
fi

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "PASS: all validator parity checks ($CASE_COUNT cases)"
else
  echo "FAIL: $FAIL_COUNT check(s) failed" >&2
  exit 1
fi
