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

_render_codex_agents() {
  local outdir="$1" gate="$2"
  mkdir -p "$outdir"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    HOME="$TMPBASE/fake_home_$gate"
    export HOME
    mkdir -p "$HOME"
    export CBOX_CONTAINER_EXEC_TOOL="$gate"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_agents_into "$outdir"
  )
}

OFF_AGENTS="$TMPBASE/agents_off"
_render_codex_agents "$OFF_AGENTS" off
grep -qi "container-exec\|container_list\|container_exec" "$OFF_AGENTS/AGENTS.override.md" \
  && _fail "AGENTS.override.md mentions container-exec with CBOX_CONTAINER_EXEC_TOOL=off:
$(cat "$OFF_AGENTS/AGENTS.override.md")"
_ok "inert: AGENTS.override.md carries no container-exec paragraph when the gate is off"

ON_AGENTS="$TMPBASE/agents_on"
_render_codex_agents "$ON_AGENTS" on
grep -q "container-exec MCP tool" "$ON_AGENTS/AGENTS.override.md" \
  || _fail "AGENTS.override.md is missing the container-exec paragraph with CBOX_CONTAINER_EXEC_TOOL=on"
_ok "active: AGENTS.override.md carries the container-exec paragraph when the gate is on"

_render_claude_kernel_block() {
  local out="$1" gate="$2"
  (
    ETC_DIR="$INSTALL_DIR/etc"
    export ETC_DIR
    CLAUDE_MD_KERNEL_MARK_START="<!-- cbox:conduct-kernel:begin -->"
    CLAUDE_MD_KERNEL_MARK_END="<!-- cbox:conduct-kernel:end -->"
    export CLAUDE_MD_KERNEL_MARK_START CLAUDE_MD_KERNEL_MARK_END
    export CBOX_CONTAINER_EXEC_TOOL="$gate"
    source "$INSTALL_DIR/lib/portable.sh"
    die() { echo "die: $*" >&2; exit 1; }
    apply_name_substitution() {
      local src="$1" dst="$2" u name
      u="$(id -un)"
      name="${u^}"
      name="${name//\\/\\\\}"
      name="${name//\//\\/}"
      name="${name//&/\\&}"
      sed "s/{NAME}/$name/g" "$src" > "$dst"
    }
    eval "$(awk '
      /^claude_md_container_exec_paragraph\(\) \{/ { infunc=1 }
      infunc { print }
      infunc && /^\}/ { infunc=0 }
    ' "$INSTALL_DIR/lib/cbox-setup.sh")"
    eval "$(awk '
      /^kernel_lang_rule_line\(\) \{/ { infunc=1 }
      infunc { print }
      infunc && /^\}/ { infunc=0 }
    ' "$INSTALL_DIR/lib/cbox-setup.sh")"
    eval "$(awk '
      /^apply_kernel_lang_rule\(\) \{/ { infunc=1 }
      infunc { print }
      infunc && /^\}/ { infunc=0 }
    ' "$INSTALL_DIR/lib/cbox-setup.sh")"
    eval "$(awk '
      /^claude_md_kernel_block_file\(\) \{/ { infunc=1 }
      infunc { print }
      infunc && /^\}/ { infunc=0 }
    ' "$INSTALL_DIR/lib/cbox-setup.sh")"
    claude_md_kernel_block_file "$out"
  )
}

OFF_KERNEL="$TMPBASE/kernel_off.txt"
_render_claude_kernel_block "$OFF_KERNEL" off
grep -qi "container-exec\|container_list\|container_exec" "$OFF_KERNEL" \
  && _fail "CLAUDE.md kernel block mentions container-exec with CBOX_CONTAINER_EXEC_TOOL=off:
$(cat "$OFF_KERNEL")"
_ok "inert: CLAUDE.md kernel block carries no container-exec paragraph when the gate is off"

ON_KERNEL="$TMPBASE/kernel_on.txt"
_render_claude_kernel_block "$ON_KERNEL" on
grep -q "container-exec MCP tool" "$ON_KERNEL" \
  || _fail "CLAUDE.md kernel block is missing the container-exec paragraph with CBOX_CONTAINER_EXEC_TOOL=on"
_ok "active: CLAUDE.md kernel block carries the container-exec paragraph when the gate is on"

RENDERED_OFF="$TMPBASE/mcp_off.json"
env -u CBOX_CONTAINER_EXEC_TOOL \
  python3 "$INSTALL_DIR/etc/mcp/render_mcp.py" \
  "$INSTALL_DIR/etc/mcp/delegates.json" all "/home/x/.claude/hooks" off claude > "$RENDERED_OFF"
python3 -c "
import json
data = json.load(open('$RENDERED_OFF'))
assert 'container-exec' not in data, data.keys()
"
_ok "inert: no container-exec MCP server entry with the gate off"

grep -q "CBOX_CONTAINER_EXEC_TOOL" "$INSTALL_DIR/templates/conf_lib.sh" \
  || _fail "templates/conf_lib.sh does not carry CBOX_CONTAINER_EXEC_TOOL - regenerate templates/conf_lib.sh from etc/registry/settings.json"
DEFAULT_LINE="$(awk '
  /^_cbox_reg_conf_defaults\(\) \{/ { infunc=1; next }
  infunc && /^\}/ { infunc=0 }
  infunc { print }
' "$INSTALL_DIR/templates/conf_lib.sh" | grep CBOX_CONTAINER_EXEC_TOOL)"
case "$DEFAULT_LINE" in
  *':=off}'*) _ok "inert: registry default for CBOX_CONTAINER_EXEC_TOOL is off" ;;
  *) _fail "registry default for CBOX_CONTAINER_EXEC_TOOL is not off: $DEFAULT_LINE" ;;
esac

echo "PASS: all container_exec_inertness checks"
