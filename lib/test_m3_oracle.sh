#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXDIR="$INSTALL_DIR/lib/fixtures/m3_oracle"
SNAP="$FIXDIR/install_dir_snapshot"
DIGESTS="$FIXDIR/digests.txt"
MODE="${1:-verify}"

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_ok() {
  echo "ok: $1"
}

case "$MODE" in
  freeze|verify) ;;
  *) _fail "usage: test_m3_oracle.sh [freeze|verify] (default verify)" ;;
esac

[ -d "$SNAP" ] || _fail "pinned fixture snapshot missing: $SNAP"

_make_fake_install() {
  local dir="$1"
  mkdir -p "$dir/etc/mcp" "$dir/etc/hooks" "$dir/etc/claude" "$dir/etc/container" \
    "$dir/etc/adapters" "$dir/lib" "$dir/templates" "$dir/generated"
  cp "$INSTALL_DIR/_common.sh" "$dir/_common.sh"
  cp "$INSTALL_DIR/lib/portable.sh" "$dir/lib/portable.sh"
  cp "$INSTALL_DIR/lib/cbox_host.py" "$dir/lib/cbox_host.py"
  cp "$INSTALL_DIR/lib/cbox_session_bridge.py" "$dir/lib/cbox_session_bridge.py"
  cp "$INSTALL_DIR/templates/generators.sh" "$dir/templates/generators.sh"
  cp "$INSTALL_DIR/etc/mcp/render_mcp.py" "$dir/etc/mcp/render_mcp.py"
  cp "$INSTALL_DIR/etc/container/cbox-session-entry.py" "$dir/etc/container/cbox-session-entry.py"
  if [ -d "$INSTALL_DIR/etc/adapters" ]; then
    cp "$INSTALL_DIR"/etc/adapters/*.py "$dir/etc/adapters/" 2>/dev/null || true
  fi
  cp "$SNAP/delegates.json" "$dir/etc/mcp/delegates.json"
  cp "$SNAP/conduct-kernel.txt" "$dir/etc/hooks/conduct-kernel.txt"
  cp "$SNAP/settings.merge.json" "$dir/etc/claude/settings.merge.json"
  cp "$SNAP/managed-settings.merge.json" "$dir/etc/claude/managed-settings.merge.json"
  printf 'schema=1\nbase=ubuntu:24.04@sha256:deadbeef\n' > "$dir/image.inputs"
}

_run() {
  local fi="$1" home="$2"
  shift 2
  (
    for v in $(env | LC_ALL=C awk -F= '/^CBOX_/{print $1}'); do
      unset "$v" 2>/dev/null || true
    done
    INSTALL_DIR="$fi"
    export INSTALL_DIR
    HOME="$home"
    export HOME
    export LC_ALL=C
    export CBOX_MCP_SERVERS=all
    export CBOX_CLAUDE_MODE=mount
    export CBOX_CODEX_PROGRESS_MODE=off
    export CBOX_WORKSPACES="/opt/m3-oracle-pinned-workspace"
    export CBOX_USER_DIR="$fi/user_dir_fixture"
    unset CBOX_HERMES_DELEGATE CBOX_CONTAINER_EXEC_TOOL CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG \
      CBOX_HERMES_DELEGATE_BIN CBOX_HERMES_DELEGATE_HOME_TEMPLATE CBOX_CODEX_MCP 2>/dev/null || true
    source "$fi/_common.sh"
    source "$fi/templates/generators.sh"
    "$@"
  )
}

_normalize() {
  local infile="$1" outfile="$2" home="$3" fi="$4"
  local rname
  rname="$(printf '%s' "$(id -un)" | LC_ALL=C awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
  sed \
    -e "s#$home#@HOME@#g" \
    -e "s#$fi#@INSTALL_DIR@#g" \
    -e "s/\\b$rname\\b/@NAME@/g" \
    "$infile" > "$outfile"
}

_setup_fixture_tree() {
  local fi="$1" home="$2"
  _make_fake_install "$fi"
  mkdir -p "$home/.codex" "$home/.claude/hooks"
  cp "$SNAP/AGENTS.override.md.host_fixture" "$home/.codex/AGENTS.override.md"
  mkdir -p "$fi/user_dir_fixture/policies"
  cp "$SNAP/user_policies/m3-oracle-policy.md" "$fi/user_dir_fixture/policies/m3-oracle-policy.md"
}

RENDER_DIR="$TMPBASE/render"
FI="$RENDER_DIR/fake_install"
HOME_FIX="$RENDER_DIR/home"
mkdir -p "$RENDER_DIR"
_setup_fixture_tree "$FI" "$HOME_FIX"

OUT="$TMPBASE/out"
mkdir -p "$OUT"

_run "$FI" "$HOME_FIX" _cbox_render_mcp_for_target \
  "$FI/etc/mcp/delegates.json" all "$HOME_FIX/.claude/hooks" off hermes \
  > "$OUT/render_mcp.hermes.json"

_run "$FI" "$HOME_FIX" _cbox_render_mcp_for_target \
  "$FI/etc/mcp/delegates.json" all "$HOME_FIX/.claude/hooks" off claude \
  > "$OUT/render_mcp.claude_off.json"

_run "$FI" "$HOME_FIX" _cbox_render_mcp_for_target \
  "$FI/etc/mcp/delegates.json" all "$HOME_FIX/.claude/hooks" on claude \
  > "$OUT/render_mcp.claude_on.json"

_run "$FI" "$HOME_FIX" _cbox_render_mcp_for_target \
  "$FI/etc/mcp/delegates.json" all "$HOME_FIX/.claude/hooks" off codex \
  > "$OUT/render_mcp.codex.json"

mkdir -p "$OUT/hermes_gen"
_run "$FI" "$HOME_FIX" gen_hermes_mcp_servers_into "$OUT/hermes_gen/mcp_servers.yaml"

mkdir -p "$FI/generated/state"
_run "$FI" "$HOME_FIX" gen_claude_json_seed
cp "$FI/generated/state/claude.json" "$OUT/claude_json_seed.json"

mkdir -p "$OUT/claude_cbox_merge"
cp "$SNAP/claude_json_seed.pre_existing.json" "$OUT/claude_cbox_merge/.claude.json"
_run "$FI" "$HOME_FIX" gen_claude_cbox_json_seed_into \
  "$OUT/claude_cbox_merge/.claude.json" ""
cp "$OUT/claude_cbox_merge/.claude.json" "$OUT/claude_cbox_seed_merge.json"

mkdir -p "$OUT/codex_agents"
_run "$FI" "$HOME_FIX" gen_codex_agents_into "$OUT/codex_agents"
cp "$OUT/codex_agents/AGENTS.override.md" "$OUT/codex_agents_override.md"

mkdir -p "$OUT/codex_hooks"
_run "$FI" "$HOME_FIX" gen_codex_hooks_json_into "$OUT/codex_hooks"
cp "$OUT/codex_hooks/hooks.json" "$OUT/codex_hooks.json"

mkdir -p "$OUT/codex_profile"
(
  export CBOX_CODEX_MCP=1
  _run "$FI" "$HOME_FIX" gen_codex_profile_into "$OUT/codex_profile" global "/opt/m3-oracle-pinned-workspace"
)
cp "$OUT/codex_profile/cbox-container.config.toml" "$OUT/codex_profile_toml.toml"

_run "$FI" "$HOME_FIX" gen_settings_volume
cp "$FI/generated/settings.json" "$OUT/settings_volume.json"

_run "$FI" "$HOME_FIX" gen_managed_settings
cp "$FI/generated/managed-settings.json" "$OUT/managed_settings.json"

NORM="$TMPBASE/normalized"
mkdir -p "$NORM"
ARTIFACTS="render_mcp.hermes.json render_mcp.claude_off.json render_mcp.claude_on.json render_mcp.codex.json hermes_gen/mcp_servers.yaml claude_json_seed.json claude_cbox_seed_merge.json codex_agents_override.md codex_hooks.json codex_profile_toml.toml settings_volume.json managed_settings.json"

for a in $ARTIFACTS; do
  mkdir -p "$NORM/$(dirname "$a")"
  _normalize "$OUT/$a" "$NORM/$a" "$HOME_FIX" "$FI"
done

_compute_digests() {
  local dir="$1" out="$2" a sha
  : > "$out"
  for a in $ARTIFACTS; do
    sha="$(sha256sum "$dir/$a" | awk '{print $1}')"
    printf '%s=%s\n' "$a" "$sha" >> "$out"
  done
  LC_ALL=C sort -o "$out" "$out"
}

if [ "$MODE" = freeze ]; then
  _compute_digests "$NORM" "$DIGESTS"
  _ok "froze $(printf '%s\n' $ARTIFACTS | wc -l | tr -d ' ') artifact digests into $DIGESTS"
  echo "PASS: m3 oracle freeze"
  exit 0
fi

[ -f "$DIGESTS" ] || _fail "no frozen oracle at $DIGESTS - run: $0 freeze"

GOT="$TMPBASE/got_digests.txt"
_compute_digests "$NORM" "$GOT"

if ! diff -u "$DIGESTS" "$GOT" > "$TMPBASE/diff.txt"; then
  echo "FAIL: m3 oracle mismatch against frozen digests - changed artifact(s):" >&2
  awk '/^[+-][a-zA-Z0-9]/{print}' "$TMPBASE/diff.txt" >&2
  exit 1
fi
_ok "all $(printf '%s\n' $ARTIFACTS | wc -l | tr -d ' ') artifacts byte-identical to the frozen oracle ($DIGESTS)"

MUT_TARGET="$NORM/settings_volume.json"
MUT_BACKUP="$TMPBASE/mut_backup.json"
cp "$MUT_TARGET" "$MUT_BACKUP"
python3 -c "
import sys
p = sys.argv[1]
with open(p, 'rb') as fh:
    data = bytearray(fh.read())
data[0] = (data[0] + 1) % 256
with open(p, 'wb') as fh:
    fh.write(data)
" "$MUT_TARGET"

MUT_DIGESTS="$TMPBASE/mut_digests.txt"
_compute_digests "$NORM" "$MUT_DIGESTS"

if diff -u "$DIGESTS" "$MUT_DIGESTS" > /dev/null 2>&1; then
  cp "$MUT_BACKUP" "$MUT_TARGET"
  _fail "mutation-check did not fire - a single-byte perturbation of settings_volume.json produced an identical digest set, the oracle is vacuous"
fi
cp "$MUT_BACKUP" "$MUT_TARGET"
_ok "mutation-check: a single-byte perturbation of settings_volume.json is caught by the byte-compare (oracle proven non-vacuous)"

echo "PASS: m3 oracle verify"
