#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys


PROFILE_ORDER = {"ask": 0, "auto": 1, "skip": 2}

SIDE_EFFECT_SECTIONS = (
    "bashrc",
    "mounts",
    "workspaces",
    "egress",
    "mcp-servers",
    "agents",
    "claude-md",
    "settings",
    "hooks",
    "codex-mcp",
    "codex-progress",
    "continuity",
)

APPLY_CMD_FOR = {
    "none": "none - takes effect on next cbox run",
    "shell": "source ~/.bashrc",
    "restart": "cbox down && cbox run <bin>",
    "recreate": "cbox down && cbox run <bin> (compose recreates)",
    "topology": "cbox down && cbox run <bin> (compose recreates)",
    "rebuild": "next cbox run rebuilds the image automatically (image.inputs changed)",
    "infra-reconcile": "cbox ollama reconcile (owner project, not the current cbox compose project)",
}

OVERRIDE_KEY_RE = re.compile(r'^([A-Z][A-Z0-9_]*)=')


def registry_path(install_dir):
    return os.path.join(install_dir, "etc", "registry", "settings.json")


def load_registry(install_dir):
    with open(registry_path(install_dir), encoding="utf-8") as fh:
        return json.load(fh)


def setting_variables(registry):
    return [v for v in registry.get("variables", []) if v.get("role") == "setting"]


def variables_by_section(variables):
    out = {}
    for v in variables:
        out.setdefault(v["section"], []).append(v)
    return out


def group_sections(sections, project_only=False):
    filtered = sections
    if project_only:
        filtered = [s for s in sections if s.get("scope") == "project"]
    return sorted(filtered, key=lambda s: PROFILE_ORDER.get(s.get("profile"), 9))


def parse_config_get_all(text):
    values = {}
    for line in text.splitlines():
        if not line or line.startswith("# "):
            continue
        if "=" in line:
            k, _, v = line.partition("=")
            values[k] = v
    return values


def parse_pending(text):
    text = text.strip()
    if text in ("", "none"):
        return {}
    out = {}
    for line in text.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k] = v
    return out


def parse_diff_overridden_keys(text):
    keys = set()
    for line in text.splitlines():
        m = OVERRIDE_KEY_RE.match(line)
        if m:
            keys.add(m.group(1))
    return keys


def apply_cmd_for(cls):
    return APPLY_CMD_FOR.get(cls, "unknown apply class")


def enum_choices(var):
    t = var.get("type") or {}
    kind = t.get("kind")
    if kind == "enum":
        return list(t.get("values", []))
    if kind == "enum-or-empty":
        return [""] + list(t.get("values", []))
    return None


def build_set_argv(cbox_path, key, value):
    return [cbox_path, "config", "set", "%s=%s" % (key, value)]


def enum_choice_argv(cbox_path, var, choice_index):
    choices = enum_choices(var)
    if choices is None:
        return None
    if choice_index < 1 or choice_index > len(choices):
        return None
    value = choices[choice_index - 1]
    return build_set_argv(cbox_path, var["key"], value)


def format_values_summary(section_id, vars_by_section, values, max_len=48):
    parts = []
    for v in vars_by_section.get(section_id, []):
        k = v["key"]
        parts.append("%s=%s" % (k, values.get(k, "")))
    s = " ".join(parts)
    if len(s) > max_len:
        s = s[:max_len - 3] + "..."
    return s


def build_index_screen(sections_grouped, vars_by_section, values, pending_map, overridden_keys, isolated, filter_text=None):
    lines = ["cbox settings"]
    rows = []
    n = 0
    for s in sections_grouped:
        sid = s["id"]
        title = s.get("title", sid)
        if filter_text:
            hay = (sid + " " + title).lower()
            if filter_text.lower() not in hay:
                continue
        n += 1
        rows.append(sid)
        markers = ""
        if sid in pending_map:
            markers += "*"
        section_vars = vars_by_section.get(sid, [])
        if any(v["key"] in overridden_keys for v in section_vars):
            markers += "^"
        machine_tag = " [machine]" if s.get("scope") == "machine" else ""
        summary = format_values_summary(sid, vars_by_section, values)
        lines.append(
            "  %2d) %-16s %-24s apply:%-16s%s%s  %s"
            % (n, sid, title, s.get("apply_class", "none"), machine_tag, markers, summary)
        )
    lines.append("")
    lines.append("  /text filters   a) apply pending   c) classic   q) quit")
    if isolated:
        lines.append("  r) reset all overrides to global   g) derive from global")
    return "\n".join(lines) + "\n", rows


