#!/usr/bin/env python3
import fcntl
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import threading
import time

HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))
SHIM_CANDIDATES = (
    os.path.join(HOOKS_DIR, "codex_mcp_shim.py"),
    os.path.join(os.path.dirname(HOOKS_DIR), "mcp", "codex_mcp_shim.py"),
)

LOCK_STALE_SECONDS = 30
OVERALL_TIMEOUT_SEC = 20
INIT_TIMEOUT_SEC = 5
RATE_LIMIT_READ_TIMEOUT_SEC = 10


def _shim_path():
    for path in SHIM_CANDIDATES:
        if os.path.isfile(path):
            return path
    return SHIM_CANDIDATES[0]


def _load_shim(shim_path=None):
    path = shim_path or _shim_path()
    spec = importlib.util.spec_from_file_location(
        "codex_mcp_shim_for_usage_refresh", path
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _has_auth(shim):
    home = shim.codex_home()
    path = os.path.join(home, "auth.json")
    try:
        return os.path.getsize(path) > 0
    except OSError:
        return False


def _acquire_lock(shim):
    path = os.path.join(shim.usage_dir(), "codex_refresh.lock")
    d = os.path.dirname(path)
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
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
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
    except OSError:
        return None
    try:
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


def _nice_prefix():
    prefix = []
    ionice = shutil.which("ionice")
    if ionice:
        prefix += [ionice, "-c3"]
    nice = shutil.which("nice")
    if nice:
        prefix += [nice, "-n19"]
    return prefix


def _kill_quietly(proc):
    try:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except Exception:
                proc.kill()
    except Exception:
        pass


def _run_probe(codex_argv=None):
    argv = _nice_prefix() + (codex_argv or ["codex", "app-server"])
    try:
        proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        return None

    timer = threading.Timer(OVERALL_TIMEOUT_SEC, _kill_quietly, args=(proc,))
    timer.daemon = True
    timer.start()

    pending = {}
    pending_lock = threading.Lock()
    next_id = [1]
    result = {"rateLimits": None, "ordinaryUsageAllowed": None}

    def send(obj):
        line = (json.dumps(obj) + "\n").encode()
        try:
            proc.stdin.write(line)
            proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def request(method, params, timeout):
        with pending_lock:
            rid = next_id[0]
            next_id[0] += 1
            ev = threading.Event()
            slot = {}
            pending[rid] = (ev, slot)
        send({"id": rid, "method": method, "params": params})
        ev.wait(timeout)
        with pending_lock:
            pending.pop(rid, None)
        return slot.get("result")

    def reader():
        try:
            for raw in proc.stdout:
                line = raw.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                rid = msg.get("id")
                if rid is not None and "method" not in msg:
                    with pending_lock:
                        entry = pending.get(rid)
                    if entry is not None:
                        ev, slot = entry
                        if "result" in msg:
                            slot["result"] = msg.get("result")
                        ev.set()
        except Exception:
            pass

    reader_thread = threading.Thread(target=reader, daemon=True)
    reader_thread.start()
    try:
        request(
            "initialize",
            {"clientInfo": {"name": "cbox-codex-usage-refresh", "version": "1"}},
            INIT_TIMEOUT_SEC,
        )
        send({"method": "initialized"})
        res = request("account/rateLimits/read", None, RATE_LIMIT_READ_TIMEOUT_SEC)
        if isinstance(res, dict):
            result["rateLimits"] = res.get("rateLimits")
            oa = res.get("ordinaryUsageAllowed")
            result["ordinaryUsageAllowed"] = oa if isinstance(oa, bool) else None
    finally:
        timer.cancel()
        _kill_quietly(proc)
    return result


def main():
    try:
        shim = _load_shim()
    except Exception:
        return 0
    if shutil.which("codex") is None:
        return 0
    if not _has_auth(shim):
        return 0
    handle = _acquire_lock(shim)
    if handle is None:
        return 0
    try:
        try:
            probe = _run_probe()
        except Exception:
            probe = None
        rate_limits = probe.get("rateLimits") if isinstance(probe, dict) else None
        ordinary_usage_allowed = (
            probe.get("ordinaryUsageAllowed") if isinstance(probe, dict) else None
        )
        if rate_limits is not None:
            try:
                shim.write_codex_usage_snapshot(rate_limits, ordinary_usage_allowed)
            except Exception:
                pass
    finally:
        _release_lock(handle)
    return 0


if __name__ == "__main__":
    sys.exit(main())
