#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "codex_mcp_shim", ROOT / "etc" / "mcp" / "codex_mcp_shim.py"
)
SHIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHIM)

STUB = ROOT / "lib" / "fixtures" / "stub_app_server.py"
DUMMY_CHILD = [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"]


def stub_child():
    return [sys.executable, str(STUB)]


class RelayHarness(unittest.TestCase):
    def setUp(self):
        self.saved_guard_config = SHIM.GUARD.CONFIG
        SHIM.GUARD.CONFIG = "/does/not/exist/codex_scope.json"
        self.saved_roots = os.environ.pop("CODEX_GUARD_EXTRA_ROOTS", None)
        os.environ["CODEX_GUARD_EXTRA_ROOTS"] = str(ROOT)
        self.good_cwd = str(ROOT)
        self.saved_stub_mode = os.environ.pop("STUB_APP_SERVER_MODE", None)
        self.saved_stub_state = os.environ.pop("STUB_APP_SERVER_STATE_FILE", None)
        self.saved_codex_home = os.environ.pop("CODEX_HOME", None)
        self._codex_home_dir = tempfile.TemporaryDirectory()
        os.environ["CODEX_HOME"] = self._codex_home_dir.name
        self._relays = []

    def tearDown(self):
        for relay in self._relays:
            proc = relay.backend.proc
            if proc is None:
                continue
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except Exception:
                    proc.kill()
            for stream in (proc.stdin, proc.stdout):
                try:
                    stream.close()
                except Exception:
                    pass
        SHIM.GUARD.CONFIG = self.saved_guard_config
        os.environ.pop("CODEX_GUARD_EXTRA_ROOTS", None)
        if self.saved_roots is not None:
            os.environ["CODEX_GUARD_EXTRA_ROOTS"] = self.saved_roots
        os.environ.pop("STUB_APP_SERVER_MODE", None)
        if self.saved_stub_mode is not None:
            os.environ["STUB_APP_SERVER_MODE"] = self.saved_stub_mode
        os.environ.pop("STUB_APP_SERVER_STATE_FILE", None)
        if self.saved_stub_state is not None:
            os.environ["STUB_APP_SERVER_STATE_FILE"] = self.saved_stub_state
        os.environ.pop("CODEX_HOME", None)
        if self.saved_codex_home is not None:
            os.environ["CODEX_HOME"] = self.saved_codex_home
        self._codex_home_dir.cleanup()

    def make_relay(self, child_argv=None, model="test-model", effort="high",
                   progress_on=False, depth_stub=False, tier="test"):
        relay = SHIM.Relay(
            tier=tier, model=model, effort=effort, progress_on=progress_on,
            child_argv=child_argv or DUMMY_CHILD, log_path="",
            depth_stub=depth_stub, kernel_text="KERNEL",
        )
        self.sent = []
        self.sent_lock = threading.Lock()

        def capturing_send(obj):
            with self.sent_lock:
                self.sent.append(obj)

        relay.send = capturing_send
        self._relays.append(relay)
        return relay

    def sent_for(self, rid):
        with self.sent_lock:
            for obj in self.sent:
                if obj.get("id") == rid and "method" not in obj:
                    return obj
        return None

    def wait_for_reply(self, rid, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = self.sent_for(rid)
            if found is not None:
                return found
            time.sleep(0.01)
        return None

    def call_message(self, name, arguments, rid=1):
        return {"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                "params": {"name": name, "arguments": arguments}}


class PolicyRejectTests(RelayHarness):
    def test_top_level_base_instructions_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd, "base-instructions": "x"}, None)
        resp = self.sent_for(1)
        self.assertEqual(resp["error"]["code"], -32000)

    def test_config_developer_instructions_case_variant_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"Developer-Instructions": "x"}}, None)
        resp = self.sent_for(1)
        self.assertEqual(resp["error"]["code"], -32000)

    def test_config_instructions_file_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"experimental_instructions_file": "/x"}}, None)
        self.assertEqual(self.sent_for(1)["error"]["code"], -32000)

    def test_top_level_profile_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd, "profile": "attacker-profile"}, None)
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("profile", err["message"])

    def test_top_level_model_provider_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd, "model_provider": "evil"}, None)
        self.assertEqual(self.sent_for(1)["error"]["code"], -32000)

    def test_config_model_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd, "config": {"model": "other"}}, None)
        self.assertEqual(self.sent_for(1)["error"]["code"], -32000)

    def test_config_model_provider_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"model_provider": "evil"}}, None)
        self.assertEqual(self.sent_for(1)["error"]["code"], -32000)

    def test_config_profile_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd, "config": {"profile": "evil"}}, None)
        self.assertEqual(self.sent_for(1)["error"]["code"], -32000)

    def test_config_notify_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"notify": ["/x"]}}, None)
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("notify", err["message"])

    def test_config_shell_environment_policy_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"shell_environment_policy": "inherit"}}, None)
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("shell_environment_policy", err["message"])

    def test_config_dotted_key_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"model_providers.openai.base_url":
                                          "http://attacker"}}, None)
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("model_providers.openai.base_url", err["message"])

    def test_config_mcp_servers_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"mcp_servers": {"s": {"command": "x"}}}}, None)
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("mcp_servers", err["message"])

    def test_config_arbitrary_string_key_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"totally_arbitrary": 5}}, None)
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("totally_arbitrary", err["message"])

    def test_config_nested_dict_value_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": self.good_cwd,
                               "config": {"model_verbosity":
                                          {"deep": {"deeper": True}}}}, None)
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("model_verbosity", err["message"])

    def test_missing_cwd_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"prompt": "do the task"}, None)
        self.assertIn("EXPLICIT cwd", self.sent_for(1)["error"]["message"])

    def test_relative_cwd_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": "relative/path", "prompt": "x"}, None)
        self.assertIn("ABSOLUTE", self.sent_for(1)["error"]["message"])

    def test_nonexistent_cwd_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": "/this/path/does/not/exist/anywhere",
                               "prompt": "x"}, None)
        self.assertIn("not an existing directory", self.sent_for(1)["error"]["message"])

    def test_out_of_scope_cwd_rejected(self):
        relay = self.make_relay()
        relay._call_codex(1, {"cwd": "/tmp", "prompt": "x"}, None)
        self.assertIn("outside the allowed scope", self.sent_for(1)["error"]["message"])

    def test_non_git_cwd_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["CODEX_GUARD_EXTRA_ROOTS"] = td
            relay = self.make_relay()
            relay._call_codex(1, {"cwd": td, "prompt": "x"}, None)
            self.assertIn("git work-tree", self.sent_for(1)["error"]["message"])

    def test_scope_check_runs_before_instruction_key_check(self):
        relay = self.make_relay()
        relay._call_codex(
            1, {"cwd": "/this/path/does/not/exist/anywhere",
                "base-instructions": "attacker"}, None,
        )
        self.assertIn("not an existing directory", self.sent_for(1)["error"]["message"])

    def test_codex_reply_unknown_thread_denied_without_backend(self):
        relay = self.make_relay()
        relay._call_codex_reply(2, {"threadId": "nope", "prompt": "continue"}, None)
        err = self.sent_for(2)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertEqual(err["message"],
                          "thread unknown to this relay - start a new codex call")
        self.assertIsNone(relay.backend.proc)

    def test_config_allowlisted_key_passes(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        relay._call_codex(1, {"cwd": self.good_cwd, "prompt": "hi",
                               "config": {"model_reasoning_summary": "auto"}}, None)
        resp = self.wait_for_reply(1)
        self.assertIsNotNone(resp, "call with an allow-listed config key hung")
        self.assertNotIn("error", resp)
        self.assertIn("STUB-REPLY", resp["result"]["content"][0]["text"])


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
        self.assertIsNotNone(SHIM.check_cwd_scope_and_git("/does/not/exist/at/all"))

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


class PolicyCheckFunctionTests(unittest.TestCase):
    def test_top_level_reject_keys(self):
        for key in ("profile", "model_provider", "Profile", "Model-Provider"):
            err = SHIM.policy_check_args({key: "x"}, None)
            self.assertIsNotNone(err, key)

    def test_config_allow_list(self):
        for key in ("model_reasoning_effort", "model_reasoning_summary",
                    "model_verbosity", "hide_agent_reasoning",
                    "Model-Reasoning-Summary"):
            err = SHIM.policy_check_args({}, {key: "auto"})
            self.assertIsNone(err, "allow-listed key was rejected: %r" % key)

    def test_config_reject_keys(self):
        for key in ("model", "model_provider", "profile", "notify",
                    "shell_environment_policy", "mcp_servers",
                    "model_providers.openai.base_url", "totally_arbitrary",
                    "sandbox_mode", "approval_policy", "profiles"):
            err = SHIM.policy_check_args({}, {key: "x"})
            self.assertIsNotNone(err, key)
            if key != "totally_arbitrary":
                self.assertIn(key, err, "error must name the key: %s" % key)

    def test_config_non_scalar_values_rejected(self):
        for value in ({"a": 1}, [1, 2]):
            for key in ("model_reasoning_effort", "hide_agent_reasoning"):
                err = SHIM.policy_check_args({}, {key: value})
                self.assertIsNotNone(err, (key, value))

    def test_model_reasoning_effort_not_rejected(self):
        err = SHIM.policy_check_args({}, {"model_reasoning_effort": "high"})
        self.assertIsNone(err)

    def test_clean_args_pass(self):
        err = SHIM.policy_check_args(
            {"cwd": "/x", "prompt": "y"},
            {"model_reasoning_summary": "auto", "hide_agent_reasoning": True},
        )
        self.assertIsNone(err)


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
        SHIM.shim_audit("codex-tier-a", "allow", None, "/zerolab/agent_ecosystem")
        lines = self._lines()
        self.assertEqual(len(lines), 1)
        rec = lines[0]
        self.assertEqual(rec["tier"], "codex-tier-a")
        self.assertEqual(rec["decision"], "allow")
        self.assertEqual(rec["reason"], "")
        self.assertIsInstance(rec["cwd_sha256"], str)
        self.assertEqual(len(rec["cwd_sha256"]), 16)
        self.assertIn("ts", rec)

    def test_refusal_line_shape_records_reason(self):
        SHIM.shim_audit("codex-tier-b", "deny", "cwd is not a git work-tree", "/tmp")
        lines = self._lines()
        self.assertEqual(len(lines), 1)
        rec = lines[0]
        self.assertEqual(rec["decision"], "deny")
        self.assertEqual(rec["reason"], "cwd is not a git work-tree")

    def test_appends_rather_than_overwrites(self):
        SHIM.shim_audit("codex-tier-a", "allow", None, "/zerolab/agent_ecosystem")
        SHIM.shim_audit("codex-tier-b", "deny", "bad cwd", "/tmp")
        lines = self._lines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0]["tier"], "codex-tier-a")
        self.assertEqual(lines[1]["tier"], "codex-tier-b")

    def test_no_raw_cwd_in_audit_line(self):
        SHIM.shim_audit("codex-tier-a", "allow", None, "/zerolab/agent_ecosystem/secret-path")
        with open(self.audit_path, encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("secret-path", raw)

    def test_refuses_to_follow_a_symlink(self):
        target = os.path.join(self.tmpdir.name, "real.jsonl")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("")
        os.makedirs(os.path.dirname(self.audit_path), exist_ok=True)
        os.symlink(target, self.audit_path)
        SHIM.shim_audit("codex-tier-a", "allow", None, "/zerolab/agent_ecosystem")
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


class ItemProgressAndExtractionTests(unittest.TestCase):
    def test_extract_final_text_prefers_final_answer(self):
        turn = {"items": [
            {"type": "agentMessage", "phase": "draft", "text": "draft text"},
            {"type": "agentMessage", "phase": "final_answer", "text": "final text"},
        ]}
        self.assertEqual(SHIM.extract_final_text(turn), "final text")

    def test_extract_final_text_falls_back_to_last_agent_message(self):
        turn = {"items": [{"type": "agentMessage", "text": "only one"}]}
        self.assertEqual(SHIM.extract_final_text(turn), "only one")

    def test_extract_final_text_no_items(self):
        self.assertEqual(SHIM.extract_final_text({"items": []}), "")
        self.assertEqual(SHIM.extract_final_text({}), "")

    def test_extract_turn_error_prefers_additional_details(self):
        turn = {"error": {"additionalDetails": "boom"}}
        self.assertEqual(SHIM.extract_turn_error(turn), "boom")

    def test_item_progress_text_command_execution(self):
        self.assertTrue(
            SHIM.item_progress_text(
                "item/started", {"type": "commandExecution", "command": "ls"}
            ).startswith("exec:")
        )

    def test_item_progress_text_delta_like_types_return_none(self):
        self.assertIsNone(SHIM.item_progress_text("item/started", {"type": "reasoning"}))


class PdeathsigArgvPrefixTests(unittest.TestCase):
    CHILD = [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"]

    def _spawn(self, which_fake):
        backend = SHIM.CodexBackend(
            self.CHILD, "test", lambda *a, **kw: None, lambda *a, **kw: None,
        )
        with mock.patch.object(SHIM.shutil, "which", which_fake):
            proc = backend._spawn_child(self.CHILD, dict(os.environ))
        return backend, proc

    def test_spawn_argv_prefixed_with_setpriv_pdeathsig_when_available(self):
        fake_setpriv = os.path.join(tempfile.mkdtemp(), "setpriv")
        with open(fake_setpriv, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                "while [ $# -gt 0 ]; do\n"
                "  case \"$1\" in\n"
                "    --pdeathsig) shift; shift ;;\n"
                "    *) break ;;\n"
                "  esac\n"
                "done\n"
                "exec \"$@\"\n"
            )
        os.chmod(fake_setpriv, 0o755)
        real_which = shutil.which

        def which_fake(name):
            if name == "setpriv":
                return fake_setpriv
            return real_which(name)

        backend, proc = self._spawn(which_fake)
        self.assertEqual(proc.args[:3], [fake_setpriv, "--pdeathsig", "KILL"])
        self.assertEqual(
            proc.args[3:],
            [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
        )
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    def test_spawn_argv_plain_when_setpriv_is_missing(self):
        real_which = shutil.which

        def which_fake(name):
            if name == "setpriv":
                return None
            return real_which(name)

        backend, proc = self._spawn(which_fake)
        self.assertEqual(
            proc.args,
            [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
        )
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


class IntegrationHarness(RelayHarness):
    def start_and_wait(self, relay, name, args, rid, timeout=10):
        relay.dispatch(self.call_message(name, args, rid))
        return self.wait_for_reply(rid, timeout=timeout)


class NewConversationAndReplyTests(IntegrationHarness):
    def test_new_conversation_then_reply(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child(), model="pinned-model-a")
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "Reply with PONG"}, 1,
        )
        self.assertIsNotNone(resp, "no reply within timeout")
        self.assertNotIn("error", resp)
        self.assertIn("STUB-REPLY", resp["result"]["content"][0]["text"])
        thread_id = resp["result"]["structuredContent"]["threadId"]

        resp2 = self.start_and_wait(
            relay, "codex-reply", {"threadId": thread_id, "prompt": "PONG2"}, 2,
        )
        self.assertIsNotNone(resp2)
        self.assertNotIn("error", resp2)
        self.assertEqual(resp2["result"]["structuredContent"]["threadId"], thread_id)

    def test_unknown_thread_denied_after_real_conversation(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        relay._call_codex_reply(2, {"threadId": "not-a-real-thread",
                                     "prompt": "continue"}, None)
        err = self.sent_for(2)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertEqual(err["message"],
                          "thread unknown to this relay - start a new codex call")


class ModelPinMismatchTests(IntegrationHarness):
    def test_mismatch_fails_call(self):
        os.environ["STUB_APP_SERVER_MODE"] = "mismatch"
        relay = self.make_relay(child_argv=stub_child(), model="pinned-model-b")
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp)
        self.assertEqual(resp["error"]["code"], -32000)
        self.assertIn("model pin mismatch", resp["error"]["message"])


class FailedTurnTests(IntegrationHarness):
    def test_failed_turn_reports_error_content(self):
        os.environ["STUB_APP_SERVER_MODE"] = "fail_turn"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp)
        self.assertNotIn("error", resp)
        result = resp["result"]
        self.assertTrue(result["isError"])
        self.assertIn("stub induced failure", result["content"][0]["text"])


class ApprovalDenyTests(IntegrationHarness):
    def test_approval_request_answered_with_deny_and_call_still_completes(self):
        os.environ["STUB_APP_SERVER_MODE"] = "approval"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp, "call hung instead of completing after approval deny")
        self.assertNotIn("error", resp)
        self.assertIn("STUB-REPLY", resp["result"]["content"][0]["text"])


