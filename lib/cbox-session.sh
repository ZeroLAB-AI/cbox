#!/usr/bin/env bash
if [ -n "${_CBOX_SESSION_LOADED:-}" ]; then
  return 0
fi
_CBOX_SESSION_LOADED=1

_CBOX_SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CBOX_SESSION_NOFOLLOW_HELPER="$_CBOX_SESSION_DIR/cbox_session_nofollow.py"
_CBOX_SESSION_BRIDGE="$_CBOX_SESSION_DIR/cbox_session_bridge.py"

_CBOX_SESSION_ID_RE='^s-[0-9]{8}-[0-9]{4}-[0-9a-f]{6}$'

_cbox_new_session_id() {
  local ts hex
  ts="$(date -u +%Y%m%d-%H%M)"
  hex="$(od -An -tx1 -N3 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$hex" ] || hex="$(printf '%06x' "$RANDOM$RANDOM" | tail -c6)"
  printf 's-%s-%s' "$ts" "$hex"
}

_cbox_session_id_valid() {
  printf '%s' "$1" | grep -qE "$_CBOX_SESSION_ID_RE"
}

_cbox_session_root() {
  local root="$1"
  printf '%s/.cbox/sessions' "$root"
}

_cbox_session_dir() {
  local root="$1" sid="$2"
  printf '%s/%s' "$(_cbox_session_root "$root")" "$sid"
}

_cbox_session_file() {
  local root="$1" sid="$2"
  printf '%s/session.json' "$(_cbox_session_dir "$root" "$sid")"
}

_cbox_session_file_rel() {
  local sid="$1"
  printf '.cbox/sessions/%s/session.json' "$sid"
}

_cbox_runtime_dir() {
  local root="$1"
  printf '%s/.cbox/runtime' "$root"
}

_cbox_runtime_sessions_file() {
  local root="$1"
  printf '%s/sessions.json' "$(_cbox_runtime_dir "$root")"
}

_cbox_runtime_sessions_file_rel() {
  printf '.cbox/runtime/sessions.json'
}

_cbox_runtime_host_dir() {
  local root="$1" hash
  hash="$(_cbox_path_hash "$root")"
  printf '%s/.config/cbox/projects/%s' "$HOME" "$hash"
}

_cbox_runtime_lock_file_host() {
  local root="$1"
  printf '%s/session-runtime.lock' "$(_cbox_runtime_host_dir "$root")"
}

_cbox_write_atomic_nofollow() {
  local root="$1" relpath="$2" content="$3"
  printf '%s' "$content" | python3 "$_CBOX_SESSION_NOFOLLOW_HELPER" write "$root" "$relpath"
}

_cbox_session_gitignore_ensure() {
  local root="$1"
  python3 "$_CBOX_SESSION_NOFOLLOW_HELPER" gitignore-ensure "$root" ".cbox/.gitignore"
}

_cbox_mkdir_nofollow() {
  local root="$1" relpath="$2"
  python3 "$_CBOX_SESSION_NOFOLLOW_HELPER" mkdir "$root" "$relpath"
}

_cbox_chmod_readonly_nofollow() {
  local root="$1" relpath="$2"
  python3 "$_CBOX_SESSION_NOFOLLOW_HELPER" chmod-readonly "$root" "$relpath"
}

_cbox_read_nofollow() {
  local root="$1" relpath="$2"
  python3 "$_CBOX_SESSION_NOFOLLOW_HELPER" read "$root" "$relpath"
}

_cbox_create_new_dir_nofollow() {
  local root="$1" relpath="$2"
  python3 "$_CBOX_SESSION_NOFOLLOW_HELPER" create-new-dir "$root" "$relpath"
}

_cbox_session_lock_acquire() {
  local root="$1" fd="$2" lockfile
  lockfile="$(_cbox_runtime_lock_file_host "$root")"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || return 1
  if [ -L "$lockfile" ]; then
    echo "cbox: refusing to lock - $lockfile is a symlink" >&2
    return 1
  fi
  eval "exec $fd> \"\$lockfile\""
  if ! flock -n -x "$fd"; then
    echo "cbox: another leg is using the session runtime lock for $root - waiting..." >&2
    flock -x "$fd"
  fi
}

_cbox_session_json_get() {
  local file="$1" dotted="$2"
  [ -f "$file" ] || return 1
  python3 - "$file" "$dotted" <<'PYEOF'
import json
import sys

path, dotted = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
node = data
for part in dotted.split("."):
    if part == "":
        continue
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(2)
if isinstance(node, (dict, list)):
    print(json.dumps(node))
elif node is None:
    print("null")
elif isinstance(node, bool):
    print("true" if node else "false")
else:
    print(node)
PYEOF
}

