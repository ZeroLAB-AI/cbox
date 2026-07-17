#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import threading
import unicodedata

MAX_MSG = 140
MAX_LINE = 1 << 20
MAX_CALLS = 64

SKIP = {
    "raw_response_item",
    "token_count",
    "user_message",
    "item_started",
    "item_completed",
    "mcp_startup_complete",
    "turn_diff",
    "agent_reasoning",
    "agent_reasoning_raw_content",
    "agent_reasoning_section_break",
}


def sanitize(text):
    flat = "".join(
        ch if ch.isprintable() and not unicodedata.combining(ch) else " "
        for ch in str(text)
    )
    return " ".join(flat.split())[:MAX_MSG]


def describe(msg):
    t = msg.get("type")
    if not isinstance(t, str) or t in SKIP or t.endswith("_delta"):
        return None
    if t == "task_started":
        return "task started"
    if t == "task_complete":
        return "task complete"
    if t == "session_configured":
        model = msg.get("model")
        return sanitize("model: " + model) if isinstance(model, str) else None
    if t == "agent_message":
        m = msg.get("message")
        return sanitize("msg: " + m) if isinstance(m, str) else "msg"
    if t == "exec_command_begin":
        cmd = msg.get("command")
        if isinstance(cmd, list):
            return sanitize("exec: " + " ".join(str(c) for c in cmd))
        return "exec"
    if t == "exec_command_end":
        return sanitize("exec exit " + str(msg.get("exit_code")))
    if t == "patch_apply_begin":
        return "applying patch"
    if t == "patch_apply_end":
        return "patch applied" if msg.get("success", True) else "patch failed"
    if t == "mcp_tool_call_begin":
        inv = msg.get("invocation")
        if isinstance(inv, dict):
            return sanitize("tool: %s.%s" % (inv.get("server"), inv.get("tool")))
        return "tool call"
    if t == "mcp_tool_call_end":
        return "tool done"
    if t in ("web_search_begin", "web_search_end"):
        q = msg.get("query")
        return sanitize("web: " + q) if isinstance(q, str) else "web search"
    if t in ("stream_error", "warning", "error"):
        m = msg.get("message")
        label = "stream" if t == "stream_error" else t
        return sanitize(label + ": " + m) if isinstance(m, str) else t
    return sanitize(t.replace("_", " "))


def pump(src, dst, on_line):
    buf = bytearray()
    over = False
    try:
        while True:
            chunk = src.read1(65536)
            if not chunk:
                break
            while chunk:
                nl = chunk.find(b"\n")
                if nl < 0:
                    if over:
                        dst.write(chunk)
                        dst.flush()
                    else:
                        buf += chunk
                        if len(buf) > MAX_LINE:
                            dst.write(bytes(buf))
                            dst.flush()
                            buf.clear()
                            over = True
                    chunk = b""
                    continue
                part = chunk[: nl + 1]
                chunk = chunk[nl + 1 :]
                if over:
                    dst.write(part)
                    dst.flush()
                    over = False
                    continue
                buf += part
                line = bytes(buf)
                buf.clear()
                extra = None
                try:
                    extra = on_line(line)
                except Exception:
                    extra = None
                dst.write(line)
                if extra:
                    dst.write(extra)
                dst.flush()
        if buf:
            dst.write(bytes(buf))
            dst.flush()
    except (BrokenPipeError, OSError):
        pass


def main():
    args = sys.argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        sys.stderr.write("codex_mcp_shim: missing child command\n")
        return 2
    child = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    calls = {}
    lock = threading.Lock()
    log_path = os.environ.get("CBOX_CODEX_SHIM_LOG", "")

    def journal(prefix, raw):
        if not log_path:
            return
        try:
            fd = os.open(
                log_path,
                os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW,
                0o600,
            )
            with os.fdopen(fd, "ab") as fh:
                fh.write(prefix + raw if raw.endswith(b"\n") else prefix + raw + b"\n")
        except OSError:
            pass

    def on_up(raw):
        m = json.loads(raw)
        method = m.get("method")
        if method == "tools/call":
            token = m.get("params", {}).get("_meta", {}).get("progressToken")
            rid = m.get("id")
            if token is not None and rid is not None:
                with lock:
                    while len(calls) >= MAX_CALLS:
                        calls.pop(next(iter(calls)))
                    calls[rid] = [token, 0]
        elif method == "notifications/cancelled":
            rid = m.get("params", {}).get("requestId")
            with lock:
                calls.pop(rid, None)
        return None

    def on_down(raw):
        m = json.loads(raw)
        if m.get("method") != "codex/event":
            rid = m.get("id")
            if rid is not None and ("result" in m or "error" in m):
                with lock:
                    calls.pop(rid, None)
            return None
        journal(b"EVENT ", raw)
        params = m.get("params", {})
        msg = params.get("msg")
        if not isinstance(msg, dict):
            msg = params
        text = describe(msg)
        if text is None:
            return None
        rid = params.get("_meta", {}).get("requestId")
        with lock:
            entry = calls.get(rid)
            if entry is None and isinstance(rid, str) and rid.isdigit():
                entry = calls.get(int(rid))
            if entry is None and isinstance(rid, int):
                entry = calls.get(str(rid))
            if entry is None and rid is None and len(calls) == 1:
                entry = next(iter(calls.values()))
            if entry is None:
                return None
            entry[1] += 1
            token, seq = entry
        note = {
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": {"progressToken": token, "progress": seq, "message": text},
        }
        extra = (json.dumps(note) + "\n").encode()
        journal(b"SYNTH ", extra)
        return extra

    def upstream():
        pump(sys.stdin.buffer, child.stdin, on_up)
        try:
            child.stdin.close()
        except OSError:
            pass

    threading.Thread(target=upstream, daemon=True).start()
    pump(child.stdout, sys.stdout.buffer, on_down)
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
