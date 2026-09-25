#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cbox_hub_screens as screens
import cbox_hub_ui as ui


def context_from_cbox(install_dir, cbox_path):
    try:
        out = subprocess.run(
            [cbox_path, "__hub_context"],
            cwd=os.getcwd(),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
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
        result = {}
        for n in names:
            argv1 = self._probe_argv1(n)
            result[n] = self._scan_one(cid, argv1)
        return result

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

    def _scan_one(self, cid, argv1):
        script = (
            'for p in /proc/[0-9]*/cmdline; do\n'
            '  [ -e "$p" ] || continue\n'
            '  a0="$(tr "\\0" "\\n" < "$p" 2>/dev/null | sed -n 1p)"\n'
            '  a1="$(tr "\\0" "\\n" < "$p" 2>/dev/null | sed -n 2p)"\n'
            '  case "$a0" in\n'
            '    */entrypoint.sh) [ "$a1" = "$1" ] && exit 0 ;;\n'
            '    "$1") exit 0 ;;\n'
            '  esac\n'
            'done\n'
            'exit 1\n'
        )
        try:
            out = subprocess.run(
                ["docker", "exec", cid, "sh", "-c", script, "sh", argv1],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError):
            return "unknown"
        return "running" if out.returncode == 0 else "down"


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
        state = {"thread": None, "last": None}
        try:
            probe._hub_probe_state = state
        except (AttributeError, TypeError):
            state = {"thread": None, "last": None}
    return state


def gather_status(probe, engine_names, budget=STATUS_BUDGET_SECONDS):
    state = _probe_state(probe)
    thread = state["thread"]
    if thread is not None and thread.is_alive():
        if state["last"] is not None:
            return dict(state["last"])
        return _fallback_snapshot(engine_names)
    workbox = {"snap": {"container_state": None, "engine_state": None}}

    def run_probe():
        try:
            cid = probe.container_id()
        except Exception:
            cid = None
        try:
            workbox["snap"]["container_state"] = probe.container_state(cid)
        except Exception:
            workbox["snap"]["container_state"] = "unknown"
        try:
            workbox["snap"]["engine_state"] = probe.running_engines(cid, engine_names)
        except Exception:
            workbox["snap"]["engine_state"] = dict((n, "unknown") for n in engine_names)

    t = threading.Thread(target=run_probe)
    t.daemon = True
    t.start()
    state["thread"] = t
    t.join(budget)
    snap = workbox["snap"]
    if snap["container_state"] is not None and snap["engine_state"] is not None:
        state["last"] = {
            "container_state": snap["container_state"],
            "engine_state": snap["engine_state"],
        }
        return dict(state["last"])
    if state["last"] is not None:
        return dict(state["last"])
    return _fallback_snapshot(engine_names)


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


def hub_loop(install_dir, cbox_path, ctx, probe, stdin_stream, stdout_write, runner=None):
    if runner is None:
        runner = subprocess.call
    stdout = _StdoutWriter(stdout_write)
    keys = ui.make_keys(stdin_stream, stdout)
    engine_names = engines_from_registry(install_dir)
    status = gather_status(probe, engine_names)
    screen_name = "main"

    while True:
        if screen_name == "main":
            snapshot = {
                "ctx": ctx,
                "engine_names": engine_names,
                "engine_state": status["engine_state"],
                "container_state": status["container_state"],
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
                "engine_state": status["engine_state"],
            }
            text, actions = renderer(snapshot)

        stdout.write(text)
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
            status = gather_status(probe, engine_names)
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

    if not (stdin.isatty() and stdout.isatty()):
        stdout.write(cli_usage(cbox_path))
        return 1

    ctx = context_from_cbox(install_dir, cbox_path)
    if ctx is None:
        stdout.write(cli_usage(cbox_path))
        return 1
    if ctx.get("mode") not in ("global", "isolated"):
        return HUB_NO_CONFIG_EXIT

    probe = Probe(ctx, install_dir)
    try:
        return hub_loop(install_dir, cbox_path, ctx, probe, stdin, stdout.write)
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
