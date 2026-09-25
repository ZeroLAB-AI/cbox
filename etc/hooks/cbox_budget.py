#!/usr/bin/env python3
import datetime
import json
import math
import os
import stat
import sys
import tempfile
import time

READ_CAP_BYTES = 65536


def safe_read_bytes(path, cap=READ_CAP_BYTES):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
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


def safe_read_json(path):
    raw = safe_read_bytes(path)
    if raw is None:
        return None
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return data


SOURCES = ("claude", "codex")
WINDOW_SECONDS = {
    "five_hour": 5 * 3600,
    "seven_day": 7 * 24 * 3600,
}
STALE_AFTER_SECONDS = 2 * 3600
FIVE_HOUR_STALE_SECONDS = 15 * 60
MIN_ELAPSED_FRACTION = 0.05

ACTIVE_HOURS_PROFILE = [2.88, 1.88, 2.63, 5.50, 5.69, 0.75, 4.25]
ACTIVE_WINDOW_START_HOUR = 6
ACTIVE_WINDOW_END_HOUR = 22
ACTIVE_WINDOW_HOURS = ACTIVE_WINDOW_END_HOUR - ACTIVE_WINDOW_START_HOUR

COST_PRIORS = {
    "claude": {"seven_day": 1.5, "five_hour": 6.0},
    "codex": {"seven_day": 14.0, "five_hour": 115.0},
}

DRIVER_RESERVE_FLOOR = 8.0
DRIVER_RESERVE_FRACTION = 0.35
CONCURRENCY_CAP_P = 3.0
H_FLOOR_HOURS = 0.25
TAPER_FRACTION = 0.10
HYSTERESIS_MARGIN = 0.2
HERMES_UNKNOWN_AFTER_SECONDS = 120

STATE_FILENAME = "state.json"


def usage_dir():
    d = os.environ.get("CBOX_USAGE_DIR")
    if d:
        return os.path.expanduser(d)
    return os.path.expanduser("~/.claude/cbox-usage")


def _num(val):
    if isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        f = float(val)
        return f if math.isfinite(f) else None
    return None


CAPTURED_AT_FUTURE_TOLERANCE_SECONDS = 60
OVERRIDE_MAX_UNTIL_SECONDS = 24 * 3600


def parse_resets_at(val):
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


def elapsed_fraction(resets_epoch, window_seconds, now):
    if resets_epoch is None or not window_seconds:
        return None
    window_start = resets_epoch - window_seconds
    frac = (now - window_start) / window_seconds
    if frac < MIN_ELAPSED_FRACTION:
        frac = MIN_ELAPSED_FRACTION
    return frac


def pace(used_percentage, frac):
    if used_percentage is None or frac is None or frac <= 0:
        return None
    return used_percentage / (100.0 * frac)


def _load_source_file(name):
    path = os.path.join(usage_dir(), "%s.json" % name)
    data = safe_read_json(path)
    if not isinstance(data, dict):
        return None
    return data


def _window_metrics(entry, window_key, now):
    if not isinstance(entry, dict):
        return None
    used = _num(entry.get("used_percentage"))
    resets = parse_resets_at(entry.get("resets_at"))
    if resets is not None:
        window_seconds = WINDOW_SECONDS[window_key]
        resets = max(now, min(resets, now + window_seconds))
    frac = elapsed_fraction(resets, WINDOW_SECONDS[window_key], now)
    return {
        "used_percentage": used,
        "resets_at": resets,
        "elapsed_fraction": frac,
        "pace": pace(used, frac),
    }


def source_metrics(name, now=None):
    now = time.time() if now is None else now
    raw = _load_source_file(name)
    if raw is None:
        return None
    captured_at = _num(raw.get("captured_at"))
    if captured_at is None:
        return None
    age = now - captured_at
    future_stale = captured_at > now + CAPTURED_AT_FUTURE_TOLERANCE_SECONDS
    return {
        "captured_at": captured_at,
        "age_seconds": age,
        "stale": future_stale or age > STALE_AFTER_SECONDS,
        "five_hour": _window_metrics(raw.get("five_hour"), "five_hour", now),
        "seven_day": _window_metrics(raw.get("seven_day"), "seven_day", now),
    }


def metrics(now=None):
    now = time.time() if now is None else now
    out = {}
    for name in SOURCES:
        m = source_metrics(name, now)
        if m is not None:
            out[name] = m
    return out


def safe_chmod_dir(d, mode):
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


def atomic_write_json(path, payload):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    safe_chmod_dir(d, 0o700)
    fd = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=".budget.tmp.", dir=d)
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


