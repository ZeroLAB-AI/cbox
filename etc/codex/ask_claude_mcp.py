#!/usr/bin/env python3
import collections
import hashlib
import json
import os
import queue
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time

SERVER_NAME = "cbox-ask-claude"
SERVER_VERSION = "0.3.0"
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
FALLBACK_MODEL_ENV = "ASK_CLAUDE_FALLBACK_MODEL"
FALLBACK_MODEL_MAP_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "ask_claude_fallback_models.json")
MODE_PROMPT = {
    "analyse": ("You are in analyse mode: read and investigate only, make "
                "no modifications, return findings."),
    "plan": ("You are in plan mode: produce an implementation plan only, "
             "make no modifications."),
}

KILL_GRACE_SEC = 3
PROGRESS_MIN_GAP_SEC = 5
PROGRESS_INTERVAL_ENV = "ASK_CLAUDE_PROGRESS_INTERVAL_SEC"
DEFAULT_PROGRESS_INTERVAL_SEC = 30.0
CANCELLED_MESSAGE = "cancelled by the client"
CANCEL_MEMORY = 256
MAX_TOKEN_LEN = 256
MAX_STDIN_LINE_BYTES = 4 * 1024 * 1024
STREAM_LINE_MAX_BYTES = 5 * 1024 * 1024
PARTIAL_OUTPUT_MAX_BYTES = 2000
MAX_STDERR_BYTES = 200000


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


SAFETY_REFUSAL_MARKERS = (
    "safety measures that flagged",
    "cyber verification program",
)


def is_safety_refusal(proc, prompt=""):
    if proc.returncode == 0:
        return False
    blob = (proc.stderr or "").lower()
    parsed = None
    try:
        parsed = json.loads(proc.stdout or "")
    except ValueError:
        parsed = None
    if isinstance(parsed, dict):
        errors = parsed.get("errors")
        if isinstance(errors, list):
            blob += "\n" + "\n".join(str(e) for e in errors[:5]).lower()
    else:
        blob += "\n" + (proc.stdout or "").lower()
    supplied = (prompt or "").lower()
    return any(marker in blob and marker not in supplied
               for marker in SAFETY_REFUSAL_MARKERS)


def valid_model_token(value):
    return isinstance(value, str) and value and not value.startswith("-") \
        and not any(ch.isspace() for ch in value)


def load_fallback_model_map():
    try:
        with open(FALLBACK_MODEL_MAP_PATH, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for key, chain in data.items():
        if not isinstance(key, str) or not isinstance(chain, list):
            continue
        clean = [m for m in chain if valid_model_token(m)]
        if clean:
            out[key] = clean
    return out


MODEL_DENY_ENV = "CBOX_AGENT_MODEL_DENY"
MODEL_BAN_ENV = "CBOX_AGENT_MODEL_BAN"


def resolve_model_alias(model):
    if isinstance(model, str) and model.isalpha():
        return os.environ.get("ANTHROPIC_DEFAULT_%s_MODEL" % model.upper()) or model
    return model


SAFETY_NOTE_RE = re.compile(r"(?m)^[ \t]*safety-fallback:")


def model_banned(model):
    ban = os.environ.get(MODEL_BAN_ENV) or ""
    if not ban:
        return None
    if isinstance(model, str) and model.isalpha() \
            and not os.environ.get("ANTHROPIC_DEFAULT_%s_MODEL" % model.upper()) \
            and re.search(re.escape(model), ban, re.IGNORECASE):
        return ("alias '%s' is not pinned (ANTHROPIC_DEFAULT_%s_MODEL unset) "
                "while the ban pattern mentions it - refusing the unresolved "
                "alias" % (model, model.upper()))
    resolved = resolve_model_alias(model)
    if re.search(ban, resolved, re.IGNORECASE):
        return ("model '%s' matches the ban pattern (%s); it has no fallback "
                "exception - use the pinned tier instead" % (resolved, MODEL_BAN_ENV))
    return None


def model_refusal(model, prompt):
    banned = model_banned(model)
    if banned:
        return banned
    resolved = resolve_model_alias(model)
    deny = os.environ.get(MODEL_DENY_ENV) or ""
    if deny and re.search(deny, resolved, re.IGNORECASE) \
            and not SAFETY_NOTE_RE.search(prompt or ""):
        return ("model '%s' matches the deny pattern (%s); it is allowed only as a "
                "safety fallback - retry with a 'safety-fallback:' note at the "
                "start of a line in the prompt" % (resolved, MODEL_DENY_ENV))
    return None


def default_fallback_chain(model):
    chain = load_fallback_model_map().get(model)
    return list(chain) if chain else []


def resolve_fallback_models(model):
    override = os.environ.get(FALLBACK_MODEL_ENV)
    if override is not None:
        if not override.strip():
            return [], None
        entries = [e.strip() for e in override.split(",")]
        for e in entries:
            if not valid_model_token(e):
                return None, "invalid entry in " + FALLBACK_MODEL_ENV + ": " + repr(e)
        return entries, None
    return default_fallback_chain(model), None


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
        "permissions bypassed. This runs Claude Code in headless print "
        "mode, so a downgrade chain is passed via --fallback-model: if the "
        "requested model is overloaded or not available, the CLI retries "
        "with the next model in the chain before this call returns. A "
        "safety-rules refusal is not covered by that flag, so this tool "
        "detects it and re-runs the same prompt on the next model in the "
        "chain itself; every attempt carries identical tool restrictions, "
        "and the whole call still obeys one overall timeout. Set "
        + FALLBACK_MODEL_ENV +
        " to a comma-separated override list, or leave it unset for a "
        "built-in default chain keyed on the requested model. A cancelled "
        "call and a running one both report a session_id when the "
        "underlying claude run reached one, so a stalled call can be "
        "diagnosed without waiting for the whole timeout. " +
        delegation_note)


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

