#!/usr/bin/env bash
set -euo pipefail

while IFS='=' read -r name _; do
  case "$name" in
    CBOX_*) unset "$name" ;;
  esac
done < <(env)

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'find "$TMPBASE" -depth -delete' EXIT
HOME="$TMPBASE/home"
HOST_HOME="$HOME"
CBOX_CLAUDE_MODE=mount
CBOX_CLAUDE_PATH="$HOME/.claude"
GEN_DIR="$TMPBASE/generated"
ETC_DIR="$INSTALL_DIR/etc"
CLAUDE_MD_KERNEL_MARK_START='<!-- cbox:conduct-kernel:begin -->'
CLAUDE_MD_KERNEL_MARK_END='<!-- cbox:conduct-kernel:end -->'
export HOME HOST_HOME CBOX_CLAUDE_MODE CBOX_CLAUDE_PATH GEN_DIR ETC_DIR INSTALL_DIR
mkdir -p "$HOME/.claude" "$HOME/.codex"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract_fn() {
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^\}/ { inside=0 }
  ' "$1"
}

line_for() {
  printf "For cbox setup, config, features or troubleshooting, read %s/.claude/cbox-docs/MANUAL.md: grep '^#' for sections, then read the section; cbox commands run on the host." "$1"
}

bytes="$(line_for /home/marek | wc -c)"
[ "$bytes" -le 240 ] || fail "discovery line is $bytes bytes"

source "$INSTALL_DIR/_common.sh"
source "$INSTALL_DIR/templates/generators.sh"
eval "$(extract_fn "$INSTALL_DIR/lib/cbox-setup.sh" _cbox_write_local)"
eval "$(extract_fn "$INSTALL_DIR/lib/cbox-setup.sh" claude_md_deploy_docs)"
eval "$(extract_fn "$INSTALL_DIR/lib/cbox-setup.sh" claude_md_kernel_block_file)"
eval "$(extract_fn "$INSTALL_DIR/entrypoint.sh" _hermes_manual_line)"
HERMES_APPEND="$(awk '
  /^    _hermes_manual_line="\$\(_hermes_manual_line\)"$/ { inside=1 }
  inside { print }
  inside && /^    fi$/ { exit }
' "$INSTALL_DIR/entrypoint.sh")"
[ -n "$HERMES_APPEND" ] || fail "Hermes prompt append missing"
die() { fail "$*"; }
apply_name_substitution() { cp "$1" "$2"; }
apply_kernel_lang_rule() { :; }
claude_md_container_exec_paragraph() { :; }
claude_md_netaccess_line() { :; }

render_all() {
  local label="$1"
  local _hermes_session_prompt=base _hermes_manual_line
  claude_md_kernel_block_file "$TMPBASE/claude_$label"
  gen_codex_agents_into "$TMPBASE/codex_$label"
  eval "$HERMES_APPEND"
  printf '%s\n' "$_hermes_session_prompt" > "$TMPBASE/hermes_$label"
}

assert_count() {
  local label="$1" expected="$2" file count
  for file in "$TMPBASE/claude_$label" "$TMPBASE/codex_$label/AGENTS.override.md" "$TMPBASE/hermes_$label"; do
    count="$(grep -cF "$(line_for "$HOST_HOME")" "$file" || true)"
    [ "$count" = "$expected" ] || fail "$file has $count manual lines, expected $expected"
  done
}

render_all absent
assert_count absent 0

claude_md_deploy_docs "$CBOX_CLAUDE_PATH/cbox-docs"
claude_md_deploy_docs "$GEN_DIR/claude/cbox-docs"
for base in "$CBOX_CLAUDE_PATH/cbox-docs" "$GEN_DIR/claude/cbox-docs"; do
  cmp -s "$INSTALL_DIR/MANUAL.md" "$base/MANUAL.md" || fail "MANUAL.md deploy differs"
  cmp -s "$INSTALL_DIR/README.md" "$base/README.md" || fail "README.md deploy differs"
done
grep -qF 'claude_md_deploy_docs "$CBOX_CLAUDE_PATH/cbox-docs"' "$INSTALL_DIR/lib/cbox-setup.sh" || fail "mount deploy call missing"
grep -qF 'claude_md_deploy_docs "$GEN_DIR/claude/cbox-docs"' "$INSTALL_DIR/lib/cbox-setup.sh" || fail "volume deploy call missing"

render_all present
assert_count present 1

mv "$CBOX_CLAUDE_PATH/cbox-docs/MANUAL.md" "$CBOX_CLAUDE_PATH/cbox-docs/MANUAL.saved"
ln -s MANUAL.saved "$CBOX_CLAUDE_PATH/cbox-docs/MANUAL.md"
render_all symlink
assert_count symlink 0

python3 - "$INSTALL_DIR/templates/generators.sh" <<'PY' || fail "templates binds are not paired with read-only cbox-docs binds"
import sys

lines = open(sys.argv[1], encoding="ascii").read().splitlines()
binds = [i for i, line in enumerate(lines) if line.startswith("      - ") and "/templates:" in line and line.endswith("/templates:ro")]
assert len(binds) == 6, binds
for i in binds:
    expected = lines[i].replace("/templates:", "/cbox-docs:").replace("/templates:ro", "/cbox-docs:ro")
    assert lines[i + 1] == expected, (i, lines[i + 1], expected)
PY

printf 'PASS: cbox manual discovery (%s bytes at /home/marek), deploy and six read-only binds\n' "$bytes"
