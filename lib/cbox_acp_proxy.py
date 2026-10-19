import argparse
import collections
import datetime
import json
import os
import select
import secrets
import selectors
import signal
import subprocess
import sys
import time
import urllib.parse


EDITOR_METHODS = {
    "initialize", "authenticate", "session/new", "session/load",
    "session/resume", "session/fork", "session/list", "session/prompt",
    "session/set_mode", "session/set_model", "session/set_config_option",
    "session/close", "session/delete",
}
SESSION_START = {"session/new", "session/load", "session/resume", "session/fork"}
SESSION_BOUND = (SESSION_START - {"session/new"}) | {
    "session/prompt", "session/cancel", "session/close", "session/delete",
    "session/set_mode", "session/set_model", "session/set_config_option",
}
FULL_ACCESS = "agent-full-access"
LIST_FIELDS = ("sessionId", "cwd", "title", "updatedAt")
AGENT_REQUESTS = {"session/request_permission", "elicitation/create"}
AGENT_NOTIFICATIONS = {"session/update", "elicitation/complete"}
DROP = object()


def inside(value, roots):
    if not isinstance(value, str) or not os.path.isabs(value):
        return False
    path = os.path.realpath(value)
    return any(path == root or path.startswith(root if root == os.sep else root + os.sep)
               for root in roots)


def allowed_uri(value, roots):
    if not isinstance(value, str):
        return False
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme.lower() != "file":
        return True
    return parsed.netloc.lower() in ("", "localhost") and inside(
        urllib.parse.unquote(parsed.path), roots
    )


def filter_content(value, roots):
    if isinstance(value, dict):
        if "path" in value and not inside(value["path"], roots):
            return DROP
        if "uri" in value and not allowed_uri(value["uri"], roots):
            return DROP
        if value.get("type") == "terminal":
            return DROP
        result = {}
        for key, child in value.items():
            if key == "_meta":
                continue
            cleaned = filter_content(child, roots)
            if cleaned is not DROP:
                result[key] = cleaned
        return result
    if isinstance(value, list):
        return [cleaned for child in value
                if (cleaned := filter_content(child, roots)) is not DROP]
    return value


def strip_meta(value):
    if isinstance(value, dict):
        return {key: strip_meta(child) for key, child in value.items() if key != "_meta"}
    if isinstance(value, list):
        return [strip_meta(child) for child in value]
    return value


def json_depth(value):
    stack = [(value, 1)]
    while stack:
        item, depth = stack.pop()
        if depth > 64:
            return False
        if isinstance(item, dict):
            stack.extend((child, depth + 1) for child in item.values()
                         if isinstance(child, (dict, list)))
        elif isinstance(item, list):
            stack.extend((child, depth + 1) for child in item
                         if isinstance(child, (dict, list)))
    return True


def write_json(stream, message):
    data = (json.dumps(message, ensure_ascii=True, separators=(",", ":")) + "\n").encode()
    fd = stream.fileno()
    while data:
        data = data[os.write(fd, data):]


def error_message(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id,
            "error": {"code": code, "message": message}}


def reject_constant(value):
    raise ValueError(value)


class LineReader:
    def __init__(self, limit):
        self.limit = limit
        self.buffer = bytearray()
        self.discard = False

    def feed(self, data):
        result = []
        for byte in data:
            if byte == 10:
                if self.discard:
                    result.append(None)
                else:
                    result.append(bytes(self.buffer))
                self.buffer.clear()
                self.discard = False
            elif not self.discard:
                if len(self.buffer) == self.limit:
                    self.buffer.clear()
                    self.discard = True
                else:
                    self.buffer.append(byte)
        return result


class StderrRing:
    def __init__(self):
        self.lines = collections.deque()
        self.partial = bytearray()
        self.size = 0

    def add_line(self, line):
        line = line[-16384:]
        self.lines.append(line)
        self.size += len(line)
        while len(self.lines) > 200 or self.size > 16384:
            self.size -= len(self.lines.popleft())

    def feed(self, data):
        for byte in data:
            if byte == 10:
                self.add_line(bytes(self.partial) + b"\n")
                self.partial.clear()
            else:
                self.partial.append(byte)
                if len(self.partial) > 16384:
                    del self.partial[:-16384]

    def tail(self):
        return (b"".join(self.lines) + bytes(self.partial))[-16384:].decode(
            "utf-8", "replace"
        )