def build_section_screen(section, section_vars, values, pending_map, overridden_keys, failed=None):
    sid = section["id"]
    lines = ["cbox settings - %s" % section.get("title", sid)]
    desc = section.get("description")
    if desc:
        lines.append(desc)
    lines.append("apply: %s   scope: %s" % (section.get("apply_class", "none"), section.get("scope", "project")))
    if sid in pending_map:
        lines.append("pending apply: %s" % pending_map[sid])
    warning = format_fetch_warning(failed)
    if warning:
        lines.append(warning)
    rows = []
    i = 0
    for v in section_vars:
        i += 1
        rows.append(v["key"])
        mark = "^" if v["key"] in overridden_keys else " "
        cur = values.get(v["key"], "")
        prompt = v.get("prompt") or v.get("help") or v["key"]
        lines.append("  %d)%s %-28s = %s" % (i, mark, v["key"], cur))
        lines.append("     %s" % prompt)
    lines.append("  b) back")
    if sid in SIDE_EFFECT_SECTIONS:
        lines.append("  w) cbox setup update %s (apply host side effects)" % sid)
    return "\n".join(lines) + "\n", rows


def parse_argv(argv):
    if len(argv) < 3:
        return None
    install_dir = argv[1]
    cbox_path = argv[2]
    rest = argv[3:]
    root = None
    if rest:
        if len(rest) != 2 or rest[0] != "--local":
            return None
        root = rest[1]
    return {"install_dir": install_dir, "cbox_path": cbox_path, "root": root}


def usage_text():
    return (
        "usage: cbox setup menu (advanced per-section settings editor)\n"
        "  numbers select a section, then a key inside it\n"
        "  /text filters the index by id or title\n"
        "  a applies pending, c runs classic, q quits, b goes back from a section\n"
        "  isolated projects add r (reset overrides to global) and g (derive from global)\n"
        "  requires a real TTY on stdin and stdout - use 'cbox setup update <section>' or 'cbox setup walk' from a script\n"
    )


