#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

export HOME="$TMPBASE/home"
mkdir -p "$HOME"

set +eu
. "$INSTALL_DIR/lib/cbox-setup.sh" >/dev/null 2>&1
. "$INSTALL_DIR/templates/generators.sh" >/dev/null 2>&1
set -eu

SEC_AUTO=1
CBOX_HERMES=off

body="$TMPBASE/body"
gen_bashrc > "$body"

: > "$HOME/.bashrc"
: > "$HOME/.zshrc"

_install_rc_block "$HOME/.bashrc" "$HOME/.bashrc-cbox" '$HOME/.bashrc-cbox' "$body" >/dev/null 2>&1
_install_rc_block "$HOME/.zshrc"  "$HOME/.zshrc-cbox"  '$HOME/.zshrc-cbox'  "$body" >/dev/null 2>&1

[ "$(grep -cF "$MARK_START" "$HOME/.bashrc")" = 1 ] || _fail "bashrc marker not installed exactly once"
[ "$(grep -cF "$MARK_START" "$HOME/.zshrc")" = 1 ]  || _fail "zshrc marker not installed exactly once"
[ -f "$HOME/.bashrc-cbox" ] || _fail "bashrc-cbox body not written"
[ -f "$HOME/.zshrc-cbox" ]  || _fail "zshrc-cbox body not written"
grep -qF 'bashrc-cbox' "$HOME/.bashrc" || _fail "bashrc does not source bashrc-cbox"
grep -qF 'zshrc-cbox'  "$HOME/.zshrc"  || _fail "zshrc does not source zshrc-cbox"
grep -qF 'zshrc-cbox' "$HOME/.bashrc" && _fail "bashrc wrongly sources the zsh rc file"
grep -qF 'bashrc-cbox' "$HOME/.zshrc" && _fail "zshrc wrongly sources the bash rc file"
_ok "install: bash and zsh each get one marker block sourcing their own rc-cbox file"

grep -qF 'cbox() {' "$HOME/.bashrc-cbox" || _fail "cbox function missing from rc-cbox body"
_ok "install: cbox wrapper function present (mandatory)"

sel_all="$TMPBASE/sel_all"
CBOX_BASHRC_COMMANDS=all CBOX_HERMES=on gen_bashrc > "$sel_all"
grep -qF 'cbox() {' "$sel_all" && grep -qF 'claude() {' "$sel_all" && grep -qF 'codex() {' "$sel_all" && grep -qF 'hermes() {' "$sel_all" \
  || _fail "'all' should emit cbox+claude+codex+hermes wrappers"
_ok "chooser: 'all' emits every wrapper"

sel_one="$TMPBASE/sel_one"
CBOX_BASHRC_COMMANDS="codex" CBOX_HERMES=off gen_bashrc > "$sel_one"
grep -qF 'cbox() {' "$sel_one" || _fail "cbox wrapper must always be present even for a narrow selection"
grep -qF 'codex() {' "$sel_one" || _fail "selected codex wrapper missing"
grep -qF 'claude() {' "$sel_one" && _fail "claude wrapper emitted though only codex was selected"
_ok "chooser: a narrow selection emits only the chosen wrappers plus the mandatory cbox"

sel_none="$TMPBASE/sel_none"
CBOX_BASHRC_COMMANDS="none" CBOX_HERMES=on gen_bashrc > "$sel_none"
grep -qF 'cbox() {' "$sel_none" || _fail "cbox wrapper must be present even when no engines are selected"
grep -qF 'claude() {' "$sel_none" && _fail "'none' must not emit claude"
grep -qF 'codex() {' "$sel_none" && _fail "'none' must not emit codex"
grep -qF 'hermes() {' "$sel_none" && _fail "'none' must not emit hermes"
_ok "chooser: 'none' (deselect all) installs only the mandatory cbox, no engine wrappers"

sel_hoff="$TMPBASE/sel_hoff"
CBOX_BASHRC_COMMANDS="all" CBOX_HERMES=off gen_bashrc > "$sel_hoff"
grep -qF 'hermes() {' "$sel_hoff" && _fail "hermes wrapper emitted with the engine off, despite 'all'"
grep -qF 'claude() {' "$sel_hoff" || _fail "'all' with hermes off should still emit claude"
_ok "chooser: hermes double-gate - 'all' with the hermes engine off excludes the hermes wrapper"

DUPE="$HOME/dupe"
printf '%s\nkeep-me\n%s\ntail\n%s\n%s\n' "$MARK_START" "$MARK_END" "$MARK_START" "$MARK_END" > "$DUPE"
if merge_bashrc_block "$DUPE" '$HOME/.bashrc-cbox' >/dev/null 2>&1; then
  _fail "merge accepted a file with two MARK_START blocks (data-loss risk)"
fi
grep -qF 'keep-me' "$DUPE" || _fail "refused merge still dropped content between duplicate markers"
_ok "security: merge refuses a file with more than one cbox marker start, content preserved"

uninstall_bashrc >/dev/null 2>&1
grep -qF "$MARK_START" "$HOME/.bashrc" && _fail "bashrc marker survived uninstall"
grep -qF "$MARK_START" "$HOME/.zshrc"  && _fail "zshrc marker survived uninstall"
_ok "uninstall: removes the marker block from both bash and zsh"

echo "PASS: all bashrc chooser checks"
