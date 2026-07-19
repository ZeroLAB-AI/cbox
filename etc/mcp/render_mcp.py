#!/usr/bin/env python3
import json
import os
import sys


ADAPTERS = ("codex-mcp", "stdio-mcp", "claude-cli")
TARGETS = ("claude", "codex")


class DelegateEntryError(Exception):
    pass


def _cbox_block(name, spec):
    cbox = spec.get("_cbox")
    if not isinstance(cbox, dict):
        raise DelegateEntryError(
            "render_mcp.py: delegate entry %r has no _cbox block - "
            "refusing to ship it" % name
        )
    return cbox


def _adapter_of(name, spec):
    cbox = _cbox_block(name, spec)
    adapter = cbox.get("adapter")
    if adapter not in ADAPTERS:
        raise DelegateEntryError(
            "render_mcp.py: delegate entry %r has unknown or missing "
            "adapter %r - refusing to ship it" % (name, adapter)
        )
    if adapter == "codex-mcp" and not name.startswith("codex-"):
        raise DelegateEntryError(
            "render_mcp.py: delegate entry %r uses adapter codex-mcp but "
            "its name does not start with codex- - refusing to ship it "
            "(would bypass the entrypoint boot gate and the mode guard)"
            % name
        )
    if name.startswith("codex-") and adapter != "codex-mcp":
        raise DelegateEntryError(
            "render_mcp.py: delegate entry %r is named codex-* but its "
            "adapter is %r, not codex-mcp - refusing to ship it (would "
            "brick claude startup, the boot gate requires every codex-* "
            "server to be shim-wrapped)" % (name, adapter)
        )
    return adapter, cbox


def wrap_codex_entry(name, spec, cbox, hooks_dir, shim_mode):
    model = cbox.get("model")
    effort = cbox.get("model_reasoning_effort")
    if not isinstance(model, str) or not isinstance(effort, str):
        raise DelegateEntryError(
            "render_mcp.py: codex entry %r has a malformed _cbox block "
            "(model and model_reasoning_effort must both be strings) - "
            "refusing to ship it unwrapped" % name
        )
    base = dict(spec)
    base.pop("_cbox", None)
    child_args = list(base.get("args") or [])
    child_command = base.get("command", "codex")
    args = [
        hooks_dir + "/codex_mcp_shim.py",
        "--tier",
        name,
        "--model",
        model,
        "--effort",
        effort,
        "--progress",
        "on" if shim_mode == "on" else "off",
        "--",
        child_command,
    ] + child_args
    base["command"] = "python3"
    base["args"] = args
    return base


def _substitute_env_placeholders(entry):
    env = entry.get("env")
    if not isinstance(env, dict):
        return
    resolved = {}
    for key, value in env.items():
        if isinstance(value, str) and value.startswith("@") \
                and value.endswith("@") and len(value) > 2:
            src_var = value[1:-1]
            resolved[key] = os.environ.get(src_var, "")
        else:
            resolved[key] = value
    entry["env"] = resolved


def render_stdio_entry(name, spec):
    entry = dict(spec)
    entry.pop("_cbox", None)
    _substitute_env_placeholders(entry)
    return entry


def render_claude_cli_entry(name, cbox, hooks_dir):
    command = cbox.get("command")
    script = cbox.get("script")
    if not isinstance(command, str) or not isinstance(script, str):
        raise DelegateEntryError(
            "render_mcp.py: claude-cli entry %r has a malformed _cbox "
            "block (command and script must both be strings) - refusing "
            "to ship it" % name
        )
    entry = {
        "command": command,
        "args": [hooks_dir + "/" + script],
    }
    if "startup_timeout_sec" in cbox:
        entry["startup_timeout_sec"] = cbox["startup_timeout_sec"]
    if "tool_timeout_sec" in cbox:
        entry["tool_timeout_sec"] = cbox["tool_timeout_sec"]
    return entry


def _env_gate_satisfied(cbox):
    gate = cbox.get("enabled_when_env")
    if not gate:
        return True
    return bool(os.environ.get(gate, "").strip())


def render(delegates, selection, hooks_dir, shim_mode, target, explicit=None):
    if target not in TARGETS:
        raise DelegateEntryError(
            "render_mcp.py: target must be one of %s, got %r"
            % (", ".join(TARGETS), target)
        )
    chosen = {}
    for name, spec in delegates.items():
        if name not in selection:
            continue
        if not isinstance(spec, dict):
            raise DelegateEntryError(
                "render_mcp.py: delegate entry %r is not an object - "
                "refusing to ship it" % name
            )
        adapter, cbox = _adapter_of(name, spec)
        available_to = cbox.get("available_to")
        if not isinstance(available_to, list) or not available_to:
            raise DelegateEntryError(
                "render_mcp.py: delegate entry %r has no available_to "
                "list - refusing to ship it" % name
            )
        if target not in available_to:
            continue
        if not _env_gate_satisfied(cbox):
            gate = cbox.get("enabled_when_env")
            if explicit is not None and name in explicit:
                raise DelegateEntryError(
                    "render_mcp.py: delegate entry %r was explicitly "
                    "selected but %s is not set - it cannot run "
                    "unconfigured; see cbox/etc/docs/LOCAL_MODEL_RUNBOOK.md"
                    % (name, gate)
                )
            continue
        if adapter == "codex-mcp":
            chosen[name] = wrap_codex_entry(name, spec, cbox, hooks_dir, shim_mode)
        elif adapter == "stdio-mcp":
            chosen[name] = render_stdio_entry(name, spec)
        elif adapter == "claude-cli":
            chosen[name] = render_claude_cli_entry(name, cbox, hooks_dir)
    return chosen


def main():
    if len(sys.argv) not in (5, 6):
        sys.stderr.write(
            "usage: render_mcp.py <delegates.json> <selection-space-separated> "
            "<hooks-dir> <shim-mode:on|off> [target:claude|codex]\n"
        )
        return 2
    servers_path, selection_raw, hooks_dir, shim_mode = sys.argv[1:5]
    target = sys.argv[5] if len(sys.argv) == 6 else "claude"
    with open(servers_path) as fh:
        delegates = json.load(fh)
    is_all = not selection_raw.split() or selection_raw.strip() == "all"
    explicit = None if is_all else set(selection_raw.split())
    selection = set(delegates.keys()) if is_all else set(selection_raw.split())
    if shim_mode not in ("on", "off"):
        sys.stderr.write("render_mcp.py: shim-mode must be 'on' or 'off'\n")
        return 2
    try:
        chosen = render(delegates, selection, hooks_dir, shim_mode, target, explicit)
    except DelegateEntryError as e:
        sys.stderr.write(str(e) + "\n")
        return 1
    sys.stdout.write(json.dumps(chosen, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
