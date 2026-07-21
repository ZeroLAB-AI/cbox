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

ROOT="$TMPBASE/scope"
mkdir -p "$ROOT"

sid="$(_cbox_new_session_id)"
echo "$sid" | grep -qE '^s-[0-9]{8}-[0-9]{4}-[0-9a-f]{6}$' || _fail "generated session id does not match the expected shape: $sid"
_ok "id generator output matches s-YYYYMMDD-HHMM-6HEX"

_cbox_session_id_valid "$sid" || _fail "validator rejected a freshly generated id"
_ok "validator accepts a freshly generated id"

_cbox_session_id_valid "not-a-session-id" && _fail "validator accepted garbage input"
_ok "validator rejects garbage input"

_cbox_session_id_valid "s-2026072-1200-abcdef" && _fail "validator accepted a short date field"
_ok "validator rejects a malformed date field (7 digits)"

_cbox_session_id_valid "s-20260721-1200-ABCDEF" && _fail "validator accepted uppercase hex"
_ok "validator rejects uppercase hex (must be lowercase)"

scope_id="deadbeefcafe"
_cbox_session_store_create "$ROOT" "$sid" "$scope_id" "container-1" || _fail "session store create failed"
sf="$(_cbox_session_file "$ROOT" "$sid")"
[ -f "$sf" ] || _fail "session.json not created at $sf"
_ok "session.json created under SCOPEROOT/.cbox/sessions/<id>/"

python3 -c "import json; json.load(open('$sf'))" || _fail "session.json is not valid JSON"
_ok "session.json round-trips as valid JSON"

schema_version="$(_cbox_session_json_get "$sf" schemaVersion)"
[ "$schema_version" = 1 ] || _fail "schemaVersion mismatch: $schema_version"
_ok "schemaVersion == 1"

got_id="$(_cbox_session_json_get "$sf" cboxSessionId)"
[ "$got_id" = "$sid" ] || _fail "cboxSessionId mismatch: $got_id != $sid"
_ok "cboxSessionId round-trips"

got_scope_id="$(_cbox_session_json_get "$sf" scope.scopeId)"
[ "$got_scope_id" = "$scope_id" ] || _fail "scope.scopeId mismatch: $got_scope_id"
_ok "scope.scopeId round-trips (nested object)"

got_root="$(_cbox_session_json_get "$sf" scope.root)"
[ "$got_root" = "$ROOT" ] || _fail "scope.root mismatch: $got_root"
_ok "scope.root round-trips"

got_state="$(_cbox_session_json_get "$sf" state)"
[ "$got_state" = open ] || _fail "initial state should be open, got $got_state"
_ok "initial state == open"

got_active="$(_cbox_session_json_get "$sf" activeMain)"
[ "$got_active" = null ] || _fail "initial activeMain should be null, got $got_active"
_ok "initial activeMain == null"

got_seq="$(_cbox_session_json_get "$sf" nextHandoffSeq)"
[ "$got_seq" = 1 ] || _fail "nextHandoffSeq should start at 1, got $got_seq"
_ok "nextHandoffSeq starts at 1"

got_handoff="$(_cbox_session_json_get "$sf" currentHandoff)"
[ "$got_handoff" = null ] || _fail "currentHandoff should be null in C1, got $got_handoff"
_ok "currentHandoff is null (C1 has no handoffs yet)"

_cbox_session_store_create "$ROOT" "$sid" "$scope_id" "" 2>/dev/null && _fail "creating a session twice should fail (dir already exists)"
_ok "creating an existing session id again is refused"

ids="$(_cbox_session_list_ids "$ROOT")"
[ "$ids" = "$sid" ] || _fail "session list mismatch: [$ids] != [$sid]"
_ok "session listing finds the created session"

ATOMIC_ROOT="$TMPBASE/atomic_root"
mkdir -p "$ATOMIC_ROOT"
TARGET="$ATOMIC_ROOT/atomic_target.json"

_cbox_write_atomic_nofollow "$ATOMIC_ROOT" "atomic_target.json" '{"a":1}' || _fail "atomic write failed on a clean target"
[ -f "$TARGET" ] || _fail "atomic write did not produce the target file"
grep -q '"a":1' "$TARGET" || _fail "atomic write content mismatch"
_ok "atomic write (temp+rename) produces the expected content"

leftover="$(find "$ATOMIC_ROOT" -maxdepth 1 -name '.cbox.*' | wc -l)"
[ "$leftover" -eq 0 ] || _fail "atomic write left a stray temp file behind"
_ok "atomic write leaves no partial/temp file behind on success"

SYMFILE="$ATOMIC_ROOT/symfile.json"
ln -s /etc/passwd "$SYMFILE"
if _cbox_write_atomic_nofollow "$ATOMIC_ROOT" "symfile.json" '{"y":1}' >/dev/null 2>&1; then
  _fail "atomic write followed a symlink target instead of refusing"
fi
[ -L "$SYMFILE" ] || _fail "symlink target was replaced instead of being left alone after refusal"
_ok "O_NOFOLLOW-style refusal: write to a symlinked target file is refused, symlink left untouched"

ESCAPE_ROOT="$TMPBASE/escape_root"
OUTSIDE_DIR="$TMPBASE/outside_dir"
mkdir -p "$ESCAPE_ROOT" "$OUTSIDE_DIR"
ln -s "$OUTSIDE_DIR" "$ESCAPE_ROOT/sessions"
if _cbox_write_atomic_nofollow "$ESCAPE_ROOT" "sessions/S/session.json" '{"z":1}' >/dev/null 2>&1; then
  _fail "atomic write followed a symlinked PARENT directory component instead of refusing"
