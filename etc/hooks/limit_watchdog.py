#!/usr/bin/env python3
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import session_scope_farm as farm

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
DELAY = int_env("CBOX_LIMIT_RESUME_DELAY", 300)
PROMPT = os.environ.get("CBOX_LIMIT_RESUME_PROMPT", "pokracuj") or "pokracuj"
STAGGER = int_env("CBOX_LIMIT_RESUME_STAGGER", 30)
MAX_PER_DAY = int_env("CBOX_LIMIT_RESUME_MAX_PER_DAY", 10)
HOSTNAME = socket.gethostname()
PANE_RE = re.compile(r"^%\d+$")
POLL = 15
FRESH_WINDOW = 48 * 3600
MARKER_TTL = 8 * 24 * 3600
EPOCH_RE = re.compile(r"limit reached\|(\d{10,13})")
RESETS_RE = re.compile(rb'"resets?At"\s*:\s*"?(\d{10,13})')
PREFILTER = (b"usage limit", b"usage credit")


def log(msg):
    try:
        os.makedirs(WATCH, exist_ok=True)
        with open(os.path.join(WATCH, "watchdog.log"), "a") as fh:
            fh.write("%s [%s] %s\n" % (
                time.strftime("%Y-%m-%d %H:%M:%S"), HOSTNAME, msg))
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


def marker_path(sid, reset_at):
    return os.path.join(MARKERS, "%s.%d.json" % (sid, reset_at or 0))


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


def inject(pane):
    subprocess.run(["tmux", "send-keys", "-t", pane, "-l", PROMPT],
                   check=True, timeout=10)
    try:
        subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"],
                       check=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        return repr(exc)
    return None


def marker_owns_transcript(marker, sid):
    transcript = marker.get("transcript") or ""
    if os.path.basename(transcript) != sid + ".jsonl":
        return False
    return transcript.startswith(os.path.join(CFG, "projects") + os.sep)


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


def prune():
    cutoff = time.time() - MARKER_TTL
    for name in farm.entries(MARKERS):
        path = os.path.join(MARKERS, name)
        rec = load_json(path)
        if rec is None or rec.get("detectedAt", 0) < cutoff:
            try:
                os.unlink(path)
            except OSError:
                pass


def daemon():
    if not farm.env_ok():
        return 0
    lock = farm.try_lock("daemon.lock")
    if lock is None:
        return 0
    os.makedirs(MARKERS, exist_ok=True)
    os.makedirs(PANES, exist_ok=True)
    log("watchdog started (autoresume=%s delay=%ss stagger=%ss cap=%s/day)" % (
        "on" if AUTORESUME else "off", DELAY, STAGGER, MAX_PER_DAY))
    offsets = {}
    while True:
        try:
            farm.refresh_all()
            scan_transcripts(offsets)
            if AUTORESUME:
                resume_pass()
            prune()
        except Exception as exc:
            log("loop error: %r" % exc)
        time.sleep(POLL)


def main(argv):
    if "--daemon" in argv:
        return daemon()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
