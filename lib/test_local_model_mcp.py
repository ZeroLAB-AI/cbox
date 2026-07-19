#!/usr/bin/env python3
import http.server
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "local_model_mcp", ROOT / "etc" / "mcp" / "local_model_mcp.py"
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FakeOllamaHandler(http.server.BaseHTTPRequestHandler):
    RESPONSE_TEXT = "hello from fake local model"
    FAIL_MODE = None
    OVERSIZED_BYTES = 0

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/api/tags":
            if self.FAIL_MODE == "health":
                self.send_response(503)
                self.end_headers()
                return
            body = json.dumps({"models": []}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except ValueError:
            payload = {}

        if self.FAIL_MODE == "http500":
            self.send_response(500)
            body = b"internal error"
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.FAIL_MODE == "badjson":
            self.send_response(200)
            body = b"not json"
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.FAIL_MODE == "hang":
            time.sleep(5)
            self.send_response(200)
            self.end_headers()
            return

        text = self.RESPONSE_TEXT
        if self.OVERSIZED_BYTES:
            text = "x" * self.OVERSIZED_BYTES
        resp = {
            "id": "chatcmpl-fake",
            "object": "chat.completion",
            "model": payload.get("model", "fake"),
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }
            ],
        }
        body = json.dumps(resp).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start_fake_server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeOllamaHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


class HealthProbeAndCallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, cls.thread = start_fake_server()
        cls.url = "http://127.0.0.1:%d" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=5)

    def setUp(self):
        FakeOllamaHandler.FAIL_MODE = None
        FakeOllamaHandler.OVERSIZED_BYTES = 0
        os.environ["CBOX_LOCAL_MODEL_URL"] = self.url
        os.environ["CBOX_LOCAL_MODEL_NAME"] = "fake-model"
        os.environ.pop("CBOX_LOCAL_MODEL_MAX_RESPONSE_BYTES", None)
        os.environ.pop("CBOX_LOCAL_MODEL_MAX_PROMPT_BYTES", None)
        os.environ.pop("CBOX_LOCAL_MODEL_TIMEOUT_SEC", None)
        os.environ.pop(MOD.DEPTH_VAR, None)
        os.environ.pop(MOD.LEGACY_DEPTH_VAR, None)

    def test_health_probe_ok(self):
        ok, reason = MOD.health_probe()
        self.assertTrue(ok, reason)

    def test_health_probe_fails_on_server_error(self):
        FakeOllamaHandler.FAIL_MODE = "health"
        ok, reason = MOD.health_probe()
        self.assertFalse(ok)
        self.assertIn("503", reason)

    def test_health_probe_fails_without_url(self):
        os.environ["CBOX_LOCAL_MODEL_URL"] = ""
        ok, reason = MOD.health_probe()
        self.assertFalse(ok)
        self.assertIn("CBOX_LOCAL_MODEL_URL", reason)

    def test_call_endpoint_parses_response_to_text(self):
        text, err = MOD.call_endpoint("hi there", None, None)
        self.assertIsNone(err)
        self.assertEqual(text, FakeOllamaHandler.RESPONSE_TEXT)

    def test_run_local_complete_success(self):
        result = MOD.run_local_complete({"prompt": "hi there"})
        self.assertFalse(result["isError"])
        self.assertEqual(result["content"][0]["text"], FakeOllamaHandler.RESPONSE_TEXT)

    def test_run_local_complete_missing_prompt(self):
        result = MOD.run_local_complete({})
        self.assertTrue(result["isError"])
        self.assertIn("prompt must be", result["content"][0]["text"])

    def test_run_local_complete_bad_temperature(self):
        result = MOD.run_local_complete({"prompt": "hi", "temperature": "hot"})
        self.assertTrue(result["isError"])
        self.assertIn("temperature", result["content"][0]["text"])

    def test_call_endpoint_http_error_surfaces(self):
        FakeOllamaHandler.FAIL_MODE = "http500"
        text, err = MOD.call_endpoint("hi", None, None)
        self.assertIsNone(text)
        self.assertIn("500", err)

    def test_call_endpoint_bad_json_surfaces(self):
        FakeOllamaHandler.FAIL_MODE = "badjson"
        text, err = MOD.call_endpoint("hi", None, None)
        self.assertIsNone(text)
        self.assertIn("non-JSON", err)

    def test_call_endpoint_timeout_surfaces(self):
        FakeOllamaHandler.FAIL_MODE = "hang"
        os.environ["CBOX_LOCAL_MODEL_TIMEOUT_SEC"] = "1"
        text, err = MOD.call_endpoint("hi", None, None)
        self.assertIsNone(text)
        self.assertIn("timed out", err)

    def test_call_endpoint_prompt_too_large(self):
        os.environ["CBOX_LOCAL_MODEL_MAX_PROMPT_BYTES"] = "10"
        text, err = MOD.call_endpoint("this prompt is way too long", None, None)
        self.assertIsNone(text)
        self.assertIn("exceeds max size", err)

    def test_call_endpoint_response_too_large(self):
        FakeOllamaHandler.OVERSIZED_BYTES = 500
        os.environ["CBOX_LOCAL_MODEL_MAX_RESPONSE_BYTES"] = "100"
        text, err = MOD.call_endpoint("hi", None, None)
        self.assertIsNone(text)
        self.assertIn("exceeds max size", err)

    def test_call_endpoint_missing_url(self):
        os.environ["CBOX_LOCAL_MODEL_URL"] = ""
        text, err = MOD.call_endpoint("hi", None, None)
        self.assertIsNone(text)
        self.assertIn("CBOX_LOCAL_MODEL_URL", err)

    def test_call_endpoint_missing_model(self):
        os.environ["CBOX_LOCAL_MODEL_NAME"] = ""
        text, err = MOD.call_endpoint("hi", None, None)
        self.assertIsNone(text)
        self.assertIn("CBOX_LOCAL_MODEL_NAME", err)