class ChildCrashTests(IntegrationHarness):
    def test_crash_on_init_fails_call_with_exit_code(self):
        os.environ["STUB_APP_SERVER_MODE"] = "crash_on_init"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp)
        self.assertEqual(resp["error"]["code"], -32000)
        self.assertIn("exited", resp["error"]["message"])


class CancelInterruptTests(IntegrationHarness):
    def test_cancel_triggers_turn_interrupt_and_sends_no_reply(self):
        os.environ["STUB_APP_SERVER_MODE"] = "cancel"
        relay = self.make_relay(child_argv=stub_child())

        def run_call():
            relay.dispatch(self.call_message(
                "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
            ))

        t = threading.Thread(target=run_call, daemon=True)
        t.start()

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with relay.call_lock:
                if 1 in relay.call_threads:
                    break
            time.sleep(0.01)
        self.assertIn(1, relay.call_threads, "turn never registered for interrupt")

        relay.dispatch({"jsonrpc": "2.0", "method": "notifications/cancelled",
                        "params": {"requestId": 1}})

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with relay.call_lock:
                if 1 not in relay.call_threads:
                    break
            time.sleep(0.01)
        t.join(timeout=5)
        self.assertIsNone(
            self.sent_for(1),
            "MCP semantics: a call cancelled via notifications/cancelled must "
            "never get a result",
        )


