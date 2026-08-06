#!/usr/bin/env python3
import glob
import json
import os
import re
import sys


ADAPTERS = ("codex-mcp", "stdio-mcp", "claude-cli")
TARGETS = ("claude", "codex", "hermes")


class DelegateEntryError(Exception):
    pass


class UserEntryError(DelegateEntryError):
    pass


USER_ENV_KEY_OK_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")

USER_ENV_KEY_DENY_RE = re.compile(
    r"^(LD_|PYTHON|NODE_|BASH_ENV$|ENV$|IFS$|PATH$|HOME$|XDG_|"
    r"[A-Z_]*_PROXY$|CODEX_|CBOX_|CLAUDE_|ANTHROPIC_|HERMES_)"
)

USER_ENV_VALUE_PLACEHOLDER_RE = re.compile(r"@[^@]+@")

USER_ESCALATION_TOKENS = (
    "--dangerously",
    "danger-full-access",
    "approval_policy",
    "bypasspermissions",
    "--ignore-rules",
    "--yolo",
)

USER_TOP_LEVEL_KEYS = ("type", "command", "args", "env", "_cbox")
USER_CBOX_KEYS = ("adapter", "available_to", "enabled_when_env")


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


def render_stdio_entry(name, spec, hooks_dir):
    entry = dict(spec)
    entry.pop("_cbox", None)
    if entry.get("command") == "python3":
        args = list(entry.get("args") or [])
        if args and not os.path.isabs(args[0]):
            args[0] = hooks_dir + "/" + args[0]
        entry["args"] = args
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


def render_hermes_entry(name, spec, cbox, hooks_dir, shim_mode, adapter, enabled):
    if adapter == "codex-mcp":
        entry = wrap_codex_entry(name, spec, cbox, hooks_dir, shim_mode)
    elif adapter == "stdio-mcp":
        entry = render_stdio_entry(name, spec, hooks_dir)
    elif adapter == "claude-cli":
        entry = render_claude_cli_entry(name, cbox, hooks_dir)
    else:
        raise DelegateEntryError(
            "render_mcp.py: delegate entry %r has adapter %r which the "
            "hermes target does not know how to render" % (name, adapter)
        )
    hermes_entry = {
        "command": entry["command"],
        "args": entry.get("args", []),
    }
    if entry.get("env"):
        hermes_entry["env"] = entry["env"]
    timeout_sec = spec.get("tool_timeout_sec", cbox.get("tool_timeout_sec"))
    if isinstance(timeout_sec, int):
        hermes_entry["timeout"] = timeout_sec
    connect_timeout_sec = spec.get(
        "startup_timeout_sec", cbox.get("startup_timeout_sec")
    )
    if isinstance(connect_timeout_sec, int):
        hermes_entry["connect_timeout"] = connect_timeout_sec
    if not enabled:
        hermes_entry["enabled"] = False
    return hermes_entry


FALSY_GATE_VALUES = ("", "off", "0", "false", "no")


def _env_gate_satisfied(cbox):
    gate = cbox.get("enabled_when_env")
    if not gate:
        return True
    return os.environ.get(gate, "").strip().lower() not in FALSY_GATE_VALUES


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
        gate_ok = _env_gate_satisfied(cbox)
        if not gate_ok:
            gate = cbox.get("enabled_when_env")
            if explicit is not None and name in explicit:
                raise DelegateEntryError(
                    "render_mcp.py: delegate entry %r was explicitly "
                    "selected but %s is not set - it cannot run "
                    "unconfigured; see cbox/etc/docs/LOCAL_MODEL_RUNBOOK.md"
                    % (name, gate)
                )
            if target != "hermes":
                continue
        if target == "hermes":
            chosen[name] = render_hermes_entry(
                name, spec, cbox, hooks_dir, shim_mode, adapter, gate_ok
            )
        elif adapter == "codex-mcp":
            chosen[name] = wrap_codex_entry(name, spec, cbox, hooks_dir, shim_mode)
        elif adapter == "stdio-mcp":
            chosen[name] = render_stdio_entry(name, spec, hooks_dir)
        elif adapter == "claude-cli":
            chosen[name] = render_claude_cli_entry(name, cbox, hooks_dir)
    return chosen


