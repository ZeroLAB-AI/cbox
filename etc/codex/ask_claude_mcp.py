#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time

SERVER_NAME = "cbox-ask-claude"
SERVER_VERSION = "0.1.0"
DEFAULT_PROTOCOL = "2024-11-05"
DEPTH_VAR = "CBOX_MCP_DEPTH"
SCOPE_CONFIG = os.environ.get(
    "CODEX_GUARD_CONFIG",
    os.path.expanduser("~/.claude/hooks/codex_scope.container.json"))
AUDIT = os.environ.get(
    "ASK_CLAUDE_AUDIT",
    os.path.expanduser("~/.claude/ask_claude_audit.container.jsonl"))
CALL_TIMEOUT = 570
AUDIT_MAX_BYTES = 5000000
QA_ALLOWED = "Read,Grep,Glob"
QA_DISALLOWED = "Bash,Edit,Write,NotebookEdit,Task,WebFetch,WebSearch"
CWD_ALLOWED = "Read,Grep,Glob,Edit,Write,NotebookEdit"
CWD_DISALLOWED = "Bash,Task,WebFetch,WebSearch"
THINKING_BUDGET = {"low": 1024, "medium": 8192, "high": 16384, "max": 31999}

TOOL = {
    "name": "ask-claude",
    "description": (
        "Delegate one task to a Claude model via Claude Code print mode. "
        "Without cwd the run is question-answering only (read-only tools, "
        "no shell, no file writes). With cwd the run is a file-editing "
        "delegate working inside that directory (read and edit tools, no "
        "shell, no subagents); cwd must be an absolute path inside the "
        "allowed workspace scope and a git work-tree. Every call spends "
        "the Claude subscription: propose the delegation and ask the user "
        "first, never delegate automatically."),
    "inputSchema": {
        "type": "object",
        "properties": {
            "prompt": {
                "type": "string",
                "description": "The task or question for Claude."},
            "model": {
                "type": "string",
                "default": "sonnet",
                "description": ("Model alias (haiku, sonnet, opus) or a "
                                "full model name.")},
            "effort": {
                "type": "string",
                "enum": ["low", "medium", "high", "max"],
                "description": ("Thinking budget tier; omit for the "
                                "model default.")},
            "cwd": {
                "type": "string",
                "description": ("Absolute working directory for an agentic "
                                "run; omit for pure question-answering.")},
            "max_turns": {
                "type": "integer",
                "default": 30,
                "minimum": 1,
                "maximum": 100,
                "description": "Agentic turn budget."},
        },
        "required": ["prompt"],
    },
}


def audit(decision, reason, args):
    try:
        if os.path.isfile(AUDIT) and os.path.getsize(AUDIT) > AUDIT_MAX_BYTES:
            os.replace(AUDIT, AUDIT + ".1")
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "decision": decision, "reason": reason,
               "model": args.get("model"), "cwd": args.get("cwd"),
               "max_turns": args.get("max_turns")}
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=True) + "\n")
    except Exception:
        pass


def send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def reply(req_id, result):
    send({"jsonrpc": "2.0", "id": req_id, "result": result})


def reply_error(req_id, code, message):
    send({"jsonrpc": "2.0", "id": req_id,
          "error": {"code": code, "message": message}})


def tool_text(text, is_error=False):
    return {"content": [{"type": "text", "text": text}],
            "isError": is_error}


def load_scope_roots():
    try:
        with open(SCOPE_CONFIG, encoding="utf-8") as f:
            cfg = json.load(f)
        roots = cfg.get("allowed_roots") or []
        return [os.path.realpath(os.path.expanduser(r))
                for r in roots if isinstance(r, str) and r.strip()]
    except Exception:
        return None


def check_cwd(cwd):
    if not os.path.isabs(cwd):
        return None, "cwd must be an absolute path"
    real = os.path.realpath(cwd)
    if not os.path.isdir(real):
        return None, "cwd is not an existing directory"
    roots = load_scope_roots()
    if roots is None:
        return None, ("workspace scope config is missing or unreadable - "
                      "agentic runs are disabled")
    if not any(real == r or real.startswith(r + os.sep) for r in roots):
        return None, ("cwd is outside the allowed workspace scope "
                      "(codex guard allowed_roots)")
    try:
        in_git = subprocess.run(
            ["git", "-C", real, "rev-parse", "--is-inside-work-tree"],
            capture_output=True, timeout=5).returncode == 0
    except Exception:
        in_git = False
    if not in_git:
        return None, ("cwd is not a git work-tree - delegated changes "
                      "must always be versioned")
    return real, None


