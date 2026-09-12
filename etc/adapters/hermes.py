#!/usr/bin/env python3
import json
import sys


def cmd_mcp_servers_yaml():
    rendered = json.loads(sys.argv[2])

    def yaml_scalar(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, int):
            return str(v)
        return json.dumps(v)

    def yaml_block(name, spec, indent):
        pad = "  " * indent
        lines = ["%s%s:" % (pad, yaml_scalar(name))]
        lines.append("%s  command: %s" % (pad, yaml_scalar(spec["command"])))
        args = spec.get("args") or []
        if args:
            lines.append("%s  args:" % pad)
            for a in args:
                lines.append("%s    - %s" % (pad, yaml_scalar(a)))
        else:
            lines.append("%s  args: []" % pad)
        env = spec.get("env")
        if env:
            lines.append("%s  env:" % pad)
            for k in sorted(env.keys()):
                lines.append("%s    %s: %s" % (pad, yaml_scalar(k), yaml_scalar(env[k])))
        if "timeout" in spec:
            lines.append("%s  timeout: %s" % (pad, yaml_scalar(spec["timeout"])))
        if "connect_timeout" in spec:
            lines.append(
                "%s  connect_timeout: %s" % (pad, yaml_scalar(spec["connect_timeout"]))
            )
        if "enabled" in spec:
            lines.append("%s  enabled: %s" % (pad, yaml_scalar(spec["enabled"])))
        return lines

    out = ["mcp_servers:"]
    if rendered:
        for name in sorted(rendered.keys()):
            out.extend(yaml_block(name, rendered[name], 1))
    else:
        out[-1] = "mcp_servers: {}"
    sys.stdout.write("\n".join(out) + "\n")


def cmd_hooks_yaml():
    hooks_path = sys.argv[2]
    command = "python3 %s/hermes_guard_bridge.py" % hooks_path
    lines = [
        "hooks:",
        "  pre_tool_call:",
        "    - matcher: terminal|process",
        "      command: %s" % json.dumps(command),
        "      timeout: 10",
    ]
    sys.stdout.write("\n".join(lines) + "\n")


COMMANDS = {
    "mcp-servers-yaml": cmd_mcp_servers_yaml,
    "hooks-yaml": cmd_hooks_yaml,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.stderr.write(
            "usage: hermes.py {%s} ...\n" % "|".join(sorted(COMMANDS))
        )
        sys.exit(2)
    COMMANDS[sys.argv[1]]()


if __name__ == "__main__":
    main()