def validate_user_entry(name, spec, cbox_names, hooks_dir):
    if not isinstance(spec, dict):
        raise UserEntryError(name, "entry is not an object")

    extra_top = set(spec.keys()) - set(USER_TOP_LEVEL_KEYS)
    if extra_top:
        raise UserEntryError(
            name,
            "entry has keys outside the allowed user schema "
            "(type/command/args/env/_cbox): %s" % ", ".join(sorted(extra_top)),
        )

    lname = name.casefold()
    if lname.startswith("codex-") or lname.startswith("cbox-"):
        raise UserEntryError(
            name,
            "user mcp names may not start with 'codex-' or 'cbox-' "
            "(those prefixes are hard-coupled to cbox's shim adapter and "
            "boot/mode guards)",
        )

    if lname in {c.casefold() for c in cbox_names}:
        raise UserEntryError(
            name,
            "shadowed by cbox - rename",
        )

    cbox = spec.get("_cbox")
    if not isinstance(cbox, dict):
        raise UserEntryError(name, "entry has no _cbox block")

    extra_cbox = set(cbox.keys()) - set(USER_CBOX_KEYS)
    if extra_cbox:
        raise UserEntryError(
            name,
            "_cbox block has keys outside the allowed user schema "
            "(adapter/available_to/enabled_when_env): %s"
            % ", ".join(sorted(extra_cbox)),
        )

    adapter = cbox.get("adapter")
    if adapter != "stdio-mcp":
        raise UserEntryError(
            name,
            "user mcp entries must use adapter 'stdio-mcp' - got %r "
            "(codex-mcp and claude-cli are trust-bearing wrappers reserved "
            "for cbox delegates)" % adapter,
        )

    available_to = cbox.get("available_to")
    if not isinstance(available_to, list) or not available_to:
        raise UserEntryError(name, "_cbox.available_to must be a non-empty list")
    bad_targets = [t for t in available_to if t not in TARGETS]
    if bad_targets:
        raise UserEntryError(
            name,
            "_cbox.available_to has unknown target(s): %s"
            % ", ".join(sorted(bad_targets)),
        )

    gate = cbox.get("enabled_when_env")
    if gate is not None and not isinstance(gate, str):
        raise UserEntryError(name, "_cbox.enabled_when_env must be a string")

    command = spec.get("command")
    if not isinstance(command, str) or not command:
        raise UserEntryError(name, "entry has no command string")

    args = spec.get("args", [])
    if not isinstance(args, list) or any(not isinstance(a, str) for a in args):
        raise UserEntryError(name, "entry args must be a list of strings")

    if command == "python3":
        if args and not os.path.isabs(args[0]):
            raise UserEntryError(
                name,
                "python3 entries must use an absolute path as args[0] - a "
                "relative script would be path-joined into cbox's trusted "
                "hooks directory",
            )
    elif not os.path.isabs(command) and ("/" in command or "\\" in command):
        raise UserEntryError(
            name,
            "command must be an absolute path or a bare PATH binary name",
        )

    hooks_real = os.path.realpath(hooks_dir) if hooks_dir else None
    for token_source in [command] + args:
        if ".." in token_source:
            raise UserEntryError(
                name, "command/args must not contain '..' (path traversal)"
            )
        if hooks_real and token_source.startswith("/"):
            tsr = os.path.realpath(token_source)
            if tsr == hooks_real or tsr.startswith(hooks_real + os.sep):
                raise UserEntryError(
                    name,
                    "command/args may not reference a path under cbox's "
                    "trusted hooks directory (%s) - that would invoke a cbox "
                    "shim/relay with pinned trust flags" % hooks_real,
                )
        lowered = token_source.casefold()
        for token in USER_ESCALATION_TOKENS:
            if token in lowered:
                raise UserEntryError(
                    name,
                    "command/args contain a disallowed escalation token: %r"
                    % token,
                )

    env = spec.get("env", {})
    if not isinstance(env, dict):
        raise UserEntryError(name, "entry env must be an object")
    for key, value in env.items():
        if not isinstance(key, str):
            raise UserEntryError(name, "entry env keys must be strings")
        if not USER_ENV_KEY_OK_RE.match(key) or USER_ENV_KEY_DENY_RE.match(key):
            raise UserEntryError(
                name,
                "entry env key %r is not allowed - user mcp env keys must be "
                "plain UPPER_SNAKE names and may not be loader/proxy vars "
                "(LD_*, PYTHON*, PATH, NODE_*, BASH_ENV, *_PROXY, ...) or "
                "cbox/claude/anthropic/codex/hermes-scoped keys (those "
                "inherit cbox trust exceptions such as danger-full-access "
                "scoping or hijack the process loader)" % key,
            )
        if isinstance(value, str) and USER_ENV_VALUE_PLACEHOLDER_RE.search(value):
            raise UserEntryError(
                name,
                "entry env value for %r contains an @VAR@ host-environment "
                "placeholder - user entries may not expand host env values "
                "(that would exfiltrate host secrets like @ANTHROPIC_API_KEY@ "
                "into the rendered config)" % key,
            )

    entry_type = spec.get("type")
    if entry_type is not None and entry_type != "stdio":
        raise UserEntryError(
            name, "entry type must be 'stdio' if present - got %r" % entry_type
        )


def load_user_entries(user_dir, cbox_names, hooks_dir):
    entries = {}
    mcp_dir = os.path.join(user_dir, "mcp")
    if not os.path.isdir(mcp_dir):
        return entries
    for path in sorted(glob.glob(os.path.join(mcp_dir, "*.json"))):
        name = os.path.splitext(os.path.basename(path))[0]
        try:
            with open(path) as fh:
                spec = json.load(fh)
        except (OSError, ValueError) as e:
            sys.stderr.write(
                "render_mcp.py: user mcp entry %r (%s) could not be read/"
                "parsed - refusing it: %s\n" % (name, path, e)
            )
            continue
        try:
            validate_user_entry(name, spec, cbox_names, hooks_dir)
        except UserEntryError as e:
            reason = e.args[1] if len(e.args) > 1 else str(e)
            if reason == "shadowed by cbox - rename":
                sys.stderr.write(
                    "render_mcp.py: user mcp %r shadowed by cbox - rename\n"
                    % name
                )
            else:
                sys.stderr.write(
                    "render_mcp.py: user mcp entry %r (%s) refused: %s\n"
                    % (name, path, reason)
                )
            continue
        entries[name] = spec
    return entries


def main():
    if len(sys.argv) not in (5, 6, 7):
        sys.stderr.write(
            "usage: render_mcp.py <delegates.json> <selection-space-separated> "
            "<hooks-dir> <shim-mode:on|off> [target:claude|codex|hermes] "
            "[user-dir]\n"
        )
        return 2
    servers_path, selection_raw, hooks_dir, shim_mode = sys.argv[1:5]
    target = sys.argv[5] if len(sys.argv) >= 6 else "claude"
    user_dir = sys.argv[6] if len(sys.argv) == 7 else None
    with open(servers_path) as fh:
        delegates = json.load(fh)
    cbox_names = set(delegates.keys())
    if user_dir:
        user_entries = load_user_entries(user_dir, cbox_names, hooks_dir)
        for uname, uspec in user_entries.items():
            delegates[uname] = uspec
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
