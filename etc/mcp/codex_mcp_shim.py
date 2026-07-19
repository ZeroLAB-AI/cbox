#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import threading
import unicodedata

MAX_MSG = 140
MAX_LINE = 1 << 20
MAX_CALLS = 64
MAX_THREADS = 256
MAX_JOURNAL = 500

DOCKERENV_PATH = "/.dockerenv"

KERNEL_FILENAME = "conduct-kernel.txt"


def in_container():
    return os.path.exists(DOCKERENV_PATH) and os.environ.get("CBOX_RUNTIME") == "container"


def kernel_path():
    override = os.environ.get("CBOX_CONDUCT_KERNEL_PATH")
    if override and not in_container():
        return override
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), KERNEL_FILENAME)


def load_kernel():
    path = kernel_path()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write(
            "codex_mcp_shim: cannot read conduct kernel at %s: %s\n" % (path, exc)
        )
        sys.exit(2)
    if not text.strip():
        sys.stderr.write("codex_mcp_shim: conduct kernel at %s is empty\n" % path)
        sys.exit(2)
    return text


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


JOURNAL_ALLOWLIST = {
    "task_started",
    "task_complete",
    "session_configured",
    "exec_command_end",
    "patch_apply_end",
}


def journal_record(m):
    line = json.dumps(m, ensure_ascii=True)
    if len(line) > MAX_JOURNAL:
        line = line[:MAX_JOURNAL] + "...TRUNCATED"
    return line.encode()


def safe_journal_record(m, msg):
    event_type = msg.get("type") if isinstance(msg, dict) else None
    if event_type not in JOURNAL_ALLOWLIST:
        return None
    rec = {"id": m.get("id"), "type": event_type}
    if event_type == "session_configured":
        model = msg.get("model")
        if isinstance(model, str):
            rec["model"] = model[:80]
    elif event_type == "exec_command_end":
        rec["exit_code"] = msg.get("exit_code")
    elif event_type == "patch_apply_end":
        rec["success"] = msg.get("success", True)
    line = json.dumps(rec, ensure_ascii=True)
    if len(line) > MAX_JOURNAL:
        line = line[:MAX_JOURNAL] + "...TRUNCATED"
    return line.encode()


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
                try:
                    out_lines = on_line(line)
                except Exception:
                    out_lines = [line]
                for piece in out_lines:
                    dst.write(piece)
                dst.flush()
        if buf:
            dst.write(bytes(buf))
            dst.flush()
    except (BrokenPipeError, OSError):
        pass


def parse_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--tier", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--effort", required=True)
    parser.add_argument("--progress", required=True, choices=["on", "off"])
    parser.add_argument("child", nargs=argparse.REMAINDER)
    ns = parser.parse_args(argv)
    child = ns.child
    if child and child[0] == "--":
        child = child[1:]
    if not child:
        sys.stderr.write("codex_mcp_shim: missing child command after --\n")
        sys.exit(2)
    if not ns.tier or not ns.model or not ns.effort:
        sys.stderr.write("codex_mcp_shim: --tier, --model, --effort must be non-empty\n")
        sys.exit(2)
    return ns, child


INSTRUCTION_KEY_SUFFIXES = ("instructions", "instructions_file")


def _normalize_key(key):
    return key.strip().lower().replace("-", "_")


def _has_instruction_key(obj):
    for key in obj:
        if not isinstance(key, str):
            continue
        norm = _normalize_key(key)
        if norm.endswith(INSTRUCTION_KEY_SUFFIXES):
            return True
    return False


class LockedWriter:
    def __init__(self, dst, lock):
        self.dst = dst
        self.lock = lock

    def write(self, data):
        with self.lock:
            return self.dst.write(data)

    def flush(self):
        with self.lock:
            return self.dst.flush()


