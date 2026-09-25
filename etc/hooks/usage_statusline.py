#!/usr/bin/env python3
import datetime
import fcntl
import json
import os
import re
import shutil
import statistics
import stat
import subprocess
import sys
import tempfile
import threading
import time

SEVEN_DAY_SECONDS = 7 * 24 * 3600
HERMES_PROBE_MIN_INTERVAL = 30
HERMES_PROBE_TIMEOUT = 1.0
HERMES_PROBE_JOIN_DEADLINE = 1.5
HERMES_PROBE_READ_CAP = 65536
SAMPLE_MIN_INTERVAL = 300
SAMPLES_MAX_LINES = 2000
SAMPLES_READ_CAP_BYTES = SAMPLES_MAX_LINES * 256

CODEX_STALE_AFTER_SECONDS = 60 * 60
CODEX_REFRESH_AFTER_SECONDS = 10 * 60
CODEX_REFRESH_SPAWN_COOLDOWN_SEC = 30

HERMES_RUN_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$")
HERMES_RUN_SCAN_CAP = 30
HERMES_HISTORY_MAX = 5
HERMES_DEFAULT_LOCK_DIR = "/tmp/cbox-hermes-delegate-locks"
HERMES_MAX_CONCURRENCY_CAP = 16


def _usage_dir():
    d = os.environ.get("CBOX_USAGE_DIR")
    if d:
        return os.path.expanduser(d)
    return os.path.expanduser("~/.claude/cbox-usage")


def _cbox_budget_mod():
    hooks_dir = os.path.dirname(os.path.abspath(__file__))
    if hooks_dir not in sys.path:
        sys.path.insert(0, hooks_dir)
    import cbox_budget
    return cbox_budget


def _read_json_file(path):
    raw = _cbox_budget_mod().safe_read_bytes(path)
    if raw is None:
        return None
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _read_text_capped(path, cap=None):
    if cap is None:
        cap = 65536
    raw = _cbox_budget_mod().safe_read_bytes(path, cap)
    if raw is None:
        return None
    return raw.decode("utf-8", "replace")


def _read_stdin_json():
    raw = sys.stdin.read(65536)
    data = json.loads(raw)
    if not isinstance(data, dict):
        return {}
    return data


def _num(val):
    if isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        return float(val)
    return None


def _parse_resets_at(val):
    epoch = _num(val)
    if epoch is not None:
        return epoch
    if isinstance(val, str) and val:
        text = val.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            dt = datetime.datetime.fromisoformat(text)
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    return None


def _window_entry(entry):
    if not isinstance(entry, dict):
        return None
    return {
        "used_percentage": _num(entry.get("used_percentage")),
        "resets_at": _parse_resets_at(entry.get("resets_at")),
    }


def _safe_chmod_dir(d, mode):
    try:
        st = os.lstat(d)
    except OSError:
        return
    if stat.S_ISLNK(st.st_mode):
        return
    if st.st_uid != os.geteuid():
        return
    try:
        os.chmod(d, mode)
    except OSError:
        pass


def _atomic_write(path, payload):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    _safe_chmod_dir(d, 0o700)
    fd = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=".usage.tmp.", dir=d)
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "w") as f:
            fd = None
            f.write(json.dumps(payload))
        os.replace(tmp, path)
        tmp = None
    except Exception:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _fmt_pct(val):
    return ("%d" % round(val)) if val is not None else None


def _pct_str(val):
    s = _fmt_pct(val)
    return (s + "%") if s is not None else None


FIVE_HOUR_COUNTDOWN_THRESHOLD_SECONDS = 60 * 60
SEVEN_DAY_COUNTDOWN_THRESHOLD_SECONDS = 2 * 24 * 3600


