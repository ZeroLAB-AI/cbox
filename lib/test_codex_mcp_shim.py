#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "codex_mcp_shim", ROOT / "etc" / "mcp" / "codex_mcp_shim.py"
)
SHIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHIM)


class RelayReplyTests(unittest.TestCase):
    def setUp(self):
        self.relay = SHIM.Relay(
            tier="test",
            model="test",
            effort="test",
            progress_on=False,
            child_argv=[sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
            log_path="",
            depth_stub=False,
            kernel_text="test",
        )
        self.responses = []
        self.relay.reply_direct = self.responses.append

    def tearDown(self):
        child = self.relay.child
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        child.stdin.close()
        child.stdout.close()

    def message(self, rid, thread_id):
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "method": "tools/call",
            "params": {
                "name": "codex-reply",
                "arguments": {"threadId": thread_id, "prompt": "continue"},
            },
        }

    def test_known_thread_forwards(self):
        self.relay.remember_thread(
            {"result": {"structuredContent": {"threadId": "known-thread"}}}
        )
        message = self.message(1, "known-thread")

        forwarded = self.relay.on_up(json.dumps(message).encode() + b"\n")

        self.assertEqual(len(forwarded), 1)
        self.assertEqual(json.loads(forwarded[0]), message)
        self.assertEqual(self.responses, [])

    def test_unknown_thread_returns_relay_error_without_forwarding(self):
        forwarded = self.relay.on_up(
            json.dumps(self.message(2, "unknown-thread")).encode() + b"\n"
        )

        self.assertEqual(forwarded, [])
        self.assertNotIn(2, self.relay.calls)
        self.assertEqual(len(self.responses), 1)
        error = json.loads(self.responses[0])
        self.assertEqual(error["id"], 2)
        self.assertEqual(error["error"]["code"], -32000)
        self.assertEqual(
            error["error"]["message"],
            "thread unknown to this relay - start a new codex call",
        )


class RewriteCodexCallTests(unittest.TestCase):
    def setUp(self):
        self.relay = SHIM.Relay(
            tier="test",
            model="test-model",
            effort="high",
            progress_on=False,
            child_argv=[sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
            log_path="",
            depth_stub=False,
            kernel_text="KERNEL",
        )

    def tearDown(self):
        child = self.relay.child
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        child.stdin.close()
        child.stdout.close()

    def call_message(self, arguments):
        return {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "codex", "arguments": arguments},
        }

    def test_top_level_base_instructions_rejected(self):
        m = self.call_message({"base-instructions": "attacker"})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_config_base_instructions_rejected(self):
        m = self.call_message({"config": {"base_instructions": "attacker"}})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_config_developer_instructions_case_variant_rejected(self):
        m = self.call_message({"config": {"Developer-Instructions": "attacker"}})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_config_instructions_file_rejected(self):
        m = self.call_message(
            {"config": {"experimental_instructions_file": "/tmp/attacker"}}
        )
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_legit_call_forwards_with_kernel_injected(self):
        m = self.call_message({"prompt": "do the task"})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNone(err)
        args = m["params"]["arguments"]
        self.assertEqual(args["developer-instructions"], "KERNEL")
        self.assertEqual(args["config"]["model_reasoning_effort"], "high")


class KernelPathTests(unittest.TestCase):
    def setUp(self):
        self.saved_override = os.environ.pop("CBOX_CONDUCT_KERNEL_PATH", None)
        self.saved_runtime = os.environ.pop("CBOX_RUNTIME", None)
        self.saved_exists = os.path.exists

    def tearDown(self):
        os.environ.pop("CBOX_CONDUCT_KERNEL_PATH", None)
        os.environ.pop("CBOX_RUNTIME", None)
        if self.saved_override is not None:
            os.environ["CBOX_CONDUCT_KERNEL_PATH"] = self.saved_override
        if self.saved_runtime is not None:
            os.environ["CBOX_RUNTIME"] = self.saved_runtime
        os.path.exists = self.saved_exists

    def test_override_honored_outside_container(self):
        os.environ["CBOX_CONDUCT_KERNEL_PATH"] = "/tmp/attacker-kernel.txt"
        self.assertEqual(SHIM.kernel_path(), "/tmp/attacker-kernel.txt")

    def test_override_ignored_inside_container(self):
        os.environ["CBOX_CONDUCT_KERNEL_PATH"] = "/tmp/attacker-kernel.txt"
        os.environ["CBOX_RUNTIME"] = "container"
        os.path.exists = lambda p: True if p == SHIM.DOCKERENV_PATH else self.saved_exists(p)
        self.assertTrue(SHIM.in_container())
        self.assertNotEqual(SHIM.kernel_path(), "/tmp/attacker-kernel.txt")


if __name__ == "__main__":
    unittest.main()