fi
[ ! -e "$OUTSIDE_DIR/S/session.json" ] || _fail "write escaped through a symlinked parent directory to $OUTSIDE_DIR"
_ok "O_NOFOLLOW parent-chain guard: a symlinked parent directory component is refused, no escape to $OUTSIDE_DIR"

RUNTIME_FILE="$(_cbox_runtime_sessions_file "$ROOT")"
[ "$RUNTIME_FILE" = "$ROOT/.cbox/runtime/sessions.json" ] || _fail "runtime sessions file path mismatch: $RUNTIME_FILE"
_ok "runtime sessions.json path is under .cbox/runtime/ (volatile split from .cbox/sessions/ durable store)"

_cbox_runtime_leg_write "$ROOT" "$sid" claude 1 12345 6789 "2026-07-21T12:00:00Z" || _fail "runtime leg write failed"
[ -f "$RUNTIME_FILE" ] || _fail "runtime sessions.json not created"
pid_read="$(_cbox_runtime_leg_read_field "$ROOT" "$sid" pid)"
[ "$pid_read" = 12345 ] || _fail "runtime leg pid round-trip mismatch: $pid_read"
_ok "runtime leg record round-trips (pid field)"

_cbox_runtime_leg_clear "$ROOT" "$sid" || _fail "runtime leg clear failed"
_cbox_runtime_leg_read_field "$ROOT" "$sid" pid 2>/dev/null && _fail "runtime leg record still present after clear"
_ok "runtime leg record removed on clear (release)"

_cbox_session_gitignore_ensure "$ROOT" || _fail "gitignore ensure failed"
GI="$ROOT/.cbox/.gitignore"
[ -f "$GI" ] || _fail ".cbox/.gitignore not created"
grep -qxF 'runtime/' "$GI" || _fail ".cbox/.gitignore does not ignore runtime/"
grep -qxF 'sessions/*/distillates/' "$GI" || _fail ".cbox/.gitignore does not ignore shared-memory distillates"
grep -qxF 'sessions/' "$GI" 2>/dev/null && _fail ".cbox/.gitignore must not ignore sessions/ (durable, versioned)"
grep -qxF 'sessions' "$GI" 2>/dev/null && _fail ".cbox/.gitignore must not ignore sessions (durable, versioned)"
_ok ".cbox/.gitignore ignores runtime/ but not sessions/"

_cbox_session_gitignore_ensure "$ROOT" || _fail "gitignore ensure (idempotent rerun) failed"
lines_after="$(grep -cxF 'runtime/' "$GI")"
[ "$lines_after" -eq 1 ] || _fail ".cbox/.gitignore got a duplicate runtime/ line on rerun ($lines_after occurrences)"
distillate_lines="$(grep -cxF 'sessions/*/distillates/' "$GI")"
[ "$distillate_lines" -eq 1 ] || _fail ".cbox/.gitignore got a duplicate distillates line on rerun ($distillate_lines occurrences)"
_ok ".cbox/.gitignore ensure is idempotent (no duplicate lines on rerun)"

TRAVERSAL_ROOT="$TMPBASE/traversal_root"
TRAVERSAL_OUTSIDE="$TMPBASE/traversal_outside"
mkdir -p "$TRAVERSAL_ROOT" "$TRAVERSAL_OUTSIDE"
BAD_SID="../../../../$(basename "$TRAVERSAL_OUTSIDE")/pwned"
_cbox_session_store_create "$TRAVERSAL_ROOT" "$BAD_SID" "deadbeef" "" 2>/dev/null \
  && _fail "session store create accepted a path-traversal session id"
[ ! -e "$TRAVERSAL_OUTSIDE/pwned" ] || _fail "path traversal session id escaped to $TRAVERSAL_OUTSIDE/pwned"
_ok "session store create rejects a path-traversal session id before building any path"

_cbox_session_field_get "$TRAVERSAL_ROOT" "$BAD_SID" state 2>/dev/null \
  && _fail "session field get accepted a path-traversal session id"
_ok "session field get rejects a path-traversal session id"

READ_ROOT="$TMPBASE/read_root"
READ_OUTSIDE="$TMPBASE/read_outside"
mkdir -p "$READ_ROOT/.cbox" "$READ_OUTSIDE/$sid"
cp "$sf" "$READ_OUTSIDE/$sid/session.json"
ln -s "$READ_OUTSIDE" "$READ_ROOT/.cbox/sessions"
if _cbox_session_field_get "$READ_ROOT" "$sid" state >/dev/null 2>&1; then
  _fail "session field read followed a symlinked parent"
fi
_ok "O_NOFOLLOW parent-chain guard also protects session reads"

if _cbox_session_set_lease "$READ_ROOT" "$sid" claude native-id test >/dev/null 2>&1; then
  _fail "session lease update followed a symlinked parent"
fi
_ok "O_NOFOLLOW parent-chain guard protects session read-modify-write operations"

_cbox_runtime_leg_write "$TRAVERSAL_ROOT" "$BAD_SID" claude 1 1 1 "2026-07-21T12:00:00Z" 2>/dev/null \
  && _fail "runtime leg write accepted a path-traversal session id"
_ok "runtime leg write rejects a path-traversal session id"

echo "PASS: all session store checks"