class ProgressMilestoneTests(IntegrationHarness):
    def test_progress_milestones_emitted_and_deltas_skipped(self):
        os.environ["STUB_APP_SERVER_MODE"] = "progress"
        relay = self.make_relay(child_argv=stub_child(), progress_on=True)
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": "tok-1"}
        relay.dispatch(msg)
        resp = self.wait_for_reply(1, timeout=10)
        self.assertIsNotNone(resp)
        with self.sent_lock:
            notes = [o for o in self.sent if o.get("method") == "notifications/progress"]
        messages = [n["params"]["message"] for n in notes]
        self.assertTrue(any("turn started" in m for m in messages))
        self.assertTrue(any(m.startswith("exec:") for m in messages))
        self.assertTrue(any("file change" in m for m in messages))
        self.assertTrue(any(m.startswith("tool:") for m in messages))
        self.assertTrue(any(m.startswith("web:") for m in messages))
        self.assertTrue(any("STUB-REPLY" in m for m in messages))
        self.assertFalse(any("delta" in m.lower() for m in messages))

    def test_progress_off_suppresses_notifications(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child(), progress_on=False)
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": "tok-1"}
        relay.dispatch(msg)
        self.wait_for_reply(1, timeout=10)
        with self.sent_lock:
            notes = [o for o in self.sent if o.get("method") == "notifications/progress"]
        self.assertEqual(notes, [])


class RespawnResumeTests(IntegrationHarness):
    def test_child_death_triggers_respawn_and_resume(self):
        with tempfile.TemporaryDirectory() as td:
            state_file = os.path.join(td, "state.json")
            os.environ["STUB_APP_SERVER_STATE_FILE"] = state_file
            os.environ["STUB_APP_SERVER_MODE"] = "happy"
            relay = self.make_relay(child_argv=stub_child())
            resp = self.start_and_wait(
                relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
            )
            self.assertIsNotNone(resp)
            thread_id = resp["result"]["structuredContent"]["threadId"]

            old_proc = relay.backend.proc
            old_proc.kill()
            old_proc.wait(timeout=5)
            old_proc.stdin.close()
            old_proc.stdout.close()

            resp2 = self.start_and_wait(
                relay, "codex-reply", {"threadId": thread_id, "prompt": "again"}, 2,
                timeout=15,
            )
            self.assertIsNotNone(resp2, "respawn+resume path did not complete")
            self.assertNotIn("error", resp2)


