#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
SETUP="$DIR/cbox-setup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

mkdir -p "$WORK/etc/registry" "$WORK/etc/agents" "$WORK/userdir"
cp "$REPO_ROOT/etc/registry/retired.json" "$WORK/etc/registry/retired.json" \
  || _fail "could not copy retired.json into the fake install dir"
printf 'x\n' > "$WORK/etc/agents/worker.md"
printf 'x\n' > "$WORK/etc/agents/codex-terra.md"

EXTRACT="$WORK/functions.sh"
{
  sed -n '/^retired_names() {/,/^}/p' "$SETUP"
  sed -n '/^retired_agent_hashes() {/,/^}/p' "$SETUP"
  sed -n '/^agent_all_names() {/,/^}/p' "$SETUP"
  sed -n '/^_managed_file_matches() {/,/^}/p' "$SETUP"
  sed -n '/^agents_prune_deselected() {/,/^}/p' "$SETUP"
  sed -n '/^merge_mcp_json() {/,/^}/p' "$SETUP"
} > "$EXTRACT"
grep -q "retired_names() {" "$EXTRACT" || _fail "could not extract retired_names from cbox-setup.sh"
grep -q "retired_agent_hashes() {" "$EXTRACT" || _fail "could not extract retired_agent_hashes from cbox-setup.sh"
grep -q "agent_all_names() {" "$EXTRACT" || _fail "could not extract agent_all_names from cbox-setup.sh"
grep -q "agents_prune_deselected() {" "$EXTRACT" || _fail "could not extract agents_prune_deselected from cbox-setup.sh"
grep -q "merge_mcp_json() {" "$EXTRACT" || _fail "could not extract merge_mcp_json from cbox-setup.sh"

source "$REPO_ROOT/lib/portable.sh"
source "$EXTRACT"
note() { printf 'setup: %s\n' "$*"; }
die() { echo "die: $*" >&2; exit 1; }

ETC_DIR="$WORK/etc"

out="$(agent_all_names)"
[ "$out" = "worker" ] \
  || _fail "case a: agent_all_names listed '$out', want exactly 'worker' (codex-terra is retired and must not appear)"
_ok "case a: agent_all_names lists worker but not retired codex-terra"

SHIPPED_TEST_RUNNER="$WORK/shipped-test-runner.md"
GIT_ROOT="$(cd "$REPO_ROOT/.." && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$GIT_ROOT" ] || _fail "setup: could not resolve the repository root to pull a real shipped agent revision from git history"
FOUND_HASH=""
for rev in $(git -C "$GIT_ROOT" log --all --format=%H -- '*/etc/agents/test-runner.md' 'etc/agents/test-runner.md'); do
  for candidate in cbox/etc/agents/test-runner.md claude-box/etc/agents/test-runner.md etc/agents/test-runner.md; do
    if git -C "$GIT_ROOT" show "$rev:$candidate" > "$SHIPPED_TEST_RUNNER" 2>/dev/null; then
      [ -s "$SHIPPED_TEST_RUNNER" ] || continue
      cand_hash="$(_cbox_sha256 "$SHIPPED_TEST_RUNNER")"
      if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in d["agents"]["test-runner"] else 1)
' "$WORK/etc/registry/retired.json" "$cand_hash"; then
        FOUND_HASH="$cand_hash"
        break 2
      fi
    fi
  done
done
[ -n "$FOUND_HASH" ] \
  || _fail "setup: could not find any historical revision of test-runner.md whose content hash is listed in retired.json - regenerate the hash list from git history"
SHIPPED_HASH="$FOUND_HASH"

mkdir -p "$WORK/target"
cp "$SHIPPED_TEST_RUNNER" "$WORK/target/test-runner.md"
printf 'my own test-runner, not the cbox one\n' > "$WORK/target/codex-terra-light.md"
printf 'x\n' > "$WORK/target/my-own.md"
ln -s "$WORK/target/my-own.md" "$WORK/target/codex-terra.md"
agents_prune_deselected "$WORK/target" > "$WORK/b_notes.txt" 2>&1 \
  || _fail "case b: agents_prune_deselected exited non-zero"

[ ! -e "$WORK/target/test-runner.md" ] \
  || _fail "case b1: cbox-shipped test-runner.md (content hash matches retired.json) was not removed"
grep -qF "agents: removed retired $WORK/target/test-runner.md" "$WORK/b_notes.txt" \
  || _fail "case b1: expected note 'agents: removed retired $WORK/target/test-runner.md' in: $(cat "$WORK/b_notes.txt")"
_ok "case b1: agents_prune_deselected removes a cbox-shipped copy of a retired agent (content hash matches)"

[ -f "$WORK/target/codex-terra-light.md" ] \
  || _fail "case b2: a user's own codex-terra-light.md (different content, not a cbox-shipped copy) was removed - it must be kept"
