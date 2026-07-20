#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import sys
import time

SERVER_NAME = "cbox-ask-claude"
SERVER_VERSION = "0.2.0"
DEFAULT_PROTOCOL = "2024-11-05"
DEPTH_VAR = "CBOX_DELEGATION_DEPTH"
LEGACY_DEPTH_VAR = "CBOX_MCP_DEPTH"
DOCKERENV_PATH = "/.dockerenv"
SCOPE_CONFIG = os.environ.get(
    "CODEX_GUARD_CONFIG",
    os.path.expanduser("~/.claude/hooks/codex_scope.container.json"))
AUDIT = os.environ.get(
    "ASK_CLAUDE_AUDIT",
    os.path.expanduser("~/.claude/ask_claude_audit.container.jsonl"))
CALL_TIMEOUT = int(os.environ.get("ASK_CLAUDE_TIMEOUT", "3300"))
AUDIT_MAX_BYTES = 5000000
QA_ALLOWED = "Read,Grep,Glob"
QA_DISALLOWED = "Bash,Edit,Write,NotebookEdit,Task,WebFetch,WebSearch"
CWD_ALLOWED = "Read,Grep,Glob,Edit,Write,NotebookEdit"
CWD_DISALLOWED = "Bash,Task,WebFetch,WebSearch"
EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")
MODE_LEVELS = ("analyse", "plan", "full")
MODE_PROMPT = {
    "analyse": ("You are in analyse mode: read and investigate only, make "
                "no modifications, return findings."),
    "plan": ("You are in plan mode: produce an implementation plan only, "
             "make no modifications."),
}


def in_container():
    return os.path.exists(DOCKERENV_PATH) \
        and os.environ.get("CBOX_RUNTIME") == "container"


def depth_reached():
    return bool(os.environ.get(DEPTH_VAR) or os.environ.get(LEGACY_DEPTH_VAR))


def default_mode():
    mode = os.environ.get("CBOX_AI_MODE")
    if mode in MODE_LEVELS:
        return mode
    return "full"


def tool_description():
    if in_container():
        delegation_note = (
            "Delegation is pre-authorized inside this container: no need "
            "to ask the user first before calling this tool. This call "
            "runs to completion before returning; your session may wait on "
            "its result, but if the user sends anything while it is "
            "pending, react to the user first rather than staying blocked.")
    else:
        delegation_note = (
            "Every call spends the Claude subscription: propose the "
            "delegation and ask the user first, never delegate "
            "automatically.")
    return (
        "Delegate one task to a Claude model via Claude Code print mode. "
        "Without cwd the run is question-answering only (read-only tools, "
        "no shell, no file writes). With cwd the run is a file-editing "
        "delegate working inside that directory; cwd must be an absolute "
        "path inside the allowed workspace scope and a git work-tree. "
        "mode selects the delegate's authority with cwd: analyse and plan "
        "are read-only (investigate or produce a plan, no modifications); "
        "full allows edits and, inside the cbox container, runs with full "
        "permissions bypassed. " + delegation_note)


def build_tool():
    return {
        "name": "ask-claude",
        "description": tool_description(),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "The task or question for Claude."},
                "model": {
                    "type": "string",
                    "default": "sonnet",
                    "description": ("Model alias (haiku, sonnet, opus, "
                                    "fable) or a full model name.")},
                "effort": {
                    "type": "string",
                    "enum": list(EFFORT_LEVELS),
                    "description": ("Reasoning effort tier; omit for the "
                                    "model default.")},
                "mode": {
                    "type": "string",
                    "enum": list(MODE_LEVELS),
                    "description": ("analyse (read-only investigation), "
                                    "plan (read-only planning), or full "
                                    "(edits allowed). Defaults to the "
                                    "CBOX_AI_MODE env var, else full.")},
                "cwd": {
                    "type": "string",
                    "description": ("Absolute working directory for an "
                                    "agentic run; omit for pure "
                                    "question-answering.")},
                "max_turns": {
                    "type": "integer",
                    "default": 30,
                    "minimum": 1,
                    "maximum": 200,
                    "description": "Agentic turn budget."},
            },
            "required": ["prompt"],
        },
    }


AUDIT_LINE_MAX = 2048


