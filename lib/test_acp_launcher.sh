set -euo pipefail

for v in $(compgen -v CBOX_); do
  unset "$v"
done

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$TMPBASE"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }

HOME="$TMPBASE/home"
export HOME
PROJ="$TMPBASE/project"
EXTRA="$TMPBASE/extra"
mkdir -p "$PROJ" "$EXTRA" "$HOME" "$TMPBASE/bin"
git -C "$PROJ" init -q
hash="$(printf '%s' "$PROJ" | sha256sum)"
eff="$HOME/.config/cbox/projects/${hash:0:12}"
mkdir -p "$eff"
printf 'CBOX_WORKSPACES="%s %s"\n' "$PROJ" "$EXTRA" > "$eff/cbox.conf"
printf '%s' "$PROJ" > "$eff/workspace"

REAL_PYTHON="$(command -v python3)"
export REAL_PYTHON
ACP_ARGS="$TMPBASE/proxy.args"
export ACP_ARGS
cat > "$TMPBASE/bin/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "$INSTALL_DIR/lib/cbox_acp_proxy.py" ]; then
  printf '%s\n' "$@" > "$ACP_ARGS"
  exit 0
fi
exec "$REAL_PYTHON" "$@"
EOF
cat > "$TMPBASE/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_ARGS"
printf 'ACP response\n'
EOF
chmod +x "$TMPBASE/bin/python3" "$TMPBASE/bin/docker"
DOCKER_ARGS="$TMPBASE/docker.args"
export DOCKER_ARGS INSTALL_DIR
PATH="$TMPBASE/bin:$PATH"
export PATH

(cd "$PROJ" && "$INSTALL_DIR/cbox" acp hermes) > "$TMPBASE/acp.out" 2> "$TMPBASE/acp.err" || fail "acp hermes did not invoke proxy"
[ ! -s "$TMPBASE/acp.out" ] || fail "proxy stub wrote unexpected output"
grep -qxF -- '--root' "$ACP_ARGS" || fail "proxy root option missing"
grep -qxF -- "$PROJ" "$ACP_ARGS" || fail "project root missing"
grep -qxF -- '--project-root' "$ACP_ARGS" || fail "bound project root option missing"
grep -qxF -- '--engine' "$ACP_ARGS" || fail "proxy engine option missing"
grep -qxF -- "$EXTRA" "$ACP_ARGS" || fail "extra workspace root missing"
grep -qxF -- "$eff/acp-blocked.log" "$ACP_ARGS" || fail "proxy log path missing"
grep -qxF -- 'acp-backend' "$ACP_ARGS" || fail "backend verb missing"
ok "proxy receives configured roots, log path, and backend command"

(cd "$PROJ" && "$INSTALL_DIR/cbox" acp claude) > "$TMPBASE/acp.out" 2> "$TMPBASE/acp.err" || fail "acp claude did not invoke proxy"
grep -qxF -- 'claude' "$ACP_ARGS" || fail "Claude backend engine missing"
ok "claude launcher invokes the project proxy"

(cd "$PROJ" && "$INSTALL_DIR/cbox" acp codex) > "$TMPBASE/acp.out" 2> "$TMPBASE/acp.err" || fail "acp codex did not invoke proxy"
grep -qxF -- 'codex' "$ACP_ARGS" || fail "Codex backend engine missing"
ok "codex launcher invokes the project proxy"

printf 'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n' > "$TMPBASE/codex-profile.toml"
python3 "$INSTALL_DIR/etc/adapters/codex.py" hooks-json "$TMPBASE/hooks" off > "$TMPBASE/codex-hooks.json"
python3 "$INSTALL_DIR/lib/codex_acp_config.py" "$TMPBASE/codex-profile.toml" "$TMPBASE/codex-hooks.json" > "$TMPBASE/codex-config.json"
python3 - "$TMPBASE/codex-config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
assert c['approval_policy']=='never'
assert c['sandbox_mode']=='danger-full-access'
assert 'PreToolUse' not in c['hooks']
PY
printf '[features]\ncodex_hooks = true\n' >> "$TMPBASE/codex-profile.toml"
python3 "$INSTALL_DIR/etc/adapters/codex.py" hooks-json "$TMPBASE/hooks" on > "$TMPBASE/codex-hooks.json"
python3 "$INSTALL_DIR/lib/codex_acp_config.py" "$TMPBASE/codex-profile.toml" "$TMPBASE/codex-hooks.json" > "$TMPBASE/codex-config.json"
python3 - "$TMPBASE/codex-config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
assert c['features']['codex_hooks'] is True
assert c['hooks']['PreToolUse'][0]['hooks'][0]['command'].endswith('/codex_guard_bridge.py')
PY
python3 "$INSTALL_DIR/etc/adapters/codex.py" hooks-json "$TMPBASE/hooks" off > "$TMPBASE/codex-hooks.json"
if python3 "$INSTALL_DIR/lib/codex_acp_config.py" "$TMPBASE/codex-profile.toml" "$TMPBASE/codex-hooks.json" > "$TMPBASE/codex-config.json" 2>/dev/null; then
  fail "Codex ACP accepted a stale hooks gate"
