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

EXPECTED_LINE="Docker networks here are reachable only through the cbox SOCKS gateway: call cbox-net net_map first, then net_probe; target containers by name over socks5h; never guess IPs or set ALL_PROXY; a down gateway is a host-side fix."

LINE_BYTES="$(printf '%s' "$EXPECTED_LINE" | wc -c)"
[ "$LINE_BYTES" -le 240 ] \
  || _fail "discovery line is $LINE_BYTES bytes, over the 240 byte budget"
_ok "discovery line is $LINE_BYTES bytes, within the 240 byte budget"

_render_codex_agents() {
  local outdir="$1" mode="$2" applied="$3"
  mkdir -p "$outdir"
  (
    INSTALL_DIR="$INSTALL_DIR"
    export INSTALL_DIR
    HOME="$TMPBASE/fake_home_codex_${mode}_${applied}"
    export HOME
    mkdir -p "$HOME"
    export CBOX_NETACCESS_MODE="$mode"
    export CBOX_NETACCESS_APPLIED="$applied"
    source "$INSTALL_DIR/_common.sh"
    source "$INSTALL_DIR/templates/generators.sh"
    gen_codex_agents_into "$outdir"
  )
}

CODEX_OFF="$TMPBASE/codex_off"
_render_codex_agents "$CODEX_OFF" off 0
[ "$(grep -cF "$EXPECTED_LINE" "$CODEX_OFF/AGENTS.override.md")" = 0 ] \
  || _fail "AGENTS.override.md carries the netaccess discovery line with netaccess off:
$(cat "$CODEX_OFF/AGENTS.override.md")"
_ok "inert: AGENTS.override.md carries no netaccess discovery line when netaccess is inactive"

CODEX_ON="$TMPBASE/codex_on"
_render_codex_agents "$CODEX_ON" socks 1
[ "$(grep -cF "$EXPECTED_LINE" "$CODEX_ON/AGENTS.override.md")" = 1 ] \
  || _fail "AGENTS.override.md does not carry the netaccess discovery line exactly once with netaccess active:
$(cat "$CODEX_ON/AGENTS.override.md")"
_ok "active: AGENTS.override.md carries the netaccess discovery line exactly once when netaccess is active"

_render_claude_kernel_block() {
  local out="$1" mode="$2" applied="$3"
  (
    ETC_DIR="$INSTALL_DIR/etc"
    export ETC_DIR
    CLAUDE_MD_KERNEL_MARK_START="<!-- cbox:conduct-kernel:begin -->"
    CLAUDE_MD_KERNEL_MARK_END="<!-- cbox:conduct-kernel:end -->"
    export CLAUDE_MD_KERNEL_MARK_START CLAUDE_MD_KERNEL_MARK_END
    export CBOX_NETACCESS_MODE="$mode"
    export CBOX_NETACCESS_APPLIED="$applied"
    source "$INSTALL_DIR/lib/portable.sh"
    source "$INSTALL_DIR/templates/generators.sh"
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
      /^claude_md_netaccess_line\(\) \{/ { infunc=1 }
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

CLAUDE_OFF="$TMPBASE/claude_off.txt"
_render_claude_kernel_block "$CLAUDE_OFF" off 0
[ "$(grep -cF "$EXPECTED_LINE" "$CLAUDE_OFF")" = 0 ] \
  || _fail "CLAUDE.md kernel block carries the netaccess discovery line with netaccess off:
$(cat "$CLAUDE_OFF")"
_ok "inert: CLAUDE.md kernel block carries no netaccess discovery line when netaccess is inactive"

CLAUDE_ON="$TMPBASE/claude_on.txt"
_render_claude_kernel_block "$CLAUDE_ON" socks 1
[ "$(grep -cF "$EXPECTED_LINE" "$CLAUDE_ON")" = 1 ] \
  || _fail "CLAUDE.md kernel block does not carry the netaccess discovery line exactly once with netaccess active:
$(cat "$CLAUDE_ON")"
_ok "active: CLAUDE.md kernel block carries the netaccess discovery line exactly once when netaccess is active"

_extract_fn() {
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$1"
}

HERMES_FIXTURE_DIR="$TMPBASE/hermes_netmap_fixture"
mkdir -p "$HERMES_FIXTURE_DIR"
HERMES_FN_SRC="$TMPBASE/hermes_netaccess_line.sh"
_extract_fn "$INSTALL_DIR/entrypoint.sh" _hermes_netaccess_line > "$HERMES_FN_SRC"
[ -s "$HERMES_FN_SRC" ] || _fail "could not extract _hermes_netaccess_line from entrypoint.sh"
HERMES_FN_FIXTURE="$TMPBASE/hermes_netaccess_line_fixture.sh"
sed "s#local netmap=/etc/cbox/net/netmap.json#local netmap=$HERMES_FIXTURE_DIR/netmap.json#" \
  "$HERMES_FN_SRC" > "$HERMES_FN_FIXTURE"
grep -q "local netmap=$HERMES_FIXTURE_DIR/netmap.json" "$HERMES_FN_FIXTURE" \
  || _fail "fixture substitution did not rewrite the hardcoded netmap path - check for drift in entrypoint.sh"

HERMES_OUT_MISSING="$(
  source "$HERMES_FN_FIXTURE"
  _hermes_netaccess_line
)"
[ -z "$HERMES_OUT_MISSING" ] \
  || _fail "_hermes_netaccess_line renders non-empty with no netmap file present: $HERMES_OUT_MISSING"
_ok "inert: _hermes_netaccess_line renders empty when the netmap file does not exist"

printf '{}' > "$HERMES_FIXTURE_DIR/netmap.json"
HERMES_OUT_PRESENT="$(
  source "$HERMES_FN_FIXTURE"
  _hermes_netaccess_line
)"
[ "$HERMES_OUT_PRESENT" = "$EXPECTED_LINE" ] \
  || _fail "_hermes_netaccess_line did not render the exact discovery line with a regular netmap file present, got: $HERMES_OUT_PRESENT"
_ok "active: _hermes_netaccess_line renders the exact discovery line when the netmap file is a regular file"

rm -f "$HERMES_FIXTURE_DIR/netmap.json"
ln -s /nonexistent-target "$HERMES_FIXTURE_DIR/netmap.json"
HERMES_OUT_SYMLINK="$(
  source "$HERMES_FN_FIXTURE"
  _hermes_netaccess_line
)"
[ -z "$HERMES_OUT_SYMLINK" ] \
  || _fail "_hermes_netaccess_line renders non-empty when the netmap path is a symlink, got: $HERMES_OUT_SYMLINK"
_ok "inert: _hermes_netaccess_line renders empty when the netmap path is a symlink, not a regular file"

_hermes_compose_probe() {
  awk '
    /^_hermes_compose_session_prompt\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/entrypoint.sh"
}
[ -n "$(_hermes_compose_probe)" ] \
  || _fail "could not extract _hermes_compose_session_prompt from entrypoint.sh - composition anchor drifted"
grep -qF '_hermes_netaccess_line="$(_hermes_netaccess_line)"' "$INSTALL_DIR/entrypoint.sh" \
  || _fail "entrypoint.sh no longer calls _hermes_netaccess_line into the hermes session prompt composition"
_ok "composition: entrypoint.sh's hermes verb calls _hermes_netaccess_line and folds a non-empty result into the session prompt"

echo "PASS: all net_discovery_line checks"
