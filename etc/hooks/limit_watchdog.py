#!/usr/bin/env python3
import calendar
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
FRESH_WINDOW = 48 * 3600
MARKER_TTL = 8 * 24 * 3600
EPOCH_RE = re.compile(r"limit reached\|(\d{10,13})")
RESETS_RE = re.compile(rb'"resets?At"\s*:\s*"?(\d{10,13})')
PREFILTER = (b"usage limit", b"usage credit")
STALE_GRACE = 300
STALE_STATES = ("working", "running", "blocked")


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
    typed = False
    try:
        subprocess.run(["tmux", "send-keys", "-t", pane, "-l", PROMPT],
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
    log("watchdog started (autoresume=%s safeguard=%s delay=%ss stagger=%ss cap=%s/day)" % (
        "on" if AUTORESUME else "off", "on" if SAFEGUARD else "off",
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
            prune()
        except Exception as exc:
            log("loop error (scan/resume/prune): %r" % exc)
        if SAFEGUARD:
            try:
                safeguard_pass()
            except Exception as exc:
                log("loop error (safeguard): %r" % exc)
        time.sleep(POLL)


def main(argv):
    if "--daemon" in argv:
        return daemon()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