fi
ok "Codex ACP config follows the managed profile and hook gate"

rc=0
(cd "$TMPBASE" && "$INSTALL_DIR/cbox" acp hermes) > "$TMPBASE/out" 2> "$TMPBASE/err" || rc=$?
[ "$rc" = 2 ] || fail "unconfigured cwd exit code is $rc"
grep -q 'not inside a cbox project or workspace' "$TMPBASE/err" || fail "unconfigured cwd message missing"
ok "unconfigured cwd is refused with exit 2"

extract_fn() { awk -v fn="$2" '$0 == fn"() {", $0 == "}"' "$1"; }
eval "$(extract_fn "$INSTALL_DIR/cbox" acp_backend)"
eval "$(extract_fn "$INSTALL_DIR/cbox" _session_run)"
eval "$(extract_fn "$INSTALL_DIR/cbox" _bins_want)"
eval "$(extract_fn "$INSTALL_DIR/cbox" _bins_stale)"

_bins_cache_get() { printf 'volume|hermes|latest|1.0|1'; }
_bins_cache_field() {
  case "$2" in
    tool) printf 'hermes' ;;
    want) printf 'latest' ;;
  esac
}
CBOX_HERMES_VERSION=latest
_bins_stale volume hermes "$(_bins_want hermes)" || fail "old Hermes cache did not trigger ACP dependency reinstall"
unset CBOX_HERMES_VERSION
ok "old Hermes bins cache is stale for the ACP dependency revision"

_bins_cache_get() { printf 'volume|claude|stable|1.0|1'; }
_bins_cache_field() {
  case "$2" in
    tool) printf 'claude' ;;
    want) printf 'stable' ;;
  esac
}
_bins_stale volume claude "$(_bins_want claude)" || fail "old Claude cache did not trigger ACP dependency reinstall"
ok "old Claude bins cache is stale for the ACP dependency revision"

_bins_cache_get() { printf 'volume|codex|0.162.1|1.0|1'; }
_bins_cache_field() {
  case "$2" in
    tool) printf 'codex' ;;
    want) printf '0.162.1' ;;
  esac
}
CBOX_CODEX_VERSION=0.162.1
_bins_stale volume codex "$(_bins_want codex)" || fail "old Codex cache did not trigger ACP dependency reinstall"
unset CBOX_CODEX_VERSION
ok "old Codex bins cache is stale for the ACP dependency revision"

eval "$(extract_fn "$INSTALL_DIR/install-bins.sh" _claude_acp_ready)"
ACPROOT="$TMPBASE/acp-claude"
ACPSRC="$INSTALL_DIR/acp-claude"
ACPNODE_VERSION=22.23.3
ACPADAPTER_VERSION=0.90.0
ACP_PACKAGE="$ACPROOT/adapter/node_modules/@agentclientprotocol/claude-agent-acp"
mkdir -p "$ACPROOT/node/bin" "$ACP_PACKAGE/dist"
cat > "$ACPROOT/node/bin/node" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --version ]; then
  printf 'v22.23.3\n'
elif [[ "${3:-}" = *codex-acp* ]]; then
  printf '2.2.2\n'
else
  printf '0.90.0\n'
fi
EOF
chmod +x "$ACPROOT/node/bin/node"
printf '{"version":"0.90.0"}\n' > "$ACP_PACKAGE/package.json"
: > "$ACP_PACKAGE/dist/index.js"
cp "$ACPSRC/package-lock.json" "$ACPROOT/adapter/package-lock.json"
printf '%s\n%s\n%s\n%s\n' "$ACPNODE_VERSION" "$ACPADAPTER_VERSION" \
  "$(sha256sum "$ACPROOT/node/bin/node" | awk '{print $1}')" \
  "$(sha256sum "$ACPROOT/adapter/package-lock.json" | awk '{print $1}')" > "$ACPROOT/.cbox-acp-stamp"