_CALLER_NAME = ""


def set_caller_name(name):
    global _CALLER_NAME
    if isinstance(name, str):
        _CALLER_NAME = name[:64]


def audit_text(value, limit=128):
    if not isinstance(value, str):
        return None
    text = "".join(ch for ch in value if ch.isprintable())
    return text[:limit]


def audit_digest(value):
    if not isinstance(value, str):
        return None
    return hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()[:16]


def audit(decision, reason, args, mode, duration_sec=None, session_id=None,
          outcome=None):
    try:
        os.makedirs(os.path.dirname(AUDIT), exist_ok=True)
        if os.path.isfile(AUDIT) and os.path.getsize(AUDIT) > AUDIT_MAX_BYTES:
            os.replace(AUDIT, AUDIT + ".1")
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               "caller": audit_text(_CALLER_NAME, 64) or "unknown",
               "decision": audit_text(decision, 16),
               "reason": audit_text(reason, 128),
               "model": audit_text(args.get("model"), 80),
               "cwd_sha256": audit_digest(args.get("cwd")),
               "max_turns": args.get("max_turns")
               if isinstance(args.get("max_turns"), int) else None,
               "mode": audit_text(mode, 16),
               "duration_sec": round(duration_sec, 3)
               if isinstance(duration_sec, (int, float)) else None,
               "session_id": audit_text(session_id, 128),
               "outcome": audit_text(outcome, 32),
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


_SEND_LOCK = threading.Lock()
_STATE_LOCK = threading.Lock()
_CANCEL = threading.Event()
_CLOSED = threading.Event()
_CALL = {"id": None, "token": None, "seq": 0, "last": 0.0}
_CANCELLED_IDS = collections.OrderedDict()
_SHUTDOWN = [False]
_IN_CALL = [False]
_LIVE_PROC = [None]


def valid_id(value):
    return isinstance(value, (str, int)) and not isinstance(value, bool)


def send(msg):
    line = json.dumps(msg, ensure_ascii=True) + "\n"
    with _SEND_LOCK:
        try:
            sys.stdout.write(line)
            sys.stdout.flush()
        except (OSError, ValueError):
            _CLOSED.set()


def begin_call(req_id, token):
    with _STATE_LOCK:
        _CALL["id"] = req_id
        _CALL["token"] = token
        _CALL["seq"] = 0
        _CALL["last"] = 0.0
        _CANCEL.clear()
        _IN_CALL[0] = True
        if valid_id(req_id) and req_id in _CANCELLED_IDS:
            del _CANCELLED_IDS[req_id]
            return False
    return True


def end_call():
    with _STATE_LOCK:
        _CALL["id"] = None
        _CALL["token"] = None
        _IN_CALL[0] = False


def cancel_request(req_id):
    if not valid_id(req_id):
        return
    with _STATE_LOCK:
        if _CALL["id"] is not None and _CALL["id"] == req_id:
            _CANCEL.set()
            return
        _CANCELLED_IDS[req_id] = True
        _CANCELLED_IDS.move_to_end(req_id)
        while len(_CANCELLED_IDS) > CANCEL_MEMORY:
            _CANCELLED_IDS.popitem(last=False)


def client_gone():
    if _SHUTDOWN[0] or _CLOSED.is_set():
        return True
    try:
        poller = select.poll()
        poller.register(sys.stdout.fileno(), select.POLLERR | select.POLLHUP)
        if poller.poll(0):
            _CLOSED.set()
            return True
    except (OSError, ValueError, AttributeError):
        pass
    return False


