#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
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
        self.saved_guard_config = SHIM.GUARD.CONFIG
        SHIM.GUARD.CONFIG = "/does/not/exist/codex_scope.json"
        self.saved_roots = os.environ.pop("CODEX_GUARD_EXTRA_ROOTS", None)
        os.environ["CODEX_GUARD_EXTRA_ROOTS"] = str(ROOT)
        self.good_cwd = str(ROOT)
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
        SHIM.GUARD.CONFIG = self.saved_guard_config
        os.environ.pop("CODEX_GUARD_EXTRA_ROOTS", None)
        if self.saved_roots is not None:
            os.environ["CODEX_GUARD_EXTRA_ROOTS"] = self.saved_roots

    def call_message(self, arguments):
        return {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "codex", "arguments": arguments},
        }

    def test_top_level_base_instructions_rejected(self):
        m = self.call_message({"cwd": self.good_cwd, "base-instructions": "attacker"})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_config_base_instructions_rejected(self):
        m = self.call_message(
            {"cwd": self.good_cwd, "config": {"base_instructions": "attacker"}}
        )
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_config_developer_instructions_case_variant_rejected(self):
        m = self.call_message(
            {"cwd": self.good_cwd, "config": {"Developer-Instructions": "attacker"}}
        )
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_config_instructions_file_rejected(self):
        m = self.call_message(
            {
                "cwd": self.good_cwd,
                "config": {"experimental_instructions_file": "/tmp/attacker"},
            }
        )
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)

    def test_legit_call_forwards_with_kernel_injected(self):
        m = self.call_message({"cwd": self.good_cwd, "prompt": "do the task"})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNone(err)
        args = m["params"]["arguments"]
        self.assertEqual(args["developer-instructions"], "KERNEL")
        self.assertEqual(args["config"]["model_reasoning_effort"], "high")

    def test_missing_cwd_rejected(self):
        m = self.call_message({"prompt": "do the task"})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)
        self.assertIn("EXPLICIT cwd", err)

    def test_relative_cwd_rejected(self):
        m = self.call_message({"cwd": "relative/path", "prompt": "do the task"})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)
        self.assertIn("ABSOLUTE", err)

    def test_nonexistent_cwd_rejected(self):
        m = self.call_message(
            {"cwd": "/this/path/does/not/exist/anywhere", "prompt": "do the task"}
        )
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)
        self.assertIn("not an existing directory", err)

    def test_out_of_scope_cwd_rejected(self):
        m = self.call_message({"cwd": "/tmp", "prompt": "do the task"})
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)
        self.assertIn("outside the allowed scope", err)

    def test_non_git_cwd_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CODEX_GUARD_EXTRA_ROOTS"] = td
            m = self.call_message({"cwd": td, "prompt": "do the task"})
            err = self.relay.rewrite_codex_call(m)
            self.assertIsNotNone(err)
            self.assertIn("git work-tree", err)

    def test_scope_check_runs_before_instruction_key_check(self):
        m = self.call_message(
            {
                "cwd": "/this/path/does/not/exist/anywhere",
                "base-instructions": "attacker",
            }
        )
        err = self.relay.rewrite_codex_call(m)
        self.assertIsNotNone(err)
        self.assertIn("not an existing directory", err)

    def test_codex_reply_does_not_require_cwd(self):
        self.relay.remember_thread(
            {"result": {"structuredContent": {"threadId": "known-thread"}}}
        )
        m = {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "codex-reply",
                "arguments": {"threadId": "known-thread", "prompt": "continue"},
            },
        }
        err = self.relay.rewrite_codex_reply(m)
        self.assertIsNone(err)


