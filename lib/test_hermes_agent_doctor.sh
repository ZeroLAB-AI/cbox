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

BLOCK="$TMPBASE/hermes_agent_block.sh"
awk '
  /^[[:space:]]*if \[ "\$\{CBOX_HERMES_DELEGATE:-off\}" = on \]; then$/ { start=1 }
  start {
    print
    if ($0 ~ /^[[:space:]]*if[[:space:]].*; then$/) depth++
    if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
      depth--
      if (depth == 0) exit
    }
  }
' "$INSTALL_DIR/cbox" > "$BLOCK"

[ -s "$BLOCK" ] || _fail "could not extract the hermes-delegate/hermes-agent doctor block from cbox - start/end markers changed"
grep -q 'hermes-agent' "$BLOCK" || _fail "extracted block does not mention hermes-agent - extraction anchors are stale"

HARNESS="$TMPBASE/harness.sh"
{
  echo '_cbox_doctor_row() { printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$ROWS_OUT"; }'
  echo 'hermes_agent_test_block() {'
  cat "$BLOCK"
  echo '}'
  echo 'hermes_agent_test_block'
} > "$HARNESS"

_run_case() {
  local rows_out="$TMPBASE/rows.out"
  : > "$rows_out"
  ROWS_OUT="$rows_out" \
  INSTALL_DIR="$1" home="$2" claude_dir="$2/.claude" in_container="$3" \
  CBOX_HERMES_DELEGATE="${4:-}" CBOX_HERMES="${5:-}" CBOX_CLAUDE_MODE="${6:-mount}" \
  CBOX_CLAUDE_PATH="${7:-}" \
  bash "$HARNESS"
  cat "$rows_out"
}

_row_status() {
  awk -F'\t' -v row="$1" '$1 == row { print $2 }' "$TMPBASE/rows.out"
}

_row_detail() {
  awk -F'\t' -v row="$1" '$1 == row { print $3 }' "$TMPBASE/rows.out"
}

FAKE_INSTALL="$TMPBASE/install"
FAKE_HOME="$TMPBASE/home"
mkdir -p "$FAKE_INSTALL/generated/claude-config" "$FAKE_HOME"

_run_case "$FAKE_INSTALL" "$FAKE_HOME" 0 off off mount "" >/dev/null
[ "$(_row_status hermes-delegate)" = OFF ] || _fail "off scenario: hermes-delegate row should be OFF, got $(_row_status hermes-delegate)"
[ "$(_row_status hermes-agent)" = OFF ] || _fail "off scenario: hermes-agent row should be OFF, got $(_row_status hermes-agent)"
_ok "CBOX_HERMES_DELEGATE off: both hermes-delegate and hermes-agent rows report OFF"

CLAUDE_PATH_PRESENT="$TMPBASE/claude-present"
mkdir -p "$CLAUDE_PATH_PRESENT/agents"
echo 'stub' > "$CLAUDE_PATH_PRESENT/agents/hermes-local.md"
echo '{"mcpServers":{"hermes-local":{}}}' > "$FAKE_INSTALL/generated/claude-config/.claude.json"

_run_case "$FAKE_INSTALL" "$FAKE_HOME" 0 on on mount "$CLAUDE_PATH_PRESENT" >/dev/null
[ "$(_row_status hermes-delegate)" = ACTIVE ] || _fail "present scenario: hermes-delegate row should be ACTIVE, got $(_row_status hermes-delegate)"
[ "$(_row_status hermes-agent)" = ACTIVE ] || _fail "present scenario: hermes-agent row should be ACTIVE, got $(_row_status hermes-agent)"
case "$(_row_detail hermes-agent)" in
  *"$CLAUDE_PATH_PRESENT/agents"*) ;;
  *) _fail "present scenario: hermes-agent detail should name $CLAUDE_PATH_PRESENT/agents, got: $(_row_detail hermes-agent)" ;;
esac
_ok "hermes-local.md present under CBOX_CLAUDE_PATH/agents: hermes-agent row reports ACTIVE"

CLAUDE_PATH_MISSING="$TMPBASE/claude-missing"
mkdir -p "$CLAUDE_PATH_MISSING/agents"

_run_case "$FAKE_INSTALL" "$FAKE_HOME" 0 on on mount "$CLAUDE_PATH_MISSING" >/dev/null
[ "$(_row_status hermes-delegate)" = ACTIVE ] || _fail "missing-agent scenario: hermes-delegate row should stay ACTIVE, got $(_row_status hermes-delegate)"
[ "$(_row_status hermes-agent)" = CONFIG-ONLY ] || _fail "missing-agent scenario: hermes-agent row should be CONFIG-ONLY, got $(_row_status hermes-agent)"
case "$(_row_detail hermes-agent)" in
  *"cbox setup update agents"*) ;;
  *) _fail "missing-agent scenario: fix command 'cbox setup update agents' missing from detail: $(_row_detail hermes-agent)" ;;
esac
_ok "hermes-local tool rendered but hermes-local.md absent: hermes-agent row is CONFIG-ONLY and names 'cbox setup update agents'"

IN_CONTAINER_HOME="$TMPBASE/incontainer-home"
mkdir -p "$IN_CONTAINER_HOME/.claude/agents"
_run_case "$FAKE_INSTALL" "$IN_CONTAINER_HOME" 1 on on mount "" >/dev/null
[ "$(_row_status hermes-agent)" = CONFIG-ONLY ] || _fail "in-container missing scenario: hermes-agent row should be CONFIG-ONLY, got $(_row_status hermes-agent)"
case "$(_row_detail hermes-agent)" in
  *"$IN_CONTAINER_HOME/.claude/agents"*) ;;
  *) _fail "in-container missing scenario: detail should name \$HOME/.claude/agents, got: $(_row_detail hermes-agent)" ;;
esac
echo 'stub' > "$IN_CONTAINER_HOME/.claude/agents/hermes-local.md"
_run_case "$FAKE_INSTALL" "$IN_CONTAINER_HOME" 1 on on mount "" >/dev/null
[ "$(_row_status hermes-agent)" = ACTIVE ] || _fail "in-container present scenario: hermes-agent row should be ACTIVE, got $(_row_status hermes-agent)"
_ok "in-container path resolves against \$HOME/.claude/agents (not CBOX_CLAUDE_PATH): missing then present both report correctly"

echo "PASS: all hermes-agent doctor checks"
