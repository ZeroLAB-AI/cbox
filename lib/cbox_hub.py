#!/usr/bin/env python3
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import threading
import time

_T_START = time.time()

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cbox_hub_screens as screens
import cbox_hub_ui as ui

_T_IMPORTED = time.time()


class _Timing(object):
    enabled = False
    origin = None


def tstart():
    if _Timing.enabled:
        return time.time()
    return 0.0


def tend(label, started):
    if _Timing.enabled:
        sys.stderr.write("cbox-hub-timing: %s %d ms\n" % (label, int((time.time() - started) * 1000)))
        sys.stderr.flush()


def tcumulative(label):
    if _Timing.enabled:
        origin = _Timing.origin if _Timing.origin is not None else _T_START
        sys.stderr.write("cbox-hub-timing: %s %d ms since start\n" % (label, int((time.time() - origin) * 1000)))
        sys.stderr.flush()


def timing_setup(environ):
    if environ.get("CBOX_HUB_TIMING", "") != "1":
        _Timing.enabled = False
        _Timing.origin = None
        return
    _Timing.enabled = True
    origin = None
    raw = environ.get("CBOX_HUB_T0", "")
    if raw.isdigit():
        origin = int(raw) / 1000000.0
    _Timing.origin = origin
    if origin is not None:
        sys.stderr.write("cbox-hub-timing: bash plus interpreter start %d ms\n" % int((_T_START - origin) * 1000))
    sys.stderr.write("cbox-hub-timing: python imports %d ms\n" % int((_T_IMPORTED - _T_START) * 1000))
    sys.stderr.flush()


def context_from_cbox(install_dir, cbox_path):
    started = tstart()
    try:
        out = subprocess.run(
            [cbox_path, "__hub_context"],
            cwd=os.getcwd(),
            stdout=subprocess.PIPE,
            stderr=None if _Timing.enabled else subprocess.DEVNULL,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    tend("context (cbox __hub_context)", started)
    if out.returncode != 0:
        return None
    try:
        data = json.loads(out.stdout.decode("utf-8", "replace").strip())
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict) or "mode" not in data:
        return None
    return data


def engines_from_registry(install_dir):
    reg = os.path.join(install_dir, "etc", "engines", "engines.json")
    try:
        with open(reg, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return ["claude", "codex"]
    engines = data.get("engines")
    if not isinstance(engines, dict) or not engines:
        return ["claude", "codex"]
    names = []
    for name, meta in engines.items():
        if not isinstance(meta, dict):
            continue
        enabled_var = meta.get("enabled_var")
        if enabled_var in (None, "null", ""):
            names.append(name)
            continue
        if os.environ.get(enabled_var, "off") == "on":
            names.append(name)
    return names


class Probe(object):
    def __init__(self, ctx, install_dir=None):
        self.ctx = ctx
        self._argv1_cache = {}
        self._engines = {}
        if install_dir:
            reg = os.path.join(install_dir, "etc", "engines", "engines.json")
            try:
                with open(reg, encoding="utf-8") as fh:
                    data = json.load(fh)
                eng = data.get("engines")
                if isinstance(eng, dict):
                    self._engines = eng
            except (OSError, ValueError):
                self._engines = {}

    def container_id(self):
        compose = self.ctx.get("compose_argv")
        service = self.ctx.get("service", "cbox")
        if not compose:
            return None
        try:
            out = subprocess.run(
                compose + ["ps", "-q", service],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if out.returncode != 0:
            return None
        cid = out.stdout.decode("utf-8", "replace").strip()
        return cid or None

    def container_state(self, cid):
        if cid is None:
            return "down"
        try:
            out = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.StartedAt}}", cid],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError):
            return "unknown"
        if out.returncode != 0:
            return "unknown"
        started = out.stdout.decode("utf-8", "replace").strip()
        if not started:
            return "unknown"
        return "up (since %s)" % started[:19]

    def running_engines(self, cid, names):
        if cid is None:
            return dict((n, "unknown") for n in names)
        argv1s = dict((n, self._probe_argv1(n)) for n in names)
        wanted = sorted(set(argv1s.values()))
        if not wanted:
            return {}
        try:
            out = subprocess.run(
                ["docker", "exec", cid, "sh", "-c", SCAN_SCRIPT, "sh"] + wanted,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError):
            return dict((n, "unknown") for n in names)
        if out.returncode != 0:
            return dict((n, "down") for n in names)
        return parse_scan_output(out.stdout.decode("utf-8", "replace"), argv1s)

    def _probe_argv1(self, name):
        argv1 = self._argv1_cache.get(name)
        if argv1 is not None:
            return argv1
        argv1 = name
        meta = self._engines.get(name)
        if isinstance(meta, dict):
            probe = meta.get("probe")
            if isinstance(probe, dict) and probe.get("kind") == "canonical-paths":
                cand = probe.get("argv1")
                if isinstance(cand, list) and cand:
                    argv1 = cand[0]
        self._argv1_cache[name] = argv1
        return argv1


