#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time

CONFIG = os.environ.get("CODEX_GUARD_CONFIG",
                        os.path.expanduser("~/.claude/hooks/codex_scope.json"))
AUDIT = os.environ.get("CODEX_GUARD_AUDIT",
                       os.path.expanduser("~/.claude/hooks/codex_guard_audit.jsonl"))
AUTONOMOUS_MODES = {"auto", "acceptEdits", "dontAsk"}


def _audit(decision, reason, tool, mode, tool_input):
    try:
        ti = tool_input or {}
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "decision": decision,
               "reason": reason, "tool": tool, "mode": mode, "cwd": ti.get("cwd"),
               "sandbox": ti.get("sandbox"), "approval": ti.get("approval-policy")}
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=True) + "\n")
    except Exception:
        pass


def deny(reason, tool="", mode="", tool_input=None):
    _audit("deny", reason, tool, mode, tool_input)
    print(f"[codex-mode-guard] DENY: {reason}", file=sys.stderr)
    sys.exit(2)


def allow(tool, mode, tool_input):
    _audit("allow", "", tool, mode, tool_input)
    sys.exit(0)


def _load_config():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except Exception:
        return {}


def _allowed_roots(cfg):
    roots = list(cfg.get("allowed_roots") or [])
    roots += os.environ.get("CODEX_GUARD_EXTRA_ROOTS", "").split(":")
    return [os.path.realpath(os.path.expanduser(r))
            for r in roots if isinstance(r, str) and r.strip()]


def _check_scope_and_git(cwd, tool, mode, ti, cfg):
    if not isinstance(cwd, str) or not cwd:
        deny("write-capable call must have an EXPLICIT cwd (absolute working "
             "directory of the task) — add cwd to the arguments", tool, mode, ti)
    if not os.path.isabs(cwd):
        deny("cwd must be an ABSOLUTE path (a relative one resolves against a "
             "foreign process)", tool, mode, ti)
    real = os.path.realpath(cwd)
    if not os.path.isdir(real):
        deny("cwd is not an existing directory", tool, mode, ti)
    roots = _allowed_roots(cfg)
    if not any(real == r or real.startswith(r + os.sep) for r in roots):
        deny("cwd is outside the allowed scope (codex_scope.json allowed_roots + "
             "CODEX_GUARD_EXTRA_ROOTS) - codex may write only there", tool, mode, ti)
    try:
        in_git = subprocess.run(
            ["git", "-C", real, "rev-parse", "--is-inside-work-tree"],
            capture_output=True, timeout=5).returncode == 0
    except Exception:
        in_git = False
    if not in_git:
        deny("cwd is not a git work-tree — codex changes must ALWAYS be versioned "
             "(git init in the target directory, or pick a repo)", tool, mode, ti)


def main():
    try:
        payload = json.load(sys.stdin)
        tool = payload.get("tool_name", "")
        ti = payload.get("tool_input") or {}
        mode = payload.get("permission_mode") or "default"
    except Exception as e:
        deny(f"unreadable hook payload ({type(e).__name__}) — fail-closed")

    if tool.endswith("__codex-reply"):
        if mode == "plan":
            deny("plan mode: continuing a codex thread may carry write scope — "
                 "wait until plan mode ends, or start a new read-only thread",
                 tool, mode, ti)
        allow(tool, mode, ti)

    approval = ti.get("approval-policy")
    sandbox = ti.get("sandbox")
    cfg = _load_config()
    in_container = "CODEX_GUARD_EXTRA_ROOTS" in os.environ
    danger_ok = cfg.get("allow_danger_full_access") is True or in_container
    write_capable = sandbox != "read-only"
    if danger_ok and not write_capable:
        write_capable = True

    if in_container and mode == "plan":
        deny("plan mode in the container has no working codex path (read-only "
             "dies on bwrap, full access is denied by the plan gate) — defer "
             "the codex call until plan mode ends", tool, mode, ti)

    if write_capable:
        _check_scope_and_git(ti.get("cwd"), tool, mode, ti, cfg)

    if in_container and sandbox != "danger-full-access":
        deny("container: sandbox must be danger-full-access (the container is "
             "the boundary; read-only and workspace-write die on bwrap and make "
             "codex escalate via an Accept/Decline elicitation) — re-issue with "
             "sandbox=danger-full-access", tool, mode, ti)

    if (mode in AUTONOMOUS_MODES or mode == "bypassPermissions") \
            and approval != "never":
        deny(f"unattended mode ({mode}): approval-policy must be 'never' — "
             "anything else makes codex elicit a human Accept/Decline answer "
             "that nobody is there to give, so the run hangs on it — re-issue "
             "with approval-policy=never", tool, mode, ti)

    if mode == "bypassPermissions":
        allow(tool, mode, ti)

    if sandbox == "danger-full-access" and not danger_ok:
        deny("sandbox=danger-full-access is allowed only in bypassPermissions mode "
             "(or in an environment whose scope config sets "
             "allow_danger_full_access=true, e.g. the cbox container)",
             tool, mode, ti)

    if mode == "plan":
        if sandbox != "read-only":
            deny("plan mode: only sandbox=read-only is allowed — re-issue the call "
                 "with codex-mode: read-only (never + read-only)", tool, mode, ti)
        allow(tool, mode, ti)

    if mode in AUTONOMOUS_MODES:
        allow(tool, mode, ti)

    if approval == "never" and sandbox != "read-only":
        deny("default mode: approval-policy=never with a write sandbox is not "
             "allowed — re-issue with codex-mode: ask (on-request + workspace-write) "
             "or read-only", tool, mode, ti)
    allow(tool, mode, ti)


main()
