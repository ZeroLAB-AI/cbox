#!/usr/bin/env python3
import json
import sys


def cmd_hooks_json():
    hooks_path = sys.argv[2]
    codex_hooks_gate = sys.argv[3] if len(sys.argv) > 3 else "off"
    command = "python3 " + hooks_path + "/continuity_session_start.py"
    events = {
        "SessionStart": [
            {"hooks": [{"type": "command", "command": command}]}
        ]
    }
    if codex_hooks_gate == "on":
        bridge_command = "python3 " + hooks_path + "/codex_guard_bridge.py"
        events["PreToolUse"] = [
            {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": bridge_command}],
            }
        ]
    doc = {"hooks": events}
    sys.stdout.write(json.dumps(doc, indent=2) + "\n")


def cmd_mcp_toml_blocks():
    rendered = json.loads(sys.argv[2])

    def toml_string(v):
        return json.dumps(v)

    def toml_value(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (int, float)):
            return str(v)
        if isinstance(v, str):
            return toml_string(v)
        if isinstance(v, list):
            return "[" + ", ".join(toml_value(item) for item in v) + "]"
        if isinstance(v, dict):
            pairs = ", ".join(
                "%s = %s" % (toml_string(k), toml_value(val))
                for k, val in v.items()
            )
            return "{ " + pairs + " }"
        raise SystemExit(
            "gen_codex_profile_into: delegate field of unsupported type %r"
            % type(v).__name__
        )

    table_key_overrides = {"ask-claude": "claude"}
    for name in sorted(rendered.keys()):
        spec = rendered[name]
        table = table_key_overrides.get(name, name)
        print()
        print("[mcp_servers.%s]" % table)
        for field in ("command", "args", "env", "startup_timeout_sec", "tool_timeout_sec"):
            if field in spec:
                print("%s = %s" % (field, toml_value(spec[field])))


COMMANDS = {
    "hooks-json": cmd_hooks_json,
    "mcp-toml-blocks": cmd_mcp_toml_blocks,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.stderr.write(
            "usage: codex.py {%s} ...\n" % "|".join(sorted(COMMANDS))
        )
        sys.exit(2)
    COMMANDS[sys.argv[1]]()


if __name__ == "__main__":
    main()
