import json
import os
from pathlib import Path
import subprocess
import sys

import rm_glob_guard


WORKSPACE = Path(os.environ.get("CBOX_RUNTIME_WORKSPACE", "/workspace")).resolve()
MAX_HOOK_BYTES = 1024 * 1024
PATH_ARGS = {
    "run_command": "Cwd",
    "view_file": "AbsolutePath",
    "write_to_file": "TargetFile",
    "replace_file_content": "TargetFile",
    "multi_replace_file_content": "TargetFile",
    "list_dir": "DirectoryPath",
    "find_by_name": "SearchDirectory",
    "grep_search": "SearchPath",
}


def workspace_contains(value):
    if not isinstance(value, str) or not value or "\0" in value:
        return False
    path = Path(value)
    return path.is_absolute() and path.resolve().is_relative_to(WORKSPACE)


def pre_tool(payload):
    tool = payload.get("toolCall")
    if not isinstance(tool, dict) or not isinstance(tool.get("name"), str) or not isinstance(tool.get("args"), dict):
        return {"decision": "deny", "reason": "Invalid tool call from the engine"}
    name = tool["name"]
    args = tool["args"]
    if name in PATH_ARGS and not workspace_contains(args.get(PATH_ARGS[name])):
        return {"decision": "deny", "reason": "Tool path must resolve inside the workspace"}
    if name == "run_command":
        command = args.get("CommandLine")
        if not isinstance(command, str) or not command or "\0" in command:
            return {"decision": "deny", "reason": "Invalid command line"}
        try:
            rm_glob_guard.check(command)
        except SystemExit:
            return {"decision": "deny", "reason": "Command rejected by the CBOX rm guard"}
    return {"decision": "allow"}


def session_start(payload):
    roots = payload.get("workspacePaths")
    if not isinstance(roots, list) or not roots or not all(workspace_contains(root) for root in roots):
        return {}
    loader = Path(__file__).with_name("continuity_session_start.py")
    result = subprocess.run([sys.executable, str(loader)], cwd=WORKSPACE, text=True,
                            input=json.dumps({"cwd": str(WORKSPACE), "source": "startup"}),
                            stdout=subprocess.PIPE, check=True, timeout=10)
    if not result.stdout.strip():
        return {}
    return {"injectSteps": [{"systemMessage": {"systemMessage": result.stdout}}]}


def main():
    preflight = sys.argv[1:] == ["pre-tool"]
    try:
        raw = sys.stdin.buffer.read(MAX_HOOK_BYTES + 1)
        if len(raw) > MAX_HOOK_BYTES:
            raise ValueError("oversized hook input")
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("hook payload must be an object")
        reply = pre_tool(payload) if preflight else session_start(payload)
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError):
        reply = {"decision": "deny", "reason": "CBOX could not validate the tool call"} if preflight else {}
    print(json.dumps(reply))


if __name__ == "__main__":
    main()