grep -qF "agents: kept $WORK/target/codex-terra-light.md (not a cbox-shipped copy)" "$WORK/b_notes.txt" \
  || _fail "case b2: expected a 'kept ... (not a cbox-shipped copy)' note for codex-terra-light.md in: $(cat "$WORK/b_notes.txt")"
_ok "case b2: agents_prune_deselected keeps a user's own retired-named agent with different content, and notes it"

[ -L "$WORK/target/codex-terra.md" ] \
  || _fail "case b3: symlinked codex-terra.md is gone or no longer a symlink - setup must not have touched it"
grep -qF "agents: kept $WORK/target/codex-terra.md (not a cbox-shipped copy)" "$WORK/b_notes.txt" \
  || _fail "case b3: expected a 'kept ... (not a cbox-shipped copy)' note for the symlinked codex-terra.md in: $(cat "$WORK/b_notes.txt")"
_ok "case b3: agents_prune_deselected never removes a symlinked retired-named agent file"

[ -f "$WORK/target/my-own.md" ] \
  || _fail "case b4: my-own.md was removed - locally added agent files must survive the prune"
_ok "case b4: agents_prune_deselected leaves an unrelated agent file alone"

ETC_DIR="$REPO_ROOT/etc"
export CBOX_USER_DIR="$WORK/userdir"
HOOKS_HOME="$WORK/home"
HOOKS_DIR="$HOOKS_HOME/.claude/hooks"

C_TARGET="$WORK/c_target.json"
python3 -c '
import json, sys
d = {"mcpServers": {
    "codex-terra": {"type": "stdio", "command": "python3", "args": [
        sys.argv[2] + "/codex_mcp_shim.py", "--tier", "codex-terra",
        "--model", "test-tier", "--effort", "max",
        "--progress", "off", "--", "codex", "app-server"]},
    "mine": {"type": "stdio", "command": "my-bin", "args": ["--serve"]},
}}
json.dump(d, open(sys.argv[1], "w"))
' "$C_TARGET" "$HOOKS_DIR"
merge_mcp_json "$C_TARGET" "$REPO_ROOT/etc/mcp/delegates.json" "" "$WORK/c_out.json" off "$HOOKS_HOME" \
  || _fail "case c1: merge_mcp_json exited non-zero on a target holding a cbox-rendered retired server"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
servers = d.get("mcpServers", {})
assert "codex-terra" not in servers, servers.keys()
assert "mine" in servers, servers.keys()
assert servers["mine"]["command"] == "my-bin", servers["mine"]
' "$WORK/c_out.json" \
  || _fail "case c1: merge_mcp_json did not drop the cbox-rendered retired codex-terra, or clobbered foreign mine"
_ok "case c1: merge_mcp_json drops a cbox-rendered (shim-wrapped) retired codex-terra, keeps foreign mine"

C2_TARGET="$WORK/c2_target.json"
python3 -c '
import json, sys
d = {"mcpServers": {
    "codex-terra": {"type": "stdio", "command": "my-codex-clone", "args": ["--serve"]},
    "mine": {"type": "stdio", "command": "my-bin", "args": ["--serve"]},
}}
json.dump(d, open(sys.argv[1], "w"))
' "$C2_TARGET"
merge_mcp_json "$C2_TARGET" "$REPO_ROOT/etc/mcp/delegates.json" "" "$WORK/c2_out.json" off "$HOOKS_HOME" \
  || _fail "case c2: merge_mcp_json exited non-zero on a target holding a foreign codex-terra"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
servers = d.get("mcpServers", {})
assert "codex-terra" in servers, "foreign codex-terra (different command) must survive: " + repr(servers.keys())
assert servers["codex-terra"]["command"] == "my-codex-clone", servers["codex-terra"]
' "$WORK/c2_out.json" \
  || _fail "case c2: merge_mcp_json removed a foreign codex-terra entry that is not cbox-rendered"
_ok "case c2: merge_mcp_json keeps a foreign codex-terra entry (different command) with the same retired name"

D_TARGET="$WORK/d_target.json"
python3 -c '
import json, sys
d = {"mcpServers": {
    "codex-terra": {"type": "stdio", "command": "python3", "args": [
        sys.argv[2] + "/codex_mcp_shim.py", "--tier", "codex-terra",
        "--model", "test-tier", "--effort", "max",
        "--progress", "off", "--", "codex", "app-server"]},
    "mine": {"type": "stdio", "command": "my-bin", "args": ["--serve"]},
}}
json.dump(d, open(sys.argv[1], "w"))
' "$D_TARGET" "$HOOKS_DIR"
python3 "$REPO_ROOT/etc/adapters/claude.py" cbox-json-seed-merge '{}' \
  "$D_TARGET" "$REPO_ROOT/etc/mcp/delegates.json" "$REPO_ROOT/etc/registry/retired.json" \
  > "$WORK/d_out.json" \
  || _fail "case d1: claude.py cbox-json-seed-merge with the retired.json arg exited non-zero"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