def run_claude(args):
    if os.environ.get(DEPTH_VAR):
        audit("deny", "depth limit", args)
        return tool_text(
            "ask-claude refused: delegation depth limit reached - a Claude "
            "instance spawned over MCP may not spawn another one", True)

    prompt = args.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return tool_text("ask-claude refused: prompt must be a non-empty "
                         "string", True)
    model = args.get("model", "sonnet")
    if not isinstance(model, str) or not model or model.startswith("-") \
            or any(ch.isspace() for ch in model):
        return tool_text("ask-claude refused: invalid model name", True)
    effort = args.get("effort")
    if effort is not None and effort not in THINKING_BUDGET:
        return tool_text("ask-claude refused: effort must be one of "
                         "low, medium, high, max", True)
    max_turns = args.get("max_turns", 30)
    if not isinstance(max_turns, int) or not 1 <= max_turns <= 100:
        return tool_text("ask-claude refused: max_turns must be an integer "
                         "between 1 and 100", True)

    cmd = ["claude", "-p", prompt,
           "--output-format", "json",
           "--model", model,
           "--max-turns", str(max_turns),
           "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    cwd = args.get("cwd")
    if cwd:
        if not isinstance(cwd, str):
            return tool_text("ask-claude refused: cwd must be a string",
                             True)
        real, reason = check_cwd(cwd)
        if reason:
            audit("deny", reason, args)
            return tool_text("ask-claude refused: " + reason, True)
        run_dir = real
        cmd += ["--permission-mode", "acceptEdits",
                "--allowedTools", CWD_ALLOWED,
                "--disallowedTools", CWD_DISALLOWED]
    else:
        run_dir = os.path.expanduser("~")
        cmd += ["--allowedTools", QA_ALLOWED,
                "--disallowedTools", QA_DISALLOWED]

    env = dict(os.environ)
    env[DEPTH_VAR] = "1"
    if effort:
        env["MAX_THINKING_TOKENS"] = str(THINKING_BUDGET[effort])

    audit("allow", "", args)
    try:
        proc = subprocess.run(cmd, cwd=run_dir, env=env,
                              capture_output=True, text=True,
                              timeout=CALL_TIMEOUT)
    except subprocess.TimeoutExpired:
        audit("error", "timeout", args)
        return tool_text(
            f"ask-claude failed: claude run exceeded {CALL_TIMEOUT}s", True)
    except FileNotFoundError:
        audit("error", "claude binary not found", args)
        return tool_text("ask-claude failed: claude binary not found", True)

    try:
        out = json.loads(proc.stdout)
        text = out.get("result") or ""
        is_error = bool(out.get("is_error")) or proc.returncode != 0
        if is_error and not text:
            text = "claude run failed"
            errors = out.get("errors")
            if errors:
                text += ": " + "; ".join(str(e) for e in errors[:3])
        return tool_text(text, is_error)
    except ValueError:
        tail = (proc.stdout or proc.stderr or "").strip()[-2000:]
        if proc.returncode == 0 and tail:
            return tool_text(tail)
        audit("error", "unparseable claude output", args)
        return tool_text(
            "ask-claude failed: unparseable claude output"
            + (": " + tail if tail else ""), True)


def handle(msg):
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        params = msg.get("params") or {}
        proto = params.get("protocolVersion")
        if not isinstance(proto, str) or not proto:
            proto = DEFAULT_PROTOCOL
        reply(req_id, {
            "protocolVersion": proto,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME,
                           "version": SERVER_VERSION}})
    elif method == "ping":
        reply(req_id, {})
    elif method == "tools/list":
        reply(req_id, {"tools": [TOOL]})
    elif method == "tools/call":
        params = msg.get("params") or {}
        if params.get("name") != "ask-claude":
            reply_error(req_id, -32602,
                        "unknown tool: " + str(params.get("name")))
            return
        reply(req_id, run_claude(params.get("arguments") or {}))
    elif req_id is not None:
        reply_error(req_id, -32601, "method not found: " + str(method))


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None,
                  "error": {"code": -32700, "message": "parse error"}})
            continue
        try:
            handle(msg)
        except Exception as e:
            if msg.get("id") is not None:
                reply_error(msg.get("id"), -32603,
                            "internal error: " + type(e).__name__)


main()