class DepthStubTests(unittest.TestCase):
    def setUp(self):
        os.environ["CBOX_LOCAL_MODEL_URL"] = "http://127.0.0.1:1"
        os.environ["CBOX_LOCAL_MODEL_NAME"] = "fake-model"

    def tearDown(self):
        os.environ.pop(MOD.DEPTH_VAR, None)
        os.environ.pop(MOD.LEGACY_DEPTH_VAR, None)

    def test_depth_reached_refuses(self):
        os.environ[MOD.DEPTH_VAR] = "1"
        self.assertTrue(MOD.depth_reached())
        result = MOD.run_local_complete({"prompt": "hi"})
        self.assertTrue(result["isError"])
        self.assertIn("depth limit", result["content"][0]["text"])

    def test_legacy_depth_var_also_refuses(self):
        os.environ[MOD.LEGACY_DEPTH_VAR] = "1"
        self.assertTrue(MOD.depth_reached())

    def test_no_depth_var_not_reached(self):
        self.assertFalse(MOD.depth_reached())


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.audit_path = os.path.join(self.tmpdir, "audit.jsonl")
        os.environ["CBOX_LOCAL_MODEL_AUDIT"] = self.audit_path
        os.environ["CBOX_LOCAL_MODEL_NAME"] = "fake-model"

    def test_audit_writes_no_prompt_content(self):
        MOD.audit("allow", "", 0.5, 10, 20)
        with open(self.audit_path) as fh:
            lines = fh.readlines()
        self.assertEqual(len(lines), 1)
        rec = json.loads(lines[0])
        self.assertEqual(rec["decision"], "allow")
        self.assertEqual(rec["prompt_bytes"], 10)
        self.assertEqual(rec["response_bytes"], 20)
        self.assertNotIn("prompt", rec)
        self.assertNotIn("text", rec)
        self.assertNotIn("content", rec)


class SubprocessStdioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, cls.thread = start_fake_server()
        cls.url = "http://127.0.0.1:%d" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=5)

    def setUp(self):
        FakeOllamaHandler.FAIL_MODE = None
        FakeOllamaHandler.OVERSIZED_BYTES = 0
        self.env = dict(os.environ)
        self.env["CBOX_LOCAL_MODEL_URL"] = self.url
        self.env["CBOX_LOCAL_MODEL_NAME"] = "fake-model"
        self.env.pop("CBOX_DELEGATION_DEPTH", None)
        self.env.pop("CBOX_MCP_DEPTH", None)

    def _run(self, messages, env=None):
        proc = subprocess.run(
            [sys.executable, str(ROOT / "etc" / "mcp" / "local_model_mcp.py")],
            input="".join(json.dumps(m) + "\n" for m in messages).encode(),
            capture_output=True,
            env=env if env is not None else self.env,
            timeout=15,
        )
        lines = [l for l in proc.stdout.decode().splitlines() if l.strip()]
        return proc, [json.loads(l) for l in lines]

    def test_initialize_tools_list_and_call(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2024-11-05"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": {"name": "local-complete",
                        "arguments": {"prompt": "hello"}}},
        ]
        proc, replies = self._run(messages)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(replies[0]["id"], 1)
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"],
                          "cbox-local-model")
        self.assertEqual(replies[1]["id"], 2)
        tool_names = [t["name"] for t in replies[1]["result"]["tools"]]
        self.assertEqual(tool_names, ["local-complete"])
        self.assertEqual(replies[2]["id"], 3)
        self.assertFalse(replies[2]["result"]["isError"])
        self.assertEqual(
            replies[2]["result"]["content"][0]["text"],
            FakeOllamaHandler.RESPONSE_TEXT)

    def test_depth_stub_over_stdio_empty_tools_and_refusal(self):
        env = dict(self.env)
        env["CBOX_DELEGATION_DEPTH"] = "1"
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "local-complete",
                        "arguments": {"prompt": "hello"}}},
        ]
        proc, replies = self._run(messages, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(replies[0]["result"]["tools"], [])
        self.assertTrue(replies[1]["result"]["isError"])
        self.assertIn("depth limit", replies[1]["result"]["content"][0]["text"])

    def test_missing_url_exits_nonzero(self):
        env = dict(self.env)
        env.pop("CBOX_LOCAL_MODEL_URL", None)
        proc, replies = self._run([], env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("CBOX_LOCAL_MODEL_URL", proc.stderr.decode())


if __name__ == "__main__":
    unittest.main()
