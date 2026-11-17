#!/usr/bin/env python3
import json
import shlex
import sys
import tomllib


def toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "[" + ", ".join(toml_value(item) for item in v) + "]"
    if isinstance(v, dict):
        pairs = ", ".join(
            "%s = %s" % (json.dumps(k), toml_value(val))
            for k, val in v.items()
        )
        return "{ " + pairs + " }"
    raise ValueError("unsupported TOML value %r" % type(v).__name__)


def cmd_settings_layers():
    with open(sys.argv[2], "rb") as stream:
        config = tomllib.load(stream)
    hooks_path, outdir = sys.argv[3:5]
    preferences = {key: config.pop(key) for key in (
        "model", "model_reasoning_effort", "hide_agent_reasoning", "tui"
    ) if key in config}
    gate = "on" if config.get("features", {}).get("codex_hooks") else "off"
    hooks = hooks_document(hooks_path, gate)["hooks"]
    requirements = {
        "allowed_approval_policies": ["never"],
        "allowed_sandbox_modes": ["danger-full-access"],
        "default_permissions": ":danger-full-access",
        "allowed_permission_profiles": {":danger-full-access": True},
        "allow_managed_hooks_only": True,
        "features": {"hooks": True},
        "hooks": dict(managed_dir=hooks_path, **hooks),
        "mcp_servers": {},
    }
    for name, spec in config.get("mcp_servers", {}).items():
        spec["enabled"] = True
        requirements["mcp_servers"][name] = {"identity": {"command": {
            "executable": spec["command"],
            "args": [{"match": "exact", "value": arg} for arg in spec.get("args", [])],
        }}}
    for name, doc in (("defaults.toml", preferences),
                      ("managed_config.toml", config),
                      ("requirements.toml", requirements)):
        with open(outdir + "/" + name, "w", encoding="ascii") as stream:
            for key, value in doc.items():
                stream.write("%s = %s\n" % (json.dumps(key), toml_value(value)))


def hooks_document(hooks_path, codex_hooks_gate):
    command = "python3 " + shlex.quote(hooks_path + "/continuity_session_start.py")
    events = {
        "SessionStart": [
            {"hooks": [{"type": "command", "command": command}]}
        ]
    }
    if codex_hooks_gate == "on":
        bridge_command = "python3 " + shlex.quote(hooks_path + "/codex_guard_bridge.py")
        events["PreToolUse"] = [
            {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": bridge_command}],
            }
        ]
    return {"hooks": events}


def cmd_hooks_json():
    doc = hooks_document(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "off")
    sys.stdout.write(json.dumps(doc, indent=2) + "\n")


def cmd_mcp_toml_blocks():
    rendered = json.loads(sys.argv[2])

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
    "settings-layers": cmd_settings_layers,
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