SCAN_SCRIPT = (
    'for p in /proc/[0-9]*/cmdline; do\n'
    '  [ -e "$p" ] || continue\n'
    '  tr "\\0" "\\n" < "$p" 2>/dev/null | {\n'
    '    IFS= read -r a0\n'
    '    IFS= read -r a1\n'
    '    for want in "$@"; do\n'
    '      case "$a0" in\n'
    '        */entrypoint.sh) [ "$a1" = "$want" ] && printf "%s\\n" "$want" ;;\n'
    '        "$want") printf "%s\\n" "$want" ;;\n'
    '      esac\n'
    '    done\n'
    '  }\n'
    'done\n'
    'exit 0\n'
)


def parse_scan_output(text, argv1s):
    found = set(line for line in text.split("\n") if line)
    return dict((n, "running" if argv1 in found else "down") for n, argv1 in argv1s.items())


class NullProbe(object):
    def container_id(self):
        return None

    def container_state(self, cid):
        return "unknown"

    def running_engines(self, cid, names):
        return dict((n, "unknown") for n in names)


STATUS_BUDGET_SECONDS = 1.5


def _fallback_snapshot(engine_names):
    return {
        "container_state": "...",
        "engine_state": dict((n, "...") for n in engine_names),
    }


def _probe_state(probe):
    state = getattr(probe, "_hub_probe_state", None)
    if state is None:
        state = {"thread": None, "last": None, "cached": None}
        try:
            probe._hub_probe_state = state
        except (AttributeError, TypeError):
            state = {"thread": None, "last": None, "cached": None}
    return state


def _snapshot_complete_and_clean(snap, engine_names):
    container = snap.get("container_state")
    engines = snap.get("engine_state")
    if not isinstance(container, str) or container in ("", "unknown", "..."):
        return False
    if not isinstance(engines, dict):
        return False
    for name in engine_names:
        if engines.get(name) in (None, "unknown", "..."):
            return False
    return True


def _start_probe(probe, engine_names, state, cache):
    workbox = {"snap": {"container_state": None, "engine_state": None}}

    def run_probe():
        total = tstart()
        step = tstart()
        try:
            cid = probe.container_id()
        except Exception:
            cid = None
        tend("probe compose ps", step)
        side = {"state": "unknown"}

        def run_state():
            began = tstart()
            try:
                side["state"] = probe.container_state(cid)
            except Exception:
                side["state"] = "unknown"
            tend("probe inspect (concurrent)", began)

        state_thread = threading.Thread(target=run_state)
        state_thread.daemon = True
        state_thread.start()
        step = tstart()
        try:
            engines = probe.running_engines(cid, engine_names)
        except Exception:
            engines = dict((n, "unknown") for n in engine_names)
        tend("probe exec scan (concurrent)", step)
        state_thread.join()
        snap = {"container_state": side["state"], "engine_state": engines}
        workbox["snap"] = snap
        state["last"] = {
            "container_state": snap["container_state"],
            "engine_state": snap["engine_state"],
        }
        tend("probe total", total)
        if cache is not None and _snapshot_complete_and_clean(snap, engine_names):
            began = tstart()
            cache.store(snap)
            tend("cache store", began)

    t = threading.Thread(target=run_probe)
    t.daemon = True
    t.start()
    state["thread"] = t
    return t