def _day_active_hours(date_obj):
    return ACTIVE_HOURS_PROFILE[date_obj.weekday()]


def _day_window_epoch(date_obj):
    start = datetime.datetime(date_obj.year, date_obj.month, date_obj.day,
                               ACTIVE_WINDOW_START_HOUR, 0, 0,
                               tzinfo=datetime.timezone.utc)
    end = datetime.datetime(date_obj.year, date_obj.month, date_obj.day,
                             ACTIVE_WINDOW_END_HOUR, 0, 0,
                             tzinfo=datetime.timezone.utc)
    return start.timestamp(), end.timestamp()


ACTIVE_HOURS_MAX_RANGE_SECONDS = 8 * 24 * 3600


def active_hours_between(start_epoch, end_epoch):
    if start_epoch is None or end_epoch is None or end_epoch <= start_epoch:
        return 0.0
    if end_epoch - start_epoch > ACTIVE_HOURS_MAX_RANGE_SECONDS:
        end_epoch = start_epoch + ACTIVE_HOURS_MAX_RANGE_SECONDS
    start_date = datetime.datetime.fromtimestamp(start_epoch, tz=datetime.timezone.utc).date()
    end_date = datetime.datetime.fromtimestamp(end_epoch, tz=datetime.timezone.utc).date()
    total = 0.0
    d = start_date
    one_day = datetime.timedelta(days=1)
    while d <= end_date:
        w0, w1 = _day_window_epoch(d)
        lo = max(w0, start_epoch)
        hi = min(w1, end_epoch)
        if hi > lo:
            rate_per_sec = _day_active_hours(d) / (ACTIVE_WINDOW_HOURS * 3600.0)
            total += (hi - lo) * rate_per_sec
        d += one_day
    return total


def _driver_reserve(family, q):
    if family != "claude":
        return 0.0
    return max(DRIVER_RESERVE_FLOOR, DRIVER_RESERVE_FRACTION * q)


def _cost_prior(family, window_key):
    env_name = "CBOX_BUDGET_COST_%s_%s" % (family.upper(), window_key.upper())
    raw = os.environ.get(env_name)
    if raw:
        try:
            val = float(raw)
        except ValueError:
            val = None
        if val is not None and math.isfinite(val) and val > 0:
            return val
    fam = COST_PRIORS.get(family)
    if fam and window_key in fam:
        return fam[window_key]
    return 1.0


def _window_stale(window_key, age_seconds):
    if window_key == "five_hour":
        return age_seconds > FIVE_HOUR_STALE_SECONDS
    return age_seconds > STALE_AFTER_SECONDS


def _mode_off():
    return os.environ.get("CBOX_BUDGET_MODE", "").strip().lower() == "off"


def _read_override(now):
    path = os.path.join(usage_dir(), "override.json")
    data = safe_read_json(path)
    if not isinstance(data, dict):
        return None
    until = _num(data.get("until"))
    b = _num(data.get("b"))
    if until is None or b is None or now >= until:
        return None
    if until > now + OVERRIDE_MAX_UNTIL_SECONDS:
        return None
    return max(0.0, min(3.0, b)), until


def _state_path():
    return os.path.join(usage_dir(), STATE_FILENAME)


def _load_state():
    data = safe_read_json(_state_path())
    return data if isinstance(data, dict) else {}


def _valid_state_n(v):
    if isinstance(v, bool):
        return False
    return isinstance(v, int) and 0 <= v <= 3


def apply_hysteresis(family, b_value, now=None):
    now = time.time() if now is None else now
    state = _load_state()
    entry = state.get(family) if isinstance(state.get(family), dict) else None
    prev_n = entry.get("n") if entry else None
    if not _valid_state_n(prev_n):
        prev_n = None
    if b_value is None:
        return prev_n
    if prev_n is None:
        n = max(0, math.ceil(b_value))
    else:
        up_threshold = prev_n + HYSTERESIS_MARGIN
        down_threshold = prev_n - 1 - HYSTERESIS_MARGIN
        if b_value >= up_threshold or b_value <= down_threshold:
            n = max(0, math.ceil(b_value))
        else:
            n = prev_n
    state[family] = {"n": n, "b": b_value, "ts": now}
    atomic_write_json(_state_path(), state)
    return n


def _soonest_resets(sm):
    if not sm:
        return None
    candidates = []
    for wk in ("five_hour", "seven_day"):
        w = sm.get(wk)
        if w and w.get("resets_at") is not None:
            candidates.append(w["resets_at"])
    return min(candidates) if candidates else None


def _unknown_result(five_used=None, seven_used=None):
    return {
        "status": "unknown",
        "b": None,
        "n": None,
        "five_hour_used": five_used,
        "seven_day_used": seven_used,
        "resets_at": None,
    }