class DepthStubTests(RelayHarness):
    def test_tools_list_empty_and_tools_call_denied(self):
        relay = self.make_relay(depth_stub=True)
        relay.dispatch({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        resp = self.sent_for(1)
        self.assertEqual(resp["result"]["tools"], [])

        relay.dispatch(self.call_message("codex", {"cwd": self.good_cwd,
                                                     "prompt": "x"}, 2))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.sent_for(2) is None:
            time.sleep(0.01)
        resp2 = self.sent_for(2)
        self.assertIsNotNone(resp2)
        self.assertEqual(resp2["error"]["code"], -32601)
        self.assertIsNone(relay.backend.proc)


class InitializeAndToolsListTests(RelayHarness):
    def test_initialize_echoes_protocol_version_and_names_server(self):
        relay = self.make_relay(tier="astra")
        relay.dispatch({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2099-01-01"}})
        resp = self.sent_for(1)
        self.assertEqual(resp["result"]["protocolVersion"], "2099-01-01")
        self.assertEqual(resp["result"]["serverInfo"]["name"], "codex-astra")
        self.assertIn("tools", resp["result"]["capabilities"])

    def test_tools_list_shape(self):
        relay = self.make_relay()
        relay.dispatch({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        tools = self.sent_for(1)["result"]["tools"]
        names = {t["name"] for t in tools}
        self.assertEqual(names, {"codex", "codex-reply"})
        codex_tool = next(t for t in tools if t["name"] == "codex")
        self.assertEqual(codex_tool["inputSchema"]["required"], ["prompt"])
        self.assertIn("cwd", codex_tool["inputSchema"]["properties"])
        self.assertIn("sandbox", codex_tool["inputSchema"]["properties"])
        self.assertNotIn("developer-instructions", codex_tool["inputSchema"]["properties"])
        self.assertNotIn("base-instructions", codex_tool["inputSchema"]["properties"])

    def test_ping_and_unknown_method(self):
        relay = self.make_relay()
        relay.dispatch({"jsonrpc": "2.0", "id": 1, "method": "ping"})
        self.assertEqual(self.sent_for(1)["result"], {})
        relay.dispatch({"jsonrpc": "2.0", "id": 2, "method": "bogus/method"})
        self.assertEqual(self.sent_for(2)["error"]["code"], -32601)


class HandshakeRobustnessTests(IntegrationHarness):
    def test_exit_after_init_gets_error_not_none(self):
        os.environ["STUB_APP_SERVER_MODE"] = "exit_after_init"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(
            resp, "no reply at all for a child that exits between "
                  "initialize and initialized"
        )
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32000)
        self.assertIn("handshake", resp["error"]["message"])
        self.assertIsNone(relay.backend.proc,
                          "failed handshake must reset the child")
        self.assertFalse(relay.backend.initialized)

    def test_init_error_respawns_and_second_call_succeeds(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["STUB_APP_SERVER_STATE_FILE"] = os.path.join(td, "state.json")
            os.environ["STUB_APP_SERVER_MODE"] = "init_error"
            relay = self.make_relay(child_argv=stub_child())
            resp = self.start_and_wait(
                relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
            )
            self.assertIsNotNone(resp, "failed initialize produced no reply")
            self.assertIn("error", resp)
            self.assertIn("handshake", resp["error"]["message"])
            self.assertIsNone(relay.backend.proc,
                              "failed handshake must reset the child")

            os.environ["STUB_APP_SERVER_MODE"] = "happy"
            resp2 = self.start_and_wait(
                relay, "codex", {"cwd": self.good_cwd, "prompt": "again"}, 2,
            )
            self.assertIsNotNone(resp2, "second call after failed "
                                        "initialize hung")
            self.assertNotIn("error", resp2)
            self.assertIn("STUB-REPLY", resp2["result"]["content"][0]["text"])

    def test_two_concurrent_first_calls_no_thread_start_before_initialized(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["STUB_APP_SERVER_STATE_FILE"] = os.path.join(td, "state.json")
            os.environ["STUB_APP_SERVER_METHODS_FILE"] = os.path.join(td, "methods.txt")
            os.environ["STUB_APP_SERVER_MODE"] = "happy"
            relay = self.make_relay(child_argv=stub_child())

            def worker(rid):
                relay.dispatch(self.call_message(
                    "codex", {"cwd": self.good_cwd, "prompt": "p%d" % rid}, rid,
                ))

            threads = [
                threading.Thread(target=worker, args=(i,), daemon=True)
                for i in (1, 2)
            ]
            for t in threads:
                t.start()
            resp1 = self.wait_for_reply(1, timeout=15)
            resp2 = self.wait_for_reply(2, timeout=15)
            for t in threads:
                t.join(timeout=10)
            self.assertIsNotNone(resp1, "first concurrent call hung")
            self.assertIsNotNone(resp2, "second concurrent call hung")
            self.assertNotIn("error", resp1)
            self.assertNotIn("error", resp2)
            with open(os.environ.pop("STUB_APP_SERVER_METHODS_FILE"),
                      encoding="utf-8") as fh:
                received = fh.read().split()
            self.assertEqual(received.count("initialize"), 1, received)
            self.assertGreater(
                received.index("thread/start"), received.index("initialized"),
                "thread/start arrived before the completed handshake: %r"
                % received,
            )


class ConcurrentReplyTests(IntegrationHarness):
    def test_two_replies_same_thread_both_answered(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "start"}, 1,
        )
        self.assertIsNotNone(resp)
        self.assertNotIn("error", resp)
        thread_id = resp["result"]["structuredContent"]["threadId"]

        def worker(rid):
            relay.dispatch(self.call_message(
                "codex-reply",
                {"threadId": thread_id, "prompt": "r%d" % rid}, rid,
            ))

        threads = [
            threading.Thread(target=worker, args=(i,), daemon=True)
            for i in (2, 3)
        ]
        for t in threads:
            t.start()
        resp2 = self.wait_for_reply(2, timeout=15)
        resp3 = self.wait_for_reply(3, timeout=15)
        for t in threads:
            t.join(timeout=10)
        self.assertIsNotNone(resp2, "first concurrent reply hung")
        self.assertIsNotNone(
            resp3, "second concurrent reply hung (clobbered waiter slot)"
        )
        self.assertNotIn("error", resp2)
        self.assertNotIn("error", resp3)
        self.assertEqual(
            resp2["result"]["structuredContent"]["threadId"], thread_id
        )
        self.assertEqual(
            resp3["result"]["structuredContent"]["threadId"], thread_id
        )


class ResumeModelPinTests(IntegrationHarness):
    def test_resume_with_wrong_model_fails_with_pin_error(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["STUB_APP_SERVER_STATE_FILE"] = os.path.join(td, "state.json")
            os.environ["STUB_APP_SERVER_MODE"] = "happy"
            relay = self.make_relay(child_argv=stub_child(), model="pinned-r")
            resp = self.start_and_wait(
                relay, "codex", {"cwd": self.good_cwd, "prompt": "start"}, 1,
            )
            self.assertIsNotNone(resp)
            self.assertNotIn("error", resp)
            thread_id = resp["result"]["structuredContent"]["threadId"]

            old_proc = relay.backend.proc
            old_proc.kill()
            old_proc.wait(timeout=5)
            old_proc.stdin.close()
            old_proc.stdout.close()

            os.environ["STUB_APP_SERVER_MODE"] = "resume_mismatch"
            relay.dispatch(self.call_message(
                "codex-reply", {"threadId": thread_id, "prompt": "continue"}, 2,
            ))
            resp2 = self.wait_for_reply(2, timeout=15)
            self.assertIsNotNone(resp2, "resume mismatch call hung")
            self.assertIn("error", resp2)
            self.assertEqual(resp2["error"]["code"], -32000)
            self.assertIn("model pin mismatch", resp2["error"]["message"])


class BigBackendLineTests(IntegrationHarness):
    def test_multi_mib_backend_message_delivered(self):
        os.environ["STUB_APP_SERVER_MODE"] = "big"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "big"}, 1,
        )
        self.assertIsNotNone(resp, "an over-long backend line was dropped")
        self.assertNotIn("error", resp)
        text = resp["result"]["content"][0]["text"]
        self.assertGreater(
            len(text), 1 << 20,
            "multi-MiB agent message was lost: only %d bytes" % len(text),
        )
        self.assertIn("STUB-REPLY", text)


class OversizedBackendLineTests(IntegrationHarness):
    def test_line_over_limit_fails_pending_calls_with_limit_error(self):
        with tempfile.TemporaryDirectory() as td:
            log_path = os.path.join(td, "shim.log")
            relay = SHIM.Relay(
                tier="test", model="m", effort="high", progress_on=False,
                child_argv=DUMMY_CHILD, log_path=log_path,
                depth_stub=False, kernel_text="KERNEL",
            )
            self._relays.append(relay)
            backend = relay.backend

            class FakeStdin:
                def write(self, data):
                    pass

                def flush(self):
                    pass

            class FakeProc:
                def __init__(self):
                    big = (
                        b'{"method": "turn/completed", "params": "x'
                        + b"y" * (SHIM.MAX_BACKEND_LINE + 10)
                    )
                    self.stdin = FakeStdin()
                    self.stdout = io.BytesIO(big + b"\n")
                    self._code = 0

                def poll(self):
                    return None

                def kill(self):
                    pass

                def terminate(self):
                    pass

                def wait(self, timeout=None):
                    return 0

            backend.proc = FakeProc()
            thread_id = "oversized-thread"
            ev = threading.Event()
            slot = {}
            waiter = {
                "event": threading.Event(), "turn": None, "turn_id": None,
                "error": None, "progress_token": None,
            }
            with backend.state_lock:
                backend.pending[99] = (ev, slot)
                backend.turn_waiters[thread_id] = waiter
            reader = threading.Thread(target=backend._read_loop, daemon=True)
            reader.start()
            self.assertTrue(
                ev.wait(timeout=5),
                "pending request never failed on an oversized backend line",
            )
            self.assertTrue(
                waiter["event"].wait(timeout=5),
                "turn waiter never failed on an oversized backend line",
            )
            reader.join(timeout=5)
            note_expected = "size limit"
            self.assertIn(note_expected, slot["error"]["message"])
            self.assertEqual(slot["error"]["message"], waiter["error"])


class HeartbeatTests(IntegrationHarness):
    def test_heartbeat_emitted_with_no_item_events(self):
        os.environ["STUB_APP_SERVER_MODE"] = "cancel"
        os.environ["CBOX_CODEX_SHIM_HEARTBEAT_SEC"] = "1"
        try:
            relay = self.make_relay(child_argv=stub_child(), progress_on=True)
            msg = self.call_message(
                "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
            )
            msg["params"]["_meta"] = {"progressToken": "tok-hb"}
            relay.dispatch(msg)

            deadline = time.monotonic() + 10
            heartbeat_seen = False
            while time.monotonic() < deadline:
                with self.sent_lock:
                    notes = [o for o in self.sent
                             if o.get("method") == "notifications/progress"]
                if any("elapsed" in n["params"]["message"] for n in notes):
                    heartbeat_seen = True
                    break
                time.sleep(0.05)
            self.assertTrue(
                heartbeat_seen,
                "no heartbeat notification arrived with no item events",
            )

            relay.dispatch({"jsonrpc": "2.0", "method": "notifications/cancelled",
                            "params": {"requestId": 1}})
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                with relay.call_lock:
                    if 1 not in relay.call_threads:
                        break
                time.sleep(0.01)
        finally:
            os.environ.pop("CBOX_CODEX_SHIM_HEARTBEAT_SEC", None)


class CancelRaceTests(IntegrationHarness):
    def test_cancel_before_dispatch_never_starts_turn(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        relay.mark_cancelled(1)
        relay.dispatch(self.call_message(
            "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        ))
        time.sleep(0.3)
        self.assertIsNone(
            self.sent_for(1), "a cancelled call must get no reply at all",
        )
        self.assertIsNone(
            relay.backend.proc,
            "a pre-cancelled call must never start the backend or a turn",
        )

    def test_cancel_while_waiting_on_thread_lock_never_starts_second_turn(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["STUB_APP_SERVER_METHODS_FILE"] = os.path.join(td, "methods.txt")
            os.environ["STUB_APP_SERVER_MODE"] = "cancel"
            relay = self.make_relay(child_argv=stub_child())

            def first_call():
                relay.dispatch(self.call_message(
                    "codex", {"cwd": self.good_cwd, "prompt": "first"}, 1,
                ))

            t1 = threading.Thread(target=first_call, daemon=True)
            t1.start()

            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                with relay.call_lock:
                    if 1 in relay.call_threads:
                        break
                time.sleep(0.01)
            self.assertIn(1, relay.call_threads, "first turn never registered")
            thread_id = relay.call_threads[1][0]

            relay.dispatch(self.call_message(
                "codex-reply", {"threadId": thread_id, "prompt": "second"}, 2,
            ))
            time.sleep(0.3)

            relay.dispatch({"jsonrpc": "2.0", "method": "notifications/cancelled",
                            "params": {"requestId": 2}})
            time.sleep(0.2)
            relay.dispatch({"jsonrpc": "2.0", "method": "notifications/cancelled",
                            "params": {"requestId": 1}})

            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                with relay.call_lock:
                    if 1 not in relay.call_threads and 2 not in relay.call_threads:
                        break
                time.sleep(0.02)
            else:
                self.fail("calls never finished cleanup after cancellation")
            t1.join(timeout=5)
            time.sleep(0.1)

            self.assertIsNone(self.sent_for(1))
            self.assertIsNone(self.sent_for(2))
            methods_path = os.environ.pop("STUB_APP_SERVER_METHODS_FILE")
            with open(methods_path, encoding="utf-8") as fh:
                received = fh.read().split()
            self.assertEqual(
                received.count("turn/start"), 1,
                "the queued call cancelled while waiting on the thread lock "
                "must never call turn/start: %r" % received,
            )


class ThreadPointerTests(IntegrationHarness):
    def test_error_text_includes_threadid_pointer(self):
        os.environ["STUB_APP_SERVER_MODE"] = "fail_turn"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp)
        text = resp["result"]["content"][0]["text"]
        self.assertIn("threadId: thread-1", text)

    def test_error_text_includes_rollout_path_when_found_on_disk(self):
        os.environ["STUB_APP_SERVER_MODE"] = "fail_turn"
        relay = self.make_relay(child_argv=stub_child())
        session_dir = os.path.join(
            self._codex_home_dir.name, "sessions", "2026", "01", "01",
        )
        os.makedirs(session_dir, exist_ok=True)
        rollout_path = os.path.join(session_dir, "rollout-thread-1.jsonl")
        with open(rollout_path, "w", encoding="utf-8") as fh:
            fh.write("")
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp)
        text = resp["result"]["content"][0]["text"]
        self.assertIn("threadId: thread-1", text)
        self.assertIn(rollout_path, text)

    def test_success_text_includes_threadid_pointer(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp)
        text = resp["result"]["content"][0]["text"]
        self.assertIn("STUB-REPLY", text)
        self.assertIn("threadId: thread-1", text)


class ResumeUnknownThreadFromDiskTests(IntegrationHarness):
    def _write_rollout(self, thread_id, cwd, name=None):
        session_dir = os.path.join(
            self._codex_home_dir.name, "sessions", "2026", "01", "01",
        )
        os.makedirs(session_dir, exist_ok=True)
        rollout_path = os.path.join(
            session_dir, name or ("rollout-%s.jsonl" % thread_id),
        )
        with open(rollout_path, "w", encoding="utf-8") as fh:
            if cwd is not None:
                fh.write(json.dumps({
                    "type": "session_meta",
                    "payload": {"id": thread_id, "cwd": cwd},
                }) + "\n")
        return rollout_path

    def test_codex_reply_resumes_thread_unknown_in_memory_via_disk_rollout(self):
        with tempfile.TemporaryDirectory() as td:
            state_file = os.path.join(td, "state.json")
            with open(state_file, "w", encoding="utf-8") as fh:
                json.dump(
                    {"disk-thread-1": {"model": "pinned-model-disk",
                                        "cwd": self.good_cwd}}, fh,
                )
            os.environ["STUB_APP_SERVER_STATE_FILE"] = state_file
            os.environ["STUB_APP_SERVER_MODE"] = "happy"

            self._write_rollout("disk-thread-1", self.good_cwd)

            relay = self.make_relay(child_argv=stub_child(), model="pinned-model-disk")
            self.assertIsNone(relay.backend.proc)

            resp = self.start_and_wait(
                relay, "codex-reply",
                {"threadId": "disk-thread-1", "prompt": "continue"}, 1,
            )
            self.assertIsNotNone(
                resp, "resume of a disk-only thread hung or was denied",
            )
            self.assertNotIn("error", resp)
            self.assertEqual(
                resp["result"]["structuredContent"]["threadId"], "disk-thread-1",
            )
            self.assertEqual(
                relay.backend.cached_cwd("disk-thread-1"),
                os.path.realpath(self.good_cwd),
                "the cwd read from the disk rollout must be passed into "
                "thread/resume",
            )

    def test_codex_reply_still_denied_without_memory_or_disk_rollout(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        relay._call_codex_reply(
            1, {"threadId": "nowhere-thread", "prompt": "continue"}, None,
        )
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertEqual(
            err["message"], "thread unknown to this relay - start a new codex call",
        )
        self.assertIsNone(relay.backend.proc)

    def test_codex_reply_denied_when_rollout_has_no_readable_cwd(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        self._write_rollout("nocwd-thread", None)
        relay._call_codex_reply(
            1, {"threadId": "nocwd-thread", "prompt": "continue"}, None,
        )
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("no readable cwd", err["message"])
        self.assertIsNone(relay.backend.proc)

    def test_codex_reply_denied_when_rollout_cwd_outside_scope(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        self._write_rollout("foreign-thread", "/tmp")
        relay._call_codex_reply(
            1, {"threadId": "foreign-thread", "prompt": "continue"}, None,
        )
        err = self.sent_for(1)["error"]
        self.assertEqual(err["code"], -32000)
        self.assertIn("outside the allowed scope", err["message"])
        self.assertIsNone(relay.backend.proc)

    def test_codex_reply_denied_when_rollout_cwd_not_a_git_worktree(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        with tempfile.TemporaryDirectory() as td:
            os.environ["CODEX_GUARD_EXTRA_ROOTS"] = td
            relay = self.make_relay(child_argv=stub_child())
            self._write_rollout("nongit-thread", td)
            relay._call_codex_reply(
                1, {"threadId": "nongit-thread", "prompt": "continue"}, None,
            )
            err = self.sent_for(1)["error"]
            self.assertEqual(err["code"], -32000)
            self.assertIn("git work-tree", err["message"])
            self.assertIsNone(relay.backend.proc)


class TurnTimeoutTests(IntegrationHarness):
    def test_turn_timeout_interrupts_and_reports_pointer(self):
        os.environ["STUB_APP_SERVER_MODE"] = "cancel"
        os.environ["CBOX_CODEX_SHIM_TURN_TIMEOUT_SEC"] = "1"
        try:
            resp = self.start_and_wait(
                self.make_relay(child_argv=stub_child()),
                "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1, timeout=15,
            )
        finally:
            os.environ.pop("CBOX_CODEX_SHIM_TURN_TIMEOUT_SEC", None)
        self.assertIsNotNone(resp, "turn timeout never resolved the call")
        self.assertTrue(resp["result"]["isError"])
        text = resp["result"]["content"][0]["text"]
        self.assertIn("wall-clock cap", text.lower())
        self.assertIn("threadId:", text)


class SignalHandlingTests(RelayHarness):
    def test_shutdown_terminates_running_child_and_turn(self):
        os.environ["STUB_APP_SERVER_MODE"] = "cancel"
        relay = self.make_relay(child_argv=stub_child())

        def run_call():
            relay.dispatch(self.call_message(
                "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
            ))

        t = threading.Thread(target=run_call, daemon=True)
        t.start()

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            proc = relay.backend.proc
            if proc is not None and proc.poll() is None:
                break
            time.sleep(0.02)
        proc = relay.backend.proc
        self.assertIsNotNone(proc, "backend child never started")
        self.assertIsNone(proc.poll(), "backend child exited before shutdown")

        relay._shutdown("test-signal")
        try:
            proc.wait(timeout=5)
        except Exception:
            self.fail("child was not terminated by _shutdown")
        self.assertIsNotNone(proc.poll(), "child still running after shutdown")
        t.join(timeout=5)


class RolloutLowLevelReadTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write(self, name, data):
        path = os.path.join(self.tmpdir.name, name)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_symlinked_rollout_not_followed(self):
        target = self._write(
            "real.jsonl",
            (json.dumps({"type": "session_meta",
                         "payload": {"id": "sneaky", "cwd": "/tmp"}}) + "\n").encode(),
        )
        link_path = os.path.join(self.tmpdir.name, "link.jsonl")
        os.symlink(target, link_path)
        self.assertIsNone(SHIM._rollout_session_meta_payload(link_path))
        self.assertIsNone(SHIM.rollout_cwd(link_path))

    def test_fifo_rollout_not_followed_or_hung(self):
        fifo_path = os.path.join(self.tmpdir.name, "fifo.jsonl")
        os.mkfifo(fifo_path)
        result_holder = {}

        def run():
            result_holder["payload"] = SHIM._rollout_session_meta_payload(fifo_path)

        t = threading.Thread(target=run, daemon=True)
        t.start()
        t.join(timeout=3)
        self.assertFalse(t.is_alive(), "reading a FIFO rollout hung")
        self.assertIsNone(result_holder.get("payload"))

    def test_oversized_first_line_handled(self):
        padding = b" " * (SHIM.ROLLOUT_META_READ_CAP + 10)
        path = self._write(
            "big.jsonl",
            b'{"type": "session_meta", "payload": {"id": "x", "cwd": "/x"'
            + padding + b"}}\n",
        )
        self.assertIsNone(SHIM._rollout_session_meta_payload(path))

    def test_non_regular_file_not_read(self):
        directory = os.path.join(self.tmpdir.name, "adir.jsonl")
        os.mkdir(directory)
        self.assertIsNone(SHIM._rollout_session_meta_payload(directory))


class RolloutScanTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.saved_codex_home = os.environ.pop("CODEX_HOME", None)
        os.environ["CODEX_HOME"] = self.tmpdir.name

    def tearDown(self):
        os.environ.pop("CODEX_HOME", None)
        if self.saved_codex_home is not None:
            os.environ["CODEX_HOME"] = self.saved_codex_home
        self.tmpdir.cleanup()

    def _session_dir(self, y="2026", m="01", d="01"):
        d_path = os.path.join(self.tmpdir.name, "sessions", y, m, d)
        os.makedirs(d_path, exist_ok=True)
        return d_path

    def _write(self, path, first_line_obj=None):
        with open(path, "w", encoding="utf-8") as fh:
            if first_line_obj is not None:
                fh.write(json.dumps(first_line_obj) + "\n")

    def test_filename_suffix_exact_match(self):
        d = self._session_dir()
        path = os.path.join(d, "rollout-abc123.jsonl")
        self._write(path)
        found = SHIM.find_rollout_path_by_thread_id("abc123")
        self.assertEqual(found, path)

    def test_short_id_does_not_substring_match_directory_name(self):
        d = self._session_dir(y="2026")
        self._write(
            os.path.join(d, "rollout-abc123.jsonl"),
            {"type": "session_meta", "payload": {"id": "abc123", "cwd": "/x"}},
        )
        found = SHIM.find_rollout_path_by_thread_id("2026")
        self.assertIsNone(found)

    def test_session_meta_id_match_without_filename_suffix(self):
        d = self._session_dir()
        path = os.path.join(d, "rollout-unrelated.jsonl")
        self._write(
            path,
            {"type": "session_meta", "payload": {"id": "target-id", "cwd": "/x"}},
        )
        found = SHIM.find_rollout_path_by_thread_id("target-id")
        self.assertEqual(found, path)

    def test_substring_of_filename_does_not_match(self):
        d = self._session_dir()
        self._write(
            os.path.join(d, "rollout-abc123extra.jsonl"),
            {"type": "session_meta", "payload": {"id": "other", "cwd": "/x"}},
        )
        found = SHIM.find_rollout_path_by_thread_id("abc123")
        self.assertIsNone(found)

    def test_symlinked_rollout_matched_by_name_but_unreadable_cwd(self):
        target = os.path.join(self.tmpdir.name, "real.jsonl")
        self._write(
            target,
            {"type": "session_meta", "payload": {"id": "linked-id", "cwd": "/x"}},
        )
        d = self._session_dir()
        link_path = os.path.join(d, "rollout-linked-id.jsonl")
        os.symlink(target, link_path)
        found = SHIM.find_rollout_path_by_thread_id("linked-id")
        self.assertEqual(found, link_path)
        self.assertIsNone(SHIM.rollout_cwd(found))

    def test_negative_lookup_is_cached_per_codex_home(self):
        found = SHIM.find_rollout_path_by_thread_id("never-exists-id")
        self.assertIsNone(found)
        self.assertTrue(
            SHIM._rollout_negative_cache_get((SHIM.codex_home(), "never-exists-id"))
        )


class InterruptFailureTerminatesBackendTests(IntegrationHarness):
    def test_interrupt_rpc_failure_terminates_backend_group(self):
        os.environ["STUB_APP_SERVER_MODE"] = "interrupt_fails"
        relay = self.make_relay(child_argv=stub_child())

        def run_call():
            relay.dispatch(self.call_message(
                "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
            ))

        t = threading.Thread(target=run_call, daemon=True)
        t.start()

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with relay.call_lock:
                if 1 in relay.call_threads:
                    break
            time.sleep(0.01)
        self.assertIn(1, relay.call_threads, "turn never registered for interrupt")

        old_proc = relay.backend.proc
        self.assertIsNotNone(old_proc)

        relay.dispatch({"jsonrpc": "2.0", "method": "notifications/cancelled",
                        "params": {"requestId": 1}})

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if old_proc.poll() is not None:
                break
            time.sleep(0.05)
        self.assertIsNotNone(
            old_proc.poll(),
            "backend child was not terminated after the interrupt RPC failed",
        )
        t.join(timeout=10)

    def test_interrupt_no_confirmation_terminates_backend_group(self):
        os.environ["STUB_APP_SERVER_MODE"] = "interrupt_no_confirmation"
        os.environ["CBOX_CODEX_SHIM_INTERRUPT_GRACE_SEC"] = "1"
        try:
            relay = self.make_relay(child_argv=stub_child())

            def run_call():
                relay.dispatch(self.call_message(
                    "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
                ))

            t = threading.Thread(target=run_call, daemon=True)
            t.start()

            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                with relay.call_lock:
                    if 1 in relay.call_threads:
                        break
                time.sleep(0.01)
            self.assertIn(1, relay.call_threads, "turn never registered for interrupt")

            old_proc = relay.backend.proc
            self.assertIsNotNone(old_proc)

            relay.dispatch({"jsonrpc": "2.0", "method": "notifications/cancelled",
                            "params": {"requestId": 1}})

            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if old_proc.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertIsNotNone(
                old_proc.poll(),
                "backend child was not terminated after the interrupt was "
                "never confirmed",
            )
            t.join(timeout=10)
        finally:
            os.environ.pop("CBOX_CODEX_SHIM_INTERRUPT_GRACE_SEC", None)


class ProgressTokenBoundsTests(IntegrationHarness):
    def test_oversized_progress_token_treated_as_absent(self):
        os.environ["STUB_APP_SERVER_MODE"] = "progress"
        relay = self.make_relay(child_argv=stub_child(), progress_on=True)
        long_token = "x" * 300
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": long_token}
        relay.dispatch(msg)
        resp = self.wait_for_reply(1, timeout=10)
        self.assertIsNotNone(resp)
        with self.sent_lock:
            notes = [o for o in self.sent if o.get("method") == "notifications/progress"]
        self.assertEqual(notes, [])
        self.assertNotIn(long_token, relay.progress_seq)

    def test_object_progress_token_treated_as_absent(self):
        os.environ["STUB_APP_SERVER_MODE"] = "progress"
        relay = self.make_relay(child_argv=stub_child(), progress_on=True)
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": {"nested": "object"}}
        relay.dispatch(msg)
        resp = self.wait_for_reply(1, timeout=10)
        self.assertIsNotNone(resp)
        with self.sent_lock:
            notes = [o for o in self.sent if o.get("method") == "notifications/progress"]
        self.assertEqual(notes, [])

    def test_list_progress_token_treated_as_absent(self):
        os.environ["STUB_APP_SERVER_MODE"] = "progress"
        relay = self.make_relay(child_argv=stub_child(), progress_on=True)
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": ["a", "b"]}
        relay.dispatch(msg)
        resp = self.wait_for_reply(1, timeout=10)
        self.assertIsNotNone(resp)
        with self.sent_lock:
            notes = [o for o in self.sent if o.get("method") == "notifications/progress"]
        self.assertEqual(notes, [])

    def test_bool_progress_token_treated_as_absent(self):
        os.environ["STUB_APP_SERVER_MODE"] = "progress"
        relay = self.make_relay(child_argv=stub_child(), progress_on=True)
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": True}
        relay.dispatch(msg)
        resp = self.wait_for_reply(1, timeout=10)
        self.assertIsNotNone(resp)
        with self.sent_lock:
            notes = [o for o in self.sent if o.get("method") == "notifications/progress"]
        self.assertEqual(notes, [])

    def test_int_progress_token_is_accepted(self):
        os.environ["STUB_APP_SERVER_MODE"] = "progress"
        relay = self.make_relay(child_argv=stub_child(), progress_on=True)
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": 42}
        relay.dispatch(msg)
        resp = self.wait_for_reply(1, timeout=10)
        self.assertIsNotNone(resp)
        with self.sent_lock:
            notes = [o for o in self.sent if o.get("method") == "notifications/progress"]
        self.assertGreater(len(notes), 0)

    def test_progress_seq_entry_dropped_after_call_ends(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child(), progress_on=True)
        msg = self.call_message("codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1)
        msg["params"]["_meta"] = {"progressToken": "tok-drop"}
        relay.dispatch(msg)
        resp = self.wait_for_reply(1, timeout=10)
        self.assertIsNotNone(resp)
        self.assertNotIn("tok-drop", relay.progress_seq)


class RateLimitSnapshotShapeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.saved_usage_dir = os.environ.pop("CBOX_USAGE_DIR", None)
        os.environ["CBOX_USAGE_DIR"] = self._tmp.name

    def tearDown(self):
        os.environ.pop("CBOX_USAGE_DIR", None)
        if self.saved_usage_dir is not None:
            os.environ["CBOX_USAGE_DIR"] = self.saved_usage_dir
        self._tmp.cleanup()

    def _codex_json(self):
        with open(os.path.join(self._tmp.name, "codex.json"), "r", encoding="utf-8") as f:
            return json.load(f)

    def test_snapshot_shape_matches_cbox_budget_schema(self):
        rl = {
            "primary": {"usedPercent": 38, "resetsAt": 1790340325, "windowDurationMins": 300},
            "secondary": {"usedPercent": 12, "resetsAt": 1790842078, "windowDurationMins": 10080},
            "planType": "plus",
        }
        snap = SHIM.codex_usage_snapshot_from_rate_limits(rl)
        self.assertEqual(snap["source"], "codex")
        self.assertEqual(snap["five_hour"]["used_percentage"], 38)
        self.assertEqual(snap["five_hour"]["resets_at"], 1790340325)
        self.assertEqual(snap["seven_day"]["used_percentage"], 12)
        self.assertEqual(snap["seven_day"]["resets_at"], 1790842078)
        self.assertEqual(snap["plan_type"], "plus")

    def test_snapshot_captures_reached_type_and_ordinary_usage_allowed(self):
        rl = {
            "primary": {"usedPercent": 100, "resetsAt": 1790340325, "windowDurationMins": 300},
            "secondary": {"usedPercent": 44, "resetsAt": 1790842078, "windowDurationMins": 10080},
            "planType": "plus",
            "rateLimitReachedType": "rate_limit_reached",
        }
        snap = SHIM.codex_usage_snapshot_from_rate_limits(rl, ordinary_usage_allowed=False)
        self.assertEqual(snap["rate_limit_reached_type"], "rate_limit_reached")
        self.assertEqual(snap["ordinary_usage_allowed"], False)

    def test_snapshot_omits_reached_fields_when_absent(self):
        rl = {"primary": {"usedPercent": 5, "resetsAt": 100}}
        snap = SHIM.codex_usage_snapshot_from_rate_limits(rl)
        self.assertNotIn("rate_limit_reached_type", snap)
        self.assertNotIn("ordinary_usage_allowed", snap)

    def test_snapshot_ignores_non_bool_ordinary_usage_allowed(self):
        rl = {"primary": {"usedPercent": 5, "resetsAt": 100}}
        snap = SHIM.codex_usage_snapshot_from_rate_limits(rl, ordinary_usage_allowed="nope")
        self.assertNotIn("ordinary_usage_allowed", snap)

    def test_malformed_window_entries_tolerated(self):
        self.assertIsNone(SHIM._rate_limit_window("not-a-dict"))
        self.assertIsNone(SHIM._rate_limit_window(None))
        w = SHIM._rate_limit_window({"usedPercent": True, "resetsAt": "bad"})
        self.assertIsNone(w["used_percentage"])
        self.assertIsNone(w["resets_at"])

    def test_no_windows_returns_none(self):
        self.assertIsNone(SHIM.codex_usage_snapshot_from_rate_limits({"foo": "bar"}))
        self.assertIsNone(SHIM.codex_usage_snapshot_from_rate_limits("not-a-dict"))
        self.assertIsNone(SHIM.codex_usage_snapshot_from_rate_limits(None))

    def test_write_returns_false_and_skips_file_when_no_usable_windows(self):
        self.assertFalse(SHIM.write_codex_usage_snapshot({"foo": "bar"}))
        self.assertFalse(os.path.exists(os.path.join(self._tmp.name, "codex.json")))

    def test_write_creates_atomic_0600_file_in_0700_dir(self):
        ok = SHIM.write_codex_usage_snapshot({
            "primary": {"usedPercent": 5, "resetsAt": 100},
        })
        self.assertTrue(ok)
        path = os.path.join(self._tmp.name, "codex.json")
        mode = stat.S_IMODE(os.stat(path).st_mode)
        self.assertEqual(mode, 0o600)
        dmode = stat.S_IMODE(os.stat(self._tmp.name).st_mode)
        self.assertEqual(dmode, 0o700)
        data = self._codex_json()
        self.assertEqual(data["source"], "codex")
        self.assertIn("captured_at", data)

    def test_write_replaces_a_preexisting_symlink_without_following_it(self):
        outside_dir = tempfile.TemporaryDirectory()
        try:
            outside = os.path.join(outside_dir.name, "outside_target.json")
            with open(outside, "w", encoding="utf-8") as f:
                f.write("SHOULD_NOT_BE_WRITTEN")
            path = os.path.join(self._tmp.name, "codex.json")
            os.makedirs(self._tmp.name, exist_ok=True)
            os.symlink(outside, path)
            ok = SHIM.write_codex_usage_snapshot({"primary": {"usedPercent": 1, "resetsAt": 1}})
            self.assertTrue(ok)
            self.assertFalse(os.path.islink(path))
            with open(outside, encoding="utf-8") as f:
                self.assertEqual(f.read(), "SHOULD_NOT_BE_WRITTEN")
        finally:
            outside_dir.cleanup()

    def test_cbox_budget_reads_the_written_snapshot(self):
        SHIM.write_codex_usage_snapshot({
            "primary": {"usedPercent": 38, "resetsAt": time.time() + 3600,
                        "windowDurationMins": 300},
            "secondary": {"usedPercent": 12, "resetsAt": time.time() + 86400,
                          "windowDurationMins": 10080},
        })
        spec = importlib.util.spec_from_file_location(
            "cbox_budget_for_shim_test", ROOT / "etc" / "hooks" / "cbox_budget.py",
        )
        budget_mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(budget_mod)
        m = budget_mod.source_metrics("codex")
        self.assertIsNotNone(m)
        self.assertEqual(m["five_hour"]["used_percentage"], 38.0)
        self.assertEqual(m["seven_day"]["used_percentage"], 12.0)


class RateLimitSingleFlightTests(unittest.TestCase):
    def test_only_one_inflight_read_runs_at_a_time(self):
        backend = SHIM.CodexBackend.__new__(SHIM.CodexBackend)
        backend.rate_limit_refresh_lock = threading.Lock()
        backend.journal = lambda *a, **k: None
        calls = []
        gate = threading.Event()

        def slow_request(method, params, timeout=60):
            calls.append(method)
            gate.wait(2)
            return {"rateLimits": {"primary": {"usedPercent": 1}}}

        backend.request = slow_request
        backend.capture_rate_limits = lambda rl, ordinary_usage_allowed=None: None
        t1 = threading.Thread(target=backend.refresh_rate_limits_once)
        t1.start()
        try:
            deadline = time.monotonic() + 2
            while not calls and time.monotonic() < deadline:
                time.sleep(0.01)
            backend.refresh_rate_limits_once()
            self.assertEqual(calls, ["account/rateLimits/read"])
        finally:
            gate.set()
            t1.join(timeout=3)

    def test_read_failure_is_swallowed_and_journalled(self):
        backend = SHIM.CodexBackend.__new__(SHIM.CodexBackend)
        backend.rate_limit_refresh_lock = threading.Lock()
        events = []
        backend.journal = lambda event, **fields: events.append(event)

        def failing_request(method, params, timeout=60):
            raise SHIM.BackendTimeout("boom")

        backend.request = failing_request
        backend.refresh_rate_limits_once()
        self.assertIn("rate_limits_read_failed", events)
        self.assertTrue(backend.rate_limit_refresh_lock.acquire(blocking=False))
        backend.rate_limit_refresh_lock.release()


class FinishTurnRefreshSpawnTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.saved_usage_dir = os.environ.pop("CBOX_USAGE_DIR", None)
        self.saved_audit = os.environ.pop("CODEX_SHIM_GUARD_AUDIT", None)
        os.environ["CBOX_USAGE_DIR"] = self._tmp.name
        os.environ["CODEX_SHIM_GUARD_AUDIT"] = os.path.join(
            self._tmp.name, "audit.jsonl")
        self.saved_digest = SHIM.GUARD._audit_digest
        SHIM.GUARD._audit_digest = lambda cwd: "0" * 16

    def tearDown(self):
        SHIM.GUARD._audit_digest = self.saved_digest
        os.environ.pop("CBOX_USAGE_DIR", None)
        if self.saved_usage_dir is not None:
            os.environ["CBOX_USAGE_DIR"] = self.saved_usage_dir
        os.environ.pop("CODEX_SHIM_GUARD_AUDIT", None)
        if self.saved_audit is not None:
            os.environ["CODEX_SHIM_GUARD_AUDIT"] = self.saved_audit
        self._tmp.cleanup()

    def _relay(self):
        relay = SHIM.Relay.__new__(SHIM.Relay)
        relay.tier = "test"
        relay.progress_lock = threading.Lock()
        relay.call_lock = threading.Lock()
        relay.call_threads = {}
        relay.backend = SHIM.CodexBackend.__new__(SHIM.CodexBackend)
        relay.backend.state_lock = threading.Lock()
        relay.backend.thread_cwd = {}
        relay.backend.cached_cwd = lambda tid: None
        relay.backend.rate_limit_refresh_lock = threading.Lock()
        relay.backend.run_turn = lambda *a, **k: ("ok-text", None)
        relay.backend.request = lambda *a, **k: {
            "rateLimits": {"primary": {"usedPercent": 1}}}
        relay.backend.capture_rate_limits = lambda rl, ordinary_usage_allowed=None: None
        relay.backend.journal = lambda *a, **k: None
        relay.was_cancelled = lambda rid: False
        relay._append_pointer = lambda text, tid, hint=None: text
        relay.reply = lambda rid, result: None
        self.audit_calls = []
        relay.shim_audit = lambda *a, **k: self.audit_calls.append((a, k))
        return relay

    def test_single_refresh_thread_spawned_when_idle(self):
        relay = self._relay()
        spawned = []
        constructor_calls = []

        class RecordingThread(threading.Thread):
            def __init__(self, *args, **kwargs):
                constructor_calls.append(kwargs)
                super().__init__(*args, **kwargs)

            def start(self):
                spawned.append(self)
                super().start()

        with mock.patch.object(SHIM.threading, "Thread", RecordingThread):
            relay._finish_turn(1, "tid-1", "prompt", None)
        self.assertEqual(len(spawned), 1)
        self.assertEqual(len(constructor_calls), 1)
        self.assertEqual(
            getattr(constructor_calls[0].get("target"), "__name__", None),
            "refresh_rate_limits_once",
        )
        self.assertTrue(constructor_calls[0].get("daemon"))
        spawned[0].join(timeout=2)
        self.assertFalse(spawned[0].is_alive())
        self.assertTrue(
            relay.backend.rate_limit_refresh_lock.acquire(blocking=False),
            "refresh thread must have released the in-flight lock on exit",
        )
        relay.backend.rate_limit_refresh_lock.release()

    def test_no_second_thread_while_refresh_in_flight(self):
        relay = self._relay()
        relay.backend.rate_limit_refresh_lock.acquire()
        try:
            spawned = []

            class RecordingThread(threading.Thread):
                def start(self):
                    spawned.append(self)
                    return super().start()

            with mock.patch.object(SHIM.threading, "Thread", RecordingThread):
                relay._finish_turn(1, "tid-1", "prompt", None)
        finally:
            relay.backend.rate_limit_refresh_lock.release()
        self.assertEqual(spawned, [])


class RateLimitLiveCaptureTests(RelayHarness):
    def setUp(self):
        super().setUp()
        self._usage_tmp = tempfile.TemporaryDirectory()
        self.saved_usage_dir = os.environ.pop("CBOX_USAGE_DIR", None)
        os.environ["CBOX_USAGE_DIR"] = self._usage_tmp.name

    def tearDown(self):
        os.environ.pop("CBOX_USAGE_DIR", None)
        if self.saved_usage_dir is not None:
            os.environ["CBOX_USAGE_DIR"] = self.saved_usage_dir
        self._usage_tmp.cleanup()
        super().tearDown()

    def _codex_json_path(self):
        return os.path.join(self._usage_tmp.name, "codex.json")

    def _wait_for_codex_json(self, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(self._codex_json_path()):
                with open(self._codex_json_path(), "r", encoding="utf-8") as f:
                    return json.load(f)
            time.sleep(0.05)
        return None

    def test_post_call_read_writes_codex_json(self):
        os.environ["STUB_APP_SERVER_MODE"] = "happy"
        relay = self.make_relay(child_argv=stub_child())
        relay._call_codex(1, {"cwd": self.good_cwd, "prompt": "hi"}, None)
        self.assertIsNotNone(self.wait_for_reply(1))
        data = self._wait_for_codex_json()
        self.assertIsNotNone(data)
        self.assertEqual(data["source"], "codex")
        self.assertEqual(data["five_hour"]["used_percentage"], 38)
        self.assertEqual(data["seven_day"]["used_percentage"], 12)
        self.assertEqual(data["plan_type"], "plus")

    def test_notification_capture_writes_codex_json(self):
        os.environ["STUB_APP_SERVER_MODE"] = "rate_limits_notify"
        relay = self.make_relay(child_argv=stub_child())
        relay._call_codex(1, {"cwd": self.good_cwd, "prompt": "hi"}, None)
        self.assertIsNotNone(self.wait_for_reply(1))
        data = self._wait_for_codex_json()
        self.assertIsNotNone(data)
        self.assertEqual(data["source"], "codex")

    def test_rate_limit_read_failure_never_breaks_the_call(self):
        os.environ["STUB_APP_SERVER_MODE"] = "rate_limits_fail"
        relay = self.make_relay(child_argv=stub_child())
        relay._call_codex(1, {"cwd": self.good_cwd, "prompt": "hi"}, None)
        resp = self.wait_for_reply(1)
        self.assertIsNotNone(resp)
        self.assertNotIn("error", resp)
        time.sleep(0.3)
        self.assertFalse(os.path.exists(self._codex_json_path()))

    def test_reached_fields_captured_when_present(self):
        os.environ["STUB_APP_SERVER_MODE"] = "rate_limits_reached"
        relay = self.make_relay(child_argv=stub_child())
        relay._call_codex(1, {"cwd": self.good_cwd, "prompt": "hi"}, None)
        self.assertIsNotNone(self.wait_for_reply(1))
        data = self._wait_for_codex_json()
        self.assertIsNotNone(data)
        self.assertEqual(data["rate_limit_reached_type"], "rate_limit_reached")
        self.assertEqual(data["ordinary_usage_allowed"], False)
        self.assertEqual(data["five_hour"]["used_percentage"], 100)
        self.assertEqual(data["seven_day"]["used_percentage"], 44)


class RefreshScheduledOnFailurePathTests(IntegrationHarness):
    def setUp(self):
        super().setUp()
        self._usage_tmp = tempfile.TemporaryDirectory()
        self.saved_usage_dir = os.environ.pop("CBOX_USAGE_DIR", None)
        os.environ["CBOX_USAGE_DIR"] = self._usage_tmp.name

    def tearDown(self):
        os.environ.pop("CBOX_USAGE_DIR", None)
        if self.saved_usage_dir is not None:
            os.environ["CBOX_USAGE_DIR"] = self.saved_usage_dir
        self._usage_tmp.cleanup()
        super().tearDown()

    def _codex_json_path(self):
        return os.path.join(self._usage_tmp.name, "codex.json")

    def _wait_for_codex_json(self, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(self._codex_json_path()):
                with open(self._codex_json_path(), "r", encoding="utf-8") as f:
                    return json.load(f)
            time.sleep(0.05)
        return None

    def test_thread_start_failure_still_refreshes_codex_json(self):
        os.environ["STUB_APP_SERVER_MODE"] = "thread_start_fail"
        relay = self.make_relay(child_argv=stub_child())
        resp = self.start_and_wait(
            relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
        )
        self.assertIsNotNone(resp)
        self.assertEqual(resp["error"]["code"], -32000)
        data = self._wait_for_codex_json()
        self.assertIsNotNone(
            data, "no background refresh happened after a thread/start failure",
        )
        self.assertEqual(data["source"], "codex")
        self.assertEqual(data["ordinary_usage_allowed"], False)

    def test_thread_resume_failure_still_refreshes_codex_json(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ["STUB_APP_SERVER_STATE_FILE"] = os.path.join(td, "state.json")
            os.environ["STUB_APP_SERVER_MODE"] = "happy"
            relay = self.make_relay(child_argv=stub_child())
            resp = self.start_and_wait(
                relay, "codex", {"cwd": self.good_cwd, "prompt": "hi"}, 1,
            )
            self.assertIsNotNone(resp)
            self.assertNotIn("error", resp)
            thread_id = resp["result"]["structuredContent"]["threadId"]

            old_proc = relay.backend.proc
            old_proc.kill()
            old_proc.wait(timeout=5)
            old_proc.stdin.close()
            old_proc.stdout.close()

            os.environ["STUB_APP_SERVER_MODE"] = "resume_fail"
            resp2 = self.start_and_wait(
                relay, "codex-reply", {"threadId": thread_id, "prompt": "again"}, 2,
                timeout=15,
            )
            self.assertIsNotNone(resp2)
            self.assertEqual(resp2["error"]["code"], -32000)
            data = self._wait_for_codex_json()
            self.assertIsNotNone(
                data, "no background refresh happened after a thread/resume failure",
            )
            self.assertEqual(data["source"], "codex")


if __name__ == "__main__":
    unittest.main()