class ScopeCheckFunctionTests(unittest.TestCase):
    def setUp(self):
        self.saved_guard_config = SHIM.GUARD.CONFIG
        SHIM.GUARD.CONFIG = "/does/not/exist/codex_scope.json"
        self.saved_roots = os.environ.pop("CODEX_GUARD_EXTRA_ROOTS", None)
        os.environ["CODEX_GUARD_EXTRA_ROOTS"] = str(ROOT)

    def tearDown(self):
        SHIM.GUARD.CONFIG = self.saved_guard_config
        os.environ.pop("CODEX_GUARD_EXTRA_ROOTS", None)
        if self.saved_roots is not None:
            os.environ["CODEX_GUARD_EXTRA_ROOTS"] = self.saved_roots

    def test_valid_cwd_passes(self):
        self.assertIsNone(SHIM.check_cwd_scope_and_git(str(ROOT)))

    def test_missing_cwd_fails(self):
        self.assertIsNotNone(SHIM.check_cwd_scope_and_git(None))
        self.assertIsNotNone(SHIM.check_cwd_scope_and_git(""))

    def test_relative_cwd_fails(self):
        self.assertIsNotNone(SHIM.check_cwd_scope_and_git("relative"))

    def test_nonexistent_cwd_fails(self):
        self.assertIsNotNone(
            SHIM.check_cwd_scope_and_git("/does/not/exist/at/all")
        )

    def test_out_of_scope_cwd_fails(self):
        self.assertIsNotNone(SHIM.check_cwd_scope_and_git("/tmp"))

    def test_non_git_cwd_fails(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CODEX_GUARD_EXTRA_ROOTS"] = td
            self.assertIsNotNone(SHIM.check_cwd_scope_and_git(td))

    def test_uses_same_config_source_as_the_hook(self):
        guard_spec = importlib.util.spec_from_file_location(
            "codex_mode_guard_standalone", ROOT / "etc" / "hooks" / "codex_mode_guard.py"
        )
        guard_standalone = importlib.util.module_from_spec(guard_spec)
        guard_spec.loader.exec_module(guard_standalone)
        guard_standalone.CONFIG = SHIM.GUARD.CONFIG
        cfg = guard_standalone._load_config()
        roots_hook = guard_standalone._allowed_roots(cfg)
        roots_shim = SHIM.GUARD._allowed_roots(SHIM.GUARD._load_config())
        self.assertEqual(roots_hook, roots_shim)
        self.assertIn(str(ROOT.resolve()), roots_shim)


class ShimAuditTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.saved_audit = os.environ.pop("CODEX_SHIM_GUARD_AUDIT", None)
        self.audit_path = os.path.join(self.tmpdir.name, "nested", "audit.jsonl")
        os.environ["CODEX_SHIM_GUARD_AUDIT"] = self.audit_path

    def tearDown(self):
        self.tmpdir.cleanup()
        os.environ.pop("CODEX_SHIM_GUARD_AUDIT", None)
        if self.saved_audit is not None:
            os.environ["CODEX_SHIM_GUARD_AUDIT"] = self.saved_audit

    def _lines(self):
        with open(self.audit_path, encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def test_allow_line_shape(self):
        SHIM.shim_audit("codex-sol", "allow", None, "/zerolab/agent_ecosystem")
        lines = self._lines()
        self.assertEqual(len(lines), 1)
        rec = lines[0]
        self.assertEqual(rec["tier"], "codex-sol")
        self.assertEqual(rec["decision"], "allow")
        self.assertEqual(rec["reason"], "")
        self.assertIsInstance(rec["cwd_sha256"], str)
        self.assertEqual(len(rec["cwd_sha256"]), 16)
        self.assertIn("ts", rec)

    def test_refusal_line_shape_records_reason(self):
        SHIM.shim_audit("codex-terra", "deny", "cwd is not a git work-tree", "/tmp")
        lines = self._lines()
        self.assertEqual(len(lines), 1)
        rec = lines[0]
        self.assertEqual(rec["decision"], "deny")
        self.assertEqual(rec["reason"], "cwd is not a git work-tree")

    def test_appends_rather_than_overwrites(self):
        SHIM.shim_audit("codex-sol", "allow", None, "/zerolab/agent_ecosystem")
        SHIM.shim_audit("codex-luna", "deny", "bad cwd", "/tmp")
        lines = self._lines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0]["tier"], "codex-sol")
        self.assertEqual(lines[1]["tier"], "codex-luna")

    def test_no_raw_cwd_in_audit_line(self):
        SHIM.shim_audit("codex-sol", "allow", None, "/zerolab/agent_ecosystem/secret-path")
        with open(self.audit_path, encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("secret-path", raw)

    def test_refuses_to_follow_a_symlink(self):
        target = os.path.join(self.tmpdir.name, "real.jsonl")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("")
        os.makedirs(os.path.dirname(self.audit_path), exist_ok=True)
        os.symlink(target, self.audit_path)
        SHIM.shim_audit("codex-sol", "allow", None, "/zerolab/agent_ecosystem")
        with open(target, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "")


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


class DescribeFilterTests(unittest.TestCase):
    def test_skip_types_return_none(self):
        for t in SHIM.SKIP:
            self.assertIsNone(SHIM.describe({"type": t}), t)

    def test_delta_types_return_none(self):
        for t in ("agent_message_content_delta", "exec_command_output_delta",
                  "reasoning_content_delta", "plan_delta"):
            self.assertIsNone(SHIM.describe({"type": t}), t)

    def test_milestone_types_describe_nonempty(self):
        self.assertEqual(SHIM.describe({"type": "task_started"}), "task started")
        self.assertEqual(SHIM.describe({"type": "task_complete"}), "task complete")
        self.assertTrue(SHIM.describe(
            {"type": "exec_command_begin", "command": ["ls", "-la"]}).startswith("exec: ls"))
        self.assertEqual(
            SHIM.describe({"type": "agent_message", "message": "hi there"}), "msg: hi there")

    def test_non_string_type_returns_none(self):
        self.assertIsNone(SHIM.describe({"type": None}))
        self.assertIsNone(SHIM.describe({}))


class ProgressStreamTests(unittest.TestCase):
    def _relay(self, progress_on=True):
        r = SHIM.Relay(
            tier="test", model="test", effort="test", progress_on=progress_on,
            child_argv=[sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
            log_path="", depth_stub=False, kernel_text="test",
        )
        self.addCleanup(self._teardown, r)
        return r

    def _teardown(self, r):
        child = r.child
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        child.stdin.close()
        child.stdout.close()

    def _event(self, rid, etype, **fields):
        params = {"_meta": {"requestId": rid}, "msg": dict(type=etype, **fields)}
        return json.dumps({"jsonrpc": "2.0", "method": "codex/event", "params": params})

    def _tools_call(self, rid, token):
        return {"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                "params": {"name": "other-tool", "_meta": {"progressToken": token},
                           "arguments": {}}}

    def test_progresstoken_registered_on_tools_call(self):
        r = self._relay()
        r.on_up(json.dumps(self._tools_call(7, "tok7")).encode() + b"\n")
        self.assertIn(7, r.progress_calls)
        self.assertEqual(r.progress_calls[7][0], "tok7")

    def test_eviction_pops_paired_progress_calls(self):
        r = self._relay()
        for i in range(SHIM.MAX_CALLS + 5):
            r.on_up(json.dumps(self._tools_call(i, "t%d" % i)).encode() + b"\n")
        self.assertEqual(len(r.calls), SHIM.MAX_CALLS)
        self.assertLessEqual(len(r.progress_calls), SHIM.MAX_CALLS,
                             "progress_calls leaked past MAX_CALLS - eviction did not pop the pair")
        self.assertEqual(set(r.calls), set(r.progress_calls),
                         "calls and progress_calls diverged after eviction")

    def test_milestone_event_synthesizes_progress(self):
        r = self._relay()
        r.progress_calls[9] = ["tok9", 0]
        out = r.on_down(self._event(9, "task_started"))
        self.assertEqual(len(out), 2, "expected [raw, synthetic-progress] pair")
        note = json.loads(out[1])
        self.assertEqual(note["method"], "notifications/progress")
        self.assertEqual(note["params"]["progressToken"], "tok9")
        self.assertEqual(note["params"]["message"], "task started")
        self.assertEqual(r.progress_calls[9][1], 1)

    def test_delta_event_passes_raw_only_no_progress(self):
        r = self._relay()
        r.progress_calls[9] = ["tok9", 0]
        out = r.on_down(self._event(9, "agent_message_content_delta", delta="tok"))
        self.assertEqual(len(out), 1, "delta must not synthesize a progress note")

    def test_missing_progresstoken_entry_passes_raw_only(self):
        r = self._relay()
        out = r.on_down(self._event(123, "task_started"))
        self.assertEqual(len(out), 1,
                         "event with no registered progressToken must pass raw with no progress")

    def test_progress_suppressed_when_progress_off(self):
        r = self._relay(progress_on=False)
        r.progress_calls[9] = ["tok9", 0]
        out = r.on_down(self._event(9, "task_started"))
        self.assertEqual(len(out), 1)

    def test_string_meta_rid_coerces_to_int_entry(self):
        r = self._relay()
        r.progress_calls[9] = ["tok9", 0]
        out = r.on_down(self._event("9", "task_started"))
        self.assertEqual(len(out), 2, "string requestId must resolve the int-keyed entry")
        self.assertEqual(json.loads(out[1])["params"]["progressToken"], "tok9")

    def test_int_meta_rid_coerces_to_string_entry(self):
        r = self._relay()
        r.progress_calls["9"] = ["tok9s", 0]
        out = r.on_down(self._event(9, "task_started"))
        self.assertEqual(len(out), 2, "int requestId must resolve the string-keyed entry")
        self.assertEqual(json.loads(out[1])["params"]["progressToken"], "tok9s")

    def test_single_active_fallback_routes_when_meta_rid_absent(self):
        r = self._relay()
        r.progress_calls[9] = ["tok9", 0]
        params = {"msg": {"type": "task_started"}}
        raw = json.dumps({"jsonrpc": "2.0", "method": "codex/event", "params": params})
        out = r.on_down(raw)
        self.assertEqual(len(out), 2,
                         "with exactly one tracked call and no requestId, the single-active "
                         "fallback must route progress to it")
        self.assertEqual(json.loads(out[1])["params"]["progressToken"], "tok9")

    def test_no_fallback_when_multiple_active_and_meta_rid_absent(self):
        r = self._relay()
        r.progress_calls[9] = ["tok9", 0]
        r.progress_calls[10] = ["tok10", 0]
        params = {"msg": {"type": "task_started"}}
        raw = json.dumps({"jsonrpc": "2.0", "method": "codex/event", "params": params})
        out = r.on_down(raw)
        self.assertEqual(len(out), 1,
                         "with 2+ tracked calls and no requestId, progress must NOT be "
                         "guessed - raw passes through with no synthetic note")


if __name__ == "__main__":
    unittest.main()