_claude_acp_ready || fail "pinned ACP install was rejected"
eval "$(extract_fn "$INSTALL_DIR/install-bins.sh" _codex_acp_ready)"
CDACPROOT="$TMPBASE/acp-codex"
CDACPSRC="$INSTALL_DIR/acp-codex"
CDACPADAPTER_VERSION=2.2.2
CDACP_PACKAGE="$CDACPROOT/adapter/node_modules/@agentclientprotocol/codex-acp"
mkdir -p "$CDACP_PACKAGE/dist"
printf '{"version":"2.2.2"}\n' > "$CDACP_PACKAGE/package.json"
: > "$CDACP_PACKAGE/dist/index.js"
cp "$CDACPSRC/package-lock.json" "$CDACPROOT/adapter/package-lock.json"
printf '%s\n%s\n%s\n%s\n' "$ACPNODE_VERSION" "$CDACPADAPTER_VERSION" \
  "$(sha256sum "$ACPROOT/node/bin/node" | awk '{print $1}')" \
  "$(sha256sum "$CDACPROOT/adapter/package-lock.json" | awk '{print $1}')" > "$CDACPROOT/.cbox-acp-stamp"
_codex_acp_ready || fail "pinned Codex ACP install was rejected"
printf 'drift\n' >> "$ACPROOT/node/bin/node"
if _claude_acp_ready; then fail "tampered ACP Node was accepted"; fi
if _codex_acp_ready; then fail "tampered ACP Node was accepted by Codex"; fi
ok "Claude ACP bins check detects a changed Node binary"

_cbox_flock() { return 0; }
_gc_bg() { :; }
_cbox_clip_dir() { printf '%s' "$TMPBASE/clip"; }
_cbox_eff_bridge_key() { printf 'test'; }
_clip_bridge_start() { :; }
_clip_bridge_stop() { :; }
_cbox_container_exec_dir() { printf '%s' "$TMPBASE/bridge"; }
_container_exec_bridge_start() { return 0; }
_container_exec_bridge_stop() { :; }
_cbox_hyperqwen_owner_heal() { :; }
_cbox_ollama_owner_heal() { :; }
_cbox_netaccess_apply_isolated() { return 0; }
_cbox_ollama_reconcile_networks() { return 0; }
_cbox_probe_exes_seed() { :; }
_cbox_netaccess_socks_exec_env() { CBOX_SOCKS_EXEC_ENV=(); }
_cbox_realpath() { printf '%s' "$1"; }
_reap() { :; }
_cbox_compose_up() { echo 'container starting'; [ "${START_FAIL:-0}" = 0 ]; }
_compose_p() { docker compose "$@"; }
run() { _session_run "$eff" "$1"; }
CBOX_CONTAINER_EXEC_ENV=()
CBOX_SOCKS_EXEC_ENV=()

(cd "$PROJ" && acp_backend hermes) > "$TMPBASE/out" 2> "$TMPBASE/err" || fail "backend session failed"
[ "$(cat "$TMPBASE/out")" = 'ACP response' ] || fail "stdout contains startup text"
grep -q 'container starting' "$TMPBASE/err" || fail "startup text did not reach stderr"
grep -q 'exec -T' "$DOCKER_ARGS" || fail "container exec did not use -T"
grep -q '/entrypoint.sh acp-hermes' "$DOCKER_ARGS" || fail "ACP entrypoint was not selected"
ok "backend stdout contains only ACP output and container exec uses -T"

(cd "$PROJ" && acp_backend claude) > "$TMPBASE/out" 2> "$TMPBASE/err" || fail "Claude backend session failed"
[ "$(cat "$TMPBASE/out")" = 'ACP response' ] || fail "Claude backend stdout contains startup text"
grep -q '/entrypoint.sh acp-claude' "$DOCKER_ARGS" || fail "Claude ACP entrypoint was not selected"
ok "Claude backend stdout contains only ACP output"

(cd "$PROJ" && acp_backend codex) > "$TMPBASE/out" 2> "$TMPBASE/err" || fail "Codex backend session failed"
[ "$(cat "$TMPBASE/out")" = 'ACP response' ] || fail "Codex backend stdout contains startup text"
grep -q '/entrypoint.sh acp-codex' "$DOCKER_ARGS" || fail "Codex ACP entrypoint was not selected"
ok "Codex backend stdout contains only ACP output"

rc=0
(cd "$PROJ" && START_FAIL=1 acp_backend hermes) > "$TMPBASE/out" 2> "$TMPBASE/err" || rc=$?
[ "$rc" = 1 ] || fail "startup failure exit code is $rc"
[ ! -s "$TMPBASE/out" ] || fail "startup failure contaminated stdout"
grep -q 'container starting' "$TMPBASE/err" || fail "startup failure did not reach stderr"
ok "startup failure stays on stderr"

echo "test_acp_launcher: all checks passed"
