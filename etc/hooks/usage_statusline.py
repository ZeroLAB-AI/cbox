#!/usr/bin/env python3
import datetime
import json
import os
import stat
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


def _usage_dir():
    d = os.environ.get("CBOX_USAGE_DIR")
    if d:
        return os.path.expanduser(d)
    return os.path.expanduser("~/.claude/cbox-usage")


def _read_stdin_json():
    raw = sys.stdin.read()
    data = json.loads(raw)
    if not isinstance(data, dict):
        return {}
    return data


def _model_name(data):
    model = data.get("model")
    if isinstance(model, dict):
        for key in ("display_name", "id", "name"):
            val = model.get(key)
            if isinstance(val, str) and val:
                return val
        return ""
    if isinstance(model, str):
        return model
    return ""


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


def _seven_day_pace(entry, now):
    if not isinstance(entry, dict):
        return None
    used = _num(entry.get("used_percentage"))
    resets = _parse_resets_at(entry.get("resets_at"))
    if used is None or resets is None:
        return None
    window_start = resets - SEVEN_DAY_SECONDS
    frac = (now - window_start) / SEVEN_DAY_SECONDS
    if frac < 0.05:
        frac = 0.05
    return used / (100.0 * frac)


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


def _fmt_pace(val):
    return "%.1f" % val


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
    existing = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            existing = json.load(f)
        if not isinstance(existing, dict):
            existing = {}
    except (OSError, ValueError):
        existing = {}
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
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        lines = []
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


def _budget_status_text():
    hooks_dir = os.path.dirname(os.path.abspath(__file__))
    if hooks_dir not in sys.path:
        sys.path.insert(0, hooks_dir)
    import cbox_budget
    info = cbox_budget.budget_for_family("claude")
    hermes = cbox_budget.hermes_state()
    b = info.get("b")
    n = info.get("n")
    if b is None:
        b_text = "B claude ? (N ?)"
    else:
        b_text = "B claude %.1f (N %s)" % (b, n if n is not None else "?")
    state = hermes.get("state")
    if state == "available":
        h_text = "hermes up"
    elif state == "unavailable":
        h_text = "hermes down"
    else:
        h_text = "hermes ?"
    return "%s | %s" % (b_text, h_text)


def main():
    model_name = ""
    try:
        data = _read_stdin_json()
        model_name = _model_name(data)
        rl = data.get("rate_limits")
        five = rl.get("five_hour") if isinstance(rl, dict) else None
        seven = rl.get("seven_day") if isinstance(rl, dict) else None

        if isinstance(rl, dict):
            snapshot = {
                "source": "claude",
                "captured_at": time.time(),
                "five_hour": _window_entry(five),
                "seven_day": _window_entry(seven),
            }
            _atomic_write(os.path.join(_usage_dir(), "claude.json"), snapshot)
            try:
                _append_sample(
                    "claude",
                    _num(five.get("used_percentage")) if isinstance(five, dict) else None,
                    _num(seven.get("used_percentage")) if isinstance(seven, dict) else None,
                    time.time(),
                )
            except Exception:
                pass

        try:
            _update_hermes_cache(time.time())
        except Exception:
            pass

        parts = []
        if model_name:
            parts.append(model_name)
        five_pct = _num(five.get("used_percentage")) if isinstance(five, dict) else None
        if five_pct is not None:
            parts.append("5h %s%%" % _fmt_pct(five_pct))
        seven_pct = _num(seven.get("used_percentage")) if isinstance(seven, dict) else None
        if seven_pct is not None:
            seg = "7d %s%%" % _fmt_pct(seven_pct)
            pace = _seven_day_pace(seven, time.time())
            if pace is not None:
                seg += " pace %s" % _fmt_pace(pace)
            parts.append(seg)
        if five_pct is not None or seven_pct is not None:
            try:
                budget_text = _budget_status_text()
            except Exception:
                budget_text = None
            if budget_text:
                parts.append(budget_text)
        print(" | ".join(parts))
    except Exception:
        if model_name:
            print(model_name)


if __name__ == "__main__":
    main()
