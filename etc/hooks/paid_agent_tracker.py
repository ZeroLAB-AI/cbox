#!/usr/bin/env python3
import fcntl
import json
import math
import os
import re
import shutil
import stat
import sys
import time
from contextlib import contextmanager

FREE_AGENT_TYPES = {"hermes-local", "aevum-elm"}
DEFAULT_DIR = "/tmp/cbox-paid-agents"
DEFAULT_TTL_H = 12.0
DEFAULT_PENDING_TTL_S = 30.0
DEFAULT_IDLE_MIN = 20.0
READ_CAP_BYTES = 65536
HOOK_READ_CAP_BYTES = 16 * 1024 * 1024
NAME_STRIP_RE = re.compile(r"[^A-Za-z0-9_-]")
FALLBACK_FIELD_RE = re.compile(rb'"(hook_event_name|agent_id)"\s*:\s*("(?:\\.|[^"\\])*")')
LOCK_TIMEOUT_S = 2.0
LOCK_POLL_S = 0.05
FUTURE_TTS_GRACE_S = 60.0


def subscription_profile():
    val = os.environ.get("CBOX_SUBSCRIPTION_PROFILE", "").strip().lower()
    return val if val in ("low", "high", "max") else "high"


def state_dir():
    return os.environ.get("CBOX_PAID_AGENT_DIR") or DEFAULT_DIR


def _positive_env(name, default):
    try:
        val = float(os.environ.get(name, ""))
    except (TypeError, ValueError):
        return default
    return val if math.isfinite(val) and val > 0 else default


def ttl_seconds():
    return _positive_env("CBOX_PAID_AGENT_TTL_H", DEFAULT_TTL_H) * 3600.0


def pending_ttl_seconds():
    return _positive_env("CBOX_PAID_AGENT_PENDING_TTL_S", DEFAULT_PENDING_TTL_S)


def idle_seconds():
    return _positive_env("CBOX_PAID_AGENT_IDLE_MIN", DEFAULT_IDLE_MIN) * 60.0


def marker_name(agent_id):
    if not isinstance(agent_id, str):
        return ""
    return NAME_STRIP_RE.sub("", agent_id)[:128]


def _dir_ok(path, create):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        if not create:
            return False
        try:
            os.mkdir(path, 0o700)
            st = os.lstat(path)
        except OSError:
            return False
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode)


class PaidAgentStateError(Exception):
    pass


@contextmanager
def _locked(create=False):
    directory = state_dir()
    st = None
    try:
        st = os.lstat(directory)
    except FileNotFoundError:
        st = None
    except OSError as exc:
        raise PaidAgentStateError("state dir unusable: %s (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)" % exc)
    if st is not None and not stat.S_ISDIR(st.st_mode):
        raise PaidAgentStateError("state path is not a real directory (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)")
    if st is None:
        if not create:
            yield None
            return
        try:
            os.mkdir(directory, 0o700)
        except FileExistsError:
            raise PaidAgentStateError("state path exists but is not a directory (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)")
        except OSError as exc:
            raise PaidAgentStateError("cannot create state dir: %s (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)" % exc)
        try:
            st = os.lstat(directory)
        except OSError as exc:
            raise PaidAgentStateError("state dir unusable: %s (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)" % exc)
        if not stat.S_ISDIR(st.st_mode):
            raise PaidAgentStateError("state path is not a real directory (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)")
    lock_path = os.path.join(directory, ".lock")
    try:
        lstat = os.lstat(lock_path)
    except FileNotFoundError:
        lstat = None
    except OSError as exc:
        raise PaidAgentStateError("cannot inspect lock file: %s (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)" % exc)
    if lstat is not None:
        if stat.S_ISLNK(lstat.st_mode):
            raise PaidAgentStateError("lock file is a symlink, not a regular file (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)")
        if not stat.S_ISREG(lstat.st_mode):
            raise PaidAgentStateError("lock file is not a regular file (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)")
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        raise PaidAgentStateError("cannot open lock file: %s (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)" % exc)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise PaidAgentStateError("lock file is not a regular file (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)")
    deadline = time.monotonic() + LOCK_TIMEOUT_S
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise PaidAgentStateError("another process holds the paid-agent lock; the state dir may be wedged (fix: python3 ~/.claude/hooks/paid_agent_tracker.py reset)")
            time.sleep(LOCK_POLL_S)
    try:
        yield directory
    finally:
        os.close(fd)