def gather_status(probe, engine_names, budget=STATUS_BUDGET_SECONDS, cache=None):
    state = _probe_state(probe)
    thread = state["thread"]
    if thread is not None and thread.is_alive():
        if state["last"] is None and state.get("cached") is not None:
            thread.join(budget)
        if state["last"] is not None:
            return dict(state["last"])
        if state.get("cached") is not None:
            return dict(state["cached"])
        return _fallback_snapshot(engine_names)
    t = _start_probe(probe, engine_names, state, cache)
    t.join(budget)
    if state["last"] is not None:
        return dict(state["last"])
    return _fallback_snapshot(engine_names)


def initial_status(probe, engine_names, cache, budget=STATUS_BUDGET_SECONDS):
    if cache is None:
        return gather_status(probe, engine_names, budget)
    began = tstart()
    cached = cache.load(engine_names)
    tend("cache load", began)
    if cached is None:
        return gather_status(probe, engine_names, budget, cache)
    state = _probe_state(probe)
    state["cached"] = cached
    _start_probe(probe, engine_names, state, cache)
    return dict(cached)


def settle_cached(probe, status, budget=STATUS_BUDGET_SECONDS, wait=False):
    if not status.get("from_cache"):
        return status
    state = _probe_state(probe)
    thread = state["thread"]
    if wait and thread is not None and thread.is_alive():
        thread.join(budget)
    if state["last"] is not None:
        return dict(state["last"])
    return status


