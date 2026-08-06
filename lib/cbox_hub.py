#!/usr/bin/env python3
import json
import os
import subprocess
import sys


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
    def __init__(self, ctx):
        self.ctx = ctx

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
            result[n] = "unknown"
        return result


class NullProbe(object):
    def container_id(self):
        return None

    def container_state(self, cid):
        return "unknown"

    def running_engines(self, cid, names):
        return dict((n, "unknown") for n in names)


def build_status_rows(ctx, probe, engine_names):
    rows = []
    try:
        cid = probe.container_id()
    except Exception:
        cid = None
    try:
        state = probe.container_state(cid)
    except Exception:
        state = "unknown"
    rows.append(("container", state))
    rows.append(("egress", ctx.get("egress", "unknown") or "unknown"))
    try:
        marks = probe.running_engines(cid, engine_names)
    except Exception:
        marks = dict((n, "unknown") for n in engine_names)
    engines_line = " ".join(
        "%s(%s)" % (n, marks.get(n, "unknown")) if marks.get(n) == "running" else n
        for n in engine_names
    )
    rows.append(("engines", engines_line or "<none>"))
    return rows


def build_screen(ctx, engine_names, status_rows):
    mode = ctx.get("mode", "none")
    root = ctx.get("root", os.getcwd())
    end_note = " (ends hub)" if mode == "global" else ""

    lines = []
    lines.append("cbox - %s   mode: %s" % (root, mode))
    for label, value in status_rows:
        lines.append("%s: %s" % (label, value))
    lines.append("")

    rows = []
    numbered = []
    i = 1
    for name in engine_names:
        numbered.append((str(i), "engine:%s" % name, "%-10s [start%s]" % (name, end_note)))
        i += 1
    numbered.append((str(i), "shell", "shell%s" % (" (ends hub)" if mode == "global" else "")))
    i += 1
    numbered.append((str(i), "logs", "logs"))
    i += 1
    numbered.append((str(i), "doctor", "doctor"))
    i += 1
    numbered.append((str(i), "config", "config (read-only view)"))
    i += 1
    numbered.append((str(i), "down", "down"))
    i += 1

    for num, action, label in numbered:
        lines.append("  %s) %s" % (num, label))
        rows.append(action)
    lines.append("  q) quit")
    return "\n".join(lines) + "\n", rows


def read_config_lines(conf_path):
    if not conf_path or not os.path.isfile(conf_path):
        return None
    out = []
    try:
        with open(conf_path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                stripped = line.rstrip("\n")
                if not stripped or stripped.lstrip().startswith("#"):
                    continue
                out.append(stripped)
    except OSError:
        return None
    return out


def action_argv(cbox_path, row):
    if row.startswith("engine:"):
        return [cbox_path, "run", row[len("engine:"):]]
    if row == "shell":
        return [cbox_path, "shell"]
    if row == "logs":
        return [cbox_path, "logs"]
    if row == "doctor":
        return [cbox_path, "doctor"]
    if row == "down":
        return [cbox_path, "down"]
    if row == "config":
        return None
    return None


def dispatch_config(ctx):
    lines = read_config_lines(ctx.get("conf"))
    sys.stderr.write("cbox config (read-only view):\n")
    if lines is None:
        sys.stderr.write("  <no configuration on disk at this scope>\n")
        return
    if not lines:
        sys.stderr.write("  <empty>\n")
        return
    for line in lines:
        sys.stderr.write("  %s\n" % line)


def run_action(cbox_path, row, ctx):
    if row == "config":
        dispatch_config(ctx)
        return 0
    argv = action_argv(cbox_path, row)
    if argv is None:
        sys.stderr.write("cbox: internal error - unknown row '%s'\n" % row)
        return 1
    try:
        return subprocess.call(argv)
    except OSError as exc:
        sys.stderr.write("cbox: failed to run %s: %s\n" % (" ".join(argv), exc))
        return 1


def hub_loop(install_dir, cbox_path, ctx, probe, stdin_stream, stdout_write):
    engine_names = engines_from_registry(install_dir)
    while True:
        status_rows = build_status_rows(ctx, probe, engine_names)
        screen, rows = build_screen(ctx, engine_names, status_rows)
        stdout_write(screen)
        stdout_write("> ")
        line = stdin_stream.readline()
        if line == "":
            stdout_write("\ncbox: EOF - quitting\n")
            return 0
        ans = line.strip()
        if ans in ("q", "Q"):
            return 0
        if not ans.isdigit():
            stdout_write("cbox: unrecognized selection '%s'\n" % ans)
            continue
        idx = int(ans)
        if idx < 1 or idx > len(rows):
            stdout_write("cbox: unrecognized selection '%s'\n" % ans)
            continue
        row = rows[idx - 1]
        rc = run_action(cbox_path, row, ctx)
        if rc != 0:
            stdout_write("cbox: action exited non-zero (%d)\n" % rc)
        if ctx.get("mode") == "global" and (row == "shell" or row.startswith("engine:")):
            return rc


def stderr_write(text):
    sys.stderr.write(text)
    sys.stderr.flush()


def usage_text(cbox_path):
    return (
        "usage: %s {run [--session <id>] <bin> [args]|session {list|new|close <id>|show <id>}|"
        "ai <analyse|plan|full> [claude|codex|auto] [--host|--container] [-p <prompt>|-] "
        "[--model M] [--effort E] [--dry-run]|up [--gpu]|down [--force]|restart [--gpu]|shell|"
        "logs [args]|update|reinstall-bins [--fresh|--if-stale]|install-hooks|continuity migrate|"
        "verify [--gpu|--isolated]|doctor|config {get|set|pending}|netaccess {status|allow|deny}|"
        "ollama {status|up|down|pull <model>|reconcile}|"
        "wg {status|up|down|keygen|peer {add|rm|list|config}}|"
        "session-broker {status|access {disabled|viewer|full-attach}|window {off|<minutes>}|"
        "key {add <pubkey-file> [comment]|rm <fingerprint>|fingerprints}}|"
        "backup|login [oauth-url]|login-codex|gc|net-refresh|ls|images [list|rm <hash>]}\n"
    ) % cbox_path


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("cbox_hub: usage: cbox_hub.py <install_dir> <cbox_path>\n")
        return 1
    install_dir = argv[1]
    cbox_path = argv[2]

    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        sys.stdout.write(usage_text(cbox_path))
        sys.stdout.write("cbox: 'cbox ls' lists RUNNING isolated projects only, not every configured project\n")
        return 1

    ctx = context_from_cbox(install_dir, cbox_path)
    if ctx is None or ctx.get("mode") not in ("global", "isolated"):
        sys.stdout.write(usage_text(cbox_path))
        sys.stdout.write("cbox: 'cbox ls' lists RUNNING isolated projects only, not every configured project\n")
        return 1

    probe = Probe(ctx)
    try:
        return hub_loop(install_dir, cbox_path, ctx, probe, sys.stdin, stderr_write)
    except KeyboardInterrupt:
        stderr_write("\ncbox: interrupted - quitting\n")
        return 130


HUB_CORE_FAILURE_EXIT = 97


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