def _reset_countdown(resets_at, now, window_key):
    if resets_at is None:
        return ""
    diff = resets_at - now
    if diff < 0:
        diff = 0.0
    if window_key == "five_hour":
        if diff >= FIVE_HOUR_COUNTDOWN_THRESHOLD_SECONDS:
            return ""
        return "(%dm)" % int(diff // 60)
    if diff >= SEVEN_DAY_COUNTDOWN_THRESHOLD_SECONDS:
        return ""
    return "(%dh)" % int(diff // 3600)


def _remaining(used):
    if used is None:
        return None
    used = max(0.0, min(100.0, used))
    return max(0.0, 100.0 - used)


def _force_reached_zero(five_r, seven_r):
    if five_r is None and seven_r is None:
        return five_r, seven_r
    if five_r is None:
        return five_r, 0.0
    if seven_r is None:
        return 0.0, seven_r
    if five_r <= seven_r:
        return 0.0, seven_r
    return five_r, 0.0


def _hermes_base_url():
    for name in ("CBOX_HERMES_DELEGATE_BASE_URL", "CBOX_HERMES_MODEL_URL", "CBOX_LOCAL_MODEL_URL"):
        val = os.environ.get(name)
        if not val:
            continue
        base = val.strip()
        if not base:
            continue
        if base.endswith("/v1"):
            base = base[:-3]
        return base.rstrip("/")
    return ""


def _probe_hermes_blocking(base, timeout, result):
    import urllib.request
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(base + "/api/ps", timeout=timeout) as resp:
            raw = resp.read(HERMES_PROBE_READ_CAP)
    except Exception:
        return
    result["reachable"] = True
    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception:
        return
    model_loaded = False
    if isinstance(payload, dict):
        models = payload.get("models")
        if isinstance(models, list) and len(models) > 0:
            model_loaded = True
    elif isinstance(payload, list):
        model_loaded = len(payload) > 0
    result["model_loaded"] = model_loaded


def _probe_hermes(base, timeout=HERMES_PROBE_TIMEOUT, join_deadline=HERMES_PROBE_JOIN_DEADLINE):
    result = {"reachable": False, "model_loaded": False}
    t = threading.Thread(target=_probe_hermes_blocking, args=(base, timeout, result), daemon=True)
    t.start()
    t.join(join_deadline)
    if t.is_alive():
        return False, False
    return result["reachable"], result["model_loaded"]


def _update_hermes_cache(now):
    path = os.path.join(_usage_dir(), "hermes.json")
    data = _read_json_file(path)
    existing = data if isinstance(data, dict) else {}
    last_probe_ts = existing.get("last_probe_ts")
    if isinstance(last_probe_ts, (int, float)) and (now - last_probe_ts) < HERMES_PROBE_MIN_INTERVAL:
        return
    base = _hermes_base_url()
    if not base:
        return
    pending = dict(existing)
    pending["last_probe_ts"] = now
    _atomic_write(path, pending)
    reachable, model_loaded = _probe_hermes(base)
    history = existing.get("history")
    if not isinstance(history, list):
        history = []
    history = (history[-1:] + [reachable])[-2:]
    payload = {
        "ts": now,
        "last_probe_ts": now,
        "reachable": reachable,
        "model_loaded": model_loaded,
        "history": history,
    }
    _atomic_write(path, payload)


def _append_sample(family, five_used, seven_used, now):
    path = os.path.join(_usage_dir(), "samples.jsonl")
    text = _read_text_capped(path, SAMPLES_READ_CAP_BYTES)
    lines = text.splitlines(keepends=True) if text is not None else []
    last_ts = None
    if lines:
        try:
            last = json.loads(lines[-1])
            last_ts = last.get("ts")
        except (ValueError, AttributeError):
            last_ts = None
    if isinstance(last_ts, (int, float)) and (now - last_ts) < SAMPLE_MIN_INTERVAL:
        return
    entry = {
        "ts": now,
        "family": family,
        "five_hour": {"used": five_used},
        "seven_day": {"used": seven_used},
    }
    lines.append(json.dumps(entry) + "\n")
    if len(lines) > SAMPLES_MAX_LINES:
        lines = lines[-SAMPLES_MAX_LINES:]
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    _safe_chmod_dir(d, 0o700)
    fd = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=".samples.tmp.", dir=d)
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "w") as f:
            fd = None
            f.writelines(lines)
        os.replace(tmp, path)
        tmp = None
    except Exception:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _agents_value():
    info = _cbox_budget_mod().budget_for_family("claude")
    return info.get("n")


def _read_codex_snapshot():
    path = os.path.join(_usage_dir(), "codex.json")
    data = _read_json_file(path)
    if not isinstance(data, dict):
        return None
    return data


def _codex_remaining(now):
    data = _read_codex_snapshot()
    if data is None:
        return None, None, None, None, False
    captured_at = _num(data.get("captured_at"))
    if captured_at is None:
        return None, None, None, None, False
    age = now - captured_at
    five = data.get("five_hour")
    seven = data.get("seven_day")
    five_used = _num(five.get("used_percentage")) if isinstance(five, dict) else None
    seven_used = _num(seven.get("used_percentage")) if isinstance(seven, dict) else None
    five_resets = _parse_resets_at(five.get("resets_at")) if isinstance(five, dict) else None
    seven_resets = _parse_resets_at(seven.get("resets_at")) if isinstance(seven, dict) else None
    five_r = _remaining(five_used)
    seven_r = _remaining(seven_used)
    ordinary_usage_allowed = data.get("ordinary_usage_allowed")
    if ordinary_usage_allowed is False:
        five_r, seven_r = _force_reached_zero(five_r, seven_r)
    stale = (five_r is not None or seven_r is not None) and age > CODEX_STALE_AFTER_SECONDS
    return five_r, seven_r, five_resets, seven_resets, stale