def _safe_read_bytes(path, cap=READ_CAP_BYTES):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks = []
        total = 0
        while total < cap:
            chunk = os.read(fd, min(65536, cap - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        return b"".join(chunks)
    except OSError:
        return None
    finally:
        os.close(fd)


def _write_marker(directory, name, record):
    tmp = os.path.join(directory, ".tmp-%s-%d-%s" % (name, os.getpid(), os.urandom(8).hex()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        try:
            os.write(fd, json.dumps(record).encode("utf-8"))
        finally:
            os.close(fd)
        os.replace(tmp, os.path.join(directory, name))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _unlink_regular(path):
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            return False
        os.unlink(path)
        return True
    except OSError:
        return False


def _ts_value(raw):
    if isinstance(raw, bool):
        return None
    try:
        ts = float(raw)
    except (OverflowError, ValueError, TypeError):
        return None
    if not math.isfinite(ts):
        return None
    return ts


def _recomputed_transcript(rec):
    transcript_dir = rec.get("main_transcript_dir")
    session = rec.get("session_id")
    agent = rec.get("agent_id")
    if not all(isinstance(x, str) and x for x in (transcript_dir, session, agent)):
        return ""
    if not os.path.isabs(transcript_dir) or NAME_STRIP_RE.sub("", session) != session:
        return ""
    base = os.path.abspath(transcript_dir)
    path = os.path.abspath(os.path.join(transcript_dir, session, "subagents", "agent-%s.jsonl" % agent))
    real_base = os.path.realpath(base)
    real_path = os.path.realpath(path)
    if real_base != base or real_path != path:
        return ""
    return path if os.path.commonpath((real_base, real_path)) == real_base else ""


def _scan_locked(directory, now, prune=True):
    live = []
    for name in sorted(os.listdir(directory)):
        if name.startswith("."):
            continue
        if NAME_STRIP_RE.sub("", name) != name or name == "pending-":
            continue
        path = os.path.join(directory, name)
        raw = _safe_read_bytes(path)
        if raw is None:
            continue
        try:
            rec = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, RecursionError):
            continue
        if not isinstance(rec, dict):
            continue
        ts = _ts_value(rec.get("ts"))
        pending = name.startswith("pending-")
        if ts is None or ts > now + FUTURE_TTS_GRACE_S:
            if prune:
                _unlink_regular(path)
            continue
        stale = now - ts > (pending_ttl_seconds() if pending else ttl_seconds())
        if not stale and not pending:
            rec["agent_id"] = name
            transcript = _recomputed_transcript(rec)
            if transcript:
                try:
                    st = os.lstat(transcript)
                    stale = stat.S_ISREG(st.st_mode) and now - st.st_mtime > idle_seconds()
                except OSError:
                    pass
        if stale:
            if prune:
                _unlink_regular(path)
                continue
        rec["agent_id"] = name[8:] if pending else name
        rec["agent_type"] = marker_name(rec.get("agent_type"))
        rec["kind"] = "pending" if pending else "marker"
        rec["ts"] = ts
        live.append(rec)
    return live


def running_paid_agents(now=None):
    now = time.time() if now is None else now
    with _locked() as directory:
        return _scan_locked(directory, now) if directory else []


def reserve_paid_agent(agent_type, session_id, tool_use_id):
    if subscription_profile() != "low":
        return []
    key = marker_name(tool_use_id) or "anon-%d-%d" % (os.getpid(), time.time_ns())
    pending_name = "pending-" + key
    with _locked(True) as directory:
        live = _scan_locked(directory, time.time())
        others = [rec for rec in live if not (rec["kind"] == "pending" and rec["agent_id"] == key)]
        if others:
            return others
        if not any(rec["kind"] == "pending" and rec["agent_id"] == key for rec in live):
            _write_marker(directory, pending_name, {
                "kind": "pending", "agent_type": agent_type, "session_id": session_id,
                "ts": time.time()})
        return []


def _transcript_dir(data):
    transcript = data.get("transcript_path")
    if not isinstance(transcript, str) or not transcript:
        return ""
    return os.path.dirname(transcript)


def _transcript_path(data):
    transcript_dir = _transcript_dir(data)
    session = data.get("session_id")
    agent = data.get("agent_id")
    if not all(isinstance(x, str) and x for x in (transcript_dir, session, agent)):
        return ""
    return os.path.join(transcript_dir, session, "subagents", "agent-%s.jsonl" % agent)


def on_start(data):
    if subscription_profile() != "low":
        return
    atype = data.get("agent_type")
    if isinstance(atype, str) and atype in FREE_AGENT_TYPES:
        return
    name = marker_name(data.get("agent_id"))
    if not name:
        return
    with _locked(True) as directory:
        live = _scan_locked(directory, time.time())
        if not any(rec["kind"] == "marker" and rec["agent_id"] == name for rec in live):
            pending = [rec for rec in live if rec["kind"] == "pending"]
            same = [rec for rec in pending if rec.get("agent_type") == atype]
            chosen = min(same or pending, key=lambda rec: rec["ts"], default=None)
            if chosen:
                _unlink_regular(os.path.join(directory, "pending-" + chosen["agent_id"]))
        _write_marker(directory, name, {
            "agent_type": atype if isinstance(atype, str) else "",
            "session_id": data.get("session_id"),
            "main_transcript_dir": _transcript_dir(data),
            "ts": time.time(),
        })


def on_stop(data):
    name = marker_name(data.get("agent_id"))
    if not name:
        return
    with _locked() as directory:
        if directory:
            _unlink_regular(os.path.join(directory, name))


def on_task_stop(data):
    ti = data.get("tool_input")
    if data.get("tool_name") == "TaskStop" and isinstance(ti, dict):
        on_stop({"agent_id": ti.get("task_id") or ti.get("shell_id")})


def clear_session(data):
    session = data.get("session_id")
    if not isinstance(session, str) or not session:
        return
    with _locked() as directory:
        if not directory:
            return
        for rec in _scan_locked(directory, time.time(), prune=False):
            if rec.get("session_id") == session:
                name = "pending-" + rec["agent_id"] if rec["kind"] == "pending" else rec["agent_id"]
                _unlink_regular(os.path.join(directory, name))


def clear_stale():
    with _locked() as directory:
        if not directory:
            return 0
        before = {name for name in os.listdir(directory) if not name.startswith(".")}
        _scan_locked(directory, time.time())
        count = len(before - set(os.listdir(directory)))
        now = time.time()
        for name in os.listdir(directory):
            if not name.startswith(".tmp-"):
                continue
            path = os.path.join(directory, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode) and now - st.st_mtime > 60:
                count += int(_unlink_regular(path))
        return count


def clear_all():
    with _locked() as directory:
        if not directory:
            return 0
        return sum(_unlink_regular(os.path.join(directory, name))
                   for name in os.listdir(directory)
                   if not name.startswith(".") or name.startswith(".tmp-"))


def clear_one(agent_id):
    name = marker_name(agent_id)
    if not name:
        return 0
    with _locked() as directory:
        if not directory:
            return 0
        removed = 0
        removed += int(_unlink_regular(os.path.join(directory, name)))
        removed += int(_unlink_regular(os.path.join(directory, "pending-" + name)))
        return removed


def _fallback_stop(raw):
    fields = {}
    for match in FALLBACK_FIELD_RE.finditer(raw):
        try:
            fields[match.group(1).decode("ascii")] = json.loads(match.group(2))
        except (ValueError, UnicodeDecodeError):
            pass
        if "hook_event_name" in fields and "agent_id" in fields:
            break
    if fields.get("hook_event_name") == "SubagentStop":
        on_stop(fields)


def reset_state():
    path = state_dir()
    removed = []
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        st = None
    if st is not None and not stat.S_ISDIR(st.st_mode):
        os.unlink(path)
        removed.append(os.path.basename(path))
        print("removed %s" % removed[-1])
    elif st is not None:
        directory_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fchmod(directory_fd, 0o700)
            for entry in os.listdir(directory_fd):
                mode = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False).st_mode
                if stat.S_ISDIR(mode):
                    shutil.rmtree(entry, dir_fd=directory_fd)
                    removed.append(entry + "/")
                else:
                    os.unlink(entry, dir_fd=directory_fd)
                    removed.append(entry)
                print("removed %s" % removed[-1])
        finally:
            os.close(directory_fd)
        os.rmdir(path)
    os.mkdir(path, 0o700)
    directory_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fchmod(directory_fd, 0o700)
        lock_fd = os.open(".lock", os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW,
                          0o600, dir_fd=directory_fd)
        os.close(lock_fd)
    finally:
        os.close(directory_fd)
    if not removed:
        print("no entries removed")
    print("recreated %s" % path)


def hook_main():
    try:
        raw = sys.stdin.buffer.read(HOOK_READ_CAP_BYTES + 1)
        try:
            data = json.loads(raw) if len(raw) <= HOOK_READ_CAP_BYTES else None
        except (ValueError, UnicodeDecodeError, RecursionError):
            data = None
        if not isinstance(data, dict):
            _fallback_stop(raw)
            return
        event = data.get("hook_event_name")
        if event == "SubagentStart":
            on_start(data)
        elif event == "SubagentStop":
            on_stop(data)
        elif event == "PostToolUse":
            on_task_stop(data)
        elif event == "SessionStart" and data.get("source") in ("startup", "resume"):
            clear_session(data)
        elif event == "SessionEnd":
            clear_session(data)
    except BaseException:
        return


if __name__ == "__main__":
    status = 0
    if len(sys.argv) > 1 and sys.argv[1] == "clear":
        try:
            count = clear_all() if len(sys.argv) > 2 and sys.argv[2] == "--all" else (
                clear_one(sys.argv[2]) if len(sys.argv) > 2 else clear_stale())
            print(count)
        except BaseException:
            print(0)
    elif len(sys.argv) > 1 and sys.argv[1] == "reset":
        try:
            reset_state()
        except Exception as exc:
            print("reset failed: %s" % exc, file=sys.stderr)
            status = 1
    else:
        hook_main()
    sys.exit(status)
