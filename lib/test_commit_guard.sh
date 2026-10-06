#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$INSTALL_DIR/etc/hooks/commit_guard.py"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

unset CBOX_REVIEW

_fail() { echo "FAIL: $1" >&2; exit 1; }
_ok() { echo "ok: $1"; }

[ -f "$HOOK" ] || _fail "commit_guard.py not found"
python3 -c "import py_compile; py_compile.compile('$HOOK', doraise=True)" || _fail "hook does not py_compile"
_ok "commit_guard.py py_compiles"

mkrepo() {
  local d="$1" staged="$2"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name t
  : > "$d/$staged"
  git -C "$d" add "$staged"
}

run_hook() {
  local d="$1" mode="$2"
  local payload
  payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"git commit -m x"}}))' "$d")"
  if [ -n "$mode" ]; then
    CBOX_REVIEW="$mode" python3 "$HOOK" <<<"$payload"
  else
    python3 "$HOOK" <<<"$payload"
  fi
}

AUTH_REPO="$TMPBASE/auth"
PLAIN_REPO="$TMPBASE/plain"
mkrepo "$AUTH_REPO" "auth_login.py"
mkrepo "$PLAIN_REPO" "notes.txt"

out="$(run_hook "$AUTH_REPO" ask)"
case "$out" in
  *"ask the owner whether to run security-reviewer"*) : ;;
  *) _fail "ask mode: auth commit note must ask the owner, got: $out" ;;
esac
case "$out" in
  *"run the security-reviewer subagent and fix CRITICAL/HIGH"*) _fail "ask mode: auth commit note still orders an automatic review" ;;
esac
_ok "ask mode: an auth/API/input commit note asks the owner instead of ordering a review"

out_default="$(run_hook "$AUTH_REPO" "")"
[ "$out_default" = "$out" ] || _fail "unset CBOX_REVIEW must behave as ask"
out_bogus="$(run_hook "$AUTH_REPO" bogus)"
[ "$out_bogus" = "$out" ] || _fail "an invalid CBOX_REVIEW must behave as ask"
_ok "unset and invalid CBOX_REVIEW behave as ask"

out="$(run_hook "$AUTH_REPO" auto)"
case "$out" in
  *"run the security-reviewer subagent and fix CRITICAL/HIGH before this commit lands"*) : ;;
  *) _fail "auto mode: auth commit note must keep the automatic review text, got: $out" ;;
esac
case "$out" in
  *"ask the owner"*) _fail "auto mode: note must not ask the owner" ;;
esac
_ok "auto mode: the automatic security-reviewer note is unchanged"

for mode in ask auto; do
  out="$(run_hook "$PLAIN_REPO" "$mode")"
  [ -z "$out" ] || _fail "$mode mode: a commit without auth/API/input paths must stay silent, got: $out"
done
_ok "a commit that touches no auth/API/input path is silent in both modes"

out="$(python3 "$HOOK" <<<'{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
[ -z "$out" ] || _fail "a non-commit command must stay silent"
_ok "a non-commit command is silent"

echo "PASS: all commit guard checks"