def cancelled():
    return _CANCEL.is_set() or client_gone()


def emit_progress(message, force=False):
    now = time.monotonic()
    with _STATE_LOCK:
        token = _CALL["token"]
        if token is None:
            return
        if not force and now - _CALL["last"] < PROGRESS_MIN_GAP_SEC:
            return
        _CALL["seq"] += 1
        _CALL["last"] = now
        seq = _CALL["seq"]
    send({"jsonrpc": "2.0", "method": "notifications/progress",
          "params": {"progressToken": token, "progress": seq,
                     "message": message}})


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


def progress_interval_sec():
    raw = os.environ.get(PROGRESS_INTERVAL_ENV)
    if not raw:
        return DEFAULT_PROGRESS_INTERVAL_SEC
    try:
        val = float(raw)
    except ValueError:
        return DEFAULT_PROGRESS_INTERVAL_SEC
    return val if val > 0 else DEFAULT_PROGRESS_INTERVAL_SEC


def _kill_group(proc, grace=KILL_GRACE_SEC):
    pgid = proc.pid
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        pass
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def _parse_stream_line(line):
    try:
        obj = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


class AttemptResult:
    def __init__(self):
        self.returncode = None
        self.stdout = ""
        self.stderr = ""
        self.session_id = None
        self.timed_out = False
        self.cancelled = False
        self.partial_text = ""


def spawn_claude_attempt(attempt_cmd, cwd, env, timeout_budget):
    argv = list(attempt_cmd)
    setpriv_path = shutil.which("setpriv")
    if setpriv_path:
        argv = [setpriv_path, "--pdeathsig", "KILL"] + argv

    proc = subprocess.Popen(
        argv, cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL, start_new_session=True)

    result = AttemptResult()
    _LIVE_PROC[0] = proc
    started = time.monotonic()
    deadline = started + max(timeout_budget, 0)
    last_progress = started
    gap = progress_interval_sec()
    line_buf = bytearray()
    err_buf = bytearray()
    partial_buf = bytearray()
    final_line = None
    try:
        open_fds = [proc.stdout, proc.stderr]
        while open_fds:
            if cancelled():
                _kill_group(proc)
                result.cancelled = True
                break
            now = time.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                _kill_group(proc)
                result.timed_out = True
                break
            if now - last_progress >= gap:
                last_progress = now
                emit_progress(
                    "claude running (%ds)" % int(now - started), force=True)
            wait = max(min(remaining, 1.0, gap), 0.05)
            rlist, _, _ = select.select(open_fds, [], [], wait)
            for fh in rlist:
                chunk = os.read(fh.fileno(), 65536)
                if not chunk:
                    open_fds.remove(fh)
                    continue
                if fh is proc.stdout:
                    line_buf += chunk
                    partial_buf += chunk
                    if len(partial_buf) > PARTIAL_OUTPUT_MAX_BYTES:
                        del partial_buf[:len(partial_buf) - PARTIAL_OUTPUT_MAX_BYTES]
                    while True:
                        idx = line_buf.find(b"\n")
                        if idx < 0:
                            break
                        line = bytes(line_buf[:idx])
                        del line_buf[:idx + 1]
                        obj = _parse_stream_line(line)
                        if obj is not None:
                            sid = obj.get("session_id")
                            if isinstance(sid, str) and sid:
                                result.session_id = sid
                            if obj.get("type") == "result":
                                final_line = line
                    if len(line_buf) > STREAM_LINE_MAX_BYTES:
                        del line_buf[:len(line_buf) - 65536]
                else:
                    err_buf += chunk
                    if len(err_buf) > MAX_STDERR_BYTES:
                        del err_buf[:len(err_buf) - MAX_STDERR_BYTES]
    finally:
        try:
            rc = proc.wait(timeout=KILL_GRACE_SEC)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            try:
                rc = proc.wait(timeout=KILL_GRACE_SEC)
            except Exception:
                rc = -1
        result.returncode = rc
        _LIVE_PROC[0] = None
        for fh in (proc.stdout, proc.stderr):
            try:
                fh.close()
            except Exception:
                pass

    if final_line is None and not result.cancelled and not result.timed_out \
            and line_buf:
        obj = _parse_stream_line(bytes(line_buf))
        if obj is not None and obj.get("type") == "result":
            final_line = bytes(line_buf)
            sid = obj.get("session_id")
            if isinstance(sid, str) and sid:
                result.session_id = sid

    if final_line is not None:
        result.stdout = final_line.decode("utf-8", "replace")
    else:
        result.stdout = bytes(line_buf).decode("utf-8", "replace")
    result.stderr = bytes(err_buf).decode("utf-8", "replace")
    result.partial_text = bytes(partial_buf).decode("utf-8", "replace").strip()
    return result