def _run_capture(argv, cwd):
    try:
        out = subprocess.run(
            argv,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.decode("utf-8", "replace")


def cbox_config_get_all(cbox_path, cwd):
    text = _run_capture([cbox_path, "config", "get", "--all"], cwd)
    if text is None:
        return {}, False
    return parse_config_get_all(text), True


def cbox_config_pending(cbox_path, cwd):
    text = _run_capture([cbox_path, "config", "pending"], cwd)
    if text is None:
        return {}, False
    return parse_pending(text), True


def cbox_config_diff(cbox_path, cwd):
    text = _run_capture([cbox_path, "config", "diff"], cwd)
    if text is None:
        return set(), False
    return parse_diff_overridden_keys(text), True


def hub_context(cbox_path, cwd):
    text = _run_capture([cbox_path, "__hub_context"], cwd)
    if text is None:
        return None
    try:
        return json.loads(text.strip())
    except ValueError:
        return None


def format_fetch_warning(failed):
    if not failed:
        return None
    return "cbox: warning - failed to run: %s (showing possibly stale or empty data)" % ", ".join(failed)


def build_header(ctx, root, cwd, failed=None):
    root_disp = root or cwd
    if ctx is None:
        lines = ["cbox settings - %s" % root_disp]
    else:
        mode = ctx.get("mode", "none")
        lines = ["cbox settings - %s   mode: %s" % (ctx.get("root", root_disp), mode)]
        egress = ctx.get("egress")
        if egress:
            lines.append("egress: %s" % egress)
        bins = ctx.get("bins")
        if bins:
            lines.append(bins)
    warning = format_fetch_warning(failed)
    if warning:
        lines.append(warning)
    return "\n".join(lines) + "\n"


def report_call_rc(argv, cwd, stdout_write):
    rc = subprocess.call(argv, cwd=cwd)
    if rc != 0:
        stdout_write("cbox: command failed (rc=%d): %s\n" % (rc, " ".join(argv)))
    return rc


def run_apply_pending(cbox_path, cwd, pending_map, stdin_stream, stdout_write):
    if not pending_map:
        stdout_write("cbox: no pending apply info\n")
        return
    stdout_write("cbox: pending apply status:\n")
    for section_id in sorted(pending_map.keys()):
        cls = pending_map[section_id]
        stdout_write("  %-16s %-16s %s\n" % (section_id, cls, apply_cmd_for(cls)))
    if any(cls == "infra-reconcile" for cls in pending_map.values()):
        stdout_write("run 'cbox ollama reconcile' now? [y/N] ")
        ans = stdin_stream.readline().strip().lower()
        if ans == "y":
            report_call_rc([cbox_path, "ollama", "reconcile"], cwd, stdout_write)


def edit_value(cbox_path, cwd, var, stdin_stream, stdout_write):
    choices = enum_choices(var)
    if choices is not None:
        stdout_write("cbox: %s - choose a value:\n" % var["key"])
        for i, choice in enumerate(choices, start=1):
            stdout_write("  %d) %s\n" % (i, choice if choice != "" else "<empty>"))
        stdout_write("> ")
        ans = stdin_stream.readline().strip()
        if not ans.isdigit():
            stdout_write("cbox: cancelled\n")
            return
        argv = enum_choice_argv(cbox_path, var, int(ans))
        if argv is None:
            stdout_write("cbox: unrecognized choice '%s'\n" % ans)
            return
        report_call_rc(argv, cwd, stdout_write)
        return
    stdout_write("cbox: %s - new value (blank cancels): " % var["key"])
    ans = stdin_stream.readline()
    if ans == "":
        return
    ans = ans.rstrip("\n")
    if ans == "":
        return
    report_call_rc(build_set_argv(cbox_path, var["key"], ans), cwd, stdout_write)


def run_section_loop(cbox_path, root, isolated, section, section_vars, cwd, stdin_stream, stdout_write):
    sid = section["id"]
    while True:
        values, values_ok = cbox_config_get_all(cbox_path, cwd)
        pending_map, pending_ok = cbox_config_pending(cbox_path, cwd)
        overridden, overridden_ok = cbox_config_diff(cbox_path, cwd) if isolated else (set(), True)
        failed = []
        if not values_ok:
            failed.append("cbox config get --all")
        if not pending_ok:
            failed.append("cbox config pending")
        if isolated and not overridden_ok:
            failed.append("cbox config diff")
        screen, rows = build_section_screen(section, section_vars, values, pending_map, overridden, failed)
        stdout_write(screen)
        stdout_write("> ")
        line = stdin_stream.readline()
        if line == "":
            stdout_write("\ncbox: EOF - quitting\n")
            return "quit"
        ans = line.strip()
        if ans in ("b", "B"):
            return "back"
        if ans in ("w", "W") and sid in SIDE_EFFECT_SECTIONS:
            report_call_rc([cbox_path, "setup", "update", sid], cwd, stdout_write)
            continue
        if not ans.isdigit():
            stdout_write("cbox: unrecognized selection '%s'\n" % ans)
            continue
        idx = int(ans)
        if idx < 1 or idx > len(rows):
            stdout_write("cbox: unrecognized selection '%s'\n" % ans)
            continue
        key = rows[idx - 1]
        var = next(v for v in section_vars if v["key"] == key)
        edit_value(cbox_path, cwd, var, stdin_stream, stdout_write)


def run_reset_overrides(cbox_path, cwd, overridden_keys, stdin_stream, stdout_write):
    if not overridden_keys:
        stdout_write("cbox: no project overrides to reset\n")
        return
    stdout_write("cbox: reset %d override(s) to global? [y/N] " % len(overridden_keys))
    ans = stdin_stream.readline().strip().lower()
    if ans != "y":
        stdout_write("cbox: cancelled\n")
        return
    report_call_rc([cbox_path, "config", "unset"] + sorted(overridden_keys), cwd, stdout_write)


def run_loop(cbox_path, root, isolated, sections, vars_by_section, cwd, stdin_stream, stdout_write):
    grouped = group_sections(sections, project_only=isolated)
    filter_text = None
    while True:
        values, values_ok = cbox_config_get_all(cbox_path, cwd)
        pending_map, pending_ok = cbox_config_pending(cbox_path, cwd)
        overridden, overridden_ok = cbox_config_diff(cbox_path, cwd) if isolated else (set(), True)
        ctx = hub_context(cbox_path, cwd)
        failed = []
        if not values_ok:
            failed.append("cbox config get --all")
        if not pending_ok:
            failed.append("cbox config pending")
        if isolated and not overridden_ok:
            failed.append("cbox config diff")
        stdout_write(build_header(ctx, root, cwd, failed))
        screen, rows = build_index_screen(grouped, vars_by_section, values, pending_map, overridden, isolated, filter_text)
        stdout_write(screen)
        stdout_write("> ")
        line = stdin_stream.readline()
        if line == "":
            stdout_write("\ncbox: EOF - quitting\n")
            return 0
        ans = line.strip()
        if ans in ("q", "Q"):
            return 0
        if ans.startswith("/"):
            filter_text = ans[1:]
            continue
        if ans in ("a", "A"):
            run_apply_pending(cbox_path, cwd, pending_map, stdin_stream, stdout_write)
            continue
        if ans in ("c", "C"):
            report_call_rc([cbox_path, "setup", "classic"], cwd, stdout_write)
            continue
        if isolated and ans in ("r", "R"):
            run_reset_overrides(cbox_path, cwd, overridden, stdin_stream, stdout_write)
            continue
        if isolated and ans in ("g", "G"):
            report_call_rc([cbox_path, "setup", "--local", root, "--from-global"], cwd, stdout_write)
            continue
        if not ans.isdigit():
            stdout_write("cbox: unrecognized selection '%s'\n" % ans)
            continue
        idx = int(ans)
        if idx < 1 or idx > len(rows):
            stdout_write("cbox: unrecognized selection '%s'\n" % ans)
            continue
        sid = rows[idx - 1]
        section = next(s for s in sections if s["id"] == sid)
        outcome = run_section_loop(cbox_path, root, isolated, section, vars_by_section.get(sid, []), cwd, stdin_stream, stdout_write)
        if outcome == "quit":
            return 0


def main(argv):
    parsed = parse_argv(argv)
    if parsed is None:
        sys.stdout.write(usage_text())
        return 1
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        sys.stdout.write(usage_text())
        return 1
    install_dir = parsed["install_dir"]
    cbox_path = parsed["cbox_path"]
    root = parsed["root"]
    isolated = root is not None
    try:
        registry = load_registry(install_dir)
    except (OSError, ValueError) as exc:
        sys.stderr.write("cbox_settings: cannot load registry: %s\n" % exc)
        return 1
    sections = registry.get("sections", [])
    variables = setting_variables(registry)
    vbs = variables_by_section(variables)
    cwd = root if root else os.getcwd()

    def stdout_write(text):
        sys.stdout.write(text)
        sys.stdout.flush()

    try:
        return run_loop(cbox_path, root, isolated, sections, vbs, cwd, sys.stdin, stdout_write)
    except KeyboardInterrupt:
        sys.stderr.write("\ncbox: interrupted - quitting\n")
        return 130


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        sys.stderr.write("cbox_settings: unhandled failure: %s\n" % exc)
        sys.exit(1)
