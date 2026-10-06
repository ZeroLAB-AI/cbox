#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

BODY="$(awk '/^gen_hooks_dir\(\) \{/,/^}$/' "$INSTALL_DIR/templates/generators.sh")"
[ -n "$BODY" ] || _fail "could not extract gen_hooks_dir from templates/generators.sh"

case "$BODY" in
  *'generated/hooks/codex_usage_refresh.py" < "$INSTALL_DIR/etc/hooks/codex_usage_refresh.py"'*) ;;
  *) _fail "gen_hooks_dir does not deploy etc/hooks/codex_usage_refresh.py into generated/hooks" ;;
esac
_ok "gen_hooks_dir deploys etc/hooks/codex_usage_refresh.py into generated/hooks"

case "$BODY" in
  *'generated/hooks/claude_usage_refresh.py" < "$INSTALL_DIR/etc/hooks/claude_usage_refresh.py"'*) ;;
  *) _fail "gen_hooks_dir does not deploy etc/hooks/claude_usage_refresh.py into generated/hooks" ;;
esac
_ok "gen_hooks_dir deploys etc/hooks/claude_usage_refresh.py into generated/hooks"

case "$BODY" in
  *'generated/hooks/usage_statusline.py" < "$INSTALL_DIR/etc/hooks/usage_statusline.py"'*) ;;
  *) _fail "gen_hooks_dir does not deploy etc/hooks/usage_statusline.py into generated/hooks (regression check)" ;;
esac
_ok "gen_hooks_dir still deploys etc/hooks/usage_statusline.py into generated/hooks"

case "$BODY" in
  *'generated/hooks/codex_mcp_shim.py" < "$INSTALL_DIR/etc/mcp/codex_mcp_shim.py"'*) ;;
  *) _fail "gen_hooks_dir does not deploy etc/mcp/codex_mcp_shim.py beside codex_usage_refresh.py in generated/hooks" ;;
esac
_ok "gen_hooks_dir deploys etc/mcp/codex_mcp_shim.py beside codex_usage_refresh.py"

case "$BODY" in
  *'generated/hooks/codex_mode_guard.py" < "$INSTALL_DIR/etc/hooks/codex_mode_guard.py"'*) ;;
  *) _fail "gen_hooks_dir does not deploy etc/hooks/codex_mode_guard.py beside codex_mcp_shim.py in generated/hooks" ;;
esac
_ok "gen_hooks_dir deploys etc/hooks/codex_mode_guard.py beside codex_mcp_shim.py"

echo "test_gen_hooks_dir_deploy: all checks passed"
