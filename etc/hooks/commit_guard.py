import json
import os
import re
import subprocess
import sys

AUTH_RE = re.compile(r"auth|login|token|password|secret|credential|api[_-]?key|"
                     r"permission|endpoint|route|input|sanitiz", re.IGNORECASE)


def current_branch(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                           capture_output=True, timeout=5)
        if r.returncode == 0:
            return r.stdout.decode("utf-8", "replace").strip()
    except Exception:
        pass
    return ""


def staged_touches_auth(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "diff", "--cached", "--name-only"],
                           capture_output=True, timeout=5)
        if r.returncode == 0:
            return AUTH_RE.search(r.stdout.decode("utf-8", "replace")) is not None
    except Exception:
        pass
    return False


def warn(msg):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": msg,
        }
    }))
    sys.exit(0)


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not re.search(r"\bgit\s+commit\b", cmd):
        return
    cwd = data.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    notes = []
    br = current_branch(cwd)
    if br and br != "main" and not br.startswith("wave") and "worktree" not in br:
        notes.append("main-only policy: committing on branch '%s' (not main) - fold and delete temporary branches after merge" % br)
    if staged_touches_auth(cwd):
        notes.append("routing policy: staged changes touch auth/API/input - run the security-reviewer subagent and fix CRITICAL/HIGH before this commit lands")
    if notes:
        warn(" | ".join(notes))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
