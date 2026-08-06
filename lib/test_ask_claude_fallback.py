#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import types
import unittest
import unittest.mock
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ask_claude_mcp", ROOT / "etc" / "codex" / "ask_claude_mcp.py"
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FakeCompletedProcess:
    def __init__(self, stdout, returncode=0):
        self.stdout = stdout
        self.stderr = ""
        self.returncode = returncode


class ValidModelTokenTests(unittest.TestCase):
    def test_accepts_plain_alias(self):
        self.assertTrue(MOD.valid_model_token("sonnet"))

    def test_accepts_bracketed_full_name(self):
        self.assertTrue(MOD.valid_model_token("some-model-name[1m]"))

    def test_rejects_empty(self):
        self.assertFalse(MOD.valid_model_token(""))

    def test_rejects_leading_dash(self):
        self.assertFalse(MOD.valid_model_token("-model"))

    def test_rejects_whitespace(self):
        self.assertFalse(MOD.valid_model_token("model name"))

    def test_rejects_non_string(self):
        self.assertFalse(MOD.valid_model_token(None))
        self.assertFalse(MOD.valid_model_token(5))


class FallbackModelMapTests(unittest.TestCase):
    def test_map_file_parses_and_has_expected_keys(self):
        data = MOD.load_fallback_model_map()
        self.assertIn("fable", data)
        self.assertIn("opus", data)
        for key, chain in data.items():
            self.assertIsInstance(chain, list)
            self.assertTrue(chain)
            for entry in chain:
                self.assertTrue(MOD.valid_model_token(entry))

    def test_unknown_model_has_no_default_chain(self):
        self.assertEqual(MOD.default_fallback_chain("sonnet"), [])
        self.assertEqual(MOD.default_fallback_chain("haiku"), [])

    def test_known_alias_has_a_default_chain(self):
        chain = MOD.default_fallback_chain("fable")
        self.assertTrue(chain)
        for entry in chain:
            self.assertTrue(MOD.valid_model_token(entry))

    def test_map_load_survives_missing_file(self):
        with mock.patch.object(MOD, "FALLBACK_MODEL_MAP_PATH", "/no/such/file.json"):
            self.assertEqual(MOD.load_fallback_model_map(), {})

    def test_map_load_survives_malformed_json(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{not valid json")
            path = f.name
        try:
            with mock.patch.object(MOD, "FALLBACK_MODEL_MAP_PATH", path):
                self.assertEqual(MOD.load_fallback_model_map(), {})
        finally:
            os.unlink(path)

    def test_map_load_drops_non_list_and_non_string_entries(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({
                "good": ["a-model"],
                "bad-not-a-list": "a-model",
                "bad-entries": ["", "  ", "-nope", "ok-model"],
            }, f)
            path = f.name
        try:
            with mock.patch.object(MOD, "FALLBACK_MODEL_MAP_PATH", path):
                data = MOD.load_fallback_model_map()
                self.assertEqual(data["good"], ["a-model"])
                self.assertNotIn("bad-not-a-list", data)
                self.assertEqual(data["bad-entries"], ["ok-model"])
        finally:
            os.unlink(path)


class ResolveFallbackModelsTests(unittest.TestCase):
    def setUp(self):
        self.env_patch = mock.patch.dict(os.environ, {}, clear=False)
        self.env_patch.start()
        os.environ.pop(MOD.FALLBACK_MODEL_ENV, None)

    def tearDown(self):
        self.env_patch.stop()

    def test_no_override_uses_default_chain_for_known_alias(self):
        chain, err = MOD.resolve_fallback_models("fable")
        self.assertIsNone(err)
        self.assertEqual(chain, MOD.default_fallback_chain("fable"))
        self.assertTrue(chain)

    def test_no_override_empty_chain_for_unmapped_model(self):
        chain, err = MOD.resolve_fallback_models("sonnet")
        self.assertIsNone(err)
        self.assertEqual(chain, [])

    def test_override_empty_string_disables_fallback(self):
        os.environ[MOD.FALLBACK_MODEL_ENV] = ""
        chain, err = MOD.resolve_fallback_models("fable")
        self.assertIsNone(err)
        self.assertEqual(chain, [])

    def test_override_comma_separated_list_accepted(self):
        os.environ[MOD.FALLBACK_MODEL_ENV] = "model-a, model-b"
        chain, err = MOD.resolve_fallback_models("sonnet")
        self.assertIsNone(err)
        self.assertEqual(chain, ["model-a", "model-b"])

    def test_override_rejects_malformed_entry(self):
        os.environ[MOD.FALLBACK_MODEL_ENV] = "model-a,-bad-entry"
        chain, err = MOD.resolve_fallback_models("sonnet")
        self.assertIsNone(chain)
        self.assertIsNotNone(err)
        self.assertIn(MOD.FALLBACK_MODEL_ENV, err)

    def test_override_rejects_whitespace_entry(self):
        os.environ[MOD.FALLBACK_MODEL_ENV] = "model-a,bad entry"
        chain, err = MOD.resolve_fallback_models("sonnet")
        self.assertIsNone(chain)
        self.assertIsNotNone(err)


class RunClaudeArgvTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop(MOD.DEPTH_VAR, None)
        os.environ.pop(MOD.LEGACY_DEPTH_VAR, None)
        os.environ.pop(MOD.FALLBACK_MODEL_ENV, None)
        self.captured = {}

    def _fake_run(self, cmd, **kwargs):
        self.captured["cmd"] = cmd
        return FakeCompletedProcess(json.dumps({"result": "ok", "is_error": False}))

    def test_default_model_has_no_fallback_flag(self):
        with mock.patch.object(MOD.subprocess, "run", self._fake_run):
            MOD.run_claude({"prompt": "hello"})
        cmd = self.captured["cmd"]
        self.assertNotIn("--fallback-model", cmd)

    def test_fable_model_gets_default_fallback_chain(self):
        with mock.patch.object(MOD.subprocess, "run", self._fake_run):
            MOD.run_claude({"prompt": "hello", "model": "fable"})
        cmd = self.captured["cmd"]
        self.assertIn("--fallback-model", cmd)
        i = cmd.index("--fallback-model")
        chain_arg = cmd[i + 1]
        expected = ",".join(MOD.default_fallback_chain("fable"))
        self.assertEqual(chain_arg, expected)
        self.assertIn("--model", cmd)
        j = cmd.index("--model")
        self.assertEqual(cmd[j + 1], "fable")

    def test_operator_override_chain_used_verbatim(self):
        os.environ[MOD.FALLBACK_MODEL_ENV] = "custom-a,custom-b"
        with mock.patch.object(MOD.subprocess, "run", self._fake_run):
            MOD.run_claude({"prompt": "hello", "model": "fable"})
        cmd = self.captured["cmd"]
        i = cmd.index("--fallback-model")
        self.assertEqual(cmd[i + 1], "custom-a,custom-b")

    def test_malformed_override_refuses_before_invoking_claude(self):
        os.environ[MOD.FALLBACK_MODEL_ENV] = "-bad"
        called = {"n": 0}

        def _should_not_run(cmd, **kwargs):
            called["n"] += 1
            return FakeCompletedProcess(json.dumps({"result": "x"}))

        with mock.patch.object(MOD.subprocess, "run", _should_not_run):
            result = MOD.run_claude({"prompt": "hello", "model": "sonnet"})
        self.assertEqual(called["n"], 0)
        self.assertTrue(result["isError"])
        self.assertIn(MOD.FALLBACK_MODEL_ENV, result["content"][0]["text"])

    def test_invalid_model_still_rejected_before_fallback_resolution(self):
        result = MOD.run_claude({"prompt": "hello", "model": "-bad-model"})
        self.assertTrue(result["isError"])
        self.assertIn("invalid model name", result["content"][0]["text"])


class SafetyRefusalRetryTests(unittest.TestCase):
    def _proc(self, rc, out="", err=""):
        return types.SimpleNamespace(returncode=rc, stdout=out, stderr=err)

    def test_clean_run_is_not_a_safety_refusal(self):
        self.assertFalse(MOD.is_safety_refusal(self._proc(0, "all good")))

    def test_marker_without_failure_is_ignored(self):
        proc = self._proc(0, "Cyber Verification Program is a thing")
        self.assertFalse(MOD.is_safety_refusal(proc))

    def test_safety_marker_on_failure_is_detected(self):
        proc = self._proc(1, "", "API Error: Fable 5 has safety measures "
                                 "that flagged this message")
        self.assertTrue(MOD.is_safety_refusal(proc))

    def test_cvp_marker_on_failure_is_detected(self):
        proc = self._proc(2, "visit the Cyber Verification Program page", "")
        self.assertTrue(MOD.is_safety_refusal(proc))

    def test_unrelated_failure_is_not_a_safety_refusal(self):
        self.assertFalse(MOD.is_safety_refusal(self._proc(1, "", "network down")))


class RetryFlagPreservationTests(unittest.TestCase):
    def test_every_attempt_carries_identical_restrictions(self):
        calls = []
        safety = types.SimpleNamespace(
            returncode=1, stdout="",
            stderr="API Error: safety measures that flagged this message")

        def fake_run(cmd, **kwargs):
            calls.append(list(cmd))
            return safety

        with unittest.mock.patch.object(MOD.subprocess, "run", fake_run), \
                unittest.mock.patch.dict(
                    os.environ, {MOD.FALLBACK_MODEL_ENV: "m2,m3"}):
            MOD.run_claude({"prompt": "hello", "model": "m1"})

        self.assertEqual(len(calls), 3)
        self.assertEqual([c[c.index("--model") + 1] for c in calls],
                         ["m1", "m2", "m3"])
        sensitive = ("--strict-mcp-config", "--mcp-config", "--permission-mode",
                     "--allowedTools", "--disallowedTools", "--max-turns",
                     "--dangerously-skip-permissions", "--append-system-prompt")

        def profile(cmd):
            out = []
            for flag in sensitive:
                if flag in cmd:
                    out.append((flag, cmd[cmd.index(flag) + 1]
                                if cmd.index(flag) + 1 < len(cmd) else None))
            return out

        first = profile(calls[0])
        for later in calls[1:]:
            self.assertEqual(profile(later), first)

    def test_marker_supplied_by_caller_does_not_trigger_retry(self):
        calls = []
        proc = types.SimpleNamespace(
            returncode=1, stdout="",
            stderr="safety measures that flagged")

        def fake_run(cmd, **kwargs):
            calls.append(list(cmd))
            return proc

        with unittest.mock.patch.object(MOD.subprocess, "run", fake_run), \
                unittest.mock.patch.dict(
                    os.environ, {MOD.FALLBACK_MODEL_ENV: "m2"}):
            MOD.run_claude({"prompt": "echo safety measures that flagged",
                            "model": "m1"})
        self.assertEqual(len(calls), 1)


class DelegateIsALeafTests(unittest.TestCase):
    def _cmds(self, args, in_container=True):
        calls = []
        proc = types.SimpleNamespace(returncode=0, stdout='{"result":"ok"}', stderr="")

        def fake_run(cmd, **kwargs):
            calls.append(list(cmd))
            return proc

        with unittest.mock.patch.object(MOD.subprocess, "run", fake_run), \
                unittest.mock.patch.object(MOD, "in_container", lambda: in_container), \
                unittest.mock.patch.object(MOD, "check_cwd", lambda p: (p, None)):
            MOD.run_claude(args)
        return calls

    def _asserts_leaf(self, cmd):
        self.assertIn("--strict-mcp-config", cmd)
        i = cmd.index("--mcp-config")
        self.assertEqual(cmd[i + 1], '{"mcpServers":{}}')

    def test_every_branch_renders_a_leaf(self):
        cases = [
            ({"prompt": "p", "model": "sonnet", "cwd": "/tmp", "mode": "full"}, True),
            ({"prompt": "p", "model": "sonnet", "cwd": "/tmp", "mode": "analyse"}, True),
            ({"prompt": "p", "model": "sonnet", "cwd": "/tmp", "mode": "full"}, False),
            ({"prompt": "p", "model": "sonnet"}, True),
        ]
        for args, inc in cases:
            with self.subTest(args=args, in_container=inc):
                for cmd in self._cmds(args, inc):
                    self._asserts_leaf(cmd)


if __name__ == "__main__":
    unittest.main()
