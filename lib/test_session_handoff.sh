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

_CBOX_COMMON_LOADED=""
. "$INSTALL_DIR/_common.sh"
. "$INSTALL_DIR/lib/cbox-session.sh"

ROOT="$TMPBASE/project"
mkdir -p "$ROOT"
SID="s-20260721-1200-abcdef"
CLAUDE_ID="11111111-1111-4111-8111-111111111111"
CODEX_ID="22222222-2222-4222-8222-222222222222"

_cbox_session_store_create "$ROOT" "$SID" deadbeef "" || _fail "store create"
_cbox_session_set_lease "$ROOT" "$SID" claude "$CLAUDE_ID" preassigned || _fail "claude lease"

DELTA1="$(python3 - "$CLAUDE_ID" <<'PY'
import json
import sys

native = sys.argv[1]
messages = []
for i in range(20):
    messages.append({
        "role": "user" if i % 2 == 0 else "assistant",
        "text": "claude message %02d" % i,
        "timestamp": "2026-07-21T12:%02d:00Z" % i,
        "sourceId": "c%d" % i,
    })
print(json.dumps({
    "schemaVersion": 1,
    "engine": "claude",
    "nativeSessionId": native,
    "locator": "projects/p/%s.jsonl" % native,
    "cursor": {"kind": "byte", "value": 100},
    "messages": messages,
}))
PY
)"

_cbox_session_store_handoff "$ROOT" "$SID" claude "$CLAUDE_ID" "$DELTA1" || _fail "claude handoff"
HANDOFF1="$ROOT/.cbox/sessions/$SID/distillates/handoff-000001.json"
[ -f "$HANDOFF1" ] || _fail "first distillate missing"
[ "$(stat -c %a "$HANDOFF1")" = 444 ] || _fail "first distillate is not immutable"
[ "$(_cbox_session_field_get "$ROOT" "$SID" currentHandoff.engine)" = claude ] || _fail "current handoff engine"
[ "$(_cbox_session_field_get "$ROOT" "$SID" engines.claude.cursor.value)" = 100 ] || _fail "claude cursor"
_ok "first engine handoff is durable, immutable, and advances cursor"

_cbox_session_release_lease "$ROOT" "$SID" 0 "$CLAUDE_ID" preassigned || _fail "claude release"
_cbox_session_set_lease "$ROOT" "$SID" codex "" discovered || _fail "codex lease"
_cbox_session_seed_env "$ROOT" "$SID" codex
case " ${CBOX_SESSION_EXEC_ENV[*]} " in
  *" CBOX_SESSION_MEMORY_FILE=$HANDOFF1 "*) ;;
  *) _fail "cross-engine memory env missing" ;;
esac
_ok "switching engine injects the latest shared memory file"

DELTA2="$(python3 - "$CODEX_ID" <<'PY'
import json
import sys

native = sys.argv[1]
print(json.dumps({
    "schemaVersion": 1,
    "engine": "codex",
    "nativeSessionId": native,
    "locator": "sessions/2026/07/21/rollout.jsonl",
    "cursor": {"kind": "byte", "value": 200},
    "messages": [
        {"role": "user", "text": "codex request", "timestamp": "2026-07-21T13:00:00Z", "sourceId": "x1"},
        {"role": "assistant", "text": "codex answer", "timestamp": "2026-07-21T13:01:00Z", "sourceId": "x2"},
    ],
}))
PY
)"

_cbox_session_store_handoff "$ROOT" "$SID" codex "$CODEX_ID" "$DELTA2" || _fail "codex handoff"
HANDOFF2="$ROOT/.cbox/sessions/$SID/distillates/handoff-000002.json"
[ -f "$HANDOFF2" ] || _fail "second distillate missing"
python3 - "$HANDOFF2" <<'PY' || _fail "merged shared memory content"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["sourceEngine"] == "codex"
assert doc["layerA"][-1]["text"] == "codex answer"
assert any(x.get("summary") == "claude message 00" for x in doc["layerB"])
PY
[ "$(_cbox_session_field_get "$ROOT" "$SID" engines.codex.currentNativeSessionId)" = "$CODEX_ID" ] || _fail "codex native id mapping"
[ "$(_cbox_session_field_get "$ROOT" "$SID" nextHandoffSeq)" = 3 ] || _fail "handoff sequence"
_ok "second engine maps its native id and extends shared memory"

_cbox_session_release_lease "$ROOT" "$SID" 0 "$CODEX_ID" diff || _fail "codex release"
[ "$(_cbox_session_field_get "$ROOT" "$SID" state)" = idle ] || _fail "idle after release"
[ "$(_cbox_session_field_get "$ROOT" "$SID" activeMain)" = null ] || _fail "active main after release"
_ok "session returns to idle after the handoff is committed"

echo "PASS: shared session handoff"