class Relay:
    def __init__(
        self,
        tier,
        model,
        effort,
        progress_on,
        child_argv,
        log_path,
        depth_stub,
        kernel_text,
    ):
        self.tier = tier
        self.model = model
        self.effort = effort
        self.progress_on = progress_on
        self.log_path = log_path
        self.depth_stub = depth_stub
        self.kernel_text = kernel_text
        self.calls = {}
        self.progress_calls = {}
        self.threads = {}
        self.mismatched = set()
        self.lock = threading.Lock()
        self.stdout_lock = threading.Lock()
        self.child = None
        if not depth_stub:
            child_env = dict(os.environ)
            child_env["CBOX_DELEGATION_DEPTH"] = "1"
            child_env["CBOX_MCP_DEPTH"] = "1"
            self.child = subprocess.Popen(
                child_argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                env=child_env,
            )

    def reply_direct(self, raw):
        with self.stdout_lock:
            sys.stdout.buffer.write(raw)
            sys.stdout.buffer.flush()

    def journal(self, prefix, raw):
        if not self.log_path:
            return
        try:
            fd = os.open(
                self.log_path,
                os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW,
                0o600,
            )
            with os.fdopen(fd, "ab") as fh:
                fh.write(prefix + raw if raw.endswith(b"\n") else prefix + raw + b"\n")
        except OSError:
            pass

    def error_response(self, rid, message):
        resp = {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {"code": -32000, "message": message},
        }
        return (json.dumps(resp) + "\n").encode()

    def rewrite_codex_call(self, m):
        params = m.get("params")
        if not isinstance(params, dict):
            return None
        args = params.get("arguments")
        if args is None:
            args = {}
            params["arguments"] = args
        if not isinstance(args, dict):
            return "codex_mcp_shim: tools/call arguments must be an object"
        if _has_instruction_key(args):
            return (
                "codex_mcp_shim: caller-supplied instructions field is rejected - "
                "task direction belongs in prompt"
            )
        args["model"] = self.model
        cfg = args.get("config")
        if cfg is None:
            cfg = {}
            args["config"] = cfg
        if not isinstance(cfg, dict):
            return "codex_mcp_shim: tools/call arguments.config must be an object"
        if _has_instruction_key(cfg):
            return (
                "codex_mcp_shim: caller-supplied instructions field is rejected - "
                "task direction belongs in prompt"
            )
        cfg["model_reasoning_effort"] = self.effort
        if in_container():
            args["approval-policy"] = "never"
            args["sandbox"] = "danger-full-access"
        args["developer-instructions"] = self.kernel_text
        return None

    def rewrite_codex_reply(self, m):
        params = m.get("params")
        if not isinstance(params, dict):
            return "codex_mcp_shim: tools/call arguments must be an object"
        args = params.get("arguments")
        if not isinstance(args, dict):
            return "codex_mcp_shim: tools/call arguments must be an object"
        tid = args.get("threadId")
        if tid is None:
            tid = args.get("conversationId")
        if not isinstance(tid, str) or not tid:
            return "thread unknown to this relay - start a new codex call"
        with self.lock:
            known = tid in self.threads
        if not known:
            return "thread unknown to this relay - start a new codex call"
        return None

    def handle_stub_upstream(self, m):
        method = m.get("method")
        rid = m.get("id")
        if method == "initialize":
            resp = {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "protocolVersion": m.get("params", {}).get(
                        "protocolVersion", "2024-11-05"
                    )
                    if isinstance(m.get("params"), dict)
                    else "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {
                        "name": "cbox-codex-relay-stub",
                        "version": "0",
                    },
                },
            }
            return [(json.dumps(resp) + "\n").encode()]
        if method == "tools/list":
            resp = {"jsonrpc": "2.0", "id": rid, "result": {"tools": []}}
            return [(json.dumps(resp) + "\n").encode()]
        if method == "tools/call":
            if rid is None:
                return []
            resp = {
                "jsonrpc": "2.0",
                "id": rid,
                "error": {
                    "code": -32601,
                    "message": "codex_mcp_shim: delegation depth limit reached, tool disabled",
                },
            }
            return [(json.dumps(resp) + "\n").encode()]
        if rid is None:
            return []
        resp = {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {"code": -32601, "message": "method not available in depth stub"},
        }
        return [(json.dumps(resp) + "\n").encode()]

    def on_up(self, raw):
        m = json.loads(raw)
        if self.depth_stub:
            return self.handle_stub_upstream(m)

        method = m.get("method")
        rid = m.get("id")
        is_codex_call = (
            method == "tools/call"
            and isinstance(m.get("params"), dict)
            and m.get("params", {}).get("name") == "codex"
        )
        is_codex_reply = (
            method == "tools/call"
            and isinstance(m.get("params"), dict)
            and m.get("params", {}).get("name") == "codex-reply"
        )

        if is_codex_call:
            err = self.rewrite_codex_call(m)
            if err is not None:
                if rid is not None:
                    self.reply_direct(self.error_response(rid, err))
                return []
        elif is_codex_reply:
            err = self.rewrite_codex_reply(m)
            if err is not None:
                if rid is not None:
                    self.reply_direct(self.error_response(rid, err))
                return []

        if method == "tools/call":
            token = m.get("params", {}).get("_meta", {}).get("progressToken")
            if rid is not None:
                with self.lock:
                    while len(self.calls) >= MAX_CALLS:
                        self.calls.pop(next(iter(self.calls)))
                    self.calls[rid] = {"active": True}
                    if token is not None:
                        self.progress_calls[rid] = [token, 0]
        elif method == "notifications/cancelled":
            crid = m.get("params", {}).get("requestId")
            with self.lock:
                self.calls.pop(crid, None)
                self.progress_calls.pop(crid, None)

        rewritten = (json.dumps(m) + "\n").encode()
        return [rewritten]

    def note_mismatch(self, rid):
        with self.lock:
            self.mismatched.add(rid)

    def is_mismatched(self, rid):
        with self.lock:
            return rid in self.mismatched

    def clear_mismatch(self, rid):
        with self.lock:
            self.mismatched.discard(rid)

    def _remember_thread_id(self, val):
        with self.lock:
            self.threads.pop(val, None)
            while len(self.threads) >= MAX_THREADS:
                self.threads.pop(next(iter(self.threads)))
            self.threads[val] = True

    def remember_thread(self, m):
        result = m.get("result")
        if not isinstance(result, dict):
            return
        for key in ("threadId", "conversationId"):
            val = result.get(key)
            if isinstance(val, str):
                self._remember_thread_id(val)
        structured = result.get("structuredContent")
        if isinstance(structured, dict):
            for key in ("threadId", "conversationId"):
                val = structured.get(key)
                if isinstance(val, str):
                    self._remember_thread_id(val)

    def on_down(self, raw):
        m = json.loads(raw)
        if m.get("method") != "codex/event":
            rid = m.get("id")
            if rid is not None and ("result" in m or "error" in m):
                if self.is_mismatched(rid):
                    self.clear_mismatch(rid)
                    with self.lock:
                        self.calls.pop(rid, None)
                        self.progress_calls.pop(rid, None)
                    self.journal(
                        b"SUPPRESS ",
                        json.dumps({"id": rid}).encode(),
                    )
                    return []
                if "result" in m:
                    self.remember_thread(m)
                with self.lock:
                    self.calls.pop(rid, None)
                    self.progress_calls.pop(rid, None)
            return [raw]

        params = m.get("params", {})
        msg = params.get("msg")
        if not isinstance(msg, dict):
            msg = params
        meta_rid = params.get("_meta", {}).get("requestId")

        safe_rec = safe_journal_record(m, msg)
        if safe_rec is not None:
            self.journal(b"EVENT ", safe_rec)

        if msg.get("type") == "session_configured":
            model = msg.get("model")
            if isinstance(model, str) and model != self.model:
                target_rid = meta_rid
                if target_rid is None:
                    with self.lock:
                        active = [
                            rid
                            for rid, info in self.calls.items()
                            if info.get("active")
                        ]
                    if len(active) == 1:
                        target_rid = active[0]
                if target_rid is not None:
                    self.note_mismatch(target_rid)
                    err = self.error_response(
                        target_rid,
                        "codex_mcp_shim: session_configured model mismatch "
                        "(tier=%s got=%s)" % (self.model, model),
                    )
                    self.journal(b"MISMATCH ", err)
                    return [raw, err]

        if not self.progress_on:
            return [raw]

        text = describe(msg)
        if text is None:
            return [raw]
        with self.lock:
            entry = self.progress_calls.get(meta_rid)
            if entry is None and isinstance(meta_rid, str) and meta_rid.isdigit():
                entry = self.progress_calls.get(int(meta_rid))
            if entry is None and isinstance(meta_rid, int):
                entry = self.progress_calls.get(str(meta_rid))
            if entry is None and meta_rid is None and len(self.progress_calls) == 1:
                entry = next(iter(self.progress_calls.values()))
            if entry is None:
                return [raw]
            entry[1] += 1
            token, seq = entry
        note = {
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": {"progressToken": token, "progress": seq, "message": text},
        }
        extra = (json.dumps(note) + "\n").encode()
        self.journal(b"SYNTH ", extra)
        return [raw, extra]

    def run(self):
        if self.depth_stub:
            pump(sys.stdin.buffer, sys.stdout.buffer, self.on_up)
            return 0

        def upstream():
            pump(sys.stdin.buffer, self.child.stdin, self.on_up)
            try:
                self.child.stdin.close()
            except OSError:
                pass

        threading.Thread(target=upstream, daemon=True).start()
        pump(self.child.stdout, LockedWriter(sys.stdout.buffer, self.stdout_lock), self.on_down)
        return self.child.wait()


def main():
    ns, child_argv = parse_args(sys.argv[1:])
    log_path = os.environ.get("CBOX_CODEX_SHIM_LOG", "")
    depth = os.environ.get("CBOX_DELEGATION_DEPTH") or os.environ.get("CBOX_MCP_DEPTH")
    depth_stub = bool(depth)
    kernel_text = load_kernel()
    relay = Relay(
        tier=ns.tier,
        model=ns.model,
        effort=ns.effort,
        progress_on=(ns.progress == "on"),
        child_argv=child_argv,
        log_path=log_path,
        depth_stub=depth_stub,
        kernel_text=kernel_text,
    )
    return relay.run()


if __name__ == "__main__":
    sys.exit(main())
