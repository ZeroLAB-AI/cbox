#!/usr/bin/env python3
import argparse
import collections
import datetime
import glob
import hashlib
import json
import os
import re
import secrets
import sqlite3
import sys


NATIVE_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
CBOX_ID_RE = re.compile(r"^s-[0-9]{8}-[0-9]{4}-[0-9a-f]{6}$")
DISTILLATE_RE = re.compile(r"^handoff-[0-9]{6}[.]json$")
MAX_JSONL_LINE = 8 * 1024 * 1024
MAX_MESSAGE_BYTES = 4 * 1024 * 1024
LAYER_A_MESSAGES = 16
LAYER_B_BYTES = 32768
RENDER_BYTES = 16000
DISCOVERY_RECORDS = 512
EXTRACT_MESSAGES = 512


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def iso_from_epoch(value):
    try:
        return datetime.datetime.fromtimestamp(float(value), datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError, OverflowError):
        return None


def normalized_root(path):
    root = os.path.realpath(path)
    if not os.path.isdir(root):
        raise ValueError("workspace root is not a directory")
    return root


def path_within(path, root):
    try:
        return os.path.commonpath([os.path.realpath(path), root]) == root
    except ValueError:
        return False


def compact_title(text):
    if not isinstance(text, str):
        return ""
    value = " ".join(text.split())
    if value.startswith("# AGENTS.md instructions") or value.startswith("<INSTRUCTIONS>"):
        return ""
    if len(value) > 96:
        value = value[:93].rstrip() + "..."
    return value


def text_blocks(content, allowed):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for item in content:
        if not isinstance(item, dict) or item.get("type") not in allowed:
            continue
        value = item.get("text")
        if isinstance(value, str) and value:
            parts.append(value)
    return "\n".join(parts)


def bounded_message(text):
    raw = text.encode("utf-8", "replace")
    if len(raw) <= MAX_MESSAGE_BYTES:
        return text
    return "[message omitted: %d bytes exceeds cbox safety limit]" % len(raw)


def jsonl_records(path, start=0, limit=0, keep="edges"):
    records = [] if not limit else collections.deque(maxlen=limit)
    first = []
    end = start
    with open(path, "rb") as fh:
        size = os.fstat(fh.fileno()).st_size
        if start < 0 or start > size:
            start = 0
        fh.seek(start)
        while True:
            line = fh.readline(MAX_JSONL_LINE + 1)
            if not line:
                break
            if len(line) > MAX_JSONL_LINE and not line.endswith(b"\n"):
                while line and not line.endswith(b"\n"):
                    line = fh.readline(MAX_JSONL_LINE + 1)
                continue
            try:
                value = json.loads(line.decode("utf-8", "replace"))
            except (ValueError, UnicodeError):
                continue
            if isinstance(value, dict):
                if limit and keep == "edges" and len(first) < limit // 2:
                    first.append(value)
                else:
                    records.append(value)
        end = fh.tell()
    if limit and keep == "edges":
        tail = list(records)[-(limit - len(first)):]
        return first + tail, end
    return list(records), end


