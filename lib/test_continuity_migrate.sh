#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_load_cbox_functions() {
  local extracted="$TMPBASE/cbox_functions.sh"
  awk '
    /^_continuity_brain_files\(\) \{/ { infunc=1 }
    /^continuity_migrate\(\) \{/ { infunc=1 }
    infunc { print }
    infunc && /^\}/ { infunc=0 }
  ' "$INSTALL_DIR/cbox" > "$extracted"
  source "$extracted"
}
_load_cbox_functions

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_git_init() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.com
  git -C "$d" config user.name t
}

test_unborn_repo() {
  local d="$TMPBASE/unborn"
  mkdir -p "$d/.claude"
  git -C "$d" init -q 2>/dev/null || { mkdir -p "$d"; git init -q "$d"; }
  echo "ledger" > "$d/.claude/LEDGER.md"
  git -C "$d" add .claude/LEDGER.md
  ( cd "$d" && continuity_migrate >/dev/null )
  git -C "$d" ls-files | grep -qx '.claude/LEDGER.md' && _fail "unborn repo: stale .claude index entry remained"
  git -C "$d" ls-files | grep -qx '.cbox/LEDGER.md' || _fail "unborn repo: .cbox/LEDGER.md not staged"
  [ -f "$d/.cbox/LEDGER.md" ] || _fail "unborn repo: .cbox/LEDGER.md missing on disk"
  echo "PASS: unborn repo migrate"
}

test_tracked_and_untracked_mix() {
  local d="$TMPBASE/mix"
  _git_init "$d"
  mkdir -p "$d/.claude"
  echo "ledger" > "$d/.claude/LEDGER.md"
  git -C "$d" add .claude/LEDGER.md
  git -C "$d" commit -q -m init
  echo "progress" > "$d/.claude/PROGRESS_2026_07_18.md"
  ( cd "$d" && continuity_migrate >/dev/null )
  [ -f "$d/.cbox/LEDGER.md" ] || _fail "mix: tracked file not moved"
  [ -f "$d/.cbox/PROGRESS_2026_07_18.md" ] || _fail "mix: untracked file not moved"
  [ -e "$d/.claude/LEDGER.md" ] && _fail "mix: tracked source file still present"
  [ -e "$d/.claude/PROGRESS_2026_07_18.md" ] && _fail "mix: untracked source file still present"
  echo "PASS: tracked+untracked mix migrate"
}

test_idempotent_rerun() {
  local d="$TMPBASE/idempotent"
  _git_init "$d"
  mkdir -p "$d/.claude"
  echo "ledger" > "$d/.claude/LEDGER.md"
  git -C "$d" add .claude/LEDGER.md
  git -C "$d" commit -q -m init
  ( cd "$d" && continuity_migrate >/dev/null )
  local out
  out="$( cd "$d" && continuity_migrate )"
  case "$out" in
    *"nothing to do"*) : ;;
    *) _fail "idempotent rerun: expected no-op, got: $out" ;;
  esac
  echo "PASS: idempotent rerun"
}

test_refuse_on_conflict() {
  local d="$TMPBASE/conflict"
  _git_init "$d"
  mkdir -p "$d/.claude"
  echo "ledger" > "$d/.claude/LEDGER.md"
  git -C "$d" add .claude/LEDGER.md
  git -C "$d" commit -q -m init
  ( cd "$d" && continuity_migrate >/dev/null )
  mkdir -p "$d/.claude"
  echo "diary" > "$d/.claude/DIARY.md"
  if ( cd "$d" && continuity_migrate >/dev/null 2>/dev/null ); then
    _fail "refuse-on-conflict: migrate should have refused but exited 0"
  fi
  [ -f "$d/.claude/DIARY.md" ] || _fail "refuse-on-conflict: conflicting file was moved instead of refused"
  echo "PASS: refuse-on-conflict"
}

test_unborn_repo
test_tracked_and_untracked_mix
test_idempotent_rerun
test_refuse_on_conflict
echo "all continuity_migrate tests passed"