def budget_for_family(family, now=None):
    now = time.time() if now is None else now
    if _mode_off():
        return {
            "status": "off",
            "b": None,
            "n": None,
            "five_hour_used": None,
            "seven_day_used": None,
            "resets_at": None,
        }
    sm = source_metrics(family, now)
    five_used = None
    seven_used = None
    if sm is not None:
        if sm.get("five_hour"):
            five_used = sm["five_hour"].get("used_percentage")
        if sm.get("seven_day"):
            seven_used = sm["seven_day"].get("used_percentage")

    override = _read_override(now)
    if override is not None:
        override_b, override_until = override
        n = apply_hysteresis(family, override_b, now)
        return {
            "status": "override",
            "b": override_b,
            "n": n,
            "five_hour_used": five_used,
            "seven_day_used": seven_used,
            "resets_at": _soonest_resets(sm),
            "override_until": override_until,
        }

    if sm is None:
        return _unknown_result()

    age = sm["age_seconds"]
    captured_future = sm["captured_at"] > now + CAPTURED_AT_FUTURE_TOLERANCE_SECONDS
    used_windows = {}
    for wk in ("five_hour", "seven_day"):
        w = sm.get(wk)
        if not w:
            continue
        used = w.get("used_percentage")
        resets_at = w.get("resets_at")
        if used is None or resets_at is None:
            continue
        if captured_future or _window_stale(wk, age):
            continue
        used_windows[wk] = (used, resets_at)

    if not used_windows:
        return _unknown_result(five_used, seven_used)

    vals = []
    for wk, (used, resets_at) in used_windows.items():
        q = max(0.0, 100.0 - used)
        reserve = _driver_reserve(family, q)
        cost = _cost_prior(family, wk)
        if wk == "five_hour":
            h_hours = max((resets_at - now) / 3600.0, 0.0)
        else:
            h_hours = active_hours_between(now, resets_at)
        h_eff = max(h_hours, H_FLOOR_HOURS)
        raw = (q - reserve) / (cost * h_eff)
        capped = min(CONCURRENCY_CAP_P, raw)
        window_len = WINDOW_SECONDS[wk]
        time_to_reset = max(resets_at - now, 0.0)
        taper_denominator = TAPER_FRACTION * window_len
        taper = min(1.0, time_to_reset / taper_denominator) if taper_denominator > 0 else 1.0
        vals.append(capped * taper)

    b = max(0.0, min(vals))
    n = apply_hysteresis(family, b, now)
    resets_at = min(r for (_, r) in used_windows.values())
    return {
        "status": "ok",
        "b": b,
        "n": n,
        "five_hour_used": five_used,
        "seven_day_used": seven_used,
        "resets_at": resets_at,
    }


def hermes_state(now=None):
    now = time.time() if now is None else now
    path = os.path.join(usage_dir(), "hermes.json")
    data = safe_read_json(path)
    if not isinstance(data, dict):
        return {"state": "unknown", "reachable": None, "model_loaded": None, "age_seconds": None}
    ts = _num(data.get("last_probe_ts"))
    if ts is None:
        ts = _num(data.get("ts"))
    if ts is None:
        return {"state": "unknown", "reachable": None, "model_loaded": None, "age_seconds": None}
    age = now - ts
    reachable = data.get("reachable")
    model_loaded = data.get("model_loaded")
    if age > HERMES_UNKNOWN_AFTER_SECONDS:
        return {"state": "unknown", "reachable": reachable, "model_loaded": model_loaded, "age_seconds": age}
    history = data.get("history")
    if isinstance(history, list) and history:
        recent = history[-2:]
        available = any(bool(x) for x in recent)
    else:
        available = bool(reachable)
    return {
        "state": "available" if available else "unavailable",
        "reachable": reachable,
        "model_loaded": model_loaded,
        "age_seconds": age,
    }


def _cmd_metrics():
    try:
        payload = metrics()
    except Exception:
        payload = {}
    print(json.dumps(payload))
    return 0


def _cmd_budget(argv):
    now = time.time()
    fam_arg = argv[2] if len(argv) > 2 else None
    fams = [fam_arg] if fam_arg else list(SOURCES)
    out = {}
    for fam in fams:
        try:
            out[fam] = budget_for_family(fam, now)
        except Exception:
            out[fam] = _unknown_result()
    print(json.dumps(out))
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "metrics":
        return _cmd_metrics()
    if len(argv) >= 2 and argv[1] == "budget":
        return _cmd_budget(argv)
    print("usage: cbox_budget.py metrics|budget [family]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
