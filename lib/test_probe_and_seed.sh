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

PROBE_SH="$(sed -n "/^_CBOX_PROBE_SH='\$/,/^'\$/p" "$INSTALL_DIR/cbox" | sed '1d;$d')"
[ -n "$PROBE_SH" ] || _fail "probe: cannot extract _CBOX_PROBE_SH from cbox"

H="$TMPBASE/home"
PROC="$TMPBASE/proc"
CLAUDE_BIN="$H/.local/share/claude/versions/9.9.9"
CODEX_BIN="$H/.codex/packages/standalone/releases/9.9.9/bin/codex"
mkdir -p "$H/.local" "$H/.codex/packages" "$(dirname "$CLAUDE_BIN")" "$(dirname "$CODEX_BIN")"
printf 'x\n%s\n' "$CLAUDE_BIN" > "$H/.local/.cbox-stamp"
printf 'x\n%s\n' "$CODEX_BIN" > "$H/.codex/packages/.cbox-stamp"
: > "$CLAUDE_BIN"
: > "$CODEX_BIN"

_mkproc() {
  local pid="$1" exe="$2"; shift 2
  mkdir -p "$PROC/$pid"
  ln -s "$exe" "$PROC/$pid/exe"
  { printf '%s' "$exe"; local a; for a in "$@"; do printf '\0%s' "$a"; done; printf '\0'; } > "$PROC/$pid/cmdline"
}

_mkproc 11 "$CLAUDE_BIN"
_mkproc 12 "$CLAUDE_BIN" --session-id abc --fork-session --resume /x/y.jsonl
_mkproc 13 "$CLAUDE_BIN" daemon run --origin transient
_mkproc 14 "$CLAUDE_BIN" --bg-pty-host /tmp/x.sock 200 50
_mkproc 15 "$CLAUDE_BIN" --bg-spare /tmp/y.sock
_mkproc 21 "$CODEX_BIN" mcp-server
_mkproc 22 "$CODEX_BIN" exec do-something
_mkproc 23 "$CODEX_BIN"
_mkproc 31 /usr/bin/sh -c sleep

n="$(HOST_HOME="$H" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 4 ] || _fail "probe: expected 4 live (interactive claude, bg job, codex exec, codex interactive), got $n"
_ok "probe filter: 4 live of 9 procs (daemon, pty-host, spare, mcp-server, foreign skipped)"

rm -f "$PROC/12/cmdline"
n="$(HOST_HOME="$H" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 3 ] || _fail "probe: vanished cmdline should be skipped, got $n"
_ok "probe filter: missing cmdline skipped"

export CBOX_CODEX_PROGRESS_MODE=off CBOX_CLAUDE_MODE=mount CBOX_MCP_SERVERS=all
export HOME="$H"
. "$INSTALL_DIR/_common.sh"
. "$INSTALL_DIR/templates/generators.sh"

S="$TMPBASE/seed"
mkdir -p "$S/cfg" "$S/state"
printf '{"projects":{"/p":{"hasTrustDialogAccepted":true}}}' > "$S/cfg/.claude.json.migrate"
printf '{"legacy":1}' > "$S/state/claude-cbox.json"
gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
python3 - "$S/cfg/.claude.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["projects"]["/p"]["hasTrustDialogAccepted"] is True, d
assert d["hasCompletedOnboarding"] is True, d
assert d["mcpServers"], d
assert "legacy" not in d, d
PY
[ ! -e "$S/cfg/.claude.json.migrate" ] || _fail "seed: migrate file not consumed"
_ok "seed: migrate adopted (trust kept, mcpServers rendered, migrate consumed)"

rm "$S/cfg/.claude.json"
gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
python3 - "$S/cfg/.claude.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["legacy"] == 1, d
assert d["mcpServers"], d
PY
_ok "seed: legacy state adopted when no migrate file"

printf '{"containerKey":"kept"}' > "$S/cfg/.claude.json"
printf 'STALE' > "$S/cfg/.claude.json.migrate"
gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
python3 - "$S/cfg/.claude.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["containerKey"] == "kept", d
assert d["mcpServers"], d
PY
[ ! -e "$S/cfg/.claude.json.migrate" ] || _fail "seed: stale migrate not removed"
_ok "seed: existing state kept, stale migrate removed"

G="$TMPBASE/gen"
mkdir -p "$G/eff/claude-config/projects" "$G/claude" "$G/codex" "$G/fakeproj"
FR="$G/fakeproj"
SLUG="$(_cbox_slug "$FR")"
ln -s "../.host-projects/$SLUG" "$G/eff/claude-config/projects/$SLUG"
(
  export CBOX_CLAUDE_MODE=mount CBOX_CODEX_MODE=mount CBOX_SESSION_SCOPE=isolated
  export CBOX_CLAUDE_PATH="$G/claude" CBOX_CODEX_PATH="$G/codex"
  gen_compose_isolated "$G/eff" "$FR" testimg testhash123456 >/dev/null 2>&1
)
[ ! -L "$G/eff/claude-config/projects/$SLUG" ] || _fail "compose: stale symlink survived"
[ -d "$G/eff/claude-config/projects/$SLUG" ] || _fail "compose: slug target is not a real dir"
grep -q "claude-cbox/projects/$SLUG" "$G/eff/docker-compose.yml" || _fail "compose: slug bind missing"
! grep -q 'state/claude-cbox.json' "$G/eff/docker-compose.yml" || _fail "compose: legacy file bind still emitted"
_ok "compose: stale symlink replaced by real dir, slug bind present, file bind gone"

echo "PASS: all probe+seed+compose checks"
