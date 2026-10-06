#!/usr/bin/env python3
import datetime
import fcntl
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
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None
    return data


LOCAL_TIER_SERVER = "hermes-local"
CLAUDE_JSON_READ_CAP_BYTES = 8 * 1024 * 1024


def _claude_json_path():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if cfg:
        return os.path.join(os.path.expanduser(cfg), ".claude.json")
    return os.path.expanduser("~/.claude.json")


def _read_claude_json():
    path = _claude_json_path()
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("not a regular file")
        chunks = []
        total = 0
        while total < CLAUDE_JSON_READ_CAP_BYTES:
            chunk = os.read(fd, min(65536, CLAUDE_JSON_READ_CAP_BYTES - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    finally:
        os.close(fd)
    if total >= CLAUDE_JSON_READ_CAP_BYTES:
        raise ValueError("oversize")
    return json.loads(b"".join(chunks).decode("utf-8"))


def _project_keys(cwd):
    base = cwd if isinstance(cwd, str) and cwd else os.getcwd()
    keys = []
    for form in (os.path.abspath(base), os.path.realpath(base)):
        if form not in keys:
            keys.append(form)
    return keys


def local_tier_present(cwd=None):
    try:
        data = _read_claude_json()
        if data is None:
            return False
        if not isinstance(data, dict):
            return True
        keys = _project_keys(cwd)
        present = False
        top = data.get("mcpServers")
        if isinstance(top, dict) and LOCAL_TIER_SERVER in top:
            present = True
        projects = data.get("projects")
        if not isinstance(projects, dict):
            projects = {}
        for key in keys:
            entry = projects.get(key)
            if not isinstance(entry, dict):
                continue
            disabled = entry.get("disabledMcpServers")
            if isinstance(disabled, list) and LOCAL_TIER_SERVER in disabled:
                return False
            servers = entry.get("mcpServers")
            if isinstance(servers, dict) and LOCAL_TIER_SERVER in servers:
                present = True
        return present
    except Exception:
        return True


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
DRIVER_RESERVE_RATE = {"five_hour": 8.0, "seven_day": 1.0}
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


def roll_window(used, resets_at, now, window_seconds):
    if resets_at is not None and now >= resets_at and window_seconds > 0:
        periods = math.floor((now - resets_at) / window_seconds) + 1
        return 0.0, resets_at + periods * window_seconds
    return used, resets_at


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


def _window_metrics(entry, window_key, now, default_captured=None):
    if not isinstance(entry, dict):
        return None
    captured = _num(entry.get("captured_at"))
    if captured is None:
        captured = default_captured
    used = _num(entry.get("used_percentage"))
    resets = parse_resets_at(entry.get("resets_at"))
    if resets is not None:
        window_seconds = WINDOW_SECONDS[window_key]
        used, resets = roll_window(used, resets, now, window_seconds)
        resets = min(resets, now + window_seconds)
    frac = elapsed_fraction(resets, WINDOW_SECONDS[window_key], now)
    return {
        "used_percentage": used,
        "resets_at": resets,
        "elapsed_fraction": frac,
        "pace": pace(used, frac),
        "captured_at": captured,
        "age_seconds": (now - captured) if captured is not None else None,
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
        "five_hour": _window_metrics(raw.get("five_hour"), "five_hour", now, captured_at),
        "seven_day": _window_metrics(raw.get("seven_day"), "seven_day", now, captured_at),
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


CLAUDE_WINDOWS = ("five_hour", "seven_day")
CLAUDE_SNAPSHOT_NAME = "claude.json"
CLAUDE_SNAPSHOT_LOCK_NAME = "claude.json.lock"
SNAPSHOT_LOCK_WAIT_SECONDS = 0.4
SNAPSHOT_LOCK_POLL_SECONDS = 0.02
SAME_WINDOW_TOLERANCE_SECONDS = 60
RESETS_PLAUSIBLE_SLACK_SECONDS = 60


def resets_plausible(resets_at, now, window_key):
    if resets_at is None:
        return True
    return resets_at <= now + WINDOW_SECONDS[window_key] + RESETS_PLAUSIBLE_SLACK_SECONDS


def clean_window(entry, window_key, now, default_captured=None):
    if not isinstance(entry, dict):
        return None
    used = _num(entry.get("used_percentage"))
    if used is None:
        return None
    resets = parse_resets_at(entry.get("resets_at"))
    if resets is not None and not math.isfinite(resets):
        resets = None
    if not resets_plausible(resets, now, window_key):
        return None
    captured = _num(entry.get("captured_at"))
    if captured is None:
        captured = default_captured
    return {"used_percentage": used, "resets_at": resets, "captured_at": captured}


def combine_window(candidate, existing):
    if candidate is None:
        return existing
    if existing is None:
        return candidate
    c_resets = candidate.get("resets_at")
    e_resets = existing.get("resets_at")
    if c_resets is None and e_resets is not None:
        return existing
    if c_resets is not None and e_resets is not None:
        if e_resets > c_resets + SAME_WINDOW_TOLERANCE_SECONDS:
            return existing
        if abs(e_resets - c_resets) <= SAME_WINDOW_TOLERANCE_SECONDS:
            if candidate["used_percentage"] < existing["used_percentage"]:
                return existing
    return candidate


def read_claude_windows(now, raw=None):
    if raw is None:
        raw = safe_read_json(os.path.join(usage_dir(), CLAUDE_SNAPSHOT_NAME))
    out = {wk: None for wk in CLAUDE_WINDOWS}
    if not isinstance(raw, dict):
        return out
    top = _num(raw.get("captured_at"))
    for wk in CLAUDE_WINDOWS:
        w = clean_window(raw.get(wk), wk, now, top)
        if w is None or w["captured_at"] is None:
            continue
        if w["captured_at"] > now + CAPTURED_AT_FUTURE_TOLERANCE_SECONDS:
            continue
        out[wk] = w
    return out


def claude_snapshot_needs_refresh(now, interval):
    raw = safe_read_json(os.path.join(usage_dir(), CLAUDE_SNAPSHOT_NAME))
    if not isinstance(raw, dict):
        return True
    top = _num(raw.get("captured_at"))
    seen = False
    for wk in CLAUDE_WINDOWS:
        w = clean_window(raw.get(wk), wk, now, top)
        if w is None:
            continue
        cap = w["captured_at"]
        if cap is None:
            return True
        seen = True
        if cap > now + CAPTURED_AT_FUTURE_TOLERANCE_SECONDS or now - cap > interval:
            return True
    return not seen


def _open_snapshot_lock():
    d = usage_dir()
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        safe_chmod_dir(d, 0o700)
        fd = os.open(os.path.join(d, CLAUDE_SNAPSHOT_LOCK_NAME),
                     os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            return None
    except OSError:
        try:
            os.close(fd)
        except OSError:
            pass
        return None
    return fd


def _lock_snapshot():
    fd = _open_snapshot_lock()
    if fd is None:
        return None
    deadline = time.monotonic() + SNAPSHOT_LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.monotonic() >= deadline:
                break
            time.sleep(SNAPSHOT_LOCK_POLL_SECONDS)
    try:
        os.close(fd)
    except OSError:
        pass
    return None


def _unlock_snapshot(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass


def update_claude_snapshot(candidates, now, source):
    fd = _lock_snapshot()
    if fd is None:
        return None, False
    try:
        path = os.path.join(usage_dir(), CLAUDE_SNAPSHOT_NAME)
        existing = read_claude_windows(now)
        chosen = {}
        changed = False
        for wk in CLAUDE_WINDOWS:
            chosen[wk] = combine_window(candidates.get(wk), existing[wk])
            if chosen[wk] != existing[wk]:
                changed = True
        if not changed:
            return chosen, False
        stamps = [w["captured_at"] for w in chosen.values() if w is not None]
        if not stamps:
            return chosen, False
        payload = {"source": source, "captured_at": max(stamps)}
        for wk in CLAUDE_WINDOWS:
            w = chosen[wk]
            payload[wk] = None if w is None else {
                "used_percentage": w["used_percentage"],
                "resets_at": w["resets_at"],
                "captured_at": w["captured_at"],
            }
        atomic_write_json(path, payload)
        return chosen, True
    finally:
        _unlock_snapshot(fd)


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


def _driver_reserve(family, q, time_hours=None, window_key=None):
    if family != "claude":
        return 0.0
    reserve0 = max(DRIVER_RESERVE_FLOOR, DRIVER_RESERVE_FRACTION * q)
    if time_hours is None or window_key is None:
        return reserve0
    return min(reserve0, DRIVER_RESERVE_RATE[window_key] * max(0.0, time_hours))


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

    used_windows = {}
    for wk in ("five_hour", "seven_day"):
        w = sm.get(wk)
        if not w:
            continue
        used = w.get("used_percentage")
        resets_at = w.get("resets_at")
        if used is None or resets_at is None:
            continue
        w_captured = w.get("captured_at")
        w_age = w.get("age_seconds")
        if w_captured is None or w_age is None:
            continue
        if w_captured > now + CAPTURED_AT_FUTURE_TOLERANCE_SECONDS or _window_stale(wk, w_age):
            continue
        used_windows[wk] = (used, resets_at)

    if not used_windows:
        return _unknown_result(five_used, seven_used)

    vals = []
    for wk, (used, resets_at) in used_windows.items():
        q = max(0.0, 100.0 - used)
        time_to_reset = max(resets_at - now, 0.0)
        reserve = _driver_reserve(family, q, time_to_reset / 3600.0, wk)
        cost = _cost_prior(family, wk)
        if wk == "five_hour":
            h_hours = max((resets_at - now) / 3600.0, 0.0)
        else:
            h_hours = active_hours_between(now, resets_at)
        h_eff = max(h_hours, H_FLOOR_HOURS)
        raw = (q - reserve) / (cost * h_eff)
        capped = min(CONCURRENCY_CAP_P, raw)
        vals.append((capped, resets_at))

    b, resets_at = min(vals, key=lambda item: item[0])
    b = max(0.0, b)
    n = apply_hysteresis(family, b, now)
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
