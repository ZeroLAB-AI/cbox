#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "hermes_delegate_mcp", ROOT / "etc" / "mcp" / "hermes_delegate_mcp.py"
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


STUB_SOURCE = '''#!/usr/bin/env python3
import json
import os
import sys
import time

CONTROL_FILE = %(control_file)r

control = {}
if os.path.exists(CONTROL_FILE):
    with open(CONTROL_FILE) as fh:
        control = json.load(fh)

marker = control.get("marker")
env_dump = control.get("env_dump")

if marker:
    with open(marker, "a") as fh:
        fh.write(" ".join(sys.argv[1:]) + "\\n")

if env_dump and not os.path.exists(env_dump):
    with open(env_dump, "w") as fh:
        fh.write("HOME=" + os.environ.get("HOME", "") + "\\n")
        fh.write("HERMES_HOME=" + os.environ.get("HERMES_HOME", "") + "\\n")
        for _name in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
                      "http_proxy", "https_proxy", "no_proxy", "all_proxy"):
            fh.write(_name + "=" + os.environ.get(_name, "") + "\\n")

TOOLSET_STATE_FILE = os.path.join(os.path.dirname(CONTROL_FILE), "toolset_state.txt")

if (len(sys.argv) >= 5 and sys.argv[1] == "config" and sys.argv[2] == "set"
        and sys.argv[3] == "agent.disabled_toolsets"):
    with open(TOOLSET_STATE_FILE, "w") as fh:
        fh.write(sys.argv[4])
    sys.exit(0)

if len(sys.argv) >= 3 and sys.argv[1] == "config" and sys.argv[2] == "set":
    sys.exit(0)

if (len(sys.argv) >= 4 and sys.argv[1] == "config" and sys.argv[2] == "get"
        and sys.argv[3] == "agent.disabled_toolsets"):
    toolset_get_mode = control.get("toolset_get_mode", "ok")
    if toolset_get_mode == "fail":
        sys.stderr.write("config get: injected failure\\n")
        sys.exit(1)
    if toolset_get_mode == "mismatch":
        sys.stdout.write("not-what-was-set\\n")
        sys.exit(0)
    stored = ""
    if os.path.exists(TOOLSET_STATE_FILE):
        with open(TOOLSET_STATE_FILE) as fh:
            stored = fh.read()
    sys.stdout.write(stored + "\\n")
    sys.exit(0)

if len(sys.argv) >= 2 and sys.argv[1] == "-z":
    mode = control.get("mode", "ok")
    if mode == "sleep":
        time.sleep(float(control.get("sleep_sec", 10)))
        sys.stdout.write("should not get here\\n")
        sys.exit(0)
    if mode == "ansi":
        sys.stdout.write("\\x1b[31mhello\\x1b[0m colored\\n")
        sys.exit(0)
    if mode == "fail":
        sys.stderr.write("stub failure\\n")
        sys.exit(1)
    sys.stdout.write("stub-canned-answer\\n")
    sys.exit(0)

sys.exit(0)
'''


def make_stub(tmpdir, control_file):
    stub_path = os.path.join(tmpdir, "hermes-stub.py")
    with open(stub_path, "w") as fh:
        fh.write(STUB_SOURCE % {"control_file": control_file})
    os.chmod(stub_path, os.stat(stub_path).st_mode | stat.S_IEXEC)
    return stub_path


def write_control(control_file, **kwargs):
    with open(control_file, "w") as fh:
        json.dump(kwargs, fh)


def make_template_home(tmpdir, hardened=True):
    home = os.path.join(tmpdir, "template-home")
    os.makedirs(home, exist_ok=True)
    cfg = os.path.join(home, "config.yaml")
    with open(cfg, "w") as fh:
        fh.write("model:\n  provider: local\n")
    if hardened:
        os.chmod(cfg, 0o444)
        os.chmod(home, 0o555)
    return home


class HermesDelegateUnitTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.control_file = os.path.join(self.tmpdir, "control.json")
        write_control(self.control_file)
        self.stub = make_stub(self.tmpdir, self.control_file)
        self.template_home = make_template_home(self.tmpdir)
        self.env_backup = dict(os.environ)
        os.environ["HERMES_BIN"] = self.stub
        os.environ["CBOX_HERMES_DELEGATE_HOME_TEMPLATE"] = self.template_home
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        os.environ["CBOX_HERMES_DELEGATE_BASE_URL"] = "http://127.0.0.1:11434"
        os.environ.pop("CBOX_HERMES_DELEGATE_MODEL", None)
        os.environ.pop("CBOX_HERMES_PROVIDER", None)
        os.environ.pop("CBOX_HERMES_MODEL_URL", None)
        os.environ.pop("CBOX_HERMES_MODEL_NAME", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_TIMEOUT_SEC", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_MAX_PROMPT_BYTES", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_MAX_RESPONSE_BYTES", None)
        os.environ.pop(MOD.DEPTH_VAR, None)
        os.environ.pop(MOD.LEGACY_DEPTH_VAR, None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_backup)

    def _tmp_root_dirs(self):
        return {
            d for d in os.listdir(tempfile.gettempdir())
            if d.startswith("cbox-hermes-delegate-")
        }

    def test_happy_path_returns_stub_answer_and_cleans_up(self):
        before = self._tmp_root_dirs()
        result = MOD.run_hermes_delegate({"prompt": "hello there"})
        after = self._tmp_root_dirs()
        self.assertFalse(result["isError"], result)
        self.assertIn("stub-canned-answer", result["content"][0]["text"])
        self.assertIn(
            "untrusted local-model output", result["content"][0]["text"])
        self.assertEqual(before, after)

    def test_audit_record_carries_caller_name(self):
        audit_path = os.path.join(self.tmpdir, "audit.jsonl")
        os.environ["CBOX_HERMES_DELEGATE_AUDIT"] = audit_path
        try:
            MOD.set_caller_name("codex")
            result = MOD.run_hermes_delegate({"prompt": "hi"})
            self.assertFalse(result["isError"], result)
            with open(audit_path) as fh:
                rec = json.loads(fh.readline())
            self.assertEqual(rec["caller"], "codex")
        finally:
            MOD.set_caller_name(None)
            MOD._CALLER_NAME = ""
            os.environ.pop("CBOX_HERMES_DELEGATE_AUDIT", None)

    def test_audit_record_defaults_to_unknown_caller(self):
        audit_path = os.path.join(self.tmpdir, "audit_unknown.jsonl")
        os.environ["CBOX_HERMES_DELEGATE_AUDIT"] = audit_path
        try:
            MOD._CALLER_NAME = ""
            result = MOD.run_hermes_delegate({"prompt": "hi"})
            self.assertFalse(result["isError"], result)
            with open(audit_path) as fh:
                rec = json.loads(fh.readline())
            self.assertEqual(rec["caller"], "unknown")
        finally:
            os.environ.pop("CBOX_HERMES_DELEGATE_AUDIT", None)

    def test_audit_write_failure_warns_on_stderr(self):
        audit_dir = os.path.join(self.tmpdir, "audit_as_dir.jsonl")
        os.makedirs(audit_dir)
        os.environ["CBOX_HERMES_DELEGATE_AUDIT"] = audit_dir
        stderr_capture = io.StringIO()
        try:
            old_stderr = sys.stderr
            sys.stderr = stderr_capture
            try:
                result = MOD.run_hermes_delegate({"prompt": "hi"})
            finally:
                sys.stderr = old_stderr
            self.assertFalse(result["isError"], result)
            self.assertIn("audit write failed", stderr_capture.getvalue())
        finally:
            os.environ.pop("CBOX_HERMES_DELEGATE_AUDIT", None)

    def test_ephemeral_home_used_not_console_home(self):
        env_dump = os.path.join(self.tmpdir, "env_dump.txt")
        write_control(self.control_file, env_dump=env_dump)
        result = MOD.run_hermes_delegate({"prompt": "hello"})
        self.assertFalse(result["isError"], result)
        with open(env_dump) as fh:
            dumped = fh.read()
        self.assertNotIn("HERMES_HOME=" + self.template_home, dumped)
        self.assertNotIn("HERMES_HOME=\n", dumped)
        home_line = [
            l for l in dumped.splitlines() if l.startswith("HERMES_HOME=")
        ][0]
        home_val = home_line.split("=", 1)[1]
        self.assertTrue(
            home_val.startswith(tempfile.gettempdir()),
            "HERMES_HOME was not an ephemeral tmp dir: %s" % home_val)
        self.assertNotEqual(home_val, self.template_home)
        self.assertFalse(os.path.isdir(home_val))

    def test_missing_prompt_refused(self):
        result = MOD.run_hermes_delegate({})
        self.assertTrue(result["isError"])
        self.assertIn("prompt must be", result["content"][0]["text"])

    def test_prompt_over_cap_refused_before_spawn(self):
        marker = os.path.join(self.tmpdir, "marker.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_HERMES_DELEGATE_MAX_PROMPT_BYTES"] = "10"
        result = MOD.run_hermes_delegate(
            {"prompt": "this prompt is way too long for the cap"})
        self.assertTrue(result["isError"])
        self.assertIn("exceeds max size", result["content"][0]["text"])
        self.assertFalse(os.path.exists(marker))

    def test_timeout_kills_and_returns_error(self):
        write_control(self.control_file, mode="sleep", sleep_sec=10)
        os.environ["CBOX_HERMES_DELEGATE_TIMEOUT_SEC"] = "1"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        self.assertIn("timed out", result["content"][0]["text"])

    def test_ansi_stripped_from_output(self):
        write_control(self.control_file, mode="ansi")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        text = result["content"][0]["text"]
        self.assertNotIn("\x1b", text)
        self.assertIn("hello", text)
        self.assertIn("colored", text)

    def test_stub_failure_surfaces_error(self):
        write_control(self.control_file, mode="fail")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])

    def test_depth_reached_refuses_without_spawn(self):
        marker = os.path.join(self.tmpdir, "marker_depth.txt")
        write_control(self.control_file, marker=marker)
        os.environ[MOD.DEPTH_VAR] = "1"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        self.assertIn("depth limit", result["content"][0]["text"])
        self.assertFalse(os.path.exists(marker))

    def test_config_applied_via_cli_when_set(self):
        marker = os.path.join(self.tmpdir, "marker_cfg.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        os.environ["CBOX_HERMES_DELEGATE_BASE_URL"] = "http://127.0.0.1:11434"
        os.environ["CBOX_HERMES_DELEGATE_MODEL"] = "qwen2.5:7b"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn("config set model.provider local", calls)
        self.assertIn(
            "config set model.base_url http://127.0.0.1:11434", calls)
        self.assertIn("config set model.default qwen2.5:7b", calls)

    def test_no_provider_refuses_to_trust_the_seeded_template(self):
        os.environ.pop("CBOX_HERMES_DELEGATE_PROVIDER", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_BASE_URL", None)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn("refusing to delegate", result["content"][0]["text"])

    def test_local_provider_without_base_url_refused(self):
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        os.environ.pop("CBOX_HERMES_DELEGATE_BASE_URL", None)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn("refusing to delegate", result["content"][0]["text"])

    def test_console_vars_are_the_fallback_endpoint(self):
        marker = os.path.join(self.tmpdir, "marker_fallback.txt")
        write_control(self.control_file, marker=marker)
        os.environ.pop("CBOX_HERMES_DELEGATE_PROVIDER", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_BASE_URL", None)
        os.environ["CBOX_HERMES_PROVIDER"] = "local"
        os.environ["CBOX_HERMES_MODEL_URL"] = "http://127.0.0.1:12345"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn("config set model.base_url http://127.0.0.1:12345", calls)

    def test_invalid_provider_config_refused(self):
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "not-a-real-provider"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"])
        self.assertIn("invalid", result["content"][0]["text"])

    def test_disabled_toolsets_applied_in_qa_mode_by_default(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets.txt")
        write_control(self.control_file, marker=marker)
        os.environ.pop("CBOX_HERMES_DELEGATE_MODE", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS", None)
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn(
            "config set agent.disabled_toolsets " + MOD.DEFAULT_DISABLED_TOOLSETS,
            calls)

    def test_disabled_toolsets_applied_with_custom_value(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets2.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = "terminal,web"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn("config set agent.disabled_toolsets terminal,web", calls)

    def test_disabled_toolsets_falls_back_to_default_when_var_empty(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets3.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = ""
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn(
            "config set agent.disabled_toolsets " + MOD.DEFAULT_DISABLED_TOOLSETS,
            calls)

    def test_disabled_toolsets_readback_confirms_the_pin(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets4.txt")
        write_control(self.control_file, marker=marker)
        os.environ["CBOX_HERMES_DELEGATE_DISABLED_TOOLSETS"] = "terminal,web"
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertFalse(result["isError"], result)
        with open(marker) as fh:
            calls = fh.read()
        self.assertIn(
            "config get agent.disabled_toolsets", calls)

    def test_disabled_toolsets_readback_mismatch_refuses_the_call(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets5.txt")
        write_control(
            self.control_file, marker=marker, toolset_get_mode="mismatch")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn(
            "did not take effect", result["content"][0]["text"])

    def test_disabled_toolsets_readback_failure_refuses_the_call(self):
        marker = os.path.join(self.tmpdir, "marker_toolsets6.txt")
        write_control(
            self.control_file, marker=marker, toolset_get_mode="fail")
        result = MOD.run_hermes_delegate({"prompt": "hi"})
        self.assertTrue(result["isError"], result)
        self.assertIn(
            "confirming the toolset pin", result["content"][0]["text"])

    def test_proxy_env_passed_through_to_child(self):
        env_dump = os.path.join(self.tmpdir, "proxy_env_dump.txt")
        write_control(self.control_file, env_dump=env_dump)
        os.environ["HTTPS_PROXY"] = "http://proxy.internal:3128"
        os.environ["no_proxy"] = "localhost,127.0.0.1"
        os.environ["ALL_PROXY"] = "socks5h://proxy.internal:1080"
        try:
            result = MOD.run_hermes_delegate({"prompt": "hi"})
            self.assertFalse(result["isError"], result)
        finally:
            os.environ.pop("HTTPS_PROXY", None)
            os.environ.pop("no_proxy", None)
            os.environ.pop("ALL_PROXY", None)
        with open(env_dump) as fh:
            dumped = fh.read()
        self.assertIn("HTTPS_PROXY=http://proxy.internal:3128", dumped)
        self.assertIn("no_proxy=localhost,127.0.0.1", dumped)
        self.assertIn("HTTP_PROXY=\n", dumped)
        self.assertIn(
            "ALL_PROXY=\n", dumped,
            "ALL_PROXY must never reach the hermes child even when set in "
            "the parent (netaccess SOCKS bridge must not follow)")

    def test_proxy_env_helper_picks_up_set_vars_only(self):
        for name in MOD.PROXY_PASSTHROUGH_VARS:
            os.environ.pop(name, None)
        self.assertEqual(MOD._proxy_env(), {})
        os.environ["HTTP_PROXY"] = "http://proxy.internal:8080"
        try:
            result = MOD._proxy_env()
            self.assertEqual(
                result, {"HTTP_PROXY": "http://proxy.internal:8080"})
        finally:
            os.environ.pop("HTTP_PROXY", None)

    def test_proxy_env_helper_never_forwards_all_proxy(self):
        self.assertNotIn("ALL_PROXY", MOD.PROXY_PASSTHROUGH_VARS)
        self.assertNotIn("all_proxy", MOD.PROXY_PASSTHROUGH_VARS)
        os.environ["ALL_PROXY"] = "socks5h://proxy.internal:1080"
        try:
            result = MOD._proxy_env()
            self.assertNotIn("ALL_PROXY", result)
        finally:
            os.environ.pop("ALL_PROXY", None)


class DelegateModeTests(unittest.TestCase):
    def test_default_mode_is_qa(self):
        os.environ.pop("CBOX_HERMES_DELEGATE_MODE", None)
        self.assertEqual(MOD.delegate_mode(), "qa")

    def test_qa_mode_validates(self):
        self.assertIsNone(MOD.validate_mode("qa"))

    def test_unknown_mode_refused_with_supported_value_named(self):
        err = MOD.validate_mode("workspace")
        self.assertIsNotNone(err)
        self.assertIn("workspace", err)
        self.assertIn("qa", err)
        self.assertIn("CBOX_HERMES_DELEGATE_MODE", err)

    def test_workspace_mode_not_yet_valid(self):
        self.assertNotIn("workspace", MOD.VALID_MODES)


class StripAnsiTests(unittest.TestCase):
    def test_csi_sgr_stripped(self):
        self.assertEqual(
            MOD.strip_ansi(b"\x1b[31mhello\x1b[0m colored\n"),
            b"hello colored\n")

    def test_csi_private_mode_stripped(self):
        self.assertEqual(
            MOD.strip_ansi(b"\x1b[?25lhide\x1b[?25h"), b"hide")

    def test_osc_title_stripped(self):
        self.assertEqual(
            MOD.strip_ansi(b"\x1b]0;title\x07after"), b"after")

    def test_two_byte_escape_stripped(self):
        self.assertEqual(
            MOD.strip_ansi(b"\x1bMreverse-index"), b"reverse-index")

    def test_control_bytes_stripped(self):
        self.assertEqual(
            MOD.strip_ansi(b"\x00\x01ctrl\x1f end"), b"ctrl end")

    def test_plain_text_passes_through(self):
        self.assertEqual(MOD.strip_ansi(b"plain text"), b"plain text")

    def test_many_unterminated_osc_sequences_do_not_hang(self):
        payload = b"\x1b]a" * 300000
        start = time.monotonic()
        MOD.strip_ansi(payload)
        elapsed = time.monotonic() - start
        self.assertLess(
            elapsed, 5.0,
            "strip_ansi took %.2fs on many unterminated OSC sequences "
            "(expected sub-second, linear-time scan)" % elapsed)

    def test_single_huge_unterminated_osc_does_not_hang(self):
        payload = b"\x1b]" + b"a" * 999998
        start = time.monotonic()
        MOD.strip_ansi(payload)
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, 5.0)

    def test_huge_unterminated_csi_params_do_not_hang(self):
        payload = b"\x1b[" + b";" * 300000
        start = time.monotonic()
        MOD.strip_ansi(payload)
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, 5.0)

    def test_fuzz_matches_reference_regex_implementation(self):
        import re
        import random

        ansi_re = re.compile(
            rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[@-_]")
        ctrl_re = re.compile(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]")

        def reference(raw):
            return ctrl_re.sub(b"", ansi_re.sub(b"", raw))

        random.seed(20260721)
        alphabet = [
            0x1b, 0x5b, 0x5d, 0x07, ord('m'), ord('a'), ord(';'), ord('?'),
            0x00, 0x1f, 0x40, 0x7e, ord('0'),
        ]
        for _ in range(4000):
            length = random.randint(0, 20)
            data = bytes(random.choice(alphabet) for _ in range(length))
            self.assertEqual(
                MOD.strip_ansi(data), reference(data),
                "mismatch for %r" % data)


class HermesDelegateStdioTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.control_file = os.path.join(self.tmpdir, "control.json")
        write_control(self.control_file)
        self.stub = make_stub(self.tmpdir, self.control_file)
        self.template_home = make_template_home(self.tmpdir)
        self.env = dict(os.environ)
        self.env["HERMES_BIN"] = self.stub
        self.env["CBOX_HERMES_DELEGATE_HOME_TEMPLATE"] = self.template_home
        self.env["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        self.env["CBOX_HERMES_DELEGATE_BASE_URL"] = "http://127.0.0.1:11434"
        self.env.pop("CBOX_HERMES_DELEGATE_MODEL", None)
        self.env.pop("CBOX_HERMES_PROVIDER", None)
        self.env.pop("CBOX_HERMES_MODEL_URL", None)
        self.env.pop("CBOX_HERMES_MODEL_NAME", None)
        self.env.pop("CBOX_DELEGATION_DEPTH", None)
        self.env.pop("CBOX_MCP_DEPTH", None)

    def _run(self, messages, env=None):
        proc = subprocess.run(
            [sys.executable, str(ROOT / "etc" / "mcp" /
                                  "hermes_delegate_mcp.py")],
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
             "params": {"name": "hermes-delegate",
                        "arguments": {"prompt": "hello"}}},
        ]
        proc, replies = self._run(messages)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(replies[0]["id"], 1)
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"],
                          "cbox-hermes-delegate")
        tool_names = [t["name"] for t in replies[1]["result"]["tools"]]
        self.assertEqual(tool_names, ["hermes-delegate"])
        self.assertFalse(replies[2]["result"]["isError"])
        self.assertIn(
            "stub-canned-answer",
            replies[2]["result"]["content"][0]["text"])

    def test_depth_stub_over_stdio_empty_tools_and_refusal(self):
        env = dict(self.env)
        env["CBOX_DELEGATION_DEPTH"] = "1"
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "hermes-delegate",
                        "arguments": {"prompt": "hello"}}},
        ]
        proc, replies = self._run(messages, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertEqual(replies[0]["result"]["tools"], [])
        self.assertTrue(replies[1]["result"]["isError"])

    def test_unknown_mode_exits_nonzero(self):
        env = dict(self.env)
        env["CBOX_HERMES_DELEGATE_MODE"] = "workspace"
        proc, replies = self._run([], env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("CBOX_HERMES_DELEGATE_MODE", proc.stderr.decode())
        self.assertIn("qa", proc.stderr.decode())

    def test_default_mode_is_qa_and_starts_cleanly(self):
        env = dict(self.env)
        env.pop("CBOX_HERMES_DELEGATE_MODE", None)
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "hermes-delegate",
                        "arguments": {"prompt": "hello"}}},
        ]
        proc, replies = self._run(messages, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        self.assertFalse(replies[0]["result"]["isError"])

    def test_missing_hermes_bin_exits_nonzero(self):
        env = dict(self.env)
        env["HERMES_BIN"] = "/nonexistent/hermes"
        proc, replies = self._run([], env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("HERMES_BIN", proc.stderr.decode())

    def test_missing_template_home_exits_nonzero(self):
        env = dict(self.env)
        env["CBOX_HERMES_DELEGATE_HOME_TEMPLATE"] = "/nonexistent/home"
        proc, replies = self._run([], env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("CBOX_HERMES_DELEGATE_HOME_TEMPLATE",
                       proc.stderr.decode())

    def test_writable_template_home_exits_nonzero(self):
        loose_tmpdir = tempfile.mkdtemp()
        loose_home = make_template_home(loose_tmpdir, hardened=False)
        env = dict(self.env)
        env["CBOX_HERMES_DELEGATE_HOME_TEMPLATE"] = loose_home
        proc, replies = self._run([], env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("CBOX_HERMES_DELEGATE_HOME_TEMPLATE",
                       proc.stderr.decode())

    def test_symlink_in_template_home_exits_nonzero(self):
        secret_dir = tempfile.mkdtemp()
        secret = os.path.join(secret_dir, "auth.json")
        with open(secret, "w") as fh:
            fh.write('{"token": "super-secret"}')
        hardened_tmpdir = tempfile.mkdtemp()
        home = make_template_home(hardened_tmpdir)
        link = os.path.join(home, "planted-link")
        os.chmod(home, 0o755)
        os.symlink(secret, link)
        os.chmod(home, 0o555)
        env = dict(self.env)
        env["CBOX_HERMES_DELEGATE_HOME_TEMPLATE"] = home
        proc, replies = self._run([], env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("CBOX_HERMES_DELEGATE_HOME_TEMPLATE",
                       proc.stderr.decode())


class HermesDelegateTemplateContentTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.control_file = os.path.join(self.tmpdir, "control.json")
        write_control(self.control_file)
        self.stub = make_stub(self.tmpdir, self.control_file)
        self.env_backup = dict(os.environ)
        os.environ["HERMES_BIN"] = self.stub
        os.environ["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        os.environ["CBOX_HERMES_DELEGATE_BASE_URL"] = "http://127.0.0.1:11434"
        os.environ.pop("CBOX_HERMES_DELEGATE_MODEL", None)
        os.environ.pop("CBOX_HERMES_PROVIDER", None)
        os.environ.pop("CBOX_HERMES_MODEL_URL", None)
        os.environ.pop("CBOX_HERMES_MODEL_NAME", None)
        os.environ.pop(MOD.DEPTH_VAR, None)
        os.environ.pop(MOD.LEGACY_DEPTH_VAR, None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_backup)

    def _seed(self, home):
        os.environ["CBOX_HERMES_DELEGATE_HOME_TEMPLATE"] = home
        ephemeral_home = tempfile.mkdtemp()
        return ephemeral_home

    def test_auth_json_in_template_is_refused(self):
        home = os.path.join(self.tmpdir, "template-home-auth")
        os.makedirs(home)
        with open(os.path.join(home, "auth.json"), "w") as fh:
            fh.write('{"token": "secret"}')
        ephemeral_home = self._seed(home)
        try:
            with self.assertRaises(MOD.TemplateHomeContractError):
                MOD._seed_ephemeral_home(ephemeral_home)
            self.assertFalse(
                os.path.exists(os.path.join(ephemeral_home, "auth.json")),
                "auth.json leaked into the ephemeral home before the "
                "contract check raised")
        finally:
            shutil.rmtree(ephemeral_home, ignore_errors=True)

    def test_skills_dir_in_template_is_refused(self):
        home = os.path.join(self.tmpdir, "template-home-skills")
        os.makedirs(os.path.join(home, "skills"))
        with open(os.path.join(home, "skills", "skill.py"), "w") as fh:
            fh.write("pass")
        ephemeral_home = self._seed(home)
        try:
            with self.assertRaises(MOD.TemplateHomeContractError):
                MOD._seed_ephemeral_home(ephemeral_home)
            self.assertFalse(
                os.path.isdir(os.path.join(ephemeral_home, "skills")),
                "skills/ leaked into the ephemeral home before the "
                "contract check raised")
        finally:
            shutil.rmtree(ephemeral_home, ignore_errors=True)

    def test_mcp_json_in_template_is_refused(self):
        home = os.path.join(self.tmpdir, "template-home-mcp")
        os.makedirs(home)
        with open(os.path.join(home, "mcp.json"), "w") as fh:
            fh.write('{"mcpServers": {"evil": {}}}')
        ephemeral_home = self._seed(home)
        try:
            with self.assertRaises(MOD.TemplateHomeContractError):
                MOD._seed_ephemeral_home(ephemeral_home)
            self.assertFalse(
                os.path.exists(os.path.join(ephemeral_home, "mcp.json")),
                "nested mcp config leaked into the ephemeral home before "
                "the contract check raised")
        finally:
            shutil.rmtree(ephemeral_home, ignore_errors=True)

    def test_clean_template_seeds_without_error(self):
        home = os.path.join(self.tmpdir, "template-home-clean")
        os.makedirs(home)
        with open(os.path.join(home, "config.yaml"), "w") as fh:
            fh.write("model:\n  provider: local\n")
        ephemeral_home = self._seed(home)
        try:
            MOD._seed_ephemeral_home(ephemeral_home)
            self.assertTrue(
                os.path.exists(os.path.join(ephemeral_home, "config.yaml")))
        finally:
            shutil.rmtree(ephemeral_home, ignore_errors=True)

    def test_nested_symlink_in_template_is_not_dereferenced(self):
        secret_dir = os.path.join(self.tmpdir, "secret")
        os.makedirs(secret_dir)
        secret = os.path.join(secret_dir, "auth.json")
        with open(secret, "w") as fh:
            fh.write('{"token": "super-secret"}')

        home = os.path.join(self.tmpdir, "template-home2")
        sub = os.path.join(home, "config")
        os.makedirs(sub)
        link = os.path.join(sub, "x")
        os.symlink(secret, link)

        ephemeral_home = self._seed(home)
        try:
            MOD._seed_ephemeral_home(ephemeral_home)
            copied = os.path.join(ephemeral_home, "config", "x")
            self.assertTrue(os.path.islink(copied),
                             "nested template symlink was dereferenced "
                             "into a regular file during seeding")
        finally:
            shutil.rmtree(ephemeral_home, ignore_errors=True)


SLOW_STUB = '''#!/usr/bin/env python3
import sys
import time
REC = %(rec)r
STATE = REC + ".toolsets"
if (len(sys.argv) >= 5 and sys.argv[1] == "config" and sys.argv[2] == "set"
        and sys.argv[3] == "agent.disabled_toolsets"):
    with open(STATE, "w") as fh:
        fh.write(sys.argv[4])
    sys.exit(0)
if (len(sys.argv) >= 4 and sys.argv[1] == "config" and sys.argv[2] == "get"
        and sys.argv[3] == "agent.disabled_toolsets"):
    stored = ""
    try:
        with open(STATE) as fh:
            stored = fh.read()
    except OSError:
        pass
    sys.stdout.write(stored + "\\n")
    sys.exit(0)
if len(sys.argv) > 1 and sys.argv[1] == "-z":
    with open(REC, "a") as fh:
        fh.write("start %%f\\n" %% time.monotonic())
    time.sleep(0.8)
    with open(REC, "a") as fh:
        fh.write("end %%f\\n" %% time.monotonic())
    sys.stdout.write("slow-stub-done\\n")
'''


class ConcurrencySlotTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.lockdir = os.path.join(self.tmpdir, "locks")
        self.env_backup = dict(os.environ)
        os.environ["CBOX_HERMES_DELEGATE_LOCK_DIR"] = self.lockdir
        os.environ.pop("CBOX_HERMES_DELEGATE_MAX_CONCURRENCY", None)
        os.environ.pop("OLLAMA_NUM_PARALLEL", None)
        os.environ.pop("CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC", None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_backup)
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_limit_default_and_sources(self):
        self.assertEqual(MOD.concurrency_limit(), 1)
        os.environ["OLLAMA_NUM_PARALLEL"] = "3"
        self.assertEqual(MOD.concurrency_limit(), 3)
        os.environ["CBOX_HERMES_DELEGATE_MAX_CONCURRENCY"] = "2"
        self.assertEqual(MOD.concurrency_limit(), 2)
        os.environ["CBOX_HERMES_DELEGATE_MAX_CONCURRENCY"] = "garbage"
        self.assertEqual(MOD.concurrency_limit(), 3)
        os.environ["OLLAMA_NUM_PARALLEL"] = "99"
        self.assertEqual(MOD.concurrency_limit(), 16)

    def test_single_slot_blocks_then_releases(self):
        os.environ["CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC"] = "1"
        fd, err = MOD.acquire_slot()
        self.assertIsNone(err)
        t0 = time.monotonic()
        fd2, err2 = MOD.acquire_slot()
        self.assertIsNone(fd2)
        self.assertIn("queue wait exceeded", err2)
        self.assertGreaterEqual(time.monotonic() - t0, 1.0)
        MOD.release_slot(fd)
        fd3, err3 = MOD.acquire_slot()
        self.assertIsNone(err3)
        MOD.release_slot(fd3)

    def test_two_slots_allow_two_holders(self):
        os.environ["CBOX_HERMES_DELEGATE_MAX_CONCURRENCY"] = "2"
        os.environ["CBOX_HERMES_DELEGATE_QUEUE_WAIT_SEC"] = "1"
        fd1, err1 = MOD.acquire_slot()
        fd2, err2 = MOD.acquire_slot()
        self.assertIsNone(err1)
        self.assertIsNone(err2)
        fd3, err3 = MOD.acquire_slot()
        self.assertIsNone(fd3)
        self.assertIn("queue wait exceeded", err3)
        MOD.release_slot(fd1)
        MOD.release_slot(fd2)

    def test_cross_process_serialization(self):
        rec = os.path.join(self.tmpdir, "rec.txt")
        stub_path = os.path.join(self.tmpdir, "slow-stub.py")
        with open(stub_path, "w") as fh:
            fh.write(SLOW_STUB % {"rec": rec})
        os.chmod(stub_path, os.stat(stub_path).st_mode | stat.S_IEXEC)
        template = make_template_home(self.tmpdir)
        env = dict(os.environ)
        env["HERMES_BIN"] = stub_path
        env["CBOX_HERMES_DELEGATE_HOME_TEMPLATE"] = template
        env["CBOX_HERMES_DELEGATE_PROVIDER"] = "local"
        env["CBOX_HERMES_DELEGATE_BASE_URL"] = "http://127.0.0.1:11434"
        for k in ("CBOX_HERMES_DELEGATE_MODEL", "CBOX_HERMES_PROVIDER",
                  "CBOX_HERMES_MODEL_URL", "CBOX_HERMES_MODEL_NAME",
                  "CBOX_DELEGATION_DEPTH", "CBOX_MCP_DEPTH"):
            env.pop(k, None)
        msgs = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "hermes-delegate",
                        "arguments": {"prompt": "x"}}},
        ]
        payload = "".join(json.dumps(m) + "\n" for m in msgs).encode()
        script = str(ROOT / "etc" / "mcp" / "hermes_delegate_mcp.py")
        procs = [subprocess.Popen([sys.executable, script],
                                  stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
                 for _ in range(2)]
        for p in procs:
            p.stdin.write(payload)
            p.stdin.close()
        for p in procs:
            p.wait(timeout=30)
        spans = []
        cur = None
        with open(rec) as fh:
            for ln in fh:
                kind, val = ln.split()
                if kind == "start":
                    cur = float(val)
                else:
                    spans.append((cur, float(val)))
        self.assertEqual(len(spans), 2)
        spans.sort()
        self.assertGreaterEqual(spans[1][0], spans[0][1] - 0.05)


if __name__ == "__main__":
    unittest.main()