def _codex_refresh_needed(now):
    data = _read_codex_snapshot()
    if data is None:
        return True
    captured_at = _num(data.get("captured_at"))
    if captured_at is None:
        return True
    return (now - captured_at) > CODEX_REFRESH_AFTER_SECONDS


def _codex_refresh_spawn_allowed(now):
    path = os.path.join(_usage_dir(), "codex_refresh_attempt.json")
    data = _read_json_file(path)
    last = data.get("ts") if isinstance(data, dict) else None
    if isinstance(last, (int, float)) and (now - last) < CODEX_REFRESH_SPAWN_COOLDOWN_SEC:
        return False
    _atomic_write(path, {"ts": now})
    return True


def _codex_refresh_disabled():
    return os.environ.get("CBOX_CODEX_USAGE_REFRESH", "").strip().lower() == "off"


def _maybe_spawn_codex_refresh(now):
    if _codex_refresh_disabled():
        return
    if not _codex_refresh_needed(now):
        return
    if not _codex_refresh_spawn_allowed(now):
        return
    if shutil.which("codex") is None:
        return
    hooks_dir = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(hooks_dir, "codex_usage_refresh.py")
    if not os.path.isfile(script):
        return
    try:
        subprocess.Popen(
            [sys.executable, script],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception:
        pass


def _hermes_lock_dir():
    return os.environ.get("CBOX_HERMES_DELEGATE_LOCK_DIR") or HERMES_DEFAULT_LOCK_DIR


def _hermes_runs_dir():
    d = os.environ.get("CBOX_HERMES_DELEGATE_RUNS_DIR", "").strip()
    if d:
        return d
    return os.path.join(os.path.expanduser("~"), ".cache", "cbox", "hermes-delegate", "runs")


def _hermes_concurrency_limit():
    def _pos_int(name):
        raw = os.environ.get(name, "")
        try:
            v = int(raw.strip())
        except (TypeError, ValueError):
            return 0
        return v
    limit = _pos_int("CBOX_HERMES_DELEGATE_MAX_CONCURRENCY")
    if limit <= 0:
        limit = _pos_int("OLLAMA_NUM_PARALLEL")
    if limit <= 0:
        limit = 1
    return min(limit, HERMES_MAX_CONCURRENCY_CAP)


def _hermes_any_slot_busy():
    d = _hermes_lock_dir()
    busy = False
    for i in range(_hermes_concurrency_limit()):
        path = os.path.join(d, "slot.%d" % i)
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            continue
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                busy = True
        finally:
            os.close(fd)
    return busy


def _parse_run_id_epoch(run_id):
    ts = run_id.split("-", 1)[0]
    try:
        dt = datetime.datetime.strptime(ts, "%Y%m%dT%H%M%SZ")
    except ValueError:
        return None
    return dt.replace(tzinfo=datetime.timezone.utc).timestamp()


def _parse_wall_ts(text):
    if not isinstance(text, str):
        return None
    try:
        dt = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None
    return dt.replace(tzinfo=datetime.timezone.utc).timestamp()


def _hermes_run_scan():
    root = _hermes_runs_dir()
    try:
        names = os.listdir(root)
    except OSError:
        return None, []
    candidates = sorted(
        (n for n in names if HERMES_RUN_ID_RE.match(n)),
        reverse=True,
    )[:HERMES_RUN_SCAN_CAP]
    latest_unfinished = None
    durations = []
    for name in candidates:
        summary_path = os.path.join(root, name, "summary.json")
        data = _read_json_file(summary_path)
        if not isinstance(data, dict):
            if latest_unfinished is None:
                started = _parse_run_id_epoch(name)
                if started is not None:
                    latest_unfinished = (name, started)
            continue
        if len(durations) < HERMES_HISTORY_MAX and data.get("outcome") == "ok":
            s = _parse_wall_ts(data.get("started"))
            e = _parse_wall_ts(data.get("ended"))
            if s is not None and e is not None and e >= s:
                durations.append(e - s)
    return latest_unfinished, durations


def _hermes_segment(now):
    if not _hermes_any_slot_busy():
        return "hermes: idle"
    latest_unfinished, durations = _hermes_run_scan()
    if latest_unfinished is None:
        return "hermes: 0min"
    _, started = latest_unfinished
    elapsed = max(0.0, now - started)
    if durations:
        median = statistics.median(durations)
        remaining = max(0.0, median - elapsed)
        minutes = int(round(remaining / 60.0))
        return "hermes: ~%dmin" % minutes
    minutes = int(round(elapsed / 60.0))
    return "hermes: %dmin" % minutes


def _dual_segment(label, five_s, seven_s, drop_seven):
    if five_s is None and seven_s is None:
        return None
    if five_s is not None and seven_s is not None and not drop_seven:
        core = "%s/%s" % (five_s, seven_s)
    elif five_s is not None:
        core = five_s
    else:
        if seven_s is None or drop_seven:
            return None
        core = "-/" + seven_s
    return "%s: %s" % (label, core)


def _terminal_width(data):
    for key in ("columns", "terminal_width", "term_width"):
        val = data.get(key) if isinstance(data, dict) else None
        n = _num(val)
        if n is not None and n > 0:
            return int(n)
    raw = os.environ.get("COLUMNS")
    if raw:
        try:
            n = int(raw.strip())
        except ValueError:
            n = None
        if n is not None and n > 0:
            return n
    return None


def _run(data, now):
    rl = data.get("rate_limits")
    five = rl.get("five_hour") if isinstance(rl, dict) else None
    seven = rl.get("seven_day") if isinstance(rl, dict) else None

    if isinstance(rl, dict):
        snapshot = {
            "source": "claude",
            "captured_at": now,
            "five_hour": _window_entry(five),
            "seven_day": _window_entry(seven),
        }
        _atomic_write(os.path.join(_usage_dir(), "claude.json"), snapshot)
        try:
            _append_sample(
                "claude",
                _num(five.get("used_percentage")) if isinstance(five, dict) else None,
                _num(seven.get("used_percentage")) if isinstance(seven, dict) else None,
                now,
            )
        except Exception:
            pass

    try:
        _update_hermes_cache(now)
    except Exception:
        pass

    try:
        _maybe_spawn_codex_refresh(now)
    except Exception:
        pass

    profile = os.environ.get("CBOX_PROFILE", "").strip()
    prefix = "[%s] " % profile if profile else ""

    claude_five_used = _num(five.get("used_percentage")) if isinstance(five, dict) else None
    claude_seven_used = _num(seven.get("used_percentage")) if isinstance(seven, dict) else None
    claude_five_resets = _parse_resets_at(five.get("resets_at")) if isinstance(five, dict) else None
    claude_seven_resets = _parse_resets_at(seven.get("resets_at")) if isinstance(seven, dict) else None
    claude_five_pct = _pct_str(_remaining(claude_five_used))
    claude_seven_pct = _pct_str(_remaining(claude_seven_used))
    claude_five_cd = _reset_countdown(claude_five_resets, now, "five_hour")
    claude_seven_cd = _reset_countdown(claude_seven_resets, now, "seven_day")

    try:
        codex_five_r, codex_seven_r, codex_five_resets, codex_seven_resets, codex_stale = _codex_remaining(now)
    except Exception:
        codex_five_r, codex_seven_r, codex_five_resets, codex_seven_resets, codex_stale = None, None, None, None, False
    codex_five_pct = _pct_str(codex_five_r)
    codex_seven_pct = _pct_str(codex_seven_r)
    codex_five_cd = _reset_countdown(codex_five_resets, now, "five_hour")
    codex_seven_cd = _reset_countdown(codex_seven_resets, now, "seven_day")

    try:
        hermes_text = _hermes_segment(now)
    except Exception:
        hermes_text = None

    try:
        agents_val = _agents_value()
    except Exception:
        agents_val = None
    agents_text = ("agents: %d" % agents_val) if agents_val is not None else None

    width = _terminal_width(data)

    def seg_value(pct, countdown, drop_countdown):
        if pct is None:
            return None
        if drop_countdown or not countdown:
            return pct
        return pct + countdown

    def render(drop_countdown, drop_agents, drop_hermes, drop_seven):
        parts = []
        claude_five_s = seg_value(claude_five_pct, claude_five_cd, drop_countdown)
        claude_seven_s = seg_value(claude_seven_pct, claude_seven_cd, drop_countdown)
        claude_seg = _dual_segment("claude", claude_five_s, claude_seven_s, drop_seven)
        if claude_seg:
            parts.append(claude_seg)
        codex_five_s = seg_value(codex_five_pct, codex_five_cd, drop_countdown)
        codex_seven_s = seg_value(codex_seven_pct, codex_seven_cd, drop_countdown)
        codex_seg = _dual_segment("codex", codex_five_s, codex_seven_s, drop_seven)
        if codex_seg:
            parts.append(codex_seg)
        if not drop_hermes and hermes_text:
            parts.append(hermes_text)
        if not drop_agents and agents_text:
            parts.append(agents_text)
        return prefix + " | ".join(parts)

    line = render(False, False, False, False)
    if width is not None and len(line) > width:
        line = render(True, False, False, False)
    if width is not None and len(line) > width:
        line = render(True, True, False, False)
    if width is not None and len(line) > width:
        line = render(True, True, True, False)
    if width is not None and len(line) > width:
        line = render(True, True, True, True)
    return line


def main():
    try:
        try:
            data = _read_stdin_json()
        except Exception:
            data = {}
        if not isinstance(data, dict):
            data = {}
        line = _run(data, time.time())
        print(line)
    except Exception:
        pass


if __name__ == "__main__":
    main()
