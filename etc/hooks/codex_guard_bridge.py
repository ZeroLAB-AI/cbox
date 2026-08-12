import json
import os
import subprocess
import sys

SPEC_PAYLOAD_SHAPE = {
    "provenance": "spec",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": "string"},
    "session_id": "string",
    "turn_id": "string",
    "tool_use_id": "string",
    "cwd": "string",
    "transcript_path": "string|null",
    "model": "string",
}

SPEC_DENY_SHAPE = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "string",
    }
}

RM_GLOB_GUARD = "rm_glob_guard.py"
COMMIT_GUARD = "commit_guard.py"


def hooks_dir():
    return os.path.dirname(os.path.realpath(__file__))


def to_claude_shaped_stdin(codex_payload):
    tool_input = codex_payload.get("tool_input") or {}
    command = tool_input.get("command") or ""
    return {
        "tool_name": codex_payload.get("tool_name") or "Bash",
        "tool_input": {"command": command},
        "cwd": codex_payload.get("cwd") or "",
    }


def run_guard(script_name, claude_stdin):
    path = os.path.join(hooks_dir(), script_name)
    payload = json.dumps(claude_stdin).encode("utf-8")
    proc = subprocess.run(
        [sys.executable or "python3", path],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    return proc.returncode, proc.stdout.decode("utf-8", "replace"), proc.stderr.decode("utf-8", "replace")


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def allow_passthrough(note):
    if note:
        sys.stderr.write(note + "\n")
    sys.exit(0)


def main():
    codex_payload = json.load(sys.stdin)
    if codex_payload.get("tool_name") != "Bash":
        allow_passthrough("")
        return
    claude_stdin = to_claude_shaped_stdin(codex_payload)

    rc, out, err = run_guard(RM_GLOB_GUARD, claude_stdin)
    if rc == 2:
        reason = err.strip() or "rm_glob_guard denied this command"
        deny(reason)

    rc2, out2, err2 = run_guard(COMMIT_GUARD, claude_stdin)
    advisory = out2.strip()
    allow_passthrough(advisory if advisory else "")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        allow_passthrough("codex_guard_bridge: internal error, allowing (fail-open, matches wrapped guards): %s" % exc)