def claude_home():
    return os.path.realpath(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"))


def codex_home():
    return os.path.realpath(os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex"))


def hermes_home():
    return os.path.realpath(os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes-cbox"))


def claude_discover(root):
    home = claude_home()
    found = []
    paths = []
    for dirname in ("projects", ".host-projects"):
        paths.extend(glob.glob(os.path.join(home, dirname, "*", "*.jsonl")))
    for path in sorted(set(paths)):
        if os.path.islink(path) or not path_within(path, home):
            continue
        native_id = os.path.basename(path)[:-6]
        if not NATIVE_ID_RE.fullmatch(native_id):
            continue
        cwd = None
        started = None
        updated = None
        title = ""
        seen_id = None
        try:
            records, _ = jsonl_records(path, limit=DISCOVERY_RECORDS)
        except OSError:
            continue
        for item in records:
            if isinstance(item.get("sessionId"), str):
                seen_id = item["sessionId"]
            value = item.get("cwd")
            if isinstance(value, str) and value:
                cwd = value
            stamp = item.get("timestamp")
            if isinstance(stamp, str) and stamp:
                if started is None:
                    started = stamp
                updated = stamp
            if not title and item.get("type") == "user":
                msg = item.get("message") if isinstance(item.get("message"), dict) else {}
                title = compact_title(text_blocks(msg.get("content"), {"text"}))
        if seen_id and seen_id != native_id:
            continue
        if not cwd or not path_within(cwd, root):
            continue
        if updated is None:
            updated = iso_from_epoch(os.path.getmtime(path))
        found.append({
            "engine": "claude",
            "kind": "interactive",
            "nativeSessionId": native_id,
            "locator": os.path.relpath(path, home),
            "startedAt": started,
            "updatedAt": updated,
            "title": title,
        })
    return found


def codex_history_titles(home):
    result = {}
    path = os.path.join(home, "history.jsonl")
    if os.path.islink(path) or not path_within(path, home):
        return result
    try:
        records, _ = jsonl_records(path, limit=DISCOVERY_RECORDS)
    except OSError:
        return result
    for item in records:
        sid = item.get("session_id")
        title = compact_title(item.get("text"))
        if isinstance(sid, str) and NATIVE_ID_RE.fullmatch(sid) and title:
            result[sid] = title
    return result


def codex_discover(root):
    home = codex_home()
    titles = codex_history_titles(home)
    found = []
    pattern = os.path.join(home, "sessions", "*", "*", "*", "*.jsonl")
    for path in sorted(glob.glob(pattern)):
        if os.path.islink(path) or not path_within(path, home):
            continue
        native_id = None
        cwd = None
        started = None
        updated = None
        fallback_title = ""
        source = ""
        try:
            records, _ = jsonl_records(path, limit=DISCOVERY_RECORDS)
        except OSError:
            continue
        for item in records:
            stamp = item.get("timestamp")
            if isinstance(stamp, str) and stamp:
                if started is None:
                    started = stamp
                updated = stamp
            payload = item.get("payload") if isinstance(item.get("payload"), dict) else {}
            if item.get("type") == "session_meta":
                value = payload.get("id") or payload.get("session_id")
                if isinstance(value, str):
                    native_id = value
                value = payload.get("cwd")
                if isinstance(value, str):
                    cwd = value
                value = payload.get("source")
                if isinstance(value, str):
                    source = value
            if not fallback_title and item.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
                fallback_title = compact_title(text_blocks(payload.get("content"), {"input_text"}))
        if not native_id or not NATIVE_ID_RE.fullmatch(native_id):
            continue
        if not cwd or not path_within(cwd, root):
            continue
        if updated is None:
            updated = iso_from_epoch(os.path.getmtime(path))
        found.append({
            "engine": "codex",
            "kind": "interactive" if source == "cli" else "auxiliary",
            "nativeSessionId": native_id,
            "locator": os.path.relpath(path, home),
            "startedAt": started,
            "updatedAt": updated,
            "title": titles.get(native_id) or fallback_title,
        })
    return found


def hermes_connection(path):
    return sqlite3.connect("file:%s?mode=ro" % path.replace("?", "%3f"), uri=True)


def hermes_discover(root):
    home = hermes_home()
    path = os.path.join(home, "state.db")
    if not os.path.isfile(path) or os.path.islink(path) or not path_within(path, home):
        return []
    found = []
    try:
        con = hermes_connection(path)
        rows = con.execute(
            "select id,cwd,git_repo_root,started_at,ended_at,title,display_name from sessions where archived=0 order by started_at"
        ).fetchall()
    except (OSError, sqlite3.Error):
        return []
    finally:
        try:
            con.close()
        except Exception:
            pass
    for sid, cwd, git_root, started, ended, title, display_name in rows:
        if not isinstance(sid, str) or not NATIVE_ID_RE.fullmatch(sid):
            continue
        candidate = git_root or cwd
        if not isinstance(candidate, str) or not path_within(candidate, root):
            continue
        found.append({
            "engine": "hermes",
            "kind": "interactive",
            "nativeSessionId": sid,
            "locator": "state.db#sessions/" + sid,
            "startedAt": iso_from_epoch(started),
            "updatedAt": iso_from_epoch(ended or started),
            "title": compact_title(title or display_name or ""),
        })
    return found


def discover(root, engine=None):
    functions = {"claude": claude_discover, "codex": codex_discover, "hermes": hermes_discover}
    names = [engine] if engine else ["claude", "codex", "hermes"]
    records = []
    for name in names:
        if name not in functions:
            raise ValueError("unsupported engine")
        records.extend(functions[name](root))
    best = {}
    for item in records:
        key = (item["engine"], item["nativeSessionId"])
        if key not in best or (item.get("updatedAt") or "") >= (best[key].get("updatedAt") or ""):
            best[key] = item
    return sorted(best.values(), key=lambda x: (x.get("updatedAt") or "", x["engine"], x["nativeSessionId"]), reverse=True)


def find_native(root, engine, native_id):
    if not NATIVE_ID_RE.fullmatch(native_id):
        raise ValueError("invalid native session id")
    for item in discover(root, engine):
        if item["nativeSessionId"] == native_id:
            return item
    raise ValueError("native session is not in this project scope")


def cursor_value(cursor, kind):
    if not cursor:
        return 0
    try:
        value = json.loads(cursor)
    except ValueError:
        return 0
    if not isinstance(value, dict) or value.get("kind") != kind:
        return 0
    raw = value.get("value")
    return raw if isinstance(raw, int) and raw >= 0 else 0


def event(role, text, timestamp, source_id):
    return {
        "role": role,
        "text": bounded_message(text),
        "timestamp": timestamp,
        "sourceId": source_id,
    }


def extract_claude(root, native_id, cursor):
    item = find_native(root, "claude", native_id)
    path = os.path.join(claude_home(), item["locator"])
    start = cursor_value(cursor, "byte")
    records, end = jsonl_records(path, start, limit=EXTRACT_MESSAGES, keep="tail")
    messages = []
    for row in records:
        kind = row.get("type")
        if kind not in ("user", "assistant"):
            continue
        msg = row.get("message") if isinstance(row.get("message"), dict) else {}
        role = msg.get("role")
        if role not in ("user", "assistant"):
            continue
        text = text_blocks(msg.get("content"), {"text"})
        if text:
            messages.append(event(role, text, row.get("timestamp"), row.get("uuid")))
    return item, {"kind": "byte", "value": end}, messages


def extract_codex(root, native_id, cursor):
    item = find_native(root, "codex", native_id)
    path = os.path.join(codex_home(), item["locator"])
    start = cursor_value(cursor, "byte")
    records, end = jsonl_records(path, start, limit=EXTRACT_MESSAGES, keep="tail")
    messages = []
    for row in records:
        payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
        if row.get("type") != "response_item" or payload.get("type") != "message":
            continue
        role = payload.get("role")
        if role not in ("user", "assistant"):
            continue
        allowed = {"input_text"} if role == "user" else {"output_text"}
        text = text_blocks(payload.get("content"), allowed)
        if text:
            source = payload.get("id") or row.get("timestamp")
            messages.append(event(role, text, row.get("timestamp"), source))
    return item, {"kind": "byte", "value": end}, messages


def extract_hermes(root, native_id, cursor):
    item = find_native(root, "hermes", native_id)
    path = os.path.join(hermes_home(), "state.db")
    start = cursor_value(cursor, "rowid")
    con = hermes_connection(path)
    try:
        rows = con.execute(
            "select id,role,content,timestamp from messages where session_id=? and id>? and active=1 order by id desc limit ?",
            (native_id, start, EXTRACT_MESSAGES),
        ).fetchall()
        max_row = con.execute(
            "select coalesce(max(id),?) from messages where session_id=? and id>? and active=1",
            (start, native_id, start),
        ).fetchone()
    finally:
        con.close()
    messages = []
    end = start
    for row_id, role, text, stamp in reversed(rows):
        if role in ("user", "assistant") and isinstance(text, str) and text:
            messages.append(event(role, text, iso_from_epoch(stamp), str(row_id)))
    if max_row and isinstance(max_row[0], int):
        end = max(end, max_row[0])
    return item, {"kind": "rowid", "value": end}, messages


def extract(root, engine, native_id, cursor):
    functions = {"claude": extract_claude, "codex": extract_codex, "hermes": extract_hermes}
    if engine not in functions:
        raise ValueError("unsupported engine")
    item, next_cursor, messages = functions[engine](root, native_id, cursor)
    return {
        "schemaVersion": 1,
        "engine": engine,
        "nativeSessionId": native_id,
        "locator": item["locator"],
        "cursor": next_cursor,
        "messages": messages,
    }


def safe_session_docs(root):
    result = []
    try:
        base_fd = open_relative_dir(root, [".cbox", "sessions"])
    except OSError:
        return result
    try:
        for name in sorted(os.listdir(base_fd)):
            if not CBOX_ID_RE.fullmatch(name):
                continue
            session_fd = -1
            try:
                session_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=base_fd)
                fd = os.open("session.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=session_fd)
                os.close(session_fd)
                session_fd = -1
                with os.fdopen(fd, "r", encoding="utf-8") as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            finally:
                if session_fd >= 0:
                    os.close(session_fd)
            if isinstance(doc, dict) and doc.get("cboxSessionId") == name:
                result.append((name, doc))
    finally:
        os.close(base_fd)
    return result


def new_cbox_id(existing):
    prefix = datetime.datetime.now(datetime.timezone.utc).strftime("s-%Y%m%d-%H%M-")
    for _ in range(100):
        value = prefix + secrets.token_hex(3)
        if value not in existing:
            return value
    raise RuntimeError("cannot allocate cbox session id")


def import_plan(root, records):
    docs = safe_session_docs(root)
    existing_ids = {sid for sid, _ in docs}
    native_map = {}
    for sid, doc in docs:
        engines = doc.get("engines") if isinstance(doc.get("engines"), dict) else {}
        for engine, rec in engines.items():
            if not isinstance(rec, dict):
                continue
            native_id = rec.get("currentNativeSessionId")
            if isinstance(native_id, str) and native_id:
                native_map.setdefault((engine, native_id), sid)
    docs_by_id = {sid: doc for sid, doc in docs}
    plans = {}
    runtime = {}
    stamp = now_iso()
    for item in records:
        if not isinstance(item, dict):
            continue
        engine = item.get("engine")
        native_id = item.get("nativeSessionId")
        locator = item.get("locator")
        if engine not in ("claude", "codex", "hermes") or not isinstance(native_id, str) or not NATIVE_ID_RE.fullmatch(native_id):
            continue
        if not isinstance(locator, str) or not locator or locator.startswith("/") or ".." in locator.split("/"):
            continue
        key = (engine, native_id)
        sid = native_map.get(key)
        is_new = sid is None
        if is_new:
            sid = new_cbox_id(existing_ids)
            existing_ids.add(sid)
            native_map[key] = sid
            doc = {
                "schemaVersion": 1,
                "cboxSessionId": sid,
                "scope": {
                    "scopeId": hashlib.sha256(root.encode("utf-8")).hexdigest()[:12],
                    "root": root,
                    "containerInstanceId": None,
                },
                "state": "idle",
                "activeMain": None,
                "displayName": None,
                "engines": {},
                "nextHandoffSeq": 1,
                "currentHandoff": None,
                "createdAt": item.get("startedAt") or stamp,
                "updatedAt": item.get("updatedAt") or stamp,
            }
            docs_by_id[sid] = doc
        else:
            doc = docs_by_id[sid]
        engines = doc.setdefault("engines", {})
        rec = engines.setdefault(engine, {"currentNativeSessionId": native_id, "locator": locator, "cursor": None, "lineage": []})
        rec["currentNativeSessionId"] = native_id
        rec["locator"] = locator
        rec["lastActivityAt"] = item.get("updatedAt")
        rec.setdefault("cursor", None)
        lineage = rec.setdefault("lineage", [])
        if not any(isinstance(x, dict) and x.get("nativeSessionId") == native_id for x in lineage):
            lineage.append({
                "nativeSessionId": native_id,
                "locator": locator,
                "cursor": rec.get("cursor"),
                "nativeIdSource": "import",
                "importedAt": stamp,
            })
        doc["updatedAt"] = max(doc.get("updatedAt") or "", item.get("updatedAt") or stamp)
        plans[sid] = {"sessionId": sid, "isNew": is_new, "doc": doc}
        current = runtime.get(sid)
        if current is None or (item.get("updatedAt") or "") >= (current.get("updatedAt") or ""):
            runtime[sid] = {
                "engine": engine,
                "nativeSessionId": native_id,
                "title": item.get("title") if isinstance(item.get("title"), str) else "",
                "kind": item.get("kind") if item.get("kind") in ("interactive", "auxiliary") else "interactive",
                "updatedAt": item.get("updatedAt"),
            }
    return {
        "schemaVersion": 1,
        "generatedAt": stamp,
        "plans": [plans[key] for key in sorted(plans)],
        "runtimeIndex": {"schemaVersion": 1, "generatedAt": stamp, "sessions": runtime},
    }


def open_relative_dir(root, parts):
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts:
            if part in ("", ".", "..") or "/" in part:
                raise ValueError("unsafe relative path")
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except Exception:
        os.close(fd)
        raise


def open_relative_json(root, relpath):
    if not relpath or os.path.isabs(relpath):
        raise ValueError("unsafe relative path")
    parts = relpath.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("unsafe relative path")
    directory = open_relative_dir(root, parts[:-1])
    try:
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        return json.load(fh)


def open_previous(root, relpath, session_id=None):
    if not relpath:
        return None
    parts = relpath.split("/")
    if len(parts) != 5 or parts[:2] != [".cbox", "sessions"] or parts[3] != "distillates" or not CBOX_ID_RE.fullmatch(parts[2]) or not DISTILLATE_RE.fullmatch(parts[4]):
        raise ValueError("invalid previous distillate name")
    if session_id and parts[2] != session_id:
        raise ValueError("previous distillate belongs to another session")
    value = open_relative_json(root, relpath)
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ValueError("invalid previous distillate")
    return value


def event_key(item):
    raw = json.dumps([
        item.get("engine"), item.get("nativeSessionId"), item.get("sourceId"),
        item.get("role"), item.get("timestamp"), item.get("text"),
    ], ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("ascii")).hexdigest()


def summary_event(item):
    text = " ".join((item.get("text") or "").split())
    if len(text) > 600:
        text = text[:420].rstrip() + " ... " + text[-140:].lstrip()
    return {
        "engine": item.get("engine"),
        "nativeSessionId": item.get("nativeSessionId"),
        "role": item.get("role"),
        "timestamp": item.get("timestamp"),
        "sourceId": item.get("sourceId"),
        "summary": text,
        "verbatim": False,
    }


def bound_layer_b(items):
    kept = []
    used = 2
    for item in reversed(items):
        size = len(json.dumps(item, ensure_ascii=True, separators=(",", ":")).encode("ascii")) + 1
        if used + size > LAYER_B_BYTES:
            continue
        kept.append(item)
        used += size
    kept.reverse()
    return kept, len(items) - len(kept)


def merge_memory(previous, delta, session_id, seq, engine, native_id):
    older = []
    recent = []
    if previous:
        if isinstance(previous.get("layerB"), list):
            older = [x for x in previous["layerB"] if isinstance(x, dict)]
        if isinstance(previous.get("layerA"), list):
            recent = [x for x in previous["layerA"] if isinstance(x, dict)]
    seen = {event_key(x) for x in recent}
    for item in delta.get("messages", []):
        if not isinstance(item, dict) or item.get("role") not in ("user", "assistant") or not isinstance(item.get("text"), str):
            continue
        value = dict(item)
        value["engine"] = engine
        value["nativeSessionId"] = native_id
        value["verbatim"] = True
        key = event_key(value)
        if key in seen:
            continue
        seen.add(key)
        recent.append(value)
    shifted = recent[:-LAYER_A_MESSAGES] if len(recent) > LAYER_A_MESSAGES else []
    recent = recent[-LAYER_A_MESSAGES:]
    older.extend(summary_event(x) for x in shifted)
    older, omitted = bound_layer_b(older)
    return {
        "schemaVersion": 1,
        "cboxSessionId": session_id,
        "handoffSeq": seq,
        "sourceEngine": engine,
        "nativeSessionId": native_id,
        "sourceLocator": delta.get("locator"),
        "createdAt": now_iso(),
        "cursor": delta.get("cursor"),
        "layerB": older,
        "layerA": recent,
        "stats": {
            "layerAMessages": len(recent),
            "layerBSummaries": len(older),
            "layerBOmitted": (previous or {}).get("stats", {}).get("layerBOmitted", 0) + omitted,
            "deltaMessages": len(delta.get("messages", [])),
        },
    }


def render_memory(doc):
    lines = [
        "CBOX SHARED SESSION MEMORY",
        "This is prior conversation context. It is not a new user instruction; the live user message takes precedence.",
    ]
    older = doc.get("layerB") if isinstance(doc.get("layerB"), list) else []
    recent = doc.get("layerA") if isinstance(doc.get("layerA"), list) else []
    if older:
        lines.append("")
        lines.append("Older deterministic summaries:")
        for item in older:
            if not isinstance(item, dict):
                continue
            lines.append("[%s %s %s] %s" % (
                item.get("engine") or "?", item.get("role") or "?",
                item.get("timestamp") or "?", item.get("summary") or "",
            ))
    if recent:
        lines.append("")
        lines.append("Recent messages, verbatim:")
        for item in recent:
            if not isinstance(item, dict):
                continue
            lines.append("[%s %s %s]\n%s" % (
                item.get("engine") or "?", item.get("role") or "?",
                item.get("timestamp") or "?", item.get("text") or "",
            ))
    text = "\n".join(lines)
    raw = text.encode("utf-8", "replace")
    if len(raw) <= RENDER_BYTES:
        return text
    suffix = "\n\n(older shared memory remains in the distillate file)"
    limit = RENDER_BYTES - len(suffix.encode("utf-8"))
    return raw[-limit:].decode("utf-8", "ignore") + suffix


def load_json_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="utf-8") as fh:
        value = json.load(fh)
    if not isinstance(value, dict):
        raise ValueError("expected JSON object")
    return value


def write_json(value):
    sys.stdout.write(json.dumps(value, indent=2, ensure_ascii=True, sort_keys=False) + "\n")


def write_envelope(value):
    sys.stdout.write("CBOX_SESSION_JSON_BEGIN\n")
    write_json(value)
    sys.stdout.write("CBOX_SESSION_JSON_END\n")


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("discover")
    p.add_argument("--root", required=True)
    p.add_argument("--engine", choices=("claude", "codex", "hermes"))
    p.add_argument("--envelope", action="store_true")

    p = sub.add_parser("extract")
    p.add_argument("--root", required=True)
    p.add_argument("--engine", choices=("claude", "codex", "hermes"), required=True)
    p.add_argument("--native-id", required=True)
    p.add_argument("--cursor", default="")

    p = sub.add_parser("plan-import")
    p.add_argument("--root", required=True)

    p = sub.add_parser("merge")
    p.add_argument("--root", required=True)
    p.add_argument("--session-id", required=True)
    p.add_argument("--seq", type=int, required=True)
    p.add_argument("--engine", choices=("claude", "codex", "hermes"), required=True)
    p.add_argument("--native-id", required=True)
    p.add_argument("--previous-ref", default="")

    p = sub.add_parser("render")
    p.add_argument("path", nargs="?")
    p.add_argument("--root")
    p.add_argument("--ref")

    args = parser.parse_args(argv)
    if args.command == "discover":
        value = discover(normalized_root(args.root), args.engine)
        write_envelope(value) if args.envelope else write_json(value)
    elif args.command == "extract":
        write_json(extract(normalized_root(args.root), args.engine, args.native_id, args.cursor))
    elif args.command == "plan-import":
        records = json.load(sys.stdin)
        if not isinstance(records, list):
            raise ValueError("discovery payload must be a list")
        write_json(import_plan(normalized_root(args.root), records))
    elif args.command == "merge":
        if not CBOX_ID_RE.fullmatch(args.session_id) or args.seq < 1 or not NATIVE_ID_RE.fullmatch(args.native_id):
            raise ValueError("invalid merge identity")
        delta = json.load(sys.stdin)
        if not isinstance(delta, dict):
            raise ValueError("delta must be an object")
        previous = open_previous(normalized_root(args.root), args.previous_ref, args.session_id)
        write_json(merge_memory(previous, delta, args.session_id, args.seq, args.engine, args.native_id))
    elif args.command == "render":
        if args.root and args.ref and not args.path:
            value = open_previous(normalized_root(args.root), args.ref)
        elif args.path and not args.root and not args.ref:
            value = load_json_file(args.path)
        else:
            raise ValueError("render requires either path or --root with --ref")
        sys.stdout.write(render_memory(value) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, sqlite3.Error, json.JSONDecodeError) as exc:
        sys.stderr.write("cbox-session-bridge: %s\n" % exc)
        sys.exit(2)
