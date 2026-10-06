#!/usr/bin/env python3
import datetime
import email.utils
import fcntl
import json
import math
import os
import stat
import sys
import threading
import time
import urllib.error
import urllib.request

HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))

ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
BETA_HEADER = "oauth-2025-04-20"
REQUEST_TIMEOUT_SEC = 5
WALL_CAP_SEC = 10
RESPONSE_CAP_BYTES = 65536
CREDENTIALS_CAP_BYTES = 65536
EXPIRY_MARGIN_SEC = 60
DEFAULT_BACKOFF_SEC = 15 * 60
MIN_BACKOFF_SEC = 60
MAX_BACKOFF_SEC = 6 * 3600
LOCK_STALE_SECONDS = 30
FRESH_SKIP_SEC = 30
WINDOWS = ("five_hour", "seven_day")
STOP_STATUSES = (401, 403)
STAMP_FUTURE_TOLERANCE_SEC = 60

_LOCK_HANDLE = [None]


def _budget():
    if HOOKS_DIR not in sys.path:
        sys.path.insert(0, HOOKS_DIR)
    import cbox_budget
    return cbox_budget


def _disabled():
    return os.environ.get("CBOX_CLAUDE_USAGE_REFRESH", "").strip().lower() == "off"


def _num(val):
    if isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        f = float(val)
        return f if math.isfinite(f) else None
    return None


def _credential_paths():
    paths = []
    d = os.environ.get("CLAUDE_SECURESTORAGE_CONFIG_DIR", "").strip()
    if d:
        paths.append(os.path.join(os.path.expanduser(d), ".credentials.json"))
    paths.append(os.path.expanduser("~/.claude/.credentials.json"))
    seen = []
    for p in paths:
        if p not in seen:
            seen.append(p)
    return seen


def _read_credentials():
    budget = _budget()
    for path in _credential_paths():
        raw = budget.safe_read_bytes(path, CREDENTIALS_CAP_BYTES)
        if raw is None:
            continue
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, RecursionError):
            continue
        oauth = data.get("claudeAiOauth") if isinstance(data, dict) else None
        if not isinstance(oauth, dict):
            continue
        token = oauth.get("accessToken")
        expires_ms = _num(oauth.get("expiresAt"))
        if not isinstance(token, str) or not token or expires_ms is None:
            continue
        if not token.isprintable() or any(ch.isspace() for ch in token):
            continue
        return token, expires_ms
    return None


def _attempt_path():
    return os.path.join(_budget().usage_dir(), "claude_refresh_attempt.json")


def _lock_path():
    return os.path.join(_budget().usage_dir(), "claude_refresh.lock")


def _read_stamp():
    data = _budget().safe_read_json(_attempt_path())
    return dict(data) if isinstance(data, dict) else {}


def _write_stamp(stamp):
    _budget().atomic_write_json(_attempt_path(), stamp)


def _acquire_lock():
    path = _lock_path()
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    except OSError:
        return None
    now = time.time()
    try:
        st = os.stat(path)
        if now - st.st_mtime < LOCK_STALE_SECONDS:
            return None
    except OSError:
        pass
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        try:
            os.close(fd)
        except OSError:
            pass
        return None
    try:
        os.ftruncate(fd, 0)
        os.write(fd, str(int(now)).encode())
    except OSError:
        pass
    return (fd, path)


def _release_lock(handle):
    if handle is None:
        return
    fd, path = handle
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.unlink(path)
    except OSError:
        pass


def _hard_exit():
    _release_lock(_LOCK_HANDLE[0])
    os._exit(0)


def _retry_after_seconds(headers, now):
    if headers is None:
        return None
    try:
        raw = headers.get("Retry-After")
    except Exception:
        return None
    if not isinstance(raw, str) or not raw.strip():
        return None
    text = raw.strip()
    try:
        secs = float(text)
        return secs if math.isfinite(secs) else None
    except ValueError:
        pass
    try:
        dt = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError):
        return None
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.timestamp() - now


def _clamp_backoff(secs):
    if secs is None:
        return DEFAULT_BACKOFF_SEC
    return max(MIN_BACKOFF_SEC, min(MAX_BACKOFF_SEC, secs))


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _build_opener():
    return urllib.request.build_opener(_NoRedirect())


