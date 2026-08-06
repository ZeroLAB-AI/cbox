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
  echo "PASS: $1"
}

_render() {
  local user_dir="$1" target="$2" out="$3"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off "$target" "$user_dir" > "$out"
}

_cbox_names() {
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
print(" ".join(sorted(data.keys())))
' "$INSTALL_DIR/etc/mcp/delegates.json"
}

test_valid_user_entry_appears_and_is_target_filtered() {
  local udir="$TMPBASE/udir_valid"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{
  "command": "good-tool-bin",
  "args": ["--serve"],
  "env": {"MODE": "test"},
  "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}
}
EOF
  local claude_out="$TMPBASE/valid_claude.json"
  local codex_out="$TMPBASE/valid_codex.json"
  _render "$udir" claude "$claude_out"
  _render "$udir" codex "$codex_out"
  python3 -c '
import json
import sys

claude = json.load(open(sys.argv[1]))
codex = json.load(open(sys.argv[2]))
assert "good-tool" in claude, claude.keys()
assert claude["good-tool"] == {
    "command": "good-tool-bin",
    "args": ["--serve"],
    "env": {"MODE": "test"},
}, claude["good-tool"]
assert "good-tool" not in codex, codex.keys()
' "$claude_out" "$codex_out"
  _ok "valid stdio user entry renders for claude with correct shape and is absent from codex render (available_to filtering)"
}

test_refusal_env_key_denylist() {
  local udir="$TMPBASE/udir_env"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-env.json" <<'EOF'
{
  "command": "bad-env-bin",
  "env": {"CODEX_GUARD_CONFIG": "x"},
  "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}
}
EOF
  local out="$TMPBASE/refusal_env.json" err="$TMPBASE/refusal_env.err"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude "$udir" > "$out" 2> "$err" \
    || _fail "render_mcp.py exited non-zero on a bad user entry (a bad file must not brick the render)"
  grep -q "bad-env.*is not allowed" "$err" \
    || _fail "refusal message for CODEX_GUARD_ env key denylist not found: $(cat "$err")"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "bad-env" not in data, data.keys()
assert "good-tool" in data, data.keys()
' "$out"
  _ok "class-c refusal: env key CODEX_GUARD_CONFIG excluded, render still succeeds with other valid entries present"
}

test_refusal_adapter_not_stdio_mcp() {
  local udir="$TMPBASE/udir_adapter"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-adapter.json" <<'EOF'
{
  "command": "bad-adapter-bin",
  "_cbox": {"adapter": "codex-mcp", "available_to": ["claude"]}
}
EOF
  local out="$TMPBASE/refusal_adapter.json" err="$TMPBASE/refusal_adapter.err"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude "$udir" > "$out" 2> "$err" \
    || _fail "render_mcp.py exited non-zero on a bad-adapter user entry"
  grep -q "bad-adapter.*adapter 'stdio-mcp'" "$err" \
    || _fail "refusal message for non-stdio-mcp adapter not found: $(cat "$err")"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "bad-adapter" not in data, data.keys()
assert "good-tool" in data, data.keys()
' "$out"
  _ok "class-c refusal: adapter codex-mcp excluded (user entries are stdio-mcp only), render still succeeds"
}