def format_age(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    return "%dm" % (seconds // 60)


def display_status(status):
    if not status.get("from_cache"):
        return status
    shown = dict(status)
    age = format_age(status.get("cached_age", 0))
    shown["container_state"] = "%s (cached %s ago)" % (status["container_state"], age)
    return shown


CACHE_MAX_AGE_SECONDS = 600
CACHE_MAX_BYTES = 16384
CACHE_TEXT = re.compile(r"^[ -~]{1,120}$")


def cache_dir():
    home = os.environ.get("HOME") or os.path.expanduser("~")
    return os.path.join(home, ".config", "cbox", "hub-cache")


def cache_scope(ctx):
    material = json.dumps([ctx.get("compose_argv"), ctx.get("service", "cbox")], sort_keys=True)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:20]


def _open_cache_dir(directory, create):
    if create:
        try:
            os.makedirs(directory, 0o700, exist_ok=True)
        except OSError:
            return None
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(directory, flags)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            os.close(fd)
            return None
    except OSError:
        os.close(fd)
        return None
    return fd


class StatusCache(object):
    def __init__(self, directory, scope, clock=time.time, max_age=CACHE_MAX_AGE_SECONDS):
        self.directory = directory
        self.scope = scope
        self.clock = clock
        self.max_age = max_age
        self.name = "status-%s.json" % scope

    def load(self, engine_names):
        dirfd = _open_cache_dir(self.directory, False)
        if dirfd is None:
            return None
        try:
            return self._load_from(dirfd, engine_names)
        except (OSError, ValueError, TypeError, KeyError):
            return None
        finally:
            os.close(dirfd)

    def _load_from(self, dirfd, engine_names):
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        fd = os.open(self.name, flags, dir_fd=dirfd)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                return None
            if info.st_size > CACHE_MAX_BYTES or info.st_mode & 0o077:
                return None
            raw = os.read(fd, CACHE_MAX_BYTES + 1)
        finally:
            os.close(fd)
        if len(raw) > CACHE_MAX_BYTES:
            return None
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict) or data.get("v") != 1 or data.get("scope") != self.scope:
            return None
        stamp = data.get("ts")
        if isinstance(stamp, bool) or not isinstance(stamp, (int, float)):
            return None
        age = self.clock() - stamp
        if age < 0 or age > self.max_age:
            return None
        container = data.get("container_state")
        engines = data.get("engine_state")
        if not isinstance(container, str) or not CACHE_TEXT.match(container):
            return None
        if not isinstance(engines, dict) or set(engines) != set(engine_names):
            return None
        snap = {"container_state": container, "engine_state": {}}
        for name in engine_names:
            value = engines[name]
            if not isinstance(value, str) or not CACHE_TEXT.match(value):
                return None
            snap["engine_state"][name] = value
        if not _snapshot_complete_and_clean(snap, engine_names):
            return None
        snap["from_cache"] = True
        snap["cached_age"] = age
        return snap

    def store(self, snap):
        payload = json.dumps({
            "v": 1,
            "scope": self.scope,
            "ts": self.clock(),
            "container_state": snap["container_state"],
            "engine_state": snap["engine_state"],
        }).encode("utf-8")
        dirfd = _open_cache_dir(self.directory, True)
        if dirfd is None:
            return False
        tmp = ".%s.%d.%s.tmp" % (self.name, os.getpid(), os.urandom(4).hex())
        wrote = False
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(tmp, flags, 0o600, dir_fd=dirfd)
            try:
                view = memoryview(payload)
                while view:
                    view = view[os.write(fd, view):]
            finally:
                os.close(fd)
            os.rename(tmp, self.name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
            wrote = True
        except (OSError, NotImplementedError, TypeError):
            try:
                os.unlink(tmp, dir_fd=dirfd)
            except (OSError, NotImplementedError, TypeError):
                pass
        finally:
            os.close(dirfd)
        return wrote


def cli_usage(cbox_path):
    try:
        out = subprocess.run(
            [cbox_path, "__cbox_hub_usage_probe__"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        text = out.stdout.decode("utf-8", "replace")
        if text:
            return text
    except (OSError, subprocess.SubprocessError):
        pass
    return "usage: %s <verb> [args]\n" % cbox_path


def settings_argv(install_dir, cbox_path, ctx):
    script = os.path.join(install_dir, "lib", "cbox_settings.py")
    argv = [sys.executable, script, install_dir, cbox_path]
    if ctx.get("mode") == "isolated":
        root = ctx.get("root")
        if not root:
            return None
        argv += ["--local", root]
    return argv


def run_action(action, keys, stdout, install_dir, cbox_path, ctx, runner):
    if action.kind == "quit":
        return "quit", 0
    if action.kind == "back":
        return "back", 0
    if action.kind == "refresh":
        return "refresh", 0
    if action.kind == "hints":
        return "hints", 0
    if action.kind == "submenu":
        return "submenu", action.submenu

    argv = action.argv
    if action.kind == "settings":
        argv = settings_argv(install_dir, cbox_path, ctx)
        if argv is None:
            stdout.write("cbox: cannot open settings - no project root resolved\n")
            return "noop", 1

    if action.argv_builder is not None:
        text = ui.read_text(keys, stdout, action.prompt or "value: ")
        if text is None:
            return "eof", 1
        if not text:
            stdout.write("cancelled\n")
            return "noop", 1
        argv = action.argv_builder(text)
        if argv is None:
            stdout.write("cancelled (bad input)\n")
            return "noop", 1

    if action.confirm:
        if action.force_token:
            text = ui.read_text(keys, stdout, "%s: " % action.confirm_prompt)
            if text is None:
                return "eof", 1
            if text != action.force_token:
                stdout.write("cancelled\n")
                return "noop", 1
            argv = argv + ["--force"]
        else:
            answer = ui.confirm(keys, stdout, action.confirm_prompt)
            if answer is None:
                return "eof", 1
            if not answer:
                return "noop", 1

    try:
        rc = runner(argv)
    except OSError as exc:
        stdout.write("cbox: failed to run %s: %s\n" % (" ".join(argv), exc))
        return "ran", 1
    if rc != 0:
        stdout.write("cbox: action exited non-zero (%d)\n" % rc)
    return "ran", rc


EOF_MESSAGE = "\ncbox: EOF - quitting\n"


def hub_loop(install_dir, cbox_path, ctx, probe, stdin_stream, stdout_write, runner=None, cache=None):
    if runner is None:
        runner = subprocess.call
    stdout = _StdoutWriter(stdout_write)
    keys = ui.make_keys(stdin_stream, stdout)
    engine_names = engines_from_registry(install_dir)
    status = initial_status(probe, engine_names, cache)
    screen_name = "main"
    first_screen = True

    while True:
        status = settle_cached(probe, status, wait=(screen_name != "main"))
        shown = display_status(status)
        if screen_name == "main":
            snapshot = {
                "ctx": ctx,
                "engine_names": engine_names,
                "engine_state": shown["engine_state"],
                "container_state": shown["container_state"],
                "cbox_path": cbox_path,
                "doctor_warnings": None,
            }
            text, actions = screens.render_main(snapshot)
        else:
            renderer = screens.RENDERERS[screen_name]
            snapshot = {
                "ctx": ctx,
                "cbox_path": cbox_path,
                "engine_names": engine_names,
                "engine_state": shown["engine_state"],
            }
            text, actions = renderer(snapshot)

        stdout.write(text)
        if first_screen:
            first_screen = False
            tcumulative("first screen shown")
        default_key = actions[0].key if actions else None
        sel = ui.read_selection(keys, stdout, default_key)
        if sel is None:
            stdout.write(EOF_MESSAGE)
            return 0
        action = ui.find_action(actions, sel)
        if action is None:
            stdout.write("cbox: unrecognized selection '%s'\n" % sel)
            continue

        if action.kind == "hints":
            stdout.write(screens.render_hints(actions))
            if keys.read_key() is None:
                stdout.write(EOF_MESSAGE)
                return 0
            continue
        if action.kind == "refresh":
            status = gather_status(probe, engine_names, cache=cache)
            continue
        if action.kind == "submenu":
            screen_name = action.submenu
            continue
        if action.kind == "back":
            screen_name = "main"
            continue
        if action.kind == "quit":
            return 0

        outcome, rc = run_action(action, keys, stdout, install_dir, cbox_path, ctx, runner)
        if outcome == "eof":
            stdout.write(EOF_MESSAGE)
            return 0
        if outcome == "ran":
            if ctx.get("mode") == "global" and screen_name == "main" and \
                    action.key.isdigit():
                return rc
            if ctx.get("mode") == "global" and screen_name == "main" and \
                    action.key == "t":
                return rc


class _StdoutWriter(object):
    def __init__(self, write_fn):
        self._write = write_fn
        self._tty_source = getattr(write_fn, "__self__", None)

    def write(self, text):
        self._write(text)
        return len(text)

    def isatty(self):
        if self._tty_source is None:
            return False
        try:
            return self._tty_source.isatty()
        except Exception:
            return False

    def fileno(self):
        if self._tty_source is None:
            raise OSError("no underlying stream for isatty/fileno")
        return self._tty_source.fileno()


def stderr_write(text):
    sys.stderr.write(text)
    sys.stderr.flush()


def main(argv, stdin=None, stdout=None):
    stdin = sys.stdin if stdin is None else stdin
    stdout = sys.stdout if stdout is None else stdout

    if len(argv) < 3:
        sys.stderr.write("cbox_hub: usage: cbox_hub.py <install_dir> <cbox_path>\n")
        return 1
    install_dir = argv[1]
    cbox_path = argv[2]
    timing_setup(os.environ)

    if not (stdin.isatty() and stdout.isatty()):
        stdout.write(cli_usage(cbox_path))
        return 1

    ctx = context_from_cbox(install_dir, cbox_path)
    tcumulative("context ready")
    if ctx is None:
        stdout.write(cli_usage(cbox_path))
        return 1
    if ctx.get("mode") not in ("global", "isolated"):
        return HUB_NO_CONFIG_EXIT

    probe = Probe(ctx, install_dir)
    cache = StatusCache(cache_dir(), cache_scope(ctx))
    try:
        return hub_loop(install_dir, cbox_path, ctx, probe, stdin, stdout.write, cache=cache)
    except KeyboardInterrupt:
        stderr_write("\ncbox: interrupted - quitting\n")
        return 130


HUB_CORE_FAILURE_EXIT = 97
HUB_NO_CONFIG_EXIT = 96


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        sys.stderr.write("cbox_hub: unhandled failure: %s\n" % exc)
        sys.exit(HUB_CORE_FAILURE_EXIT)