class Proxy:
    def __init__(self, args, command):
        self.roots = tuple(os.path.realpath(root) for root in args.root)
        self.project_root = os.path.realpath(args.project_root or args.root[0])
        self.codex = args.engine == "codex"
        if self.project_root not in self.roots:
            raise ValueError("project root must be a configured root")
        self.limit = args.max_line_bytes
        self.logfile = open(args.log, "a", encoding="utf-8") if args.log else None
        self.editor_pending = {}
        self.agent_pending = {}
        self.sessions = set()
        self.mode_ready = set()
        self.mode_pending = {}
        self.relock = set()
        self.auth_methods = set()
        self.initialize_answered = False
        self.startup_error_sent = False
        self.token = secrets.token_hex(12)
        self.next_id = 0
        self.stderr = StderrRing()
        self.spawn_error = None
        try:
            self.backend = subprocess.Popen(command, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, bufsize=0)
        except OSError as exc:
            self.backend = None
            self.spawn_error = str(exc)
            self.stderr.feed(self.spawn_error.encode("utf-8", "replace"))

    def log(self, direction, method, reason):
        if self.logfile:
            stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
            clean = lambda item: str(item).encode("unicode_escape").decode("ascii")[:200]
            self.logfile.write(f"{stamp} {direction} {clean(method)} {clean(reason)}\n")
            self.logfile.flush()

    def new_id(self, prefix):
        self.next_id += 1
        return f"{prefix}:{self.token}:{self.next_id}"

    def send_editor(self, value):
        try:
            write_json(sys.stdout.buffer, value)
        except (BrokenPipeError, OSError):
            raise SystemExit(self.shutdown() if self.backend is not None else 127)

    def send_agent(self, value):
        if self.backend is None or self.backend.poll() is not None:
            return False
        try:
            write_json(self.backend.stdin, value)
            return True
        except (BrokenPipeError, OSError):
            return False

    def refuse(self, target, request_id, code, message, direction, method, reason):
        self.log(direction, method, reason)
        if request_id is not None:
            target(error_message(request_id, code, message))

    def backend_failure_text(self, before):
        self.drain_stderr()
        code = self.backend.poll() if self.backend is not None else 127
        if code is None:
            code = "unknown"
        lead = (f"cbox could not start the agent backend (exit {code})" if before
                else f"cbox: agent backend exited (code {code})")
        tail = self.stderr.tail()
        if not tail:
            return lead
        available = 8192 - len(lead.encode()) - 1
        tail = tail.encode("utf-8")[-available:].decode("utf-8", "replace")
        while len(tail.encode("utf-8")) > available:
            tail = tail[1:]
        return lead + "\n" + tail

    def capture_stderr(self, data):
        self.stderr.feed(data)
        try:
            while data:
                data = data[os.write(sys.stderr.fileno(), data):]
        except OSError:
            pass

    def drain_stderr(self):
        if self.backend is None:
            return
        while select.select([self.backend.stderr], [], [], 0)[0]:
            data = os.read(self.backend.stderr.fileno(), 65536)
            if not data:
                break
            self.capture_stderr(data)

    def backend_died(self):
        before = not self.initialize_answered
        text = self.backend_failure_text(before)
        if not before:
            for session_id in tuple(self.sessions):
                self.send_editor({"jsonrpc": "2.0", "method": "session/update",
                                  "params": {"sessionId": session_id,
                                             "update": {"sessionUpdate": "agent_message_chunk",
                                                        "content": {"type": "text", "text": text}}}})
        for original, method, session_id in self.editor_pending.values():
            self.send_editor(error_message(original, -32000, text))
        self.editor_pending.clear()
        for original, message, session_id in self.mode_pending.values():
            if original is not None:
                self.send_editor(error_message(original, -32000, text))
        self.mode_pending.clear()

    def start_in_flight(self, session_id):
        return any(method in SESSION_START and sid == session_id
                   for _, method, sid in self.editor_pending.values())

    def lock_in_flight(self, session_id):
        return any(sid == session_id for _, _, sid in self.mode_pending.values())

    def start_lock(self, session_id, original, start_message):
        self.mode_ready.discard(session_id)
        internal_id = self.new_id("m")
        self.mode_pending[internal_id] = (original, start_message, session_id)
        if self.send_agent({"jsonrpc": "2.0", "id": internal_id,
                            "method": "session/set_mode",
                            "params": {"sessionId": session_id, "modeId": FULL_ACCESS}}):
            return True
        self.mode_pending.pop(internal_id, None)
        self.sessions.discard(session_id)
        return False

    def relock_session(self, session_id):
        self.mode_ready.discard(session_id)
        if self.start_in_flight(session_id):
            return
        if self.lock_in_flight(session_id):
            self.relock.add(session_id)
            return
        self.start_lock(session_id, None, None)

    def mode_drifted(self, params):
        update = params.get("update")
        if not isinstance(update, dict):
            return False
        kind = update.get("sessionUpdate")
        if kind == "current_mode_update":
            return update.get("currentModeId", update.get("modeId")) != FULL_ACCESS
        if kind == "config_option_update":
            options = update.get("configOptions")
            return isinstance(options, list) and any(
                isinstance(option, dict) and option.get("id") == "mode" and
                option.get("currentValue") != FULL_ACCESS for option in options)
        return False

    def parse(self, raw, direction):
        if raw is None:
            self.log(direction, "-", "line over byte limit")
            return None
        try:
            message = json.loads(raw, parse_constant=reject_constant)
        except (ValueError, UnicodeDecodeError, RecursionError):
            self.log(direction, "-", "invalid JSON")
            return None
        if not isinstance(message, dict) or not json_depth(message):
            self.log(direction, "-", "non-object, batch, or depth over 64")
            return None
        if message.get("jsonrpc") != "2.0":
            self.log(direction, message.get("method", "-"), "invalid JSON-RPC version")
            return None
        if "id" in message and (isinstance(message["id"], bool) or
                                not isinstance(message["id"], (str, int))):
            self.log(direction, message.get("method", "-"), "invalid id")
            return None
        return message

    def editor_message(self, message):
        method = message.get("method")
        if method is None:
            if ("result" in message) == ("error" in message):
                self.log("editor->agent", "-", "invalid response shape")
                return
            pending = self.agent_pending.pop(message.get("id"), None)
            if pending is None:
                self.log("editor->agent", "-", "unknown response id")
                return
            message["id"] = pending
            self.send_agent(message)
            return
        request_id = message.get("id")
        if not isinstance(method, str):
            self.refuse(self.send_editor, request_id, -32600, "invalid method",
                        "editor->agent", "-", "invalid method")
            return
        if method not in EDITOR_METHODS and not (method == "session/cancel" and request_id is None):
            self.refuse(self.send_editor, request_id, -32601,
                        f"cbox acp: {method} blocked", "editor->agent", method, "blocked method")
            return
        if request_id is None and method != "session/cancel":
            self.log("editor->agent", method, "request sent as notification")
            return
        params = message.get("params", {})
        if not isinstance(params, dict):
            self.refuse(self.send_editor, request_id, -32602, "invalid params",
                        "editor->agent", method, "invalid params")
            return
        if method in SESSION_START and not inside(params.get("cwd"), (self.project_root,)):
            self.refuse(self.send_editor, request_id, -32602, "cbox acp: cwd outside project roots",
                        "editor->agent", method, "cwd outside roots")
            return
        if method != "session/list" and (method in SESSION_BOUND or "sessionId" in params) and (
                not isinstance(params.get("sessionId"), str) or
                params["sessionId"] not in self.sessions):
            self.refuse(self.send_editor, request_id, -32602, "cbox acp: foreign sessionId",
                        "editor->agent", method, "foreign sessionId")
            return
        if (self.codex and (method in SESSION_START or method == "session/prompt") and
                isinstance(params.get("sessionId"), str) and
                (self.start_in_flight(params["sessionId"]) or
                 self.lock_in_flight(params["sessionId"]))):
            self.refuse(self.send_editor, request_id, -32602, "cbox acp: session start in progress",
                        "editor->agent", method, "session start in progress")
            return
        if method in SESSION_START:
            params = dict(params)
            params["mcpServers"] = []
            params.pop("additionalDirectories", None)
            params = strip_meta(params)
        elif method == "session/list":
            if "cwd" in params and not inside(params["cwd"], (self.project_root,)):
                self.refuse(self.send_editor, request_id, -32602, "cbox acp: cwd outside project roots",
                            "editor->agent", method, "cwd outside roots")
                return
            if "cursor" in params and not isinstance(params["cursor"], str):
                self.refuse(self.send_editor, request_id, -32602, "cbox acp: invalid cursor",
                            "editor->agent", method, "invalid cursor")
                return
            params = {key: params[key] for key in ("cwd", "cursor") if key in params}
        if method == "authenticate" and (not isinstance(params.get("methodId"), str) or
                                         params["methodId"] not in self.auth_methods):
            self.refuse(self.send_editor, request_id, -32602, "cbox acp: auth method blocked",
                        "editor->agent", method, "auth method blocked")
            return
        if self.codex and method == "session/prompt" and params.get("sessionId") not in self.mode_ready:
            self.refuse(self.send_editor, request_id, -32602, "cbox acp: session mode not ready",
                        "editor->agent", method, "session mode not ready")
            return
        if self.codex and method == "session/set_mode" and params.get("modeId") != "agent-full-access":
            self.refuse(self.send_editor, request_id, -32602, "cbox acp: mode locked",
                        "editor->agent", method, "mode locked")
            return
        if (self.codex and method == "session/set_config_option" and
                params.get("configId") == "mode" and params.get("value") != "agent-full-access"):
            self.refuse(self.send_editor, request_id, -32602, "cbox acp: mode locked",
                        "editor->agent", method, "mode locked")
            return
        if method == "initialize":
            advertised = params.get("clientCapabilities")
            advertised = advertised if isinstance(advertised, dict) else {}
            elicitation = advertised.get("elicitation")
            elicitation = elicitation if isinstance(elicitation, dict) else {}
            form = elicitation.get("form")
            capabilities = {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}
            if form is not None and form is not False:
                capabilities["elicitation"] = {"form": {}}
            params = {key: value for key, value in params.items() if key == "protocolVersion"}
            params["clientCapabilities"] = capabilities
        if request_id is not None:
            if len(self.editor_pending) >= 64:
                self.refuse(self.send_editor, request_id, -32000, "cbox acp: too many requests",
                            "editor->agent", method, "in-flight limit")
                return
            remapped = self.new_id("e")
            self.editor_pending[remapped] = (request_id, method, params.get("sessionId"))
            message["id"] = remapped
        message["params"] = params
        if not self.send_agent(message) and request_id is not None:
            self.editor_pending.pop(message["id"], None)
            self.send_editor(error_message(request_id, -32000,
                                           self.backend_failure_text(not self.initialize_answered)))
            if method == "initialize":
                self.startup_error_sent = True

    def agent_message(self, message):
        method = message.get("method")
        if method is None:
            if ("result" in message) == ("error" in message):
                self.log("agent->editor", "-", "invalid response shape")
                return
            mode_pending = self.mode_pending.pop(message.get("id"), None)
            if mode_pending is not None:
                original, start_message, session_id = mode_pending
                if "error" in message or not isinstance(message.get("result"), dict):
                    self.sessions.discard(session_id)
                    self.mode_ready.discard(session_id)
                    self.relock.discard(session_id)
                    if original is not None:
                        self.send_editor(error_message(original, -32000,
                                                       "cbox acp: could not lock session mode"))
                    return
                if session_id in self.relock:
                    self.relock.discard(session_id)
                    if not self.start_lock(session_id, original, start_message) and original is not None:
                        self.send_editor(error_message(original, -32000,
                                                       "cbox acp: could not lock session mode"))
                    return
                self.mode_ready.add(session_id)
                if start_message is None:
                    return
                result = start_message["result"]
                if isinstance(result.get("modes"), dict):
                    result["modes"]["currentModeId"] = FULL_ACCESS
                options = result.get("configOptions")
                if isinstance(options, list):
                    for option in options:
                        if isinstance(option, dict) and option.get("id") == "mode":
                            option["currentValue"] = FULL_ACCESS
                self.send_editor(start_message)
                return
            pending = self.editor_pending.pop(message.get("id"), None)
            if pending is None:
                self.log("agent->editor", "-", "unknown response id")
                return
            original, request_method, session_id = pending
            message["id"] = original
            if request_method == "initialize":
                self.initialize_answered = True
                result = message.get("result")
                if isinstance(result, dict):
                    methods = []
                    auths = result.get("authMethods")
                    for auth in auths if isinstance(auths, list) else []:
                        if not isinstance(auth, dict):
                            continue
                        if auth.get("type", "agent") != "agent" or any(
                                key in auth for key in ("command", "args", "env")):
                            continue
                        methods.append(auth)
                        if isinstance(auth.get("id"), str):
                            self.auth_methods.add(auth["id"])
                    result = strip_meta(result)
                    result["authMethods"] = methods
                    message["result"] = result
            elif request_method in SESSION_START:
                result = message.get("result")
                new_session_id = None
                if isinstance(result, dict) and isinstance(result.get("sessionId"), str):
                    new_session_id = result["sessionId"]
                elif (request_method in ("session/load", "session/resume") and
                      "error" not in message and isinstance(result, dict) and
                      isinstance(session_id, str)):
                    new_session_id = session_id
                if new_session_id is not None:
                    if self.codex and self.lock_in_flight(new_session_id):
                        self.send_editor(error_message(original, -32000,
                                                       "cbox acp: session start in progress"))
                        return
                    self.sessions.add(new_session_id)
                    if self.codex:
                        if not self.start_lock(new_session_id, original, message):
                            self.send_editor(error_message(original, -32000,
                                                           "cbox acp: could not lock session mode"))
                        return
                elif self.codex and "error" not in message:
                    self.send_editor(error_message(original, -32603,
                                                   "cbox acp: invalid session response"))
                    return
            elif request_method == "session/list" and "error" not in message:
                result = message.get("result")
                if not isinstance(result, dict):
                    self.send_editor(error_message(original, -32603, "cbox acp: invalid session list"))
                    return
                visible = []
                rows = result.get("sessions")
                for item in rows if isinstance(rows, list) else []:
                    if not isinstance(item, dict) or not isinstance(item.get("sessionId"), str):
                        continue
                    if not inside(item.get("cwd"), (self.project_root,)):
                        continue
                    cleaned = strip_meta({key: item[key] for key in LIST_FIELDS if key in item})
                    visible.append(cleaned)
                    self.sessions.add(item["sessionId"])
                result = {"sessions": visible, **({"nextCursor": result["nextCursor"]}
                          if isinstance(result.get("nextCursor"), str) else {})}
                message["result"] = result
            elif request_method in ("session/close", "session/delete") and "error" not in message:
                self.sessions.discard(session_id)
                self.mode_ready.discard(session_id)
                self.relock.discard(session_id)
            self.send_editor(message)
            return
        request_id = message.get("id")
        if not isinstance(method, str):
            self.refuse(self.send_agent, request_id, -32600, "invalid method",
                        "agent->editor", "-", "invalid method")
            return
        if method not in AGENT_REQUESTS and not (method in AGENT_NOTIFICATIONS and request_id is None):
            self.refuse(self.send_agent, request_id, -32601,
                        f"cbox acp: {method} blocked", "agent->editor", method, "blocked method")
            return
        if request_id is None and method not in AGENT_NOTIFICATIONS:
            self.log("agent->editor", method, "request sent as notification")
            return
        params = message.get("params", {})
        if not isinstance(params, dict):
            self.refuse(self.send_agent, request_id, -32602, "invalid params",
                        "agent->editor", method, "invalid params")
            return
        if "sessionId" in params and (not isinstance(params["sessionId"], str) or
                                      params["sessionId"] not in self.sessions):
            self.refuse(self.send_agent, request_id, -32602, "cbox acp: foreign sessionId",
                        "agent->editor", method, "foreign sessionId")
            return
        if self.codex and method == "session/update" and "sessionId" in params and self.mode_drifted(params):
            self.relock_session(params["sessionId"])
        if method == "elicitation/create":
            if (not isinstance(params, dict) or "url" in params or
                    (params.get("mode") != "form" and not
                     ("mode" not in params and "requestedSchema" in params))):
                self.refuse(self.send_agent, request_id, -32602,
                            "cbox acp: URL elicitation blocked", "agent->editor", method,
                            "URL elicitation blocked")
                return
        if method in ("session/update", "session/request_permission"):
            cleaned = filter_content(message.get("params", {}), self.roots)
            if cleaned is DROP and method == "session/request_permission":
                self.refuse(self.send_agent, request_id, -32602, "cbox acp: permission request blocked",
                            "agent->editor", method, "permission params removed")
                return
            message["params"] = {} if cleaned is DROP else cleaned
        if request_id is not None:
            if len(self.agent_pending) >= 64:
                self.refuse(self.send_agent, request_id, -32000, "cbox acp: too many requests",
                            "agent->editor", method, "in-flight limit")
                return
            remapped = self.new_id("a")
            self.agent_pending[remapped] = request_id
            message["id"] = remapped
        self.send_editor(message)

    def run(self):
        if self.backend is None:
            reader = LineReader(self.limit)
            while True:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    return 127
                for raw in reader.feed(data):
                    message = self.parse(raw, "editor->agent")
                    if message is not None:
                        self.editor_message(message)
                    if self.startup_error_sent:
                        return 127
        selector = selectors.DefaultSelector()
        selector.register(sys.stdin.fileno(), selectors.EVENT_READ, "editor")
        selector.register(self.backend.stdout, selectors.EVENT_READ, "agent")
        selector.register(self.backend.stderr, selectors.EVENT_READ, "stderr")
        readers = {"editor": LineReader(self.limit), "agent": LineReader(self.limit)}
        closed = set()
        dead_since = None
        while True:
            for key, _ in selector.select(0.05):
                role = key.data
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    closed.add(role)
                    if role == "editor":
                        return self.shutdown()
                    continue
                if role == "stderr":
                    self.capture_stderr(data)
                    continue
                direction = "editor->agent" if role == "editor" else "agent->editor"
                for raw in readers[role].feed(data):
                    message = self.parse(raw, direction)
                    if message is not None:
                        (self.editor_message if role == "editor" else self.agent_message)(message)
                    elif role == "agent" and raw is not None:
                        self.capture_stderr(raw + b"\n")
            if self.backend.poll() is not None:
                if dead_since is None:
                    dead_since = time.monotonic()
            if dead_since is not None and ({"agent", "stderr"} <= closed or
                                           time.monotonic() - dead_since >= 0.1):
                if self.startup_error_sent:
                    return self.backend.returncode
                if not self.initialize_answered and not self.editor_pending:
                    continue
                self.backend_died()
                return self.backend.returncode

    def shutdown(self):
        if self.backend.stdin:
            self.backend.stdin.close()
        try:
            return self.backend.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.backend.terminate()
        try:
            return self.backend.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.backend.kill()
            return self.backend.wait()


def main():
    argv = sys.argv[1:]
    if "--" not in argv:
        raise SystemExit("backend argv required after --")
    split = argv.index("--")
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", action="append", required=True)
    parser.add_argument("--project-root")
    parser.add_argument("--engine", choices=("hermes", "claude", "codex"), default="hermes")
    parser.add_argument("--log")
    parser.add_argument("--max-line-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args(argv[:split])
    command = argv[split + 1:]
    if not command or args.max_line_bytes < 1:
        parser.error("backend argv and positive max-line-bytes required")
    proxy = Proxy(args, command)

    def forward(signum, frame):
        if proxy.backend is not None and proxy.backend.poll() is None:
            proxy.backend.send_signal(signum)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    return proxy.run()


if __name__ == "__main__":
    sys.exit(main())