def run_claude(args):
    call_start = time.monotonic()
    if depth_reached():
        audit("deny", "depth limit", args, None,
              duration_sec=time.monotonic() - call_start, outcome="refused")
        return tool_text(
            "ask-claude refused: delegation depth limit reached - a Claude "
            "instance spawned over MCP may not spawn another one", True)

    prompt = args.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return tool_text("ask-claude refused: prompt must be a non-empty "
                         "string", True)
    model = args.get("model", "sonnet")
    if not valid_model_token(model):
        return tool_text("ask-claude refused: invalid model name", True)
    effort = args.get("effort")
    if effort is not None and effort not in EFFORT_LEVELS:
        return tool_text("ask-claude refused: effort must be one of "
                         "low, medium, high, xhigh, max", True)
    mode = args.get("mode") or default_mode()
    if mode not in MODE_LEVELS:
        return tool_text("ask-claude refused: mode must be one of "
                         "analyse, plan, full", True)
    refusal = model_refusal(model, prompt)
    if refusal:
        audit("deny", "model-policy", args, mode,
              duration_sec=time.monotonic() - call_start, outcome="refused")
        return tool_text("ask-claude refused: " + refusal, True)
    max_turns = args.get("max_turns")
    if max_turns is None:
        max_turns = 50 if mode == "full" else 30
    if not isinstance(max_turns, int) or not 1 <= max_turns <= 200:
        return tool_text("ask-claude refused: max_turns must be an integer "
                         "between 1 and 200", True)

    cwd = args.get("cwd")
    if cwd is not None and not isinstance(cwd, str):
        return tool_text("ask-claude refused: cwd must be a string", True)

    fallback_models, fallback_err = resolve_fallback_models(model)
    if fallback_err:
        return tool_text("ask-claude refused: " + fallback_err, True)

    run_dir = None
    if cwd:
        real, reason = check_cwd(cwd)
        if reason:
            audit("deny", reason, args, mode,
                  duration_sec=time.monotonic() - call_start,
                  outcome="refused")
            return tool_text("ask-claude refused: " + reason, True)
        run_dir = real

    base_cmd = ["claude", "-p", prompt, "--output-format", "stream-json",
                "--verbose"]
    cmd = []
    if effort:
        cmd += ["--effort", effort]

    if run_dir is not None:
        cmd += ["--max-turns", str(max_turns)]
        if in_container() and mode == "full":
            cmd += ["--strict-mcp-config", "--mcp-config",
                    '{"mcpServers":{}}',
                    "--dangerously-skip-permissions"]
        elif in_container() and mode in ("analyse", "plan"):
            cmd += ["--strict-mcp-config", "--mcp-config",
                    '{"mcpServers":{}}',
                    "--permission-mode", "plan",
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

    audit("allow", "", args, mode, duration_sec=time.monotonic() - call_start)
    attempts = [model]
    for m in fallback_models:
        if m not in attempts and model_banned(m) is None:
            attempts.append(m)
    deadline = time.monotonic() + CALL_TIMEOUT
    proc = None
    session_id = None
    for index, attempt_model in enumerate(attempts):
        remaining = attempts[index + 1:]
        budget = deadline - time.monotonic()
        if budget < 1:
            break
        attempt_cmd = base_cmd + ["--model", attempt_model]
        if remaining:
            attempt_cmd += ["--fallback-model", ",".join(remaining)]
        attempt_cmd += cmd
        try:
            proc = spawn_claude_attempt(attempt_cmd, run_dir, env, budget)
        except FileNotFoundError:
            audit("error", "claude binary not found", args, mode,
                  duration_sec=time.monotonic() - call_start,
                  session_id=session_id, outcome="error")
            return tool_text("ask-claude failed: claude binary not found", True)

        if proc.session_id:
            session_id = proc.session_id

        if proc.cancelled:
            audit("cancel", CANCELLED_MESSAGE, args, mode,
                  duration_sec=time.monotonic() - call_start,
                  session_id=session_id, outcome="cancelled")
            body = "ask-claude failed: " + CANCELLED_MESSAGE
            if session_id:
                body += " (session_id: %s)" % session_id
            return tool_text(body, True)

        if proc.timed_out:
            audit("error", "timeout", args, mode,
                  duration_sec=time.monotonic() - call_start,
                  session_id=session_id, outcome="timeout")
            body = "ask-claude failed: claude run exceeded %ds" % CALL_TIMEOUT
            if session_id:
                body += " (session_id: %s)" % session_id
            if proc.partial_text:
                body += "\n[partial output]\n" + proc.partial_text
            return tool_text(body, True)

        if not remaining or not is_safety_refusal(proc, prompt):
            break
        audit("safety-fallback", attempt_model + " -> " + remaining[0],
              args, mode, duration_sec=time.monotonic() - call_start,
              session_id=session_id)

    if proc is None:
        audit("error", "timeout before first attempt", args, mode,
              duration_sec=time.monotonic() - call_start,
              session_id=session_id, outcome="timeout")
        return tool_text(
            "ask-claude failed: call timeout expired before any attempt "
            "could run", True)

    try:
        out = json.loads(proc.stdout)
        text = out.get("result") or ""
        is_error = bool(out.get("is_error")) or proc.returncode != 0
        if not session_id:
            session_id = out.get("session_id")
        if is_error and not text:
            text = "claude run failed"
            errors = out.get("errors")
            if errors:
                text += ": " + "; ".join(str(e) for e in errors[:3])
        if session_id:
            text += "\n[session_id: %s]" % session_id
        audit("allow" if not is_error else "error",
              "" if not is_error else "claude run failed", args, mode,
              duration_sec=time.monotonic() - call_start,
              session_id=session_id, outcome="ok" if not is_error else "error")
        return tool_text(text, is_error)
    except ValueError:
        tail = (proc.stdout or proc.stderr or "").strip()[-2000:]
        if proc.returncode == 0 and tail:
            audit("allow", "", args, mode,
                  duration_sec=time.monotonic() - call_start,
                  session_id=session_id, outcome="ok")
            return tool_text(tail)
        audit("error", "unparseable claude output", args, mode,
              duration_sec=time.monotonic() - call_start,
              session_id=session_id, outcome="error")
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
        client_info = params.get("clientInfo")
        if isinstance(client_info, dict):
            set_caller_name(client_info.get("name"))
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
        if req_id is None:
            return
        meta = params.get("_meta")
        token = meta.get("progressToken") if isinstance(meta, dict) else None
        if not valid_id(token) or (
                isinstance(token, str) and len(token) > MAX_TOKEN_LEN):
            token = None
        try:
            if not begin_call(req_id, token):
                return
            result = run_claude(params.get("arguments") or {})
        finally:
            end_call()
        if cancelled():
            return
        reply(req_id, result)
    elif req_id is not None:
        reply_error(req_id, -32601, "method not found: " + str(method))


def _stdin_lines(stream):
    while True:
        line = stream.readline(MAX_STDIN_LINE_BYTES + 1)
        if not line:
            return
        if len(line) > MAX_STDIN_LINE_BYTES and not line.endswith(b"\n"):
            while True:
                rest = stream.readline(MAX_STDIN_LINE_BYTES)
                if not rest or rest.endswith(b"\n"):
                    break
            yield None
            continue
        yield line


def _read_stdin(inbox):
    try:
        for line in _stdin_lines(sys.stdin.buffer):
            if line is None:
                send({"jsonrpc": "2.0", "id": None,
                      "error": {"code": -32600,
                                "message": "request line too long"}})
                continue
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                send({"jsonrpc": "2.0", "id": None,
                      "error": {"code": -32700, "message": "parse error"}})
                continue
            if not isinstance(msg, dict):
                send({"jsonrpc": "2.0", "id": None,
                      "error": {"code": -32600, "message": "invalid request"}})
                continue
            method = msg.get("method")
            if method == "notifications/cancelled":
                params = msg.get("params")
                if isinstance(params, dict):
                    cancel_request(params.get("requestId"))
                continue
            if method == "ping" and msg.get("id") is not None:
                reply(msg.get("id"), {})
                continue
            inbox.put(msg)
    except Exception:
        pass
    inbox.put(None)


def _on_signal(signum, frame):
    _SHUTDOWN[0] = True
    proc = _LIVE_PROC[0]
    if proc is not None:
        _kill_group(proc)
    if not _IN_CALL[0]:
        raise SystemExit(128 + signum)


def main():
    inbox = queue.Queue()
    reader = threading.Thread(target=_read_stdin, args=(inbox,), daemon=True)
    reader.start()
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, _on_signal)
    while not client_gone():
        try:
            msg = inbox.get(timeout=0.5)
        except queue.Empty:
            continue
        if msg is None:
            break
        try:
            handle(msg)
        except Exception as e:
            if msg.get("id") is not None:
                reply_error(msg.get("id"), -32603,
                            "internal error: " + type(e).__name__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