servers = d.get("mcpServers", {})
assert "codex-terra" not in servers, servers.keys()
assert "mine" in servers, servers.keys()
' "$WORK/d_out.json" \
  || _fail "case d1: cbox-json-seed-merge did not drop the cbox-rendered retired codex-terra, or lost foreign mine"
_ok "case d1: claude.py cbox-json-seed-merge drops a cbox-rendered codex-terra via the 5th-arg retired registry, keeps mine"

D2_TARGET="$WORK/d2_target.json"
python3 -c '
import json, sys
d = {"mcpServers": {
    "codex-terra": {"type": "stdio", "command": "my-codex-clone", "args": ["--serve"]},
    "mine": {"type": "stdio", "command": "my-bin", "args": ["--serve"]},
}}
json.dump(d, open(sys.argv[1], "w"))
' "$D2_TARGET"
python3 "$REPO_ROOT/etc/adapters/claude.py" cbox-json-seed-merge '{}' \
  "$D2_TARGET" "$REPO_ROOT/etc/mcp/delegates.json" "$REPO_ROOT/etc/registry/retired.json" \
  > "$WORK/d2_out.json" \
  || _fail "case d2: claude.py cbox-json-seed-merge exited non-zero on a foreign codex-terra"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
servers = d.get("mcpServers", {})
assert "codex-terra" in servers, "foreign codex-terra (different command) must survive: " + repr(servers.keys())
assert servers["codex-terra"]["command"] == "my-codex-clone", servers["codex-terra"]
' "$WORK/d2_out.json" \
  || _fail "case d2: cbox-json-seed-merge removed a foreign codex-terra entry that is not cbox-rendered"
_ok "case d2: claude.py cbox-json-seed-merge keeps a foreign codex-terra entry (different command) with the same retired name"

D3_TARGET="$WORK/d3_target.json"
python3 -c '
import json, sys
d = {"mcpServers": {
    "codex-terra": {"type": "stdio", "command": "codex", "args": ["mcp-server", "-c", "model=test-tier"]},
    "mine": {"type": "stdio", "command": "my-bin", "args": ["--serve"]},
}}
json.dump(d, open(sys.argv[1], "w"))
' "$D3_TARGET"
python3 "$REPO_ROOT/etc/adapters/claude.py" cbox-json-seed-merge '{}' \
  "$D3_TARGET" "$REPO_ROOT/etc/mcp/delegates.json" "$REPO_ROOT/etc/registry/retired.json" \
  > "$WORK/d3_out.json" \
  || _fail "case d3: claude.py cbox-json-seed-merge exited non-zero on a pre-shim-era codex-terra"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
servers = d.get("mcpServers", {})
assert "codex-terra" not in servers, servers.keys()
assert "mine" in servers, servers.keys()
' "$WORK/d3_out.json" \
  || _fail "case d3: cbox-json-seed-merge did not drop a pre-shim-era ('codex mcp-server') cbox-rendered codex-terra"
_ok "case d3: claude.py cbox-json-seed-merge also drops the pre-shim-era 'codex mcp-server' rendered shape"

D4_TARGET="$WORK/d4_target.json"
python3 -c '
import json, sys
d = {"mcpServers": {
    "codex-terra": {"type": "stdio", "command": "codex", "args": ["app-server"]},
    "mine": {"type": "stdio", "command": "my-bin", "args": ["--serve"]},
}}
json.dump(d, open(sys.argv[1], "w"))
' "$D4_TARGET"
python3 "$REPO_ROOT/etc/adapters/claude.py" cbox-json-seed-merge '{}' \
  "$D4_TARGET" "$REPO_ROOT/etc/mcp/delegates.json" \
  > "$WORK/d4_out.json" \
  || _fail "case e: cbox-json-seed-merge without the 5th argument no longer works (backward compatibility broken)"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
servers = d.get("mcpServers", {})
assert "mine" in servers, servers.keys()
assert "codex-terra" in servers, "4-argument call must not start pruning anything it could not see before (codex-terra lost: " + repr(servers.keys()) + ")"
' "$WORK/d4_out.json" \
  || _fail "case e: 4-argument cbox-json-seed-merge lost the foreign mine entry or its pre-retired-registry behavior changed"
_ok "case e: cbox-json-seed-merge without the 5th argument still works and keeps mine"

echo "PASS: retired-name registry prunes agents (by shipped content hash) and mcp servers (by cbox-rendered shape)"
