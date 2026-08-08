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

_mkproc_argv0() {
  local pid="$1" exe="$2" argv0="$3"; shift 3
  mkdir -p "$PROC/$pid"
  ln -s "$exe" "$PROC/$pid/exe"
  { printf '%s' "$argv0"; local a; for a in "$@"; do printf '\0%s' "$a"; done; printf '\0'; } > "$PROC/$pid/cmdline"
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

n="$(CBOX_PROBE_CP="$CLAUDE_BIN" CBOX_PROBE_XP="$CODEX_BIN" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 4 ] || _fail "probe: expected 4 live (interactive claude, bg job, codex exec, codex interactive), got $n"
_ok "probe filter: 4 live of 9 procs (daemon, pty-host, spare, mcp-server, foreign skipped)"

rm -f "$PROC/12/cmdline"
n="$(CBOX_PROBE_CP="$CLAUDE_BIN" CBOX_PROBE_XP="$CODEX_BIN" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 3 ] || _fail "probe: vanished cmdline should be skipped, got $n"
_ok "probe filter: missing cmdline skipped"

rm -rf "$PROC"
_mkproc 11 "$CLAUDE_BIN"
_mkproc 21 "$CODEX_BIN" exec do-something
_mkproc_argv0 41 /usr/bin/python3.12 /opt/hermes/bin/python3 /opt/hermes/bin/hermes
n="$(CBOX_PROBE_CP="$CLAUDE_BIN" CBOX_PROBE_XP="$CODEX_BIN" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 3 ] || _fail "probe: expected 3 live (claude, codex exec, venv-shebang hermes), got $n"
_ok "probe filter: venv-shebang hermes proc (exe /usr/bin/python3.12, argv0 /opt/hermes/bin/python3, argv1 /opt/hermes/bin/hermes) is counted"

_mkproc_argv0 42 /usr/bin/python3.12 /opt/hermes/bin/python3 /opt/hermes/bin/hermes -z
n="$(CBOX_PROBE_CP="$CLAUDE_BIN" CBOX_PROBE_XP="$CODEX_BIN" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 4 ] || _fail "probe: expected 4 live (3 prior + hermes -z one-shot), got $n"
_ok "probe filter: hermes -z one-shot invocation is also counted (no exclusions, bias toward counting)"

_mkproc_argv0 43 /usr/bin/python3 /usr/bin/python3 /some/other/script.py
n="$(CBOX_PROBE_CP="$CLAUDE_BIN" CBOX_PROBE_XP="$CODEX_BIN" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 4 ] || _fail "probe: unrelated python3 process (argv0 /usr/bin/python3, not /opt/hermes/bin/*) must not be counted, got $n"
_ok "probe filter: unrelated python3 process (argv0 /usr/bin/python3) is not counted as hermes"

_mkproc_argv0 44 /opt/hermes/bin/python3 /opt/hermes/bin/python3 /opt/hermes/bin/hermes
n="$(CBOX_PROBE_CP="$CLAUDE_BIN" CBOX_PROBE_XP="$CODEX_BIN" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 5 ] || _fail "probe: expected 5 live (4 prior + --copies-venv hermes, exe resolves to /opt/hermes/bin/python3 itself), got $n"
_ok "probe filter: --copies-venv hermes proc (exe /opt/hermes/bin/python3, argv0 /opt/hermes/bin/python3, argv1 /opt/hermes/bin/hermes) is counted"

rm -rf "$PROC"
_mkproc 11 "$CLAUDE_BIN"
_mkproc 21 "$CODEX_BIN" exec do-something
printf 'x\n/tmp/bogus-tampered-path\n' > "$H/.local/.cbox-stamp"
printf 'x\n/tmp/bogus-tampered-path\n' > "$H/.codex/packages/.cbox-stamp"
n="$(CBOX_PROBE_CP="$CLAUDE_BIN" CBOX_PROBE_XP="$CODEX_BIN" HOST_HOME="$H" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 2 ] || _fail "probe A0: tampered stamp must NOT change the count - env is the source of truth, got $n (expected 2)"
_ok "probe A0: container-tampered stamp lines are ignored; expected exe paths come from the env, not the stamp"

n="$(CBOX_PROBE_CP="" CBOX_PROBE_XP="" HOST_HOME="$H" sh -c "${PROBE_SH//\/proc\//$PROC/}")"
[ "$n" = 0 ] || _fail "probe A0: empty env cp/xp must not match claude/codex from the stamp, got $n (expected 0)"
_ok "probe A0: with empty env the heredoc counts no claude/codex (stamp is never read)"

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
_ok "seed: existing state kept, invalid migrate discarded"

printf '{"containerKey":"old","projects":{"/q":{"hasTrustDialogAccepted":true}}}' > "$S/cfg/.claude.json.migrate"
gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
python3 - "$S/cfg/.claude.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["projects"]["/q"]["hasTrustDialogAccepted"] is True, d
assert d["containerKey"] == "old", d
assert d["mcpServers"], d
PY
[ ! -e "$S/cfg/.claude.json.migrate" ] || _fail "seed: valid migrate not consumed"
_ok "seed: valid migrate adopted over existing state (operator import wins)"

VICTIM="$TMPBASE/victim-host-secret"
printf 'HOST SECRET - must survive\n' > "$VICTIM"
rm -f "$S/cfg/.claude.json" "$S/cfg/.claude.json.migrate"
ln -s "$VICTIM" "$S/cfg/.claude.json.migrate"
gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
[ "$(cat "$VICTIM")" = "HOST SECRET - must survive" ] || _fail "seed: symlinked migrate followed - host file was read/adopted"
[ ! -L "$S/cfg/.claude.json" ] || _fail "seed: target became a symlink"
python3 - "$S/cfg/.claude.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mcpServers"], d
PY
_ok "seed: symlinked migrate is not followed (no host-file traversal)"

printf 'HOST SECRET - must survive\n' > "$VICTIM"
rm -f "$S/cfg/.claude.json" "$S/cfg/.claude.json.migrate"
ln -s "$VICTIM" "$S/cfg/.claude.json"
gen_claude_cbox_json_seed_into "$S/cfg/.claude.json" "$S/state/claude-cbox.json"
[ "$(cat "$VICTIM")" = "HOST SECRET - must survive" ] || _fail "seed: symlinked target followed - host file overwritten"
[ ! -L "$S/cfg/.claude.json" ] || _fail "seed: symlinked target survived (write followed the link)"
_ok "seed: symlinked target replaced in place, host file untouched"

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

PF="$TMPBASE/probefns.sh"
sed -n '/^_cbox_probe_exes_file() {/,/^}/p;/^_probe() {/,/^}/p' "$INSTALL_DIR/cbox" > "$PF"
grep -q '^_probe() {' "$PF" || _fail "probe A0: cannot extract _probe from cbox"
grep -q '^_cbox_probe_exes_file() {' "$PF" || _fail "probe A0: cannot extract _cbox_probe_exes_file from cbox"
. "$PF"

PE="$TMPBASE/effnocache"
mkdir -p "$PE"
rc="$(_probe fakecid "$PE")"
[ "$rc" = unknown ] || _fail "probe A0 fail-safe: missing cache file must yield 'unknown', not '$rc' (a 0 here would trigger reap teardown)"
_ok "probe A0 fail-safe: missing probe-exes cache -> 'unknown' (never 0), so a wiped/absent cache cannot trigger a teardown"

rc="$(_probe fakecid "")"
[ "$rc" = unknown ] || _fail "probe A0 fail-safe: empty eff arg must yield 'unknown', not '$rc'"
_ok "probe A0 fail-safe: empty eff -> 'unknown'"

printf '\n\n' > "$PE/probe-exes"
rc="$(_probe fakecid "$PE")"
[ "$rc" = unknown ] || _fail "probe A0 fail-safe: empty cache lines must yield 'unknown', not '$rc'"
_ok "probe A0 fail-safe: empty cache lines -> 'unknown'"

RF="$TMPBASE/refreshfns.sh"
sed -n '/^_cbox_probe_exes_file() {/,/^}/p;/^_cbox_probe_exes_refresh() {/,/^}/p' "$INSTALL_DIR/cbox" > "$RF"
grep -q '^_cbox_probe_exes_refresh() {' "$RF" || _fail "probe A0: cannot extract _cbox_probe_exes_refresh from cbox"
. "$RF"

STUBDIR="$TMPBASE/stubbin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
if [ "$1" = exec ]; then
  case "$*" in
    *".local/.cbox-stamp"*) printf '/root/.local/share/claude/versions/1.2.3/claude\n' ;;
    *".codex/packages/.cbox-stamp"*) printf '/root/.codex/packages/standalone/releases/9.9.9/bin/codex\n' ;;
    *) : ;;
  esac
fi
exit 0
DOCKEREOF
chmod +x "$STUBDIR/docker"

PR="$TMPBASE/effrefresh"
mkdir -p "$PR"
( PATH="$STUBDIR:$PATH"; _cbox_probe_exes_refresh "$PR" stubcid ) || _fail "probe A0 producer: refresh returned nonzero on valid stub stamp"
[ -f "$PR/probe-exes" ] || _fail "probe A0 producer: refresh did not write the cache file"
l1="$(sed -n 1p "$PR/probe-exes")"
l2="$(sed -n 2p "$PR/probe-exes")"
[ "$l1" = "/root/.local/share/claude/versions/1.2.3/claude" ] || _fail "probe A0 producer: claude exe path not cached (got '$l1') - a broken newline guard blanking normal paths would fail here"
[ "$l2" = "/root/.codex/packages/standalone/releases/9.9.9/bin/codex" ] || _fail "probe A0 producer: codex exe path not cached (got '$l2')"
_ok "probe A0 producer: refresh reads stamp via docker exec and writes both exe paths to the host-only cache (normal single-line paths survive the newline guard)"

cat > "$STUBDIR/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
exit 7
DOCKEREOF
chmod +x "$STUBDIR/docker"
printf '%s\n%s\n' "/good/claude" "/good/codex" > "$PR/probe-exes"
( PATH="$STUBDIR:$PATH"; _cbox_probe_exes_refresh "$PR" stubcid ) && _fail "probe A0 producer: refresh must return nonzero when docker exec fails"
[ "$(sed -n 1p "$PR/probe-exes")" = "/good/claude" ] || _fail "probe A0 producer: a transient docker-exec failure must NOT overwrite a previously good cache"
_ok "probe A0 producer: docker-exec failure leaves the prior good cache intact (no empty-cache overwrite)"

echo "PASS: all probe+seed+compose checks"