_cbox_session_new_json() {
  local sid="$1" scope_id="$2" root="$3" container_instance_id="$4"
  python3 - "$sid" "$scope_id" "$root" "$container_instance_id" <<'PYEOF'
import datetime
import json
import sys

sid, scope_id, root, cid = sys.argv[1:5]
stamp = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
doc = {
    "schemaVersion": 1,
    "cboxSessionId": sid,
    "scope": {
        "scopeId": scope_id,
        "root": root,
        "containerInstanceId": cid or None,
    },
    "state": "open",
    "activeMain": None,
    "engines": {},
    "nextHandoffSeq": 1,
    "currentHandoff": None,
    "createdAt": stamp,
    "updatedAt": stamp,
}
print(json.dumps(doc, indent=2, sort_keys=False))
PYEOF
}

_cbox_session_store_create() {
  local root="$1" sid="$2" scope_id="$3" cid="${4:-}" json
  _cbox_session_id_valid "$sid" || { echo "cbox: refusing - invalid session id '$sid'" >&2; return 1; }
  _cbox_create_new_dir_nofollow "$root" ".cbox/sessions/$sid" || { echo "cbox: session dir for $sid already exists or is unsafe" >&2; return 1; }
  json="$(_cbox_session_new_json "$sid" "$scope_id" "$root" "$cid")" || return 1
  _cbox_write_atomic_nofollow "$root" "$(_cbox_session_file_rel "$sid")" "$json"
}

