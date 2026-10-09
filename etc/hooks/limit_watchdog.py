#!/usr/bin/env python3
import calendar
import fcntl
import json
import math
import os
import re
import socket
import stat
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import session_scope_farm as farm
import cbox_budget

CFG = farm.CFG
WATCH = os.path.join(CFG, "limit-watch") if CFG else ""
MARKERS = os.path.join(WATCH, "markers") if CFG else ""
PANES = os.path.join(WATCH, "panes") if CFG else ""
def int_env(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


AUTORESUME = os.environ.get("CBOX_LIMIT_AUTORESUME", "off") == "on"


def regulator_autoresume_enabled(value):
    return value.strip().lower() not in ("", "off", "0", "false", "no")


REGULATOR_AUTORESUME = regulator_autoresume_enabled(os.environ.get("CBOX_REGULATOR_AUTORESUME", "on"))
DELAY = int_env("CBOX_LIMIT_RESUME_DELAY", 10)
PROMPT = os.environ.get("CBOX_LIMIT_RESUME_PROMPT", "pokracuj") or "pokracuj"
STAGGER = int_env("CBOX_LIMIT_RESUME_STAGGER", 3)
MAX_PER_DAY = int_env("CBOX_LIMIT_RESUME_MAX_PER_DAY", 10)

SAFEGUARD = os.environ.get("CBOX_SAFEGUARD_AUTOCONFIRM", "off") == "on"
SAFEGUARD_TAIL_LINES = int_env("CBOX_SAFEGUARD_TAIL_LINES", 24)
SAFEGUARD_COOLDOWN = int_env("CBOX_SAFEGUARD_COOLDOWN", 20)
SAFEGUARD_MAX_PER_DAY = int_env("CBOX_SAFEGUARD_MAX_PER_DAY", 40)
SAFEGUARD_CONFIRM_KEY = "Enter"
SAFEGUARD_CHROME_WINDOW = 4
SAFEGUARD_ANCHOR_RE = re.compile(
    r"safety\s+safeguards?\s+(?:triggered|switch)"
    r"|switch(?:ing)?\s+to\s+\w+\s+(?:and\s+)?retry"
    r"|model\s+safeguards?\s+(?:switch|triggered)", re.I)
SAFEGUARD_CHROME_RE = re.compile(
    r"^\s*(?:[^\w\s]\s+)?(?:\d+[.)]|\[[^\]]+\])\s")
SAFEGUARD_FOREIGN_RE = re.compile(
    r"do you want to proceed"
    r"|do you trust the files"
    r"|tell claude what to do differently"
    r"|no,?\s+(?:and\s+)?(?:tell|keep|exit)", re.I)
HOSTNAME = socket.gethostname()
PANE_RE = re.compile(r"^%\d+$")
POLL = 15
LOG_LIMIT = 1024 * 1024
REGULATOR_EXPIRY = 6 * 3600
FRESH_WINDOW = 48 * 3600
MARKER_TTL = 8 * 24 * 3600
EPOCH_RE = re.compile(r"limit reached\|(\d{10,13})")
RESETS_RE = re.compile(rb'"resets?At"\s*:\s*"?(\d{10,13})')
PREFILTER = (b"usage limit", b"usage credit")
STALE_GRACE = 300
STALE_STATES = ("working", "running", "blocked")


_LOG_SEEN = {}


def log(msg):
    dedupe = msg.startswith(("reconciled stale job:", "loop error (", "safeguard pane pass error:",
                             "inject failed before typing:", "regulator inject failed:",
                             "regulator budget read failed:", "regulator marker pass error:"))
    key = msg.split(" prevState=", 1)[0] if msg.startswith("reconciled stale job:") else msg.split(" ", 5)[:5] if msg.startswith("regulator marker pass error:") else msg.split(":", 1)[0]
    if isinstance(key, list):
        key = " ".join(key)
    if dedupe and _LOG_SEEN.get(key) == msg:
        return
    try:
        os.makedirs(WATCH, exist_ok=True)
        path = os.path.join(WATCH, "watchdog.log")
        line = "%s [%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), HOSTNAME, msg)
        lockfd = os.open(path + ".lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(lockfd, fcntl.LOCK_EX)
            try:
                info = os.lstat(path)
                if not stat.S_ISREG(info.st_mode):
                    raise OSError("invalid watchdog log")
                size = info.st_size
            except FileNotFoundError:
                size = 0
            if size + len(line.encode("utf-8")) > LOG_LIMIT:
                os.replace(path, path + ".1")
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, line.encode("utf-8"))
            finally:
                os.close(fd)
        finally:
            os.close(lockfd)
        if dedupe:
            _LOG_SEEN[key] = msg
    except OSError:
        pass


def norm_epoch(value):
    v = int(value)
    if v > 10 ** 12:
        v //= 1000
    if v < 10 ** 9 or v > 10 ** 11:
        return None
    return v


def extract_event(raw):
    if not any(p in raw for p in PREFILTER):
        return None
    try:
        entry = json.loads(raw)
    except ValueError:
        return None
    if not entry.get("isApiErrorMessage"):
        return None
    message = entry.get("message") or {}
    content = message.get("content")
    texts = []
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                texts.append(item["text"])
    text = " ".join(texts)
    if "usage limit" not in text.lower() and "usage credit" not in text.lower():
        return None
    reset_at = None
    m = EPOCH_RE.search(text)
    if m:
        reset_at = norm_epoch(m.group(1))
    if reset_at is None:
        m = RESETS_RE.search(raw)
        if m:
            reset_at = norm_epoch(m.group(1))
    cwd = entry.get("cwd")
    if not isinstance(cwd, str):
        cwd = ""
    return {"resetAt": reset_at, "cwd": cwd[:512]}


def marker_path(sid, reset_at, kind="limit"):
    if kind == "regulator":
        return os.path.join(MARKERS, "%s.regulator.json" % sid)
    return os.path.join(MARKERS, "%s.%d.json" % (sid, reset_at or 0))


def write_regulator_marker(sid, transcript, due, created_at=None):
    if not isinstance(sid, str) or not farm.SID_RE.fullmatch(sid):
        return False
    if not isinstance(transcript, str) or not marker_owns_transcript({"transcript": transcript}, sid):
        return False
    try:
        size = os.stat(transcript, follow_symlinks=False).st_size
        if not stat.S_ISREG(os.lstat(transcript).st_mode):
            return False
        os.makedirs(MARKERS, mode=0o700, exist_ok=True)
        if not stat.S_ISDIR(os.lstat(MARKERS).st_mode):
            return False
        path = marker_path(sid, None, "regulator")
        if os.path.islink(path):
            return False
        created = time.time() if created_at is None else created_at
        rec = {"kind": "regulator", "session_id": sid,
               "transcript_path": transcript, "transcript_offset": size,
               "due": due, "first_due": due, "created_at": created}
        fd, tmp = tempfile.mkstemp(prefix=".regulator.", dir=MARKERS)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as fh:
                json.dump(rec, fh)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        return True
    except (OSError, ValueError, TypeError):
        return False


def write_marker(sid, event, transcript, size):
    os.makedirs(MARKERS, exist_ok=True)
    path = marker_path(sid, event["resetAt"])
    if os.path.lexists(path):
        return False
    rec = {
        "sessionId": sid,
        "resetAt": event["resetAt"],
        "cwd": event["cwd"],
        "transcript": transcript,
        "eventOffset": size,
        "detectedAt": int(time.time()),
        "detectedBy": HOSTNAME,
        "state": "pending",
    }
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(rec, fh)
        os.replace(tmp, path)
    except OSError:
        return False
    log("limit detected: session=%s resetAt=%s transcript=%s" % (
        sid, event["resetAt"], transcript))
    return True


def scan_transcripts(offsets):
    projects = os.path.join(CFG, "projects")
    now = time.time()
    seen = set()
    for slug in farm.entries(projects):
        pdir = os.path.join(projects, slug)
        if not os.path.isdir(pdir):
            continue
        for name in farm.entries(pdir):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(pdir, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if now - st.st_mtime > FRESH_WINDOW:
                continue
            seen.add(path)
            offset = offsets.get(path, 0)
            if st.st_size < offset:
                offset = 0
            if st.st_size == offset:
                continue
            sid = name[:-6]
            if not farm.SID_RE.match(sid):
                continue
            try:
                with open(path, "rb") as fh:
                    fh.seek(offset)
                    for raw in fh:
                        if not raw.endswith(b"\n"):
                            break
                        offset += len(raw)
                        event = extract_event(raw)
                        if event:
                            write_marker(sid, event, path, offset)
            except OSError:
                continue
            offsets[path] = offset
    for path in list(offsets):
        if path not in seen:
            del offsets[path]


def load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def pane_for(sid):
    return load_json(os.path.join(PANES, sid + ".json"))


def pane_alive(pane):
    try:
        rc = subprocess.run(
            ["tmux", "display-message", "-p", "-t", pane, "ok"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=10).returncode
    except (OSError, subprocess.TimeoutExpired):
        return False
    return rc == 0


def activity_after_event(marker):
    try:
        with open(marker["transcript"], "rb") as fh:
            fh.seek(marker.get("eventOffset", 0))
            for raw in fh:
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                if entry.get("isApiErrorMessage"):
                    continue
                if entry.get("type") in ("user", "assistant"):
                    return True
    except OSError:
        return True
    return False


def _transcript_bytes(path, offset, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not isinstance(offset, int) or offset < 0 or offset > info.st_size:
            raise ValueError("invalid transcript")
        os.lseek(fd, offset, os.SEEK_SET)
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            raise ValueError("transcript read limit")
        return data
    finally:
        os.close(fd)


def human_prompt_after_event(marker):
    try:
        raw_data = _transcript_bytes(marker["transcript_path"], marker["transcript_offset"], 4 * 1024 * 1024)
        for raw in raw_data.splitlines():
            if len(raw) > 1024 * 1024:
                return True
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("type") != "user":
                continue
            if any(entry.get(key) for key in ("isMeta", "isSynthetic", "synthetic", "meta")):
                continue
            if entry.get("source") in ("meta", "synthetic") or entry.get("userType") == "synthetic":
                continue
            message = entry.get("message")
            if not isinstance(message, dict) or any(message.get(key) for key in ("isMeta", "isSynthetic")):
                continue
            content = message.get("content")
            if isinstance(content, str):
                return True
            if isinstance(content, list) and content and all(isinstance(item, dict) for item in content):
                if not any(item.get("type") == "tool_result" for item in content):
                    return True
    except (OSError, KeyError, ValueError, TypeError):
        return True
    return False


def pane_idle(marker):
    try:
        path = marker["transcript_path"]
        size = os.stat(path, follow_symlinks=False).st_size
        lines = _transcript_bytes(path, max(0, size - 65536), 65536).splitlines()
        for raw in reversed(lines):
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict) or any(entry.get(key) for key in ("isMeta", "isSynthetic", "synthetic", "meta")):
                continue
            if entry.get("type") == "user":
                return False
            if entry.get("type") != "assistant":
                continue
            message = entry.get("message")
            return isinstance(message, dict) and message.get("stop_reason") == "end_turn"
    except (OSError, KeyError, ValueError, TypeError):
        return False
    return False


def resumed_last_day(sid):
    count = 0
    cutoff = time.time() - 24 * 3600
    for name in farm.entries(MARKERS):
        if not name.startswith(sid + "."):
            continue
        rec = load_json(os.path.join(MARKERS, name))
        if rec and rec.get("state") == "resumed" and \
                rec.get("resumedAt", 0) >= cutoff:
            count += 1
    return count


def update_locked(path, expect_state, **fields):
    try:
        fh = open(path, "r+")
    except OSError:
        return None
    with fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX)
            rec = json.load(fh)
        except (OSError, ValueError):
            return None
        if rec.get("state") != expect_state:
            return None
        rec.update(fields)
        fh.seek(0)
        fh.truncate()
        json.dump(rec, fh)
        return rec


def inject(pane, prompt=None):
    text = PROMPT if prompt is None else prompt
    typed = False
    try:
        subprocess.run(["tmux", "send-keys", "-t", pane, "-l", text],
                       check=True, timeout=10)
        typed = True
        subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"],
                       check=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        if typed:
            return repr(exc)
        raise
    return None


def capture_pane_tail(pane, lines):
    try:
        out = subprocess.run(
            ["tmux", "capture-pane", "-p", "-t", pane],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        text = out.stdout.decode("utf-8", "replace")
    except Exception:
        return None
    rows = text.splitlines()
    while rows and not rows[-1].strip():
        rows.pop()
    return rows[-max(lines, 1):]


def safeguard_dialog_present(pane):
    rows = capture_pane_tail(pane, SAFEGUARD_TAIL_LINES)
    if not rows:
        return False
    joined = "\n".join(rows)
    if SAFEGUARD_FOREIGN_RE.search(joined):
        return False
    anchor_idx = None
    for i, row in enumerate(rows):
        if SAFEGUARD_ANCHOR_RE.search(row):
            anchor_idx = i
            break
    if anchor_idx is None:
        return False
    window = rows[anchor_idx + 1:anchor_idx + 1 + SAFEGUARD_CHROME_WINDOW]
    for row in window:
        if SAFEGUARD_CHROME_RE.search(row):
            return True
    return False


def safeguard_confirm(pane):
    try:
        subprocess.run(["tmux", "send-keys", "-t", pane, SAFEGUARD_CONFIRM_KEY],
                       check=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        return repr(exc)
    return None


_SAFEGUARD_MEM = {}


def safeguard_pass():
    if not os.path.isdir(PANES):
        return
    now = time.time()
    today = time.strftime("%Y-%m-%d")
    for name in sorted(farm.entries(PANES)):
        if not name.endswith(".json"):
            continue
        sid = name[:-5]
        if not farm.SID_RE.match(sid):
            continue
        pane = pane_for(sid)
        if not pane or pane.get("container") != HOSTNAME:
            continue
        pane_id = pane.get("pane")
        if not pane_id or not PANE_RE.match(pane_id) or not pane_alive(pane_id):
            continue
        try:
            _safeguard_pane_pass(sid, pane_id, now, today)
        except Exception as exc:
            log("safeguard pane pass error: session=%s pane=%s %r" % (sid, pane_id, exc))


def _safeguard_num(value):
    return value if isinstance(value, (int, float)) else 0


def _safeguard_pane_pass(sid, pane_id, now, today):
    mem = _SAFEGUARD_MEM.get(sid) or {}
    if mem.get("disabled"):
        return
    state_path = os.path.join(WATCH, "safeguard", sid + ".json")
    st = load_json(state_path)
    if not isinstance(st, dict):
        st = {}
    last = max(_safeguard_num(st.get("last")), _safeguard_num(mem.get("last")))
    if now - last < SAFEGUARD_COOLDOWN:
        return
    if st.get("day") != today:
        st = {"day": today, "count": 0}
    if mem.get("day") != today:
        mem = {"day": today, "count": 0}
    count = max(_safeguard_num(st.get("count")), _safeguard_num(mem.get("count")))
    if count >= SAFEGUARD_MAX_PER_DAY:
        return
    if not safeguard_dialog_present(pane_id):
        return
    err = safeguard_confirm(pane_id)
    count += 1
    st["last"] = now
    st["count"] = count
    mem = {"day": today, "count": count, "last": now}
    _SAFEGUARD_MEM[sid] = mem
    try:
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        tmp = state_path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, state_path)
    except OSError as exc:
        mem["disabled"] = True
        _SAFEGUARD_MEM[sid] = mem
        log("safeguard state write failed, disabling session for this run: session=%s %r" % (sid, exc))
    if err:
        log("safeguard confirm send failed: session=%s pane=%s %s" % (sid, pane_id, err))
        return
    time.sleep(1)
    if safeguard_dialog_present(pane_id):
        log("safeguard dialog still present after confirm: session=%s pane=%s" % (sid, pane_id))
    else:
        log("safeguard dialog auto-confirmed: session=%s pane=%s" % (sid, pane_id))


def marker_owns_transcript(marker, sid):
    transcript = marker.get("transcript_path") or marker.get("transcript") or ""
    if not isinstance(transcript, str) or os.path.basename(transcript) != sid + ".jsonl":
        return False
    projects = os.path.realpath(os.path.join(CFG, "projects"))
    return os.path.realpath(transcript).startswith(projects + os.sep)


def _regulator_count_path(sid):
    return os.path.join(WATCH, "regulator-counts", sid + ".json")


def _regulator_times(sid, now):
    data = load_json(_regulator_count_path(sid))
    times = data.get("times") if isinstance(data, dict) else None
    if not isinstance(times, list):
        return []
    return [value for value in times if isinstance(value, (int, float)) and math.isfinite(value) and now - 24 * 3600 <= value <= now]


def _regulator_record_count(sid, now):
    path = _regulator_count_path(sid)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".count.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump({"times": _regulator_times(sid, now) + [now]}, fh)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _marker_signature(path):
    info = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("invalid marker")
    return info.st_ino, info.st_mtime_ns, info.st_size


def _remove_marker(path, signature):
    try:
        if _marker_signature(path) != signature:
            return False
        os.unlink(path)
        return True
    except FileNotFoundError:
        return False


def _replace_marker(path, signature, marker):
    fd, tmp = tempfile.mkstemp(prefix=".regulator.", dir=MARKERS)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(marker, fh)
        if _marker_signature(path) != signature:
            return False
        os.replace(tmp, path)
        return True
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _regulator_marker_pass(path, name, now):
    signature = _marker_signature(path)
    marker = load_json(path)
    if not isinstance(marker, dict) or marker.get("kind") != "regulator":
        return
    if _marker_signature(path) != signature:
        return
    sid = marker.get("session_id")
    due = marker.get("due")
    first_due = marker.get("first_due", due)
    valid_sid = isinstance(sid, str) and farm.SID_RE.fullmatch(sid)
    valid_time = (isinstance(due, (int, float)) and math.isfinite(due) and
                  isinstance(first_due, (int, float)) and math.isfinite(first_due) and
                  now - REGULATOR_EXPIRY - 60 <= first_due <= due <= now + MARKER_TTL)
    if not valid_sid or path != marker_path(sid, None, "regulator") or not marker_owns_transcript(marker, sid) or not valid_time:
        _remove_marker(path, signature)
        log("invalid regulator marker rejected: %s" % name)
        return
    if now - first_due >= REGULATOR_EXPIRY:
        _remove_marker(path, signature)
        log("regulator marker expired: session=%s" % sid)
        return
    if now < due:
        return
    if human_prompt_after_event(marker):
        _remove_marker(path, signature)
        log("regulator marker cancelled by human prompt: session=%s" % sid)
        return
    try:
        budget = cbox_budget.budget_for_family("claude", now=now)
    except Exception as exc:
        log("regulator budget read failed: session=%s err=%r" % (sid, exc))
        return
    b = budget.get("b")
    if b is not None and b < 0.5 and budget.get("status") in ("ok", "override"):
        next_reset = budget.get("resets_at")
        if isinstance(next_reset, (int, float)) and math.isfinite(next_reset) and next_reset > now:
            marker["due"] = next_reset + 2
            _replace_marker(path, signature, marker)
        return
    if len(_regulator_times(sid, now)) >= MAX_PER_DAY:
        _remove_marker(path, signature)
        log("regulator resume suppressed (daily cap): session=%s" % sid)
        return
    pane = pane_for(sid)
    if not pane or pane.get("container") != HOSTNAME:
        return
    pane_id = pane.get("pane")
    if not pane_id or not PANE_RE.fullmatch(pane_id) or not pane_alive(pane_id):
        return
    if human_prompt_after_event(marker) or not pane_idle(marker):
        return
    if _marker_signature(path) != signature:
        return
    reset_text = time.strftime("%H:%M:%SZ", time.gmtime(int(due) - 2))
    n = budget.get("n")
    if budget.get("free") or budget.get("status") == "off":
        agents_text = "inf"
    else:
        agents_text = str(n if isinstance(n, int) else 0)
    prompt = "cbox: quota reset at %s, agents: %s; continue the blocked step" % (reset_text, agents_text)
    try:
        partial = inject(pane_id, prompt)
    except (OSError, subprocess.SubprocessError) as exc:
        log("regulator inject failed: session=%s err=%r" % (sid, exc))
        return
    if partial:
        log("regulator inject partial: session=%s err=%s" % (sid, partial))
    try:
        _regulator_record_count(sid, now)
    except OSError as exc:
        log("regulator count write failed: session=%s err=%r" % (sid, exc))
    _remove_marker(path, signature)
    log("regulator resumed: session=%s pane=%s" % (sid, pane_id))


def regulator_pass():
    if not REGULATOR_AUTORESUME:
        return
    now = time.time()
    for name in sorted(farm.entries(MARKERS)):
        if not name.endswith(".regulator.json"):
            continue
        try:
            _regulator_marker_pass(os.path.join(MARKERS, name), name, now)
        except (OSError, ValueError, TypeError, OverflowError) as exc:
            log("regulator marker pass error: %s %r" % (name, exc))


def resume_pass():
    now = time.time()
    injected = 0
    for name in sorted(farm.entries(MARKERS)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(MARKERS, name)
        marker = load_json(path)
        if not marker or marker.get("state") != "pending":
            continue
        reset_at = marker.get("resetAt")
        if not reset_at or now < reset_at + DELAY:
            continue
        sid = marker.get("sessionId") or ""
        if not farm.SID_RE.match(sid) or not marker_owns_transcript(marker, sid):
            if update_locked(path, "pending", state="invalid"):
                log("invalid marker rejected: %s" % name)
            continue
        if activity_after_event(marker):
            if update_locked(path, "pending", state="cancelled"):
                log("cancelled (session active after event): session=%s" % sid)
            continue
        if resumed_last_day(sid) >= MAX_PER_DAY:
            if update_locked(path, "pending", state="suppressed"):
                log("suppressed (daily cap): session=%s" % sid)
            continue
        pane = pane_for(sid)
        if not pane or pane.get("container") != HOSTNAME:
            continue
        pane_id = pane.get("pane")
        if not pane_id or not PANE_RE.match(pane_id) or not pane_alive(pane_id):
            continue
        if injected and STAGGER:
            time.sleep(STAGGER)
        rec = update_locked(path, "pending", state="resuming",
                            resumedBy=HOSTNAME)
        if not rec:
            continue
        try:
            partial = inject(pane_id)
        except (OSError, subprocess.SubprocessError) as exc:
            update_locked(path, "resuming", state="pending",
                          lastError=repr(exc))
            log("inject failed before typing: session=%s err=%r" % (sid, exc))
            continue
        if partial:
            update_locked(path, "resuming", state="resumed",
                          resumedAt=int(time.time()), lastError=partial)
            log("resumed (enter failed, prompt typed): session=%s err=%s"
                % (sid, partial))
        else:
            update_locked(path, "resuming", state="resumed",
                          resumedAt=int(time.time()))
            log("resumed: session=%s pane=%s" % (sid, pane_id))
        injected += 1


def parse_iso(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        v = value
        if v.endswith("Z"):
            v = v[:-1] + "+00:00"
        return calendar.timegm(time.strptime(v[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, OverflowError):
        return None


def local_sessions():
    result = {}
    sdir = os.path.join(CFG, "sessions")
    for name in farm.entries(sdir):
        if not name.endswith(".json"):
            continue
        rec = load_json(os.path.join(sdir, name))
        if not rec:
            continue
        sid = rec.get("sessionId")
        if isinstance(sid, str) and sid:
            result.setdefault(sid, []).append(rec)
    return result


def pid_alive_with_start(pid, proc_start):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    try:
        with open("/proc/%d/stat" % pid) as fh:
            raw = fh.read()
    except OSError:
        return False
    close = raw.rfind(")")
    if close < 0:
        return False
    fields = raw[close + 2:].split()
    if len(fields) < 20:
        return False
    if proc_start is None:
        return True
    try:
        return int(str(fields[19])) == int(float(str(proc_start)))
    except (TypeError, ValueError):
        return str(fields[19]) == str(proc_start)


def session_alive(rec):
    return pid_alive_with_start(rec.get("pid"), rec.get("procStart"))


def daemon_roster_mentions(sid, job_id):
    status = load_json(os.path.join(CFG, "daemon.status.json"))
    if not isinstance(status, dict):
        return False
    workers = status.get("workers")
    try:
        blob = json.dumps(workers)
    except (TypeError, ValueError):
        return False
    return (sid and sid in blob) or (job_id and job_id in blob)


def job_owned_locally(job_id, state, sessions_by_id):
    sid = state.get("sessionId")
    if not isinstance(sid, str) or not sid or not farm.SID_RE.match(sid):
        return False
    return sid in sessions_by_id


def job_alive(job_id, state, sessions_by_id):
    sid = state.get("sessionId")
    recs = sessions_by_id.get(sid, []) if isinstance(sid, str) else []
    for rec in recs:
        if session_alive(rec):
            return True
    if daemon_roster_mentions(sid, job_id):
        return True
    return False


def job_stale_seconds(job_path, state):
    updated = parse_iso(state.get("updatedAt"))
    if updated is None:
        try:
            updated = os.path.getmtime(job_path)
        except OSError:
            return 0
    return time.time() - updated


def reconcile_locked(path, expect_state, detail_suffix):
    try:
        fh = open(path, "r+")
    except OSError:
        return None
    with fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX)
            rec = json.load(fh)
        except (OSError, ValueError):
            return None
        if rec.get("state") != expect_state:
            return None
        rec["state"] = "failed"
        rec["detail"] = (rec.get("detail") or "") + detail_suffix
        tmp = path + ".tmp"
        try:
            with open(tmp, "w") as tfh:
                json.dump(rec, tfh)
            os.replace(tmp, path)
        except OSError:
            return None
        return rec


def reconcile_stale_jobs():
    farm_dir = os.path.join(CFG, "jobs")
    if not os.path.isdir(farm_dir):
        return
    sessions_by_id = local_sessions()
    for name in farm.entries(farm_dir):
        if name == "settled" or not farm.SID_RE.match(name):
            continue
        job_dir = os.path.join(farm_dir, name)
        if not os.path.isdir(job_dir):
            continue
        state_path = os.path.join(job_dir, "state.json")
        state = load_json(state_path)
        if not state or state.get("state") not in STALE_STATES:
            continue
        if not job_owned_locally(name, state, sessions_by_id):
            continue
        if job_stale_seconds(state_path, state) < STALE_GRACE:
            continue
        if job_alive(name, state, sessions_by_id):
            continue
        if reconcile_locked(state_path, state.get("state"),
                             "; reconciled: no live process"):
            log("reconciled stale job: id=%s prevState=%s" % (
                name, state.get("state")))


def prune():
    now = time.time()
    cutoff = now - MARKER_TTL
    for name in farm.entries(MARKERS):
        path = os.path.join(MARKERS, name)
        rec = load_json(path)
        created = rec.get("created_at", 0) if isinstance(rec, dict) and rec.get("kind") == "regulator" else rec.get("detectedAt", 0) if isinstance(rec, dict) else 0
        if rec is None or created < cutoff:
            try:
                os.unlink(path)
            except OSError:
                pass
    count_dir = os.path.join(WATCH, "regulator-counts")
    for name in farm.entries(count_dir):
        if not name.endswith(".json"):
            continue
        path = os.path.join(count_dir, name)
        data = load_json(path)
        times = data.get("times") if isinstance(data, dict) else None
        if not isinstance(times, list) or not any(isinstance(value, (int, float)) and math.isfinite(value) and now - 24 * 3600 <= value <= now for value in times):
            try:
                os.unlink(path)
            except OSError:
                pass
    for directory, prefixes in ((MARKERS, (".regulator.",)), (count_dir, (".count.",))):
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        for name in names:
            if not name.startswith(prefixes):
                continue
            path = os.path.join(directory, name)
            try:
                if os.lstat(path).st_mtime < now - 3600:
                    os.unlink(path)
            except OSError:
                pass


def next_sleep(now=None):
    now = time.time() if now is None else now
    due_times = []
    for name in farm.entries(MARKERS):
        if not name.endswith(".json"):
            continue
        rec = load_json(os.path.join(MARKERS, name))
        if not isinstance(rec, dict):
            continue
        if rec.get("kind") == "regulator":
            if REGULATOR_AUTORESUME:
                due_times.append(rec.get("due"))
                first_due = rec.get("first_due", rec.get("due"))
                if isinstance(first_due, (int, float)) and math.isfinite(first_due):
                    due_times.append(first_due + REGULATOR_EXPIRY)
        elif AUTORESUME and rec.get("state") == "pending":
            reset = rec.get("resetAt")
            if isinstance(reset, (int, float)):
                due_times.append(reset + DELAY)
    due_times = [value for value in due_times if isinstance(value, (int, float)) and math.isfinite(value) and value > now]
    if not due_times:
        return float(POLL)
    return max(0.5, min(float(POLL), min(due_times) - now))


def daemon():
    if not farm.env_ok():
        return 0
    lock = farm.try_lock("daemon.lock")
    if lock is None:
        return 0
    os.makedirs(MARKERS, exist_ok=True)
    os.makedirs(PANES, exist_ok=True)
    log("watchdog started (autoresume=%s regulator=%s safeguard=%s delay=%ss stagger=%ss cap=%s/day)" % (
        "on" if AUTORESUME else "off", "on" if REGULATOR_AUTORESUME else "off", "on" if SAFEGUARD else "off",
        DELAY, STAGGER, MAX_PER_DAY))
    offsets = {}
    while True:
        try:
            farm.refresh_all()
        except Exception as exc:
            log("loop error (refresh_all): %r" % exc)
        try:
            reconcile_stale_jobs()
        except Exception as exc:
            log("loop error (reconcile_stale_jobs): %r" % exc)
        try:
            scan_transcripts(offsets)
            if AUTORESUME:
                resume_pass()
            if REGULATOR_AUTORESUME:
                regulator_pass()
        except Exception as exc:
            log("loop error (scan/resume): %r" % exc)
        try:
            prune()
        except Exception as exc:
            log("loop error (prune): %r" % exc)
        if SAFEGUARD:
            try:
                safeguard_pass()
            except Exception as exc:
                log("loop error (safeguard): %r" % exc)
        time.sleep(next_sleep())


def main(argv):
    if "--daemon" in argv:
        return daemon()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