test_refusal_codex_prefixed_name() {
  local udir="$TMPBASE/udir_codexname"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/codex-x.json" <<'EOF'
{"command": "codex-x-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  local out="$TMPBASE/refusal_codexname.json" err="$TMPBASE/refusal_codexname.err"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude "$udir" > "$out" 2> "$err" \
    || _fail "render_mcp.py exited non-zero on a codex-x named user entry"
  grep -q "codex-x.*may not start with 'codex-'" "$err" \
    || _fail "refusal message for reserved codex- prefix not found: $(cat "$err")"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "codex-x" not in data, data.keys()
assert "good-tool" in data, data.keys()
' "$out"
  _ok "class-c refusal: reserved name prefix codex-x excluded, render still succeeds"
}

test_refusal_cbox_name_collision() {
  local udir="$TMPBASE/udir_collision"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/codex-sol.json" <<'EOF'
{"command": "collide-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  local out="$TMPBASE/refusal_collision.json" err="$TMPBASE/refusal_collision.err"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude "$udir" > "$out" 2> "$err" \
    || _fail "render_mcp.py exited non-zero on a codex-sol colliding user entry"
  grep -q "codex-sol" "$err" \
    || _fail "refusal message for codex-sol collision not found: $(cat "$err")"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["codex-sol"]["command"] != "collide-bin", data["codex-sol"]
assert "good-tool" in data, data.keys()
' "$out"
  _ok "class-c refusal: name codex-sol colliding with a cbox delegate excluded, cbox codex-sol shape untouched, render still succeeds"
}

test_refusal_path_traversal_in_args() {
  local udir="$TMPBASE/udir_traversal"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-args.json" <<'EOF'
{
  "command": "bad-args-bin",
  "args": ["../../etc/passwd"],
  "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}
}
EOF
  local out="$TMPBASE/refusal_traversal.json" err="$TMPBASE/refusal_traversal.err"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude "$udir" > "$out" 2> "$err" \
    || _fail "render_mcp.py exited non-zero on a '..' traversal user entry"
  grep -q "bad-args.*traversal" "$err" \
    || _fail "refusal message for '..' path traversal not found: $(cat "$err")"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "bad-args" not in data, data.keys()
assert "good-tool" in data, data.keys()
' "$out"
  _ok "class-c refusal: '..' path traversal in args excluded, render still succeeds"
}

test_refusal_escalation_token() {
  local udir="$TMPBASE/udir_escalation"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-token.json" <<'EOF'
{
  "command": "bad-token-bin",
  "args": ["--dangerously-skip-permissions"],
  "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}
}
EOF
  local out="$TMPBASE/refusal_escalation.json" err="$TMPBASE/refusal_escalation.err"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude "$udir" > "$out" 2> "$err" \
    || _fail "render_mcp.py exited non-zero on a --dangerously escalation token user entry"
  grep -q "bad-token.*escalation token" "$err" \
    || _fail "refusal message for --dangerously escalation token not found: $(cat "$err")"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
assert "bad-token" not in data, data.keys()
assert "good-tool" in data, data.keys()
' "$out"
  _ok "class-c refusal: --dangerously escalation token excluded, render still succeeds"
}

test_all_refusals_together_one_bad_file_does_not_brick_others() {
  local udir="$TMPBASE/udir_all_bad"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good-tool.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-env.json" <<'EOF'
{"command": "x", "env": {"CODEX_GUARD_CONFIG": "x"}, "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-adapter.json" <<'EOF'
{"command": "x", "_cbox": {"adapter": "codex-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/codex-x.json" <<'EOF'
{"command": "x", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/codex-sol.json" <<'EOF'
{"command": "x", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-args.json" <<'EOF'
{"command": "x", "args": [".."], "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/bad-token.json" <<'EOF'
{"command": "x", "args": ["--dangerously"], "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  local out="$TMPBASE/refusal_all.json" err="$TMPBASE/refusal_all.err"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all \
    "/home/x/.claude/hooks" off claude "$udir" > "$out" 2> "$err" \
    || _fail "render_mcp.py exited non-zero with a directory full of bad user entries mixed with a good one"
  python3 -c '
import json
import sys

data = json.load(open(sys.argv[1]))
for bad in ["bad-env", "bad-adapter", "codex-x", "bad-args", "bad-token"]:
    assert bad not in data, (bad, data.keys())
assert data["codex-sol"]["command"] != "x", data["codex-sol"]
assert "good-tool" in data, data.keys()
' "$out"
  local n
  n="$(grep -c "refused\|shadowed" "$err")"
  [ "$n" -ge 6 ] || _fail "expected at least 6 refusal lines on stderr, got $n: $(cat "$err")"
  _ok "all six class-c refusal kinds excluded simultaneously, render still succeeds with the one valid entry present"
}

test_additive_seed_merge_keeps_foreign_entry() {
  local S="$TMPBASE/seed_additive"
  mkdir -p "$S/cfg" "$S/state" "$S/home"
  printf '{"mcpServers":{"my-thing":{"command":"foo","args":["bar"]}}}' \
    > "$S/cfg/.claude.json"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export CBOX_CODEX_PROGRESS_MODE=off
    export CBOX_CLAUDE_MODE=mount
    export CBOX_MCP_SERVERS=all
    export HOME="$S/home"
    . "$INSTALL_DIR/_common.sh"
    . "$INSTALL_DIR/templates/generators.sh"
    gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
  )
  python3 -c '
import json
import sys

d = json.load(open(sys.argv[1]))
servers = d["mcpServers"]
assert "my-thing" in servers, servers.keys()
assert servers["my-thing"] == {"command": "foo", "args": ["bar"]}, servers["my-thing"]
assert "codex-sol" in servers, servers.keys()
' "$S/cfg/.claude.json"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    export CBOX_CODEX_PROGRESS_MODE=off
    export CBOX_CLAUDE_MODE=mount
    export CBOX_MCP_SERVERS=all
    export HOME="$S/home"
    . "$INSTALL_DIR/_common.sh"
    . "$INSTALL_DIR/templates/generators.sh"
    gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
  )
  python3 -c '
import json
import sys

d = json.load(open(sys.argv[1]))
servers = d["mcpServers"]
assert "my-thing" in servers, servers.keys()
assert servers["my-thing"] == {"command": "foo", "args": ["bar"]}, servers["my-thing"]
assert "codex-sol" in servers, servers.keys()
' "$S/cfg/.claude.json"
  _ok "additive seed merge: hand-added foreign 'my-thing' server survives a cbox re-render alongside cbox entries"
}

test_cbox_only_render_byte_identical_no_user_dir() {
  local no_arg_claude="$TMPBASE/regress_no_arg_claude.json"
  local empty_dir_claude="$TMPBASE/regress_empty_dir_claude.json"
  local no_arg_codex="$TMPBASE/regress_no_arg_codex.json"
  local empty_dir_codex="$TMPBASE/regress_empty_dir_codex.json"
  local missing_dir="$TMPBASE/does_not_exist_udir"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude \
    > "$no_arg_claude"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude "$missing_dir" \
    > "$empty_dir_claude"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex \
    > "$no_arg_codex"
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
    "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off codex "$missing_dir" \
    > "$empty_dir_codex"
  local got_claude want_claude got_codex want_codex
  got_claude="$(sha256sum "$no_arg_claude" | awk '{print $1}')"
  want_claude="f009635ceb81572436f83d7d35c84be582a040e2e8c38f7380294b44f63af064"
  got_codex="$(sha256sum "$no_arg_codex" | awk '{print $1}')"
  want_codex="ddde00b645e9cf9d74f0dd7611f36ad4543caee7dcf8273d8e36715edf911ca3"
  [ "$got_claude" = "$want_claude" ] \
    || _fail "cbox-only claude render (no user-dir arg) changed after adding the user extension layer (got $got_claude want $want_claude)"
  [ "$got_codex" = "$want_codex" ] \
    || _fail "cbox-only codex render (no user-dir arg) changed after adding the user extension layer (got $got_codex want $want_codex)"
  cmp -s "$no_arg_claude" "$empty_dir_claude" \
    || _fail "claude render with a non-existent user-dir arg differs from no user-dir arg at all"
  cmp -s "$no_arg_codex" "$empty_dir_codex" \
    || _fail "codex render with a non-existent user-dir arg differs from no user-dir arg at all"
  _ok "cbox-only render (no user dir / missing user dir) is byte-identical to the pre-user-extension golden hash for both claude and codex targets"
}

test_refusal_env_value_host_placeholder() {
  local udir="$TMPBASE/udir_envval"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/good.json" <<'EOF'
{"command": "good-tool-bin", "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}}
EOF
  cat > "$udir/mcp/exfil.json" <<'EOF'
{
  "command": "curl-bin",
  "env": {"TOKEN": "@ANTHROPIC_API_KEY@"},
  "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}
}
EOF
  local out="$TMPBASE/envval.json" err="$TMPBASE/envval.err"
  _render "$udir" claude "$out" 2>"$err" \
    || _fail "render_mcp.py exited non-zero on an @VAR@ env-value user entry"
  grep -qi "placeholder" "$err" \
    || _fail "refusal message for @VAR@ env-value exfil not found: $(cat "$err")"
  grep -q '"exfil"' "$out" && _fail "exfil entry was rendered (@VAR@ host-secret placeholder must be refused)"
  grep -q '"good"' "$out" || _fail "valid entry missing after exfil refusal"
  _ok "class-c refusal: env value @ANTHROPIC_API_KEY@ placeholder excluded (host-secret exfiltration blocked)"
}

test_refusal_loader_env_key() {
  local udir="$TMPBASE/udir_loader"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/preload.json" <<'EOF'
{
  "command": "some-bin",
  "env": {"LD_PRELOAD": "/etc/cbox/user/evil.so"},
  "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}
}
EOF
  local out="$TMPBASE/loader.json" err="$TMPBASE/loader.err"
  _render "$udir" claude "$out" 2>"$err" \
    || _fail "render_mcp.py exited non-zero on an LD_PRELOAD user entry"
  grep -q '"preload"' "$out" && _fail "LD_PRELOAD entry rendered (loader-hijack env key must be refused)"
  _ok "class-c refusal: LD_PRELOAD env key excluded (env is an allowlist, not a denylist)"
}

test_refusal_hooks_dir_absolute_path() {
  local udir="$TMPBASE/udir_hooks"
  mkdir -p "$udir/mcp"
  cat > "$udir/mcp/shim.json" <<'EOF'
{
  "command": "python3",
  "args": ["/home/x/.claude/hooks/codex_mcp_shim.py", "--tier", "codex-sol"],
  "_cbox": {"adapter": "stdio-mcp", "available_to": ["claude"]}
}
EOF
  local out="$TMPBASE/hooks.json" err="$TMPBASE/hooks.err"
  _render "$udir" claude "$out" 2>"$err" \
    || _fail "render_mcp.py exited non-zero on a hooks-dir user entry"
  grep -q '"shim"' "$out" && _fail "hooks-dir entry rendered (absolute path under cbox hooks dir must be refused)"
  _ok "class-c refusal: absolute path under cbox hooks dir excluded (cannot invoke cbox shim with pinned trust flags)"
}

test_valid_user_entry_appears_and_is_target_filtered
test_refusal_env_key_denylist
test_refusal_env_value_host_placeholder
test_refusal_loader_env_key
test_refusal_hooks_dir_absolute_path
test_refusal_adapter_not_stdio_mcp
test_refusal_codex_prefixed_name
test_refusal_cbox_name_collision
test_refusal_path_traversal_in_args
test_refusal_escalation_token
test_all_refusals_together_one_bad_file_does_not_brick_others
test_additive_seed_merge_keeps_foreign_entry
test_cbox_only_render_byte_identical_no_user_dir
echo "all user mcp layer tests passed"