_cbox_session_list_ids() {
  local root="$1" base f sid
  base="$(_cbox_session_root "$root")"
  [ -d "$base" ] || return 0
  for f in "$base"/*/session.json; do
    [ -f "$f" ] || continue
    sid="$(basename "$(dirname "$f")")"
    printf '%s\n' "$sid"
  done
}

_cbox_session_lease_decision() {
  local state="$1" active_live="$2" requested_engine="$3" live_engine="$4"
  case "$state" in
    closed)
      printf 'refuse:closed'
      return 0
      ;;
    open)
      if [ "$active_live" = 1 ]; then
        printf 'refuse:live:%s' "$live_engine"
        return 0
      fi
      printf 'accept:reclaim-stale'
      return 0
      ;;
    idle|"")
      printf 'accept:fresh'
      return 0
      ;;
    *)
      printf 'refuse:unknown-state'
      return 0
      ;;
  esac
}

_cbox_proc_live() {
  local pid="$1" want_start="$2" have_start
  [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null || return 1
  [ -n "$want_start" ] || return 1
  [ -d "/proc/$pid" ] || return 1
  have_start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" || return 1
  [ -n "$have_start" ] && [ "$have_start" = "$want_start" ]
}

_cbox_proc_start_ticks() {
  local pid="$1"
  awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}

_cbox_runtime_leg_read_field() {
  local root="$1" sid="$2" field="$3"
  _cbox_read_nofollow "$root" "$(_cbox_runtime_sessions_file_rel)" | python3 -c '
import json, sys
sid, field = sys.argv[1:3]
data = json.load(sys.stdin)
leg = data.get(sid)
if not isinstance(leg, dict) or field not in leg:
    sys.exit(2)
val = leg[field]
print(val if val is not None else "")
' "$sid" "$field"
}

_cbox_runtime_leg_write() {
  local root="$1" sid="$2" engine="$3" leg_n="$4" pid="$5" proc_start="$6" started_at="$7" file existing tmp
  _cbox_session_id_valid "$sid" || return 1
  file="$(_cbox_runtime_sessions_file "$root")"
  if existing="$(_cbox_read_nofollow "$root" "$(_cbox_runtime_sessions_file_rel)" 2>/dev/null)"; then
    :
  elif [ -e "$file" ] || [ -L "$file" ]; then
    return 1
  else
    existing='{}'
  fi
  tmp="$(printf '%s' "$existing" | python3 -c '
import json, sys
sid, engine, leg_n, pid, proc_start, started_at = sys.argv[1:7]
try:
    data = json.load(sys.stdin)
except ValueError:
    data = {}
if not isinstance(data, dict):
    data = {}
data[sid] = {
    "engine": engine,
    "leg": int(leg_n),
    "pid": int(pid),
    "procStart": proc_start,
    "startedAt": started_at,
}
print(json.dumps(data, indent=2, sort_keys=True))
' "$sid" "$engine" "$leg_n" "$pid" "$proc_start" "$started_at")" || return 1
  _cbox_write_atomic_nofollow "$root" "$(_cbox_runtime_sessions_file_rel)" "$tmp"
}

_cbox_runtime_leg_clear() {
  local root="$1" sid="$2" file existing tmp
  _cbox_session_id_valid "$sid" || return 1
  file="$(_cbox_runtime_sessions_file "$root")"
  if existing="$(_cbox_read_nofollow "$root" "$(_cbox_runtime_sessions_file_rel)" 2>/dev/null)"; then
    :
  elif [ -e "$file" ] || [ -L "$file" ]; then
    return 1
  else
    return 0
  fi
  tmp="$(printf '%s' "$existing" | python3 -c '
import json, sys
sid = sys.argv[1]
data = json.load(sys.stdin)
if isinstance(data, dict):
    data.pop(sid, None)
print(json.dumps(data, indent=2, sort_keys=True))
' "$sid")" || return 1
  _cbox_write_atomic_nofollow "$root" "$(_cbox_runtime_sessions_file_rel)" "$tmp"
}

_cbox_session_field_get() {
  local root="$1" sid="$2" dotted="$3"
  _cbox_session_id_valid "$sid" || return 1
  _cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")" | python3 -c '
import json
import sys
dotted = sys.argv[1]
node = json.load(sys.stdin)
for part in dotted.split("."):
    if not part:
        continue
    if not isinstance(node, dict) or part not in node:
        raise SystemExit(2)
    node = node[part]
if isinstance(node, (dict, list)):
    print(json.dumps(node))
elif node is None:
    print("null")
elif isinstance(node, bool):
    print("true" if node else "false")
else:
    print(node)
' "$dotted"
}

_cbox_session_set_lease() {
  local root="$1" sid="$2" engine="$3" native_id="$4" native_id_source="$5" current tmp
  _cbox_session_id_valid "$sid" || return 1
  current="$(_cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")")" || return 1
  tmp="$(printf '%s' "$current" | python3 -c '
import json, sys
engine, native_id, native_id_source = sys.argv[1:4]
doc = json.load(sys.stdin)
doc["state"] = "open"
doc["activeMain"] = engine
engines = doc.setdefault("engines", {})
rec = engines.setdefault(engine, {"currentNativeSessionId": None, "locator": None, "cursor": None, "lineage": []})
rec["currentNativeSessionId"] = native_id or None
rec.setdefault("lineage", []).append({
    "nativeSessionId": native_id or None,
    "locator": rec.get("locator"),
    "cursor": rec.get("cursor"),
    "nativeIdSource": native_id_source,
})
print(json.dumps(doc, indent=2, sort_keys=False))
' "$engine" "$native_id" "$native_id_source")" || return 1
  _cbox_write_atomic_nofollow "$root" "$(_cbox_session_file_rel "$sid")" "$tmp"
}

_cbox_session_release_lease() {
  local root="$1" sid="$2" rc="$3" confirmed_native_id="$4" confirmed_source="$5" current tmp
  _cbox_session_id_valid "$sid" || return 1
  current="$(_cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")")" || return 1
  tmp="$(printf '%s' "$current" | python3 -c '
import json, sys
rc, confirmed_native_id, confirmed_source = sys.argv[1:4]
doc = json.load(sys.stdin)
engine = doc.get("activeMain")
doc["state"] = "idle"
doc["activeMain"] = None
if engine:
    engines = doc.setdefault("engines", {})
    rec = engines.setdefault(engine, {"currentNativeSessionId": None, "locator": None, "cursor": None, "lineage": []})
    lineage = rec.setdefault("lineage", [])
    if lineage:
        last = lineage[-1]
        last["rc"] = int(rc)
        if confirmed_native_id:
            last["nativeSessionId"] = confirmed_native_id
            last["nativeIdSource"] = confirmed_source or last.get("nativeIdSource")
            rec["currentNativeSessionId"] = confirmed_native_id
print(json.dumps(doc, indent=2, sort_keys=False))
' "$rc" "$confirmed_native_id" "$confirmed_source")" || return 1
  _cbox_write_atomic_nofollow "$root" "$(_cbox_session_file_rel "$sid")" "$tmp"
}

_cbox_session_close() {
  local root="$1" sid="$2" current tmp lockfd=9 rc=0
  _cbox_session_id_valid "$sid" || return 1
  _cbox_session_lock_acquire "$root" "$lockfd" || { echo "cbox: cannot acquire session runtime lock for $root" >&2; return 1; }
  if ! current="$(_cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")")"; then
    eval "exec ${lockfd}>&-"
    return 1
  fi
  tmp="$(printf '%s' "$current" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
doc["state"] = "closed"
doc["activeMain"] = None
print(json.dumps(doc, indent=2, sort_keys=False))
')" || rc=1
  if [ "$rc" -eq 0 ]; then
    _cbox_write_atomic_nofollow "$root" "$(_cbox_session_file_rel "$sid")" "$tmp" || rc=1
  fi
  eval "exec ${lockfd}>&-"
  return "$rc"
}

_cbox_session_envelope_json() {
  python3 -c '
import sys

text = sys.stdin.read()
begin = "CBOX_SESSION_JSON_BEGIN\n"
end = "\nCBOX_SESSION_JSON_END"
if begin not in text or end not in text:
    raise SystemExit(2)
sys.stdout.write(text.rsplit(begin, 1)[1].split(end, 1)[0])
'
}

_cbox_session_sync_native() {
  local root raw discovered plan lockfd=9 count=0
  root="$(_cbox_workspace_root)" || { echo "cbox: refusing session sync outside a workspace root" >&2; return 1; }
  [ -f "$_CBOX_SESSION_BRIDGE" ] || { echo "cbox: session bridge missing at $_CBOX_SESSION_BRIDGE" >&2; return 1; }
  raw="$(_run_isolated python3 /opt/cbox/cbox_session_bridge.py discover --root "$root" --envelope)" || return 1
  discovered="$(printf '%s' "$raw" | _cbox_session_envelope_json)" || {
    echo "cbox: native session discovery returned an invalid envelope" >&2
    return 1
  }
  _cbox_session_lock_acquire "$root" "$lockfd" || return 1
  plan="$(printf '%s' "$discovered" | python3 "$_CBOX_SESSION_BRIDGE" plan-import --root "$root")" || {
    eval "exec ${lockfd}>&-"
    return 1
  }
  while IFS=$'\t' read -r sid is_new encoded; do
    [ -n "$sid" ] || continue
    _cbox_session_id_valid "$sid" || continue
    local doc
    doc="$(printf '%s' "$encoded" | base64 -d)" || continue
    if [ "$is_new" = 1 ]; then
      _cbox_create_new_dir_nofollow "$root" ".cbox/sessions/$sid" || continue
      count=$((count + 1))
    fi
    _cbox_write_atomic_nofollow "$root" "$(_cbox_session_file_rel "$sid")" "$doc" || continue
  done < <(printf '%s' "$plan" | python3 -c '
import base64,json,sys
d=json.load(sys.stdin)
for p in d.get("plans", []):
    sid=p.get("sessionId", "")
    raw=json.dumps(p.get("doc", {}), indent=2, ensure_ascii=True).encode("ascii")
    print("%s\t%d\t%s" % (sid, 1 if p.get("isNew") else 0, base64.b64encode(raw).decode("ascii")))
')
  local runtime
  runtime="$(printf '%s' "$plan" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("runtimeIndex", {}), indent=2, ensure_ascii=True))')" || runtime=""
  if [ -n "$runtime" ]; then
    _cbox_write_atomic_nofollow "$root" ".cbox/runtime/native-index.json" "$runtime" || true
  fi
  _cbox_session_gitignore_ensure "$root" || true
  eval "exec ${lockfd}>&-"
  echo "cbox: native session sync complete ($count imported)" >&2
}

_cbox_session_bridge_exec() {
  local root="$1"; shift
  [ -n "${_CBOX_SESSION_EFF:-}" ] || return 1
  _compose_p "$_CBOX_SESSION_EFF" exec -T -w "$root" cbox \
    /entrypoint.sh python3 /opt/cbox/cbox_session_bridge.py "$@"
}

_cbox_session_native_ids() {
  local root="$1" engine="$2"
  _cbox_session_bridge_exec "$root" discover --root "$root" --engine "$engine" \
    | python3 -c 'import json,sys; print("\n".join(sorted(x["nativeSessionId"] for x in json.load(sys.stdin))))'
}

_cbox_session_native_diff() {
  local before="$1" after="$2" result count
  result="$(comm -13 <(printf '%s\n' "$before" | sed '/^$/d' | sort -u) <(printf '%s\n' "$after" | sed '/^$/d' | sort -u))"
  count="$(printf '%s\n' "$result" | sed '/^$/d' | wc -l)"
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$result"
}

_cbox_session_previous_ref() {
  local root="$1" sid="$2" ref
  ref="$(_cbox_session_field_get "$root" "$sid" currentHandoff.ref 2>/dev/null)" || return 1
  ref="${ref%\"}"; ref="${ref#\"}"
  case "$ref" in
    ".cbox/sessions/$sid/distillates/"handoff-[0-9][0-9][0-9][0-9][0-9][0-9].json) printf '%s' "$ref" ;;
    *) return 1 ;;
  esac
}

_cbox_session_store_handoff() {
  local root="$1" sid="$2" engine="$3" native_id="$4" delta="$5"
  local seq rel previous_ref="" merged current tmp
  local -a merge_args
  _cbox_session_id_valid "$sid" || return 1
  seq="$(_cbox_session_field_get "$root" "$sid" nextHandoffSeq 2>/dev/null)" || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  [ "$seq" -ge 1 ] || return 1
  rel=".cbox/sessions/$sid/distillates/handoff-$(printf '%06d' "$seq").json"
  if previous_ref="$(_cbox_session_previous_ref "$root" "$sid" 2>/dev/null)"; then
    :
  fi
  merge_args=(merge --root "$root" --session-id "$sid" --seq "$seq" --engine "$engine" --native-id "$native_id")
  [ -z "$previous_ref" ] || merge_args+=(--previous-ref "$previous_ref")
  merged="$(printf '%s' "$delta" | python3 "$_CBOX_SESSION_BRIDGE" "${merge_args[@]}")" || return 1
  _cbox_mkdir_nofollow "$root" ".cbox/sessions/$sid/distillates" || return 1
  _cbox_write_atomic_nofollow "$root" "$rel" "$merged" || return 1
  _cbox_chmod_readonly_nofollow "$root" "$rel" || return 1
  current="$(_cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")")" || return 1
  tmp="$(printf '%s' "$current" | python3 -c '
import json, os, sys
ref, engine, native_id, seq = sys.argv[1:5]
doc = json.load(sys.stdin)
with os.fdopen(3, "r", encoding="utf-8") as fh:
    memory = json.load(fh)
engines = doc.setdefault("engines", {})
rec = engines.setdefault(engine, {"currentNativeSessionId": None, "locator": None, "cursor": None, "lineage": []})
rec["currentNativeSessionId"] = native_id
rec["locator"] = memory.get("sourceLocator")
rec["cursor"] = memory.get("cursor")
lineage = rec.setdefault("lineage", [])
if lineage:
    lineage[-1]["nativeSessionId"] = native_id
    lineage[-1]["locator"] = rec.get("locator")
    lineage[-1]["cursor"] = rec.get("cursor")
doc["currentHandoff"] = {
    "seq": int(seq),
    "engine": engine,
    "nativeSessionId": native_id,
    "ref": ref,
    "createdAt": memory.get("createdAt"),
}
doc["nextHandoffSeq"] = int(seq) + 1
doc["updatedAt"] = memory.get("createdAt")
print(json.dumps(doc, indent=2, ensure_ascii=True))
' "$rel" "$engine" "$native_id" "$seq" 3< <(printf '%s' "$merged"))" || return 1
  _cbox_write_atomic_nofollow "$root" "$(_cbox_session_file_rel "$sid")" "$tmp"
}

_cbox_session_capture_engine() {
  local root="$1" sid="$2" engine="$3" native_id="$4" cursor delta
  [ -n "$native_id" ] || return 1
  cursor="$(_cbox_session_field_get "$root" "$sid" "engines.$engine.cursor" 2>/dev/null)" || cursor=""
  case "$cursor" in null) cursor="" ;; esac
  delta="$(_cbox_session_bridge_exec "$root" extract --root "$root" --engine "$engine" --native-id "$native_id" --cursor "$cursor")" || return 1
  _cbox_session_store_handoff "$root" "$sid" "$engine" "$native_id" "$delta"
}

_cbox_session_prime_memory() {
  local root="$1" sid="$2" source engine native
  source="$(_cbox_session_field_get "$root" "$sid" currentHandoff 2>/dev/null)" || source=null
  [ "$source" = null ] || return 0
  read -r engine native < <(_cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
best = None
for engine, rec in doc.get("engines", {}).items():
    if not isinstance(rec, dict) or not rec.get("currentNativeSessionId"):
        continue
    candidate = (rec.get("lastActivityAt") or "", engine, rec.get("currentNativeSessionId"))
    if best is None or candidate > best:
        best = candidate
if best:
    print(best[1], best[2])
')
  [ -n "${engine:-}" ] && [ -n "${native:-}" ] || return 0
  _cbox_session_capture_engine "$root" "$sid" "$engine" "$native" || true
}

_cbox_session_seed_env() {
  local root="$1" sid="$2" target="$3" source ref
  CBOX_SESSION_EXEC_ENV=(-e "CBOX_SESSION_ID=$sid")
  source="$(_cbox_session_field_get "$root" "$sid" currentHandoff.engine 2>/dev/null)" || return 0
  source="${source%\"}"; source="${source#\"}"
  [ -n "$source" ] && [ "$source" != null ] && [ "$source" != "$target" ] || return 0
  ref="$(_cbox_session_previous_ref "$root" "$sid" 2>/dev/null)" || return 0
  _cbox_read_nofollow "$root" "$ref" >/dev/null 2>&1 || return 0
  CBOX_SESSION_EXEC_ENV+=(-e "CBOX_SESSION_MEMORY_FILE=$root/$ref")
}

_cbox_claude_diff_native_id() {
  local claude_config_dir="$1" slug="$2" before_list="$3" after_dir newest=""
  after_dir="$claude_config_dir/projects/$slug"
  [ -d "$after_dir" ] || return 1
  local f id newest_mtime=0 mtime new_count=0
  for f in "$after_dir"/*.jsonl; do
    [ -f "$f" ] || continue
    id="$(basename "$f" .jsonl)"
    case " $before_list " in
      *" $id "*) continue ;;
    esac
    new_count=$((new_count + 1))
    mtime="$(stat -c %Y "$f" 2>/dev/null)" || continue
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest_mtime="$mtime"
      newest="$id"
    fi
  done
  if [ "$new_count" -gt 1 ]; then
    echo "cbox: warning: $new_count new transcript files appeared during this leg - native id ambiguous, not confirming via diff" >&2
    return 1
  fi
  [ -n "$newest" ] && printf '%s' "$newest"
}

_cbox_session_run_leg() {
  local root sid="$1" engine="$2"; shift 2
  _cbox_session_id_valid "$sid" || { echo "cbox: refusing - invalid session id '$sid'" >&2; return 1; }
  root="$(_cbox_workspace_root)" || { echo "cbox: refusing session leg outside a workspace root" >&2; return 1; }

  case "$engine" in claude|codex|hermes) ;; *) echo "cbox: sessions unsupported for engine '$engine'" >&2; return 1 ;; esac

  local lockfd=9 rc=0 decision state active_live=0 live_pid live_engine="" native_id native_id_source
  _cbox_session_lock_acquire "$root" "$lockfd" || { echo "cbox: cannot acquire session runtime lock for $root" >&2; return 1; }

  state="$(_cbox_session_field_get "$root" "$sid" state 2>/dev/null)" || {
    eval "exec ${lockfd}>&-"
    echo "cbox: no such session $sid in $root" >&2
    return 1
  }
  state="${state%\"}"; state="${state#\"}"

  live_engine="$(_cbox_session_field_get "$root" "$sid" activeMain 2>/dev/null)" || live_engine=null
  live_engine="${live_engine%\"}"; live_engine="${live_engine#\"}"
  if [ "$state" = open ] && [ "$live_engine" != null ] && [ -n "$live_engine" ]; then
    live_pid="$(_cbox_runtime_leg_read_field "$root" "$sid" pid 2>/dev/null)" || live_pid=""
    local want_start
    want_start="$(_cbox_runtime_leg_read_field "$root" "$sid" procStart 2>/dev/null)" || want_start=""
    if _cbox_proc_live "$live_pid" "$want_start"; then
      active_live=1
    fi
  fi

  decision="$(_cbox_session_lease_decision "$state" "$active_live" "$engine" "$live_engine")"
  case "$decision" in
    refuse:live:*)
      eval "exec ${lockfd}>&-"
      echo "cbox: session $sid already has a live main leg ($live_engine) - refusing a second concurrent leg" >&2
      return 1
      ;;
    refuse:closed)
      eval "exec ${lockfd}>&-"
      echo "cbox: session $sid is closed - reopen or start a new session" >&2
      return 1
      ;;
    refuse:*)
      eval "exec ${lockfd}>&-"
      echo "cbox: session $sid refused ($decision)" >&2
      return 1
      ;;
  esac

  local scope_id
  scope_id="$(_cbox_path_hash "$root")"

  local existing_native_id=""
  existing_native_id="$(_cbox_session_field_get "$root" "$sid" "engines.$engine.currentNativeSessionId" 2>/dev/null)" || existing_native_id=""
  existing_native_id="${existing_native_id%\"}"; existing_native_id="${existing_native_id#\"}"
  case "$existing_native_id" in ""|null) existing_native_id="" ;; esac

  local resume_mode=0
  if [ -n "$existing_native_id" ]; then
    resume_mode=1
    native_id="$existing_native_id"
    native_id_source=resumed
  elif [ "$engine" = claude ]; then
    native_id="$(_cbox_new_session_uuid)"
    native_id_source=preassigned
  else
    native_id=""
    native_id_source=discovered
  fi

  local leg_n
  leg_n="$(_cbox_session_field_get "$root" "$sid" "engines.$engine.lineage" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d))' 2>/dev/null)" || leg_n=0
  leg_n=$((leg_n + 1))

  _cbox_session_set_lease "$root" "$sid" "$engine" "$native_id" "$native_id_source" || {
    eval "exec ${lockfd}>&-"
    echo "cbox: failed writing session lease for $sid" >&2
    return 1
  }

  export CBOX_SESSION_ID="$sid"

  _cbox_runtime_leg_write "$root" "$sid" "$engine" "$leg_n" "$$" "$(_cbox_proc_start_ticks $$)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true

  CBOX_SESSION_EXEC_ENV=(-e "CBOX_SESSION_ID=$sid")
  _CBOX_SESSION_LEG_ROOT="$root"
  _CBOX_SESSION_LEG_SID="$sid"
  _CBOX_SESSION_LEG_ENGINE="$engine"
  _CBOX_SESSION_LEG_NATIVE_ID="$native_id"
  _CBOX_SESSION_LEG_NATIVE_SOURCE="$native_id_source"
  _CBOX_SESSION_LEG_BEFORE_IDS=""

  local -a engine_args=()
  if [ "$resume_mode" = 1 ]; then
    case "$engine" in
      claude) engine_args=(--resume "$native_id") ;;
      codex) engine_args=(resume "$native_id") ;;
      hermes) engine_args=(--resume "$native_id") ;;
    esac
  elif [ "$engine" = claude ]; then
    engine_args=(--session-id "$native_id")
  fi
  engine_args+=("$@")

  _run_isolated "$engine" --session-env --pre-hook _cbox_session_leg_pre_hook \
    --post-hook _cbox_session_leg_post_hook -- "${engine_args[@]}" || rc=$?

  _cbox_runtime_leg_clear "$root" "$sid" || true

  eval "exec ${lockfd}>&-"
  return "$rc"
}

_cbox_session_leg_pre_hook() {
  _CBOX_SESSION_LEG_BEFORE_IDS="$(_cbox_session_native_ids "$_CBOX_SESSION_LEG_ROOT" "$_CBOX_SESSION_LEG_ENGINE" 2>/dev/null)" || _CBOX_SESSION_LEG_BEFORE_IDS=""
  _cbox_session_prime_memory "$_CBOX_SESSION_LEG_ROOT" "$_CBOX_SESSION_LEG_SID" || true
  _cbox_session_seed_env "$_CBOX_SESSION_LEG_ROOT" "$_CBOX_SESSION_LEG_SID" "$_CBOX_SESSION_LEG_ENGINE"
  return 0
}

_cbox_session_leg_post_hook() {
  local rc="${1:-0}"
  local confirmed="$_CBOX_SESSION_LEG_NATIVE_ID" src="$_CBOX_SESSION_LEG_NATIVE_SOURCE" after=""
  if [ -z "$confirmed" ]; then
    after="$(_cbox_session_native_ids "$_CBOX_SESSION_LEG_ROOT" "$_CBOX_SESSION_LEG_ENGINE" 2>/dev/null)" || after=""
    confirmed="$(_cbox_session_native_diff "$_CBOX_SESSION_LEG_BEFORE_IDS" "$after" 2>/dev/null)" || confirmed=""
    [ -z "$confirmed" ] || src=diff
  fi
  if [ -n "$confirmed" ]; then
    if ! _cbox_session_capture_engine "$_CBOX_SESSION_LEG_ROOT" "$_CBOX_SESSION_LEG_SID" "$_CBOX_SESSION_LEG_ENGINE" "$confirmed"; then
      echo "cbox: warning: could not capture shared memory for $_CBOX_SESSION_LEG_ENGINE session $confirmed" >&2
    fi
  else
    echo "cbox: warning: native session id for $_CBOX_SESSION_LEG_ENGINE was not uniquely discoverable" >&2
  fi
  _cbox_session_release_lease "$_CBOX_SESSION_LEG_ROOT" "$_CBOX_SESSION_LEG_SID" "$rc" "$confirmed" "$src" || true
}

_cbox_new_session_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
    return 0
  fi
  python3 -c 'import uuid; print(uuid.uuid4())'
}

_cbox_session_row_summary() {
  local root="$1" sid="$2" session_doc runtime_doc
  session_doc="$(_cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")")" || return 1
  runtime_doc="$(_cbox_read_nofollow "$root" ".cbox/runtime/native-index.json" 2>/dev/null)" || runtime_doc='{}'
  printf '%s' "$session_doc" | python3 -c '
import json, os, sys
sid = sys.argv[1]
doc = json.load(sys.stdin)
with os.fdopen(3, "r", encoding="utf-8") as fh:
    runtime = json.load(fh).get("sessions", {}).get(sid, {})
state = doc.get("state", "?")
active = doc.get("activeMain") or "-"
engines = doc.get("engines", {})
leg_count = sum(len(v.get("lineage", [])) for v in engines.values() if isinstance(v, dict))
last_engine = "-"
mapped = []
for name, rec in engines.items():
    if isinstance(rec, dict) and rec.get("currentNativeSessionId"):
        last_engine = name
        mapped.append("%s:%s" % (name, rec["currentNativeSessionId"][:8]))
title = runtime.get("title") or doc.get("displayName") or ""
title = " ".join(str(title).split())[:72]
kind = runtime.get("kind") or "interactive"
updated = runtime.get("updatedAt") or doc.get("updatedAt") or doc.get("createdAt") or "0000"
print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" % (sid, state, active, last_engine, leg_count, ",".join(mapped) or "-", title or "-", updated, kind))
' "$sid" 3< <(printf '%s' "$runtime_doc")
}

_cbox_session_cmd_list() {
  local root sid row s state active last legs mapped title updated kind
  root="$(_cbox_workspace_root)" || die "refusing to operate in $PWD (home, /, or a mount root)"
  printf '%-24s %-11s %-8s %-10s %-8s %-5s %-32s %s\n' SESSION KIND STATE ACTIVE LAST LEGS NATIVE TITLE
  while IFS=$'\t' read -r s state active last legs mapped title updated kind; do
    [ -n "$s" ] || continue
    printf '%-24s %-11s %-8s %-10s %-8s %-5s %-32s %s\n' "$s" "$kind" "$state" "$active" "$last" "$legs" "$mapped" "$title"
  done < <(
    while IFS= read -r sid; do
      [ -n "$sid" ] || continue
      _cbox_session_row_summary "$root" "$sid" 2>/dev/null || true
    done < <(_cbox_session_list_ids "$root") | sort -t$'\t' -k8,8r
  )
}

_cbox_session_cmd_new() {
  local root sid scope_id
  root="$(_cbox_workspace_root)" || die "refusing to operate in $PWD (home, /, or a mount root)"
  scope_id="$(_cbox_path_hash "$root")"
  sid="$(_cbox_new_session_id)"
  _cbox_session_gitignore_ensure "$root" || true
  _cbox_session_store_create "$root" "$sid" "$scope_id" "" || { echo "cbox: failed to create session" >&2; return 1; }
  printf '%s\n' "$sid"
}

_cbox_session_cmd_close() {
  local sid="${1:-}" root
  root="$(_cbox_workspace_root)" || die "refusing to operate in $PWD (home, /, or a mount root)"
  [ -n "$sid" ] || { echo "cbox: usage: $0 session close <id>" >&2; return 1; }
  _cbox_session_id_valid "$sid" || { echo "cbox: refusing - invalid session id '$sid'" >&2; return 1; }
  _cbox_session_close "$root" "$sid" || { echo "cbox: failed to close session $sid" >&2; return 1; }
  echo "cbox: session $sid closed"
}

_cbox_session_cmd_show() {
  local root sid="$1"
  root="$(_cbox_workspace_root)" || die "refusing to operate in $PWD (home, /, or a mount root)"
  [ -n "$sid" ] || { echo "cbox: usage: $0 session show <id>" >&2; return 1; }
  _cbox_session_id_valid "$sid" || { echo "cbox: refusing - invalid session id '$sid'" >&2; return 1; }
  _cbox_read_nofollow "$root" "$(_cbox_session_file_rel "$sid")" | python3 -m json.tool || {
    echo "cbox: no such or unsafe session $sid" >&2
    return 1
  }
}

_cbox_session_cmd() {
  local sub="${1:-}"
  case "$sub" in
    list) _cbox_session_cmd_list ;;
    sync|import) _cbox_session_sync_native ;;
    new) shift; _cbox_session_cmd_new "$@" ;;
    close) shift; _cbox_session_cmd_close "${1:-}" ;;
    show) shift; _cbox_session_cmd_show "${1:-}" ;;
    *) echo "cbox: usage: $0 session {list|sync|new|close <id>|show <id>}" >&2; return 1 ;;
  esac
}
