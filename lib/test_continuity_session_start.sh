#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$INSTALL_DIR/etc/hooks/continuity_session_start.py"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

_fail() {
  echo "FAIL: $1" >&2
  exit 1
}

_body_bytes() {
  local kind="$1" payload="$2"
  printf '%s' "$payload" | python3 -c '
import sys

kind = sys.argv[1]
text = sys.stdin.read()
begin = "--- CBOX CONTINUITY PAYLOAD %s BEGIN ---\n" % kind
end_prefix = "--- CBOX CONTINUITY PAYLOAD %s END" % kind
try:
    part = text.split(begin, 1)[1]
    # Skip the label/version line; the remainder is the payload body.
    body = part.split("\n", 1)[1].split(end_prefix, 1)[0]
except (IndexError, ValueError):
    raise SystemExit(2)
sys.stdout.write(str(len(body.rstrip("\n").encode("utf-8"))))
' "$kind"
}

_make_repo() {
  local d="$1"
  mkdir -p "$d/.claude"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name t
}

test_reference_payload_cap() {
  local d="$TMPBASE/reference" payload bytes
  _make_repo "$d"
  python3 - "$d/.claude/LEDGER.md" <<'PY'
import sys

with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write("# LEDGER\n\n## VLNA A\n")
    f.write(("reference payload line with enough text to exceed the cap\n") * 200)
PY
  payload="$(python3 "$HOOK" <<JSON
{"source":"startup","cwd":"$d"}
JSON
)"
  bytes="$(_body_bytes bounded-ledger "$payload")" || _fail "missing bounded ledger payload"
  [ "$bytes" -le 4000 ] || _fail "reference body is $bytes B, exceeds 4000 B"
  case "$payload" in
    *"(remainder on disk, not injected)"*) : ;;
    *) _fail "oversized reference payload has no truncation marker" ;;
  esac
  echo "PASS: reference data capped at 4000 B"
}

test_core_payload_cap() {
  local d="$TMPBASE/core" payload bytes
  _make_repo "$d"
  payload="$(python3 "$HOOK" <<JSON
{"source":"startup","cwd":"$d"}
JSON
)"
  bytes="$(_body_bytes core "$payload")" || _fail "missing core payload"
  [ "$bytes" -le 7000 ] || _fail "core body is $bytes B, exceeds 7000 B"
  case "$payload" in
    *"SESSION CORE"*) : ;;
    *) _fail "core payload missing" ;;
  esac
  echo "PASS: required core retains its 7000 B ceiling"
}

test_light_profile_has_security_floor() {
  local d="$TMPBASE/light" payload
  _make_repo "$d"
  payload="$(CBOX_CONTEXT_PROFILE=light python3 "$HOOK" <<JSON
{"source":"startup","cwd":"$d"}
JSON
)"
  case "$payload" in
    *"security-reviewer"*) : ;;
    *) _fail "light profile core payload missing security-reviewer gate rule" ;;
  esac
  echo "PASS: light profile retains security-reviewer gate rule"
}

test_resume_profile_has_security_floor() {
  local d="$TMPBASE/resume" payload
  _make_repo "$d"
  payload="$(python3 "$HOOK" <<JSON
{"source":"resume","cwd":"$d"}
JSON
)"
  case "$payload" in
    *"security-reviewer"*) : ;;
    *) _fail "resume profile core payload missing security-reviewer gate rule" ;;
  esac
  echo "PASS: resume profile retains security-reviewer gate rule"
}

test_reference_payload_cap
test_core_payload_cap
test_light_profile_has_security_floor
test_resume_profile_has_security_floor
echo "all continuity_session_start tests passed"