def _fetch(token, now):
    req = urllib.request.Request(
        ENDPOINT,
        headers={
            "anthropic-beta": BETA_HEADER,
            "Content-Type": "application/json",
        },
        method="GET",
    )
    req.add_unredirected_header("Authorization", "Bearer " + token)
    try:
        with _build_opener().open(req, timeout=REQUEST_TIMEOUT_SEC) as resp:
            status = getattr(resp, "status", 200)
            raw = resp.read(RESPONSE_CAP_BYTES + 1)
    except urllib.error.HTTPError as exc:
        return ("http", exc.code, _retry_after_seconds(getattr(exc, "headers", None), now))
    except Exception:
        return ("error", None, None)
    if status != 200:
        return ("http", status, None)
    if len(raw) > RESPONSE_CAP_BYTES:
        return ("invalid", None, None)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, RecursionError):
        return ("invalid", None, None)
    if not isinstance(payload, dict):
        return ("invalid", None, None)
    return ("ok", payload, None)


def _parse_window(entry, key, now):
    if not isinstance(entry, dict):
        return None
    util = _num(entry.get("utilization"))
    if util is None or util < 0 or util > 100:
        return None
    raw_reset = entry.get("resets_at")
    if raw_reset is None:
        resets = None
    else:
        resets = _budget().parse_resets_at(raw_reset)
        if resets is None or not math.isfinite(resets):
            return None
        if not _budget().resets_plausible(resets, now, key):
            return None
    return {"used_percentage": util, "resets_at": resets, "captured_at": now}


def _build_candidates(payload, now):
    out = {}
    for key in WINDOWS:
        parsed = _parse_window(payload.get(key), key, now)
        if parsed is not None:
            out[key] = parsed
    return out


def _bounded_backoff(stamp, now):
    until = _num(stamp.get("backoff_until"))
    if until is None or until > now + MAX_BACKOFF_SEC:
        return None
    return until


def _stop_applies(stamp, expires_ms, now):
    if _num(stamp.get("stop_expires_at")) != expires_ms:
        return False
    stopped_at = _num(stamp.get("stop_at"))
    return stopped_at is not None and stopped_at <= now + STAMP_FUTURE_TOLERANCE_SEC


def run_once(now):
    stamp = _read_stamp()
    backoff_until = _bounded_backoff(stamp, now)
    if backoff_until is not None and now < backoff_until:
        return "backoff"
    if not _budget().claude_snapshot_needs_refresh(now, FRESH_SKIP_SEC):
        return "fresh"
    creds = _read_credentials()
    if creds is None:
        return "no-token"
    token, expires_ms = creds
    if expires_ms / 1000.0 - now <= EXPIRY_MARGIN_SEC:
        return "expired"
    if _stop_applies(stamp, expires_ms, now):
        return "stopped"
    kind, value, retry_after = _fetch(token, now)
    token = None
    stamp["ts"] = now
    result = kind
    if kind == "ok":
        candidates = _build_candidates(value, now)
        if not candidates:
            result = "invalid"
        else:
            _, wrote = _budget().update_claude_snapshot(candidates, now, "claude-api")
            if not wrote:
                result = "unchanged"
            stamp.pop("backoff_until", None)
            stamp.pop("stop_expires_at", None)
            stamp.pop("stop_at", None)
    elif kind == "http" and value == 429:
        stamp["backoff_until"] = now + _clamp_backoff(retry_after)
    elif kind == "http" and value in STOP_STATUSES:
        stamp["stop_expires_at"] = expires_ms
        stamp["stop_at"] = now
    _write_stamp(stamp)
    return result


def main():
    if _disabled():
        return 0
    timer = threading.Timer(WALL_CAP_SEC, _hard_exit)
    timer.daemon = True
    timer.start()
    handle = _acquire_lock()
    if handle is None:
        timer.cancel()
        return 0
    _LOCK_HANDLE[0] = handle
    try:
        try:
            run_once(time.time())
        except Exception:
            pass
    finally:
        timer.cancel()
        _release_lock(handle)
        _LOCK_HANDLE[0] = None
    return 0


if __name__ == "__main__":
    sys.exit(main())