def audit_text(value, limit=128):
    if not isinstance(value, str):
        return None
    text = "".join(ch for ch in value if ch.isprintable())
    return text[:limit]


def audit_digest(value):
    if not isinstance(value, str):
        return None
    return hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()[:16]


def audit(decision, reason, args, mode):
    try:
        os.makedirs(os.path.dirname(AUDIT), exist_ok=True)
        if os.path.isfile(AUDIT) and os.path.getsize(AUDIT) > AUDIT_MAX_BYTES:
            os.replace(AUDIT, AUDIT + ".1")
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "decision": audit_text(decision, 16),
               "reason": audit_text(reason, 128),
               "model": audit_text(args.get("model"), 80),
               "cwd_sha256": audit_digest(args.get("cwd")),
               "max_turns": args.get("max_turns")
               if isinstance(args.get("max_turns"), int) else None,
               "mode": audit_text(mode, 16),
               "runtime": "container" if in_container() else "host"}
        line = json.dumps(rec, ensure_ascii=True)
        if len(line.encode("utf-8")) > AUDIT_LINE_MAX:
            line = json.dumps(
                {"ts": rec["ts"], "event": "audit-record-truncated"},
                ensure_ascii=True)
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(line + "\n")
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
    if depth_reached():
        audit("deny", "depth limit", args, None)
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
    if effort is not None and effort not in EFFORT_LEVELS:
        return tool_text("ask-claude refused: effort must be one of "
                         "low, medium, high, xhigh, max", True)
    mode = args.get("mode") or default_mode()
    if mode not in MODE_LEVELS:
        return tool_text("ask-claude refused: mode must be one of "
                         "analyse, plan, full", True)
    max_turns = args.get("max_turns")
    if max_turns is None:
        max_turns = 50 if mode == "full" else 30
    if not isinstance(max_turns, int) or not 1 <= max_turns <= 200:
        return tool_text("ask-claude refused: max_turns must be an integer "
                         "between 1 and 200", True)

    cwd = args.get("cwd")
    if cwd is not None and not isinstance(cwd, str):
        return tool_text("ask-claude refused: cwd must be a string", True)

    run_dir = None
    if cwd:
        real, reason = check_cwd(cwd)
        if reason:
            audit("deny", reason, args, mode)
            return tool_text("ask-claude refused: " + reason, True)
        run_dir = real

    cmd = ["claude", "-p", prompt,
           "--output-format", "json",
           "--model", model]
    if effort:
        cmd += ["--effort", effort]

    if run_dir is not None:
        cmd += ["--max-turns", str(max_turns)]
        if in_container() and mode == "full":
            cmd += ["--dangerously-skip-permissions"]
        elif in_container() and mode in ("analyse", "plan"):
            cmd += ["--permission-mode", "plan",
                    "--append-system-prompt", MODE_PROMPT[mode]]
        else:
            cmd += ["--strict-mcp-config", "--mcp-config",
                    '{"mcpServers":{}}',
                    "--permission-mode", "acceptEdits",
                    "--allowedTools", CWD_ALLOWED,
                    "--disallowedTools", CWD_DISALLOWED]
            if mode in ("analyse", "plan"):
                cmd += ["--append-system-prompt", MODE_PROMPT[mode]]
    else:
        run_dir = os.path.expanduser("~")
        cmd += ["--max-turns", str(max_turns),
               "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
               "--allowedTools", QA_ALLOWED,
               "--disallowedTools", QA_DISALLOWED]

    env = dict(os.environ)
    env[DEPTH_VAR] = "1"
    env[LEGACY_DEPTH_VAR] = "1"

    audit("allow", "", args, mode)
    try:
        proc = subprocess.run(cmd, cwd=run_dir, env=env,
                              capture_output=True, text=True,
                              timeout=CALL_TIMEOUT)
    except subprocess.TimeoutExpired:
        audit("error", "timeout", args, mode)
        return tool_text(
            f"ask-claude failed: claude run exceeded {CALL_TIMEOUT}s", True)
    except FileNotFoundError:
        audit("error", "claude binary not found", args, mode)
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
        audit("error", "unparseable claude output", args, mode)
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
        reply(req_id, {"tools": [build_tool()]})
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
