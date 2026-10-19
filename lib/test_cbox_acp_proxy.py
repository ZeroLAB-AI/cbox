import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest


PROXY = pathlib.Path(__file__).with_name("cbox_acp_proxy.py")
FAKE = r'''
import json
import os
import signal
import sys

log_path = os.environ["FAKE_LOG"]
mode = os.environ.get("FAKE_MODE", "normal")

def stop(signum, frame):
    open(os.environ["FAKE_SIGNAL"], "w", encoding="ascii").write(str(signum))
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

if mode == "die_immediate":
    sys.stderr.write("immediate cbox failure\n")
    sys.stderr.flush()
    open(os.environ["FAKE_SIGNAL"], "w", encoding="ascii").write("died")
    sys.exit(6)

def send(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

def record(value):
    with open(log_path, "a", encoding="ascii") as stream:
        stream.write(json.dumps(value) + "\n")

if mode == "log_banner":
    sys.stdout.write("cbox: starting container\n")
    sys.stdout.flush()

locks = 0
held = None

for line in sys.stdin:
    value = json.loads(line)
    record(value)
    method = value.get("method")
    if method == "initialize":
        if mode == "log_fail":
            sys.stdout.write("compose failed: network x\n")
            sys.stdout.flush()
            sys.exit(1)
        if mode == "die_before":
            for index in range(205):
                sys.stderr.write("old stderr line %d\n" % index)
            sys.stderr.write("startup detail from cbox\n")
            sys.stderr.flush()
            sys.exit(7)
        if mode == "auth_not_list":
            send({"jsonrpc": "2.0", "id": value["id"], "result": {"authMethods": "bad"}})
            continue
        send({"jsonrpc": "2.0", "id": value["id"], "result": {
            "_meta": {"secret": 1},
            "authMethods": [
                {"id": "agent-id", "name": "Agent"},
                {"id": "agent-typed", "type": "agent"},
                {"id": "terminal-id", "type": "terminal"},
                {"id": "legacy", "command": "setup"},
                {"id": "with-args", "args": ["setup"]},
                {"id": "with-env", "env": {"A": "B"}}]}})
    elif method in ("session/new", "session/load", "session/resume", "session/fork"):
        result = {"sessionId": "sid-" + method.split("/")[1],
                  "modes": {"availableModes": [{"id": "agent"},
                                               {"id": "agent-full-access"}],
                            "currentModeId": "agent"},
                  "configOptions": [{"id": "mode", "currentValue": "agent"}]}
        if mode == "omit_load_id" and method == "session/load":
            del result["sessionId"]
        if mode == "fail_load" and method == "session/load":
            send({"jsonrpc": "2.0", "id": value["id"],
                  "error": {"code": -32002, "message": "session not found"}})
            continue
        send({"jsonrpc": "2.0", "id": value["id"], "result": result})
    elif method == "session/set_mode" and mode in ("drift_hold", "drift_fail", "lock_hold"):
        locks += 1
        if mode == "lock_hold" or (mode == "drift_hold" and locks > 1):
            held = value["id"]
        elif mode == "drift_fail" and locks > 1:
            send({"jsonrpc": "2.0", "id": value["id"],
                  "error": {"code": -32000, "message": "mode failed"}})
        else:
            send({"jsonrpc": "2.0", "id": value["id"], "result": {"ok": True}})
    elif method == "session/set_model" and held is not None:
        send({"jsonrpc": "2.0", "id": held, "result": {"ok": True}})
        held = None
        send({"jsonrpc": "2.0", "id": value["id"], "result": {"ok": True}})
    elif method == "session/set_mode" and mode == "mode_fail":
        send({"jsonrpc": "2.0", "id": value["id"],
              "error": {"code": -32000, "message": "mode failed"}})
    elif method == "session/list":
        if value.get("params", {}).get("cursor") == "bad-shape":
            send({"jsonrpc": "2.0", "id": value["id"], "result": [{"cwd": os.environ["OUTSIDE"]}]})
            continue
        send({"jsonrpc": "2.0", "id": value["id"], "result": {"sessions": [
            {"sessionId": "sid-listed", "cwd": os.environ["ROOT"], "title": "local",
             "updatedAt": "2026-01-01T00:00:00Z", "_meta": {"secret": 1},
             "mode": "agent", "note": "extra"},
            {"sessionId": "sid-extra", "cwd": os.environ["EXTRA"], "title": "extra"},
            {"sessionId": "sid-foreign", "cwd": os.environ["OUTSIDE"], "title": "foreign"},
            {"sessionId": "sid-escape", "cwd": os.environ["ESCAPE"], "title": "escape"},
            {"sessionId": "sid-missing", "title": "missing"}], "nextCursor": "next"}})
    elif method == "session/prompt":
        trigger = value.get("params", {}).get("trigger")
        if trigger == "die":
            sys.stderr.write("runtime detail from cbox\n")
            sys.stderr.flush()
            sys.exit(9)
        if trigger == "blocked":
            for index, blocked in enumerate(("fs/write_text_file", "terminal/create",
                                             "mcp/message", "nes/suggest", "ext/unknown")):
                send({"jsonrpc": "2.0", "id": 100 + index,
                      "method": blocked, "params": {}})
            send({"jsonrpc": "2.0", "method": "document/did_open", "params": {}})
            send({"jsonrpc": "2.0", "id": 110, "method": "elicitation/create",
                  "params": {"mode": "url", "url": "https://example.org"}})
            send({"jsonrpc": "2.0", "id": 111, "method": "elicitation/create",
                  "params": {"mode": "form", "requestedSchema": {"type": "object"}}})
            send({"jsonrpc": "2.0", "method": "elicitation/complete",
                  "params": {"sessionId": "sid-new"}})
        if trigger == "content":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sid-new", "_meta": {"secret": 1},
                "update": {"sessionUpdate": "agent_message_chunk", "_meta": {"secret": 2},
                           "content": [
                    {"type": "text", "path": os.environ["ROOT"] + "/inside.txt", "text": "in"},
                    {"type": "text", "path": os.environ["OUTSIDE"], "text": "out"},
                    {"type": "text", "path": os.environ["ESCAPE"], "text": "escape"},
                    {"type": "text", "uri": "file://" + os.environ["OUTSIDE"], "text": "uri"},
                    {"type": "text", "uri": "file://" + os.environ["ROOT"] + "/inside.txt", "text": "in-uri"},
                    {"type": "terminal", "text": "terminal"},
                    {"type": "text", "text": "safe", "_meta": {"secret": 3}}]}}})
            send({"jsonrpc": "2.0", "id": 120, "method": "session/request_permission",
                  "params": {"sessionId": "sid-new", "toolCall": {
                      "locations": [{"path": os.environ["ROOT"] + "/inside.txt"},
                                    {"path": os.environ["OUTSIDE"]}]}}})
        if trigger == "drift":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sid-new",
                "update": {"sessionUpdate": "current_mode_update", "currentModeId": "agent"}}})
        if trigger == "drift_config":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sid-new",
                "update": {"sessionUpdate": "config_option_update",
                           "configOptions": [{"id": "mode", "currentValue": "agent"}]}}})
        if trigger == "same_mode":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "sid-new",
                "update": {"sessionUpdate": "current_mode_update",
                           "currentModeId": "agent-full-access"}}})
        if trigger == "dropped_permission":
            send({"jsonrpc": "2.0", "id": 140, "method": "session/request_permission",
                  "params": {"sessionId": "sid-new", "path": os.environ["OUTSIDE"]}})
        if trigger == "foreign":
            send({"jsonrpc": "2.0", "method": "session/update",
                  "params": {"sessionId": "foreign", "update": {"text": "bad"}}})
            send({"jsonrpc": "2.0", "id": 130, "method": "session/request_permission",
                  "params": {"sessionId": "foreign"}})
        if trigger == "forged":
            send({"jsonrpc": "2.0", "id": "e:forged:1", "result": {"bad": True}})
            send({"jsonrpc": "2.0", "method": "ext/unknown", "params": {}})
            send({"jsonrpc": "2.0", "method": "_auth/status_update", "params": {"status": "bad"}})
            send({"jsonrpc": "2.0", "method": "session/update",
                  "params": {"sessionId": "sid-new", "padding": "x" * 1000}})
        if trigger == "flood":
            for index in range(65):
                send({"jsonrpc": "2.0", "id": 200 + index,
                      "method": "elicitation/create",
                      "params": {"mode": "form", "requestedSchema": {"type": "object"}}})
        if trigger != "hold":
            send({"jsonrpc": "2.0", "id": value["id"], "result": {"ok": True}})
    elif "id" in value and method is not None:
        send({"jsonrpc": "2.0", "id": value["id"], "result": {"ok": True}})
open(os.environ["FAKE_EOF"], "w", encoding="ascii").write("eof")
'''


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.root = self.base / "root"
        self.root.mkdir()
        self.extra = self.base / "extra"
        self.extra.mkdir()
        self.outside = self.base / "outside.txt"
        self.outside.write_text("outside", encoding="ascii")
        self.escape = self.root / "escape"
        self.escape.symlink_to(self.outside)
        self.fake = self.base / "fake.py"
        self.fake.write_text(FAKE, encoding="ascii")
        self.log = self.base / "backend.jsonl"
        self.proxy_log = self.base / "proxy.log"
        self.eof = self.base / "eof"
        self.signal_file = self.base / "signal"
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("CBOX_")}
        self.environment.update(FAKE_LOG=str(self.log), FAKE_EOF=str(self.eof),
                                FAKE_SIGNAL=str(self.signal_file),
                                ROOT=str(self.root), EXTRA=str(self.extra), OUTSIDE=str(self.outside),
                                ESCAPE=str(self.escape))
        self.process = None
        self.buffer = bytearray()
        self.lines = []

    def tearDown(self):
        if self.process is not None:
            if not self.process.stdin.closed:
                self.process.stdin.close()
            if self.process.poll() is None:
                self.process.wait(timeout=2)
            self.process.stdout.close()
            self.process.stderr.close()

    def start(self, mode="normal", limit=None, backend=None, engine="hermes"):
        self.environment["FAKE_MODE"] = mode
        argv = [sys.executable, str(PROXY), "--root", str(self.root),
                "--root", str(self.extra), "--project-root", str(self.root),
                "--engine", engine,
                "--log", str(self.proxy_log)]
        if limit:
            argv.extend(["--max-line-bytes", str(limit)])
        argv.extend(["--"] + (backend or [sys.executable, str(self.fake)]))
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=self.environment)

    def send(self, method=None, params=None, request_id=1):
        message = {"jsonrpc": "2.0"}
        if method is not None:
            message["method"] = method
            message["params"] = {} if params is None else params
        if request_id is not None:
            message["id"] = request_id
        self.raw(message)

    def raw(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()

    def receive(self, timeout=2):
        end = time.monotonic() + timeout
        while not self.lines:
            remaining = end - time.monotonic()
            self.assertGreater(remaining, 0, "timed out waiting for proxy output")
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            self.assertTrue(ready, "timed out waiting for proxy output")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            self.assertTrue(chunk, "proxy closed stdout")
            self.buffer.extend(chunk)
            while b"\n" in self.buffer:
                line, _, rest = self.buffer.partition(b"\n")
                self.lines.append(json.loads(line))
                self.buffer = bytearray(rest)
        return self.lines.pop(0)

    def initialize(self, capabilities=None):
        params = {"clientCapabilities": capabilities or {}, "auth": {"bad": True},
                  "_meta": {"bad": True}}
        self.send("initialize", params, 1)
        result = self.receive()
        self.assertEqual(result["id"], 1)
        return result

    def new_session(self):
        self.send("session/new", {"cwd": str(self.root)}, 2)
        result = self.receive()
        self.assertEqual(result["result"]["sessionId"], "sid-new")

    def captured(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="ascii").splitlines()]

    def test_initialize_capabilities_auth_and_authenticate(self):
        self.start()
        result = self.initialize({"fs": {"readTextFile": True}, "terminal": True,
                                  "elicitation": {"form": {}, "url": {}}})
        self.assertEqual([item["id"] for item in result["result"]["authMethods"]],
                         ["agent-id", "agent-typed"])
        self.assertNotIn("_meta", result["result"])
        self.send("authenticate", {"methodId": "terminal-id"}, 3)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("authenticate", {"methodId": "agent-id"}, 4)
        self.assertEqual(self.receive()["id"], 4)
        captured = self.captured()[0]
        self.assertEqual(captured["params"]["clientCapabilities"], {
            "fs": {"readTextFile": False, "writeTextFile": False},
            "terminal": False, "elicitation": {"form": {}}})
        self.assertNotIn("auth", captured["params"])
        self.assertNotIn("_meta", captured["params"])
        self.assertEqual(set(captured["params"]), {"clientCapabilities"})

    def test_session_rewrites_paths_and_foreign_ids(self):
        self.start()
        self.initialize()
        self.assertNotIn("elicitation", self.captured()[0]["params"]["clientCapabilities"])
        for index, method in enumerate(("new", "load", "resume", "fork"), 10):
            params = {"cwd": str(self.root), "mcpServers": [{"command": "unsafe"}],
                      "additionalDirectories": [str(self.outside)],
                      "_meta": {"claudeCode": {"options": ["unsafe"]}}}
            if method != "new":
                params["sessionId"] = "sid-new"
            self.send("session/" + method, params, index)
            self.assertEqual(self.receive()["result"]["sessionId"], "sid-" + method)
        for message in self.captured()[1:]:
            self.assertEqual(message["params"]["mcpServers"], [])
            self.assertNotIn("additionalDirectories", message["params"])
            self.assertNotIn("_meta", message["params"])
        self.send("session/new", {"cwd": str(self.outside.parent)}, 20)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        sibling = self.base / "rooted"
        sibling.mkdir()
        self.send("session/new", {"cwd": str(sibling)}, 27)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/new", {"cwd": str(self.escape)}, 21)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/new", {"cwd": "relative"}, 28)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/prompt", {"sessionId": "foreign"}, 22)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/load", {"cwd": str(self.root), "sessionId": "foreign"}, 26)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/prompt", {"sessionId": "sid-new"}, 23)
        self.assertEqual(self.receive()["id"], 23)
        for index, method in enumerate(("session/set_mode", "session/set_model",
                                        "session/set_config_option"), 30):
            self.send(method, {"sessionId": "sid-new"}, index)
            self.assertEqual(self.receive()["id"], index)
        self.send("session/close", {"sessionId": "sid-new"}, 24)
        self.assertEqual(self.receive()["id"], 24)
        self.send("session/prompt", {"sessionId": "sid-new"}, 25)
        self.assertEqual(self.receive()["error"]["code"], -32602)

    def test_project_list_and_delete_policy(self):
        self.start()
        self.initialize()
        self.send("session/list", {"cwd": str(self.outside)}, 2)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/list", {"cwd": str(self.extra)}, 9)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/list", {"cursor": []}, 11)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/list", {"cursor": "bad-shape"}, 12)
        self.assertEqual(self.receive()["error"]["code"], -32603)
        self.send("session/list", {"_meta": {"unsafe": True}, "mcpServers": [{"command": "bad"}]}, 3)
        result = self.receive()["result"]
        self.assertEqual([item["sessionId"] for item in result["sessions"]], ["sid-listed"])
        self.assertEqual(result["nextCursor"], "next")
        self.send("session/delete", {"sessionId": "sid-foreign"}, 4)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/delete", {"sessionId": "sid-extra"}, 10)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/close", {"sessionId": "sid-foreign"}, 5)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/load", {"cwd": str(self.root), "sessionId": "sid-listed",
                                   "mcpServers": [{"command": "bad"}],
                                   "additionalDirectories": [str(self.outside)]}, 6)
        self.assertEqual(self.receive()["result"]["sessionId"], "sid-load")
        self.send("session/delete", {"sessionId": "sid-listed"}, 7)
        self.assertEqual(self.receive()["id"], 7)
        self.send("session/delete", {"sessionId": "sid-listed"}, 8)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        forwarded = self.captured()
        listed = [item for item in forwarded if item.get("method") == "session/list"]
        self.assertEqual(len(listed), 2)
        self.assertNotIn("_meta", listed[1]["params"])
        self.assertNotIn("mcpServers", listed[1]["params"])
        loaded = [item for item in forwarded if item.get("method") == "session/load"]
        self.assertEqual(loaded[0]["params"]["mcpServers"], [])
        self.assertNotIn("additionalDirectories", loaded[0]["params"])

    def test_agent_methods_content_and_responses(self):
        self.start()
        self.initialize()
        self.new_session()
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": "blocked"}, 3)
        forwarded = self.receive()
        self.assertEqual(forwarded["method"], "elicitation/create")
        self.send(params={"action": "accept"}, request_id=forwarded["id"])
        self.assertEqual(self.receive()["method"], "elicitation/complete")
        self.assertEqual(self.receive()["id"], 3)
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": "content"}, 4)
        update = self.receive()
        self.assertEqual(update["method"], "session/update")
        content = update["params"]["update"]["content"]
        self.assertEqual([item["text"] for item in content], ["in", "in-uri", "safe"])
        self.assertNotIn("_meta", update["params"])
        self.assertNotIn("_meta", update["params"]["update"])
        self.assertNotIn("_meta", content[2])
        permission = self.receive()
        self.assertEqual(permission["method"], "session/request_permission")
        self.assertEqual(permission["params"]["toolCall"]["locations"],
                         [{"path": str(self.root / "inside.txt")}])
        self.send(params={"outcome": "cancelled"}, request_id=permission["id"])
        self.assertEqual(self.receive()["id"], 4)
        self.send("session/list", {}, 5)
        self.assertEqual(self.receive()["id"], 5)
        captured = self.captured()
        blocked = [item for item in captured if item.get("id") in list(range(100, 105)) + [110]]
        self.assertEqual(len(blocked), 6)
        self.assertTrue(all(item["error"]["code"] in (-32601, -32602) for item in blocked))
        self.assertIn("blocked method", self.proxy_log.read_text(encoding="utf-8"))
        self.assertNotIn("document/did_open", [item.get("method") for item in captured])
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": "foreign"}, 6)
        self.assertEqual(self.receive()["id"], 6)
        self.send("session/list", {}, 7)
        self.assertEqual(self.receive()["id"], 7)
        self.assertEqual([item["error"]["code"] for item in self.captured()
                          if item.get("id") == 130], [-32602])

    def test_framing_notifications_and_forged_response(self):
        self.start(limit=512)
        self.initialize()
        self.new_session()
        self.process.stdin.write(b"x" * 600 + b"\n")
        self.process.stdin.write(b"[]\n")
        self.raw({"jsonrpc": "2.0", "id": 88, "method": "session/list",
                  "params": {"deep": json.loads("[" * 65 + "0" + "]" * 65)}})
        self.raw({"jsonrpc": "2.0", "id": "a:forged:1", "result": {"bad": True}})
        self.process.stdin.flush()
        self.send("fs/read_text_file", {"secret": "DO_NOT_LOG_BODY"}, None)
        self.send("session/cancel", {"sessionId": "sid-new"}, None)
        self.send("terminal/create", {"secret": "DO_NOT_LOG_BODY"}, 90)
        self.assertEqual(self.receive()["error"]["code"], -32601)
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": "forged"}, 3)
        self.assertEqual(self.receive()["id"], 3)
        self.assertFalse(self.lines)
        log = self.proxy_log.read_text(encoding="utf-8")
        self.assertIn("line over byte limit", log)
        self.assertIn("non-object", log)
        self.assertIn("depth over 64", log)
        self.assertIn("unknown response id", log)
        self.assertIn("blocked method", log)
        self.assertIn("_auth/status_update", log)
        self.assertNotIn("DO_NOT_LOG_BODY", log)
        self.assertEqual(len([item for item in self.captured()
                              if item.get("method") == "session/cancel"]), 1)

    def test_backend_dies_before_initialize(self):
        self.start("die_before")
        self.send("initialize", {}, 1)
        result = self.receive()
        self.assertEqual(result["error"]["code"], -32000)
        self.assertIn("exit 7", result["error"]["message"])
        self.assertIn("startup detail from cbox", result["error"]["message"])
        self.assertNotIn("old stderr line 0\n", result["error"]["message"])
        self.assertLessEqual(len(result["error"]["message"].encode()), 8192)
        self.assertEqual(self.process.wait(timeout=2), 7)
        self.assertIn(b"startup detail from cbox", self.process.stderr.read())

    def test_backend_stdout_log_lines_stay_out_of_editor(self):
        self.start("log_banner")
        result = self.initialize()
        self.assertEqual(result["id"], 1)
        self.assertIn("authMethods", result["result"])
        stderr = b""
        end = time.monotonic() + 2
        while b"cbox: starting container" not in stderr:
            remaining = end - time.monotonic()
            self.assertGreater(remaining, 0, "timed out waiting for proxy stderr")
            ready, _, _ = select.select([self.process.stderr], [], [], remaining)
            self.assertTrue(ready, "timed out waiting for proxy stderr")
            chunk = os.read(self.process.stderr.fileno(), 65536)
            self.assertTrue(chunk, "proxy closed stderr")
            stderr += chunk
        self.assertEqual(self.captured()[0]["method"], "initialize")

    def test_backend_stdout_log_in_startup_error(self):
        self.start("log_fail")
        self.send("initialize", {}, 1)
        result = self.receive()
        self.assertEqual(result["error"]["code"], -32000)
        self.assertIn("exit 1", result["error"]["message"])
        self.assertIn("compose failed: network x", result["error"]["message"])
        self.assertIn(b"compose failed: network x", self.process.stderr.read())

    def test_backend_spawn_failure(self):
        self.start(backend=[str(self.base / "missing-backend")])
        self.send("initialize", {}, 1)
        result = self.receive()
        self.assertEqual(result["error"]["code"], -32000)
        self.assertIn("exit 127", result["error"]["message"])

    def test_backend_dies_before_editor_initializes(self):
        self.start("die_immediate")
        for _ in range(1000):
            if self.signal_file.exists():
                break
            time.sleep(0.001)
        self.assertTrue(self.signal_file.exists())
        self.send("initialize", {}, 1)
        result = self.receive()
        self.assertEqual(result["error"]["code"], -32000)
        self.assertIn("exit 6", result["error"]["message"])
        self.assertIn("immediate cbox failure", result["error"]["message"])

    def test_inflight_limits_in_both_directions(self):
        self.start()
        self.initialize()
        self.new_session()
        for index in range(65):
            self.send("session/prompt", {"sessionId": "sid-new", "trigger": "hold"},
                      1000 + index)
        overflow = self.receive()
        self.assertEqual(overflow["id"], 1064)
        self.assertEqual(overflow["error"]["code"], -32000)
        count = 0
        for _ in range(100):
            count = len([item for item in self.captured()
                         if item.get("method") == "session/prompt"])
            if count == 64:
                break
            time.sleep(0.001)
        self.assertEqual(count, 64)

    def test_agent_inflight_limit(self):
        self.start()
        self.initialize()
        self.new_session()
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": "flood"}, 3)
        forwarded = [self.receive() for _ in range(65)]
        self.assertEqual(len([item for item in forwarded
                              if item.get("method") == "elicitation/create"]), 64)
        self.assertEqual(forwarded[-1]["id"], 3)
        self.send("session/list", {}, 4)
        self.assertEqual(self.receive()["id"], 4)
        errors = [item for item in self.captured() if item.get("id") == 264]
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["error"]["code"], -32000)

    def test_backend_dies_mid_session(self):
        self.start()
        self.initialize()
        self.new_session()
        self.send("session/load", {"cwd": str(self.root), "sessionId": "sid-new"}, 4)
        self.assertEqual(self.receive()["result"]["sessionId"], "sid-load")
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": "hold"}, 3)
        self.send("session/prompt", {"sessionId": "sid-load", "trigger": "die"}, 5)
        updates = [self.receive(), self.receive()]
        self.assertEqual({item["params"]["sessionId"] for item in updates},
                         {"sid-new", "sid-load"})
        self.assertTrue(all(item["method"] == "session/update" for item in updates))
        text = updates[0]["params"]["update"]["content"]["text"]
        self.assertIn("runtime detail from cbox", text)
        self.assertIn("code 9", text)
        failures = [self.receive(), self.receive()]
        self.assertEqual({item["id"] for item in failures}, {3, 5})
        self.assertTrue(all(item["error"]["code"] == -32000 for item in failures))
        self.assertTrue(all(item["error"]["message"] == text for item in failures))

    def test_codex_locks_each_session_and_mode_changes(self):
        self.start(engine="codex")
        self.initialize()
        self.send("session/list", {}, 2)
        self.assertEqual(self.receive()["result"]["sessions"][0]["sessionId"], "sid-listed")
        self.send("session/prompt", {"sessionId": "sid-listed"}, 3)
        self.assertEqual(self.receive()["error"]["message"], "cbox acp: session mode not ready")
        self.send("session/load", {"cwd": str(self.root), "sessionId": "sid-listed"}, 4)
        loaded = self.receive()["result"]
        self.assertEqual(loaded["modes"]["currentModeId"], "agent-full-access")
        self.assertEqual(loaded["configOptions"][0]["currentValue"], "agent-full-access")
        for index, method in enumerate(("session/new", "session/resume", "session/fork"), 5):
            params = {"cwd": str(self.root)}
            if method != "session/new":
                params["sessionId"] = "sid-load"
            self.send(method, params, index)
            self.assertEqual(self.receive()["result"]["modes"]["currentModeId"],
                             "agent-full-access")
        for index, method in enumerate(("session/set_mode", "session/set_config_option"), 10):
            params = {"sessionId": "sid-new", "modeId": "agent"} if method.endswith("set_mode") else {
                "sessionId": "sid-new", "configId": "mode", "value": "agent"}
            self.send(method, params, index)
            self.assertEqual(self.receive()["error"]["message"], "cbox acp: mode locked")
        self.send("session/prompt", {"sessionId": "sid-new"}, 12)
        self.assertEqual(self.receive()["id"], 12)
        internal = [item for item in self.captured() if item.get("method") == "session/set_mode"]
        self.assertEqual(len(internal), 4)
        self.assertTrue(all(item["params"]["modeId"] == "agent-full-access"
                            for item in internal))

    def test_codex_mode_lock_failure_refuses_session(self):
        self.start(mode="mode_fail", engine="codex")
        self.initialize()
        self.send("session/new", {"cwd": str(self.root)}, 2)
        self.assertEqual(self.receive()["error"]["message"],
                         "cbox acp: could not lock session mode")
        self.send("session/prompt", {"sessionId": "sid-new"}, 3)
        self.assertEqual(self.receive()["error"]["code"], -32602)

    def test_codex_failed_load_passes_error_without_mode_lock(self):
        self.start(mode="fail_load", engine="codex")
        self.initialize()
        self.send("session/list", {}, 2)
        self.assertEqual(self.receive()["result"]["sessions"][0]["sessionId"], "sid-listed")
        self.send("session/load", {"cwd": str(self.root), "sessionId": "sid-listed"}, 4)
        reply = self.receive()
        self.assertEqual(reply["id"], 4)
        self.assertIn("error", reply)
        internal = [item for item in self.captured() if item.get("method") == "session/set_mode"]
        self.assertEqual(internal, [])

    def test_codex_load_without_session_id_still_locks_mode(self):
        self.start(mode="omit_load_id", engine="codex")
        self.initialize()
        self.send("session/list", {}, 2)
        self.assertEqual(self.receive()["result"]["sessions"][0]["sessionId"], "sid-listed")
        self.send("session/load", {"cwd": str(self.root), "sessionId": "sid-listed"}, 4)
        loaded = self.receive()["result"]
        self.assertNotIn("sessionId", loaded)
        self.assertEqual(loaded["modes"]["currentModeId"], "agent-full-access")
        self.assertEqual(loaded["configOptions"][0]["currentValue"], "agent-full-access")
        internal = [item for item in self.captured() if item.get("method") == "session/set_mode"]
        self.assertEqual(len(internal), 1)
        self.assertEqual(internal[0]["params"]["sessionId"], "sid-listed")
        self.assertEqual(internal[0]["params"]["modeId"], "agent-full-access")
        self.send("session/prompt", {"sessionId": "sid-listed"}, 5)
        self.assertEqual(self.receive()["id"], 5)

    def test_session_start_cwd_bound_to_project_root(self):
        self.start()
        self.initialize()
        self.new_session()
        for index, method in enumerate(("new", "load", "resume", "fork"), 40):
            params = {"cwd": str(self.extra)}
            if method != "new":
                params["sessionId"] = "sid-new"
            self.send("session/" + method, params, index)
            reply = self.receive()
            self.assertEqual(reply["error"]["code"], -32602)
            self.assertIn("cwd outside project roots", reply["error"]["message"])
        self.assertEqual([item for item in self.captured()
                          if item.get("method") in ("session/load", "session/resume",
                                                    "session/fork")], [])

    def test_missing_or_bad_session_id_refused(self):
        self.start()
        self.initialize()
        self.new_session()
        index = 50
        for method in ("session/load", "session/resume", "session/fork", "session/close",
                       "session/delete", "session/prompt", "session/set_mode",
                       "session/set_model", "session/set_config_option"):
            for params in ({}, {"sessionId": 5}, {"sessionId": None}):
                params = dict(params, cwd=str(self.root))
                self.send(method, params, index)
                self.assertEqual(self.receive()["error"]["code"], -32602, method)
                index += 1
        self.send("session/cancel", {}, None)
        self.send("session/cancel", {"sessionId": 5}, None)
        self.send("session/list", {}, index)
        self.assertEqual(self.receive()["id"], index)
        forwarded = [item.get("method") for item in self.captured()]
        self.assertNotIn("session/cancel", forwarded)
        self.assertEqual(forwarded.count("session/new"), 1)
        self.send("session/new", {"cwd": str(self.root)}, index + 1)
        self.assertEqual(self.receive()["result"]["sessionId"], "sid-new")

    def test_codex_concurrent_start_for_same_session_refused(self):
        self.start(engine="codex")
        self.initialize()
        self.send("session/list", {}, 2)
        self.receive()
        two = [{"jsonrpc": "2.0", "id": 3, "method": "session/load",
                "params": {"cwd": str(self.root), "sessionId": "sid-listed"}},
               {"jsonrpc": "2.0", "id": 4, "method": "session/resume",
                "params": {"cwd": str(self.root), "sessionId": "sid-listed"}},
               {"jsonrpc": "2.0", "id": 5, "method": "session/prompt",
                "params": {"sessionId": "sid-listed"}}]
        self.process.stdin.write(b"".join((json.dumps(item) + "\n").encode() for item in two))
        self.process.stdin.flush()
        replies = {}
        for _ in range(3):
            reply = self.receive()
            replies[reply["id"]] = reply
        self.assertEqual(replies[3]["result"]["sessionId"], "sid-load")
        self.assertEqual(replies[4]["error"]["message"], "cbox acp: session start in progress")
        self.assertEqual(replies[5]["error"]["message"], "cbox acp: session start in progress")
        internal = [item for item in self.captured() if item.get("method") == "session/set_mode"]
        self.assertEqual(len(internal), 1)

    def test_codex_start_refused_while_lock_in_flight(self):
        self.start(mode="lock_hold", engine="codex")
        self.initialize()
        self.send("session/new", {"cwd": str(self.root)}, 2)
        for _ in range(500):
            if [item for item in self.captured() if item.get("method") == "session/set_mode"]:
                break
            time.sleep(0.01)
        self.send("session/load", {"cwd": str(self.root), "sessionId": "sid-new"}, 3)
        refused = self.receive()
        self.assertEqual(refused["id"], 3)
        self.assertEqual(refused["error"]["message"], "cbox acp: session start in progress")
        self.send("session/prompt", {"sessionId": "sid-new"}, 4)
        self.assertEqual(self.receive()["error"]["message"],
                         "cbox acp: session start in progress")
        self.send("session/set_model", {"sessionId": "sid-new"}, 5)
        self.assertEqual(self.receive()["result"]["sessionId"], "sid-new")
        self.assertEqual(self.receive()["id"], 5)
        self.send("session/prompt", {"sessionId": "sid-new"}, 6)
        self.assertEqual(self.receive()["id"], 6)

    def drift_session(self, mode, trigger):
        self.start(mode=mode, engine="codex")
        self.initialize()
        self.new_session()
        self.send("session/prompt", {"sessionId": "sid-new"}, 3)
        self.assertEqual(self.receive()["id"], 3)
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": trigger}, 4)
        update = self.receive()
        self.assertEqual(update["method"], "session/update")
        self.assertEqual(self.receive()["id"], 4)

    def test_codex_mode_drift_relocks_and_blocks_prompts(self):
        for trigger in ("drift", "drift_config"):
            self.drift_session("drift_hold", trigger)
            self.send("session/prompt", {"sessionId": "sid-new"}, 5)
            self.assertEqual(self.receive()["error"]["message"], "cbox acp: session start in progress")
            internal = [item for item in self.captured() if item.get("method") == "session/set_mode"]
            self.assertEqual(len(internal), 2)
            self.assertEqual(internal[1]["params"], {"sessionId": "sid-new",
                                                     "modeId": "agent-full-access"})
            self.send("session/set_model", {"sessionId": "sid-new"}, 6)
            self.assertEqual(self.receive()["id"], 6)
            self.send("session/prompt", {"sessionId": "sid-new"}, 7)
            self.assertEqual(self.receive()["id"], 7)
            self.process.stdin.close()
            self.process.wait(timeout=2)
            self.process.stdout.close()
            self.process.stderr.close()
            self.process = None
            self.log.unlink()

    def test_codex_mode_drift_lock_failure_fails_session_closed(self):
        self.drift_session("drift_fail", "drift")
        for _ in range(200):
            if len([item for item in self.captured()
                    if item.get("method") == "session/set_mode"]) == 2:
                break
            time.sleep(0.01)
        time.sleep(0.1)
        self.send("session/prompt", {"sessionId": "sid-new"}, 5)
        self.assertEqual(self.receive()["error"]["code"], -32602)
        self.send("session/set_model", {"sessionId": "sid-new"}, 6)
        self.assertEqual(self.receive()["error"]["message"], "cbox acp: foreign sessionId")

    def test_codex_same_mode_update_does_not_relock(self):
        self.drift_session("normal", "same_mode")
        self.send("session/prompt", {"sessionId": "sid-new"}, 5)
        self.assertEqual(self.receive()["id"], 5)
        internal = [item for item in self.captured() if item.get("method") == "session/set_mode"]
        self.assertEqual(len(internal), 1)

    def test_initialize_auth_methods_not_a_list(self):
        self.start("auth_not_list")
        result = self.initialize()
        self.assertEqual(result["result"]["authMethods"], [])

    def test_permission_with_params_removed_answers_agent_with_error(self):
        self.start()
        self.initialize()
        self.new_session()
        self.send("session/prompt", {"sessionId": "sid-new", "trigger": "dropped_permission"}, 3)
        self.assertEqual(self.receive()["id"], 3)
        self.assertEqual([item["error"]["code"] for item in self.captured()
                          if item.get("id") == 140], [-32602])
        self.assertFalse(self.lines)

    def test_session_list_rows_keep_only_allowed_fields(self):
        self.start()
        self.initialize()
        self.send("session/list", {}, 2)
        rows = self.receive()["result"]["sessions"]
        self.assertEqual(rows, [{"sessionId": "sid-listed", "cwd": str(self.root),
                                 "title": "local", "updatedAt": "2026-01-01T00:00:00Z"}])

    def test_editor_eof_closes_backend(self):
        self.start()
        self.initialize()
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=2), 0)
        self.assertEqual(self.eof.read_text(encoding="ascii"), "eof")

    def test_signals_forwarded_to_backend(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            self.start()
            self.initialize()
            self.process.send_signal(signum)
            self.assertEqual(self.process.wait(timeout=2), 0)
            self.assertEqual(self.signal_file.read_text(encoding="ascii"), str(signum))
            self.process.stdin.close()
            self.process.stdout.close()
            self.process.stderr.close()
            self.process = None


if __name__ == "__main__":
    unittest.main()
