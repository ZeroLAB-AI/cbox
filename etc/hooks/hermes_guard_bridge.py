#!/usr/bin/env python3
import json
import os
import subprocess
import sys

GUARD_TIMEOUT = 5


def _guard_dir():
    return os.path.dirname(os.path.abspath(__file__))


def _run_guard(name, payload_bytes):
    path = os.path.join(_guard_dir(), name)
    r = subprocess.run(
        [sys.executable, path],
        input=payload_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=GUARD_TIMEOUT,
    )
    return r.returncode, r.stdout, r.stderr


def _allow(note=None):
    if note:
        sys.stderr.write(note + "\n")
    sys.exit(0)


def _block(reason):
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}) + "\n")
    sys.exit(0)


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw)

    if payload.get("hook_event_name") != "pre_tool_call":
        return _allow()
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return _allow()
    if tool_name == "terminal":
        command = tool_input.get("command")
    elif tool_name == "process":
        if tool_input.get("action") not in ("write", "submit"):
            return _allow()
        command = tool_input.get("data")
    else:
        return _allow()
    if not isinstance(command, str) or not command:
        return _allow()

    cwd = payload.get("cwd") or ""
    claude_shaped = {
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": cwd,
    }
    payload_bytes = json.dumps(claude_shaped).encode("utf-8")

    rc, out, err = _run_guard("rm_glob_guard.py", payload_bytes)
    if rc == 2:
        reason = err.decode("utf-8", "replace").strip() or "rm-glob-guard denied this command"
        return _block(reason)

    rc2, out2, err2 = _run_guard("commit_guard.py", payload_bytes)
    note = None
    if out2:
        try:
            decoded = json.loads(out2.decode("utf-8", "replace"))
            reason = (decoded.get("hookSpecificOutput") or {}).get("permissionDecisionReason")
            if reason:
                note = "hermes_guard_bridge: commit_guard advisory (not blocking): %s" % reason
        except Exception:
            pass

    return _allow(note)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        sys.stderr.write(
            "hermes_guard_bridge: internal error, degrading to allow (fail-open armor): %r\n" % (e,)
        )
        sys.exit(0)
