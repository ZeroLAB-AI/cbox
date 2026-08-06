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

REG="$INSTALL_DIR/etc/registry/settings.json"
python3 -c "
import json
d = json.load(open('$REG'))
v = [x for x in d['variables'] if x['key'] == 'CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG']
assert len(v) == 1, v
v = v[0]
assert v['section'] == 'mounts', v
assert v['type']['kind'] == 'enum-or-empty', v
assert sorted(v['type']['values']) == ['off', 'on'], v
assert v['default'] == '', v
assert v['export'] is False, v
"
_ok "registry variable CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG is declared with the three-state enum-or-empty shape"

_scratch_install_dir() {
  local scratch="$1"
  mkdir -p "$scratch/home"
  ln -s "$INSTALL_DIR/etc" "$scratch/etc"
  ln -s "$INSTALL_DIR/_common.sh" "$scratch/_common.sh"
  ln -s "$INSTALL_DIR/templates" "$scratch/templates"
}

_run_seed() {
  local scratch="$1" flag="$2"
  (
    export HOME="$scratch/home"
    export INSTALL_DIR="$scratch"
    export CBOX_CLAUDE_SWITCH_MODELS_ON_FLAG="$flag"
    export CBOX_MCP_SERVERS="all"
    export CBOX_CODEX_PROGRESS_MODE="off"
    export CBOX_CLAUDE_MODE="volume"
    . "$scratch/templates/generators.sh"
    gen_claude_json_seed
  )
}

test_fresh_install_no_flag_key() {
  local scratch="$TMPBASE/fresh_default"
  _scratch_install_dir "$scratch"
  _run_seed "$scratch" ""
  local target="$scratch/generated/state/claude.json"
  [ -f "$target" ] || _fail "fresh install: seed file not created"
  python3 -c "
import json
d = json.load(open('$target'))
assert 'switchModelsOnFlag' not in d, d
assert d['hasCompletedOnboarding'] is True, d
assert 'mcpServers' in d, d
"
  _ok "fresh install, gate empty: switchModelsOnFlag is absent, existing shape preserved exactly"
}

test_fresh_install_flag_on() {
  local scratch="$TMPBASE/fresh_on"
  _scratch_install_dir "$scratch"
  _run_seed "$scratch" "on"
  local target="$scratch/generated/state/claude.json"
  python3 -c "
import json
d = json.load(open('$target'))
assert d['switchModelsOnFlag'] is True, d
"
  _ok "fresh install, gate=on: switchModelsOnFlag is written true"
}

test_fresh_install_flag_off() {
  local scratch="$TMPBASE/fresh_off"
  _scratch_install_dir "$scratch"
  _run_seed "$scratch" "off"
  local target="$scratch/generated/state/claude.json"
  python3 -c "
import json
d = json.load(open('$target'))
assert d['switchModelsOnFlag'] is False, d
"
  _ok "fresh install, gate=off: switchModelsOnFlag is written false"
}

test_existing_file_without_key_gets_added() {
  local scratch="$TMPBASE/existing_no_key"
  _scratch_install_dir "$scratch"
  local target="$scratch/generated/state/claude.json"
  mkdir -p "$(dirname "$target")"
  printf '{"hasCompletedOnboarding":true,"mcpServers":{},"someUserKey":"keep-me"}' > "$target"
  _run_seed "$scratch" "on"
  python3 -c "
import json
d = json.load(open('$target'))
assert d['switchModelsOnFlag'] is True, d
assert d['someUserKey'] == 'keep-me', d
assert d['hasCompletedOnboarding'] is True, d
"
  _ok "existing seed without the key, gate=on: key added, rest of the file untouched"
}

test_existing_file_with_key_false_stays_false() {
  local scratch="$TMPBASE/existing_key_false"
  _scratch_install_dir "$scratch"
  local target="$scratch/generated/state/claude.json"
  mkdir -p "$(dirname "$target")"
  printf '{"hasCompletedOnboarding":true,"mcpServers":{},"switchModelsOnFlag":false}' > "$target"
  _run_seed "$scratch" "on"
  python3 -c "
import json
d = json.load(open('$target'))
assert d['switchModelsOnFlag'] is False, d
"
  _ok "existing seed with switchModelsOnFlag already false, gate=on: cbox never overwrites a value the user set"
}

test_existing_file_with_key_true_stays_true_when_gate_off() {
  local scratch="$TMPBASE/existing_key_true"
  _scratch_install_dir "$scratch"
  local target="$scratch/generated/state/claude.json"
  mkdir -p "$(dirname "$target")"
  printf '{"hasCompletedOnboarding":true,"mcpServers":{},"switchModelsOnFlag":true}' > "$target"
  _run_seed "$scratch" "off"
  python3 -c "
import json
d = json.load(open('$target'))
assert d['switchModelsOnFlag'] is True, d
"
  _ok "existing seed with switchModelsOnFlag already true, gate=off: cbox never overwrites a value the user set"
}

test_existing_file_gate_empty_no_change() {
  local scratch="$TMPBASE/existing_gate_empty"
  _scratch_install_dir "$scratch"
  local target="$scratch/generated/state/claude.json"
  mkdir -p "$(dirname "$target")"
  printf '{"hasCompletedOnboarding":true,"mcpServers":{}}' > "$target"
  local before after
  before="$(sha256sum "$target" | awk '{print $1}')"
  _run_seed "$scratch" ""
  after="$(sha256sum "$target" | awk '{print $1}')"
  [ "$before" = "$after" ] || _fail "gate empty must leave an existing seed byte-identical"
  _ok "existing seed, gate empty (default): file left byte-identical"
}

test_gate_toggle_after_first_write_does_not_flip() {
  local scratch="$TMPBASE/toggle_after"
  _scratch_install_dir "$scratch"
  local target="$scratch/generated/state/claude.json"
  _run_seed "$scratch" "on"
  python3 -c "
import json
d = json.load(open('$target'))
assert d['switchModelsOnFlag'] is True, d
"
  _run_seed "$scratch" "off"
  python3 -c "
import json
d = json.load(open('$target'))
assert d['switchModelsOnFlag'] is True, d
"
  _ok "an operator flip of the gate after the seed already exists does not overwrite the on-disk value"
}

test_fresh_install_no_flag_key
test_fresh_install_flag_on
test_fresh_install_flag_off
test_existing_file_without_key_gets_added
test_existing_file_with_key_false_stays_false
test_existing_file_with_key_true_stays_true_when_gate_off
test_existing_file_gate_empty_no_change
test_gate_toggle_after_first_write_does_not_flip

echo "PASS: all claude switchModelsOnFlag merge tests"
